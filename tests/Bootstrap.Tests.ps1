Describe 'Pester の取り込み' {
    It '固定した 5.9.0 が読み込まれている' {
        (Get-Module Pester).Version.ToString() | Should -Be '5.9.0'
    }
    It '取り込み先に完了印がある' {
        Join-Path $PSScriptRoot '.modules\Pester\5.9.0\.complete' | Should -Exist
    }
}

Describe 'テスト実行の入口' {
    It '読み込めないテストファイルがあれば 0 以外で終わる' {
        # このスイート自身を壊すわけにはいかないので、別ディレクトリを作ってそこへ投げる
        $scratch = Join-Path $env:TEMP ("invoke-probe-" + [Guid]::NewGuid().ToString('n'))
        New-Item $scratch -ItemType Directory -Force | Out-Null
        try {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'bootstrap.ps1') -Destination $scratch
            $broken = "Describe 'broken' {`r`n    It 'never runs' {`r`n        `$x = @{`r`n    }`r`n}`r`n"
            [IO.File]::WriteAllText((Join-Path $scratch 'Broken.Tests.ps1'), $broken,
                (New-Object Text.UTF8Encoding $true))

            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File (Join-Path $PSScriptRoot 'invoke.ps1') -Dir $scratch *> $null
            $LASTEXITCODE | Should -Not -Be 0
        } finally {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
