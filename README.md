# scoop_shishi

個人用の Scoop bucket。

```powershell
scoop bucket add shishi https://github.com/shishi/scoop_shishi
```

## フォント

日本語フォント 16 種。**global インストール専用**なので、管理者権限のシェルで `-g` を付ける。

```powershell
scoop install -g bizter
```

per-user（`-g` なし）は受け付けない。Windows がログオン時にロードするフォントは
`FontCache-FontSet-<SID>.dat` が持つ集合で決まり、`HKCU` への登録も `AddFontResourceW` も
その集合を変えないため、**再起動するとフォントが消える**（実測: `HKCU` に 126 件登録済みでも
OS が開くのは固定の 44 件だけ。キャッシュを退避して再構築させても増えなかった）。
Microsoft の [GDI ドキュメント](https://learn.microsoft.com/en-us/windows/win32/gdi/font-installation-and-deletion)も
`AddFontResource` を temporary installation と明記し、永続化には `%windir%\fonts` への配置を求めている。

per-user で入れた版から移行する場合は、先に片付けてから入れ直す。

```powershell
scoop uninstall bizter
```

| manifest | フォント |
|---|---|
| `hackgen` / `hackgen-nf` | 白源（Hack + 源柔ゴシック） |
| `plemoljp` / `plemoljp-nf` | PlemolJP（IBM Plex Mono + IBM Plex Sans JP） |
| `udev-gothic` / `udev-gothic-nf` | UDEV Gothic（BIZ UDゴシック + JetBrains Mono） |
| `notonoto` | NOTONOTO（Noto Sans Mono + Noto Sans JP） |
| `bizin-gothic` / `bizin-gothic-nf` / `bizin-gothic-discord` | Bizin Gothic（BIZ UDゴシック + Inconsolata） |
| `bizter` | BIZTER（BIZ UDPゴシック + Inter） |
| `biz-udgothic` / `biz-udmincho` | モリサワ BIZ UD |
| `noto-sans-jp` / `noto-serif-jp` / `noto-color-emoji` | Noto |

`-nf` は Nerd Fonts 版。文字幅比率 3:5 の「35」系は zip に含まれるが登録しない。

## ツール

| manifest | 配布元 |
|---|---|
| `mery` | https://www.haijin-boys.com/wiki/ |
| `win11debloat` | https://github.com/Raphire/Win11Debloat |
| `crvskkserv` | https://github.com/nathancorvussolis/crvskkserv |
| `nomeiryoui` | https://github.com/Tatsu-syo/noMeiryoUI |
| `tclock-win10` | https://github.com/MantisMountainMobile/TClock-Win10 |
| `umaumachecker` | https://github.com/Cilda/UmaUmaChecker |
| `umaumacruise` | https://github.com/amate/UmaUmaCruise |
| `skip-uac-prompt` | https://www.sordum.org/skip-uac-prompt |
| `xcolumn` | https://github.com/mashersan/XColumn |

`win11debloat` は Windows PowerShell 5.1 を名指しで起動する（本体が pwsh を拒否するため）。起動時に作業ディレクトリをアプリ配下へ移すので、`-Apps` や `-Config` にはフルパスを渡すこと。
