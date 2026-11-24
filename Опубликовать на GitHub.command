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

Open watched apps now sit in the free space of the bottom row (max 3, +N),
separate icon row removed — panel back to its compact height. Auto-start by
apps is skipped when the battery is at or below the chosen limit.

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
