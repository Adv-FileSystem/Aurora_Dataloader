#!/usr/bin/env bash
set -euo pipefail

POOL_LABEL="${POOL_LABEL:-test_pool}"
HDF5_CONT="${HDF5_CONT:-hdf5_cont}"
POSIX_CONT="${POSIX_CONT:-posix_cont}"

RUN_USER="${SUDO_USER:-$(whoami)}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
DFUSE_MOUNT="${DFUSE_MOUNT:-$RUN_HOME/dfuse_mount}"
ENV_FILE="$RUN_HOME/daos_test_env.sh"
LOG="$RUN_HOME/daos-client-reinit.log"

exec >> "$LOG" 2>&1

echo "============================================================"
echo "[START] $(date '+%F %T') DAOS client reinit"
echo "RUN_USER=$RUN_USER"
echo "POOL_LABEL=$POOL_LABEL"
echo "HDF5_CONT=$HDF5_CONT"

echo "[1] ensure daos_agent active"
if ! systemctl is-active --quiet daos_agent; then
  sudo systemctl start daos_agent
fi

echo "[2] wait daos_agent socket"
for i in {1..30}; do
  if [ -S /var/run/daos_agent/daos_agent.sock ]; then
    echo "[OK] daos_agent socket exists"
    break
  fi

  if [ "$i" -eq 30 ]; then
    echo "[FAIL] daos_agent socket missing"
    systemctl status daos_agent --no-pager -l || true
    exit 1
  fi

  sleep 2
done

export DAOS_AGENT_DRPC_DIR=/var/run/daos_agent

echo "[3] wait pool ready: $POOL_LABEL"
for i in {1..120}; do
  if daos pool query "$POOL_LABEL"; then
    echo "[OK] pool ready: $POOL_LABEL"
    break
  fi

  if [ "$i" -eq 120 ]; then
    echo "[FAIL] pool not ready: $POOL_LABEL"
    exit 1
  fi

  sleep 5
done

echo "[4] ensure HDF5 container exists: $HDF5_CONT"
if daos container query "$POOL_LABEL" "$HDF5_CONT"; then
  echo "[OK] HDF5 container exists: $HDF5_CONT"
else
  echo "[INFO] creating HDF5 container: $HDF5_CONT"

  if daos container create --type HDF5 "$POOL_LABEL" "$HDF5_CONT"; then
    echo "[OK] HDF5 container created: positional label syntax"
  elif daos container create --type HDF5 --label "$HDF5_CONT" "$POOL_LABEL"; then
    echo "[OK] HDF5 container created: --label syntax"
  elif daos cont create --type HDF5 --label "$HDF5_CONT" "$POOL_LABEL"; then
    echo "[OK] HDF5 container created: cont alias syntax"
  else
    echo "[FAIL] failed to create HDF5 container"
    exit 1
  fi
fi

POSIX_CONT="${POSIX_CONT:-posix_cont}"

echo "[4-1] ensure POSIX container exists: $POSIX_CONT"
if daos container query "$POOL_LABEL" "$POSIX_CONT"; then
  echo "[OK] POSIX container exists: $POSIX_CONT"
else
  echo "[INFO] creating POSIX container: $POSIX_CONT"

  if daos container create --type POSIX "$POOL_LABEL" "$POSIX_CONT"; then
    echo "[OK] POSIX container created: $POSIX_CONT"
  else
    echo "[FAIL] failed to create POSIX container: $POSIX_CONT"
    exit 1
  fi
fi

echo "[4-2] ensure DFuse mount: $DFUSE_MOUNT"

if ! command -v dfuse >/dev/null 2>&1; then
  echo "[WARN] dfuse command not found. Skipping DFuse mount."
else
  echo "[INFO] cleanup stale DFuse mount if any"

  fusermount -uz "$DFUSE_MOUNT" 2>/dev/null || true
  fusermount3 -uz "$DFUSE_MOUNT" 2>/dev/null || true
  umount -l "$DFUSE_MOUNT" 2>/dev/null || true

  mkdir -p "$DFUSE_MOUNT"
  chown "$RUN_USER:$RUN_USER" "$DFUSE_MOUNT" 2>/dev/null || true

  echo "[INFO] mounting DFuse: pool=$POOL_LABEL container=$POSIX_CONT mount=$DFUSE_MOUNT"

  if dfuse --mountpoint "$DFUSE_MOUNT" \
           --pool "$POOL_LABEL" \
           --container "$POSIX_CONT"; then
    echo "[OK] DFuse mounted: $DFUSE_MOUNT"
  elif dfuse -m "$DFUSE_MOUNT" \
             --pool "$POOL_LABEL" \
             --container "$POSIX_CONT"; then
    echo "[OK] DFuse mounted with -m: $DFUSE_MOUNT"
  else
    echo "[FAIL] DFuse mount failed"
    exit 1
  fi
fi

echo "[5] write env file: $ENV_FILE"
cat > "$ENV_FILE" <<ENVEOF
export DAOS_POOL=$POOL_LABEL

# HDF5 VOL-DAOS bypass
export DAOS_CONT=$HDF5_CONT
export DAOS_HDF5_CONT=$HDF5_CONT

# POSIX / DFuse
export DAOS_POSIX_CONT=$POSIX_CONT
export DAOS_DFUSE_MOUNT=$DFUSE_MOUNT

export DAOS_AGENT_DRPC_DIR=/var/run/daos_agent

export HDF5_VOL_CONNECTOR=daos
export HDF5_PLUGIN_PATH=/home/keti/for_dataloader_RHA/.deps/keti/daos-vol-install/lib
export HDF5_DAOS_BYPASS_DUNS=1

export DAOS_BYPASS_DUNS=1
export ROMIO_FSTYPE_FORCE=daos:
ENVEOF

chown "$RUN_USER:$RUN_USER" "$ENV_FILE"

echo "[6] final check"
daos pool query "$POOL_LABEL"
daos container query "$POOL_LABEL" "$HDF5_CONT"

echo "[DONE] $(date '+%F %T') client reinit complete"
