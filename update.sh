#!/usr/bin/env bash
# Tessentry v1.3.0 updater — consistent stopped-service backup and rollback.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
for cmd in python3 tar systemctl mount findmnt mountpoint flock; do
  command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }
done
mountpoint -q /mutable && [[ -w /mutable ]] || { echo '/mutable must be mounted and writable' >&2; exit 1; }
[[ -d /opt/tessentry/tessentry ]] || { echo 'Tessentry is not installed' >&2; exit 1; }
for svc in tessentry-worker.service tessentry-web.service; do
  systemctl cat "$svc" >/dev/null 2>&1 || { echo "Missing service: $svc" >&2; exit 1; }
done
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -d "$SRC/tessentry" ]] || { echo 'Source directory missing' >&2; exit 1; }

python3 - "$SRC/tessentry" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ('core.py', 'web.py', '__init__.py', '__main__.py'):
    p = root / name
    compile(p.read_bytes(), str(p), 'exec')
for name in ('en.json', 'he.json'):
    p = root / 'locales' / name
    assert isinstance(json.loads(p.read_text(encoding='utf-8')), dict)
print('Source validation: OK')
PY

BACKUP_DIR=/mutable/tessentry/upgrade-backups
install -d -m 700 "$BACKUP_DIR"
exec 9>"$BACKUP_DIR/update.lock"
flock -n 9 || { echo 'Another update is running' >&2; exit 1; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
CODE_BACKUP="$BACKUP_DIR/code-$STAMP.tar.gz"
STATE_BACKUP="$BACKUP_DIR/state-$STAMP.tar.gz"
PREVIOUS="/opt/tessentry/.previous-$STAMP"
STAGE="/opt/tessentry/.stage-$STAMP"
WORKER_OVERRIDE=/etc/systemd/system/tessentry-worker.service.d/10-snapshot-access.conf
ARCHIVE_SERVICE=sentryusb-archive.service
ARCHIVE_OVERRIDE=/etc/systemd/system/sentryusb-archive.service.d/50-tessentry-snapshot-interval.conf
WORKER_BACKUP="$BACKUP_DIR/worker-$STAMP.conf"
ARCHIVE_BACKUP="$BACKUP_DIR/archive-$STAMP.conf"

ROOT_WAS_RO=0
[[ ",$(findmnt -no OPTIONS /)," == *,ro,* ]] && ROOT_WAS_RO=1
ROOT_REMOUNT_ATTEMPTED=0
STOP_ATTEMPTED=0
OLD_MOVED=0
NEW_INSTALLED=0
WORKER_CHANGED=0
ARCHIVE_CHANGED=0
WORKER_EXISTED=0
ARCHIVE_EXISTED=0
ARCHIVE_WAS_ACTIVE=0
SUCCESS=0

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( ! SUCCESS )); then
    echo 'Update failed. Attempting rollback...' >&2
    if (( OLD_MOVED )); then
      if (( NEW_INSTALLED )); then
        rm -rf /opt/tessentry/tessentry || rc=1
      fi
      if [[ -d "$PREVIOUS" ]]; then
        mv "$PREVIOUS" /opt/tessentry/tessentry || rc=1
      else
        echo 'CRITICAL: Previous application directory missing' >&2
        rc=1
      fi
    fi
    if (( WORKER_CHANGED )); then
      if (( WORKER_EXISTED )); then
        cp -a "$WORKER_BACKUP" "$WORKER_OVERRIDE" || rc=1
      else
        rm -f "$WORKER_OVERRIDE" || rc=1
      fi
    fi
    if (( ARCHIVE_CHANGED )); then
      if (( ARCHIVE_EXISTED )); then
        cp -a "$ARCHIVE_BACKUP" "$ARCHIVE_OVERRIDE" || rc=1
      else
        rm -f "$ARCHIVE_OVERRIDE" || rc=1
      fi
    fi
    if (( WORKER_CHANGED || ARCHIVE_CHANGED )); then
      systemctl daemon-reload || rc=1
    fi
    if (( STOP_ATTEMPTED )); then
      systemctl restart tessentry-worker.service tessentry-web.service || rc=1
      systemctl is-active --quiet tessentry-worker.service || rc=1
      systemctl is-active --quiet tessentry-web.service || rc=1
    fi
    if (( ARCHIVE_CHANGED && ARCHIVE_WAS_ACTIVE )); then
      systemctl restart "$ARCHIVE_SERVICE" || rc=1
      systemctl is-active --quiet "$ARCHIVE_SERVICE" || rc=1
    fi
    (( rc != 0 )) || rc=1
  fi
  if [[ -d "$STAGE" ]]; then
    rm -rf "$STAGE" || rc=1
  fi
  if (( ROOT_WAS_RO && ROOT_REMOUNT_ATTEMPTED )); then
    sync
    mount -o remount,ro / || { echo 'CRITICAL: Root filesystem could not be restored read-only' >&2; rc=1; }
  fi
  if (( SUCCESS )); then
    echo "Update successful. Code backup: $CODE_BACKUP"
    echo "Stopped-service data backup: $STATE_BACKUP"
    echo "Previous code retained: $PREVIOUS"
  else
    echo "Rollback attempted. Check service status and backups before retrying." >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo 'Backing up current code...'
