#!/usr/bin/env bash
# List people assignable on a Jira project, with their accountId (what @mentions need).
# Usage:
#   jira-people.sh [PROJECT_KEY]            # everyone assignable on the project
#   jira-people.sh [PROJECT_KEY] "Jane"     # filter by name/email
# Emails show as "—" when Jira privacy settings hide them (normal).
# Note: user/assignable/search needs the project KEY, not its display name.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_jira
PROJECT="${1:-$JIRA_PROJECT_KEY}"
[ -n "$PROJECT" ] || asdlc_die "set JIRA_PROJECT_KEY in $ASDLC_CONF_FILE or pass a project key"
QUERY="${2:-}"

args=(--data-urlencode "project=$PROJECT" --data-urlencode "maxResults=200")
[ -n "$QUERY" ] && args+=(--data-urlencode "query=$QUERY")

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
code=$(asdlc_http jira GET /rest/api/3/user/assignable/search "$tmp" "${args[@]}")
if ! asdlc_http_ok "$code"; then
  asdlc_http_fail jira "$code" "$tmp" "project '$PROJECT'"
  [ "$code" = "403" ] && echo "  -> Ask an admin for 'Browse users and groups', or read each accountId from the person's Jira profile URL (last path segment)." >&2
  exit 1
fi

rows=$(jq -r '.[] | select(.accountType=="atlassian" and .active==true)
           | [.accountId, .displayName, (.emailAddress // "—")] | @tsv' "$tmp" \
  | sort -t "$(printf '\t')" -k2,2)

if [ -z "$rows" ]; then
  total=$(jq 'length' "$tmp" 2>/dev/null || echo "?")
  echo "HTTP 200, but no active human users matched (raw users returned: $total)."
  echo "Try a name filter, e.g.  jira-people.sh $PROJECT \"a\""
  exit 0
fi

{ printf 'ACCOUNT_ID\tNAME\tEMAIL\n'; printf '%s\n' "$rows"; } \
  | { command -v column >/dev/null && column -t -s "$(printf '\t')" || cat; }

echo
echo "Comma-joined accountIds shown above (for NOTIFY_ACCOUNT_IDS in .asdlc/jira.conf):"
printf '%s\n' "$rows" | cut -f1 | paste -sd, -
