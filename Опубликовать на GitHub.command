#!/bin/bash
# awake. — commit everything and push to GitHub (private repo morphinephotographer/awake.). Log: publish.log
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1
REPO="morphinephotographer/awake."
{
  echo "=== $(date) ==="
  [ -d .git ] || git init -b main
  git add -A
  git commit -q -m "awake. $(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

Auto-on while chosen apps are open, «while working» mode (CPU/network),
until-time, ±15 min by scroll, +15 before the end, battery limit for all
modes, ⌥⌘A hotkey, click ears to stop, awake:// links for Shortcuts,
uninstall the lid helper — all in the right-click menu, design unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_014WsSJBqUtcoU9dVQdZn5wN" && echo COMMIT_OK || echo NOTHING_TO_COMMIT
  if git remote get-url origin >/dev/null 2>&1; then
    git push -u origin HEAD && echo PUSH_OK
  elif gh repo view "$REPO" >/dev/null 2>&1; then
    git remote add origin "https://github.com/$REPO.git" && git push -u origin HEAD && echo PUSH_OK
  else
    gh repo create "$REPO" --private --source . --remote origin --push && echo CREATED_AND_PUSHED
  fi
  git log --oneline -3
  echo "=== done ==="
} 2>&1 | tee "$HERE/publish.log"
