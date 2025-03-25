# Pi-hole Wireless Reconnect + SMS Alert Script

A robust Bash script that monitors network connectivity on a Pi-hole device, automatically reconnects when the connection drops, and sends SMS alerts for status updates.

>This script is an independent project and is not associated with or supported by the Pi-hole team.

## Features

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

## Prerequisites

The script requires the following dependencies:

1. **Postfix** (or another Mail Transfer Agent)
2. **mailutils** (provides the `mail` command used for SMS)
3. **iconv** (for proper character encoding in SMS messages)

## Installation

### 1. Install Dependencies

```bash
# Update package lists
sudo apt update

# Install postfix, mailutils and other dependencies
sudo apt install postfix mailutils libc-bin
```
> **Note:** `iconv` is included in `libc-bin`, so installing `libc-bin` will provide `iconv`.

### 2. Configure Postfix

During installation:

* Select **"Internet Site"** when prompted
* For the system mail name, you'll be prompted to enter a fully qualified domain name (FQDN). If this is just for local use on your home network, entering `localhost.localdomain` or `raspberrypi.local` is sufficient.

### 3. Install the Script

```bash
# Copy the script to /usr/local/bin/
sudo cp reconnect_router.sh /usr/local/bin/

# Make it executable
sudo chmod +x /usr/local/bin/reconnect_router.sh
```

### 4. Create a Systemd Service

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

> **Note:** The service now uses `Restart=on-failure` instead of `Restart=always` and includes a `RestartSec=30` directive to prevent excessive restart cycles.

Enable and start the service:

```bash
sudo systemctl enable reconnect_router.service
sudo systemctl start reconnect_router.service
```

## Configuration

Before using the script, you need to modify several variables in the script:

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

3. Optional configuration parameters:
   - `RETRY_DELAY`: Time between reconnection attempts (default: 15s)
   - `MAX_RETRIES`: Maximum reconnection attempts before giving up (default: 10)
   - `HEARTBEAT_ENABLED`: Enable/disable heartbeat monitoring (default: true)
   - `HEARTBEAT_INTERVAL`: Time between heartbeat checks (default: 3600s = 1 hour)
   - `MISSED_HEARTBEATS_THRESHOLD`: Number of missed heartbeats before alerting (default: 3)
   - `PING_COUNT`: Number of pings to send when checking connection (default: 2)
   - `PING_TIMEOUT`: Timeout in seconds for ping operation (default: 3)
   - `MAX_INTERNET_FAILURES`: Number of internet failures before temporary backoff (default: 5)
   - `STARTUP_THRESHOLD`: Time (in seconds) to suppress duplicate startup notifications (default: 300)

4. Save and close the file

## Advanced Configuration

### Startup Notification Management

The script now includes a feature to prevent duplicate startup notifications when the service restarts frequently:

```bash
# Startup notification configuration
STARTUP_CHECK_FILE="/tmp/reconnect_router_last_start"
STARTUP_THRESHOLD=300  # 5 minutes
```

If the script restarts within 5 minutes of a previous run, it will suppress the startup SMS notification to reduce message spam. You can adjust the threshold by changing the value (in seconds).

### Heartbeat Monitoring

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

### Enhanced Lock File Handling

The script now includes improved lock file management:
- Detects and removes stale lock files from crashed script instances
- Stores PID in the lock file for better tracking
- Properly releases locks during script termination

This prevents issues where a crashed script might leave behind a lock file that blocks future script runs.

### SMS Notifications

Notification format has been optimized to fit within SMS character limits (160 characters):
- Connection restored messages are now more concise
- Critical information is preserved while removing verbose details
- Recovery messages show downtime duration and attempts used

Example recovery message:
```
[OK] Pi-hole Online! Down: 2m30s. 3/10 attempts
```

### Log Files

The script uses multiple log files for different types of events:

- **Main log** (`/var/log/reconnect_router.log`): General script activity
- **Downtime log** (`/var/log/router_downtime.log`): Connection loss and recovery events
- **Heartbeat log** (`/var/log/router_heartbeat.log`): Heartbeat status and interruptions

You can monitor these logs separately for more targeted troubleshooting. If the script cannot write to the standard locations, it will automatically fall back to using files in the `/tmp` directory.

### Log Management

The script includes two complementary approaches to log management:

#### 1. Built-in Basic Log Rotation

The script performs basic size-based log rotation:

```bash
# Add log rotation check
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -ge 10485760 ]; then
    log_message "Log file $LOG has grown too large, rotating"
    sudo mv "$LOG" "$LOG.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
fi
```

This provides an emergency safeguard against excessive log growth but has limitations:
- It doesn't compress rotated logs
- It doesn't remove old rotated logs
- The 10MB threshold may be too large for comfortable viewing

> **Note:** For most users, we recommend implementing the system-level log rotation described below, which provides more complete log management.

### Exponential Backoff

During extended outages, the script uses exponential backoff to reduce system load:

