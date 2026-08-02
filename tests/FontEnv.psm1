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

function Assert-RegistryUnchangedExcept {
    # Assert-FontEnvRestored と同じ三方比較(追加/削除/値の変化)を、レジストリ値だけに
    # 限定して行う。全 16 manifest が同じ共有スクリプトを使うため、ある manifest の
    # 更新が無関係な他のフォントへ波及しないことを確認するのに使う。$ExceptNames に
    # 挙げたキーは比較から除く(更新対象のフォント自身のキーなど、変化して当然のもの)。
    #
    # キー名の集合が変わっていないことだけを見る比較では、更新処理が誤って他の
    # フォントの値を書き換えても(キー自体は増減しないので)検知できない。この関数は
    # 値の変化も見る
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$Now,
        [string[]]$ExceptNames = @()
    )
    $beforeKeys = @($Before.Registry.Keys | Where-Object { $_ -notin $ExceptNames })
    $nowKeys    = @($Now.Registry.Keys    | Where-Object { $_ -notin $ExceptNames })
    $addedReg   = @($nowKeys    | Where-Object { -not $Before.Registry.ContainsKey($_) })
    $removedReg = @($beforeKeys | Where-Object { -not $Now.Registry.ContainsKey($_) })
    $changedReg = @($beforeKeys | Where-Object {
        $Now.Registry.ContainsKey($_) -and $Now.Registry[$_] -ne $Before.Registry[$_] })

    $msg = @()
    if ($addedReg)   { $msg += "増えたレジストリ値: $($addedReg -join ', ')" }
    if ($removedReg) { $msg += "消えたレジストリ値: $($removedReg -join ', ')" }
    if ($changedReg) { $msg += "変わったレジストリ値: $($changedReg -join ', ')" }
    if ($msg) { throw ("関係の無いフォントの登録が変化した`n  " + ($msg -join "`n  ")) }
}

Export-ModuleMember -Function Get-FontRegValue, Get-FontEnvSnapshot, Assert-FontEnvRestored, Assert-RegistryUnchangedExcept
