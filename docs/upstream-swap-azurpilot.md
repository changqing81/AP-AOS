# 上游替换方案（讨论稿）：ALAS → Azurpilot-Auto

> 状态：**方案讨论，未落地任何代码**。
> 日期：2026-09-24
> 输入：本仓（`changqing81/AP-AOS`）现状 + 目标仓 `changqing81/Azurpilot-Auto@master` 只读源码核查。
> 结论先行：**技术上可行，但代价集中在「依赖与 Python 版本」这一条生死线上**，其余是可控的工程量。

---

## 0. 一句话结论

AP-AOS 与 ALAS 的耦合是**深但收敛**的——总共 5 种形态、9 个整文件补丁、约 4900 行。换成 Azurpilot-Auto 后：

- **设备通道层（最核心的桥）几乎原样可用**：Azurpilot 保留了与 ALAS 完全一致的「加文件 + 改 MRO + 加分派项」扩展点，`alasaos.py` 是新增文件，不吃上游版本。
- **9 个整文件补丁必须全部重做**：它们是「上游某 commit 的整份文件副本 + 改动」，Azurpilot 这些文件已大幅漂移，直接覆盖等于**回退 Azurpilot 的功能**。
- **三个机制级地雷**：① Python 版本要求 3.14（本仓是 3.12）；② 部署模型强绑 uv + 项目内 `.venv`（本仓是系统级 pip）；③ `AutoUpdate` 键被删除 → 现有「钉版保护」的唯一闸门消失。
- **App（Kotlin）层几乎零改动**：这是本仓架构最值钱的地方，替换成本主要落在 rootfs 与补丁集。

---

## 1. AP-AOS 是什么，与 ALAS 什么关系

### 1.1 定位

`ALAS-AOS` = **ALAS on Android OS**。把《碧蓝航线》自动化脚本 ALAS（Python）打包进一台**免 root** 的 arm64 Android 手机，游戏跑在**后台虚拟屏**里挂机，主屏正常使用。

三层进程模型（这是理解一切耦合的前提）：

```
App 进程（Kotlin / Compose，appId=io.github.shinarin.alasaos）
  ├─ WebView  → http://127.0.0.1:22267   （ALAS 原生 WebUI）
  ├─ HTTP     → http://127.0.0.1:22400   （wrapper.py 薄控制层）
  └─ AIDL     → Shizuku 特权进程
特权进程（Shizuku 拉起，shell uid）
  ├─ 后台虚拟屏 1280×720 + 截屏/触控注入
  └─ 桥服务 :22300（ping/screencap/click/swipe/shell）
proot Ubuntu rootfs（App 私有目录，免 root）
  └─ wrapper.py → runner.py（ALAS 调度器）→ gui.py（WebUI）→ 桥 → 虚拟屏里的游戏
```

### 1.2 仓库结构地图

| 目录 | 职责 | 与本次替换的关系 |
|---|---|---|
| `app/` | MaaFwApp fork 复活副本（Kotlin 外壳）；`assets/alas/` 是补丁与 overlay 的**第二份源** | 改动最小 |
| `rootfs/build/build-rootfs.sh` | GHA ARM64 runner 上 chroot 烘焙 rootfs | **必须改**（换上游、换 base、换依赖） |
| `rootfs/patches/` | ALAS 补丁集（9 个整文件 + 新增插件 + 素材 + assets_fix.py） | **重做主体** |
| `rootfs/overlays/` | wrapper.py / runner.py / OCR 的 in-proc 版 | runner 基本可用；OCR 需重设计 |
| `rootfs/seeds/` | deploy.yaml / 实例播种 / 热更新 / args 再生 / 环境自检 | 大部分需重写 |
| `rootfs/models/`、`rootfs/shims/` | PP-OCR 模型、jellyfish shim | 视 OCR 方案决定去留 |
| `docs/`、`handoff/`、`devlog.md`、`debug.md` | 账册体系 | 沿用 |

### 1.3 与 ALAS 的耦合：5 种形态

这是本次评估的核心表。**补丁越"重"，换上游的代价越高**：

| # | 形态 | 具体做法 | 换上游的代价 |
|---|---|---|---|
| ① | **新增文件** | `module/device/method/alasaos.py`（自包含的 TCP 桥客户端） | ✅ **零代价**（不吃上游版本） |
| ② | **类混入（MRO）** | `class Screenshot(AlasAos, Adb, WSA, DroidCast, ...)`、`class Control(AlasAos, Hermit, Minitouch, ...)`、`class AppControl(AlasAos, Adb, WSA, Uiautomator2)` | ⚠️ 锚点会变，需重做但改法简单 |
| ③ | **分派表注册** | 往 `screenshot_methods` / `click_methods` 加 `'alasaos': self.xxx_alasaos` | ⚠️ 同上 |
| ④ | **整文件覆盖** | `connection.py`(1267 行)、`screenshot.py`(280)、`control.py`(191)、`app_control.py`(100)、`base.py`(488)、`minitouch.py`(725)、`method/utils.py`(512)、`map_detection/utils.py`(395)、`webui/patch.py`(177)、`webui/utils.py`(571) | 🔴 **全部重做**——覆盖即回退 Azurpilot 改动 |
| ⑤ | **配置/资产注入** | `regen_args.py` 往 args.json 补 `alasaos` 选项；`assets_fix.py` 按 Button 名改素材；`seed_config.py` 播种实例 | 🟡 机制可复用，键名/素材需重新校准 |

**关键洞察**：① 是这个项目最聪明的设计——桥客户端是**新文件**，所以「驱动层」与「上游版本」解耦。真正贵的是 ④ 那 10 个整文件补丁。

---

## 2. 目标仓库 Azurpilot-Auto 是怎么组织的

### 2.1 谱系与基本盘

```
LmeSzinc/AzurLaneAutoScript（ALAS 本体，GPL-3.0）
   └─ wess09/AzurPilot（269★，原始改造版）
        └─ Maratrain/AzurPilot（一级 fork）
             └─ changqing81/Azurpilot-Auto（本目标，二级 fork，GPL-3.0）★ 活跃，2026-09-24 仍在推
```

- 描述自称：**「AzurLaneAutoScript 的修改版 AzurPilot 的修改版」**
- 支持 **CN / EN / JP / TW 四服**；README 明确声明**代码大量由 AI 生成**，自评「屎山指数 88.95」
- 官网 `alas.nanoda.work`；国内镜像 `gitcode.com/gcw_BYvq9jGu/AzurPilot`（master，11.76K commits）

### 2.2 目录结构（顶层）

```
alas.py（102KB，核心）      gui.py（39KB，WebUI 入口）   mcp_server_sse.py（MCP 服务，:22268）
pyproject.toml（uv 管理）   Dockerfile / docker-compose.yml
module/     ← 核心模块（webui/ 已从 1 个 app.py 拆成 59 个文件）
webapp/     ← pnpm workspace 前端（Vue/TS，含 packages/renderer/）
campaign/   ← 100+ 活动地图数据包（.py，体积小）
bin/        ← 推送到手机的 Android 侧 APK/JAR + OCR 模型（~120MB，体积大头）
deploy/     ← 部署/更新（键名已大改）
config/     ← template.json（115KB）等
assets/ submodule/ switch/ tests/ dev_tools/ doc/ licenses/ wallpapers/
```

### 2.3 相对 ALAS 的关键差异（只列影响替换的）

| 维度 | ALAS（本仓现用） | Azurpilot-Auto | 影响 |
|---|---|---|---|
| Python | 3.12（Ubuntu 24.04） | **`requires-python = ">=3.14.6,<3.15"`** | 🔴 直接冲突 |
| 依赖管理 | 系统级 `pip --break-system-packages`，手工钉版 | **uv + 项目内 `.venv`**；`deploy/config.py` 里 `PythonExecutable` 默认指向 `./.venv/...`；**无 requirements.txt、无 uv.lock（被 gitignore）** | 🔴 范式冲突 |
| OCR | m0 移植的 in-proc PP-OCR（`rpc.py` shim + 自备模型） | **RapidOCR 3.9.0 / PP-OCRv6**，自带 `rpc.py`；默认 `UseOcrServer=false`（进程内）；模型入库 ~120MB | 🟡 可改用原生，省掉 shim |
| WebUI | pywebio 单 `app.py`，端口 22267 | pywebio 拆分 59 文件 + `fastapi.py`/`api.py`；**默认端口 25548**；另有 Vue 前端 `webapp/` | 🟡 端口可用 deploy.yaml 钉回 22267 |
| WebUI 启停按钮 | `module/webui/app.py` 绑 `self.alas.stop()` / `start(None, ev)` | 迁到 `app_overview.py`，API 改为 `stop_by_user()` / `start(task)` | 🟡 锁定补丁需重做 |
| 进程模型 | `ProcessManager`（start/stop/alive/state） | 同名类保留，但新增 `worker_registry.py`（PID 登记 + 孤儿回收 + `./cache/webui-workers.json`）、`app_lifecycle.py`、`app_shell.py` | 🟡 需复核 wrapper 的双头管理假设 |
| deploy 键 | `AutoUpdate:false` 是保住钉版的**唯一闸门** | **`AutoUpdate` 已删除**，改为 `CloudUpdateControl` + `GitOverCdn` | 🔴 钉版保护机制失效 |
| URL 改写 | `config_redirect()` 把 gitee 改写成 `git.lyoko.io` | 仍会静默改写旧 gitee/lyoko 类 URL → `git://git.pull/AzurPilot`；`Repository='auto'` 时 CN 地区自动选 **gitcode 镜像** | 🟡 不能写旧 URL |
| 日志 | `./log/{日期}_{name}.txt` + **`./log/error/{毫秒}/` 错误现场** | `./log/{日期}_{name}.txt` + 午夜轮转进 `./log/bak/`；**`log/error/` 已消失** | 🔴 App 的 ALAS 日志页「错误记录」分区会空 |
| 端口 | 22267(WebUI) / 22300(桥) / 22400(wrapper) / 22268(OCR) | WebUI 25548、MCP 22268、OCR 22268 | 🔴 **22268 被 MCP 与 OCR 双重占用** |
| 仓库体积 | 小 | **~1.04GB**（含历史）；HEAD 内 ~120MB OCR 模型 + assets | 🔴 热更新成本 |
| 遥测 | 无 | README 明示会上报侵蚀统计 + 设备 ID(SHA256) + IP，**开关键名与默认值未披露** | 🟡 需定位并关闭 |

