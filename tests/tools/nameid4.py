"""フォントの nameID 4 からレジストリのキー名を作る。PowerShell 版とは別実装。

同じ間違いをしないことに価値があるので、PowerShell 側を参考にせず
OpenType 仕様だけを見て書くこと。
"""
import io
import json
import os
import struct
import sys


def tables(data):
    if len(data) < 12:
        raise ValueError('短すぎる')
    if data[:4] == b'ttcf':
        raise ValueError('TTC は対象外')
    num = struct.unpack('>H', data[4:6])[0]
    out = {}
    for i in range(num):
        rec = 12 + i * 16
        tag = data[rec:rec + 4].decode('latin1')
        off, length = struct.unpack('>II', data[rec + 8:rec + 16])
        out[tag] = (off, length)
    return out


def name_record(path, want):
    """nameID `want` の文字列を返す。Windows/en-US を最優先する。

    プラットフォーム ID ごとに文字列のエンコーディングが違う
    (OpenType 'name' テーブル仕様): platform 0 (Unicode) と
    platform 3 (Windows) は UTF-16BE、platform 1 (Macintosh) は
    1 バイトの Mac Roman。ランク付けだけ先に済ませ、実際に採用する
    レコード 1 件だけをそのプラットフォームに応じた方式でデコードする
    (途中の候補まで UTF-16BE 決め打ちでデコードすると、Mac レコードの
    奇数バイト長データで例外になる)。
    """
    data = io.open(path, 'rb').read()
    tabs = tables(data)
    if 'name' not in tabs:
        raise ValueError('name テーブルが無い')
    off = tabs['name'][0]
    count, str_off = struct.unpack('>HH', data[off + 2:off + 6])
    str_base = off + str_off
    best = None
    best_rank = 99
    for i in range(count):
        rec = off + 6 + i * 12
        pid, eid, lid, nid, length, noff = struct.unpack('>HHHHHH', data[rec:rec + 12])
        if nid != want:
            continue
        rank = 0 if (pid == 3 and lid == 0x409) else 1 if pid == 3 else 2 if pid == 0 else 9
        if rank >= best_rank:
            continue
        best = (pid, noff, length)
        best_rank = rank
    if best is None:
        raise ValueError('nameID %d が無い' % want)
    pid, noff, length = best
    raw = data[str_base + noff:str_base + noff + length]
    encoding = 'mac_roman' if pid == 1 else 'utf-16-be'
    return raw.decode(encoding)


def family_name(path):
    """フォントが属するファミリ名を返す。

    nameID 16 (Typographic Family) があればそれを使う。OpenType 仕様上、
    GDI の 4 スタイル (Regular/Bold/Italic/BoldItalic) に収まらない
    ウェイト展開を持つフォントは、nameID 1 (Font Family) 側にウェイト名
    まで含めてしまう (例: "NOTONOTO Black")。この場合でも nameID 16 は
    展開前の本来のファミリ名 ("NOTONOTO") を指す。nameID 16 が無いフォント
    では nameID 1 がそのままファミリ名になる。
    """
    try:
        return name_record(path, 16)
    except ValueError:
        return name_record(path, 1)


def main():
    """引数で受け取ったディレクトリ群だけを走査する。

    scoop/apps 全体を見てはいけない。tor-browser・rstudio・calibre などが
    フォントを同梱しており、実測でこのマシンには 909 個の .ttf/.otf がある。
    """
    roots = sys.argv[1:]
    if not roots:
        raise SystemExit('走査するディレクトリを 1 つ以上渡すこと')
    regnames = {}
    families = set()
    for root in roots:
        for dirpath, _, files in os.walk(root):
            for fn in files:
                ext = os.path.splitext(fn)[1].lower()
                if ext not in ('.ttf', '.otf'):
                    continue
                if '35' in os.path.splitext(fn)[0]:
                    continue          # 共通スクリプトが除外する対象
                path = os.path.join(dirpath, fn)
                suffix = ' (OpenType)' if ext == '.otf' else ' (TrueType)'
                name = name_record(path, 4) + suffix
                if fn in regnames and regnames[fn] != name:
                    raise SystemExit('同名ファイルで名前が食い違う: %s' % fn)
                regnames[fn] = name
                families.add(family_name(path))
    out = {'regnames': regnames, 'families': sorted(families)}
    print(json.dumps(out, ensure_ascii=False, indent=2, sort_keys=True))


if __name__ == '__main__':
    main()
