# 上游 fork 差异分析：`wess09/AzurPilot-for-Android`

**分析日期**：2026-10-07
**分析对象**：`https://github.com/wess09/AzurPilot-for-Android`（33★，51MB，默认分支 `main`，最近推送 2026-10-07）
**本地**：`D:\AP-AOS` @ `0e460cd`（2026-09-25）

> 本文为**只读侦察结论**。按项目规范（`拉取合并规范` skill 第 0 步），未经用户点头不做任何 git 写操作。

---

## 1. 两仓关系：同源 fork，双向大分叉

该仓库描述为「AzurPilot 安卓版本 基于ALAS-AOS」，**与本地共享完整历史**：

| 项 | 值 |
|---|---|
| 共同祖先 | **`adc9f19`**（2026-09-21，`docs: v0.1.4 发布收官`）——正是我们换上游工作**之前**的远端状态 |
| 他独有 | **111 条有效提交**（163 条含 `chore: check AzurPilot upstream [skip ci]` 自动提交与 merge） |
| 我们独有 | **42 条**（换上游到 Azurpilot-Auto 的整条工作线） |

**分叉性质**：从 09-21 起，双方各自独立演进 16 天，**无交叉吸收**（`ours/main..HEAD` 与 `HEAD..ours/main` 完全互斥）。

---

## 2. 为什么**不能逐条 cherry-pick**（三条硬障碍）

### 2.1 他做了 App 侧包名重构 🔴

| | 他 | 我们 |
|---|---|---|
| 包根 | `app/app/src/main/java/com/azurpilot/ghio/` | `app/app/src/main/java/com/aliothmoon/maafw/` |
| App 类 | `AzurPilotApp.kt` / `AppDispatchers.kt` | `MaaFwApp.kt` / `MaaDispatchers.kt` |
| 新增子模块 | `auth`、`keepalive`、`report`、`update` | （多 `util`） |

→ **所有 App 侧 Kotlin 提交的路径都不同**，`git cherry-pick` 必然大面积冲突。

### 2.2 架构路线分叉 🔴

他有一个提交 `66b96ec feat: Implement native AzurPilot interface, replacing WebUI with in-app navigation` ——
**用原生界面替代了 WebUI**。而我们保留 PyWebIO 路线（用户已定「UI 用目标源自带的 pywebio」）。
→ 该提交及其下游（导航、UI 结构）**与我们的路线直接冲突**。

### 2.3 依赖断链（本地完全没有的体系）

`git grep` 实测（本地 `app/` 下命中文件数）：

| 特征 | 本地文件数 | 含义 |
|---|---|---|
| `okdownload` | **0** | 他的下载链路库，我们没有 |
| `device-report` | **0** | 他的设备报告体系（`server/device-report`） |
| `hot-update` | **0** | 他的热更新链路（我们走另一套） |
| `ExpressiveLoadingIndicator` | **0** | 他的 UI 组件 |
| `feedback_group` | **0** | 他的反馈入口体系 |
| `semi-icons` | **597** | **我们有、他没有**（我们的图标库）→ 他的 UI 提交可能与我们的图标体系不兼容 |

### 2.4 唯一两个「路径相同」的 CI 提交也**不适用**

| 提交 | 内容 | 为何不适用 |
|---|---|---|
| `555bf5c` | `fix(ci): pcre2 10.47 已从 Termux 池下架，钉版升级 10.49 并缓存 deb` | 改的是 `app/scripts/fetch-proot-libs.sh`，**本地无此脚本**（我们 `app/scripts/` 只有 `check_i18n_strings.py`）；且内容是 **x86_64 架构支持**，我们只做 arm64 |
| `d154aca` | `fix(ci): APK job 内 assets 拷贝路径` | 我们的 CI 第 167 行**已经是正确路径** `app/app/src/main/assets/rootfs/` |

---

## 3. 分类清单

### A. 可直接收编（新文件，零冲突）

