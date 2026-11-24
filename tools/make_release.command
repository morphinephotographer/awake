#!/bin/bash
# awake. — build, pack DMG + zip, make the repo public and publish a GitHub release. Log: release.log
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/Library/Python/3.9/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
REPO="morphinephotographer/awake."
{
  echo "=== $(date) ==="
  sh build.sh || { echo BUILD_FAILED; exit 1; }
  VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/awake.app/Contents/Info.plist)
  mkdir -p dist

  # Retina background for the DMG window
  tiffutil -cathidpicheck tools/dmg-background.png tools/dmg-background@2x.png -out tools/dmg-background.tiff && echo TIFF_OK

  # dmgbuild lays out the window without scripting Finder
  python3 -c "import dmgbuild" 2>/dev/null || python3 -m pip install --user --quiet dmgbuild
  rm -f "dist/awake-$VER.dmg"
  python3 -m dmgbuild -s tools/dmg_settings.py -D app=build/awake.app "awake." "dist/awake-$VER.dmg" && echo "DMG_OK dist/awake-$VER.dmg"
  rm -f "dist/awake-$VER.zip"
  ditto -c -k --keepParent build/awake.app "dist/awake-$VER.zip" && echo "ZIP_OK dist/awake-$VER.zip"
  rm -f tools/dmg-background.tiff

  # Repository: public, with a description and topics
  gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences && echo PUBLIC_OK
  gh repo edit "$REPO" \
    --description "Keeps your Mac awake — right from the MacBook notch. Timers, render watcher for 70 creative apps and AI agents (Claude Code, Codex…), closed-lid mode." \
    --add-topic macos --add-topic notch --add-topic swiftui --add-topic caffeine --add-topic amphetamine \
    --add-topic keep-awake --add-topic menubar --add-topic macbook && echo META_OK

  # Commit and push the sources
  git add -A
  git commit -q -F tools/release-commit.txt && echo COMMIT_OK || echo NOTHING_TO_COMMIT
  git push -q origin HEAD && echo PUSH_OK

  # Release with both files (replace the files if the release already exists)
  if gh release view "v$VER" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VER" "dist/awake-$VER.dmg" "dist/awake-$VER.zip" --repo "$REPO" --clobber && echo RELEASE_UPDATED
  else
    gh release create "v$VER" "dist/awake-$VER.dmg" "dist/awake-$VER.zip" --repo "$REPO" \
      --title "awake. $VER" --notes-file tools/release-notes.md --latest && echo RELEASE_OK
  fi
  gh repo view "$REPO" --json visibility,description,url -q '.visibility + " " + .url'
  echo "=== done ==="
} 2>&1 | tee "$ROOT/release.log"
