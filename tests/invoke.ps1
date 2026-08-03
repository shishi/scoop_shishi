param(
    [Parameter(Mandatory)][string]$Dir,
    [string[]]$Tag
)
$ErrorActionPreference = 'Stop'
. (Join-Path $Dir 'bootstrap.ps1')
# InstallSource は「他のスイートが実機を汚したまま終わっていないか」を見るので、
# 必ず最後に回す。Pester にディレクトリを渡すと discovery はファイル名順になり、
# 'I' で始まるこのスイートは Lifecycle / Update / Win11Debloat より先に終わって
# しまう。それらが汚しても緑のまま通るので、順序を明示して渡す
$files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.Tests.ps1' | Sort-Object Name)
$last  = @($files | Where-Object { $_.Name -eq 'InstallSource.Tests.ps1' })
$paths = @(@($files | Where-Object { $_.Name -ne 'InstallSource.Tests.ps1' }) + $last |
    ForEach-Object { $_.FullName })

$peParams = @{ Path = $paths; PassThru = $true; Output = 'Detailed' }
if ($Tag) { $peParams['TagFilter'] = $Tag }
$r = Invoke-Pester @peParams

# FailedCount だけを見てはいけない。テストファイルが構文エラーで読み込めなかった場合、
# 失敗した「テスト」は 0 件のまま FailedContainersCount だけが立つ。実測では
# 壊れたテストファイルを置いても FailedCount=0 / FailedContainersCount=1 / Result=Failed になり、
# FailedCount を返す実装では終了コード 0 になって壊れたテストが黙って通る
$failed = $r.FailedCount + $r.FailedBlocksCount + $r.FailedContainersCount
if ($failed -eq 0 -and $r.Result -ne 'Passed') { $failed = 1 }

# 件数をそのまま返さない。Windows の終了コードは 256 で折り返すので、
# 失敗が 256 の倍数のときに成功と区別できなくなる
exit ([int]($failed -gt 0))
