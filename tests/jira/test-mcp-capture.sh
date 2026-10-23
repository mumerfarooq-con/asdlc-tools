#!/usr/bin/env bash
# The MCP capture protocol: jira-context.sh mcp-request, the PostToolUse capture hook, the
# PreToolUse comment guard, and run-state.sh's sweep of expired requests. The hook is fed fixture
# stdin JSON (synthetic PROJ tickets); there is no MCP server, no network, no Jira.
. "$(dirname "$0")/helpers.sh"
JC="$S/jira-context.sh"; RS="$S/run-state.sh"; HOOK="$ROOT/plugins/asdlc/hooks/mcp-capture.sh"
SERVER=fixture_atlassian; TOOL="mcp__${SERVER}__getJiraIssue"
SENTINEL="SENTINEL-DESC-123"
export ASDLC_JIRA_MCP_SERVER="$SERVER"
FIELDS='["summary","description","status","issuetype","parent","issuelinks","attachment","comment"]'
PFIELDS='["summary","description","status","issuetype"]'

# The tool_response body of a ticket, as Atlassian's getJiraIssue returns it.
issue_text() {  # <KEY> [parent KEY or ""]
  jq -nc --arg k "$1" --arg p "${2:-}" --arg s "$SENTINEL" '
    {issues: {nodes: [{key: $k, fields: ({summary: "Synthetic ticket", description: ($s + " the secret body"),
       comment: {comments: [{id: "1", body: "first"}, {id: "2", body: "second"}], total: 2, maxResults: 2, startAt: 0},
       attachment: [{id: "10001"}]} + (if $p == "" then {} else {parent: {key: $p}} end))}]},
     context: {cloudId: "per-call-id", requestId: "r-1"}}'
}
# The hook stdin for a call. shape: string | array | object.
stdin_json() {  # <tool_name> <KEY> <fields json> <format> <response text> [shape]
  jq -nc --arg tn "$1" --arg k "$2" --argjson f "$3" --arg fmt "$4" --arg r "$5" --arg shape "${6:-array}" '
    {session_id: "sess-1", cwd: "/x", hook_event_name: "PostToolUse", tool_name: $tn,
     tool_input: {cloudId: "example.atlassian.net", issueIdOrKey: $k, fields: $f, responseContentFormat: $fmt, updateHistory: false},
     tool_response: (if $shape == "string" then $r elif $shape == "array" then [{type: "text", text: $r}]
                     else ($r | fromjson) end),
     tool_use_id: "toolu_x"}'
}
hook() {  # <stdin json> [mode]: run the hook from the sandbox with the project dir set
  local in="$1"; shift
  run env CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "$1" | "$2" "${@:3}"' _ "$in" "$HOOK" "$@"
}
caps() { find "$SB/plans" -name 'cap-*.json' 2>/dev/null | sort; }
ncaps() { caps | grep -c . || true; }
receipt_text() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedMCPToolOutput // empty' 2>/dev/null; }
open_req() {  # <KEY> <purpose>
  run "$JC" mcp-request "$1" --for "$2"; assert_eq "$CODE" "0" "mcp-request $1 $2 exit"
}
issue_call() {  # <KEY> [response text] [shape]
  hook "$(stdin_json "$TOOL" "$1" "$FIELDS" markdown "${2:-$(issue_text "$1" PROJ-0)}" "${3:-array}")"
}
expect_rejected() {  # <what> <reason fragment>: after a hook run
  assert_eq "$CODE" "0" "$1: exit"
  assert_contains "$(receipt_text)" "rejected" "$1: receipt"
  assert_contains "$(receipt_text)" "$2" "$1: reason"
  assert_not_contains "$OUT$ERR" "$SENTINEL" "$1: sentinel"
  assert_eq "$(ncaps)" "0" "$1: captures written"
}

# ---- no request: a no-op ------------------------------------------------------------------
t "with no request open the hook is silent, writes nothing, and exits 0"
sandbox
before="$(find "$SB" -not -path '*/.git/*' | sort)"
issue_call PROJ-1
assert_eq "$CODE/$OUT/$ERR" "0//" "no plans/ at all"
mkdir -p plans/PROJ-1
issue_call PROJ-1; assert_eq "$CODE/$OUT/$ERR" "0//" "plans/PROJ-1 without a request"
rmdir plans/PROJ-1; rmdir plans 2>/dev/null || true
assert_eq "$(find "$SB" -not -path '*/.git/*' | sort)" "$before" "files"
run env CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "not json at all" | "$1"' _ "$HOOK"
assert_eq "$CODE/$OUT/$ERR" "0//" "garbage stdin"

