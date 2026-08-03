# 実機スイートが「テスト前に入っていたアプリを元どおりに戻す」ための共通処理。
#
# 各スイートは検証のためリポジトリ内の manifest を直接指して install する。
# 後片付けで素直に同じパスから入れ直すと、install.json にリポジトリのパスが
# 焼き付いたまま残る。そのアプリは scoop update が bucket ではなくローカル
# ファイルを見続けるので Excavator の更新を永久に拾わず、scoop export した
# Scoopfile も別マシンには存在しないパスを指す。どちらも静かに壊れる。
#
# テスト前の出どころ(install.json の bucket / url)を控えて、そこへ戻す。
# 戻ったかどうかは終了コードではなく実体の有無で見る。scoop install は
# 失敗しても throw しないため。検査は tests/InstallSource.Tests.ps1 が行う。

function Get-AppCurrentDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$ScoopRoot
    )
    Join-Path $ScoopRoot "apps\$App\current"
}

function Test-AppInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$ScoopRoot
    )
    # scoop list はグローバルインストールも並べるので使わない。
    # 実機スイートが触るのはローカルだけなので、ローカルの実体だけを見る
    Test-Path -LiteralPath (Get-AppCurrentDir -App $App -ScoopRoot $ScoopRoot)
}

function Get-AppInstallSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$ScoopRoot
    )
    $installJson = Join-Path (Get-AppCurrentDir -App $App -ScoopRoot $ScoopRoot) 'install.json'
    if (-not (Test-Path -LiteralPath $installJson)) { return $null }
    $info = Get-Content -LiteralPath $installJson -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($info.bucket)  { return "$($info.bucket)/$App" }
    if ($info.url)     { return $info.url }
    $null
}

function Get-AppInstalledVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$ScoopRoot
    )
    $manifest = Join-Path (Get-AppCurrentDir -App $App -ScoopRoot $ScoopRoot) 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    (Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json).version
}

function Restore-AppInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$App,
        [Parameter(Mandatory)][string]$ScoopRoot,
        # テスト前に Get-AppInstallSource で控えたもの
        [string]$OriginalSource,
        [string]$OriginalVersion,
        # 出どころが分からなかったときの最後の手段(たいていリポジトリの manifest)
        [string]$Fallback
    )

    foreach ($src in @($OriginalSource, $Fallback | Where-Object { $_ })) {
        scoop install $src 2>&1 | Out-Null
        if (Test-AppInstalled -App $App -ScoopRoot $ScoopRoot) { break }
        Write-Warning "$src からの $App の入れ直しに失敗した"
    }

    if (-not (Test-AppInstalled -App $App -ScoopRoot $ScoopRoot)) {
        # ここまで来たらテストが環境からアプリを取り上げたままになる。
        # 黙って終わらせず、何を実行すれば戻るかまで出す
        $hint = if ($OriginalSource) { $OriginalSource } else { $Fallback }
        Write-Warning "$App を入れ直せなかった。手で 'scoop install $hint' を実行すること"
        return
    }

    # 版まで元どおりとは限らない(bucket が先に進んでいれば上がる)。
    # 黙って変えたことにしないで報せる
    $after = Get-AppInstalledVersion -App $App -ScoopRoot $ScoopRoot
    if ($OriginalVersion -and $after -ne $OriginalVersion) {
        Write-Warning "$App の入れ直しで版が $OriginalVersion から $after に変わった"
    }
}

Export-ModuleMember -Function Get-AppCurrentDir, Test-AppInstalled, Get-AppInstallSource,
                              Get-AppInstalledVersion, Restore-AppInstall
