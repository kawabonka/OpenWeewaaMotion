#!/usr/bin/env python3
"""Check/apply the pinned Mac-only nxnative source adapter (no game files)."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil


def transform(text):
    anchors = [
        ('#include "pad_switch2_apple.h"', '#include "pad_switch2_apple.h"\n#include "weewaa_bridge.h"'),
        ('        dm_haptics_apple_init();\n        pads_start();',
         '        dm_haptics_apple_init();\n        dm_weewaa_start();\n        pads_start();'),
        ('    g_input_on = 0;\n', '    g_input_on = 0;\n    dm_weewaa_set_active(0);\n'),
        ('    g_input_on = 1;\n', '    g_input_on = 1;\n    dm_weewaa_set_active(1);\n'),
        ('    for (int i = 0; i < n; i++) dm_motion_set_hid(p, s[i].acc, s[i].rot, s[i].ns);',
         '    if (dm_weewaa_owns_motion(p)) return;\n    for (int i = 0; i < n; i++) dm_motion_set_hid(p, s[i].acc, s[i].rot, s[i].ns);'),
    ]
    for old, new in anchors:
        if text.count(old) != 1:
            raise ValueError(f"Expected one integration anchor: {old!r}")
        text = text.replace(old, new)
    if text.count('dm_motion_attach(') != 3:
        raise ValueError("GameController motion attachment sites changed")
    return text.replace('dm_motion_attach(', 'dm_weewaa_motion_attach(')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('repo', type=Path, help='Existing nxnative source checkout')
    parser.add_argument('--apply', action='store_true', help='Apply after checking; default only checks')
    args = parser.parse_args()
    package = Path(__file__).resolve().parent
    manifest = json.loads((package / 'manifest.json').read_text())
    front = args.repo / 'dm/host/front_mac.m'
    original = front.read_bytes()
    if hashlib.sha256(original).hexdigest() != manifest['front_mac_sha256']:
        raise SystemExit('Source differs from the verified upstream revision; do not apply blindly. Rebase the adapter first.')
    updated = transform(original.decode('utf-8'))
    target = args.repo / 'dm/host/weewaa_bridge.h'
    if target.exists():
        raise SystemExit(f'Refusing to overwrite existing adapter: {target}')
    print('PASS: integration anchors match upstream', manifest['upstream_commit'])
    if args.apply:
        shutil.copy2(package / 'weewaa_bridge.h', target)
        front.write_text(updated, encoding='utf-8')
        print('Applied source changes. Rebuild your Mac game host/app; no prebuilt game was modified.')
    else:
        print('Check only. Add --apply to write the two source files.')


if __name__ == '__main__':
    main()