# ---- mcp-request --------------------------------------------------------------------------
t "mcp-request writes the request and prints the one call the model may make"
sandbox
open_req PROJ-1 fetch
assert_eq "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" "0" "one line"
assert_eq "$(printf '%s' "$OUT" | jq -c '.')" "$OUT" "valid JSON"
assert_eq "$(printf '%s' "$OUT" | jq -r '.tool')" "$TOOL" "tool"
assert_eq "$(printf '%s' "$OUT" | jq -c '.args')" "$(jq -nc --argjson f "$FIELDS" '{cloudId: "example.atlassian.net", issueIdOrKey: "PROJ-1", fields: $f, responseContentFormat: "markdown", updateHistory: false}')" "args"
R=plans/PROJ-1/.mcp/request.json
assert_file "$R"
assert_eq "$(jq -r '[.v, .key, .purpose, .server, (.nonce | test("\\A[0-9a-f]{24}\\z")), (.expires_epoch - .created_epoch), .allow_keys[0], .marker] | join(" ")' "$R")" "1 PROJ-1 fetch $SERVER true 600 PROJ-1 [asdlc]" "request fields"
assert_eq "$(jq -c '.calls.getJiraIssue.fields' "$R")" "$FIELDS" "request asks for the issue fields plus comment"
assert_eq "$(jq -c '.calls.parent.fields' "$R")" "$PFIELDS" "request asks for the parent fields"
assert_not_contains "$(cat "$R")" "$HOME" "no personal path"
old="$(jq -r .nonce "$R")"
open_req PROJ-1 check; assert_eq "$(jq -r '[.purpose, .nonce != "'"$old"'", (.calls | has("parent"))] | join(" ")' "$R")" "check true false" "a new request replaces the old"
run "$JC" mcp-request PROJ-1 --for bogus; assert_eq "$CODE" "2" "bad purpose"
run "$JC" mcp-request "../x" --for fetch; assert_eq "$CODE" "2" "bad key"
run "$JC" mcp-request PROJ-1; assert_eq "$CODE" "2" "no --for"
run env ASDLC_JIRA_MCP_SERVER='a b' "$JC" mcp-request PROJ-1 --for fetch; assert_eq "$CODE" "2" "bad server name"
rm -rf plans/PROJ-1/.mcp; mkdir -p "$SB/elsewhere" plans/PROJ-1; ln -s "$SB/elsewhere" plans/PROJ-1/.mcp
run "$JC" mcp-request PROJ-1 --for fetch; assert_eq "$CODE" "2" "symlinked .mcp refused"
assert_eq "$(ls "$SB/elsewhere" | wc -l | tr -d ' ')" "0" "nothing written through the link"

# ---- the happy path, three response shapes -------------------------------------------------
for shape in string array object; do
  t "capture ($shape response): stored without context, receipt has counts and no ticket text"
  sandbox; open_req PROJ-1 fetch
  issue_call PROJ-1 "$(issue_text PROJ-1 PROJ-0)" "$shape"
  assert_eq "$CODE" "0" "exit"
  assert_eq "$(ncaps)" "1" "one capture"
  c="$(caps)"
  assert_eq "$(jq -r '[.nonce == "'"$(jq -r .nonce plans/PROJ-1/.mcp/request.json)"'", .role, .tool_name, .session_id, (.captured_epoch | type), .response.issues.nodes[0].key, (.response | has("context"))] | join(" ")' "$c")" "true issue $TOOL sess-1 number PROJ-1 false" "capture content"
  assert_eq "$(jq -r '.response.issues.nodes[0].fields.description' "$c")" "$SENTINEL the secret body" "ticket text is kept in the capture"
  rcpt="$(receipt_text)"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse" "event name"
  assert_contains "$rcpt" "asdlc captured PROJ-1 (fetch): 2/2 comments, parent PROJ-0, 1 attachments." "receipt counts"
  assert_contains "$rcpt" '"issueIdOrKey":"PROJ-0"' "receipt names the parent call"
  assert_contains "$rcpt" "$PFIELDS" "receipt asks for the parent fields"
  assert_not_contains "$OUT$ERR" "$SENTINEL" "receipt sentinel"
  assert_not_contains "$OUT$ERR" "secret body" "receipt text"
  assert_not_contains "$OUT$ERR" "Synthetic ticket" "receipt summary"
  assert_eq "$(jq -c '.allow_keys' plans/PROJ-1/.mcp/request.json)" '["PROJ-1","PROJ-0"]' "the parent was allowed"
  assert_file plans/PROJ-1/.mcp/request.json
