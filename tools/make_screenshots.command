#!/bin/bash
# awake. — draws the real panel into PNGs (the running app does it via awake://snapshot)
# and copies them to docs/shots for the README. Log: shots.log
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
{
  echo "=== $(date) ==="
  rm -rf /Users/Shared/awake/shots
  pgrep -x Awake >/dev/null || { open /Applications/awake.app; sleep 6; }
  open "awake://snapshot"
  for i in $(seq 1 20); do
    [ "$(ls /Users/Shared/awake/shots/*.png 2>/dev/null | wc -l)" -ge 6 ] && break
    sleep 0.5
  done
  mkdir -p docs/shots
  cp /Users/Shared/awake/shots/*.png docs/shots/ && echo SHOTS_OK
  ls -l docs/shots
  echo "=== done ==="
} 2>&1 | tee "$ROOT/shots.log"
