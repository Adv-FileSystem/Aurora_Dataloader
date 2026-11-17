#!/bin/bash
set -euo pipefail

echo "=== Clean rebuild (PROJECT_ROOT+TAG): MPICH → HDF5 1.14.6 (MPI) → DAOS-VOL → (optional) python deps ==="

# =============================================================================
# 권장 실행(ssh 끊김 방지): tmux 안에서!
#   tmux new -s daosbuild
#   TAG=keti PYTHON_BIN=/usr/bin/python3.9 ./setup_daos_client_final.sh |& tee build.log
#
# ✅ DAOS 스택 고정 정책:
#   - 기본은 서버(2.6.3)에 맞춰 DAOS_DIR를 /home/keti/daos-2.6.3/usr 로 "강제(pin)".
#   - 다른 DAOS_DIR를 정말 쓰고 싶으면:
#       ALLOW_DAOS_DIR_OVERRIDE=1 DAOS_DIR=/path/to/other/usr ./setup_daos_client_final.sh
#
# 옵션:
#   INSTALL_DEPS=1              # dnf로 빌드 의존성 설치
#   INSTALL_PYDEPS=1|0          # prefix에 python deps 설치 (기본 1)
#   PYDEPS_PREFIX=...           # python deps prefix (기본 $PROJECT_ROOT/.pydeps)
#   TEST_DAOS_VOL=1             # VOL init test (기본 0)
#
#   H5PY_SPEC="h5py>=3.11.0"    # 기본 (TF 2.20 요구 충족)
#   WRITE_SITECUSTOMIZE=1|0     # 기본 1 (항상 올바른 위치에 python 코드가 존재하게)
# =============================================================================

# ---------- 0) PROJECT_ROOT / TAG ----------
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"
TAG="${TAG:-$(whoami)}"

DEPS_DIR="$PROJECT_ROOT/.deps/$TAG"
SRC_DIR="$DEPS_DIR/src"
ENV_DIR="$PROJECT_ROOT/env"
MONKEY_DIR="$PROJECT_ROOT/monkey_patch"
ENV_FILE="$ENV_DIR/daos_env_${TAG}.sh"

mkdir -p "$SRC_DIR" "$ENV_DIR" "$MONKEY_DIR"

# ---------- 0-1) DAOS 클라이언트 경로 ----------
# ✅ 서버(2.6.3)와 ABI/프로토콜 맞추려면, RPM-extract prefix의 /usr 를 DAOS_DIR로 둬야 함.
DAOS_DIR_263_DEFAULT="/home/keti/daos-2.6.3/usr"
ALLOW_DAOS_DIR_OVERRIDE="${ALLOW_DAOS_DIR_OVERRIDE:-0}"

# 사용자 환경에 DAOS_DIR가 남아있어도, 기본은 "강제"로 2.6.3 사용
if [[ "$ALLOW_DAOS_DIR_OVERRIDE" == "1" ]]; then
  DAOS_DIR="${DAOS_DIR:-$DAOS_DIR_263_DEFAULT}"
else
  if [[ -n "${DAOS_DIR:-}" && "${DAOS_DIR}" != "$DAOS_DIR_263_DEFAULT" ]]; then
    echo "[WARN] DAOS_DIR is set to '$DAOS_DIR' but override is DISABLED."
    echo "[WARN] Pinning DAOS_DIR to server-matched '$DAOS_DIR_263_DEFAULT'."
  fi
  DAOS_DIR="$DAOS_DIR_263_DEFAULT"
fi

# ---------- 0-2) 설치 prefix (TAG로 분리) ----------
MPICH_PREFIX="$DEPS_DIR/mpich-3.4.3-install"
HDF5_PREFIX="$DEPS_DIR/hdf5-1.14.6-install"
VOL_PREFIX="$DEPS_DIR/daos-vol-install"

# ---------- 0-3) 소스 checkout 경로 (TAG로 분리) ----------
MPICH_SRC="$SRC_DIR/mpich-3.4.3"
HDF5_SRC="$SRC_DIR/hdf5"
VOL_SRC="$SRC_DIR/vol-daos"

# ---------- 0-4) 병렬 빌드 스레드 ----------
JOBS="${JOBS:-$(nproc)}"

# ---------- 0-5) python deps 옵션 ----------
INSTALL_PYDEPS="${INSTALL_PYDEPS:-1}"
PYDEPS_PREFIX="${PYDEPS_PREFIX:-$PROJECT_ROOT/.pydeps}"

# ---------- 0-5-1) 사용할 파이썬 인터프리터 ----------
PYTHON_BIN="${PYTHON_BIN:-python3}"

