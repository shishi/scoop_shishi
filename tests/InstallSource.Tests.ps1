BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'ScoopApp.psm1') -Force
    $script:Repo = Split-Path $PSScriptRoot
    # フォント manifest は global 専用なので、per-user 側だけ見ると global へ
    # 焼き付いたローカルパスを見逃す。両方を走査する。
    # global 側の解決は ScoopApp.psm1 に寄せる(config.json の global_path まで見る)
    # どちらの解決も ScoopApp.psm1 に寄せる(config.json の root_path / global_path まで見る)
    $script:ScoopRoots = @((Get-ScoopUserRoot), (Get-ScoopGlobalRoot))
    # 区切り文字はリテラルで書かない。ここは何段もの引用符を通って生成された
    # ことがあり、バックスラッシュが黙って食われて TrimEnd('') + '' になっていた
    # (見た目は通るし、前方一致としては動いてしまうので気づけない)
    $script:Sep        = [IO.Path]::DirectorySeparatorChar
    $script:RepoPrefix = $script:Repo.TrimEnd($script:Sep) + $script:Sep
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
        $stray = @(foreach ($root in $script:ScoopRoots) {
            $appsDir = Join-Path $root 'apps'
            # global 側の scoop を使っていない環境では apps ディレクトリが無い。
            # -ErrorAction SilentlyContinue に頼らず明示的に飛ばす(黙って
            # 飛ばすと「走査したのに 0 件」と「走査していない」が区別できない)
            if (-not (Test-Path -LiteralPath $appsDir)) { continue }
            Get-ChildItem -LiteralPath $appsDir -Directory | ForEach-Object {
                $installJson = Join-Path $_.FullName 'current\install.json'
                if (Test-Path -LiteralPath $installJson) {
                    $info = Get-Content -LiteralPath $installJson -Raw -Encoding UTF8 | ConvertFrom-Json
                    # 区切り文字まで含めて比べる。素の前方一致だと、隣に置かれた
                    # scoop_shishi-backup のような無関係のパスまで拾ってしまう
                    if ($info.url -and $info.url.StartsWith($script:RepoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        $_.Name
                    }
                }
            }
        })
        ($stray -join ', ') | Should -BeNullOrEmpty
    }
}
