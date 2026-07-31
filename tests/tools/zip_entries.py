"""bucket/*.json の url から収録ファイル一覧を取り、フィクスチャへ書き出す。

zip は末尾の中央ディレクトリだけ HTTP range で取得する。PlemolJP は 206 MB
あるが転送は数百 KB で済む。
"""
import io
import json
import os
import struct
import subprocess

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUCKET = os.path.join(REPO, 'bucket')
OUT = os.path.join(REPO, 'tests', 'fixtures', 'zip-entries.json')

FONT_EXT = ('.ttf', '.otf')


def curl(args):
    return subprocess.run(['curl', '-sL'] + args, capture_output=True).stdout


def content_length(url):
    head = curl(['-I', url]).decode('latin1')
    n = None
    for line in head.splitlines():
        if line.lower().startswith('content-length:'):
            n = int(line.split(':')[1].strip())
    return n


def zip_names(url, tail=300000):
    total = content_length(url)
    if not total:
        raise SystemExit('サイズを取得できない: %s' % url)
    buf = curl(['-H', 'Range: bytes=%d-' % max(0, total - tail), url])
    i = buf.rfind(b'PK\x05\x06')
    if i < 0:
        raise SystemExit('EOCD が見つからない: %s' % url)
    cd_off = struct.unpack('<I', buf[i + 16:i + 20])[0]
    base = total - len(buf)
    if cd_off < base:
        buf = curl(['-H', 'Range: bytes=%d-' % cd_off, url])
        base = cd_off
    p = cd_off - base
    names = []
    while p < len(buf) - 4 and buf[p:p + 4] == b'PK\x01\x02':
        nlen, elen, clen = struct.unpack('<HHH', buf[p + 28:p + 34])
        name = buf[p + 46:p + 46 + nlen].decode('utf-8', 'replace')
        if not name.endswith('/'):
            names.append(name.rsplit('/', 1)[-1])
        p += 46 + nlen + elen + clen
    return names


def main():
    result = {}
    for fn in sorted(os.listdir(BUCKET)):
        if not fn.endswith('.json'):
            continue
        with io.open(os.path.join(BUCKET, fn), encoding='utf-8') as f:
            m = json.load(f)
        if 'installer' not in m:
            continue          # フォント以外の manifest は飛ばす
        urls = m['url'] if isinstance(m['url'], list) else [m['url']]
        names = []
        for u in urls:
            if u.lower().endswith('.zip'):
                names.extend(zip_names(u))
            else:
                names.append(u.rsplit('/', 1)[-1])
        result[fn[:-5]] = sorted(n for n in names if n.lower().endswith(FONT_EXT))
        print(fn[:-5], len(result[fn[:-5]]))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    main()
