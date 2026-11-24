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

## 1.2 — extras (right-click the expanded panel)
- **Автовключение, пока открыто** — pick apps (Capture One, DaVinci Resolve, toreo. …); awake. turns on while any of them runs.
- **Пока идёт работа** — stays awake while CPU > 25 % or network > 300 KB/s, ends after 3 min of calm.
- **До времени** — until the next whole hours.
- **±15 минут** — also by scrolling over the panel or the notch ears; one minute before the end the panel pops up with **+15м**.
- **Выключать при заряде батареи** — never / 10 / 20 / 30 % (all modes).
- **⌥⌘A** toggles from anywhere; **click the ears** of the notch to stop.
- Links for the Shortcuts app: `awake://toggle`, `awake://stop`, `awake://start?minutes=90`, `awake://until?time=18:30`, `awake://activity`.
