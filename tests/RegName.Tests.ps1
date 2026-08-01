BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\expected-regnames.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Expected = $fixture.regnames
    $script:Families = $fixture.families
    $script:FontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
}

Describe 'レジストリのキー名' {
    It '期待値が 125 件ある' {
        @($script:Expected.PSObject.Properties).Count | Should -Be 125
    }

    It 'ファミリが 25 種ある' {
        @($script:Families).Count | Should -Be 25
    }

    It 'ファイルが GDI+ で期待どおりのファミリ名として読める' {
        # このテスト名は実際に検証している内容に合わせてある。ここで確認しているのは
        # 「このファイルを GDI+ のパーサーに読ませると期待どおりのファミリ名になる」
        # ことであって、「OS がこれをインストール済みフォントとして認識している」こと
        # ではない。後者(OS レベルでの可視性)は下の 'レジストリ値' 系のテスト
        # (独立実装の期待値どおりに登録されている / Windows 自身が付けた名前と
        # 同じ規則である)が担保する。
        #
        # 元は InstalledFontCollection で OS からの見え方を検証していたが、システム
        # 全体の InstalledFontCollection は、ユーザー単位 (HKCU) でインストールした
        # フォントを同一セッション内の新規プロセスへ確実には反映しないことが実機で
        # 判明した(HKCU にしか無いフォントが表示されない一方、たまたま HKLM に
        # 同名の別由来のフォントが既に入っているものは表示されてしまい、判定がこの
        # PC の既存インストール状況に依存してしまう)。そこで PrivateFontCollection
        # で実ファイルを直接読み込ませ、GDI+ 自身のパーサーが認識するファミリ名の
        # 集合で検証する方式に変えた(ファイル破損の検出という目的は保ったまま、
        # システムのフォントキャッシュ状態に依存しない)。
        # PrivateFontCollection.AddFontFile はファイルをロックしたままにする。これは
        # Dispose を呼んでも解放されない GDI+ 側の既知の挙動(実測。Dispose 後も
        # ハンドルが残り、プロセスが終わるまで消えない)。Pester は全テストファイルを
        # 同一プロセスで実行するため、ここでロックすると後続の Update.Tests.ps1 の
        # uninstall が "used by another process" で失敗する(実測で確認済み)。
        #
        # 代替として AddMemoryFont(バイト列をアンマネージメモリへコピーしてから
        # 読ませる方式)も試したが、Noto Sans JP / Noto Serif JP / NOTONOTO など
        # 複数ファミリがロードされなくなった(実測)。AddFontFile と AddMemoryFont は
        # GDI+ 内部で別経路を通り、後者は一部フォントを読めないため代替にならない。
        #
        # そこで検証そのものは Start-Job の子プロセスで行う。ロックは子プロセスの
        # 生存期間に閉じ込められ、ジョブが終われば(子プロセスが終了すれば)解放される。
        # 検証方法(AddFontFile で実ファイルを読ませる)は変えない
        $names = @($script:Expected.PSObject.Properties | ForEach-Object { $_.Name })
        $job = Start-Job -ScriptBlock {
            param($fontDir, $names)
            Add-Type -AssemblyName System.Drawing
            $pfc = New-Object System.Drawing.Text.PrivateFontCollection
            foreach ($n in $names) {
                $pfc.AddFontFile((Join-Path $fontDir $n))
            }
            $result = @($pfc.Families | Select-Object -ExpandProperty Name)
            $pfc.Dispose()
            $result
        } -ArgumentList $script:FontDir, $names
        $loaded = @(Receive-Job -Job $job -Wait -AutoRemoveJob)
        $missing = @($script:Families | Where-Object { $_ -notin $loaded })
        ($missing -join ', ') | Should -BeNullOrEmpty
    }

    It '独立実装の期待値どおりに登録されている' {
        $wrong = @()
        foreach ($p in $script:Expected.PSObject.Properties) {
            $actual = Get-FontRegValue -Name $p.Value
            if ($null -eq $actual) { $wrong += "$($p.Value) が未登録 ($($p.Name))" ; continue }
            $expectedPath = Join-Path $script:FontDir $p.Name
            if ($actual -ne $expectedPath) { $wrong += "$($p.Value) の値が $actual" }
        }
        ($wrong -join '; ') | Should -BeNullOrEmpty
    }

    It 'ファイル名由来のキーが作られていない' {
        Get-FontRegValue -Name 'HackGen-Regular (TrueType)'      | Should -BeNullOrEmpty
        Get-FontRegValue -Name 'UDEVGothicNF-Bold (TrueType)'    | Should -BeNullOrEmpty
        Get-FontRegValue -Name 'NotoSansJP-Regular (OpenType)'   | Should -BeNullOrEmpty
    }

    It 'Windows 自身が付けた名前と同じ規則である' {
        # 「どのレコードを採用するか」の順位付け (Windows/en-US > Windows/その他 >
        # Unicode > Mac) は nameid4.py と PowerShell 側インストーラーの両方が同じ
        # 規則を使っている。順位付けそのものが誤っていれば両方が同じように誤るので、
        # 両者を突き合わせるだけでは検証にならない。真のグラウンドトゥルースは
        # Windows 自身がこのマシンの HKLM に付けた名前で、以前は BIZ UDGothic
        # (OS 同梱) 1 ファミリだけで突き合わせていたが、それでは順位付けの正しさを
        # 1 種類のレコード構成でしか裏づけられない。
        #
        # ここでは「今回 scoop でインストールしたファイルと同一実体かどうか」は
        # 問わない。HKLM に登録されている、このフィクスチャのいずれかのファミリに
        # 該当する実ファイルを片っ端から集め、nameid4.py 自身の name_record() で
        # 直接 nameID 4 を読み直し、Windows がレジストリキーに使った文字列と
        # 一致するかを確認する。ファイル自体が scoop 版と違っていても構わない
        # ("同じ順位付けルールで読んだときに Windows の選択と一致するか" が
        # 見たい性質であって、"同一バイト列か" ではないため)。実際、このマシンの
        # HKLM には何年も前の別バージョンのファイルが残っている
        # (UDEVGothicNF-*.ttf など)が、順位付けルール自体はそれらに対しても
        # Windows の選択と一致する。
        #
        # サフィックス ((TrueType)/(OpenType)) は比較対象から外す。これは
        # nameID 4 の候補順位付けとは別の軸(ファイル拡張子からの機械的な変換)
        # で、HKCU 側の独立実装テストで自己無矛盾性を確認済み。一方 HKLM には
        # 拡張子と食い違う古い第三者登録が残っている(例: 実測で Noto Serif JP の
        # 一部 .otf は sfnt version が 'OTTO' にもかかわらず HKLM 上は
        # "(TrueType)" 登録)。これは順位付けルールの誤りではなく無関係な環境要因
        # なので、このテストの対象から外す。詳細は check-hklm-names.py 内のコメント。
        #
        # 既知の残存リスク: このレジストリ値名は通常 Windows 自身が nameID 4 から
        # 生成するが、MSI インストーラーの RegisterFonts アクションは Font テーブルに
        # 呼び出し側が指定した FontTitle を使うことができ、その場合は nameID 4 と
        # 食い違う名前がここに登録されうる(参考: MSI Font テーブル仕様)。このマシンで
        # 実際に集めた 117 件の候補では該当する食い違いは一件も無かった。今後もし
        # ここでの不一致が出た場合、まず「順位付けルールの実装ミスか」「MSI 由来の
        # 独自タイトルのような無関係な例外か」を切り分けてから対処すること
        # (このテストを安易に緩めない)。
        $hklm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
        $sysFontDir = "$env:WINDIR\Fonts"
        $sortedFamilies = @($script:Families | Sort-Object -Property Length -Descending)

        $candidates = @()
        foreach ($prop in $hklm.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            if ($prop.Value -like '*.ttc') { continue }   # nameid4.py は TTC 非対応
            $family = @($sortedFamilies | Where-Object { $prop.Name -eq $_ -or $prop.Name.StartsWith("$_ ") })[0]
            if (-not $family) { continue }
            $path = Join-Path $sysFontDir $prop.Value
            if (-not (Test-Path $path)) { continue }
            $candidates += [pscustomobject]@{ key = $prop.Name; file = $path; family = $family }
        }

        if ($candidates.Count -eq 0) {
            Set-ItResult -Skipped -Because 'HKLM に、このフィクスチャのファミリに該当する登録が一つも無い'
            return
        }

        $checker = Join-Path $PSScriptRoot 'tools\check-hklm-names.py'
        $payload = $candidates | ConvertTo-Json -Compress -Depth 3
        $resultJson = $payload | & python3 $checker
        if ($LASTEXITCODE -ne 0) { throw "check-hklm-names.py が失敗した: $resultJson" }
        $result = $resultJson | ConvertFrom-Json

        Write-Host ("HKLM ground-truth: {0}/{1} エントリ, {2}/{3} ファミリ ({4}) を裏付け確認" -f `
            $result.ok, $candidates.Count, @($result.families).Count, @($script:Families).Count, ($result.families -join ', '))

        (@($result.wrong) -join '; ') | Should -BeNullOrEmpty
    }
}
