# scoop:uninstaller  ここから 16 manifest 共通
$ErrorActionPreference = 'Stop'

# --- OS へフォントの増減を知らせる仕組み。installer と同じ内容を持つ ---
# 消したフォントを RemoveFontResourceW で現在のセッションのフォントテーブルから外し、
# WM_FONTCHANGE を配って起動済みのアプリにも再列挙させる。これが無いと
# アンインストール後も再ログオンするまでフォント一覧に残り続ける
try {
    if (-not ('ScoopFont.Gdi' -as [type])) {
        Add-Type -Namespace 'ScoopFont' -Name 'Gdi' -MemberDefinition @'
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

# 通知の失敗で uninstall を落とさない。ファイルとレジストリは既に片付いているので、
# 最悪でも「再ログオンするまで一覧に残る」で済む
$notifyFonts = {
    param([string[]]$Add, [string[]]$Remove, [switch]$Broadcast)
    if (-not ('ScoopFont.Gdi' -as [type])) { return }
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
        try { [void][ScoopFont.Gdi]::RemoveFontResourceW($p) }
        catch { Write-Host "フォントの登録解除に失敗した: $p : $_" -Foreground Yellow }
    }
    foreach ($p in $Add) {
        try {
            if ([ScoopFont.Gdi]::AddFontResourceW($p) -eq 0) {
                Write-Host "GDI へ追加できなかった: $p" -Foreground Yellow
            }
        } catch { Write-Host "フォントの登録に失敗した: $p : $_" -Foreground Yellow }
    }
    if ($Broadcast) {
        # HWND_BROADCAST = 0xffff / WM_FONTCHANGE = 0x1D / SMTO_ABORTIFHUNG = 2。
        # タイムアウトはウィンドウ 1 枚ごとに効くので、増減を済ませてから 1 回だけ配る
        try {
            $res = [IntPtr]::Zero
            [void][ScoopFont.Gdi]::SendMessageTimeout([IntPtr]0xffff, 0x1D, [IntPtr]::Zero, [IntPtr]::Zero, 2, 3000, [ref]$res)
        } catch { Write-Host "WM_FONTCHANGE の配信に失敗した: $_" -Foreground Yellow }
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
if (-not (Test-Path $statePath)) { $statePath = Join-Path $dir 'scoop-font-state.json' }
if (-not (Test-Path $statePath)) {
    # 何も無いなら黙って戻ってよいが、退避ディレクトリまたはアプリディレクトリに
    # 記録が残っている場合は「中断された uninstall がある」という意味なので、
    # 場所を明示して気づけるようにする。退役済みの記録は「見つかった方」を
    # そのまま退役させるため、backupDir 側とは限らず dir 側に残ることもある
    Write-Host "有効な記録が見つからない。フォントの削除は行わない。" -Foreground Yellow
    Write-Host "  探した場所: $backupDir\scoop-font-state.json" -Foreground Yellow
    Write-Host "              $dir\scoop-font-state.json" -Foreground Yellow
    $foundAny = $false
    foreach ($d in $backupDir, $dir) {
        if (-not (Test-Path $d)) { continue }
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
$mine = @($touched | Where-Object {
    (Test-Path -LiteralPath $_.Dest -PathType Leaf) -and
    (Get-FileHash -LiteralPath $_.Dest).Hash -eq $_.Hash
} | ForEach-Object { $_.Dest })
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
    $destExists = Test-Path $e.Dest
    $destIsOurs = $destExists -and (Get-FileHash -LiteralPath $e.Dest).Hash -eq $e.Hash

    if ($destExists -and -not $destIsOurs) {
        Write-Host "ファイルは残す: $($e.File) は install 後に置き換えられている" -Foreground Yellow
        [void]$unresolved.Add($e.File)
    } elseif ($e.HadDest) {
        # 配置先が消えていても復元する。退避を残したまま消すと元ファイルを失う
        if (-not ($e.Backup -and (Test-Path $e.Backup))) {
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
    if (Test-Path "$($e.Dest).scoop-tmp") { Remove-Item -LiteralPath "$($e.Dest).scoop-tmp" -Force }
    } catch {
        Write-Host "処理できなかった: $($e.File): $_" -Foreground Yellow
        [void]$unresolved.Add($e.File)
    }
}

# 登録し直すのは、さっき外した分のうちまだファイルが在るもの＝復元された元ファイルだけ。
# 「実在する配置先すべて」にすると、外していないファイルにまで参照を足すことになる。
# 判断を「消したつもり」ではなく実状態で行うので、途中で失敗した項目が混ざっていても揃う
& $notifyFonts -Add @($mine | Where-Object { Test-Path -LiteralPath $_ }) -Broadcast

# 記録は既にループ前で退役させてある。ここでは退避の後始末だけを判断する
if ($unresolved.Count -eq 0) {
    # 全件片付いた。退避はもう不要なので丸ごと消し、消えたことを確認する
    Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $backupDir) { throw "退避 $backupDir を削除できなかった。手で消すこと（残すと次回の install が誤動作する）" }
} else {
    # 触れなかったファイルの退避は消せない。記録は既に退役済み
    Write-Host "未解決のファイルがある。退避は $backupDir に残す:" -Foreground Yellow
    $unresolved | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -Foreground Yellow }
}
