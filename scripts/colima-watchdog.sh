#!/bin/bash
# =============================================================
# colima-watchdog.sh
# Keeps Colima running under LaunchAgent supervision.
# - If Colima is not running, starts it in foreground mode so
#   launchd can track the process and auto-restart on crash.
# - If Colima is already running, sleeps indefinitely so the
#   LaunchAgent stays alive but idle.
# =============================================================

set -e

if ! /opt/homebrew/bin/colima status 2>/dev/null | grep -q 'colima is running'; then
  exec /opt/homebrew/bin/colima start --foreground
fi

# Colima is already running — stay alive so launchd can keep tracking
while true; do
  # Periodically verify Colima is still running
  if ! /opt/homebrew/bin/colima status 2>/dev/null | grep -q 'colima is running'; then
    exec /opt/homebrew/bin/colima start --foreground
  fi
  sleep 60
done
