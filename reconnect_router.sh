#!/bin/bash
set -Euo pipefail  # -E: inherit ERR traps, -u: error on unset vars, -o pipefail: catch pipe failures
# Intentionally omitting -e: this is a long-running daemon where many commands
# legitimately return nonzero (grep, ping, arithmetic). Use explicit || guards instead.

# Force UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Configuration
ROUTER_IP="192.168.1.1" # Default value - should match user's router config
INTERFACE="wlan0"
LOG_FILE="/var/log/reconnect_router.log"
DOWNTIME_LOG="/var/log/router_downtime.log" # New: dedicated log for tracking downtime events
MAX_RETRIES=10
RETRY_DELAY=15
ROUTER_FAILURE_THRESHOLD=4  # Number of consecutive failures before triggering reconnection attempts (~60s at 15s RETRY_DELAY)
PING_COUNT=2
PING_TIMEOUT=3
RESTART_TIME_FILE="/tmp/reconnect_last_iface_restart"
RESTART_INTERVAL=180  # 3 minutes minimum between restarts
DNS_CHECK_HOSTS=("1.1.1.1" "1.0.0.1")  # Cloudflare IPv4 redundancy
SMS_INTERNET_CHECK="8.8.8.8"  # For SMS delivery checks
PING_SIZE=32 #sets ping package size
INTERNET_WAS_DOWN=false
ROUTER_WAS_DOWN=false
LAST_INTERNET_DOWN_TIME=""
LAST_ROUTER_DOWN_TIME=""
# Added flag to prevent duplicate restoration logs
DOWNTIME_ALREADY_LOGGED=false

# SMS Configuration
PHONE_NUMBER="123456789"  # Replace with your phone number
CARRIER_GATEWAY="vtext.com"  # Verizon (or AT&T: txt.att.net, T-Mobile: tmomail.net)
SMS_EMAIL="$PHONE_NUMBER@$CARRIER_GATEWAY"
EMAIL_SUBJECT="Pi-hole Alert"
HOSTNAME=$(hostname)

# Heartbeat Configuration
HEARTBEAT_ENABLED=true         # Set to false to disable heartbeat
HEARTBEAT_INTERVAL=3600        # Time between heartbeats in seconds (1 hour)
MISSED_HEARTBEATS_THRESHOLD=3  # Alert after this many missed heartbeats
HEARTBEAT_FILE="/tmp/pihole_last_heartbeat"
HEARTBEAT_LOG="/var/log/router_heartbeat.log" # New: dedicated log for heartbeat events

# Internet failure tracking
# One threshold: send SMS after this many consecutive internet-only failures.
# At RETRY_DELAY=15s per loop, 10 failures ≈ 2.5 minutes of no internet.
# The old MAX_INTERNET_FAILURES=5 that reset the counter is removed — it
# prevented SMS_INTERNET_FAILURE_THRESHOLD from ever being reached.
INTERNET_FAILURES=0
SMS_INTERNET_FAILURE_THRESHOLD=10

# Lock file
LOCK_FILE="/tmp/reconnect_router.lock"

# Last termination reason log
LAST_TERM_REASON_FILE="/tmp/reconnect_router_last_term.log"

# Function to log messages (define early for diagnostic use)
log_message() {
    local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $1" >> "$LOG_FILE" 2>/dev/null || echo "$timestamp - $1" >> "/tmp/reconnect_router.log"
    echo "$timestamp - $1"
}

# Advanced diagnostic logging - IMPROVED to avoid recursive logging
log_message "Script started with PID $$"
log_message "Command line: $0 ${*}"

# Get clean termination reason without recursion
if journalctl -u reconnect_router.service --since "1 hour ago" | grep -i "terminated" | grep -v "Last terminated reason" | tail -1 > "$LAST_TERM_REASON_FILE" 2>/dev/null; then
    log_message "Last terminated reason: $(cat "$LAST_TERM_REASON_FILE" 2>/dev/null || echo 'Not available')"
else
    log_message "Last terminated reason: Not available"
fi

