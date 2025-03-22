#!/bin/bash

# Force UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Configuration
ROUTER_IP="192.168.1.1" # Default value - should match user's router config
INTERFACE="wlan0"
LOG_FILE="/var/log/router_reconnect.log"
DOWNTIME_LOG="/var/log/router_downtime.log" # New: dedicated log for tracking downtime events
MAX_RETRIES=10
RETRY_DELAY=15
PING_COUNT=2
PING_TIMEOUT=3

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

# Check for mail command availability
if ! command -v mail >/dev/null; then
    echo "mail command not found — SMS notifications will not work"
    echo "Please install mailutils or equivalent package"
    exit 1
fi

# Create a lock file to prevent multiple instances
LOCK_FILE="/tmp/reconnect_router.lock"
exec 200>$LOCK_FILE

if ! flock -n 200; then
    echo "Script is already running. Exiting."
    exit 1
fi

# Ensure log files and directories exist
for LOG in "$LOG_FILE" "$DOWNTIME_LOG" "$HEARTBEAT_LOG"; do
    # Create directory if needed (without using flock yet since file might not exist)
    if [ ! -d "$(dirname $LOG)" ]; then
        sudo mkdir -p "$(dirname $LOG)"
    fi
    
    # Touch the file if it doesn't exist
    if [ ! -f "$LOG" ]; then
        sudo touch "$LOG"
        sudo chown "$(whoami)" "$LOG"
    fi
    
    # Now we can safely flock on the existing file
    flock "$LOG" -c "echo 'Log file ready: $LOG'" > /dev/null 2>&1
done

# Ensure heartbeat is initialized on startup
if [ "$HEARTBEAT_ENABLED" = true ] && [ ! -f "$HEARTBEAT_FILE" ]; then
    echo "$(date +%s)" > "$HEARTBEAT_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | HEARTBEAT | INITIALIZED | Startup initialization" >> "$HEARTBEAT_LOG"
fi

# Function to log messages
log_message() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $1" >> "$LOG_FILE"
    echo "$timestamp - $1"
}

# Function to log downtime events
log_downtime() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local event="$1"
    local duration="$2"
    
    # Format: TIMESTAMP | EVENT | DURATION | ADDITIONAL_INFO
    echo "$timestamp | $event | $duration | $3" >> "$DOWNTIME_LOG"
    
    # Also log to main log (can be commented out to reduce redundancy if desired)
    log_message "Downtime event: $event | $duration | $3"
}

# Function to log heartbeat events
log_heartbeat() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local event="$1"
    
    # Format: TIMESTAMP | EVENT | STATUS | ADDITIONAL_INFO
    echo "$timestamp | HEARTBEAT | $event | $2" >> "$HEARTBEAT_LOG"
}

# Enhanced SMS function with better message queuing and retry logic
send_sms() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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
    if ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; then
        # Internet is available

        # If we have queued messages, process them intelligently
        if [ -f "$queue_file" ]; then
            log_message "Processing queued messages"

            # Extract the last message of each important type
            declare -A latest_msgs
            
            while read line; do
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
        # Fix character encoding issues by converting to ASCII
        echo -e "$message" | iconv -f UTF-8 -t ASCII//TRANSLIT | mail -s "$EMAIL_SUBJECT" -a "Content-Type: text/plain; charset=UTF-8" "$SMS_EMAIL" 2>/dev/null
        if [ $? -eq 0 ]; then
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
    if [ "$HEARTBEAT_ENABLED" != true ]; then
        return
    fi
    
    local current_time=$(date +%s)
    
    # Create heartbeat file if it doesn't exist
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "$current_time" > "$HEARTBEAT_FILE"
        log_heartbeat "INITIALIZED" "First run"
        # Removed initial heartbeat SMS - we'll only send alerts, not status messages
        return
    fi
    
    # Read last heartbeat time
    local last_heartbeat=$(cat "$HEARTBEAT_FILE")
    local elapsed_time=$((current_time - last_heartbeat))
    
    # Check if we should update the heartbeat
    if [ $elapsed_time -ge $HEARTBEAT_INTERVAL ]; then
        # Check if we missed too many heartbeats
        if [ $elapsed_time -ge $((HEARTBEAT_INTERVAL * MISSED_HEARTBEATS_THRESHOLD)) ]; then
            # We missed several heartbeats - might have been down
            local down_time=$(date -d "@$last_heartbeat" '+%Y-%m-%d %H:%M:%S')
            local current_time_str=$(date '+%Y-%m-%d %H:%M:%S')
            local hours=$((elapsed_time / 3600))
            local minutes=$(( (elapsed_time % 3600) / 60 ))
            local seconds=$((elapsed_time % 60))
            local downtime_str="${hours}h ${minutes}m ${seconds}s"
            
            log_heartbeat "MISSED" "$downtime_str (${elapsed_time}s)"
            log_downtime "SCRIPT_INTERRUPTED" "$downtime_str" "Detected via missed heartbeats"
            
            send_sms "[ALERT] Pi-hole monitoring resumed after inactivity
