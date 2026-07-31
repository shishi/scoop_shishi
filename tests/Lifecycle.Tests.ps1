BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $script:Repo     = Split-Path $PSScriptRoot
    $script:Manifest = Join-Path $script:Repo 'bucket\biz-udgothic.json'
    $script:FontDir  = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $script:Expected = @('BIZUDGothic-Bold.ttf', 'BIZUDGothic-Regular.ttf',
                         'BIZUDPGothic-Bold.ttf', 'BIZUDPGothic-Regular.ttf')
    # このスイートに入る前の状態を覚えておく。Task 10 以降は 16 個とも入っているので、
    # 無条件に uninstall して終わると環境を壊す
    $script:WasInstalled = ((scoop list biz-udgothic 6>$null | Out-String) -match 'biz-udgothic')
    scoop uninstall biz-udgothic 2>&1 | Out-Null
    $script:Before   = Get-FontEnvSnapshot   # uninstall 後の状態を基準にする

    $script:InstallOutput = & scoop install $script:Manifest 2>&1 | Out-String
}

AfterAll {
    scoop uninstall biz-udgothic 2>&1 | Out-Null
    if ($script:WasInstalled) { scoop install $script:Manifest 2>&1 | Out-Null }
}

Describe 'biz-udgothic のライフサイクル' {
    It 'install が成功する' {
        (scoop list biz-udgothic 6>$null | Out-String) | Should -Match 'biz-udgothic'
    }

    It '期待した 4 ファイルが Fonts フォルダにある' -ForEach @('BIZUDGothic-Bold.ttf', 'BIZUDGothic-Regular.ttf', 'BIZUDPGothic-Bold.ttf', 'BIZUDPGothic-Regular.ttf') {
        Join-Path "$env:LOCALAPPDATA\Microsoft\Windows\Fonts" $_ | Should -Exist
    }

    It '35 を含むファイルは 1 つも置かれていない' {
        @(Get-ChildItem $script:FontDir -Filter '*35*' -File -Force |
            Where-Object { $_.Name -like 'BIZ*' }) | Should -BeNullOrEmpty
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

    It 'デスクトップの GDI がフォントを認識している' {
        Add-Type -AssemblyName System.Drawing
        $families = (New-Object System.Drawing.Text.InstalledFontCollection).Families |
            Select-Object -ExpandProperty Name
        $families | Should -Contain 'BIZ UDGothic'
    }

    It '記録が app ディレクトリと退避先の両方にある' {
        $appDir = (scoop prefix biz-udgothic)
        Join-Path $appDir 'scoop-font-state.json' | Should -Exist
        Join-Path "$env:LOCALAPPDATA\scoop-font-backup\biz-udgothic-1.051" 'scoop-font-state.json' | Should -Exist
    }

    It 'uninstall 後にフォント環境が元通りになる' {
        scoop uninstall biz-udgothic 2>&1 | Out-Null
        { Assert-FontEnvRestored -Before $script:Before } | Should -Not -Throw
    }

    It 'uninstall 後に退避ディレクトリが残っていない' {
        "$env:LOCALAPPDATA\scoop-font-backup\biz-udgothic-1.051" | Should -Not -Exist
    }
}
