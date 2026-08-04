# 実機のフォント登録を読む。フォント manifest は global 専用なので HKLM を見る
# (永続化されるのは %WINDIR%\Fonts + HKLM だけで、per-user は再起動でロードされない)。
#
# 環境の前後比較(Get-FontEnvSnapshot / Assert-FontEnvRestored)は持たない。
# それを使っていた実機スイートは、global のフォントが OS にロードされていて
# uninstall で削除できず比較が常に失敗するため廃止した。installer / uninstaller の
# 振る舞いはサンドボックスの Collision / GlobalInstall / GdiRefCount が検証する
$script:RegKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts'

function Get-FontRegValue {
    param([Parameter(Mandatory)][string]$Name)
    $p = Get-ItemProperty -Path $script:RegKey -Name $Name -ErrorAction SilentlyContinue
    if ($p) { return $p.($Name) }
    return $null
}

Export-ModuleMember -Function Get-FontRegValue
