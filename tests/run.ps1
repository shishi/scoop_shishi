<#
.PARAMETER StaticOnly
    Bootstrap / Manifest / Uniqueness / FontName と Win11Debloat の静的検査のみを
    実行する。これらはレジストリや %WINDIR%\Fonts、実インストール済みの
    scoop app に触れないマシン非依存のスイートで、'Static' タグを付けてある。
    Lifecycle / Collision / Update / RegName / FontNotify / GdiRefCount /
    GlobalInstall と Win11Debloat の実機スイートはこのスイッチでは実行しない。
    これらは実機を書き換える:
      - フォント manifest は global 専用になったため、scoop の install / uninstall は
        -g を付けて走る。**このためフォント系の実機スイートは昇格が必要**
        (Lifecycle は昇格していなければ BeforeAll で止まる)
      - scoop で実際に install / uninstall し、HKLM のフォント登録を消して書き戻し、
        %WINDIR%\Fonts を書き換え、検証用の一時 bucket を作る
      - RegName は 16 個のフォント manifest がすべて install 済みであることを前提にする
      - 常用フォント(HackGen・PlemolJP など)を描画中のアプリが開いているとファイルが
        ロックされ、Collision / Lifecycle が落ちる。テストの不具合ではないので、
        対象のフォントを使っているアプリを閉じてから実行すること
      - Win11Debloat は persist の中身を意図的に壊す。実環境の保存設定と
        レジストリバックアップは ~\scoop\persist\win11debloat ごと一時退避してから
        走り、AfterAll で戻す(こちらは per-user のままなので昇格は不要)
.PARAMETER IncludeRealScoop
    'RealScoop' タグの付いたスイート(Lifecycle / Update)も実行する。既定では外す。
    これらは実 scoop で install / uninstall するが、global のフォントは OS が
    ログオン時にロードするため uninstall が「使用中」で失敗し、環境に残骸
    (%WINDIR%\Fonts のファイルと退避ディレクトリ)が残ることがある。
    失敗を skip で隠すと残骸を放置したまま緑になり、次の install がその残骸を
    「元からあったファイル」と誤認して所有権の追跡が壊れるので、隠さず失敗させる代わりに
    実行するかどうかを明示の選択にしてある。走らせた後に残ったら、再起動してから
    uninstall し直すこと。昇格が必要。
    Collision / GdiRefCount / GlobalInstall はサンドボックスなのでこの制限は無い。
.NOTES
    GdiRefCount / GlobalInstall / Collision は実環境を汚さないので昇格も不要:
    P/Invoke をスタブへ、$env:WINDIR と $env:ProgramData を一時ディレクトリへ、
    HKLM: PSDrive を HKCU\Software\ScoopFont*Test へ張り替える(張り替え先を HKCU に
    することで、global 経路の検証でありながら実 HKLM へ書かずに済ませている)。
    これだけを走らせたいときは -Tag GdiRef / -Tag Global を invoke.ps1 へ渡す。
#>
param([switch]$StaticOnly, [switch]$IncludeRealScoop)
$ErrorActionPreference = 'Stop'
$invokeArgs = @('-Dir', $PSScriptRoot)
if ($StaticOnly) { $invokeArgs += @('-Tag', 'Static') }
# 実機を書き換えるスイート(Lifecycle / Update)は既定で走らせない。
# global のフォントは OS がロードしていて uninstall が「使用中」で失敗しうるので、
# 走らせると環境に残骸が残ることがある。明示的に選んだときだけ実行する
elseif (-not $IncludeRealScoop) { $invokeArgs += @('-ExcludeTag', 'RealScoop') }
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'invoke.ps1') @invokeArgs
exit $LASTEXITCODE
