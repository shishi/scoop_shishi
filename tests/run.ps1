<#
.PARAMETER StaticOnly
    Bootstrap / Manifest / Uniqueness / FontName と Win11Debloat の静的検査のみを
    実行する。これらはレジストリや %WINDIR%\Fonts、実インストール済みの
    scoop app に触れないマシン非依存のスイートで、'Static' タグを付けてある。

    スイートは実機への影響で 3 つに分かれる。

    (a) 実機を書き換える(既定では走らない。'RealScoop' タグ + -IncludeRealScoop):
      - Lifecycle / Update / FontNotify。scoop で実際に global install / uninstall し、
        HKLM のフォント登録を消して書き戻し、%WINDIR%\Fonts を書き換え、
        検証用の一時 bucket を作る。**昇格が必要**
        (Lifecycle は昇格していなければ BeforeAll で止まる)
      - global のフォントは OS がログオン時にロードするので uninstall が「使用中」で
        失敗し、環境に残骸が残ることがある。詳細は -IncludeRealScoop の項

    (b) 実機を読むだけ(既定で走る。昇格は不要):
      - RegName。16 個のフォント manifest がすべて install 済みであることを前提に、
        レジストリとファイルを読んで検証する。書き換えはしない

    (c) サンドボックス(既定で走る。実環境を汚さないので昇格も不要):
      - Collision / GdiRefCount / GlobalInstall。詳細は .NOTES

    Win11Debloat の実機スイートも既定で走る。persist の中身を意図的に壊すが、
    実環境の保存設定とレジストリバックアップは ~\scoop\persist\win11debloat ごと
    一時退避してから走り、AfterAll で戻す(per-user のままなので昇格は不要)。
.PARAMETER IncludeRealScoop
    'RealScoop' タグの付いたスイート(Lifecycle / Update / FontNotify)も実行する。
    既定では外す。**実行すると環境に残骸が残ることがある。**

    これらは実 scoop で global install / uninstall するが、%WINDIR%\Fonts のフォントは
    OS がログオン時にロードして常時参照するため、uninstall が「使用中」で失敗し、
    フォントファイルと退避ディレクトリが残る。per-user 時代は %LOCALAPPDATA% だったので
    使うアプリを閉じれば解放されたが、global では閉じても解放されない。
    失敗を skip で隠すと残骸を放置したまま緑になり、次の install がその残骸を
    「元からあったファイル」と誤認して所有権の追跡が壊れる。だから隠さず失敗させ、
    走らせるかどうかを明示の選択にしてある。
    **走らせた後にフォントが残ったら、再起動してから uninstall し直すこと。**
    昇格が必要。

    **実測(2026-08-04): これらの uninstall 側の検証は現実にはほぼ必ず失敗する。**
    global install したフォントは必ずログオン時にロードされるので、その状態で
    uninstall を走らせれば削除できない。340 PASS / 3 FAILED の内訳は
    Lifecycle の退避ディレクトリ 1 件と、Update の「新版へ入れ替わる」「旧版の
    退避が残らない」2 件で、いずれも旧版の uninstall がロックで失敗した結果。
    install 側の検証(ファイル配置・レジストリ登録・記録の生成)は通る。
    uninstall / update の振る舞いはサンドボックスの Collision と GlobalInstall が
    完全にカバーしているので、これらを緑にすることを目標にしないこと。
    ここが失敗しても bucket の欠陥ではない。
.NOTES
    サンドボックスのスイート(Collision / GdiRefCount / GlobalInstall)は
    実環境を汚さないので昇格も不要:
    P/Invoke をカウンタ付きスタブへ、$env:WINDIR と $env:ProgramData を一時
    ディレクトリへ、HKLM: PSDrive を HKCU\Software\ScoopFont*Test へ張り替える。
    張り替え先を HKCU にすることで、global 経路(HKLM)の検証でありながら
    実 HKLM へ書かずに済ませている。張り替えが外れていたら各 BeforeEach が
    停止するので、実レジストリを消す事故は起きない。
    個別に走らせたいときは invoke.ps1 へ -Tag Collision / GdiRef / Global を渡す。
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
