#!/usr/bin/env bash
# Atlassian MCP capture hook (PostToolUse) and comment guard (PreToolUse), for the Jira leg.
#
#   mcp-capture.sh          PostToolUse: while jira-context.sh has a request open
#                           (plans/<KEY>/.mcp/request.json), store the Atlassian response in
#                           plans/<KEY>/.mcp/ and replace what the model sees with a receipt that
#                           carries no ticket text (updatedMCPToolOutput).
#   mcp-capture.sh guard    PreToolUse on addCommentToJiraIssue / editJiraIssue: while a request is
#                           open for the ticket, block a comment edit, any issue edit, and a comment
#                           that does not start with the pipeline marker (exit 2 and a reason).
#   mcp-capture.sh bb       PostToolUse on any MCP tool: while bb-open-pr.sh / bb-pr-comment.sh
#                           --mcp-args has a request open (plans/.mcp/bb/request.json), store the PR
#                           id and URL of the Bitbucket answer. The tool name comes from the request
#                           (which got it from the profile), never from a list in this script.
#
# With no request open it is a no-op: one glob test, no output, no writes, exit 0. It makes no
# network calls, parses no config (the request file carries what it needs), writes only inside
# plans/<KEY>/.mcp/, never prints ticket text, and always exits 0 (the guard alone may exit 2).
# Needs jq. If a request is open and anything goes wrong, the model still gets a receipt, never
# the raw response.
set -euo pipefail
MODE="${1:-capture}"
MAXB="${ASDLC_MCP_MAX_BYTES:-4194304}"

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
SEARCH_REQ=plans/.mcp/search/request.json; SEARCH_OPEN=0
if [ -e "$SEARCH_REQ" ] || [ -L "$SEARCH_REQ" ]; then SEARCH_OPEN=1; fi
BB_REQ=plans/.mcp/bb/request.json
if [ "$MODE" = bb ]; then { [ -e "$BB_REQ" ] || [ -L "$BB_REQ" ]; } || exit 0; fi         # bb mode: its own request only
compgen -G 'plans/*/.mcp/request.json' >/dev/null || [ "$SEARCH_OPEN" = 1 ] || [ "$MODE" = bb ] || exit 0     # the fast path: nothing open

ENGAGED=0; EMITTED=0
finish() {
  local rc=$?
  if [ "$MODE" = guard ]; then [ "$rc" != 2 ] || exit 2; exit 0; fi
  if [ "$ENGAGED" = 1 ] && [ "$EMITTED" = 0 ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedMCPToolOutput":"asdlc could not capture the Atlassian response and withheld it. Nothing was stored. Open a new request with jira-context.sh mcp-request to retry."}}'
  fi
  exit 0
}
trap finish EXIT
# Without jq nothing can be checked or stored. A request is open, so the response is withheld
# (the EXIT trap prints the fixed receipt); the guard has nothing to go on and lets the call through.
if ! command -v jq >/dev/null 2>&1; then [ "$MODE" = bb ] || ENGAGED=1; exit 0; fi   # bb mode sees every MCP call: it never withholds one it cannot check

receipt() {  # <text>: replace the tool output the model sees
  EMITTED=1
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedMCPToolOutput:$r}}' 2>/dev/null ||
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedMCPToolOutput":"asdlc withheld the Atlassian response (receipt could not be built)."}}'
}
reject() {  # <reason>
  receipt "asdlc rejected the Atlassian response for ${KEY:-an invalid key}: $1. Nothing was stored and the response was withheld from this session. Open a new request with jira-context.sh mcp-request to retry."
  exit 0
}

NOW="$(date +%s)"
IN="$(cat)"

