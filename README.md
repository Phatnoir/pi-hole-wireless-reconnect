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

```bash
# 1. Install dependencies
sudo apt update && sudo apt install -y postfix mailutils libc-bin

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
```

</details>

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
* **Enhanced fallback logging** — Automatically redirects logs to /tmp if standard log paths are unavailable
* **Improved interface restart** — Better handling for different DHCP client types and interface states
* **Persistent internet-only failure handling** — Special handling for cases where router is reachable but internet is not
* **Sophisticated trap handling** — Comprehensive exit handlers with proper cleanup and reporting
* **Startup frequency detection** — Prevents excessive notifications during frequent restarts
</details>

## Advanced Configuration

<details>
<summary><strong>Internet Connectivity Handling</strong></summary>

The script now distinguishes between two types of connectivity issues:
1. **Complete connection loss** — Cannot reach the router
2. **Internet-only failures** — Can reach the router but not the internet

For internet-only failures, the script uses a more gradual approach:
```bash
# Internet failure tracking settings
INTERNET_FAILURES=0
MAX_INTERNET_FAILURES=5
```

When internet-only failures persist for multiple cycles, the script will attempt a network restart, but with less aggressive timing than for complete connection loss.
</details>

<details>
<summary><strong>Enhanced Error Handling</strong></summary>

The script now includes more sophisticated error handling:

- **Diagnostic logging** — Tracks script termination reasons via journal analysis
- **Fallback log paths** — Automatically redirects logs to /tmp if standard paths are unavailable
- **Cross-platform compatibility** — Better detection of system-specific networking tools
- **Log path verification** — Creates log directories if they don't exist with appropriate permissions

This makes the script more resilient in diverse environments and helps with troubleshooting.
</details>

## Troubleshooting

<details>
<summary><strong>Understanding script termination reasons</strong></summary>

The script now logs its termination reasons:

```bash
# View the last termination reason
cat /tmp/reconnect_router_last_term.log

# Check clean exit markers
cat /tmp/reconnect_router_clean_exit

# View systemd termination information
sudo journalctl -u reconnect_router.service | grep -i "terminated"
```

These logs can help diagnose why the script might be restarting unexpectedly.
</details>

<details>
<summary><strong>Diagnosing internet-only failures</strong></summary>

If you're experiencing situations where the router is reachable but the internet connection fails:

1. Check the main log for "Can reach router but cannot reach internet" messages
2. Verify the DNS check host is reachable from your network: `ping 1.1.1.1`
3. Consider adjusting the `MAX_INTERNET_FAILURES` value (default: 5) if you have an inconsistent internet connection
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
sudo rm -f /tmp/reconnect_router.lock /tmp/sms_queue.txt /tmp/pihole_last_heartbeat /tmp/reconnect_router_last_start /tmp/reconnect_router_last_term.log /tmp/reconnect_router_clean_exit
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

