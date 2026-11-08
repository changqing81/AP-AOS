# 2026-11-08 · 安卓壳路线拍板 + Repository auto 分流

## 结论

1. **路线拍板（用户确认）**：AP-AOS 维持自家壳（WebView + PyWebIO，端口 22267）；放弃把 wess09 原生 Compose UI 接到 changqing81/Azurpilot-Auto 的路线——他的原生 UI 数据通道绑死 `module/api/` FastAPI WebSocket 网关（31 文件），该层在你的仓库 dev/master 均不存在（GitHub API 404 实测），移植等于把 wess09/AzurPilot 的新架构整个搬过来。
2. **「截图里看不到我的功能」的根因**：那张截图是 wess09 的 App + 他的运行时（出厂种子 wess09/AzurPilot + dev + pypi.org）。你的独特功能全在 PyWebIO WebUI 侧，他的壳不渲染 PyWebIO，永远显示不了。AP-AOS 的壳恰好能显示全部。
3. **内部源与镜像现状（此前已完成，本轮核实）**：
   - build-rootfs.sh:56 flavor=azurpilot → `changqing81/Azurpilot-Auto.git@master`（CI 钉最新 commit）
   - build-rootfs.sh:79 UPDATE_REPO → gitcode `gcw_BYvq9jGu/AzurPilot`（ls-remote 实测 dev=master=92c81dc 与 GitHub 同步）
   - deploy seed PyPI 镜像 → aliyun

## 本轮改动

| 文件 | 改动 |
|---|---|
| `rootfs/seeds/deploy-azurpilot.yaml` | `Deploy.Git.Repository`: 钉死 GitHub URL → `auto`（CN→gitcode，其余→GitHub，检测失败回落 GitHub）；注释第 5 条重写 |

**验证**：本机 AzurPilot venv（D:/alas/AzurPilot）跑真实 `config_redirect` + monkeypatch get_country_code：CN→gitcode ✓ / 海外→GitHub ✓ / 检测失败→GitHub ✓ / 具体 URL 保留 ✓。

## 下一步

1. commit（只提交 seed + 账册；显式路径，防并发写入）；
2. **push 等用户明确点头**（红线）；
3. push 后 CI 手动触发 rootfs（勾 build_apk）出新 APK；
4. 真机验收：部署设置页 Repository 应显示 `auto`（或重定向后的实际值）；挂机页各任务可见 = 你的功能已上机。

## 注意事项

- wess09/AzurPilot-for-Android 的原生 DeploySettingsPage 与 DEPLOY_GROUPS 只是「他的架构」的事实，不要试图往你的仓库塞 module/api——除非将来重新拍板走原生 UI 路线。
- 本机到 GitHub 的 git 协议连接极不稳（Connection was reset 频发）；api.github.com 的 web 前端可用。拉上游文件优先 contents API（base64）。
- 验证脚本曾两次误读「本机 config/deploy.yaml 的属性」当「seed 合并结果」——DeployConfig.__init__ 读的是本机配置文件；测 redirect 必须显式 object.__setattr__ 喂值。
