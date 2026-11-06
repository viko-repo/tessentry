#!/usr/bin/env bash
# Tessentry safe code-only updater. Persistent data in /mutable/tessentry is never replaced.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root (sudo)' >&2; exit 1; }
for cmd in python3 tar systemctl mount findmnt flock; do command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }; done
mountpoint -q /mutable && [[ -w /mutable ]] || { echo '/mutable must be writable' >&2; exit 1; }
[[ -d /opt/tessentry/tessentry ]] || { echo 'Tessentry is not installed' >&2; exit 1; }
for svc in tessentry-worker.service tessentry-web.service; do
  [[ -f /etc/systemd/system/$svc ]] || { echo "Missing service: $svc" >&2; exit 1; }
done
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SRC/tessentry/core.py" && -f "$SRC/tessentry/web.py" ]] || { echo 'Source code missing' >&2; exit 1; }
mkdir -p /mutable/tessentry/upgrade-backups
chmod 700 /mutable/tessentry/upgrade-backups
exec 9>/mutable/tessentry/upgrade-backups/update.lock
flock -n 9 || { echo 'Another update is running' >&2; exit 1; }
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP="/mutable/tessentry/upgrade-backups/code-$STAMP.tar.gz"
STATE_BACKUP="/mutable/tessentry/upgrade-backups/state-$STAMP.tar.gz"
PREVIOUS="/opt/tessentry/.previous-$STAMP"
STAGE="/opt/tessentry/.stage-$STAMP"
ROOT_CHANGED=0; BOOT_CHANGED=0; SWAPPED=0; STOPPED=0; SUCCESS=0
is_ro() { [[ ",$(findmnt -no OPTIONS "$1")," == *,ro,* ]]; }
ROOT_RO=0; BOOT_RO=0
is_ro / && ROOT_RO=1
if mountpoint -q /boot/firmware && is_ro /boot/firmware; then BOOT_RO=1; fi
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if (( ! SUCCESS )); then
    echo 'Update failed; restoring previous code if needed...' >&2
    if (( SWAPPED )); then
      rm -rf /opt/tessentry/tessentry || rc=1
      if [[ -d "$PREVIOUS" ]]; then mv "$PREVIOUS" /opt/tessentry/tessentry || rc=1; else echo 'Previous code missing!' >&2; rc=1; fi
    fi
    if (( STOPPED )); then
      systemctl restart tessentry-worker.service tessentry-web.service || rc=1
    fi
  fi
  [[ ! -e "$STAGE" ]] || rm -rf "$STAGE" || rc=1
  if (( BOOT_CHANGED )); then mount -o remount,ro /boot/firmware || rc=1; fi
  if (( ROOT_CHANGED )); then mount -o remount,ro / || rc=1; fi
  if (( SUCCESS )); then
    echo "Update successful. Code backup: $BACKUP"
    echo "Persistent data backup: $STATE_BACKUP"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$SRC/tessentry" <<'PY'
import pathlib, sys
for p in pathlib.Path(sys.argv[1]).rglob('*.py'):
    compile(p.read_bytes(), str(p), 'exec')
print('Python syntax: OK')
PY
# Backup before any changes. Exclude backup archive directory to avoid recursion.
tar -czf "$BACKUP" -C /opt/tessentry tessentry
chmod 600 "$BACKUP"
if [[ -d /mutable/tessentry ]]; then
  tar -czf "$STATE_BACKUP" --exclude='./tessentry/upgrade-backups' --exclude='*.mp4' -C /mutable ./tessentry
  chmod 600 "$STATE_BACKUP"
fi
if (( ROOT_RO )); then mount -o remount,rw /; ROOT_CHANGED=1; fi
# /boot/firmware is not modified by this code-only update: leave it read-only.
mkdir -p "$STAGE"
cp -a "$SRC/tessentry/." "$STAGE/"
chown -R root:root "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
# Stop services only after the staged code is ready.
systemctl stop tessentry-worker.service tessentry-web.service
STOPPED=1
mv /opt/tessentry/tessentry "$PREVIOUS"
# Mark as swapped before the second move so rollback also covers failures here.
SWAPPED=1
mv "$STAGE" /opt/tessentry/tessentry
systemctl restart tessentry-worker.service tessentry-web.service
sleep 3
systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service
# Check that both processes survive the initial startup period.
sleep 3
systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service
SUCCESS=1
# Keep the previous code directory for manual rollback and investigation.
echo "Previous code retained at: $PREVIOUS"
