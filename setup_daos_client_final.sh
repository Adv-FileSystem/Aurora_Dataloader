#!/bin/bash
set -euo pipefail

echo "=== Clean rebuild (CMake path): MPICH → HDF5 1.14.6 (MPI) → DAOS-VOL ==="

# ---------- 0) 경로 ----------
SRC="$HOME/src"; mkdir -p "$SRC"
DAOS_DIR="${DAOS_DIR:-$HOME/daos-install}"      # DAOS 클라이언트가 사전 설치되어 있다고 가정
MPICH_PREFIX="$HOME/software/mpich"
HDF5_PREFIX="$HOME/hdf5-1.14.6-install"
VOL_PREFIX="$HOME/daos-vol-install"

# ---------- 1) 정리 ----------
rm -rf "$MPICH_PREFIX" "$HDF5_PREFIX" "$VOL_PREFIX"
rm -rf "$SRC/mpich-3.4.3" "$SRC/hdf5" "$SRC/vol-daos"

# ---------- 2) MPICH 3.4.3 (ROMIO+ufs+daos) ----------
cd "$SRC"
unset CC CXX FC F77 F90 || true
hash -r
git clone -b v3.4.3 https://github.com/pmodels/mpich mpich-3.4.3
cd mpich-3.4.3
git submodule update --init --recursive
./autogen.sh
./configure --prefix="$MPICH_PREFIX" \
  --enable-fortran=all --enable-romio --enable-cxx --enable-g=all --enable-debuginfo \
  --with-device=ch3:nemesis --with-file-system=ufs+daos --with-daos="$DAOS_DIR" \
  FFLAGS=-fallow-argument-mismatch
make -j"$(nproc)"
make install

# ---------- 3) HDF5 1.14.6 (CMake, 병렬; C++ OFF, SZIP OFF) ----------
cd "$SRC"
git clone https://github.com/HDFGroup/hdf5.git
cd hdf5
git fetch --all --tags
git checkout hdf5_1_14_6
rm -rf build && mkdir build && cd build

cmake .. \
  -DCMAKE_INSTALL_PREFIX="$HDF5_PREFIX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$MPICH_PREFIX/bin/mpicc" \
  -DHDF5_ENABLE_PARALLEL=ON \
  -DHDF5_BUILD_CPP_LIB=OFF \
  -DHDF5_ENABLE_SZIP_SUPPORT=OFF \
  -DHDF5_BUILD_HL_LIB=ON \
  -DHDF5_BUILD_TOOLS=ON \
  -DHDF5_ENABLE_MAP_API=ON

cmake --build . -j"$(nproc)"
cmake --install .

# ---------- 4) DAOS VOL Plugin (같은 HDF5로) ----------
cd "$SRC"
git clone --recurse-submodules https://github.com/HDFGroup/vol-daos.git
cd vol-daos && rm -rf build && mkdir build && cd build

cmake .. \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$VOL_PREFIX" \
  -DHDF5_DIR="$HDF5_PREFIX/share/cmake/hdf5" \
  -DCMAKE_C_COMPILER="$MPICH_PREFIX/bin/mpicc" \
  -DDAOS_INCLUDE_DIR="$DAOS_DIR/include" \
  -DDAOS_LIBRARY="$DAOS_DIR/lib64/libdaos.so" \
  -DDAOS_UNS_LIBRARY="$DAOS_DIR/lib64/libduns.so" \
  -DBUILD_TESTING=OFF

cmake --build . -j"$(nproc)"
cmake --install .

# ---------- 5) 환경 세팅 ----------
cat > "$HOME/daos_env.sh" <<'EOF'
# === auto-generated ===
export HDF5_DIR="$HOME/hdf5-1.14.6-install"
export DAOS_DIR="$HOME/daos-install"
export MPICH_DAOS_DIR="$HOME/software/mpich"

export PATH="$HDF5_DIR/bin:$MPICH_DAOS_DIR/bin:$PATH"
#export LD_LIBRARY_PATH="$VOL_DIR/lib:$HDF5_DIR/lib:$DAOS_DIR/lib64:$MPICH_DAOS_DIR/lib:$HOME/daos-vol-install/lib:$LD_LIBRARY_PATH"
export LD_LIBRARY_PATH="$VOL_DIR/lib:$HDF5_DIR/lib:$DAOS_DIR/lib:$DAOS_DIR/lib64:$LD_LIBRARY_PATH"

export VOL_DIR="$HOME/daos-vol-install"
export HDF5_PLUGIN_PATH="$VOL_DIR/lib:$VOL_DIR/lib/hdf5/plugin"
# export HDF5_PLUGIN_PATH="$HOME/daos-vol-install/lib"
#export HDF5_VOL_CONNECTOR="daos"
export HDF5_VOL_CONNECTOR="daos;pool=$DAOS_POOL;cont=$DAOS_CONT"

export PYTHONPATH="$HOME/monkey_patch:$HOME/daos/src/client:$PYTHONPATH"

# 풀/컨테이너(실 값으로 교체 권장)
export DAOS_POOL="${DAOS_POOL:-cba6f3f3-8b08-4038-a6ab-7774a499dead}"
export DAOS_CONT="${DAOS_CONT:-8d2094b6-5e68-41c5-a806-e26bef46b4b1}"
EOF

chmod +x "$HOME/daos_env.sh"
grep -q 'source ~/daos_env.sh' "$HOME/.bashrc" 2>/dev/null || echo 'source ~/daos_env.sh' >> "$HOME/.bashrc"
# 즉시 적용
# shellcheck disable=SC1090
source "$HOME/daos_env.sh"

# ---------- 6) 검증 ----------
echo "== verify: lib links =="
ldd "$HDF5_PLUGIN_PATH/libhdf5_vol_daos.so" | grep -i hdf5 || true
which h5dump && h5dump -V || true
ldd "$(which h5dump)" | grep -i hdf5 || true

echo "=== DONE. 새 터미널 열거나 'source ~/daos_env.sh' 후 사용 ==="
