#!/usr/bin/env bash
set -Eeuo pipefail
# Tessentry installer for Sentry-USB-Rusty; does not modify archiveloop.
[[ $EUID -eq 0 ]] || { echo 'Run: sudo bash install.sh'; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"
[[ -f "$SRC/tessentry/core.py" ]] || { echo 'Run from extracted project directory'; exit 1; }
command -v python3 >/dev/null || { echo 'Python 3 is required'; exit 1; }
mountpoint -q /mutable || { echo 'ERROR: /mutable is not mounted; refusing install'; exit 1; }
[[ -w /mutable ]] || { echo 'ERROR: /mutable not writable'; exit 1; }
INITIAL_ROOT_OPTS="$(findmnt -no OPTIONS /)"
INITIAL_BOOT_OPTS="$(findmnt -no OPTIONS /boot/firmware)"
ROOT_WAS_RO=0
[[ ",$INITIAL_ROOT_OPTS," == *,ro,* ]] && ROOT_WAS_RO=1
restore_ro() {
  if (( ROOT_WAS_RO )); then
    mount -o remount,ro / || echo 'WARNING: failed to restore read-only root; check manually' >&2
  fi
}
trap restore_ro EXIT
if (( ROOT_WAS_RO )); then
  # SentryUSB helper is preferred if present, but may also remount boot; restore below.
  if [[ -x /root/bin/remountfs_rw ]]; then /root/bin/remountfs_rw; else mount -o remount,rw /; fi
fi
# Do not change boot mount state unless helper did.
BOOT_WAS_RO=1
[[ ",$INITIAL_BOOT_OPTS," == *,rw,* ]] && BOOT_WAS_RO=0
cleanup() {
  if (( BOOT_WAS_RO )); then mount -o remount,ro /boot/firmware 2>/dev/null || true; fi
  restore_ro
}
trap cleanup EXIT
if ! id tessentry >/dev/null 2>&1; then useradd --system --home-dir /mutable/tessentry --shell /usr/sbin/nologin tessentry; fi
install -d -m 750 -o tessentry -g tessentry /mutable/tessentry
install -d -m 755 /opt/tessentry
cp -a "$SRC/tessentry" /opt/tessentry/
chown -R root:root /opt/tessentry
find /opt/tessentry -type d -exec chmod 755 {} +
find /opt/tessentry -type f -exec chmod 644 {} +
if [[ ! -f /mutable/tessentry/password.hash ]]; then
  PASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(18))')"
  TESSENTRY_PASS="$PASSWORD" python3 - <<'PYI'
import os,sys
sys.path.insert(0,'/opt/tessentry')
from tessentry.web import hash_password
with open('/mutable/tessentry/password.hash','w') as f:f.write(hash_password(os.environ['TESSENTRY_PASS'])+'\n')
PYI
  chmod 600 /mutable/tessentry/password.hash
  echo "IMPORTANT: Tessentry admin password (save securely): $PASSWORD"
fi
chown -R tessentry:tessentry /mutable/tessentry
chmod 750 /mutable/tessentry
cat >/etc/systemd/system/tessentry-worker.service <<'UNIT'
[Unit]
Description=Tessentry event monitor
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=tessentry
Group=tessentry
Environment=PYTHONPATH=/opt/tessentry
Environment=TESSENTRY_DATA=/mutable/tessentry
ExecStart=/usr/bin/python3 -m tessentry worker
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/mutable/tessentry
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
cat >/etc/systemd/system/tessentry-web.service <<'UNIT'
[Unit]
Description=Tessentry management UI
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=tessentry
Group=tessentry
Environment=PYTHONPATH=/opt/tessentry
Environment=TESSENTRY_DATA=/mutable/tessentry
Environment=TESSENTRY_BIND=0.0.0.0
Environment=TESSENTRY_PORT=8788
ExecStart=/usr/bin/python3 -m tessentry web
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/mutable/tessentry
PrivateTmp=true
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now tessentry-worker.service tessentry-web.service
printf '\nInstalled. Monitoring is OFF until configured. Open http://<PI-IP>:8788/tessentry/\n'
printf 'SECURITY: HTTP is not encrypted. Use trusted LAN or Tailscale only; do not port-forward 8788.\n'
