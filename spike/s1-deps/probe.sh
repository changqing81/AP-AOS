#!/usr/bin/env bash
# =============================================================================
# AP-AOS · M0-S1 探针：Azurpilot-Auto 依赖在 Ubuntu 26.04 + aarch64 + Python 3.14 上能否装成
#
# 定位：**独立探针**。不改动 build-rootfs.sh / rootfs.yml / 任何既有资产，独立工作目录，
# 产物只有一份日志。目的：在正式改造构建链之前，先回答「依赖装不装得上」这条生死线。
#
# 为什么放在 spike/ 而不是 rootfs/build/：`rootfs.yml` 的触发条件是 push 到 `rootfs/**`，
# 探针放进去会误触发一次 120 分钟的全量 rootfs 构建。spike/ 是阶段〇实验代码的既定位置。
#
# 为什么需要它：Azurpilot-Auto 的 pyproject 声明 requires-python = ">=3.14.6,<3.15"，
# 而本仓现有 rootfs 是 Python 3.12 → 必须换 base 到 Ubuntu 26.04。换 base 后依赖面是否
# 还成立，只有真在 aarch64 上装一遍才知道。
#
# 运行环境：GitHub Actions `ubuntu-24.04-arm` runner（原生 aarch64，chroot 无需 qemu）。
# 本机（Windows + Git Bash）不可执行——核心动作是 chroot / mount --bind / GNU tar；
# 本机只做 `bash -n` 语法检查。
#
# 环境变量（冒号后为默认值）：
#   PROBE_WORK          $GITHUB_WORKSPACE/probe-work
#   PROBE_BASE_URL      cdimage ubuntu-base 26.04.1 LTS arm64
#   PROBE_BASE_SHA256   5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd
#                       （文件名与 sha256 取自官方 SHA256SUMS，硬钉防上游替换）
#   PROBE_PYPROJECT     Azurpilot-Auto master 的 pyproject.toml（只取单文件，不 clone 整仓）
#   PROBE_PYPI_MIRROR   https://pypi.org/simple
# =============================================================================
set -uo pipefail

PROBE_WORK="${PROBE_WORK:-${GITHUB_WORKSPACE:-$PWD}/probe-work}"
PROBE_BASE_URL="${PROBE_BASE_URL:-https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04.1-base-arm64.tar.gz}"
PROBE_BASE_SHA256="${PROBE_BASE_SHA256:-5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd}"
PROBE_PYPROJECT="${PROBE_PYPROJECT:-https://raw.githubusercontent.com/changqing81/Azurpilot-Auto/master/pyproject.toml}"
PROBE_PYPI_MIRROR="${PROBE_PYPI_MIRROR:-https://pypi.org/simple}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOTFS_DIR="$PROBE_WORK/rootfs"
LOG="$PROBE_WORK/probe-s1.log"

# chroot / mount 需要 root；GHA runner 有免密 sudo，自提权（-E 保留环境变量）。
# 注意：提权必须在 tee 之前——exec 替换进程会让进程替换的 tee 变孤儿。
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E bash "$REPO_ROOT/spike/s1-deps/probe.sh" "$@"
fi

mkdir -p "$PROBE_WORK"
exec > >(tee "$LOG") 2>&1

say() { echo "[probe-s1] $*"; }
hr()  { echo "-------------------------------------------------------------------------------"; }

hr; say "开始 M0-S1 探针"; say "工作目录: $PROBE_WORK"; hr

if [[ "$(uname -m)" != "aarch64" ]]; then
  say "!! 宿主架构 $(uname -m) 非 aarch64，本探针设计运行于 GHA ubuntu-24.04-arm，chroot 预计失败"
fi

chroot_run() {
  chroot "$ROOTFS_DIR" /usr/bin/env -i \
    HOME=/root LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
    GIT_TERMINAL_PROMPT=0 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$@"
}

# ---------- 1. 下载并校验 ubuntu-base 26.04.1 ----------
BASE_TAR="$PROBE_WORK/ubuntu-base-26.04.1-arm64.tar.gz"
if [[ ! -f "$BASE_TAR" ]]; then
  say "下载 base: $PROBE_BASE_URL"
  curl -fL --retry 3 -o "$BASE_TAR" "$PROBE_BASE_URL" || { say "!! base 下载失败"; exit 1; }
