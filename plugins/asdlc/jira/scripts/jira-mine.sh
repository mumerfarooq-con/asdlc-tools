#!/usr/bin/env bash
# List Jira tickets to work on. Default: my STATUS_DEFAULT tickets in the project.
# Usage:
#   jira-mine.sh [PROJECT_KEY]                  # my tickets in STATUS_DEFAULT
#   jira-mine.sh --key PROJ-142                 # one or more specific tickets
#   jira-mine.sh --key PROJ-142,PROJ-150        #   (ignores assignee/status/sprint)
#   jira-mine.sh --sprint active                # my tickets in the open sprint
#   jira-mine.sh --sprint 42                    # sprint by ID (see jira-sprints.sh)
#   jira-mine.sh --sprint "Board Sprint 7"      # sprint by exact name
# Extra options: --status "To Do,Idea" (one or more) | --any-status | --anyone
# Over the Atlassian MCP (no token needed; see jira-context.sh mcp-request for the protocol):
#   jira-mine.sh --mcp-args <selection>         # opens a search request, prints the one call to make
#   jira-mine.sh --from-mcp <selection>         # same JSON as above, from the captured search
#                                               #   (the selection must be the one given to --mcp-args)
# Shared options: --conf <file> | --fixtures <dir>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
MCP=""
for a in "$@"; do case "$a" in --mcp-args) MCP=args ;; --from-mcp) MCP=from ;; esac; done
if [ -n "$MCP" ]; then
  [ -n "$JIRA_BASE_URL" ] || asdlc_die "JIRA_BASE_URL is not set in $ASDLC_CONF_FILE"
  asdlc_check_jira_url "$JIRA_BASE_URL"
  case "${JIRA_TRANSPORT:-auto}" in auto|mcp) ;; rest) echo "JIRA_TRANSPORT=rest: refusing to search over MCP" >&2; exit 2 ;;
    *) echo "JIRA_TRANSPORT must be auto, mcp or rest" >&2; exit 2 ;; esac
else
  asdlc_need_jira
fi

PROJECT="$JIRA_PROJECT_KEY"
KEYS=""; SPRINT=""; STATUS="$STATUS_DEFAULT"; ANY_STATUS=0; ANYONE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --key|--keys)  KEYS="${2:?}"; shift 2 ;;
    --sprint)      SPRINT="${2:?}"; shift 2 ;;
    --status)      STATUS="${2:?}"; shift 2 ;;
    --any-status)  ANY_STATUS=1; shift ;;
    --anyone)      ANYONE=1; shift ;;
    --mcp-args|--from-mcp) shift ;;
    -*)            echo "unknown option: $1" >&2; exit 2 ;;
    *)             PROJECT="$1"; shift ;;
  esac
done

if [ -n "$KEYS" ]; then
  list=$(printf '%s' "$KEYS" | tr ',' ' ' | tr '[:lower:]' '[:upper:]')
  quoted=$(for k in $list; do printf '"%s",' "$k"; done | sed 's/,$//')
  JQL="key in ($quoted) ORDER BY created ASC"
else
  [ -n "$PROJECT" ] || asdlc_die "set JIRA_PROJECT_KEY in $ASDLC_CONF_FILE or pass a project key"
  JQL="project = \"$PROJECT\""
  [ "$ANYONE" -eq 0 ]    && JQL="$JQL AND assignee = currentUser()"
  if [ "$ANY_STATUS" -eq 0 ]; then
    statusIn=$(printf '%s' "$STATUS" | awk -F',' '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); printf "%s\"%s\"",(i>1?",":""),$i}}')
    JQL="$JQL AND status in ($statusIn)"
  fi
  if [ -n "$SPRINT" ]; then
    case "$SPRINT" in
      active|current|open) JQL="$JQL AND sprint in openSprints()" ;;
      closed|past)         JQL="$JQL AND sprint in closedSprints()" ;;
      future|next)         JQL="$JQL AND sprint in futureSprints()" ;;
      *[!0-9]*)            JQL="$JQL AND sprint = \"$SPRINT\"" ;;   # a name
      *)                   JQL="$JQL AND sprint = $SPRINT" ;;        # a numeric ID
    esac
  fi
  JQL="$JQL ORDER BY created ASC"
fi

LIST_JQ='[.issues[] | {
    key,
    summary:     .fields.summary,
    type:        .fields.issuetype.name,
    status:      .fields.status.name,
    priority:    (.fields.priority.name // "None"),
    labels:      .fields.labels,
    url:         ($base + "/browse/" + .key)
  }]'
MCP_FIELDS="summary,status,priority,issuetype,labels"
MCP_MAX=40

