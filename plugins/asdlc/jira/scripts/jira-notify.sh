#!/usr/bin/env bash
# Add watchers and post a mention comment on a Jira issue.
# People come from NOTIFY_ACCOUNT_IDS in .asdlc/jira.conf (comma-separated
# Atlassian accountIds; list them with jira-people.sh).
# Usage: jira-notify.sh <KEY> ["note text"]                       watchers and the comment, over REST
#
# Over the Atlassian MCP (the comment needs no token):
#   jira-notify.sh --adf <KEY> ["note text"]    no network: opens a comment request (that is what
#                                                arms the plugin's comment guard for the ticket) and
#                                                prints the ADF comment body, marker text first and
#                                                then the accountId mentions. The model posts it with
#                                                addCommentToJiraIssue {contentFormat:"adf",
#                                                commentBody:<that JSON>}; the user confirms that call.
#   jira-notify.sh --from-mcp <KEY>              reads what the hook stored for that call and prints
#                                                COMMENT <id> (the id M4's "no second comment" needs)
#   jira-notify.sh --watchers <KEY>              the watchers alone: over REST when a Jira login is
#                                                ready, else it says "watchers skipped"
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}

MODE=rest
case "${1:-}" in --adf) MODE=adf; shift ;; --from-mcp) MODE=from; shift ;; --watchers) MODE=watchers; shift ;; esac
case "$MODE" in
  rest) asdlc_need_jira ;;
  watchers) [ -n "$JIRA_BASE_URL" ] || asdlc_die "JIRA_BASE_URL is not set in $ASDLC_CONF_FILE" ;;
  *) [ -n "$JIRA_BASE_URL" ] || asdlc_die "JIRA_BASE_URL is not set in $ASDLC_CONF_FILE"
     asdlc_check_jira_url "$JIRA_BASE_URL" ;;
esac
[ "$MODE" = from ] || [ "$MODE" = watchers ] || asdlc_need_marker
KEY="${1:?usage: jira-notify.sh [--adf|--from-mcp|--watchers] <KEY> [note]}"
asdlc_is_key "$KEY" || asdlc_die "not a Jira key: $(printf '%s' "$KEY" | tr -cd '[:print:]' | cut -c1-40)"

if [ "$MODE" = from ]; then
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  asdlc_mcp_take "$KEY" comment "$tmpd" addCommentToJiraIssue ||
    asdlc_die "$MCP_WHY. If the comment call may have gone through, check the ticket before posting again."
  asdlc_mcp_close "$KEY"
  echo "COMMENT $(jq -r '.id // "unknown"' "$tmpd/addCommentToJiraIssue.json")"
  exit 0
fi

NOTE="${2:-Moved to Testing — please take a look.}"
[ -n "$NOTIFY_ACCOUNT_IDS" ] || asdlc_die "set NOTIFY_ACCOUNT_IDS in $ASDLC_CONF_FILE (see jira-people.sh)"
ids=$(asdlc_split_csv "$NOTIFY_ACCOUNT_IDS")

# The comment: an ADF document that @mentions them and starts with the marker, so the
# pipeline can tell its own comments from people's.
adf_doc() {
  local mentions
  mentions=$(printf '%s\n' "$ids" | jq -R '{type:"mention",attrs:{id:.}}' | jq -s '.')
  jq -nc --arg note "$PIPELINE_COMMENT_MARKER $NOTE " --argjson mentions "$mentions" '
    {type:"doc",version:1,content:[
      {type:"paragraph",content:([{type:"text",text:$note}] + $mentions)}
    ]}'
}

add_watchers() {
  local tmp code id
  tmp="$(mktemp)"
  while IFS= read -r id; do
    code=$(asdlc_http jira POST "/rest/api/3/issue/$KEY/watchers" "$tmp" \
             -H "Content-Type: application/json" -d "\"$id\"")
    asdlc_http_ok "$code" || echo "warn: could not add watcher $id (HTTP $code)" >&2
  done <<<"$ids"
  rm -f "$tmp"
}

if [ "$MODE" = adf ]; then
  doc="$(adf_doc)"
  first="$(ASDLC_JIRA_CONF="$ASDLC_CONF_FILE" "$ASDLC_JIRA_SCRIPTS/jira-context.sh" mcp-request "$KEY" --for comment)" || exit $?
  echo "post it with: $(jq -c '{tool, args: (.args + {contentFormat: "adf", commentBody: "<the ADF JSON on stdout, as a string>"})}' <<<"$first")" >&2
  printf '%s\n' "$doc"
  exit 0
fi

if [ "$MODE" = watchers ]; then
  if asdlc_rest_ready; then add_watchers; echo "Watchers added on $KEY: $(printf '%s' "$ids" | tr '\n' ' ')"
  else echo "watchers skipped (the Atlassian MCP has no watcher tool and no Jira login is set)"; fi
  exit 0
fi

# 1) add each person as a watcher
add_watchers

# 2) post the comment
asdlc_send_json jira POST "/rest/api/3/issue/$KEY/comment" "$(jq -nc --argjson d "$(adf_doc)" '{body:$d}')" >/dev/null
echo "Notified on $KEY: $(printf '%s' "$ids" | tr '\n' ' ')"
