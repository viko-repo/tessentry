
#!/usr/bin/env bash
set -Eeuo pipefail

# Tessentry v1.3.0 installer for Sentry-USB-Rusty.
# Does not modify archiveloop, TeslaCam recordings,
# or the original Sentry-USB-Rusty service files.

[[ $EUID -eq 0 ]] || {
  echo "Run: sudo bash install.sh"
  exit 1
}

SRC="$(cd "$(dirname "$0")" && pwd)"

[[ -f "$SRC/tessentry/core.py" ]] || {
  echo "ERROR: Run from the Tessentry project directory"
  exit 1
}

for cmd in python3 findmnt mountpoint systemctl tar; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: Required command missing: $cmd"
    exit 1
  }
done

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

# Validate application files before modifying the system.
echo "Validating Tessentry application..."

python3 - "$SRC" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / "tessentry"

for name in ("core.py", "web.py", "__main__.py", "__init__.py"):
    path = root / name
    compile(path.read_bytes(), str(path), "exec")

for lang in ("en", "he"):
    path = root / "locales" / f"{lang}.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"Invalid locale: {lang}")

print("Python and locale validation: OK")
PY

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
      echo "CRITICAL: Failed to restore boot filesystem to RO" >&2
      rc=1
    fi
  fi

  if (( ROOT_WAS_RO )); then
    if ! mount -o remount,ro /; then
      echo "CRITICAL: Failed to restore root filesystem to RO" >&2
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

# If boot was originally read-only, ensure it is writable
# during installation. The cleanup trap restores its state.
if (( BOOT_WAS_RO )); then
  CURRENT_BOOT_OPTS="$(findmnt -no OPTIONS /boot/firmware)"
  if [[ ",$CURRENT_BOOT_OPTS," == *,ro,* ]]; then
    mount -o remount,rw /boot/firmware
  fi
fi

echo "Installing FFmpeg dependencies..."

if ! command -v ffmpeg >/dev/null 2>&1 ||
   ! command -v ffprobe >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ffmpeg
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

# Preserve the previous application for manual rollback.
if [[ -d /opt/tessentry/tessentry ]]; then
  install -d -m 700 /mutable/tessentry/upgrade-backups

  BACKUP_FILE="/mutable/tessentry/upgrade-backups/tessentry-code-$(date +%Y%m%d-%H%M%S).tar.gz"

  tar -czf "$BACKUP_FILE" -C /opt/tessentry tessentry

  echo "Previous code backup: $BACKUP_FILE"
fi

# Replace application code without touching persistent data.
rm -rf /opt/tessentry/tessentry
cp -a "$SRC/tessentry" /opt/tessentry/

chown -R root:root /opt/tessentry/tessentry
find /opt/tessentry/tessentry -type d -exec chmod 755 {} +
find /opt/tessentry/tessentry -type f -exec chmod 644 {} +

# Preserve existing credentials.
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

# The worker needs access to /tmp/snapshots.
PrivateTmp=false

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

# Configure faster snapshots without duplicating
# an existing effective 300-second setting.
echo "Checking 5-minute snapshot interval..."

ARCHIVE_SERVICE="sentryusb-archive.service"
ARCHIVE_CHANGED=0

if systemctl cat "$ARCHIVE_SERVICE" >/dev/null 2>&1; then
  if systemctl show "$ARCHIVE_SERVICE" -p Environment --value |
      tr ' ' '\n' | grep -Fxq 'SNAPSHOT_INTERVAL=300'; then
    echo "Snapshot interval already configured: 300 seconds"
  else
    ARCHIVE_OVERRIDE_DIR="/etc/systemd/system/${ARCHIVE_SERVICE}.d"
    install -d -m 755 "$ARCHIVE_OVERRIDE_DIR"

    cat >"${ARCHIVE_OVERRIDE_DIR}/50-tessentry-snapshot-interval.conf" <<'UNIT'
[Service]
Environment="SNAPSHOT_INTERVAL=300"
UNIT

    chmod 644 "${ARCHIVE_OVERRIDE_DIR}/50-tessentry-snapshot-interval.conf"
    ARCHIVE_CHANGED=1

    echo "Snapshot interval configured: 300 seconds"
  fi
else
  echo "WARNING: sentryusb-archive.service not found."
  echo "Snapshot interval was not modified."
fi

echo "Enabling Tessentry services..."

echo 'Configuring web network readiness...'
WEB_OVERRIDE=/etc/systemd/system/tessentry-web.service.d/10-wait-tailscale.conf
install -d -m 755 "$(dirname "$WEB_OVERRIDE")"
cat >"$WEB_OVERRIDE" <<'UNIT'
[Service]
ExecStartPre=/bin/sh -c 'case "$$TESSENTRY_BIND" in 127.*|0.0.0.0) exit 0;; esac; i=0; until /usr/sbin/ip -o -4 addr show | /usr/bin/grep -Fq "inet $$TESSENTRY_BIND/"; do i=$$((i+1)); if [ "$$i" -ge 60 ]; then echo "Tessentry bind IP not ready after 60 seconds"; exit 1; fi; /usr/bin/sleep 1; done'
UNIT
chmod 644 "$WEB_OVERRIDE"

systemctl daemon-reload

systemctl enable tessentry-worker.service tessentry-web.service

systemctl restart tessentry-worker.service tessentry-web.service

systemctl is-active --quiet tessentry-worker.service
systemctl is-active --quiet tessentry-web.service

# Restart the archive only if its configuration changed.
# This avoids interrupting an already working archive.
if (( ARCHIVE_CHANGED )); then
  if systemctl is-active --quiet "$ARCHIVE_SERVICE"; then
    echo "Restarting snapshot archive service to apply interval..."
    systemctl restart "$ARCHIVE_SERVICE"
    systemctl is-active --quiet "$ARCHIVE_SERVICE"
  else
    echo "Archive service is not running; interval applies on next start."
  fi
fi

echo
echo "=============================================="
echo "TESSENTRY v1.3.0 INSTALLATION COMPLETED"
echo "=============================================="
printf 'Management UI: http://%s:8788/tessentry/\n' "$TAILSCALE_IP"
echo "Existing monitoring settings and data were preserved."
echo "Worker snapshot access: enabled."
echo "Snapshot interval: 300 seconds (when supported)."
echo "Services are enabled for automatic startup."
echo "A controlled reboot is recommended."
echo "Do not expose port 8788 to the public Internet."
echo "=============================================="
