#!/usr/bin/env bash
# Decide PR review depth from the ACTUAL diff against the base branch.
# Prints "council" or "solo" on stdout; a one-line reason on stderr.
# Usage: review-mode.sh [base-branch] [head-ref] [issue_type] [labels_csv]
# base-branch defaults to TARGET_BRANCH. Thresholds come from .asdlc/jira.conf:
#   REVIEW_COUNCIL_FILES  (default 10)   files changed >= this  -> council
#   REVIEW_COUNCIL_LINES  (default 400)  lines changed >= this  -> council
#   REVIEW_COUNCIL_PATHS  (regex)        any changed path matching -> council
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ASDLC_CONF_OPTIONAL=1 asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
BASE="${1:-$TARGET_BRANCH}"
[ -n "$BASE" ] || asdlc_die "pass a base branch or set TARGET_BRANCH in $ASDLC_CONF_FILE"
HEAD_REF="${2:-HEAD}"
ITYPE="${3:-}"; LABELS="${4:-}"

FILES_MAX="$REVIEW_COUNCIL_FILES"
LINES_MAX="$REVIEW_COUNCIL_LINES"
SENSITIVE="$REVIEW_COUNCIL_PATHS"

mb="$(git merge-base "$BASE" "$HEAD_REF" 2>/dev/null || echo "$BASE")"
files="$(git diff --name-only "$mb" "$HEAD_REF" 2>/dev/null | sed '/^$/d' || true)"
nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
read -r add del < <(git diff --numstat "$mb" "$HEAD_REF" 2>/dev/null | awk '{a+=($1=="-"?0:$1); d+=($2=="-"?0:$2)} END{print a+0, d+0}')
nlines=$(( add + del ))
hits="$(printf '%s\n' "$files" | grep -Ei "$SENSITIVE" || true)"

mode="solo"; reason="$nfiles files / $nlines lines — within thresholds"
if   [ -n "$hits" ]; then mode="council"; reason="sensitive paths: $(printf '%s' "$hits" | tr '\n' ' ' | sed 's/ *$//')"
elif [ "$nfiles" -ge "$FILES_MAX" ]; then mode="council"; reason="$nfiles files changed (>= $FILES_MAX)"
elif [ "$nlines" -ge "$LINES_MAX" ]; then mode="council"; reason="$nlines lines changed (>= $LINES_MAX)"
elif printf '%s' "$ITYPE" | grep -qiE '^(epic|story)$'; then mode="council"; reason="issue type $ITYPE"
elif printf ',%s,' "$LABELS" | grep -qiE ',[[:space:]]*large[[:space:]]*,'; then mode="council"; reason="labelled large"
fi

echo "$mode"
echo "review-mode: $mode — $reason" >&2
