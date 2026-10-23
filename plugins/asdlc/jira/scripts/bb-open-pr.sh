#!/usr/bin/env bash
# Open a Bitbucket PR from <source-branch> into the target branch. Prints: "<pr_id> <pr_url>"
# Usage: bb-open-pr.sh <source-branch> <title> [dest-branch]   (dest defaults to TARGET_BRANCH)
# Over a Bitbucket MCP server (BB_TRANSPORT=mcp, see lib.sh and jira/mcp/bitbucket-<profile>.json):
#   bb-open-pr.sh --mcp-args <source-branch> <title> [dest-branch]   # opens a request, prints the one call to make
#   bb-open-pr.sh --from-mcp                                         # prints "<pr_id> <pr_url>" from the capture
# Auth: BB_AUTH=bearer (default; workspace/repo access tokens and user API tokens)
#       or BB_AUTH=basic with BITBUCKET_EMAIL, for personal API tokens Bearer rejects.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
MCP=""
case "${1:-}" in --mcp-args) MCP=args; shift ;; --from-mcp) MCP=from; shift ;; esac
if [ "$MCP" = from ]; then asdlc_bb_mcp_take open_pr || exit 1; exit 0; fi
if [ -z "$MCP" ]; then
  asdlc_bb_mcp_check || exit 2
  [ "$BB_TRANSPORT" = rest ] || { echo "BB_TRANSPORT=mcp: run bb-open-pr.sh --mcp-args, make the call it prints, then bb-open-pr.sh --from-mcp" >&2; exit 2; }
  asdlc_need_bb
fi
SRC="${1:?usage: bb-open-pr.sh <source-branch> <title> [dest-branch]}"
TITLE="${2:?title required}"
DEST="${3:-$TARGET_BRANCH}"
[ -n "$DEST" ] || asdlc_die "pass a dest branch or set TARGET_BRANCH in $ASDLC_CONF_FILE"

if [ "$MCP" = args ]; then
  asdlc_bb_mcp_open open_pr "$(jq -nc --arg w "$BB_WORKSPACE" --arg r "$BB_REPO" --arg t "$TITLE" --arg s "$SRC" --arg d "$DEST" \
    '{workspace:$w, repo:$r, title:$t, source:$s, dest:$d}')"
  exit 0
fi

body=$(jq -n --arg t "$TITLE" --arg s "$SRC" --arg d "$DEST" \
  '{title:$t, source:{branch:{name:$s}}, destination:{branch:{name:$d}}, close_source_branch:true}')

resp=$(asdlc_send_json bb POST "/repositories/${BB_WORKSPACE}/${BB_REPO}/pullrequests" "$body")

echo "$(jq -r '.id' <<<"$resp") $(jq -r '.links.html.href' <<<"$resp")"
