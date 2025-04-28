#!/bin/bash
set -Eu  # Exit on error, ensure ERR traps are inherited, error on unset variables

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
SMS_INTERNET_FAILURE_THRESHOLD=10  # Number of consecutive internet failures before SMS alert (10 ~ 3Min; 20 ~ 9min)

# Added flag to prevent duplicate restoration logs
DOWNTIME_ALREADY_LOGGED=false

# SMS Configuration
PHONE_NUMBER="1234567890"  # Replace with your phone number
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
INTERNET_FAILURES=0
MAX_INTERNET_FAILURES=5

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

# Check for startup frequency - NEW
STARTUP_CHECK_FILE="/tmp/reconnect_router_last_start"
STARTUP_THRESHOLD=300  # 5 minutes

if [ -f "$STARTUP_CHECK_FILE" ]; then
    last_start=$(cat "$STARTUP_CHECK_FILE" 2>/dev/null || echo "0")
    current_time=$(date +%s)
    elapsed=$((current_time - last_start))
    
    if [ $elapsed -lt $STARTUP_THRESHOLD ]; then
        log_message "Script restarted within $elapsed seconds - suppressing start notification"
        SUPPRESS_START_NOTIFICATION=true
    else
        SUPPRESS_START_NOTIFICATION=false
    fi
else
    SUPPRESS_START_NOTIFICATION=false
fi

# Update startup time
date +%s > "$STARTUP_CHECK_FILE"

# Check for required dependencies
for cmd in mail iconv ip ping; do
    if ! command -v $cmd >/dev/null; then
        echo "ERROR: Required command '$cmd' not found. Please install the necessary package."
        exit 1
    fi
done

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

# Create lock file with PID - NEW
# echo $$ > "$LOCK_FILE" edit by GPT to stop racing

# Ensure log files and directories exist with fallback to /tmp
for LOG in "$LOG_FILE" "$DOWNTIME_LOG" "$HEARTBEAT_LOG"; do
    # Create directory if needed
    if [ ! -d "$(dirname "$LOG")" ]; then
        if ! sudo mkdir -p "$(dirname "$LOG")" 2>/dev/null; then
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
        if ! sudo touch "$LOG" 2>/dev/null || ! sudo chown "$(whoami)" "$LOG" 2>/dev/null; then
            log_message "WARNING: Could not create or set permissions for $LOG"
        else
            # Set explicit permissions
            sudo chmod 644 "$LOG" 2>/dev/null || true
        fi
    fi
    
    # Now make sure we can write to it
    if ! touch "$LOG" 2>/dev/null; then
        log_message "ERROR: Cannot write to log file $LOG. Check permissions."
    fi
    
    # Add log rotation check
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -ge 10485760 ]; then
        log_message "Log file $LOG has grown too large, rotating"
        sudo mv "$LOG" "$LOG.$(date '+%Y%m%d%H%M%S')" 2>/dev/null || true
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
    # Reset the downtime logging flag at the start of each check
    DOWNTIME_ALREADY_LOGGED=false
    
    # First check basic network connectivity to router
    if ! ping -s "$PING_SIZE" -c $PING_COUNT -W $PING_TIMEOUT $ROUTER_IP >/dev/null 2>&1; then
		if [ "$ROUTER_WAS_DOWN" = false ]; then
			ROUTER_WAS_DOWN=true
			LAST_ROUTER_DOWN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
		fi
		log_message "Cannot reach router at $ROUTER_IP"
		return 1
	else
		if [ "$ROUTER_WAS_DOWN" = true ]; then
			recovery_time=$(date '+%Y-%m-%d %H:%M:%S')
			down_time_seconds=$(date -u -d "$LAST_ROUTER_DOWN_TIME" +%s)
			up_time_seconds=$(date -u -d "$recovery_time" +%s)
			duration_seconds=$((up_time_seconds - down_time_seconds))
			minutes=$((duration_seconds / 60))
			seconds=$((duration_seconds % 60))
			duration_str="${minutes}m ${seconds}s"

			log_message "Router connectivity restored after $duration_str of downtime"
			log_downtime "ROUTER_RESTORED" "$duration_str" "Router outage"
			ROUTER_WAS_DOWN=false
		fi
	fi


    # Then check if we can reach an upstream DNS server directly
    internet_ok=false
    for host in "${DNS_CHECK_HOSTS[@]}"; do
        if ping -s "$PING_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1; then
            internet_ok=true
            break
        fi
    done

    if [ "$internet_ok" = false ]; then
        # Internet was previously up but now it's down - mark the time
        if [ "$INTERNET_WAS_DOWN" = false ]; then
            LAST_INTERNET_DOWN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
            INTERNET_WAS_DOWN=true
        fi
        
        log_message "Can reach router but cannot reach internet (none of: ${DNS_CHECK_HOSTS[*]} responded)"
        ((INTERNET_FAILURES++))

        if [ "$INTERNET_FAILURES" -ge "$MAX_INTERNET_FAILURES" ]; then
			log_message "Internet unreachable for $MAX_INTERNET_FAILURES attempts — backing off temporarily"
    
			if [ "$INTERNET_FAILURES" -ge "$SMS_INTERNET_FAILURE_THRESHOLD" ]; then
				send_sms "[ALERT] Pi-hole has no internet despite router access. $INTERNET_FAILURES consecutive failures."
			fi

			sleep $((RETRY_DELAY * 5))
			INTERNET_FAILURES=0
		fi

        return 2
    else
        # Internet is back up - log recovery if it was previously down
        if [ "$INTERNET_WAS_DOWN" = true ]; then
            recovery_time=$(date '+%Y-%m-%d %H:%M:%S')
            # Calculate duration between LAST_INTERNET_DOWN_TIME and now
            down_time_seconds=$(date -u -d "$LAST_INTERNET_DOWN_TIME" +%s)
            up_time_seconds=$(date -u -d "$recovery_time" +%s)
            duration_seconds=$((up_time_seconds - down_time_seconds))
            minutes=$((duration_seconds / 60))
            seconds=$((duration_seconds % 60))
            duration_str="${minutes}m ${seconds}s"
            
            log_message "Internet connectivity restored after $duration_str of downtime"
            log_downtime "CONNECTION_RESTORED" "$duration_str" "Internet-only outage (router was reachable)"
            INTERNET_WAS_DOWN=false
            # Set the flag to indicate we've already logged a restoration
            DOWNTIME_ALREADY_LOGGED=true
        fi
        INTERNET_FAILURES=0
    fi

    return 0  # Success - can reach both router and internet
}

