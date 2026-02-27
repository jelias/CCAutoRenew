#!/bin/bash

# Claude Auto-Renewal Daemon - Continuous Running Script
# Runs continuously in the background, checking for renewal windows

LOG_FILE="$HOME/.claude-auto-renew-daemon.log"
PID_FILE="$HOME/.claude-auto-renew-daemon.pid"
LAST_ACTIVITY_FILE="$HOME/.claude-last-activity"
START_TIME_FILE="$HOME/.claude-auto-renew-start-time"
STOP_TIME_FILE="$HOME/.claude-auto-renew-stop-time"
MESSAGE_FILE="$HOME/.claude-auto-renew-message"
SLEEP_PID=""  # Track background sleep process for graceful shutdown
RENEWAL_MODEL="claude-haiku-4-5-20251001"

# Load shared library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ccusage-utils.sh"

# Function to log messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Log detailed verification status
log_verification_status() {
    local verify_ret=$1
    local minutes=$((REMAINING_SECONDS / 60))
    local hours=$((minutes / 60))
    local mins=$((minutes % 60))

    case $verify_ret in
        0)
            log_message "✅ VERIFIED: Active session with $minutes min (${hours}h ${mins}m) remaining"
            log_message "   Source: $TIMING_SOURCE (API-verified)"
            ;;
        1)
            log_message "❌ FAILED: No timing data available from ccusage"
            ;;
        2)
            log_message "❌ FAILED: Timing source not API-verified"
            log_message "   Source: $TIMING_SOURCE | Remaining: $minutes min"
            ;;
        3)
            log_message "❌ FAILED: Not enough time remaining (≤60 min)"
            log_message "   Source: $TIMING_SOURCE | Remaining: $minutes min"
            ;;
    esac
}

