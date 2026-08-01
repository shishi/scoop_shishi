BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $script:Repo    = Split-Path $PSScriptRoot
    $script:FontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $script:New     = Join-Path $script:Repo 'bucket\hackgen.json'

    # scoop list <query> は部分一致するため "hackgen" は "hackgen-nf" にも
    # マッチしてしまう(実測: scoop list hackgen で両方の行が返る)。行頭を
    # 空白で区切って厳密に "hackgen" だけを見る
    # script: を付けて宣言する。BeforeAll のローカル関数のままだと後続の It
    # ブロックから見えない(実測。Pester は $script: 変数はブリッジするが、
    # 素の関数宣言のスコープはブリッジしない)
    function script:Test-HackgenListed([string]$Pattern) {
        (scoop list hackgen 6>$null | Out-String) -match "(?m)^hackgen\s+$Pattern"
    }

    # スナップショットは強制 uninstall より「前」に取る。AfterAll で入れ直した後、
    # 「本当に元どおりか」を確かめる基準はこちら(Lifecycle.Tests.ps1 と同じ方針)。
    # $script:Before(下)は hackgen が無い状態の基準であり、hackgen が
    # 元々入っていた場合の「真の元の状態」にはならない
    $script:TrueBefore = Get-FontEnvSnapshot

    # 本番の hackgen が入っていたら一旦外す。終了時に入れ直す
    $script:WasInstalled = (Test-HackgenListed '\S+')
    scoop uninstall hackgen 2>&1 | Out-Null
    $script:Before = Get-FontEnvSnapshot

    # 一時 bucket を作る。scoop bucket add は git リポジトリを要求する
    $script:TmpBucket = Join-Path $env:TEMP ("fonttest-" + [Guid]::NewGuid().ToString('n'))
    New-Item (Join-Path $script:TmpBucket 'bucket') -ItemType Directory -Force | Out-Null
    $script:TmpManifest = Join-Path $script:TmpBucket 'bucket\hackgen.json'

    # 現行 manifest から v2.9.1 を指す旧版を作る
    $m = Get-Content $script:New -Raw -Encoding UTF8 | ConvertFrom-Json
    # 新版として何が入るかは hackgen.json 自体(autoupdate で変わりうる)から取る。
    # ここでリテラルの現行バージョンをハードコードすると、次に hackgen が
    # バージョンアップしたときに「更新は正しく動いているのにテストだけ落ちる」
    # ことになる
    $script:NewVersion = $m.version
    $m.version     = '2.9.1'
    $m.url         = 'https://github.com/yuru7/HackGen/releases/download/v2.9.1/HackGen_v2.9.1.zip'
    $m.extract_dir = 'HackGen_v2.9.1'
    $m.hash        = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
    $m | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:TmpManifest -Encoding UTF8
    # scoop は SCOOP 環境変数でインストール先を変えられる。既定の
    # %USERPROFILE%\scoop 決め打ちだと、それ以外の場所に入れている環境で壊れる
    $script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
    & "$script:ScoopRoot\apps\scoop\current\bin\checkhashes.ps1" `
        -App 'hackgen' -Dir (Split-Path $script:TmpManifest) -Update 2>&1 | Out-Null

    Push-Location $script:TmpBucket
    git init --quiet 2>&1 | Out-Null
    git add . 2>&1 | Out-Null
    git -c user.email=test@example.invalid -c user.name=test commit --quiet -m old 2>&1 | Out-Null
    Pop-Location

    # Windows パスをそのまま渡すと "is not a valid Git URL!" で拒否される（実測）。
    # file URI に変換する。bucket 名は固定文字列だと、たまたま同名の bucket が
    # 既に登録されていた場合にそれを乗っ取って AfterAll で消してしまう事故になる。
    # 一時ディレクトリと同じ GUID を使い、衝突しない名前にする
    # (Split-Path の Leaf は既に "fonttest-<guid>" なので、そのまま使う)
    $script:BucketName = Split-Path $script:TmpBucket -Leaf
    scoop bucket add $script:BucketName ([Uri]$script:TmpBucket).AbsoluteUri 2>&1 | Out-Null
}

AfterAll {
    scoop uninstall hackgen 2>&1 | Out-Null
    scoop bucket rm $script:BucketName 2>&1 | Out-Null
    if (Test-Path $script:TmpBucket) { Remove-Item $script:TmpBucket -Recurse -Force }
    if ($script:WasInstalled) { scoop install $script:New 2>&1 | Out-Null }
    # 入れ直した結果が元どおりかまで確かめる(WasInstalled の分岐に関わらず常に)。
    # 試みるだけでは、再インストールが冪等でなかったときに緑のまま環境がずれる。
    # 比較対象は $script:TrueBefore(強制 uninstall より前の、真の元の状態)であって
    # $script:Before(hackgen が無い状態)ではない — hackgen が元々入っていた場合、
    # 後者を基準にすると「正しく入れ直せた」ことがむしろ差分として検出されてしまう
    # (Lifecycle.Tests.ps1 と同じ方針)
    Assert-FontEnvRestored -Before $script:TrueBefore
}

Describe '旧版から新版への更新' {
    It '旧版が bucket 経由で入る' {
        scoop install "$script:BucketName/hackgen" 2>&1 | Out-Null
        Test-HackgenListed '2\.9\.1' | Should -BeTrue
    }

    It 'scoop update で新版へ入れ替わる' {
        # 一時 bucket の manifest を新版に差し替えてコミットし、scoop update に拾わせる
        Copy-Item -LiteralPath $script:New -Destination $script:TmpManifest -Force
        Push-Location $script:TmpBucket
        git add . 2>&1 | Out-Null
        git -c user.email=test@example.invalid -c user.name=test commit --quiet -m new 2>&1 | Out-Null
        Pop-Location

        # 引数無しの `scoop update` は Scoop 本体と登録済みの全 bucket
        # (main/extras/... を含む)を更新してしまい、この統合テストの範囲を
        # 超えた副作用になる(実測: Updating Scoop... / Updating Buckets... が
        # 全 bucket に対して走る)。scoop がこの一時 bucket を clone した先だけを
        # 直接 git pull し、影響範囲をこのテストに閉じる
        git -C (Join-Path $script:ScoopRoot "buckets\$script:BucketName") pull --quiet 2>&1 | Out-Null
        scoop update hackgen 2>&1 | Out-Null  # ここで旧版の uninstaller → 新版の installer が走る
        Test-HackgenListed ([regex]::Escape($script:NewVersion)) | Should -BeTrue
    }

    It '旧版(2.9.1)の退避ディレクトリが残らない' {
        # 発見した不具合の回帰テスト: scoop update は scoop-update.ps1 の中で
        # $version を新版へ再代入した後、そのスコープのまま旧版の uninstaller
        # フックを呼ぶため、共有 uninstaller が $backupDir を組み立てるのに
        # (信用できない)$version を使うと、旧版(2.9.1)の退避ディレクトリを
        # 一度も参照できず、掃除されずオーファンとして残り続けていた(実機で確認済み)。
        # $dir から復元するよう直したので、ここで残っていないことを確認する
        Join-Path "$env:LOCALAPPDATA\scoop-font-backup" 'hackgen-2.9.1' | Should -Not -Exist
    }

    It '新版のファイルがすべて登録されている' {
        foreach ($n in 'HackGen-Bold.ttf', 'HackGen-Regular.ttf',
                       'HackGenConsole-Bold.ttf', 'HackGenConsole-Regular.ttf') {
            Join-Path $script:FontDir $n | Should -Exist
        }
    }

    It '35 系が混ざっていない' {
        @(Get-ChildItem $script:FontDir -Filter 'HackGen35*' -Force) | Should -BeNullOrEmpty
    }

    It '関係の無いフォントが影響を受けていない' {
        # 更新の前後で他ファミリの登録が変わっていないこと
        $now = Get-FontEnvSnapshot
        $others = @($now.Registry.Keys | Where-Object { $_ -notlike 'HackGen*' })
        $before = @($script:Before.Registry.Keys | Where-Object { $_ -notlike 'HackGen*' })
        Compare-Object $before $others | Should -BeNullOrEmpty
    }

    It 'uninstall で完全に戻る' {
        scoop uninstall hackgen 2>&1 | Out-Null
        { Assert-FontEnvRestored -Before $script:Before } | Should -Not -Throw
    }
}
