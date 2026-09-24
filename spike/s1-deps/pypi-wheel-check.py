#!/usr/bin/env python3
"""M0-S1 桌面核查 v2：Azurpilot-Auto 关键依赖在 PyPI 上的
**Linux aarch64 + Python 3.14** 轮子可用性。

v1 的 bug：'arm64' 子串把 macOS arm64 轮子误判为 aarch64，已修正为
只认 manylinux/musllinux 且排除 macosx。

只读 PyPI JSON API，不安装任何东西。
"""
import json
import sys
import urllib.request
import urllib.error

TARGETS = [
    ('numpy', '2.4.6'), ('scipy', '1.18.0'), ('opencv-python', '5.0.0.93'),
    ('onnxruntime', '1.27.0'), ('numba', '0.66.0'), ('rapidocr', '3.9.0'),
    ('ncnn', None), ('zerorpc', '0.6.3'), ('pyzmq', '27.1.0'),
    ('matplotlib', '3.11.0'), ('uv', '0.11.32'), ('mcp', '1.23.0'),
    ('sse-starlette', '3.0.3'), ('aiortc', None),
    ('pillow', None), ('lxml', None), ('pywebio', None), ('uvicorn', None),
    ('fastapi', None), ('aiofiles', None), ('inflection', None), ('pyyaml', None),
    ('requests', None), ('tqdm', None), ('rich', None), ('websockets', None),
    ('pypresence', None), ('onepush', None), ('adbutils', None),
    ('uiautomator2', None), ('pydantic', None), ('imageio', '2.27.0'),
    ('cached-property', None),
]


def fetch(pkg, ver=None):
    url = f'https://pypi.org/pypi/{pkg}/{ver}/json' if ver else f'https://pypi.org/pypi/{pkg}/json'
    req = urllib.request.Request(url, headers={'User-Agent': 'apaos-s1-check/2.0'})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.loads(r.read().decode('utf-8'))


def parse_wheel(fn):
    """→ (py_tag, abi_tag, platform_tag) 或 None"""
    if not fn.endswith('.whl'):
        return None
    parts = fn[:-4].split('-')
    if len(parts) < 5:
        return None
    return parts[-3], parts[-2], parts[-1]


def is_linux_aarch64(plat):
    if 'macosx' in plat or 'win' in plat or 'ios' in plat:
        return False
    if 'aarch64' not in plat and 'arm64' not in plat:
        return False
    return ('manylinux' in plat) or ('musllinux' in plat) or (plat == 'linux_aarch64')


def py314_ok(py_tag, abi_tag):
    if py_tag in ('cp314', 'cp314t'):
        return True
    if py_tag == 'py3' and abi_tag == 'none':
        return True
    if abi_tag in ('abi3', 'none') and py_tag.startswith('cp3'):
        try:
            return int(py_tag[3:5]) <= 14
        except ValueError:
            return False
    return False


def classify(files):
    wheels = [f for f in files if f.get('packagetype') == 'bdist_wheel']
    sdists = [f for f in files if f.get('packagetype') == 'sdist']

    univ, la64, x86_314 = None, None, None
    for f in wheels:
        t = parse_wheel(f['filename'])
        if not t:
            continue
        py, abi, plat = t
        if plat == 'any':
            univ = univ or f['filename']
            continue
        if not py314_ok(py, abi):
            continue
        if is_linux_aarch64(plat):
            la64 = la64 or f['filename']
        elif 'x86_64' in plat or 'amd64' in plat:
            x86_314 = x86_314 or f['filename']

    if la64:
        return 'LINUX-A64', la64
    if univ:
        return 'UNIVERSAL', univ
    if x86_314:
        return 'X86-ONLY', x86_314
    if sdists:
        return 'SRC-ONLY', sdists[0]['filename']
    return 'MISSING', '-'


def main():
    print(f'{"package":20} {"version":14} {"verdict":11} linux-aarch64 artifact')
    print('-' * 118)
    tally = {}
    risky = []
    for pkg, ver in TARGETS:
        try:
            data = fetch(pkg, ver)
            resolved = data['info']['version']
            verdict, art = classify(data.get('urls') or [])
        except urllib.error.HTTPError as e:
            resolved, verdict, art = (ver or '?'), 'MISSING', f'HTTP {e.code}'
        except Exception as e:
            resolved, verdict, art = (ver or '?'), 'ERROR', f'{type(e).__name__}'
        tally[verdict] = tally.get(verdict, 0) + 1
        if verdict in ('SRC-ONLY', 'X86-ONLY', 'MISSING', 'ERROR'):
            risky.append(f'{pkg}=={resolved} ({verdict})')
        print(f'{pkg:20} {resolved:14} {verdict:11} {art[:74]}')
    print('-' * 118)
    print('汇总:', ', '.join(f'{k}={v}' for k, v in sorted(tally.items())))
    print()
    if risky:
        print('需要关注（无 Linux aarch64 轮子）:')
        for r in risky:
            print('  -', r)
    else:
        print('全部依赖在 PyPI 上都有可用于 Linux aarch64 的轮子。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
