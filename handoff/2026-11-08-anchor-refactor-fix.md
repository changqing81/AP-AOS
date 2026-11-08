# 2026-11-08 晚 · Emulator 挂载重构兼容修复 + CI 打包

## 背景

push e5eadcc..c40aae8 后触发 CI 打包（run 42479355239），build job 在「运行时就绪冒烟」步失败：
`seed_config.py KeyError: 'Emulator'`。

## 根因

**你的 Azurpilot-Auto master 把模拟器参数挂载位重构了**：
- args.json / template.json：`Alas.Emulator.*` → `EmulatorSettings.Emulator.*`
- task.yaml 注释明说「参数名不变（Emulator_Serial 等），只是挂载位置变了」
- **AP-AOS 两个 seed 脚本锚死旧挂载位**：
  - `seed_config.py` OVERRIDES 写 `cfg['Alas']['Emulator'][key]` → 构建期 KeyError（CI 实证）
  - `regen_args.py` 补挂 `args['Alas']['Emulator'][key]` → 设备上 WARN 静默跳过 → 「ALAS-AOS 桥」选项从下拉消失
- i18n 两代顶层都是组名 `Emulator`，**没断**
- bootstrap 注入锚点（config 属性 Emulator_Serial / screenshot_methods / click_methods 等）**没断**（8/8 审计过）

## 修复（commit 402f748）

| 文件 | 改法 |
|---|---|
| rootfs/seeds/regen_args.py | ALASAOS_OPTION_PATHS 候选路径列表（新挂载优先，旧挂载兜底）；i18n 单独 I18N_KEYS |
| rootfs/seeds/seed_config.py | OVERRIDE_CANDIDATES 同款策略；命中判定=「父层 dict 且目标键存在」 |

## 验证（本机 AzurPilot venv，模拟 /opt/alas 布局端到端）

- regen_args 实跑：`options_patched=['EmulatorSettings.Emulator.ScreenshotMethod', 'EmulatorSettings.Emulator.ControlMethod'] i18n_patched=True`，option 末尾出现 alasaos，i18n 显示名「ALAS-AOS 桥」
- seed_config 实跑：五项种子（Serial/PackageName/ScreenshotMethod/ControlMethod/ScreenshotDedithering）全部写进 EmulatorSettings.Emulator

## CI 打包线（进行中）

| run | 触发 | 结果 |
|---|---|---|
| 42479355239 | 手动 dispatch（build_apk）@ c40aae8 | ❌ build 失败（本次修复的 bug） |
| 42479793006 | 手动 dispatch（build_apk）@ 402f748 | 🔄 进行中 |

**build job 基线约 40 分钟，apk job 追加约 8 分钟**；产物 apk-debug artifact（保留 14 天）。

## 下一步

1. 等 run 42479793006 完成；apk job 绿 → 下载 apk-debug 真机装包验收
2. 真机验收点：部署设置页 Repository=auto；EmulatorSettings 页两下拉含「ALAS-AOS 桥」；你的 WebUI 功能（委托统计/岛屿规划/心智计算器）可见可操作