### 2.4 好消息：扩展点全部保留

核查确认，Azurpilot **完整保留**了本仓赖以生效的全部扩展点：

- `module/device/method/` 下仍有 `ascreencap.py` / `ldopengl.py` / `nemu_ipc.py` / `hermit.py` / `wsa.py` / `droidcast.py` → **通道插件机制与 ALAS 一致**
- `module/device/connection.py` 的 `detect_device / adb_connect / detect_package / check_mumu_app_keep_alive` 四个调用**都在**
- `connection_attr.py` / `env.py` / `method/pool.py` / `method/remove_warning.py` / `method/utils.py` **全部存在，无重命名**
- `argument.yaml` 里 `Alas.Emulator.ScreenshotMethod` / `ControlMethod` **仍在**，可加 `alasaos` 候选值
- `config_updater.py` 的 `__main__` 生成链**仍在** → `regen_args.py` 的「现场再生」思路可沿用
- `config/template.json` **仍在** → `seed_config.py` 播种思路可沿用
- `alas.py` 里 `class AzurLaneAutoScript` 的 `loop()` / `run(command, skip_first_screenshot=)` / `device` / `stop_event` **全部保留** → `runner.py` 的调用形态**基本不用改**

---

## 3. 逐项对表：哪些能直接用，哪些必须重做

| 文件 | 形态 | 判定 | 说明 |
|---|---|---|---|
| `patches/module/device/method/alasaos.py` | 新增 | ✅ **直接复用** | 唯一要改：`screenshot_methods`/`click_methods` 在 Azurpilot 里变成了 `@cached_property`；`AppControl` 无分派字典（按 `Emulator_ControlMethod` 分支） |
| `patches/module/device/connection.py` | 整文件 | 🔴 **重做** | Azurpilot 新增 `is_over_http` 分支，短路锚点变了 |
| `patches/module/device/screenshot.py` | 整文件 | 🔴 **重做** | MRO 前插 + 字典注册，写法要适配 cached_property |
| `patches/module/device/control.py` | 整文件 | 🔴 **重做** | 同上 |
| `patches/module/device/app_control.py` | 整文件 | 🔴 **重做** | 无字典，改分支判断 |
| `patches/module/device/method/minitouch.py` | 整文件 | 🟡 **先复核后重做** | 原为 u2>=3 兼容 shim；Azurpilot 自己可能已适配 |
| `patches/module/device/method/utils.py` | 整文件 | 🟡 **先复核后重做** | 同上 |
| `patches/module/base/base.py` | 整文件 | 🔴 **重做** | `early_ocr_import` 预热逻辑基于旧 OCR 栈，需按新栈重写 |
| `patches/module/map_detection/utils.py` | 整文件 | ⚪ **大概率可删** | numpy2 `vstack` 修复；Azurpilot 已用 numpy 2.4.6，上游多半已修 |
| `patches/module/webui/patch.py` | 整文件 | 🟡 **复核** | Azurpilot 有自己的 `patch.py`，可能已含同类修复 |
| `patches/module/webui/utils.py` | 整文件 | 🟡 **复核** | pywebio `TaskHandler.stop` 修复，同上 |
| `patches/assets/cn/*.png` + `assets_fix.py` | 资产 | 🟡 **重新校准** | Azurpilot 改了大量 UI，素材要按真机重录；**`assets_fix.py` 的「按名修补」机制本身可复用** |
| `overlays/module/ocr/rpc.py` + `al_numpy.py` + `models/` | 替换 | 🟡 **重新决策** | 优先改用 Azurpilot 原生 in-proc OCR（`UseOcrServer=false`），弃用 m0 shim；若不成立再移植 |
| `overlays/runner.py` | 新增 | ✅ **基本复用** | 只改错误提示文案与黑帧判定常量引用 |
| `overlays/wrapper.py` | 新增 | ✅ **基本复用** | 完全不 import ALAS，与上游解耦 |
| `seeds/deploy.yaml` | 配置 | 🔴 **重写** | `AutoUpdate` 已删、`RequirementsFile` 路径失效、新增 `CloudUpdateControl`/`GitOverCdn` |
| `seeds/alasaos_update.sh` | 脚本 | 🔴 **重写** | REPO 换源；CDN 增量包通道（复刻 ALAS `git_over_cdn` 协议）对 Azurpilot **不适用** |
| `seeds/regen_args.py` | 脚本 | ✅ **基本复用** | 生成链与 args.json 结构都还在，改 option 值即可 |
| `seeds/seed_config.py` | 脚本 | 🟡 **复核** | OVERRIDES 的 4 个键需在 Azurpilot 的 template.json 里确认仍在 |
| `seeds/env_fix.sh` | 脚本 | 🟡 **复核** | imageio 钉版是否还必要（依赖栈已换）、`template.py` 白名单还原是否还成立 |
| `shims/jellyfish.py` | shim | 🟡 **复核** | 视 Azurpilot 是否仍依赖 jellyfish |
| `build/build-rootfs.sh` | 构建 | 🔴 **大改** | 上游源、rootfs base、Python 版本、依赖清单、uv 引入 |
| `app/.../AlasOverlay.kt` | Kotlin | ✅ **微调** | MAPPINGS/STALE_FILES 路径不变，增删条目即可 |
| `app/.../AlasUpdater.kt` | Kotlin | ✅ **零改动** | 三态协议 UPDATED/UNCHANGED/FAILED 不变 |
| `app/.../ProotHost.kt` | Kotlin | ✅ **零改动** | 启动链与 `/opt/alas` 路径约定不变 |
| `app/.../AlasLogSource.kt` / `AlasLogScreen.kt` | Kotlin | 🟡 **小改** | 「错误记录」分区依赖 `log/error/<ms>/`，需改为适配 `log/bak/` 或直接下线该分区 |
| `app/.../AlasControlPanel.kt` / WebView | Kotlin | ✅ **零改动** | 端口靠 deploy.yaml 钉回 22267 |

**统计**：零/微改动 8 项，复核 8 项，重做 9 项，新增决策 2 项。**重做主体是 9 个整文件补丁。**

---

## 4. 替换方案设计

### 4.1 总体思路（三层解耦）

把「上游」从一个**写死的假设**变成一个**构建期参数**，并把补丁从「整文件覆盖」升级为「最小 diff」：

```
┌─ 第 1 层：上游参数化（构建期）─────────────────────────┐
│  build-rootfs.sh 的 ALAS_REPO / ALAS_REF 已是参数       │
│  → 扩展为 UPSTREAM_REPO / UPSTREAM_REF / UPSTREAM_FLAVOR│
│  → deploy.yaml 与热更新脚本的源同源派生                  │
└──────────────────────────────────────────────────────┘
┌─ 第 2 层：补丁形态升级（核心工作量）───────────────────┐
│  现状：整文件副本（= 钉死在某个上游 commit）             │
│  目标：最小 diff 补丁（patch 文件 / 结构化注入）          │
│  → 上游漂移时不再静默回退，而是「冲突可见」               │
└──────────────────────────────────────────────────────┘
┌─ 第 3 层：驱动层保持新增文件（不动）───────────────────┐
│  alasaos.py（桥客户端）+ wrapper.py + runner.py         │
│  → 与上游无关，是本次能低成本换源的根本原因               │
└──────────────────────────────────────────────────────┘
```

### 4.2 三个候选方案