done

t "a parent is accepted only after the issue capture named it, and only with the parent fields"
sandbox; open_req PROJ-1 fetch
hook "$(stdin_json "$TOOL" PROJ-0 "$PFIELDS" markdown "$(issue_text PROJ-0)")"
expect_rejected "parent before the issue" "no open request covers this ticket"
issue_call PROJ-1 >/dev/null; assert_eq "$(ncaps)" "1" "issue captured"
hook "$(stdin_json "$TOOL" PROJ-0 "$FIELDS" markdown "$(issue_text PROJ-0)")"
assert_contains "$(receipt_text)" "rejected" "parent with the issue's fields"
assert_eq "$(ncaps)" "1" "still one capture"
hook "$(stdin_json "$TOOL" PROJ-0 "$PFIELDS" markdown "$(issue_text PROJ-0)")"
assert_contains "$(receipt_text)" "captured PROJ-0, the parent of PROJ-1" "parent accepted"
assert_not_contains "$OUT" "$SENTINEL" "parent receipt"
assert_eq "$(ncaps)" "2" "two captures"
assert_eq "$(for c in $(caps); do jq -r .role "$c"; done | sort | tr '\n' ' ')" "issue parent " "roles"
hook "$(stdin_json "$TOOL" PROJ-5 "$PFIELDS" markdown "$(issue_text PROJ-5)")"
assert_contains "$(receipt_text)" "rejected" "an unrelated key while a request is open"

t "a check request takes no parent, and its receipt points at the stale check"
sandbox; open_req PROJ-1 check
issue_call PROJ-1
assert_contains "$(receipt_text)" "(check): 2/2 comments, parent PROJ-0, 1 attachments. Next: run jira-context.sh check plans/PROJ-1.plan.md" "check receipt"
assert_eq "$(jq -c '.allow_keys' plans/PROJ-1/.mcp/request.json)" '["PROJ-1"]' "no parent allowed"
hook "$(stdin_json "$TOOL" PROJ-0 "$PFIELDS" markdown "$(issue_text PROJ-0)")"
assert_contains "$(receipt_text)" "rejected" "parent under a check request"

