BeforeAll {
    # 配置先に既存ファイル・既存登録がある状況での installer / uninstaller の振る舞いを
    # 検証する。
    #
    # 実機の %WINDIR%\Fonts では成立しない。global install したフォントは OS が
    # ログオン時にロードして常時参照するため、配置先のファイルを消す・置き換える
    # 操作が「使用中」で失敗する(実測 2026-08-04: BIZUDPGothic-Regular.ttf が
    # 常にロックされ 13 件が落ちた)。per-user 時代は %LOCALAPPDATA% だったので
    # 使うアプリを閉じれば解放されたが、global では閉じても解放されない。
    # そこで GdiRefCount / GlobalInstall と同じサンドボックス方式で走らせる。
    #   1. GDI の P/Invoke をスタブへ(型名ごと差し替える)
    #   2. $env:WINDIR と $env:ProgramData を一時ディレクトリへ向ける
    #   3. HKLM: PSDrive をサンドボックスのサブキーへ張り替える
    # 3 の張り替え先は HKCU 配下なので、実 HKLM へ書かず昇格も要らない。
    #
    # 検証用フォントは実在フォントの name テーブルを同じバイト長の別名へ置換して作る。
    # bucket のどのフォントとも名前が衝突しないので、実機の登録と混ざらない。
    # ファイル名を CollTest-A..D にしてあるので Get-ChildItem の列挙順が
    # A→B→C→D で決まる。元の実装は「BIZUDPGothic-Regular.ttf が列挙順で最後」という
    # 保証の無い前提に依存していたが、ここではその不確かさが無い。

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
    if (-not ('ScoopStub.GdiV1' -as [type])) {
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

    # --- 2. $env:WINDIR / $env:ProgramData をサンドボックスへ ---
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) "collision-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:RealWinDir = $env:WINDIR
    $env:WINDIR = Join-Path $script:Sandbox 'windir'
    New-Item -ItemType Directory -Path "$env:WINDIR\Fonts" -Force | Out-Null
    $script:RealProgramData = $env:ProgramData
    $env:ProgramData = Join-Path $script:Sandbox 'programdata'
    New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null

    # --- 3. HKLM: PSDrive を張り替える ---
    $script:SandboxRegRoot = 'HKEY_CURRENT_USER\Software\ScoopFontCollisionTest'
    New-Item -Path 'HKCU:\Software\ScoopFontCollisionTest' -Force | Out-Null
    $script:RealHklmRoot = (Get-PSDrive HKLM).Root
    Remove-PSDrive -Name HKLM -Force
    New-PSDrive -Name HKLM -PSProvider Registry -Root $script:SandboxRegRoot -Scope Global | Out-Null
    if ((Get-PSDrive HKLM).Root -ne $script:SandboxRegRoot) {
        throw 'HKLM: の張り替えに失敗した。実レジストリを汚さないため中止する'
    }

    # --- 対象スクリプト。manifest から取り出して原本と同じものを走らせる ---
    $manifestPath = Join-Path $script:Repo 'bucket\bizter.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:InstallerSrc   = ($m.installer.script   -join "`n").Replace('ScoopFont.GdiV1', 'ScoopStub.GdiV1')
    $script:UninstallerSrc = ($m.uninstaller.script -join "`n").Replace('ScoopFont.GdiV1', 'ScoopStub.GdiV1')
    # pre_uninstall は GDI を触らないのでスタブ差し替えは要らない。
    # exit 1 するので同一プロセスでは走らせられず、子プロセスで実行する
    $script:PreUninstallSrc = ($m.pre_uninstall -join "`n")
    if ($script:InstallerSrc -like '*ScoopFont.GdiV1*' -or $script:InstallerSrc -notlike '*ScoopStub.GdiV1*') {
        throw '型名の差し替えに失敗した。実 GDI を触らないため中止する'
    }

    $script:App     = 'colltest'
    $script:Version = '1.0.0'
    $script:AppDir  = Join-Path $script:Sandbox "$script:App\$script:Version"
    $script:FontDir = "$env:WINDIR\Fonts"
    $script:Backup  = "$env:ProgramData\scoop-font-backup\$script:App-$script:Version"
    $script:RegKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

    # 4 ファイル。列挙順は A→B→C→D
    $script:Files = @(
        @{ File = 'CollTest-A.ttf'; Token = 'CA' },
        @{ File = 'CollTest-B.ttf'; Token = 'CB' },
        @{ File = 'CollTest-C.ttf'; Token = 'CC' },
        @{ File = 'CollTest-D.ttf'; Token = 'CD' }
    )
    foreach ($f in $script:Files) { $f.RegName = (& $script:TagFor $f.Token) + ' (TrueType)' }
    $script:Names   = @($script:Files | ForEach-Object { $_.File })
    $script:Target  = Join-Path $script:FontDir 'CollTest-A.ttf'
    $script:RegName = ($script:Files | Where-Object { $_.File -eq 'CollTest-A.ttf' }).RegName

    $script:RunInstaller = {
        $dir = $script:AppDir; $app = $script:App; $version = $script:Version; $global = $true
        Invoke-Expression $script:InstallerSrc
    }
    # $VersionOverride は scoop update の状況を再現するためにある。scoop update は
    # scoop-update.ps1 の中で $version を新版へ再代入した後、その同じスコープのまま
    # 旧版の uninstaller を呼ぶので、旧版の uninstaller から見える $version は
    # 新版のものになっている(実測)。uninstaller はこれを信用せず $dir から版を
    # 復元しなければならない
    $script:RunUninstaller = {
        param([string]$VersionOverride)
        $dir = $script:AppDir; $app = $script:App; $global = $true
        $version = if ($VersionOverride) { $VersionOverride } else { $script:Version }
        Invoke-Expression $script:UninstallerSrc
    }

    # レジストリ値の読み出し。FontEnv.psm1 は実機の HKLM を前提にしているので使わない
    # (このスイートでは HKLM: が張り替わっているため結果的に同じ場所を見るが、
    #  依存関係を明示するために自前で持つ)
    $script:GetReg = {
        param([string]$Name)
        $p = Get-ItemProperty -Path $script:RegKey -Name $Name -ErrorAction SilentlyContinue
        if ($p) { return $p.($Name) }
        return $null
    }

    # 囮: 実在フォントを土台に 1 バイト変える。中身は別物だが name テーブルは読める
    $script:NewDecoy = {
        param([string]$Path)
        $b = [IO.File]::ReadAllBytes($script:SeedFont)
        $b[$b.Length - 1] = [byte](($b[$b.Length - 1] + 1) % 256)
        [IO.File]::WriteAllBytes($Path, $b)
        return (Get-FileHash -LiteralPath $Path).Hash
    }

    $script:ResetCase = {
        # サンドボックスなので実環境には一切触れない。app ディレクトリのフォントは
        # 毎回作り直す(テストが配置先を壊すことはあっても src は壊さないが、
        # ケース間で状態を持ち越さないことを明示する)
        if (Test-Path -LiteralPath $script:AppDir) { Remove-Item -LiteralPath $script:AppDir -Recurse -Force }
        New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null
        foreach ($f in $script:Files) {
            & $script:MakeFont $script:SeedFont (Join-Path $script:AppDir $f.File) `
                $script:SeedFamily (& $script:TagFor $f.Token)
        }
        [ScoopStub.GdiV1]::Counts.Clear()
        if (Test-Path -LiteralPath $script:FontDir) { Remove-Item -LiteralPath $script:FontDir -Recurse -Force }
        New-Item -ItemType Directory -Path $script:FontDir -Force | Out-Null
        Remove-Item -LiteralPath "$env:ProgramData\scoop-font-backup" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:RegKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

AfterAll {
    # 張り替えたものを必ず戻す。戻さないとこのプロセスの後続テストが
    # サンドボックスを見続ける
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
Describe '既存ファイルとの衝突' -Tag 'Collision' {
    BeforeEach {
        # 破壊的操作の前に毎回サンドボックスを確認する。張り替えが外れていたら
        # このマシンの実フォント登録が黙って消える
        if ((Get-PSDrive HKLM).Root -ne $script:SandboxRegRoot) {
            throw 'HKLM: がサンドボックスを指していない。実レジストリを消さないため中止する'
        }
        if ($env:WINDIR -notlike "$script:Sandbox*") {
            throw "WINDIR がサンドボックス外を指している: $env:WINDIR"
        }
        & $script:ResetCase
    }

    It '内容の違う同名ファイルがあると退避してから上書きし、uninstall で戻る' {
        $decoyHash = & $script:NewDecoy $script:Target

        & $script:RunInstaller
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Not -Be $decoyHash
        (Join-Path $script:Backup 'CollTest-A.ttf') | Should -Exist

        & $script:RunUninstaller
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Be $decoyHash
    }

    It '既存の登録があれば上書きし、uninstall で元の値へ戻る' {
        & $script:NewDecoy $script:Target | Out-Null
        # installer が書く値($script:Target)と同じ値を仕込むと、レジストリ処理が
        # 完全な no-op でも before/after/expected が全部同じになり、テストが
        # 何も検証できなくなる。installer が書く値とは違う番兵パスを仕込む
        $sentinel = Join-Path $script:FontDir 'Sentinel-Not-CollTest.ttf'
        # New-ItemProperty -Force は値の作成・上書きは Force するが、親キーが無い
        # 場合の作成まではしない(installer 側にも同じ実測コメントがある)。
        # ResetCase が Fonts キーごと消しているので、ここで先に作る
        if (-not (Test-Path -LiteralPath $script:RegKey)) { New-Item -Path $script:RegKey -Force | Out-Null }
        New-ItemProperty -Path $script:RegKey -Name $script:RegName -Value $sentinel -Force | Out-Null

        & $script:RunInstaller
        (& $script:GetReg $script:RegName) | Should -Be $script:Target

        & $script:RunUninstaller
        (& $script:GetReg $script:RegName) | Should -Be $sentinel
    }

    It 'install 後に第三者が差し替えたファイルは uninstall で消さない' {
        & $script:RunInstaller
        $tamperedHash = & $script:NewDecoy $script:Target

        & $script:RunUninstaller
        $script:Target | Should -Exist
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Be $tamperedHash
    }

    It '記録が無ければ uninstall は何も消さない' {
        & $script:RunInstaller
        Remove-Item (Join-Path $script:AppDir 'scoop-font-state.json') -Force
        Remove-Item (Join-Path $script:Backup 'scoop-font-state.json') -Force

        & $script:RunUninstaller
        $script:Target | Should -Exist
    }
}

Describe '変更途中の失敗' -Tag 'Collision' {
    BeforeEach {
        if ((Get-PSDrive HKLM).Root -ne $script:SandboxRegRoot) {
            throw 'HKLM: がサンドボックスを指していない。実レジストリを消さないため中止する'
        }
        & $script:ResetCase
    }

    It '配置先にディレクトリがあると下調べの検知で落ち、1 ファイルも変更されない' {
        # 配置先と同名のディレクトリを作っておくと、installer は下調べ段階
        # (どのファイルも変更する前)でこれを検知して例外を投げる。この経路は
        # 「1 ファイルも変更しないうちに終わる」ことを守るものであり、catch 内の
        # 巻き戻し(退避からの復元・ハッシュ検証・レジストリの戻し)は通らない。
        # 巻き戻し自体を検証するのは下の 'Move-Item' の項
        # 下調べ段階で落ちることの検証なので、どのファイルを塞いでもよい
        $blocker = Join-Path $script:FontDir $script:Names[-1]
        New-Item $blocker -ItemType Directory -Force | Out-Null

        # 何でも「例外が出た」で OK にすると、無関係の理由で落ちただけでも
        # 下の「残っていない」検証が素通りする。原因まで確認する
        $caught = $null
        try { & $script:RunInstaller } catch { $caught = $_ }
        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match '配置先がファイルではない'

        (Test-Path $script:Target) | Should -BeFalse
        (& $script:GetReg $script:RegName) | Should -BeNullOrEmpty
    }

    It '最後の配置先だけ書き込みを塞ぐと Move-Item で失敗し、先行するファイルが囮の内容へ巻き戻る' {
        # 下調べのディレクトリ検知は「1 ファイルも変更しないうちに落ちる」経路であり、
        # catch 内の巻き戻しを 1 行も通らない。実際に通すには、変更が始まったあとで
        # 失敗させる必要がある。4 ファイルすべてに囮を置き、列挙順で最後の
        # CollTest-D.ttf だけ書き込みを防ぐハンドルで掴む。
        #
        # 完全排他('ReadWrite','None')では狙いどおりに動かない。installer は下調べ
        # 段階で配置先のハッシュを Get-FileHash で読む(退避の検証に使うため変更前に
        # 計画へ保存する)。'None' で読み取りも塞ぐとこの時点で落ち、1 ファイルも
        # 変更されないまま終わる。読み取りは許可し書き込みだけ拒否する('Read','Read')と、
        # 下調べの読み取りと退避コピーは素通りし、最後の Move-Item だけが失敗する
        $decoyHashes = @{}
        foreach ($n in $script:Names) { $decoyHashes[$n] = & $script:NewDecoy (Join-Path $script:FontDir $n) }

        # installer は Get-ChildItem の列挙順で処理する。その順序はファイルシステム
        # 依存で、名前順とは限らない。決め打ちすると、ロックした 1 件が最初に処理される
        # 環境では 1 ファイルも退避されないまま落ちて(巻き戻しを通らない経路になり)
        # $backedUp.Count の検証が失敗する。installer と同じ列挙をして最後の 1 件を取る
        $enumerated = @(Get-ChildItem $script:AppDir -Recurse -Include '*.ttf', '*.otf' |
            Where-Object { $_.BaseName -notmatch '35' } | ForEach-Object { $_.Name })
        $enumerated.Count | Should -Be $script:Names.Count -Because '4 ファイルすべてが列挙されるはず'
        $lockedName = $enumerated[-1]

        $lockedPath = Join-Path $script:FontDir $lockedName
        $handle = [IO.File]::Open($lockedPath, 'Open', 'Read', 'Read')
        try {
            $caught = $null
            try { & $script:RunInstaller } catch { $caught = $_ }
            $caught | Should -Not -BeNullOrEmpty
            $caught.FullyQualifiedErrorId | Should -Match 'MoveItemCommand'
            "$($caught.TargetObject)" | Should -Be $lockedPath
        } finally {
            $handle.Close()
        }

        # 巻き戻しが単に「何もしなかった」のではなく、実際に置き換えてから戻した
        # ことの証拠。退避には置き換える直前の内容、つまり囮の内容が控えられている
        $others = @($script:Names | Where-Object { $_ -ne $lockedName })
        $backedUp = @($others | Where-Object { Test-Path (Join-Path $script:Backup $_) })
        $backedUp.Count | Should -BeGreaterThan 0
        foreach ($n in $backedUp) {
            (Get-FileHash -LiteralPath (Join-Path $script:Backup $n)).Hash | Should -Be $decoyHashes[$n]
        }

        # 配置先自体も、置き換え→巻き戻しを経て囮の内容に戻っていること
        foreach ($n in $script:Names) {
            (Get-FileHash -LiteralPath (Join-Path $script:FontDir $n)).Hash | Should -Be $decoyHashes[$n]
        }
        (& $script:GetReg $script:RegName) | Should -BeNullOrEmpty
    }
}

Describe 'uninstaller のロック耐性とジャーナル退役' -Tag 'Collision' {
    BeforeEach {
        if ((Get-PSDrive HKLM).Root -ne $script:SandboxRegRoot) {
            throw 'HKLM: がサンドボックスを指していない。実レジストリを消さないため中止する'
        }
        & $script:ResetCase
    }

    It 'ロックされた1件があっても残りは処理され、ジャーナルは退役し、解錠後の再実行で完全に消える' {
        & $script:RunInstaller

        $lockedFile = 'CollTest-A.ttf'
        $lockedPath = Join-Path $script:FontDir $lockedFile
        $handle = [IO.File]::Open($lockedPath, 'Open', 'Read', 'Read')
        try {
            # 1 件のロックで残り全部と退役処理を巻き添えにしない、が検証の主題
            { & $script:RunUninstaller } | Should -Not -Throw

            foreach ($n in @($script:Names | Where-Object { $_ -ne $lockedFile })) {
                (Join-Path $script:FontDir $n) | Should -Not -Exist
            }
            $lockedPath | Should -Exist

            # ジャーナルは退役済み: アクティブな state.json は無く retired.json がある
            (Join-Path $script:Backup 'scoop-font-state.json') | Should -Not -Exist
            (Join-Path $script:Backup 'scoop-font-state.retired.json') | Should -Exist

            # 未解決のエントリがあるので退避ディレクトリ自体は生き残る
            $script:Backup | Should -Exist
        } finally {
            $handle.Close()
        }

        # 解錠後の再実行で残りが片付く。backupDir 側の記録は既に退役済みなので、
        # uninstaller は app ディレクトリ側の写しを読む
        & $script:RunUninstaller
        $lockedPath | Should -Not -Exist
        (& $script:GetReg $script:RegName) | Should -BeNullOrEmpty
    }

    It '退役の Move-Item が失敗するとループへ入る前に落ち、ファイルもレジストリも変わらない' {
        # 退役(state.json を retired.json へ改名)はフォント処理ループへ入る「前」に
        # 無条件で行う設計。ここが後ろへ移ると、中断時に「変更済み × 有効な記録」が
        # 残り、後日同じ版を入れ直したときに「中断した試行の続き」と誤認されて
        # 所有権の追跡が壊れる(uninstall が成功を報告しながら何も消さなくなる)。
        # 退役自体を失敗させて、1 ファイルも変更されないことを確かめる
        & $script:RunInstaller

        $statePath = Join-Path $script:Backup 'scoop-font-state.json'
        $statePath | Should -Exist -Because '退役の対象が無いと検証にならない'

        $before = @{}
        foreach ($f in $script:Files) {
            $before[$f.File] = (Get-FileHash -LiteralPath (Join-Path $script:FontDir $f.File)).Hash
        }

        # 削除・改名を拒否するハンドルで掴む。Move-Item は delete 共有権限を要求する
        $handle = [IO.File]::Open($statePath, 'Open', 'Read', 'Read')
        try {
            { & $script:RunUninstaller } | Should -Throw
        } finally {
            $handle.Close()
        }

        # 1 ファイルも消えていない・中身も変わっていない
        foreach ($f in $script:Files) {
            $dest = Join-Path $script:FontDir $f.File
            $dest | Should -Exist
            (Get-FileHash -LiteralPath $dest).Hash | Should -Be $before[$f.File]
            (& $script:GetReg $f.RegName) | Should -Be $dest
        }
        # 記録も退役していない(改名が失敗したので元の名前のまま)
        $statePath | Should -Exist
        (Join-Path $script:Backup 'scoop-font-state.retired.json') | Should -Not -Exist
    }

    It 'pre_uninstall はロックされたフォントのファイル名を出して exit 1 する' {
        # pre_uninstall は配置先を自分自身へ Rename-Item してロックを検出し、
        # 失敗すると exit 1 で uninstall 全体を止める。catch の中では $_ が
        # ErrorRecord に変わってパイプラインの FileInfo ではなくなるため、
        # メッセージに使う名前は try へ入る前に控えておく必要がある
        # (控え忘れるとファイル名が空のエラーになる)。その回帰を見る。
        # exit 1 するので子プロセスで走らせる。$env:WINDIR はサンドボックスを
        # 指したまま子へ継承される
        & $script:RunInstaller

        $probe = Join-Path $script:Sandbox 'pre-uninstall-probe.ps1'
        # pre_uninstall は $dir と $app を呼び出し元スコープから読む
        $body = "`$dir = '$script:AppDir'`n`$app = '$script:App'`n" + $script:PreUninstallSrc
        # 日本語を含むので BOM 付きで書く(PowerShell 5.1 は BOM 無し UTF-8 を
        # ANSI として読み、パースエラーで黙って死ぬ)。Set-Content -Encoding UTF8 は
        # 5.1 では BOM 付きで書く
        Set-Content -LiteralPath $probe -Value $body -Encoding UTF8

        # 前提: ロックが無ければ素通りして exit 0。これを確かめておかないと、
        # 下の exit 1 が「ロックのおかげ」なのか「常に 1 を返すだけ」なのか区別できない。
        # pre_uninstall は配置先を自分自身へ改名するだけなので副作用は無い
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because 'ロックが無ければ pre_uninstall は素通りする'

        $lockedName = $script:Files[0].File
        $lockedPath = Join-Path $script:FontDir $lockedName
        # 読み取りは許すが delete 共有を拒否する。Rename-Item は delete 権限を
        # 要求するのでこれで失敗する(実測: ロック無しでは成功し、この共有指定では
        # IOException になる)
        $handle = [IO.File]::Open($lockedPath, 'Open', 'Read', 'Read')
        try {
            $out = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe 2>&1 | Out-String)
            $LASTEXITCODE | Should -Be 1 -Because 'ロックを検出したら uninstall 全体を止める'
            $out | Should -Match ([regex]::Escape($lockedName)) -Because 'どのファイルが使用中かを出す'
        } finally {
            $handle.Close()
        }
    }

    It '$version が新版に化けていても $dir から版を復元して退避を片付ける' {
        # scoop update の回帰テスト。scoop update は scoop-update.ps1 の中で
        # $version を新版へ再代入した後、その同じスコープのまま旧版の
        # pre_uninstall / uninstaller フックを呼ぶ。Invoke-HookScript は
        # パラメータ渡しをせず呼び出し元スコープの変数をそのまま読むため、
        # 旧版の uninstaller から見える $version は新版のものになっている(実測)。
        # これに気づかず $backupDir を組み立てると、scoop update のたびに
        # 旧版の退避ディレクトリが掃除されずオーファンとして残り続ける実害があった。
        #
        # 実 scoop での検証(旧 Update.Tests.ps1)は、global のフォントが OS に
        # ロードされていて uninstall が「使用中」で失敗するため成立しなくなった。
        # 回帰の本体は「$version を信用せず $dir から版を復元する」ことなので、
        # $version だけを新版に差し替えて uninstaller を呼べば等価に検証できる
        & $script:RunInstaller
        $script:Backup | Should -Exist -Because '退避が無いと片付け対象が無い'

        & $script:RunUninstaller -VersionOverride '9.9.9'

        # 実際の版(1.0.0)の退避が片付いていること。$version を信用していると
        # <app>-9.9.9 を探して見つからず、<app>-1.0.0 が残る
        $script:Backup | Should -Not -Exist -Because '$dir から版を復元すれば正しい退避を掃除できる'
        Join-Path "$env:ProgramData\scoop-font-backup" "$script:App-9.9.9" | Should -Not -Exist
        foreach ($f in $script:Files) {
            (Join-Path $script:FontDir $f.File) | Should -Not -Exist
            (& $script:GetReg $f.RegName) | Should -BeNullOrEmpty
        }
    }

    It '記録がどこにも無い状態で再実行しても何も壊さない' {
        # 全部片付いた後の再実行が安全であること。記録が無いので退却するだけ
        & $script:RunInstaller
        & $script:RunUninstaller
        & $script:RunUninstaller   # 2 回目: 有効な記録は無い

        foreach ($n in $script:Names) { (Join-Path $script:FontDir $n) | Should -Not -Exist }
        (& $script:GetReg $script:RegName) | Should -BeNullOrEmpty
    }
}