Last seen: $down_time
Current: $current_time_str
Downtime: ${hours}h ${minutes}m ${seconds}s"
        else
            # Normal heartbeat - log but don't send SMS
            log_heartbeat "NORMAL" "${elapsed_time}s since last heartbeat"
            # Removed SMS notification for normal heartbeats
        fi
        
        # Update heartbeat time
        echo "$current_time" > "$HEARTBEAT_FILE"
    fi
}

# Function to check network connectivity
check_connection() {
    # First check basic network connectivity to router
    if ! ping -c $PING_COUNT -W $PING_TIMEOUT $ROUTER_IP >/dev/null 2>&1; then
        log_message "Cannot reach router at $ROUTER_IP"
        return 1
    fi

    # Then check if we can reach an upstream DNS server directly
    if ! ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        log_message "Can reach router but cannot reach internet (1.1.1.1)"
        ((INTERNET_FAILURES++))
        
        if [ $INTERNET_FAILURES -ge $MAX_INTERNET_FAILURES ]; then
            log_message "Internet unreachable for $MAX_INTERNET_FAILURES attempts — stopping retries temporarily"
            sleep $((RETRY_DELAY * 5)) # Back off more aggressively for internet issues
            INTERNET_FAILURES=0
        fi
        return 1
    else
        INTERNET_FAILURES=0
    fi

    return 0
}

# Function to restart network interface
restart_interface() {
    log_message "Attempting to restart $INTERFACE..."

    # Kill any hanging DHCP client processes
    sudo pkill dhclient
    sleep 1

    # Release DHCP lease with verbose output
    sudo dhclient -v -r $INTERFACE 2>/dev/null
    sleep 2

    # Bring interface down
    sudo ip link set $INTERFACE down
    sleep 2

    # Clear IP address
    sudo ip addr flush dev $INTERFACE

    # Bring interface up
    sudo ip link set $INTERFACE up
    sleep 5

    # Release and renew DHCP lease more explicitly with verbose output
    sudo dhclient -v -r $INTERFACE 2>/dev/null
    sleep 2
    sudo dhclient -v $INTERFACE

    # Wait for interface to stabilize
    sleep 5
}

# Trap script termination
cleanup() {
    log_message "Script stopped. Ensuring interface is up..."
    log_heartbeat "STOPPED" "Script terminated"
    sudo ip link set $INTERFACE up
    # Release the lock file
    flock -u 200
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP EXIT

# Main loop
connection_was_down=false
consecutive_failures=0
last_heartbeat_check=$(date +%s)

log_message "Network monitoring started for interface $INTERFACE"
log_heartbeat "STARTED" "Monitoring initialization"
send_sms "[START] Pi-hole network monitoring started on $HOSTNAME"

while true; do
    # Process heartbeat if needed
    current_time=$(date +%s)
    if [ $((current_time - last_heartbeat_check)) -ge 60 ]; then  # Check every minute
        process_heartbeat
        last_heartbeat_check=$current_time
    fi
    
    if ! check_connection; then
        ((consecutive_failures++))
        
        # Cap consecutive_failures to avoid unbounded backoff
        if [ $consecutive_failures -gt 10 ]; then
            consecutive_failures=10
        fi

        # Only trigger reconnection after 2 consecutive failures
        if [ $consecutive_failures -ge 2 ]; then
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

                if check_connection; then
                    up_time=$(date '+%Y-%m-%d %H:%M:%S')
                    
                    # Calculate downtime
                    down_time_seconds=$(date -d "$down_time" +%s)
                    up_time_seconds=$(date -d "$up_time" +%s)
                    downtime_seconds=$((up_time_seconds - down_time_seconds))
                    downtime_minutes=$((downtime_seconds / 60))
                    downtime_seconds=$((downtime_seconds % 60))
                    downtime_str="${downtime_minutes}m ${downtime_seconds}s"
                    
                    recovery_message="[OK] Pi-hole Back Online!
Down: $down_time
Up: $up_time
Downtime: $downtime_str
Attempts needed: $i of $MAX_RETRIES"
                    
                    # Use only log_downtime to prevent duplicate logging
                    log_downtime "CONNECTION_RESTORED" "$downtime_str" "$i attempts needed"
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
    else
        consecutive_failures=0
    fi

    # Calculate delay using exponential backoff with a ceiling
    if [ $consecutive_failures -gt 5 ]; then
        # Calculate backoff delay (2^n)
        backoff=$((RETRY_DELAY * (2 ** (consecutive_failures - 5))))
        
        # Cap the backoff at 10 minutes (600 seconds)
        if [ $backoff -gt 600 ]; then
            backoff=600
        fi
        
        log_message "Using exponential backoff: ${backoff}s delay"
        sleep $backoff
    else
        sleep $RETRY_DELAY
    fi
done