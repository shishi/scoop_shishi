BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $script:Repo     = Split-Path $PSScriptRoot
    $script:Manifest = Join-Path $script:Repo 'bucket\biz-udgothic.json'
    $script:FontDir  = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $script:Target   = Join-Path $script:FontDir 'BIZUDGothic-Regular.ttf'
    $script:RegName  = 'BIZ UDGothic (TrueType)'
    $script:Backup   = "$env:LOCALAPPDATA\scoop-font-backup\biz-udgothic-1.051"

    # $script:RegName は 4 ファイルのうち 1 つ分でしかない。「記録が無ければ uninstall は
    # 何も消さない」テストは残り 3 つの登録もわざと残したまま次のケースへ進むので、
    # Reset-Case はこの 4 つ全部を毎回消さないと、次のケース以降にレジストリの
    # 残骸が漏れて Assert-FontEnvRestored がずっと失敗し続ける
    $script:AllRegNames = @('BIZ UDGothic (TrueType)', 'BIZ UDGothic Bold (TrueType)',
                            'BIZ UDPGothic (TrueType)', 'BIZ UDPGothic Bold (TrueType)')

    # このスイートは $script:Target と $script:RegName を繰り返し消す。
    # 元から手動で入っていた場合に失われるので、中身ごと退避してから始める。
    #
    # 順序が重要。app が入った状態で退避すると scoop が置いたファイルを掴んでしまい、
    # その下に隠れている「本当の元ファイル」を取り逃がす。先に uninstall して
    # 素の状態を露出させてから退避する
    $script:WasInstalled = ((scoop list biz-udgothic 6>$null | Out-String) -match 'biz-udgothic')
    scoop uninstall biz-udgothic 2>&1 | Out-Null

    # このスイートが触りうるファイルは $script:Target だけではない。
    # 故障注入は BIZUDPGothic-Regular.ttf も消してディレクトリに置き換える。
    # biz-udgothic が配る 4 ファイルすべてを退避対象にする
    $script:Touched = @('BIZUDGothic-Bold.ttf', 'BIZUDGothic-Regular.ttf',
                        'BIZUDPGothic-Bold.ttf', 'BIZUDPGothic-Regular.ttf')

    $script:Vault = Join-Path $env:TEMP ("collision-vault-" + [Guid]::NewGuid().ToString('n'))
    New-Item $script:Vault -ItemType Directory -Force | Out-Null
    $script:VaultedFiles = @()
    # 配置先と同名の「ディレクトリ」が最初から存在していた場合も想定する（普段は無いはずだが、
    # このスイート自身が故障注入で作る種類の衝突なので、元からあったケースも同じ扱いで守る）
    $script:VaultedDirs = @()
    foreach ($n in $script:Touched) {
        $p = Join-Path $script:FontDir $n
        if (Test-Path $p -PathType Leaf) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $script:Vault $n) -Force
            $script:VaultedFiles += $n
        } elseif (Test-Path $p -PathType Container) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $script:Vault $n) -Recurse -Force
            $script:VaultedDirs += $n
        }
    }

    # 退避対象のファイルを指しているレジストリ値、および Reset-Case が名前だけで
    # 無条件に消す $script:AllRegNames の現在値をすべて控える。後者を漏らすと、
    # 元から別のパスを指していた登録が消えたきり戻らない
    $script:VaultedReg = @{}
    $props = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
    if ($props) {
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $leaf = Split-Path $p.Value -Leaf
            if (($leaf -in $script:Touched) -or ($p.Name -in $script:AllRegNames)) {
                $script:VaultedReg[$p.Name] = $p.Value
            }
        }
    }

    # $script:Backup（scoop-font-backup\biz-udgothic-1.051）自体も、割り込まれた
    # 別のインストール試行の唯一の復旧手段（journal・退避ファイル）を保持している
    # かもしれない。Reset-Case は毎回これを空にするので、消える前に丸ごと退避する
    $script:HadBackupDir = Test-Path $script:Backup
    $script:BackupVault  = Join-Path $script:Vault '__backup-dir__'
    if ($script:HadBackupDir) {
        Copy-Item -LiteralPath $script:Backup -Destination $script:BackupVault -Recurse -Force
    }

    function Reset-Case {
        scoop uninstall biz-udgothic 2>&1 | Out-Null
        # 故障注入がディレクトリを置いている場合があるので -Recurse で消す
        foreach ($n in $script:Touched) {
            $p = Join-Path $script:FontDir $n
            if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        foreach ($k in @($script:VaultedReg.Keys) + $script:AllRegNames) {
            Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
                -Name $k -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $script:Backup) { Remove-Item -LiteralPath $script:Backup -Recurse -Force }
    }

    function New-DecoyFont([string]$Path) {
        # 実在のフォントを土台に 1 バイトだけ変える。中身は別物だが name テーブルは読める
        $src = Join-Path $env:WINDIR 'Fonts\BIZUDGothic-Regular.ttf'
        $b = [IO.File]::ReadAllBytes($src)
        $b[$b.Length - 1] = [byte](($b[$b.Length - 1] + 1) % 256)
        [IO.File]::WriteAllBytes($Path, $b)
        return (Get-FileHash -LiteralPath $Path).Hash
    }

    $script:Before = Get-FontEnvSnapshot
}

