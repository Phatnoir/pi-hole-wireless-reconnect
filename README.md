# Pi-hole Wireless Reconnect + SMS Alert Script

A robust Bash script that monitors network connectivity on a Pi-hole device, automatically reconnects when the connection drops, and sends SMS alerts for status updates.

>This script is an independent project and is not associated with or supported by the Pi-hole team.

## Table of Contents
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

## Features

<details>
<summary><strong>Click to expand feature list</strong></summary>

* **Automatic reconnection** — Detects connectivity loss and reattempts connection
* **SMS notifications** — Real-time alerts for status changes with intelligent message queuing
* **Heartbeat monitoring** — Detects script interruptions and system downtime
* **Exponential backoff** — Intelligently adjusts retry intervals during extended outages
* **Multiple log files** — Separate logs for reconnection events, downtime tracking, and heartbeats
* **Message prioritization** — Reduces notification spam by prioritizing important messages
* **System integration** — Runs automatically at startup via systemd
* **Robust locking** — Prevents multiple instances from running simultaneously with stale lock detection
* **Self-test** — Verifies environment and dependencies on startup
* **Error handling** — Set up with trap handlers for safe termination
* **Fallback logging** — Redirects to /tmp if standard log locations are unavailable
* **Log rotation** — Automatically rotates large log files to prevent disk space issues
* **Anti-spam measures** — Suppresses duplicate startup notifications when service restarts frequently
* **Concise SMS format** — Optimized messages fit within SMS character limits
* **Enhanced reliability** — Properly quoted variables and better error handling throughout
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
sudo apt install postfix mailutils libc-bin
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
After=network.target

[Service]
ExecStart=/usr/local/bin/reconnect_router.sh
Restart=on-failure
RestartSec=30
User=root

[Install]
WantedBy=multi-user.target
```

> **Note:** The service uses `Restart=on-failure` with `RestartSec=30` to prevent excessive restart cycles.

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
- `MAX_RETRIES`: Maximum reconnection attempts before giving up (default: 10)
- `HEARTBEAT_ENABLED`: Enable/disable heartbeat monitoring (default: true)
- `HEARTBEAT_INTERVAL`: Time between heartbeat checks (default: 3600s = 1 hour)
- `MISSED_HEARTBEATS_THRESHOLD`: Number of missed heartbeats before alerting (default: 3)
- `PING_COUNT`: Number of pings to send when checking connection (default: 2)
- `PING_TIMEOUT`: Timeout in seconds for ping operation (default: 3)
- `MAX_INTERNET_FAILURES`: Number of internet failures before temporary backoff (default: 5)
- `STARTUP_THRESHOLD`: Time (in seconds) to suppress duplicate startup notifications (default: 300)
</details>

### Advanced Configuration

<details>
<summary><strong>Startup Notification Management</strong></summary>

The script includes a feature to prevent duplicate startup notifications when the service restarts frequently:

```bash
# Startup notification configuration
STARTUP_CHECK_FILE="/tmp/reconnect_router_last_start"
STARTUP_THRESHOLD=300  # 5 minutes
```

If the script restarts within 5 minutes of a previous run, it will suppress the startup SMS notification to reduce message spam. You can adjust the threshold by changing the value (in seconds).
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

This prevents issues where a crashed script might leave behind a lock file that blocks future script runs.
</details>

<details>
<summary><strong>SMS Notifications</strong></summary>

Notification format has been optimized to fit within SMS character limits (160 characters):
- Connection restored messages are now more concise
- Critical information is preserved while removing verbose details
- Recovery messages show downtime duration and attempts used

Example recovery message:
```
[OK] Pi-hole Online! Down: 2m30s. 3/10 attempts
```
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

- **[START]** - Script has started (suppressed if restarted within 5 minutes)
- **[ALERT]** - Network connection lost
- **[TRYING]** - Reconnection attempts (limited to reduce spam)
- **[OK]** - Connection successfully restored (with concise downtime info)
- **[CRITICAL]** - All reconnection attempts failed
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

- If you're receiving multiple [START] notifications, check if your systemd service is set to `Restart=always` instead of `Restart=on-failure`
- Verify the `STARTUP_THRESHOLD` value (default 300 seconds) is appropriate for your environment
- Check logs for signs of script crashes causing frequent restarts
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
- Check the DHCP client is working: `ps aux | grep dhclient`
- Review verbose dhclient output in the logs
- Verify both dhclient and dhcpcd availability on your system
</details>

<details>
<summary><strong>Lock file issues</strong></summary>

- Check /tmp directory permissions: `ls -ld /tmp`
- Verify lock file exists: `ls -l /tmp/reconnect_router.lock`
- If you suspect a stale lock file, check if the PID it contains is still running: `cat /tmp/reconnect_router.lock && ps -p $(cat /tmp/reconnect_router.lock)`
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
sudo rm -f /tmp/reconnect_router.lock /tmp/sms_queue.txt /tmp/pihole_last_heartbeat /tmp/reconnect_router_last_start
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