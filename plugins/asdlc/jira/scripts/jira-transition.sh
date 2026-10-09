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
