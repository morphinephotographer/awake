#!/bin/sh
# Installs the awake. lid guard (run as root by the app, after the macOS password prompt).
# Usage: install-guard.sh <uid> <resources-dir>
set -eu
UID_ARG="$1"; RES="$2"
case "$UID_ARG" in *[!0-9]* | "") echo "bad uid" >&2; exit 2 ;; esac
HELPER=/Library/PrivilegedHelperTools/local.morphine.awake.guard
PLIST=/Library/LaunchDaemons/local.morphine.awake.guard.plist
install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
sed "s/__ALLOWED_UID__/$UID_ARG/" "$RES/awake-guard.sh" > "$HELPER.tmp"
chown root:wheel "$HELPER.tmp"; chmod 755 "$HELPER.tmp"; mv -f "$HELPER.tmp" "$HELPER"
cp "$RES/local.morphine.awake.guard.plist" "$PLIST.tmp"
chown root:wheel "$PLIST.tmp"; chmod 644 "$PLIST.tmp"; mv -f "$PLIST.tmp" "$PLIST"
launchctl bootout system/local.morphine.awake.guard 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo installed