tar -czf "$CODE_BACKUP" -C /opt/tessentry tessentry
chmod 600 "$CODE_BACKUP"

echo 'Preparing root filesystem...'
if (( ROOT_WAS_RO )); then
  ROOT_REMOUNT_ATTEMPTED=1
  mount -o remount,rw /
fi

echo 'Staging new code...'
mkdir "$STAGE"
cp -a "$SRC/tessentry/." "$STAGE/"
chown -R root:root "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +

if [[ -f "$WORKER_OVERRIDE" ]]; then
  cp -a "$WORKER_OVERRIDE" "$WORKER_BACKUP"
  chmod 600 "$WORKER_BACKUP"
  WORKER_EXISTED=1
fi
if systemctl cat "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  if [[ -f "$ARCHIVE_OVERRIDE" ]]; then
    cp -a "$ARCHIVE_OVERRIDE" "$ARCHIVE_BACKUP"
    chmod 600 "$ARCHIVE_BACKUP"
    ARCHIVE_EXISTED=1
  fi
  systemctl is-active --quiet "$ARCHIVE_SERVICE" && ARCHIVE_WAS_ACTIVE=1 || true
fi

echo 'Stopping Tessentry services for a consistent data backup...'
STOP_ATTEMPTED=1
systemctl stop tessentry-worker.service tessentry-web.service
systemctl is-active --quiet tessentry-worker.service && { echo 'Worker still active' >&2; exit 1; } || true
systemctl is-active --quiet tessentry-web.service && { echo 'Web still active' >&2; exit 1; } || true

echo 'Backing up persistent state while Tessentry is stopped...'
tar -czf "$STATE_BACKUP" \
  --exclude='./tessentry/upgrade-backups' \
  --exclude='*.mp4' \
  -C /mutable ./tessentry
chmod 600 "$STATE_BACKUP"
tar -tzf "$STATE_BACKUP" >/dev/null

echo 'Installing new application...'
mv /opt/tessentry/tessentry "$PREVIOUS"
OLD_MOVED=1
mv "$STAGE" /opt/tessentry/tessentry
NEW_INSTALLED=1

echo 'Configuring snapshot access...'
install -d -m 755 "$(dirname "$WORKER_OVERRIDE")"
WORKER_CHANGED=1
cat >"$WORKER_OVERRIDE" <<'UNIT'
[Service]
PrivateTmp=no
UNIT
chmod 644 "$WORKER_OVERRIDE"

if systemctl cat "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  if systemctl show "$ARCHIVE_SERVICE" -p Environment --value |
      tr ' ' '\n' | grep -Fxq 'SNAPSHOT_INTERVAL=300'; then
    echo 'Archive interval already 300 seconds; leaving it unchanged.'
  else
    install -d -m 755 "$(dirname "$ARCHIVE_OVERRIDE")"
    ARCHIVE_CHANGED=1
    cat >"$ARCHIVE_OVERRIDE" <<'UNIT'
[Service]
Environment="SNAPSHOT_INTERVAL=300"
UNIT
    chmod 644 "$ARCHIVE_OVERRIDE"
  fi
else
  echo 'Archive service not found; leaving its settings unchanged.'
fi

systemctl daemon-reload
PRIVATE_TMP="$(systemctl show tessentry-worker.service -p PrivateTmp --value)"
[[ "$PRIVATE_TMP" == no || "$PRIVATE_TMP" == false ]] || { echo 'Worker still has PrivateTmp enabled' >&2; exit 1; }

echo 'Starting updated services...'
systemctl restart tessentry-worker.service tessentry-web.service
sleep 3
systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service
if (( ARCHIVE_CHANGED && ARCHIVE_WAS_ACTIVE )); then
  systemctl restart "$ARCHIVE_SERVICE"
  systemctl is-active --quiet "$ARCHIVE_SERVICE"
fi
SUCCESS=1
printf '\nTessentry v1.3.0 update completed. Persistent state preserved.\n'
