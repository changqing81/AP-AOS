# 2026-10-07 · 选择性移植上游同源 fork `wess09/AzurPilot-for-Android`

> 上一篇：`2026-09-21-release-v014.md`（v0.1.4 发版）。
> **本篇补上了 2026-09-25 ~ 2026-10-07 之间缺失的交接**（这段工作当时没写 handoff，违反 AGENTS.md 第二节；本次从 `devlog.md` + `git log` 重建）。

## 一、任务来源与结论

用户要求「合并上游优质提交」。只读侦察结论落在 **`docs/upstream-wess09-fork-diff.md`**（+ 收编的技术文档 `docs/upstream-wess09-ref/`，13 篇）。

**核心结论：不能 merge / 不能 cherry-pick，只能按文件对位手工改写。**

| 项 | 值 |
|---|---|
| 共同祖先 | `adc9f19`（2026-09-21，v0.1.4 收官） |
| 他独有 | 111 条有效提交（含 `chore: check upstream [skip ci]` 自动提交共 163） |
| 我们独有 | 42 条（换上游到 `changqing81/Azurpilot-Auto` 的整条线） |
| 硬障碍 1 | 他做了 App 侧包名重构：`com/azurpilot/ghio/` vs 本仓 `com/aliothmoon/maafw/`；类名 `AzurPilotApp`/`AppDispatchers` vs `MaaFwApp`/`MaaDispatchers` |
| 硬障碍 2 | 架构路线分叉：他 `66b96ec` 用**原生 UI 替代 WebUI**，依赖上游 `module/api/` 的 `/api/v1/ws` 网关；本仓保留 pywebio + WebView，**没有那一层** |
| 硬障碍 3 | 依赖断链：`okdownload`/`device-report`/`hot-update`/`feedback` 本仓全为 0 命中 |

**fork 他的仓库也不成立**（除非重写 UI 层）：他的原生 UI 数据通道绑死在 `wess09/AzurPilot` 的 API 层上，而「用你的源」(`changqing81/Azurpilot-Auto`) 没有那层。详见 diff 文档 §7。

## 二、已完成（本轮）

| 类别 | commit | 来源提交 | 内容 | CI |
|---|---|---|---|---|
| A | `c0a5d64` | — | 收编他的 `doc/` 13 篇 → `docs/upstream-wess09-ref/` | — |
| A | `61a4112` | — | 补 §3.5 文件级量化差异（实测） | — |
| B-2 | `95e6cfe` | `0129bfa`+`d604b82` | 渠道 SDK 弹窗回迁虚拟屏（新增 `SdkTaskRepatriator.kt` 250 行 + `ActivityUtils` 3 成员 + `RemoteServiceImpl` 4 处启停） | ✅ run `37598427496` 全绿 |
| B-1 | `1e806f8` | `8e33253` | 虚拟屏帧卡踢活（`WatchdogState.FRAME_STALLED(4)` + `AppWatchdog` 帧停滞检测 +134 行 + `BridgeServer.frames`） | ✅ run `37600184429`：build 全绿、apk「Build debug APK」success |
| B-4 | `66d8e55` | `055266c` | 特权进程日志落盘进导出包（`Ln.java` 文件 sink，Java 重写；`RemoteBootTrace.debugDir`；`RemoteServiceImpl` 启用） | ⏳ **未推，未验证** |
| C-2 | `01c55cd` | `7a8a908` | 虚拟屏帧率可调（16 文件：settings/MVI/UI/AIDL/特权侧/`DisplayManager.java`/strings） | ⏳ **未推，未验证** |

**本地 HEAD = `01c55cd`；远端 `origin/main` = `1e806f8`** → 本地**领先 2 个 commit**（`66d8e55`、`01c55cd`），**等用户点头才能 push**。

## 三、C 类逐项判定（证据见 diff 文档 §3）

