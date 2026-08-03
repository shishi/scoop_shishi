BeforeAll {
    $script:Repo = Split-Path $PSScriptRoot
    # scoop は SCOOP 環境変数でインストール先を変えられる
    $script:ScoopRoot = if ($env:SCOOP) { $env:SCOOP } else { "$env:USERPROFILE\scoop" }
}

Describe 'インストール元' {
    It 'このリポジトリのローカル manifest から入ったままのアプリが無い' {
        # 実機スイートは検証のためリポジトリ内の manifest を直接指して install する。
        # 後片付けで元の出どころへ戻し損ねると、install.json にリポジトリのパスが
        # 焼き付いたまま残る。そうなると:
        #   - scoop update が bucket ではなくローカルファイルを見続け、
        #     Excavator が上げた version を永久に拾わない
        #   - scoop export した Scoopfile が、別マシンには存在しないパスを指す
        #     (scoop import はその文字列をそのまま scoop install へ渡す)
        # どちらも壊れ方が静かなので、実機の状態そのものを検査して留め金にする
        $appsDir = Join-Path $script:ScoopRoot 'apps'
        $stray = @(Get-ChildItem -LiteralPath $appsDir -Directory | ForEach-Object {
            $installJson = Join-Path $_.FullName 'current\install.json'
            if (Test-Path -LiteralPath $installJson) {
                $info = Get-Content -LiteralPath $installJson -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($info.url -and $info.url.StartsWith($script:Repo, [StringComparison]::OrdinalIgnoreCase)) {
                    $_.Name
                }
            }
        })
        ($stray -join ', ') | Should -BeNullOrEmpty
    }
}
