<#
.PARAMETER StaticOnly
    Bootstrap / Manifest / Uniqueness / FontName のみを実行する。この 4 つは
    レジストリや %LOCALAPPDATA%\...\Fonts、実インストール済みの scoop app に
    触れないマシン非依存のスイートで、'Static' タグを付けてある。
    Lifecycle / Collision / Update / RegName / FontNotify は実機のフォント環境を
    書き換える(詳細は README のテストの節)ため、このスイッチでは実行しない。
#>
param([switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
$invokeArgs = @('-Dir', $PSScriptRoot)
if ($StaticOnly) { $invokeArgs += @('-Tag', 'Static') }
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'invoke.ps1') @invokeArgs
exit $LASTEXITCODE
