# bucket 配下の manifest を「フォント」と「それ以外のツール」に分ける唯一の場所。
#
# 判別は名簿(tests/fixtures/font-manifests.json)で行う。共有 installer
# スクリプトの配布先を決める sync_scripts.py も同じ名簿を読む。
#
# manifest の中身(installer キーの有無など)で判別してはいけない。検査したい
# プロパティ自身が「検査するかどうか」を決めることになり、installer を書き
# 忘れた manifest が、まさにそれが無いことを理由にフォント扱いから外れて
# 黙って素通りする。名簿と bucket の突き合わせは Manifest.Tests.ps1 が行う
function Get-FontRoster {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TestsDir)

    $path = Join-Path $TestsDir 'fixtures\font-manifests.json'
    if (-not (Test-Path -LiteralPath $path)) {
        throw "フォント名簿が見つからない: $path"
    }
    @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).fonts)
}

function Get-FontManifestFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BucketDir,
        [Parameter(Mandatory)][string]$TestsDir
    )

    $roster = Get-FontRoster -TestsDir $TestsDir
    @(Get-ChildItem $BucketDir -Filter '*.json' | Where-Object { $_.BaseName -in $roster })
}

Export-ModuleMember -Function Get-FontRoster, Get-FontManifestFile
