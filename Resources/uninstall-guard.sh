#!/bin/sh
# Removes the awake. lid guard (run as root by the app after the macOS password prompt).
launchctl bootout system/local.morphine.awake.guard 2>/dev/null || true
rm -f /Library/LaunchDaemons/local.morphine.awake.guard.plist /Library/PrivilegedHelperTools/local.morphine.awake.guard
if [ -f /var/db/local.morphine.awake.guard.active ]; then
  pmset -a disablesleep 0
  rm -f /var/db/local.morphine.awake.guard.active
fi
echo removed