| 资产 | 内容 | 价值 |
|---|---|---|
| `doc/*.md`（13 篇） | `privileged-bridge-protocol.md`、`runtime-provisioning.md`、`architecture.md`、`hot-update.md`、`multi-arch.md`、`adb-e2e-testing.md`、`device-reporting.md`、`build-profiles.md`、`release-channel.md`、`xiaomi-workstation.md`、`comment-style.md`、`development-guide.md`、`module-reference.md` | **高** —— 与我们的核心机制高度相关，可作参考文档收编 |
| `tools/watch-android-logs.ps1` | 日志监视工具 | 中 |
| `server/device-report` | 设备报告服务 | 中（独立服务） |

### B. 建议**手工移植**（本地有对应文件，按文件对位改）

本地 `remote/`、`privileged/` 模块文件名与上游**基本一致**（同源），因此以下提交可对位移植：

| 提交 | 作用 | 本地对应文件 |
|---|---|---|
| `8e33253` | `fix(remote): kick frozen target on virtual display when capture frames stall` —— **虚拟屏帧卡住时踢目标**（挂机稳定性） | `remote/internal/AppWatchdog.kt`、`privileged/WatchdogState.kt`、`remote/internal/BridgeServer.kt`、`remote/RemoteServiceImpl.kt` **均存在** |
| `0129bfa` | `fix(remote): move channel-SDK popups stranded on the primary display back to the virtual display` —— **渠道 SDK 弹窗跑到主屏时拉回虚拟屏**（真实痛点） | `remote/RemoteServiceImpl.kt`、`remote/internal/ActivityUtils.kt` 存在；`SdkTaskRepatriator.kt` 为**新文件** |
| `d604b82` | 同上，另一处场景 | 同上 |
| `055266c` | `feat(remote): persist privileged-process logs into the exported debug bundle` —— 特权进程日志进导出包（排障） | 我们有日志导出体系 |

### C. 建议**新增**（本地完全没有，价值明确）

| 提交 | 作用 | 优先级 |
|---|---|---|
| `e6337cf` | `feat(keepalive): 新增多策略后台保活系统与设置开关`（13+ 新文件：AIDL + Service + Alarm/Job/Broadcast 多策略） | **高**（挂机命脉） |
| `7a8a908` | `支援虚拟屏帧率设置`（本地 grep `fps`/`frameRate`/`refreshRate` **零命中**） | **中高**（性能调优） |
| `87c58b6` | `feat: 实例管理新增配置导入，导入前提示安卓特殊配置差异` | 中 |
| `c2994d7` | `feat(shortcut): add launcher app shortcuts for quick actions` | 中 |
| `31b73ba` / `37e5fe2` / `15b7a9b` | splash 圆形遮罩图标 / 启动图标+动画开屏 / ExpressiveLoadingIndicator | 中低（观感） |
| `a7e03ea` | `feat: 新增用户界面风格设置选项及提示信息` | 中低 |
| `154859e` / `a584bdd` | 反馈 Bug 入口 / 加群反馈入口 | 中低（运营） |

### D. 不建议合（附理由）

| 提交/类别 | 理由 |
|---|---|
| `66b96ec` native interface 替代 WebUI | **架构路线冲突**（用户已定保留 pywebio） |
| `247ae1e`、`0035c31`、`8462cf4`、`70e954a`、`3d9beed` 大重构 | 跨模块 200+ 文件、纯注释/结构重排，**极易与本地未跟踪文件撞车**（skill 明确建议跳过） |
| `42e0212`、`d110260` 版本线 | 他切到 `1.1.131`→`1.2.0`，我们仍是 `0.1.x` |
| `3880311`、`c505225` okdownload | **本地无 okdownload**（grep 0 命中） |
| `8bd9650`、`2f34af7` feedback i18n | 本地无 feedback 体系；且本地 res 只有 `values`/`values-en`（他是四语言） |
| `f77ab74` CI 每 30 分钟自动提交 | 我们的 CI 不需要此机制 |
| 多语言 README（`README_en/ja/zh-TW`）、KDoc 双语 | 我们无此约定 |
| `1db9173` 删失修单测 | 本地单测状况不同 |

### E. 需评估（可能有部分重叠）

| 提交 | 说明 |
|---|---|
| `0234635` LAN control + remote access + Runtime restart | 本地已有 `privileged/RemoteAccessCoordinator.kt`、`RemoteAccessPort.kt` 等 —— **需先比对是否部分重叠**，再决定补哪些 |
| 热更新链路 5 条（`2a9908b`/`fe20d44`/`4db825c`/`df6a622`/`e95936a`） | 我们也在做热更新但架构不同；`doc/hot-update.md` 可先作参考 |
| `e24c4ee`/`de7d25f` 设备报告 | 依赖 `server/device-report`（独立服务，可整体评估） |

