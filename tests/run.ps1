<#
.PARAMETER StaticOnly
    Bootstrap / Manifest / Uniqueness / FontName のみを実行する。この 4 つは
    レジストリや %LOCALAPPDATA%\...\Fonts、実インストール済みの scoop app に
    触れないマシン非依存のスイートで、'Static' タグを付けてある。
    Lifecycle / Collision / Update / RegName / FontNotify / GdiRefCount は
    このスイッチでは実行しない。これらは実機を書き換える:
      - scoop で実際に install / uninstall し、HKCU のフォント登録を消して書き戻し、
        %LOCALAPPDATA%\Microsoft\Windows\Fonts を書き換え、検証用の一時 bucket を作る
      - RegName は 16 個のフォント manifest がすべて install 済みであることを前提にする
      - 常用フォント(HackGen・PlemolJP など)を描画中のアプリが開いているとファイルが
        ロックされ、Collision / Lifecycle が落ちる。テストの不具合ではないので、
        対象のフォントを使っているアプリを閉じてから実行すること
    GdiRefCount は例外で、P/Invoke をスタブへ、$env:LOCALAPPDATA を一時ディレクトリへ、
    HKCU: PSDrive を HKCU\Software\ScoopFontRefCountTest へ張り替えるので実環境は汚さない。
    これだけを走らせたいときは -Tag GdiRef を invoke.ps1 へ渡す。
#>
param([switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
$invokeArgs = @('-Dir', $PSScriptRoot)
if ($StaticOnly) { $invokeArgs += @('-Tag', 'Static') }
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'invoke.ps1') @invokeArgs
exit $LASTEXITCODE
