# scoop:uninstaller  ここから 16 manifest 共通
$ErrorActionPreference = 'Stop'

# --- OS へフォントの増減を知らせる仕組み。installer と同じ内容を持つ ---
# 消したフォントを RemoveFontResourceW で現在のセッションのフォントテーブルから外し、
# WM_FONTCHANGE を配って起動済みのアプリにも再列挙させる。これが無いと
# アンインストール後も再ログオンするまでフォント一覧に残り続ける
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
    Write-Host "フォント通知 API を用意できなかった: $_" -Foreground Yellow
}

# 実際に外せたパスの記録。復元したファイルはここから戻す。
# 「外そうとした回数」ではなく「効いた回数」でなければならない。
# RemoveFontResourceW は参照が 0 になると false を返して飽和するが、
# AddFontResourceW は飽和しないため、空振りぶんまで Add すると参照が純増する
$removedOk = New-Object Collections.ArrayList

# 通知の失敗で uninstall を落とさない。ファイルとレジストリは既に片付いているので、
# 最悪でも「再ログオンするまで一覧に残る」で済む
$notifyFonts = {
    param([string[]]$Add, [string[]]$Remove, [switch]$Broadcast)
    if (-not ('ScoopFont.GdiV1' -as [type])) { return }
    # 1 パスの失敗で残りを巻き添えにしない。諦めた分は再ログオンまで
    # 一覧に残るだけで、ファイルとレジストリは正しい状態のまま
    foreach ($p in $Remove) {
        # Remove は「ファイルがまだ在るうち」に呼ぶこと。消した後だとパスを解決できず
        # 即 false が返り、セッションのフォントテーブルに残り続ける(実測)。
        #
        # 外すのは 1 回だけ。参照カウントはプロセスをまたいでセッション全体で共有される
        # (実測: プロセス A が 2 回 Add して終了した後、別プロセス B の
        # RemoveFontResourceW が 2 回 true を返した)。false になるまで外すと、
        # 同じファイルを使っている第三者アプリの参照まで奪ってしまう
        try {
            # 返り値を捨ててはいけない。true が「実際に 1 減った」の唯一の証拠
            if ([ScoopFont.GdiV1]::RemoveFontResourceW($p)) { [void]$removedOk.Add($p) }
        }
        catch { Write-Host "フォントの登録解除に失敗した: $p : $_" -Foreground Yellow }
    }
    foreach ($p in $Add) {
        try {
            if ([ScoopFont.GdiV1]::AddFontResourceW($p) -eq 0) {
                Write-Host "GDI へ追加できなかった: $p" -Foreground Yellow
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
# Get-FileHash は "being used by another process" で落ちる)。これをループの
# 手前に素で置くと、1 件のロックで「記録は退役済み・中身は何も片付いていない」
# という最悪の状態で終わる。読めないものは「自分のものではない」と見なす
# 返り値は 3 値。true なら自分のファイル、false なら別物、null なら読めなかった。
# $null も条件式では偽なので Where-Object などはそのまま書ける。
# 「別物なので残す」と「読めないので残す」は手当ての方向が真逆なので分ける
$isOurFile = {
    param([string]$Path, [string]$Hash)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return ((Get-FileHash -LiteralPath $Path).Hash -eq $Hash) }
    catch {
        Write-Host "ハッシュを取得できない(ロック中か権限不足): $Path : $_" -Foreground Yellow
        return $null
    }
}

# $version はここでは信用できない(実測。scoop update は scoop-update.ps1 の中で
# $version = $manifest.version を新版へ再代入した後、その同じスコープのまま
# 旧版の pre_uninstall/uninstaller フックを呼ぶ。Invoke-HookScript は
# パラメータ渡しをせず呼び出し元スコープの変数をそのまま読むため、旧版の
# uninstaller から見える $version は新版のものになっている。これに気づかず
# $backupDir を組み立てると、scoop update のたびに旧版の退避ディレクトリが
# 掃除されずオーファンとして残り続ける実害があった)。
# $dir は常に「今アンインストールしている版のディレクトリ」を指すので、
# フォルダ名(=バージョン文字列)からそのまま復元する
$appVersion = Split-Path $dir -Leaf
# journal（退避先）が正。app ディレクトリ側は写しなので、無い場合の予備として使う
$backupDir = "$env:LOCALAPPDATA\scoop-font-backup\$app-$appVersion"
$statePath = Join-Path $backupDir 'scoop-font-state.json'
if (-not (Test-Path -LiteralPath $statePath)) { $statePath = Join-Path $dir 'scoop-font-state.json' }
if (-not (Test-Path -LiteralPath $statePath)) {
    # 何も無いなら黙って戻ってよいが、退避ディレクトリまたはアプリディレクトリに
    # 記録が残っている場合は「中断された uninstall がある」という意味なので、
    # 場所を明示して気づけるようにする。退役済みの記録は「見つかった方」を
    # そのまま退役させるため、backupDir 側とは限らず dir 側に残ることもある
    Write-Host "有効な記録が見つからない。フォントの削除は行わない。" -Foreground Yellow
    Write-Host "  探した場所: $backupDir\scoop-font-state.json" -Foreground Yellow
    Write-Host "              $dir\scoop-font-state.json" -Foreground Yellow
    $foundAny = $false
    foreach ($d in $backupDir, $dir) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $found = @(Get-ChildItem $d -Filter '*.json' -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) { continue }
        if (-not $foundAny) {
            Write-Host "  記録が残っている。中断された uninstall の可能性がある:" -Foreground Yellow
            $foundAny = $true
        }
        $found | ForEach-Object { Write-Host "    $($_.FullName)" -Foreground Yellow }
    }
    if ($foundAny) {
        # Phase はインストーラーだけが書き、アンインストーラーは更新しない。
        # つまり退役済みの記録が残しているのは install 時の計画であって、
        # 中断された uninstall が実際に何を undo できた/できなかったかではない
        Write-Host "  退役済みの記録 (*.retired.json) には install 時の計画が残っている(何を undo したかではない)" -Foreground Yellow
    }
    return
}

# @(...) で囲んではいけない。PS 5.1 の ConvertFrom-Json は配列を 1 個の値として流すため、
# @() で包むと foreach が 1 回しか回らず $e が配列全体になる（実測で確認済み）
$entries = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
$unresolved = New-Object Collections.ArrayList   # 触れなかったエントリ

# 記録を「何かを変更する前に」退役させる。
# 退役を最後に置くと、その 1 行が失敗したときだけ「変更済み × 有効な記録」という
# 危険な組み合わせが残る。後日同じ版を入れ直したときに「中断した試行の続き」と誤認され、
# 所有権の追跡が壊れて uninstall が成功を報告しながら何も消さない状態に陥る。
# 先に退役させておけば、リネームが失敗するのは「まだ何も変更していない」時点なので、
# そこで落ちても安全。中断しても残るのは「退役済みの記録 ＋ 部分的に片付いた状態」で、
# 次の install が誤認する経路が存在しない
$retired = Join-Path (Split-Path $statePath) 'scoop-font-state.retired.json'
Move-Item -LiteralPath $statePath -Destination $retired -Force

# 触る対象。Phase が planned / rolledback のものは install が何もしていないので除く
$touched = @($entries | Where-Object { $_.Phase -ne 'planned' -and $_.Phase -ne 'rolledback' })

# ファイルを消す「前」に GDI 側の登録を外す。消した後では RemoveFontResourceW が
# パスを解決できず false を返すだけで、セッションのフォントテーブルに残り続ける。
# 実測では uninstall 後もファイル・レジストリが消えているのにアプリからは
# フォントが見えたままだった。
#
# 対象は「今そこに在るのが自分の置いたファイル」に限る。install 後に第三者が
# 置き換えた配置先まで外すと、相手の参照を奪うことになる(後のループでも
# そういうファイルは「残す」と判断している)
$mine = @($touched | Where-Object { & $isOurFile $_.Dest $_.Hash } | ForEach-Object { $_.Dest })
& $notifyFonts -Remove $mine

foreach ($e in $entries) {
    if ($e.Phase -eq 'planned' -or $e.Phase -eq 'rolledback') { continue }
    # 1 件の失敗で残り全部と退役処理を巻き添えにしない。
    # ここを素通しにしていたため、ロック中のファイルで例外が出た瞬間にループが止まり、
    # 記録の退役も飛んで「次の install が既存ファイルありと誤認 → 以後の uninstall が
    # 復元に化けて成功を報告しながら何も消さない」状態に陥る事故が実際に起きた
    try {
    # install 時のスコープを記録から復元する。installer とは別の呼び出しなので変数は残っていない
    $regKey = "$($e.RegRoot):\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

    # --- レジストリ。自分が書いた値のままであれば戻す ---
    $prop = Get-ItemProperty -Path $regKey -Name $e.RegName -ErrorAction SilentlyContinue
    $curReg = if ($prop) { $prop.($e.RegName) } else { $null }   # 括弧が必要（下記の注意を参照）
    # 値が消えていても HadRegValue なら復元する。放置すると journal ごと元の値を失う
    if (($curReg -eq $e.InstalledRegValue) -or ($null -eq $curReg -and $e.HadRegValue)) {
        if ($e.HadRegValue) { New-ItemProperty -Path $regKey -Name $e.RegName -Value $e.PrevRegValue -Force | Out-Null }
        else { Remove-ItemProperty -Path $regKey -Name $e.RegName -Force -ErrorAction SilentlyContinue }
    } elseif ($null -ne $curReg) {
        Write-Host "レジストリは残す: $($e.RegName) は install 後に変更されている" -Foreground Yellow
        [void]$unresolved.Add($e.File)
    }

    # --- ファイル ---
    $destExists = Test-Path -LiteralPath $e.Dest
    # ロックされていると Get-FileHash は落ちる。素で書くとこのエントリの
    # 残り(一時ファイルの後始末)まで飛ぶので、判定は $isOurFile を通す
    $ours = & $isOurFile $e.Dest $e.Hash
    $destIsOurs = ($ours -eq $true)

    if ($destExists -and -not $destIsOurs) {
        if ($null -eq $ours) {
            # 「置き換えられている」と出すと手当ての方向が逆になる。
            # こちらは使用中のアプリを閉じて再実行すれば片付く
            Write-Host "ファイルは残す: $($e.File) を読めなかった(使用中か権限不足)。閉じてから再実行すること" -Foreground Yellow
        } else {
            Write-Host "ファイルは残す: $($e.File) は install 後に置き換えられている" -Foreground Yellow
        }
        [void]$unresolved.Add($e.File)
    } elseif ($e.HadDest) {
        # 配置先が消えていても復元する。退避を残したまま消すと元ファイルを失う
        if (-not ($e.Backup -and (Test-Path -LiteralPath $e.Backup))) {
            Write-Host "復元できない: $($e.File) の退避が見つからない" -Foreground Yellow
            [void]$unresolved.Add($e.File)
        } elseif ((Get-FileHash -LiteralPath $e.Backup).Hash -ne $e.PrevDestHash) {
            Write-Host "復元できない: $($e.File) の退避が壊れている" -Foreground Yellow
            [void]$unresolved.Add($e.File)
        } else {
            Copy-Item -LiteralPath $e.Backup -Destination $e.Dest -Force
        }
    } elseif ($destIsOurs) {
        Remove-Item -LiteralPath $e.Dest -Force
    }

    # 中断で取り残された一時ファイル
    if (Test-Path -LiteralPath "$($e.Dest).scoop-tmp") { Remove-Item -LiteralPath "$($e.Dest).scoop-tmp" -Force }
    } catch {
        Write-Host "処理できなかった: $($e.File): $_" -Foreground Yellow
        [void]$unresolved.Add($e.File)
    }
}

# 登録し直すのは「元ファイルを戻したうえで、元から GDI 参照があった配置先」だけ。
#
# 「実際に外せた分を戻す」では足りない。外したのは install 時に自分が足した参照で、
# 戻す先は復元された元ファイルだからだ。元ファイルを誰も参照していなかった場合
# (HadGdiRef が false)、戻すと誰も外さない参照が生える。install 時に
# 上書き前 Remove が true を返したかを記録してあるので、それで判断する。
#
# $mine で数えるのも誤り。install 側の Add が失敗していた場合、Remove は空振りして
# false を返すので、$mine を戻すと外していない参照を足すことになる
#
# HadGdiRef が記録に「無い」場合を false と同一視してはいけない。
# ConvertFrom-Json は存在しないプロパティを $null にするので、この項目を
# 書いていなかった版の記録を読むと、区別が付かないまま「参照は無かった」と
# 判断してしまう。元ファイルはディスクに戻るのに GDI 参照だけ戻らず、
# 第三者のフォントがセッションから消える(実測: 記録から HadGdiRef を
# 抜くと refcount が 1 -> 0 になった)。
# 不明なときは HadDest に倒す。参照を 1 つ余分に足す害は再ログオンで消えるが、
# 第三者の参照を消す害は相手のアプリが壊れる。軽い方を選ぶ
$readd = @($touched | Where-Object {
    $hadRef = if ($_.PSObject.Properties.Name -contains 'HadGdiRef') { $_.HadGdiRef } else { $_.HadDest }
    $hadRef -and ($removedOk -contains $_.Dest) -and (Test-Path -LiteralPath $_.Dest)
} | ForEach-Object { $_.Dest })
& $notifyFonts -Add $readd -Broadcast

# 記録は既にループ前で退役させてある。ここでは退避の後始末だけを判断する
if ($unresolved.Count -eq 0) {
    # 全件片付いた。退避はもう不要なので丸ごと消し、消えたことを確認する
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $backupDir) { throw "退避 $backupDir を削除できなかった。手で消すこと（残すと次回の install が誤動作する）" }
} else {
    # 触れなかったファイルの退避は消せない。記録は既に退役済み
    Write-Host "未解決のファイルがある。退避は $backupDir に残す:" -Foreground Yellow
    $unresolved | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -Foreground Yellow }
}
