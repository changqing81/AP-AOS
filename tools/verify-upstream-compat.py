#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AP-AOS rootfs 种子兼容性一键验证（构建前跑，防上游结构漂移）。

验什么：对 changqing81/Azurpilot-Auto 本机检出（dev=master）做五项实证——
  1) 注入锚点 8/8（bootstrap 消费的类/方法存在）
  2) args.json 新旧挂载位（regen_args 候选路径至少一头命中）
  3) template.json 种子锚点（seed_config 候选路径至少一头命中）
  4) uv sync 闸门（烘焙 seed 的 InstallDependencies=false 能被行级读取关闭）
  5) deploy 分流（auto 在 CN/海外/未知三态的正确落点）
用法：
  python tools/verify-upstream-compat.py [--upstream D:/alas/AzurPilot]
exit 0 全绿；非 0 有断锚。
"""
import argparse
import io
import json
import os
import sys
from pathlib import Path

# Windows GBK 控制台防乱码：stdout/stderr 强制 UTF-8
if sys.stdout.encoding and sys.stdout.encoding.lower() != 'utf-8':
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding='utf-8', errors='replace')

HERE = Path(__file__).resolve().parent          # tools/
REPO = HERE.parent                              # AP-AOS 根
SEEDS = REPO / 'rootfs' / 'seeds'

def read(p):
    return Path(p).read_text(encoding='utf-8')

def check_anchor(text, symbols, tag):
    ok = True
    for s in symbols:
        hit = s in text
        print(f'  {"OK  " if hit else "FAIL"} {tag}: {s}')
        ok = ok and hit
    return ok

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--upstream', default='D:/alas/AzurPilot')
    a = ap.parse_args()
    UP = Path(a.upstream)
    if not UP.exists():
        print(f'FAIL 上游检出不存在: {UP}')
        return 1
    print(f'上游检出: {UP}')
    green = True

    # 1) 注入锚点
    print('1) 注入锚点（alasaos_bootstrap.py 消费面）')
    anchors = [
        ('module/device/screenshot.py', ['class Screenshot', 'def screenshot_methods']),
        ('module/device/control.py', ['class Control', 'def click_methods']),
        ('module/device/app_control.py', ['class AppControl']),
        ('module/device/connection.py', ['class Connection']),
        ('module/device/connection_attr.py', ['class ConnectionAttr', 'adb_binary']),
        ('module/webui/worker_registry.py', ['_process_created_at', 'process_matches']),
        ('module/webui/process_manager.py', ['_stop_worker_locked']),
        ('module/base/decorator.py', ['class cached_property']),
    ]
    for f, syms in anchors:
        p = UP / f
        if not p.exists():
            print(f'  FAIL 文件缺失: {f}')
            green = False
            continue
        green = check_anchor(read(p), syms, f) and green

    # 2) args.json 挂载位
    print('2) args.json 挂载位（EmulatorSettings 新 / Alas.Emulator 旧）')
    args = json.loads(read(UP / 'module/config/argument/args.json'))
    for key in ('ScreenshotMethod', 'ControlMethod'):
        new = args.get('EmulatorSettings', {}).get('Emulator', {}).get(key)
        old = args.get('Alas', {}).get('Emulator', {}).get(key)
        node = new if isinstance(new, dict) else old
        ok = isinstance(node, dict) and isinstance(node.get('option'), list)
        print(f'  {"OK  " if ok else "FAIL"} {key}: {"新挂载" if new else ("旧挂载" if old else "均无")}')
        green = green and ok

    # 3) template.json 种子锚点
    print('3) template.json 种子锚点')
    tpl = json.loads(read(UP / 'config/template.json'))
    for key in ('Serial', 'PackageName', 'ScreenshotMethod', 'ControlMethod', 'ScreenshotDedithering'):
        new = tpl.get('EmulatorSettings', {}).get('Emulator', {})
        old = tpl.get('Alas', {}).get('Emulator', {})
        ok = key in new or key in old
        print(f'  {"OK  " if ok else "FAIL"} {key}: {"新挂载" if key in new else ("旧挂载" if key in old else "缺失")}')
        green = green and ok

    # 4) uv sync 闸门（模拟烘焙 root：seed 原文作为 config/deploy.yaml）
    print('4) uv sync 闸门（seed → config/deploy.yaml 行级读取）')
    sys.path.insert(0, str(UP))
    import shutil
    # 临时目录放项目内 .tmp（AGENTS.md：临时文件不进系统盘）
    root = UP / '.tmp' / 'verify-compat-root'   # 上游检出内（其 .tmp 已 gitignore，且本路径前轮实证可建）
    if root.exists():
        shutil.rmtree(root, ignore_errors=True)
    (root / 'config').mkdir(parents=True, exist_ok=True)
    (root / 'config' / 'deploy.yaml').write_text(read(SEEDS / 'deploy-azurpilot.yaml'), encoding='utf-8')
    try:
        from deploy.uv import _read_deploy_value, _deploy_bool  # noqa
        v = _read_deploy_value(root, 'InstallDependencies')
        ok = _deploy_bool(root, 'InstallDependencies', default=True) is False
        print(f'  {"OK  " if ok else "FAIL"} InstallDependencies 行值={v} → 闸门{"关" if ok else "没关"}')
        green = green and ok
        for k, want in (('WebuiPort', '22267'), ('Repository', 'auto'), ('PypiMirror', 'https://mirrors.aliyun.com/pypi/simple')):
            got = _read_deploy_value(root, k)
            ok = got == want
            print(f'  {"OK  " if ok else "FAIL"} {k}={got} (期望 {want})')
            green = green and ok
    finally:
        shutil.rmtree(root, ignore_errors=True)

    # 5) deploy 分流（真实 config_redirect）
    print('5) Repository auto 三态分流（monkeypatch 地区）')
    import deploy.config as dc
    from deploy.config import DeployConfig, CN_REPOSITORY, GITHUB_REPOSITORY
    def make():
        cfg = DeployConfig.__new__(DeployConfig)
        DeployConfig.__init__(cfg)
        object.__setattr__(cfg, '_github_location_checked', False)
        object.__setattr__(cfg, 'Repository', 'auto')
        cfg.config['Repository'] = 'auto'
        return cfg
    orig = dc.get_country_code
    for tag, cc, want in (('CN', 'cn', CN_REPOSITORY), ('海外', 'us', GITHUB_REPOSITORY), ('未知', None, GITHUB_REPOSITORY)):
        dc.get_country_code = lambda *a, cc=cc: cc
        cfg = make()
        cfg.config_redirect()
        dc.get_country_code = orig
        ok = cfg.Repository == want
        print(f'  {"OK  " if ok else "FAIL"} {tag} -> {cfg.Repository}')
        green = green and ok

    print()
    print('ALL PASS' if green else 'HAS FAILURES')
    return 0 if green else 1

if __name__ == '__main__':
    sys.exit(main())
