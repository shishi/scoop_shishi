BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ScoopApp.psm1') -Force
    # scoop は SCOOP 環境変数でインストール先を変えられる。既定の
    # %USERPROFILE%\scoop 決め打ちだと、それ以外の場所に入れている環境で壊れる
    # root は 2 つ要る。混ぜてはいけない。
    #   ScoopRoot     : フォント app の所在。global 専用なので global 側。
    #                   per-user を見ると「入っていない」と誤判定して復元せず終わる
    #   ScoopUserRoot : scoop 本体(bin\checkhashes.ps1)と buckets の置き場。
    #                   scoop 自身は per-user インストールで、global 側には存在しない
    #                   (実測: global root を見て CommandNotFoundException で落ちた)
    $script:ScoopRoot     = Get-ScoopGlobalRoot
    $script:ScoopUserRoot = Get-ScoopUserRoot
    $script:Repo    = Split-Path $PSScriptRoot
    $script:FontDir = "$env:WINDIR\Fonts"
    $script:New     = Join-Path $script:Repo 'bucket\hackgen.json'

    # 「関係の無いフォントが影響を受けていない」で hackgen 自身の変更を除外するための
    # 正確な 4 件。hackgen-nf は "HackGen Console NF *" という、"HackGen" で始まる
    # 別の登録名を持つため、ワイルドカード -notlike 'HackGen*' で除外すると
    # hackgen-nf まで一緒に隠れてしまう(全 16 manifest が同じ共有スクリプトを使う
    # ため、hackgen の更新で hackgen-nf が巻き添えを食う不具合こそこのテストが
    # 捕まえるべきシナリオ)。ファイル名→登録名の正本は
    # tests/fixtures/expected-regnames.json なのでそこから読む
    $fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\expected-regnames.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:HackgenOwnRegNames = @(
        $fixture.regnames.'HackGen-Bold.ttf',
        $fixture.regnames.'HackGen-Regular.ttf',
        $fixture.regnames.'HackGenConsole-Bold.ttf',
        $fixture.regnames.'HackGenConsole-Regular.ttf'
    )

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
    # 入れ直すときの出どころを uninstall の前に控える。控えずに $script:New
    # (リポジトリ内の manifest)から入れ直すと install.json にそのパスが焼き付き、
    # scoop update が bucket ではなくそのファイルを見続けることになる
    $script:OrigSource  = Get-AppInstallSource    -App 'hackgen' -ScoopRoot $script:ScoopRoot
    $script:OrigVersion = Get-AppInstalledVersion -App 'hackgen' -ScoopRoot $script:ScoopRoot
    scoop uninstall -g hackgen 2>&1 | Out-Null
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
    & "$script:ScoopUserRoot\apps\scoop\current\bin\checkhashes.ps1" `
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
    scoop uninstall -g hackgen 2>&1 | Out-Null
    scoop bucket rm $script:BucketName 2>&1 | Out-Null
    if (Test-Path $script:TmpBucket) { Remove-Item $script:TmpBucket -Recurse -Force }
    if ($script:WasInstalled) {
        Restore-AppInstall -App 'hackgen' -ScoopRoot $script:ScoopRoot `
            -OriginalSource $script:OrigSource -OriginalVersion $script:OrigVersion `
            -Fallback $script:New -Global
    }
    # 入れ直した結果が元どおりかまで確かめる(WasInstalled の分岐に関わらず常に)。
    # 試みるだけでは、再インストールが冪等でなかったときに緑のまま環境がずれる。
    # 比較対象は $script:TrueBefore(強制 uninstall より前の、真の元の状態)であって
    # $script:Before(hackgen が無い状態)ではない — hackgen が元々入っていた場合、
    # 後者を基準にすると「正しく入れ直せた」ことがむしろ差分として検出されてしまう
    # (Lifecycle.Tests.ps1 と同じ方針)
    Assert-FontEnvRestored -Before $script:TrueBefore
}

# 'RealScoop' タグを付けて既定の実行から外してある(run.ps1 が除外する)。
# scoop update そのもの(旧版の uninstaller → 新版の installer が同一プロセスで
# 走る順序)を検証するので実 scoop が必要で、サンドボックスへは移せない。
# global 専用になったことで %WINDIR%\Fonts のフォントは OS がロードされており、
# uninstall が「使用中」で失敗して環境に残骸が残ることがある。
# 走らせるのは明示の選択にする:
#   .\tests\run.ps1 -IncludeRealScoop
# 昇格が必要
Describe '旧版から新版への更新' -Tag 'RealScoop', 'Update' {
    It '旧版が bucket 経由で入る' {
        scoop install -g "$script:BucketName/hackgen" 2>&1 | Out-Null
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
        git -C (Join-Path $script:ScoopUserRoot "buckets\$script:BucketName") pull --quiet 2>&1 | Out-Null
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
        Join-Path "$env:ProgramData\scoop-font-backup" 'hackgen-2.9.1' | Should -Not -Exist
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
        # 更新の前後で他ファミリの登録が変わっていないこと。除外するのは
        # hackgen 自身の 4 件のみ(HackGen Console NF * を含め、それ以外は
        # すべて比較対象に残す)。
        # キー名の集合だけでなく値も比較する(Assert-RegistryUnchangedExcept)。
        # キー名の比較だけでは、更新処理が誤って他フォントの登録値を書き換えても
        # (キー自体は増減しないため)見逃してしまう
        $now = Get-FontEnvSnapshot
        { Assert-RegistryUnchangedExcept -Before $script:Before -Now $now -ExceptNames $script:HackgenOwnRegNames } |
            Should -Not -Throw
    }

    It 'uninstall で完全に戻る' {
        scoop uninstall -g hackgen 2>&1 | Out-Null
        { Assert-FontEnvRestored -Before $script:Before } | Should -Not -Throw
    }
}
