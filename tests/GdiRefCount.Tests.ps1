BeforeAll {
    # GDI の参照カウントの収支を検証する。
    #
    # ここを静的テストだけで守っていたところ、外部レビューで 3 回続けて
    # 収支の誤りが見つかった(巻き戻しで第三者の参照が減ったまま返らない /
    # 呼んだ回数で数えて純増する / 上書き前の Remove が抜けている)。
    # いずれもファイルとレジストリは正しいままなので、既存のスイートでは検出できない。
    #
    # 実機の GDI もフォント環境も触らずに済ませるため、次の 3 つを差し替える。
    #   1. GDI の P/Invoke をカウンタ付きのスタブに差し替える。スクリプト側の
    #      Add-Type は -as [type] のガードで素通りし、全呼び出しがカウンタに入る
    #   2. $env:LOCALAPPDATA を一時ディレクトリへ向ける
    #   3. HKCU: PSDrive をサンドボックスのサブキーへ張り替える
    # 3 は本物の HKCU を汚しうるので、張り替わったことを確認してから先へ進む。

    $script:Repo = Split-Path $PSScriptRoot

    # --- 1. 偽の GDI。実測に合わせた挙動にする ---
    #   Remove は参照が 0 のとき false を返して飽和する
    #   Add は飽和しない
    #
    # 本物と同じ ScoopFont.GdiV1 では定義できない。Collision.Tests.ps1 が
    # uninstaller.script を同一プロセスで実行するため、このスイートが走る頃には
    # 本物の型が既に読み込まれていることがある(アルファベット順で C < G)。
    # そうなるとスクリプト側の -as [type] ガードが真になってスタブが飛ばされ、
    # 静的フィールドが null のまま進む(実測)。型名ごと別にして、実行する
    # スクリプトのテキスト側を差し替える
    $script:StubType = 'ScoopStub.GdiV1'
    if (-not ($script:StubType -as [type])) {
        Add-Type -Namespace 'ScoopStub' -Name 'GdiV1' -MemberDefinition @'
public static System.Collections.Generic.Dictionary<string,int> Counts =
    new System.Collections.Generic.Dictionary<string,int>(System.StringComparer.OrdinalIgnoreCase);

// 実 GDI に合わせて、パスが解決できなければ何もしない。
// この分岐が無いと「ファイルを消してから外す」退行を振る舞いテストが見逃す
// (実測: 実 GDI は削除済みパスに対して Remove が false・カウント不変、
//  存在しないパスへの Add は 0 で増えない)
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

    $script:RefCount = {
        param([string]$Path)
        if ([ScoopStub.GdiV1]::Counts.ContainsKey($Path)) { [ScoopStub.GdiV1]::Counts[$Path] } else { 0 }
    }

    # --- 検証用のフォントを作る ---
    # 実在するフォントの name テーブル内の文字列を、同じバイト長の別名へ置換する。
    # 長さを変えなければオフセットもレコード長も変わらないので、単純な置換でよい。
    # bucket のどのフォントとも名前が衝突しないので、レジストリ名も混ざらない
    $script:MakeFont = {
        param([string]$Source, [string]$Dest, [string]$From, [string]$To)
        if ($From.Length -ne $To.Length) { throw "置換前後の長さが違う: '$From' -> '$To'" }
        $bytes = [IO.File]::ReadAllBytes($Source)
        $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes)
        $idx = $text.IndexOf($From)
        if ($idx -lt 0) { throw "name テーブルに '$From' が無い: $Source" }
        $fromBytes = [Text.Encoding]::BigEndianUnicode.GetBytes($From)
        $toBytes = [Text.Encoding]::BigEndianUnicode.GetBytes($To)
        for ($i = 0; $i -lt $bytes.Length - $fromBytes.Length; $i++) {
            $hit = $true
            for ($j = 0; $j -lt $fromBytes.Length; $j++) {
                if ($bytes[$i + $j] -ne $fromBytes[$j]) { $hit = $false; break }
            }
            if (-not $hit) { continue }
            for ($j = 0; $j -lt $toBytes.Length; $j++) { $bytes[$i + $j] = $toBytes[$j] }
        }
        [IO.File]::WriteAllBytes($Dest, $bytes)
    }

    # 素材は OS 同梱のフォント。scoop の管理外なので都合がよい。
    # 置換元のファミリ名を知っている必要があるので、任意の ttf を拾う
    # フォールバックにはできない(拾った先に 'BIZ UDGothic' は無く、
    # 全ケースが「name テーブルに無い」で死ぬ)。候補と名前を対にして持つ
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

    # --- 2/3. サンドボックス ---
    $script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) "gdi-refcount-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    $script:RealLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = Join-Path $script:Sandbox 'localappdata'
    New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

    $script:SandboxRegRoot = 'HKEY_CURRENT_USER\Software\ScoopFontRefCountTest'
    # 張り替える前に作る。New-PSDrive は存在しないキーを root にできない。
    # ここはまだ本物の HKCU: を見ているので、この 1 行だけが実レジストリへの書き込み
    New-Item -Path 'HKCU:\Software\ScoopFontRefCountTest' -Force | Out-Null

    $script:RealHkcuRoot = (Get-PSDrive HKCU).Root
    Remove-PSDrive -Name HKCU -Force
    New-PSDrive -Name HKCU -PSProvider Registry -Root $script:SandboxRegRoot -Scope Global | Out-Null

    # 張り替わっていなければ本物の HKCU を汚す。ここで止める
    if ((Get-PSDrive HKCU).Root -ne $script:SandboxRegRoot) {
        throw "HKCU: の張り替えに失敗した。本物のレジストリを汚さないため中止する"
    }

    # --- 対象スクリプト。manifest から取り出して原本と同じものを走らせる ---
    $manifestPath = Join-Path $script:Repo 'bucket\bizter.json'
    $m = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # 型名をスタブへ向ける。ガード文字列と呼び出しの両方が一括で置き換わる
    $script:InstallerSrc = ($m.installer.script -join "`n").Replace('ScoopFont.GdiV1', 'ScoopStub.GdiV1')
    $script:UninstallerSrc = ($m.uninstaller.script -join "`n").Replace('ScoopFont.GdiV1', 'ScoopStub.GdiV1')
    # 置換が効いていなければ本物の GDI を叩く。ここで止める
    if ($script:InstallerSrc -like '*ScoopFont.GdiV1*' -or $script:InstallerSrc -notlike '*ScoopStub.GdiV1*') {
        throw '型名の差し替えに失敗した。本物の GDI を触らないため中止する'
    }

    # scoop が用意する変数を模す。$dir は「app ディレクトリ」
    $script:RunInstaller = {
        param([string]$AppDir, [string]$AppName, [string]$Version)
        $dir = $AppDir; $app = $AppName; $version = $Version; $global = $false
        # 呼び出し元スコープの変数を読む点まで scoop と同じ
        Invoke-Expression $script:InstallerSrc
    }
    $script:RunUninstaller = {
        param([string]$AppDir, [string]$AppName, [string]$Version)
        $dir = $AppDir; $app = $AppName; $version = $Version; $global = $false
        Invoke-Expression $script:UninstallerSrc
    }

    $script:FontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"

    # 置換後の名前は置換前と同じバイト長でなければならない。素材によって
    # ファミリ名の長さが違うので、短い識別子を素材の長さへ詰める
    $script:TagFor = {
        param([string]$Token)
        $len = $script:SeedFamily.Length
        if ($Token.Length -gt $len) { throw "識別子が素材のファミリ名より長い: $Token" }
        $Token.PadRight($len, 'x')
    }

    # 1 ケースぶんの下ごしらえ。app ディレクトリに 1 本だけ置く
    $script:NewCase = {
        param([string]$Name, [string]$Token)
        $appDir = Join-Path $script:Sandbox "$Name\1.0.0"
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        & $script:MakeFont $script:SeedFont (Join-Path $appDir 'RefTest-Regular.ttf') `
            $script:SeedFamily (& $script:TagFor $Token)
        return $appDir
    }
}

AfterAll {
    # 張り替えたものを必ず戻す。戻さないとこのプロセスの後続テストが
    # サンドボックスのレジストリを見続ける
    if ($script:RealHkcuRoot) {
        Remove-PSDrive -Name HKCU -Force -ErrorAction SilentlyContinue
        New-PSDrive -Name HKCU -PSProvider Registry -Root $script:RealHkcuRoot -Scope Global |
            Out-Null
    }
    if ($script:RealLocalAppData) { $env:LOCALAPPDATA = $script:RealLocalAppData }

    Remove-Item -LiteralPath "Registry::$script:SandboxRegRoot" -Recurse -Force -ErrorAction SilentlyContinue
    if ($script:Sandbox) { Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue }
}

# 'Static' は付けない。実レジストリにサンドボックス用のキーを 1 つ作り、
# HKCU: PSDrive をプロセス単位で張り替えるため、-StaticOnly の対象外にする。
# 'GdiRef' タグはこのスイートだけを走らせたいときのため
Describe 'GDI 参照カウントの収支' -Tag 'GdiRef' {

    BeforeEach {
        # 破壊的操作の前に毎回サンドボックスを確認する。BeforeAll で 1 回だけ
        # 確かめても、以降の BeforeEach は無条件に Remove-Item -Recurse を撃つ。
        # 張り替えが外れていたら、このマシンの実フォント登録が黙って消える
        # (-ErrorAction SilentlyContinue なので失敗すら見えない)
        if ((Get-PSDrive HKCU).Root -ne $script:SandboxRegRoot) {
            throw 'HKCU: がサンドボックスを指していない。実レジストリを消さないため中止する'
        }
        if ($script:FontDir -notlike "$script:Sandbox*") {
            throw "フォントディレクトリがサンドボックス外を指している: $script:FontDir"
        }

        # ケース間で状態を持ち越さない。カウンタも配置先もレジストリも毎回まっさらにする。
        # ここを怠ると、前のケースが残した参照が次のケースの期待値に化けて、
        # どのケースが本当に壊れているのか分からなくなる(実測でそうなった)
        [ScoopStub.GdiV1]::Counts.Clear()
        Remove-Item -LiteralPath $script:FontDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "$env:LOCALAPPDATA\scoop-font-backup" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
            -Recurse -Force -ErrorAction SilentlyContinue
    }

    It '新規 install で 1 になり、uninstall で 0 に戻る' {
        $appDir = & $script:NewCase 'refcase1' 'Zq1'
        $dest = Join-Path $script:FontDir 'RefTest-Regular.ttf'

        & $script:RunInstaller $appDir 'refcase1' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 1 -Because 'install は自分の参照を 1 つ持つ'

        & $script:RunUninstaller $appDir 'refcase1' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 0 -Because 'uninstall で自分の参照だけ返す'
    }

    It '第三者が参照している既存ファイルを上書きしても収支が動かない' {
        # 配置先に別のフォントが既にあり、誰かが AddFontResourceW 済みという状況
        $appDir = & $script:NewCase 'refcase2' 'Zq2'
        $dest = Join-Path $script:FontDir 'RefTest-Regular.ttf'
        New-Item -ItemType Directory -Path $script:FontDir -Force | Out-Null
        & $script:MakeFont $script:SeedFont $dest $script:SeedFamily (& $script:TagFor 'Zt1')
        [void][ScoopStub.GdiV1]::AddFontResourceW($dest)
        (& $script:RefCount $dest) | Should -Be 1

        & $script:RunInstaller $appDir 'refcase2' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 1 -Because '上書き前に 1 つ外し、置いた後に 1 つ足すので増減しない'

        & $script:RunUninstaller $appDir 'refcase2' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 1 -Because '元ファイルを復元したので第三者の参照は戻っている'
    }

    It '誰も参照していない既存ファイルを上書きしても参照が生えない' {
        # 空振りした Remove のぶんまで Add すると、ここで 0 -> 1 以上になる。
        # 「呼んだ回数」で数えていた実装はこの経路で純増していた
        $appDir = & $script:NewCase 'refcase3' 'Zq3'
        $dest = Join-Path $script:FontDir 'RefTest-Regular.ttf'
        New-Item -ItemType Directory -Path $script:FontDir -Force | Out-Null
        & $script:MakeFont $script:SeedFont $dest $script:SeedFamily (& $script:TagFor 'Zt2')
        (& $script:RefCount $dest) | Should -Be 0

        & $script:RunInstaller $appDir 'refcase3' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 1 -Because '自分が置いたファイルの参照は 1 つ'

        & $script:RunUninstaller $appDir 'refcase3' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 0 -Because '復元した元ファイルは誰も参照していなかった'
    }

    It 'HadGdiRef を書いていない旧い記録でも第三者の参照を返す' {
        # ConvertFrom-Json は存在しないプロパティを $null にする。これを
        # 「参照は無かった」と読むと、元ファイルはディスクに戻るのに GDI 参照
        # だけ戻らず、第三者のフォントがセッションから消える。
        # この項目を書いていなかった版で入れたものが実際に手元に 40 件あった
        $appDir = & $script:NewCase 'refcase5' 'Zq5'
        $dest = Join-Path $script:FontDir 'RefTest-Regular.ttf'
        New-Item -ItemType Directory -Path $script:FontDir -Force | Out-Null
        & $script:MakeFont $script:SeedFont $dest $script:SeedFamily (& $script:TagFor 'Zt5')
        [void][ScoopStub.GdiV1]::AddFontResourceW($dest)

        & $script:RunInstaller $appDir 'refcase5' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 1

        # 記録から HadGdiRef を落として「旧い版が書いた記録」を作る
        $states = @(
            (Join-Path $appDir 'scoop-font-state.json'),
            (Join-Path "$env:LOCALAPPDATA\scoop-font-backup\refcase5-1.0.0" 'scoop-font-state.json')
        )
        foreach ($sp in $states) {
            if (-not (Test-Path -LiteralPath $sp)) { continue }
            $entries = @(Get-Content -LiteralPath $sp -Raw -Encoding UTF8 | ConvertFrom-Json |
                ForEach-Object { $_ | Select-Object -Property * -ExcludeProperty HadGdiRef })
            ($entries | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $sp -Encoding UTF8
        }
        # 落ちていることを確かめてから進む。落ちていないと検証にならない
        $check = Get-Content -LiteralPath $states[1] -Raw -Encoding UTF8 | ConvertFrom-Json
        @($check)[0].PSObject.Properties.Name | Should -Not -Contain 'HadGdiRef'

        & $script:RunUninstaller $appDir 'refcase5' '1.0.0'
        (& $script:RefCount $dest) | Should -Be 1 -Because '不明なときは第三者の参照を消さない側に倒す'
    }

    It 'install が失敗して巻き戻しても第三者の参照が減らない' {
        # 巻き戻しの補償が抜けていると、ここで 1 -> 0 になる。
        # ディスクは元どおりなのにセッションからフォントが消える経路
        $appDir = & $script:NewCase 'refcase4' 'Zq4'
        $dest = Join-Path $script:FontDir 'RefTest-Regular.ttf'
        New-Item -ItemType Directory -Path $script:FontDir -Force | Out-Null
        & $script:MakeFont $script:SeedFont $dest $script:SeedFamily (& $script:TagFor 'Zt3')
        [void][ScoopStub.GdiV1]::AddFontResourceW($dest)

        # 共有を Read にする。下調べの Get-FileHash と退避の Copy-Item は通り、
        # 配置の Move-Item -Force だけが失敗する。共有を None にすると下調べの
        # 段階で落ちてしまい、狙っている「変更に入った後の失敗」にならない
        $stream = [IO.File]::Open($dest, 'Open', 'Read', 'Read')
        try {
            { & $script:RunInstaller $appDir 'refcase4' '1.0.0' } | Should -Throw
        } finally {
            $stream.Dispose()
        }

        (& $script:RefCount $dest) | Should -Be 1 -Because '巻き戻したら外した分は必ず戻す'
    }
}