fi
GOT_SHA="$(sha256sum "$BASE_TAR" | awk '{print $1}')"
if [[ "$GOT_SHA" != "$PROBE_BASE_SHA256" ]]; then
  say "!! base sha256 不符：期望 $PROBE_BASE_SHA256，实得 $GOT_SHA"
  exit 1
fi
say "base sha256 校验通过: $GOT_SHA"

rm -rf -- "${ROOTFS_DIR:?}/"
mkdir -p "$ROOTFS_DIR"
tar -xzf "$BASE_TAR" -C "$ROOTFS_DIR" || { say "!! base 解包失败"; exit 1; }

# ---------- 2. 挂载（trap 兜底卸载） ----------
MOUNTED=()
mount_bind() { mount --bind "$1" "$2" && MOUNTED+=("$2"); }
cleanup_mounts() {
  local i
  for (( i=${#MOUNTED[@]}-1; i>=0; i-- )); do
    umount -lf "${MOUNTED[i]}" 2>/dev/null || true
  done
  MOUNTED=()
}
trap cleanup_mounts EXIT

rm -f "$ROOTFS_DIR/etc/resolv.conf"
touch "$ROOTFS_DIR/etc/resolv.conf"
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > "$PROBE_WORK/resolv.conf"
mount_bind "$PROBE_WORK/resolv.conf" "$ROOTFS_DIR/etc/resolv.conf"
mkdir -p "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"
mount_bind /dev "$ROOTFS_DIR/dev"
mount_bind /dev/pts "$ROOTFS_DIR/dev/pts"
mount_bind /proc "$ROOTFS_DIR/proc"
mount_bind /sys "$ROOTFS_DIR/sys"

# ---------- 3. apt：最小系统依赖 ----------
# 刻意不含 libgl1 / libglx：本仓走 opencv-python-headless，装了 libGL 反而掩盖问题
hr; say "步骤 3 · apt 最小依赖"
chroot_run apt-get update -qq || { say "!! apt-get update 失败"; exit 1; }
chroot_run apt-get install -y --no-install-recommends -qq \
  python3 python3-venv python3-pip curl ca-certificates git xz-utils \
  libglib2.0-0t64 libgomp1 \
  || { say "!! apt install 失败"; exit 1; }
chroot_run /bin/bash -c 'rm -rf /var/lib/apt/lists/*'

# ---------- 4. 环境事实 ----------
hr; say "步骤 4 · 环境事实"
PY_FULL="$(chroot_run python3 -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
GLIBC="$(chroot_run /bin/bash -c 'ldd --version | head -1')"
OS_PRETTY="$(chroot_run /bin/bash -c 'grep PRETTY_NAME /etc/os-release' 2>/dev/null || echo unknown)"
say "OS            : ${OS_PRETTY:-unknown}"
say "Python        : $PY_FULL"
say "glibc         : $GLIBC"
say "架构          : $(chroot_run python3 -c 'import platform; print(platform.machine())')"

PY_GATE="$(chroot_run python3 - <<'PY'
import sys
v = sys.version_info[:3]
ok = v >= (3, 14, 6) and v < (3, 15)
print('PASS' if ok else 'FAIL (need >=3.14.6,<3.15, got %s)' % '.'.join(map(str, v)))
PY
)"
say "requires-python 门禁: $PY_GATE"

# ---------- 5. 装 uv（已核实有 py3-none-manylinux_2_17_aarch64 轮子） ----------
hr; say "步骤 5 · 安装 uv"
if ! chroot_run python3 -m pip install --break-system-packages --no-cache-dir -q \
      -i "$PROBE_PYPI_MIRROR" uv; then
  say "!! uv 安装失败"
  exit 1
fi
UV_VER="$(chroot_run uv --version 2>&1)"
say "uv: $UV_VER"

# ---------- 6. 取上游 pyproject.toml（只取单文件，不 clone 整仓） ----------
hr; say "步骤 6 · 取上游 pyproject.toml"
mkdir -p "$ROOTFS_DIR/opt/probe"
if ! chroot_run curl -fsSL -o /opt/probe/pyproject.toml "$PROBE_PYPROJECT"; then
  say "!! pyproject 拉取失败: $PROBE_PYPROJECT"
  exit 1
fi
say "已取到，行数: $(chroot_run /bin/bash -c 'wc -l < /opt/probe/pyproject.toml')"

# ---------- 7. 从 pyproject 抽依赖清单（含 opencv 变体替换） ----------
# 用 tomllib 解析而非硬编码清单，保证忠实于上游；平台 marker 原样透传，
# 由 uv 按当前平台自行求值（win32/mac 专属项会被自动跳过）。
hr; say "步骤 7 · 抽依赖清单（opencv-python → opencv-python-headless）"
if ! chroot_run python3 - <<'PY'
import json
import pathlib
import re
import tomllib

p = pathlib.Path('/opt/probe/pyproject.toml')
data = tomllib.loads(p.read_text(encoding='utf-8'))
proj = data.get('project', {})
deps = list(proj.get('dependencies', []) or [])
opt = {k: v for k, v in (proj.get('optional-dependencies') or {}).items()}


def to_headless(spec: str) -> str:
    """opencv-python -> opencv-python-headless（跳过已 headless 的）。
    本仓 rootfs 刻意不装 Qt/X11，opencv-python 轮子链接 libGL，import cv2 会炸。"""
    if re.match(r'^opencv-python(\s|==|>=|<=|~=|>|<|$)', spec) and 'headless' not in spec:
        return re.sub(r'^opencv-python', 'opencv-python-headless', spec, count=1)
    return spec


patched, subs = [], []
for d in deps:
    n = to_headless(d)
    if n != d:
        subs.append(f'{d}  ->  {n}')
    patched.append(n)

pathlib.Path('/opt/probe/requirements.txt').write_text('\n'.join(patched) + '\n', encoding='utf-8')

uv_cfg = data.get('tool', {}).get('uv', {})
overrides = uv_cfg.get('override-dependencies') or []
if overrides:
    pathlib.Path('/opt/probe/overrides.txt').write_text('\n'.join(overrides) + '\n', encoding='utf-8')

print(f'  requires-python : {proj.get("requires-python")}')
print(f'  dependencies    : {len(deps)} 条')
print(f'  optional groups : {list(opt)}')
print(f'  [tool.uv] 存在  : {"是" if uv_cfg else "否"}')
for k in ('index', 'package', 'override-dependencies'):
    if k in uv_cfg:
        print(f'    tool.uv.{k} = {json.dumps(uv_cfg[k], ensure_ascii=False)[:200]}')
print(f'  opencv 替换     : {subs or "无需替换"}')
PY
then
  say "!! 依赖清单抽取失败"
  exit 1
fi

hr; say "requirements.txt 内容（已替换 opencv 变体）："
chroot_run /bin/bash -c 'cat -n /opt/probe/requirements.txt'

# ---------- 8. 通道 A：uv venv + uv pip install（主路径） ----------
hr; say "步骤 8 · 通道 A：uv venv + uv pip install"
chroot_run uv venv /opt/probe/venv --python /usr/bin/python3 2>&1 | tail -5
say "venv python: $(chroot_run /opt/probe/venv/bin/python -c 'import platform;print(platform.python_version())' 2>&1)"

UV_PIP_EXTRA=()
[[ -f "$ROOTFS_DIR/opt/probe/overrides.txt" ]] && UV_PIP_EXTRA=(--override /opt/probe/overrides.txt)

set +e
chroot_run uv pip install --python /opt/probe/venv/bin/python \
  -i "$PROBE_PYPI_MIRROR" -r /opt/probe/requirements.txt "${UV_PIP_EXTRA[@]}"
RC_UV_PIP=$?
set -e
say "通道 A 退出码: $RC_UV_PIP"

# ---------- 9. 通道 B：uv sync（保真度测试，非致命） ----------
# 测试「上游没有 uv.lock 时能否从 pyproject 直接解析」——本仓 adopt uv 的关键未知。
hr; say "步骤 9 · 通道 B：uv sync（无 uv.lock，信息性）"
mkdir -p "$ROOTFS_DIR/opt/probe/proj"
cp "$ROOTFS_DIR/opt/probe/pyproject.toml" "$ROOTFS_DIR/opt/probe/proj/pyproject.toml"
set +e
chroot_run /bin/bash -c 'cd /opt/probe/proj && uv sync --no-dev 2>&1 | tail -25'
RC_UV_SYNC=$?
set -e
say "通道 B 退出码: $RC_UV_SYNC（非致命；仅用于判断是否必须自建 lockfile）"

# ---------- 10. import 门禁 ----------
# 核心组硬失败；次要组只报告（不因单个次要包失败而否定整条通道）
hr; say "步骤 10 · import 门禁"
GATE_RC=0
for PYEXE in /opt/probe/venv/bin/python /usr/bin/python3; do
  say "--- 用 $PYEXE 跑门禁 ---"
  set +e
  chroot_run "$PYEXE" - <<'PY'
import importlib
import sys

CORE = [
    ('cv2', 'opencv'), ('numpy', 'numpy'), ('scipy', 'scipy'), ('PIL', 'pillow'),
    ('lxml.etree', 'lxml'), ('yaml', 'pyyaml'), ('pywebio', 'pywebio'),
    ('uvicorn', 'uvicorn'), ('fastapi', 'fastapi'), ('pydantic', 'pydantic'),
    ('imageio', 'imageio'), ('rich', 'rich'), ('requests', 'requests'),
    ('onnxruntime', 'onnxruntime'), ('rapidocr', 'rapidocr'),
    ('adbutils', 'adbutils'), ('uiautomator2', 'uiautomator2'),
    ('cached_property', 'cached-property'), ('websockets', 'websockets'),
    ('aiofiles', 'aiofiles'), ('inflection', 'inflection'), ('tqdm', 'tqdm'),
]
SOFT = [
    ('numba', 'numba'), ('ncnn', 'ncnn'), ('zmq', 'pyzmq'), ('gevent', 'gevent'),
    ('zerorpc', 'zerorpc'), ('matplotlib', 'matplotlib'), ('mcp', 'mcp'),
    ('sse_starlette', 'sse-starlette'), ('aiortc', 'aiortc'),
    ('pypresence', 'pypresence'), ('onepush', 'onepush'), ('jellyfish', 'jellyfish'),
]


def probe(mod):
    try:
        m = importlib.import_module(mod)
    except Exception as e:
        return False, f'{type(e).__name__}: {str(e)[:90]}'
    v = getattr(m, '__version__', None)
    if v is None:
        try:
            from importlib.metadata import version
            v = version(mod.split('.')[0])
        except Exception:
            v = '?'
    return True, str(v)


core_fail = []
print('  [核心组]')
for mod, pkg in CORE:
    ok, info = probe(mod)
    print(f'    {"OK  " if ok else "FAIL"} {mod:18} ({pkg:16}) {info}')
    if not ok:
        core_fail.append(f'{mod} ({pkg}): {info}')
print('  [次要组]')
for mod, pkg in SOFT:
    ok, info = probe(mod)
    print(f'    {"OK  " if ok else "MISS"} {mod:18} ({pkg:16}) {info}')

print()
if core_fail:
    print('  !! 核心组失败项:')
    for f in core_fail:
        print('     -', f)
    sys.exit(1)
print('  ALL_CORE_IMPORTS_OK')
PY
  RC_GATE=$?
  set -e
  say "门禁退出码（$PYEXE）: $RC_GATE"
  [[ $RC_GATE -ne 0 ]] && GATE_RC=1
done

# ---------- 11. 汇总 ----------
cleanup_mounts
hr; say "M0-S1 探针汇总"
say "Ubuntu base       : 26.04.1 LTS (Resolute Raccoon) arm64"
say "Python            : $PY_FULL"
say "glibc             : $GLIBC"
say "requires-python   : $PY_GATE"
say "uv                : $UV_VER"
say "通道 A uv pip     : exit=$RC_UV_PIP"
say "通道 B uv sync    : exit=$RC_UV_SYNC（非致命）"
if [[ $GATE_RC -eq 0 ]]; then say "import 门禁       : PASS"; else say "import 门禁       : FAIL"; fi
say "日志              : $LOG"
hr

if [[ $GATE_RC -ne 0 ]]; then
  say "结论：核心依赖在 aarch64 + Python 3.14 上未能全部 import —— 需排查上方 FAIL 项"
  exit 1
fi
say "结论：核心依赖全部可用，S1 通过（仍需看通道 A/B 退出码决定 adopt uv 的方式）"
exit 0
