BeforeAll {
    $script:Manifest = Join-Path (Split-Path $PSScriptRoot) 'bucket\win11debloat.json'
    $script:Json = if (Test-Path -LiteralPath $script:Manifest) {
        Get-Content $script:Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
    }
}

Describe 'win11debloat manifest の静的検査' -Tag 'Static' {
    It 'manifest が存在する' {
        $script:Manifest | Should -Exist
    }

    It '必須キーが揃っている' {
        foreach ($key in 'version', 'description', 'homepage', 'license',
                         'url', 'hash', 'extract_dir', 'bin', 'checkver', 'autoupdate') {
            $script:Json.PSObject.Properties.Name | Should -Contain $key
        }
    }

    It 'url が Get.ps1 と同じ「リリースタグの source zip」を指している' {
        # Get.ps1 は (Invoke-RestMethod .../releases/latest).zipball_url を落とす。
        # zipball_url の展開先ディレクトリ名には commit の短縮 SHA が入って
        # 予測できないので、同一ツリーで展開先が Win11Debloat-<tag> に決まる
        # /archive/refs/tags/<tag>.zip を使う。release 資産の Get.ps1 本体を
        # 置く形にすると実行のたびに GitHub から取り直すことになり、
        # scoop の version 固定もキャッシュも効かなくなる
        $script:Json.url | Should -Be `
            "https://github.com/Raphire/Win11Debloat/archive/refs/tags/$($script:Json.version).zip"
    }

    It 'extract_dir が zip の実際の展開先と一致する' {
        $script:Json.extract_dir | Should -Be "Win11Debloat-$($script:Json.version)"
    }

    It 'autoupdate の url と extract_dir に $version が入っている' {
        $script:Json.autoupdate.url         | Should -Match '\$version'
        $script:Json.autoupdate.extract_dir | Should -Match '\$version'
    }

    It 'bin が Run.bat ではなく Win11Debloat.ps1 を指している' {
        # Run.bat は %* を渡さないので、シム経由の引数(-DisableTelemetry など)が
        # 黙って捨てられる。Win11Debloat.ps1 は自身が管理者権限を確認して
        # -Verb RunAs で再起動し、そのとき引数も引き継ぐので直接シムしてよい
        ($script:Json.bin | ForEach-Object { $_ }) -join ' ' | Should -Match 'Win11Debloat\.ps1'
        ($script:Json.bin | ForEach-Object { $_ }) -join ' ' | Should -Not -Match 'Run\.bat'
    }

    It 'ユーザーデータを persist している' {
        # アプリは $PSScriptRoot 直下へ書く。Backups はレジストリ復元機能の
        # 本体なので、これを失うと「元に戻す」ができなくなる
        foreach ($item in 'Config', 'Backups', 'Logs') {
            $script:Json.persist | Should -Contain $item
        }
    }

    It 'Config を persist しても同梱の既定値が凍らない仕掛けがある' {
        # Config には版ごとに更新される Apps.json / Features.json /
        # DefaultSettings.json が同梱されている。素直に persist すると
        # 初回インストール時の内容が居座り、新版で増えた機能が出てこない。
        #
        # scoop は persist 先が既にあるとき、zip から出たての $dir\Config を
        # 消さずに Config.original へ退避してから junction を張る
        # (scoop lib/install.ps1 の persist_data)。その新版の既定値を
        # 書き戻すのが post_install の仕事。実際に入れ替わることは
        # 「更新しても」の It が実機で確かめる
        $post = ($script:Json.post_install -join "`n")
        $post | Should -Match 'Config\.original'
        $post | Should -Match 'Copy-Item'
    }

    It 'post_install が PowerShell として構文解析できる' {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            ($script:Json.post_install -join "`n"), [ref]$null, [ref]$errs)
        @($errs | ForEach-Object { $_.Message }) -join '; ' | Should -BeNullOrEmpty
    }

    It 'BOM が付いていない' {
        $head = [IO.File]::ReadAllBytes($script:Manifest)[0..2]
        ($head -join ',') | Should -Not -Be '239,187,191'
    }

    It '改行が CRLF に揃っている' {
        $b = [IO.File]::ReadAllBytes($script:Manifest)
        $lf = 0; $crlf = 0
        for ($i = 0; $i -lt $b.Length; $i++) {
            if ($b[$i] -ne 10) { continue }
            if ($i -gt 0 -and $b[$i - 1] -eq 13) { $crlf++ } else { $lf++ }
        }
        $crlf | Should -BeGreaterThan 0
        $lf   | Should -Be 0
    }
}

