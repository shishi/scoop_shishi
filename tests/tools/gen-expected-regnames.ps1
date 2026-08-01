<#
.SYNOPSIS
    tests/fixtures/expected-regnames.json を実インストール済みの 16 アプリから再生成する。

.DESCRIPTION
    scoop prefix で 16 個の app ディレクトリを集め、nameid4.py (PowerShell 側の
    インストーラーとは独立した実装) に渡して標準出力を得て、そのままフィクスチャへ
    書き出す。scoop/apps 全体を走査すると tor-browser・rstudio・calibre などが
    同梱する無関係なフォントまで拾ってしまうため、必ずこの 16 個の prefix だけを渡す。

    PowerShell が外部コマンドの標準出力を変数へ代入すると、改行ごとに 1 要素の
    配列として受け取り、各要素から改行文字そのものは取り除かれる。そのため
    "`n" で結合し直すだけで CRLF 混入を避けられる (Python の標準出力はテキスト
    モードで "\n" を "\r\n" へ書き換えるが、それは PowerShell 側で吸収される)。
    書き出しは BOM 無し UTF-8 に固定し、コミット済みのフィクスチャ (BOM 無し・LF)
    と完全に一致する出力にする。

    実行には 16 個すべてが scoop でインストール済みであることが前提
    (このリポジトリでは Task 10 以降、16 個全部が入っている状態が常態)。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Apps = @(
    'biz-udgothic', 'biz-udmincho', 'bizin-gothic', 'bizin-gothic-discord',
    'bizin-gothic-nf', 'bizter', 'hackgen', 'hackgen-nf', 'notonoto',
    'noto-color-emoji', 'noto-sans-jp', 'noto-serif-jp', 'plemoljp',
    'plemoljp-nf', 'udev-gothic', 'udev-gothic-nf'
)

$dirs = @()
foreach ($app in $Apps) {
    $prefix = (scoop prefix $app 2>$null | Out-String).Trim()
    if (-not $prefix -or -not (Test-Path $prefix)) {
        throw "'$app' の prefix が解決できない。scoop install 済みか確認すること"
    }
    $dirs += $prefix
}

$script = Join-Path $RepoRoot 'tests\tools\nameid4.py'
$out    = Join-Path $RepoRoot 'tests\fixtures\expected-regnames.json'

$lines = & python3 $script @dirs
if ($LASTEXITCODE -ne 0) { throw 'nameid4.py の実行に失敗した' }

$json = ($lines -join "`n") + "`n"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($out, $json, $utf8NoBom)

Write-Host "wrote $out ($($dirs.Count) 個のディレクトリから生成)"
