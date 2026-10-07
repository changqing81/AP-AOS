# 上游参考文档：来源与注意事项

> **本目录下的 `.md` 文件是原样收编的第三方文档，不是本项目（AP-AOS）的文档。**
> 引用前请先读本文的「路径与命名对照表」。

## 来源

| 项 | 值 |
|---|---|
| 仓库 | [`wess09/AzurPilot-for-Android`](https://github.com/wess09/AzurPilot-for-Android)（33★，默认分支 `main`） |
| 收编自 | 该仓 `doc/` 目录（14 个文件，约 130KB） |
| 收编时的 commit | `e6ac801cc`（2026-10-07） |
| 收编日期 | 2026-10-07 |
| 许可 | 该仓 fork 自 `Shinarin/ALAS-AOS`，继承 AGPL-3.0（与本项目同源同许可） |

**两仓关系**：同源 fork，共同祖先为 `adc9f19`（2026-09-21，v0.1.4 收官）。此后双方各自独立演进
（他 111 条有效提交 / 我们 42 条）。差异分析见 `docs/upstream-wess09-fork-diff.md`。

## 为什么要收编

这批文档覆盖的都是本项目**正在做但缺文档**的领域，可作为设计参照与排错线索：

| 文档 | 与本项目的关系 |
|---|---|
| `privileged-bridge-protocol.md` | **特权桥协议** —— 本项目桥（22300）的同类设计 |
| `runtime-provisioning.md` | **Runtime 部署与更新** —— 对应本项目 `RootfsProvisioner` |
| `architecture.md` | 系统分层结构 —— 可对照本项目三层进程模型 |
| `hot-update.md` | 运行时热更新架构 |
| `multi-arch.md` | 多架构支持（本项目目前仅 arm64） |
| `release-channel.md` | 固定 Release + `latest.json` 分发通道 |
| `device-reporting.md` | 机型适配提交机制 |
| `adb-e2e-testing.md` | ADB 端到端测试手册 |
| `module-reference.md` | 模块职责与进程边界 |
| `build-profiles.md` | 构建 profile 打包 |
| `development-guide.md` | 新维护者上手 |
| `comment-style.md` | 注释规范 |
| `xiaomi-workstation.md` | 小米澎湃 OS「工作台」适配 |
| `README.md` | 上游自己的文档索引 |

## ⚠️ 路径与命名对照表（**引用时必须转换**）

这些文档描述的是**他的项目**，路径 / 包名 / 端口与本项目**都不同**：

| 概念 | 他的（文档里写的） | 本项目的（实际） |
|---|---|---|
| 上游源码 | `wess09/AzurPilot` | **`changqing81/Azurpilot-Auto`** |
| rootfs 内源码路径 | `/opt/azurpilot` | **`/opt/alas`** |
| App 包名 | `com.azurpilot.ghio` | **`com.aliothmoon.maafw`** |
| App 主类 | `AzurPilotApp` / `AppDispatchers` | **`MaaFwApp` / `MaaDispatchers`** |
| 设备通道名 | `azurpilot_android` | **`alasaos`** |
| WebUI 端口 | 25548 | **22267** |
| rootfs 构建脚本 | `rootfs/build/build-azurpilot.sh` | **`rootfs/build/build-rootfs.sh`** |
| 实例播种脚本 | `rootfs/seeds/seed_azurpilot.py` | **`rootfs/seeds/seed_config.py`** |
| rootfs 入口进程 | `rootfs/overlays/android_host.py` | **`rootfs/overlays/wrapper.py`** → `runner.py` |
| 依赖锁定 | `uv sync --frozen`（有 uv.lock） | `uv sync`（**无 lock**） |
| App 界面形态 | **原生 Compose** + `/api/v1/ws` 网关 | **WebView + pywebio** |

> 特别提示：他的「原生界面」依赖上游的 `module/api/`（WebSocket 网关），
> 而 `changqing81/Azurpilot-Auto` **没有**这个模块 —— 详见 `docs/upstream-wess09-fork-diff.md` §7。

## 使用约定

1. **只作参考，不作依据**：本项目的行为以本仓源码与 `development.md` 为准。
2. **引用时转换路径**：直接照抄文档里的 `/opt/azurpilot` 会指向不存在的位置。
3. **不要修改本目录文件**：如需勘误或提炼，写在本文件或新建项目自有文档，保持原始收编件可追溯。
4. **更新方式**：上游如有更新，重新从其 `doc/` 导出并更新本文的「收编时的 commit」。
