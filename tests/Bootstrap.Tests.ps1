Describe 'Pester の取り込み' {
    It '固定した 5.9.0 が読み込まれている' {
        (Get-Module Pester).Version.ToString() | Should -Be '5.9.0'
    }
    It '取り込み先に完了印がある' {
        Join-Path $PSScriptRoot '.modules\Pester\5.9.0\.complete' | Should -Exist
    }
}