# ---- rejections ---------------------------------------------------------------------------
t "rejections: nothing stored, a receipt names the reason, no ticket text reaches the model"
sandbox; open_req PROJ-1 fetch
good="$(issue_text PROJ-1)"
hook "$(stdin_json "$TOOL" PROJ-2 "$FIELDS" markdown "$(issue_text PROJ-2)")"; expect_rejected "key mismatch" "no open request covers"
hook "$(stdin_json "$TOOL" PROJ-1 '["summary","description"]' markdown "$good")"; expect_rejected "fields without comment" "fields or format differ"
hook "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" adf "$good")"; expect_rejected "wrong format" "fields or format differ"
hook "$(stdin_json "mcp__other_server__getJiraIssue" PROJ-1 "$FIELDS" markdown "$good")"; expect_rejected "another server" "another MCP server"
hook "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "$(jq -nc --arg s "$SENTINEL" '{error: true, message: ("not found " + $s), statusCode: 404}')")"; expect_rejected ".error" "reported an error"
hook "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "$(issue_text PROJ-9)")"; expect_rejected "moved key" "different ticket"
hook "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "$(printf '%s' "$good" | jq -c '.issues.nodes += .issues.nodes')")"; expect_rejected "two nodes" "exactly one issue"
hook "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "{not json $SENTINEL" string)"; expect_rejected "malformed JSON" "not valid JSON"
hook "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "$good" array)"; assert_eq "$(ncaps)" "1" "control: the same call is accepted"
rm -f plans/PROJ-1/.mcp/cap-*.json
run env CLAUDE_PROJECT_DIR="$SB" ASDLC_MCP_MAX_BYTES=300 bash -c 'printf "%s" "$1" | "$2"' _ "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "$good")" "$HOOK"; expect_rejected "over-size" "larger than the capture limit"
hook "$(stdin_json "$TOOL" '../etc/PROJ-1' "$FIELDS" markdown "$good")"; expect_rejected "a ../ key" "no valid Jira key"
assert_eq "$(find "$SB" -name 'cap-*' | wc -l | tr -d ' ')" "0" "nothing anywhere"
hook "$(stdin_json "$TOOL" "PROJ-1
PROJ-2" "$FIELDS" markdown "$good")"; expect_rejected "a key with a newline" "no valid Jira key"

t "an expired request is rejected, and never captures"
jq '.expires_epoch = (now | floor) - 1' plans/PROJ-1/.mcp/request.json > r.tmp && mv r.tmp plans/PROJ-1/.mcp/request.json
issue_call PROJ-1; expect_rejected "expired" "expired"

t "a symlinked .mcp (or request) is rejected and nothing is written through it"
sandbox; open_req PROJ-1 fetch
mv plans/PROJ-1/.mcp "$SB/real-mcp"; ln -s "$SB/real-mcp" plans/PROJ-1/.mcp
issue_call PROJ-1
assert_contains "$(receipt_text)" "symbolic link" "receipt"
assert_not_contains "$OUT" "$SENTINEL" "sentinel"
assert_eq "$(find "$SB/real-mcp" -name 'cap-*' | wc -l | tr -d ' ')" "0" "nothing through the link"
rm plans/PROJ-1/.mcp; mkdir plans/PROJ-1/.mcp; ln -s "$SB/real-mcp/request.json" plans/PROJ-1/.mcp/request.json
issue_call PROJ-1
assert_contains "$(receipt_text)" "symbolic link" "request.json link"
assert_eq "$(find "$SB/plans" -name 'cap-*' | wc -l | tr -d ' ')" "0" "no captures"

t "a malformed request is rejected the same way (fail closed)"
sandbox; mkdir -p plans/PROJ-1/.mcp; echo '{broken' > plans/PROJ-1/.mcp/request.json
issue_call PROJ-1
assert_contains "$(receipt_text)" "rejected" "receipt"
assert_not_contains "$OUT" "$SENTINEL" "sentinel"

t "if the hook cannot run jq while a request is open it still withholds the response"
sandbox; open_req PROJ-1 fetch
nojq="$SB/nojq"; mkdir -p "$nojq"
for b in date cat mktemp rm dirname bash; do ln -s "$(command -v $b)" "$nojq/$b"; done
run env PATH="$nojq" CLAUDE_PROJECT_DIR="$SB" "$(command -v bash)" -c 'printf "%s" "$1" | "$2"' _ "$(stdin_json "$TOOL" PROJ-1 "$FIELDS" markdown "$(issue_text PROJ-1)")" "$HOOK"
assert_eq "$CODE" "0" "exit"
assert_contains "$OUT" "withheld" "fixed receipt"
assert_not_contains "$OUT$ERR" "$SENTINEL" "sentinel"

t "a write tool this request did not ask for is left alone; one it did ask for is captured"
sandbox; open_req PROJ-1 fetch
hook "$(stdin_json "mcp__${SERVER}__transitionJiraIssue" PROJ-1 '[]' markdown '{"ok":true}')"
assert_eq "$CODE/$OUT" "0/" "not part of a fetch request"
open_req PROJ-1 transition
hook "$(stdin_json "mcp__${SERVER}__getTransitionsForJiraIssue" PROJ-1 '[]' markdown '{"transitions":[{"id":"11","name":"Start"}]}')"
assert_eq "$(ncaps)" "1" "transitions captured"
assert_eq "$(jq -r .role "$(caps)")" "getTransitionsForJiraIssue" "role"
assert_contains "$(receipt_text)" "captured the getTransitionsForJiraIssue response for PROJ-1" "receipt"

# ---- the PreToolUse guard -------------------------------------------------------------------
guard_in() {  # <tool> <tool_input json>
  jq -nc --arg tn "mcp__${SERVER}__$1" --argjson ti "$2" '{session_id: "s", hook_event_name: "PreToolUse", tool_name: $tn, tool_input: $ti}'
}
# tool_input of a comment: a markdown body ("md"), or an ADF document whose first text is $2 ("adf").
comment_in() {  # <md|adf> <text> [extra tool_input json]
  local extra="${3-}"; [ -n "$extra" ] || extra='{}'
  jq -nc --arg f "$1" --arg t "$2" --argjson x "$extra" '
    {issueIdOrKey: "PROJ-1"} + $x + (if $f == "md" then {commentBody: $t}
      else {contentFormat: "adf", commentBody: ({type: "doc", version: 1, content: [{type: "paragraph", content: [{type: "text", text: $t}, {type: "mention", attrs: {id: "a1"}}]}]} | tojson)} end)'
}
t "the guard blocks a comment edit, an issue edit and an unmarked comment, but only while a request is open"
sandbox
hook "$(guard_in editJiraIssue '{"issueIdOrKey":"PROJ-1","fields":{}}')" guard; assert_eq "$CODE" "0" "no request: editJiraIssue allowed"
hook "$(guard_in addCommentToJiraIssue '{"issueIdOrKey":"PROJ-1","commentBody":"hello"}')" guard; assert_eq "$CODE/$OUT/$ERR" "0//" "no request: any comment allowed"
open_req PROJ-1 comment
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "[asdlc] edited" '{"commentId":"77"}')")" guard
assert_eq "$CODE" "2" "commentId"; assert_contains "$ERR" "existing comment" "reason"
hook "$(guard_in editJiraIssue '{"issueIdOrKey":"PROJ-1","fields":{"summary":"x"}}')" guard
assert_eq "$CODE" "2" "editJiraIssue"; assert_contains "$ERR" "editing the issue is blocked" "reason"
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "no marker here")")" guard
assert_eq "$CODE" "2" "unmarked markdown body"; assert_contains "$ERR" "pipeline marker" "reason"
hook "$(guard_in addCommentToJiraIssue "$(comment_in adf "hi [asdlc]")")" guard
assert_eq "$CODE" "2" "unmarked ADF body"
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "  \\[asdlc\\] plan ready")")" guard
assert_eq "$CODE/$ERR" "0/" "a marked body, with Jira's wiki escapes and leading space"
hook "$(guard_in addCommentToJiraIssue "$(comment_in adf "[asdlc] ready")")" guard
assert_eq "$CODE/$ERR" "0/" "a marked ADF body"
hook "$(guard_in addCommentToJiraIssue '{"issueIdOrKey":"PROJ-1"}')" guard; assert_eq "$CODE" "2" "no body"
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "unmarked, another ticket" '{"issueIdOrKey":"PROJ-7"}')")" guard
assert_eq "$CODE" "0" "a ticket with no open request"
jq '.expires_epoch = (now | floor) - 1' plans/PROJ-1/.mcp/request.json > r.tmp && mv r.tmp plans/PROJ-1/.mcp/request.json
hook "$(guard_in editJiraIssue '{"issueIdOrKey":"PROJ-1","fields":{}}')" guard; assert_eq "$CODE" "0" "expired request: not open"

