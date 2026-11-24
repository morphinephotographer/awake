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

Launch animation «Восход» (soft dawn + 1-px line). Built-in catalog of 60 apps
matched by bundle ID (Resources/catalog.json, refreshed weekly), first-launch card
with the apps found on this Mac, apps that hold their own sleep assertion count
as busy, suggestions for busy unknown apps, version and author in the menu.

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
