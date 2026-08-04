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

function Get-ScoopGlobalRoot {
    # フォント manifest は global 専用なので、実機スイートが触るのは global 側だけ。
    # ここを per-user の root にしていると、global で入っているアプリを
    # 「入っていない」と誤判定し、テストが取り上げたまま復元しない。
    #
    # 解決順は scoop 本体(core.ps1)と同じにする。環境変数だけを見ると、
    # config.json の global_path で移した環境で誤判定し、実インストールを
    # 取り上げたまま AfterAll が復元を諦める
    if ($env:SCOOP_GLOBAL) { return $env:SCOOP_GLOBAL }

    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { "$env:USERPROFILE\.config" }
    $configFile = Join-Path $configHome 'scoop\config.json'
    if (Test-Path -LiteralPath $configFile) {
        # config が壊れていても実機スイートを止めない。既定値へ落とす
        try {
            $cfg = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg.global_path) {
                # %VAR% 形式で入っていることがある。展開に失敗しても元の文字列を返す
                return [Environment]::ExpandEnvironmentVariables($cfg.global_path)
            }
        } catch {
            Write-Warning "scoop の config.json を読めなかった。global_path は既定値を使う: $_"
        }
    }
    Join-Path $env:ProgramData 'scoop'
}

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
    # scoop list は per-user と global の両方を並べるので使わない。
    # 渡された root の実体だけを見る($ScoopRoot に何を渡すかは呼び出し側の責任。
    # フォント manifest は global 専用なので Get-ScoopGlobalRoot を渡す)
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
        [string]$Fallback,
        # global (-g) で入れ直す。フォント manifest は global 専用なので、
        # ここを付け忘れると installer が per-user を拒否して復元に失敗する
        [switch]$Global
    )

    foreach ($src in @($OriginalSource, $Fallback | Where-Object { $_ })) {
        if ($Global) { scoop install -g $src 2>&1 | Out-Null }
        else         { scoop install    $src 2>&1 | Out-Null }
        if (Test-AppInstalled -App $App -ScoopRoot $ScoopRoot) { break }
        Write-Warning "$src からの $App の入れ直しに失敗した"
    }

    if (-not (Test-AppInstalled -App $App -ScoopRoot $ScoopRoot)) {
        # ここまで来たらテストが環境からアプリを取り上げたままになる。
        # 黙って終わらせず、何を実行すれば戻るかまで出す
        $hint = if ($OriginalSource) { $OriginalSource } else { $Fallback }
        $cmd = if ($Global) { "scoop install -g $hint" } else { "scoop install $hint" }
        Write-Warning "$App を入れ直せなかった。手で '$cmd' を実行すること"
        return
    }

    # 版まで元どおりとは限らない(bucket が先に進んでいれば上がる)。
    # 黙って変えたことにしないで報せる
    $after = Get-AppInstalledVersion -App $App -ScoopRoot $ScoopRoot
    if ($OriginalVersion -and $after -ne $OriginalVersion) {
        Write-Warning "$App の入れ直しで版が $OriginalVersion から $after に変わった"
    }
}

Export-ModuleMember -Function Get-ScoopGlobalRoot, Get-AppCurrentDir, Test-AppInstalled,
                              Get-AppInstallSource, Get-AppInstalledVersion, Restore-AppInstall
