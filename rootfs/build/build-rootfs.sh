#!/usr/bin/env bash
# =============================================================================
# AP-AOS · rootfs 烘焙（M1 上游参数化改造，2026-09-24）
#
# 烘焙 Ubuntu ARM64 rootfs：ubuntu-base 24.04.5 LTS + 上游（Azurpilot/ALAS）
# + uv 托管 Python + 依赖 + OCR 模型 + wrapper/runner/patches
#
# 运行环境：GitHub Actions `ubuntu-24.04-arm` runner（原生 aarch64，chroot 无需 qemu）。
# 本机（Windows + Git Bash）不可执行：核心动作是 chroot / mount --bind / GNU tar，
# Windows 无这些语义；本机只做 `bash -n` 语法检查与 rootfs/ 资产 curated。
#
# ── M1 改造要点（2026-09-24 修订：吸收 wess09/AzurPilot 作者的并行方案）────────
# 1) 上游参数化：UPSTREAM_FLAVOR（azurpilot | azurpilot-upstream | alas）
#    + UPSTREAM_REPO/REF；旧变量名 ALAS_REPO/ALAS_REF 保留为别名。
# 2) **base 保持 Ubuntu 24.04.5，不升 26.04**（修订）。
#    原计划升 26.04 是多余的：26.04 自带的 python3 是 3.14.4，**仍不满足**上游
#    requires-python（>=3.14.6），而换 base 要重新验证整个 apt/系统层。正解是
#    用 uv 的 python-build-standalone 提供解释器（见 3），base 版本与之无关。
# 3) Python 与依赖（修订）：
#    - `uv python install 3.14.6` + **UV_PYTHON_PREFERENCE=only-managed**，确保 uv
#      只用自己托管的解释器，不会被发行版 python 3.14.4 截胡；
#    - 依赖用 **`uv sync`**（读 pyproject 的**全部**配置，含 [tool.uv]
#      override-dependencies —— 上游靠 `packaging==24.2` 这条 override 解开
#      uiautomator2==2.16.17 的 packaging<21 冲突；自己抽 requirements 会漏掉它，
#      首跑 rootfs 构建正是因此失败）；
#    - venv 建在**源码树之外**（/opt/alas-venv，用 UV_PROJECT_ENVIRONMENT 直接建在
#      终位，不靠 mv），再软链 /opt/alas/.venv → ../alas-venv。这样**上游源码热更新
#      不会触碰已验依赖环境**——比自建 CDN 增量包简单得多。
# 4) 体积裁剪：trim_payload()，按 TRIM_LEVEL（conservative | aggressive）裁掉
#    确定不用的模型与 Android 侧推装件（详见该函数注释）。
# 5) BUILD_MANIFEST 契约：alas_* → upstream_*，新增 flavor / guest_python / trim_level。
#    rootfs_version 默认 0.2.0（**必须与上一版不同**，否则设备侧不重解新 rootfs）。
#
# 环境变量（冒号后为默认值）：
#   UPSTREAM_FLAVOR    azurpilot           上游口味（见文件内 flavor 表）
#   UPSTREAM_REPO      <按 flavor 派生>
#   UPSTREAM_REF       master              分支/tag；40 位 sha 则按 commit 浅 fetch
#   PYTHON_VERSION     3.14.6              uv 托管的 Python 版本（需满足上游 requires-python）
#   ROOTFS_VERSION     0.2.0               写入 BUILD_MANIFEST.rootfs_version
#   TRIM_LEVEL         conservative        conservative | aggressive | none
#   UBUNTU_BASE        cdimage ubuntu-base 24.04.5 LTS arm64
#   UBUNTU_BASE_SHA256 a91d5a93…914f2      取自官方 SHA256SUMS（置空则跳过校验）
#   WORK_DIR           $GITHUB_WORKSPACE/work
#
# 产物：
#   $GITHUB_WORKSPACE/dist/rootfs.tar.xz       rootfs 包
#   $GITHUB_WORKSPACE/dist/BUILD_MANIFEST      构建清单（同时装入镜像 /opt/alas/）
# =============================================================================
set -euo pipefail

# ---------- 0. 参数与 flavor 解析 ----------
UPSTREAM_FLAVOR="${UPSTREAM_FLAVOR:-azurpilot}"
case "$UPSTREAM_FLAVOR" in
  # 用户自有 fork（旧架构：pywebio WebUI + module/webui/；无 frontend/、无 module/api/）
  azurpilot)
    _default_repo="https://github.com/changqing81/Azurpilot-Auto.git"
    _default_ref="master"
    ;;
  # 上游主线（新架构：FastAPI module/api/ + React frontend/），AzurPilot 原作者在维护，
  # 活跃度极高。若决定切到新架构，把 UPSTREAM_FLAVOR 改成这个即可（见文档 §15.3）。
  azurpilot-upstream)
    _default_repo="https://github.com/wess09/AzurPilot.git"
    _default_ref="master"
    ;;
  alas)
    _default_repo="https://github.com/LmeSzinc/AzurLaneAutoScript.git"
    _default_ref="master"
    ;;
  *)
    echo "::error::未知 UPSTREAM_FLAVOR: $UPSTREAM_FLAVOR（期望 azurpilot | azurpilot-upstream | alas）"
    exit 1
    ;;
esac
# 旧变量名向后兼容：ALAS_REPO/ALAS_REF 若非空则覆盖
UPSTREAM_REPO="${UPSTREAM_REPO:-${ALAS_REPO:-$_default_repo}}"
UPSTREAM_REF="${UPSTREAM_REF:-${ALAS_REF:-$_default_ref}}"
# 注：GHA runner 在海外，GitHub 原生最快；gitee 同名镜像对匿名克隆要凭证（401），勿用。
# 国内本地复现构建时可 export UPSTREAM_REPO=<可达镜像>；runtime 更新镜像由 deploy.yaml 管。

