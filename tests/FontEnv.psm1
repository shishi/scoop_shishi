$script:FontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
$script:RegKey  = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Get-FontRegValue {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-ItemProperty -Path $script:RegKey -Name $Name -ErrorAction SilentlyContinue
    if ($p) { return $p.($Name) }
    return $null
}

function Get-FontEnvSnapshot {
    $files = @()
    if (Test-Path $script:FontDir) {
        $files = @(Get-ChildItem $script:FontDir -File -Force | Select-Object -ExpandProperty Name | Sort-Object)
    }
    $reg = @{}
    $props = Get-ItemProperty -Path $script:RegKey -ErrorAction SilentlyContinue
    if ($props) {
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $reg[$p.Name] = $p.Value
        }
    }
    [pscustomobject]@{ Files = $files; Registry = $reg }
}

function Assert-FontEnvRestored {
    param([Parameter(Mandatory)]$Before)
    $now = Get-FontEnvSnapshot
    $addedFiles   = @($now.Files   | Where-Object { $_ -notin $Before.Files })
    $removedFiles = @($Before.Files | Where-Object { $_ -notin $now.Files })
    $addedReg     = @($now.Registry.Keys    | Where-Object { -not $Before.Registry.ContainsKey($_) })
    $removedReg   = @($Before.Registry.Keys | Where-Object { -not $now.Registry.ContainsKey($_) })
    $changedReg   = @($Before.Registry.Keys | Where-Object {
        $now.Registry.ContainsKey($_) -and $now.Registry[$_] -ne $Before.Registry[$_] })

    $msg = @()
    if ($addedFiles)   { $msg += "増えたファイル: $($addedFiles -join ', ')" }
    if ($removedFiles) { $msg += "消えたファイル: $($removedFiles -join ', ')" }
    if ($addedReg)     { $msg += "増えたレジストリ値: $($addedReg -join ', ')" }
    if ($removedReg)   { $msg += "消えたレジストリ値: $($removedReg -join ', ')" }
    if ($changedReg)   { $msg += "変わったレジストリ値: $($changedReg -join ', ')" }
    if ($msg) { throw ("フォント環境が元に戻っていない`n  " + ($msg -join "`n  ")) }
}

Export-ModuleMember -Function Get-FontRegValue, Get-FontEnvSnapshot, Assert-FontEnvRestored
