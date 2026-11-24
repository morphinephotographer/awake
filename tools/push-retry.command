#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
{
  echo "=== $(date) ==="
  gh api repos/morphinephotographer/awake. -q '"visibility=" + .visibility + " disabled=" + (.disabled|tostring) + " archived=" + (.archived|tostring)'
  for i in 1 2 3; do git push -q origin HEAD && { echo PUSH_OK; break; }; sleep 10; done
  gh release view v1.5.0 --repo morphinephotographer/awake. --json assets -q '.assets[].name'
  git log --oneline -2
  echo "=== done ==="
} 2>&1 | tee push.log