---

## 4. 执行建议

| 方案 | 内容 | 风险 |
|---|---|---|
| **方案 1（推荐）** | 只做 A 类：收编 `doc/` 文档 + `tools/` + `server/` | **零冲突**，纯新增文件；立即有价值（文档补齐） |
| **方案 2** | A + B 类：文档 + 手工移植 remote/privileged 的 3 项修复 | 中；文件对位明确，但需按我们的包名/结构改写 + 真机验证 |
| **方案 3** | A + B + C 全做 | 高；C 类含整个 keepalive 模块（13+ 文件）与 UI 改动，工作量大 |

**无论选哪个方案，都不建议 `git merge` 整体合并**（111 条 vs 42 条的架构分叉，冲突会淹没一切）。

---

## 5. 合并注意事项（若执行 B/C 类）

1. **不能用 cherry-pick** —— 包名不同（`aliothmoon.maafw` vs `azurpilot.ghio`），必须**按文件对位手工改写**，并逐处替换包名引用。
2. **改名映射**：`AzurPilotApp`→`MaaFwApp`、`AppDispatchers`→`MaaDispatchers`、`com.azurpilot.ghio`→`com.aliothmoon.maafw`。
3. **图标体系不同**：我们有 `semi-icons`（597 文件）而他没有 —— 他的 UI 提交若引用了 Material Icons，需替换为我们的图标。
4. **多语言资源**：本地只有 `values`/`values-en`，他的提交常同时改 4 个语言目录（含 `values-ja`/`values-zh-rTW`）→ 只取我们有的两个。
5. **依赖断链一律不碰**：okdownload / device-report / hot-update / feedback 相关代码不要夹带进来。
6. **本机无 Android 工具链** → 编译验证只能走 CI 的 `apk` job（手动触发），或真机安装验证。
7. **push 需用户点头**（项目红线）。
8. **参考先例**：本仓已有两次「采纳同源 fork」的成功做法 ——
   - `3277fd0 fix: 采纳 wess09 三条坑点——固定 debug keystore / pip 超时 / imageio 构建期钉版`
   - `a91433b fix(ui): 切页不再闪「启动环境」/不再黑屏重载——采纳同源 fork v0.1.5 的修复`
   → B/C 类可沿用此模式（手工采纳 + 注明来源提交）。

---

## 6. 待用户决策

1. 选哪个方案（1 / 2 / 3）？
2. B 类里，`8e33253`（虚拟屏帧卡踢目标）与 `0129bfa`（渠道 SDK 弹窗回迁）优先级是否最高？
3. C 类的 keepalive 模块（13+ 文件）是否要做？

---

## 7. 「fork 他的仓库」方案评估（2026-10-07 补充）

### 7.1 决定性事实：他的原生 UI 依赖上游的 `/api/v1/ws` 网关 🔴

证据（`app/app/src/main/java/com/azurpilot/ghio/proot/AzurPilotGateway.kt` KDoc 原文）：

> AzurPilot `/api/v1/ws` 网关客户端
> WebUI 前端用的就是这一条长连接：请求/响应信封 + 主题推送 + `seq` 序号。
> **原生界面不碰 HTTP 静态资源，但业务能力全部来自这里** —— 所以这个类要能表达协议的全部语义

以及 `rootfs/overlays/android_host.py`（rootfs 入口进程）原文：

> chdir 到 `/opt/azurpilot` 后以 venv Python **启动上游 `gui.py`**（WebUI 与 WebSocket 网关，默认监听 127.0.0.1:25548）

**架构链条**：

```
他的 App 原生 UI（Compose，ui/azurpilot/sections/*）
        ↓ WebSocket /api/v1/ws
上游 wess09/AzurPilot 的 module/api/（FastAPI + 协议层 protocol.py）
```

**关键**：`changqing81/Azurpilot-Auto`（**你的源**）**没有 `module/api/`** —— 它是 pywebio 老架构，不存在这条 WebSocket 网关。

