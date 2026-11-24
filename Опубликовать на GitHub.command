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

Notch ear moved to the right (app icons while rendering, otherwise time left),
analog clock removed, left side always free. Hover an app icon -> popover on
how awake. treats it. ⋯ button with a simplified options menu. ⌘Q while the
panel is open under the pointer. Launch animation of the notch.

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
