# 2026-11-08 晚 · APK 全绿出包 + 双上游侦察收官

## CI 打包线（闭环）

| run | head | 结果 | 根因/修复 |
|---|---|---|---|
| 42479355239 | c40aae8 | ❌ | seed_config KeyError 'Emulator' → 402f748 |
| 42479793006 | 402f748 | ❌ | 门禁查旧挂载 → 49c891c |
| **42480393356** | **49c891c** | ✅ | **apk-debug 688.4MB，11-22 过期** |

**包内容**：你的 master@92c81dc（11-07 全部新功能）+ Repository=auto 分流 + Emulator 挂载重构兼容。

## 真机验收清单（待用户执行）

1. 下载 [run 42480393356](https://github.com/changqing81/AP-AOS/actions/runs/42480393356) Artifacts → apk-debug
2. 卸旧装新（debug 签名，正式签名包会冲突）
3. 验收点：
   - 部署设置页 Repository 显示 auto
   - EmulatorSettings 页截图/控制两下拉含「ALAS-AOS 桥」
   - 你的 WebUI 功能可见：委托统计/岛屿规划器/心智计算器/透明主题
   - 挂机启动、桥截图、桥控制正常

## 侦察账册

docs/upstream-recon-2026-11-08.md：wess09 线无可移植净收益（逐项实证）；Shinarin 线四条候选
（9be72778/f6eb30f9/3e8d7ee9/9a756584）**待用户拍板**。

## 本地领先远端

docs/upstream-recon-2026-11-08.md + devlog + 本 handoff 未 commit（下轮一并）。

## 追加（同日深夜）：兼容性验证脚本

**tools/verify-upstream-compat.py**（commit 54aec8e）：对本仓五段上游依赖一键实证——
①注入锚点 8/8 ②args.json 新旧挂载位 ③template.json 种子锚点 ④uv sync 闸门 ⑤auto 分流三态。
用法：`python tools/verify-upstream-compat.py`（默认上游检出 D:/alas/AzurPilot，--upstream 可改）。
实跑 ALL PASS。**以后每次 CI 出包前先跑它**，本日两轮 CI 失败（挂载重构断 seed/门禁）的教训固化。
