# scoop_shishi

個人用の Scoop bucket。

## フォント manifest

日本語フォント 16 種を per-user インストールで提供する。全 manifest で
125 個のフォントファイルがレジストリへ登録され、25 のフォントファミリになる。

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

### 制約と仕様

- **per-user 専用。** `-g`（global）を付けると installer が例外を投げて止まる
- **文字幅比率 3:5 の「35」系は登録しない。** zip には含まれるが Fonts フォルダへは置かれない
- **レジストリのキー名はフォント内部の Full font name（nameID 4）から作る。** Windows 標準のインストーラーと同じ規則なので、手動で入れた同じフォントの登録を置き換える
- **AppContainer（UWP アプリ）からフォントが見えるかは未検証。** Fonts ディレクトリへ `S-1-15-2-1` / `S-1-15-2-2` の読み取り許可を付けてはいるが、実際に UWP アプリから開けることは確認していない
- **Noto Color Emoji のカラー表示は実測待ち。** 同梱の `NotoColorEmoji_WindowsCompatible.ttf` を解析した結果、`CBDT`/`CBLC`（ビットマップ型カラーグリフ）テーブルを持ち、`COLR`/`CPAL`（ベクター型カラーグリフ）は持たない。`glyf` テーブルは 1 byte のみで実質空のフォールバック輪郭である。これはファイル構造から確認した事実であり、画面上で実際にカラー表示されるかどうかはまだ誰も確認していない。もし色が出ない場合は Windows 標準の Segoe UI Emoji を使えばよい

### 既知の制限

- **ループ途中の失敗ではもう壊れない。** 状態管理用ジャーナル(`scoop-font-state.json`)の退役は、フォントごとの処理ループへ入る前に無条件で行う。ループ本体も1ファイルごとにtry/catchで囲んであり、ロックされたファイルなどで1件が失敗しても最後まで走り切る。そのため「変更済みなのに有効な記録が残ったままになり、次のinstallがそれを既存のものと誤認して、以後のuninstallが復元に化けて成功を報告し続ける」という壊れ方は構造的に起きなくなっている(これは開発中に一度実際に発生し、手動での復旧が必要になった不具合で、その修正)。
  - 中断されたアンインストールが何を触ったか確認したい場合は、
    `%LOCALAPPDATA%\scoop-font-backup\<app>-<version>\scoop-font-state.retired.json`
    (退役済みの記録)を見ること。アクティブな `scoop-font-state.json` は退役後には存在しない
- **正直な残存ケース: 2回連続で中断されると、3回目は何もしない。** 退役の対象は「そのとき見つかった記録」1つだけで、退避ディレクトリ側の写しを優先し、無ければアプリディレクトリ側の写しを使う。プロセスが2回続けてkillされると、この2つの写しが1回ずつ消費されてしまい、3回目の試行では有効な記録がどこにも見つからない。この場合は成功したと偽らずフォントの削除を行わずに退却し、探した場所と退避ディレクトリに残っている `*.retired.json` をコンソールへ表示する
  - 対策: アンインストールは強制終了させず最後まで完走させること

### manifest を追加・変更するとき

`installer.script` / `pre_uninstall` / `uninstaller.script` の 3 つは **16 manifest すべてで完全に同一**でなければならない。手で写さないこと。原本は
`scripts/installer.ps1` / `scripts/pre_uninstall.ps1` / `scripts/uninstaller.ps1` の 3 ファイルだけである。

1. 原本(`scripts/*.ps1`)を直す
2. `python3 tests/tools/sync_scripts.py` で全 manifest へ配る
3. `tests/tools/sync_scripts.py` の `FONT_MANIFESTS` に新しい名前を足す(manifest を増やした場合)
4. `powershell -File tests\run.ps1` でテストする

同一性は `tests/Manifest.Tests.ps1` が検査する。

### テスト

```powershell
.\tests\run.ps1
```

Pester 5.9.0 を `tests/.modules/` へ自動で取り込む(バージョンと SHA256 を固定)。
共有のモジュールパスは汚さないので、他プロジェクトが使う Pester 3.4.0 には影響しない。
