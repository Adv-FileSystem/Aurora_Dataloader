#!/usr/bin/env bash

# WSL/client 로그인 시 DAOS 실험 환경 복구용
# - storage 서버: daos_server / storage format / pool create
# - client 서버: daos_agent / container create / env 적용

set -u

STORAGE_HOST="${STORAGE_HOST:-ketiops-daos-storage}"
STORAGE_USER="${STORAGE_USER:-keti}"
STORAGE_REINIT="${STORAGE_REINIT:-/usr/local/sbin/daos-ram-reinit.sh}"

CLIENT_REINIT="${CLIENT_REINIT:-/usr/local/sbin/daos-client-reinit.sh}"
CLIENT_ENV="${CLIENT_ENV:-$HOME/daos_test_env.sh}"

# 기존 DAOS/HDF5/MPICH/VOL 환경파일
# 실제 파일이 있으면 사용, 없으면 건너뜀
PROJECT_ENV="${PROJECT_ENV:-$HOME/for_dataloader_RHA/env/daos_env_keti.sh}"

LOG="$HOME/daos_auto_recover_on_login.log"

{
  echo "============================================================"
  echo "[START] $(date '+%F %T') DAOS auto recover on login"
  echo "[INFO] STORAGE_HOST=$STORAGE_HOST"
  echo "[INFO] PROJECT_ENV=$PROJECT_ENV"
  echo "[INFO] CLIENT_ENV=$CLIENT_ENV"

  echo "[1] recover storage server via ssh"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$STORAGE_USER@$STORAGE_HOST" "sudo $STORAGE_REINIT"; then
    echo "[OK] storage reinit completed"
  else
    echo "[WARN] storage reinit failed or SSH/sudo requires password"
    echo "[WARN] Run manually on storage:"
    echo "       sudo $STORAGE_REINIT"
  fi

  echo "[2] ensure daos_agent on client"
  if systemctl is-active --quiet daos_agent; then
    echo "[OK] daos_agent already active"
  else
    echo "[INFO] starting daos_agent"
    sudo systemctl start daos_agent || {
      echo "[FAIL] cannot start daos_agent"
      exit 1
    }
  fi

  echo "[3] run client reinit"
  if "$CLIENT_REINIT"; then
    echo "[OK] client reinit completed"
  else
    echo "[FAIL] client reinit failed"
    exit 1
  fi

  echo "[4] source env files into current shell? cannot from child process"
  echo "[INFO] This script prepares env file, but .bashrc must source it separately."

  echo "[DONE] $(date '+%F %T') DAOS auto recover finished"
} >> "$LOG" 2>&1
