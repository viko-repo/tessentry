
#!/usr/bin/env bash
set -Eeuo pipefail

# Tessentry installer for Sentry-USB-Rusty.
# Does not modify archiveloop or TeslaCam recordings.

[[ $EUID -eq 0 ]] || {
  echo "Run: sudo bash install.sh"
  exit 1
}

SRC="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SRC/tessentry/core.py" ]] || {
  echo "Run from the extracted Tessentry project directory"
  exit 1
}

command -v python3 >/dev/null || {
  echo "ERROR: Python 3 is required"
  exit 1
}

command -v findmnt >/dev/null || {
  echo "ERROR: findmnt is required"
  exit 1
}

mountpoint -q /mutable || {
  echo "ERROR: /mutable is not mounted"
  exit 1
}

[[ -w /mutable ]] || {
  echo "ERROR: /mutable is not writable"
  exit 1
}

command -v tailscale >/dev/null || {
  echo "ERROR: Tailscale is required"
  exit 1
}

TAILSCALE_IP="$(tailscale ip -4 | head -n 1)"

[[ "$TAILSCALE_IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: No Tailscale IPv4 address"
  exit 1
}

INITIAL_ROOT_OPTS="$(findmnt -no OPTIONS /)"
INITIAL_BOOT_OPTS="$(findmnt -no OPTIONS /boot/firmware)"

ROOT_WAS_RO=0
BOOT_WAS_RO=0

[[ ",$INITIAL_ROOT_OPTS," == *,ro,* ]] && ROOT_WAS_RO=1
[[ ",$INITIAL_BOOT_OPTS," == *,ro,* ]] && BOOT_WAS_RO=1

cleanup() {
  local rc=$?
  trap - EXIT

  sync

  if (( BOOT_WAS_RO )); then
    if ! mount -o remount,ro /boot/firmware; then
      echo "CRITICAL: Failed to restore /boot/firmware to RO" >&2
      rc=1
    fi
  fi

  if (( ROOT_WAS_RO )); then
    if ! mount -o remount,ro /; then
      echo "CRITICAL: Failed to restore / to RO" >&2
      rc=1
    fi
  fi

  exit "$rc"
}

trap cleanup EXIT

echo "Preparing SentryUSB filesystem..."

if (( ROOT_WAS_RO )); then
  if [[ -x /root/bin/remountfs_rw ]]; then
    /root/bin/remountfs_rw
  else
    mount -o remount,rw /
  fi
fi

echo "Creating Tessentry system user..."

if ! id tessentry >/dev/null 2>&1; then
  useradd --system \
    --home-dir /mutable/tessentry \
    --shell /usr/sbin/nologin \
    tessentry
fi

install -d -m 750 -o tessentry -g tessentry /mutable/tessentry
install -d -m 755 /opt/tessentry

echo "Installing Tessentry application..."

cp -a "$SRC/tessentry" /opt/tessentry/

chown -R root:root /opt/tessentry
find /opt/tessentry -type d -exec chmod 755 {} +
find /opt/tessentry -type f -exec chmod 644 {} +

if [[ ! -f /mutable/tessentry/password.hash ]]; then
  echo "Generating Tessentry admin password..."

  PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"

  TESSENTRY_PASS="$PASSWORD" python3 - <<'PYI'
import os
import sys

sys.path.insert(0, "/opt/tessentry")
from tessentry.web import hash_password

with open("/mutable/tessentry/password.hash", "w") as f:
    f.write(hash_password(os.environ["TESSENTRY_PASS"]) + "\n")
PYI

  chmod 600 /mutable/tessentry/password.hash

  echo
  echo "=============================================="
  echo "TESSENTRY ADMIN PASSWORD"
  echo "$PASSWORD"
  echo "SAVE THIS PASSWORD SECURELY"
  echo "=============================================="
  echo
fi

chown -R tessentry:tessentry /mutable/tessentry
chmod 750 /mutable/tessentry

echo "Installing Tessentry worker service..."

cat >/etc/systemd/system/tessentry-worker.service <<'UNIT'
[Unit]
Description=Tessentry event monitor
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

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

echo "Installing Tessentry web service..."

cat >/etc/systemd/system/tessentry-web.service <<UNIT
[Unit]
Description=Tessentry management UI
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
User=tessentry
Group=tessentry
Environment=PYTHONPATH=/opt/tessentry
Environment=TESSENTRY_DATA=/mutable/tessentry
Environment=TESSENTRY_BIND=${TAILSCALE_IP}
Environment=TESSENTRY_PORT=8788
ExecStartPre=/bin/sh -c 'until /usr/bin/ip -4 addr show | /bin/grep -Fq "${TAILSCALE_IP}/"; do /bin/sleep 2; done'
ExecStart=/usr/bin/python3 -m tessentry web
TimeoutStartSec=120
Restart=always
RestartSec=10
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/mutable/tessentry
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

echo "Enabling Tessentry services..."

systemctl daemon-reload
systemctl enable tessentry-worker.service tessentry-web.service

echo
echo "=============================================="
echo "TESSENTRY INSTALLATION COMPLETED"
echo "=============================================="
printf 'Management UI: http://%s:8788/tessentry/\n' "$TAILSCALE_IP"
echo "Monitoring remains OFF until configured."
echo "Services are enabled for automatic startup."
echo "A controlled reboot is recommended."
echo "Do not expose port 8788 to the public Internet."
echo "=============================================="