# ---- a comment request opened by jira-notify.sh --adf arms the guard and records the id ------
write_in() {  # <tool> <response text or ""> [tool_input json]: PostToolUse stdin for a write
  local dti='{"cloudId":"example.atlassian.net","issueIdOrKey":"PROJ-1"}'
  jq -nc --arg tn "mcp__${SERVER}__$1" --arg r "$2" --argjson ti "${3:-$dti}" '
    {session_id: "sess-1", hook_event_name: "PostToolUse", tool_name: $tn, tool_input: $ti,
     tool_response: [{type: "text", text: $r}], tool_use_id: "toolu_x"}'
}
t "jira-notify.sh --adf is what arms the comment guard; without it nothing is blocked"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1'
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "no marker here")")" guard
assert_eq "$CODE" "0" "no request yet: not blocked"
run "$S/jira-notify.sh" --adf PROJ-1 "Ready." ; assert_eq "$CODE" "0" "notify --adf exit"; ADF="$OUT"
assert_eq "$(jq -r '.purpose' plans/PROJ-1/.mcp/request.json)" "comment" "request purpose"
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "no marker here")")" guard
assert_eq "$CODE" "2" "unmarked body now blocked"
hook "$(guard_in addCommentToJiraIssue "$(comment_in md "x" '{"commentId":"5"}')")" guard
assert_eq "$CODE" "2" "commentId blocked"
hook "$(guard_in editJiraIssue '{"issueIdOrKey":"PROJ-1","fields":{}}')" guard
assert_eq "$CODE" "2" "editJiraIssue blocked"
hook "$(guard_in addCommentToJiraIssue "$(jq -nc --arg b "$ADF" '{issueIdOrKey: "PROJ-1", contentFormat: "adf", commentBody: $b}')")" guard
assert_eq "$CODE/$ERR" "0/" "the body --adf printed passes the guard"
hook "$(guard_in addCommentToJiraIssue "$(jq -nc --argjson b "$ADF" '{issueIdOrKey: "PROJ-1", contentFormat: "adf", commentBody: $b}')")" guard
assert_eq "$CODE/$ERR" "0/" "the same body as an object passes too"

