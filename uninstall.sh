#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo'; exit 1; }
# Uninstall does not delete /mutable/tessentry data.
ROOT_RO=0
[[ ",$(findmnt -no OPTIONS /)," == *,ro,* ]] && ROOT_RO=1
cleanup() {
  local rc=$?
  trap - EXIT
  if (( ROOT_RO )); then
    if ! mount -o remount,ro /; then
      echo "CRITICAL: Failed to restore root filesystem to RO" >&2
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
if ((ROOT_RO)); then mount -o remount,rw /; fi
systemctl disable --now tessentry-worker.service tessentry-web.service || true
rm -f /etc/systemd/system/tessentry-worker.service /etc/systemd/system/tessentry-web.service
systemctl daemon-reload
rm -rf /opt/tessentry
echo 'Removed services and code. Data retained at /mutable/tessentry'
