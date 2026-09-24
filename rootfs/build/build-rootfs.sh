#!/usr/bin/env bash
# =============================================================================
# AP-AOS · rootfs 烘焙（M1 上游参数化改造，2026-09-24）
#
# 烘焙 Ubuntu ARM64 rootfs：ubuntu-base 26.04.1 LTS + 上游（Azurpilot/ALAS）
# + uv 托管 Python + 依赖 + OCR 模型 + wrapper/runner/patches
#
# 运行环境：GitHub Actions `ubuntu-24.04-arm` runner（原生 aarch64，chroot 无需 qemu）。
# 本机（Windows + Git Bash）不可执行：核心动作是 chroot / mount --bind / GNU tar，
# Windows 无这些语义；本机只做 `bash -n` 语法检查与 rootfs/ 资产 curated。
#
# ── M1 相对旧版的 5 处改造 ──────────────────────────────────────────────────
# 1) 上游参数化：新增 UPSTREAM_FLAVOR（azurpilot | alas）+ UPSTREAM_REPO/REF，
#    旧变量名 ALAS_REPO/ALAS_REF 保留为别名（向后兼容既有 CI 调用）。
# 2) base 升级：ubuntu-base 24.04.5 → 26.04.1 LTS（Python 3.14），并**新增 sha256 校验**。
# 3) Python 与依赖：发行版 python3 是 3.14.4，不满足上游 requires-python（>=3.14.6）
#    → 改用 **uv 托管的 python-build-standalone**，依赖装进 /opt/alas/.venv。
#    依赖清单对 azurpilot 走「从上游 pyproject.toml 现场抽取」，对 alas 仍用 curated 列表。
# 4) 体积裁剪：新增 trim_payload()，按 TRIM_LEVEL（conservative | aggressive）裁掉
#    确定不用的模型与 Android 侧推装件（详见该函数注释）。
# 5) BUILD_MANIFEST 契约：alas_* → upstream_*，新增 flavor / guest_python / trim_level。
#    rootfs_version 默认 0.2.0（**必须与上一版不同**，否则设备侧不重解新 rootfs）。
#
# 环境变量（冒号后为默认值）：
#   UPSTREAM_FLAVOR    azurpilot           上游口味：azurpilot | alas
#   UPSTREAM_REPO      <按 flavor 派生>
#   UPSTREAM_REF       master              分支/tag；40 位 sha 则按 commit 浅 fetch
#   ROOTFS_VERSION     0.2.0               写入 BUILD_MANIFEST.rootfs_version
#   TRIM_LEVEL         conservative        conservative | aggressive | none
#   UBUNTU_BASE        cdimage ubuntu-base 26.04.1 LTS arm64
#   UBUNTU_BASE_SHA256 5a190679…b219fd     取自官方 SHA256SUMS，硬钉防上游替换
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
  azurpilot)
    _default_repo="https://github.com/changqing81/Azurpilot-Auto.git"
    _default_ref="master"
    ;;
  alas)
    _default_repo="https://github.com/LmeSzinc/AzurLaneAutoScript.git"
    _default_ref="master"
    ;;
  *)
    echo "::error::未知 UPSTREAM_FLAVOR: $UPSTREAM_FLAVOR（期望 azurpilot | alas）"
    exit 1
    ;;
esac
# 旧变量名向后兼容：ALAS_REPO/ALAS_REF 若非空则覆盖
UPSTREAM_REPO="${UPSTREAM_REPO:-${ALAS_REPO:-$_default_repo}}"
UPSTREAM_REF="${UPSTREAM_REF:-${ALAS_REF:-$_default_ref}}"
# 注：GHA runner 在海外，GitHub 原生最快；gitee 同名镜像对匿名克隆要凭证（401），勿用。
# 国内本地复现构建时可 export UPSTREAM_REPO=<可达镜像>；runtime 更新镜像由 deploy.yaml 管。

