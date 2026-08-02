Describe 'Pester の取り込み' -Tag 'Static' {
    It '固定した 5.9.0 が読み込まれている' {
        (Get-Module Pester).Version.ToString() | Should -Be '5.9.0'
    }
    It '取り込み先に完了印がある' {
        Join-Path $PSScriptRoot '.modules\Pester\5.9.0\.complete' | Should -Exist
    }
}

Describe 'テスト実行の入口' -Tag 'Static' {
    It '読み込めないテストファイルがあれば 0 以外で終わる' {
        # このスイート自身を壊すわけにはいかないので、別ディレクトリを作ってそこへ投げる。
        #
        # scratch 側の bootstrap.ps1 は「取り込み済みの Pester を読むだけ」の差し替え版にする。
        # 本物をコピーすると scratch は毎回まっさらなので PSGallery から再取得することになり、
        # 以降 14 タスクぶんのテスト実行が毎回ネットワークに依存して遅くなる。
        # さらに、取得に失敗しても bootstrap が投げて「0 以外で終わる」が満たされてしまい、
        # 本来見たい経路を 1 度も通らないままテストが通る
        $scratch = Join-Path $env:TEMP ("invoke-probe-" + [Guid]::NewGuid().ToString('n'))
        New-Item $scratch -ItemType Directory -Force | Out-Null
        try {
            $psd1 = Join-Path $PSScriptRoot '.modules\Pester\5.9.0\Pester.psd1'
            [IO.File]::WriteAllText((Join-Path $scratch 'bootstrap.ps1'),
                "Import-Module '$psd1' -Force`r`n", (New-Object Text.UTF8Encoding $true))
            $broken = "Describe 'broken' {`r`n    It 'never runs' {`r`n        `$x = @{`r`n    }`r`n}`r`n"
            [IO.File]::WriteAllText((Join-Path $scratch 'Broken.Tests.ps1'), $broken,
                (New-Object Text.UTF8Encoding $true))

            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot 'invoke.ps1') -Dir $scratch 2>&1 | Out-String
            $code = $LASTEXITCODE

            # Pester が実際に走って「そのファイルの読み込みに失敗した」ことまで確かめる。
            # 終了コードが 0 以外なだけでは、bootstrap の失敗でも通ってしまう
            $out  | Should -Match 'Broken\.Tests\.ps1'
            $code | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
