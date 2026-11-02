#!/usr/bin/env bash
# The human-review record store. No network. Only /asdlc:review-tour writes records, and only for
# hunks the user answered. The record is an honesty aid, not a security control: a model could forge it.
# Usage:
#   review-record.sh add <KEY> <PR_ID> <sha40> <path:start-end>...
#       appends one JSON line to plans/<KEY>/human-review.jsonl, writes the PR comment text to
#       plans/<KEY>/human-review.comment.md and prints that path (post it: bb-pr-comment.sh --record --file)
#   review-record.sh last <KEY> [<PR_ID>]   prints the sha of the newest record (for that PR), or nothing
#   review-record.sh parse-comment          reads one comment body on stdin; prints the sha if its first
#                                           line is "[asdlc] Human review: hunks <h>, ... at <sha40>", else exit 1
set -euo pipefail
. "$(dirname "$0")/lib.sh"

die2() { echo "review-record: $*" >&2; exit 2; }
need_key() { asdlc_is_key "${1:-}" || die2 "'${1:-}' is not a ticket key like PROJ-1"; }
need_dir() {  # <KEY> -> prints plans/<KEY>; refuses a symlinked plans or plans/<KEY>
  local d="plans/$1"
  [ ! -L plans ] || die2 "plans is a symlink"
  [ ! -L "$d" ] || die2 "$d is a symlink"
  printf '%s' "$d"
}
SHA_RE='^[0-9a-f]{40}$'
# <path>:<start>-<end>. The path stays free of whitespace, commas and control characters, so the
# comment line "hunks <h1>, <h2> at <sha>" always parses back.
valid_hunk() {
  local h="$1" path rest s e comp
  [[ $h =~ ^(.+):([0-9]+)-([0-9]+)$ ]] || return 1
  path="${BASH_REMATCH[1]}"; s="${BASH_REMATCH[2]}"; e="${BASH_REMATCH[3]}"
  [ "${#s}" -le 9 ] && [ "${#e}" -le 9 ] || return 1
  [ "$((10#$s))" -ge 1 ] && [ "$((10#$s))" -le "$((10#$e))" ] || return 1
  case "$path" in /*|-*|*[[:space:],]*) return 1 ;; esac
  [ -z "$(printf '%s' "$path" | tr -d '[:print:]')" ] || return 1
  rest="$path"
  while :; do
    comp="${rest%%/*}"
    case "$comp" in ''|..) return 1 ;; esac
    [ "$comp" != "$rest" ] || break
    rest="${rest#*/}"
  done
  return 0
}

case "${1:-}" in
  add)
    shift
    KEY="${1:-}"; PR="${2:-}"; SHA="${3:-}"; shift 3 2>/dev/null || die2 "usage: review-record.sh add <KEY> <PR_ID> <sha40> <path:start-end>..."
    need_key "$KEY"
    [[ $PR =~ ^[0-9]{1,18}$ ]] || die2 "PR id must be a number"
    [[ $SHA =~ $SHA_RE ]] || die2 "sha must be 40 lowercase hex characters"
    [ $# -gt 0 ] || die2 "give at least one hunk (path:start-end)"
    for h in "$@"; do valid_hunk "$h" || die2 "bad hunk '$(printf '%s' "$h" | tr -cd '[:print:]')': want path:start-end, a relative path with no '..', no leading '-', no spaces or commas"; done
    D="$(need_dir "$KEY")"
    mkdir -p "$D"
    for f in "$D/human-review.jsonl" "$D/human-review.comment.md"; do [ ! -L "$f" ] || die2 "$f is a symlink"; done
    jq -nc --argjson pr "$PR" --arg sha "$SHA" --argjson at "$(date +%s)" \
      '{v:1, pr:$pr, sha:$sha, hunks:$ARGS.positional, at:$at}' --args "$@" >> "$D/human-review.jsonl"
    list=""; for h in "$@"; do list="${list:+$list, }$h"; done
    printf '%s hunks %s at %s\nReviewed in /asdlc:review-tour. This record is written by the reviewer'"'"'s own tooling.\n' \
      "$ASDLC_HR_PREFIX" "$list" "$SHA" > "$D/human-review.comment.md"
    echo "$D/human-review.comment.md"
    ;;
  last)
    KEY="${2:-}"; PR="${3:-}"
    need_key "$KEY"
    [ -z "$PR" ] || [[ $PR =~ ^[0-9]{1,18}$ ]] || die2 "PR id must be a number"
    D="$(need_dir "$KEY")"
    [ -f "$D/human-review.jsonl" ] || exit 0
    # Newest = last line. Lines that don't parse, or lack a 40-hex sha, are skipped.
    jq -Rr --arg pr "${PR:-}" 'fromjson? | select(type == "object" and (.sha | type) == "string" and (.sha | test("^[0-9a-f]{40}$")))
        | select($pr == "" or ((.pr | tostring) == $pr)) | .sha' "$D/human-review.jsonl" | tail -n 1
    ;;
  parse-comment)
    IFS= read -r line || [ -n "$line" ] || exit 1
    line="${line%$'\r'}"
    re="^\\[asdlc\\] Human review: hunks .+ at ([0-9a-f]{40})\$"
    [[ $line =~ $re ]] || exit 1
    printf '%s\n' "${BASH_REMATCH[1]}"
    ;;
  *) echo "usage: review-record.sh add|last|parse-comment ..." >&2; exit 2 ;;
esac
