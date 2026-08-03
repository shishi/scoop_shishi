# scoop_shishi

個人用の Scoop bucket。

```powershell
scoop bucket add shishi https://github.com/shishi/scoop_shishi
```

## フォント

日本語フォント 16 種。**per-user インストール専用**で、`-g`（global）を付けると止まる。

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

`win11debloat` は Windows PowerShell 5.1 を名指しで起動する（本体が pwsh を拒否するため）。起動時に作業ディレクトリをアプリ配下へ移すので、`-Apps` や `-Config` にはフルパスを渡すこと。

`skip-uac-prompt` の配布 URL は版を含まない固定 URL なので、新版が出ても checkver が拾うのは hash だけになる（version は配布ページの `Skip UAC Prompt v1.3` から読む）。zip の最上位は版に依らず `SkipUAC` 固定なので `extract_dir` も固定。コマンド名は 32/64bit どちらでも `skipuac` に揃えてある。
