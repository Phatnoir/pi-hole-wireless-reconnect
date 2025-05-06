#!/bin/bash
#######################################
# RECONNECT_ROUTER.SH
# 
# This script monitors the network connection to a router and the internet.
# If the connection is lost, it attempts to restart the network interface
# and sends SMS notifications about the status.
#
# Features:
# - Router and internet connectivity monitoring
# - Automatic interface restart on connection loss
# - SMS notifications for connection events
# - Detailed logging of downtime and recovery
# - Heartbeat mechanism to detect script interruptions
#
# Security features:
# - Input validation for configuration variables
# - Secure file permission handling
# - Protection against command injection
# - Proper error trapping and handling
#######################################

# Strict error handling
set -Eu  # Exit on error, ensure ERR traps are inherited, error on unset variables

# Security: Ensure PATH is restricted to system directories
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Security: Ensure no user-controlled env vars affect commands
unset LD_LIBRARY_PATH LD_PRELOAD

#######################################
# CONFIGURATION VARIABLES
#######################################

# Character encoding settings
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Network Configuration
ROUTER_IP="192.168.1.1"        # IP address of the router to monitor
INTERFACE="wlan0"              # Network interface to monitor and restart if needed
MAX_RETRIES=10                 # Maximum reconnection attempts before giving up
RETRY_DELAY=15                 # Seconds to wait between reconnection attempts
PING_COUNT=2                   # Number of pings to send when checking connectivity
PING_TIMEOUT=3                 # Seconds to wait for ping response before timeout
PING_SIZE=32                   # Size of ping packet in bytes
RESTART_INTERVAL=180           # Minimum time (seconds) between interface restarts (3 minutes)

# Monitoring Configuration
# Using Cloudflare and Google DNS servers for redundant connectivity checks
DNS_CHECK_HOSTS=("1.1.1.1" "1.0.0.1")  # Cloudflare DNS for internet checks
SMS_INTERNET_CHECK="8.8.8.8"            # Google DNS for SMS delivery checks
MAX_INTERNET_FAILURES=5                 # Threshold for logging internet failures
SMS_INTERNET_FAILURE_THRESHOLD=10       # Threshold for SMS alerts about internet failures

# SMS Configuration - Edit these with your personal information
PHONE_NUMBER="1234567890"               # Replace with your phone number
CARRIER_GATEWAY="vtext.com"             # Carrier gateway (Verizon, AT&T: txt.att.net, T-Mobile: tmomail.net)
EMAIL_SUBJECT="Pi-hole Alert"           # Subject line for SMS notifications
HOSTNAME=$(hostname)                    # Local hostname for identifying the device in messages

# Construct email address after validating inputs
# Security: Validate inputs before concatenation
if [[ "$PHONE_NUMBER" =~ ^[0-9]+$ ]]; then
    SMS_EMAIL="${PHONE_NUMBER}@${CARRIER_GATEWAY}" # Email-to-SMS gateway address
else
    echo "ERROR: Phone number must contain only digits"
    exit 1
fi

# Heartbeat Configuration - For detecting script interruptions
HEARTBEAT_ENABLED=true                  # Set to false to disable heartbeat functionality
HEARTBEAT_INTERVAL=3600                 # Time between heartbeats in seconds (1 hour)
MISSED_HEARTBEATS_THRESHOLD=3           # Alert after this many missed heartbeats

# File Paths - Security: Use secure paths
readonly LOG_DIR="/var/log"
readonly TMP_DIR="/tmp"
readonly LOG_FILE="${LOG_DIR}/reconnect_router.log"
readonly DOWNTIME_LOG="${LOG_DIR}/router_downtime.log"
readonly HEARTBEAT_LOG="${LOG_DIR}/router_heartbeat.log"
readonly RESTART_TIME_FILE="${TMP_DIR}/reconnect_last_iface_restart"
readonly HEARTBEAT_FILE="${TMP_DIR}/pihole_last_heartbeat"
readonly LOCK_FILE="${TMP_DIR}/reconnect_router.lock"
readonly LAST_TERM_REASON_FILE="${TMP_DIR}/reconnect_router_last_term.log"
readonly STARTUP_CHECK_FILE="${TMP_DIR}/reconnect_router_last_start"
readonly SMS_QUEUE_FILE="${TMP_DIR}/sms_queue.txt"

# Status Tracking Variables
INTERNET_WAS_DOWN=false         # Flag to track if internet was previously down
ROUTER_WAS_DOWN=false           # Flag to track if router was previously down
LAST_INTERNET_DOWN_TIME=""      # Timestamp when internet connectivity was lost
INTERNET_FAILURES=0             # Counter for consecutive internet failures
DOWNTIME_ALREADY_LOGGED=false   # Flag to prevent duplicate logging of recovery
STARTUP_THRESHOLD=300           # 5 minute threshold for suppressing duplicate startup notifications

# Cache command paths and validate they exist - SECURITY: Use full paths
DATE_CMD=$(command -v date)        # Full path to date command
PING_CMD=$(command -v ping)        # Full path to ping command
IP_CMD=$(command -v ip)            # Full path to ip command
MAIL_CMD=$(command -v mail)        # Full path to mail command
CHMOD_CMD=$(command -v chmod)      # Full path to chmod command
CHOWN_CMD=$(command -v chown)      # Full path to chown command
SUDO_CMD=$(command -v sudo)        # Full path to sudo command

# Security: Validate required commands exist
for cmd in "$DATE_CMD" "$PING_CMD" "$IP_CMD" "$MAIL_CMD"; do
    if [ -z "$cmd" ] || [ ! -x "$cmd" ]; then
        echo "ERROR: Required command '${cmd##*/}' not found or not executable"
        exit 1
    fi
done

#######################################
# VALIDATION FUNCTIONS
#######################################

