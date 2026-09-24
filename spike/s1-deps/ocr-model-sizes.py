#!/usr/bin/env python3
"""AP-AOS · OCR 模型 / 大体积资产核算（M5 体积预算的输入）。

只读 GitHub contents API，递归统计 Azurpilot-Auto 仓库内几个「会显著影响
rootfs.tar.xz 体积」的目录，按目录汇总字节数，并按体积排序。

背景：APK 里 rootfs.tar.xz 是 noCompress 的，所以 rootfs 体积 1:1 变成 APK 体积。
Azurpilot 把 OCR 模型入库在 bin/ 下，需要先算清这笔账才知道要裁多少。

用法：
    python3 spike/s1-deps/ocr-model-sizes.py [--repo OWNER/NAME] [--ref master]
环境变量 GH_TOKEN 可选（有则带 Authorization，避免未认证限流）。
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_REPO = 'changqing81/Azurpilot-Auto'
DEFAULT_REF = 'master'
# 关注的大体积目录（相对于仓库根）；递归但限制深度，避免打爆 API 配额
ROOTS = ['bin', 'assets', 'campaign', 'webapp', 'doc', 'wallpapers', 'submodule', 'switch']
MAX_DEPTH = 3


def api(url, token=None):
    req = urllib.request.Request(url, headers={'User-Agent': 'apaos-size-audit/1.0'})
    if token:
        req.add_header('Authorization', f'Bearer {token}')
    req.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def walk(repo, ref, path, token, depth, budget):
    """返回 (总字节, 文件数)。budget 是可变单元素列表，用于硬性限制 API 调用次数。"""
    if depth > MAX_DEPTH or budget[0] <= 0:
        return 0, 0
    url = f'https://api.github.com/repos/{repo}/contents/{path}?ref={ref}'
    budget[0] -= 1
    try:
        items = api(url, token)
    except urllib.error.HTTPError as e:
        print(f'  ! {path}: HTTP {e.code}', file=sys.stderr)
        return 0, 0
    except Exception as e:
        print(f'  ! {path}: {type(e).__name__}', file=sys.stderr)
        return 0, 0
    if isinstance(items, dict):
        return int(items.get('size', 0)), 1
    total = count = 0
    for it in items:
        if it['type'] == 'file':
            total += int(it.get('size', 0))
            count += 1
        elif it['type'] == 'dir':
            t, c = walk(repo, ref, it['path'], token, depth + 1, budget)
            total += t
            count += c
    return total, count


def mb(n):
    return f'{n / 1048576:.1f} MB'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=DEFAULT_REPO)
    ap.add_argument('--ref', default=DEFAULT_REF)
    ap.add_argument('--budget', type=int, default=60, help='API 调用次数上限')
    args = ap.parse_args()

    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    budget = [args.budget]

    print(f'仓库 {args.repo}@{args.ref}（认证: {"是" if token else "否"}）')
    print(f'{"目录":28} {"体积":>12} {"文件数":>8}')
    print('-' * 54)

    rows = []
    for root in ROOTS:
        size, cnt = walk(args.repo, args.ref, root, token, 1, budget)
        if size or cnt:
            rows.append((root, size, cnt))
    rows.sort(key=lambda r: -r[1])
    for root, size, cnt in rows:
        print(f'{root:28} {mb(size):>12} {cnt:>8}')

    print('-' * 54)
    print(f'{"合计（关注目录）":28} {mb(sum(r[1] for r in rows)):>12} '
          f'{sum(r[2] for r in rows):>8}')
    print(f'剩余 API 配额: {budget[0]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