if [ "$MCP" = args ]; then
  # Opens plans/.mcp/search/request.json (10 minutes) and prints the one call the model may make.
  # The capture hook stores the response and hands the model a receipt, so no ticket text is read.
  server="${ASDLC_JIRA_MCP_SERVER:-claude_ai_Atlassian}"
  [[ $server =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ASDLC_JIRA_MCP_SERVER must be letters, digits, _ and - only" >&2; exit 2; }
  host="${JIRA_BASE_URL#https://}"; host="${host%%[:/]*}"
  [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || asdlc_die "JIRA_BASE_URL has no usable host for the MCP cloudId"
  dir=plans/.mcp/search
  if [ -L plans ] || [ -L plans/.mcp ] || [ -L "$dir" ]; then asdlc_die "refusing: plans/, plans/.mcp or $dir is a symbolic link"; fi
  mkdir -p "$dir"; rm -f "$dir"/request.json "$dir"/cap-*.json
  now=$(date +%s); nonce="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  rtmp="$(mktemp "$dir/.request.XXXXXX")"
  jq -n --arg server "$server" --arg nonce "$nonce" --arg cloud "$host" --arg jql "$JQL" --arg f "$MCP_FIELDS" \
        --argjson max "$MCP_MAX" --argjson now "$now" \
        '{v: 1, kind: "search", server: $server, nonce: $nonce, cloud_id: $cloud, created_epoch: $now,
          expires_epoch: ($now + 600), jql: $jql, fields: ($f | split(",")), maxResults: $max}' > "$rtmp" \
    || { rm -f "$rtmp"; asdlc_die "could not write the search request"; }
  mv "$rtmp" "$dir/request.json"
  jq -nc --arg t "mcp__${server}__searchJiraIssuesUsingJql" --arg cloud "$host" --slurpfile r "$dir/request.json" \
    '{tool: $t, args: {cloudId: $cloud, jql: $r[0].jql, fields: $r[0].fields, maxResults: $r[0].maxResults}}'
  exit 0
fi

if [ "$MCP" = from ]; then
  dir=plans/.mcp/search; req="$dir/request.json"
  if [ -L plans ] || [ -L plans/.mcp ] || [ -L "$dir" ] || [ -L "$req" ]; then asdlc_die "refusing: plans/, plans/.mcp or $dir is a symbolic link"; fi
  [ -f "$req" ] || { echo "no open MCP search request; run jira-mine.sh --mcp-args <selection>, make the call it prints, then retry" >&2; exit 1; }
  line="$(jq -r '[.v, .kind, .server, .nonce, .created_epoch, .expires_epoch] | map(tostring) | join(" ")' "$req" 2>/dev/null)" || line=""
  read -r v kind srv nonce created expires <<<"$line" || true
  if ! { [ "${v:-}" = 1 ] && [ "${kind:-}" = search ] && [[ ${srv:-} =~ ^[A-Za-z0-9_-]+$ ]] && [[ ${nonce:-} =~ ^[0-9a-f]{8,64}$ ]] &&
         [[ ${created:-} =~ ^[0-9]+$ ]] && [[ ${expires:-} =~ ^[0-9]+$ ]]; }; then
    echo "the MCP search request is unreadable; open a new one with --mcp-args" >&2; exit 1
  fi
  [ "$expires" -gt "$(date +%s)" ] || { echo "the MCP search request has expired; open a new one with --mcp-args" >&2; exit 1; }
  [ "$(jq -r --arg j "$JQL" '.jql == $j' "$req" 2>/dev/null)" = true ] ||
    { echo "the open MCP search request is for a different selection; give --from-mcp the selection --mcp-args got" >&2; exit 1; }
  best=""; bestat=-1
  for f in "$dir"/cap-*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    at="$(jq -r --arg n "$nonce" --argjson c "$created" --arg tool "mcp__${srv}__searchJiraIssuesUsingJql" '
          select(type == "object" and .nonce == $n and .tool_name == $tool and .role == "search"
                 and (.captured_epoch | type) == "number" and .captured_epoch >= $c
                 and (.response.issues.nodes | type) == "array") | .captured_epoch | floor' "$f" 2>/dev/null)" || continue
    [[ $at =~ ^[0-9]+$ ]] || continue
    if [ "$at" -gt "$bestat" ] || { [ "$at" -eq "$bestat" ] && [[ $f > $best ]]; }; then best="$f"; bestat="$at"; fi
  done
  [ -n "$best" ] || { echo "no valid capture of the search under the open MCP request (make the call --mcp-args printed, with exactly those args)" >&2; exit 1; }
  resp="$(mktemp)"; trap 'rm -f "$resp"' EXIT
  jq -c '.response | {issues: .issues.nodes, more: (.issues.pageInfo.hasNextPage == true)}' "$best" > "$resp" 2>/dev/null ||
    { echo "could not read the search capture" >&2; exit 1; }
  rm -f "$req" "$dir"/cap-*.json; rmdir "$dir" plans/.mcp 2>/dev/null || true
  if [ "$(jq -r '.more' "$resp")" = true ]; then
    echo "warn: more than $MCP_MAX tickets match; only the first $MCP_MAX are listed. Narrow the selection (--key, --status, --sprint)." >&2
  fi
  if [ "$(jq -r '.issues | length' "$resp")" = 0 ]; then
    echo "warn: no tickets found. Over MCP an unknown status or sprint name is not reported as an error, it just matches nothing; check the spelling of the names in the selection." >&2
  fi
  jq --arg base "$JIRA_BASE_URL" "$LIST_JQ" "$resp"
  exit 0
fi

# /rest/api/3/search is gone (410); the v2 search/jql endpoint is the
# supported search. Descriptions are not requested: ticket text is read only by
# jira-context.sh, so it stays out of the orchestrator's context.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
code=$(asdlc_http jira GET /rest/api/2/search/jql "$tmp" \
        --data-urlencode "jql=$JQL" \
        --data-urlencode "fields=summary,status,priority,issuetype,labels" \
        --data-urlencode "maxResults=50")
if ! asdlc_http_ok "$code"; then
  asdlc_http_fail jira "$code" "$tmp" "the ticket search"
  echo "JQL was: $JQL" >&2
  exit 1
fi

jq --arg base "$JIRA_BASE_URL" "$LIST_JQ" "$tmp"