# Function to restart network interface
restart_interface() {
    log_message "Attempting to restart $INTERFACE..."
    
    # Check if interface exists
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_message "ERROR: Interface $INTERFACE does not exist"
        return 1
    fi

    # Kill any hanging DHCP client processes
    sudo pkill dhclient 2>/dev/null || true
    sleep 1

    # Detect DHCP client type
    DHCP_CLIENT=""
    if command -v dhclient >/dev/null; then
        DHCP_CLIENT="dhclient"
    elif command -v dhcpcd >/dev/null; then
        DHCP_CLIENT="dhcpcd"
    else
        log_message "WARNING: No DHCP client found."
    fi

    # Release DHCP lease based on client type
    if [ "$DHCP_CLIENT" = "dhclient" ]; then
        log_message "Releasing DHCP lease with dhclient"
        sudo dhclient -v -r $INTERFACE 2>/dev/null || true
    elif [ "$DHCP_CLIENT" = "dhcpcd" ]; then
        log_message "Releasing DHCP lease with dhcpcd"
        sudo dhcpcd -k $INTERFACE 2>/dev/null || true
    fi
    sleep 2

    # Bring interface down
    log_message "Bringing interface down"
    sudo ip link set $INTERFACE down || {
        log_message "ERROR: Failed to bring interface down"
        return 1
    }
    sleep 2

    # Clear IP address
    log_message "Flushing IP address"
    if ip link show "$INTERFACE" | grep -q 'UP'; then
        sudo ip addr flush dev $INTERFACE || {
            log_message "ERROR: Failed to flush IP address"
        }
    else
        log_message "Interface is down, skipping IP address flush"
    fi

    # Bring interface up
    log_message "Bringing interface up"
    sudo ip link set $INTERFACE up || {
        log_message "ERROR: Failed to bring interface up"
        return 1
    }
    sleep 5

    # Get new IP address based on client type
    if [ "$DHCP_CLIENT" = "dhclient" ]; then
        log_message "Requesting new IP with dhclient"
        sudo dhclient -v $INTERFACE || {
            log_message "ERROR: dhclient failed to get IP"
        }
    elif [ "$DHCP_CLIENT" = "dhcpcd" ]; then
        log_message "Requesting new IP with dhcpcd"
        sudo dhcpcd $INTERFACE || {
            log_message "ERROR: dhcpcd failed to get IP"
        }
    else
        log_message "No DHCP client available. Waiting for system to assign IP."
        # Some systems will automatically assign an IP when the interface comes up
        sleep 10
    fi

    # Wait for interface to stabilize
    sleep 5
    
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
    
    # Test DHCP client availability
    if ! command -v dhclient >/dev/null && ! command -v dhcpcd >/dev/null; then
        log_message "WARNING: No DHCP client (dhclient or dhcpcd) found. Network restart may fail."
    fi
    
    # Test router reachability 
    if ! ping -s "$PING_SIZE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$ROUTER_IP" >/dev/null 2>&1; then
        log_message "WARNING: Cannot reach router at $ROUTER_IP. Please verify router IP address."
    fi
    
    log_message "Self-test complete."
    return 0
}

