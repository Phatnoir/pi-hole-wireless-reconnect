# Pi-hole Wireless Reconnect + SMS Alert Script

A robust Bash script that monitors network connectivity on a Pi-hole device, automatically reconnects when the connection drops, and sends SMS alerts for status updates.

## Features

* **Automatic reconnection** — Detects connectivity loss and reattempts connection
* **SMS notifications** — Real-time alerts for status changes with intelligent message queuing
* **Heartbeat monitoring** — Detects script interruptions and system downtime
* **Exponential backoff** — Intelligently adjusts retry intervals during extended outages
* **Multiple log files** — Separate logs for reconnection events, downtime tracking, and heartbeats
* **Message prioritization** — Reduces notification spam by prioritizing important messages
* **System integration** — Runs automatically at startup via systemd
* **Robust locking** — Prevents multiple instances from running simultaneously

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
sudo cp router_reconnect.sh /usr/local/bin/

# Make it executable
sudo chmod +x /usr/local/bin/router_reconnect.sh
```

### 4. Create a Systemd Service

Create a new service file:

```bash
sudo nano /etc/systemd/system/router_reconnect.service
```

Add the following content:

```ini
[Unit]
Description=Pi-hole Wireless Reconnect Script
After=network.target

[Service]
ExecStart=/usr/local/bin/router_reconnect.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
```

Enable and start the service:

```bash
sudo systemctl enable router_reconnect.service
sudo systemctl start router_reconnect.service
```

## Configuration

Before using the script, you need to modify several variables in the script:

1. Edit the script with your preferred editor:
   ```bash
   sudo nano /usr/local/bin/router_reconnect.sh
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

4. Save and close the file

## Advanced Configuration

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

### Log Files

The script uses multiple log files for different types of events:

- **Main log** (`/var/log/router_reconnect.log`): General script activity
- **Downtime log** (`/var/log/router_downtime.log`): Connection loss and recovery events
- **Heartbeat log** (`/var/log/router_heartbeat.log`): Heartbeat status and interruptions

You can monitor these logs separately for more targeted troubleshooting.

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
sudo systemctl start router_reconnect.service

# Stop the service
sudo systemctl stop router_reconnect.service

# Restart the service
sudo systemctl restart router_reconnect.service

# Check status
sudo systemctl status router_reconnect.service
```

## Monitoring and Logs

Check the various logs to see the script's activity:

```bash
# View the main log
tail -f /var/log/router_reconnect.log

# View downtime events
tail -f /var/log/router_downtime.log

# View heartbeat activity
tail -f /var/log/router_heartbeat.log
```

### Log Rotation

To prevent log files from growing too large, set up log rotation:

```bash
sudo nano /etc/logrotate.d/router_reconnect
```

Add the following content:

```
/var/log/router_reconnect.log /var/log/router_downtime.log /var/log/router_heartbeat.log {
    rotate 4
    weekly
    compress
    missingok
    notifempty
    create 0644 root root
}
```

This configuration will:
- Rotate logs on a weekly basis instead of daily
- Keep 4 rotations (approximately one month of logs)
- Compress old log files to save space

## SMS Alert Types

The script sends different types of alerts:

- **[START]** - Script has started
- **[ALERT]** - Network connection lost
- **[TRYING]** - Reconnection attempts (limited to reduce spam)
- **[OK]** - Connection successfully restored
- **[CRITICAL]** - All reconnection attempts failed
- **[HEARTBEAT]** - No longer sent (heartbeat only used for downtime detection)

## Troubleshooting

### Script not starting
- Check if the service is running: `sudo systemctl status router_reconnect.service`
- Verify script permissions: `sudo chmod +x /usr/local/bin/router_reconnect.sh`
- Check for error messages: `sudo journalctl -u router_reconnect.service`

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

### Network not reconnecting properly
- Confirm the correct network interface name with: `ip a`
- Verify the router IP is correct: `ping 192.168.1.1` (replace with your router's IP)
- Check the DHCP client is working: `ps aux | grep dhclient`
- Review verbose dhclient output in the logs

### Heartbeat not working
- Check if the heartbeat file exists: `ls -l /tmp/pihole_last_heartbeat`
- Verify heartbeat log has entries: `cat /var/log/router_heartbeat.log`

## License

This script is released under the MIT License.

## Uninstallation

If you need to completely remove the script and its components from your system, you can use the following uninstallation script:

```bash
#!/bin/bash
echo "Stopping and disabling router-reconnect service..."
sudo systemctl stop router_reconnect.service
sudo systemctl disable router_reconnect.service
echo "Removing service file..."
sudo rm -f /etc/systemd/system/router_reconnect.service
echo "Removing script..."
sudo rm -f /usr/local/bin/router_reconnect.sh
echo "Removing logs..."
sudo rm -f /var/log/router_reconnect.log /var/log/router_downtime.log /var/log/router_heartbeat.log
echo "Reloading systemd..."
sudo systemctl daemon-reload
echo "Uninstallation complete."
```

Save this as `uninstall_router_reconnect.sh`, make it executable with `chmod +x uninstall_router_reconnect.sh`, and run it with `sudo ./uninstall_router_reconnect.sh`.

## Contributing

If you found this helpful or made improvements, feel free to submit an issue or pull request — feedback is always welcome!
