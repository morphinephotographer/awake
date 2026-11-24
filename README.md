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

## 1.3 — render watcher
The ▶︎ film button in the bottom row (green = on) follows your apps; the row of icons below shows them:
dim = closed, bright = open, green dot = keeping the Mac awake. The notch ears and the top row show the app's icon and «рендер / качает / открыт».
- **Пока работает** (Photoshop, Lightroom, Bridge, Capture One, Retouch4me Dodge & Burn, Reblum, CapCut, DaVinci Resolve): all processes of the app use > 0.6 CPU core or write > 2 MB/s.
- **Пока качает** (toreo.): writes > 150 KB/s.
- **Пока открыто** (Teleo.).
Holds 2 min after the last activity. Modes per app and «Добавить программу…» — right-click → «Следить за программами».

## 1.5 — for everyone
- **Catalog** `Resources/catalog.json`: 60 known apps (photo, video, 3D, audio, downloaders) with a default mode, matched by bundle ID first, then by name. awake. checks GitHub for a newer catalog once a week (needs this repo to be public, or the file hosted elsewhere).
- **First launch:** after the animation the panel shows the apps found on this Mac — «Следить» / «Не нужно».
- **Any app that asks macOS not to sleep** (Final Cut, Compressor, HandBrake…) counts as busy.
- **Suggestions:** an unknown app that asks not to sleep or uses > 1.2 cores for a minute gets a «?» icon in the bottom row — click to follow it.
