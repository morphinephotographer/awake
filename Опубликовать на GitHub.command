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
  git commit -q -m "awake. 1.1.0 — notch app that keeps the Mac awake

Notch panel with power button and durations, analog countdown clock,
keep-display, closed-lid mode (root guard + pmset disablesleep),
launch at login, white app icon.

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
