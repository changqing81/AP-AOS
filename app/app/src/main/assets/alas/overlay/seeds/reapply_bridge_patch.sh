#!/bin/bash
# =============================================================================
# AlasAos · 桥接补丁自愈（幂等）
#
# 为什么需要
# ----------
# `seeds/azurpilot-android.patch` 改的全是**上游跟踪文件**。任何 `git reset/pull`
# 都会把它们打回原版 → 桥接接线消失 → 截图/控制退回 ADB 设备通道 → 手机上
# 根本连不上游戏。而症状是「连不上设备」，极难联想到补丁（debug.md 有记录）。
#
# reset 的来源有三条：
#   1) App 侧 `alasaos_update.sh`（启动时热更新）
#   2) **GUI（WebUI）开发者菜单里的更新器** —— `module/webui/updater.py` 的
#      `_run_update()` 收尾同样 `git reset/pull`
#   3) 手工 git 操作
#
# App 侧的 `AlasUpdater` 只在**它自己**跑出 UPDATED 时重放补丁
# （ProotHost.replayBridgePatch）；**GUI 内那条路它不知情** —— WebUI 更新走的是
# `updater._trigger_reload()` → `State.restart_event.set()` → gui.py **重启 WebUI
# 子进程**（gui.py 进程本身不退出，只 break 回外层循环）。
#
# 所以本脚本挂在 gui.py 的「外层重启循环入口」（每轮 = 一次 WebUI 启动/重启），
# 这样 GUI 内更新、WebUI 崩溃重拉、App 启动首次，三条路径都被覆盖。
#
# 三态判据（幂等，顺序不能换）
# ----------------------------
#   ① apply --check 能过           → 补丁不在位 → apply
#   ② apply --reverse --check 能过 → 补丁已在位 → 跳过
#   ③ 都不行                       → 上游漂移 → 试 --3way（会写 index，故放最后）
#
# 输出：单行四态之一，供 gui.py 侧记录
#   ALREADY_APPLIED | APPLIED | APPLIED_3WAY | SKIPPED <原因> | FAILED <原因>
#
# 环境变量（冒号后为默认值）
#   ALASAOS_ALAS_ROOT    /opt/alas
# =============================================================================
set -uo pipefail

ALAS_DIR="${ALASAOS_ALAS_ROOT:-/opt/alas}"
PATCH="$ALAS_DIR/seeds/azurpilot-android.patch"

[[ -f "$PATCH" ]] || { echo "SKIPPED 补丁不存在（非 azurpilot flavor）"; exit 0; }
cd "$ALAS_DIR" || { echo "FAILED cd $ALAS_DIR"; exit 1; }
[[ -d .git ]] || { echo "SKIPPED 无 .git（尚未初始化）"; exit 0; }

# 补丁改的是上游跟踪文件；git 以 root 跑，需放开 safe.directory。
# 注意 '*' 必须被引号包住，否则被 shell 当 glob 展开。
if git -c 'safe.directory=*' apply --check "$PATCH" >/dev/null 2>&1; then
  if git -c 'safe.directory=*' apply "$PATCH" >/dev/null 2>&1; then
    echo "APPLIED"
    exit 0
  fi
  echo "FAILED apply 失败（检查工作树是否干净）"
  exit 1
fi

if git -c 'safe.directory=*' apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "ALREADY_APPLIED"
  exit 0
fi

if git -c 'safe.directory=*' apply --3way "$PATCH" >/dev/null 2>&1; then
  echo "APPLIED_3WAY"
  exit 0
fi

echo "FAILED 补丁漂移（上游已改这些文件），桥不可用——建议重下整包"
exit 1