# ---------- 0-6) DAOS pool/cont 기본값 ----------
DAOS_POOL_DEFAULT="${DAOS_POOL_DEFAULT:-1a158ece-b233-48f5-9510-94d6cfbf9b4c}"
DAOS_POSIX_CONT_DEFAULT="${DAOS_POSIX_CONT_DEFAULT:-c965902c-8129-4a52-bed4-3641b01253ac}"
DAOS_HDF5_CONT_DEFAULT="${DAOS_HDF5_CONT_DEFAULT:-d1a58421-8d22-421d-ab35-6d53b4a2a7c9}"

# ✅ agent dRPC 소켓 위치(정상 동작 케이스: /var/run/daos_agent/daos_agent.sock)
DAOS_AGENT_DRPC_DIR_DEFAULT="${DAOS_AGENT_DRPC_DIR_DEFAULT:-/var/run/daos_agent}"

TEST_DAOS_VOL="${TEST_DAOS_VOL:-0}"

# ---------- 0-7) h5py 설치 스펙 ----------
H5PY_SPEC="${H5PY_SPEC:-h5py>=3.11.0}"

# ---------- 0-8) sitecustomize 생성 여부 ----------
WRITE_SITECUSTOMIZE="${WRITE_SITECUSTOMIZE:-1}"

echo "[INFO] PROJECT_ROOT             = $PROJECT_ROOT"
echo "[INFO] TAG                      = $TAG"
echo "[INFO] DEPS_DIR                 = $DEPS_DIR"
echo "[INFO] DAOS_DIR (PINNED)        = $DAOS_DIR"
echo "[INFO] ALLOW_DAOS_DIR_OVERRIDE  = $ALLOW_DAOS_DIR_OVERRIDE"
echo "[INFO] JOBS                     = $JOBS"
echo "[INFO] INSTALL_PYDEPS           = $INSTALL_PYDEPS"
echo "[INFO] PYDEPS_PREFIX            = $PYDEPS_PREFIX"
echo "[INFO] PYTHON_BIN               = $PYTHON_BIN"
echo "[INFO] TEST_DAOS_VOL            = $TEST_DAOS_VOL"
echo "[INFO] H5PY_SPEC                = $H5PY_SPEC"
echo "[INFO] WRITE_SITECUSTOMIZE      = $WRITE_SITECUSTOMIZE"
echo "[INFO] ENV_FILE                 = $ENV_FILE"
echo

# ---------- 0-9) 안전 체크 ----------
if [[ "$PROJECT_ROOT" == "$HOME" || "$PROJECT_ROOT" == "/" ]]; then
  echo "[ERROR] PROJECT_ROOT가 너무 위험한 경로입니다: $PROJECT_ROOT"
  exit 1
fi
if [[ ! -d "$DAOS_DIR" ]]; then
  echo "[ERROR] DAOS_DIR 경로가 존재하지 않습니다: $DAOS_DIR"
  exit 1
fi

# ---------- 0-10) (선택) 빌드 의존성 설치 ----------
if [[ "${INSTALL_DEPS:-0}" == "1" ]]; then
  echo "[STEP 0] Install build deps (dnf) ..."
  sudo dnf install -y \
    autoconf automake libtool m4 make gcc gcc-c++ git cmake pkgconf-pkg-config patch \
    perl flex bison wget tar gzip bzip2 xz openssl-devel zlib-devel \
    python3 python3-pip python3-devel which findutils
  echo
fi

# ---------- 0-11) 필요한 툴 체크 ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] missing command: $1"; exit 1; }; }
need_cmd git
need_cmd make
need_cmd cmake
need_cmd autoconf
need_cmd automake
need_cmd "$PYTHON_BIN"

if ! command -v libtoolize >/dev/null 2>&1 && ! command -v libtool >/dev/null 2>&1; then
  echo "[ERROR] missing command: libtoolize (or libtool)"
  exit 1
fi

PYVER="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "[INFO] PYVER = $PYVER"
echo

# ---------- 0-12) DAOS 라이브러리/헤더 경로 확인 ----------
if [[ ! -d "$DAOS_DIR/include" ]]; then
  echo "[ERROR] DAOS include directory not found: $DAOS_DIR/include"
  exit 1
fi

DAOS_LIBDIR=""
if [[ -d "$DAOS_DIR/lib64" ]]; then
  DAOS_LIBDIR="$DAOS_DIR/lib64"
elif [[ -d "$DAOS_DIR/lib" ]]; then
  DAOS_LIBDIR="$DAOS_DIR/lib"
else
  echo "[ERROR] DAOS library directory not found: $DAOS_DIR/lib64 or $DAOS_DIR/lib"
  exit 1
fi

DAOS_LIBRARY="$(ls -1 "$DAOS_LIBDIR"/libdaos.so* 2>/dev/null | head -n 1 || true)"
DAOS_DUNS_LIBRARY="$(ls -1 "$DAOS_LIBDIR"/libduns.so* 2>/dev/null | head -n 1 || true)"

