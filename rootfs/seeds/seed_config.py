#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AlasAos：由 config/template.json 生成 config/alas.json 并注入桥接配置。

在 ~/alas 根目录下运行：python seed_config.py
幂等：config/alas.json 已存在时不覆盖（改配置请走 WebUI）。
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
# 允许从任意目录运行：脚本在 termux/ 下，ALAS 根目录取 ~/alas
ALAS = os.environ.get('ALASAOS_ALAS_ROOT', os.path.expanduser('~/alas'))

SRC = os.path.join(ALAS, 'config', 'template.json')
DST = os.path.join(ALAS, 'config', 'alas.json')

# 种子覆盖项：候选路径按序命中第一个（新挂载优先，旧挂载兜底）。
#   2026-09 烘焙基线：template['Alas']['Emulator'][key]
#   2026-11 挂载重构：template['EmulatorSettings']['Emulator'][key]
#   （task.yaml：参数名不变、挂载位置变了；config_updater 有存量迁移）
OVERRIDE_CANDIDATES = [
    ('Serial', 'alasaos', [
        ('EmulatorSettings', 'Emulator', 'Serial'),
        ('Alas', 'Emulator', 'Serial'),
    ]),
    ('PackageName', 'com.bilibili.azurlane', [
        ('EmulatorSettings', 'Emulator', 'PackageName'),
        ('Alas', 'Emulator', 'PackageName'),
    ]),
    ('ScreenshotMethod', 'alasaos', [
        ('EmulatorSettings', 'Emulator', 'ScreenshotMethod'),
        ('Alas', 'Emulator', 'ScreenshotMethod'),
    ]),
    ('ControlMethod', 'alasaos', [
        ('EmulatorSettings', 'Emulator', 'ControlMethod'),
        ('Alas', 'Emulator', 'ControlMethod'),
    ]),
    # 省电与稳定：截图去抖动关闭（虚拟屏无噪点）
    ('ScreenshotDedithering', False, [
        ('EmulatorSettings', 'Emulator', 'ScreenshotDedithering'),
        ('Alas', 'Emulator', 'ScreenshotDedithering'),
    ]),
]


def main():
    if os.path.exists(DST):
        print(f'{DST} already exists, skip')
        return
    with open(SRC, encoding='utf-8') as f:
        cfg = json.load(f)
    for arg, value, paths in OVERRIDE_CANDIDATES:
        hit = None
        for path in paths:
            parent = cfg
            ok = True
            for key in path[:-1]:          # 走到目标键的父层
                if not isinstance(parent, dict):
                    ok = False
                    break
                parent = parent.get(key)
            if ok and isinstance(parent, dict) and path[-1] in parent:
                hit = path                  # 父层是 dict 且目标键真实存在 → 命中
                break
        if hit is None:
            print(f'seed_config: WARN anchor missing for {arg} (tried {paths})')
            continue
        cfg[hit[0]][hit[1]][hit[2]] = value
    with open(DST, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f'seeded {DST} with alasaos bridge config')


if __name__ == '__main__':
    sys.exit(main())