→ **他的原生 UI 无法直接配你的源**。这就是「他的 UI 是新的 / 我的源是老的 pywebio」这个矛盾的**技术本质**。

### 7.2 他的上游与路径配置（与我们的差异）

| 项 | 他 | 我们 |
|---|---|---|
| 上游 repo | `https://github.com/wess09/AzurPilot.git`（钉 `1841cb19`） | `changqing81/Azurpilot-Auto.git` |
| rootfs 路径 | `/opt/azurpilot` | `/opt/alas` |
| 设备通道名 | `azurpilot_android` | `alasaos` |
| 依赖锁定 | `uv sync --frozen`（**有 uv.lock**） | `uv sync`（无 lock） |
| WebUI 端口 | 25548 | 22267 |
| 兼容层 | `overlays/android_process_compat.py` 注入 site-packages | `shims/` |

> 注：他的 `AzurPilotSchema.kt` KDoc 声明「取值全部来自网关的 `args.json`，**App 侧不硬编码任何一项**」——
> 即 UI **渲染层**是动态的、理论上可配任意 ALAS 系上游；但**数据通道**（WebSocket 网关）是 wess09/AzurPilot 独有的。

### 7.3 他的成熟度（值得参照，也说明他这条路走得通）

| 项 | 值 |
|---|---|
| 最新 Release | **`1.2.85`**（tag `azurpilot-android-latest`） |
| 产物 | `-arm64-v8a-full.apk` **870.6MB** · `-update.apk` **12.8MB（增量）** · `-x86_64-full.apk` 921.9MB |
| 分发 | `latest.json`（**下载 505 次**）· `rootfs-arm64-v8a.tar.xz` 859.1MB · `frontend-<sha>.tar.xz` 7.7MB |
| 版本演进 | 1.2.62 → 1.2.76 → 1.2.85（持续发版） |
| 文档 | `doc/` 13 篇（中英双语）+ 四语言 README |
| 功能（release notes 摘） | 局域网控制、远程访问（P2P/SSH 隧道）、重启 Runtime、保活机制 |

**对照我们**：v0.1.4、单架构（arm64）、无 release、无增量更新、真机验证未见记录。

### 7.4 三个选项对比

| 选项 | 做法 | 得到 | 代价 | 风险 |
|---|---|---|---|---|
| **1. 不 fork（现状继续）** | 在 AP-AOS 上选择性移植他的技术点（§3 的 B/C 类） | **你的源** + pywebio + 我们已完成的换上游成果（运行时注入、CI 打绿） | 手工移植、无法持续跟踪他 | **低** |
| **2. fork 他 + 换上游到你的源** | 改 `build-azurpilot.sh` 上游 + 桥接适配 + **UI 层重做** | 他的 App 外壳 + 你的源 | **UI 层要重写**（原生 UI 依赖他的 api 网关，你的源没有）；或给 Azurpilot-Auto 补一套 `/api/v1/ws` 网关 | **高** |
| **3. fork 他直接用** | 直接用他的仓库/Release | **成熟可用的 App**（1.2.85，870MB，多架构，增量更新） | **放弃「用你的源」** | 低 |
| 3b. **不 fork，直接用他的 Release** | 下载 `1.2.85` APK 装机 | 同选项 3 | 同上；且不改代码，无需 fork | 最低 |

### 7.5 结论

**fork 与「用你的源」不可兼得**，除非做 UI 层重写（选项 2，代价最大）。

- 若**坚持用你的源** → 选 **选项 1**（继续现状 + 选择性移植）
- 若**只想要个能跑的成品** → 选 **3b**（直接下他的 Release，**连 fork 都不需要**）
- **fork 的唯一真实价值**是「可持续跟踪他的更新」；但代价是 UI 层要么重写、要么放弃你的源

**需要你明确的**：你的最终目标是哪一个？
- **A. 用成功我的源**（`changqing81/Azurpilot-Auto`）→ 选项 1
- **B. 一个能用的 Android 挂机 App**（上游是谁不重要）→ 选项 3b
- **C. 两者都要**（我的源 + 他的 App 完善度）→ 选项 2（需评估 UI 层重写工作量）

---

> 本报告为只读侦察结论，**未做任何 git 写操作**。所有「本地有没有」判定均附 `git grep` / `git ls-tree` 实测证据。
