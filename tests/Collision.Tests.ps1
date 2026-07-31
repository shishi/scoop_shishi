BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'FontEnv.psm1') -Force
    $script:Repo     = Split-Path $PSScriptRoot
    $script:Manifest = Join-Path $script:Repo 'bucket\biz-udgothic.json'
    $script:FontDir  = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
    $script:Target   = Join-Path $script:FontDir 'BIZUDGothic-Regular.ttf'
    $script:RegName  = 'BIZ UDGothic (TrueType)'
    $script:Backup   = "$env:LOCALAPPDATA\scoop-font-backup\biz-udgothic-1.051"

    # $script:RegName は 4 ファイルのうち 1 つ分でしかない。「記録が無ければ uninstall は
    # 何も消さない」テストは残り 3 つの登録もわざと残したまま次のケースへ進むので、
    # Reset-Case はこの 4 つ全部を毎回消さないと、次のケース以降にレジストリの
    # 残骸が漏れて Assert-FontEnvRestored がずっと失敗し続ける
    $script:AllRegNames = @('BIZ UDGothic (TrueType)', 'BIZ UDGothic Bold (TrueType)',
                            'BIZ UDPGothic (TrueType)', 'BIZ UDPGothic Bold (TrueType)')

    # このスイートは $script:Target と $script:RegName を繰り返し消す。
    # 元から手動で入っていた場合に失われるので、中身ごと退避してから始める。
    #
    # 順序が重要。app が入った状態で退避すると scoop が置いたファイルを掴んでしまい、
    # その下に隠れている「本当の元ファイル」を取り逃がす。先に uninstall して
    # 素の状態を露出させてから退避する
    $script:WasInstalled = ((scoop list biz-udgothic 6>$null | Out-String) -match 'biz-udgothic')
    scoop uninstall biz-udgothic 2>&1 | Out-Null

    # このスイートが触りうるファイルは $script:Target だけではない。
    # 故障注入は BIZUDPGothic-Regular.ttf も消してディレクトリに置き換える。
    # biz-udgothic が配る 4 ファイルすべてを退避対象にする
    $script:Touched = @('BIZUDGothic-Bold.ttf', 'BIZUDGothic-Regular.ttf',
                        'BIZUDPGothic-Bold.ttf', 'BIZUDPGothic-Regular.ttf')

    $script:Vault = Join-Path $env:TEMP ("collision-vault-" + [Guid]::NewGuid().ToString('n'))
    New-Item $script:Vault -ItemType Directory -Force | Out-Null
    $script:VaultedFiles = @()
    # 配置先と同名の「ディレクトリ」が最初から存在していた場合も想定する（普段は無いはずだが、
    # このスイート自身が故障注入で作る種類の衝突なので、元からあったケースも同じ扱いで守る）
    $script:VaultedDirs = @()
    foreach ($n in $script:Touched) {
        $p = Join-Path $script:FontDir $n
        if (Test-Path $p -PathType Leaf) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $script:Vault $n) -Force
            $script:VaultedFiles += $n
        } elseif (Test-Path $p -PathType Container) {
            Copy-Item -LiteralPath $p -Destination (Join-Path $script:Vault $n) -Recurse -Force
            $script:VaultedDirs += $n
        }
    }

    # 退避対象のファイルを指しているレジストリ値、および Reset-Case が名前だけで
    # 無条件に消す $script:AllRegNames の現在値をすべて控える。後者を漏らすと、
    # 元から別のパスを指していた登録が消えたきり戻らない
    $script:VaultedReg = @{}
    $props = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' -ErrorAction SilentlyContinue
    if ($props) {
        foreach ($p in $props.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $leaf = Split-Path $p.Value -Leaf
            if (($leaf -in $script:Touched) -or ($p.Name -in $script:AllRegNames)) {
                $script:VaultedReg[$p.Name] = $p.Value
            }
        }
    }

    # $script:Backup（scoop-font-backup\biz-udgothic-1.051）自体も、割り込まれた
    # 別のインストール試行の唯一の復旧手段（journal・退避ファイル）を保持している
    # かもしれない。Reset-Case は毎回これを空にするので、消える前に丸ごと退避する
    $script:HadBackupDir = Test-Path $script:Backup
    $script:BackupVault  = Join-Path $script:Vault '__backup-dir__'
    if ($script:HadBackupDir) {
        Copy-Item -LiteralPath $script:Backup -Destination $script:BackupVault -Recurse -Force
    }

    function Reset-Case {
        scoop uninstall biz-udgothic 2>&1 | Out-Null
        # 故障注入がディレクトリを置いている場合があるので -Recurse で消す
        foreach ($n in $script:Touched) {
            $p = Join-Path $script:FontDir $n
            if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force }
        }
        foreach ($k in @($script:VaultedReg.Keys) + $script:AllRegNames) {
            Remove-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
                -Name $k -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $script:Backup) { Remove-Item -LiteralPath $script:Backup -Recurse -Force }
    }

    function New-DecoyFont([string]$Path) {
        # 実在のフォントを土台に 1 バイトだけ変える。中身は別物だが name テーブルは読める
        $src = Join-Path $env:WINDIR 'Fonts\BIZUDGothic-Regular.ttf'
        $b = [IO.File]::ReadAllBytes($src)
        $b[$b.Length - 1] = [byte](($b[$b.Length - 1] + 1) % 256)
        [IO.File]::WriteAllBytes($Path, $b)
        return (Get-FileHash -LiteralPath $Path).Hash
    }

    $script:Before = Get-FontEnvSnapshot
}

