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

- **ループ途中の失敗ではもう壊れないが、退役するのは「見つかった記録 1 つ」だけ。** 状態管理用ジャーナル(`scoop-font-state.json`)の退役は、フォントごとの処理ループへ入る前に無条件で行う。ループ本体も1ファイルごとにtry/catchで囲んであり、ロックされたファイルなどで1件が失敗しても最後まで走り切る。そのため「変更済みなのに有効な記録が残ったままになり、次のinstallがそれを既存のものと誤認して、以後のuninstallが復元に化けて成功を報告し続ける」という壊れ方は構造的に起きなくなっている(これは開発中に一度実際に発生し、手動での復旧が必要になった不具合で、その修正)。ただし退役するのは、退避ディレクトリ側の写しがあればそちら、無ければアプリディレクトリ側の写し――その時点で「見つかった方」1つだけであり、もう片方の写しが残っていればそれはアクティブなまま残る(次の bullet の「2回連続で中断されると3回目は何もしない」は、この2つの写しが1回ずつ消費される経路そのもの)。
  - 退役済みの記録は、消費した写しが元々あった場所にそのまま残る。退避ディレクトリ側の写しを使った通常のケースでは
    `%LOCALAPPDATA%\scoop-font-backup\<app>-<version>\scoop-font-state.retired.json`
    に残るが、直前の中断で退避ディレクトリ側が既に退役済みのためアプリディレクトリ側の写しにフォールバックした場合は、アプリのインストール先ディレクトリ直下の `scoop-font-state.retired.json` に残る(見つけた場所の隣へリネームするだけで、退避ディレクトリへ集約はしない)
  - この記録は「中断されたアンインストールが実際に何を undo できたか」を示すものではない。`Phase` はインストーラーだけが書き込み、アンインストーラーは更新しないため、退役後の記録は install 時点の計画(何を書き換える見込みだったか)のままであり、undo の結果ではない
- **正直な残存ケース: 2回連続で中断されると、3回目は何もしない。** 退役の対象は「そのとき見つかった記録」1つだけで、退避ディレクトリ側の写しを優先し、無ければアプリディレクトリ側の写しを使う。プロセスが2回続けてkillされると、この2つの写しが1回ずつ消費されてしまい、3回目の試行では有効な記録がどこにも見つからない。この場合は成功したと偽らずフォントの削除を行わずに退却し、探した場所と退避ディレクトリに残っている `*.retired.json` をコンソールへ表示する
  - 対策: アンインストールは強制終了させず最後まで完走させること

### manifest を追加・変更するとき

`installer.script` / `pre_uninstall` / `uninstaller.script` の 3 つは **16 manifest すべてで完全に同一**でなければならない。手で写さないこと。原本は
`scripts/installer.ps1` / `scripts/pre_uninstall.ps1` / `scripts/uninstaller.ps1` の 3 ファイルだけである。

**manifest を増やす・減らす場合の順序(重要):** `sync_scripts.py` は `FONT_MANIFESTS`
の allowlist でフィルタするので、先に allowlist を直さないと新しい manifest が
黙って同期対象から外れる。

1. `tests/tools/sync_scripts.py` の `FONT_MANIFESTS` に新しい名前を足す(manifest を増やした場合。減らす場合は外す)
2. 原本(`scripts/*.ps1`)を直す(変更する場合)
3. `python3 tests/tools/sync_scripts.py` で全 manifest へ配る
4. 「どの manifest がフォントか」を判定・カウントしている箇所は他にもあり、
   manifest を増減したときは全部を直す必要がある:
   - `tests/tools/sync_scripts.py` の `FONT_MANIFESTS`(手順 1 で対応済み)
   - `tests/tools/gen-expected-regnames.ps1` の `$Apps`
   - `tests/Manifest.Tests.ps1` の除外リスト `-notin @('crvskkserv', ...)`(BeforeDiscovery に 1 箇所、BeforeAll に 2 箇所、計 3 箇所)
   - `tests/Uniqueness.Tests.ps1` の除外リスト `$script:CurrentFontManifests`
   - `tests/tools/zip_entries.py` は manifest に `installer` キーがあるかどうかで
     自動判定するので手を入れる必要はないが、判定条件がここにもある点は把握しておく
   - 件数のハードコード: `tests/RegName.Tests.ps1`(期待値 125 件・25 ファミリ)、
     `tests/Uniqueness.Tests.ps1`(16 manifest・配布 217 個・登録 125 個・35 系除外 92 個)
