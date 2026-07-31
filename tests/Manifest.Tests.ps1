BeforeDiscovery {
    $script:BucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
    $script:ManifestFiles = @(Get-ChildItem $script:BucketDir -Filter '*.json' |
        Where-Object { $_.BaseName -notin @('crvskkserv','mery','nomeiryoui','tclock-win10','umaumachecker','umaumacruise') })
}

Describe 'manifest の静的検査' {
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