t "the comment write is captured with its id only, and the model gets a receipt without ticket text"
hook "$(write_in addCommentToJiraIssue "$(jq -nc --arg s "$SENTINEL" '{id: "10042", body: ("[asdlc] " + $s), author: {accountId: "acc-9"}}')")"
assert_eq "$CODE" "0" "exit"
assert_eq "$(ncaps)" "1" "one capture"
assert_eq "$(jq -c '[.role, .response]' "$(caps)")" '["addCommentToJiraIssue",{"id":"10042"}]' "role and only the id"
assert_contains "$(receipt_text)" "comment id 10042" "receipt carries the id"
assert_not_contains "$OUT$(cat "$(caps)")" "$SENTINEL" "no body anywhere"
assert_not_contains "$OUT$(cat "$(caps)")" "acc-9" "no author"
run "$S/jira-notify.sh" --from-mcp PROJ-1
assert_eq "$CODE/$OUT" "0/COMMENT 10042" "consumed"
assert_eq "$(ls -A plans/PROJ-1 2>/dev/null)" "" "closed after use"
run "$S/jira-notify.sh" --adf PROJ-1 >/dev/null 2>&1
hook "$(write_in addCommentToJiraIssue '{"comment":{"id":77}}')"
assert_eq "$(jq -c .response "$(caps)")" '{"id":"77"}' "a nested numeric id"
rm -f "$(caps)"
hook "$(write_in addCommentToJiraIssue '{"id":"not-a-number","body":"x"}')"
assert_eq "$(jq -c .response "$(caps)")" '{"id":null}' "an odd id is not stored"; assert_contains "$(receipt_text)" "comment id unknown" "receipt"
rm -f "$(caps)"
hook "$(write_in addCommentToJiraIssue '{"error":true,"message":"nope"}')"
expect_rejected "a comment error" "tool reported an error"
t "a comment write while a fetch request is open is not ours; a transition write with an empty answer is recorded"
sandbox; open_req PROJ-1 fetch
hook "$(write_in addCommentToJiraIssue '{"id":"1"}')"; assert_eq "$CODE/$OUT" "0/" "left alone"; assert_eq "$(ncaps)" "0" "no capture"
open_req PROJ-1 transition
hook "$(write_in transitionJiraIssue "" '{"cloudId":"x","issueIdOrKey":"PROJ-1","transition":{"id":"21"}}')"
assert_eq "$(ncaps)" "1" "captured"; assert_eq "$(jq -c '[.role, .response]' "$(caps)")" '["transitionJiraIssue",{}]' "empty answer"
assert_contains "$(receipt_text)" "captured the transitionJiraIssue response" "receipt"
rm -f "$(caps)"
hook "$(write_in getTransitionsForJiraIssue '{"nope":1}')"
expect_rejected "a transitions answer without a list" "not a list of transitions"

# ---- run-state sweeps expired requests ----------------------------------------------------
t "run-state lock and unlock sweep expired requests, keep live ones, never follow a link"
sandbox
open_req PROJ-1 fetch >/dev/null; open_req PROJ-2 check >/dev/null; open_req PROJ-3 fetch >/dev/null
jq '.expires_epoch = (now | floor) - 5' plans/PROJ-1/.mcp/request.json > r.tmp && mv r.tmp plans/PROJ-1/.mcp/request.json
mkdir -p plans/.mcp/search; echo '{"expires_epoch": 1}' > plans/.mcp/search/request.json
mkdir -p plans/PROJ-4/.mcp; echo junk > plans/PROJ-4/.mcp/cap-1-1.json; touch -t 202001010000 plans/PROJ-4/.mcp
mkdir -p "$SB/keep"; echo x > "$SB/keep/request.json"; mkdir -p plans/PROJ-5; ln -s "$SB/keep" plans/PROJ-5/.mcp
run "$RS" lock; assert_eq "$CODE" "0" "lock exit"; ID="$OUT"
assert_not_contains "$OUT" "mcp" "lock stays quiet"
[ ! -e plans/PROJ-1/.mcp ] && ok || nok "expired request kept"
[ -f plans/PROJ-2/.mcp/request.json ] && [ -f plans/PROJ-3/.mcp/request.json ] && ok || nok "live request swept"
[ ! -e plans/.mcp ] && ok || nok "expired search request kept"
[ ! -e plans/PROJ-4/.mcp ] && ok || nok "old orphan directory kept"
[ -L plans/PROJ-5/.mcp ] && [ -f "$SB/keep/request.json" ] && ok || nok "swept through a symlink"
jq '.expires_epoch = (now | floor) - 5' plans/PROJ-2/.mcp/request.json > r.tmp && mv r.tmp plans/PROJ-2/.mcp/request.json
run "$RS" unlock "$ID"; assert_eq "$CODE" "0" "unlock exit"
[ ! -e plans/PROJ-2/.mcp ] && ok || nok "unlock did not sweep"
[ -f plans/PROJ-3/.mcp/request.json ] && ok || nok "unlock swept a live request"
run "$RS" lock; ID="$OUT"; run "$RS" lock; assert_eq "$CODE" "10" "a refused lock still refuses"
[ -f plans/PROJ-3/.mcp/request.json ] && ok || nok "live request lost"

