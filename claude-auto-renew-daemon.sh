#!/bin/bash

# Claude Auto-Renewal Daemon - Continuous Running Script
# Runs continuously in the background, checking for renewal windows

LOG_FILE="$HOME/.claude-auto-renew-daemon.log"
PID_FILE="$HOME/.claude-auto-renew-daemon.pid"
LAST_ACTIVITY_FILE="$HOME/.claude-last-activity"
START_TIME_FILE="$HOME/.claude-auto-renew-start-time"
STOP_TIME_FILE="$HOME/.claude-auto-renew-stop-time"
MESSAGE_FILE="$HOME/.claude-auto-renew-message"
DISABLE_CCUSAGE=false
SLEEP_PID=""  # Track background sleep process for graceful shutdown

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
            log_message "❌ FAILED: No timing data from ccusage or clock"
            ;;
        2)
            log_message "❌ FAILED: Clock-based only (not API-verified)"
            log_message "   Source: $TIMING_SOURCE | Estimated: $minutes min"
            ;;
        3)
            log_message "❌ FAILED: Session exists but not fresh (<4.5h)"
            log_message "   Source: $TIMING_SOURCE | Remaining: $minutes min (need >270)"
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

    # Clear daemon config file
    clear_daemon_config

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
    log_message "Starting Claude session for renewal..."
    
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
    
    # Create a persistent session by keeping stdin open for 5 hours
    # This prevents the session from closing immediately after the first response
    # Unset CLAUDECODE to allow renewal from within an existing Claude session
    (unset CLAUDECODE; { echo "$selected_message"; sleep 18000; } | claude >> "$LOG_FILE" 2>&1) &
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

