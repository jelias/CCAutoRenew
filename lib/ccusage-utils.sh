#!/bin/bash
# Shared library for ccusage query logic
# Used by both daemon and manager scripts

# Config file to track daemon state
DAEMON_CONFIG_FILE="$HOME/.claude-auto-renew-daemon-config"

# Global variables set by get_remaining_time()
TIMING_SOURCE=""
REMAINING_SECONDS=0

# Get the ccusage command (ccusage, bunx, or npx)
# Returns: command name or exits with error code
get_ccusage_cmd() {
    if command -v ccusage &> /dev/null; then
        echo "ccusage"
        return 0
    elif command -v bunx &> /dev/null; then
        echo "bunx"
        return 0
    elif command -v npx &> /dev/null; then
        echo "npx"
        return 0
    else
        return 1
    fi
}

# Check if ccusage is disabled via config file
# Returns: 0 if disabled, 1 if enabled
is_ccusage_disabled() {
    if [ ! -f "$DAEMON_CONFIG_FILE" ]; then
        return 1  # Not disabled (no config = default enabled)
    fi

    # Read config file
    local disable_flag=$(grep "^DISABLE_CCUSAGE=" "$DAEMON_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)
    local daemon_pid=$(grep "^DAEMON_PID=" "$DAEMON_CONFIG_FILE" 2>/dev/null | cut -d'=' -f2)

    # Validate PID to detect stale config
    if [ -n "$daemon_pid" ] && ! kill -0 "$daemon_pid" 2>/dev/null; then
        # Stale config - daemon not running
        rm -f "$DAEMON_CONFIG_FILE"
        return 1  # Treat as enabled
    fi

    if [ "$disable_flag" = "true" ]; then
        return 0  # Disabled
    else
        return 1  # Enabled
    fi
}

# Query ccusage and return minutes remaining
# Returns: minutes remaining (0-300) or error code
get_minutes_until_reset() {
    local cmd=$(get_ccusage_cmd)
    if [ $? -ne 0 ]; then
        return 1  # ccusage not available
    fi

    # Check if ccusage is disabled
    if is_ccusage_disabled; then
        return 2  # ccusage disabled by flag
    fi

    # Check if jq is available for JSON parsing
    if ! command -v jq &> /dev/null; then
        return 7  # jq not available for JSON parsing
    fi

    # Query ccusage blocks in JSON format
    local json_output
    if [ "$cmd" = "ccusage" ]; then
        json_output=$(ccusage blocks --json 2>/dev/null)
    else
        json_output=$($cmd ccusage blocks --json 2>/dev/null)
    fi

    if [ -z "$json_output" ]; then
        return 3  # No output from ccusage
    fi

    # Extract active block with remaining minutes from JSON
    local remaining_minutes=$(echo "$json_output" | jq -r '.blocks[] | select(.isActive == true) | .projection.remainingMinutes' 2>/dev/null | head -1)

    # Check if we got valid data
    if [ -z "$remaining_minutes" ] || [ "$remaining_minutes" = "null" ]; then
        return 3  # No active block found
    fi

    # Validate it's a number
    if ! [[ "$remaining_minutes" =~ ^[0-9]+$ ]]; then
        return 4  # Invalid format
    fi

    # Validate range (0-300 minutes = 5 hours max)
    if [ "$remaining_minutes" -lt 0 ] || [ "$remaining_minutes" -gt 300 ]; then
        return 5  # Invalid range
    fi

    echo "$remaining_minutes"
    return 0
}

# Fallback: Calculate remaining time from activity file (clock-based)
# Returns: seconds remaining or error code
calculate_remaining_from_activity() {
    local activity_file="$HOME/.claude-last-activity"

    if [ ! -f "$activity_file" ]; then
        return 1  # No activity file
    fi

    local last_activity=$(cat "$activity_file" 2>/dev/null)
    if [ -z "$last_activity" ]; then
        return 2  # Empty file
    fi

    local current_epoch=$(date +%s)
    local elapsed=$((current_epoch - last_activity))
    local remaining=$((18000 - elapsed))  # 18000 = 5 hours

    if [ "$remaining" -le 0 ]; then
        return 3  # Session expired
    fi

    echo "$remaining"
    return 0
}

# Smart function: Try ccusage first, fall back to clock-based calculation
# Returns: seconds remaining or error code
# Sets: TIMING_SOURCE global variable
# Note: Call this function WITHOUT command substitution to preserve TIMING_SOURCE
# Example: get_remaining_time; remaining=$?
get_remaining_time() {
    # Try ccusage first
    local minutes=$(get_minutes_until_reset 2>/dev/null)
    local ret=$?
    if [ $ret -eq 0 ] && [ -n "$minutes" ]; then
        TIMING_SOURCE="ccusage"
        REMAINING_SECONDS=$((minutes * 60))  # Convert to seconds
        return 0
    fi

    # Fallback to clock-based calculation
    local seconds=$(calculate_remaining_from_activity 2>/dev/null)
    ret=$?
    if [ $ret -eq 0 ] && [ -n "$seconds" ]; then
        TIMING_SOURCE="clock"
        REMAINING_SECONDS=$seconds
        return 0
    fi

    # No timing available
    TIMING_SOURCE="none"
    REMAINING_SECONDS=0
    return 1
}

# Verify that an active Claude session exists with sufficient time remaining
# Returns: 0 if verified active (>60 min via ccusage), 1 otherwise
# Sets: TIMING_SOURCE and REMAINING_SECONDS globals
# Note: Accepts any active session with >60 minutes (not just fresh 5-hour sessions)
verify_session_active() {
    # Query current session state
    get_remaining_time
    local ret=$?

    # Must have timing data
    if [ $ret -ne 0 ]; then
        return 1  # No timing available
    fi

    # Must be ccusage-verified (not clock-based estimation)
    if [ "$TIMING_SOURCE" != "ccusage" ]; then
        return 2  # Not API-verified
    fi

    # Calculate minutes from seconds
    local minutes=$((REMAINING_SECONDS / 60))

    # Must have >60 minutes (1 hour) remaining - sufficient for continued operation
    # We don't require a fresh 5-hour session; any active session with time is acceptable
    if [ "$minutes" -le 60 ]; then
        return 3  # Not enough time remaining
    fi

    # Success - verified active session with sufficient time
    return 0
}

# Save daemon configuration (called on daemon startup)
# Args: $1 = disable_ccusage flag (true/false)
save_daemon_config() {
    local disable_flag="$1"
    local daemon_pid=$$

    cat > "$DAEMON_CONFIG_FILE" <<EOF
# Auto-generated daemon config
# Created: $(date)
DAEMON_PID=$daemon_pid
DISABLE_CCUSAGE=$disable_flag
EOF

    chmod 600 "$DAEMON_CONFIG_FILE"
}

# Clear daemon configuration (called on daemon shutdown)
clear_daemon_config() {
    rm -f "$DAEMON_CONFIG_FILE"
}
