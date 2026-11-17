#!/usr/bin/env bash

# SSH interactive login에서만 실행
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

# 너무 자주 실행되지 않게 5분 쿨다운
STAMP="/tmp/daos_login_auto_check_${USER}.stamp"
NOW="$(date +%s)"
LAST="$(cat "$STAMP" 2>/dev/null || echo 0)"

if [ $((NOW - LAST)) -lt 300 ]; then
  echo "[DAOS] login auto-check skipped, cooldown active"
  return 0 2>/dev/null || exit 0
fi

echo "$NOW" > "$STAMP"

echo "============================================================"
echo "[DAOS] Storage login auto recover/check start: $(date '+%F %T')"

echo "[1] start storage auto recover service"
sudo systemctl start daos-storage-auto-recover.service

echo "[2] recent recover log"
sudo tail -n 80 /var/log/daos/daos-storage-auto-recover.log || true

echo "[3] DAOS system query"
sudo dmg system query -v || true

echo "[4] DAOS pool query: test_pool"
sudo dmg pool query test_pool || true

echo "[DAOS] Storage login auto recover/check done"
echo "============================================================"