| 方案 | 做法 | 优点 | 缺点 | 建议 |
|---|---|---|---|---|
| **A. 整体换源** | ALAS 彻底换成 Azurpilot-Auto，旧补丁全部重做 | 架构最干净；能吃到 Azurpilot 全部新功能（岛屿计划、大世界智能调度、四服） | 一次性投入大；放弃 ALAS 官方上游的更新 | ⭐ **推荐**（用户意图明确是「替换」） |
| **B. 双引擎可切换** | 构建期 `UPSTREAM_FLAVOR=alas\|azurpilot`，两套补丁集并存 | 可回退、可 A/B 对比 | 补丁集翻倍维护；两套依赖栈；rootfs 体积翻倍 | 仅作为 A 的**过渡态**（M2 期间保留 ALAS 分支做对照） |
| **C. 只做抽象不换源** | 把补丁重做成最小 diff，但上游仍留 ALAS | 风险最低，为将来换源铺路 | 不满足用户「换成我自己的仓库」的诉求 | 作为 A 的**第 1 步**执行 |

**建议路径**：以 **A** 为目标，但按 **C 的手法**推进——先把补丁形态升级 + 上游参数化（低风险、可验证），再切源。M2 期间用方案 B 的形态保留 ALAS 分支做回归对照，切源成功后删除。

### 4.3 分层改造清单

**第 1 层 · 构建层（`rootfs/build/build-rootfs.sh`）**
1. rootfs base：`ubuntu-base-24.04` → **`ubuntu-base-26.04`**（Python 3.14；这是解 Python 版本冲突最干净的路）
2. 上游源：`ALAS_REPO` 默认值 → Azurpilot-Auto；`ALAS_REF` → `master`（构建时解析并写入 BUILD_MANIFEST 钉 commit）
3. 依赖安装：引入 **uv**（aarch64 有官方静态二进制），按 `pyproject.toml` 解析安装到 `/opt/alas/.venv`；`deploy/config.py` 的 `PythonExecutable` 指向该 venv
4. `require_file` 清单同步增删（新增 Azurpilot 侧必需资产，删掉失效项）
5. BUILD_MANIFEST 字段名保持（App 可读），值语义改为 Azurpilot 的 commit

**第 2 层 · 补丁层（`rootfs/patches/`）**
1. `alasaos.py` 落盘（适配 cached_property 分派字典 + AppControl 分支）
2. 9 个整文件补丁 → 以 Azurpilot master 为基线重做，改为**最小 diff**（建议落成 `.patch` 文件 + 构建期 `git apply`，冲突即构建失败，而不是静默覆盖）
3. `assets_fix.py` 机制保留，`FIXES` 表按 Azurpilot 真机重新校准
4. `map_detection/utils.py`、`webui/patch.py`、`webui/utils.py` 先复核，能删则删

**第 3 层 · 运行面（`rootfs/seeds/` + `overlays/`）**
1. `deploy.yaml` 重写：钉 `WebuiPort: 22267`、关 `UseOcrServer`/`StartOcrServer`、关 MCP、**重建钉版保护**（替代被删的 `AutoUpdate:false`）、`Repository` 显式填 URL（不能写 gitee/lyoko，会被静默改写）
2. `alasaos_update.sh` 重写：源改 Azurpilot；CDN 增量通道失效 → 降级为 `git ls-remote` + `fetch --depth 1`；**先做体积评估**（浅树仍含 ~120MB OCR 模型）
3. `regen_args.py` 基本复用（改 option 值 + 确认 args.json 结构）
4. `seed_config.py` / `env_fix.sh` / `shims/jellyfish.py` 复核后调整
5. OCR：改用 Azurpilot 原生 in-proc 路径，删掉 m0 的 `rpc.py` shim 与自备模型（或保留作为降级）

**第 4 层 · App 层（`app/`）**
1. `AlasOverlay.MAPPINGS` / `STALE_FILES` 增删条目
2. `AlasLogSource` / `AlasLogScreen` 的「错误记录」分区适配 `log/bak/`（或下线）
3. 文案与命名（`ALAS` → `AzurPilot`？需用户决策）

---

## 5. 关键改动点：逐文件清单

### 5.1 必须新增/重做的文件（按优先级）

| 优先级 | 文件 | 动作 |
|---|---|---|
| P0 | `rootfs/build/build-rootfs.sh` | base 换 26.04；上游源参数化；uv 引入；依赖清单重建 |
| P0 | `rootfs/seeds/deploy.yaml` | 重写；**重建钉版保护**；端口钉 22267；关 MCP/OCR server |
| P0 | `rootfs/patches/module/device/connection.py` | 最小 diff 重做（桥接短路） |
| P0 | `rootfs/patches/module/device/screenshot.py` / `control.py` / `app_control.py` | 最小 diff 重做（MRO + 分派） |
| P1 | `rootfs/patches/module/base/base.py` | 按新 OCR 栈重写预热逻辑 |
| P1 | `rootfs/seeds/alasaos_update.sh` | 换源 + CDN 通道降级 |
| P1 | OCR 方案落地（`overlays/module/ocr/*` + `models/`） | 改用原生 or 保留 shim（二选一） |
| P2 | `rootfs/patches/assets_fix.py` + `patches/assets/cn/*.png` | 真机重新校准 |
| P2 | `rootfs/seeds/seed_config.py` / `env_fix.sh` / `shims/jellyfish.py` | 复核后调整 |
| P2 | `app/.../AlasOverlay.kt` / `AlasLogSource.kt` / `AlasLogScreen.kt` | 微调 |
| P3 | `rootfs/patches/module/map_detection/utils.py` / `webui/patch.py` / `webui/utils.py` | 复核后可能删除 |
| P3 | 文案与命名 | 待决策 |

### 5.2 完全不用动的文件（架构红利）

- `rootfs/overlays/wrapper.py` —— 本体完全不 import ALAS，只 subprocess 拉 runner
- `rootfs/overlays/runner.py` —— `from alas import AzurLaneAutoScript` + `loop()`/`run()` 调用形态在 Azurpilot 里**原样保留**
- `app/.../AlasUpdater.kt` —— 三态协议不变
- `app/.../ProotHost.kt` —— 启动链（env_fix → seed_config → update → regen_args → spawn proot）不变
- `app/.../AlasControlPanel.kt` + WebView 容器 —— 只要端口钉回 22267
- 整个特权进程 / 虚拟屏 / 桥（Kotlin 侧 22300）—— 与上游完全无关

---

## 6. 红色风险与前置 Spike

**在动任何代码之前，必须先跑通这三个 Spike。任一不过，方案需要重新设计。**

| Spike | 问题 | 不过的后果 |
|---|---|---|
| **S1 · Python 3.14 依赖可装性**（🔴 最大生死线） | rootfs 换 26.04 后，`pyproject.toml` 里 `ncnn` / `onnxruntime==1.27.0` / `numba==0.66.0` / `rapidocr==3.9.0` / `zerorpc` / `aiortc` 在 **aarch64 + Python 3.14** 上能否装成？uv 是否必须（无 uv.lock）？ | 装不上则方案不成立，需考虑裁剪依赖或换上游版本 |
| **S2 · 原生 OCR 在 proot 里能跑吗** | RapidOCR + PP-OCRv6（onnxruntime CPU）在 proot aarch64 上能否推理？精度对得上本仓的油数验收线吗？ | 不过则退回移植 m0 的 in-proc shim（工作量 +1） |
| **S3 · 最小可运行闭环** | `alas.loop()` 能否在 rootfs 里起来、WebUI 能否在 22267 出页面、桥能否 ping 通（**先不接游戏**）？ | 不过则说明补丁重做有遗漏，需回查 |

**其余风险（已知，可控）**

| 风险 | 等级 | 缓解 |
|---|---|---|
| 9 个整文件补丁重做时遗漏上游新逻辑 | 🟠 | 改最小 diff + `git apply` 冲突即失败，禁止静默覆盖 |
| `AutoUpdate` 键被删导致钉版失效 | 🟠 | 显式关掉 `CloudUpdateControl` / `GitOverCdn`；热更新只走自有脚本 |
| 22268 端口被 MCP 与 OCR 双重占用 | 🟠 | deploy.yaml 里关 MCP、OCR 换端口或关服务 |
| 仓库 1GB / 浅树仍含 120MB 模型 → 热更新成本 | 🟠 | 先实测浅克隆体积；必要时降级为「随 APK 发版」 |
| 遥测默认开启（侵蚀统计 + 设备 ID + IP） | 🟠 | 定位配置键并强制关闭；本仓面向用户需合规 |
| Vue 前端 `webapp/` 是否需要 Node 构建 | 🟡 | 待确认；若需要，rootfs 无 Node 会炸（renderer 只提交了 `src/`，未见 `dist/`） |
| Azurpilot 代码质量（AI 生成、自评屎山 88.95） | 🟡 | 提高真机回归测试密度 |
| 许可：Azurpilot 是 GPL-3.0，本仓 AGPL-3.0 | 🟢 | 与现状同构（本仓本就含 ALAS GPL-3.0 补丁），署名义务照旧 |

