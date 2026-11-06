# Tessentry 🚗

**Tesla Sentry events → WhatsApp notifications, powered by Sentry-USB-Rusty, Tailscale and OpenWA.**

Tessentry is a lightweight companion service for a Raspberry Pi running [Sentry-USB-Rusty](https://github.com/Sentry-Six/Sentry-USB-Rusty). It watches configured TeslaCam `SentryClips` and `SavedClips` event folders and sends event information, a short `event.mp4` clip, and an optional native WhatsApp location message through OpenWA.

> **Start here: install Sentry-USB-Rusty first.** Tessentry is an add-on, not a replacement for the Tesla USB recorder or archive system. If Sentry-USB-Rusty is already installed and working, **do not reinstall it**.

## Installation roadmap

| Step | Component | Purpose |
| --- | --- | --- |
| **1** | **[Sentry-USB-Rusty](https://github.com/Sentry-Six/Sentry-USB-Rusty)** | Tesla USB recording, event storage and archiving — **required first** |
| 2 | [Tailscale](https://tailscale.com/) | Private connectivity between the Raspberry Pi and OpenWA |
| 3 | OpenWA / compatible WhatsApp API | Send WhatsApp notifications and video |
| 4 | **Tessentry** | Monitor new Sentry events and provide a configuration UI |

### Step 1 — Install Sentry-USB-Rusty (required)

Follow the **[official Sentry-USB-Rusty installation instructions](https://github.com/Sentry-Six/Sentry-USB-Rusty#install)**. For a supported Raspberry Pi, the upstream project provides a Raspberry Pi Imager manifest and a guided initial setup at `http://sentryusb.local`.

1. Install and configure Sentry-USB-Rusty according to its official guide.
2. Confirm the Pi is working with your Tesla and that recordings/events are being archived.
3. Confirm the locations of the `SentryClips` and `SavedClips` folders on **your** installation.
4. Keep Sentry-USB-Rusty running; Tessentry does not replace or reconfigure its archiving service.

**Important:** The upstream project notes that Tesla dashcam encryption can prevent Sentry USB from reading recordings. Review its current compatibility guidance before troubleshooting missing events.

### Step 2 — Set up Tailscale

Install and authenticate Tailscale on the Raspberry Pi and on the host running OpenWA. Verify that the Pi can reach the OpenWA server across your tailnet. Tessentry's installer expects Tailscale to be installed and running and binds the web interface to the Pi's current Tailscale IPv4 address.

### Step 3 — Prepare OpenWA

Set up an OpenWA/compatible WhatsApp API server and verify that it can send a message to a **test** chat or group. Have its server URL, session, API key (if required), and target chat/group ID ready. Never put these credentials in GitHub.

### Step 4 — Install Tessentry on the Raspberry Pi

Review `install.sh` before running it, especially on a read-only Sentry-USB-Rusty system:

```bash
git clone https://github.com/viko-repo/tessentry.git
cd tessentry
sudo bash install.sh
```

The installer checks that `/mutable` is writable, temporarily makes the root filesystem writable when needed, installs FFmpeg if required, installs Tessentry and its systemd services, and attempts to restore the original read-only state. It prints a generated administrator password on first installation; **save it securely**. Existing configuration and password are retained on subsequent installations.

> **Installation status:** A fresh install directly from this GitHub repository has not yet been independently validated. Use a backup and review the installer before deployment.

### Step 5 — Configure and enable monitoring

Open the web interface from a device on your tailnet:

```text
http://<PI-TAILSCALE-IP>:8788/tessentry/
```

Sign in with the installation password, then configure the OpenWA server URL, session, API key, target chat/group ID and the TeslaCam event folders. Confirm the paths match your installation. Test delivery to a non-production WhatsApp destination before enabling monitoring.

**Monitoring is disabled by default on a new installation.** Enabling it is an explicit configuration choice. Tessentry keeps an initial baseline to avoid sending old archived events as new alerts.

## Features

- Detects new events in configured `SentryClips` and `SavedClips` folders.
- Reads `event.json` when present for time, location, reason and camera details.
- Sends event details and an H.264-compatible `event.mp4` through the tested OpenWA integration.
- Can send a native WhatsApp location message separately from the video.
- Password-protected web UI for settings and status.
- SQLite-backed event tracking to avoid duplicate sends.
- Keeps Tessentry configuration and history under `/mutable/tessentry`.
- Does not intentionally modify TeslaCam recordings, Sentry-USB-Rusty `archiveloop`, or snapshots.

## Screenshots

Screenshots of the login, status, settings and WhatsApp notification screens will be added here **after privacy redaction**. Public examples will hide real locations, Tailscale IP addresses, credentials, group identifiers and video frames. Illustrations are not a substitute for screenshots of the actual running UI.

## Security and limitations

- **Never publish** `/mutable/tessentry/config.json`, `password.hash`, SQLite databases, API keys, private IP addresses, or TeslaCam recordings.
- The web UI currently uses **plain HTTP**. Access it only through a trusted network/Tailscale; do **not** expose port `8788` directly to the public Internet. Prefer an encrypted reverse proxy when appropriate.
- The installer binds to the current Tailscale IPv4 address. If that address changes, the binding must be updated.
- Event eligibility uses the presence and age of `event.mp4`; this does **not** guarantee archiving has fully finished.
- Missing `event.json` is permitted when `event.mp4` exists.
- Failed or interrupted deliveries may require manual review; automatic replay is intentionally restricted to avoid duplicates.
- The UI's OpenWA reachability indication is not a complete authenticated API health check. Check worker status with `systemctl`.
- This is an independent companion project, not affiliated with Tesla or the Sentry-USB-Rusty maintainers.

## Diagnostics

```bash
systemctl status tessentry-worker tessentry-web
journalctl -u tessentry-worker -n 50 --no-pager
tailscale status
```

## Uninstall

From the checked-out project directory:

```bash
sudo bash uninstall.sh
```

Uninstalling the services preserves `/mutable/tessentry` and its configuration/history. Remove that data separately **only** if you deliberately want to erase it.

## Development and tests

Tessentry uses Python 3.11+ and the standard library for its Python code. Run the included tests with:

```bash
python3 -m unittest discover -s tests -v
```

## Validation status

| Capability | Status |
| --- | --- |
| Raspberry Pi 4 / Debian 13 ARM64 development environment | Tested |
| OpenWA connectivity over Tailscale | Tested |
| Hebrew WhatsApp text notification | Tested manually |
| H.264 video delivery | Tested manually |
| Native WhatsApp location message | Tested manually |
| SQLite deduplication and initial baseline | Tested |
| Automatic monitoring on development Pi | Enabled |
| Fully unattended delivery from a newly archived real Tesla event | **Awaiting real-world validation** |
| Fresh installation from GitHub on a new device | **Not yet independently validated** |

## Credits

Tessentry builds on the recording and archiving functionality of **[Sentry-USB-Rusty by Sentry-Six](https://github.com/Sentry-Six/Sentry-USB-Rusty)**. Please follow and support the upstream project. Sentry-USB-Rusty has its own license and installation requirements; Tessentry's repository contains its own MIT license.

**Tessentry license:** MIT — see [LICENSE](LICENSE).
