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

    It 'bin が .ps1 を直に指していない' {
        # scoop が .ps1 に張るシムは pwsh があればそちらを優先する
        # (生成された win11debloat.cmd を実測)。ところが Win11Debloat.ps1 は
        # PSEdition が Core なら「Windows PowerShell 5.1 で実行しろ」と出して
        # exit 1 する(本体 108 行目。Appx モジュールが pwsh で動かないため)。
        # つまり pwsh を入れている環境では .ps1 を直にシムした瞬間に使えなくなる。
        # Run.bat も駄目で、あちらは %* を渡さないので引数が黙って捨てられる
        $bin = ($script:Json.bin | ForEach-Object { $_ }) -join ' '
        $bin | Should -Not -Match 'Win11Debloat\.ps1'
        $bin | Should -Not -Match 'Run\.bat'
        $bin | Should -Match 'win11debloat\.cmd'
    }

    It 'pre_install が 5.1 を名指しするランチャーを用意する' {
        # bin の実体を作るのは pre_install。scoop は pre_install(54 行目)の後に
        # create_shims(59 行目)を呼ぶので、この順でなければシムが張れない
        $pre = ($script:Json.pre_install -join "`n")
        $pre | Should -Match 'win11debloat\.cmd'
        $pre | Should -Match 'powershell\.exe'
        $pre | Should -Match '%\*'          # 引数をそのまま渡すこと
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

    It 'pre_install と post_install が PowerShell として構文解析できる' {
        foreach ($key in 'pre_install', 'post_install') {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput(
                ($script:Json.$key -join "`n"), [ref]$null, [ref]$errs)
            @($errs | ForEach-Object { "${key}: $($_.Message)" }) -join '; ' |
                Should -BeNullOrEmpty
        }
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
        # 退避した実環境の persist を戻すのは、途中で何が落ちても必ずやる。
        # ここを素直に並べると、uninstall や Remove-Item が投げた時点で
        # 復元まで到達せず、利用者の保存設定とレジストリバックアップが
        # %TEMP% に取り残される。片付けの失敗より復元の方が重い
        try {
            scoop uninstall win11debloat 2>&1 | Out-Null
            if (Test-Path -LiteralPath $script:Persist) {
                Remove-Item -LiteralPath $script:Persist -Recurse -Force
            }
        } finally {
            if ($script:PersistBackup -and (Test-Path -LiteralPath $script:PersistBackup)) {
                if (Test-Path -LiteralPath $script:Persist) {
                    # 消し損ねている。上書きせず、退避したものを別名で残して気づけるようにする
                    Write-Warning "テストが作った $script:Persist を消せなかった。退避したデータは $script:PersistBackup に在る"
                } else {
                    Move-Item -LiteralPath $script:PersistBackup -Destination $script:Persist
                }
            }
            if ($script:WasInstalled) { scoop install $script:ManifestPath 2>&1 | Out-Null }
        }
    }

    It 'manifest から install できてシムが張られる' {
        scoop install $script:ManifestPath 2>&1 | Out-Null
        Test-Installed | Should -BeTrue
        Join-Path $script:ScoopRoot 'shims\win11debloat.cmd' | Should -Exist
    }

    It 'ランチャーが Windows PowerShell 5.1 で本体を起動し、引数をそのまま渡す' {
        # ここが歯の要。「シムのファイルが在る」だけを見ていると、pwsh が
        # 入った環境で本体が exit 1 するのに緑のまま通ってしまう(実際に一度
        # 見逃した)。配布するランチャーそのものを一時ディレクトリへ複製し、
        # 本体の代わりに素性を報告するスタブを置いて、どちらの PowerShell が
        # 起動したかと引数が届いたかを実行して確かめる。
        # 本物の Win11Debloat.ps1 は昇格して実機を書き換えるので走らせない
        $launcher = Join-Path $script:ScoopRoot 'apps\win11debloat\current\win11debloat.cmd'
        $launcher | Should -Exist

        $sandbox = Join-Path $env:TEMP ("win11debloat-launcher-" + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        try {
            # ランチャーは %~dp0 で隣の Win11Debloat.ps1 を呼ぶので、複製先の
            # スタブが拾われる
            Copy-Item -LiteralPath $launcher -Destination (Join-Path $sandbox 'win11debloat.cmd')
            Set-Content -LiteralPath (Join-Path $sandbox 'Win11Debloat.ps1') -Encoding ASCII -Value @(
                'param([switch]$DisableTelemetry)'
                'Write-Output "edition=$($PSVersionTable.PSEdition)"'
                'Write-Output "flag=$DisableTelemetry"'
            )

            $out = & cmd.exe /c "`"$(Join-Path $sandbox 'win11debloat.cmd')`" -DisableTelemetry" 2>&1 | Out-String

            # pwsh が起動していれば Core になり、本体なら exit 1 していた
            $out | Should -Match 'edition=Desktop'
            $out | Should -Match 'flag=True'
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
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
