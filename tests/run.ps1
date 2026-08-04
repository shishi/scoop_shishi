<#
.SYNOPSIS
    このリポジトリのテストスイートを実行する。
.PARAMETER StaticOnly
    'Static' タグの付いた静的検査だけを実行する
    (Bootstrap / Manifest / Uniqueness / FontName と Win11Debloat の静的検査)。
    レジストリや %WINDIR%\Fonts、実インストール済みの scoop app に触れない
    マシン非依存のスイート。
.NOTES
    スイートは実機への影響で 3 つに分かれる。既定ではすべて実行され、
    **昇格は要らない**。

    (a) サンドボックス — Collision / GdiRefCount / GlobalInstall
        実環境を一切汚さない。P/Invoke をカウンタ付きスタブへ、$env:WINDIR と
        $env:ProgramData を一時ディレクトリへ、HKLM: PSDrive を
        HKCU\Software\ScoopFont*Test へ張り替える。張り替え先を HKCU にすることで、
        global 経路(HKLM)の検証でありながら実 HKLM へ書かずに済ませている。
        張り替えが外れていたら各 BeforeEach が停止するので、実レジストリを消す
        事故は起きない。installer / uninstaller / pre_uninstall の振る舞いは
        すべてここで検証する。
        個別に走らせるなら invoke.ps1 へ -Tag Collision / GdiRef / Global。

    (b) 実機を読むだけ — RegName / InstallSource
        RegName は 16 個のフォント manifest がすべて install 済みであることを
        前提に、レジストリとファイルを読んで検証する。InstallSource は
        per-user と global の両方の scoop root を走査して、リポジトリ内の
        ローカル manifest から入ったままの app が無いことを確かめる。
        どちらも書き換えはしない。

    (c) 実機を書き換える — Win11Debloat
        persist の中身を意図的に壊すが、実環境の保存設定とレジストリバックアップは
        ~\scoop\persist\win11debloat ごと一時退避してから走り、AfterAll で戻す。
        per-user なので昇格は不要。

    実 scoop で global install / uninstall していたスイート
    (Lifecycle / Update / FontNotify)は 2026-08-04 に廃止した。
    global 専用にした結果、%WINDIR%\Fonts のフォントは OS がログオン時にロードして
    常時参照するため、uninstall が「使用中」で失敗して環境に残骸を残す。
    per-user 時代は %LOCALAPPDATA% だったので使うアプリを閉じれば解放されたが、
    global では閉じても解放されない。つまり uninstall 側の検証が構造的に成立せず、
    走らせれば必ず赤くなる。常に赤いテストは本当の回帰を隠すので残さない。
    失われた検証は (a) のサンドボックスへ移した:
      - install の配置・登録・記録の生成、登録名が nameID 4 由来であること → GlobalInstall
      - 既存ファイルとの衝突・巻き戻し・ジャーナル退役の順序・
        pre_uninstall のロック診断・$version が新版に化けても $dir から版を復元すること
        → Collision
      - GDI 参照カウントの収支 → GdiRefCount
#>
param([switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
$invokeArgs = @('-Dir', $PSScriptRoot)
if ($StaticOnly) { $invokeArgs += @('-Tag', 'Static') }
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'invoke.ps1') @invokeArgs
exit $LASTEXITCODE
