"""HKLM に既存登録があるフォントファイルを nameid4.py 自身のランキングで読み、
Windows 自身がレジストリキーに付けた名前(nameID 4 の文字列部分)と一致するか
確認する。

RegName.Tests.ps1 の「Windows 自身が付けた名前と同じ規則である」テストから
JSON 配列 [{"key": <HKLM のキー名>, "file": <実ファイルパス>,
"family": <フィクスチャ上のファミリ名>}, ...] を書いたファイルのパスを
第 1 引数に渡して呼び出す。

入力を標準入力ではなくファイルで受けるのは、`$payload | & python3 ...` が
ごく稀に空の標準入力のまま起動することがあるため(実測: 同一コミットで
5 回中 2 回、json.decoder.JSONDecodeError: Expecting value: line 1 column 1
で落ちた)。この環境の python3 は scoop の shim (~/scoop/shims/python3.exe) で、
実体の python を起動する中継プロセスが挟まる。ファイル渡しにすれば
中継を跨ぐ標準入力そのものが不要になる。

入力が空だと「候補が一件も無い」場合と区別が付かず、テストが理由不明に
落ちる。呼び出し側でも書き出しの成否を確かめているが、こちらでも空を弾く。

なぜサフィックス((TrueType)/(OpenType))を比較対象から外すか:
nameid4.py はサフィックスをファイル拡張子から機械的に決めている
(.otf → OpenType, .ttf → TrueType)。この規則が自己無矛盾であることは
別の独立実装テスト(HKCU 側、scoop が今回インストールしたファイル同士の
突き合わせ)で 125/125 件確認済み。一方 HKLM 側には、このリポジトリと無関係な
何年も前の第三者ツールによる登録が残っており、実測すると Noto Serif JP の
一部 .otf ファイルは sfnt version が 'OTTO' (CFF アウトライン) であるにも
かかわらず HKLM 上は "(TrueType)" として登録されている
(古いツールの命名規則の違いであり、本リポジトリのどちらの実装が誤っている
わけでもない)。この widen テストの目的はあくまで finding 1 が指す
「候補レコードの順位付け(Windows/en-US > Windows/その他 > Unicode > Mac)」
の正しさを外部で裏付けることなので、その順位付けの結果である nameID 4 の
文字列本体だけを比較し、無関係なサフィックス規約の食い違いで足を取られない
ようにする。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nameid4  # noqa: E402


def main():
    if len(sys.argv) < 2:
        raise SystemExit('使い方: check-hklm-names.py <候補を書いた JSON ファイル>')
    raw = open(sys.argv[1], encoding='utf-8-sig').read()
    if not raw.strip():
        raise SystemExit('入力が空: %s。呼び出し側の書き出しが失敗している' % sys.argv[1])
    candidates = json.loads(raw)
    # PowerShell の ConvertTo-Json は要素が 1 個だと配列にせず単体オブジェクトを出す
    if isinstance(candidates, dict):
        candidates = [candidates]
    if not candidates:
        raise SystemExit('候補が 0 件。呼び出し側が Skipped にすべき状態で呼んでいる')

    ok = 0
    wrong = []
    families = set()
    for c in candidates:
        path = c['file']
        key = c['key']
        family = c['family']
        try:
            actual = nameid4.name_record(path, 4)
        except Exception as e:
            wrong.append('%s: %s: %s' % (path, type(e).__name__, e))
            continue
        expected_base = key.rsplit(' (', 1)[0]
        if actual == expected_base:
            ok += 1
            families.add(family)
        else:
            wrong.append('%s: key=%r actual base=%r' % (path, key, actual))

    print(json.dumps({'ok': ok, 'wrong': wrong, 'families': sorted(families)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
