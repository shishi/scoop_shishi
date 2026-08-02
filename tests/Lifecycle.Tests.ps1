BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $script:Repo     = Split-Path $PSScriptRoot
    $script:Manifest = Join-Path $script:Repo 'bucket\biz-udgothic.json'
    $script:FontDir  = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    # バージョンをハードコードすると、Excavator が hourly でバージョンを上げた
    # 次の瞬間からここが黙って外れて検証にならなくなる(実測: このリポジトリの
    # .github/workflows/schedule.yml は Excavator を毎時走らせ、バージョン更新を
    # 直接 default branch へコミットする)。Update.Tests.ps1 と同じく manifest 自身
    # から読む
    $script:BizUdgothicVersion = (Get-Content $script:Manifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
    $script:Backup = Join-Path "$env:LOCALAPPDATA\scoop-font-backup" "biz-udgothic-$script:BizUdgothicVersion"
    # このスイートに入る前の状態を覚えておく。Task 10 以降は 16 個とも入っているので、
    # 無条件に uninstall して終わると環境を壊す。
    # スナップショットは強制 uninstall より「前」に取る。後で取ると
    # 「入っていた状態へ戻せたか」を検証する基準が失われる
    $script:TrueBefore   = Get-FontEnvSnapshot
    $script:WasInstalled = ((scoop list biz-udgothic 6>$null | Out-String) -match 'biz-udgothic')
    scoop uninstall biz-udgothic 2>&1 | Out-Null
    $script:Before = Get-FontEnvSnapshot   # 「入っていない」状態の基準

    scoop install $script:Manifest 2>&1 | Out-Null
}

AfterAll {
    scoop uninstall biz-udgothic 2>&1 | Out-Null
    if ($script:WasInstalled) { scoop install $script:Manifest 2>&1 | Out-Null }
    # 入れ直した結果が元どおりかまで確かめる。試みるだけでは、
    # 再インストールが冪等でなかったときに緑のまま環境がずれる
    Assert-FontEnvRestored -Before $script:TrueBefore
}

Describe 'biz-udgothic のライフサイクル' {
    It 'install が成功する' {
        (scoop list biz-udgothic 6>$null | Out-String) | Should -Match 'biz-udgothic'
    }

    It '期待した 4 ファイルが Fonts フォルダにある' -ForEach @('BIZUDGothic-Bold.ttf', 'BIZUDGothic-Regular.ttf', 'BIZUDPGothic-Bold.ttf', 'BIZUDPGothic-Regular.ttf') {
        Join-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" $_ | Should -Exist
    }

    It 'レジストリに登録され、値が実在するパスを指す' {
        $v = Get-FontRegValue -Name 'BIZ UDGothic (TrueType)'
        $v | Should -Not -BeNullOrEmpty
        $v | Should -Exist
    }

    It 'レジストリのキー名がファイル名由来ではない' {
        Get-FontRegValue -Name 'BIZUDGothic-Regular (TrueType)' | Should -BeNullOrEmpty
    }

    It 'Fonts ディレクトリに AppContainer 用の ACL がある' -ForEach @('S-1-15-2-1', 'S-1-15-2-2') {
        # -ForEach の値を先に取る。Where-Object の中では $_ が ACL エントリに変わる
        $sid = $_
        # ACE の IdentityReference は NTAccount（例: "APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES"）
        # として返る。これを SecurityIdentifier へ逆変換しようとすると、環境によっては
        # IdentityNotMappedException で落ちる（実測）。SID → アカウント名の順方向変換は
        # 常に安全に通るので、そちらで比較する
        $acctName = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value
        $acl = Get-Acl "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
        $found = @($acl.Access | Where-Object { $_.IdentityReference.Value -eq $acctName })
        $found | Should -Not -BeNullOrEmpty
    }

    It '記録が app ディレクトリと退避先の両方にある' {
        $appDir = (scoop prefix biz-udgothic)
        Join-Path $appDir 'scoop-font-state.json' | Should -Exist
        Join-Path $script:Backup 'scoop-font-state.json' | Should -Exist
    }

    It 'uninstall 後にフォント環境が元通りになる' {
        scoop uninstall biz-udgothic 2>&1 | Out-Null
        { Assert-FontEnvRestored -Before $script:Before } | Should -Not -Throw
    }

    It 'uninstall 後に退避ディレクトリが残っていない' {
        $script:Backup | Should -Not -Exist
    }
}