# Determine if this is a true reboot or just a failure-restart by comparing boot IDs.
# Boot ID lives in /proc (changes on every real reboot) and we persist the last-seen
# value in /var/lib so it survives systemd-tmpfiles wiping /tmp at 4am.
BOOT_ID_FILE="/var/lib/reconnect_router_last_boot_id"
CURRENT_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")

if [ -f "$BOOT_ID_FILE" ]; then
    last_boot_id=$(cat "$BOOT_ID_FILE" 2>/dev/null || echo "")
    if [ "$last_boot_id" = "$CURRENT_BOOT_ID" ]; then
        # Same boot, script was restarted by systemd after a failure — suppress SMS
        log_message "Script restarted within same boot session (boot ID unchanged) - suppressing start notification"
        SUPPRESS_START_NOTIFICATION=true
    else
        # Boot ID changed — genuine reboot, send SMS
        log_message "New boot detected (boot ID changed) - will send start notification"
        SUPPRESS_START_NOTIFICATION=false
    fi
else
    # First run ever — no stored boot ID
    SUPPRESS_START_NOTIFICATION=false
fi

# Persist current boot ID for next startup
echo "$CURRENT_BOOT_ID" > "$BOOT_ID_FILE" 2>/dev/null || \
    log_message "WARNING: Could not write boot ID to $BOOT_ID_FILE — check /var/lib permissions"

# Check for required dependencies
for cmd in mail iconv ip ping flock wpa_cli iw; do
    if ! command -v $cmd >/dev/null; then
        echo "ERROR: Required command '$cmd' not found. Please install the necessary package."
        exit 1
    fi
done

# Check for optional but recommended dependencies
if ! command -v ethtool >/dev/null; then
    log_message "WARNING: 'ethtool' not found. MAC address restoration will be skipped. Install with: sudo apt install ethtool"
fi

# Check /tmp permissions - more portable across Unix systems
if [ "$(stat -c %A /tmp)" != "drwxrwxrwt" ]; then
    log_message "WARNING: /tmp directory doesn't have correct permissions (1777/drwxrwxrwt). This may cause lock file issues."
    # Uncomment to automatically fix permissions:
    # sudo chmod 1777 /tmp
fi

# Enhanced lock file handling - NEW
# Check if the process holding the lock is still running
if [ -f "$LOCK_FILE" ]; then
    PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$PID" ] && ! ps -p "$PID" > /dev/null 2>&1; then
        log_message "Removing stale lock file from PID $PID"
        rm -f "$LOCK_FILE"
    fi
fi

# Open FD 200 and associate it with the lock file
exec 200>"$LOCK_FILE" || {
    echo "ERROR: Could not open lock file $LOCK_FILE"
    exit 1
}

# Attempt to acquire the lock
if ! flock -n 200; then
    echo "Script is already running. Exiting."
    exit 1
fi

# Write PID into the lock file after acquiring it (safe - no race with flock held).
# Writing to FD 200 writes to the underlying file; stale-lock check reads the same file.
echo $$ >&200

# Ensure log files and directories exist with fallback to /tmp
for LOG in "$LOG_FILE" "$DOWNTIME_LOG" "$HEARTBEAT_LOG"; do
    # Create directory if needed
    if [ ! -d "$(dirname "$LOG")" ]; then
        if ! mkdir -p "$(dirname "$LOG")" 2>/dev/null; then
            # If can't create in /var/log, fall back to /tmp
            NEW_LOG="/tmp/$(basename "$LOG")"
            log_message "WARNING: Could not create directory for $LOG, falling back to $NEW_LOG"
            
            # Update variable based on name
            if [ "$LOG" = "$LOG_FILE" ]; then
                LOG_FILE="$NEW_LOG"
            elif [ "$LOG" = "$DOWNTIME_LOG" ]; then
                DOWNTIME_LOG="$NEW_LOG"
            elif [ "$LOG" = "$HEARTBEAT_LOG" ]; then
                HEARTBEAT_LOG="$NEW_LOG"
            fi
            LOG="$NEW_LOG"
        fi
    fi
    
    # Touch the file if it doesn't exist
    if [ ! -f "$LOG" ]; then
        if ! touch "$LOG" 2>/dev/null || ! chown "$(whoami)" "$LOG" 2>/dev/null; then
            log_message "WARNING: Could not create or set permissions for $LOG"
        else
            # Set explicit permissions
            chmod 644 "$LOG" 2>/dev/null || true
        fi
    fi
    
    # Now make sure we can write to it
    if ! touch "$LOG" 2>/dev/null; then
        log_message "ERROR: Cannot write to log file $LOG. Check permissions."
    fi
    
    # Add log rotation check
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -ge 10485760 ]; then
        log_message "Log file $LOG has grown too large, rotating"
        mv "$LOG" "$LOG.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
    fi