AfterAll {
    Reset-Case

    # 故障注入がディレクトリに置き換えた配置先を片付ける
    foreach ($n in $script:Touched) {
        $p = Join-Path $script:FontDir $n
        if (Test-Path $p -PathType Container) { Remove-Item -LiteralPath $p -Recurse -Force }
    }

    # 退避しておいた実体とレジストリ値を戻す
    foreach ($n in $script:VaultedFiles) {
        Copy-Item -LiteralPath (Join-Path $script:Vault $n) -Destination (Join-Path $script:FontDir $n) -Force
    }
    foreach ($n in $script:VaultedDirs) {
        $dest = Join-Path $script:FontDir $n
        if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath (Join-Path $script:Vault $n) -Destination $dest -Recurse -Force
    }
    foreach ($k in $script:VaultedReg.Keys) {
        New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
            -Name $k -Value $script:VaultedReg[$k] -Force | Out-Null
    }
    # 割り込まれた別の試行の退避ディレクトリがあれば、消える前の状態へ戻す。
    # これが無いと、このスイート自身は入っていなかった第三者の復旧データを消して終わる
    if ($script:HadBackupDir) {
        if (Test-Path $script:Backup) { Remove-Item -LiteralPath $script:Backup -Recurse -Force }
        Copy-Item -LiteralPath $script:BackupVault -Destination $script:Backup -Recurse -Force
    }
    if (Test-Path $script:Vault) { Remove-Item -LiteralPath $script:Vault -Recurse -Force }

    # このスイートに入る前に入っていたなら入れ直す
    if ($script:WasInstalled) { scoop install $script:Manifest 2>&1 | Out-Null }

    if (-not $script:WasInstalled) { Assert-FontEnvRestored -Before $script:Before }
}

Describe '既存ファイルとの衝突' {
    BeforeEach { Reset-Case }

    It '内容の違う同名ファイルがあると退避してから上書きし、uninstall で戻る' {
        $decoyHash = New-DecoyFont $script:Target
        scoop install $script:Manifest 2>&1 | Out-Null

        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Not -Be $decoyHash
        (Join-Path $script:Backup 'BIZUDGothic-Regular.ttf') | Should -Exist

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Be $decoyHash
    }

    It 'Windows 標準の名前で登録済みなら上書きし、uninstall で元の値へ戻る' {
        New-DecoyFont $script:Target | Out-Null
        New-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' `
            -Name $script:RegName -Value $script:Target -Force | Out-Null

        scoop install $script:Manifest 2>&1 | Out-Null
        Get-FontRegValue -Name $script:RegName | Should -Be $script:Target

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        Get-FontRegValue -Name $script:RegName | Should -Be $script:Target
    }

    It 'install 後に第三者が差し替えたファイルは uninstall で消さない' {
        scoop install $script:Manifest 2>&1 | Out-Null
        $tamperedHash = New-DecoyFont $script:Target

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        $script:Target | Should -Exist
        (Get-FileHash -LiteralPath $script:Target).Hash | Should -Be $tamperedHash
    }

    It '記録が無ければ uninstall は何も消さない' {
        scoop install $script:Manifest 2>&1 | Out-Null
        Remove-Item (Join-Path (scoop prefix biz-udgothic) 'scoop-font-state.json') -Force
        Remove-Item (Join-Path $script:Backup 'scoop-font-state.json') -Force

        scoop uninstall biz-udgothic 2>&1 | Out-Null
        $script:Target | Should -Exist
    }
}

Describe '変更途中の失敗' {
    BeforeEach { Reset-Case }

    It 'コピーに失敗すると、それまでの変更が巻き戻る' {
        # 配置先と同名のディレクトリを作っておくと Copy-Item が必ず失敗する
        $blocker = Join-Path $script:FontDir 'BIZUDPGothic-Regular.ttf'
        if (Test-Path $blocker) { Remove-Item -LiteralPath $blocker -Force }
        New-Item $blocker -ItemType Directory -Force | Out-Null
        try {
            # installer が例外で失敗すると、scoop はその例外をそのまま呼び出し元へ伝播させる。
            # 2>&1 | Out-Null はエラーストリームを黙らせるだけで終端例外は捕まえないため、
            # ここで受け止めないと以降の検証が実行されないまま It が例外で落ちる。
            # ただし何でも握りつぶすと、ダウンロード失敗など無関係の理由で install が
            # 早期に失敗しただけでもこの後の「残っていない」検証が素通りしてしまう。
            # 配置先の衝突が原因だったことまで確認する
            $caught = $null
            try { scoop install $script:Manifest 2>&1 | Out-Null } catch { $caught = $_ }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -Match '配置先がファイルではない'

            # 先に処理された分が残っていないこと
            (Test-Path $script:Target) | Should -BeFalse
            Get-FontRegValue -Name $script:RegName | Should -BeNullOrEmpty
        } finally {
            if (Test-Path $blocker) { Remove-Item -LiteralPath $blocker -Recurse -Force }
        }
    }
}