```bash
# After 5 consecutive failures, backoff increases exponentially (2^n)
# The backoff is capped at 10 minutes (600 seconds)
```

This prevents excessive reconnection attempts during prolonged network outages.

## Advanced Mail Configuration (Optional)

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

## Usage

The script will run automatically at system startup. You can manually control it with:

```bash
# Start the service
sudo systemctl enable reconnect_router.service
sudo systemctl start reconnect_router.service

# Stop the service
sudo systemctl stop reconnect_router.service

# Restart the service
sudo systemctl restart reconnect_router.service

# Check status
sudo systemctl status reconnect_router.service
```

## Monitoring and Logs

Check the various logs to see the script's activity:

```bash
# View the main log
tail -f /var/log/reconnect_router.log

# View downtime events
tail -f /var/log/router_downtime.log

# View heartbeat activity
tail -f /var/log/router_heartbeat.log
```

### Recommended System-Level Log Rotation

For the most effective log management, set up system-level log rotation using logrotate:

```bash
sudo nano /etc/logrotate.d/reconnect_router
```

Add the following improved configuration:

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

This enhanced configuration will:
- Rotate logs when they reach 2MB in size (much more manageable than 10MB)
- Perform rotation weekly or when size threshold is reached, whichever comes first
- Keep 4 rotations of history (approximately one month of logs)
- Compress old log files to save space
- Ensure proper permissions on new log files
- Delay compression by one cycle to avoid issues with open file handles

To apply the configuration immediately:
```bash
sudo logrotate -f /etc/logrotate.d/reconnect_router
```

## SMS Alert Types

The script sends different types of alerts:

- **[START]** - Script has started (suppressed if restarted within 5 minutes)
- **[ALERT]** - Network connection lost
- **[TRYING]** - Reconnection attempts (limited to reduce spam)
- **[OK]** - Connection successfully restored (with concise downtime info)
- **[CRITICAL]** - All reconnection attempts failed
- **[HEARTBEAT]** - No longer sent (heartbeat only used for downtime detection)

## Advanced Diagnostics

The script now includes enhanced diagnostic logging to help troubleshoot service issues:

```bash
log_message "Script started with PID $$"
log_message "Command line: $0 $@"
log_message "Last terminated reason: $(journalctl -u reconnect_router.service -n 20 | grep -i 'terminated' | tail -1)"
```

This provides valuable information in the logs about how the script is being initialized and why previous instances terminated.

## Self-Test Feature

The script includes a self-test function that runs at startup to check for potential issues:

- Verifies lock file creation
- Confirms network interface exists and lists available interfaces if not found
- Checks for DHCP client availability
- Tests router reachability

This helps identify configuration problems before they cause runtime failures.

## Troubleshooting

### Script not starting
- Check if the service is running: `sudo systemctl status reconnect_router.service`
- Verify script permissions: `sudo chmod +x /usr/local/bin/reconnect_router.sh`
- Check for error messages: `sudo journalctl -u reconnect_router.service`
- Look for information in the self-test output in the main log

### Multiple start notifications
- If you're receiving multiple [START] notifications, check if your systemd service is set to `Restart=always` instead of `Restart=on-failure`
- Verify the `STARTUP_THRESHOLD` value (default 300 seconds) is appropriate for your environment
- Check logs for signs of script crashes causing frequent restarts

### SMS notifications not working
- Verify the mail command is installed: `which mail`
- Check if iconv is available: `which iconv`
- Test mail configuration manually: 
  ```bash
  echo "Test message" | mail -s "Pi-hole Test" 1234567890@vtext.com
  ```
  Replace the gateway domain with your carrier's SMS gateway as needed.
- Check mail logs: `tail -f /var/log/mail.log`
- Verify carrier gateway settings for your provider

### SMS messages getting truncated
- The script now uses a more concise format for notifications to avoid truncation
- If messages are still getting truncated, you may need to further customize the recovery message format

### Network not reconnecting properly
- Confirm the correct network interface name with: `ip a`
- Verify the router IP is correct: `ping 192.168.1.1` (replace with your router's IP)
- Check the DHCP client is working: `ps aux | grep dhclient`
- Review verbose dhclient output in the logs
- Verify both dhclient and dhcpcd availability on your system

### Heartbeat not working
- Check if the heartbeat file exists: `ls -l /tmp/pihole_last_heartbeat`
- Verify heartbeat log has entries: `cat /var/log/router_heartbeat.log`
- Check file permissions on the heartbeat file

### Lock file issues
- Check /tmp directory permissions: `ls -ld /tmp`
- Verify lock file exists: `ls -l /tmp/reconnect_router.lock`
- If you suspect a stale lock file, check if the PID it contains is still running: `cat /tmp/reconnect_router.lock && ps -p $(cat /tmp/reconnect_router.lock)`

## License

This script is released under the MIT License.

## Uninstallation

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

## Contributing

If you found this helpful or made improvements, feel free to submit an issue or pull request — feedback is always welcome!