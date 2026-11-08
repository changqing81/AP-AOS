# 2026-11-08 深夜 · 真机双症修复（keepalive 自环 + rootfs 升级闸门）

## 用户反馈（21:43 日志包）

1. UI 严重卡顿（带全部界面）
2. 模拟器设置页截图/控制下拉没有 alasaos 桥选项 → runner 崩溃循环

## 根因（全部日志实证，见 debug.md 同日两条）

| 症 | 根因 | 修复 |
|---|---|---|
| 卡顿 | Sticky.onStartCommand→ping→startService 自环（81 次/秒 ×2.5min） | 上游 1b184f1 对位改写：去 ping + bindService 去重 |
| 无桥选项 | ROOTFS_VERSION 恒 0.2.0 → 升级包跳过解压 → 旧 regen_args 锚旧位 | 版本→0.3.0 + Provisioner「version\|build_time」复合指纹 |

commit `c5403e4`（5 文件）。CI：run 42488289550（勾 build_apk）进行中。

## 下一步

1. 等 run 42488289550 绿 → 下载 apk-debug
2. **用户重装新包**（marker 指纹必变 → 必然重新解压 rootfs，约 770MB 数分钟）
3. 复验：桥选项出现 + 选桥后 runner 不再崩 + UI 不卡（onStartCommand 频率正常）
4. Shinarin 四条移植候选仍待拍板（镜像切换 UI 那条现在更有价值——与本次「升级不生效」正交）
