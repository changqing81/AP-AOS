#!/bin/bash
# =============================================================================
# AlasAos · ALAS 热更新（rootfs 内由 App 侧 AlasUpdater 经 proot 拉起）
#
# 只拉 ALAS 源码，不动依赖（InstallDependencies:false 已锁死 pip）。
# deploy.yaml 里 ALAS 内置更新器已被 AutoUpdate:false 锁死，
# 本脚本是设备上唯一的 ALAS 更新通道。
#
# 双通道（2026-09-18 起，按优先级）：
#   1. CDN pack（seeds/cdn_update.py，复刻上游 git_over_cdn 协议）：
#      latest.json(3s) → 有更新才下 {latest}/{current}.zip 增量 pack（仅 ~400KB，
#      git 浅树的零头），落 .git/objects/pack + refs 后统一 reset --hard。
#      404/403（无此增量包）或 CDN 不可达 → 回落通道 2。
#   2. git://git.lyoko.io（9418 裸 TCP，运营商限速下 fetch 曾连续烧满 240s 超时，
#      只作兜底）：ls-remote(60s) 比对 → 需要才 fetch --depth(240s)。
#
# 失败退避：两通道都失败 → 记当天日期到 $FAIL_FILE，当天后续启动直接跳过
# （弱网/镜像抽风时开机不再每天烧 N 次 4 分钟）；次日自动恢复检查。
#
# 补丁重放不在本脚本职责内：git reset 会把上游跟踪文件打回原版，
# App 侧在收到 UPDATED 后重放 assets/alas（patches/module、patches/assets、
# overlays/rpc.py）并重跑 assets_fix.py。
#
# 与 App 的协议：最后一行打印三态之一，UPDATED/UNCHANGED 退出码 0，FAILED 退出码 1。
# FAILED（断网/超时/镜像不可达）由 App 降级为"跳过更新"，不阻塞启动。
#
# 环境变量（均可 export 覆盖，冒号后为默认值）：
#   ALASAOS_ALAS_ROOT      /opt/alas
#   ALASAOS_UPDATE_REPO    git://git.lyoko.io/AzurLaneAutoScript
#   ALASAOS_UPDATE_BRANCH  master
#   ALASAOS_UPDATE_DEPTH   50
#   ALASAOS_UPDATE_TIMEOUT 240（秒；首次 fetch 需整棵浅树，弱网可调大）
#   ALASAOS_UPDATE_NO_CDN  置非空则跳过 CDN 通道（排障用）
# =============================================================================
set -uo pipefail

ALAS_DIR="${ALASAOS_ALAS_ROOT:-/opt/alas}"
BRANCH="${ALASAOS_UPDATE_BRANCH:-master}"
DEPTH="${ALASAOS_UPDATE_DEPTH:-50}"
TIMEOUT="${ALASAOS_UPDATE_TIMEOUT:-240}"
STATE_FILE="$ALAS_DIR/.alasaos_alas_commit"
FAIL_FILE="$ALAS_DIR/.alasaos_update_fail_date"

