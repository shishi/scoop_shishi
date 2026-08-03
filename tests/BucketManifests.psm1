# bucket 配下の manifest を「フォント」と「それ以外のツール」に分ける唯一の場所。
#
# 以前は 'crvskkserv','mery',... というツール名のブロックリストを
# Manifest.Tests.ps1(3 箇所)と Uniqueness.Tests.ps1(1 箇所)へ写していた。
# manifest を 1 つ足すたびに 4 箇所すべてを直す必要があり、直し忘れると
# 新しく足したツールがフォント扱いのまま「license は OFL-1.1」で落ちる。
#
# 判別は名前ではなく中身で行う。フォント manifest だけが installer キーを
# 持つ(実測: フォント 16 件は全部持ち、ツール 6 件は 1 つも持たない)。
# ツールは bin / shortcuts で足りるので installer を書く理由が無い
function Get-FontManifestFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BucketDir)

    @(Get-ChildItem $BucketDir -Filter '*.json' | Where-Object {
        $json = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $json.PSObject.Properties.Name -contains 'installer'
    })
}

Export-ModuleMember -Function Get-FontManifestFile
