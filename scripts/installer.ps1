# scoop:installer  ここから 16 manifest 共通
$ErrorActionPreference = 'Stop'

function Get-FontFullName([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $n = $b.Length
    $u16 = { param($o) if ($o + 1 -ge $n) { throw "範囲外: $Path" }; [int]$b[$o] * 256 + [int]$b[$o + 1] }
    $u32 = { param($o) [int64](& $u16 $o) * 65536 + (& $u16 ($o + 2)) }
    if ($n -lt 12) { throw "フォントとして短すぎる: $Path" }
    if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -eq 'ttcf') { throw "TTC は非対応: $Path" }
    $nameOff = $null
    for ($i = 0; $i -lt (& $u16 4); $i++) {
        $rec = 12 + $i * 16
        if ([Text.Encoding]::ASCII.GetString($b, $rec, 4) -eq 'name') { $nameOff = & $u32 ($rec + 8); break }
    }
    if ($null -eq $nameOff -or $nameOff + 6 -gt $n) { throw "name テーブルが無い: $Path" }
    $strOff = $nameOff + (& $u16 ($nameOff + 4))
    $best = $null; $bestRank = 99
    for ($i = 0; $i -lt (& $u16 ($nameOff + 2)); $i++) {
        $r = $nameOff + 6 + $i * 12
        if ((& $u16 ($r + 6)) -ne 4) { continue }   # nameID 4 = Full font name
        # $pid という名前は使えない。PowerShell の自動変数で読み取り専用のため、
        # 関数の中でも代入した瞬間に Cannot overwrite variable PID で落ちる（実測）
        $platform = & $u16 $r; $lid = & $u16 ($r + 4)
        $rank = if ($platform -eq 3 -and $lid -eq 0x409) { 0 } elseif ($platform -eq 3) { 1 } elseif ($platform -eq 0) { 2 } else { 9 }
        if ($rank -ge $bestRank) { continue }
        $len = & $u16 ($r + 8); $off = $strOff + (& $u16 ($r + 10))
        if ($off -lt 0 -or $off + $len -gt $n) { throw "name の文字列が範囲外: $Path" }
        # platform 3 (Windows) と platform 0 (Unicode) はどちらも UTF-16BE
        $best = [Text.Encoding]::BigEndianUnicode.GetString($b, $off, $len); $bestRank = $rank
    }
    if (-not $best) { throw "nameID 4 が無い: $Path" }
    return $best
}

# --- OS へフォントの増減を知らせる仕組み ---
# レジストリ登録とファイル配置だけでは、あとから起動したプロセスからも
# DirectWrite にフォントが見えなかった(実測)。AddFontResourceW で現在のセッションの
# フォントテーブルへ加え、WM_FONTCHANGE を配って起動済みのアプリにも再列挙させる。
# これが無いと再ログオンするまで使えない
#
# 型名に版番号を付けておく。scoop update は同一プロセスで旧版 uninstaller →
# 新版 installer の順に走らせるため、名前が同じだと新版の Add-Type が
# 「もうある」と判断されて飛ばされ、新版のコードが旧版の P/Invoke 定義で動く。
# 定義を変えるときはここの番号を上げること
try {
    if (-not ('ScoopFont.GdiV1' -as [type])) {
        Add-Type -Namespace 'ScoopFont' -Name 'GdiV1' -MemberDefinition @'
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern int AddFontResourceW(string path);
[DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
public static extern bool RemoveFontResourceW(string path);
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam,
    IntPtr lParam, uint flags, uint timeout, out IntPtr result);
'@
    }
} catch {
    # Add-Type はコンパイラを呼ぶので環境によっては失敗しうる。
    # 通知できないだけで install 自体は成立するため、ここでは止めない
    Write-Host "フォント通知 API を用意できなかった: $_" -Foreground Yellow
}

# 実際に外せたパスの記録。巻き戻しでここから戻す。
# 「外そうとした回数」ではなく「効いた回数」でなければならない。
# RemoveFontResourceW は参照が 0 になると false を返して飽和するが、
# AddFontResourceW は飽和しない。呼んだ回数で数えると、空振りした Remove のぶんまで
# Add してしまい、触ってもいないファイルの参照が純増する(レビューで実測)
$removedOk = New-Object Collections.ArrayList

