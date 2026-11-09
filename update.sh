
#!/usr/bin/env bash
# Tessentry v1.3.0 safe updater for Sentry-USB-Rusty.
# Preserves persistent data and provides rollback on failure.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || {
  echo 'Run as root (sudo)' >&2
  exit 1
}

for cmd in python3 tar systemctl mount findmnt flock; do
  command -v "$cmd" >/dev/null || {
    echo "Missing: $cmd" >&2
    exit 1
  }
done

mountpoint -q /mutable && [[ -w /mutable ]] || {
  echo '/mutable must be writable' >&2
  exit 1
}

[[ -d /opt/tessentry/tessentry ]] || {
  echo 'Tessentry is not installed' >&2
  exit 1
}

for svc in tessentry-worker.service tessentry-web.service; do
  [[ -f /etc/systemd/system/$svc ]] || {
    echo "Missing service: $svc" >&2
    exit 1
  }
done

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$SRC/tessentry/core.py" && -f "$SRC/tessentry/web.py" ]] || {
  echo 'Source code missing' >&2
  exit 1
}

mkdir -p /mutable/tessentry/upgrade-backups
chmod 700 /mutable/tessentry/upgrade-backups

exec 9>/mutable/tessentry/upgrade-backups/update.lock
flock -n 9 || {
  echo 'Another update is running' >&2
  exit 1
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"

BACKUP="/mutable/tessentry/upgrade-backups/code-$STAMP.tar.gz"
STATE_BACKUP="/mutable/tessentry/upgrade-backups/state-$STAMP.tar.gz"

PREVIOUS="/opt/tessentry/.previous-$STAMP"
STAGE="/opt/tessentry/.stage-$STAMP"

WORKER_DROPIN_DIR="/etc/systemd/system/tessentry-worker.service.d"
WORKER_DROPIN="$WORKER_DROPIN_DIR/10-snapshot-access.conf"

ARCHIVE_SERVICE="sentryusb-archive.service"
ARCHIVE_DROPIN_DIR="/etc/systemd/system/${ARCHIVE_SERVICE}.d"
ARCHIVE_DROPIN="$ARCHIVE_DROPIN_DIR/50-tessentry-snapshot-interval.conf"

WORKER_BACKUP="/mutable/tessentry/upgrade-backups/worker-$STAMP.conf"
ARCHIVE_BACKUP="/mutable/tessentry/upgrade-backups/archive-$STAMP.conf"

ROOT_CHANGED=0
SWAPPED=0
STOPPED=0
SUCCESS=0

WORKER_CHANGED=0
WORKER_EXISTED=0
ARCHIVE_CHANGED=0
ARCHIVE_EXISTED=0
ARCHIVE_WAS_ACTIVE=0

is_ro() {
  [[ ",$(findmnt -no OPTIONS "$1")," == *,ro,* ]]
}

ROOT_RO=0
is_ro / && ROOT_RO=1

cleanup() {
  local rc=$?
  trap - EXIT INT TERM

  if (( ! SUCCESS )); then
    echo 'Update failed; restoring previous installation...' >&2

    if (( SWAPPED )); then
      rm -rf /opt/tessentry/tessentry || rc=1

      if [[ -d "$PREVIOUS" ]]; then
        mv "$PREVIOUS" /opt/tessentry/tessentry || rc=1
      else
        echo 'Previous code missing!' >&2
        rc=1
      fi
    fi

    if (( WORKER_CHANGED )); then
      if (( WORKER_EXISTED )); then
        cp -a "$WORKER_BACKUP" "$WORKER_DROPIN" || rc=1
      else
        rm -f "$WORKER_DROPIN" || rc=1
      fi
    fi

    if (( ARCHIVE_CHANGED )); then
      if (( ARCHIVE_EXISTED )); then
        cp -a "$ARCHIVE_BACKUP" "$ARCHIVE_DROPIN" || rc=1
      else
        rm -f "$ARCHIVE_DROPIN" || rc=1
      fi
    fi

    if (( WORKER_CHANGED || ARCHIVE_CHANGED )); then
      systemctl daemon-reload || rc=1
    fi

    if (( STOPPED )); then
      systemctl restart \
        tessentry-worker.service \
        tessentry-web.service || rc=1
    fi

    if (( ARCHIVE_CHANGED && ARCHIVE_WAS_ACTIVE )); then
      systemctl restart "$ARCHIVE_SERVICE" || rc=1
    fi
  fi

  if [[ -e "$STAGE" ]]; then
    rm -rf "$STAGE" || rc=1
  fi

  if (( ROOT_CHANGED )); then
    sync
    mount -o remount,ro / || rc=1
  fi

  if (( SUCCESS )); then
    echo
    echo "Update successful."
    echo "Code backup: $BACKUP"
    echo "Persistent data backup: $STATE_BACKUP"
    echo "Worker snapshot access: PrivateTmp=no"
    echo "Snapshot interval: 300 seconds (when supported)"
  fi

  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Validating Tessentry application..."

python3 - "$SRC/tessentry" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

for path in root.rglob('*.py'):
    compile(path.read_bytes(), str(path), 'exec')

for lang in ('en', 'he'):
    path = root / 'locales' / f'{lang}.json'
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict):
        raise ValueError(f'Invalid locale: {lang}')

print('Python and locale validation: OK')
PY

echo "Backing up installed application..."

tar -czf "$BACKUP" -C /opt/tessentry tessentry
chmod 600 "$BACKUP"

echo "Backing up persistent state..."

tar -czf "$STATE_BACKUP" \
  --exclude='./tessentry/upgrade-backups' \
  --exclude='*.mp4' \
  -C /mutable ./tessentry

chmod 600 "$STATE_BACKUP"

echo "Preparing filesystem..."

if (( ROOT_RO )); then
  mount -o remount,rw /
  ROOT_CHANGED=1
fi

echo "Staging updated application..."

mkdir -p "$STAGE"
cp -a "$SRC/tessentry/." "$STAGE/"

chown -R root:root "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +

echo "Backing up systemd overrides..."

if [[ -f "$WORKER_DROPIN" ]]; then
  cp -a "$WORKER_DROPIN" "$WORKER_BACKUP"
  chmod 600 "$WORKER_BACKUP"
  WORKER_EXISTED=1
fi

if systemctl cat "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  if [[ -f "$ARCHIVE_DROPIN" ]]; then
    cp -a "$ARCHIVE_DROPIN" "$ARCHIVE_BACKUP"
    chmod 600 "$ARCHIVE_BACKUP"
    ARCHIVE_EXISTED=1
  fi

  if systemctl is-active --quiet "$ARCHIVE_SERVICE"; then
    ARCHIVE_WAS_ACTIVE=1
  fi
fi

echo "Stopping Tessentry services..."

STOPPED=1
systemctl stop tessentry-worker.service tessentry-web.service

echo "Installing updated application..."

mv /opt/tessentry/tessentry "$PREVIOUS"
SWAPPED=1
mv "$STAGE" /opt/tessentry/tessentry

echo "Configuring worker snapshot access..."

mkdir -p "$WORKER_DROPIN_DIR"
WORKER_CHANGED=1

cat >"$WORKER_DROPIN" <<'UNIT'
[Service]
# Share the host /tmp namespace to access Sentry snapshots.
PrivateTmp=no
UNIT

chmod 644 "$WORKER_DROPIN"

echo "Configuring snapshot interval..."

if systemctl cat "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  mkdir -p "$ARCHIVE_DROPIN_DIR"
  ARCHIVE_CHANGED=1

  cat >"$ARCHIVE_DROPIN" <<'UNIT'
[Service]
Environment="SNAPSHOT_INTERVAL=300"
UNIT

  chmod 644 "$ARCHIVE_DROPIN"
else
  echo "WARNING: Archive service not found; snapshot interval unchanged."
fi

systemctl daemon-reload

echo "Verifying worker configuration..."

WORKER_PRIVATE_TMP="$(
  systemctl show -p PrivateTmp --value tessentry-worker.service
)"

[[ "$WORKER_PRIVATE_TMP" == "no" || "$WORKER_PRIVATE_TMP" == "false" ]] || {
  echo "ERROR: Worker PrivateTmp is still enabled" >&2
  exit 1
}

echo "Starting Tessentry services..."

systemctl restart tessentry-worker.service tessentry-web.service

sleep 3

systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service

sleep 3

systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service

if (( ARCHIVE_CHANGED && ARCHIVE_WAS_ACTIVE )); then
  echo "Restarting archive service to apply snapshot interval..."
  systemctl restart "$ARCHIVE_SERVICE"
  systemctl is-active --quiet "$ARCHIVE_SERVICE"
fi

SUCCESS=1

echo
echo "=============================================="
echo "TESSENTRY v1.3.0 UPDATE COMPLETED"
echo "=============================================="
echo "Application code updated successfully."
echo "Worker snapshot access: PrivateTmp=no"
echo "Snapshot interval: 300 seconds (when supported)"
echo "Web service security settings preserved."
echo "Persistent settings and event history preserved."
echo "Previous code retained at: $PREVIOUS"
echo "=============================================="
