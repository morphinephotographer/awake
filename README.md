# awake.

Minimal macOS app that lives in the MacBook notch and keeps the Mac awake — like Amphetamine / StayAwake.

- Hover the notch → it grows into a small panel: big ⏻ button, durations **15м · 1ч · 2ч · 4ч · ∞**.
- While active the notch shows a tiny analog clock (time left) and a countdown.
- ☀︎ keep the display on · 💻 keep working with the lid closed · ↻ launch at login · ✕ quit.

## How it works
- Sleep is prevented with IOKit power assertions (`PreventUserIdleSystemSleep`, optionally `PreventUserIdleDisplaySleep`), each with its own timeout.
- Closed-lid mode installs (once, with the admin password) a tiny root LaunchDaemon `local.morphine.awake.guard`.
  It turns `pmset disablesleep` on only while the running app renews a short request in `/Users/Shared/awake/lid-request`
  (every minute, max 5 min ahead), and turns it off when the session ends, the app quits/crashes, or the battery is ≤ 10 %.

## Build
Double-click **«Собрать и установить.command»** (builds, installs to /Applications and launches), or run `sh build.sh`.
Requires Xcode Command Line Tools, macOS 14+.

Icon: `tools/make_icon.py` (Python + Pillow) renders `tools/icon-1024.png` and `Resources/AppIcon.icns`.

## Remove the closed-lid helper
```sh
sudo launchctl bootout system/local.morphine.awake.guard
sudo rm /Library/LaunchDaemons/local.morphine.awake.guard.plist /Library/PrivilegedHelperTools/local.morphine.awake.guard
sudo pmset -a disablesleep 0
```
