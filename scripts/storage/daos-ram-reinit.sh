#!/usr/bin/env bash
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

POOL_LABEL="${POOL_LABEL:-test_pool}"
POOL_SIZE="${POOL_SIZE:-20G}"
SCM_MOUNT="${SCM_MOUNT:-/mnt/daos}"

LOG="/var/log/daos/daos-ram-reinit.log"

mkdir -p /var/log/daos
exec >> "$LOG" 2>&1

echo "============================================================"
echo "[START] $(date '+%F %T') daos ram reinit on storage"
echo "POOL_LABEL=$POOL_LABEL"
echo "POOL_SIZE=$POOL_SIZE"
echo "SCM_MOUNT=$SCM_MOUNT"

echo "[0] check commands"
command -v dmg
command -v systemctl

echo "[1] wait daos_server active"
for i in {1..60}; do
  if systemctl is-active --quiet daos_server; then
    echo "[OK] daos_server active"
    break
  fi

  if [ "$i" -eq 60 ]; then
    echo "[FAIL] daos_server not active"
    systemctl status daos_server --no-pager -l || true
    exit 1
  fi

  sleep 2
done

echo "[2] wait management port"
for i in {1..60}; do
  if timeout 2 bash -c '</dev/tcp/10.0.2.101/10001' >/dev/null 2>&1; then
    echo "[OK] mgmt port open"
    break
  fi

  if [ "$i" -eq 60 ]; then
    echo "[FAIL] mgmt port not open"
    exit 1
  fi

  sleep 2
done

echo "[3] query system"
if dmg system query -v; then
  echo "[OK] system already initialized"
else
  echo "[WARN] system query failed. Checking whether storage format is required..."

  if journalctl -u daos_server -n 200 --no-pager -l | grep -qiE "SCM format required|Metadata format required|storage format required|system is uninitialized|requires a .* format"; then
    echo "[INFO] storage format required. Running dmg storage format."
    if dmg storage format; then
       echo "[OK] dmg storage format completed"
    else
       echo "[FAIL] dmg storage format failed"
       echo "[HINT] Visible storage:"
       dmg storage scan || true
       echo "[HINT] Recent daos_server logs:"
       journalctl -u daos_server -n 80 --no-pager -l || true
       exit 1
  fi
  else
    echo "[FAIL] system query failed but no clear format-required message found."
    journalctl -u daos_server -n 200 --no-pager -l || true
    exit 1
  fi
fi

echo "[4] wait system joined after format"
for i in {1..90}; do
  if dmg system query -v; then
    echo "[OK] system query OK"
    break
  fi

  if [ "$i" -eq 90 ]; then
    echo "[FAIL] system did not become ready"
    journalctl -u daos_server -n 200 --no-pager -l || true
    exit 1
  fi

  sleep 2
done

echo "[5] ensure pool exists: $POOL_LABEL"
if dmg pool query "$POOL_LABEL" >/dev/null 2>&1; then
  echo "[OK] pool exists: $POOL_LABEL"
else
  echo "[INFO] creating pool with dmg: $POOL_LABEL size=$POOL_SIZE"

  if dmg pool create --size "$POOL_SIZE" --user=keti@ "$POOL_LABEL"; then
    echo "[OK] pool created with owner keti@: $POOL_LABEL"
  elif dmg pool create --size "$POOL_SIZE" "$POOL_LABEL"; then
    echo "[OK] pool created without explicit owner: $POOL_LABEL"
  else
    echo "[FAIL] pool create failed"
    dmg pool create --help || true
    exit 1
  fi
fi

echo "[6] final pool query"
dmg pool query "$POOL_LABEL"

echo "[DONE] $(date '+%F %T') storage reinit complete"
echo "[NEXT] Go to client server and run daos-client-reinit.sh"