if [[ -z "$DAOS_LIBRARY" ]]; then
  echo "[ERROR] DAOS library not found in $DAOS_LIBDIR (expected libdaos.so*)"
  exit 1
fi
if [[ -z "$DAOS_DUNS_LIBRARY" ]]; then
  echo "[ERROR] DAOS duns library not found in $DAOS_LIBDIR (expected libduns.so*)"
  exit 1
fi

echo "[INFO] DAOS_LIBDIR       = $DAOS_LIBDIR"
echo "[INFO] DAOS_LIBRARY      = $DAOS_LIBRARY"
echo "[INFO] DAOS_DUNS_LIBRARY = $DAOS_DUNS_LIBRARY"
echo

# ---------- 1) 정리 ----------
echo "[STEP 1] Clean previous installs (TAG-scoped) ..."
rm -rf "$MPICH_PREFIX" "$HDF5_PREFIX" "$VOL_PREFIX"
rm -rf "$MPICH_SRC" "$HDF5_SRC" "$VOL_SRC"
echo "  - cleaned: $DEPS_DIR"
echo

# ---------- 2) MPICH ----------
echo "[STEP 2] Build MPICH 3.4.3 ..."
cd "$SRC_DIR"
unset CC CXX FC F77 F90 || true
hash -r

git clone -b v3.4.3 https://github.com/pmodels/mpich "$MPICH_SRC"
cd "$MPICH_SRC"
git submodule update --init --recursive
./autogen.sh

./configure --prefix="$MPICH_PREFIX" \
  --enable-fortran=all --enable-romio --enable-cxx --enable-g=all --enable-debuginfo \
  --with-device=ch3:nemesis --with-file-system=ufs+daos --with-daos="$DAOS_DIR" \
  FFLAGS=-fallow-argument-mismatch

make -j"$JOBS"
make install
echo "  - installed: $MPICH_PREFIX"
echo

# ---------- 3) HDF5 ----------
echo "[STEP 3] Build HDF5 1.14.6 (parallel, CMake) ..."
cd "$SRC_DIR"
git clone https://github.com/HDFGroup/hdf5.git "$HDF5_SRC"
cd "$HDF5_SRC"
git fetch --all --tags
git checkout hdf5_1_14_6

rm -rf build && mkdir -p build && cd build
cmake .. \
  -DCMAKE_INSTALL_PREFIX="$HDF5_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$MPICH_PREFIX/bin/mpicc" \
  -DHDF5_ENABLE_PARALLEL=ON \
  -DHDF5_ENABLE_MAP_API=ON \
  -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
  -DHDF5_BUILD_HL_LIB=ON \
  -DHDF5_BUILD_TOOLS=ON \
  -DHDF5_ENABLE_CMAKE_PACKAGE=ON \
  -DCMAKE_INSTALL_LIBDIR=lib

cmake --build . -j"$JOBS"
cmake --install .
echo "  - installed: $HDF5_PREFIX"
echo

# ---------- 4) DAOS VOL ----------
echo "[STEP 4] Build DAOS VOL plugin ..."
cd "$SRC_DIR"
git clone --recurse-submodules https://github.com/HDFGroup/vol-daos.git "$VOL_SRC"
cd "$VOL_SRC"
rm -rf build && mkdir -p build && cd build

HDF5_CMAKE_DIR="$(dirname "$(find "$HDF5_PREFIX" -name 'HDF5Config.cmake' -o -name 'hdf5-config.cmake' | head -n 1)")"

cmake .. \
  -DCMAKE_INSTALL_PREFIX="$VOL_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$HDF5_PREFIX;$MPICH_PREFIX" \
  -DHDF5_DIR="$HDF5_CMAKE_DIR" \
  -DHDF5_ROOT="$HDF5_PREFIX" \
  -DCMAKE_C_COMPILER="$MPICH_PREFIX/bin/mpicc" \
  -DDAOS_INCLUDE_DIR="$DAOS_DIR/include" \
  -DDAOS_LIBRARY="$DAOS_LIBRARY" \
  -DDAOS_UNS_LIBRARY="$DAOS_DUNS_LIBRARY" \
  -DBUILD_TESTING=OFF

cmake --build . -j"$JOBS"
cmake --install .
echo "  - installed: $VOL_PREFIX"
echo

# ---------- 4.5) monkey_patch/sitecustomize.py 생성 ----------
if [[ "$WRITE_SITECUSTOMIZE" == "1" ]]; then
  echo "[STEP 4.5] Write monkey_patch/sitecustomize.py (PYTHON code lives here, NOT in env/*.sh) ..."
  SITECUSTOMIZE_PY="$MONKEY_DIR/sitecustomize.py"

  cat > "$SITECUSTOMIZE_PY" <<'PY'
# monkey_patch/sitecustomize.py
# (FIXED: sys.modules-first lazy import + no meta_path recursion)

import os
import sys
import site
import builtins
import io
import importlib
import importlib.abc
import importlib.machinery
import threading