AfterAll {
    # 各手順を独立した try/catch で囲む。1 つが終了エラーを投げても残りの手順は
    # 必ず走らせる。素直に並べると、途中の 1 行（例: scoop uninstall が投げる
    # DirectoryNotFoundException）で以降がすべて飛び、退避した本物のフォントや
    # レジストリを戻せないまま環境が汚れて残る事例が実際に起きた。
    # ただし黙って Write-Host するだけだと失敗が握りつぶされて見た目は green の
    # まま終わるので、失敗は $failures に集めて最後に throw し、Pester にも
    # 失敗として伝える
    $failures = New-Object Collections.ArrayList

    # 退避（$script:Vault）は「本物の元ファイル・レジストリ・退避ディレクトリ」の
    # 最後の控えなので、以下の復元・後始末がすべて成功したときだけ消す。途中で
    # 1 つでも失敗したら Vault は残し、次回に手で救出できるようにする（P1 対応）。
    # ここで宣言するのは、下の「配置先ディレクトリの後始末」も対象に含めるため。
    # これが未削除のまま残っていると、続く Copy-Item がディレクトリの「中へ」書き込んで
    # 見かけ上は成功し、元がファイルだったことを示す唯一の控え（Vault）を
    # 後始末に成功したと誤認して消してしまう
    $restoreOk = $true

    try { Reset-Case } catch { [void]$failures.Add("Reset-Case: $_"); Write-Host "Reset-Case に失敗: $_" -Foreground Red }

    # Reset-Case は $ErrorActionPreference='Stop' の下で複数手順を素直に並べただけの
    # 関数で、内部で 1 行が終了エラーを投げると（例: scoop uninstall が途中で失敗する）
    # 以降の自身の後始末（$script:Touched の削除など）が飛ぶ。ここは Reset-Case の
    # 成否に関わらず独立して効く安全網として、配置先に残っている物（ファイルでも
    # 故障注入のディレクトリでも）を丸ごと片付ける
    foreach ($n in $script:Touched) {
        try {
            $p = Join-Path $script:FontDir $n
            if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        } catch {
            $restoreOk = $false; [void]$failures.Add("配置先の後始末($n): $_")
            Write-Host "配置先($n)の後始末に失敗: $_" -Foreground Red
        }
    }

    # 退避しておいた実体を戻す。1 件が失敗しても他のファイルの復元を止めない
    # ように、foreach の外ではなく各要素ごとに try/catch を置く
    foreach ($n in $script:VaultedFiles) {
        try {
            Copy-Item -LiteralPath (Join-Path $script:Vault $n) -Destination (Join-Path $script:FontDir $n) -Force
        } catch {
            $restoreOk = $false; [void]$failures.Add("退避ファイルの復元($n): $_")
            Write-Host "退避ファイル($n)の復元に失敗: $_" -Foreground Red
        }
    }

    foreach ($n in $script:VaultedDirs) {
        try {
            $dest = Join-Path $script:FontDir $n
            if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            Copy-Item -LiteralPath (Join-Path $script:Vault $n) -Destination $dest -Recurse -Force
        } catch {
            $restoreOk = $false; [void]$failures.Add("退避ディレクトリの復元($n): $_")
            Write-Host "退避ディレクトリ($n)の復元に失敗: $_" -Foreground Red
        }
    }

    foreach ($k in $script:VaultedReg.Keys) {
        try {
            New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
                -Name $k -Value $script:VaultedReg[$k] -Force | Out-Null
        } catch {
            $restoreOk = $false; [void]$failures.Add("退避レジストリ値の復元($k): $_")
            Write-Host "退避レジストリ値($k)の復元に失敗: $_" -Foreground Red
        }
    }

    try {
        # 割り込まれた別の試行の退避ディレクトリがあれば、消える前の状態へ戻す。
        # これが無いと、このスイート自身は入っていなかった第三者の復旧データを消して終わる
        if ($script:HadBackupDir) {
            if (Test-Path $script:Backup) { Remove-Item -LiteralPath $script:Backup -Recurse -Force }
            Copy-Item -LiteralPath $script:BackupVault -Destination $script:Backup -Recurse -Force
        }
    } catch { $restoreOk = $false; [void]$failures.Add("退避ディレクトリ(backupDir)の復元: $_"); Write-Host "退避ディレクトリ(backupDir)の復元に失敗: $_" -Foreground Red }

    try {
        # Vault は上の復元が 1 つでも失敗していたら消さない。本物の元ファイルが
        # ここにしか残っていない可能性があるので、失敗を握りつぶして消してしまうと
        # 復旧手段を自分で断つことになる
        if ($restoreOk -and (Test-Path $script:Vault)) { Remove-Item -LiteralPath $script:Vault -Recurse -Force }
        elseif (-not $restoreOk) { Write-Host "復元に失敗があったため Vault を残す: $script:Vault" -Foreground Yellow }
    } catch { [void]$failures.Add("Vault の削除: $_"); Write-Host "Vault の削除に失敗: $_" -Foreground Red }

    try {
        # このスイートに入る前に入っていたなら入れ直す
        if ($script:WasInstalled) { scoop install $script:Manifest 2>&1 | Out-Null }
    } catch { [void]$failures.Add("テスト前の状態への再インストール: $_"); Write-Host "テスト前の状態への再インストールに失敗: $_" -Foreground Red }

    if (-not $script:WasInstalled) {
        try { Assert-FontEnvRestored -Before $script:Before }
        catch { [void]$failures.Add("環境の復元検証: $_"); Write-Host "環境が元に戻っていない: $_" -Foreground Red }
    }

    # 個々の手順は握りつぶさずに進めたが、1 つでも失敗していれば AfterAll 自体は
    # 失敗として報告する。黙って green にすると後始末の失敗に誰も気づけない
    if ($failures.Count -gt 0) {
        throw ("後始末で失敗した手順がある:`n  " + ($failures -join "`n  "))
    }
}

