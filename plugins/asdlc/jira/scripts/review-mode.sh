#!/usr/bin/env bash
# Decide PR review depth from the ACTUAL diff against the base branch.
# Prints exactly one word, "council" or "solo", on stdout; a one-line reason on
# stderr ("review-mode: <mode> — <reason>").
# Usage: review-mode.sh [base-branch] [head-ref] [issue_type] [labels_csv]
# base-branch defaults to TARGET_BRANCH. Thresholds come from .asdlc/jira.conf:
#   REVIEW_COUNCIL_FILES  (default 10)   files changed >= this  -> council
#   REVIEW_COUNCIL_LINES  (default 400)  lines changed >= this  -> council
#   REVIEW_COUNCIL_PATHS  (regex)        any changed path matching -> council
#                                        (empty = no path rule)
# Fails closed: if the diff can't be measured (a ref doesn't resolve, git or
# grep errors, a bad threshold or regex) the answer is "council" with the
# reason, never "solo". Exit 2 only when a ref has invalid syntax.
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

# Refs, patterns and thresholds come from the config or the caller, so show
# them printable-only (no terminal escapes in our own message).
printable() { printf '%s' "$1" | tr -cd '[:print:]'; }
# Can't tell how big or risky the change is: be strict, say why.
council_because() { echo "council"; echo "review-mode: council — $*" >&2; exit 0; }
bad_ref() { echo "review-mode: $*" >&2; exit 2; }

# Refs: reject a leading '-' first (check-ref-format would read it as an
# option), then require valid branch-name syntax for the base. After this only
# commit SHAs reach git, so nothing from a config can act as an option.
case "$BASE" in -*) bad_ref "invalid base ref '$(printable "$BASE")': must not start with '-'" ;; esac
git check-ref-format --branch "$BASE" >/dev/null 2>&1 \
  || bad_ref "invalid base ref '$(printable "$BASE")': not a valid branch name"
case "$HEAD_REF" in -*) bad_ref "invalid head ref '$(printable "$HEAD_REF")': must not start with '-'" ;; esac

# Thresholds must be positive integers (at most 9 digits, so test(1) can't
# overflow); anything else would fall through to "solo" in the comparisons.
for pair in "REVIEW_COUNCIL_FILES:$FILES_MAX" "REVIEW_COUNCIL_LINES:$LINES_MAX"; do
  v="${pair#*:}"
  if ! [[ $v =~ ^[1-9][0-9]*$ ]] || [ "${#v}" -gt 9 ]; then
    council_because "${pair%%:*} '$(printable "$v")' is not a positive integer"
  fi
done

resolve() { git rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null; }
base_sha="$(resolve "$BASE")" || council_because "base '$(printable "$BASE")' not found (fetch it?)"
head_sha="$(resolve "$HEAD_REF")" || council_because "head '$(printable "$HEAD_REF")' not found"
mb="$(git merge-base "$base_sha" "$head_sha" 2>/dev/null)" \
  || council_because "no merge base between '$(printable "$BASE")' and '$(printable "$HEAD_REF")'"
files="$(git diff --name-only "$mb" "$head_sha" 2>/dev/null)" || council_because "git diff failed"
numstat="$(git diff --numstat "$mb" "$head_sha" 2>/dev/null)" || council_because "git diff failed"
files="$(printf '%s\n' "$files" | sed '/^$/d')"
nfiles="$(printf '%s\n' "$files" | grep -c . || true)"
adddel="$(printf '%s\n' "$numstat" | awk '{a+=($1=="-"?0:$1); d+=($2=="-"?0:$2)} END{print a+0, d+0}')"
nlines=$(( ${adddel% *} + ${adddel#* } ))

# An empty pattern is "no path rule" (as an -e pattern it would match every
# path). grep exits 2 on a bad regex; 1 only means "no match".
hits=""
if [ -n "$SENSITIVE" ]; then
  rc=0; hits="$(printf '%s\n' "$files" | grep -Ei -e "$SENSITIVE" 2>/dev/null)" || rc=$?
  [ "$rc" -le 1 ] || council_because "REVIEW_COUNCIL_PATHS is not a valid regex: '$(printable "$SENSITIVE")'"
fi

mode="solo"; reason="$nfiles files / $nlines lines — within thresholds"
if   [ -n "$hits" ]; then mode="council"; reason="sensitive paths: $(printf '%s' "$hits" | tr '\n' ' ' | sed 's/ *$//')"
elif [ "$nfiles" -ge "$FILES_MAX" ]; then mode="council"; reason="$nfiles files changed (>= $FILES_MAX)"
elif [ "$nlines" -ge "$LINES_MAX" ]; then mode="council"; reason="$nlines lines changed (>= $LINES_MAX)"
elif printf '%s' "$ITYPE" | grep -qiE '^(epic|story)$'; then mode="council"; reason="issue type $ITYPE"
elif printf ',%s,' "$LABELS" | grep -qiE ',[[:space:]]*large[[:space:]]*,'; then mode="council"; reason="labelled large"
fi

echo "$mode"
echo "review-mode: $mode — $reason" >&2