def _dbg(msg: str) -> None:
    if os.environ.get("DAOS_SITE_DEBUG", ""):
        print(f"[sitecustomize] {msg}", file=sys.stderr)

def _remove_user_site_paths() -> None:
    os.environ["PYTHONNOUSERSITE"] = "1"
    user_site = None
    try:
        user_site = site.getusersitepackages()
    except Exception:
        user_site = None

    new_path = []
    removed = []
    for p in list(sys.path):
        if not p:
            new_path.append(p)
            continue
        if ("/.local/" in p) or (user_site and p == user_site):
            removed.append(p)
            continue
        new_path.append(p)

    sys.path[:] = new_path
    if removed:
        _dbg(f"removed user-site paths: {removed}")

def _prepend_path(p: str) -> None:
    if p and p not in sys.path:
        sys.path.insert(0, p)

def _force_pydeps_sys_path() -> None:
    project_root = os.environ.get("PROJECT_ROOT", "")
    pydeps_plat = os.environ.get("PYDEPS_PLATLIB", "")
    pydeps_pure = os.environ.get("PYDEPS_PURELIB", "")

    _remove_user_site_paths()

    if project_root:
        _prepend_path(os.path.join(project_root, "monkey_patch"))

    _prepend_path(pydeps_pure)
    _prepend_path(pydeps_plat)
    _dbg(f"sys.path head: {sys.path[:8]}")

_force_pydeps_sys_path()

DAOS_MNT_ROOT    = "/mnt/daos/u"
POSIX_MNT_PREFIX = "/mnt/daos/u/posix"
HDF5_MNT_PREFIX  = "/mnt/daos/u/hdf5"

def _must_env(k: str) -> str:
    v = os.environ.get(k)
    if not v:
        raise RuntimeError(f"[DAOS ENV] {k} is missing. export {k}=... 해야 함.")
    return v

def _pool() -> str:
    return _must_env("DAOS_POOL")

def _hdf5_cont() -> str:
    return _must_env("DAOS_HDF5_CONT")

def is_daos_like_path(path: str) -> bool:
    return isinstance(path, str) and (path.startswith("daos://") or path.startswith("/mnt/daos/"))

def mnt_to_daos_hdf5(path: str) -> str:
    if not path.startswith(HDF5_MNT_PREFIX + "/"):
        raise ValueError(f"Expected HDF5 UNS path under {HDF5_MNT_PREFIX}: {path}")
    rel = path[len(HDF5_MNT_PREFIX) + 1 :]
    return f"daos://{_pool()}/{_hdf5_cont()}/{rel}"

_tf = None
_torch = None
_tf_io = None
_pt_io = None

def _lazy_import_tf():
    global _tf, _tf_io
    if _tf is None:
        m = sys.modules.get("tensorflow")
        if m is not None:
            _tf = m
        else:
            import tensorflow as tf  # noqa
            _tf = tf
    if _tf_io is None:
        m = sys.modules.get("tf_daos_io")
        if m is not None:
            _tf_io = m
        else:
            import tf_daos_io as tf_io  # noqa
            _tf_io = tf_io
    return _tf, _tf_io

def _lazy_import_torch():
    global _torch, _pt_io
    if _torch is None:
        m = sys.modules.get("torch")
        if m is not None:
            _torch = m
        else:
            import torch  # noqa
            _torch = torch
    if _pt_io is None:
        m = sys.modules.get("pt_daos_io")
        if m is not None:
            _pt_io = m
        else:
            import pt_daos_io as pt_io  # noqa
            _pt_io = pt_io
    return _torch, _pt_io

_ORIG_OPEN = builtins.open
_TF_TLS = threading.local()

def _patch_torch():
    if os.environ.get("DAOS_TORCH_PATCH", "1") in ("0", "false", "False"):
        _dbg("torch patch skipped (DAOS_TORCH_PATCH=0)")
        return
    torch, pt_io = _lazy_import_torch()
    if getattr(torch, "__DAOS_PATCHED__", False):
        return
    _orig_torch_load = torch.load

    def patched_open(path, mode="rb", *args, **kwargs):
        if not (isinstance(path, str) and mode.startswith("r")):
            return _ORIG_OPEN(path, mode, *args, **kwargs)
        ext = os.path.splitext(path)[1].lower()
        if ext in [".h5", ".hdf5"] and path.startswith(HDF5_MNT_PREFIX + "/"):
            daos_uri = mnt_to_daos_hdf5(path)
            t = pt_io._from_hdf5(daos_uri)
            return io.BytesIO(t.detach().cpu().numpy().tobytes())
        return _ORIG_OPEN(path, mode, *args, **kwargs)

    def patched_torch_load(path, *args, **kwargs):
        return _orig_torch_load(path, *args, **kwargs)

    builtins.open = patched_open
    torch.load = patched_torch_load
    torch.__DAOS_PATCHED__ = True
    _dbg("torch patches applied")