ROOTFS_VERSION="${ROOTFS_VERSION:-0.2.0}"
TRIM_LEVEL="${TRIM_LEVEL:-conservative}"
UBUNTU_BASE="${UBUNTU_BASE:-https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04.1-base-arm64.tar.gz}"
UBUNTU_BASE_SHA256="${UBUNTU_BASE_SHA256:-5a1906794ced63a71a8119c3f211ef5f0bbe0a243001b4bbd41fdf80c5b219fd}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$REPO_ROOT}"
WORK_DIR="${WORK_DIR:-$GITHUB_WORKSPACE/work}"
ROOTFS_DIR="$WORK_DIR/rootfs"
ASSETS="$REPO_ROOT/rootfs"          # 本仓 curated 资产
DIST_DIR="$GITHUB_WORKSPACE/dist"

# guest 侧固定路径（**App 侧必须同源**：ProotHost.GUEST_PYTHON）
GUEST_ALAS_ROOT="/opt/alas"
GUEST_VENV="$GUEST_ALAS_ROOT/.venv"
GUEST_PYTHON="$GUEST_VENV/bin/python"

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
    "$@"
}

log "flavor=$UPSTREAM_FLAVOR repo=$UPSTREAM_REPO ref=$UPSTREAM_REF rootfs_version=$ROOTFS_VERSION trim=$TRIM_LEVEL"

# ---------- 2. 下载并校验 ubuntu-base 26.04.1 ----------
mkdir -p "$WORK_DIR" "$DIST_DIR"
BASE_TAR="$WORK_DIR/ubuntu-base-26.04.1-arm64.tar.gz"
if [[ ! -f "$BASE_TAR" ]]; then
  log "下载 ubuntu-base: $UBUNTU_BASE"
  curl -fL --retry 3 -o "$BASE_TAR" "$UBUNTU_BASE"
fi
GOT_SHA="$(sha256sum "$BASE_TAR" | awk '{print $1}')"
if [[ "$GOT_SHA" != "$UBUNTU_BASE_SHA256" ]]; then
  echo "::error::ubuntu-base sha256 不符：期望 $UBUNTU_BASE_SHA256，实得 $GOT_SHA"
  exit 1
fi
log "ubuntu-base sha256 校验通过"

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
# opencv-headless 运行只需 glib/gomp 级系统库；**不装 libgl1/libglx**——走了 headless
# 变体，装了反而会掩盖 libGL 缺失类问题（与 M0-S1 探针同一取舍）
chroot_run apt-get update
chroot_run apt-get install -y --no-install-recommends \
  python3 python3-pip python3-venv git ca-certificates curl xz-utils \
  libglib2.0-0t64 libgomp1
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

# uv 托管的 python-build-standalone：解「发行版 python 版本低于上游 requires-python」
log "安装 uv 托管 Python 3.14（>=3.14.6）"
chroot_run uv python install 3.14
UV_PY_PATH="$(chroot_run uv python find 3.14 | tail -1)"
if [[ -z "$UV_PY_PATH" ]]; then
  echo "::error::uv python find 3.14 未返回路径"
  exit 1
fi
chroot_run uv venv "$GUEST_VENV" --python "$UV_PY_PATH"
VENV_PY_VER="$(chroot_run "$GUEST_PYTHON" -c 'import platform; print(platform.python_version())')"
log "venv python: $VENV_PY_VER（$GUEST_PYTHON）"

if [[ "$UPSTREAM_FLAVOR" == "azurpilot" ]]; then
  # 依赖清单从上游 pyproject.toml 现场抽取（忠实于上游 + opencv 变体替换），
  # 平台 marker 原样透传，由 uv 按当前平台求值
  log "从上游 pyproject.toml 抽取依赖（opencv-python → opencv-python-headless）"
  chroot_run python3 - <<'PY'
import pathlib
import re
import tomllib

src = pathlib.Path('/opt/alas/pyproject.toml')
if not src.is_file():
    raise SystemExit('::error::上游缺少 pyproject.toml，无法抽取依赖')