---

## 7. 建议的推进顺序

```
M0 前置 Spike（S1/S2/S3）           ← 不通过不动手
      ↓
M1 构建层参数化 + 换 base            ← rootfs 26.04 + uv + 上游参数化
      ↓
M2 补丁形态升级（先对 ALAS，后对 Azurpilot）  ← 核心工作量；期间保留双分支对照
      ↓
M3 运行面适配（deploy/热更新/OCR/配置）      ← 最小可运行闭环（S3 复跑）
      ↓
M4 App 侧收尾 + 真机回归             ← 日志页、文案、长稳
```

**M2 是唯一的重活**，建议做法：先以 Azurpilot master 为基线把 9 个整文件补丁转成最小 diff（此时不切源，ALAS 分支仍可跑，可随时回归对照），验证通过后再执行切源。

---

## 8. 已确认决策（2026-09-24 用户拍板）

| # | 决策项 | 结论 | 直接后果 |
|---|---|---|---|
| 1 | 替换范围 | **彻底更换**（方案 A） | ALAS 出局；9 个整文件补丁以 Azurpilot master 为基线重做；双分支对照仅作 M2 期间的过渡手段，切源成功后删除 |
| 2 | rootfs base | **接受升级到 Ubuntu 26.04 LTS** | `ubuntu-base-24.04` → `26.04`，Python 3.12 → 3.14；**等于重建整个 rootfs 环境**，apt 包名、系统库、pip 行为都需重新验 |
| 3 | 热更新 | **保留设备端热更新** | 必须解决「1GB 仓库 + 浅树仍含 ~120MB OCR 模型」的体积问题；原 CDN 增量包通道对 Azurpilot 不适用，需重设计（见 §9） |
| 4 | 命名 | **改为 `AP-AOS`** | 需分级处理，`appId` 改动会断升级链（见 §10） |
| 5 | 服务器范围 | **先定 CN（国服）** | 沿用 `com.bilibili.azurlane`；Azurpilot 的 EN/JP/TW 资源与分支逻辑先不启用、不实测 |
| 6 | OCR 路线 | **原生为主 + 保留 in-proc PP-OCR 兜底** | 双通道：默认走 Azurpilot 原生 RapidOCR/PP-OCRv6；保留本仓 in-proc PP-OCR 作为降级路径（需做成可切换开关，见 §11） |

---

## 9. 热更新方案（决策 #3 展开）

现状通道对本仓失效的原因：`seeds/cdn_update.py` 复刻的是 **ALAS 官方 `git_over_cdn` 协议**（`latest.json` + `{latest}/{current}.zip` 增量 pack，托管在 ALAS 的 CDN 上）。Azurpilot 的对应物是 `CloudUpdateControl` + `GitOverCdn`，指向 `git://git.pull/AzurPilot`，**协议与托管方都不同**，不能直接复用。

候选路线（按推荐度）：

| 路线 | 做法 | 代价 |
|---|---|---|
| **T1 · 双通道：自有 CDN 增量包**（推荐） | 复用 `cdn_update.py` 的机制，把 pack 源换成本仓自己托管的静态目录（GHA 定时构建「Azurpilot commit → 增量 zip」） | 需自建构建任务 + 托管位；换来「常态零下载」 |
| T2 · 纯 git 浅拉 | `git ls-remote` 比对 → 需要才 `fetch --depth 1` | 实现最简；但每次真更新要下整棵浅树（含 ~120MB OCR 模型） |
| T3 · 排除大目录的稀疏检出 | `git sparse-checkout` 排除 `bin/ocr_models`、`assets` 等 | 需实测 Azurpilot 是否能在缺这些目录时启动（OCR 模型在 `bin/` 里） |

**待办**：M0 阶段先实测 T2 的浅树体积（决定 T1 是否必要）；同时确认 `bin/ocr_models/` 是否可从热更新中排除（若 OCR 模型必须随源更新，则 T3 不成立）。

---

## 10. 改名方案（决策 #4 展开）：`AP-AOS`

改名必须**分级**做，否则会踩三个坑：① `appId` 一改，老用户无法覆盖安装、且 App 私有目录换路径 → rootfs 需重新部署（约 300MB）；② 桥接标识符（`ALASAOS_*` 环境变量、`alasaos` serial、`alasaos.py` 文件名、`AlasAos` 类名）是 rootfs 与 `app/assets/alas/` **双源同步**的，改一处必须两边同改；③ v0.1.3 已经做过一次全量断代更名（`maaal` → `alasaos`），有成熟套路可循。

| 级别 | 范围 | 成本 | 建议 |
|---|---|---|---|
| **L1 · 用户可见身份** | `README.md`、`CHANGELOG.md`、`docs/`、Release 标题与资产名（`AP-AOS-v<x>-android-arm64.apk`）、应用显示名（`strings.xml` 的 `app_name`） | 低 | **本次就做** |
| **L2 · 内部标识符** | `ALASAOS_*` → `APAOS_*`；`alasaos` serial → `apaos`；`alasaos.py` → `apaos.py`；`AlasAos` 类 → `ApAos`；`AlasOverlay`/`AlasUpdater`/`AlasLogSource` 等 Kotlin 类名；`log/alasaos_*` 等 | 中（双源同步 + 一次断代迁移） | **与 M2 补丁重做合并做**（反正补丁要重写，顺手改代价最低） |
| **L3 · `appId`** | `io.github.shinarin.alasaos` → 新包名 | **高**：断升级链、rootfs 重部署、外部私有目录路径变化、`provider_paths.xml`/FileProvider、`RemoteBootTrace` 硬推导路径 | **建议暂缓**，作为独立版本发布并配迁移说明；需用户单独确认 |

> ⚠️ 建议：L1 立即做，L2 随 M2 做，L3 单独立项。若 L3 与 L2 同时做，一次断代迁移即可覆盖，但用户侧代价（重装 + 重部署）无法避免。

---

## 11. OCR 双通道方案（决策 #6 展开）

```
                        ┌─ 主通道：Azurpilot 原生 ───────────────────┐
   ALAS OCR 调用面 ──►  │ RapidOCR 3.9.0 / PP-OCRv6，进程内推理       │
                        │ UseOcrServer=false（默认）                  │
                        └────────────────────────────────────────────┘
                        ┌─ 兜底通道：本仓 in-proc PP-OCR（保留）─────┐
                        │ overlays/module/ocr/rpc.py（m0 shim）       │
                        │ + models/ocr/{det,rec}.onnx + keys.txt      │
                        └────────────────────────────────────────────┘
```

要点：
1. 两套 OCR 的**调用面**都落在 `module/ocr/` 上，但 Azurpilot 自带 `rpc.py`（含 `start_ocr_server(port=22268)`、zerorpc 路径）→ 我方 shim 若覆盖它，会**同时废掉原生路径**。因此不能再用「整文件覆盖 `rpc.py`」的手法。
2. 正确做法：把兜底通道做成**独立模块 + 一个开关**（如 `module/ocr/apaos_fallback.py` + `config` 键或环境变量 `APAOS_OCR_BACKEND=native|inproc`），由构建/启动期选择，**不改动 Azurpilot 的 `rpc.py`**。
3. 兜底通道的触发条件：原生 RapidOCR 在 aarch64/proot 上装不上（依赖缺失）或精度不达线（M0-S2 判定）。
4. 模型资产是否仍随包内置：实测 `bin/ocr_models/` 全量 **288.8MB**（§13.2），但**默认路径只用到其中一小部分**（见 §11.1）；本仓自备的 PP-OCR 模型可仅在兜底通道启用时才部署。

### 11.1 原生 OCR 的默认模型集与 CPU 路径（S2 桌面预判，2026-09-24）

只读 `module/ocr/al_ocr.py` 所得，**大幅收窄了 S2 的不确定性，也直接改写体积裁剪方案**：

**(1) 默认档位不是 medium，是 standard（=small）**

配置键 `config.ocr_model_version(<逻辑名>)`，默认值 `'auto'` → 解析到 `DEFAULT_ONNX_MODEL_VERSION`：

| 逻辑名 | 默认模型 | 文件 | 体积 |
|---|---|---|---|
| `azur_lane` | `alocr_en_v2_6`（旧版 PP-OCRv4 结构） | `azur_lane/alocr-en-us-v2.6.nvc.onnx` | 7.3 MB |
| `cn` | `alocr_cn_v3`（旧版 PP-OCRv5 结构） | `zh-CN/alocr-zh-cn-v3.dtk.onnx` | 15.8 MB |
| `ppocr_v6` / `jp` / `tw` / `azur_lane_jp` | `standard`（=small） | `ppocr-v6/PP-OCRv6_small_rec.onnx` | 20.2 MB |

**(2) 检测模型默认只用 tiny**