def _patch_tf():
    if os.environ.get("DAOS_TF_PATCH", "1") in ("0", "false", "False"):
        _dbg("tensorflow patch skipped (DAOS_TF_PATCH=0)")
        return
    tf, tf_io = _lazy_import_tf()
    if getattr(tf, "__DAOS_PATCHED__", False):
        return
    _orig_read_file = tf.io.read_file

    def _enter_tf():
        if getattr(_TF_TLS, "in_patch", False):
            return False
        _TF_TLS.in_patch = True
        return True

    def _exit_tf():
        _TF_TLS.in_patch = False

    def patched_read_file(path):
        if not _enter_tf():
            return _orig_read_file(path)
        try:
            if tf.is_tensor(path):
                if tf.executing_eagerly():
                    path = path.numpy().decode()
                else:
                    return _orig_read_file(path)
            if not isinstance(path, str):
                return _orig_read_file(path)
            ext = os.path.splitext(path)[1].lower()
            if ext in [".h5", ".hdf5"] and path.startswith(HDF5_MNT_PREFIX + "/"):
                daos_uri = mnt_to_daos_hdf5(path)
                return tf_io._from_hdf5_as_bytes(daos_uri)
            return _orig_read_file(path)
        finally:
            _exit_tf()

    tf.io.read_file = patched_read_file
    tf.__DAOS_PATCHED__ = True
    _dbg("tensorflow patches applied")

class _AutoPatchLoader(importlib.abc.Loader):
    def __init__(self, original_loader, root: str):
        self.original_loader = original_loader
        self.root = root

    def create_module(self, spec):
        if hasattr(self.original_loader, "create_module"):
            return self.original_loader.create_module(spec)
        return None

    def exec_module(self, module):
        self.original_loader.exec_module(module)
        if self.root == "tensorflow":
            _patch_tf()
        elif self.root == "torch":
            _patch_torch()

class _WrapLoaderFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname: str, path=None, target=None):
        if fullname not in ("tensorflow", "torch"):
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if spec and spec.loader:
            spec.loader = _AutoPatchLoader(spec.loader, fullname)
        return spec

sys.meta_path.insert(0, _WrapLoaderFinder())
_dbg("import hook installed (PathFinder-based, no recursion)")

if os.environ.get("DAOS_SITE_DEBUG", ""):
    try:
        import pip
        _dbg(f"pip file = {pip.__file__}")
    except Exception as e:
        _dbg(f"pip import failed: {e}")
PY

  chmod 0644 "$SITECUSTOMIZE_PY"
  echo "  - wrote: $SITECUSTOMIZE_PY"
  echo
else
  echo "[STEP 4.5] Skip writing sitecustomize.py (WRITE_SITECUSTOMIZE=0)"
  echo
fi

# ---------- 5) env 파일 생성 ----------
echo "[STEP 5] Write env file (BASH ONLY; avoid python calls in env to prevent ssh drop) ..."

cat > "$ENV_FILE" <<EOF
#!/bin/bash
# NOTE: This file must stay BASH ONLY.
#       Python code belongs to: \$PROJECT_ROOT/monkey_patch/sitecustomize.py

export PROJECT_ROOT="$PROJECT_ROOT"
export TAG="$TAG"

export PYTHON_BIN="$PYTHON_BIN"
export PYDEPS_PREFIX="$PYDEPS_PREFIX"

# =========================================================
# Core toolchain dirs
# =========================================================
export HDF5_DIR="$HDF5_PREFIX"

# ✅ DAOS stack: PIN to server-matched 2.6.3 (avoid ABI/protocol mismatch)
export DAOS_DIR="$DAOS_DIR"
export DAOS_LIBDIR="$DAOS_LIBDIR"

export MPICH_DAOS_DIR="$MPICH_PREFIX"
export DAOS_VOL_DIR="$VOL_PREFIX"

# =========================================================
# PATH / LIB PATHS
#   - Put DAOS(2.6.3) bin/lib FIRST to avoid mixing with other installs
# =========================================================
export PATH="\$DAOS_DIR/bin:\$PROJECT_ROOT/bin:\$HDF5_DIR/bin:\$MPICH_DAOS_DIR/bin:\$PATH"
export LD_LIBRARY_PATH="\$DAOS_LIBDIR:\$HDF5_DIR/lib:\$MPICH_DAOS_DIR/lib:\$DAOS_VOL_DIR/lib:\${LD_LIBRARY_PATH:-}"
export LIBRARY_PATH="\$DAOS_LIBDIR:\$HDF5_DIR/lib:\$MPICH_DAOS_DIR/lib:\$DAOS_VOL_DIR/lib:\${LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\$HDF5_DIR/lib/pkgconfig:\$HDF5_DIR/share/pkgconfig:\${PKG_CONFIG_PATH:-}"

