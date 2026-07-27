#!/bin/bash
# =============================================================
# colima-watchdog.sh
# Keeps Colima running under LaunchAgent supervision.
# =============================================================

while true; do
  STATUS=$(/opt/homebrew/bin/colima status 2>/dev/null)
  if echo "$STATUS" | grep -q 'colima is running'; then
    sleep 60
  else
    exec /opt/homebrew/bin/colima start --foreground
  fi
done
