#!/bin/sh
# awake. lid guard — runs as root from launchd (local.morphine.awake.guard).
# Keeps `pmset disablesleep` on ONLY while awake. of ALLOWED_UID holds a live,
# short request (the app renews it every minute), and turns it off as soon as
# that stops: deadline passed, app quit/crashed, request removed, battery <= 10 %.
# It only turns off what it turned on itself (marker file).
PATH=/usr/bin:/bin:/usr/sbin:/sbin
ALLOWED_UID=__ALLOWED_UID__
DIR=/Users/Shared/awake
REQ="$DIR/lid-request"
MARK=/var/db/local.morphine.awake.guard.active
MAX_AHEAD=660

want=0
if [ -d "$DIR" ] && [ ! -L "$DIR" ] && [ -f "$REQ" ] && [ ! -L "$REQ" ] \
   && [ "$(stat -f %u "$DIR")" = "$ALLOWED_UID" ] && [ "$(stat -f %u "$REQ")" = "$ALLOWED_UID" ]; then
  line=$(head -c 64 "$REQ" | head -n 1)
  deadline=${line%% *}
  pid=${line##* }
  case "$deadline:$pid" in
    *[!0-9:]* | :* | *:) ;;
    *)
      now=$(date +%s)
      if [ "$deadline" -gt "$now" ] && [ "$deadline" -le $((now + MAX_AHEAD)) ] \
         && [ "$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$ALLOWED_UID" ] \
         && ps -o comm= -p "$pid" 2>/dev/null | grep -Eq '(^|/)Awake$'; then
        want=1
      fi
      ;;
  esac
fi

if [ "$want" = 1 ]; then
  batt=$(pmset -g batt)
  case "$batt" in
    *"Battery Power"*)
      pct=$(printf '%s\n' "$batt" | grep -Eo '[0-9]+%' | head -n 1 | tr -d '%')
      if [ -n "$pct" ] && [ "$pct" -le 10 ]; then want=0; fi
      ;;
  esac
fi

current=$(pmset -g | awk '/SleepDisabled/ {print $2; exit}')
if [ "$want" = 1 ]; then
  [ "$current" = 1 ] || pmset -a disablesleep 1
  touch "$MARK"
elif [ -f "$MARK" ]; then
  [ "$current" = 0 ] || pmset -a disablesleep 0
  rm -f "$MARK"
fi
exit 0
