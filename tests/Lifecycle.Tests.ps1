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
    # 再インストールが冪等でなかったときに緑のまま環境がずれる
    Assert-FontEnvRestored -Before $script:TrueBefore
}

Describe 'biz-udgothic のライフサイクル' {
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
        $script:Backup | Should -Not -Exist
    }
}