# ★ 上游源**从 BUILD_MANIFEST 派生**，不再写死 ALAS 的 lyoko 镜像。
# 写死的后果很严重：AzurPilot 的 rootfs 会被 fetch + `git reset --hard` 成
# **ALAS 源码**——整个运行环境被悄悄换成另一个项目，而症状是「更新后一堆怪错」，
# 极难归因（补丁也会随之全部失配）。
MANIFEST="$ALAS_DIR/BUILD_MANIFEST"
if [[ -z "${ALASAOS_UPDATE_REPO:-}" && -f "$MANIFEST" ]]; then
  # 优先 update_repo（**设备侧国内镜像**），缺失才回落 upstream_repo（烘焙源）。
  # 两个字段分开是为了「烘焙走海外、设备走国内」：设备直连 GitHub 会 443 超时
  # （真机实证 Couldn't connect after 31445ms），且镜像通常落后一点，
  # 正好让设备停在已适配的版本上。
  _repo="$(grep -o '"update_repo": *"[^"]*"' "$MANIFEST" | head -1 | sed 's/.*: *"//; s/"$//')"
  if [[ -z "$_repo" ]]; then
    _repo="$(grep -o '"upstream_repo": *"[^"]*"' "$MANIFEST" | head -1 | sed 's/.*: *"//; s/"$//')"
  fi
  if [[ -n "$_repo" ]]; then
    ALASAOS_UPDATE_REPO="$_repo"
    echo "[update] 上游源取自 BUILD_MANIFEST: $_repo"
  fi
fi
REPO="${ALASAOS_UPDATE_REPO:-git://git.lyoko.io/AzurLaneAutoScript}"

# 终态失败才记退避：通道内回落不算失败
fail() { date +%F > "$FAIL_FILE" 2>/dev/null; echo "FAILED $1"; exit 1; }

cd "$ALAS_DIR" || fail "cd $ALAS_DIR"

# 当前 commit：优先 state 文件（上次更新写入），否则 BUILD_MANIFEST 的烘焙钉版
current=""
if [[ -f "$STATE_FILE" ]]; then
  current="$(cat "$STATE_FILE")"
elif [[ -f BUILD_MANIFEST ]]; then
  # 字段名 M1 起为 upstream_commit（旧烘焙的 manifest 仍是 alas_commit，两个都认）
  current="$(grep -oE '"(upstream|alas)_commit": *"[0-9a-f]{40}"' BUILD_MANIFEST | grep -o '[0-9a-f]\{40\}' | head -1)"
fi

# 失败退避：今天已败过一次就不再烧超时（次日自动恢复）
today="$(date +%F)"
if [[ -f "$FAIL_FILE" && "$(cat "$FAIL_FILE" 2>/dev/null)" == "$today" ]]; then
  echo "UNCHANGED backoff-until-tomorrow current=${current:-unknown}"
  exit 0
fi

if [[ ! -d .git ]]; then
  git init -q . || fail "git init"
  git remote add origin "$REPO" || fail "git remote add"
fi

# 上次被杀的 fetch/reset 可能留锁（App 侧启动清理也会扫一遍，这里双保险）
find .git -name '*.lock' -delete 2>/dev/null

# ---------- 通道 1：CDN pack ----------
# 该通道复刻的是 **ALAS 官方 git_over_cdn 协议**（latest.json + 增量 zip，托管在 ALAS
# 自己的 CDN 上），**只对 lyoko 那个仓库有效**。换成其他上游（AzurPilot）没有对应
# CDN，直接跳过，免得白跑一次 404/超时。
if [[ -z "${ALASAOS_UPDATE_NO_CDN:-}" && "$REPO" == *lyoko* ]]; then
  cdn_out="$(python3 seeds/cdn_update.py "$ALAS_DIR" "$current" 2>&1)"; cdn_rc=$?
  echo "$cdn_out" | sed 's/^/  /'
  cdn_last="$(echo "$cdn_out" | tail -1)"
  if [[ $cdn_rc -eq 0 && "$cdn_last" == "UPTODATE" ]]; then
    echo "$current" > "$STATE_FILE"
    echo "UNCHANGED $current (cdn)"
    exit 0
  elif [[ $cdn_rc -eq 0 && "$cdn_last" == PACK_READY\ * ]]; then
    new="${cdn_last#PACK_READY }"
    git reset --hard origin/"$BRANCH" || fail "reset --hard $new (cdn)"
    echo "$new" > "$STATE_FILE"
    rm -f "$FAIL_FILE"
    echo "UPDATED $new (cdn)"
    exit 0
  fi
  echo "  cdn| 通道不可用（$cdn_last），回落 git://"
fi

# ---------- 通道 2：git:// 兜底 ----------
# 快进路径：ls-remote 直取远端 HEAD（无需本地仓库对象，秒级），
# 与当前一致就连 fetch 都免了——已是最新的常态下热更新必须零下载
remote_head="$(timeout 60 git ls-remote origin "$BRANCH" | head -1 | cut -f1)"
[[ -z "$remote_head" ]] && fail "ls-remote"
if [[ "$remote_head" == "$current" ]]; then
  echo "$remote_head" > "$STATE_FILE"
  echo "UNCHANGED $remote_head"
  exit 0
fi

# 首次更新本地没有对象：只取单提交树先把更新跑完（后续 fetch 会按需加深历史）
if [[ ! -f .git/FETCH_HEAD && ! -f .git/shallow ]]; then
  DEPTH=1
fi

timeout "$TIMEOUT" git fetch --depth "$DEPTH" origin "$BRANCH" || fail "fetch"
new="$(git rev-parse FETCH_HEAD)" || fail "rev-parse FETCH_HEAD"

if [[ "$new" == "$current" ]]; then
  echo "$new" > "$STATE_FILE"
  echo "UNCHANGED $new"
  exit 0
fi

git reset --hard FETCH_HEAD || fail "reset --hard $new"
echo "$new" > "$STATE_FILE"
rm -f "$FAIL_FILE"
echo "UPDATED $new"
exit 0