done

# Function to log downtime events
log_downtime() {
    local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local event="$1"
    local duration="$2"
    
    # Format: TIMESTAMP | EVENT | DURATION | ADDITIONAL_INFO
    echo "$timestamp | $event | $duration | $3" >> "$DOWNTIME_LOG" 2>/dev/null || \
        echo "$timestamp | $event | $duration | $3" >> "/tmp/router_downtime.log"
    
    # Also log to main log (can be commented out to reduce redundancy if desired)
    log_message "Downtime event: $event | $duration | $3"
    
    # Set the flag if this is a CONNECTION_RESTORED event
    if [ "$event" = "CONNECTION_RESTORED" ]; then
        DOWNTIME_ALREADY_LOGGED=true
    fi
}

# Function to log heartbeat events
log_heartbeat() {
    local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local event="$1"
    
    # Format: TIMESTAMP | HEARTBEAT | EVENT | ADDITIONAL_INFO
    echo "$timestamp | HEARTBEAT | $event | $2" >> "$HEARTBEAT_LOG" 2>/dev/null || \
        echo "$timestamp | HEARTBEAT | $event | $2" >> "/tmp/router_heartbeat.log"
}

# Ensure heartbeat is initialized on startup
if [ "$HEARTBEAT_ENABLED" = "true" ] && [ ! -f "$HEARTBEAT_FILE" ]; then
    date +%s > "$HEARTBEAT_FILE" 2>/dev/null || log_message "WARNING: Could not create heartbeat file"
    log_heartbeat "INITIALIZED" "Startup initialization"
fi

