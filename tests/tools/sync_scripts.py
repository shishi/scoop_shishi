"""scripts/*.ps1 の 3 つの PowerShell スクリプトを bucket/*.json へ同期する。

manifest は自己完結した JSON でなければならないためスクリプトは 16 箇所に複製される。
手で写すと必ずずれるので、原本は scripts/ 以下の 3 ファイルだけとし、ここから機械的に配る。
Excavator が書き換えるのは version / url / hash / extract_dir なので競合しない。
"""
import io
import json
import os

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPTS_DIR = os.path.join(REPO, 'scripts')
BUCKET = os.path.join(REPO, 'bucket')

MARKERS = {
    'installer': '# scoop:installer',
    'pre_uninstall': '# scoop:pre_uninstall',
    'uninstaller': '# scoop:uninstaller',
}


def load_blocks():
    found = {}
    for key, marker in MARKERS.items():
        path = os.path.join(SCRIPTS_DIR, key + '.ps1')
        if not os.path.isfile(path):
            raise SystemExit('原本が見つからない: %s' % path)
        # 原本は日本語コメントを含むため UTF-8 BOM 付きで保存されている
        # (PowerShell 5.1 が BOM 無し UTF-8 を cp932 と誤解釈するため)。
        # manifest へ注入する内容に BOM を残してはいけないので utf-8-sig で剥がして読む
        text = io.open(path, encoding='utf-8-sig').read()
        first = text.splitlines()[0] if text else ''
        if not first.startswith(marker):
            raise SystemExit('%s の先頭行がマーカー %s で始まっていない' % (path, marker))
        found[key] = text.rstrip('\n').split('\n')
    return found


def apply(path, blocks):
    # 読みは utf-8-sig（BOM 付きでも無しでも通る）、書きは BOM 無し。
    # manifest に BOM を付けてはいけない。scoop 本体は Get-Content -Raw -Encoding UTF8 で
    # 読むので BOM は不要だし、Python 側で encoding='utf-8' で読むツール
    # （zip_entries.py / nameid4.py）が BOM で例外になる。
    # PowerShell 側で日本語が化けるのは読む側の問題なので、読む側で -Encoding UTF8 を指定する
    with io.open(path, encoding='utf-8-sig') as f:
        manifest = json.load(f)
    manifest.setdefault('installer', {})['script'] = blocks['installer']
    manifest['pre_uninstall'] = blocks['pre_uninstall']
    manifest.setdefault('uninstaller', {})['script'] = blocks['uninstaller']
    out = json.dumps(manifest, ensure_ascii=False, indent=4) + '\n'
    # 直接上書きしない。このツールは 16 ファイルに対して繰り返し走るので、
    # 途中で中断されると切り詰められた JSON が残り、その manifest では
    # scoop install が通らなくなる。一時ファイルへ書いてから置換する
    tmp = path + '.tmp'
    # 改行は CRLF。scoop の checkhashes.ps1 / checkver.ps1 が manifest を書き戻すと
    # CRLF になるため、こちらを LF にすると両者が毎回相手の行末を潰し合い、
    # 実質的な変更が無いのに全 manifest へ差分が出続ける(実測)
    with io.open(tmp, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(out)
    os.replace(tmp, path)


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
