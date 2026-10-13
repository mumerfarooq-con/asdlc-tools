#!/usr/bin/env bash
# Move a Jira issue to a target status by name (e.g. "Testing").
# Usage: jira-transition.sh <KEY> <STATUS-NAME | :todo | :in-progress | :testing | :needs-info>
# The :aliases resolve to STATUS_TODO / STATUS_IN_PROGRESS / STATUS_TESTING /
# STATUS_NEEDS_INFO in .asdlc/jira.conf, so callers needn't know board names.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_jira
KEY="${1:?usage: jira-transition.sh <KEY> <STATUS-NAME>}"
TARGET="${2:?status name required}"
case "$TARGET" in
  :todo)        TARGET="$STATUS_TODO" ;;
  :in-progress) TARGET="$STATUS_IN_PROGRESS" ;;
  :testing)     TARGET="$STATUS_TESTING" ;;
  :needs-info)  TARGET="$STATUS_NEEDS_INFO" ;;
  :*)           asdlc_die "unknown status alias $TARGET (use :todo :in-progress :testing :needs-info)" ;;
esac
path="/rest/api/3/issue/$KEY/transitions"

# Already there (e.g. a re-run after a crash): nothing to do. Workflows rarely allow a
# transition to the current status, so asking for one would fail the run.
current=$(asdlc_get_json jira "/rest/api/3/issue/$KEY" --data-urlencode "fields=status" | jq -r '.fields.status.name // empty')
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ -n "$current" ] && [ "$(lc "$current")" = "$(lc "$TARGET")" ]; then
  echo "$KEY is already in \"$current\""
  exit 0
fi

transitions=$(asdlc_get_json jira "$path")
tid=$(jq -r --arg s "$TARGET" '.transitions[] | select((.to.name==$s) or (.name==$s)) | .id' <<<"$transitions" | head -n1)

if [ -z "$tid" ]; then
  echo "No transition to \"$TARGET\" is available from $KEY's current status." >&2
  echo "Available transitions:" >&2
  jq -r '.transitions[] | "  - \(.name)  ->  \(.to.name)"' <<<"$transitions" >&2
  exit 1
fi

asdlc_send_json jira POST "$path" "$(jq -n --arg id "$tid" '{transition:{id:$id}}')" >/dev/null
echo "Moved $KEY to \"$TARGET\""
