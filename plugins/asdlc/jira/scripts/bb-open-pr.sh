#!/usr/bin/env bash
# Open a Bitbucket PR from <source-branch> into the target branch. Prints: "<pr_id> <pr_url>"
# Usage: bb-open-pr.sh <source-branch> <title> [dest-branch]   (dest defaults to TARGET_BRANCH)
# Auth: BB_AUTH=bearer (default; workspace/repo access tokens and user API tokens)
#       or BB_AUTH=basic with BITBUCKET_EMAIL, for personal API tokens Bearer rejects.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_need_bb
SRC="${1:?usage: bb-open-pr.sh <source-branch> <title> [dest-branch]}"
TITLE="${2:?title required}"
DEST="${3:-$TARGET_BRANCH}"
[ -n "$DEST" ] || asdlc_die "pass a dest branch or set TARGET_BRANCH in $ASDLC_CONF_FILE"

body=$(jq -n --arg t "$TITLE" --arg s "$SRC" --arg d "$DEST" \
  '{title:$t, source:{branch:{name:$s}}, destination:{branch:{name:$d}}, close_source_branch:true}')

resp=$(asdlc_send_json bb POST "/repositories/${BB_WORKSPACE}/${BB_REPO}/pullrequests" "$body")

echo "$(jq -r '.id' <<<"$resp") $(jq -r '.links.html.href' <<<"$resp")"
