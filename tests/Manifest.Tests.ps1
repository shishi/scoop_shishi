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
            ForEach-Object { [pscustomobject]@{ Name = $_.BaseName; Json = (Get-Content $_.FullName -Raw | ConvertFrom-Json) } })
    }

    It 'フォント manifest が 1 つ以上ある' {
        $script:Fonts.Count | Should -BeGreaterThan 0
    }

    It '<_.BaseName> に必須キーが揃っている' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
        foreach ($key in 'version', 'description', 'homepage', 'license', 'url', 'hash', 'checkver', 'autoupdate') {
            $j.PSObject.Properties.Name | Should -Contain $key
        }
    }

    It '<_.BaseName> の license は OFL-1.1' -ForEach $script:ManifestFiles {
        (Get-Content $_.FullName -Raw | ConvertFrom-Json).license | Should -Be 'OFL-1.1'
    }

    It '<_.BaseName> の autoupdate.url に $version が入っている' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
        ($j.autoupdate.url -join ' ') | Should -Match '\$version'
    }

    It '<_.BaseName> は extract_dir を持つなら autoupdate 側にも持つ' -ForEach $script:ManifestFiles {
        $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
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
}