PYTHON_VERSION="${PYTHON_VERSION:-3.14.6}"
ROOTFS_VERSION="${ROOTFS_VERSION:-0.2.0}"
TRIM_LEVEL="${TRIM_LEVEL:-conservative}"
# base 保持 24.04.5（**不升 26.04**，理由见文件头 2）。sha256 取自官方 SHA256SUMS；
# 置空 UBUNTU_BASE_SHA256 可跳过校验（仅用于本地试验，CI 上不要关）。
UBUNTU_BASE="${UBUNTU_BASE:-https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz}"
UBUNTU_BASE_SHA256="${UBUNTU_BASE_SHA256:-a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$REPO_ROOT}"
WORK_DIR="${WORK_DIR:-$GITHUB_WORKSPACE/work}"
ROOTFS_DIR="$WORK_DIR/rootfs"
ASSETS="$REPO_ROOT/rootfs"          # 本仓 curated 资产
DIST_DIR="$GITHUB_WORKSPACE/dist"

# guest 侧固定路径（**App 侧必须同源**：ProotHost.GUEST_PYTHON）
GUEST_ALAS_ROOT="/opt/alas"
# venv 建在源码树**之外**：上游源码热更新（整目录替换 /opt/alas）时不触碰已验依赖环境。
# /opt/alas/.venv 只是指向它的软链 —— 因此 App 侧 GUEST_PYTHON 仍是
# /opt/alas/.venv/bin/python，三条同源路径不必因这次改造而变。
GUEST_VENV="/opt/alas-venv"
GUEST_VENV_LINK="$GUEST_ALAS_ROOT/.venv"
GUEST_PYTHON="$GUEST_VENV_LINK/bin/python"

# 构建期 pip 源：默认 PyPI 官方（GHA runner 在海外，直连最快最稳）；
# 与设备运行时无关（InstallDependencies 已锁，rootfs 永不在设备上装包）。
PYPI_MIRROR="${PYPI_MIRROR:-https://pypi.org/simple}"

log() { echo "[build-rootfs] $*"; }

# chroot / mount 需要 root；GHA runner 有免密 sudo，自提权（-E 保留环境变量）
if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E bash "$REPO_ROOT/rootfs/build/build-rootfs.sh" "$@"
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
  log "WARNING: 宿主架构 $(uname -m) 非 aarch64；本脚本设计运行于 GHA ubuntu-24.04-arm，chroot 预计将失败"
fi

# ---------- 1. fail-fast：必需资产（并行任务提供） ----------
# 缺任何一个都不许开构建——在下载与 apt 之前先验，省一次白跑
require_file() {
  if [[ ! -f "$1" ]]; then
    echo "::error::必需资产缺失: $1（由并行任务提供，请先落地该文件再触发构建）"
    exit 1
  fi
}
require_file "$ASSETS/overlays/module/ocr/rpc.py"
require_file "$ASSETS/overlays/wrapper.py"
require_file "$ASSETS/overlays/runner.py"
require_file "$ASSETS/build/spike-f-ocr-gate.py"
require_file "$ASSETS/patches/assets_fix.py"
require_file "$ASSETS/seeds/deploy.yaml"
require_file "$ASSETS/seeds/alasaos_update.sh"
require_file "$ASSETS/seeds/regen_args.py"
require_file "$ASSETS/shims/jellyfish.py"
require_file "$ASSETS/models/ocr/det.onnx"
require_file "$ASSETS/models/ocr/rec.onnx"
require_file "$ASSETS/models/ocr/keys.txt"

# chroot 内统一环境：干净 env + 非交互 + C.UTF-8（免 perl locale 警告）
chroot_run() {
  chroot "$ROOTFS_DIR" /usr/bin/env -i \
    HOME=/root LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive \
    GIT_TERMINAL_PROMPT=0 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    UV_CACHE_DIR=/opt/uv-cache \
    UV_PROJECT_ENVIRONMENT="$GUEST_VENV" \
    UV_PYTHON_PREFERENCE=only-managed \
    UV_DEFAULT_INDEX="$PYPI_MIRROR" \
    UV_NO_PROGRESS=1 \
    "$@"
}

log "flavor=$UPSTREAM_FLAVOR repo=$UPSTREAM_REPO ref=$UPSTREAM_REF rootfs_version=$ROOTFS_VERSION trim=$TRIM_LEVEL"

# ---------- 2. 下载并校验 ubuntu-base 24.04.5 ----------
mkdir -p "$WORK_DIR" "$DIST_DIR"
BASE_TAR="$WORK_DIR/ubuntu-base-24.04.5-arm64.tar.gz"
if [[ ! -f "$BASE_TAR" ]]; then
  log "下载 ubuntu-base: $UBUNTU_BASE"
  curl -fL --retry 3 -o "$BASE_TAR" "$UBUNTU_BASE"
fi
if [[ -n "$UBUNTU_BASE_SHA256" ]]; then
  GOT_SHA="$(sha256sum "$BASE_TAR" | awk '{print $1}')"
  if [[ "$GOT_SHA" != "$UBUNTU_BASE_SHA256" ]]; then
    echo "::error::ubuntu-base sha256 不符：期望 $UBUNTU_BASE_SHA256，实得 $GOT_SHA"
    exit 1
  fi
  log "ubuntu-base sha256 校验通过"
else
  log "WARN: UBUNTU_BASE_SHA256 为空，跳过校验（仅限本地试验，CI 上不要关）"
fi

rm -rf -- "${ROOTFS_DIR:?}/"
mkdir -p "$ROOTFS_DIR"
tar -xzf "$BASE_TAR" -C "$ROOTFS_DIR"