`det/` 里三个档位（medium 59.2 / small 9.4 / tiny 1.7 MB）中，**默认路径只加载 `PP-OCRv6_tiny_det.onnx`（1.7MB）**。

→ **默认模型集实际只需 ~25–45MB，而非 288.8MB。** 裁剪方案（§13.3）据此收敛：`det/` 只需留 tiny；`ppocr-v6/` 只需留 small（若 `cn` 走 AlOCR 则可能连 PP-OCRv6 都不需要）；`ncnn/` 整目录（97.3MB）**确认可全删**（代码里 ncnn 只是可选后端，非默认）。

**(3) 纯 CPU 路径存在，且不需要任何 GPU 栈**

`config.ocr_device = 'cpu'` 时：`use_dml = False`（代码注释明示「不能交给 RapidOCR 默认 DirectML」）、`use_coreml = ocr_device == 'ane'`（cpu 时为 False）、**全代码无 Vulkan 引用**；`_configure_windows_ml_sessions()` 有 `if os.name != 'nt': return ocr` 守卫 → 非 Windows 直接保持 RapidOCR 默认 CPU session。

**(4) 不需要 zerorpc / OCR server**

`al_ocr.py` **无任何 zerorpc 引用**；所谓"服务"只是进程内的后台线程队列（`AlOcrQueue` 线程 + `queue.Queue`），用于避免阻塞主循环。→ 原 ALAS 的 `StartOcrServer` 那套在原生路径下完全不参与。

**(5) 🔴 新风险：omegaconf 版本陷阱（上游已注释，M1 必须显式钉版）**

上游源码注释原文：

> rapidocr 的 `RapidOCR._load_config` 在 `Global.model_root_dir` 为 None 时会把 `pathlib.Path` 写进 `DictConfig`，而 omegaconf 2.0.x（rapidocr 只声明 `omegaconf!=2.2.1`，没有下限，Python 3.14 下会解析到 2.0.6）拒绝 Path，抛 `UnsupportedValueType` 导致所有 OCR 初始化失败。

上游靠「把根目录显式转成字符串」规避。**我方在 M1 必须显式钉 `omegaconf` 版本**，否则 Python 3.14 上会静默解析到 2.0.6 并让整条 OCR 链失效。

**(6) 🔴 裁剪红线：不能删默认路径加载的模型**

`al_ocr.py` 的 import 失败路径是 `handle_ocr_error(e)` → **无条件 `raise RequestHumanTakeover`**（硬中断，整个调度器停摆）。所以裁剪必须**只删非默认档位/非默认后端**的模型，删错一个就直接宕机。这条必须在 M2/M5 用 S2 实测把关。

**(7) 残余风险**

`onnxruntime` 的 aarch64 可用性（已核实 cp314 aarch64 轮子存在，§12.1）；`rapidocr`/`omegaconf`/`numpy`/`opencv-python`/`Pillow` 的版本兼容（部分由 S1 探针覆盖）。

---

## 12. 前置 Spike 更新（结合决策）

| Spike | 内容 | 判定线 | 与决策的关系 |
|---|---|---|---|
| **S1 · 依赖可装性** | Ubuntu 26.04 + aarch64 + Python 3.14 上装 `ncnn`/`onnxruntime==1.27.0`/`numba==0.66.0`/`rapidocr==3.9.0`/`zerorpc`/`aiortc` 等 | 全部装成且 `import` 通过 | 决策 #2 的前提 |
| **S2 · 原生 OCR 可行性** | RapidOCR + PP-OCRv6 在 proot aarch64 CPU 上推理 | 能跑且达本仓油数验收线 | 决策 #6 的主/兜底分流 |
| **S3 · 最小可运行闭环** | `alas.loop()` 起得来 + WebUI 在 22267 出页面 + 桥 ping 通（不接游戏） | 三者皆通 | 决策 #1 的验证 |
| **S4 · 热更新体积实测**（新增） | Azurpilot `fetch --depth 1` 浅树实际下载量 | < 50MB 走 T2；否则做 T1 | 决策 #3 的前提 |

### 12.1 M0-S1 桌面核查结果（2026-09-24，**已执行**）

在动用 GHA aarch64 runner 实测之前，先只读 PyPI JSON API 排除了「根本不存在 cp314 aarch64 轮子」的死项。核查脚本：`spike/s1-deps/pypi-wheel-check.py`、`spike/s1-deps/pypi-wheel-check-transitive.py`。

**结论：桌面核查通过，无阻断性缺口。** 33 个直接依赖 + 12 个高风险传递/变体包，全部存在可用于 **Linux aarch64 + Python 3.14** 的轮子：

| 类别 | 结果 |
|---|---|
| Linux aarch64 二进制轮子 | 25 个（含 `numpy 2.4.6` / `scipy 1.18.0` / `onnxruntime 1.27.0` / `numba 0.66.0` / `ncnn 1.0.20260526` / `matplotlib 3.11.0` / `uv 0.11.32` / `pillow` / `lxml` / `pyyaml` / `websockets` / `pyzmq` / `av` / `pylibsrtp` / `cryptography` / `gevent` / `greenlet` / `scikit-image` / `pyclipper` / `shapely`） |
| 与平台无关轮子（py3-none-any） | 18 个（含 `rapidocr` / `zerorpc` / `mcp` / `sse-starlette` / `aiortc` / `uvicorn` / `fastapi` 等） |
| 仅 sdist（纯 Python，可构建） | `pywebio 1.8.4`、`adbutils 2.12.0` |
| 缺失 | **0** |

**两条必须落地的具体调整**：

1. **`opencv-python` → `opencv-python-headless`（必须替换）**
   Azurpilot 的 pyproject 钉的是 `opencv-python`，该轮子**链接 libGL/X11**；而本仓 rootfs 刻意不装 Qt/X11（`build-rootfs.sh` 的 apt 清单只有 `libglib2.0-0t64`/`libgomp1`），装了会在 `import cv2` 时直接炸。
   已核实 `opencv-python-headless 5.0.0.93` **有** `cp37-abi3-manylinux2014_aarch64` 轮子 → 用 uv/pip 的 override 机制替换即可（本仓现状就是用它）。
2. **`adbutils 2.12.0` 无 Linux aarch64 轮子**（平台标签只有 `macosx_10_9_intel` / `manylinux1_x86_64` / `win32` / `win_amd64`）→ 在 aarch64 上回落到 sdist 安装。它是**纯 Python**，装得起来；其 `manylinux1_x86_64` 轮子内含的 adb 二进制在 aarch64 上不可用，但**本仓的桥完全不走 adb**，无实际影响。非阻断。

**仍需 GHA 实测确认的（桌面核查覆盖不到）**：① Ubuntu 26.04 的 glibc 版本是否满足 `manylinux_2_28`（26.04 应远高于 2.28，预期无碍）；② `numba 0.66.0` 与 `numpy 2.4.6` 的运行期兼容；③ `uv sync` 在无 `uv.lock` 情况下能否从 `pyproject.toml` 正常解析（预期可以，`--frozen` 才需要 lockfile）。

### 12.2 改名波及面盘点（决策 #4，2026-09-24 实测）

| 标识符 | 出现处数 | 涉及文件数 | 归属级别 |
|---|---|---|---|
| `ALAS-AOS` | 72 | 17 | **L1** 用户可见（README / CHANGELOG / `strings.xml`(zh+en) / docs / AGENTS.md） |
| `alasaos` | 278 | 40 | **L2** 内部标识符（桥 method 值、脚本名、日志前缀） |
| `ALASAOS_` | 79 | 23 | **L2** 环境变量前缀 |
| `AlasAos` | 168 | 43 | **L2** 类名（Python `AlasAos` + Kotlin `AlasOverlay`/`AlasUpdater`/`AlasLogSource`/`AlasLogScreen` 等） |
| `shinarin` | 20 | 6 | **L3** appId / 仓库地址 / keystore 路径 |

**可直接复用的现成套路**：`handoff/2026-09-20-rebrand-alas-aos.md` 记录了上一次同规模断代更名（`maaal`→`alasaos` / `MaaAL`→`AlasAos` / `MAAAL_`→`ALASAOS_`）的完整打法，其结论直接适用：

- `applicationId` 的**单点改动位**在 `app/build-logic/convention/.../AndroidApplicationConventionPlugin.kt` 的 `BASE_APPLICATION_ID`；manifest 的 provider 走 `${applicationId}` 占位自动跟随；运行时全走 `context.packageName`，无硬编码 → **改 appId 的代码 churn 接近零，代价全在用户侧（必须卸载重装）**。
- Java 包名 `com.aliothmoon.maafw`（`namespace`）**刻意保留**，与 appId 解耦，不动。
- 上次遗留的教训：残留扫描**必须覆盖 `rootfs/` 与 `app/assets/alas/` 双源**（上次漏了 `rootfs/build/` 两个文件，其中一处是功能断链）；改完必须 `cmp` 双源一致性 + `sh -n` + Python AST + `assembleRelease` 全绿。
- 配套动作：`AlasOverlay.STALE_FILES` 增列旧名文件（防旧码被误加载）、`regen_args.py` 的桥选项显示名同步（双源）。

