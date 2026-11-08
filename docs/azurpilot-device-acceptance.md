# AzurPilot-Auto 上机验收清单（v2）

**适用**：run 42480393356 起的 APK（你的 Azurpilot-Auto master + auto 分流 + Emulator 挂载重构兼容）
**日期**：2026-11-08（重写；v1 是 2026-09-24 ALAS→AzurPilot 首验版，挂载位/镜像段已过时）
**输入**：CI 产出的 apk-debug（rootfs 已内嵌）

> 目标一句话：**你的仓库在手机上完整跑起来，你的功能可见可操作**。

---

## 0. 拿包

[run 42480393356](https://github.com/changqing81/AP-AOS/actions/runs/42480393356) → Artifacts → `apk-debug`（688.4MB，11-22 过期）。

⚠️ debug 签名包：与正式签名旧版冲突，先卸旧版（**会清 rootfs 与配置**）。

## 1. 安装与首启

1. `adb install -r apk-debug/app-debug.apk`（需自备 adb；设备 AVAY025422002864，命令前 `export MSYS_NO_PATHCONV=1`）
2. 首启流式解压 ~770MB rootfs（数分钟，别杀进程）→ Shizuku 授权 → 进主界面

## 2. ★ 核心验收点

### 2.1 桥可选（构建层门禁已过，真机复验）

进 App 内 WebView 控制台（端口 22267）→ **模拟器设置**（注意：你的 master 已把模拟器参数
独立成「模拟器设置」页，不再是 Alas 页下的 Emulator 组）：

| 配置项 | 期望 |
|---|---|
| Serial（设备序列） | 可选/可填 `alasaos` |
| ScreenshotMethod（截图方案） | 选项含 **`alasaos`（显示名「ALAS-AOS 桥」）** |
| ControlMethod（控制方案） | 选项含 **`alasaos`（显示名「ALAS-AOS 桥」）** |

> 选项来自 `rootfs/seeds/regen_args.py` 每次启动现场补挂（新挂载
> `EmulatorSettings.Emulator.*` 优先、旧挂载兜底）。构建期门禁 BRIDGE_OPTION_OK
> 已实证选项在 args.json 里。

### 2.2 镜像与部署设置

| 项 | 期望 |
|---|---|
| 部署设置 Repository | 显示 `auto`（国内网络实际解析为 gitcode gcw_BYvq9jGu/AzurPilot） |
| PypiMirror | `https://mirrors.aliyun.com/pypi/simple` |
| WebuiPort | 22267（App 侧 WebView 打它） |

### 2.3 你的独特功能可见（对照桌面 AzurPilot dev）

挂机页 / 统计页逐项确认：
- 委托统计（钻石委托历史累计行、成功率区块）
- 岛屿规划器（货运缺口/优先级/鱼肉兑换/渔场）
- 心智计算器（满级筛选/批量编辑）
- 舰队科技（只看满星未确认筛选）
- 维护公告查询、队列徽标、净赚体力变色等 11-02~11-07 系列改进

## 3. 挂机验证

1. 选配置实例 `alas`，启动
2. 预期：能截到游戏画面（桥截图通道）、能点击（桥控制通道）、能停止（双头停止已修）

## 4. 已知差异速查（AzurPilot 特性）

| 项 | 值 |
|---|---|
| WebUI 端口 | 22267（seed 钉死） |
| 桥端口 | 22300 |
| 实例名 | `alas` |
| 依赖位置 | /opt/alas-venv（源码树外软链） |
| 日志 | `log/alas.txt`（无 `log/error/{毫秒}/` 目录，错误在正文） |
| 更新 | 全关（.git 已删、Update 三关、CloudUpdateControl null）——版本由换 APK 升级 |

## 5. 失败诊断

| 症状 | 查 |
|---|---|
| 桥选项不在下拉 | App 日志中心找 `regen_args` 行（`options_patched=`）与 `alasaos_bootstrap.log`；确认 `AlasOverlay` flavor=azurpilot* |
| 桥 ping 不通 | Shizuku 授权状态；特权进程/虚拟屏指示 |
| 启动即崩 `uv sync` | 不应发生（InstallDependencies=false 门禁已实证）；若发生查 deploy.yaml 是否被外力改写 |
| 纯启动/卡死分账 | 参考 commit a1843bba08（你的 master 已修）——先看崩溃类别 |

> 本文随验收反馈更新。构建层证据链见 handoff/2026-11-08-anchor-refactor-fix.md 与
> docs/upstream-recon-2026-11-08.md。