# ---------- 3. 挂载准备（trap 兜底卸载；打包前还会显式卸载并校验） ----------
# chroot 老规矩：/dev /proc /sys bind 进去；/dev/pts 单独 bind（bind 不携带子挂载点，
# 而 apt 部分 postinst 需要 pts）。挂载失败 → set -e 中止 → EXIT trap 卸掉已挂部分。
MOUNTED=()
mount_bind() {
  mount --bind "$1" "$2"
  MOUNTED+=("$2")
}
cleanup_mounts() {
  local i
  for (( i=${#MOUNTED[@]}-1; i>=0; i-- )); do
    if ! umount -lf "${MOUNTED[i]}" 2>/dev/null; then
      echo "::warning::umount 失败: ${MOUNTED[i]}（runner 为一次性环境，影响有限，但需记录）"
    fi
  done
  MOUNTED=()
}
trap cleanup_mounts EXIT

# DNS：不能 bind 宿主 /etc/resolv.conf——GHA runner 是 systemd-resolved stub
# （127.0.0.53），chroot 内没有 resolved 监听，解析必挂。写静态 resolv.conf
# （AliDNS + Cloudflare）；ubuntu-base 自带的是指向 /run/systemd 的悬空软链，先删
rm -f "$ROOTFS_DIR/etc/resolv.conf"
touch "$ROOTFS_DIR/etc/resolv.conf"
printf 'nameserver 223.5.5.5\nnameserver 1.1.1.1\n' > "$WORK_DIR/resolv.conf"
mount_bind "$WORK_DIR/resolv.conf" "$ROOTFS_DIR/etc/resolv.conf"
mkdir -p "$ROOTFS_DIR/dev/pts" "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys"
mount_bind /dev "$ROOTFS_DIR/dev"
mount_bind /dev/pts "$ROOTFS_DIR/dev/pts"
mount_bind /proc "$ROOTFS_DIR/proc"
mount_bind /sys "$ROOTFS_DIR/sys"

# ---------- 4. chroot 内 apt：最小系统依赖 ----------
# 修订（吸收 wess09 方案）：**不再回避 libgl1**。原因：rapidocr 声明依赖 `opencv-python`
# （非 headless），会作为传递依赖装进来并与 opencv-python-headless 争同一个 `cv2/` 路径，
# 最终 cv2 需要 libxcb.so.1 —— 无 X11 环境下 import 直接炸（M0-S1 run #35981880600 实测）。
# **libgl1 会连带拉进 libx11/libxcb**，问题自然消失；libvulkan1 让 ncnn 的 Vulkan 后端可用；
# libsndfile1 供音频路径。取舍：约 +10MB，换来不再跟 opencv 变体斗。
chroot_run apt-get update
chroot_run apt-get install -y --no-install-recommends \
  python3 python3-pip python3-venv git ca-certificates curl xz-utils \
  libglib2.0-0t64 libgomp1 libgl1 libstdc++6 libatomic1 \
  libsm6 libxext6 libsndfile1 libvulkan1
chroot_run /bin/bash -c 'rm -rf /var/lib/apt/lists/*'

# 系统 python 仍供系统工具使用；deploy.yaml 里的 PythonExecutable 另指 venv
chroot_run ln -sf /usr/bin/python3 /usr/local/bin/python

DISTRO_PY="$(chroot_run python3 -c 'import platform; print(platform.python_version())')"
log "发行版 python3: $DISTRO_PY（低于上游 requires-python，故依赖装在 uv 托管的 venv 里）"

# ---------- 5. chroot 内浅克隆并钉版上游 ----------
if [[ "$UPSTREAM_REF" =~ ^[0-9a-fA-F]{40}$ ]]; then
  # 钉 commit：浅 fetch 指定 sha。镜像若未开 allow-any-sha1-in-want 会拒绝——
  # 那时请改用 branch/tag；此处失败即构建失败，钉版语义不允许静默回退
  chroot_run git init "$GUEST_ALAS_ROOT"
  chroot_run git -C "$GUEST_ALAS_ROOT" remote add origin "$UPSTREAM_REPO"
  chroot_run git -C "$GUEST_ALAS_ROOT" fetch --depth 1 origin "$UPSTREAM_REF"
  chroot_run git -C "$GUEST_ALAS_ROOT" checkout --detach FETCH_HEAD
else
  chroot_run git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_REPO" "$GUEST_ALAS_ROOT"
fi
PINNED_COMMIT="$(chroot_run git -C "$GUEST_ALAS_ROOT" rev-parse HEAD)"
log "上游钉版: $PINNED_COMMIT (flavor=$UPSTREAM_FLAVOR ref=$UPSTREAM_REF)"

# ---------- 6. 装 uv + uv 托管 Python + venv + 依赖 ----------
log "安装 uv"
chroot_run python3 -m pip install --break-system-packages --no-cache-dir -q \
  -i "$PYPI_MIRROR" uv
UV_VER="$(chroot_run uv --version)"
log "uv: $UV_VER"

# uv 托管的 python-build-standalone：解「发行版 python 版本低于上游 requires-python」。
# 发行版 python3 是 3.14.4，上游要 >=3.14.6 —— 用 uv 自带解释器，与 base 版本无关。
# UV_PYTHON_PREFERENCE=only-managed（在 chroot_run 里）确保不会被发行版 python 截胡。
log "安装 uv 托管 Python $PYTHON_VERSION"
chroot_run uv python install "$PYTHON_VERSION"
UV_PY_PATH="$(chroot_run uv python find "$PYTHON_VERSION" | tail -1)"
if [[ -z "$UV_PY_PATH" ]]; then
  echo "::error::uv python find $PYTHON_VERSION 未返回路径"
  exit 1
fi
log "uv 托管解释器: $UV_PY_PATH"

if [[ "$UPSTREAM_FLAVOR" == "azurpilot" || "$UPSTREAM_FLAVOR" == "azurpilot-upstream" ]]; then
  # 用 **uv sync**，而非自己抽 requirements + uv pip install：
  # uv sync 会读 pyproject 的**全部**配置，尤其是 [tool.uv] override-dependencies
  # —— 上游靠 `packaging==24.2` 这条 override 解开 uiautomator2==2.16.17 的
  # packaging<21 冲突。自己抽清单会漏掉 override，rootfs 首跑（run #35983440584）
  # 正是死在这里（No solution found when resolving dependencies）。
  # venv 由 UV_PROJECT_ENVIRONMENT 直接建在源码树之外（/opt/alas-venv，见文件头 3）。
  if [[ -f "$ROOTFS_DIR$GUEST_ALAS_ROOT/uv.lock" ]]; then
    log "检测到 uv.lock → 用 --frozen 保证可复现"
    chroot_run /bin/bash -c "cd $GUEST_ALAS_ROOT && uv sync --frozen --no-dev --python $PYTHON_VERSION"
  else
    log "无 uv.lock（上游未入库）→ 用 uv sync 现场解析（不可复现，但装得上）"
    chroot_run /bin/bash -c "cd $GUEST_ALAS_ROOT && uv sync --no-dev --python $PYTHON_VERSION"
  fi
else
  # curated 依赖列表（flavor=alas）：其 requirements.txt 钉的是 py3.7 时代版本，
  # aarch64 + py3.14 上大面积死链（numpy 1.17.4 / scipy 1.4.1 / pillow 9.5.0 等），
  # 故改用现代化宽松版本，来源 = m0 termux/setup_env.sh 真机实证集。
  # 不装：jellyfish（Rust/maturin，由 shims/jellyfish.py 顶替）、cnocr/mxnet
  # （被 in-proc onnxruntime OCR 取代）、zerorpc/pyzmq（TCP 桥方案废弃）、av（编译死链）。
  # cached-property：ALAS config_updater.py / alas.py 顶层 import，必须显式装。
  # imageio 钉 2.27.0：2.35+ 把 P 模式 GIF 统一解码成 RGB 3 通道，campaign 选关模板匹配
  # 时 cv2 通道断言直接崩（T2 真机崩溃根因）。
  log "使用 curated 依赖列表（flavor=alas）"
  chroot_run uv venv "$GUEST_VENV" --python "$UV_PY_PATH"
  chroot_run uv pip install --python "$GUEST_VENV/bin/python" -i "$PYPI_MIRROR" \
    'numpy>=2' scipy pillow lxml opencv-python-headless onnxruntime \
    pywebio uvicorn fastapi aiofiles inflection pyyaml requests tqdm rich \
    'imageio==2.27.0' 'pydantic<2' adbutils uiautomator2 uiautomator2cache \
    websockets pypresence onepush cached-property
fi

# 兼容上游对 .venv 的默认预期：软链 /opt/alas/.venv -> ../alas-venv。
# 这一步是「venv 在源码树之外」的关键——上游源码热更新整目录替换 /opt/alas 时，
# 依赖环境（/opt/alas-venv）不受影响，软链在新树里重建即可。
chroot_run /bin/bash -c "ln -sfn ../alas-venv $GUEST_VENV_LINK"
VENV_PY_VER="$(chroot_run "$GUEST_PYTHON" -c 'import platform; print(platform.python_version())' 2>/dev/null || echo '?')"
log "venv python: $VENV_PY_VER（$GUEST_VENV，软链 $GUEST_VENV_LINK）"

# ---------- 7. 应用本仓资产（宿主侧拷入 $ROOTFS_DIR/opt/alas） ----------
# ⚠️ 关键区分：本仓 patches/module/ 是 **ALAS 时代的「整文件覆盖」补丁**
# （connection.py 1267 行 / screenshot.py / control.py / app_control.py / base.py /
#  minitouch.py / method/utils.py / map_detection/utils.py / webui/patch.py / webui/utils.py）。
# 它们是**对着 ALAS 上游写的整份文件副本**，直接盖到 AzurPilot 上会回退上游实现、
# 引用不存在的 API —— 等于把上游改坏（见 docs/upstream-swap-azurpilot.md §1.3 形态④）。
#
# 按 flavor 分流：
#   - flavor=alas：维持旧行为（整层覆盖）
#   - azurpilot*：**只装纯新增的文件**。`module/device/method/alasaos.py` 是自包含的
#     桥客户端（不吃上游版本，纯新增）；其余整文件补丁一律不装。
#     桥接集成（Screenshot/Control/AppControl 的 MRO 混入 + 方法分派 + Connection 短路）
#     必须按 AzurPilot 源码**重新派生**，那是 M2 的工作。
if [[ "$UPSTREAM_FLAVOR" == "alas" ]]; then
  cp -rf "$ASSETS/patches/module/." "$ROOTFS_DIR/opt/alas/module/"
  cp -rf "$ASSETS/patches/assets/." "$ROOTFS_DIR/opt/alas/assets/"
  # assets_fix.py 改的是上游树内文件（argv[1]=上游根）：按 Button 名就地重写，非整文件覆盖
  python3 "$ASSETS/patches/assets_fix.py" "$ROOTFS_DIR/opt/alas"
else
  # M2 桥接集成：**最小 diff 补丁**，不是整文件覆盖。
  # 补丁只在上游源码里插入必要接线（MRO 混入 + 方法分派 + Connection 短路），
  # 上游其余部分原样保留。git apply 失败即构建失败 —— 上游漂移会**响亮地**报出来，
  # 而不是像整文件覆盖那样静默回退上游实现（见 §1.3 / §4.1）。
  # 补丁由 .tmp/make-azurpilot-patch.py 生成；**必须是 LF 行尾**：上游 .gitattributes
  # 声明 *.py eol=lf，而 Windows 上 Path.write_text() 默认产出 CRLF，会必然失败（已实测）。
  PATCH="$ASSETS/patches/azurpilot-android.patch"
  if [[ ! -f "$PATCH" ]]; then
    echo "::error::缺少桥接补丁: $PATCH（用 .tmp/make-azurpilot-patch.py 生成）"
    exit 1
  fi
  if grep -q $'\r' "$PATCH"; then
    echo "::error::桥接补丁含 CRLF 行尾，Linux 构建机上必然应用失败: $PATCH"
    exit 1
  fi
  # 宿主侧 git apply：补丁在仓内、不在 chroot 里；树属 root，需 safe.directory
  log "应用桥接补丁（最小 diff）: $(basename "$PATCH")"
  git -c safe.directory='*' -C "$ROOTFS_DIR$GUEST_ALAS_ROOT" apply --verbose "$PATCH" \
    || { echo "::error::桥接补丁应用失败——上游源码已漂移，请用 .tmp/make-azurpilot-patch.py 重新生成"; exit 1; }
  # 新增文件：桥客户端本身（补丁只管已跟踪文件的插入）
  install -D -m 0644 "$ASSETS/patches/module/device/method/alasaos.py" \
    "$ROOTFS_DIR/opt/alas/module/device/method/alasaos.py"
  log "azurpilot：桥接补丁已应用 + alasaos.py 已装（纯新增）"
  log "azurpilot：assets_fix.py 未重放（其 FIXES 表针对 ALAS 资产，上游素材版本不同）"
fi

# OCR：**flavor 相关，不能一刀切覆盖**（见 docs/upstream-swap-azurpilot.md §11）
# - flavor=alas：用 m0 的 in-proc onnxruntime 版 rpc.py 顶掉上游——ALAS 原生 OCR 依赖
#   cnocr/mxnet/zerorpc，在本环境装不上。
# - flavor=azurpilot：**保持上游原生 OCR**（RapidOCR / PP-OCRv6，默认进程内推理、
#   纯 CPU 路径、不需要 zerorpc，已由 M0-S1 实测可装可用）。我方 shim 只作兜底，
#   另存 seeds/ocr_fallback/，由开关选择，**绝不覆盖上游 rpc.py**。
if [[ "$UPSTREAM_FLAVOR" == "alas" ]]; then
  cp "$ASSETS/overlays/module/ocr/rpc.py" "$ROOTFS_DIR/opt/alas/module/ocr/rpc.py"
else
  install -D -m 0644 "$ASSETS/overlays/module/ocr/rpc.py" \
    "$ROOTFS_DIR/opt/alas/seeds/ocr_fallback/rpc.py"
  if [[ -f "$ASSETS/overlays/module/ocr/al_numpy.py" ]]; then
    install -D -m 0644 "$ASSETS/overlays/module/ocr/al_numpy.py" \
      "$ROOTFS_DIR/opt/alas/seeds/ocr_fallback/al_numpy.py"
  fi
  log "OCR：保留上游原生实现；我方 in-proc shim 存 seeds/ocr_fallback/（兜底，未启用）"
fi

# jellyfish shim：现代 jellyfish 是 Rust/maturin 构建，目标环境装不了；
# 把纯 Python shim 放到 venv 的 site-packages 顶替模块名（ALAS 只调 levenshtein_distance）。
# 路径在 chroot 内用 venv 的 sysconfig 查实，不猜前缀
VENV_PURELIB="$(chroot_run "$GUEST_PYTHON" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
install -D -m 0644 "$ASSETS/shims/jellyfish.py" "$ROOTFS_DIR$VENV_PURELIB/jellyfish.py"

# deploy.yaml：**按 flavor 选**（两边的键集不同，详见各文件头注释）
#   - alas        ：AutoUpdate:false 等七锁
#   - azurpilot*  ：InstallDependencies:false + Update 三关（替代已消失的 AutoUpdate）
#                   + WebuiPort 钉回 22267（上游模板默认 25548）
#   注意 azurpilot 那份是**覆盖文件**：上游 DeployConfig.read() 先读模板再用它覆盖，
#   缺失键自动回落模板默认 —— 所以只写覆盖项，不照抄整份模板。
if [[ "$UPSTREAM_FLAVOR" == "alas" ]]; then
  DEPLOY_SEED="$ASSETS/seeds/deploy.yaml"
else
  DEPLOY_SEED="$ASSETS/seeds/deploy-azurpilot.yaml"
fi
require_file "$DEPLOY_SEED"
install -D -m 0644 "$DEPLOY_SEED" "$ROOTFS_DIR/opt/alas/config/deploy.yaml"
log "deploy.yaml 来源: $(basename "$DEPLOY_SEED")"

# 实例配置生成器 / 热更新脚本 / args 再生器 / 环境自检修复
install -D -m 0644 "$ASSETS/seeds/seed_config.py" "$ROOTFS_DIR/opt/alas/seeds/seed_config.py"
install -D -m 0755 "$ASSETS/seeds/alasaos_update.sh" "$ROOTFS_DIR/opt/alas/seeds/alasaos_update.sh"
install -D -m 0755 "$ASSETS/seeds/regen_args.py" "$ROOTFS_DIR/opt/alas/seeds/regen_args.py"
install -D -m 0755 "$ASSETS/seeds/env_fix.sh" "$ROOTFS_DIR/opt/alas/seeds/env_fix.sh"

# PP-OCR 模型三件套 → /opt/alas/models/ocr/（v3 自定义路径，非上游约定）
install -D -m 0644 "$ASSETS/models/ocr/det.onnx" "$ROOTFS_DIR/opt/alas/models/ocr/det.onnx"
install -D -m 0644 "$ASSETS/models/ocr/rec.onnx" "$ROOTFS_DIR/opt/alas/models/ocr/rec.onnx"
install -D -m 0644 "$ASSETS/models/ocr/keys.txt" "$ROOTFS_DIR/opt/alas/models/ocr/keys.txt"

# wrapper / runner / Spike F 门禁
cp "$ASSETS/overlays/wrapper.py" "$ASSETS/overlays/runner.py" \
   "$ASSETS/build/spike-f-ocr-gate.py" "$ROOTFS_DIR/opt/alas/"

# ---------- 8. 体积裁剪 ----------
# APK 里 rootfs.tar.xz 是 noCompress 的 → rootfs 体积 1:1 变成 APK 体积，必须在这里裁。
# 原则：**只删确定不用的**。删错会导致 al_ocr.py 的 handle_ocr_error 抛
# RequestHumanTakeover（硬中断、调度器停摆），见 docs/upstream-swap-azurpilot.md §11.1。
trim_payload() {
  local root="$ROOTFS_DIR$GUEST_ALAS_ROOT"
  local before after

  before="$(du -sm "$root" | awk '{print $1}')"

  # --- conservative：确定无用的，任何 flavor 下都安全 ---
  # ncnn/ 是 ppocr-v6 同三档的 ncnn 格式副本（实测 97.3MB）；代码里 ncnn 只是
  # 可选后端（config.ocr_backend），默认走 onnxruntime → 整目录可删
  rm -rf "$root/bin/ocr_models/ncnn"
  # bin/ 下的 Android 侧推装件：本仓的桥（TCP 22300）已完全取代，运行时不用
  rm -rf "$root/bin/DroidCast" "$root/bin/MaaTouch" "$root/bin/ascreencap" \
         "$root/bin/hermit" "$root/bin/scrcpy"
  # 非运行时目录（仅 Electron 启动器/开发/文档用）
  rm -rf "$root/webapp" "$root/doc" "$root/wallpapers" "$root/tests" "$root/dev_tools"
  rm -rf "$root/.github" "$root/.agent" "$root/.claude" "$root/.cursor"
  rm -f  "$root/AGENTS.md" "$root/CLAUDE.md" "$root/.cursorignore" "$root/.dockerignore" \
         "$root/docker-compose.yml" "$root/Dockerfile" \
         "$root/一键启动.bat" "$root/重置环境.bat"
  # 构建缓存（uv 的 python 安装目录 /opt/uv-python 必须保留——venv 依赖它）
  rm -rf "$ROOTFS_DIR/opt/uv-cache"

  # --- aggressive：档位裁剪（**需 S2 实测 OCR 精度后才可启用**） ---
  # 默认档位 = standard(=small) rec + tiny det；medium/pro 与 cnocr 均非默认。
  # 风险：删错一个默认路径加载的模型 → 直接 RequestHumanTakeover。
  if [[ "$TRIM_LEVEL" == "aggressive" ]]; then
    log "TRIM_LEVEL=aggressive：裁掉非默认档位模型（须已过 S2 精度验证）"
    rm -f "$root/bin/ocr_models/ppocr-v6/PP-OCRv6_medium_rec.onnx"
    rm -f "$root/bin/ocr_models/det/PP-OCRv6_medium_det.onnx"
    rm -f "$root/bin/ocr_models/det/PP-OCRv6_small_det.onnx"
    rm -rf "$root/bin/cnocr_models"
  fi

  after="$(du -sm "$root" | awk '{print $1}')"
  log "裁剪（$TRIM_LEVEL）：$GUEST_ALAS_ROOT ${before}MB -> ${after}MB（省 $((before - after))MB）"
  echo "$((before - after))" > "$WORK_DIR/trim_saved_mb.txt"
}
trim_payload

# ---------- 9. import 硬门禁 + BUILD_MANIFEST ----------
ORT_VER="$(chroot_run "$GUEST_PYTHON" -c 'import onnxruntime; print(onnxruntime.__version__)')"
CV_VER="$(chroot_run "$GUEST_PYTHON" -c 'import cv2; print(cv2.__version__)')"

# import 硬门禁（fail-fast）：任一 ImportError → ::error:: 并以退出码 1 中止构建
# （set -e 捕获）。必须在 assets 与 jellyfish shim 安装（第 7 步）之后跑。
# 注意：**只对装了依赖的 venv python 跑**——对系统 python3 跑必然全失败，
# 那只会把结论污染成假阴性（M0-S1 探针首跑即踩此坑）。
chroot_run "$GUEST_PYTHON" - <<'PY'
try:
    import cv2, numpy, scipy, PIL, lxml.etree, yaml
    import pywebio, uvicorn, starlette, pydantic, imageio, rich, requests
    import adbutils, uiautomator2, onnxruntime, cached_property, jellyfish
except ImportError as e:
    print(f'::error::import 硬门禁失败: {e}')
    raise SystemExit(1)
print('cv2', cv2.__version__, '| numpy', numpy.__version__, '| scipy', scipy.__version__, '| PIL', PIL.__version__)
print('pydantic', pydantic.VERSION, '| pywebio', pywebio.__version__, '| onnxruntime', onnxruntime.__version__)
print('jellyfish shim check:', jellyfish.levenshtein_distance('abc', 'abd') == 1)
print('ALL_IMPORTS_OK')
PY

# 深层 import 冒烟（新增，重要）：上面那个门禁只碰**第三方库**，碰不到上游自身的
# 模块链——首版正是因此漏掉了「ALAS 整文件补丁把上游改坏」这类问题（浅门禁照样
# ALL_IMPORTS_OK，而实际 rootfs 是坏的）。这里 import 上游真实入口链：
# 调度器 → 设备链（拉 connection/screenshot/control/app_control）→ OCR → 配置生成。
# HARD 组失败即构建失败；SOFT 组只报告（WebUI/可选功能不应阻断烘焙，但要可见）。
chroot_run "$GUEST_PYTHON" - <<'PY'
import importlib
import os
import sys

ROOT = '/opt/alas'
os.chdir(ROOT)
sys.path.insert(0, ROOT)

HARD = ['alas', 'module.device.device', 'module.ocr.al_ocr', 'module.config.config_updater']
SOFT = ['module.webui.app', 'module.device.method.alasaos']


def probe(mod):
    try:
        importlib.import_module(mod)
        return True, 'OK'
    except Exception as e:
        return False, f'{type(e).__name__}: {str(e)[:160]}'


fail = []
print('[deep] HARD 组')
for m in HARD:
    ok, info = probe(m)
    print(f'  {"OK  " if ok else "FAIL"} {m:38} {info}')
    if not ok:
        fail.append(f'{m}: {info}')
print('[deep] SOFT 组')
for m in SOFT:
    ok, info = probe(m)
    print(f'  {"OK  " if ok else "MISS"} {m:38} {info}')

if fail:
    print('::error::深层 import 冒烟失败（上游模块链被改坏或依赖缺失）:')
    for f in fail:
        print(f'  - {f}')
    raise SystemExit(1)
print('DEEP_IMPORTS_OK')
PY

# ---------- 9.7 运行时就绪冒烟 ----------
# 前三层门禁（第三方 import / 上游模块链 import）都只证明「导得进」，
# 不证明「跑得起来」。这里做三件在上游真实代码上跑的事：
#   1) 播种实例配置 seed_config.py → config/alas.json
#      （校验我方 seeder 对上游 template.json 的键是否仍成立）
#   2) 再生 args regen_args.py → 跑上游 config_updater 完整生成链，再补回 'alasaos' 桥选项
#      ★ 关键：WebUI 的 ScreenshotMethod/ControlMethod 下拉里必须出现 alasaos，
#        否则用户在控制台根本选不到桥，整个方案不成立
#   3) SOFT：构造 AzurLaneAutoScript('alas') —— 校验配置绑定 + 设备链（含桥接短路）
# 注：regen_args 会改写树内 args.json / zh-CN.json，**不回滚** —— 运行时每次启动
#     也会再生一遍；烘一份进去正好当兜底（regen 失败时选项仍在）。
hr; say "步骤 9.7 · 运行时就绪冒烟"
chroot_run /bin/bash -c "cd $GUEST_ALAS_ROOT && ALASAOS_ALAS_ROOT=$GUEST_ALAS_ROOT $GUEST_PYTHON seeds/seed_config.py" \
  || { echo "::error::seed_config.py 失败（我方 seeder 与上游 template.json 已不匹配）"; exit 1; }
if [[ -f "$ROOTFS_DIR$GUEST_ALAS_ROOT/config/alas.json" ]]; then
  log "播种成功: config/alas.json"
else
  echo "::error::seed_config.py 未产出 config/alas.json"
  exit 1
fi

chroot_run /bin/bash -c "cd $GUEST_ALAS_ROOT && $GUEST_PYTHON seeds/regen_args.py" \
  || { echo "::error::regen_args.py 失败（上游 config_updater 生成链或 args.json 结构已变）"; exit 1; }
# 校验 alasaos 桥选项确实进了 args.json —— 这是「控制台能选到桥」的硬条件
chroot_run "$GUEST_PYTHON" - <<'PY'
import json
p = '/opt/alas/module/config/argument/args.json'
d = json.load(open(p, encoding='utf-8'))
bad = []
for task, group, arg in (('Alas', 'Emulator', 'ScreenshotMethod'),
                         ('Alas', 'Emulator', 'ControlMethod')):
    opts = d.get(task, {}).get(group, {}).get(arg, {}).get('option')
    ok = isinstance(opts, list) and 'alasaos' in opts
    print(f'  {"OK  " if ok else "FAIL"} {task}.{group}.{arg} option 含 alasaos = {ok}')
    if not ok:
        bad.append(f'{task}.{group}.{arg}')
if bad:
    print('::error::args.json 缺少 alasaos 选项:', bad)
    raise SystemExit(1)
print('BRIDGE_OPTION_OK')
PY

# SOFT：构造调度器对象（不跑 loop —— loop 会去连桥，CI 里没有桥）
# 用 heredoc 走 stdin，避免嵌套引号转义（`bash -c "... -c \"...\""` 太脆）
if chroot_run /bin/bash -c "cd $GUEST_ALAS_ROOT && $GUEST_PYTHON -" <<'PY'
from alas import AzurLaneAutoScript
a = AzurLaneAutoScript('alas')
print('  OK   构造 AzurLaneAutoScript 成功, config_name =', a.config_name)
print('RUNTIME_CONSTRUCT_OK')
PY
then
  log "运行时就绪冒烟：全部通过"
else
  log "WARN: 构造 AzurLaneAutoScript 失败（SOFT，不阻断烘焙；但运行期大概率也会失败）"
fi

# 优先用 GITHUB_SHA（checkout 的那个 commit）；本地兜底走 git——脚本已 sudo 提权为 root，
# 直接 git 会撞 "dubious ownership"（仓属 runner 用户），故带 -c safe.directory
REPO_COMMIT="${GITHUB_SHA:-$(git -c safe.directory='*' -C "$REPO_ROOT" rev-parse HEAD)}"
BUILD_TIME_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DET_SHA="$(sha256sum "$ASSETS/models/ocr/det.onnx" | awk '{print $1}')"
REC_SHA="$(sha256sum "$ASSETS/models/ocr/rec.onnx" | awk '{print $1}')"
KEYS_SHA="$(sha256sum "$ASSETS/models/ocr/keys.txt" | awk '{print $1}')"
TRIM_SAVED_MB="$(cat "$WORK_DIR/trim_saved_mb.txt" 2>/dev/null || echo 0)"

ROOTFS_VERSION="$ROOTFS_VERSION" BUILD_TIME_UTC="$BUILD_TIME_UTC" \
UPSTREAM_FLAVOR="$UPSTREAM_FLAVOR" UPSTREAM_REPO="$UPSTREAM_REPO" PINNED_COMMIT="$PINNED_COMMIT" \
REPO_COMMIT="$REPO_COMMIT" GUEST_PYTHON="$GUEST_PYTHON" VENV_PY_VER="$VENV_PY_VER" \
DISTRO_PY="$DISTRO_PY" UV_VER="$UV_VER" TRIM_LEVEL="$TRIM_LEVEL" TRIM_SAVED_MB="$TRIM_SAVED_MB" \
DET_SHA="$DET_SHA" REC_SHA="$REC_SHA" KEYS_SHA="$KEYS_SHA" \
ORT_VER="$ORT_VER" CV_VER="$CV_VER" \
python3 - <<'PY' > "$ROOTFS_DIR/opt/alas/BUILD_MANIFEST"
import json
import os

e = os.environ
manifest = {
    # 设备侧版本闸门：RootfsProvisioner 只读这一个字段（VERSION_KEY 正则）
    "rootfs_version": e["ROOTFS_VERSION"],
    "build_time_utc": e["BUILD_TIME_UTC"],
    # 上游身份（字段名由 alas_* 改为 upstream_*；App 不读这两个字段，改名安全）
    "upstream_flavor": e["UPSTREAM_FLAVOR"],
    "upstream_repo": e["UPSTREAM_REPO"],
    "upstream_commit": e["PINNED_COMMIT"],
    # guest 侧 Python（App 侧 ProotHost.GUEST_PYTHON 必须与此一致）
    "guest_python": e["GUEST_PYTHON"],
    "python_version": e["VENV_PY_VER"],
    "distro_python_version": e["DISTRO_PY"],
    "uv_version": e["UV_VER"],
    "trim_level": e["TRIM_LEVEL"],
    "trim_saved_mb": e["TRIM_SAVED_MB"],
    "patches_source": f"m0-archive/termux/patches @ repo commit {e['REPO_COMMIT']}",
    "ocr_models": {
        "det.onnx": e["DET_SHA"],
        "rec.onnx": e["REC_SHA"],
        "keys.txt": e["KEYS_SHA"],
    },
    "onnxruntime_version": e["ORT_VER"],
    "opencv_version": e["CV_VER"],
}
print(json.dumps(manifest, indent=2, ensure_ascii=False))
PY
cp "$ROOTFS_DIR/opt/alas/BUILD_MANIFEST" "$DIST_DIR/BUILD_MANIFEST"
log "BUILD_MANIFEST 已生成"

# ---------- 10. 瘦身 + 打包 ----------
# 先显式卸载全部 bind mount（trap 只是兜底）：否则下面 find/rm 会爬进宿主 /proc /sys /dev，
# 打包也会把宿主文件系统打进 tar。卸载后再做一切 rootfs 内部清理
cleanup_mounts
for mp in dev dev/pts proc sys etc/resolv.conf; do
  if mountpoint -q "$ROOTFS_DIR/$mp"; then
    echo "::error::$ROOTFS_DIR/$mp 仍处于挂载状态，拒绝清理与打包（trap 已兜底，此处为显式防线）"
    exit 1
  fi
done

rm -rf "$ROOTFS_DIR/opt/alas/.git"
find "$ROOTFS_DIR" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
# /var 首跑占 208MB（原因待查）——把 apt 缓存/日志/临时目录一并清掉再量。
# 注意：这里已过 cleanup_mounts，**不能再 chroot**（无 /proc /sys /dev），
# 所以全部用宿主侧 rm；apt-get clean 的等价物就是删 /var/cache/apt。
rm -rf "$ROOTFS_DIR/var/lib/apt/lists"/* "$ROOTFS_DIR/var/cache/apt"/* \
       "$ROOTFS_DIR/var/log"/* "$ROOTFS_DIR/var/tmp"/* \
       "$ROOTFS_DIR/root/.cache" "$ROOTFS_DIR/tmp"/*

# ---------- 9.5 体积分解报告（打包前） ----------
# 首跑（run #35985087081）实测 rootfs.tar.xz = **808MB**（目标 ~250MB、告警线 400MB），
# 未压缩总计 2279MB，其中 **venv 独占 1045MB**（远大于 bin/ 的 223MB）——
# 凭估算裁剪的方向完全错了。故本报告 + 依赖可达性探针是后续裁剪的唯一依据。
report_size() {
  local out="$DIST_DIR/SIZE_REPORT.txt"
  {
    echo "=== rootfs 体积分解（打包前，已剔除 .git / __pycache__ / apt 缓存）==="
    echo "--- 总计 ---"
    du -sm "$ROOTFS_DIR"
    echo
    echo "--- /opt 顶层 ---"
    du -sm "$ROOTFS_DIR/opt"/* 2>/dev/null | sort -rn
    echo
    echo "--- /opt/alas 顶层（前 15）---"
    du -sm "$ROOTFS_DIR/opt/alas"/* 2>/dev/null | sort -rn | head -15
    echo
    echo "--- venv site-packages（前 30）---"
    du -sm "$ROOTFS_DIR/opt/alas-venv"/lib/python*/site-packages/* 2>/dev/null | sort -rn | head -30
    echo
    echo "--- /var 与 /usr 顶层 ---"
    du -sm "$ROOTFS_DIR/var"/* 2>/dev/null | sort -rn | head -10
    du -sm "$ROOTFS_DIR/usr"/* 2>/dev/null | sort -rn | head -8
  } | tee "$out"
  log "体积分解报告已写入: $out"
}
report_size

# ---------- 9.6 依赖可达性探针 ----------
# 回答「哪些大包可以安全删」：扫描上游源码里每个候选包的 import 出现次数。
# 0 次 ⇒ 大概率可删（但要过 §11.1 那条红线：删错会让 OCR 初始化抛
# RequestHumanTakeover）。结果进日志与 artifact，作为 aggressive 裁剪的依据。
probe_dep_usage() {
  local out="$DIST_DIR/DEP_USAGE.txt"
  # 宿主侧直读——只扫源码文件，不需要 chroot（此时挂载已卸，chroot 反而不安全）。
  # 用宿主 python3；路径通过环境变量传进去。
  AP_ROOT="$ROOTFS_DIR$GUEST_ALAS_ROOT" python3 - <<'PY' | tee "$out"
import os
import pathlib
import re

SRC = pathlib.Path(os.environ['AP_ROOT'])
CANDIDATES = [
    'numba', 'llvmlite', 'av', 'aiortc', 'matplotlib', 'imageio_ffmpeg',
    'imageio', 'ncnn', 'rapidocr', 'onnxruntime', 'zerorpc', 'zmq', 'gevent',
    'psutil', 'watchdog', 'openai', 'mcp', 'sse_starlette', 'uvloop',
    'Crypto', 'cryptography', 'pylibsrtp', 'fontTools', 'uiautomator2',
    'adbutils', 'websockets', 'pypresence', 'onepush', 'lz4', 'pandas',
    'sympy', 'networkx', 'requests', 'aiohttp', 'torch',
]
# 只扫上游源码（跳过 venv 自身与我们的 overlay 副本）
files = [p for p in SRC.rglob('*.py')
         if 'site-packages' not in p.parts and '.venv' not in p.parts]
print(f'扫描 {len(files)} 个 .py 文件（上游源码树）')
print(f'{"import 名":22} {"命中文件数":>10}  样例')
print('-' * 78)
for name in CANDIDATES:
    pat = re.compile(rf'^\s*(?:from\s+{re.escape(name)}(?:\.|\s)|import\s+{re.escape(name)}(?:\s|\.|,|$))',
                     re.M)
    hits = []
    for p in files:
        try:
            if pat.search(p.read_text(encoding='utf-8', errors='ignore')):
                hits.append(p.relative_to(SRC))
        except OSError:
            pass
    sample = str(hits[0]) if hits else '-'
    print(f'{name:22} {len(hits):>10}  {sample}')
PY
  log "依赖可达性报告已写入: $out"
}
probe_dep_usage

OUT="$DIST_DIR/rootfs.tar.xz"
# --one-file-system 双保险：即使有残留挂载也不会把宿主文件系统打进包；
# XZ_OPT=-T0 多线程压缩（单线程 xz 压 ~600MB 要几分钟）
XZ_OPT=-T0 tar --one-file-system -C "$ROOTFS_DIR" -cJf "$OUT" .
SIZE="$(stat -c %s "$OUT")"
SHA="$(sha256sum "$OUT" | awk '{print $1}')"
log "rootfs.tar.xz: $SIZE bytes"
log "rootfs.tar.xz sha256: $SHA"
# 目标 ~250MB；超 400MB 报警（不 fail，留人审）
if (( SIZE > 400*1024*1024 )); then
  echo "::warning::rootfs.tar.xz 超 400MB（$SIZE bytes，目标 ~250MB），需要瘦身"
fi
log "完成：$OUT"
