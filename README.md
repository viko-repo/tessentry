# Tessentry 🚗

**Tessentry v0.1.2 — early preview / not yet validated against your OpenWA deployment.**

Tessentry monitors TeslaCam `SentryClips` and `SavedClips` event folders on a Sentry-USB-Rusty Raspberry Pi and can send `event.mp4` plus `event.json` metadata to an OpenWA/WAHA-compatible WhatsApp API over Tailscale.

## Safety and limitations

- **Monitoring is disabled by default.** Configure and verify OpenWA's actual API before enabling.
- Never store personal API keys or WhatsApp IDs in the Git repository. Local configuration lives at `/mutable/tessentry/config.json` (mode 0600).
- Does **not** modify SentryUSB `archiveloop`, snapshots, recordings or TeslaCam files.
- Watches folders you configure. The default `/mutable/TeslaCam/...` paths are **not proven to be the final archived paths**. Confirm them using a real archived event.
- An event is eligible only after `event.mp4` exists and has an old enough modification time. This is a heuristic, **not** an archive completion guarantee.
- Only folders containing `event.mp4` are sent. Missing `event.json` is allowed.
- Text/video completion is recorded independently. Failed or interrupted deliveries are held for manual review (no unsafe automatic replay). The UI does not yet offer manual retry controls.
- The multipart `send-file` and JSON `send-text` routes are **assumptions** based on common OpenWA conventions, not validated against your server. Adapt `tessentry/core.py:send` after checking your server's API.
- Password-protected web UI is plain HTTP. Access it **only from a trusted LAN or Tailscale**, preferably through an encrypted proxy. Do not expose TCP 8788 to the Internet. The installer binds the UI **only to the current Tailscale IPv4 address**; no firewall rules are changed. If the Tailscale IP changes, reinstall to refresh the binding.
- The UI shows Tailscale IP availability and an OpenWA TCP reachability probe, not an authenticated API health check. Worker health must still be checked with systemctl.

## Install from a Git checkout

On the Pi, **after reviewing the script**:

```bash
git clone https://github.com/viko-repo/tessentry.git
cd tessentry
sudo bash install.sh
```

This is the intended one-command installer **after checkout**; a future release may offer a verified single-line bootstrap. Do not pipe a remote script straight into root shell without review.

The installer checks that `/mutable` is mounted and writable, temporarily remounts `/` writable if needed (preferring `/root/bin/remountfs_rw`), installs Python-only code and systemd units, and restores read-only root on exit. It does not install Python packages. The installer displays a generated admin password **once**; save it securely. Subsequent runs retain the existing password and configuration.

Open `http://<PI-TAILSCALE-IP>:8788/tessentry/`, sign in, and configure OpenWA and event folders. Default monitoring: **off**. Service updates take effect at the next scan.

## OpenWA integration

Set OpenWA base URL, session, API key, and chat/group ID in Settings. By default, the OpenWA URL must use an IPv4 address in the Tailscale `100.64.0.0/10` range. You can explicitly allow a non-Tailscale URL for trusted LAN usage. Verify API headers, message endpoints, form-data field names and authentication against your running OpenWA server before enabling. **Do not test with a production WhatsApp group first.**

## Diagnostics

```bash
systemctl status tessentry-worker tessentry-web
journalctl -u tessentry-worker -n 50 --no-pager
tailscale status
```

## Remove

```bash
sudo bash uninstall.sh
```

Uninstall retains `/mutable/tessentry` (including credentials and history). Delete that directory manually only if you intend to erase all local data.

## Development

Standard library only, Python 3.11+. To run on a development machine:

```bash
export TESSENTRY_DATA=/tmp/tessentry-dev
python3 -m tessentry web
python3 -m tessentry worker
```

Create a `password.hash` in the data folder using `tessentry.web.hash_password(...)` before logging in.

## Planned improvements

- Validate real OpenWA routes and end-to-end video delivery.
- Verify final SentryUSB archive folder and reliable completion signals.
- Per-channel send state, safe retries, and manual requeue.
- Add HTTPS and authenticated OpenWA API health checks; validate Tailnet IP binding on network changes.
- Unit and integration tests with recorded fixtures.

License: MIT.

## v0.1.2 security notes

- Installer restores both root and boot RO states, reports cleanup failure and refuses installation without an active Tailscale IP.
- Web UI binds only to the Tailscale IP, not `0.0.0.0`. Traffic remains plain HTTP inside the tailnet.
- OpenWA routes are **not verified**: leave monitoring disabled until tested with a non-production destination.
- Event delivery records text and video separately and holds ambiguous failures for review.


## v0.1.2 installer fix

Fix systemd TESSENTRY_BIND interpolation and print the actual Tailscale URL. Installation on the target SentryUSB device and OpenWA media API remain unvalidated; do not enable monitoring until verified.
