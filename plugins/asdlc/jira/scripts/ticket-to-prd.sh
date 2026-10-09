#!/usr/bin/env bash
# Turn one Jira ticket into a PRD markdown file for /asdlc:implement-prd. Prints the path.
# Usage: ticket-to-prd.sh <ISSUE-KEY> [--conf <file>] [--fixtures <dir>]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_jira
KEY="${1:?usage: ticket-to-prd.sh <ISSUE-KEY>}"
mkdir -p ./prds
OUT="./prds/${KEY}.md"

json=$(asdlc_get_json jira "/rest/api/2/issue/$KEY" \
  --data-urlencode "fields=summary,description,issuetype,labels,priority")

summary=$(jq -r '.fields.summary' <<<"$json")
type=$(jq -r '.fields.issuetype.name' <<<"$json")
# v2 returns description as text for most tickets. If your tickets use rich
# formatting and this comes out as JSON, re-fetch with expand=renderedFields
# and read .renderedFields.description instead.
desc=$(jq -r 'if (.fields.description|type)=="string" then .fields.description
              else "See ticket for full formatted description." end' <<<"$json")

{
  echo "# ${KEY}: ${summary}"
  echo
  echo "- Source: ${JIRA_BASE_URL}/browse/${KEY}"
  echo "- Type: ${type}"
  echo
  echo "## Description / Requirements"
  echo
  echo "${desc}"
  echo
  echo "## Acceptance criteria"
  echo
  echo "Treat any checklist items or \"AC:\" lines in the description above as required."
} > "$OUT"

echo "$OUT"
