# Tessentry 🚗

**Tesla Sentry events → WhatsApp (OpenWA), Telegram, or both — powered by Sentry-USB-Rusty and Tailscale.**

Tessentry is a lightweight companion service for a Raspberry Pi running [Sentry-USB-Rusty](https://github.com/Sentry-Six/Sentry-USB-Rusty). It watches configured TeslaCam `SentryClips` and `SavedClips` event folders and sends event details and a short `event.mp4` clip to WhatsApp (via OpenWA), Telegram, or both. WhatsApp can receive a separate native location message; Telegram includes a clickable Google Maps link in the video caption (or text message when video is disabled), when valid coordinates are available.

> [!IMPORTANT]
> **Notifications are not instantaneous.** Tessentry v1.3.0 configures a **300-second (5-minute) snapshot interval** for `sentryusb-archive.service` when needed, or preserves an existing effective 300-second setting. The actual delay can exceed five minutes because snapshot creation, archiving, worker scanning, processing and network delivery take additional time. In one live test on November 9, 2026, a 22:29 event was delivered to WhatsApp and Telegram around 22:32. This is an example, **not a guaranteed delivery time**. If the five-minute override is not active, Sentry-USB-Rusty's original 3,480-second (~58-minute) interval may still apply. Tessentry does not edit the upstream `archiveloop` script.

> **Start here: install Sentry-USB-Rusty first.** Tessentry is an add-on, not a replacement for the Tesla USB recorder or archive system. If Sentry-USB-Rusty is already installed and working, **do not reinstall it**.

## Installation roadmap

| Step | Component | Purpose |
| --- | --- | --- |
| **1** | **[Sentry-USB-Rusty](https://github.com/Sentry-Six/Sentry-USB-Rusty)** | Tesla USB recording, event storage and archiving — **required first** |
| 2 | [Tailscale](https://tailscale.com/) | Private connectivity to the Raspberry Pi and, when used, the OpenWA server |
| 3 | OpenWA and/or a Telegram bot | Configure the notification destination(s) you intend to use |
| 4 | **Tessentry** | Monitor new Sentry events and provide a configuration UI |

### Step 1 — Install Sentry-USB-Rusty (required)

Follow the **[official Sentry-USB-Rusty installation instructions](https://github.com/Sentry-Six/Sentry-USB-Rusty#install)**. For a supported Raspberry Pi, the upstream project provides a Raspberry Pi Imager manifest and a guided initial setup at `http://sentryusb.local`.

1. Install and configure Sentry-USB-Rusty according to its official guide.
2. Confirm the Pi is working with your Tesla and that recordings/events are being archived.
3. Confirm the locations of the `SentryClips` and `SavedClips` folders on **your** installation.
4. Keep Sentry-USB-Rusty running. Tessentry does not replace its archiving service, but v1.3.0 can set its snapshot interval through a systemd drop-in.

**Important:** The upstream project notes that Tesla dashcam encryption can prevent Sentry USB from reading recordings. Review its current compatibility guidance before troubleshooting missing events.

### Step 2 — Set up Tailscale

Install and authenticate Tailscale on the Raspberry Pi and on the host running OpenWA. Verify that the Pi can reach the OpenWA server across your tailnet. Tessentry's installer expects Tailscale to be installed and running and binds the web interface to the Pi's current Tailscale IPv4 address.

### Step 3 — Prepare notification providers

**WhatsApp (optional):** Set up an OpenWA/compatible WhatsApp API server and verify that it can send a message to a **test** chat or group. Have its server URL, session, API key (if required), and target chat/group ID ready.

**Telegram (optional):** Create a bot with [@BotFather](https://t.me/BotFather), start a conversation with the bot or add it to the intended group/channel, and obtain the destination Chat ID. The Raspberry Pi must be able to reach the Telegram Bot API over HTTPS.

You can configure WhatsApp, Telegram, or both. Never put credentials or chat IDs in GitHub.

### Step 4 — Install Tessentry on the Raspberry Pi

Review `install.sh` before running it, especially on a read-only Sentry-USB-Rusty system:

```bash
git clone https://github.com/viko-repo/tessentry.git
cd tessentry
sudo bash install.sh
```

The installer checks that `/mutable` is writable, temporarily makes the root filesystem writable when needed, installs FFmpeg if required, installs Tessentry and its systemd services, configures the archive snapshot interval if needed, and attempts to restore the original read-only state. It prints a generated administrator password on first installation; **save it securely**. Existing configuration and password are retained on subsequent installations.

> **Installation status:** The v1.3.0 fresh installer and failure rollback paths have not yet been independently validated on a separate Pi. Use a backup and review the installer before deployment.

### Step 5 — Configure and enable monitoring

Open the web interface from a device on your tailnet:

```text
http://<PI-TAILSCALE-IP>:8788/tessentry/
```

Sign in with the installation password, select **WhatsApp (OpenWA)**, **Telegram Bot**, or **WhatsApp + Telegram**, and configure the credentials and destination for each selected provider. Set the TeslaCam event folders and confirm that the paths match your installation. Test delivery to non-production destinations before enabling monitoring.

**Monitoring is disabled by default on a new installation.** Enabling it is an explicit configuration choice. Tessentry keeps an initial baseline to avoid sending old archived events as new alerts.

## Features

- Detects new events in configured `SentryClips` and `SavedClips` folders.
- Reads `event.json` when present for time, location, reason and camera details.
- Sends event details and an H.264-compatible `event.mp4` to WhatsApp through OpenWA, Telegram, or both.
- WhatsApp can receive a separate native location message after the video.
- Telegram embeds a clickable Google Maps link in the video caption (or text message if video is disabled), without sending a second location message.
- English and Hebrew notifications use the existing `tessentry/locales/en.json` and `he.json` translations, including the map-link label.
- Tracks delivery separately for each selected provider.
- Password-protected web UI for settings and status.
- SQLite-backed event tracking to avoid duplicate sends.
- Keeps Tessentry configuration and history under `/mutable/tessentry`.
- Does not intentionally modify TeslaCam recordings or Sentry-USB-Rusty's `archiveloop` source. Version 1.3.0 can change the archive service's snapshot **interval** using a systemd drop-in.

## Setup walkthrough — real screenshots

These are screenshots of the actual Tessentry interface. Follow the installation roadmap above before using the web UI. The screenshots show different stages of setup, **not** a single live status report.

### 1. First sign-in

On first installation, the installer prints a generated administrator password in the SSH terminal. Save it securely, open the Tessentry web interface, and enter the password.

![Tessentry initial password sign-in screen](docs/images/01-initial-sign-in.jpg)

### 2. Successful sign-in

After entering the correct password, Tessentry confirms the session. Click **Open status** to check the initial state.

![Tessentry successful sign-in confirmation](docs/images/02-successful-sign-in.jpg)

### 3. Check the initial status

Before configuration, **Monitoring: disabled** is expected. The current Status page also reports the selected notification provider and whether OpenWA and Telegram are configured. Check that the watched Sentry event folders and Tailscale are available.

![Tessentry initial status before OpenWA configuration](docs/images/03-initial-system-status.jpeg)

### 4. Enter notification provider and event settings

Open **Settings**, select the notification provider (**WhatsApp**, **Telegram**, or **both**), and enter your own values:

- **OpenWA base URL (when using WhatsApp):** Your OpenWA server address and port, preferably reachable over Tailscale.
- **OpenWA session:** The session identifier configured on your OpenWA server.
- **WhatsApp chat/group ID:** The destination for notifications.
- **OpenWA API key:** The key required by your server, if applicable. When editing an existing configuration, leaving this blank retains the current key.
- **Telegram Bot Token (when using Telegram):** The token issued by BotFather. Leaving this blank during an edit retains the configured token.
- **Telegram Chat ID:** The target numeric chat ID or supported public channel username.
- **Event folders:** The actual `SentryClips` and `SavedClips` archive paths on your Sentry-USB-Rusty installation.
- **Notification options:** Language, event details, video delivery and monitoring.
- **Timing:** Minimum event-file age and scan interval.

Click **Save settings**. Verify connectivity and test message delivery before enabling monitoring. The screenshot shows a configuration example with connection fields cleared or redacted; **do not copy its values**.

![Tessentry settings page with sensitive connection fields removed](docs/images/04-settings-configuration.jpg)

### 5. Verify the configured status

Return to **Status** after saving. When monitoring has been enabled, the page should report **Monitoring: enabled**, the selected notification provider, configuration status for OpenWA and Telegram, available event folders and Tailscale connectivity. Only the selected provider(s) must be configured.

**Important:** **OpenWA: TCP reachable (API not verified)** only confirms that the network port responds. It does not prove authenticated API access or successful WhatsApp delivery. Check `tessentry-worker` separately if needed.

![Tessentry configured status with monitoring enabled](docs/images/05-configured-system-status.jpg)

### 6. Real notification — manual delivery tests

The screenshot shows a real WhatsApp notification delivered through OpenWA during a manual end-to-end test. It contains a short `event.mp4` clip and event details (date, time, reason and camera), followed by a separate native WhatsApp location card. The video and map are obscured for privacy.

A later manual dual-provider test succeeded for both WhatsApp and Telegram. In Telegram, the event is delivered as a single video message with event details and a localized, clickable Google Maps link in its caption; no separate Telegram map message is sent. **Automatic delivery of a newly exposed real Tesla Sentry event to both WhatsApp and Telegram was observed on November 9, 2026.** A 22:29 event produced notifications around 22:32. Delivery times vary.

![Actual Tessentry WhatsApp notification with video and map obscured](docs/images/06-real-whatsapp-notification.jpg)

## Security and limitations

- **Never publish** `/mutable/tessentry/config.json`, `password.hash`, SQLite databases, API keys, private IP addresses, or TeslaCam recordings.
- The web UI currently uses **plain HTTP**. Access it only through a trusted network/Tailscale; do **not** expose port `8788` directly to the public Internet. Prefer an encrypted reverse proxy when appropriate.
- The installer binds to the current Tailscale IPv4 address. If that address changes, the binding must be updated.
- Event eligibility uses the presence and age of `event.mp4`; this does **not** guarantee archiving has fully finished.
- **Snapshot access:** The `tessentry-worker` systemd service requires `PrivateTmp=false` so it can follow Sentry-USB-Rusty snapshot-backed event paths through `/tmp/snapshots`. Keep `PrivateTmp=true` for the separate web service. The updated `install.sh` sets this for new installs, and `update.sh` adds a worker systemd drop-in for existing installations. The web service retains `PrivateTmp=true`.
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
| Telegram video with localized clickable map link (no separate map message) | Tested manually |
| Manual delivery to WhatsApp and Telegram in one test | Tested manually |
| SQLite deduplication and initial baseline | Tested |
| Automatic monitoring on development Pi | Enabled |
| Fully unattended WhatsApp delivery from a newly exposed real Tesla Sentry event | **Validated November 8 and observed again November 9, 2026** |
| Fully unattended Telegram delivery from a newly exposed real Tesla Sentry event | **Observed November 9, 2026** |
| Fresh installation from GitHub on a new device | **Not yet independently validated** |

## Credits

Tessentry builds on the recording and archiving functionality of **[Sentry-USB-Rusty by Sentry-Six](https://github.com/Sentry-Six/Sentry-USB-Rusty)**. Please follow and support the upstream project. Sentry-USB-Rusty has its own license and installation requirements; Tessentry's repository contains its own MIT license.

**Tessentry license:** MIT — see [LICENSE](LICENSE).

## Telegram notifications (optional)

Tessentry supports **WhatsApp (OpenWA)**, **Telegram**, or **both**. Existing installations default to WhatsApp, and existing `config.json` and event history are retained during an upgrade.

1. Create a Telegram bot using [@BotFather](https://t.me/BotFather), and keep its token private.
2. Start a chat with your bot, or add it to a group/channel with permission to post. Obtain the destination's numeric **Chat ID** (or a public `@channelusername` where applicable).
3. Open **Tessentry → Settings**, select **Telegram Bot** or **WhatsApp + Telegram**, and enter the **Bot Token** and **Chat ID**. The token is stored locally and is not displayed again.
4. Save settings and check **Status**. Enable monitoring only when all selected providers are configured.

Each Telegram event is sent as a video with event details (or as text if video is disabled). When valid coordinates are available, the message includes a clickable Google Maps link with a localized label from `tessentry/locales/en.json` or `he.json`; **Telegram does not send a separate native location message**. WhatsApp retains its separate native location message. Telegram Bot API uploads are limited to **50 MB** for this integration; larger videos are held for review rather than silently dropped. The current implementation uses the public Telegram Bot API over HTTPS, so the Raspberry Pi must have internet access.

### Upgrading an existing installation

Keep a separate copy of `/mutable/tessentry/config.json`, `/mutable/tessentry/events.sqlite` (including its SQLite WAL files if present), and `/mutable/tessentry/password.hash` before upgrading. On the Raspberry Pi, extract the release and run `sudo bash install.sh`. The installer keeps existing settings, credentials and history, backs up the previous installed application code under `/mutable/tessentry/upgrade-backups`, and restarts the worker and web services. **Do not remove `/mutable/tessentry` or reset the baseline.**

Delivery is tracked per provider. A successful WhatsApp notification will not be repeated when Telegram fails during the same event. Ambiguous network failures are placed in **review** and are not automatically retried, to prevent duplicates. Historical events already marked **sent** are never replayed merely because a new provider is enabled.

**Validation:** Offline automated tests cover Telegram payloads, provider selection, legacy configuration, location handling and dual-provider progress. Manual live delivery of a test event to both Telegram and WhatsApp has succeeded on the target Raspberry Pi. A fresh GitHub installation still requires independent validation. Fully unattended delivery of a real Sentry event to both WhatsApp and Telegram was observed on November 9, 2026.

## Updating an existing installation

Download the latest release ZIP from this repository, extract it, and run `sudo bash update.sh` from the extracted project directory on your Raspberry Pi. The updater validates Python syntax, backs up existing code and persistent state under `/mutable/tessentry/upgrade-backups/`, installs the new code, and checks both systemd services. It preserves `/mutable/tessentry/config.json`, the admin password and the event database. If a service fails to start, the previous application code is restored. The updater restores the original read-only filesystem mount state. **This script updates a locally downloaded project; `update-from-github.sh` provides the network-based update path described below.**

### Snapshot interval and upgrade behavior (v1.3.0)

The installer and updater target `sentryusb-archive.service`, whose `ExecStart` should run the Sentry-USB-Rusty `archiveloop`. They inspect the effective systemd environment and preserve an existing `SNAPSHOT_INTERVAL=300` setting. Otherwise, they create `/etc/systemd/system/sentryusb-archive.service.d/50-tessentry-snapshot-interval.conf`. When they add that override, they restart the archive service if it is active so the new interval takes effect. This restart can temporarily interrupt archiving; schedule upgrades accordingly. They do **not** modify `/root/bin/archiveloop`.

Check the effective setting with:

```bash
systemctl show sentryusb-archive.service -p Environment -p DropInPaths
```

Expected environment: `SNAPSHOT_INTERVAL=300`. Confirm actual snapshot creation and notification delivery separately; this systemd output alone does not prove the archive loop uses the setting.

### One-command GitHub update

After publishing `update.sh` and `update-from-github.sh` on the `main` branch, existing installations can fetch and install the current main branch with:

```bash
curl -fsSL https://raw.githubusercontent.com/viko-repo/tessentry/main/update-from-github.sh | sudo bash
```

**Security:** This executes code from the repository's current `main` branch with root privileges. Only use it if you trust the repository and its maintainers. For reproducible deployments, download and inspect a tagged release instead. Keep a separate off-device backup of your `/mutable/tessentry/` data. This updater does not upgrade OS packages or FFmpeg. The bundled `update.sh` adds a worker systemd drop-in setting `PrivateTmp=no` and, if needed, an archive drop-in setting `SNAPSHOT_INTERVAL=300`. If the archive service already has an effective 300-second setting, the updater preserves it without restarting that service. The web service should retain `PrivateTmp=true`. A full fresh-install and failure-rollback test on a separate Pi is still recommended before production deployment.