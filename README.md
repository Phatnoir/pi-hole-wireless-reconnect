# Pi-hole Wireless Reconnect + SMS Alert Script

A robust Bash script that monitors network connectivity on a Pi-hole device, automatically reconnects when the connection drops, and sends SMS alerts for status updates.

>This script is an independent project and is not associated with or supported by the Pi-hole team.

## Table of Contents
- [Quick Start](#quick-start)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
  - [Basic Configuration](#basic-configuration)
  - [Advanced Configuration](#advanced-configuration)
- [Usage](#usage)
- [Monitoring and Logs](#monitoring-and-logs)
- [Troubleshooting](#troubleshooting)
- [Uninstallation](#uninstallation)
- [License](#license)
- [Contributing](#contributing)

## Quick Start

<details>
<summary><strong>Click to expand Quick Start</strong></summary>

<pre><code>
# 1. Install dependencies
sudo apt update && sudo apt install -y postfix mailutils libc-bin ethtool wpasupplicant iw

# 👉 The script must run as root (no sudo inside — systemd handles this via User=root)

# 👉 If using Gmail as your mail relay, you'll also need to:
#    - Create an App Password: https://myaccount.google.com/apppasswords
#    - Configure Postfix with your Gmail SMTP credentials (see "Advanced Mail Configuration" below)

# 2. Get the script
wget -O reconnect_router.sh https://raw.githubusercontent.com/Phatnoir/pi-hole-wireless-reconnect/main/reconnect_router.sh
sudo mv reconnect_router.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/reconnect_router.sh

# 3. Configure your settings (required)
sudo nano /usr/local/bin/reconnect_router.sh
# Edit ROUTER_IP, INTERFACE, PHONE_NUMBER, and CARRIER_GATEWAY

# 4. Create service file
sudo tee /etc/systemd/system/reconnect_router.service > /dev/null << EOL
[Unit]
Description=Pi-hole Wireless Reconnect Script
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/bin/reconnect_router.sh
Restart=always
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
EOL

# 5. Enable and start the service
sudo systemctl enable reconnect_router.service
sudo systemctl start reconnect_router.service

# 6. Check status
sudo systemctl status reconnect_router.service
</code></pre>

</details>

## Features

<details>
<summary><strong>Click to expand feature list</strong></summary>

* **Automatic reconnection** — Detects connectivity loss and reattempts connection with intelligent retries
* **Graduated recovery ladder** — Escalates from soft `wpa_cli reconnect` → link bounce → `dhcpcd` restart
* **Internet-first connectivity check** — Tests upstream IPs (Cloudflare) before the router, so router ICMP blips don't trigger a restart
* **Failure threshold debounce** — Requires sustained failure for ~60 seconds before any recovery action
* **Exponential backoff** — Gradually increases delay during outages, capped at 10 minutes
* **SMS notifications** — Real-time alerts with queued delivery and message type prioritization
* **Heartbeat monitoring** — Tracks unexpected interruptions and logs downtime duration
* **Multiple log files** — Separate logs for events, downtime, and heartbeats with fallback to `/tmp`
* **System integration** — Runs at startup via `systemd` with graceful restart handling
* **Message filtering** — START, ALERT, TRYING, OK, and CRITICAL types reduce notification spam
* **Robust locking** — Prevents race conditions with PID-based locking and stale lock cleanup
* **Self-test** — Validates network interface, DHCP client, and dependencies on launch
* **Error handling** — Trap-based termination with environment cleanup
* **Log rotation** — Prevents disk bloat with built-in size checks and auto-rotation
* **Anti-spam safeguards** — Suppresses duplicate START messages on same-boot restarts using kernel boot ID; only alerts on true reboots
* **Concise SMS format** — Includes downtime and retry count while staying under SMS length limits
* **Wi-Fi power save management** — Disables `brcmfmac` power save after each link-up to reduce spurious ping drops
* **Dual network issue detection** — Differentiates router drop vs internet-only failures
* **dhcpcd integration** — Link bounce only; lets `dhcpcd` handle DHCP automatically without conflicts
* **Redundant DNS checks** — Uses multiple upstream IPs (Cloudflare) to verify internet access
</details>

## Prerequisites

The script requires the following dependencies:

1. **Postfix** (or another Mail Transfer Agent)
2. **mailutils** (provides the `mail` command used for SMS)
3. **iconv** (for proper character encoding in SMS messages)

## Installation

<details>
<summary><strong>1. Install Dependencies</strong></summary>

```bash
# Update package lists
sudo apt update

# Install postfix, mailutils and other dependencies
sudo apt install postfix mailutils libc-bin wpasupplicant iw
```
> **Note:** `iconv` is included in `libc-bin`, so installing `libc-bin` will provide `iconv`.
</details>

<details>
<summary><strong>2. Configure Postfix</strong></summary>

During installation:

* Select **"Internet Site"** when prompted
* For the system mail name, you'll be prompted to enter a fully qualified domain name (FQDN). If this is just for local use on your home network, entering `localhost.localdomain` or `raspberrypi.local` is sufficient.
</details>

<details>
<summary><strong>3. Install the Script</strong></summary>

```bash
# Copy the script to /usr/local/bin/
sudo cp reconnect_router.sh /usr/local/bin/

# Make it executable
sudo chmod +x /usr/local/bin/reconnect_router.sh
```
</details>

<details>
<summary><strong>4. Create a Systemd Service</strong></summary>

Create a new service file:

```bash
sudo nano /etc/systemd/system/reconnect_router.service
```

Add the following content:

```ini
[Unit]
Description=Pi-hole Wireless Reconnect Script
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sleep 10
ExecStart=/usr/local/bin/reconnect_router.sh
Restart=always
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
```

> **Note:** The service must run as `root` — the script uses `ip`, `iw`, `ethtool`, and `systemctl` directly without `sudo`. Running it as any other user will fail. The `Restart=always` + `RestartSec=30` pairing prevents excessive restart cycles.

Enable and start the service:

```bash
sudo systemctl enable reconnect_router.service
sudo systemctl start reconnect_router.service
```
</details>

## Configuration

### Basic Configuration

<details>
<summary><strong>Required Settings</strong></summary>

1. Edit the script with your preferred editor:
   ```bash
   sudo nano /usr/local/bin/reconnect_router.sh
   ```

2. Update the following variables:
   - `ROUTER_IP`: Your router's IP address (default is "192.168.1.1")
   - `INTERFACE`: Your network interface (default is "wlan0" for WiFi)
     - For Ethernet connections, use "eth0" (or "enp3s0" on newer systems)
     - To find your interface name, run: `ip addr show` or `ifconfig`
   - `PHONE_NUMBER`: Your phone number for SMS alerts
   - `CARRIER_GATEWAY`: Your cellular carrier's SMS gateway
     - Verizon: vtext.com
     - AT&T: txt.att.net
     - T-Mobile: tmomail.net

3. Save and close the file
</details>

<details>
<summary><strong>Optional Parameters</strong></summary>

- `RETRY_DELAY`: Time between reconnection attempts (default: 15s)
- `ROUTER_FAILURE_THRESHOLD`: Consecutive failures required before triggering recovery (default: 4, ~60s at 15s delay)
- `MAX_RETRIES`: Maximum reconnection attempts before giving up (default: 10)
- `HEARTBEAT_ENABLED`: Enable/disable heartbeat monitoring (default: true)
- `HEARTBEAT_INTERVAL`: Time between heartbeat checks (default: 3600s = 1 hour)
- `MISSED_HEARTBEATS_THRESHOLD`: Number of missed heartbeats before alerting (default: 3)
- `PING_COUNT`: Number of pings to send when checking connection (default: 2)
- `PING_TIMEOUT`: Timeout in seconds for ping operation (default: 3)
- `PING_SIZE`: Size of ping packet in bytes (default: 32)

- `DNS_CHECK_HOSTS`: Array of DNS servers to check for internet connectivity (default: Cloudflare DNS)
- `SMS_INTERNET_CHECK`: IP address to verify internet connectivity for SMS delivery (default: 8.8.8.8)
- `SMS_INTERNET_FAILURE_THRESHOLD`: Consecutive internet-only failures before sending an [ALERT] SMS (default: 10, ≈2.5 min at 15s retry delay)
</details>

### Advanced Configuration

<details>
<summary><strong>Startup Notification Management</strong></summary>

The script suppresses duplicate startup SMS notifications by comparing the kernel boot ID on each start:

```bash
BOOT_ID_FILE="/var/lib/reconnect_router_last_boot_id"
CURRENT_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
```

The boot ID is stored in `/var/lib/` (survives `/tmp` wipes) and changes only on a real reboot. If the stored ID matches the current one, the script was restarted by systemd after a failure and suppresses the SMS. If the IDs differ, the Pi-hole genuinely rebooted and the SMS fires. This correctly handles scheduled reboots (e.g. a 4am weekly reboot via cron) without requiring any time-window tuning.
</details>

<details>
<summary><strong>Heartbeat Monitoring</strong></summary>

The script includes a heartbeat system that:
- Silently monitors script execution in the background
- Detects script interruptions or system failures
- Calculates downtime during script interruptions
- Sends alerts ONLY when the script resumes after unexpected downtime

To configure heartbeat monitoring:

```bash
# Heartbeat Configuration
HEARTBEAT_ENABLED=true         # Set to false to disable heartbeat
HEARTBEAT_INTERVAL=3600        # Time between heartbeats in seconds (1 hour)
MISSED_HEARTBEATS_THRESHOLD=3  # Alert after this many missed heartbeats
```
</details>

<details>
<summary><strong>Enhanced Lock File Handling</strong></summary>

The script now includes improved lock file management:
- Detects and removes stale lock files from crashed script instances
- Stores PID in the lock file for better tracking
- Properly releases locks during script termination
- Verifies /tmp directory permissions

This prevents issues where a crashed script might leave behind a lock file that blocks future script runs.
</details>

<details>
<summary><strong>SMS Notifications</strong></summary>

The script implements a sophisticated message queuing system:
- Messages are queued when internet connectivity is unavailable
- When connection is restored, the script intelligently processes the queue
- START, ALERT, and CRITICAL messages are prioritized
- TRYING and HEARTBEAT messages may be skipped to reduce spam
- Recovery messages (OK) include downtime duration and attempt count

Example recovery message:
```
[OK] Pi-hole Online! Down: 2m30s. 3/10 attempts
```
</details>

<details>
<summary><strong>Internet Connectivity Handling</strong></summary>

The script checks upstream internet connectivity **first** on every cycle. If `1.1.1.1` or `1.0.0.1` responds, the connection is considered healthy regardless of whether the router answers ICMP — this prevents router ping blips from triggering unnecessary restarts.

If the upstream check fails, the script checks the router to distinguish between two failure types:
1. **Complete connection loss** — Cannot reach the router (Wi-Fi likely down; triggers graduated recovery)
2. **Internet-only failures** — Can reach the router but not the internet (ISP issue; script logs and waits)

For internet-only failures the script deliberately does **not** bounce `wlan0` — if the router is reachable, the Wi-Fi link is fine and a restart can't fix an upstream ISP issue. Instead, the failure counter increments each cycle and a single [ALERT] SMS fires when the threshold is crossed:

```bash
INTERNET_FAILURES=0
SMS_INTERNET_FAILURE_THRESHOLD=10  # ≈2.5 min at default 15s retry delay
```

The counter resets automatically when internet connectivity is restored.
</details>

<details>
<summary><strong>DNS Connectivity Checking</strong></summary>

The script uses multiple DNS servers to verify internet connectivity:

```bash
DNS_CHECK_HOSTS=("1.1.1.1" "1.0.0.1")  # Cloudflare IPv4 redundancy
SMS_INTERNET_CHECK="8.8.8.8"  # For SMS delivery checks
```

This redundancy helps prevent false positives when a single DNS server might be temporarily unavailable.
</details>

<details>
<summary><strong>Adaptive Retry with Exponential Backoff</strong></summary>

During extended network outages, the script uses exponential backoff to avoid excessive reconnection attempts:

```bash
# Calculate backoff delay (2^n)
backoff=$((RETRY_DELAY * (2 ** (consecutive_failures - 5))))

# Cap the backoff at 10 minutes (600 seconds)
if [ "$backoff" -gt 600 ]; then
    backoff=600
fi
```

This means:
- First 5 failures: Normal retry interval
- 6th failure: 2x normal delay
- 7th failure: 4x normal delay
- 8th failure: 8x normal delay
- 9th failure: 16x normal delay
- 10th+ failure: 40x normal delay (capped at 10 minutes)
</details>

<details>
<summary><strong>Advanced Mail Configuration (Optional)</strong></summary>

**Note:** For Gmail, you must use an [app password](https://myaccount.google.com/apppasswords), not your regular password.

If you want to use a relay service like Gmail to send your notifications:

1. Edit the Postfix configuration:
   ```bash
   sudo nano /etc/postfix/main.cf
   ```

2. Add the following lines:
   ```
   relayhost = [smtp.gmail.com]:587
   smtp_sasl_auth_enable = yes
   smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
   smtp_sasl_security_options = noanonymous
   smtp_use_tls = yes
   ```

3. Create a password file:
   ```bash
   sudo nano /etc/postfix/sasl_passwd
   ```

4. Add your credentials:
   ```
   [smtp.gmail.com]:587 your-email@gmail.com:your-password
   ```

5. Hash and secure the password file:
   ```bash
   sudo postmap /etc/postfix/sasl_passwd
   sudo chmod 600 /etc/postfix/sasl_passwd
   sudo systemctl restart postfix
   ```
</details>

<details>
<summary><strong>Enhanced Error Handling</strong></summary>

The script includes sophisticated error handling:

- **Diagnostic logging** — Tracks script termination reasons via journal analysis
- **Fallback log paths** — Automatically redirects logs to /tmp if standard paths are unavailable
- **Cross-platform compatibility** — Better detection of system-specific networking tools (dhclient vs dhcpcd)
- **Log path verification** — Creates log directories if they don't exist with appropriate permissions
- **Log rotation** — Automatically rotates log files when they reach 10MB in size

This makes the script more resilient in diverse environments and helps with troubleshooting.
</details>

## Usage

The script will run automatically at system startup. You can manually control it with:

```bash
# Start the service
sudo systemctl enable reconnect_router.service
sudo systemctl start reconnect_router.service

# Check status
sudo systemctl status reconnect_router.service
```

## Monitoring and Logs

<details>
<summary><strong>Viewing Logs</strong></summary>

Check the various logs to see the script's activity:

```bash
# View the main log
tail -f /var/log/reconnect_router.log

# View downtime events
tail -f /var/log/router_downtime.log

# View heartbeat activity
tail -f /var/log/router_heartbeat.log
```
</details>

<details>
<summary><strong>Recommended System-Level Log Rotation</strong></summary>

For the most effective log management, set up system-level log rotation:

```bash
sudo nano /etc/logrotate.d/reconnect_router
```

Add the following configuration:

```
/var/log/reconnect_router.log /var/log/router_downtime.log /var/log/router_heartbeat.log {
    rotate 4
    weekly
    compress
    size 2M
    missingok
    notifempty
    create 0644 root root
    delaycompress
}
```

This configuration will:
- Rotate logs when they reach 2MB in size
- Perform rotation weekly or when size threshold is reached, whichever comes first
- Keep 4 rotations of history (approximately one month of logs)
- Compress old log files to save space

To apply the configuration immediately:
```bash
sudo logrotate -f /etc/logrotate.d/reconnect_router
```
</details>

<details>
<summary><strong>SMS Alert Types</strong></summary>

The script sends different types of alerts:

- **[START]** - Script has started after a true system reboot (suppressed on same-boot failure-restarts)
- **[ALERT]** - Network connection lost
- **[TRYING]** - Reconnection attempts (limited to every 3rd attempt to reduce spam)
- **[OK]** - Connection successfully restored (with concise downtime info and attempt count)
- **[CRITICAL]** - All reconnection attempts failed (single-line, SMS-safe format)
</details>

## Troubleshooting

<details>
<summary><strong>Script not starting</strong></summary>

- Check if the service is running: `sudo systemctl status reconnect_router.service`
- Verify script permissions: `sudo chmod +x /usr/local/bin/reconnect_router.sh`
- Check for error messages: `sudo journalctl -u reconnect_router.service`
- Look for information in the self-test output in the main log
</details>

<details>
<summary><strong>Multiple start notifications</strong></summary>

If you're receiving unexpected `[START]` notifications:
* The script uses the kernel boot ID to distinguish a true reboot from a systemd failure-restart. A `[START]` SMS should only fire when the boot ID changes (i.e. the Pi-hole actually rebooted).
* If you're getting `[START]` texts on failure-restarts, check that `/var/lib/reconnect_router_last_boot_id` exists and is readable by root.
* Review logs (`journalctl -u reconnect_router.service`) for crash loops or permission issues causing frequent restarts.
* If the script is restarting extremely often (multiple times per minute), this indicates a deeper problem — check for unguarded nonzero exits or dependency failures in the log.
</details>

<details>
<summary><strong>SMS notifications not working</strong></summary>

- Verify the mail command is installed: `which mail`
- Check if iconv is available: `which iconv`
- Test mail configuration manually: 
  ```bash
  echo "Test message" | mail -s "Pi-hole Test" 1234567890@vtext.com
  ```
  Replace the gateway domain with your carrier's SMS gateway as needed.
- Check mail logs: `tail -f /var/log/mail.log`
- Verify carrier gateway settings for your provider
</details>

<details>
<summary><strong>Network not reconnecting properly</strong></summary>

- Confirm the correct network interface name with: `ip a`
- Verify the router IP is correct: `ping 192.168.1.1` (replace with your router's IP)
- Confirm `dhcpcd` is managing the interface: `ps aux | grep dhcpcd`
- Check that `wpa_cli` is available: `which wpa_cli` (required for level-1 soft recovery)
- Do **not** run `dhclient` alongside `dhcpcd` — they will fight over routes and IP assignment
</details>

<details>
<summary><strong>Lock file issues</strong></summary>

- Check /tmp directory permissions: `ls -ld /tmp`
- Verify lock file exists: `ls -l /tmp/reconnect_router.lock`
- If you suspect a stale lock file, check if the PID it contains is still running: `cat /tmp/reconnect_router.lock && ps -p $(cat /tmp/reconnect_router.lock)`
</details>

<details>
<summary><strong>Understanding script termination reasons</strong></summary>

The script logs its termination reasons:

```bash
# View the last termination reason
cat /tmp/reconnect_router_last_term.log

# View systemd termination information
sudo journalctl -u reconnect_router.service | grep -i "terminated"

# Check exit code from last run
cat /tmp/reconnect_router_debug
```

These logs can help diagnose why the script might be restarting unexpectedly.
</details>

<details>
<summary><strong>Diagnosing internet-only failures</strong></summary>

If you're experiencing situations where the router is reachable but the internet connection fails:

1. Check the main log for "Can reach router but cannot reach internet" messages
2. Verify the DNS check hosts are reachable from your network: `ping 1.1.1.1` and `ping 1.0.0.1`
3. Consider adjusting `SMS_INTERNET_FAILURE_THRESHOLD` (default: 10, ≈2.5 min) if you want earlier or later SMS alerts for persistent internet-only outages
4. Review the `RETRY_DELAY` value which affects how quickly the script responds to transient issues
</details>

## Uninstallation

<details>
<summary><strong>Uninstallation Script</strong></summary>

If you need to completely remove the script and its components from your system, you can use the following uninstallation script:

```bash
#!/bin/bash
echo "Stopping and disabling router-reconnect service..."
sudo systemctl stop reconnect_router.service
sudo systemctl disable reconnect_router.service
echo "Removing service file..."
sudo rm -f /etc/systemd/system/reconnect_router.service
echo "Removing script..."
sudo rm -f /usr/local/bin/reconnect_router.sh
echo "Removing logs..."
sudo rm -f /var/log/reconnect_router.log /var/log/router_downtime.log /var/log/router_heartbeat.log
echo "Removing temporary files..."
sudo rm -f /tmp/reconnect_router.lock /tmp/sms_queue.txt /tmp/pihole_last_heartbeat /tmp/reconnect_router_last_term.log
sudo rm -f /var/lib/reconnect_router_last_boot_id
echo "Reloading systemd..."
sudo systemctl daemon-reload
echo "Uninstallation complete."
```

Save this as `uninstall_reconnect_router.sh`, make it executable with `chmod +x uninstall_reconnect_router.sh`, and run it with `sudo ./uninstall_reconnect_router.sh`.
</details>

## License

This script is released under the MIT License.

## Contributing

If you found this helpful or made improvements, feel free to submit an issue or pull request — feedback is always welcome!