5. フィクスチャを再生成する(内容を機械的に生成し直すことで、上のカウント変更を裏づける):
   - `powershell -File tests\tools\gen-expected-regnames.ps1`(16 個すべてが `scoop install` 済みであることが前提)
   - `python3 tests/tools/zip_entries.py`(16 manifest ぶんネットワークアクセスする。数分かかる)
6. `powershell -File tests\run.ps1` でテストする

同一性は `tests/Manifest.Tests.ps1` が検査する。フィクスチャの manifest 集合や
バージョンとの食い違いは `tests/Uniqueness.Tests.ps1` が検査する。

### テスト

⚠️ **このスイートは実機のフォント環境を書き換える。** 通常のユニットテストではない。

- `Lifecycle` / `Collision` / `Update` / `FontNotify` は実際に scoop でフォントパッケージを
  uninstall・reinstall し、HKCU のレジストリ値を削除してから書き戻し、
  `%LOCALAPPDATA%\Microsoft\Windows\Fonts` を書き換え、検証用の一時 Scoop bucket を
  追加・削除する
- `FontNotify` は install/uninstall の直後にフォントが OS から見えるか(見えなくなるか)を
  新しいプロセスの DirectWrite で確かめる。検証に使うファミリは HKLM
  (`C:\Windows\Fonts`)に同名の登録が無いものでなければならない。あると install の
  有無に関わらず「見える」になり、スイート全体が無意味になる
- `GdiRefCount` は GDI のフォント参照カウントの収支を検証する。実機の GDI もフォント環境も
  触らない代わりに、P/Invoke をカウンタ付きのスタブへ差し替え、`$env:LOCALAPPDATA` を
  一時ディレクトリへ、`HKCU:` PSDrive を `HKCU\Software\ScoopFontRefCountTest` へ
  張り替える(実レジストリへの書き込みはこのサンドボックス用キーの作成 1 回だけ)。
  張り替えに失敗した場合は本物のレジストリを汚す前に停止する。
  このスイートだけを走らせるには `tests\invoke.ps1 -Dir tests -Tag GdiRef`

  ファイルとレジストリが正しくても参照カウントだけが狂う不具合は、他のどのスイートでも
  検出できない。外部レビューで 3 回続けて同じ場所を間違えたので専用のスイートを置いた
- `RegName` は 16 個のフォント manifest すべてが事前に `scoop install` 済みであることを
  前提にする(未インストールのものがあると失敗する)
- `Manifest` は `tests/tools/sync_scripts.py` を実行するため作業ツリー(`bucket/*.json`)
  を書き換える(冪等なので実質的な差分は残らないはずだが、実行自体はする)

⚠️ **使用中のフォントがあると `Collision` / `Lifecycle` が落ちることがある。**
エディタや端末が実際にそのフォントで描画していると、ファイルがメモリマップされて
削除できない(実測: HackGen と PlemolJP は常用しているため、しばしばロックされている)。
テストの不具合ではなく環境の状態なので、対象のフォントを使っているアプリを閉じてから
実行すること。`pre_uninstall` が同じ状況を検出して案内を出すのと同じ理屈

```powershell
.\tests\run.ps1
```

Pester 5.9.0 を `tests/.modules/` へ自動で取り込む(バージョンと SHA256 を固定)。
共有のモジュールパスは汚さないので、他プロジェクトが使う Pester 3.4.0 には影響しない。

`Bootstrap` / `Manifest` / `Uniqueness` / `FontName` はレジストリにも実フォント環境にも
触れない、マシン非依存の静的スイートで `Static` タグを付けてある。それだけを走らせるには:

```powershell
.\tests\run.ps1 -StaticOnly
```
