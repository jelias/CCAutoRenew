#!/bin/bash

set -e

echo "=========================================="
echo "Claude Auto-Renew Daemon"
echo "=========================================="
echo "Start time: ${START_HOUR:-6}:00"
echo "Stop time: ${END_HOUR:-17}:00"
echo "API Key: ${ANTHROPIC_API_KEY:0:20}..."
echo "=========================================="

START_TIME=$(printf "%02d:00" "${START_HOUR:-6}")
STOP_TIME=$(printf "%02d:00" "${END_HOUR:-17}")

echo "Configuring daemon for $START_TIME - $STOP_TIME..."

./claude-daemon-manager.sh start --at "$START_TIME" --stop "$STOP_TIME"

echo "Daemon started. Use 'docker exec <container> ./claude-daemon-manager.sh status' to check."

tail -f /dev/null