### 12.3 M0 桌面核查补充发现（2026-09-24）

**(1) 前端不需要 Node —— 一项 🟡 风险解除**

Azurpilot 顶层 `webapp/` 是 pnpm workspace（Vue/TS），一度担心运行期需要 Node 构建。实查 `gui.py` 后确认：**不需要**。

- `gui.py` 只服务 `module.webui.app:app`（PyWebIO 应用），**没有** `StaticFiles` 挂载、**没有** `dist/`/`static/` 引用、**没有任何** npm/pnpm/yarn/vite 调用。
- `webapp/` 的 Vue 前端是给**可选**的 Electron 桌面启动器用的（`--electron` 开关）；不传该开关，WebUI 完整可用。
- PyWebIO 的静态资源由自身在运行时提供，或经 `--cdn` 走 jsdelivr。

→ **rootfs 不需要引入 Node**，本仓 WebView 照旧加载 PyWebIO 页面即可。

**(2) 🔴 新发现：`gui.py` 启动时会跑 `uv sync`**

`gui.py` 内含 `_sync_dependencies()` / `_prepare_dependency_sync_before_webui_start()` / `_start_dependency_sync_service()`，通过 `deploy.uv` 调用 **`uv sync`**，并有超时常量 `DEPENDENCY_SYNC_TIMEOUT`。这相当于 ALAS 时代 `InstallDependencies` 的替代物，但**换了机制**（ALAS 走 `pip install -r`，Azurpilot 走 `uv sync`）。

后果与对策：
- 本仓的部署哲学是「依赖在构建期烘死，运行时永不装包」（无网、proot 慢、避免漂移）。若放任 `uv sync` 在设备上跑，会尝试联网解析/安装依赖 → 违反设计。
- 原 `deploy.yaml` 的 `InstallDependencies: false` 是否仍能挡住 `uv sync` **待确认**（Azurpilot 的 `deploy/config.py` 键名已改，且 `AutoUpdate` 已被删除）。
- **对策**：M3 阶段必须显式定位并关闭依赖同步服务（配置键或环境变量），或把 `PythonExecutable`/venv 指向预烘好的 `.venv` 并让 `uv sync` 判定为已满足。此项列入 M3 必办。

**(3) 默认端口确认**

`gui.py`：`port = args.port or int(State.deploy_config.WebuiPort) or 25548` → 默认 25548，但 **`WebuiPort` 配置键优先级更高** → 在 `deploy.yaml` 里钉 `WebuiPort: 22267` 即可让本仓 App 侧（WebView + 探针）零改动。

**(4) 内部 supervisor 与 wrapper 的叠加**

`gui.py` 自带 `run_webui_supervisor()`（基于 multiprocessing event 的自研监管），而本仓 `wrapper.py` 也对外部监管 `gui.py`（崩溃重拉 5s→60s 退避）。两套监管叠加会造成「谁在管谁」的语义混乱（与 Spike D 记录的 `ProcessManager` 双头管理风险同源）。M3 需决策：保留 wrapper 侧监管 + 关掉 Azurpilot 内部 supervisor，或反之。**不可两套同时生效。**

## 13. APK 打包链与体积预算（2026-09-24 补充）

> 用户明确：**AP-AOS 的交付物是 Android APK，rootfs 打进包内**。因此「换上游」不是改代码，而是走完整条打包链，且**体积是硬约束**。

### 13.1 打包链全景（现状，7 步）

```
① 改 rootfs/** 或手动触发 → GHA `rootfs.yml`（ubuntu-24.04-arm）
② 产出 artifact：dist/rootfs.tar.xz + dist/BUILD_MANIFEST（保留 14 天）
③ PC 侧 `gh run download <RUN> -n rootfs -D .tmp/rootfs-dist/`
④ 把 rootfs.tar.xz 拷进 app/app/src/main/assets/rootfs/（**gitignored，不入库**）
   BUILD_MANIFEST 入库（678B）——它是版本闸门
⑤ Gradle 打 APK（`jniLibs.srcDir("src/main/prootLibs")` + assets）
⑥ 设备首启：RootfsProvisioner 流式解 assets/rootfs/rootfs.tar.xz → filesDir/rootfs
⑦ 与设备 marker `files/rootfs/.provisioned` 比对 rootfs_version，不一致则重解
```

**三个必须知道的约束**：

1. **`noCompress += "xz"`**（`app/app/build.gradle.kts:41-42`）——rootfs.tar.xz 在 APK 里**不压缩**（为让 `assets.openFd` 能按字节读进度）。后果：**rootfs 的体积 1:1 直接变成 APK 体积**，没有任何压缩缓冲。想缩 APK 只能缩 rootfs。
2. **App 只读 BUILD_MANIFEST 的一个字段**：`RootfsProvisioner.VERSION_KEY = Regex("\"rootfs_version\"\\s*:\\s*\"([^\"]+)\"")`。→ 改 `alas_repo`/`alas_commit` 的**字段名**对 App 无影响（可安全改名）；但 **`rootfs_version` 的值必须 bump**，否则老装机不会重解新 rootfs，会拿旧环境跑新代码。
3. **Gitee Release 附件上限 100MB**（devlog 已记）→ 换上游后 APK 只会更大，**分发必须走 GitHub Release**，Gitee 镜像不能作为 APK 分发位。

### 13.2 体积实测（2026-09-24，**已执行**）

核算脚本：`spike/s1-deps/ocr-model-sizes.py`（只读 GitHub contents API）。

| 目录 | 体积 | 文件数 | 备注 |
|---|---|---|---|
| `bin/` | **322.8 MB** | 44 | **体积黑洞** |
| `assets/` | 15.6 MB | 1595 | 模板图库 |
| `campaign/` `webapp/` `doc/` `wallpapers/` `submodule/` `switch/` | 未测 | — | 未认证 API 限流耗尽；已由 workflow 步骤用 token 覆盖 |

**`bin/` 内部拆解（这才是关键）**——`bin/ocr_models/` 独占约 **288.8 MB，占 `bin/` 的 89.5%**：

| 子目录 | 体积 | 内容 |
|---|---|---|
| `ppocr-v6/`（rec，onnx） | 97.6 MB | medium 73.0 + small 20.2 + tiny 4.3 + 词表 0.12 —— **三档全带** |
| `ncnn/` | 97.3 MB | `ppocr_v6_pro` 72.9 + `standard` 20.1 + `lite` 4.2 —— **同三档的 ncnn 格式副本** |
| `det/` | 70.3 MB | medium 59.2 + small 9.4 + tiny 1.7 |
| `zh-CN/` | 15.8 MB | `alocr-zh-cn-v3.dtk.onnx` |
| `azur_lane/` | 7.3 MB | `alocr-en-us-v2.6.nvc.onnx`（**EN 模型**） |
| `cls` + README | 0.6 MB | 方向分类器 |
| 其余（`cnocr_models/`、`DroidCast/`、`MaaTouch/`、`ascreencap/`、`hermit/`、`scrcpy/`） | ~34 MB | 多后端/多服模型 + Android 侧推装件 |

**结论：Azurpilot 把「同三档精度 × 两种推理格式（onnx + ncnn）× 多个语种」的模型全量入库了。** 对 AP-AOS 的 CN-only + onnx + 单一档位场景，其中 95%+ 是用不上的。

### 13.2.1 体积预算（据实测重算）

| 情形 | rootfs.tar.xz | APK | 说明 |
|---|---|---|---|
| 现状（v0.1.4） | ~250 MB | **327 MB** | v0.1.3 时代曾到 392 MB |
| **朴素替换**（Azurpilot 源码原样烘入） | ~573 MB | **~650 MB** | 比先前估的 450MB 严重得多——`bin/` 实测 322.8MB，不是研究员初估的 120MB |
| **裁剪后目标** | ~275–300 MB | **~350–375 MB** | 见 §13.3；**设 400MB 硬线纳入 DoD** |

### 13.3 体积裁剪杠杆（据实测重排，按收益）