# Trap script termination - ENHANCED CLEANUP
cleanup() {
    log_message "Script stopped. Ensuring interface is up..."
    log_heartbeat "STOPPED" "Script terminated"
    sudo ip link set $INTERFACE up 2>/dev/null || true

    # Clean up temp files
    rm -f /tmp/sms_queue.txt || true
    
    # Release and remove the lock file
    rm -f "$LOCK_FILE" || true
    flock -u 200 || true
    exec 200>&- || true
    
    exit 0
}
trap 'EXIT_CODE=$?; echo "$(date) - Script stopped. Exit code: $EXIT_CODE" > /tmp/reconnect_router_debug; echo "$(date +"%Y-%m-%d %H:%M:%S") - Normal termination" > /tmp/reconnect_router_clean_exit; cleanup' EXIT
trap cleanup SIGTERM SIGINT SIGHUP

# Run self-test
self_test || log_message "WARNING: Self-test reported issues, but continuing execution"

# Main loop
connection_was_down=false
consecutive_failures=0
last_heartbeat_check=$(date +%s)

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

        # Only trigger reconnection after 2 consecutive failures
        if [ "$consecutive_failures" -ge 2 ]; then
            if [ "$connection_was_down" = false ]; then
                down_time=$(date '+%Y-%m-%d %H:%M:%S')
                log_message "Network connectivity lost at $down_time"
                log_downtime "CONNECTION_LOST" "N/A" "Starting recovery attempts"
                
                # Queue the alert message even though we can't send it now
                # It will be sent once connection is restored
                send_sms "[ALERT] Pi-hole Disconnected at $down_time"
                connection_was_down=true
            fi

            # Try multiple times to reconnect
            reconnect_success=false
            for ((i=1; i<=MAX_RETRIES; i++)); do
                log_message "Reconnection attempt $i of $MAX_RETRIES"

                # Queue notification for every 3rd attempt to reduce message volume
                if (( i % 3 == 0 )); then
                    send_sms "[TRYING] Pi-hole reconnection attempt $i of $MAX_RETRIES"
                fi

                restart_interface

                # Check connection again after restart attempt
                check_connection
                current_code=$?
                
                # If we can reach router (even if we can't reach internet), consider it a partial success
                if [ "$current_code" -eq 0 ] || [ "$current_code" -eq 2 ]; then
                    up_time=$(date '+%Y-%m-%d %H:%M:%S')
                    
                    # Calculate downtime
                    down_time_seconds=$(date -u -d "$down_time" +%s)
                    up_time_seconds=$(date -d "$up_time" +%s)
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
                start_time_str=$(date -d "$down_time" +%s)
                time_diff=$((total_time_str - start_time_str))
                minutes=$((time_diff / 60))
                seconds=$((time_diff % 60))
                downtime_str="${minutes}m ${seconds}s"

                timeout_message="[CRITICAL] Pi-hole recovery failed!
- Down since: $down_time
- Current time: $timeout_time
- Total downtime: $downtime_str
- All $MAX_RETRIES attempts failed
Manual intervention required!"

                log_message "Failed to restore connection after $MAX_RETRIES attempts"
                log_message "Total downtime so far: $downtime_str"
                log_downtime "RECOVERY_FAILED" "$downtime_str" "All $MAX_RETRIES attempts failed"
                send_sms "$timeout_message"

                # Reset consecutive failures to trigger a new cycle after delay
                consecutive_failures=1
            fi
        fi
    elif [ $connection_code -eq 2 ]; then  # Can reach router but not internet
        # Increment failure count but with a lower weight
        consecutive_failures=$((consecutive_failures + 1))
        
        # For internet-only failures, we don't need to do a full network restart
        # Just log and wait - no exit needed
        log_message "Can reach router but not internet. Attempt $consecutive_failures - waiting to retry"
        
        # If this persists for multiple cycles, try a network restart
        if [ $consecutive_failures -gt 5 ] && [ $((consecutive_failures % 5)) -eq 0 ]; then
			log_message "Persistent internet connectivity issues - attempting network restart"

			restart_ok=true

			if [ -f "$RESTART_TIME_FILE" ]; then
					last_restart=$(cat "$RESTART_TIME_FILE" 2>/dev/null || echo "0")
					now=$(date +%s)
				if (( now - last_restart < RESTART_INTERVAL )); then
					log_message "... suppressed ..."
					restart_ok=false
					sleep $RETRY_DELAY
				fi
			fi

			if $restart_ok; then
				date +%s > "$RESTART_TIME_FILE"
				restart_interface
			fi
		fi
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