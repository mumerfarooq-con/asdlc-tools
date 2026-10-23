#!/usr/bin/env bash
# Move a Jira issue to a target status by name (e.g. "Testing").
# Usage: jira-transition.sh <KEY> <STATUS-NAME | :todo | :in-progress | :testing | :needs-info>
# The :aliases resolve to STATUS_TODO / STATUS_IN_PROGRESS / STATUS_TESTING /
# STATUS_NEEDS_INFO in .asdlc/jira.conf, so callers needn't know board names.
#
# Over the Atlassian MCP (no token needed), in two steps around the model's tool calls:
#   jira-transition.sh --mcp-args <KEY>             open a transition request; prints the two read
#                                                    calls (getJiraIssue for the status, then
#                                                    getTransitionsForJiraIssue) as {"tool","args"} lines
#   jira-transition.sh --from-mcp <KEY> <target>    read what the capture hook stored; prints
#                                                    ALREADY "<status>", or TRANSITION <id> and the
#                                                    transitionJiraIssue call as one JSON line, or
#                                                    lists the available transitions and exits 1
# The REST form is the fallback and gives the same result.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}

MODE=rest
case "${1:-}" in --mcp-args) MODE=args; shift ;; --from-mcp) MODE=from; shift ;; esac
if [ "$MODE" = rest ]; then asdlc_need_jira; else
  [ -n "$JIRA_BASE_URL" ] || asdlc_die "JIRA_BASE_URL is not set in $ASDLC_CONF_FILE"
  asdlc_check_jira_url "$JIRA_BASE_URL"
fi
KEY="${1:?usage: jira-transition.sh [--mcp-args|--from-mcp] <KEY> <STATUS-NAME>}"
asdlc_is_key "$KEY" || asdlc_die "not a Jira key: $(printf '%s' "$KEY" | tr -cd '[:print:]' | cut -c1-40)"

if [ "$MODE" = args ]; then
  first="$(ASDLC_JIRA_CONF="$ASDLC_CONF_FILE" "$ASDLC_JIRA_SCRIPTS/jira-context.sh" mcp-request "$KEY" --for transition)" || exit $?
  printf '%s\n' "$first"
  jq -nc --argjson f "$first" '{tool: ($f.tool | sub("__getJiraIssue$"; "__getTransitionsForJiraIssue")),
                                args: {cloudId: $f.args.cloudId, issueIdOrKey: $f.args.issueIdOrKey}}'
  exit 0
fi

TARGET="${2:?status name required}"
case "$TARGET" in
  :todo)        TARGET="$STATUS_TODO" ;;
  :in-progress) TARGET="$STATUS_IN_PROGRESS" ;;
  :testing)     TARGET="$STATUS_TESTING" ;;
  :needs-info)  TARGET="$STATUS_NEEDS_INFO" ;;
  :*)           asdlc_die "unknown status alias $TARGET (use :todo :in-progress :testing :needs-info)" ;;
esac
path="/rest/api/3/issue/$KEY/transitions"
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The one transition selector, for both transports: the id of the first transition whose
# target status or own name is $TARGET (given the transitions JSON), empty if none.
pick_transition() { jq -r --arg s "$TARGET" '.transitions[]? | select((.to.name==$s) or (.name==$s)) | .id' <<<"$1" | head -n1; }
list_transitions() { jq -r '.transitions[]? | "  - \(.name)  ->  \(.to.name)"' <<<"$1" >&2; }

if [ "$MODE" = from ]; then
  tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
  asdlc_mcp_take "$KEY" transition "$tmpd" issue getTransitionsForJiraIssue || asdlc_die "$MCP_WHY"
  current="$(jq -r '.fields.status.name // empty' "$tmpd/issue.json")"
  if [ -n "$current" ] && [ "$(lc "$current")" = "$(lc "$TARGET")" ]; then
    asdlc_mcp_close "$KEY"
    echo "ALREADY \"$current\""
    exit 0
  fi
  transitions="$(cat "$tmpd/getTransitionsForJiraIssue.json")"
  tid="$(pick_transition "$transitions")"
  if [ -z "$tid" ]; then
    asdlc_mcp_close "$KEY"
    echo "No transition to \"$TARGET\" is available from $KEY's current status." >&2
    echo "Available transitions:" >&2
    list_transitions "$transitions"
    exit 1
  fi
  [[ $tid =~ ^[0-9]+$ ]] || { asdlc_mcp_close "$KEY"; asdlc_die "the transition id Jira returned is not a number"; }
  # The request stays open so the hook can record the transitionJiraIssue call (and keeps the
  # comment guard armed); the captures are already used up.
  echo "TRANSITION $tid"
  jq -nc --arg t "mcp__${MCP_SERVER}__transitionJiraIssue" --arg c "$(asdlc_mcp_cloud)" --arg k "$KEY" --arg id "$tid" \
    '{tool: $t, args: {cloudId: $c, issueIdOrKey: $k, transition: {id: $id}}}'
  exit 0
fi

# Already there (e.g. a re-run after a crash): nothing to do. Workflows rarely allow a
# transition to the current status, so asking for one would fail the run.
current=$(asdlc_get_json jira "/rest/api/3/issue/$KEY" --data-urlencode "fields=status" | jq -r '.fields.status.name // empty')
if [ -n "$current" ] && [ "$(lc "$current")" = "$(lc "$TARGET")" ]; then
  echo "$KEY is already in \"$current\""
  exit 0
fi

transitions=$(asdlc_get_json jira "$path")
tid=$(pick_transition "$transitions")

if [ -z "$tid" ]; then
  echo "No transition to \"$TARGET\" is available from $KEY's current status." >&2
  echo "Available transitions:" >&2
  list_transitions "$transitions"
  exit 1
fi

asdlc_send_json jira POST "$path" "$(jq -n --arg id "$tid" '{transition:{id:$id}}')" >/dev/null
echo "Moved $KEY to \"$TARGET\""
