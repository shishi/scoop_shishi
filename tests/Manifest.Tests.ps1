BeforeDiscovery {
    $script:BucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
    $script:ManifestFiles = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
        Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') })
}

Describe 'manifest の静的検査' -Tag 'Static' {
    BeforeAll {
        $script:BucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
        $script:Fonts = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
            Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') } |
            ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Json = (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } })
        # BeforeDiscovery の $script:ManifestFiles は Discovery フェーズ限定で、
        # -ForEach では使えても Run フェーズの通常 It 本体からは見えない（実測: Count が 0 になる）。
        # ここで BeforeAll として同じフィルタを再設定し、Run フェーズでも参照できるようにする
        $script:ManifestFiles = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
            Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') })
    }

    It 'フォント manifest が 1 つ以上ある' {
        $script:Fonts.Count | Should -BeGreaterThan 0
    }

    It '<_.BaseName> に必須キーが揃っている' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in 'version', 'description', 'homepage', 'license', 'url', 'hash', 'checkver', 'autoupdate') {
            $j.PSObject.Properties.Name | Should -Contain $key
        }
    }

    It '<_.BaseName> の license は OFL-1.1' -ForEach $script:ManifestFiles {
        (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).license | Should -Be 'OFL-1.1'
    }

    It '<_.BaseName> の autoupdate.url に $version が入っている' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        ($j.autoupdate.url -join ' ') | Should -Match '\$version'
    }

    It '<_.BaseName> は extract_dir を持つなら autoupdate 側にも持つ' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'extract_dir') {
            $j.autoupdate.PSObject.Properties.Name | Should -Contain 'extract_dir'
        }
    }

    It 'installer.script が全 manifest で完全に同一' {
        $sets = $script:Fonts | ForEach-Object { ($_.Json.installer.script -join "`n") } | Select-Object -Unique
        $sets.Count | Should -Be 1
    }

    It 'pre_uninstall が全 manifest で完全に同一' {
        $sets = $script:Fonts | ForEach-Object { ($_.Json.pre_uninstall -join "`n") } | Select-Object -Unique
        $sets.Count | Should -Be 1
    }

    It 'uninstaller.script が全 manifest で完全に同一' {
        $sets = $script:Fonts | ForEach-Object { ($_.Json.uninstaller.script -join "`n") } | Select-Object -Unique
        $sets.Count | Should -Be 1
    }

    It '共通スクリプトのフィルタは 35 のみ（Discord を除外していない）' {
        $s = ($script:Fonts[0].Json.installer.script -join "`n")
        $s | Should -Match "notmatch '35'"
        $s | Should -Not -Match 'Discord'
    }

    It 'installer が global インストールを拒否する' {
        ($script:Fonts[0].Json.installer.script -join "`n") | Should -Match '\$global'
    }

    It 'installer がレジストリキー($regKey)を作成してから書き込む' {
        # 一度も per-user フォントを入れたことが無いプロファイルでは
        # HKCU\...\Fonts キー自体が存在せず、New-ItemProperty -Force はキーの
        # 作成まではしないため書き込みが失敗する(実測)。振る舞いテストには
        # scratch hive が要り割に合わないので、共有 installer に
        # キー作成が入っていることを静的に検査する
        $s = ($script:Fonts[0].Json.installer.script -join "`n")
        $s | Should -Match 'New-Item\s+-Path\s+\$regKey\s+-Force'
    }

    It '<_.BaseName> に BOM が付いていない' -ForEach $script:ManifestFiles {
        $head = [IO.File]::ReadAllBytes($_.FullName)[0..2]
        ($head -join ',') | Should -Not -Be '239,187,191'
    }

    It '<_.BaseName> の改行が CRLF に揃っている' -ForEach $script:ManifestFiles {
        $b = [IO.File]::ReadAllBytes($_.FullName)
        $lf = 0; $crlf = 0
        for ($i = 0; $i -lt $b.Length; $i++) {
            if ($b[$i] -ne 10) { continue }
            if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $lf++ }
        }
        $crlf | Should -BeGreaterThan 0
        $lf   | Should -Be 0
    }

    It 'sync_scripts.py を走らせても manifest が変化しない（冪等）' {
        # sync_scripts.py と scoop の checkhashes.ps1 が行末を潰し合い、
        # 実質的な変更が無いのに全 manifest へ差分が出続けた実績がある。
        # 片方を直しても、もう一方が将来変わればまた再発するのでテストで固定する
        $repo   = Split-Path $PSScriptRoot
        $before = @{}
        foreach ($f in $script:ManifestFiles) { $before[$f.FullName] = [IO.File]::ReadAllBytes($f.FullName) }

        & python3 (Join-Path $repo 'tests\tools\sync_scripts.py') *> $null
        $LASTEXITCODE | Should -Be 0

        $changed = @()
        foreach ($f in $script:ManifestFiles) {
            $now = [IO.File]::ReadAllBytes($f.FullName)
            if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$before[$f.FullName], [byte[]]$now)) {
                $changed += $f.Name
            }
        }
        ($changed -join ', ') | Should -BeNullOrEmpty
    }

    It 'installer と uninstaller が OS へフォントの増減を通知する' {
        # レジストリ登録とファイル配置だけでは、あとから起動したプロセスからも
        # DirectWrite にフォントが見えない(実測: plemoljp は HKCU に 48 件登録済み・
        # ファイルも実在の状態でファミリごと見えず、どのアプリからも使えなかった)。
        # 振る舞いは FontNotify.Tests.ps1 が検証する。ここでは将来のリファクタで
        # この呼び出しが黙って落ちないよう、静的にも留め金を掛けておく
        $j = $script:Fonts[0].Json
        $inst = ($j.installer.script -join "`n")
        $unin = ($j.uninstaller.script -join "`n")

        $inst | Should -Match 'AddFontResourceW'
        $unin | Should -Match 'RemoveFontResourceW'
        # WM_FONTCHANGE = 0x1D。これを配らないと起動済みのアプリが一覧を作り直さない
        foreach ($s in $inst, $unin) {
            $s | Should -Match 'SendMessageTimeout'
            $s | Should -Match '0x1D'
        }
    }

    It '通知の失敗が install/uninstall を巻き添えにしない' {
        # フォント自体は既に置かれている。通知できないことを理由に throw すると
        # 成功した変更まで巻き戻すことになり、実害の方が大きい。
        # $notifyFonts の本体と Add-Type の両方が try/catch の中にあること
        foreach ($key in 'installer', 'uninstaller') {
            $s = ($script:Fonts[0].Json.$key.script -join "`n")
            # Add-Type は環境によっては失敗しうるので、それ自体を包んである
            $s | Should -Match '(?s)try\s*\{[^}]*Add-Type\s+-Namespace\s+''ScoopFont'''
            # 通知本体も包んである。catch 側は Write-Host で警告するだけ
            $s | Should -Match '(?s)\$notifyFonts\s*=\s*\{.*?try\s*\{.*?\}\s*catch\s*\{[^}]*Write-Host'
        }
    }

    It '共通スクリプトが読み取り専用の自動変数へ代入していない' {
        # $pid への代入で全 manifest が動かなくなった実績がある。
        # 関数スコープの中でも Cannot overwrite variable PID で落ちる
        $reserved = 'pid', 'host', 'error', 'true', 'false', 'null', 'pshome', 'shellid', 'executioncontext'
        $j = $script:Fonts[0].Json
        $all = (@($j.installer.script) + @($j.pre_uninstall) + @($j.uninstaller.script)) -join "`n"
        $bad = @($reserved | Where-Object { $all -match ('\$' + $_ + '\s*=[^=]') })
        ($bad -join ', ') | Should -BeNullOrEmpty
    }
}
