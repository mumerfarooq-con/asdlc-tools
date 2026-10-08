#!/usr/bin/env bash
# List sprints for the project's board so you can find a sprint's ID.
# Usage: jira-sprints.sh [PROJECT_KEY]
# If the project has several boards, set JIRA_BOARD_ID in .asdlc/jira.conf to choose one.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_jira
PROJECT="${1:-$JIRA_PROJECT_KEY}"
[ -n "$PROJECT" ] || asdlc_die "set JIRA_PROJECT_KEY in $ASDLC_CONF_FILE or pass a project key"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

board="$JIRA_BOARD_ID"
if [ -z "$board" ]; then
  asdlc_http jira GET /rest/agile/1.0/board "$tmp" --data-urlencode "projectKeyOrId=$PROJECT" >/dev/null
  board=$(jq -r '.values[0].id // empty' "$tmp" 2>/dev/null || true)
  if [ -z "$board" ]; then
    echo "No board found for '$PROJECT'. Response:" >&2; cat "$tmp" >&2; echo >&2; exit 1
  fi
  n=$(jq -r '.values | length' "$tmp")
  if [ "$n" -gt 1 ]; then
    echo "Project has $n boards; using $board. Set JIRA_BOARD_ID in $ASDLC_CONF_FILE to pick another:" >&2
    jq -r '.values[] | "  \(.id)  \(.name)"' "$tmp" >&2
  fi
fi

asdlc_http jira GET "/rest/agile/1.0/board/$board/sprint" "$tmp" --data-urlencode "maxResults=50" >/dev/null
if [ "$(jq -r 'has("values")' "$tmp" 2>/dev/null || echo false)" != "true" ]; then
  echo "Could not list sprints (is this a Scrum board?). Response:" >&2; cat "$tmp" >&2; echo >&2; exit 1
fi

{ printf 'ID\tSTATE\tNAME\n'
  jq -r '.values[] | [.id, .state, .name] | @tsv' "$tmp"; } \
  | { command -v column >/dev/null && column -t -s "$(printf '\t')" || cat; }
