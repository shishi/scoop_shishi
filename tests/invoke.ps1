param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Stop'
. (Join-Path $Dir 'bootstrap.ps1')
$r = Invoke-Pester -Path $Dir -PassThru -Output Detailed
exit $r.FailedCount
