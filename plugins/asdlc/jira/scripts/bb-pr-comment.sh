#!/usr/bin/env bash
# Post a comment on a Bitbucket PR. Text from $2, from --file, or piped via stdin.
# Usage: bb-pr-comment.sh <pr-id> "text"   |   echo "text" | bb-pr-comment.sh <pr-id>
#        bb-pr-comment.sh <pr-id> --file plans/<KEY>/review-brief.md
# The first line must start with "[asdlc] " (exit 2 otherwise). A first line starting
# "[asdlc] Human review:" is refused unless --record is given; only /asdlc:review-tour passes it.
# --file reads the text from a regular file under plans/ (no symlinks, not empty, at most 32 KB).
# The text is never printed.
# Over a Bitbucket MCP server (BB_TRANSPORT=mcp, see lib.sh and jira/mcp/bitbucket-<profile>.json):
#   bb-pr-comment.sh --mcp-args <pr-id> "text"   # opens a request, prints the one call to make
#   bb-pr-comment.sh --from-mcp <pr-id>          # prints "Posted comment to PR <id>" once the capture is there
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_refuse_test_modes "bb-pr-comment.sh"
MCP=""; RECORD=""; FILE=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mcp-args) MCP=args; shift ;;
    --from-mcp) MCP=from; shift ;;
    --record)   RECORD=1; shift ;;
    --file)     [ $# -ge 2 ] || { echo "--file needs a path under plans/" >&2; exit 2; }; FILE="$2"; shift 2 ;;
    *)          POS+=("$1"); shift ;;
  esac
done
set -- ${POS[@]+"${POS[@]}"}
if [ -z "$MCP" ]; then
  asdlc_bb_mcp_check || exit 2
  [ "$BB_TRANSPORT" = rest ] || { echo "BB_TRANSPORT=mcp: run bb-pr-comment.sh --mcp-args, make the call it prints, then bb-pr-comment.sh --from-mcp" >&2; exit 2; }
  asdlc_need_bb
fi
PR="${1:?usage: bb-pr-comment.sh <pr-id> [text | --file <path>]}"
if [ -n "$MCP" ]; then [[ $PR =~ ^[0-9]{1,18}$ ]] || { echo "pr-id must be a number" >&2; exit 2; }; fi
if [ "$MCP" = from ]; then asdlc_bb_mcp_take pr_comment >/dev/null || exit 1; echo "Posted comment to PR $PR"; exit 0; fi

# --file: a regular file under plans/, reached without a symlink or a ../ step.
file_refuse() { echo "--file: $1" >&2; exit 2; }
read_file_text() {  # <path> -> TEXT
  local f="$1" top size
  top="$(pwd -P)"
  case "$f" in "$top"/*) f="${f#"$top"/}" ;; /*) file_refuse "'$f' is outside plans/" ;; esac
  case "$f" in plans/*) ;; *) file_refuse "'$f' is outside plans/" ;; esac
  asdlc_plain_walk "$f" file_refuse   # no '..', '.', '//' or symlink part (review-lib.sh)
  [ -f "$f" ] || file_refuse "'$f' is not a regular file"
  # Read once, capped: a swap after a separate size check can't get past the limit.
  TEXT="$(head -c 32769 < "$f"; printf x)"; TEXT="${TEXT%x}"
  size="$(printf '%s' "$TEXT" | wc -c | tr -d ' ')"
  [ "$size" -gt 0 ] || file_refuse "'$f' is empty"
  [ "$size" -le 32768 ] || file_refuse "'$f' is over the limit of 32768 bytes"
}
if [ -n "$FILE" ]; then
  [ "${2:-}" = "" ] || { echo "--file and text are exclusive" >&2; exit 2; }
  read_file_text "$FILE"
elif [ "${2:-}" != "" ]; then TEXT="$2"; else TEXT="$(cat)"; fi

# The marker rule (D-H5): judged on the first line only, and never echoed back.
FIRST="${TEXT%%$'\n'*}"
case "$FIRST" in
  "$ASDLC_PR_MARKER"*) ;;
  *) echo "refused: the comment's first line must start with \"${ASDLC_PR_MARKER}\"" >&2; exit 2 ;;
esac
case "$FIRST" in
  "$ASDLC_HR_PREFIX"*) [ -n "$RECORD" ] || { echo "refused: a \"${ASDLC_HR_PREFIX}\" comment is only posted by /asdlc:review-tour (--record)" >&2; exit 2; } ;;
esac

if [ "$MCP" = args ]; then
  asdlc_bb_mcp_open pr_comment "$(jq -nc --arg w "$BB_WORKSPACE" --arg r "$BB_REPO" --arg p "$PR" --arg t "$TEXT" '{workspace:$w, repo:$r, pr:$p, text:$t}')"
  exit 0
fi

asdlc_send_json bb POST "/repositories/${BB_WORKSPACE}/${BB_REPO}/pullrequests/${PR}/comments" \
  "$(jq -n --arg r "$TEXT" '{content:{raw:$r}}')" >/dev/null
echo "Posted comment to PR $PR"
