# scoop:pre_uninstall  ここから 16 manifest 共通
$fontDir = "$env:LOCALAPPDATA\Microsoft\Windows\Fonts"
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