# 通知の失敗で install を落とさない。フォントは既に置かれているので、
# 最悪でも「再ログオンするまで反映されない」で済む。ここで throw すると
# 成功した変更まで巻き戻すことになり、実害の方が大きい
$notifyFonts = {
    param([string[]]$Add, [string[]]$Remove, [switch]$Broadcast)
    if (-not ('ScoopFont.GdiV1' -as [type])) { return }
    # 1 パスの失敗で残りを巻き添えにしない。諦めた分は再ログオンまで
    # 反映されないだけで、ファイルとレジストリは正しい状態のまま
    foreach ($p in $Remove) {
        # Remove は「ファイルがまだ在るうち」に呼ぶこと。消した後だとパスを解決できず
        # 即 false が返り、セッションのフォントテーブルに残り続ける(実測)。
        #
        # 外すのは 1 回だけ。参照カウントはプロセスをまたいでセッション全体で共有される
        # (実測: プロセス A が 2 回 Add して終了した後、別プロセス B の
        # RemoveFontResourceW が 2 回 true を返した)。false になるまで外すと、
        # 同じファイルを使っている第三者アプリの参照まで奪ってしまう。
        # install 1 回につき Add 1 回・uninstall 1 回につき Remove 1 回で釣り合う
        try {
            # 返り値を捨ててはいけない。true が「実際に 1 減った」の唯一の証拠で、
            # 巻き戻しで戻すべき対象はこれだけ
            if ([ScoopFont.GdiV1]::RemoveFontResourceW($p)) { [void]$removedOk.Add($p) }
        }
        catch { Write-Host "フォントの登録解除に失敗した: $p : $_" -Foreground Yellow }
    }
    foreach ($p in $Add) {
        # 戻り値 0 は失敗。捨てると「install は成功したのにフォントが使えない」が
        # 無言で起きる。それはまさにこの通知が直そうとしている症状そのもの
        try {
            if ([ScoopFont.GdiV1]::AddFontResourceW($p) -eq 0) {
                Write-Host "GDI へ追加できなかった。再ログオンまで使えない場合がある: $p" -Foreground Yellow
            }
        } catch { Write-Host "フォントの登録に失敗した: $p : $_" -Foreground Yellow }
    }
    if ($Broadcast) {
        # HWND_BROADCAST = 0xffff / WM_FONTCHANGE = 0x1D / SMTO_ABORTIFHUNG = 2。
        # タイムアウトはウィンドウ 1 枚ごとに効くので、増減を済ませてから 1 回だけ配る
        try {
            $res = [IntPtr]::Zero
            [void][ScoopFont.GdiV1]::SendMessageTimeout([IntPtr]0xffff, 0x1D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 3000, [ref]$res)
        } catch { Write-Host "WM_FONTCHANGE の配信に失敗した: $_" -Foreground Yellow }
    }
}

# 配置先に在るのが自分の置いたファイルかを、例外を投げずに判定する。
# $ErrorActionPreference = 'Stop' の下では、排他オープンされたファイルに対する
# Get-FileHash は terminating error になる(実測: Test-Path は True を返すが
# Get-FileHash は "being used by another process" で落ちる)。これを巻き戻しや
# uninstall の入口に素で置くと、1 件のロックで後続の処理が丸ごと飛ぶ。
# 読めないものは「自分のものではない」と見なして安全側へ倒す
# 返り値は 3 値。true なら自分のファイル、false なら別物、null なら読めなかった。
# $null も条件式では偽なので Where-Object などはそのまま書ける。
# 呼び出し側が「別物」と「読めない」で案内を変えられるように分けてある
$isOurFile = {
    param([string]$Path, [string]$Hash)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return ((Get-FileHash -LiteralPath $Path).Hash -eq $Hash) }
    catch {
        Write-Host "ハッシュを取得できない(ロック中か権限不足): $Path : $_" -Foreground Yellow
        return $null
    }
}

