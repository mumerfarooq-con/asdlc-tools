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
# asdlc_need_key and asdlc_need_dir (review-lib.sh) report through die2.
SHA_RE='^[0-9a-f]{40}$'
case "${1:-}" in
  add)
    shift
    KEY="${1:-}"; PR="${2:-}"; SHA="${3:-}"; shift 3 2>/dev/null || die2 "usage: review-record.sh add <KEY> <PR_ID> <sha40> <path:start-end>..."
    asdlc_need_key "$KEY"
    [[ $PR =~ ^[0-9]{1,18}$ ]] || die2 "PR id must be a number"
    [[ $SHA =~ $SHA_RE ]] || die2 "sha must be 40 lowercase hex characters"
    [ $# -gt 0 ] || die2 "give at least one hunk (path:start-end)"
    for h in "$@"; do asdlc_valid_hunk "$h" || die2 "bad hunk '$(printf '%s' "$h" | tr -cd '[:print:]')': want path:start-end, a relative path with no '..', no leading '-', no spaces or commas"; done
    D="$(asdlc_need_dir "$KEY")"
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
    asdlc_need_key "$KEY"
    [ -z "$PR" ] || [[ $PR =~ ^[0-9]{1,18}$ ]] || die2 "PR id must be a number"
    D="$(asdlc_need_dir "$KEY")"
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