export CPATH="\$MPICH_DAOS_DIR/include:\${CPATH:-}"
export C_INCLUDE_PATH="\$MPICH_DAOS_DIR/include:\${C_INCLUDE_PATH:-}"
export CPLUS_INCLUDE_PATH="\$MPICH_DAOS_DIR/include:\${CPLUS_INCLUDE_PATH:-}"

# =========================================================
# Python site path for prefix deps (NO python calls; avoid ssh drop)
# =========================================================
export PYDEPS_PURELIB="\$PYDEPS_PREFIX/lib/python${PYVER}/site-packages"
export PYDEPS_PLATLIB="\$PYDEPS_PREFIX/lib64/python${PYVER}/site-packages"
if [ ! -d "\$PYDEPS_PLATLIB" ] && [ -d "\$PYDEPS_PURELIB" ]; then
  export PYDEPS_PLATLIB="\$PYDEPS_PURELIB"
fi

# sitecustomize ALWAYS-ON (monkey_patch first)
export PYTHONPATH="\$PROJECT_ROOT/monkey_patch:\$PYDEPS_PLATLIB:\$PYDEPS_PURELIB\${PYTHONPATH:+:\$PYTHONPATH}"

# =========================================================
# DAOS pool/containers
# =========================================================
export DAOS_POOL="\${DAOS_POOL:-$DAOS_POOL_DEFAULT}"
DAOS_POSIX_CONT_DEFAULT="${DAOS_POSIX_CONT_DEFAULT:-uns_cont}"
export DAOS_HDF5_CONT="\${DAOS_HDF5_CONT:-$DAOS_HDF5_CONT_DEFAULT}"

# =========================================================
# DAOS MPI-IO bypass / ROMIO DAOS backend
# =========================================================
export DAOS_CONT="\${DAOS_CONT:-\$DAOS_POSIX_CONT}"
export DAOS_BYPASS_DUNS="\${DAOS_BYPASS_DUNS:-1}"
export ROMIO_FSTYPE_FORCE="\${ROMIO_FSTYPE_FORCE:-daos:}"

# =========================================================
# DAOS agent socket dir (dRPC)
# =========================================================
export DAOS_AGENT_DRPC_DIR="\${DAOS_AGENT_DRPC_DIR:-$DAOS_AGENT_DRPC_DIR_DEFAULT}"

# =========================================================
# HDF5 VOL switch helpers
# =========================================================
export HDF5_VOL_CONNECTOR="\${HDF5_VOL_CONNECTOR:-native}"
export HDF5_PLUGIN_PATH="\${HDF5_PLUGIN_PATH:-}"
export HDF5_DAOS_BYPASS_DUNS="\${HDF5_DAOS_BYPASS_DUNS:-0}"

# =========================================================
# Helpers
# =========================================================
pin_daos_263() {
  export PATH="\$DAOS_DIR/bin:\$PATH"
  export LD_LIBRARY_PATH="\$DAOS_LIBDIR:\${LD_LIBRARY_PATH:-}"
  hash -r
  echo "[ENV] Pinned DAOS stack: DAOS_DIR=\$DAOS_DIR"
  which daos || true
  daos version || true
}

enable_daos_vol() {
  export HDF5_VOL_CONNECTOR="daos"
  export HDF5_PLUGIN_PATH="\$DAOS_VOL_DIR/lib"
  echo "[ENV] DAOS VOL enabled"
}

enable_daos_vol_bypass() {
  export HDF5_VOL_CONNECTOR="daos"
  export HDF5_PLUGIN_PATH="\$DAOS_VOL_DIR/lib"
  export HDF5_DAOS_BYPASS_DUNS="1"
  unset DAOS_CONT || true
  echo "[ENV] DAOS VOL BYPASS enabled (HDF5_DAOS_BYPASS_DUNS=1, DAOS_CONT unset)"
}

enable_daos_vol_uns() {
  export HDF5_VOL_CONNECTOR="daos"
  export HDF5_PLUGIN_PATH="\$DAOS_VOL_DIR/lib"
  export HDF5_DAOS_BYPASS_DUNS="0"
  echo "[ENV] DAOS VOL UNS mode (HDF5_DAOS_BYPASS_DUNS=0)"
}

disable_daos_vol() {
  export HDF5_VOL_CONNECTOR="native"
  export HDF5_PLUGIN_PATH=""
  export HDF5_DAOS_BYPASS_DUNS="0"
  echo "[ENV] DAOS VOL disabled"
}

enable_daos_mpi_bypass() {
  export DAOS_CONT="${DAOS_CONT:-$DAOS_POSIX_CONT}"
  export DAOS_BYPASS_DUNS="1"
  export ROMIO_FSTYPE_FORCE="daos:"
  echo "[ENV] DAOS MPI-IO BYPASS enabled"
  echo "      DAOS_POOL=$DAOS_POOL"
  echo "      DAOS_CONT=$DAOS_CONT"
  echo "      DAOS_BYPASS_DUNS=$DAOS_BYPASS_DUNS"
  echo "      ROMIO_FSTYPE_FORCE=$ROMIO_FSTYPE_FORCE"
}

