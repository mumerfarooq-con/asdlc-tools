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
# Shared options: --conf <file> | --fixtures <dir>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_jira

PROJECT="$JIRA_PROJECT_KEY"
KEYS=""; SPRINT=""; STATUS="$STATUS_DEFAULT"; ANY_STATUS=0; ANYONE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --key|--keys)  KEYS="${2:?}"; shift 2 ;;
    --sprint)      SPRINT="${2:?}"; shift 2 ;;
    --status)      STATUS="${2:?}"; shift 2 ;;
    --any-status)  ANY_STATUS=1; shift ;;
    --anyone)      ANYONE=1; shift ;;
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

# /rest/api/3/search is gone (410); the v2 search/jql endpoint returns
# descriptions as plain wiki text, which is what the planner reads.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
code=$(asdlc_http jira GET /rest/api/2/search/jql "$tmp" \
        --data-urlencode "jql=$JQL" \
        --data-urlencode "fields=summary,description,status,priority,issuetype,labels" \
        --data-urlencode "maxResults=50")
if ! asdlc_http_ok "$code"; then
  asdlc_http_fail jira "$code" "$tmp" "the ticket search"
  echo "JQL was: $JQL" >&2
  exit 1
fi

jq --arg base "$JIRA_BASE_URL" '[.issues[] | {
    key,
    summary:     .fields.summary,
    type:        .fields.issuetype.name,
    status:      .fields.status.name,
    priority:    (.fields.priority.name // "None"),
    labels:      .fields.labels,
    url:         ($base + "/browse/" + .key),
    description: (.fields.description // "")
  }]' "$tmp"
