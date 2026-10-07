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
| B-4 | `66d8e55` | `055266c` | 特权进程日志落盘进导出包（`Ln.java` 文件 sink，Java 重写；`RemoteBootTrace.debugDir`；`RemoteServiceImpl` 启用） | ✅ run `37610634358` 全绿 |
| C-2 | `01c55cd` | `7a8a908` | 虚拟屏帧率可调（16 文件：settings/MVI/UI/AIDL/特权侧/`DisplayManager.java`/strings） | ✅ 随 `d8c04d6` 验证（run `37620078058`） |
| C | `b6354fe` | `e6337cf` | keepalive 多策略保活（13 Kotlin + 1 AIDL，约 1400 行；清单 5 权限 + 组件、`MaaFwApp`、`CoreModule`、无障碍转发、`keepAliveEnabled` 五件套） | ❌ run `37618029394` 失败（`combine` 超参） |
| C | `4f56488` | `e6337cf` | keepalive 的 UI 部分：`KeepAliveCard`（7 状态行）+ 22 条中英文案 | ✅ 随 `d8c04d6` 验证 |
| fix | `d8c04d6` | — | `SettingsViewModel` 的 `combine` 由 6 源回落 5 参（末两项合成 Pair） | 🔄 run `37620078058` 进行中（第 11 步编译） |
| fix | `e0b6210` | — | 补回 `KeepAliveLocalService` / `KeepAliveDaemonService` 清单声明（7/7 对齐上游） | ⏳ **未推** |

**本地 HEAD = `e0b6210`；远端 `origin/main` = `d8c04d6`** → 本地**领先 1 个 commit**（`e0b6210`），**等用户点头才能 push**。

> ⚠️ **`b6354fe` / `4f56488` / `d8c04d6` 是另一个会话代为推送的**（本轮出现两次并发写入，见 §五 第 7、8 条）。

## 三、C 类逐项判定（证据见 diff 文档 §3）

| 提交 | 内容 | 判定 |
|---|---|---|
| `e6337cf` | 多策略后台保活（29 文件 +1434 行，AIDL + Service + Alarm/Job/Broadcast） | ✅ **已做**（`b6354fe` + `4f56488`，另见 §五 第 8 条：曾漏 2 个清单声明，已由 `e0b6210` 补回） |
| `7a8a908` | 虚拟屏帧率 | ✅ **已做**（`01c55cd`） |
| `87c58b6` | 实例配置导入 | ❌ 断链跳过（改 `ui/azurpilot/sections/settings/InstancesPage.kt`，本仓无此原生 UI） |
| `c2994d7` | launcher 快捷方式（9 文件 +314） | 可行，未做 |
| `154859e` / `a584bdd` | 反馈 / 加群入口 | 可行，未做（中低优先） |
| `31b73ba` / `37e5fe2` | splash 圆形遮罩 + 启动图标 | 暂缓（二进制观感类，且会删本仓 mipmap 全套 PNG） |
| `15b7a9b` | ExpressiveLoadingIndicator（+334 行） | ❌ 断链跳过（依赖 `ui/azurpilot/sections/*`） |
| `a7e03ea` | UI 风格设置 | ❌ 跳过（只有 4 份 strings、无配套代码） |

## 四、下一步（按优先级）

1. **push `e0b6210` + 触发 CI**——keepalive 的最终编译验证。`d8c04d6` 的 run `37620078058` 只验到「清单漏声明修复之前」的代码，`e0b6210` 之后必须再跑一次。**push 必须先拿到用户明确点头**（AGENTS.md 第六节 + 用户红线）。
2. **真机验收 keepalive**（本轮完全没上过机）：开关打开后 `dumpsys activity processes | grep daemon` 应能看到 `:daemon` 进程；否则「双进程守护」行仍是谎报。
3. `c2994d7` 快捷方式（需动 `MainActivity.kt` + `ui/AppRoot.kt`，`AppRoot` 两边都大改，谨慎）。
4. `154859e`/`a584bdd` 反馈入口（低优先，含对外链接，需用户确认运营意图）。
5. **修测试源集脱节**（见 `debug.md` 2026-10-07 条目）——范围比原先记录的更大，是一整套系统性失修，不止 `FakeAppSettingsGateway`：
   - `FakeAppSettingsGateway`：缺 `keepAliveEnabled`（接口新增）＋ 6 个孤儿 `override`（`closeAppAfterTask`/`touchPreviewEnabled`/`resolutionPreference`/`wakeUnlockEnabled`/`wakeCredential`/`telemetryEnabled`）＋ 悬空 `import com.aliothmoon.maafw.runner.ResolutionPreference`
   - `EnvironmentHooksTest`：引用 `wakeUnlockEnabled` / `wakeCredential` / `closeAppAfterTask`
   - `MaaFrameworkRunnerPortTest`：引用 `ResolutionPreference.P720`
   - `SessionViewModelTest`：`import com.aliothmoon.maafw.runner.ResolutionPreference`（主源集已无此类）
   → `testDebugUnitTest` 必然编译失败；CI 只跑 `assembleDebug`，所以**一直不可见**。要么整体修，要么在 CI 里补一个单测 job 让它显形。

