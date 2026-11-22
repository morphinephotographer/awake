#!/bin/bash
# awake. — собрать, установить в /Applications, запустить и упаковать в dist/awake-<версия>.zip. Лог: build.log
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
{
  echo "=== $(date) ==="
  if sh build.sh; then
    pkill -x Awake && sleep 0.7
    rm -rf /Applications/awake.app
    ditto build/awake.app /Applications/awake.app && touch /Applications/awake.app && echo INSTALLED
    VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/awake.app/Contents/Info.plist)
    mkdir -p dist
    rm -f "dist/awake-$VER.zip"
    ditto -c -k --keepParent build/awake.app "dist/awake-$VER.zip" && echo "ZIP_OK dist/awake-$VER.zip"
    open /Applications/awake.app
    sleep 2
    pgrep -x Awake >/dev/null && echo LAUNCHED_OK || echo NOT_RUNNING
  else
    echo BUILD_FAILED
  fi
  echo "=== done ==="
} 2>&1 | tee "$HERE/build.log"
