#!/usr/bin/env bash
# Run every Jira-leg script test. Offline: needs bash, git and jq only.
# Usage: tests/jira/run.sh [test-name-substring]
set -u
cd "$(dirname "$0")" || exit 1
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
failed=0; ran=0
for f in test-*.sh; do
  case "$f" in *"${1:-}"*) ;; *) continue ;; esac
  ran=$((ran + 1))
  bash "$f" || failed=$((failed + 1))
done
echo "---"
echo "$ran test file(s), $failed failed"
[ "$failed" -eq 0 ]
