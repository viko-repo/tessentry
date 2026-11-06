#!/usr/bin/env bash
# Tessentry transactional code updater. Run on the Raspberry Pi as root.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash update.sh' >&2; exit 1; }
command -v python3 >/dev/null && command -v tar >/dev/null && command -v systemctl >/dev/null || { echo 'Missing required utilities' >&2; exit 1; }
mountpoint -q /mutable && [[ -w /mutable ]] || { echo '/mutable must be mounted read-write' >&2; exit 1; }
[[ -d /opt/tessentry/tessentry ]] || { echo 'Tessentry not installed' >&2; exit 1; }
[[ -f /etc/systemd/system/tessentry-worker.service && -f /etc/systemd/system/tessentry-web.service ]] || { echo 'Tessentry services missing' >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SRC/tessentry/core.py" && -f "$SRC/tessentry/web.py" ]] || { echo 'Missing Tessentry source files' >&2; exit 1; }
BACKUP_DIR=/mutable/tessentry/upgrade-backups
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
BACKUP="$BACKUP_DIR/pre-update-$STAMP.tar.gz"
STATE_BACKUP="$BACKUP_DIR/state-$STAMP.tar.gz"
ROOT_RO=0; BOOT_RO=0; ROOT_CHANGED=0; BOOT_CHANGED=0; STOPPED=0; COMMITTED=0
[[ ",$(findmnt -no OPTIONS /)," == *,ro,* ]] && ROOT_RO=1
if mountpoint -q /boot/firmware; then
  [[ ",$(findmnt -no OPTIONS /boot/firmware)," == *,ro,* ]] && BOOT_RO=1
fi
cleanup() {
  local rc=$?
  trap - EXIT
  if (( ! COMMITTED && STOPPED )); then
    echo 'Update failed: restoring previous application...' >&2
    rm -rf /opt/tessentry/tessentry
    tar -xzf "$BACKUP" -C /opt/tessentry || rc=1
    systemctl restart tessentry-worker.service tessentry-web.service || rc=1
  fi
  if (( BOOT_CHANGED )); then mount -o remount,ro /boot/firmware || rc=1; fi
  if (( ROOT_CHANGED )); then mount -o remount,ro / || rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
# Syntax-check all Python files without generating __pycache__ on the read-only system.
python3 - "$SRC/tessentry" <<'PY'
import pathlib,sys
for p in pathlib.Path(sys.argv[1]).rglob('*.py'):
    compile(p.read_bytes(),str(p),'exec')
print('Python syntax validation passed')
PY
# Back up the application and persistent settings/database, but never replace the latter.
tar -czf "$BACKUP" -C /opt/tessentry tessentry
if [[ -d /mutable/tessentry ]]; then
  tar -czf "$STATE_BACKUP" -C /mutable tessentry --exclude='tessentry/upgrade-backups' --exclude='tessentry/*.mp4'
  chmod 600 "$STATE_BACKUP"
fi
if (( ROOT_RO )); then mount -o remount,rw /; ROOT_CHANGED=1; fi
if (( BOOT_RO )); then mount -o remount,rw /boot/firmware; BOOT_CHANGED=1; fi
systemctl stop tessentry-worker.service tessentry-web.service
STOPPED=1
STAGE="$(mktemp -d /opt/tessentry/.update.XXXXXXXX)"
cp -a "$SRC/tessentry/." "$STAGE/"
chown -R root:root "$STAGE"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
mv /opt/tessentry/tessentry "/opt/tessentry/.previous-$STAMP"
mv "$STAGE" /opt/tessentry/tessentry
systemctl restart tessentry-worker.service tessentry-web.service
sleep 2
systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service
COMMITTED=1
rm -rf "/opt/tessentry/.previous-$STAMP"
echo "Tessentry updated successfully. Code backup: $BACKUP"
echo "Persistent data backup: $STATE_BACKUP"