# global インストールは対象外。中途半端に対応するより明確に拒否する
if ($global) { throw "$app は per-user インストール専用。-g を外して実行すること。" }

$fontDir   = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
$regRoot   = 'HKCU'
$regKey    = "${regRoot}:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"
$backupDir = Join-Path "$env:LOCALAPPDATA\scoop-font-backup" "$app-$version"
$statePath = Join-Path $dir 'scoop-font-state.json'
$journalPath = Join-Path $backupDir 'scoop-font-state.json'   # app ディレクトリが消えても残る控え

$saveState = {
    $json = $plan | ConvertTo-Json -Depth 3
    foreach ($p in @($statePath, $journalPath)) {
        if (-not (Test-Path -LiteralPath (Split-Path $p))) { continue }
        $json | Set-Content -LiteralPath "$p.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$p.tmp" -Destination $p -Force
    }
}

# 前回の試行が強制終了で残した記録があれば、それを「元の状態」の正とする
$prior = $null
if (Test-Path -LiteralPath $journalPath) {
    $prior = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "前回の試行の記録が残っている。元の状態はそちらを使う: $journalPath" -Foreground Yellow
}

# --- 1. 下調べ。ここでは何も変更しない ---
$plan = New-Object Collections.ArrayList
foreach ($f in (Get-ChildItem $dir -Recurse -Include '*.ttf', '*.otf' |
                Where-Object { $_.BaseName -notmatch '35' })) {
    $type = if ($f.Extension -eq '.otf') { ' (OpenType)' } else { ' (TrueType)' }
    $regName = (Get-FontFullName $f.FullName) + $type   # 失敗したらここで例外。変更前に止まる
    $dest = Join-Path $fontDir $f.Name
    if ($plan.Dest -contains $dest) { throw "同じ配置先が重複している: $dest" }
    # 配置先がディレクトリだと Copy-Item は $dest.scoop-tmp へ書き込むため素通りし、
    # 続く Move-Item -Force はディレクトリの中へ書き込んでエラーにならない（実測）。
    # 検知せずに進めると、レジストリだけディレクトリを指す壊れた状態が「成功」として残る
    if ((Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $dest -PathType Leaf)) {
        throw "配置先がファイルではない: $dest"
    }
    $prop = Get-ItemProperty -Path $regKey -Name $regName -ErrorAction SilentlyContinue
    $hadDest = Test-Path -LiteralPath $dest

    # 前回の記録があれば、今の実状態ではなくそちらを「元の状態」とする。
    # 前回の試行が既に上書きしているので、今見えているのは自分が置いたファイルかもしれない
    $old = if ($prior) { $prior | Where-Object { $_.File -eq $f.Name } | Select-Object -First 1 } else { $null }

    [void]$plan.Add([pscustomobject]@{
        Src = $f.FullName; File = $f.Name; Dest = $dest; RegName = $regName
        HadDest      = if ($old) { $old.HadDest }     else { $hadDest }            # ファイルの所有権
        HadRegValue  = if ($old) { $old.HadRegValue } else { $null -ne $prop }     # レジストリの所有権（独立に持つ）
        PrevRegValue = if ($old) { $old.PrevRegValue } elseif ($prop) { $prop.($regName) } else { $null }
        Backup       = if ($old) { $old.Backup } elseif ($hadDest) { Join-Path $backupDir $f.Name } else { $null }
        # 退避の検証はこのハッシュで行う。変更前に計画へ入れて保存するので、
        # 変更の途中でプロセスが落ちても失われない
        PrevDestHash = if ($old) { $old.PrevDestHash } elseif ($hadDest) { (Get-FileHash -LiteralPath $dest).Hash } else { $null }
        InstalledRegValue = $dest
        Hash    = (Get-FileHash -LiteralPath $f.FullName).Hash
        RegRoot = $regRoot
        Phase   = 'planned'   # planned -> mutating -> done（巻き戻したら rolledback）
    })
}

