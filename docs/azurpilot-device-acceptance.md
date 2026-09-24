# AzurPilot 上机验收清单

**适用**：AP-AOS 换上游（ALAS → `changqing81/Azurpilot-Auto`）后的首次真机验证
**日期**：2026-09-24
**输入**：CI 产出的 `apk-debug`（rootfs 已内嵌，无需额外部署步骤）

> 本次目标只有一句话：**让你的源在手机上真正跑起来**。下面第 3 节是唯一的关键验收点。

---

## 0. 拿到 APK

在 Actions 页手动跑一次 `rootfs` workflow，勾上 `build_apk`：

```
https://github.com/changqing81/AP-AOS/actions/workflows/rootfs.yml
→ Run workflow → 勾 "同时构建 debug APK" → Run
```

跑完后在 run 页面的 **Artifacts** 区下载 `apk-debug`。

产物结构（job 内已验证）：

| 步骤 | 内容 |
|---|---|
| build | rootfs 烘焙（ubuntu-base 24.04.5 → uv python 3.14.6 → uv sync → 桥接补丁 → 裁剪 → 5 层门禁） |
| apk | 下载 rootfs artifact → 拷进 `app/app/src/main/assets/rootfs/` → `gradlew :app:assembleDebug` |

---

## 1. 安装

⚠️ **这是 debug 签名包**。如果你手机上装的是之前的**正式签名**版本，直接覆盖会**签名冲突**、安装失败。

处置：先卸载旧版（**会清掉 rootfs 与配置**，首启需重新部署），或改用一个干净的测试机。

```bash
# 需要自行准备 adb（本机当前没有 adb，见第 5 节）
adb install -r apk-debug/app-debug.apk
```

> 目标设备（AGENTS.md 记载）：`AVAY025422002864`

---

## 2. 首启部署

1. 首次启动会**流式解压 ~770MB rootfs** 到 `filesDir/rootfs`，**会慢（数分钟）**，界面有进度。别杀进程。
2. 按提示授权 **Shizuku**（特权进程用于创建虚拟屏与起桥）。
3. 等待进入主界面。

**预期**：不出现崩溃、不卡在部署页。

---

## 3. ★ 核心验收点：桥在 WebUI 里可选

进 ALAS 控制台（App 内 WebView，**端口 22267**），找到**模拟器/设备设置**区，检查这两个下拉：

| 配置项 | 期望 |
|---|---|
| `ScreenshotMethod`（截图方式） | 选项列表里有 **`ALAS-AOS 桥`** |
| `ControlMethod`（控制方式） | 选项列表里有 **`ALAS-AOS 桥`** |

**这两个下拉里能看到「ALAS-AOS 桥」= 桥真的接上了**，整个换上游方案在此成立。

> 该显示名来自 `rootfs/seeds/regen_args.py` 的 `ALASAOS_DISPLAY = 'ALAS-AOS 桥'`，
> 它同时写进 `args.json` 的 `option` 与 `module/config/i18n/zh-CN.json`。
> 构建期已实证（run `35990379139`）：
> ```
> options_patched=['Alas.Emulator.ScreenshotMethod', 'Alas.Emulator.ControlMethod']
> i18n_patched=True
> BRIDGE_OPTION_OK
> ```

**如果看不到「ALAS-AOS 桥」** → 说明补丁或 `args.json` 没生效，走第 5 节诊断。

---

## 4. 挂机验证

1. 在控制台把 `ScreenshotMethod` / `ControlMethod` 都选成 **`ALAS-AOS 桥`** 并保存。
2. 回挂机页，选配置（实例名 **`alas`**），启动。
3. **预期**：能截到游戏画面（说明桥的截图通道通）、能点击（说明控制通道通）。

### 已确认的运行面事实（供对照）

| 项 | 值 |
|---|---|
| WebUI 端口 | **22267**（上游默认 25548，已在 `deploy-azurpilot.yaml` 钉回） |
| 桥端口 | 22300 |
| 实例名 | `alas` |
| 依赖位置 | `/opt/alas-venv`（源码树外），软链 `/opt/alas/.venv` |
| 日志 | `log/alas.txt`（**注意：不再是 `2026-09-24_alas.txt` 那种命名**） |
| 错误现场 | **没有** `log/error/{毫秒}/` 目录了；错误写在日志正文里 |
| 历史日志 | 轮转进 `log/bak/` |

---

## 5. 失败诊断路径

### 5.1 桥选项不可见

按可能性排序查：

1. **App 日志中心**：看 `AlasOverlay` 的 flavor 判定结果 —— 应为 `azurpilot*`。
   若显示 `unknown` 或 `alas`，说明 `BUILD_MANIFEST.upstream_flavor` 没读到（走的是保守策略，不铺资产）。
2. **补丁是否应用**：构建期日志应有
   `Applied patch module/device/{app_control,connection,control,screenshot}.py cleanly.`
3. **args.json 是否含 alasaos**：构建期日志应有 `BRIDGE_OPTION_OK`。

### 5.2 桥 ping 不通 / 连不上设备

症状表现为「连不上设备」，但**根因常在别处**：

| 可能原因 | 查法 |
|---|---|
| 热更新后补丁被 `git reset --hard` 冲掉 | App 日志里找 `replayBridgePatch` 的结果；失败会留痕 |
| 特权进程/虚拟屏没起来 | 查 Shizuku 授权状态、App 内桥状态指示 |
| 选错了通道 | 确认下拉里选的是「ALAS-AOS 桥」而不是 ADB 之类 |

### 5.3 本机 adb 现状（重要）

**当前这台机器没有 adb 工具链** —— `where.exe adb` 为空，AGENTS.md 曾记载的
`C:\Users\da270\AppData\Local\Android\Sdk` 与 `D:\VSCodeCache\shizku-m\build-env\`
**均不存在**（2026-09-24 实测，该条记录已更正）。

所以：**装机与初步观察请在手机上直接做**。若需要 adb 诊断，需先自行准备 adb
（platform-tools）。真机调试纪律仍适用：

```bash
export MSYS_NO_PATHCONV=1        # adb shell 命令前必须
adb devices
```

---

## 6. 已知差异速查（ALAS 时代 → AzurPilot）

换上游后行为有变的地方，一次列清：

| 项 | ALAS | AzurPilot | 我方处置 |
|---|---|---|---|
| WebUI 默认端口 | 22267 | 25548 | 钉回 22267 |
| 钉版保护 | `Deploy.AutoUpdate: false` | **该键已删** | 改由 `Update.{EnableReload,CheckUpdateInterval,AutoRestartTime}` 三关 + 打包删 `.git` |
| 启动时装依赖 | `InstallDependencies` | 模板默认 **true** | 显式 false |
| 日志文件名 | `{日期}_{实例}.txt` | `log/{实例}.txt` | App 侧已适配 |
| 错误现场 | `log/error/{毫秒}/` | **无** | 「错误记录」分区自然不显示 |
| 历史日志 | 同目录 | `log/bak/` | App 侧已收进列表 |
| OCR | 我方 in-proc shim 覆盖 `rpc.py` | **原生 RapidOCR**（不覆盖） | 按冻结决策走原生；shim 留 `seeds/ocr_fallback/` 作兜底 |
| 设备通道 | 整文件覆盖补丁 | **最小 diff 补丁**（15 处插入） | 上游漂移会 `git apply` 失败即构建失败 |

---

> 本文为验收清单，随换上游进度更新。相关设计见 `docs/upstream-swap-azurpilot.md`。