# Function to calculate next check time
calculate_sleep_duration() {
    local minutes_remaining=$(get_minutes_until_reset)
    
    if [ -n "$minutes_remaining" ] && [ "$minutes_remaining" -gt 0 ]; then
        log_message "Time remaining: $minutes_remaining minutes"
        
        if [ "$minutes_remaining" -le 5 ]; then
            # Check every 30 seconds when close to reset
            echo 30
        elif [ "$minutes_remaining" -le 30 ]; then
            # Check every 2 minutes when within 30 minutes
            echo 120
        else
            # Check every 10 minutes otherwise
            echo 600
        fi
    else
        # Fallback: check based on last activity
        if [ -f "$LAST_ACTIVITY_FILE" ]; then
            local last_activity=$(cat "$LAST_ACTIVITY_FILE")
            local current_time=$(date +%s)
            local time_diff=$((current_time - last_activity))
            local remaining=$((18000 - time_diff))  # 5 hours = 18000 seconds
            
            if [ "$remaining" -le 300 ]; then  # 5 minutes
                echo 30
            elif [ "$remaining" -le 1800 ]; then  # 30 minutes
                echo 120
            else
                echo 600
            fi
        else
            # No info available, check every 5 minutes
            echo 300
        fi
    fi
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
    save_daemon_config "$DISABLE_CCUSAGE"

    log_message "=== Claude Auto-Renewal Daemon Started ==="
    log_message "PID: $$"
    log_message "Logs: $LOG_FILE"
    
    # Log ccusage status
    if [ "$DISABLE_CCUSAGE" = true ]; then
        log_message "⚠️  ccusage DISABLED - Using clock-based timing only"
    else
        log_message "✅ ccusage ENABLED - Using accurate timing when available"
    fi
    
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
    
    # Check ccusage availability
    if [ "$DISABLE_CCUSAGE" = false ] && ! get_ccusage_cmd &> /dev/null; then
        log_message "WARNING: ccusage not found. Using time-based checking."
        log_message "Install ccusage for more accurate timing: npm install -g ccusage"
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
        
        # Check if we're approaching stop time
        current_time=$(date +%s)
        stop_time_approaching=false
        
        if [ -f "$STOP_TIME_FILE" ]; then
            stop_epoch=$(cat "$STOP_TIME_FILE")
            time_until_stop=$((stop_epoch - current_time))
            
            # Don't start new renewals if stop time is within 10 minutes
            if [ "$time_until_stop" -le 600 ] && [ "$time_until_stop" -gt 0 ]; then
                stop_time_approaching=true
                minutes_until_stop=$((time_until_stop / 60))
                log_message "⚠️  Stop time approaching in ${minutes_until_stop} minutes - no new renewals"
            fi
        fi
        
        # Get minutes until reset
        minutes_remaining=$(get_minutes_until_reset)
        
        # Check if we should renew (only if not approaching stop time)
        should_renew=false
        
        if [ "$stop_time_approaching" = false ]; then
            if [ -n "$minutes_remaining" ] && [ "$minutes_remaining" -gt 0 ]; then
                if [ "$minutes_remaining" -le 2 ]; then
                    should_renew=true
                    log_message "Reset imminent ($minutes_remaining minutes), preparing to renew..."
                fi
            else
                # Fallback check
                if [ -f "$LAST_ACTIVITY_FILE" ]; then
                    last_activity=$(cat "$LAST_ACTIVITY_FILE")
                    current_time=$(date +%s)
                    time_diff=$((current_time - last_activity))
                    
                    if [ $time_diff -ge 18000 ]; then
                        should_renew=true
                        log_message "5 hours elapsed since last activity, renewing..."
                    fi
                else
                    # No activity recorded, safe to start
                    should_renew=true
                    log_message "No previous activity recorded, starting initial session..."
                fi
            fi
        fi
        
        # Perform renewal if needed
        if [ "$should_renew" = true ]; then
            log_message "=== Starting renewal attempt sequence ==="

            # Wait for the old block to expire and the new block to be 1 minute old.
            # Triggering inside the dying old block causes immediate verification failure
            # ("not fresh enough") and a gap at the hour boundary ("no timing data").
            # By waiting until we're 1 minute into the new block, the session is created
            # in a fresh 5-hour window and verification succeeds on the first attempt.
            get_remaining_time
            local wait_for_new_block=$((REMAINING_SECONDS + 60))  # old block + 1 min into new
            log_message "Waiting ${wait_for_new_block}s for new billing block to be established..."
            sleep "$wait_for_new_block"

            # Create the session ONCE (now inside the fresh new billing block)
            log_message "Creating persistent Claude session..."
            if start_claude_session; then
                log_message "Session created, beginning verification loop..."

                # Retry configuration
                local max_retries=20  # ~30 minutes of retries
                local attempt=0
                local retry_delay=30  # Start with 30 seconds
                local verified=false

                # Verification retry loop with exponential backoff
                while [ $attempt -lt $max_retries ] && [ "$verified" = false ]; do
                    attempt=$((attempt + 1))

                    # Check if stop time approaching (but don't abort - user preference)
                    local current_epoch=$(date +%s)
                    if [ -f "$STOP_TIME_FILE" ]; then
                        local stop_epoch=$(cat "$STOP_TIME_FILE")
                        local time_until_stop=$((stop_epoch - current_epoch))
                        if [ "$time_until_stop" -gt 0 ] && [ "$time_until_stop" -lt 600 ]; then
                            log_message "⚠️  Stop time in $((time_until_stop / 60)) minutes, continuing verification attempts..."
                        fi
                    fi

                    log_message "Verification attempt $attempt/$max_retries..."

                    # Wait a moment for session to register with API
                    sleep 5

                    # Verify session is actually active
                    verify_session_active
                    local verify_ret=$?

                    # Get verification details
                    local minutes=$((REMAINING_SECONDS / 60))

                    if [ $verify_ret -eq 0 ]; then
                        # Success - verified active session
                        log_message "✅ Renewal verified! Active session with $minutes minutes ($((minutes / 60))h $((minutes % 60))m) remaining"
                        log_message "   Timing source: $TIMING_SOURCE (API-verified)"

                        # Update activity file now that we've confirmed success
                        date +%s > "$LAST_ACTIVITY_FILE"

                        verified=true

                        # Sleep for 5 minutes after successful renewal
                        sleep 300
                    else
                        # Verification failed - log details
                        case $verify_ret in
                            1)
                                log_message "❌ Verification failed: No timing data available"
                                log_message "   ccusage may not be detecting an active session"
                                ;;
                            2)
                                log_message "❌ Verification failed: Only clock-based timing available"
                                log_message "   Timing source: $TIMING_SOURCE (not API-verified)"
                                log_message "   Estimated remaining: $minutes minutes"
                                ;;
                            3)
                                log_message "❌ Verification failed: Session not fresh enough"
                                log_message "   Timing source: $TIMING_SOURCE"
                                log_message "   Remaining: $minutes minutes (need >270 for fresh renewal)"
                                ;;
                        esac

                        # Check if a manual session might exist
                        if [ $verify_ret -eq 0 ] || [ "$minutes" -gt 60 ]; then
                            log_message "   Possible manual session detected - stopping verification loop"
                            verified=true  # Treat as resolved
                            break
                        fi

                        # Calculate next retry delay with exponential backoff
                        if [ $attempt -lt $max_retries ]; then
                            # Backoff schedule: 30s, 60s, 120s, 300s, then 300s fixed
                            case $attempt in
                                1) retry_delay=30 ;;
                                2) retry_delay=60 ;;
                                3) retry_delay=120 ;;
                                *) retry_delay=300 ;;
                            esac

                            log_message "   Will retry verification in $((retry_delay / 60)) minutes ($retry_delay seconds)..."
                            sleep $retry_delay
                        fi
                    fi
                done

                # Final outcome logging
                if [ "$verified" = true ]; then
                    log_message "=== Renewal sequence completed successfully ==="
                else
                    log_message "=== Renewal sequence failed after $max_retries verification attempts ==="
                    log_message "⚠️  Session created but could not verify via ccusage API"
                    log_message "⚠️  Session may still be active - check manually with 'ccusage blocks'"
                fi
            else
                log_message "❌ Failed to create Claude session - aborting renewal"
            fi
        fi
        
        # Calculate how long to sleep
        sleep_duration=$(calculate_sleep_duration)
        log_message "Next check in $((sleep_duration / 60)) minutes"

        # Sleep until next check (event-driven approach for instant shutdown)
        sleep "$sleep_duration" &
        SLEEP_PID=$!
        wait "$SLEEP_PID" 2>/dev/null
        SLEEP_PID=""  # Clear after wait completes
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --disableccusage)
            DISABLE_CCUSAGE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Start the daemon
main