# validate_ipv4: Validate IPv4 address format
# Arguments:
#   $1 - IP address to validate
# Returns:
#   0 if valid, 1 if invalid
validate_ipv4() {
    local ip="$1"
    local stat=1
    
    # Regex pattern for IP validation
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a ip_segments <<< "$ip"
        [[ ${ip_segments[0]} -le 255 && ${ip_segments[1]} -le 255 \
            && ${ip_segments[2]} -le 255 && ${ip_segments[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

# validate_interface: Check if interface exists
# Arguments:
#   $1 - Interface name to validate
# Returns:
#   0 if valid, 1 if invalid
validate_interface() {
    local iface="$1"
    $IP_CMD link show "$iface" >/dev/null 2>&1
    return $?
}

# validate_integer: Check if value is a positive integer
# Arguments:
#   $1 - Value to validate
# Returns:
#   0 if valid, 1 if invalid
validate_integer() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 0 ]
    return $?
}

# validate_directory: Check if directory exists and is writable
# Arguments:
#   $1 - Directory path to validate
# Returns:
#   0 if valid, 1 if invalid
validate_directory() {
    local dir="$1"
    [ -d "$dir" ] && [ -w "$dir" ]
    return $?
}

# security_check: Perform initial security validation
# Description:
#   Validates configuration settings for security concerns
security_check() {
    local errors=0
    
    # Validate IP addresses
    if ! validate_ipv4 "$ROUTER_IP"; then
        echo "ERROR: Invalid router IP address: $ROUTER_IP"
        ((errors++))
    fi
    
    for dns in "${DNS_CHECK_HOSTS[@]}"; do
        if ! validate_ipv4 "$dns"; then
            echo "ERROR: Invalid DNS server IP address: $dns"
            ((errors++))
        fi
    done
    
    if ! validate_ipv4 "$SMS_INTERNET_CHECK"; then
        echo "ERROR: Invalid SMS internet check IP address: $SMS_INTERNET_CHECK"
        ((errors++))
    fi
    
    # Validate network interface
    if ! validate_interface "$INTERFACE"; then
        echo "WARNING: Network interface '$INTERFACE' not found"
        ((errors++))
    fi
    
    # Validate numeric parameters
    for param in MAX_RETRIES RETRY_DELAY PING_COUNT PING_TIMEOUT PING_SIZE RESTART_INTERVAL \
                 MAX_INTERNET_FAILURES SMS_INTERNET_FAILURE_THRESHOLD HEARTBEAT_INTERVAL \
                 MISSED_HEARTBEATS_THRESHOLD STARTUP_THRESHOLD; do
        if ! validate_integer "${!param}"; then
            echo "ERROR: Invalid value for $param: ${!param}"
            ((errors++))
        fi
    done
    
    # Validate directories
    if ! validate_directory "$(dirname "$LOG_FILE")"; then
        echo "WARNING: Log directory $(dirname "$LOG_FILE") does not exist or is not writable"
        ((errors++))
    fi
    
    if ! validate_directory "$TMP_DIR"; then
        echo "ERROR: Temporary directory $TMP_DIR does not exist or is not writable"
        ((errors++))
    fi
    
    # Validate SMS configuration
    if [[ ! "$PHONE_NUMBER" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Invalid phone number format. Must be digits only: $PHONE_NUMBER"
        ((errors++))
    fi
    
    if [[ -z "$CARRIER_GATEWAY" ]]; then
        echo "ERROR: Empty carrier gateway"
        ((errors++))
    fi
    
    # Check temporary directory permissions
    if [ "$(stat -c %a "$TMP_DIR")" != "1777" ]; then
        echo "WARNING: $TMP_DIR permissions are not 1777 (drwxrwxrwt)"
        ((errors++))
    fi
    
    # Return status based on number of errors
    [ $errors -eq 0 ] && return 0 || return 1
}

#######################################
# LOGGING FUNCTIONS
#######################################

# secure_log_message: Log a message with sanitized input
# Arguments:
#   $1 - The message to log
# Outputs:
#   Writes timestamp and message to log file and stdout
# Security:
#   - Ensures directory permissions
#   - Sanitizes input
#   - Fails gracefully
secure_log_message() {
    # Security: Sanitize input by removing control characters
    local message
    message=$(echo "$1" | tr -d '[:cntrl:]')
    
    local timestamp
    timestamp=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
    
    # Ensure log directory exists with proper permissions
    if [ ! -d "$(dirname "$LOG_FILE")" ]; then
        if [ -w "$(dirname "$(dirname "$LOG_FILE")")" ]; then
            $SUDO_CMD mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
            $SUDO_CMD "$CHMOD_CMD" 755 "$(dirname "$LOG_FILE")" 2>/dev/null
        fi
    fi
    
    # Try to write to configured log file, fall back to /tmp if it fails
    if ! echo "$timestamp - $message" >> "$LOG_FILE" 2>/dev/null; then
        # Security: Use safe temporary file with restricted permissions
        local tmp_log="${TMP_DIR}/reconnect_router.log"
        
        # Ensure tmp file has proper permissions
        touch "$tmp_log" 2>/dev/null && $CHMOD_CMD 600 "$tmp_log" 2>/dev/null
        
        echo "$timestamp - $message" >> "$tmp_log" 2>/dev/null
    fi
    
    # Output to console, sanitized
    echo "$timestamp - $message"
}

# log_message: Secure wrapper for logging
log_message() {
    secure_log_message "$1"
}

# log_downtime: Record downtime events in a structured format
# Arguments:
#   $1 - Event type (CONNECTION_LOST, CONNECTION_RESTORED, etc.)
#   $2 - Duration of the event (or N/A if ongoing)
#   $3 - Additional information or context
# Outputs:
#   Writes structured record to downtime log file
# Security:
#   - Sanitizes inputs
#   - Restricts permissions
log_downtime() {
    # Security: Sanitize inputs
    local event
    event=$(echo "$1" | tr -d '[:cntrl:]' | cut -c 1-50)
    
    local duration
    duration=$(echo "$2" | tr -d '[:cntrl:]' | cut -c 1-20)
    
    local info
    info=$(echo "$3" | tr -d '[:cntrl:]' | cut -c 1-100)
    
    local timestamp
    timestamp=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
    
    # Ensure log file has proper permissions
    local log_entry="$timestamp | $event | $duration | $info"
    
    # Write to downtime log or fall back to /tmp
    if ! echo "$log_entry" >> "$DOWNTIME_LOG" 2>/dev/null; then
        local tmp_log="${TMP_DIR}/router_downtime.log"
        touch "$tmp_log" 2>/dev/null && $CHMOD_CMD 600 "$tmp_log" 2>/dev/null
        echo "$log_entry" >> "$tmp_log" 2>/dev/null
    fi
    
    # Also log to main log
    log_message "Downtime event: $event | $duration | $info"
    
    # Set flag if this is a recovery event
    if [ "$event" = "CONNECTION_RESTORED" ]; then
        DOWNTIME_ALREADY_LOGGED=true
    fi
}

# log_heartbeat: Record heartbeat events securely
# Arguments:
#   $1 - Event type (INITIALIZED, NORMAL, MISSED, etc.)
#   $2 - Additional information or context
# Outputs:
#   Writes structured record to heartbeat log file
# Security:
#   - Sanitizes inputs
#   - Restricts permissions
log_heartbeat() {
    # Security: Sanitize inputs
    local event
    event=$(echo "$1" | tr -d '[:cntrl:]' | cut -c 1-50)
    
    local info
    info=$(echo "$2" | tr -d '[:cntrl:]' | cut -c 1-100)
    
    local timestamp
    timestamp=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
    
    # Format the log entry
    local log_entry="$timestamp | HEARTBEAT | $event | $info"
    
    # Write to heartbeat log or fall back to /tmp
    if ! echo "$log_entry" >> "$HEARTBEAT_LOG" 2>/dev/null; then
        local tmp_log="${TMP_DIR}/router_heartbeat.log"
        touch "$tmp_log" 2>/dev/null && $CHMOD_CMD 600 "$tmp_log" 2>/dev/null
        echo "$log_entry" >> "$tmp_log" 2>/dev/null
    fi
}

#######################################
# NOTIFICATION FUNCTIONS
#######################################

# send_email_with_retry: Send an email with retry mechanism
# Arguments:
#   $1 - Message content to send
# Returns:
#   0 on success, non-zero on failure after multiple attempts
# Security:
#   - Sanitizes email content
#   - Uses secure temporary files
#   - Protects against command injection
send_email_with_retry() {
    # Security: Sanitize and truncate message to prevent injection
    local message
    message=$(echo "$1" | tr -d '[:cntrl:]' | cut -c 1-160)  # SMS length limit
    
    local attempts=0
    local max_attempts=3
    local success=false
    
    while [ $attempts -lt $max_attempts ]; do
        # Create a secure temporary file for the message
        local msg_file
        msg_file=$(mktemp "${TMP_DIR}/sms_msg.XXXXXX")
        
        # Set secure permissions
        $CHMOD_CMD 600 "$msg_file"
        
        # Security: Convert to ASCII safely
        if ! echo -e "$message" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null > "$msg_file"; then
            # Fallback if iconv fails
            echo "$message" > "$msg_file"
        fi
        
        # Security: Use quoted variables to prevent shell injection
        if "$MAIL_CMD" -s "$EMAIL_SUBJECT" -a "Content-Type: text/plain; charset=UTF-8" "$SMS_EMAIL" < "$msg_file" 2>/dev/null; then
            success=true
            rm -f "$msg_file"
            break
        fi
        
        # Clean up temp file
        rm -f "$msg_file"
        
        ((attempts++))
        log_message "Email send attempt $attempts failed, retrying..."
        sleep 2
    done
    
    if ! $success; then
        log_message "Failed to send SMS notification after $max_attempts attempts"
        return 1
    fi
    
    return 0
}

# send_sms: Send SMS notification with intelligent queuing
# Arguments:
#   $1 - Message content to send
# Description:
#   - If internet is available, sends message immediately
#   - If internet is down, queues message for later delivery
#   - Intelligently processes queued messages to avoid spam
# Security:
#   - Sanitizes message content
#   - Uses secure temporary files
#   - Protects queue file
send_sms() {
    # Security: Sanitize message content
    local message
    message=$(echo "$1" | tr -d '[:cntrl:]' | cut -c 1-160)  # SMS length limit
    
    local timestamp
    timestamp=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
    local message_type=""

    # Determine message type by looking for tags in the message
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

    # Add timestamp to message if it doesn't already have one
    if [[ ! "$message" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
        message="$timestamp - $message"
    fi

    # Security: Ensure queue file has proper permissions
    if [ -f "$SMS_QUEUE_FILE" ]; then
        $CHMOD_CMD 600 "$SMS_QUEUE_FILE" 2>/dev/null
    fi

    # Check internet connectivity securely before attempting to send
    if $PING_CMD -s "$PING_SIZE" "$PING_COUNT" -W "$PING_TIMEOUT" "$SMS_INTERNET_CHECK" > /dev/null 2>&1; then
        # Internet is available - attempt delivery

        # Process queued messages if any exist
        if [ -f "$SMS_QUEUE_FILE" ]; then
            log_message "Processing queued messages"

            # Security: Create secure temporary files for processing
            local tmp_queue
            tmp_queue=$(mktemp "${TMP_DIR}/sms_queue.XXXXXX")
            $CHMOD_CMD 600 "$tmp_queue"
            
            # Copy queue to secure temp file
            cat "$SMS_QUEUE_FILE" > "$tmp_queue"

            # Extract the last message of each important type to reduce spam
            declare -A latest_msgs
            
            # Security: Process the queue file line by line with proper quoting
            while IFS= read -r line; do
                if [[ "$line" == *"[START]"* ]]; then
                    latest_msgs["START"]="$line"
                elif [[ "$line" == *"[ALERT]"* ]]; then
                    latest_msgs["ALERT"]="$line"
                elif [[ "$line" == *"[CRITICAL]"* ]]; then
                    latest_msgs["CRITICAL"]="$line"
                fi
                # Skip TRYING and HEARTBEAT messages to reduce notification volume
            done < "$tmp_queue"
            
            # Clean up temp file
            rm -f "$tmp_queue"
            
            # Intelligently select which messages to send based on current message type
            if [ "$message_type" = "OK" ]; then
                # For OK (recovery) messages, send only the original ALERT and current OK
                if [ -n "${latest_msgs[ALERT]}" ]; then
                    log_message "Sending queued ALERT message"
                    send_email_with_retry "${latest_msgs[ALERT]}"
                    sleep 2
                fi
                
                # Send current OK message
                send_email_with_retry "$message"
            else
                # For other message types, send important status updates
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
            
            # Security: Securely delete the queue file
            rm -f "$SMS_QUEUE_FILE"
        else
            # No queue exists, just send current message
            send_email_with_retry "$message"
        fi
    else
        # No internet - queue the message for later delivery
        # Security: Create queue file with restricted permissions if it doesn't exist
        if [ ! -f "$SMS_QUEUE_FILE" ]; then
            touch "$SMS_QUEUE_FILE"
            $CHMOD_CMD 600 "$SMS_QUEUE_FILE"
        fi
        
        echo "$message" >> "$SMS_QUEUE_FILE"
        log_message "Message queued for later delivery: $message"
        
        # Limit queue size to prevent excessive growth
        if [ -f "$SMS_QUEUE_FILE" ] && [ "$(wc -l < "$SMS_QUEUE_FILE")" -gt 50 ]; then
            log_message "SMS queue size exceeded limit, trimming to last 50 entries"
            
            # Security: Use secure temporary file
            local tmp_queue
            tmp_queue=$(mktemp "${TMP_DIR}/sms_queue.XXXXXX")
            $CHMOD_CMD 600 "$tmp_queue"
            
            tail -n 50 "$SMS_QUEUE_FILE" > "$tmp_queue"
            mv "$tmp_queue" "$SMS_QUEUE_FILE"
            $CHMOD_CMD 600 "$SMS_QUEUE_FILE"
        fi
    fi
}

#######################################
# NETWORK MONITORING FUNCTIONS
#######################################

# process_heartbeat: Update heartbeat status and detect missed heartbeats
# Description:
#   Maintains a heartbeat system to detect if the script was interrupted
#   by comparing current time with the last recorded heartbeat
# Security:
#   - Uses secure file operations
#   - Validates data before use
#   - Implements proper error handling
process_heartbeat() {
    # Skip if heartbeat functionality is disabled
    if [ "$HEARTBEAT_ENABLED" != "true" ]; then
        return
    fi
    
    local current_time
    current_time=$($DATE_CMD +%s)
    
    # Security: Validate heartbeat file path
    if [[ "$HEARTBEAT_FILE" != "${TMP_DIR}/"* ]]; then
        log_message "ERROR: Invalid heartbeat file path: $HEARTBEAT_FILE"
        return 1
    fi
    
    # Create heartbeat file if it doesn't exist
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        echo "$current_time" > "$HEARTBEAT_FILE"
        $CHMOD_CMD 600 "$HEARTBEAT_FILE" 2>/dev/null
        log_heartbeat "INITIALIZED" "First run"
        return
    fi
    
    # Security: Ensure proper permissions on heartbeat file
    $CHMOD_CMD 600 "$HEARTBEAT_FILE" 2>/dev/null
    
    # Read last heartbeat time securely
    local last_heartbeat
    if [ -r "$HEARTBEAT_FILE" ]; then
        last_heartbeat=$(cat "$HEARTBEAT_FILE" 2>/dev/null || echo "$current_time")
        # Security: Validate the timestamp is an integer
        if ! [[ "$last_heartbeat" =~ ^[0-9]+$ ]]; then
            log_message "WARNING: Invalid heartbeat timestamp. Resetting."
            last_heartbeat=$current_time
        fi
    else
        last_heartbeat=$current_time
    fi
    
    local elapsed_time=$((current_time - last_heartbeat))
    
    # Check if we should update the heartbeat
    if [ "$elapsed_time" -ge "$HEARTBEAT_INTERVAL" ]; then
        # Check if we missed too many heartbeats (possible script downtime)
        if [ "$elapsed_time" -ge "$((HEARTBEAT_INTERVAL * MISSED_HEARTBEATS_THRESHOLD))" ]; then
            # Calculate downtime in hours, minutes, seconds
            local down_time
            down_time=$($DATE_CMD -d "@$last_heartbeat" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "Unknown")
            local hours=$((elapsed_time / 3600))
            local minutes=$(( (elapsed_time % 3600) / 60 ))
            local seconds=$((elapsed_time % 60))
            local downtime_str="${hours}h ${minutes}m ${seconds}s"
            
            # Log the missed heartbeat and send alert
            log_heartbeat "MISSED" "$downtime_str (${elapsed_time}s)"
            log_downtime "SCRIPT_INTERRUPTED" "$downtime_str" "Detected via missed heartbeats"
            send_sms "[ALERT] Pi-hole back online! Down: ${hours}h${minutes}m${seconds}s (${down_time} to now)"
        else
            # Normal heartbeat - log but don't send SMS
            log_heartbeat "NORMAL" "${elapsed_time}s since last heartbeat"
        fi
        
        # Security: Update heartbeat time with secure permissions
        echo "$current_time" > "$HEARTBEAT_FILE"
        $CHMOD_CMD 600 "$HEARTBEAT_FILE" 2>/dev/null
    fi
}

# check_connection: Verify network connectivity to router and internet
# Returns:
#   0 - Both router and internet are reachable
#   1 - Router is unreachable
#   2 - Router is reachable but internet is not
# Description:
#   This function performs two-stage connectivity testing and
#   logs status changes between up/down states
# Security:
#   - Validates IP addresses
#   - Handles timeouts properly
#   - Securely calculates timestamps
check_connection() {
    # Reset the downtime logging flag at the start of each check
    DOWNTIME_ALREADY_LOGGED=false
    local now
    
    # Security: Validate router IP before ping
    if ! validate_ipv4 "$ROUTER_IP"; then
        log_message "ERROR: Invalid router IP address: $ROUTER_IP"
        return 1
    fi
    
    # First check - Can we reach the router?
    # Security: Use timeout to prevent hanging
    if ! timeout "$PING_TIMEOUT" "$PING_CMD" -s "$PING_SIZE" "$PING_COUNT" -W "$PING_TIMEOUT" "$ROUTER_IP" >/dev/null 2>&1; then
        # Only log when state changes from up to down (prevents log spam)
        if [ "$ROUTER_WAS_DOWN" = false ]; then
            ROUTER_WAS_DOWN=true
            # Security: Generate timestamp securely
            LAST_ROUTER_DOWN_TIME=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
            log_message "Cannot reach router at $ROUTER_IP"
        fi
        return 1  # Router is unreachable
    else
        # Log recovery if router was previously down
        if [ "$ROUTER_WAS_DOWN" = true ]; then
            # Calculate downtime duration securely
            now=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
            
            # Security: Use date with error handling
            down_time_seconds=$($DATE_CMD -u -d "$LAST_ROUTER_DOWN_TIME" +%s 2>/dev/null || echo "0")
            up_time_seconds=$($DATE_CMD -u -d "$now" +%s 2>/dev/null || echo "0")
            
            # Validate timestamps
            if [ "$down_time_seconds" = "0" ] || [ "$up_time_seconds" = "0" ]; then
                duration_str="Unknown"
            else
                duration_seconds=$((up_time_seconds - down_time_seconds))
                minutes=$((duration_seconds / 60))
                seconds=$((duration_seconds % 60))
                duration_str="${minutes}m ${seconds}s"
            fi

            # Log the recovery
            log_message "Router connectivity restored after $duration_str of downtime"
            log_downtime "ROUTER_RESTORED" "$duration_str" "Router outage"
            ROUTER_WAS_DOWN=false
        fi
    fi

    # Second check - Can we reach internet DNS servers?
    # Security: Validate DNS server IPs before ping
    internet_ok=false
    for host in "${DNS_CHECK_HOSTS[@]}"; do
        if ! validate_ipv4 "$host"; then
            log_message "ERROR: Invalid DNS server IP: $host"
            continue
        fi
        
        # Security: Use timeout to prevent hanging
        if timeout "$PING_TIMEOUT" "$PING_CMD" -s "$PING_SIZE" "$PING_COUNT" -W "$PING_TIMEOUT" "$host" > /dev/null 2>&1; then
            internet_ok=true
            break
        fi
    done

    if [ "$internet_ok" = false ]; then
        # Internet was previously up but now it's down - mark the time
        if [ "$INTERNET_WAS_DOWN" = false ]; then
            LAST_INTERNET_DOWN_TIME=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
            INTERNET_WAS_DOWN=true
        fi
        
        log_message "Can reach router but cannot reach internet (none of: ${DNS_CHECK_HOSTS[*]} responded)"
        ((INTERNET_FAILURES++))

        # After X consecutive failures, back off and potentially send an alert
        if [ "$INTERNET_FAILURES" -ge "$MAX_INTERNET_FAILURES" ]; then
            log_message "Internet unreachable for $MAX_INTERNET_FAILURES attempts — backing off temporarily"
    
            # Send SMS alert if failures exceed threshold
            if [ "$INTERNET_FAILURES" -ge "$SMS_INTERNET_FAILURE_THRESHOLD" ]; then
                send_sms "[ALERT] Pi-hole has no internet despite router access. $INTERNET_FAILURES consecutive failures."
            fi

            # Security: Use a safe sleep calculation 
            sleep $((RETRY_DELAY > 0 ? RETRY_DELAY * 5 : 30))
            INTERNET_FAILURES=0
        fi

        return 2  # Internet is unreachable
    else
        # Internet is back up - log recovery if it was previously down
        if [ "$INTERNET_WAS_DOWN" = true ]; then
            # Calculate duration of the outage
            now=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
            
            # Security: Generate timestamps securely with error handling
            down_time_seconds=$($DATE_CMD -u -d "$LAST_INTERNET_DOWN_TIME" +%s 2>/dev/null || echo "0")
            up_time_seconds=$($DATE_CMD -u -d "$now" +%s 2>/dev/null || echo "0")
            
            # Validate timestamps
            if [ "$down_time_seconds" = "0" ] || [ "$up_time_seconds" = "0" ]; then
                duration_str="Unknown"
            else
                duration_seconds=$((up_time_seconds - down_time_seconds))
                minutes=$((duration_seconds / 60))
                seconds=$((duration_seconds % 60))
                duration_str="${minutes}m ${seconds}s"
            fi
            
            # Log the recovery
            log_message "Internet connectivity restored after $duration_str of downtime"
            log_downtime "CONNECTION_RESTORED" "$duration_str" "Internet-only outage (router was reachable)"
            INTERNET_WAS_DOWN=false
            # Set the flag to prevent duplicate recovery logs
            DOWNTIME_ALREADY_LOGGED=true
        fi
        INTERNET_FAILURES=0
    fi

    return 0  # Success - can reach both router and internet
}

# restart_interface: Restart the network interface
# Returns:
#   0 - Interface restart was successful
#   1 - Interface restart failed
# Description:
#   Performs a complete network interface restart procedure with
#   improved error handling and security checks
# Security:
#   - Validates interface
#   - Uses sudo securely
#   - Implements proper error handling
restart_interface() {
    log_message "Attempting to restart $INTERFACE..."
    
    # Security: Validate interface name to prevent injection
    if [[ ! "$INTERFACE" =~ ^[a-zA-Z0-9_\-\.]+$ ]]; then
        log_message "ERROR: Invalid interface name: $INTERFACE"
        return 1
    fi
    
    # Check if interface exists before proceeding
    if ! $IP_CMD link show "$INTERFACE" >/dev/null 2>&1; then
        log_message "ERROR: Interface $INTERFACE does not exist"
        return 1
    fi

    # Kill any hanging DHCP client processes
    $SUDO_CMD pkill dhclient 2>/dev/null || true
    sleep 1

    # Detect which DHCP client is available on the system
    local DHCP_CLIENT=""
    if command -v dhclient >/dev/null; then
        DHCP_CLIENT="dhclient"
    elif command -v dhcpcd >/dev/null; then
        DHCP_CLIENT="dhcpcd"
    else
        log_message "WARNING: No DHCP client found."
    fi

    # Step 1: Release DHCP lease based on client type
    if [ "$DHCP_CLIENT" = "dhclient" ]; then
        log_message "Releasing DHCP lease with dhclient"
        $SUDO_CMD dhclient -r "$INTERFACE" 2>/dev/null || true
    elif [ "$DHCP_CLIENT" = "dhcpcd" ]; then
        log_message "Releasing DHCP lease with dhcpcd"
        $SUDO_CMD dhcpcd -k "$INTERFACE" 2>/dev/null || true
    fi
    sleep 2

    # Step 2: Bring interface down
    log_message "Bringing interface down"
    $SUDO_CMD "$IP_CMD" link set "$INTERFACE" down || {
        log_message "ERROR: Failed to bring interface down"
        return 1
    }
    sleep 2

    # Step 3: Clear IP address (only if interface is still up)
    log_message "Flushing IP address"
    if $IP_CMD link show "$INTERFACE" | grep -q 'UP'; then
        $SUDO_CMD "$IP_CMD" addr flush dev "$INTERFACE" || {
            log_message "ERROR: Failed to flush IP address"
        }
    else
        log_message "Interface is down, skipping IP address flush"
    fi

    # Step 4: Bring interface up
    log_message "Bringing interface up"
    $SUDO_CMD "$IP_CMD" link set "$INTERFACE" up || {
        log_message "ERROR: Failed to bring interface up"
        return 1
    }
    sleep 3  # Reduced sleep time for efficiency

# Step 5: Get new IP address based on client type
    if [ "$DHCP_CLIENT" = "dhclient" ]; then
        log_message "Requesting new IP with dhclient"
        $SUDO_CMD dhclient "$INTERFACE" || {
            log_message "ERROR: dhclient failed to get IP"
        }
    elif [ "$DHCP_CLIENT" = "dhcpcd" ]; then
        log_message "Requesting new IP with dhcpcd"
        $SUDO_CMD dhcpcd "$INTERFACE" || {
            log_message "ERROR: dhcpcd failed to get IP"
        }
    else
        log_message "No DHCP client available. Waiting for system to assign IP."
        # Some systems will automatically assign an IP when the interface comes up
        sleep 10
    fi

    # Wait for interface to stabilize (shorter time)
    sleep 3
    
    # Verify we have an IP address assigned
    if ! $IP_CMD addr show dev "$INTERFACE" | grep -q 'inet '; then
        log_message "WARNING: No IP address assigned to $INTERFACE after restart"
        return 1
    else
        log_message "IP address successfully assigned to $INTERFACE"
        return 0
    fi
}

# self_test: Verify environment and dependencies
# Returns:
#   0 - Self-test passed
#   1 - Critical issue detected
# Description:
#   Checks system configuration and dependencies to ensure the script
#   has all prerequisites to run successfully
# Security:
#   - Validates configuration
#   - Checks permissions
#   - Reports all issues
self_test() {
    log_message "Running self-test..."
    local errors=0
    
    # Test lock file creation capabilities
    if ! touch "$LOCK_FILE" 2>/dev/null; then
        log_message "ERROR: Cannot create lock file at $LOCK_FILE. Check /tmp permissions."
        ((errors++))
    fi
    
    # Security: Verify interface exists with proper validation
    if ! validate_interface "$INTERFACE"; then
        log_message "WARNING: Network interface '$INTERFACE' not found. Script may not work correctly."
        # List available interfaces to help user troubleshoot
        log_message "Available interfaces:"
        $IP_CMD link show | grep -E '^[0-9]+:' | cut -d' ' -f2 | tr -d ':' | while read -r iface; do
            # Sanitize interface name for logging
            iface=$(echo "$iface" | tr -cd '[:alnum:]_\-.')
            log_message " - $iface"
        done
        ((errors++))
    fi
    
    # Check for DHCP client availability
    if ! command -v dhclient >/dev/null && ! command -v dhcpcd >/dev/null; then
        log_message "WARNING: No DHCP client (dhclient or dhcpcd) found. Network restart may fail."
        ((errors++))
    fi
    
    # Security: Verify router is reachable with proper validation
    if validate_ipv4 "$ROUTER_IP"; then
        if ! timeout "$PING_TIMEOUT" "$PING_CMD" -s "$PING_SIZE" "$PING_COUNT" -W "$PING_TIMEOUT" "$ROUTER_IP" >/dev/null 2>&1; then
            log_message "WARNING: Cannot reach router at $ROUTER_IP. Please verify router IP address."
            ((errors++))
        fi
    else
        log_message "ERROR: Invalid router IP address: $ROUTER_IP"
        ((errors++))
   
    fi
    
    # Check log file permissions
    for log_file in "$LOG_FILE" "$DOWNTIME_LOG" "$HEARTBEAT_LOG"; do
        if [ -f "$log_file" ] && [ ! -w "$log_file" ]; then
            log_message "WARNING: Cannot write to log file $log_file. Check permissions."
            ((errors++))
        fi
    done
    
    log_message "Self-test complete with $errors warnings/errors."
    [ $errors -eq 0 ] && return 0 || return 1
}

# cleanup: Perform script cleanup on exit
# Description:
#   Called by trap to ensure clean shutdown:
#   - Logs termination
#   - Ensures network interface is up
#   - Releases lock file
# Security:
#   - Properly releases resources
#   - Secure file cleanup
cleanup() {
    log_message "Script stopped. Ensuring interface is up..."
    log_heartbeat "STOPPED" "Script terminated"
    
    # Make sure interface is up when we exit
    if validate_interface "$INTERFACE"; then
        $SUDO_CMD "$IP_CMD" link set "$INTERFACE" up 2>/dev/null || true
    fi

    # Clean up temp files securely
    rm -f "$SMS_QUEUE_FILE" || true
    
    # Release and remove the lock file
    rm -f "$LOCK_FILE" || true
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    
    exit 0
}

#######################################
# SCRIPT INITIALIZATION
#######################################

# Set up exit handlers - Ensure proper cleanup on exit
trap 'EXIT_CODE=$?; echo "$(date) - Script stopped. Exit code: $EXIT_CODE" > /tmp/reconnect_router_debug; echo "$(date +"%Y-%m-%d %H:%M:%S") - Normal termination" > /tmp/reconnect_router_clean_exit; cleanup' EXIT
trap cleanup SIGTERM SIGINT SIGHUP

# Run security validation
security_check || {
    log_message "CRITICAL: Security validation failed. Please check configuration and try again."
    # Continue execution with warnings
}

# Advanced diagnostic logging
log_message "Script started with PID $$"
log_message "Command line: $0 ${*}"

# Get clean termination reason without recursion
if journalctl -u reconnect_router.service --since "1 hour ago" | grep -i "terminated" | grep -v "Last terminated reason" | tail -1 > "$LAST_TERM_REASON_FILE" 2>/dev/null; then
    log_message "Last terminated reason: $(cat "$LAST_TERM_REASON_FILE" 2>/dev/null || echo 'Not available')"
else 
    log_message "Last terminated reason: Not available"
fi

# Check for startup frequency - Avoid excessive restart notifications
SUPPRESS_START_NOTIFICATION=false
if [ -f "$STARTUP_CHECK_FILE" ]; then
    # Security: Read with validation
    last_start=$(cat "$STARTUP_CHECK_FILE" 2>/dev/null || echo "0")
    if ! [[ "$last_start" =~ ^[0-9]+$ ]]; then
        last_start=0
        log_message "WARNING: Invalid startup timestamp. Resetting."
    fi
    
    current_time=$($DATE_CMD +%s)
    elapsed=$((current_time - last_start))
    
    if [ $elapsed -lt $STARTUP_THRESHOLD ]; then
        log_message "Script restarted within $elapsed seconds - suppressing start notification"
        SUPPRESS_START_NOTIFICATION=true
    fi
fi

# Update startup time securely
$DATE_CMD +%s > "$STARTUP_CHECK_FILE"
$CHMOD_CMD 600 "$STARTUP_CHECK_FILE" 2>/dev/null || true

# Check for required dependencies
for cmd in mail iconv "$IP_CMD" "$PING_CMD"; do
    if ! command -v "$cmd" >/dev/null; then
        echo "ERROR: Required command '${cmd##*/}' not found. Please install the necessary package."
        exit 1
    fi
done

# Check /tmp permissions - more portable across Unix systems
if [ "$(stat -c %a "$TMP_DIR")" != "1777" ]; then
    log_message "WARNING: $TMP_DIR directory doesn't have correct permissions (1777/drwxrwxrwt). This may cause lock file issues."
    # Uncomment to automatically fix permissions:
    # sudo chmod 1777 /tmp
fi

#######################################
# LOCK FILE MANAGEMENT
#######################################

# Handle existing lock file - Check if previous process is still running
if [ -f "$LOCK_FILE" ]; then
    # Security: Read PID with validation
    PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if ! [[ "$PID" =~ ^[0-9]+$ ]]; then
        log_message "WARNING: Invalid PID in lock file. Removing stale lock."
        rm -f "$LOCK_FILE"
    elif [ -n "$PID" ] && ! ps -p "$PID" > /dev/null 2>&1; then
        log_message "Removing stale lock file from PID $PID"
        rm -f "$LOCK_FILE"
    fi
fi

# Create and acquire lock to prevent multiple instances
# Security: Use file descriptor-based locking
exec 200>"$LOCK_FILE" || {
    echo "ERROR: Could not open lock file $LOCK_FILE"
    exit 1
}

# Attempt to acquire the lock with non-blocking flock
if ! flock -n 200; then
    echo "Script is already running. Exiting."
    exit 1
fi

# Security: Set proper permissions on lock file
$CHMOD_CMD 600 "$LOCK_FILE" 2>/dev/null || true

#######################################
# LOG FILE SETUP
#######################################

# Ensure log files and directories exist with fallback to /tmp
for LOG in "$LOG_FILE" "$DOWNTIME_LOG" "$HEARTBEAT_LOG"; do
    # Create directory if needed with secure permissions
    if [ ! -d "$(dirname "$LOG")" ]; then
        if ! $SUDO_CMD mkdir -p "$(dirname "$LOG")" 2>/dev/null; then
            # If can't create in /var/log, fall back to /tmp
            NEW_LOG="${TMP_DIR}/$(basename "$LOG")"
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
        else 
            # Set secure permissions on log directory
            $SUDO_CMD "$CHMOD_CMD" 755 "$(dirname "$LOG")" 2>/dev/null || true
        fi
    fi
    
    # Touch the file if it doesn't exist - with secure permissions
    if [ ! -f "$LOG" ]; then
        if ! $SUDO_CMD touch "$LOG" 2>/dev/null || ! $SUDO_CMD "$CHOWN_CMD" "$(whoami)" "$LOG" 2>/dev/null; then
            log_message "WARNING: Could not create or set permissions for $LOG"
        else
            # Set explicit permissions
            $SUDO_CMD "$CHMOD_CMD" 644 "$LOG" 2>/dev/null || true
        fi
    fi
    
    # Make sure we can write to it
    if ! touch "$LOG" 2>/dev/null; then
        log_message "ERROR: Cannot write to log file $LOG. Check permissions."
    fi
    
    # Log rotation check to prevent enormous log files - with secure temp files
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -ge 10485760 ]; then
        log_message "Log file $LOG has grown too large, rotating"
        # Create a timestamp for the rotation
        timestamp="$($DATE_CMD '+%Y%m%d%H%M%S')"
        $SUDO_CMD mv "$LOG" "${LOG}.${timestamp}" 2>/dev/null || true
    fi
done

# Run self-test to verify environment
self_test || log_message "WARNING: Self-test reported issues, but continuing execution"

#######################################
# MAIN LOOP
#######################################

# Initialize tracking variables
connection_was_down=false
consecutive_failures=0
last_heartbeat_check=$($DATE_CMD +%s)
saved_down_time=""  # Save the exact down time to use for recovery

# Start monitoring
log_message "Network monitoring started for interface $INTERFACE"
log_heartbeat "STARTED" "Monitoring initialization"

# Send startup notification if not suppressed due to recent restart
if [ "$SUPPRESS_START_NOTIFICATION" != "true" ]; then
    send_sms "[START] Pi-hole network monitoring started on $HOSTNAME"
    log_message "Sent startup notification"
else
    log_message "Startup notification suppressed due to recent restart"
fi

# Main monitoring loop - runs indefinitely
while true; do
    # Process heartbeat checks once per minute
    current_time=$($DATE_CMD +%s)
    if [ "$((current_time - last_heartbeat_check))" -ge 60 ]; then
        process_heartbeat
        last_heartbeat_check=$current_time
    fi
    
    # Reset downtime flag at the start of each loop iteration
    DOWNTIME_ALREADY_LOGGED=false
    
    # Check connection status
    check_connection
    connection_code=$?
    
    if [ $connection_code -eq 1 ]; then  # Cannot reach router
        ((consecutive_failures++))
        
        # Cap consecutive_failures to avoid unbounded backoff
        if [ "$consecutive_failures" -gt 10 ]; then
            consecutive_failures=10
        fi

        # Only trigger reconnection after 2 consecutive failures
        # This avoids reacting to temporary glitches
        if [ "$consecutive_failures" -ge 2 ]; then
            if [ "$connection_was_down" = false ]; then
                # Capture the exact time the connection went down
                # for proper downtime calculation later
                saved_down_time=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
                log_message "Network connectivity lost at $saved_down_time"
                log_downtime "CONNECTION_LOST" "N/A" "Starting recovery attempts"
                
                # Queue the alert message even though we can't send it now
                # It will be sent once connection is restored
                send_sms "[ALERT] Pi-hole Disconnected at $saved_down_time"
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

                # Attempt to restart the network interface
                restart_interface

                # Check connection again after restart attempt
                check_connection
                current_code=$?
                
                # If we can reach router (even if we can't reach internet), consider it a partial success
                if [ "$current_code" -eq 0 ] || [ "$current_code" -eq 2 ]; then
                    up_time=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
                    
                    # Calculate downtime using saved_down_time for accuracy
                    down_time_seconds=$($DATE_CMD -u -d "$saved_down_time" +%s 2>/dev/null || echo "0")
                    up_time_seconds=$($DATE_CMD -d "$up_time" +%s 2>/dev/null || echo "0")
                    
                    # Security: Validate timestamp calculations
                    if [ "$down_time_seconds" = "0" ] || [ "$up_time_seconds" = "0" ]; then
                        downtime_str="Unknown"
                        downtime_minutes=0
                        downtime_seconds=0
                    else
                        downtime_seconds=$((up_time_seconds - down_time_seconds))
                        downtime_minutes=$((downtime_seconds / 60))
                        downtime_seconds=$((downtime_seconds % 60))
                        downtime_str="${downtime_minutes}m ${downtime_seconds}s"
                    fi
                    
                    # Format condensed message to fit within SMS 160 character limit
                    recovery_message="[OK] Pi-hole Online! Down: ${downtime_minutes}m${downtime_seconds}s. ${i}/${MAX_RETRIES} attempts"
                    
                    # Only log downtime if it hasn't already been logged by check_connection
                    if [ "$DOWNTIME_ALREADY_LOGGED" = false ]; then
                        log_downtime "CONNECTION_RESTORED" "$downtime_str" "$i attempts needed"
                    fi
                    
                    # Send success notification
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
                # Calculate total downtime so far
                timeout_time=$($DATE_CMD '+%Y-%m-%d %H:%M:%S')
                
                # Security: Calculate downtime with validation
                total_time_str=$($DATE_CMD -d "$timeout_time" +%s 2>/dev/null || echo "0")
                start_time_str=$($DATE_CMD -d "$saved_down_time" +%s 2>/dev/null || echo "0")
                
                # Validate timestamps
                if [ "$total_time_str" = "0" ] || [ "$start_time_str" = "0" ]; then
                    downtime_str="Unknown"
                else
                    time_diff=$((total_time_str - start_time_str))
                    minutes=$((time_diff / 60))
                    seconds=$((time_diff % 60))
                    downtime_str="${minutes}m ${seconds}s"
                fi

                # Format critical failure message
                timeout_message="[CRITICAL] Pi-hole recovery failed!
- Down since: $saved_down_time
- Current time: $timeout_time
- Total downtime: $downtime_str
- All $MAX_RETRIES attempts failed
Manual intervention required!"

                # Log failure and send alert
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

            # Avoid restarting interface too frequently
            if [ -f "$RESTART_TIME_FILE" ]; then
                # Security: Read with validation
                last_restart=$(cat "$RESTART_TIME_FILE" 2>/dev/null || echo "0")
                if ! [[ "$last_restart" =~ ^[0-9]+$ ]]; then
                    last_restart=0
                    log_message "WARNING: Invalid restart timestamp. Resetting."
                fi
                
                now=$($DATE_CMD +%s)
                if (( now - last_restart < RESTART_INTERVAL )); then
                    log_message "Interface restart suppressed - minimum interval not reached"
                    restart_ok=false
                    sleep $RETRY_DELAY
                fi
            fi

            # Restart if minimum interval has passed
            if $restart_ok; then
                $DATE_CMD +%s > "$RESTART_TIME_FILE"
                $CHMOD_CMD 600 "$RESTART_TIME_FILE" 2>/dev/null || true
                restart_interface
            fi
        fi
    else
        # Connection is good - reset failure counter
        consecutive_failures=0
    fi

    # Calculate delay using exponential backoff with a ceiling
    if [ "$consecutive_failures" -gt 5 ]; then
        # Security: Calculate backoff safely
        # Calculate backoff delay (2^n)
        # Use max function to ensure RETRY_DELAY is at least 1
        backoff=$((RETRY_DELAY > 0 ? RETRY_DELAY * (2 ** (consecutive_failures - 5)) : 30))
        
        # Cap the backoff at 10 minutes (600 seconds)
        if [ "$backoff" -gt 600 ]; then
            backoff=600
        fi
        
        log_message "Using exponential backoff: ${backoff}s delay"
        sleep $backoff
    else
        # Use standard delay
        sleep $RETRY_DELAY
    fi
done