#!/usr/bin/env python3
"""M0-S1 桌面核查 v3：补查容易漏掉的「传递依赖 / 变体包」。

重点：
1. opencv-python 的 abi3 轮子链接 libGL，headless 环境 import 会炸
   → 本仓现用 opencv-python-headless，需确认它也有 aarch64 轮子
2. aiortc 是纯 Python，但它的原生传递依赖（av / pylibsrtp / cryptography）才是编译风险
3. adbutils 的轮子是否覆盖 linux aarch64（本仓 connection.py 顶层 import 它）
4. zerorpc 的原生传递依赖 gevent
"""
import json
import sys
import urllib.request
import urllib.error

TARGETS = [
    ('opencv-python-headless', None),
    ('av', None),
    ('pylibsrtp', None),
    ('cryptography', None),
    ('gevent', None),
    ('greenlet', None),
    ('adbutils', None),
    ('scikit-image', None),
    ('pyclipper', None),
    ('shapely', None),
    ('pypng', None),
    ('opencv-contrib-python-headless', None),
]


def fetch(pkg, ver=None):
    url = f'https://pypi.org/pypi/{pkg}/{ver}/json' if ver else f'https://pypi.org/pypi/{pkg}/json'
    req = urllib.request.Request(url, headers={'User-Agent': 'apaos-s1-check/3.0'})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode('utf-8'))


def parse_wheel(fn):
    if not fn.endswith('.whl'):
        return None
    parts = fn[:-4].split('-')
    return (parts[-3], parts[-2], parts[-1]) if len(parts) >= 5 else None


def is_linux_aarch64(plat):
    if any(x in plat for x in ('macosx', 'win', 'ios')):
        return False
    if 'aarch64' not in plat and 'arm64' not in plat:
        return False
    return ('manylinux' in plat) or ('musllinux' in plat) or plat == 'linux_aarch64'


def py314_ok(py, abi):
    if py in ('cp314', 'cp314t'):
        return True
    if py == 'py3' and abi == 'none':
        return True
    if abi in ('abi3', 'none') and py.startswith('cp3'):
        try:
            return int(py[3:5]) <= 14
        except ValueError:
            return False
    return False


def summarize(files):
    wheels = [f for f in files if f.get('packagetype') == 'bdist_wheel']
    sdists = [f for f in files if f.get('packagetype') == 'sdist']
    univ = la64 = x86 = None
    plats = set()
    for f in wheels:
        t = parse_wheel(f['filename'])
        if not t:
            continue
        py, abi, plat = t
        plats.add(plat.split('.')[0])
        if plat == 'any':
            univ = univ or f['filename']
            continue
        if not py314_ok(py, abi):
            continue
        if is_linux_aarch64(plat):
            la64 = la64 or f['filename']
        elif 'x86_64' in plat or 'amd64' in plat:
            x86 = x86 or f['filename']
    if la64:
        v = 'LINUX-A64'
    elif univ:
        v = 'UNIVERSAL'
    elif x86:
        v = 'X86-ONLY'
    elif sdists:
        v = 'SRC-ONLY'
    else:
        v = 'MISSING'
    return v, (la64 or univ or x86 or (sdists[0]['filename'] if sdists else '-')), plats


def main():
    print(f'{"package":30} {"version":12} {"verdict":11} artifact')
    print('-' * 120)
    for pkg, ver in TARGETS:
        try:
            d = fetch(pkg, ver)
            v, art, plats = summarize(d.get('urls') or [])
            print(f'{pkg:30} {d["info"]["version"]:12} {v:11} {art[:62]}')
            if v in ('X86-ONLY', 'SRC-ONLY', 'MISSING'):
                print(f'{"":30} {"":12} {"":11} 平台标签: {sorted(plats)[:6]}')
        except urllib.error.HTTPError as e:
            print(f'{pkg:30} {(ver or "?"):12} {"MISSING":11} HTTP {e.code}')
        except Exception as e:
            print(f'{pkg:30} {(ver or "?"):12} {"ERROR":11} {type(e).__name__}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