Describe 'win11debloat のインストールと更新' {
    BeforeAll {
        $script:ManifestPath = Join-Path (Split-Path $PSScriptRoot) 'bucket\win11debloat.json'
        # scoop は SCOOP 環境変数でインストール先を変えられる。既定の
        # %USERPROFILE%\scoop 決め打ちだと、それ以外の場所に入れている環境で壊れる
        $script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
        $script:Persist   = Join-Path $script:ScoopRoot 'persist\win11debloat'

        function script:Test-Installed {
            (scoop list win11debloat 6>$null | Out-String) -match '(?m)^win11debloat\s'
        }

        # このスイートは persist の中身を意図的に壊す。実環境の保存設定や
        # レジストリバックアップを巻き添えにしないよう、丸ごと退避して
        # AfterAll で戻す。uninstall では persist は消えない
        $script:WasInstalled = Test-Installed
        scoop uninstall win11debloat 2>&1 | Out-Null
        $script:PersistBackup = $null
        if (Test-Path -LiteralPath $script:Persist) {
            $script:PersistBackup = Join-Path $env:TEMP ("win11debloat-persist-" + [Guid]::NewGuid().ToString('n'))
            Move-Item -LiteralPath $script:Persist -Destination $script:PersistBackup
        }
    }

    AfterAll {
        scoop uninstall win11debloat 2>&1 | Out-Null
        if (Test-Path -LiteralPath $script:Persist) {
            Remove-Item -LiteralPath $script:Persist -Recurse -Force
        }
        if ($script:PersistBackup) {
            Move-Item -LiteralPath $script:PersistBackup -Destination $script:Persist
        }
        if ($script:WasInstalled) { scoop install $script:ManifestPath 2>&1 | Out-Null }
    }

    It 'manifest から install できてシムが張られる' {
        scoop install $script:ManifestPath 2>&1 | Out-Null
        Test-Installed | Should -BeTrue
        # bin は .ps1 を指す。シムは @args で引数をそのまま渡すので
        # win11debloat -DisableTelemetry のような使い方ができる
        Join-Path $script:ScoopRoot 'shims\win11debloat.ps1' | Should -Exist
    }

    It 'ユーザーデータの置き場が persist されている' {
        # Backups はレジストリ復元機能の本体。ここを失うと「元に戻す」ができなくなる
        foreach ($name in 'Config', 'Backups', 'Logs') {
            Join-Path $script:Persist $name | Should -Exist
        }
    }

    It '同梱の既定値が Config に揃っている' {
        foreach ($name in 'Apps.json', 'DefaultSettings.json', 'Features.json') {
            Join-Path $script:Persist "Config\$name" | Should -Exist
        }
    }

    It '入れ直しても同梱の既定値が配布物のものに揃え直される' {
        # Config を素直に persist しただけだと、初回インストール時の既定値が
        # 居座って新版で増えた機能が画面に出てこない。post_install が
        # Config.original から書き戻していることを、中身の入れ替わりで確かめる
        $features = Join-Path $script:Persist 'Config\Features.json'
        $shipped  = (Get-FileHash -LiteralPath $features).Hash

        Set-Content -LiteralPath $features -Value '{"stale":true}'
        (Get-FileHash -LiteralPath $features).Hash | Should -Not -Be $shipped

        scoop uninstall win11debloat 2>&1 | Out-Null
        scoop install $script:ManifestPath 2>&1 | Out-Null

        (Get-FileHash -LiteralPath $features).Hash | Should -Be $shipped
    }

    It '入れ直しても利用者の保存設定は残る' {
        # LastUsedSettings.json は配布物に入っていないので、既定値の
        # 書き戻しに巻き込まれてはいけない
        $saved = Join-Path $script:Persist 'Config\LastUsedSettings.json'
        Set-Content -LiteralPath $saved -Value '{"Version":"1.0","Settings":[{"Name":"DisableTelemetry","Value":true}]}'

        scoop uninstall win11debloat 2>&1 | Out-Null
        scoop install $script:ManifestPath 2>&1 | Out-Null

        $saved | Should -Exist
        (Get-Content -LiteralPath $saved -Raw) | Should -Match 'DisableTelemetry'
    }

    It '退避ディレクトリが残らない' {
        # 書き戻しに使った Config.original を消し忘れると、$dir に版ごとの
        # ゴミが積もる。mery が post_install で *.original を掃除しているのと同じ趣旨
        Join-Path $script:ScoopRoot 'apps\win11debloat\current\Config.original' | Should -Not -Exist
    }
}
