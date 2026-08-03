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
}

Describe 'win11debloat のインストールと更新' {
    BeforeAll {
        $script:ManifestPath = Join-Path (Split-Path $PSScriptRoot) 'bucket\win11debloat.json'
        # scoop は SCOOP 環境変数でインストール先を変えられる。既定の
        # %USERPROFILE%\scoop 決め打ちだと、それ以外の場所に入れている環境で壊れる
        $script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
        $script:Persist   = Join-Path $script:ScoopRoot 'persist\win11debloat'

        # scoop list はグローバルインストールも並べる。それを「入っていた」と
        # 数えると、AfterAll のローカル install がグローバル版と二重になる。
        # このスイートが触るのはローカルだけなので、ローカルの実体だけを見る
        function script:Test-Installed {
            Test-Path -LiteralPath (Join-Path $script:ScoopRoot 'apps\win11debloat\current')
        }

        # このスイートは persist の中身を意図的に壊す。実環境の保存設定や
        # レジストリバックアップを巻き添えにしないよう、丸ごと退避して
        # AfterAll で戻す。uninstall では persist は消えない
        function script:Get-InstalledVersion {
            $m = Join-Path $script:ScoopRoot 'apps\win11debloat\current\manifest.json'
            if (Test-Path -LiteralPath $m) {
                (Get-Content -LiteralPath $m -Raw -Encoding UTF8 | ConvertFrom-Json).version
            }
        }

        $script:WasInstalled = Test-Installed
        # 入れ直すときの出どころを控える。無条件にこのリポジトリの manifest から
        # 入れ直すと、bucket 経由で入っていた場合に install.json の bucket が
        # リポジトリのパスに化け、版も勝手に上下する
        $script:OriginalSource  = $null
        $script:OriginalVersion = $null
        if ($script:WasInstalled) {
            $script:OriginalVersion = Get-InstalledVersion
            $installJson = Join-Path $script:ScoopRoot 'apps\win11debloat\current\install.json'
            if (Test-Path -LiteralPath $installJson) {
                $info = Get-Content -LiteralPath $installJson -Raw -Encoding UTF8 | ConvertFrom-Json
                $script:OriginalSource =
                    if ($info.bucket)  { "$($info.bucket)/win11debloat" }
                    elseif ($info.url) { $info.url }
            }
        }
        scoop uninstall win11debloat 2>&1 | Out-Null
        $script:PersistBackup = $null
        $script:PersistExistedAtStart = Test-Path -LiteralPath $script:Persist
        if ($script:PersistExistedAtStart) {
            # 退避先は同じ persist ディレクトリの隣に取る。%TEMP% が別ボリューム
            # だと Move-Item がコピー+削除に化け、途中で失敗すると部分コピーが残る
            $candidate = Join-Path (Split-Path $script:Persist) `
                ("win11debloat.testbackup-" + [Guid]::NewGuid().ToString('n'))
            Move-Item -LiteralPath $script:Persist -Destination $candidate -ErrorAction Stop

            # 「退避できた」と記録するのは、移動先が在って移動元が消えたことを
            # 確かめてから。先に記録すると、移動が中途で失敗したときに AfterAll が
            # 実データの方を消して復元できない
            if ((-not (Test-Path -LiteralPath $candidate)) -or (Test-Path -LiteralPath $script:Persist)) {
                throw "persist の退避に失敗した。実データを壊さないためテストを中止する ($script:Persist)"
            }
            $script:PersistBackup = $candidate
        }
    }

    AfterAll {
        # 退避した実環境の persist を戻すのは、途中で何が落ちても必ずやる。
        # ここを素直に並べると、uninstall や Remove-Item が投げた時点で
        # 復元まで到達せず、利用者の保存設定とレジストリバックアップが
        # %TEMP% に取り残される。片付けの失敗より復元の方が重い
        try {
            scoop uninstall win11debloat 2>&1 | Out-Null
        } finally {
            if ($script:PersistExistedAtStart -and -not $script:PersistBackup) {
                # 退避に失敗して BeforeAll が中止したケース。実データがその場に
                # 残っているので、片付けと称して消してはいけない
                Write-Warning "persist の退避に失敗していたため $script:Persist には手を触れていない"
            } else {
                try {
                    if (Test-Path -LiteralPath $script:Persist) {
                        Remove-Item -LiteralPath $script:Persist -Recurse -Force
                    }
                } finally {
                    if ($script:PersistBackup -and (Test-Path -LiteralPath $script:PersistBackup)) {
                        if (Test-Path -LiteralPath $script:Persist) {
                            # 消し損ねている。上書きせず、退避したものを残して気づけるようにする
                            Write-Warning "テストが作った $script:Persist を消せなかった。退避したデータは $script:PersistBackup に在る"
                        } else {
                            Move-Item -LiteralPath $script:PersistBackup -Destination $script:Persist
                        }
                    }
                }
            }
            if ($script:WasInstalled) {
                # 出どころを優先順に試す。scoop install は失敗しても throw せず、
                # 終了コードを見るだけでも「入ったこと」の確認にはならない。
                # 実体が戻ったかで判定する
                $sources = @()
                if ($script:OriginalSource) { $sources += $script:OriginalSource }
                if ($script:OriginalSource -ne $script:ManifestPath) { $sources += $script:ManifestPath }

                foreach ($src in $sources) {
                    scoop install $src 2>&1 | Out-Null
                    if (Test-Installed) { break }
                    Write-Warning "$src からの入れ直しに失敗した"
                }

                if (-not (Test-Installed)) {
                    # ここまで来たらテストが環境からアプリを取り上げたままになる。
                    # 黙って終わらせず、何を実行すれば戻るかまで出す
                    $hint = if ($script:OriginalSource) { $script:OriginalSource } else { $script:ManifestPath }
                    Write-Warning "win11debloat を入れ直せなかった。手で 'scoop install $hint' を実行すること"
                } else {
                    # 版まで元どおりとは限らない(bucket が先に進んでいれば上がる)。
                    # 黙って変えたことにしないで報せる
                    $after = Get-InstalledVersion
                    if ($script:OriginalVersion -and $after -ne $script:OriginalVersion) {
                        Write-Warning "入れ直しで版が $script:OriginalVersion から $after に変わった"
                    }
                }
            }
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
        # 呼び出し元の cwd はランチャーの置き場と別にする。同じにすると
        # 「cwd をアプリ配下へ移す」処理が有っても無くても同じ結果になり歯が無くなる
        $caller  = Join-Path $env:TEMP ("win11debloat-caller-"   + [Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        New-Item -ItemType Directory -Path $caller  -Force | Out-Null
        try {
            # ランチャーは %~dp0 で隣の Win11Debloat.ps1 を呼ぶので、複製先の
            # スタブが拾われる
            Copy-Item -LiteralPath $launcher -Destination (Join-Path $sandbox 'win11debloat.cmd')
            Set-Content -LiteralPath (Join-Path $sandbox 'Win11Debloat.ps1') -Encoding ASCII -Value @(
                'param([switch]$DisableTelemetry)'
                'Write-Output "edition=$($PSVersionTable.PSEdition)"'
                'Write-Output "flag=$DisableTelemetry"'
                'Write-Output "cwd=$($PWD.Path)"'
            )
            # cmd はコマンド名を解決するとき、既定でカレントディレクトリを
            # PATH より先に見る。拡張子まで書かれた名前には PATHEXT が効かない
            # ので、囮も powershell.exe そのものでなければ刺さらない
            # (powershell.bat を置いても素通りした。実測)。
            # 囮は呼び出し元の cwd に置く。攻撃者が書ける場所で叩かれる状況を模す
            Copy-Item -LiteralPath "$env:SystemRoot\System32\cmd.exe" `
                      -Destination (Join-Path $caller 'powershell.exe')

            # この環境には NoDefaultCurrentDirectoryInExePath=1 が入っていて、
            # cmd がカレントを検索から外すため乗っ取りが起きない。素の Windows に
            # この変数は無いので、外して既定の Windows を代表させる
            $savedNoDefault = $env:NoDefaultCurrentDirectoryInExePath
            Remove-Item Env:\NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue

            $outFile = Join-Path $sandbox 'out.txt'
            try {
                # 作業ディレクトリは Start-Process に指定する。Push-Location は
                # PowerShell 上の位置を変えるだけで子プロセスには効かず、PATH 上の
                # scoop シムが拾われて本物の Win11Debloat.ps1 が起動した(実測)
                Start-Process -FilePath (Join-Path $sandbox 'win11debloat.cmd') `
                    -ArgumentList '-DisableTelemetry' -WorkingDirectory $caller `
                    -NoNewWindow -Wait -RedirectStandardOutput $outFile
            } finally {
                if ($null -ne $savedNoDefault) {
                    $env:NoDefaultCurrentDirectoryInExePath = $savedNoDefault
                }
            }
            $out = Get-Content -LiteralPath $outFile -Raw

            # pwsh が起動していれば Core になり、本体なら exit 1 していた。
            # 囮を掴んでいれば、そもそもこの出力が出ない
            $out | Should -Match 'edition=Desktop'
            $out | Should -Match 'flag=True'

            # 本体は管理者でなければ Start-Process powershell -Verb RunAs で
            # 自分を入れ直す。ShellExecute はカレントディレクトリも探すため、
            # 呼び出し元の cwd に囮があるとその二段目で掴まれる。上流のコードは
            # 書き換えない方針なので、ランチャー側で cwd をアプリ配下へ移して
            # 囮の居ない場所から昇格させる
            $out | Should -Match ("cwd=" + [regex]::Escape($sandbox))
        } finally {
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $caller  -Recurse -Force -ErrorAction SilentlyContinue
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
