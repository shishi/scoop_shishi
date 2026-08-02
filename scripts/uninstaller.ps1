# scoop:uninstaller  ここから 16 manifest 共通
$ErrorActionPreference = 'Stop'

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
    # 何も無いなら黙って戻ってよいが、退避ディレクトリだけ残っている場合は
    # 「中断された uninstall がある」という意味なので、場所を明示して気づけるようにする
    Write-Host "有効な記録が見つからない。フォントの削除は行わない。" -Foreground Yellow
    Write-Host "  探した場所: $backupDir\scoop-font-state.json" -Foreground Yellow
    Write-Host "              $dir\scoop-font-state.json" -Foreground Yellow
    if (Test-Path $backupDir) {
        Write-Host "  退避ディレクトリが残っている。中断された uninstall の可能性がある:" -Foreground Yellow
        Get-ChildItem $backupDir -Filter '*.json' -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Host "    $($_.Name)" -Foreground Yellow }
        Write-Host "  退役済みの記録 (*.retired.json) があれば、そこに何を触ったかが残っている" -Foreground Yellow
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