copy_mpi_to_daos_root() {
  local src="${1:?usage: copy_mpi_to_daos_root /path/to/file.mpi}"
  local base
  local remote

  base="$(basename "$src")"
  remote="${base%.*}_root_$(date +%s).mpi"

  daos fs copy \
    -s "$src" \
    -d "daos://$DAOS_POOL/$DAOS_CONT/$remote"

  if [ -f "${src}.meta" ]; then
    daos fs copy \
      -s "${src}.meta" \
      -d "daos://$DAOS_POOL/$DAOS_CONT/${remote}.meta"
  fi

  export MPI_ROOT_FILE="$remote"
  export MPI_FILE="daos:$MPI_ROOT_FILE"

  echo "[ENV] MPI file copied for DAOS MPI-IO bypass"
  echo "      MPI_ROOT_FILE=$MPI_ROOT_FILE"
  echo "      MPI_FILE=$MPI_FILE"
}

# =========================================================
# Print summary
# =========================================================
echo "[ENV] Loaded DAOS env for TAG=\$TAG"
echo "      DAOS_DIR=\$DAOS_DIR"
echo "      DAOS_LIBDIR=\$DAOS_LIBDIR"
echo "      DAOS_AGENT_DRPC_DIR=\$DAOS_AGENT_DRPC_DIR"
echo "      DAOS_POOL=\$DAOS_POOL"
echo "      DAOS_HDF5_CONT=\$DAOS_HDF5_CONT"
echo "      HDF5_VOL_CONNECTOR=\$HDF5_VOL_CONNECTOR"
echo "      HDF5_DAOS_BYPASS_DUNS=\$HDF5_DAOS_BYPASS_DUNS"
EOF

chmod +x "$ENV_FILE"
echo "  - wrote: $ENV_FILE"
echo

# ---------- 6) 검증 ----------
echo "[STEP 6] Verify (source env in THIS script) ..."
# shellcheck disable=SC1090
source "$ENV_FILE"

echo "== verify: pinned daos stack (expect 2.6.3) =="
pin_daos_263 || true
echo

echo "== verify: toolchain paths =="
which mpicc || true
which h5dump || true
which daos || true
echo

echo "== verify: native h5dump (must succeed) =="
HDF5_VOL_CONNECTOR=native HDF5_PLUGIN_PATH="" h5dump -V || true
echo

if [[ "$TEST_DAOS_VOL" == "1" ]]; then
  echo "== verify: DAOS VOL init (may fail if agent/protocol mismatch) =="
  enable_daos_vol
  h5dump -V || true
  disable_daos_vol
  echo
fi

# ---------- 7) python deps ----------
if [[ "$INSTALL_PYDEPS" == "1" ]]; then
  echo "[STEP 7] Build+install python deps into prefix (packaging tools, numpy, mpi4py, h5py) ..."
  mkdir -p "$PYDEPS_PREFIX"

  if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
    "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
  fi
  if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
    echo "[ERROR] pip is missing for $PYTHON_BIN. (dnf install python3-pip or choose PYTHON_BIN with pip)"
    exit 1
  fi

  export PYTHONNOUSERSITE=1
  export PIP_DISABLE_PIP_VERSION_CHECK=1
  export PIP_NO_WARN_SCRIPT_LOCATION=0

  PYDEPS_PYTHONPATH="$PROJECT_ROOT/monkey_patch:$PYDEPS_PLATLIB:$PYDEPS_PURELIB"

  echo "  [7-clean] remove old numpy/mpi4py/h5py/Cython from prefix (lib & lib64) ..."
  for d in "$PYDEPS_PREFIX"/lib/python${PYVER}/site-packages \
           "$PYDEPS_PREFIX"/lib64/python${PYVER}/site-packages; do
    [[ -d "$d" ]] || continue
    rm -rf "$d"/numpy "$d"/numpy-*.dist-info \
           "$d"/mpi4py "$d"/mpi4py-*.dist-info \
           "$d"/h5py "$d"/h5py-*.dist-info \
           "$d"/Cython "$d"/Cython-*.dist-info || true
  done

  echo "  [7-0] ensure base build tools in prefix (PIN setuptools<70) ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" \
  "$PYTHON_BIN" -m pip install --no-user --no-cache-dir --prefix "$PYDEPS_PREFIX" \
    --ignore-installed --upgrade --force-reinstall \
    "setuptools<70" "wheel>=0.38" "packaging>=23.0"

  PYTHONPATH="$PYDEPS_PYTHONPATH" \
  "$PYTHON_BIN" -m pip install --no-user --no-cache-dir --prefix "$PYDEPS_PREFIX" \
    --ignore-installed --upgrade --force-reinstall \
    "backports.tarfile"

  echo "  [7-1] install numpy==1.26.4 (HARD PIN) ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" \
  "$PYTHON_BIN" -m pip install --no-user --no-cache-dir --prefix "$PYDEPS_PREFIX" \
    --no-deps --ignore-installed --upgrade --force-reinstall "numpy==1.26.4"

  echo "  [7-1b] verify numpy import via prefix only ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" "$PYTHON_BIN" - <<PY
