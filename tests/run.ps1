$ErrorActionPreference = 'Stop'
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'invoke.ps1') -Dir $PSScriptRoot
exit $LASTEXITCODE