| # | 杠杆 | 实测收益 | 说明 |
|---|---|---|---|
| **1** | **丢弃 `bin/ocr_models/ncnn/` 整目录** | **省 97.3 MB** | 它是 onnx 那三档的 ncnn 格式副本。我方在 proot 里走 onnxruntime（现状就是），**ncnn 后端完全用不上** |
| **2** | **rec 档位降到 small 或 tiny**（丢弃 medium） | **省 52.8 / 68.8 MB** | `PP-OCRv6_medium_rec=73.0` → small 20.2 或 tiny 4.3。精度是否仍达线由 M0-S2 判定 |
| **3** | **det 档位降到 small 或 tiny**（丢弃 medium） | **省 49.8 / 57.5 MB** | `PP-OCRv6_medium_det=59.2` → small 9.4 或 tiny 1.7 |
| **4** | **丢弃 `bin/ocr_models/zh-CN/`** | **省 15.8 MB** | `alocr-zh-cn-v3.dtk.onnx` 是另一套（DTK）后端模型，非 PP-OCRv6 路径 |
| **5** | **丢弃 `bin/ocr_models/azur_lane/`（EN 模型）** | **省 7.3 MB** | 决策 #5 已定 CN 国服优先，EN 模型不部署 |
| **6** | **丢弃 `bin/` 的 Android 侧 helper** | **省 ~34 MB 中的大头** | `DroidCast/`、`MaaTouch/`、`ascreencap/`、`hermit/`、`scrcpy/`、`cnocr_models/`——**本仓的桥（22300）已完全取代这些推装件** |
| 7 | 剥离非运行时目录 | 待测 | `webapp/`（仅 Electron 用）、`doc/`、`wallpapers/`、`dev_tools/`、`tests/`、`.github/`、AI 工具配置（`.agent`/`.claude`/`.cursor`） |
| 8 | 已有项（沿用） | — | `.git` 删除、`__pycache__` 清、`root/.cache` 与 `apt/lists` 清 |

**裁剪后 `bin/ocr_models/` 目标体积**：

| 方案 | 组成 | 体积 | 相对朴素（288.8MB）省 |
|---|---|---|---|
| 极简（tiny 档 + onnx） | rec tiny 4.3 + det tiny 1.7 + 词表 0.12 + cls 0.6 | **6.6 MB** | **省 282 MB** |
| 稳妥（small 档 + onnx） | rec small 20.2 + det small 9.4 + 词表 0.12 + cls 0.6 | **30.3 MB** | **省 258 MB** |

→ **单靠 1–6 号杠杆，APK 就能从朴素的 ~650MB 拉回 ~350MB 量级，与现状 327MB 基本持平。** 体积问题完全可控，但**必须在 `build-rootfs.sh` 里显式做裁剪**，不能原样烘入。

### 13.4 对已确认决策的反馈

**决策 #3（保留热更新）从「体验优化」升级为「体积约束下的必然选择」**：既然 rootfs 体积 1:1 进 APK、且换上游后 APK 会涨到 350MB+，那么「每次上游 commit 都重发一个 400MB 的 APK」在分发上不可接受（GitHub Release 单文件 + 用户下载成本）。**设备端热更新是唯一能避免重发整包的手段** → M0-S4 的体积实测优先级提高。

### 13.5 换上游必须同步的打包链改动

1. `build-rootfs.sh`：base 换 26.04、上游换源、依赖重建、**新增裁剪步骤（§13.3）**、`ROOTFS_VERSION` bump
2. `BUILD_MANIFEST`：`rootfs_version` 值 bump（触发老装机重解）；`alas_repo`/`alas_commit`/`patches_source` 字段名建议改为 `upstream_*`（App 不读，安全）
3. `app/app/src/main/assets/rootfs/BUILD_MANIFEST`（入库那份）随构建产物同步替换
4. 发版流程：APK 命名 → `AP-AOS-v<版本>-android-arm64.apk`；**仅 GitHub Release**
5. DoD 新增一条：**APK 体积 < 400MB**

## 14. M0-S1 探针（2026-09-24 已就绪，待授权推送执行）

**为什么是独立探针**：S1 要在 aarch64 Linux 上建 chroot 装依赖，本机（Windows）跑不了；而按项目红线不能擅自 push。探针做成**完全独立**的一件东西，一次授权推送即可拿到结论，且不污染主线。

### 14.1 文件

| 文件 | 作用 |
|---|---|
| `spike/s1-deps/probe.sh` | 探针主体（323 行，`bash -n` 已过） |
| `spike/s1-deps/ocr-model-sizes.py` | 体积核算（已本地跑通，见 §13.2） |
| `.github/workflows/probe-s1-deps.yml` | 轻量 workflow（YAML 已校验） |

**放在 `spike/` 而非 `rootfs/build/` 的原因**：`rootfs.yml` 的触发条件是 push 到 `rootfs/**`——探针若放进去会**连带触发一次 120 分钟的全量 rootfs 构建**。现在触发路径限定为 `spike/s1-deps/**` 与 workflow 自身，与 `rootfs.yml` 完全隔离（已核对）。

### 14.2 探针做什么（11 步）

```
1  下载 ubuntu-base 26.04.1 LTS arm64 并**校验 sha256**
   （5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd，取自官方 SHA256SUMS）
2  mount bind /dev /dev/pts /proc /sys（trap 兜底卸载）
3  apt 最小依赖（刻意**不含 libgl1/libglx**——走 headless，装了反而掩盖问题）
4  环境事实：OS / Python / glibc / 架构 + requires-python 门禁判定（>=3.14.6,<3.15）
5  装 uv（已核实有 py3-none-manylinux_2_17_aarch64 轮子）
6  只取上游 pyproject.toml 单文件（**不 clone 1GB 整仓**）
7  用 tomllib 解析出依赖清单，**opencv-python → opencv-python-headless 替换**，
   平台 marker 原样透传由 uv 按当前平台求值
8  通道 A：uv venv + uv pip install -r（主路径）
9  通道 B：uv sync --no-dev（**保真度测试**：验「上游无 uv.lock 时能否从 pyproject 解析」）
10 import 门禁：核心组 22 项**硬失败**，次要组 12 项仅报告
11 汇总
```

### 14.3 结果怎么读

| 观察点 | 含义 | 对应决策 |
|---|---|---|
| 步骤 4 的 `requires-python 门禁` | Ubuntu 26.04 的 Python 是否满足 `>=3.14.6` | 不满足则 `uv sync` 必失败，只能走 `uv pip install` 绕过 |
| 步骤 8 `通道 A 退出码` | uv 能否在 aarch64 上装齐依赖 | 非 0 → 逐项排查 requirements.txt |
| 步骤 9 `通道 B 退出码` | 无 lockfile 时 `uv sync` 是否可行 | 不可行 → M1 必须自建 `uv.lock` 或改用 `uv pip install` |
| 步骤 10 `核心组 FAIL` | 依赖装上了但 import 炸（典型：libGL 缺失、ABI 不兼容） | 定位具体模块，可能是 headless 替换不彻底 |
| 步骤 10 `次要组 MISS` | `numba`/`ncnn`/`aiortc` 等缺失 | 多为可选路径，不阻断；确认 Azurpilot 是否有降级 |

产物：`probe-s1-log` artifact（含 `probe-s1.log` 全文）。

### 14.4 触发方式（需用户授权）

```bash
# 待用户明确授权后执行（红线：不擅自 push）
git add spike/s1-deps .github/workflows/probe-s1-deps.yml
git commit -m "probe(m0-s1): Azurpilot 依赖在 Ubuntu 26.04 + aarch64 + py3.14 的可装性探针"
git push
# 或直接在 Actions 页手动 workflow_dispatch
gh run watch
gh run download <RUN> -n probe-s1-log -D .tmp/probe-s1/
```

### 14.5 S1 首跑结果（2026-09-24，run #1 `35979598236`）——**实质通过**

**run 结论是 `failure`，但失败原因是我探针自身的 3 个 bug，不是依赖装不上。** 去掉噪声后的真实结论：**S1 通过**。

#### 真实结果

| 观测项 | 值 | 判定 |
|---|---|---|
| Ubuntu base | 26.04.1 LTS (Resolute Raccoon) arm64，glibc **2.43** | ✅ |
| uv | **0.12.18**（aarch64-unknown-linux-gnu） | ✅ 可用 |
| 依赖安装 | **140 个包全部解析安装成功**（`uv pip install` exit=0） | ✅ |
| venv 内核心组 import | **21/22 OK** | ✅（唯一 FAIL 见下） |
| venv 内次要组 import | **12/12 OK**（`numba 0.66.0` / `ncnn 1.0.20260526` / `onnxruntime 1.27.0` / `rapidocr 3.9.0` / `aiortc 1.15.0` / `mcp 1.23.0` 全过） | ✅ |
| 体积核算（步骤 5，认证后完整） | `bin/` **322.8MB** + `assets/` **79.9MB**（6816 文件）= 402.7MB | 见 §13.2 |

**唯一 FAIL 的 `fastapi` 是我的门禁清单写错了**——上游 `pyproject` 只依赖 `starlette==0.49.1`，**根本不依赖 fastapi**。

#### 🔴 唯一的硬伤：Python 版本差两个补丁

**Ubuntu 26.04.1 自带的 `python3` 是 3.14.4，而上游要求 `>=3.14.6,<3.15`。**

后果：靠发行版 python 无法满足 `requires-python`。**解法（已写进探针）**：不依赖发行版解释器，改用 **uv 自带的 python-build-standalone**：

```bash
uv python install 3.14     # 装 uv 托管的最新 3.14.x（>=3.14.6）
uv venv .venv --python "$(uv python find 3.14)"
```