import numpy as np
print("numpy =", np.__version__)
print("numpy file =", np.__file__)
PY
  echo

  echo "  [7-2] install mpi4py (build isolation ON, MPICH mpicc) ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" \
  MPICC="$MPICH_DAOS_DIR/bin/mpicc" \
  "$PYTHON_BIN" -m pip install --no-user --no-cache-dir --prefix "$PYDEPS_PREFIX" \
    --ignore-installed --upgrade --force-reinstall \
    --no-binary=mpi4py -v mpi4py

  echo "  [7-2b] verify mpi4py import ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" "$PYTHON_BIN" - <<PY
import mpi4py
print("mpi4py =", mpi4py.__version__)
print("mpi4py file =", mpi4py.__file__)
PY
  echo

  echo "  [7-3prep] pin Cython<3 for h5py build (avoid Cython 3 Plex breakage) ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" \
  "$PYTHON_BIN" -m pip install --no-user --no-cache-dir --prefix "$PYDEPS_PREFIX" \
    --ignore-installed --upgrade --force-reinstall \
    "Cython<3"

  echo "  [7-3precheck] verify numpy in prefix BEFORE building h5py ..."
  PYTHONPATH="$PYDEPS_PYTHONPATH" "$PYTHON_BIN" - <<PY
import numpy as np
print("numpy(pre) =", np.__version__)
print("numpy(pre) file =", np.__file__)
assert np.__version__.startswith("1.26."), "numpy must be 1.26.x pinned before building h5py"
PY
  echo

  echo "  [7-3] install ${H5PY_SPEC} (MPI mode build against our HDF5; HDF5_DIR only; NO-DEPS to prevent numpy upgrade) ..."

  PYTHONPATH="$PYDEPS_PYTHONPATH" \
  HDF5_VOL_CONNECTOR=native \
  HDF5_PLUGIN_PATH="" \
  HDF5_MPI=ON \
  HDF5_DIR="$HDF5_DIR" \
  HDF5_INCLUDEDIR="$HDF5_DIR/include" \
  HDF5_LIBDIR="$HDF5_DIR/lib" \
  LD_LIBRARY_PATH="$HDF5_DIR/lib:${LD_LIBRARY_PATH:-}" \
  PATH="$HDF5_DIR/bin:$PATH" \
  CC="$MPICH_DAOS_DIR/bin/mpicc" \
  bash -c '
    set -euo pipefail

    unset HDF5_VERSION HDF5_ROOT HDF5_INCLUDEDIR HDF5_LIBDIR HDF5_PKGCONFIG_NAME HDF5_HOME || true

    echo "[DEBUG] which h5dump: $(command -v h5dump || true)"
    echo "[DEBUG] h5dump -V:"
    h5dump -V || true

    echo "[DEBUG] env | egrep \"^(HDF5|CC|PATH|LD_LIBRARY_PATH)=\""
    env | egrep "^(HDF5|CC|PATH|LD_LIBRARY_PATH)=" || true

    "'"$PYTHON_BIN"'" -m pip install --no-user --no-cache-dir --prefix "'"$PYDEPS_PREFIX"'" \
      --ignore-installed --upgrade --force-reinstall \
      --no-deps \
      --no-binary=h5py \
      --no-build-isolation \
      -v "'"$H5PY_SPEC"'"
  '

  echo
  echo "== verify: import (prefix only) =="
  PYTHONPATH="$PYDEPS_PYTHONPATH" "$PYTHON_BIN" - <<PY
import numpy as np, mpi4py, h5py
print("numpy", np.__version__)
print("mpi4py", mpi4py.__version__)
print("h5py", h5py.__version__, "HDF5", h5py.version.hdf5_version, "MPI", h5py.get_config().mpi)
PY
  echo
fi

echo "=== DONE ==="
echo "[NEXT] source env:"
echo "       source \"$ENV_FILE\""
echo "       pin_daos_263          # ✅ DAOS 2.6.3 스택 강제(재발 방지)"
echo "       enable_daos_vol_bypass   # ✅ bypass 원샷"
echo
echo "[DEBUG] check sitecustomize only:"
echo "       DAOS_SITE_DEBUG=1 $PYTHON_BIN -c 'import sys; print(\"ok\"); print(sys.path[:6])'"
