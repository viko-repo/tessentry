
#!/usr/bin/env bash
# Tessentry safe updater.
# Preserves persistent data and fixes Sentry snapshot access.
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

# Permanent systemd fix for snapshot-backed Sentry videos.
WORKER_DROPIN_DIR="/etc/systemd/system/tessentry-worker.service.d"
WORKER_DROPIN="$WORKER_DROPIN_DIR/10-snapshot-access.conf"

DROPIN_BACKUP="/mutable/tessentry/upgrade-backups/worker-dropin-$STAMP.conf"

ROOT_CHANGED=0
BOOT_CHANGED=0
SWAPPED=0
STOPPED=0
SUCCESS=0
DROPIN_CHANGED=0
DROPIN_EXISTED=0

is_ro() {
  [[ ",$(findmnt -no OPTIONS "$1")," == *,ro,* ]]
}

ROOT_RO=0
BOOT_RO=0

is_ro / && ROOT_RO=1

if mountpoint -q /boot/firmware && is_ro /boot/firmware; then
  BOOT_RO=1
fi

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

    # Restore the previous systemd override.
    if (( DROPIN_CHANGED )); then
      if (( DROPIN_EXISTED )); then
        cp -a "$DROPIN_BACKUP" "$WORKER_DROPIN" || rc=1
      else
        rm -f "$WORKER_DROPIN" || rc=1
      fi

      systemctl daemon-reload || rc=1
    fi

    if (( STOPPED )); then
      systemctl restart \
        tessentry-worker.service \
        tessentry-web.service || rc=1
    fi
  fi

  if [[ -e "$STAGE" ]]; then
    rm -rf "$STAGE" || rc=1
  fi

  if (( BOOT_CHANGED )); then
    mount -o remount,ro /boot/firmware || rc=1
  fi

  if (( ROOT_CHANGED )); then
    mount -o remount,ro / || rc=1
  fi

  if (( SUCCESS )); then
    echo
    echo "Update successful."
    echo "Code backup: $BACKUP"
    echo "Persistent data backup: $STATE_BACKUP"
    echo "Worker snapshot access: PrivateTmp=no"
  fi

  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Validating Tessentry Python code..."

python3 - "$SRC/tessentry" <<'PY'
import pathlib
import sys

for p in pathlib.Path(sys.argv[1]).rglob('*.py'):
    compile(p.read_bytes(), str(p), 'exec')

print('Python syntax: OK')
PY

echo "Backing up installed application..."

tar -czf "$BACKUP" -C /opt/tessentry tessentry
chmod 600 "$BACKUP"

echo "Backing up persistent state..."

if [[ -d /mutable/tessentry ]]; then
  tar -czf "$STATE_BACKUP" \
    --exclude='./tessentry/upgrade-backups' \
    --exclude='*.mp4' \
    -C /mutable ./tessentry

  chmod 600 "$STATE_BACKUP"
fi

echo "Preparing filesystem..."

if (( ROOT_RO )); then
  mount -o remount,rw /
  ROOT_CHANGED=1
fi

# /boot/firmware is not modified by this updater.

echo "Staging new application code..."

mkdir -p "$STAGE"
cp -a "$SRC/tessentry/." "$STAGE/"

chown -R root:root "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +

echo "Preparing worker snapshot-access fix..."

# Preserve an existing override before changing it.
if [[ -f "$WORKER_DROPIN" ]]; then
  cp -a "$WORKER_DROPIN" "$DROPIN_BACKUP"
  chmod 600 "$DROPIN_BACKUP"
  DROPIN_EXISTED=1
fi

echo "Stopping Tessentry services..."

STOPPED=1
systemctl stop tessentry-worker.service tessentry-web.service

echo "Installing updated application..."

mv /opt/tessentry/tessentry "$PREVIOUS"

# Mark before the second move so rollback covers failures.
SWAPPED=1

mv "$STAGE" /opt/tessentry/tessentry

echo "Applying permanent Sentry snapshot-access fix..."

mkdir -p "$WORKER_DROPIN_DIR"

DROPIN_CHANGED=1

cat >"$WORKER_DROPIN" <<'UNIT'
[Service]
# Sentry-USB-Rusty exposes snapshot-backed clips via /tmp/snapshots.
# The worker must share the host temporary-file namespace.
PrivateTmp=no
UNIT

chmod 644 "$WORKER_DROPIN"

systemctl daemon-reload

echo "Verifying effective worker configuration..."

WORKER_PRIVATE_TMP="$(
  systemctl show \
    -p PrivateTmp \
    --value \
    tessentry-worker.service
)"

[[ "$WORKER_PRIVATE_TMP" == "no" || "$WORKER_PRIVATE_TMP" == "false" ]] || {
  echo "ERROR: Worker PrivateTmp is still enabled" >&2
  exit 1
}

echo "Starting Tessentry services..."

systemctl restart \
  tessentry-worker.service \
  tessentry-web.service

sleep 3

systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service

# Verify that both processes survive initial startup.
sleep 3

systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service

SUCCESS=1

echo
echo "=============================================="
echo "TESSENTRY UPDATE COMPLETED"
echo "=============================================="
echo "Application code updated successfully."
echo "Worker snapshot access: PrivateTmp=no"
echo "Web service security settings preserved."
echo "Persistent settings and event history preserved."
echo "Previous code retained at: $PREVIOUS"
echo "=============================================="