| 提交 | 内容 | 判定 |
|---|---|---|
| `e6337cf` | 多策略后台保活（29 文件 +1434 行，AIDL + Service + Alarm/Job/Broadcast） | **可行，工作量大** → 单独批次 |
| `7a8a908` | 虚拟屏帧率 | ✅ **已做**（`01c55cd`） |
| `87c58b6` | 实例配置导入 | ❌ 断链跳过（改 `ui/azurpilot/sections/settings/InstancesPage.kt`，本仓无此原生 UI） |
| `c2994d7` | launcher 快捷方式（9 文件 +314） | 可行，未做 |
| `154859e` / `a584bdd` | 反馈 / 加群入口 | 可行，未做（中低优先） |
| `31b73ba` / `37e5fe2` | splash 圆形遮罩 + 启动图标 | 暂缓（二进制观感类，且会删本仓 mipmap 全套 PNG） |
| `15b7a9b` | ExpressiveLoadingIndicator（+334 行） | ❌ 断链跳过（依赖 `ui/azurpilot/sections/*`） |
| `a7e03ea` | UI 风格设置 | ❌ 跳过（只有 4 份 strings、无配套代码） |

## 四、下一步（按优先级）

1. **push + CI 验证 `66d8e55` / `01c55cd`**（本机无 JDK，编译只能靠 CI）。**必须先拿到用户明确点头**（AGENTS.md 第六节 + 用户红线）。
2. `e6337cf` keepalive 单独批次：先评估本仓 `settings`/`di` 的对位改造量（本仓 `AppSettingsGateway` 是 5 项契约、MVI 走 `SettingsUiState`/`SettingsIntent`；上游是 `koinInject` 直连），再决定做/不做。
3. `c2994d7` 快捷方式（需动 `MainActivity.kt` + `ui/AppRoot.kt`，`AppRoot` 两边都大改，谨慎）。
4. `154859e`/`a584bdd` 反馈入口（低优先，含对外链接，需用户确认运营意图）。
5. **修测试源集脱节**（见 `debug.md` 2026-10-07 条目）：`FakeAppSettingsGateway` 引用 6 个接口里不存在的成员 + 已删除的 `runner.ResolutionPreference`，`testDebugUnitTest` 必然编译失败；CI 只跑 `assembleDebug` 所以一直不可见。

## 五、关键决策与注意事项

1. **移植方式三分**：路径/包名可对位的用 `git apply`（B-1 的两个文件）；KDoc 上下文不同的手工改；语言不同（上游 Kotlin / 本仓 Java，如 `Ln`、`FakeContext`）必须按本仓语义重写。**一律不能 cherry-pick**。
2. **UI 侧一律要重排**：上游设置页是 `App*` 组件 + `koinInject` 直连；本仓是 `Maa*` 组件 + MVI（`SettingsUiState`/`SettingsIntent`/`AppSettingsGateway`）。C-2 就是按这个重排的。
3. **资源只取两份**：本仓只有 `values`/`values-en`，上游常同改 4 语言（含 `values-ja`/`values-zh-rTW`）→ 只取我们有的两份。
4. **本机工具链确实不存在**（本次再测：`java`/`javac` 都不在 PATH；PATH 里 `D:\softinstall\jdk-18.0.1` 是**失效路径**）→ 编译验证只能走 CI 的 `apk` job（手动触发，`build_apk=true`）。
5. **CI 触发与查状态**：本机 curl 打 `api.github.com` 返回 000（沙箱拦），查 run 状态用 WebFetch 打 `https://api.github.com/repos/changqing81/AP-AOS/actions/runs/<id>/jobs`；判断 `git push` 是否成功用 `git ls-remote origin main`（`origin/main` 本地跟踪 ref 会滞后，别拿它当远端真相）。
6. **上游参考克隆**：`.tmp/wess-apa`（`wess09/AzurPilot-for-Android`，230 提交，`[blob:none]` 部分克隆，按需拉 blob，`--numstat`/`--stat` 类命令会超时，用 `--name-only`）。