这条同时解决了「换 base 到 26.04 仍不满足版本要求」的隐患，也让 rootfs 不再受发行版 Python 版本牵制。

#### 探针的 3 个 bug（已修，待重跑确认）

| # | Bug | 后果 | 修法 |
|---|---|---|---|
| 1 | 门禁对 `/usr/bin/python3` 也跑了一遍 | 系统解释器没装依赖 → 必然全 FAIL，把结论污染成「失败」 | 只对 venv 跑门禁；`GATE_RC` 直接取 venv 结果 |
| 2 | `uv sync --no-dev 2>&1 \| tail -25` | **管道退出码是 `tail` 的**，把失败吞成 `exit=0`（首跑就报了假成功） | 输出落盘再 `tail`，退出码取 `uv sync` 本身 |
| 3 | 门禁核心组列了 `fastapi` | 上游不依赖它 → 假 FAIL | 换成 `starlette`（上游真实依赖） |

#### 依赖面的重要发现（影响 M1）

- **`pydantic>=2.12.5`（v2）**——本仓 ALAS 时代钉的是 `pydantic<2`。**这是依赖面的根本变化**，ALAS 侧任何依赖 v1 API 的补丁都要重估。
- **`imageio==2.26.0`**——本仓因 T2 崩溃（P 模式 GIF 被解成 RGB 3 通道 → cv2 通道断言崩）钉的是 **2.27.0**。需复核该问题在 Azurpilot 下是否仍存在（若存在，要在 override 里钉回 2.27.0）。
- `adbutils==0.11.0` + `uiautomator2==2.16.17`——都是**很老的版本**（本仓现状用的是 u2 3.x）。装得上（纯 Python），但要注意 `minitouch.py`/`method/utils.py` 那两个 u2>=3 兼容 shim 是否还需要。
- `uv==0.11.32` 被上游**列为运行时依赖**（不只是构建工具）。
- `onnxruntime==1.27.0; sys_platform=='linux'`——已确认装上并 import OK。

## 15. 并行工作与上游分叉（2026-09-24 发现，**需要拍板**）

用户提供了 `wess09/ALAS-AOS` 的 `codex/azurpilot-android-verify` 分支。核查后确认了一件必须让决策者知道的事：

> **`wess09`（茗）就是 AzurPilot 的原作者**。他 fork 了同一个仓库（基线正是我们推送前的 `adc9f19a`），并在 **同一天**做**同一件事**（分支名含 `codex`，疑为 AI 辅助）。核心提交 `32f3f10f feat: adapt Android runtime for AzurPilot master`，规模 +1,864 / −33,893。

### 15.1 他的路线 ≠ 我们的路线

| | 我们的路线（增量换源） | wess09 的路线（重建） |
|---|---|---|
| ALAS 时代 overlay | **保留并移植**（`wrapper.py`/`runner.py`/`rpc.py`/`al_numpy.py`/`seeds/*`） | **全删** |
| guest 侧进程管理 | 我们的 `wrapper.py` + `runner.py` | **AzurPilot 原生 `RuntimeService` + `ProcessManager`** |
| 端口 | 沿用 22267 / 22300 / 22400 | **改为 WebUI 25548 / 桥 22301**（与旧版分离，双包并存） |
| 包名 | 沿用 `io.github.shinarin.alasaos` | 新建 `io.github.shinarin.azurpilotandroid` |
| 上游适配 | 9 个整文件补丁 → 计划改最小 diff | **单一 `rootfs/patches/azurpilot-android.patch`** |
| 更新通道 | 设备端热更新（git / CDN pack） | **`runtime.tar.xz` + `latest.json` 运行时包** |
| 构建脚本 | 改造 `build-rootfs.sh` | 新建 `build-azurpilot.sh` |
| 验收状态 | S1 ✅；rootfs 构建 ❌（依赖解析） | **同样未验证**（README 明说「请勿当作可安装成品」） |

### 15.2 应直接吸收的 4 处技术（无论最终选哪条路线）

1. **不升 base**：保留 **Ubuntu 24.04.5**，用 `uv python install 3.14.6` + **`UV_PYTHON_PREFERENCE=only-managed`** 提供 Python。
   → 我方升 26.04 是**多余的**：26.04 只给到 3.14.4（仍不满足 requires-python），而换 base 要重新验证整个 apt/系统层。`only-managed` 是关键 flag——否则 uv 可能挑中发行版 python。
2. **venv 移出源码树**：`mv /opt/azurpilot/.venv /opt/azurpilot-venv` + `ln -s ../azurpilot-venv .venv`
   → **源码热更新时不触碰已验依赖环境**。这比「CDN 增量包」更简单地解决了 M0-S4 的体积难题——**直接采纳**。
3. **装 GL/X11 库**：`libgl1 libstdc++6 libatomic1 libsm6 libxext6 libsndfile1 libvulkan1`
   → `libgl1` 会拉进 `libx11`/`libxcb`，我们踩的 `libxcb.so.1` 问题自然消失；`libvulkan1` 让 ncnn 后端可用。
4. **用 `uv sync` 而非自己抽 requirements + `uv pip install`**：`uv sync` 会读取 pyproject 的**全部**配置，包括 `[tool.uv] override-dependencies`——**这正是我们 rootfs 构建失败的原因**（见 §15.4）。wess09 还额外用了 `--frozen`（依赖 `uv.lock`；注意我们目标仓**没有** `uv.lock`，故只能用不带 `--frozen` 的 `uv sync`）。

其他可借鉴：`dev_tools.import_smoke_test` 内置冒烟、`rootfs_version` 取上游 commit 前 12 位、`AZURPILOT_ANDROID=1` 环境变量门控 Android 行为、Gradle `verifyBundledAzurPilotRuntime` 校验任务。

### 15.3 🔴 上游分叉：我们选的目标仓落后于上游主线

| | `changqing81/Azurpilot-Auto` master（我们的目标） | `wess09/AzurPilot` master（上游主线） |
|---|---|---|
| `frontend/`（React + Vite + TS，带 playwright/vitest） | ❌ **没有** | ✅ 有 |
| `module/api/`（FastAPI + WebSocket） | ❌ **没有** | ✅ 有（12 文件，含 `runtime_service.py`/`socket.py`/`static.py`） |
| WebUI 形态 | pywebio `module/webui/` + `webapp/`(pnpm/Vue) | **FastAPI + WebSocket + React** |
| 活跃度 | — | **极高**：24h 内 19+ 提交、PR #1042–#1046、仍在 merge `lme/master` |

**含义**：若坚持用 `changqing81/Azurpilot-Auto` 作上游，我们是在**旧架构**上做适配，且拿不到 React WebUI 与 `RuntimeService`；而 wess09 的 Android 适配正是基于新架构。**这条需要决策者明确选择上游。**

### 15.4 我们的 rootfs 构建失败原因（run `35983440584`，3 分钟即挂）

**与 base 升级无关**，是依赖解析失败：

```
error: No solution found when resolving dependencies
  cause: Because uiautomator2==2.16.17 depends on packaging>=20.3,<21.dev0
         and you require packaging==24.2, we can conclude that your requirements are unsatisfiable.
```

**上游 pyproject 自相矛盾**：同时钉了 `uiautomator2==2.16.17`（要求 `packaging<21`）与 `packaging==24.2`。
**为什么探针能过**：探针额外把 `[tool.uv] override-dependencies` 抽出来传了 `--override`，构建脚本没传。
**修法**：改用 `uv sync --no-dev`（读 pyproject 全部配置），与 wess09 一致。

### 15.5 我们的相对优势（不应被抹掉的部分）

wess09 复用了 App 外壳（Kotlin），但 rootfs 侧完全重写。**我方独有且已真机验证的资产**：
- 特权进程 + 虚拟屏 + 桥（22300 五端点）—— m0 实测 p50 109ms / 1800 次零失败，v0.1.4 装机可用
- 真机调试闭环经验与 `debug.md` 全部坑点（含手势劫持红线、VD flag 硬约束、幻影进程查杀）
- Shizuku 冲突引导、悬浮窗、日志中心等 App 侧已交付功能

→ 无论选哪条路线，这些都不该丢。

### 15.6 建议

1. **立即吸收 §15.2 的 4 处技术**（与路线选择无关，纯赚）；
2. **上游选择要单独拍板**：`wess09/AzurPilot`（新架构、活跃、原作者在维护）vs `changqing81/Azurpilot-Auto`（老架构、我们已摸清）；
3. **考虑协作而非并行**：他与我们同仓库、同基线、同一目标，且**双方都还没验证成功**。并行重复劳动的性价比低——是否联系/复用，请决策者定。

---

> 本文为方案稿。§1–§7 为现状分析与改造设计；§8 起为 2026-09-24 用户拍板后的**冻结决策与展开方案**；§15 为当日发现的并行工作与上游分叉。所有对目标仓库的判断均基于只读源码核查；标注「待确认」的项需实测。