# Only values that pass a strict shape test leave this step, so nothing below can be steered by them.
BBFLAG=false; [ "$MODE" != bb ] || BBFLAG=true
{ IFS= read -r TN; IFS= read -r SID; IFS= read -r KEY; } < <(printf '%s' "$IN" | jq -r --argjson bb "$BBFLAG" '
  (.tool_name // "" | tostring | if test(if $bb then "\\Amcp__[A-Za-z0-9_-]+__[A-Za-z][A-Za-z0-9_-]*\\z" else "\\Amcp__[A-Za-z0-9_-]+__[A-Za-z]+\\z" end) then . else "" end),
  (.session_id // "" | tostring | gsub("[^A-Za-z0-9_-]"; "") | .[0:80]),
  (.tool_input.issueIdOrKey // "" | tostring | if test("\\A[A-Z][A-Z0-9_]*-[0-9]+\\z") then . else "" end)' 2>/dev/null) || true
TN="${TN:-}"; SID="${SID:-}"; KEY="${KEY:-}"
[ -n "$TN" ] || exit 0
TOOL="${TN##*__}"; SERVER="${TN#mcp__}"; SERVER="${SERVER%__*}"

# One response body, whichever of the three shapes the tool_response has.
NORMJQ='def norm: if type == "string" then fromjson
      elif type == "array" then (map(select(type == "object" and .type == "text") | .text) | join("") | fromjson)
      elif type == "object" and (.content | type) == "array" and (has("issues") | not) then (.content | norm)
      else . end;'
# ---- a Bitbucket call (bb-open-pr.sh / bb-pr-comment.sh --mcp-args): plans/.mcp/bb/request.json ----
# The request names the one tool, its exact arguments and where the id and URL sit in the answer
# (all from the profile). Only the id and URL are stored; the model gets a receipt.
if [ "$MODE" = bb ]; then
  BD=plans/.mcp/bb
  KEY="the Bitbucket call"
  bb_reject() {  # <reason>
    EMITTED=1
    jq -nc --arg r "asdlc rejected the Bitbucket response: $1. Nothing was stored and the response was withheld from this session. Open a new request with --mcp-args to retry." \
      '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedMCPToolOutput:$r}}' 2>/dev/null ||
      printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","updatedMCPToolOutput":"asdlc withheld the Bitbucket response."}}'
    exit 0
  }
  if [ -L plans ] || [ -L plans/.mcp ] || [ -L "$BD" ] || [ -L "$BB_REQ" ]; then ENGAGED=1; bb_reject "a request location is a symbolic link"; fi
  bline="$(jq -r '[.v, .kind, .server, .tool, .nonce, .created_epoch, .expires_epoch, .id_path, .url_path] | map(tostring) | join(" ")' "$BB_REQ" 2>/dev/null)" || bline=""
  read -r bv bkind bsrv btool bnonce bcreated bexp bidp burlp <<<"$bline" || true
  { [ "${bv:-}" = 1 ] && [ "${bkind:-}" = bb ] && [[ ${bexp:-} =~ ^[0-9]+$ ]] && [[ ${bcreated:-} =~ ^[0-9]+$ ]] \
      && [[ ${bnonce:-} =~ ^[0-9a-f]{8,64}$ ]] && [[ ${bsrv:-} =~ ^[A-Za-z0-9_-]+$ ]] && [[ ${btool:-} =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
      && [[ ${bidp:-} =~ ^[A-Za-z0-9_.]+$ ]] && [[ ${burlp:-} =~ ^[A-Za-z0-9_.]+$ ]]; } || {
    # Not decidable whether this call was ours: an unreadable request only ever withholds this tool's own answer.
    exit 0; }
  # Another tool than the one the request names is none of our business (the hook sees every MCP call).
  [ "$TN" = "mcp__${bsrv}__${btool}" ] || exit 0
  ENGAGED=1
  [ "$bexp" -gt "$NOW" ] || bb_reject "the request has expired"
  if [ "${#IN}" -gt "$MAXB" ]; then bb_reject "the response is larger than the capture limit"; fi
  printf '%s' "$IN" | jq -e --slurpfile r "$BB_REQ" '.tool_input == $r[0].args' >/dev/null 2>&1 \
    || bb_reject "the call's arguments differ from what the request asked for"
  BTMP="$(mktemp -d "$BD/.cap.XXXXXX")" || bb_reject "could not write inside the request directory"
  trap 'rm -rf "$BTMP"; finish' EXIT
  printf '%s' "$IN" | jq -c "$NORMJQ"'.tool_response | norm' > "$BTMP/resp.json" 2>/dev/null || bb_reject "the response is not valid JSON"
  jq -e '(type == "object") and ((.error // false) | not)' "$BTMP/resp.json" >/dev/null 2>&1 || bb_reject "the tool reported an error"
  jq -c --arg ip "$bidp" --arg up "$burlp" '
      (getpath($ip | split(".")) | if type == "string" or type == "number" then tostring else null end) as $i
      | (getpath($up | split(".")) | if type == "string" then . else null end) as $u
      | {id: (if $i != null and ($i | test("\\A[0-9]{1,18}\\z")) then $i else null end),
         url: (if $u != null and ($u | test("\\Ahttps://[^[:space:]]+\\z")) then $u else "" end)}' "$BTMP/resp.json" > "$BTMP/stripped.json" 2>/dev/null \
    || bb_reject "the response could not be read"
  jq -e '.id != null' "$BTMP/stripped.json" >/dev/null 2>&1 || bb_reject "the response holds no PR or comment id at the profile's path"
  jq -n --arg nonce "$bnonce" --arg tn "$TN" --arg sid "$SID" --argjson at "$NOW" --slurpfile r "$BTMP/stripped.json" \
        '{nonce: $nonce, tool_name: $tn, session_id: $sid, captured_epoch: $at, role: "bb", response: $r[0]}' > "$BTMP/cap.json" 2>/dev/null \
    || bb_reject "the capture could not be written"
  mv "$BTMP/cap.json" "$BD/cap-$NOW-$RANDOM$RANDOM.json" || bb_reject "the capture could not be written"
  EMITTED=1
  jq -nc --arg r "asdlc captured the Bitbucket response (id $(jq -r .id "$BTMP/stripped.json")). Next: run the same script with --from-mcp." \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",updatedMCPToolOutput:$r}}'
  exit 0
fi
case "$TOOL" in
  getJiraIssue|getTransitionsForJiraIssue|transitionJiraIssue|addCommentToJiraIssue) ;;
  editJiraIssue) [ "$MODE" = guard ] || exit 0 ;;
  searchJiraIssuesUsingJql) [ "$MODE" != guard ] || exit 0 ;;
  *) exit 0 ;;
esac


# ---- a search (jira-mine.sh --mcp-args): plans/.mcp/search/request.json ----------------------
# Same discipline as a ticket read: the request must be open, unexpired, for this server and for
# exactly the jql, fields and maxResults it printed. The response is stored, the model gets a
# receipt with counts only.
if [ "$TOOL" = searchJiraIssuesUsingJql ]; then
  [ "$SEARCH_OPEN" = 1 ] || exit 0
  ENGAGED=1; KEY="the search"
  SD=plans/.mcp/search
  if [ -L plans ] || [ -L plans/.mcp ] || [ -L "$SD" ] || [ -L "$SEARCH_REQ" ]; then reject "a request location is a symbolic link"; fi
  sline="$(jq -r '[.v, .kind, .server, .nonce, .created_epoch, .expires_epoch] | map(tostring) | join(" ")' "$SEARCH_REQ" 2>/dev/null)" || reject "unreadable request"
  read -r sv skind ssrv snonce screated sexp <<<"$sline" || true
  { [ "${sv:-}" = 1 ] && [ "${skind:-}" = search ] && [[ ${sexp:-} =~ ^[0-9]+$ ]] && [[ ${screated:-} =~ ^[0-9]+$ ]] \
      && [[ ${snonce:-} =~ ^[0-9a-f]{8,64}$ ]]; } || reject "unreadable request"
  [ "$sexp" -gt "$NOW" ] || reject "the request has expired"
  [ "$SERVER" = "${ssrv:-}" ] || reject "the tool belongs to another MCP server than the request names"
  if [ "${#IN}" -gt "$MAXB" ]; then reject "the response is larger than the capture limit"; fi
  printf '%s' "$IN" | jq -e --slurpfile r "$SEARCH_REQ" '
      ($r[0]) as $w | (.tool_input.jql == $w.jql) and (.tool_input.maxResults == $w.maxResults)
      and (.tool_input.fields | type) == "array" and ((.tool_input.fields | sort) == ($w.fields | sort))' >/dev/null 2>&1 \
    || reject "the call's jql, fields or maxResults differ from what the request asked for"
  STMP="$(mktemp -d "$SD/.cap.XXXXXX")" || reject "could not write inside the request directory"
  trap 'rm -rf "$STMP"; finish' EXIT
  printf '%s' "$IN" | jq -c "$NORMJQ"'.tool_response | norm' > "$STMP/resp.json" 2>/dev/null || reject "the response is not valid JSON"
  jq -e '(type == "object") and ((.error // false) | not)' "$STMP/resp.json" >/dev/null 2>&1 || reject "the tool reported an error"
  jq -e '(.issues.nodes | type) == "array"' "$STMP/resp.json" >/dev/null 2>&1 || reject "the response is not a search result"
  jq -c 'del(.context)' "$STMP/resp.json" > "$STMP/stripped.json" 2>/dev/null || reject "the response could not be stripped"
  jq -n --arg nonce "$snonce" --arg tn "$TN" --arg sid "$SID" --argjson at "$NOW" --slurpfile r "$STMP/stripped.json" \
        '{nonce: $nonce, tool_name: $tn, session_id: $sid, captured_epoch: $at, role: "search", response: $r[0]}' \
        > "$STMP/cap.json" 2>/dev/null || reject "the capture could not be written"
  mv "$STMP/cap.json" "$SD/cap-$NOW-$RANDOM$RANDOM.json" || reject "the capture could not be written"
  SSTATS="$(jq -r '"\(.issues.nodes | length) tickets, more pages: \(if .issues.pageInfo.hasNextPage == true then "yes" else "no" end)"' "$STMP/stripped.json" 2>/dev/null)" || SSTATS="counts unavailable"
  receipt "asdlc captured the search ($SSTATS). Next: run jira-mine.sh --from-mcp with the same selection."
  exit 0
fi

# Find the open request for KEY (as the ticket, or as the parent its issue capture named).
REQ=""; ROLE=""; ANY=0; EXPIRED=0; UNSAFE=0
for f in plans/*/.mcp/request.json; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  d="${f%/request.json}"
  if [ -L "$f" ] || [ -L "$d" ] || [ -L "${d%/.mcp}" ]; then UNSAFE=1; continue; fi
  line="$(jq -r --arg k "$KEY" '[(.expires_epoch | tostring),
      (if $k != "" and .key == $k then "issue" elif $k != "" and ((.allow_keys // []) | index($k)) != null then "parent" else "none" end)] | join(" ")' "$f" 2>/dev/null)" || { ANY=1; continue; }
  exp="${line% *}"; r="${line#* }"
  [[ $exp =~ ^[0-9]+$ ]] || { ANY=1; continue; }
  if [ "$exp" -le "$NOW" ]; then
    [ "$r" = none ] || EXPIRED=1
    continue
  fi
  ANY=1
  if [ "$r" = issue ] || { [ "$r" = parent ] && [ -z "$REQ" ]; }; then REQ="$f"; ROLE="$r"; fi
done

# ---- the guard ---------------------------------------------------------------------------
if [ "$MODE" = guard ]; then
  [ -n "$REQ" ] || exit 0
  case "$TOOL" in addCommentToJiraIssue|editJiraIssue) ;; *) exit 0 ;; esac
  if [ "$TOOL" = editJiraIssue ]; then
    echo "asdlc: $KEY has an open pipeline request; editing the issue is blocked. Pipeline comments are new comments only." >&2; exit 2
  fi
  marker="$(jq -r '.marker // ""' "$REQ" 2>/dev/null)" || marker=""
  if printf '%s' "$IN" | jq -e '.tool_input | has("commentId") or has("comment_id")' >/dev/null 2>&1; then
    echo "asdlc: $KEY has an open pipeline request; editing an existing comment is blocked. Post a new comment." >&2; exit 2
  fi
  if ! printf '%s' "$IN" | jq -e --arg m "$marker" '
        def unesc: split("\\[") | join("[") | split("\\]") | join("]");
        (.tool_input.commentBody // .tool_input.body // null) as $b
        | (if ($b | type) == "string" then ($b | try fromjson catch null) else $b end) as $p
        | (if ($p | type) == "object" then ([$p | .. | objects | select(has("text")) | .text | strings] | .[0] // "")
           elif ($b | type) == "string" then $b else "" end) as $t
        | ($m | length) > 0 and ($t | sub("^\\s+"; "") | unesc | startswith($m))' >/dev/null 2>&1; then
    echo "asdlc: a comment on $KEY must start with the pipeline marker; this one does not (or its first text could not be read). Not posted." >&2; exit 2
  fi
  exit 0
fi

# ---- the capture -------------------------------------------------------------------------
if [ "$UNSAFE" = 1 ] && [ "$TOOL" = getJiraIssue ]; then ENGAGED=1; reject "a request location is a symbolic link"; fi
if [ -z "$REQ" ]; then
  [ "$TOOL" = getJiraIssue ] && { [ "$ANY" = 1 ] || [ "$EXPIRED" = 1 ]; } || exit 0
  ENGAGED=1
  if [ -z "$KEY" ]; then reject "the call named no valid Jira key"
  elif [ "$EXPIRED" = 1 ] && [ "$ANY" = 0 ]; then reject "the request has expired"
  else reject "no open request covers this ticket (a parent is only accepted after its child was captured)"; fi
fi

ENGAGED=1
RD="${REQ%/request.json}"
rq() { jq -r "$1" "$REQ" 2>/dev/null; }
[ "$(rq '.v')" = 1 ] || reject "unreadable request"
[ "$SERVER" = "$(rq '.server')" ] || reject "the tool belongs to another MCP server than the request names"
CALL="getJiraIssue"; [ "$ROLE" != parent ] || CALL="parent"
[ "$TOOL" = getJiraIssue ] || CALL="$TOOL"
if [ "$(jq -r --arg c "$CALL" '.calls | has($c)' "$REQ" 2>/dev/null)" != true ]; then
  [ "$TOOL" != getJiraIssue ] || reject "this request does not cover a ticket read"
  ENGAGED=0; exit 0     # a write tool this request did not ask for: not ours
fi
PURPOSE="$(rq '.purpose')"
[[ $PURPOSE =~ ^(fetch|check|transition|comment)$ ]] || reject "unreadable request"
if [ "${#IN}" -gt "$MAXB" ]; then reject "the response is larger than the capture limit"; fi

if [ "$TOOL" = getJiraIssue ]; then
  want="$(jq -c --arg c "$CALL" '.calls[$c]' "$REQ" 2>/dev/null)" || reject "unreadable request"
  printf '%s' "$IN" | jq -e --argjson w "$want" '
      (.tool_input.fields | type) == "array" and ((.tool_input.fields | sort) == ($w.fields | sort))
      and (.tool_input.responseContentFormat == $w.format)' >/dev/null 2>&1 \
    || reject "the call's fields or format differ from what the request asked for"
fi

TMP="$(mktemp -d "$RD/.cap.XXXXXX")" || reject "could not write inside the request directory"
trap 'rm -rf "$TMP"; finish' EXIT
printf '%s' "$IN" | jq -c '
    '"$NORMJQ"'.tool_response | norm' > "$TMP/resp.json" 2>/dev/null || { [ "$TOOL" = transitionJiraIssue ] && echo '{}' > "$TMP/resp.json"; } || reject "the response is not valid JSON"
# A transition that worked may answer with nothing at all: that is a response of {}.
if [ "$TOOL" = transitionJiraIssue ] && ! jq -e 'type == "object" or type == "array"' "$TMP/resp.json" >/dev/null 2>&1; then echo '{}' > "$TMP/resp.json"; fi
[ "$(jq -r 'if type == "object" or type == "array" then "ok" else "no" end' "$TMP/resp.json" 2>/dev/null)" = ok ] || reject "the response is not valid JSON"
case "$TOOL" in
  getTransitionsForJiraIssue)
    jq -e '(type == "object") and ((.error // false) | not) and ((.transitions | type) == "array")' "$TMP/resp.json" >/dev/null 2>&1 \
      || reject "the response is not a list of transitions (or the tool reported an error)" ;;
  transitionJiraIssue|addCommentToJiraIssue)
    jq -e '((type == "object") | not) or ((.error // false) | not)' "$TMP/resp.json" >/dev/null 2>&1 || reject "the tool reported an error" ;;
esac

if [ "$TOOL" = getJiraIssue ]; then
  jq -e '(type == "object") and ((.error // false) | not)' "$TMP/resp.json" >/dev/null 2>&1 || reject "the tool reported an error"
  jq -e '((.issues.nodes // []) | length) == 1' "$TMP/resp.json" >/dev/null 2>&1 || reject "the response does not hold exactly one issue"
  jq -e --arg k "$KEY" '.issues.nodes[0].key == $k and (.issues.nodes[0].fields | type) == "object"' "$TMP/resp.json" >/dev/null 2>&1 \
    || reject "the response is for a different ticket than the one asked for (moved or renamed?)"
fi

if [ "$TOOL" = addCommentToJiraIssue ]; then
  # Only the new comment's id is kept (M4's "no second comment" needs it); the body and the rest are dropped.
  jq -c '(if type == "object" then (.id // .comment.id // null) else null end) as $i
         | {id: (if ($i | type) == "string" or ($i | type) == "number" then ($i | tostring) else null end)}
         | .id |= (if . != null and test("\\A[0-9]{1,20}\\z") then . else null end)' "$TMP/resp.json" > "$TMP/stripped.json" 2>/dev/null || reject "the response could not be stripped"
elif [ "$TOOL" = transitionJiraIssue ]; then
  echo '{}' > "$TMP/stripped.json"     # nothing of a transition's answer is needed
else
  jq -c 'if type == "object" then del(.context) else . end' "$TMP/resp.json" > "$TMP/stripped.json" 2>/dev/null || reject "the response could not be stripped"
fi
ROLEOUT="$ROLE"; [ "$TOOL" = getJiraIssue ] || ROLEOUT="$TOOL"
NONCE="$(rq '.nonce')"; RKEY="$(rq '.key')"; CLOUD="$(rq '.cloud_id')"
jq -n --arg nonce "$NONCE" --arg tn "$TN" --arg sid "$SID" --argjson at "$NOW" --arg role "$ROLEOUT" \
      --slurpfile r "$TMP/stripped.json" \
      '{nonce: $nonce, tool_name: $tn, session_id: $sid, captured_epoch: $at, role: $role, response: $r[0]}' \
      > "$TMP/cap.json" 2>/dev/null || reject "the capture could not be written"
CAP="$RD/cap-$NOW-$RANDOM$RANDOM.json"
mv "$TMP/cap.json" "$CAP" || reject "the capture could not be written"

# Only a read of the ticket itself says anything about a parent; a parent read is the end of the chain.
if [ "$TOOL" = addCommentToJiraIssue ]; then
  CID="$(jq -r '.id // "unknown"' "$TMP/stripped.json" 2>/dev/null)" || CID="unknown"
  receipt "asdlc captured the addCommentToJiraIssue response for $KEY ($PURPOSE): comment id $CID. Next: run jira-notify.sh --from-mcp $KEY"
  exit 0
fi
if [ "$TOOL" != getJiraIssue ]; then
  receipt "asdlc captured the $TOOL response for $KEY ($PURPOSE)."
  exit 0
fi

PK="$(jq -r '.issues.nodes[0].fields.parent.key // "" | tostring | if test("\\A[A-Z][A-Z0-9_]*-[0-9]+\\z") then . else "" end' "$TMP/stripped.json" 2>/dev/null)" || PK=""
NEXT=""
if [ "$ROLE" = parent ]; then
  NEXT="run jira-context.sh fetch $RKEY --source mcp"
  receipt "asdlc captured $KEY, the parent of $RKEY ($PURPOSE). Next: $NEXT"
  exit 0
fi
if [ -n "$PK" ] && [ "$(rq '.calls | has("parent")')" = true ]; then
  jq --arg p "$PK" '.allow_keys |= ((. // []) as $a | if ($a | index($p)) then $a else $a + [$p] end)' "$REQ" > "$TMP/req.json" 2>/dev/null && mv "$TMP/req.json" "$REQ" || true
  NEXT="call this tool once with exactly these args, then run jira-context.sh fetch $KEY --source mcp: $(jq -nc --arg t "mcp__${SERVER}__getJiraIssue" --arg c "$CLOUD" --arg k "$PK" --argjson f "$(jq -c '.calls.parent.fields' "$REQ")" \
    '{tool: $t, args: {cloudId: $c, issueIdOrKey: $k, fields: $f, responseContentFormat: "markdown", updateHistory: false}}')"
elif [ "$PURPOSE" = check ]; then NEXT="run jira-context.sh check plans/$KEY.plan.md"
elif [ "$PURPOSE" = fetch ]; then NEXT="run jira-context.sh fetch $KEY --source mcp"
else NEXT="continue with the $PURPOSE step"; fi
# Counts only: numbers and a validated key, never a word of the ticket.
STATS="$(jq -r --arg pk "$PK" '.issues.nodes[0].fields as $f
    | ((($f.comment.comments // []) | if type == "array" then length else "?" end) | tostring) as $n
    | (($f.comment.total | numbers | tostring) // "?") as $t
    | ((($f.attachment // []) | if type == "array" then length else "?" end) | tostring) as $a
    | "\($n)/\($t) comments, parent \(if $pk == "" then "none" else $pk end), \($a) attachments"' "$TMP/stripped.json" 2>/dev/null)" || STATS="counts unavailable"
receipt "asdlc captured $KEY ($PURPOSE): $STATS. Next: $NEXT"
exit 0
