#!/usr/bin/env bash
# Post a comment on a Bitbucket PR. Text from $2, or piped via stdin.
# Usage: bb-pr-comment.sh <pr-id> "text"   |   echo "text" | bb-pr-comment.sh <pr-id>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_bb
PR="${1:?usage: bb-pr-comment.sh <pr-id> [text]}"
if [ "${2:-}" != "" ]; then TEXT="$2"; else TEXT="$(cat)"; fi

asdlc_send_json bb POST "/repositories/${BB_WORKSPACE}/${BB_REPO}/pullrequests/${PR}/comments" \
  "$(jq -n --arg r "$TEXT" '{content:{raw:$r}}')" >/dev/null
echo "Posted comment to PR $PR"
