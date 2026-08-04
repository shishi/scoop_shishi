BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ScoopApp.psm1') -Force
    # フォント manifest は global 専用。per-user の root を見ると、global で
    # 入っているアプリを「入っていない」と誤判定して復元せず終わる
    $script:ScoopRoot = Get-ScoopGlobalRoot
    $script:Repo     = Split-Path $PSScriptRoot
    $script:Manifest = Join-Path $script:Repo 'bucket\biz-udgothic.json'
    # global 専用なので配置先は %WINDIR%\Fonts。このスイートは昇格が必要
    $script:FontDir  = "$env:WINDIR\Fonts"
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'このスイートは global install を検証するため昇格が必要。管理者権限で実行すること。'
    }
    # バージョンをハードコードすると、Excavator が hourly でバージョンを上げた
    # 次の瞬間からここが黙って外れて検証にならなくなる(実測: このリポジトリの
    # .github/workflows/schedule.yml は Excavator を毎時走らせ、バージョン更新を
    # 直接 default branch へコミットする)。Update.Tests.ps1 と同じく manifest 自身
    # から読む
    $script:BizUdgothicVersion = (Get-Content $script:Manifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
    $script:Backup = Join-Path "$env:ProgramData\scoop-font-backup" "biz-udgothic-$script:BizUdgothicVersion"
    # このスイートに入る前の状態を覚えておく。Task 10 以降は 16 個とも入っているので、
    # 無条件に uninstall して終わると環境を壊す。
    # スナップショットは強制 uninstall より「前」に取る。後で取ると
    # 「入っていた状態へ戻せたか」を検証する基準が失われる
    $script:TrueBefore   = Get-FontEnvSnapshot
    $script:WasInstalled = Test-AppInstalled -App 'biz-udgothic' -ScoopRoot $script:ScoopRoot
    # 入れ直すときの出どころを uninstall の前に控える。控えずに
    # $script:Manifest から入れ直すと install.json にリポジトリのパスが焼き付き、
    # scoop update が bucket ではなくそのファイルを見続けることになる
    $script:OrigSource  = Get-AppInstallSource    -App 'biz-udgothic' -ScoopRoot $script:ScoopRoot
    $script:OrigVersion = Get-AppInstalledVersion -App 'biz-udgothic' -ScoopRoot $script:ScoopRoot
    scoop uninstall -g biz-udgothic 2>&1 | Out-Null
    $script:Before = Get-FontEnvSnapshot   # 「入っていない」状態の基準

    scoop install -g $script:Manifest 2>&1 | Out-Null
}

AfterAll {
    scoop uninstall -g biz-udgothic 2>&1 | Out-Null
    if ($script:WasInstalled) {
        Restore-AppInstall -App 'biz-udgothic' -ScoopRoot $script:ScoopRoot `
            -OriginalSource $script:OrigSource -OriginalVersion $script:OrigVersion `
            -Fallback $script:Manifest -Global
    }
    # 入れ直した結果が元どおりかまで確かめる。試みるだけでは、
    # 再インストールが冪等でなかったときに緑のまま環境がずれる。
    #
    # 配置先が使用中で消せずに残ると、ここは「増えたファイル」を検出して失敗する。
    # それは隠さない。緑と偽って残骸を放置すると、次の install がその残骸を
    # 「元からあったファイル」と誤認して所有権の追跡が壊れるため、失敗として
    # 見えている方が安全。ロックが起きうること自体は 'RealScoop' タグで
    # 既定の実行から外すことで扱う(下の Describe のコメントを参照)
    Assert-FontEnvRestored -Before $script:TrueBefore
}

# 実 scoop 経由の統合テスト。installer / uninstaller 自体の詳細な振る舞いは
# サンドボックスで走る GlobalInstall / Collision が見るので、ここは
# 「scoop から呼んで通ること」に絞る。
#
# 'RealScoop' タグを付けて既定の実行から外してある(run.ps1 が除外する)。
# global 専用になったことで、install したフォントは %WINDIR%\Fonts に置かれて
# OS がログオン時にロードする。すると uninstall で「使用中」により削除できず、
# 後始末が失敗して環境に残骸が残る(実測 2026-08-04)。per-user 時代は
# %LOCALAPPDATA% だったので使うアプリを閉じれば解放されたが、global では
# 閉じても解放されない。失敗を skip で隠すと残骸を放置したまま緑になり、
# 次の install がその残骸を「元からあったファイル」と誤認する。
# 隠さずに失敗させ、代わりに走らせるかどうかを明示の選択にする:
#   .\tests\run.ps1 -IncludeRealScoop
# 走らせた後にフォントが残ってしまったら、再起動してから uninstall し直すこと。
# 昇格が必要
Describe 'biz-udgothic のライフサイクル' -Tag 'RealScoop', 'Lifecycle' {
    It 'install が成功する' {
        (scoop list biz-udgothic 6>$null | Out-String) | Should -Match 'biz-udgothic'
    }

    It '期待した 4 ファイルが Fonts フォルダにある' -ForEach @('BIZUDGothic-Bold.ttf', 'BIZUDGothic-Regular.ttf', 'BIZUDPGothic-Bold.ttf', 'BIZUDPGothic-Regular.ttf') {
        Join-Path "$env:WINDIR\Fonts" $_ | Should -Exist
    }

    It 'レジストリに登録され、値が実在するパスを指す' {
        $v = Get-FontRegValue -Name 'BIZ UDGothic (TrueType)'
        $v | Should -Not -BeNullOrEmpty
        $v | Should -Exist
    }

    It 'レジストリのキー名がファイル名由来ではない' {
        Get-FontRegValue -Name 'BIZUDGothic-Regular (TrueType)' | Should -BeNullOrEmpty
    }

    # AppContainer 用の ACL は検証しない。%WINDIR%\Fonts は元から全ユーザー・
    # 全 AppContainer が読めるので、installer は ACL を触らない

    It '記録が app ディレクトリと退避先の両方にある' {
        $appDir = (scoop prefix biz-udgothic)
        Join-Path $appDir 'scoop-font-state.json' | Should -Exist
        Join-Path $script:Backup 'scoop-font-state.json' | Should -Exist
    }

    It 'uninstall 後にフォント環境が元通りになる' {
        scoop uninstall -g biz-udgothic 2>&1 | Out-Null
        { Assert-FontEnvRestored -Before $script:Before } | Should -Not -Throw
    }

    It 'uninstall 後に退避ディレクトリが残っていない' {
        # 未解決のエントリが 1 件でもあると、uninstaller は退避を残す(設計どおり。
        # 手で復旧できる控えを消さないため)。配置先が使用中で消せなければここは失敗する。
        # それは実際に残骸が残っている状態なので隠さない(Describe のコメントを参照)
        $script:Backup | Should -Not -Exist
    }
}