Describe '既存ファイルとの衝突' {
    BeforeEach { Reset-Case }

    It '内容の違う同名ファイルがあると退避してから上書きし、uninstall で戻る' {
        $decoyHash = New-DecoyFont $script:Target
        scoop install $script:Manifest 2>&1 | Out-Null

        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Not -Be $decoyHash
        (Join-Path $script:Backup 'BIZUDGothic-Regular.ttf') | Should -Exist

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Be $decoyHash
    }

    It 'Windows 標準の名前で登録済みなら上書きし、uninstall で元の値へ戻る' {
        New-DecoyFont $script:Target | Out-Null
        # installer が書く値（$script:Target）と同じ値を仕込むと、レジストリ処理が
        # 完全な no-op でも before/after/expected が全部同じになり、テストが
        # 何も検証できなくなる。installer が書く値とは違う番兵パスを仕込む
        $sentinel = Join-Path $script:FontDir 'Sentinel-Not-BIZUDGothic.ttf'
        New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
            -Name $script:RegName -Value $sentinel -Force | Out-Null

        scoop install $script:Manifest 2>&1 | Out-Null
        Get-FontRegValue -Name $script:RegName | Should -Be $script:Target

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        Get-FontRegValue -Name $script:RegName | Should -Be $sentinel
    }

    It 'install 後に第三者が差し替えたファイルは uninstall で消さない' {
        scoop install $script:Manifest 2>&1 | Out-Null
        $tamperedHash = New-DecoyFont $script:Target

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        $script:Target | Should -Exist
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Be $tamperedHash
    }

    It '記録が無ければ uninstall は何も消さない' {
        scoop install $script:Manifest 2>&1 | Out-Null
        Remove-Item (Join-Path (scoop prefix biz-udgothic) 'scoop-font-state.json') -Force
        Remove-Item (Join-Path $script:Backup 'scoop-font-state.json') -Force

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        $script:Target | Should -Exist
    }
}

