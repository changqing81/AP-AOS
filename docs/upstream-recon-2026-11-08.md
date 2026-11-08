# 上游优质提交侦察（2026-11-08）

> 只读侦察结论；移植均按「文件对位手工改写」执行（铁律 0：不 merge / 不 cherry-pick）。

## 线 1：wess09/AzurPilot-for-Android（e6ac801..a944e2e，113 条有效）

### 判定为「本地已有」
| 上游提交 | 内容 | 本地证据 |
|---|---|---|
| 055266c/8e33253/e6337cf 等 | keepalive/帧卡踢活/日志落盘 | 2026-10-07 已采纳（commit 66d8e55/1e806f8/b6354fe） |
| a2446d3 等 check 类 | 自动 upstream 检查 | 我方 CI 手动触发，不需要 |

### 判定为「依赖断链」
| 上游提交 | 内容 | 断链点 |
|---|---|---|
| 049e12c | 共享内存截帧 | 依赖他壳的 LocalSocket 帧服务 com.azurpilot.ghio.frames.v1，我壳无此服务 |
| 004c6ba/349433e | CNB 热更新/Node.js 打包 | 绑他的 CNB release 通道 |
| 8ff7556/0c5d0f3 等 | CNB 构建 | 我用 GHA |

### 判定为「本地已解决/不适用」
| 上游提交 | 内容 | 判定依据 |
|---|---|---|
| 73133fc/b20a1ce/e770b74 | NTP 后台校时防阻塞 | **你的源 time_source.refresh 已是后台线程+立即返回**（docstring「调用线程绝不联网」）；wrapper/runner 无 fork 场景，进程状态重置不需要 |
| f9d5727 | 口令/部署设置保留 | 我壳不写 deploy.yaml（实证 ProotHost/wrapper 均 0 写入）；seed 钉死口令 null |
| ec7eb4e | 升级保留 deploy.yaml | 同上：deploy.yaml 只由构建期 seed 写，运行期零写入，升级重解压语义正确 |
| a944e2e/b162cf8 | config compat 包装 | 我源无 module/api，desktop→android 配置导入不适用 |
| 2c1b9af/81fd1d3/6f5e541 等 MTK NPU 系列 | OCR 硬件加速 | 我走 RapidOCR in-proc CPU，无 MTK 编译链；且这些绑定他壳 OCR 网关 |

### 结论
wess09 线本轮**无可移植净收益**——他 rootfs 层的演进全部围绕「新架构 + 他的壳」，
我方架构（PyWebIO+WebView+自有注入）已在等价问题上各自我修。

## 线 2：Shinarin/ALAS-AOS（adc9f19a..711dd1fb，27 条，同包名同构）

### 建议移植（用户未拍板，待点头）
| 提交 | 内容 | 工作量 |
|---|---|---|
| 9be72778 | 镜像源切换 UI（AlasMirror+settings 六件套+UI）+ 热更新进度旁路 + seed 三件 | 约 20 文件，半天 |
| f6eb30f9 | WebView 退后台暂停+空闲退避轮询+日志节流 | 7 文件 |
| 3e8d7ee9 | wrapper 日志统计 O(1) | 4 文件 |
| 9a756584 | Shizuku 引导补齐 | 8 文件（本地有旧版） |

### 跳过
- 大扫除六连（批次A-E）：对象是他的死代码，本仓无对应
- fullcn 适配（5b54c7da）：给 ALAS 上游的，本仓已换 Azurpilot-Auto
- OCR 门禁（208d6b4f）：本仓 flavor=azurpilot 跳过门禁

## CI 状态（同日）

- run 42480393356 **全绿**：apk-debug artifact 688.4MB（你的 master@92c81dc + auto 分流 + 挂载重构兼容），11-22 过期
- 修复链：42479355239（seed_config KeyError）→ 402f748 修复 → 42479793006（门禁 FAIL）→ 49c891c 修复 → 42480393356 ✅
