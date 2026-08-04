BeforeAll {
    # global インストール経路を検証する。
    #
    # フォントを永続化できるのは %WINDIR%\Fonts + HKLM の global 経路だけである。
    # per-user (LOCALAPPDATA + HKCU) は Windows がログオン時にロードする対象を
    # FontCache-FontSet-<SID>.dat から決めており、レジストリ登録も
    # AddFontResourceW もその集合を変えないため、再起動でフォントが消える
    # (実測 2026-08-04: HKCU に 126 件登録済みでも、OS が開くのは固定の 44 件だけ。
    #  キャッシュを退避して再構築させても変わらなかった)。
    # Microsoft の GDI ドキュメントも AddFontResource を temporary installation と
    # 明記しており、永続化には %windir%\fonts への配置が必要としている。
    #
    # 実機の GDI もフォント環境もレジストリも触らずに済ませるため、
    # GdiRefCount.Tests.ps1 と同じ手法で 3 つを差し替える。
    #   1. GDI の P/Invoke をスタブへ (型名ごと差し替える)
    #   2. $env:WINDIR を一時ディレクトリへ向ける
    #   3. HKLM: PSDrive をサンドボックスのサブキーへ張り替える
    # 3 のおかげで実 HKLM へ書かないので、このスイートは昇格を必要としない。

    $script:Repo = Split-Path $PSScriptRoot

    # --- 素材は張り替える「前」に確保する。$env:WINDIR を差し替えた後では拾えない ---
    $script:SeedFont = $null
    foreach ($c in @(
        @{ File = 'BIZUDGothic-Regular.ttf'; Family = 'BIZ UDGothic' },
        @{ File = 'segoeui.ttf';             Family = 'Segoe UI' },
        @{ File = 'arial.ttf';               Family = 'Arial' }
    )) {
        $path = Join-Path "$env:WINDIR\Fonts" $c.File
        if (Test-Path -LiteralPath $path) {
            $script:SeedFont = $path
            $script:SeedFamily = $c.Family
            break
        }
    }
    if (-not $script:SeedFont) { throw '素材にできるフォントが見つからない' }

    # --- 1. 偽の GDI ---
    $script:StubType = 'ScoopStub.GdiV1'
    if (-not ($script:StubType -as [type])) {
        Add-Type -Namespace 'ScoopStub' -Name 'GdiV1' -MemberDefinition @'
public static System.Collections.Generic.Dictionary<string,int> Counts =
    new System.Collections.Generic.Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase);

public static int AddFontResourceW(string path) {
    if (!System.IO.File.Exists(path)) { return 0; }
    if (!Counts.ContainsKey(path)) { Counts[path] = 0; }
    Counts[path] = Counts[path] + 1;
    return 1;
}

public static bool RemoveFontResourceW(string path) {
    if (!System.IO.File.Exists(path)) { return false; }
    if (!Counts.ContainsKey(path) || Counts[path] <= 0) { return false; }
    Counts[path] = Counts[path] - 1;
    return true;
}

public static System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.IntPtr wParam,
        System.IntPtr lParam, uint flags, uint timeout, out System.IntPtr result) {
    result = System.IntPtr.Zero;
    return System.IntPtr.Zero;
}
'@
    }

    # 実在フォントの name テーブルを同じバイト長の別名へ置換して検証用フォントを作る
    $script:MakeFont = {
        param([string]$Source, [string]$Dest, [string]$From, [string]$To)
        if ($From.Length -ne $To.Length) { throw "置換前後の長さが違う: '$From' -> '$To'" }
        $bytes = [IO.File]::ReadAllBytes($Source)
        $fromBytes = [Text.Encoding]::BigEndianUnicode.GetBytes($From)
        $toBytes = [Text.Encoding]::BigEndianUnicode.GetBytes($To)
        $found = $false
        for ($i = 0; $i -lt $bytes.Length - $fromBytes.Length; $i++) {
            $hit = $true
            for ($j = 0; $j -lt $fromBytes.Length; $j++) {
                if ($bytes[$i + $j] -ne $fromBytes[$j]) { $hit = $false; break }
            }
            if (-not $hit) { continue }
            for ($j = 0; $j -lt $toBytes.Length; $j++) { $bytes[$i + $j] = $toBytes[$j] }
            $found = $true
        }
        if (-not $found) { throw "name テーブルに '$From' が無い: $Source" }
        [IO.File]::WriteAllBytes($Dest, $bytes)
    }

    $script:TagFor = {
        param([string]$Token)
        $len = $script:SeedFamily.Length
        if ($Token.Length -gt $len) { throw "識別子が素材のファミリ名より長い: $Token" }
        $Token.PadRight($len, 'x')
    }

    # --- 2. $env:WINDIR をサンドボックスへ ---
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) "global-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:RealWinDir = $env:WINDIR
    $env:WINDIR = Join-Path $script:Sandbox 'windir'
    New-Item -ItemType Directory -Path $env:WINDIR -Force | Out-Null
    # global の退避先は ProgramData 配下になる。ここもサンドボックスへ向ける
    $script:RealProgramData = $env:ProgramData
    $env:ProgramData = Join-Path $script:Sandbox 'programdata'
    New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null

    # --- 3. HKLM: PSDrive を張り替える ---
    # 実 HKLM へ書けば昇格が必要になるうえ、このマシンのフォント登録を壊しうる。
    # 張り替え先は HKCU 配下なので昇格不要
    $script:SandboxRegRoot = 'HKEY_CURRENT_USER\Software\ScoopFontGlobalTest'
    New-Item -Path 'HKCU:\Software\ScoopFontGlobalTest' -Force | Out-Null

    $script:RealHklmRoot = (Get-PSDrive HKLM).Root
    Remove-PSDrive -Name HKLM -Force
    New-PSDrive -Name HKLM -PSProvider Registry -Root $script:SandboxRegRoot -Scope Global | Out-Null

    # 張り替わっていなければ実 HKLM を汚す。ここで止める
    if ((Get-PSDrive HKLM).Root -ne $script:SandboxRegRoot) {
        throw 'HKLM: の張り替えに失敗した。実レジストリを汚さないため中止する'
    }

    # --- 対象スクリプト。manifest から取り出して原本と同じものを走らせる ---
    $manifestPath = Join-Path $script:Repo 'bucket\bizter.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:InstallerSrc = ($m.installer.script -join "`n").Replace('ScoopFont.GdiV1', 'ScoopStub.GdiV1')
    $script:UninstallerSrc = ($m.uninstaller.script -join "`n").Replace('ScoopFont.GdiV1', 'ScoopStub.GdiV1')
    if ($script:InstallerSrc -like '*ScoopFont.GdiV1*' -or $script:InstallerSrc -notlike '*ScoopStub.GdiV1*') {
        throw '型名の差し替えに失敗した。実 GDI を触らないため中止する'
    }

    # scoop が用意する変数を模す。$global の値がこのスイートの主題
    $script:RunInstaller = {
        param([string]$AppDir, [string]$AppName, [string]$Version, [bool]$Global = $true)
        $dir = $AppDir; $app = $AppName; $version = $Version; $global = $Global
        Invoke-Expression $script:InstallerSrc
    }
    $script:RunUninstaller = {
        param([string]$AppDir, [string]$AppName, [string]$Version, [bool]$Global = $true)
        $dir = $AppDir; $app = $AppName; $version = $Version; $global = $Global
        Invoke-Expression $script:UninstallerSrc
    }

    $script:NewCase = {
        param([string]$Name, [string]$Token)
        $appDir = Join-Path $script:Sandbox "$Name\1.0.0"
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        & $script:MakeFont $script:SeedFont (Join-Path $appDir 'GlobalTest-Regular.ttf') `
            $script:SeedFamily (& $script:TagFor $Token)
        return $appDir
    }
}

AfterAll {
    if ($script:RealHklmRoot) {
        Remove-PSDrive -Name HKLM -Force -ErrorAction SilentlyContinue
        New-PSDrive -Name HKLM -PSProvider Registry -Root $script:RealHklmRoot -Scope Global | Out-Null
    }
    if ($script:RealWinDir) { $env:WINDIR = $script:RealWinDir }
    if ($script:RealProgramData) { $env:ProgramData = $script:RealProgramData }

    Remove-Item -LiteralPath "Registry::$script:SandboxRegRoot" -Recurse -Force -ErrorAction SilentlyContinue
    if ($script:Sandbox) { Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# 'Static' は付けない。実レジストリにサンドボックス用のキーを 1 つ作り、
# HKLM: PSDrive をプロセス単位で張り替えるため
Describe 'global インストール経路' -Tag 'Global' {

    BeforeEach {
        # 破壊的操作の前に毎回サンドボックスを確認する。張り替えが外れていたら
        # このマシンの実フォント登録が黙って消える
        if ((Get-PSDrive HKLM).Root -ne $script:SandboxRegRoot) {
            throw 'HKLM: がサンドボックスを指していない。実レジストリを消さないため中止する'
        }
        if ($env:WINDIR -notlike "$script:Sandbox*") {
            throw "WINDIR がサンドボックス外を指している: $env:WINDIR"
        }

        [ScoopStub.GdiV1]::Counts.Clear()
        Remove-Item -LiteralPath "$env:WINDIR\Fonts" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:ProgramData\scoop-font-backup" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
            -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'global install でフォントが WINDIR\Fonts に置かれ HKLM に登録される' {
        $appDir = & $script:NewCase 'globalcase1' 'Zg1'

        & $script:RunInstaller $appDir 'globalcase1' '1.0.0' $true

        $dest = Join-Path "$env:WINDIR\Fonts" 'GlobalTest-Regular.ttf'
        $dest | Should -Exist -Because 'Windows が永続化を保証するのは %WINDIR%\Fonts に置いたフォントだけ'

        $regName = (& $script:TagFor 'Zg1') + ' (TrueType)'
        $v = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
            -Name $regName -ErrorAction SilentlyContinue
        $v | Should -Not -BeNullOrEmpty -Because 'global install は HKLM に登録する'
        $v.($regName) | Should -Be $dest -Because '登録の値は配置先の実パスを指す'
    }

    It 'レジストリのキー名がファイル名由来ではない' {
        $appDir = & $script:NewCase 'globalcase2' 'Zg2'
        & $script:RunInstaller $appDir 'globalcase2' '1.0.0' $true

        # 登録名は OpenType の name テーブルの nameID 4(Full font name)由来。
        # ファイル名から組み立てる実装に退行すると、Windows 標準のインストーラーと
        # 規則が違ってしまい、手動導入ぶんの登録を置き換えられなくなる
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'
        Get-ItemProperty -Path $key -Name 'GlobalTest-Regular (TrueType)' -ErrorAction SilentlyContinue |
            Should -BeNullOrEmpty -Because 'ファイル名由来の名前では登録しない'
        Get-ItemProperty -Path $key -Name ((& $script:TagFor 'Zg2') + ' (TrueType)') -ErrorAction SilentlyContinue |
            Should -Not -BeNullOrEmpty -Because 'nameID 4 由来の名前で登録する'
    }

    It '記録が app ディレクトリと退避先の両方にある' {
        # app ディレクトリが消えても退避側に控えが残り、退避が消えても app 側から
        # 追える。片方だけだと中断時に復旧の手がかりを失う
        $appDir = & $script:NewCase 'globalcase3' 'Zg3'
        & $script:RunInstaller $appDir 'globalcase3' '1.0.0' $true

        Join-Path $appDir 'scoop-font-state.json' | Should -Exist
        Join-Path "$env:ProgramData\scoop-font-backup" 'globalcase3-1.0.0\scoop-font-state.json' | Should -Exist
    }
}
