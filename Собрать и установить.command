#!/bin/bash
# awake. — собрать, установить в /Applications и запустить. Лог: build.log
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
{
  echo "=== $(date) ==="
  if sh build.sh; then
    pkill -x Awake && sleep 0.7
    rm -rf /Applications/awake.app
    ditto build/awake.app /Applications/awake.app && touch /Applications/awake.app && echo INSTALLED
    open /Applications/awake.app
    sleep 2
    pgrep -x Awake >/dev/null && echo LAUNCHED_OK || echo NOT_RUNNING
  else
    echo BUILD_FAILED
  fi
  echo "=== done ==="
} 2>&1 | tee "$HERE/build.log"
