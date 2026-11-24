#!/bin/sh
set -eu
cd "$(dirname "$0")"
APP="build/awake.app"
mkdir -p build/.module-cache
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns build/AppIcon.icns
elif [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  if xcrun swift tools/MakeIcon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns; then
    echo ICON_OK
  else
    echo ICON_SKIPPED
  fi
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cp Resources/awake-guard.sh Resources/install-guard.sh Resources/uninstall-guard.sh Resources/local.morphine.awake.guard.plist "$APP/Contents/Resources/"

xcrun swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" -module-cache-path build/.module-cache \
  Sources/*.swift -o "$APP/Contents/MacOS/Awake"
codesign --force --sign - "$APP"
echo "BUILD_OK $APP"
