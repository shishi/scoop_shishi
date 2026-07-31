"""仕様書の 3 つの PowerShell ブロックを bucket/*.json へ同期する。

manifest は自己完結した JSON でなければならないためスクリプトは 16 箇所に複製される。
手で写すと必ずずれるので、原本は仕様書の 1 箇所だけとし、ここから機械的に配る。
Excavator が書き換えるのは version / url / hash / extract_dir なので競合しない。
"""
import io
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC = os.path.join(REPO, 'docs', 'superpowers', 'specs',
                    '2026-07-31-scoop-font-bucket-design.md')
BUCKET = os.path.join(REPO, 'bucket')

MARKERS = {
    'installer': '# scoop:installer',
    'pre_uninstall': '# scoop:pre_uninstall',
    'uninstaller': '# scoop:uninstaller',
}


def load_blocks():
    text = io.open(SPEC, encoding='utf-8').read()
    blocks = re.findall(r'```powershell\n(.*?)```', text, re.S)
    found = {}
    for body in blocks:
        first = body.splitlines()[0]
        for key, marker in MARKERS.items():
            if first.startswith(marker):
                if key in found:
                    raise SystemExit('マーカー %s が仕様書に複数ある' % marker)
                found[key] = body.rstrip('\n').split('\n')
    missing = set(MARKERS) - set(found)
    if missing:
        raise SystemExit('仕様書に見つからないマーカー: %s' % ', '.join(sorted(missing)))
    return found


def apply(path, blocks):
    # utf-8-sig: PowerShell 5.1 の既定の Get-Content（-Encoding 省略時）は BOM が無い
    # UTF-8 をシステムの ANSI コードページ（日本語環境では cp932）として読むため、
    # スクリプト中の日本語コメントが原因で JSON 構造そのものが壊れる（実測で確認済み）。
    # BOM を付けて書くことで Get-Content の既定動作でも正しく UTF-8 と認識させる。
    # utf-8-sig は読み込み時に BOM の有無どちらにも対応する。
    with io.open(path, encoding='utf-8-sig') as f:
        manifest = json.load(f)
    manifest.setdefault('installer', {})['script'] = blocks['installer']
    manifest['pre_uninstall'] = blocks['pre_uninstall']
    manifest.setdefault('uninstaller', {})['script'] = blocks['uninstaller']
    out = json.dumps(manifest, ensure_ascii=False, indent=4) + '\n'
    with io.open(path, 'w', encoding='utf-8-sig', newline='\n') as f:
        f.write(out)


FONT_MANIFESTS = {
    'biz-udgothic', 'biz-udmincho', 'bizin-gothic', 'bizin-gothic-discord',
    'bizin-gothic-nf', 'bizter', 'hackgen', 'hackgen-nf', 'notonoto',
    'noto-color-emoji', 'noto-sans-jp', 'noto-serif-jp', 'plemoljp',
    'plemoljp-nf', 'udev-gothic', 'udev-gothic-nf',
}


def main():
    blocks = load_blocks()
    names = sorted(n for n in os.listdir(BUCKET)
                   if n.endswith('.json') and n[:-5] in FONT_MANIFESTS)
    if not names:
        raise SystemExit('bucket にフォント manifest が無い')
    for name in names:
        apply(os.path.join(BUCKET, name), blocks)
        print('updated', name)


if __name__ == '__main__':
    main()
