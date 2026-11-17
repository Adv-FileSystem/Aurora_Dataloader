#!/usr/bin/env bash

case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

STAMP="/tmp/daos_client_login_auto_check_${USER}.stamp"
NOW="$(date +%s)"
LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"

if [ $((NOW - LAST)) -lt 300 ]; then
  echo "[DAOS] client login auto-check skipped, cooldown active"
  return 0 2>/dev/null || exit 0
fi

echo "$NOW" > "$STAMP"

echo "============================================================"
echo "[DAOS] Client login reinit/check start: $(date '+%F %T')"

echo "[1] run client reinit"
sudo systemctl start daos-client-reinit.service || /usr/local/sbin/daos-client-reinit.sh

echo "[2] source DAOS env"
if [ -f "$HOME/daos_test_env.sh" ]; then
  source "$HOME/daos_test_env.sh"
fi

echo "[3] env check"
echo "DAOS_POOL=$DAOS_POOL"
echo "DAOS_CONT=$DAOS_CONT"
echo "DAOS_HDF5_CONT=$DAOS_HDF5_CONT"
echo "HDF5_VOL_CONNECTOR=$HDF5_VOL_CONNECTOR"
echo "HDF5_PLUGIN_PATH=$HDF5_PLUGIN_PATH"
echo "HDF5_DAOS_BYPASS_DUNS=$HDF5_DAOS_BYPASS_DUNS"

echo "[4] pool query"
timeout 10 daos pool query "$DAOS_POOL" || true

echo "[5] HDF5 container query"
timeout 10 daos container query "$DAOS_POOL" "$DAOS_HDF5_CONT" || true

echo "[DAOS] Client login reinit/check done"
echo "============================================================"