data = tomllib.loads(src.read_text(encoding='utf-8'))
proj = data.get('project', {})
deps = list(proj.get('dependencies', []) or [])


def to_headless(spec: str) -> str:
    """opencv-python -> opencv-python-headless。
    本仓 rootfs 刻意不装 Qt/X11，opencv-python 轮子链接 libGL，import cv2 会炸。"""
    if re.match(r'^opencv-python(\s|==|>=|<=|~=|>|<|$)', spec) and 'headless' not in spec:
        return re.sub(r'^opencv-python', 'opencv-python-headless', spec, count=1)
    return spec


patched = [to_headless(d) for d in deps]
out = pathlib.Path('/opt/alas/requirements.alasaos.txt')
out.write_text('\n'.join(patched) + '\n', encoding='utf-8')
print(f'[build-rootfs] 抽取 {len(deps)} 条依赖 -> {out}')
print(f'[build-rootfs] requires-python = {proj.get("requires-python")}')
PY
  chroot_run uv pip install --python "$GUEST_PYTHON" -i "$PYPI_MIRROR" \
    -r /opt/alas/requirements.alasaos.txt

  # opencv 变体去重（M0-S1 run #35981880600 实测踩到的坑）：
  # rapidocr 声明依赖 `opencv-python`（非 headless，链接 libGL/libxcb），会被作为
  # **传递依赖**装进来，与我们要的 opencv-python-headless 争同一个 `cv2/` 路径 →
  # cv2 变成需要 libxcb.so.1 的版本，在无 X11 的 rootfs 里 `import cv2` 直接炸。
  # 只替换直接依赖不够，必须装完后卸掉非 headless 那份、再把 headless 重新铺回去。
  OPENCV_SPEC="$(grep -iE '^opencv-python-headless' /opt/alas/requirements.alasaos.txt 2>/dev/null | head -1 || true)"
  if [[ -n "${OPENCV_SPEC:-}" ]]; then
    log "opencv 去重：卸掉非 headless 变体，重铺 $OPENCV_SPEC"
    chroot_run uv pip uninstall --python "$GUEST_PYTHON" opencv-python
    chroot_run uv pip install --python "$GUEST_PYTHON" -i "$PYPI_MIRROR" \
      --reinstall "$OPENCV_SPEC"
  else
    log "requirements 里没有 opencv-python-headless，跳过去重"
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
  chroot_run uv pip install --python "$GUEST_PYTHON" -i "$PYPI_MIRROR" \
    'numpy>=2' scipy pillow lxml opencv-python-headless onnxruntime \
    pywebio uvicorn fastapi aiofiles inflection pyyaml requests tqdm rich \
    'imageio==2.27.0' 'pydantic<2' adbutils uiautomator2 uiautomator2cache \
    websockets pypresence onepush cached-property
fi

# ---------- 7. 应用本仓资产（宿主侧拷入 $ROOTFS_DIR/opt/alas） ----------
# m0 补丁集：module/ 与 assets/ 子树整层覆盖上游同名文件
cp -rf "$ASSETS/patches/module/." "$ROOTFS_DIR/opt/alas/module/"
cp -rf "$ASSETS/patches/assets/." "$ROOTFS_DIR/opt/alas/assets/"

# assets_fix.py 改的是 **上游树内** 文件（argv[1]=上游根目录）：按 Button 名就地重写
# module/*/assets.py 里的 cn area/color/button，非整文件覆盖（上游资产更新后可重放）
python3 "$ASSETS/patches/assets_fix.py" "$ROOTFS_DIR/opt/alas"

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

# deploy.yaml：更新器键全锁（详见 seeds/deploy.yaml 文件头注释）
install -D -m 0644 "$ASSETS/seeds/deploy.yaml" "$ROOTFS_DIR/opt/alas/config/deploy.yaml"

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
rm -rf "$ROOTFS_DIR/root/.cache" "$ROOTFS_DIR/var/lib/apt/lists"/*

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
