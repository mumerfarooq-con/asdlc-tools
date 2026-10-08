#!/usr/bin/env bash
# Add watchers and post a mention comment on a Jira issue.
# People come from NOTIFY_ACCOUNT_IDS in .asdlc/jira.conf (comma-separated
# Atlassian accountIds; list them with jira-people.sh).
# Usage: jira-notify.sh <KEY> ["note text"]
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_jira
KEY="${1:?usage: jira-notify.sh <KEY> [note]}"
NOTE="${2:-Moved to Testing — please take a look.}"
[ -n "$NOTIFY_ACCOUNT_IDS" ] || asdlc_die "set NOTIFY_ACCOUNT_IDS in $ASDLC_CONF_FILE (see jira-people.sh)"

ids=$(asdlc_split_csv "$NOTIFY_ACCOUNT_IDS")

# 1) add each person as a watcher
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
while IFS= read -r id; do
  code=$(asdlc_http jira POST "/rest/api/3/issue/$KEY/watchers" "$tmp" \
           -H "Content-Type: application/json" -d "\"$id\"")
  asdlc_http_ok "$code" || echo "warn: could not add watcher $id (HTTP $code)" >&2
done <<<"$ids"

# 2) post an ADF comment that @mentions them
mentions=$(printf '%s\n' "$ids" | jq -R '{type:"mention",attrs:{id:.}}' | jq -s '.')
body=$(jq -n --arg note "$NOTE " --argjson mentions "$mentions" '
  {body:{type:"doc",version:1,content:[
    {type:"paragraph",content:([{type:"text",text:$note}] + $mentions)}
  ]}}')

asdlc_send_json jira POST "/rest/api/3/issue/$KEY/comment" "$body" >/dev/null
echo "Notified on $KEY: $(printf '%s' "$ids" | tr '\n' ' ')"