## 五、关键决策与注意事项

1. **移植方式三分**：路径/包名可对位的用 `git apply`（B-1 的两个文件）；KDoc 上下文不同的手工改；语言不同（上游 Kotlin / 本仓 Java，如 `Ln`、`FakeContext`）必须按本仓语义重写。**一律不能 cherry-pick**。
2. **UI 侧一律要重排**：上游设置页是 `App*` 组件 + `koinInject` 直连；本仓是 `Maa*` 组件 + MVI（`SettingsUiState`/`SettingsIntent`/`AppSettingsGateway`）。C-2 就是按这个重排的。
3. **资源只取两份**：本仓只有 `values`/`values-en`，上游常同改 4 语言（含 `values-ja`/`values-zh-rTW`）→ 只取我们有的两份。
4. **本机工具链确实不存在**（本次再测：`java`/`javac` 都不在 PATH；PATH 里 `D:\softinstall\jdk-18.0.1` 是**失效路径**）→ 编译验证只能走 CI 的 `apk` job（手动触发，`build_apk=true`）。
5. **CI 触发与查状态**：本机 curl 打 `api.github.com` 返回 000（沙箱拦），查 run 状态用 WebFetch 打 `https://api.github.com/repos/changqing81/AP-AOS/actions/runs/<id>/jobs`；判断 `git push` 是否成功用 `git ls-remote origin main`（`origin/main` 本地跟踪 ref 会滞后，别拿它当远端真相）。
6. **上游参考克隆**：`.tmp/wess-apa`（`wess09/AzurPilot-for-Android`，230 提交，`[blob:none]` 部分克隆，按需拉 blob，`--numstat`/`--stat` 类命令会超时，用 `--name-only`）。
7. **⚠️ 并发写入风险（2026-10-07 实际发生）**：本轮 B-4 提交后，`RemoteBootTrace.kt` 在 **17:42:38** 被**另一个进程**再次写入——它独立加了同一个 `debugDir` 成员，与已提交的那份构成**重复声明**（Kotlin redeclaration，必编译失败）。判断为**另一个会话在并行做同一件 B-4 移植**。处置：手工消重，只留一份（`f5e3115` 之后的修复提交）。**教训**：`git add` 用显式路径是对的（没把对方改动扫进我的提交），但**提交前后都要复查 `git status --porcelain`**，发现非本人改动先停手确认，别盲目 `git add -A`，更别抢着 push。
8. **⚠️ 移植 `AndroidManifest.xml` 必须逐组件对账，不能凭「编译过了」就算完（2026-10-07 踩到）**：`b6354fe` 采纳 keepalive 时漏了 `KeepAliveLocalService` / `KeepAliveDaemonService` 两个 `<service>`，**CI 全绿也发现不了**——组件未声明时 `startService` 只让 AMS 打一条 "not found" 日志并返回 null，**不抛异常**；调用点又包在 `runCatching` 里，连兜底日志都不会打。结果是功能静默失效 + **设置页状态行谎报「已激活」**。
   **对账办法（可复用）**：拿上游 commit 的 `--stat` 新增行数与本地比对（本次 62 vs 51，差额 11 行正好是这两段），并逐条列组件名做集合比对，别只看文件是否同名。
9. **本仓 settings 源比上游多一个 → `combine` 会撞 5 参上限（2026-10-07 踩到）**：Kotlin `combine` 只有 2~5 参重载，第 6 个会落到 vararg 重载、lambda 收到 `Array<Any>`，报错形式是 `Argument type mismatch: actual type is 'suspend (Array<Any>, ???)'` 加一串 `Cannot infer type for value parameter`（**看不出是重载问题**）。上游 `e6337cf` 只需 4 个源所以不撞，本仓在 C-2 之后已有 5 个 → 再加一个就爆。修法是末两项先合成 `Pair` 再参与 5 参重载。
