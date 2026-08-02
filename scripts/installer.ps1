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
        if (-not (Test-Path (Split-Path $p))) { continue }
        $json | Set-Content -LiteralPath "$p.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$p.tmp" -Destination $p -Force
    }
}

# 前回の試行が強制終了で残した記録があれば、それを「元の状態」の正とする
$prior = $null
if (Test-Path $journalPath) {
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
    if ((Test-Path $dest) -and -not (Test-Path $dest -PathType Leaf)) {
        throw "配置先がファイルではない: $dest"
    }
    $prop = Get-ItemProperty -Path $regKey -Name $regName -ErrorAction SilentlyContinue
    $hadDest = Test-Path $dest

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

    foreach ($e in $plan) {
        # 変更に入る前に印を付けて保存する。途中でプロセスが落ちても対象だと分かる
        $e.Phase = 'mutating'; & $saveState

        # 既にある退避は絶対に上書きしない。前回の試行が残した本物の元ファイルかもしれない
        if ($e.Backup -and -not (Test-Path $e.Backup)) {
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
} catch {
    # --- 4. 自力で巻き戻す。scoop は失敗した install に対して uninstaller を呼ばない ---
    $original = $_
    $failed = New-Object Collections.ArrayList
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

            if (Test-Path "$($e.Dest).scoop-tmp") { Remove-Item -LiteralPath "$($e.Dest).scoop-tmp" -Force }

            $destExists = Test-Path $e.Dest
            $destIsOurs = $destExists -and (Get-FileHash -LiteralPath $e.Dest).Hash -eq $e.Hash
            if ($destExists -and -not $destIsOurs) {
                # 第三者のファイル。触らない
            } elseif ($e.HadDest) {
                if (-not ($e.Backup -and (Test-Path $e.Backup) -and
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
    if ($failed.Count) {
        Write-Host "巻き戻しに失敗した項目がある。$statePath を見て手で復旧すること:" -Foreground Red
        $failed | ForEach-Object { Write-Host "  $_" -Foreground Red }
    }
    throw $original   # 元の失敗原因を握りつぶさない
}
