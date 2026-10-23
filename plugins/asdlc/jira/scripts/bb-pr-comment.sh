#!/usr/bin/env bash
# Post a comment on a Bitbucket PR. Text from $2, or piped via stdin.
# Usage: bb-pr-comment.sh <pr-id> "text"   |   echo "text" | bb-pr-comment.sh <pr-id>
# Over a Bitbucket MCP server (BB_TRANSPORT=mcp, see lib.sh and jira/mcp/bitbucket-<profile>.json):
#   bb-pr-comment.sh --mcp-args <pr-id> "text"   # opens a request, prints the one call to make
#   bb-pr-comment.sh --from-mcp <pr-id>          # prints "Posted comment to PR <id>" once the capture is there
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
MCP=""
case "${1:-}" in --mcp-args) MCP=args; shift ;; --from-mcp) MCP=from; shift ;; esac
if [ -z "$MCP" ]; then
  asdlc_bb_mcp_check || exit 2
  [ "$BB_TRANSPORT" = rest ] || { echo "BB_TRANSPORT=mcp: run bb-pr-comment.sh --mcp-args, make the call it prints, then bb-pr-comment.sh --from-mcp" >&2; exit 2; }
  asdlc_need_bb
fi
PR="${1:?usage: bb-pr-comment.sh <pr-id> [text]}"
if [ -n "$MCP" ]; then [[ $PR =~ ^[0-9]{1,18}$ ]] || { echo "pr-id must be a number" >&2; exit 2; }; fi
if [ "$MCP" = from ]; then asdlc_bb_mcp_take pr_comment >/dev/null || exit 1; echo "Posted comment to PR $PR"; exit 0; fi
if [ "${2:-}" != "" ]; then TEXT="$2"; else TEXT="$(cat)"; fi
if [ "$MCP" = args ]; then
  asdlc_bb_mcp_open pr_comment "$(jq -nc --arg w "$BB_WORKSPACE" --arg r "$BB_REPO" --arg p "$PR" --arg t "$TEXT" '{workspace:$w, repo:$r, pr:$p, text:$t}')"
  exit 0
fi

asdlc_send_json bb POST "/repositories/${BB_WORKSPACE}/${BB_REPO}/pullrequests/${PR}/comments" \
  "$(jq -n --arg r "$TEXT" '{content:{raw:$r}}')" >/dev/null
echo "Posted comment to PR $PR"