# ---- the plugin's hook wiring --------------------------------------------------------------
t "hooks.json wires the capture to the five tools and the guard to comment and edit only"
HJ="$ROOT/plugins/asdlc/hooks/hooks.json"
assert_eq "$(jq -r '.hooks.PostToolUse[0].matcher' "$HJ")" '^mcp__.+__(getJiraIssue|searchJiraIssuesUsingJql|getTransitionsForJiraIssue|transitionJiraIssue|addCommentToJiraIssue)$' "post matcher"
assert_eq "$(jq -r '.hooks.PreToolUse[0].matcher' "$HJ")" '^mcp__.+__(addCommentToJiraIssue|editJiraIssue)$' "pre matcher"
assert_eq "$(jq -r '.hooks.PostToolUse[0].hooks[0] | "\(.command) \(.timeout)"' "$HJ")" '"${CLAUDE_PLUGIN_ROOT}/hooks/mcp-capture.sh" 30' "post command"
assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HJ")" '"${CLAUDE_PLUGIN_ROOT}/hooks/mcp-capture.sh" guard' "pre command"
for tn in getJiraIssue searchJiraIssuesUsingJql getTransitionsForJiraIssue transitionJiraIssue addCommentToJiraIssue; do
  printf '%s' "mcp__any_Server-1__$tn" | grep -qE "$(jq -r '.hooks.PostToolUse[0].matcher' "$HJ")" && ok || nok "matcher misses $tn"
done
printf '%s' "mcp__s__createJiraIssue" | grep -qE "$(jq -r '.hooks.PostToolUse[0].matcher' "$HJ")" && nok "matcher takes createJiraIssue" || ok

# ---- the search request (jira-mine.sh --mcp-args) -------------------------------------------
STOOL="mcp__${SERVER}__searchJiraIssuesUsingJql"
SF='["summary","status","priority","issuetype","labels"]'
SECRET="SENTINEL-SUMMARY-9"
search_text() { jq -nc --arg s "$SECRET" '{issues: {nodes: [{key: "PROJ-1", fields: {summary: $s, status: {name: "To Do"}}}, {key: "PROJ-2", fields: {summary: "b", status: {name: "To Do"}}}], pageInfo: {hasNextPage: false, endCursor: null}}, context: {cloudId: "c"}}'; }
search_in() {  # <response text> [jql] [fields json] [maxResults] [tool name]
  jq -nc --arg tn "${5:-$STOOL}" --arg r "$1" --arg q "${2:-$SJQL}" --argjson f "${3:-$SF}" --argjson m "${4:-40}" '
    {session_id: "sess-1", hook_event_name: "PostToolUse", tool_name: $tn,
     tool_input: {cloudId: "example.atlassian.net", jql: $q, fields: $f, maxResults: $m},
     tool_response: [{type: "text", text: $r}], tool_use_id: "t"}'
}
scaps() { find "$SB/plans/.mcp/search" -name 'cap-*.json' 2>/dev/null | sort; }
open_search() { run "$S/jira-mine.sh" --mcp-args --anyone --any-status; assert_eq "$CODE" "0" "--mcp-args exit"; }
SJQL='project = "PROJ" ORDER BY created ASC'
srej() {  # <what> <reason fragment>
  assert_eq "$CODE" "0" "$1: exit"; assert_contains "$(receipt_text)" "rejected" "$1: receipt"; assert_contains "$(receipt_text)" "$2" "$1: reason"
  assert_not_contains "$OUT$ERR" "$SECRET" "$1: ticket text"; assert_eq "$(scaps | grep -c . || true)" "0" "$1: captures written"
}