Describe '変更途中の失敗' {
    BeforeEach { Reset-Case }

    It '配置先にディレクトリがあると下調べの検知で落ち、1 ファイルも変更されない（巻き戻しの経路は通らない）' {
        # 配置先と同名のディレクトリを作っておくと、installer は下調べ段階
        # （どのファイルも変更する前）でこれを検知して例外を投げる。この経路は
        # 「1 ファイルも変更しないうちに終わる」ことを守るものであり、catch 内の
        # 巻き戻し（退避からの復元・ハッシュ検証・レジストリの戻し）は通らない。
        # 巻き戻し自体を検証するテストは下の 'Move-Item' の項を見よ
        $blocker = Join-Path $script:FontDir 'BIZUDPGothic-Regular.ttf'
        if (Test-Path $blocker) { Remove-Item -LiteralPath $blocker -Force }
        New-Item $blocker -ItemType Directory -Force | Out-Null
        try {
            # installer が例外で失敗すると、scoop はその例外をそのまま呼び出し元へ伝播させる。
            # 2>&1 | Out-Null はエラーストリームを黙らせるだけで終端例外は捕まえないため、
            # ここで受け止めないと以降の検証が実行されないまま It が例外で落ちる。
            # ただし何でも握りつぶすと、ダウンロード失敗など無関係の理由で install が
            # 早期に失敗しただけでもこの後の「残っていない」検証が素通りしてしまう。
            # 配置先の衝突が原因だったことまで確認する
            $caught = $null
            try { scoop install $script:Manifest 2>&1 | Out-Null } catch { $caught = $_ }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -Match '配置先がファイルではない'

            # 先に処理された分が残っていないこと
            (Test-Path $script:Target) | Should -BeFalse
            Get-FontRegValue -Name $script:RegName | Should -BeNullOrEmpty
        } finally {
            if (Test-Path $blocker) { Remove-Item -LiteralPath $blocker -Recurse -Force }
        }
    }

    It '最後の配置先だけ書き込みを塞ぐと Move-Item で失敗し、先行する 3 ファイルが囮の内容へ巻き戻る' {
        # 下調べのディレクトリ検知は「1 ファイルも変更しないうちに落ちる」経路であり、
        # catch 内の巻き戻し（退避からの復元・ハッシュ検証・レジストリの戻し）を
        # 1 行も通らない。この経路を実際に通すには、変更が始まったあとで失敗させる
        # 必要がある。4 ファイルすべてに囮を置いたうえで、最後に処理される配置先
        # （ファイル名の並びで最後になる BIZUDPGothic-Regular.ttf）だけ書き込みを防ぐ
        # ハンドルで掴んでおく。先行する 3 ファイルは実際に置き換わり、最後で失敗し、
        # 巻き戻しが走って 3 ファイルとも囮の内容へ戻るはず。
        #
        # 完全排他（'ReadWrite', 'None'）は実測では狙いどおりに動かない。installer は
        # 下調べ段階で「配置先に元々あったファイルのハッシュ」を Get-FileHash で読む
        # （退避の検証に使うため、変更前に計画へ保存する）。'None' で読み取りも塞ぐと、
        # この下調べの時点で例外になり、1 ファイルも変更されないまま落ちる。これは
        # 上のディレクトリ検知テストと同じ経路であり、巻き戻しを一切通らない。
        # 読み取りは許可し書き込みだけ拒否する（'Read', 'Read'）と、下調べの読み取りと
        # 退避コピー（どちらも読み取りのみ）は素通りし、最後の Move-Item（配置先の
        # 削除・置換に書き込み権限が要る）だけが確実に失敗する。実測で確認済み。
        #
        # なお installer は Get-ChildItem の列挙順で処理するため、順序自体は
        # ドキュメント化された保証ではない。ロックした BIZUDPGothic-Regular.ttf が
        # 実際に何番目に処理されるかに関わらず、以下の検証は「ロックした 1 件を除く
        # 残りが何件でも、退避されていればその中身は囮のハッシュと一致する」ことだけを
        # 見る。これなら列挙順が変わっても壊れず、むしろ「ロックした 1 件より前に
        # 処理された分は実際に置き換わってから正しく巻き戻った」ことを検証できる
        $decoyHashes = @{}
        foreach ($n in $script:Touched) {
            $decoyHashes[$n] = New-DecoyFont (Join-Path $script:FontDir $n)
        }

        $lockedPath = Join-Path $script:FontDir 'BIZUDPGothic-Regular.ttf'
        $handle = [IO.File]::Open($lockedPath, 'Open', 'Read', 'Read')
        try {
            $caught = $null
            try { scoop install $script:Manifest 2>&1 | Out-Null } catch { $caught = $_ }
            $caught | Should -Not -BeNullOrEmpty
            # 何でも「例外が出た」だけで OK にすると、無関係の理由（ダウンロード失敗等）で
            # install が早期に落ちただけでも通ってしまい、下の「巻き戻った」検証が
            # 何も保証しないまま素通りしかねない。ロックした配置先を Move-Item が
            # 掴み損ねて失敗したことまで確認する（実測: FullyQualifiedErrorId は
            # MoveFileInfoItemIOError,Microsoft.PowerShell.Commands.MoveItemCommand、
            # TargetObject はロックしたパスそのもの）
            $caught.FullyQualifiedErrorId | Should -Match 'MoveItemCommand'
            "$($caught.TargetObject)" | Should -Be $lockedPath
        } finally {
            $handle.Close()
        }

        # 巻き戻しが単に「何もしなかった」のではなく、実際に置き換えてから
        # 戻したことの証拠。退避（backup）には置き換える直前の内容、つまり
        # 囮の内容が控えられているはず。installer は Get-ChildItem の列挙順で
        # 処理するため、ロックした 1 件が実際に何番目に処理されるかはドキュメント化
        # された保証ではない。列挙順が変わっても壊れないよう、件数を決め打ちせず
        # 「実際に退避が作られたもの」を動的に見て、1 件以上あることだけを必須にする
        # （0 件なら、ロックした 1 件が最初に処理されて 1 ファイルも変更されずに
        # 落ちたことになり、それはこのテストが証明したい経路ではない）
        $others = @($script:Touched | Where-Object { $_ -ne 'BIZUDPGothic-Regular.ttf' })
        $backedUp = @($others | Where-Object { Test-Path (Join-Path $script:Backup $_) })
        $backedUp.Count | Should -BeGreaterThan 0
        foreach ($n in $backedUp) {
            (Get-FileHash -LiteralPath (Join-Path $script:Backup $n)).Hash | Should -Be $decoyHashes[$n]
        }

        # 配置先自体も、置き換え→巻き戻しを経て囮の内容に戻っていること
        foreach ($n in $script:Touched) {
            (Get-FileHash -LiteralPath (Join-Path $script:FontDir $n)).Hash | Should -Be $decoyHashes[$n]
        }
        Get-FontRegValue -Name $script:RegName | Should -BeNullOrEmpty
    }
}