# Function to handle shutdown
cleanup() {
    log_message "Daemon shutting down..."

    # Kill the background sleep process if it's running
    if [ -n "$SLEEP_PID" ] && kill -0 "$SLEEP_PID" 2>/dev/null; then
        kill "$SLEEP_PID" 2>/dev/null
        wait "$SLEEP_PID" 2>/dev/null  # Clean up zombie process
    fi

    # Clear daemon config and state files
    clear_daemon_config
    clear_state_file

    rm -f "$PID_FILE"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Function to check if we're in the active monitoring window
is_monitoring_active() {
    local current_epoch=$(date +%s)
    local start_epoch=""
    local stop_epoch=""
    
    if [ -f "$START_TIME_FILE" ]; then
        start_epoch=$(cat "$START_TIME_FILE")
    fi
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi
    
    # If no start time set, always active (unless stop time is set and passed)
    if [ -z "$start_epoch" ]; then
        if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
            return 1  # Past stop time
        else
            return 0  # Active
        fi
    fi
    
    # Check if we're before start time
    if [ "$current_epoch" -lt "$start_epoch" ]; then
        return 1  # Before start time
    fi
    
    # Check if we're past stop time
    if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 1  # Past stop time
    fi
    
    return 0  # In active window
}

# Function to check if we should schedule next day restart
should_restart_tomorrow() {
    if [ ! -f "$START_TIME_FILE" ] || [ ! -f "$STOP_TIME_FILE" ]; then
        return 1  # No scheduling needed
    fi
    
    local current_epoch=$(date +%s)
    local stop_epoch=$(cat "$STOP_TIME_FILE")
    
    # Check if we've passed stop time
    if [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 0  # Should restart tomorrow
    fi
    
    return 1  # Not yet time
}

# Function to schedule restart for next day
schedule_next_day_restart() {
    if [ ! -f "$START_TIME_FILE" ]; then
        return 1
    fi
    
    local start_epoch=$(cat "$START_TIME_FILE")
    local stop_epoch=""
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi
    
    # Calculate tomorrow's start time
    local next_start=$((start_epoch + 86400))
    local next_stop=""
    
    if [ -n "$stop_epoch" ]; then
        next_stop=$((stop_epoch + 86400))
    fi
    
    # Update the time files for tomorrow
    echo "$next_start" > "$START_TIME_FILE"
    if [ -n "$next_stop" ]; then
        echo "$next_stop" > "$STOP_TIME_FILE"
    fi
    
    # Remove activation marker so it gets recreated tomorrow
    rm -f "${START_TIME_FILE}.activated" 2>/dev/null
    
    log_message "🔄 Scheduled restart for tomorrow at $(date -d "@$next_start" 2>/dev/null || date -r "$next_start")"
    
    return 0
}

# Function to get time until start
get_time_until_start() {
    if [ ! -f "$START_TIME_FILE" ]; then
        echo "0"
        return
    fi
    
    local start_epoch=$(cat "$START_TIME_FILE")
    local current_epoch=$(date +%s)
    local diff=$((start_epoch - current_epoch))
    
    if [ "$diff" -le 0 ]; then
        echo "0"
    else
        echo "$diff"
    fi
}

# Function to start Claude session
start_claude_session() {
    log_message "Starting Claude session for renewal (model: $RENEWAL_MODEL)..."
    
    if ! command -v claude &> /dev/null; then
        log_message "ERROR: claude command not found"
        return 1
    fi
    
    # Check if custom message is available
    local selected_message=""
    
    if [ -f "$MESSAGE_FILE" ]; then
        # Use custom message
        selected_message=$(cat "$MESSAGE_FILE")
        log_message "Using custom message: \"$selected_message\""
    else
        # Define an array of predefined messages
        local messages=("hi" "hello" "hey there" "good day" "greetings" "howdy" "what's up" "salutations")
        
        # Randomly select a message from the array
        local random_index=$((RANDOM % ${#messages[@]}))
        selected_message="${messages[$random_index]}"
    fi
    
    # Ephemeral session: send message and let it close naturally (EOF on pipe)
    # Claude writes JSONL to disk immediately on session end, allowing ccusage
    # to detect the new billing block right away for verification.
    # Unset CLAUDECODE to allow renewal from within an existing Claude session
    (unset CLAUDECODE; echo "$selected_message" | claude --model "$RENEWAL_MODEL" >> "$LOG_FILE" 2>&1) &
    local pid=$!
    
    # Wait up to 10 seconds
    local count=0
    while kill -0 $pid 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        ((count++))
    done
    
    # Kill if still running
    if kill -0 $pid 2>/dev/null; then
        kill $pid 2>/dev/null
        wait $pid 2>/dev/null
        local result=124  # timeout exit code
    else
        wait $pid
        local result=$?
    fi
    
    if [ $result -eq 0 ] || [ $result -eq 124 ]; then  # 124 is timeout exit code
        log_message "Claude session process completed with message: $selected_message"
        # Note: activity file updated only after verification
        return 0
    else
        log_message "ERROR: Failed to start Claude session"
        return 1
    fi
}

# Determine the target epoch for the next renewal.
# Claude billing blocks expire at the top of the hour. Target is 5 minutes
# past that boundary, giving the new block time to be established.
# Retries every 5 minutes if ccusage is unavailable.
# Returns: target epoch via echo, or 0 if no active block (renew immediately)
get_renewal_target_epoch() {
    local attempt=0
    while true; do
        attempt=$((attempt + 1))

        local end_epoch
        end_epoch=$(get_block_end_epoch)
        local ret=$?

        if [ $ret -eq 0 ] && [ -n "$end_epoch" ]; then
            # Active block found - target is 5 min past the block's end time
            # Blocks always expire at the top of the hour, so end_epoch + 5 min
            local target=$(( end_epoch + 300 ))
            write_state_file "$end_epoch"
            echo "$target"
            return 0
        elif [ $ret -eq 3 ]; then
            # No active block - signal to renew immediately
            echo "0"
            return 0
        else
            # ccusage/jq unavailable - retry
            log_message "⚠️  ccusage unavailable (attempt $attempt), retrying in 5 minutes..."
            sleep 300
        fi
    done
}

# Main daemon loop
main() {
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Daemon already running with PID $OLD_PID"
            exit 1
        else
            log_message "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi
    
    # Save PID
    echo $$ > "$PID_FILE"

    # Save daemon configuration
    save_daemon_config

    log_message "=== Claude Auto-Renewal Daemon Started ==="
    log_message "PID: $$"
    log_message "Logs: $LOG_FILE"

    # Check for start and stop times
    if [ -f "$START_TIME_FILE" ]; then
        start_epoch=$(cat "$START_TIME_FILE")
        log_message "Start time configured: $(date -d "@$start_epoch" 2>/dev/null || date -r "$start_epoch")"
    else
        log_message "No start time set - will begin monitoring immediately"
    fi
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
        log_message "Stop time configured: $(date -d "@$stop_epoch" 2>/dev/null || date -r "$stop_epoch")"
    else
        log_message "No stop time set - will monitor continuously"
    fi
    
    # Check for custom message
    if [ -f "$MESSAGE_FILE" ]; then
        custom_message=$(cat "$MESSAGE_FILE")
        log_message "Custom renewal message configured: \"$custom_message\""
    else
        log_message "Using default random greeting messages for renewal"
    fi
    
    # Check ccusage/jq availability at startup (non-fatal; get_renewal_target_epoch retries)
    if ! get_ccusage_cmd &> /dev/null; then
        log_message "WARNING: ccusage not found. Will retry until available."
        log_message "Install ccusage: npm install -g ccusage"
    elif ! command -v jq &> /dev/null; then
        log_message "WARNING: jq not found. Will retry until available."
        log_message "Install jq: sudo apt-get install jq"
    else
        log_message "✅ ccusage and jq available"
    fi

    # Main loop
    while true; do
        # Check if we should schedule next day restart first
        if should_restart_tomorrow; then
            log_message "🛑 Stop time reached. Scheduling restart for tomorrow..."
            schedule_next_day_restart
            
            # Wait for tomorrow's start time
            while ! is_monitoring_active; do
                time_until_start=$(get_time_until_start)
                hours=$((time_until_start / 3600))
                minutes=$(((time_until_start % 3600) / 60))
                
                if [ "$hours" -gt 0 ]; then
                    log_message "⏰ Waiting for tomorrow's start time (${hours}h ${minutes}m remaining)..."
                    sleep 3600  # Check every hour when waiting for tomorrow
                else
                    log_message "⏰ Waiting for start time (${minutes}m remaining)..."
                    sleep 300   # Check every 5 minutes when close
                fi
            done
            
            log_message "🌅 New day started! Resuming monitoring..."
            continue
        fi
        
        # Check if we're in monitoring window
        if ! is_monitoring_active; then
            # Calculate time until start or reason for inactivity
            if [ -f "$START_TIME_FILE" ]; then
                time_until_start=$(get_time_until_start)
                hours=$((time_until_start / 3600))
                minutes=$(((time_until_start % 3600) / 60))
                seconds=$((time_until_start % 60))
                
                if [ "$time_until_start" -gt 0 ]; then
                    # Before start time
                    if [ "$hours" -gt 0 ]; then
                        log_message "⏰ Waiting for start time (${hours}h ${minutes}m remaining)..."
                        sleep 300  # Check every 5 minutes when waiting
                    elif [ "$minutes" -gt 2 ]; then
                        log_message "⏰ Waiting for start time (${minutes}m ${seconds}s remaining)..."
                        sleep 60   # Check every minute when close
                    elif [ "$time_until_start" -gt 10 ]; then
                        log_message "⏰ Waiting for start time (${minutes}m ${seconds}s remaining)..."
                        sleep 10   # Check every 10 seconds when very close
                    else
                        log_message "⏰ Waiting for start time (${seconds}s remaining)..."
                        sleep 2    # Check every 2 seconds when imminent
                    fi
                else
                    # Past stop time, waiting for tomorrow
                    log_message "🛑 Past stop time, waiting for tomorrow..."
                    sleep 300
                fi
            else
                # No start time but inactive - must be past stop time
                log_message "🛑 Past stop time, no restart scheduled..."
                sleep 300
            fi
            continue
        fi
        
        # If we just entered active time, log it
        if [ -f "$START_TIME_FILE" ]; then
            # Check if this is the first time we're active today
            if [ ! -f "${START_TIME_FILE}.activated" ]; then
                log_message "✅ Start time reached! Beginning auto-renewal monitoring..."
                touch "${START_TIME_FILE}.activated"
            fi
        fi
        
        # === DETERMINE NEXT RENEWAL TIME ===
        # Query ccusage for the active block's endTime. Retries every 5 min on error.
        # Claude blocks always expire at the top of the hour; we target 5 min past that.
        local target_epoch
        target_epoch=$(get_renewal_target_epoch)

        if [ "$target_epoch" -eq 0 ]; then
            # No active block found - fresh start or block already expired; renew now
            log_message "No active session block found, renewing immediately..."
        else
            local renewal_time_str
            renewal_time_str=$(date -d "@$target_epoch" '+%H:%M')

            # If renewal target is past stop time, sleep until stop and let loop handle it
            if [ -f "$STOP_TIME_FILE" ]; then
                local stop_epoch
                stop_epoch=$(cat "$STOP_TIME_FILE")
                if [ "$target_epoch" -gt "$stop_epoch" ]; then
                    local stop_time_str
                    stop_time_str=$(date -d "@$stop_epoch" '+%H:%M')
                    log_message "Next renewal at $renewal_time_str is past stop time $stop_time_str — skipping"
                    local wait_seconds=$(( stop_epoch - $(date +%s) ))
                    if [ "$wait_seconds" -gt 0 ]; then
                        sleep "$wait_seconds" &
                        SLEEP_PID=$!
                        wait "$SLEEP_PID" 2>/dev/null
                        SLEEP_PID=""
                    fi
                    continue
                fi
            fi

            # Sleep precisely until 5 minutes past the next hour boundary
            local now
            now=$(date +%s)
            local wait_seconds=$(( target_epoch - now ))
            if [ "$wait_seconds" -gt 0 ]; then
                log_message "Next renewal at $renewal_time_str — sleeping ${wait_seconds}s..."
                sleep "$wait_seconds" &
                SLEEP_PID=$!
                wait "$SLEEP_PID" 2>/dev/null
                SLEEP_PID=""
            else
                log_message "Target time $renewal_time_str already passed, renewing now..."
            fi
        fi

        # === RENEWAL ===
        log_message "=== Starting renewal ==="
        if start_claude_session; then
            log_message "Session created, beginning verification..."

            local max_retries=5
            local attempt=0
            local retry_delay=30
            local verified=false

            while [ $attempt -lt $max_retries ] && [ "$verified" = false ]; do
                attempt=$((attempt + 1))
                log_message "Verification attempt $attempt/$max_retries..."

                # Wait a moment for session to register with API
                sleep 5

                verify_session_active
                local verify_ret=$?
                local minutes=$(( REMAINING_SECONDS / 60 ))

                if [ $verify_ret -eq 0 ]; then
                    log_message "✅ Renewal verified! Active session with $minutes min ($((minutes/60))h $((minutes%60))m) remaining"
                    log_message "   Timing source: $TIMING_SOURCE (API-verified)"
                    date +%s > "$LAST_ACTIVITY_FILE"
                    verified=true
                else
                    log_verification_status "$verify_ret"
                    if [ $attempt -lt $max_retries ]; then
                        case $attempt in
                            1) retry_delay=30 ;;
                            2) retry_delay=60 ;;
                            3) retry_delay=120 ;;
                            *) retry_delay=300 ;;
                        esac
                        log_message "   Retrying in $((retry_delay/60))m ${retry_delay}s..."
                        sleep $retry_delay
                    fi
                fi
            done

            if [ "$verified" = true ]; then
                log_message "=== Renewal sequence completed successfully ==="
            else
                log_message "=== Renewal sequence failed after $max_retries verification attempts ==="
                log_message "⚠️  Session may still be active - check manually with 'ccusage blocks'"
            fi
        else
            log_message "❌ Failed to create Claude session"
            sleep 60  # Brief pause before looping back on session start failure
        fi

        # Loop back to top: query ccusage for the next block's endTime
    done
}

# Start the daemon
main