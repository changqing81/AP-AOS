#!/bin/bash
# =============================================================================
# AlasAos · 环境自检修复（rootfs 内由 App 侧 ProotHost 经 proot 拉起，每次启动跑）
#
# 职责（全幂等，失败只告警不阻塞启动）：
# 1) imageio 钉回上游 requirements.txt 的 2.27.0：imageio 2.35+ 把 P 模式 GIF 统一
#    解码成 RGB 3 通道，campaign 选关模板匹配时 cv2 通道断言直接崩（T2 真机根因 =
#    环境未按上游钉版，非 ALAS 代码问题）。已部署 rootfs 靠本脚本就地降级，不必
#    重烘焙；烘焙侧 build-rootfs.sh 已同步钉版（'imageio==2.27.0'）。
# 2) 把被旧构建补丁盖过的 module/base/template.py 用 git 还原成钉版上游原版
#    （烘焙是深度 1 克隆，本地含 commit 对象，离线字节级还原；补丁机制此后不再
#    覆盖该文件）。只还原显式白名单路径——overlay 里的合法补丁（base.py /
#    connection.py / rpc.py 等）每次启动由 AlasOverlay 重铺，绝不整树 checkout。
#
# 输出：env_fix: 前缀行进 runGuest 回收输出（App 侧 Timber 落日志）；
# 并在 ./log/env_fix.txt 追加一行当次记录（wrapper /logs 按 mtime 可取到）。
# =============================================================================
set -u

ALAS_DIR="${ALASAOS_ALAS_ROOT:-/opt/alas}"
cd "$ALAS_DIR" || { echo "env_fix: WARN cd $ALAS_DIR failed"; exit 0; }

# M1 起依赖装在 uv 托管的 venv 里，**系统 python3 没有依赖** —— 必须用 venv 解释器，
# 否则下面 `import imageio` 必然失败、pip 也会装到错误的解释器上。
# 路径必须与 build-rootfs.sh 的 GUEST_PYTHON 及 App 侧 ProotHost.GUEST_PYTHON 同源。
PY="${ALASAOS_GUEST_PYTHON:-$ALAS_DIR/.venv/bin/python}"
if [ ! -x "$PY" ]; then
  echo "env_fix: WARN venv python 不存在（$PY），回落系统 python3"
  PY="$(command -v python3 || echo /usr/bin/python3)"
fi

# imageio 目标版本。**flavor 相关，待 M3 定案**：
# 本仓 ALAS 时代钉 2.27.0（2.35+ 把 P 模式 GIF 解成 RGB 3 通道 → campaign 选关模板
# 匹配时 cv2 通道断言崩，T2 真机根因）；而 Azurpilot 自己钉的是 2.26.0。
# 该问题在 Azurpilot 下是否仍存在尚未验证，故做成可覆盖，默认沿用 2.27.0。
WANT="${ALASAOS_IMAGEIO_VERSION:-2.27.0}"
MIRROR="${ALASAOS_PYPI_MIRROR:-https://mirrors.aliyun.com/pypi/simple}"

# 进度留痕到文件：proot 管道 stdout 可能被块缓冲（进程被杀时丢失），
# 设备侧排查以 log/env_fix.txt 为准（wrapper /logs 按 mtime 可取）
mkdir -p log
mark() { echo "$(date '+%F %T') $1" >> log/env_fix.txt; echo "env_fix: $1"; }

mark "start"
cur="$("$PY" -c 'import imageio; print(imageio.__version__)' 2>/dev/null)"
if [ "$cur" = "$WANT" ]; then
  mark "imageio already $WANT"
else
  mark "imageio ${cur:-missing} -> $WANT, pip install..."
  # proot 下 pip 比原生慢 5~10 倍（ptrace 拦截 + 首次要解依赖/下 wheel），
  # 单次请求超时按 120s 给足；外层 ProotHost.ENV_FIX_TIMEOUT_MS 已是 300s。
  # 原先的 --timeout 15 --retries 2 在慢网/无网下 40 余秒就放弃，
  # 日志表现为「pip install failed（保留现状不阻塞启动）」——真机实测（2026-09-25）。
  # venv 内不需要 --break-system-packages
  "$PY" -m pip install -q --no-cache-dir \
    --timeout 120 --retries 3 --disable-pip-version-check \
    -i "$MIRROR" "imageio==$WANT" \
    || mark "WARN pip install failed（保留现状不阻塞启动）"
fi
now="$("$PY" -c 'import imageio; print(imageio.__version__)' 2>/dev/null)"
[ "$now" = "$WANT" ] || mark "WARN imageio verify = ${now:-missing}"

# 白名单还原：仅 module/base/template.py（T2 旧补丁从资产中删除后，设备上遗留的覆盖件）
# 注意：该文件是 **ALAS 侧的历史遗留**；flavor=azurpilot 下可能不存在，此时直接 skip
# （不做 checkout，免得刷 WARN restore-failed 误导排查）。
tstate="skip(no .git)"
if [ ! -f module/base/template.py ]; then
  tstate="skip(no such file)"
elif [ -d .git ]; then
  if git -c safe.directory='*' diff --quiet HEAD -- module/base/template.py 2>/dev/null; then
    tstate="clean"
  else
    if git -c safe.directory='*' checkout -- module/base/template.py 2>/dev/null; then
      tstate="restored"
    else
      tstate="WARN restore-failed"
    fi
  fi
fi
mark "template.py $tstate"
mark "done imageio=${now:-?} template=$tstate"
exit 0