Describe 'uninstaller のロック耐性とジャーナル退役' {
    BeforeEach { Reset-Case }

    It 'ロックされた1件があっても残り3件は処理され、ジャーナルは退役し、解錠後の再インストール/再アンインストールで完全に消える' {
        # pre_uninstall は「配置先を自分自身へ Rename-Item してみる」ことでロックを検出し、
        # 失敗すると exit 1 でアンインストール全体（scoop-uninstall.ps1 の該当呼び出しそのもの）
        # を止める。これは実測で確認済み: Rename-Item と Remove-Item はどちらも
        # delete 共有権限を要求するため、uninstaller.script の Remove-Item を失敗させる
        # ロック（'Open','Read','Read'。書き込み・削除のみ拒否）は pre_uninstall の
        # Rename-Item も同じ理由で失敗させ、uninstaller.script の本体（今回 try/catch を
        # 追加した箇所）へ到達する前に scoop uninstall biz-udgothic 全体が失敗して終わる。
        # pre_uninstall は今回の修正対象ではなく、この不具合・修正はどちらも
        # uninstaller.script の中だけで完結する。そのため、ロックを再現している間は
        # uninstaller.script だけを manifest から取り出して直接実行し、対象の
        # コード（try/catch と退役の順序）をそのまま検証する。ロックが無い区間の
        # install/uninstall は通常どおり scoop コマンドを使い、scoop 自身の帳簿
        # （app ディレクトリ・current ジャンクション）の整合はそちらに任せる。
        scoop install $script:Manifest 2>&1 | Out-Null

        # $dir は「今アンインストールしている版のディレクトリ」（例: ...\biz-udgothic\1.051）。
        # scoop prefix が返す current ジャンクションの葉は 'current' であり、
        # そのまま使うと uninstaller.script 内の Split-Path -Leaf でバージョン文字列を
        # 取り違えるため、ジャンクションの実体を解決してから使う
        $versionDir = (Get-Item (scoop prefix biz-udgothic)).Target

        $lockedFile = 'BIZUDGothic-Regular.ttf'
        $lockedPath = Join-Path $script:FontDir $lockedFile
        $handle = [IO.File]::Open($lockedPath, 'Open', 'Read', 'Read')
        try {
            $manifestObj = Get-Content -LiteralPath $script:Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $uninstallerText = $manifestObj.uninstaller.script -join "`r`n"

            # uninstaller.script はこの2変数だけを呼び出し元スコープから読む
            $app = 'biz-udgothic'
            $dir = $versionDir
            { Invoke-Command ([scriptblock]::Create($uninstallerText)) } | Should -Not -Throw

            # ロックされていない残り3件は処理された(ファイル削除・レジストリ削除)
            $others = @($script:Touched | Where-Object { $_ -ne $lockedFile })
            foreach ($n in $others) {
                (Join-Path $script:FontDir $n) | Should -Not -Exist
            }
            # ロックされた1件はファイルの削除に失敗して残る
            $lockedPath | Should -Exist

            # ジャーナルは退役済み: アクティブな state.json は無く、retired.json がある
            (Join-Path $script:Backup 'scoop-font-state.json') | Should -Not -Exist
            (Join-Path $script:Backup 'scoop-font-state.retired.json') | Should -Exist

            # 未解決のエントリがあるので退避ディレクトリ自体は生き残る
            $script:Backup | Should -Exist

            # 注意: ここでもう一度 uninstaller.script を実行する検証は意図的に置かない。
            # backupDir 側の記録は既に退役済みなので、ここで再実行すると app ディレクトリ側の
            # 写し(フォールバック)まで退役させてしまう。その写しは、ロック解除後に続く
            # 「通常の scoop uninstall」(下記)がロックされた1件の後始末を終えるために
            # 読む唯一の記録なので、ここで消費すると後続の検証がロックされたファイルを
            # 永久に片付けられなくなる。中断後の再実行の安全性は、全て片付いた後
            # (記録がどこにも無い状態)で確認する形でこの Describe の末尾に別途置く
        } finally {
            $handle.Close()
        }

        # ロックを解いたので、scoop 自身の帳簿(app ディレクトリ・current ジャンクション)を
        # 整えるために通常の uninstall を一度通す。このとき backupDir 側のジャーナルは
        # 既に退役済みなので、uninstaller.script は app ディレクトリ側の写しを読み、
        # ロックのため残っていたファイルとレジストリ登録の後始末を完了させる
        scoop uninstall biz-udgothic 2>&1 | Out-Null

        # ここが本題の検証: 修正前の実装では、中断で退役し損ねたジャーナルを次の
        # install が「元から存在した(HadDest=true)」と誤読し、以後の uninstall は
        # 復元に化けて何も削除しないまま成功を報告し続けた。今回の修正
        # (try/catch で他のエントリを巻き添えにしない・退役を最初に無条件で行う)で
        # その連鎖が断たれていることを、再インストール→再アンインストールで確認する
        scoop install $script:Manifest 2>&1 | Out-Null
        scoop uninstall biz-udgothic 2>&1 | Out-Null

        foreach ($n in $script:Touched) {
            (Join-Path $script:FontDir $n) | Should -Not -Exist
        }
        foreach ($rn in $script:AllRegNames) {
            Get-FontRegValue -Name $rn | Should -BeNullOrEmpty
        }
        $script:Backup | Should -Not -Exist

        # 新規: 全て片付いた後(記録も退避ディレクトリも存在しない状態)にもう一度
        # 同じスクリプトを実行しても、記録が見つからないので何もせず安全に退却する
        # ことを確認する。中断後の再実行が「記録が無ければ何もしない」という
        # 宣言どおりに振る舞うことの直接的な確認
        { Invoke-Command ([scriptblock]::Create($uninstallerText)) } | Should -Not -Throw
        foreach ($n in $script:Touched) {
            (Join-Path $script:FontDir $n) | Should -Not -Exist
        }
        $script:Backup | Should -Not -Exist
    }

    It '退役の Move-Item 自体が失敗すると、ループへ入る前に例外を投げ、ファイルもレジストリも一切変更しない（退役をループの後ろへ戻す回帰を検出する）' {
        # このスイートの上の It は「失敗後にジャーナルが退役済みになっている」という
        # 終了状態だけを見ている。だが per-entry の try/catch（既存の修正）は失敗が
        # あってもループを最後まで走らせることを保証しているため、退役をループの
        # 前に置いても後ろに置いても、その終了状態は区別できない。つまり上の It は
        # 「try/catch がある」ことしか証明しておらず、退役の順序そのものは検出できない。
        #
        # 順序を直接検出するには、退役の Move-Item 自体を失敗させて「例外が投げられ、
        # かつ 1 件も変更されていない」ことを確認すればよい。退役が先頭にあれば、
        # 何も変更する前に例外で落ちるのでこの検証は通る。退役が末尾へ戻されていれば、
        # ループは既に全ファイル・全レジストリを変更し終えてから退役に失敗するので、
        # 「何も変更されていない」という検証が確実に落ちる
        scoop install $script:Manifest 2>&1 | Out-Null

        $versionDir = (Get-Item (scoop prefix biz-udgothic)).Target
        $manifestObj = Get-Content -LiteralPath $script:Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $uninstallerText = $manifestObj.uninstaller.script -join "`r`n"

        # backupDir 側のジャーナルが正として使われる。その退役先
        # (scoop-font-state.retired.json) をあらかじめ「ディレクトリ」として
        # 用意しておくだけでは、Move-Item -Force は「ディレクトリの中へ移動」を
        # 試みて成功してしまう（実測で確認済み）。中に移動元と同じ名前
        # (scoop-font-state.json) の「ディレクトリ」も置いておくと、-Force は
        # ファイルの上書きは許すがディレクトリをファイルで置き換えることはできない
        # ため、これで確実に Move-Item が失敗する
        $retiredBlock = Join-Path $script:Backup 'scoop-font-state.retired.json'
        New-Item $retiredBlock -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $retiredBlock 'scoop-font-state.json') -ItemType Directory -Force | Out-Null

        $beforeHashes = @{}
        foreach ($n in $script:Touched) {
            $beforeHashes[$n] = (Get-FileHash -LiteralPath (Join-Path $script:FontDir $n)).Hash
        }
        $beforeReg = @{}
        foreach ($rn in $script:AllRegNames) {
            $beforeReg[$rn] = Get-FontRegValue -Name $rn
        }

        # uninstaller.script はこの2変数だけを呼び出し元スコープから読む
        $app = 'biz-udgothic'
        $dir = $versionDir
        try {
            { Invoke-Command ([scriptblock]::Create($uninstallerText)) } | Should -Throw

            foreach ($n in $script:Touched) {
                (Get-FileHash -LiteralPath (Join-Path $script:FontDir $n)).Hash | Should -Be $beforeHashes[$n]
            }
            foreach ($rn in $script:AllRegNames) {
                Get-FontRegValue -Name $rn | Should -Be $beforeReg[$rn]
            }

            # ジャーナル本体もまだ退役されていないこと（Move-Item が完全に
            # 失敗し、何も動かしていないことの直接的な証拠）
            (Join-Path $script:Backup 'scoop-font-state.json') | Should -Exist
        } finally {
            # 自分で仕込んだ障害物を片付け、以降（次の BeforeEach / AfterAll）の
            # 本物の scoop uninstall が正常に退役できる状態へ戻す
            Remove-Item -LiteralPath $retiredBlock -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
