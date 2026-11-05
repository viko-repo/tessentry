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
ROOT_WAS_RO=0; BOOT_WAS_RO=0
[[ ",$INITIAL_ROOT_OPTS," == *,ro,* ]] && ROOT_WAS_RO=1
[[ ",$INITIAL_BOOT_OPTS," == *,ro,* ]] && BOOT_WAS_RO=1
cleanup() {
  local rc=$?; trap - EXIT
  if (( BOOT_WAS_RO )); then
    if ! mount -o remount,ro /boot/firmware; then
      echo 'CRITICAL: boot filesystem could not be restored to read-only' >&2; rc=1
    fi
  fi
  if (( ROOT_WAS_RO )); then
    if ! mount -o remount,ro /; then
      echo 'CRITICAL: root filesystem could not be restored to read-only' >&2; rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
if (( ROOT_WAS_RO )); then
  if [[ -x /root/bin/remountfs_rw ]]; then /root/bin/remountfs_rw; else mount -o remount,rw /; fi
fi
# Fail closed: no world-accessible admin UI. Bind to the local Tailscale IPv4.
command -v tailscale >/dev/null || { echo 'Tailscale is required for the management UI' >&2; exit 1; }
TAILSCALE_IP="$(tailscale ip -4 | head -n1)"
[[ "$TAILSCALE_IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'No active Tailscale IPv4 address' >&2; exit 1; }
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
cat >/etc/systemd/system/tessentry-worker.service <<UNIT
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
cat >/etc/systemd/system/tessentry-web.service <<UNIT
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
Environment=TESSENTRY_BIND=${TAILSCALE_IP}
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
printf '\nInstalled. Monitoring is OFF until configured. Open http://%s:8788/tessentry/\n' "$TAILSCALE_IP"
printf 'SECURITY: UI listens only on the Tailscale IP; HTTP is not encrypted. Do not port-forward.\n'
