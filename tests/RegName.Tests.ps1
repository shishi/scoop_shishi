BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $fixture = Get-Content (Join-Path $PSScriptRoot 'fixtures\expected-regnames.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Expected = $fixture.regnames
    $script:Families = $fixture.families
    $script:FontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
}

Describe 'レジストリのキー名' {
    It '期待値が 125 件ある' {
        @($script:Expected.PSObject.Properties).Count | Should -Be 125
    }

    It 'ファミリが 25 種ある' {
        @($script:Families).Count | Should -Be 25
    }

    It 'GDI が期待どおりのファミリを列挙する' {
        # システム全体の InstalledFontCollection は、ユーザー単位 (HKCU) でインストール
        # したフォントを同一セッション内の新規プロセスへ確実には反映しない。実機で確認
        # 済み: HKCU にしか無いフォントが表示されない一方、たまたま HKLM に同名の別由来の
        # フォントが既に入っているものは表示されてしまい、判定がこの PC の既存インストール
        # 状況に依存してしまう。そこで PrivateFontCollection で実ファイルを直接読み込ませ、
        # GDI+ 自身のパーサーが認識するファミリ名の集合で検証する(ファイル破損の検出という
        # 目的は保ったまま、システムのフォントキャッシュ状態に依存しない)。
        Add-Type -AssemblyName System.Drawing
        $pfc = New-Object System.Drawing.Text.PrivateFontCollection
        foreach ($p in $script:Expected.PSObject.Properties) {
            $path = Join-Path $script:FontDir $p.Name
            $pfc.AddFontFile($path)
        }
        $loaded = @($pfc.Families | Select-Object -ExpandProperty Name)
        $missing = @($script:Families | Where-Object { $_ -notin $loaded })
        ($missing -join ', ') | Should -BeNullOrEmpty
    }

    It '独立実装の期待値どおりに登録されている' {
        $wrong = @()
        foreach ($p in $script:Expected.PSObject.Properties) {
            $actual = Get-FontRegValue -Name $p.Value
            if ($null -eq $actual) { $wrong += "$($p.Value) が未登録 ($($p.Name))" ; continue }
            $expectedPath = Join-Path $script:FontDir $p.Name
            if ($actual -ne $expectedPath) { $wrong += "$($p.Value) の値が $actual" }
        }
        ($wrong -join '; ') | Should -BeNullOrEmpty
    }

    It 'ファイル名由来のキーが作られていない' {
        Get-FontRegValue -Name 'HackGen-Regular (TrueType)'      | Should -BeNullOrEmpty
        Get-FontRegValue -Name 'UDEVGothicNF-Bold (TrueType)'    | Should -BeNullOrEmpty
        Get-FontRegValue -Name 'NotoSansJP-Regular (OpenType)'   | Should -BeNullOrEmpty
    }

    It 'Windows 自身が付けた名前と同じ規則である' {
        # OS 同梱の BIZ UDGothic は HKLM に Windows 自身が登録している。
        # scoop が HKCU に付ける名前と一致していれば規則が合っている
        $hklm = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
        $osName = @($hklm.PSObject.Properties | Where-Object { $_.Name -like 'BIZ UDGothic*' } |
            Select-Object -ExpandProperty Name)
        if (-not $osName) { Set-ItResult -Skipped -Because 'OS 側に BIZ UDGothic の登録が無い' }
        $script:Expected.'BIZUDGothic-Regular.ttf' | Should -BeIn $osName
    }
}