# --- 2. 変更前に計画を保存する。install が失敗して scoop が uninstaller を呼ばなくても手で追える ---
New-Item $backupDir -ItemType Directory -Force | Out-Null   # 控えの置き場を先に作る
& $saveState

# --- 3. 変更。各段階の直前に Phase を進めて保存する ---
try {
    New-Item $fontDir -ItemType Directory -Force | Out-Null
    $acl = Get-Acl $fontDir
    foreach ($sid in 'S-1-15-2-1', 'S-1-15-2-2') {
        $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            [System.Security.Principal.SecurityIdentifier]::new($sid),
            'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -AclObject $acl $fontDir

    # 一度も per-user フォントを入れたことが無いプロファイルでは、このキー自体が
    # 存在しない。New-ItemProperty -Force は値の作成・上書きは Force するが、
    # 親キーが無い場合の作成まではしない(実測: キー不在だと
    # "Cannot find path ... because it does not exist" で失敗する)。ここで先に作る
    if (-not (Test-Path -LiteralPath $regKey)) { New-Item -Path $regKey -Force | Out-Null }

    # 上書きする配置先は、書き込む前に GDI の登録を外しておく。
    # 参照カウントが 0 でないパスにファイルを被せても GDI は読み直さず、古い中身を
    # 配り続ける(実測: パス P へ font A を Add してから P を font B で上書きし、
    # もう一度 Add しても、別プロセスからは最後まで A のまま見えた)。
    #
    # これは best-effort。参照カウントが 2 以上あると 1 回外しても 0 に落ちず、
    # 陳腐化はそのまま残る(実測)。0 まで外せば確実だが、それは同じファイルを
    # 使っている第三者アプリの参照を奪うことになるので採らない。
    #
    # 判断は所有権の記録($_.HadDest)ではなく「今そこにファイルが在るか」。
    # HadDest は前回の試行のジャーナルを引き継ぐことがあり、今の実状態とずれる。
    # ずれたまま Remove を飛ばすと、この後の Add と釣り合わず参照が二重に残る
    & $notifyFonts -Remove @($plan |
        Where-Object { Test-Path -LiteralPath $_.Dest -PathType Leaf } |
        ForEach-Object { $_.Dest })

    foreach ($e in $plan) {
        # 変更に入る前に印を付けて保存する。途中でプロセスが落ちても対象だと分かる
        $e.Phase = 'mutating'; & $saveState

        # 既にある退避は絶対に上書きしない。前回の試行が残した本物の元ファイルかもしれない
        if ($e.Backup -and -not (Test-Path -LiteralPath $e.Backup)) {
            New-Item $backupDir -ItemType Directory -Force | Out-Null
            Copy-Item -LiteralPath $e.Dest -Destination "$($e.Backup).tmp" -Force
            Move-Item -LiteralPath "$($e.Backup).tmp" -Destination $e.Backup -Force
        }
        if ($e.Backup -and (Get-FileHash -LiteralPath $e.Backup).Hash -ne $e.PrevDestHash) {
            throw "退避の検証に失敗: $($e.File)"
        }
        # 一時名へ書いてから置換する。途中で切れても配置先が壊れた中身にならない
        Copy-Item -LiteralPath $e.Src -Destination "$($e.Dest).scoop-tmp" -Force
        Move-Item -LiteralPath "$($e.Dest).scoop-tmp" -Destination $e.Dest -Force

        New-ItemProperty -Path $regKey -Name $e.RegName -Value $e.InstalledRegValue -Force | Out-Null

        $e.Phase = 'done'; & $saveState
    }

    # 変更が全部通ってから 1 回だけ通知する。1 件ごとにブロードキャストすると
    # 起動中のアプリがフォント数だけ再列挙して無駄に重い
    & $notifyFonts -Add @($plan | ForEach-Object { $_.Dest }) -Broadcast
} catch {
    # --- 4. 自力で巻き戻す。scoop は失敗した install に対して uninstaller を呼ばない ---
    $original = $_
    $failed = New-Object Collections.ArrayList

    # 巻き戻しでファイルを消す/元へ差し替える前に、GDI 側の登録を外しておく。
    # 消した後では RemoveFontResourceW がパスを解決できず、外れないまま残る。
    #
    # 対象は「Phase が planned でない」ではなく「今そこに在るのが自分の置いたファイル」。
    # 印を付けた直後に退避の検証で落ちた場合など、mutating のままファイルには
    # 一切触れていないエントリがある。そこに第三者の既存フォントがあると
    # (Collision.Tests.ps1 が扱う状況)、触っていないファイルの登録まで剥がしてしまう
    $mine = @($plan | Where-Object {
        $_.Phase -ne 'planned' -and (& $isOurFile $_.Dest $_.Hash)
    } | ForEach-Object { $_.Dest })
    & $notifyFonts -Remove $mine
    for ($i = $plan.Count - 1; $i -ge 0; $i--) {     # 逆順で戻す
        $e = $plan[$i]
        if ($e.Phase -eq 'planned') { continue }
        # 1 件の失敗で巻き戻し全体を止めない。判断基準は uninstall と同じ「今の実状態」
        try {
            $prop = Get-ItemProperty -Path $regKey -Name $e.RegName -ErrorAction SilentlyContinue
            $cur = if ($prop) { $prop.($e.RegName) } else { $null }
            if (($cur -eq $e.InstalledRegValue) -or ($null -eq $cur -and $e.HadRegValue)) {
                if ($e.HadRegValue) { New-ItemProperty -Path $regKey -Name $e.RegName -Value $e.PrevRegValue -Force | Out-Null }
                else { Remove-ItemProperty -Path $regKey -Name $e.RegName -Force -ErrorAction SilentlyContinue }
            }

            if (Test-Path -LiteralPath "$($e.Dest).scoop-tmp") { Remove-Item -LiteralPath "$($e.Dest).scoop-tmp" -Force }

            $destExists = Test-Path -LiteralPath $e.Dest
            # ロックされていると Get-FileHash は落ちる。判定は $isOurFile を通す
            $destIsOurs = & $isOurFile $e.Dest $e.Hash
            if ($destExists -and -not $destIsOurs) {
                # 第三者のファイル。触らない
            } elseif ($e.HadDest) {
                if (-not ($e.Backup -and (Test-Path -LiteralPath $e.Backup) -and
                          (Get-FileHash -LiteralPath $e.Backup).Hash -eq $e.PrevDestHash)) {
                    throw "退避が無いか壊れていて復元できない"
                }
                Copy-Item -LiteralPath $e.Backup -Destination $e.Dest -Force
                if ((Get-FileHash -LiteralPath $e.Dest).Hash -ne $e.PrevDestHash) { throw "復元後の検証に失敗" }
            } elseif ($destIsOurs) {
                Remove-Item -LiteralPath $e.Dest -Force
            }

            $e.Phase = 'rolledback'   # 検証まで通ったものだけ完了印を付ける
        } catch {
            [void]$failed.Add("$($e.File): $_")   # Phase は mutating のまま残し、後の uninstall に拾わせる
        }
    }
    & $saveState

    # 「実際に外せた分」だけを戻す。これが守るべき不変条件。
    # 呼んだ回数で数えてはいけない。RemoveFontResourceW は参照が 0 になると
    # false を返して飽和するのに、AddFontResourceW は飽和しない。
    # 同じパスがループ前と巻き戻しの両方で Remove 対象になると、
    # 実効 1 減・2 増で純増する(レビューで実測)。$removedOk には true が
    # 返ったものだけが入っているので、そのまま戻せば必ず収支が合う
    $restore = New-Object Collections.ArrayList
    foreach ($p in @($removedOk)) {
        if ($p -and (Test-Path -LiteralPath $p)) { [void]$restore.Add($p) }
    }
    & $notifyFonts -Add $restore -Broadcast

    if ($failed.Count) {
        Write-Host "巻き戻しに失敗した項目がある。$statePath を見て手で復旧すること:" -Foreground Red
        $failed | ForEach-Object { Write-Host "  $_" -Foreground Red }
    }
    throw $original   # 元の失敗原因を握りつぶさない
}