# Enhanced SMS function with better message queuing and retry logic
send_sms() {
    local message="$1"
    local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local queue_file="/tmp/sms_queue.txt"
    local message_type=""

    # Determine message type
    if [[ "$message" == *"[START]"* ]]; then
        message_type="START"
    elif [[ "$message" == *"[ALERT]"* ]]; then
        message_type="ALERT"
    elif [[ "$message" == *"[TRYING]"* ]]; then
        message_type="TRYING"
    elif [[ "$message" == *"[OK]"* ]]; then
        message_type="OK"
    elif [[ "$message" == *"[CRITICAL]"* ]]; then
        message_type="CRITICAL"
    elif [[ "$message" == *"[HEARTBEAT]"* ]]; then
        message_type="HEARTBEAT"
    fi

    # Format message with timestamp if it doesn't already have one
    if [[ ! "$message" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        message="$timestamp - $message"
    fi

    # Try to send directly if internet is available
    if ping -s "$PING_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" $SMS_INTERNET_CHECK > /dev/null 2>&1; then
        # Internet is available

        # If we have queued messages, process them intelligently
        if [ -f "$queue_file" ]; then
            log_message "Processing queued messages"

            # Extract the last message of each important type
            declare -A latest_msgs
            
            while read -r line; do
                if [[ "$line" == *"[START]"* ]]; then
                    latest_msgs["START"]="$line"
                elif [[ "$line" == *"[ALERT]"* ]]; then
                    latest_msgs["ALERT"]="$line"
                elif [[ "$line" == *"[CRITICAL]"* ]]; then
                    latest_msgs["CRITICAL"]="$line"
                fi
                # Skip TRYING and HEARTBEAT messages to reduce spam
            done < "$queue_file"
            
            # If reconnection was successful, send only ALERT and current OK message
            if [ "$message_type" = "OK" ]; then
                # Send the most recent ALERT message to show when it went down
                if [ -n "${latest_msgs[ALERT]}" ]; then
                    log_message "Sending queued ALERT message"
                    send_email_with_retry "${latest_msgs[ALERT]}"
                    sleep 2
                fi
                
                # Send current OK message
                send_email_with_retry "$message"
            else
                # For other message types, send ALERT and CRITICAL if they exist
                if [ -n "${latest_msgs[ALERT]}" ]; then
                    log_message "Sending queued ALERT message"
                    send_email_with_retry "${latest_msgs[ALERT]}"
                    sleep 2
                fi
                
                if [ -n "${latest_msgs[CRITICAL]}" ]; then
                    log_message "Sending queued CRITICAL message"
                    send_email_with_retry "${latest_msgs[CRITICAL]}"
                    sleep 2
                fi
                
                # Send current message
                send_email_with_retry "$message"
            fi
            
            # Clear the queue
            rm "$queue_file"
        else
            # No queue, just send current message
            send_email_with_retry "$message"
        fi
    else
        # No internet, queue the message
        echo "$message" >> "$queue_file"
        log_message "Message queued for later delivery: $message"
        
        # Limit queue size to 50 entries to prevent bloat
        if [ -f "$queue_file" ] && [ "$(wc -l < "$queue_file")" -gt 50 ]; then
            log_message "SMS queue size exceeded limit, trimming to last 50 entries"
            tail -n 50 "$queue_file" > "$queue_file.tmp"
            mv "$queue_file.tmp" "$queue_file"
        fi
    fi
}

# Function to send email with retry logic
send_email_with_retry() {
    local message="$1"
    local attempts=0
    local max_attempts=3
    local success=false
    
    while [ $attempts -lt $max_attempts ]; do
        # Fix character encoding issues by converting to ASCII - with better error handling
        converted=$(echo -e "$message" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || echo "$message")
        if echo "$converted" | mail -s "$EMAIL_SUBJECT" -a "Content-Type: text/plain; charset=UTF-8" "$SMS_EMAIL" 2>/dev/null; then
            success=true
            break
        fi
        ((attempts++))
        log_message "Email send attempt $attempts failed, retrying..."
        sleep 2
    done
    
    if ! $success; then
        log_message "Failed to send SMS notification after $max_attempts attempts"
    fi
}

# Function to manage heartbeat
process_heartbeat() {
    if [ "$HEARTBEAT_ENABLED" != "true" ]; then
        return
    fi
    
    local current_time
	current_time=$(date +%s)
    
    # Create heartbeat file if it doesn't exist
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "$current_time" > "$HEARTBEAT_FILE"
        log_heartbeat "INITIALIZED" "First run"
        return
    fi
    
    # Read last heartbeat time
    local last_heartbeat
	last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "$current_time")
    local elapsed_time=$((current_time - last_heartbeat))
    
    # Check if we should update the heartbeat
    if [ "$elapsed_time" -ge "$HEARTBEAT_INTERVAL" ]; then
        # Check if we missed too many heartbeats
        if [ "$elapsed_time" -ge "$((HEARTBEAT_INTERVAL * MISSED_HEARTBEATS_THRESHOLD))" ]; then
            # We missed several heartbeats - might have been down
            local down_time
			down_time=$(date -d "@$last_heartbeat" '+%Y-%m-%d %H:%M:%S')
            local hours=$((elapsed_time / 3600))
            local minutes=$(( (elapsed_time % 3600) / 60 ))
            local seconds=$((elapsed_time % 60))
            local downtime_str="${hours}h ${minutes}m ${seconds}s"
            
            log_heartbeat "MISSED" "$downtime_str (${elapsed_time}s)"
            log_downtime "SCRIPT_INTERRUPTED" "$downtime_str" "Detected via missed heartbeats"
            
            # FIXED SMS FORMAT - More concise to fit within 160 characters
            send_sms "[ALERT] Pi-hole back online! Down: ${hours}h${minutes}m${seconds}s (${down_time} to now)"
        else
            # Normal heartbeat - log but don't send SMS
            log_heartbeat "NORMAL" "${elapsed_time}s since last heartbeat"
        fi
        
        # Update heartbeat time
        echo "$current_time" > "$HEARTBEAT_FILE"
    fi
}

# Function to check network connectivity
check_connection() {
    # Check upstream internet FIRST. If we can reach 1.1.1.1, Wi-Fi is working
    # regardless of whether the router responds to ICMP. This prevents router
    # ping blips from accumulating consecutive_failures and causing false restarts.
    internet_ok=false
    for host in "${DNS_CHECK_HOSTS[@]}"; do
        if ping -s "$PING_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1; then
            internet_ok=true
            break
        fi
    done

    if [ "$internet_ok" = true ]; then
        # Internet is reachable - handle recovery logging for any prior outage
        if [ "$ROUTER_WAS_DOWN" = true ]; then
            recovery_time=$(date '+%Y-%m-%d %H:%M:%S')
            down_time_seconds=$(date -u -d "$LAST_ROUTER_DOWN_TIME" +%s)
            up_time_seconds=$(date -u -d "$recovery_time" +%s)
            duration_seconds=$((up_time_seconds - down_time_seconds))
            minutes=$((duration_seconds / 60))
            seconds=$((duration_seconds % 60))
            log_message "Router connectivity restored after ${minutes}m ${seconds}s of downtime"
            log_downtime "ROUTER_RESTORED" "${minutes}m ${seconds}s" "Router outage"
            ROUTER_WAS_DOWN=false
        fi
        if [ "$INTERNET_WAS_DOWN" = true ]; then
            recovery_time=$(date '+%Y-%m-%d %H:%M:%S')
            down_time_seconds=$(date -u -d "$LAST_INTERNET_DOWN_TIME" +%s)
            up_time_seconds=$(date -u -d "$recovery_time" +%s)
            duration_seconds=$((up_time_seconds - down_time_seconds))
            minutes=$((duration_seconds / 60))
            seconds=$((duration_seconds % 60))
            log_message "Internet connectivity restored after ${minutes}m ${seconds}s of downtime"
            log_downtime "CONNECTION_RESTORED" "${minutes}m ${seconds}s" "Internet-only outage (router was reachable)"
            INTERNET_WAS_DOWN=false
            DOWNTIME_ALREADY_LOGGED=true
        fi
        INTERNET_FAILURES=0
        return 0  # Internet reachable - all good
    fi

    # Internet not reachable - check router to distinguish Wi-Fi failure from ISP issue
    if ! ping -s "$PING_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ROUTER_IP" >/dev/null 2>&1; then
        # Neither internet nor router reachable - likely Wi-Fi is down
        if [ "$ROUTER_WAS_DOWN" = false ]; then
            ROUTER_WAS_DOWN=true
            LAST_ROUTER_DOWN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
            log_message "Cannot reach router at $ROUTER_IP"
        fi
        return 1
    else
        # Router reachable but no internet - ISP issue, don't restart Wi-Fi
        if [ "$INTERNET_WAS_DOWN" = false ]; then
            LAST_INTERNET_DOWN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
            INTERNET_WAS_DOWN=true
        fi

        log_message "Can reach router but cannot reach internet (none of: ${DNS_CHECK_HOSTS[*]} responded)"
        INTERNET_FAILURES=$((INTERNET_FAILURES + 1))

        # Send one SMS alert when the threshold is first crossed; keep counting so
        # the recovery log reflects the true failure count. Counter resets in the
        # return-0 branch above when internet comes back.
        if [ "$INTERNET_FAILURES" -eq "$SMS_INTERNET_FAILURE_THRESHOLD" ]; then
            send_sms "[ALERT] Pi-hole has no internet despite router access. ${INTERNET_FAILURES} consecutive failures (~$((INTERNET_FAILURES * RETRY_DELAY / 60))min)."
        fi

        return 2
    fi
}

# Function to restart network interface (link bounce only - dhcpcd manages DHCP)
restart_interface() {
    log_message "Attempting to restart $INTERFACE..."

    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_message "ERROR: Interface $INTERFACE does not exist"
        return 1
    fi

    # Bring interface down - dhcpcd detects carrier loss and cleans up IP/routes automatically
    log_message "Bringing interface down"
    ip link set $INTERFACE down || {
        log_message "ERROR: Failed to bring interface down"
        return 1
    }
    sleep 2

    # Restore hardware MAC address before bringing interface up.
    # Prevents MAC randomization from causing DHCP failures (router rejects unknown MACs).
    if command -v ethtool >/dev/null; then
        HARDWARE_MAC=$(ethtool -P "$INTERFACE" 2>/dev/null | awk '{print $3}')
        if [ -n "$HARDWARE_MAC" ]; then
            log_message "Restoring hardware MAC address: $HARDWARE_MAC"
            ip link set "$INTERFACE" address "$HARDWARE_MAC" 2>/dev/null || \
                log_message "WARNING: Could not restore hardware MAC address"
        else
            log_message "WARNING: Could not retrieve hardware MAC address from ethtool"
        fi
    else
        log_message "WARNING: ethtool not available, skipping MAC restoration (random MAC may cause DHCP failure)"
    fi

    # Bring interface up - dhcpcd will detect carrier and re-acquire the lease automatically
    log_message "Bringing interface up"
    ip link set $INTERFACE up || {
        log_message "ERROR: Failed to bring interface up"
        return 1
    }

    # Disable Wi-Fi power save - brcmfmac re-enables it on every link-up and it can
    # cause intermittent ping drops that trigger false reconnection cycles
    iw dev "$INTERFACE" set power_save off 2>/dev/null && \
        log_message "Wi-Fi power save disabled" || \
        log_message "WARNING: Could not disable Wi-Fi power save (iw not available?)"

    sleep 10  # Give dhcpcd time to re-acquire address

    # Verify we have an IP
    if ! ip addr show dev "$INTERFACE" | grep -q 'inet '; then
        log_message "WARNING: No IP address assigned to $INTERFACE after restart"
        return 1
    else
        log_message "IP address successfully assigned to $INTERFACE"
        return 0
    fi
}

# Run self-test to check environment
self_test() {
    log_message "Running self-test..."
    
    # Test lock file creation
    if ! touch "$LOCK_FILE" 2>/dev/null; then
        log_message "ERROR: Cannot create lock file at $LOCK_FILE. Check /tmp permissions."
        return 1
    fi
    
    # Test network interface
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_message "WARNING: Network interface '$INTERFACE' not found. Script may not work correctly."
        log_message "Available interfaces:"
        ip link show | grep -E '^[0-9]+:' | cut -d' ' -f2 | tr -d ':' | while read -r iface; do
            log_message " - $iface"
        done
    fi
    
    # Test DHCP client availability (dhcpcd is required; script no longer uses dhclient)
    if ! command -v dhcpcd >/dev/null; then
        log_message "WARNING: dhcpcd not found. Network restart may not re-acquire an IP automatically."
    fi
    
    # Test router reachability 
    if ! ping -s "$PING_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ROUTER_IP" >/dev/null 2>&1; then
        log_message "WARNING: Cannot reach router at $ROUTER_IP. Please verify router IP address."
    fi
    
    log_message "Self-test complete."
    return 0
}

# Cleanup runs once, always through the EXIT trap.
# Signal traps just call exit with the correct code, which fires EXIT.
# This prevents double-cleanup (the old pattern ran cleanup in the signal trap
# and then again via EXIT, causing duplicate log lines and flock errors).
cleanup() {
    log_message "Script stopped. Ensuring interface is up..."
    log_heartbeat "STOPPED" "Script terminated"
    ip link set $INTERFACE up 2>/dev/null || true

    # Clean up temp files
    rm -f /tmp/sms_queue.txt || true

    # Release lock first, then remove the file
    flock -u 200 || true
    exec 200>&- || true
    rm -f "$LOCK_FILE" || true
}

on_exit() {
    local ec=$?
    echo "$(date) - Script stopped. Exit code: $ec" > /tmp/reconnect_router_debug
    cleanup
    exit "$ec"
}

trap on_exit EXIT
trap 'exit 143' SIGTERM   # 128 + 15
trap 'exit 130' SIGINT    # 128 + 2
trap 'exit 129' SIGHUP    # 128 + 1

# Run self-test
self_test || log_message "WARNING: Self-test reported issues, but continuing execution"

# Main loop
connection_was_down=false
consecutive_failures=0
last_heartbeat_check=$(date +%s)
saved_down_time=""  # NEW: Save the exact down time to use for recovery

log_message "Network monitoring started for interface $INTERFACE"
log_heartbeat "STARTED" "Monitoring initialization"

# Only send startup SMS if not suppressed due to recent restart - NEW
if [ "$SUPPRESS_START_NOTIFICATION" != "true" ]; then
    send_sms "[START] Pi-hole network monitoring started on $HOSTNAME"
    log_message "Sent startup notification"
else
    log_message "Startup notification suppressed due to recent restart"
fi

while true; do
    # Process heartbeat if needed
    current_time=$(date +%s)
    if [ "$((current_time - last_heartbeat_check))" -ge 60 ]; then  # Check every minute
        # Process heartbeat first, then update the check time
        # This prevents missed heartbeats from being reset too early
        process_heartbeat
        last_heartbeat_check=$current_time
    fi
    
    # Reset downtime flag at the start of each loop iteration
    DOWNTIME_ALREADY_LOGGED=false
    
    # Check connection with enhanced return code handling
    check_connection
    connection_code=$?
    
    if [ $connection_code -eq 1 ]; then  # Cannot reach router
        ((consecutive_failures++))
        
        # Cap consecutive_failures to avoid unbounded backoff
        if [ "$consecutive_failures" -gt 10 ]; then
            consecutive_failures=10
        fi

        # Only trigger reconnection after $ROUTER_FAILURE_THRESHOLD consecutive failures
        if [ "$consecutive_failures" -ge "$ROUTER_FAILURE_THRESHOLD" ]; then
            if [ "$connection_was_down" = false ]; then
                # FIXED: Ensure we capture the exact time the connection went down
                # for proper downtime calculation later
                saved_down_time=$(date '+%Y-%m-%d %H:%M:%S')
                log_message "Network connectivity lost at $saved_down_time"
                log_downtime "CONNECTION_LOST" "N/A" "Starting recovery attempts"
                
                # Queue the alert message even though we can't send it now
                # It will be sent once connection is restored
                send_sms "[ALERT] Pi-hole Disconnected at $saved_down_time"
                connection_was_down=true
            fi

            # Try multiple times to reconnect using a graduated recovery ladder:
            #   attempts 1-3:  wpa_cli reconnect (soft, no disruption)
            #   attempts 4-7:  link bounce        (dhcpcd handles DHCP)
            #   attempts 8+:   restart dhcpcd     (nuclear option)
            reconnect_success=false
            for ((i=1; i<=MAX_RETRIES; i++)); do
                log_message "Reconnection attempt $i of $MAX_RETRIES"

                # Queue notification for every 3rd attempt to reduce message volume
                if (( i % 3 == 0 )); then
                    send_sms "[TRYING] Pi-hole reconnection attempt $i of $MAX_RETRIES"
                fi

                if [ "$i" -le 3 ]; then
                    log_message "Recovery level 1: soft wpa_cli reconnect"
                    wpa_cli -i "$INTERFACE" reconnect 2>/dev/null || true
                    sleep 10
                elif [ "$i" -le 7 ]; then
                    log_message "Recovery level 2: link bounce (dhcpcd manages DHCP)"
                    restart_interface
                else
                    log_message "Recovery level 3: restarting dhcpcd service"
                    systemctl restart dhcpcd 2>/dev/null || \
                        log_message "WARNING: Failed to restart dhcpcd"
                    sleep 15
                fi

                # Check connection again after restart attempt
                check_connection
                current_code=$?
                
                # If we can reach router (even if we can't reach internet), consider it a partial success
                if [ "$current_code" -eq 0 ] || [ "$current_code" -eq 2 ]; then
                    up_time=$(date '+%Y-%m-%d %H:%M:%S')
                    
                    # FIXED: Use saved_down_time for accurate downtime calculation
                    down_time_seconds=$(date -u -d "$saved_down_time" +%s)
                    up_time_seconds=$(date -u -d "$up_time" +%s)
                    downtime_seconds=$((up_time_seconds - down_time_seconds))
                    downtime_minutes=$((downtime_seconds / 60))
                    downtime_seconds=$((downtime_seconds % 60))
                    downtime_str="${downtime_minutes}m ${downtime_seconds}s"
                    
                    # Shorter message format to fit within SMS 160 character limit
                    recovery_message="[OK] Pi-hole Online! Down: ${downtime_minutes}m${downtime_seconds}s. ${i}/${MAX_RETRIES} attempts"
                    
                    # Only log downtime if it hasn't already been logged by check_connection
                    if [ "$DOWNTIME_ALREADY_LOGGED" = false ]; then
                        log_downtime "CONNECTION_RESTORED" "$downtime_str" "$i attempts needed"
                    fi
                    
                    send_sms "$recovery_message"
                    connection_was_down=false
                    consecutive_failures=0
                    reconnect_success=true
                    break
                else
                    if [ $i -eq $MAX_RETRIES ]; then
                        log_message "Failed to restore connection after $MAX_RETRIES attempts"
                    else
                        log_message "Reconnection attempt failed, waiting $RETRY_DELAY seconds"
                        sleep $RETRY_DELAY
                    fi
                fi
            done

            # If all reconnection attempts failed
            if [ "$reconnect_success" = false ]; then
                timeout_time=$(date '+%Y-%m-%d %H:%M:%S')
                total_time_str=$(date -d "$timeout_time" +%s)
                start_time_str=$(date -d "$saved_down_time" +%s)  # FIXED: Use saved_down_time
                time_diff=$((total_time_str - start_time_str))
                minutes=$((time_diff / 60))
                seconds=$((time_diff % 60))
                downtime_str="${minutes}m ${seconds}s"

                timeout_message="[CRITICAL] Pi-hole still down since $saved_down_time. Total: ${downtime_str}. ${MAX_RETRIES} attempts failed."

                log_message "Failed to restore connection after $MAX_RETRIES attempts"
                log_message "Total downtime so far: $downtime_str"
                log_downtime "RECOVERY_FAILED" "$downtime_str" "All $MAX_RETRIES attempts failed"
                send_sms "$timeout_message"

                # Reset consecutive failures to trigger a new cycle after delay
                consecutive_failures=1
            fi
        fi
    elif [ $connection_code -eq 2 ]; then  # Can reach router but not internet
        # Internet-only failure: router is reachable so Wi-Fi is fine.
        # Bouncing the interface can't fix an ISP or upstream issue.
        # Just log and let check_connection() handle SMS after SMS_INTERNET_FAILURE_THRESHOLD.
        # consecutive_failures is intentionally NOT incremented here — that counter is for
        # router-level failures that warrant reconnection attempts.
        log_message "Can reach router but not internet — waiting for upstream to recover"
    else
        consecutive_failures=0
    fi

    # Calculate delay using exponential backoff with a ceiling
    if [ "$consecutive_failures" -gt 5 ]; then
        # Calculate backoff delay (2^n)
        backoff=$((RETRY_DELAY * (2 ** (consecutive_failures - 5))))
        
        # Cap the backoff at 10 minutes (600 seconds)
        if [ "$backoff" -gt 600 ]; then
            backoff=600
        fi
        
        log_message "Using exponential backoff: ${backoff}s delay"
        sleep $backoff
    else
        sleep $RETRY_DELAY
    fi
done