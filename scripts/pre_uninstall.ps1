# scoop:pre_uninstall  ここから 16 manifest 共通
# 見るのは %WINDIR%\Fonts だけにする。per-user 側(旧版の配置先)も調べると、
# そこに残った同名ファイルが無関係なアプリにロックされているだけで exit 1 し、
# global の uninstall / update が不可能になる。global uninstall が消す必要が
# あるのは %WINDIR%\Fonts の実体だけ。旧版が per-user に残したファイルは
# uninstaller が記録($e.Dest)を辿って片付け、ロックされていた分は
# 「未解決」として報告する(1 件の失敗で全体を止めない作りになっている)
$fontDir = "$env:WINDIR\Fonts"
Get-ChildItem $dir -Recurse -Include '*.ttf', '*.otf' |
    Where-Object { $_.BaseName -notmatch '35' } |
    ForEach-Object {
        $dest = Join-Path $fontDir $_.Name
        if (-not (Test-Path -LiteralPath $dest)) { return }
        # catch の中では $_ は ErrorRecord になり、パイプラインの FileInfo ではなくなる
        # (実測: catch 内で $_.Name は空)。メッセージに使う名前は try へ入る前に控えておく
        $name = $_.Name
        try {
            # 自分自身へ改名してみる。使用中ならここで失敗する
            Rename-Item -LiteralPath $dest -NewName $name -ErrorAction Stop
        } catch {
            Write-Host ""
            Write-Host " エラー " -Background DarkRed -Foreground White
            Write-Host " $app のフォント $name が他のアプリケーションで使用中のため削除できない。" -Foreground DarkRed
            Write-Host " 使用しているアプリケーション（エディタや端末など）を閉じてから再実行すること。" -Foreground Magenta
            Write-Host ""
            exit 1
        }
    }
