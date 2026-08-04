param(
    [Parameter(Mandatory)][string]$Dir,
    [string[]]$Tag,
    # 既定の実行から外したいスイート(実機を書き換えるもの)を除くために使う。
    # -Tag を明示したときは除外しない。「RealScoop だけ走らせたい」という
    # 指定が除外に打ち消されると、走らせる手段が無くなる
    [string[]]$ExcludeTag
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
# -Tag が指定されていれば除外しない。RealScoop を名指しで走らせたいときに
# 既定の除外が効いてしまうと 0 件になる
elseif ($ExcludeTag) { $peParams['ExcludeTagFilter'] = $ExcludeTag }
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