t "a search request alone engages the hook: capture without context, receipt with counts and no ticket text"
sandbox; open_search
assert_eq "$(jq -r '.kind' plans/.mcp/search/request.json)" "search" "request kind"
hook "$(search_in "$(search_text)")"
assert_eq "$CODE" "0" "exit"; assert_eq "$ERR" "" "stderr"
assert_eq "$(receipt_text)" "asdlc captured the search (2 tickets, more pages: no). Next: run jira-mine.sh --from-mcp with the same selection." "receipt"
assert_not_contains "$OUT" "$SECRET" "ticket text"
assert_eq "$(scaps | grep -c .)" "1" "one capture"
c="$(scaps | head -n1)"
assert_eq "$(jq -r '[.role, .tool_name, (.nonce == input.nonce), has("response"), (.response | has("context")), (.response.issues.nodes | length)] | map(tostring) | join(" ")' "$c" plans/.mcp/search/request.json)" "search $STOOL true true false 2" "capture"
assert_eq "$(find "$SB/plans/.mcp/search" -name '.cap.*' | wc -l | tr -d ' ')" "0" "no temp dir left"
for shape in string object; do
  sandbox; open_search
  if [ "$shape" = string ]; then in="$(jq -c --arg r "$(search_text)" '.tool_response = $r' <<<"$(search_in x)")"; else in="$(jq -c --argjson r "$(search_text)" '.tool_response = $r' <<<"$(search_in x)")"; fi
  hook "$in"; assert_contains "$(receipt_text)" "captured the search" "$shape response"; assert_eq "$(scaps | grep -c .)" "1" "$shape capture"
done
sandbox; open_search; hook "$(search_in "$(search_text | jq -c '.issues.pageInfo.hasNextPage = true')")"
assert_contains "$(receipt_text)" "more pages: yes" "hasNextPage in the receipt"

t "search capture rejections: another server, expired, args that differ, an error, not a search result, malformed, over-size, symlinks"
sandbox; open_search; hook "$(search_in "$(search_text)" "$SJQL" "$SF" 40 "mcp__other_server__searchJiraIssuesUsingJql")"; srej "another server" "another MCP server"
sandbox; open_search; hook "$(search_in "$(search_text)" 'project = "OTHER"')"; srej "another jql" "differ from what the request asked for"
sandbox; open_search; hook "$(search_in "$(search_text)" "$SJQL" '["summary","description"]')"; srej "other fields" "differ"
sandbox; open_search; hook "$(search_in "$(search_text)" "$SJQL" "$SF" 41)"; srej "other maxResults" "differ"
sandbox; open_search; jq '.expires_epoch = (now | floor) - 5' plans/.mcp/search/request.json > "$SB/r" && mv "$SB/r" plans/.mcp/search/request.json
hook "$(search_in "$(search_text)")"; srej "expired" "expired"
sandbox; open_search; hook "$(search_in '{"error":true,"message":"nope","statusCode":500}')"; srej "an error" "reported an error"
sandbox; open_search; hook "$(search_in '{"issues":{"nodes":"x"}}')"; srej "not a search result" "not a search result"
sandbox; open_search; hook "$(search_in 'not json {')"; srej "malformed" "not valid JSON"
sandbox; open_search; run env ASDLC_MCP_MAX_BYTES=50 CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "$1" | "$2"' _ "$(search_in "$(search_text)")" "$HOOK"; srej "over-size" "larger than the capture limit"
sandbox; open_search; rm -rf plans/.mcp/search/request.json; echo '{}' > plans/.mcp/search/request.json; hook "$(search_in "$(search_text)")"; srej "unreadable request" "unreadable request"
sandbox; open_search; mv plans/.mcp/search "$SB/real"; ln -s "$SB/real" plans/.mcp/search
hook "$(search_in "$(search_text)")"; srej "symlinked search dir" "symbolic link"
assert_eq "$(find "$SB/real" -name 'cap-*' | wc -l | tr -d ' ')" "0" "nothing written through the link"
sandbox; open_search; rm plans/.mcp/search/request.json; hook "$(search_in "$(search_text)")"
assert_eq "$CODE/$OUT/$ERR" "0//" "no request: a search is not ours"
sandbox; open_req PROJ-1 fetch; hook "$(search_in "$(search_text)")"
assert_eq "$CODE/$OUT/$ERR" "0//" "only an issue request is open: a search is not ours"; assert_eq "$(ncaps)" "0" "nothing captured"
sandbox; open_search; issue_call PROJ-1
assert_eq "$CODE/$OUT/$ERR" "0//" "only a search request is open: an issue read is not touched"

finish
