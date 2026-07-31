param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'
. (Join-Path $Dir 'bootstrap.ps1')
$r = Invoke-Pester -Path $Dir -PassThru -Output Detailed

# FailedCount だけを見てはいけない。テストファイルが構文エラーで読み込めなかった場合、
# 失敗した「テスト」は 0 件のまま FailedContainersCount だけが立つ。実測では
# 壊れたテストファイルを置いても FailedCount=0 / FailedContainersCount=1 / Result=Failed になり、
# FailedCount を返す実装では終了コード 0 になって壊れたテストが黙って通る
$failed = $r.FailedCount + $r.FailedBlocksCount + $r.FailedContainersCount
if ($failed -eq 0 -and $r.Result -ne 'Passed') { $failed = 1 }
exit $failed
