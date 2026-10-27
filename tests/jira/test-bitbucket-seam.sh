#!/usr/bin/env bash
# The Bitbucket MCP seam (D-M7): BB_TRANSPORT, the profile file, bb-open-pr.sh / bb-pr-comment.sh
# --mcp-args and --from-mcp, and the capture hook's bb mode. Synthetic tool names, no network.
. "$(dirname "$0")/helpers.sh"
OPEN="$S/bb-open-pr.sh"; CMT="$S/bb-pr-comment.sh"; HOOK="$ROOT/plugins/asdlc/hooks/mcp-capture.sh"
PROFILE="$ROOT/plugins/asdlc/jira/mcp/bitbucket-test.json"
SRV=bbfixture
OT="mcp__${SRV}__testOpenPullRequest"; CT="mcp__${SRV}__testCreatePrComment"
URL="https://bitbucket.example.test/acme/widgets/pull-requests/42"
use_test_profile() { export ASDLC_BB_MCP_SERVER="$SRV" ASDLC_BB_MCP_PROFILE=test ASDLC_ALLOW_TEST_BB_PROFILE=1; }
no_profile_env() { unset ASDLC_BB_MCP_SERVER ASDLC_BB_MCP_PROFILE ASDLC_ALLOW_TEST_BB_PROFILE; }
bbhook() {  # <stdin json> [mode]
  local in="$1"; shift
  run env CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "$1" | "$2" "${@:3}"' _ "$in" "$HOOK" "${@:-bb}"
}
hook_in() {  # <tool_name> <tool_input json> <response json|array> 
  jq -nc --arg tn "$1" --argjson ti "$2" --arg r "$3" \
    '{session_id: "s1", cwd: "/x", hook_event_name: "PostToolUse", tool_name: $tn, tool_input: $ti,
      tool_response: [{type: "text", text: $r}], tool_use_id: "toolu_x"}'
}
reqargs() { jq -c '.args' "$SB/plans/.mcp/bb/request.json"; }
ncap() { find "$SB/plans/.mcp/bb" -name 'cap-*.json' 2>/dev/null | grep -c . || true; }
receipt() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedMCPToolOutput // empty' 2>/dev/null; }
OK_RESP="$(jq -nc --arg u "$URL" '{id: 42, title: "never stored", links: {html: {href: $u}}, description: "SENTINEL-PR-BODY"}')"

t "the profile file is valid, synthetic, and flagged test; the hook and lib name no tool of it"
jq -e '.test == true and .profile == "test" and (.open_pr.tool | test("^test")) and (.pr_comment.tool | test("^test"))' "$PROFILE" >/dev/null && ok || nok "profile shape"
for f in "$ROOT/plugins/asdlc/hooks/mcp-capture.sh" "$ROOT/plugins/asdlc/jira/scripts/lib.sh" "$ROOT/plugins/asdlc/hooks/hooks.json"; do
  assert_eq "$(grep -c 'testOpenPullRequest\|testCreatePrComment' "$f")" "0" "no hard-coded Bitbucket tool in $(basename "$f")"
done
assert_contains "$(jq -r '.hooks.PostToolUse[].hooks[].command' "$ROOT/plugins/asdlc/hooks/hooks.json")" "mcp-capture.sh\" bb" "bb mode registered"

t "transport validation: a bad value, a missing server, a missing or test-only profile all stop with a message"
sandbox 'BB_TRANSPORT=pigeon'; no_profile_env
run "$OPEN" --mcp-args feature/x "Add x"; assert_eq "$CODE" "2" "bad BB_TRANSPORT"; assert_contains "$ERR" "BB_TRANSPORT must be rest or mcp"
sandbox 'BB_TRANSPORT=mcp'
run "$OPEN" --mcp-args feature/x "Add x"; assert_eq "$CODE" "2" "no server"; assert_contains "$ERR" "needs ASDLC_BB_MCP_SERVER"
ASDLC_BB_MCP_SERVER=nosuch run "$OPEN" --mcp-args feature/x "Add x"
assert_eq "$CODE" "2" "no profile"; assert_contains "$ERR" "no Bitbucket MCP profile 'nosuch'"; assert_contains "$ERR" "BB_TRANSPORT=rest"
ASDLC_BB_MCP_SERVER=test run "$OPEN" --mcp-args feature/x "Add x"
assert_eq "$CODE" "2" "test profile without the allowance"; assert_contains "$ERR" "for tests only"
ASDLC_BB_MCP_SERVER=test run "$CMT" --mcp-args 7 "hi"; assert_eq "$CODE" "2" "comment: same"
ASDLC_BB_MCP_SERVER=test run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "from-mcp: same"; assert_contains "$ERR" "for tests only"
ASDLC_BB_MCP_SERVER='a b' run "$OPEN" --mcp-args feature/x "Add x"; assert_eq "$CODE" "2" "server name shape"
[ ! -e plans ] && ok || nok "no request was opened by a refused call"
use_test_profile
run "$OPEN" feature/x "Add x"; assert_eq "$CODE" "2" "a plain call under mcp never falls back to REST"; assert_contains "$ERR" "--mcp-args"
run "$CMT" 7 "hi"; assert_eq "$CODE" "2" "comment: plain call refused"
sandbox; use_test_profile
run "$OPEN" --mcp-args feature/x "Add x"; assert_eq "$CODE" "2" "rest: --mcp-args refused"; assert_contains "$ERR" "BB_TRANSPORT is rest"
run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "rest: --from-mcp refused"

t "default behaviour (rest) is unchanged: a plain call still goes over REST"
sandbox; use_fixtures basic; BITBUCKET_TOKEN=x run "$OPEN" feature/x "Add x"
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" " https://" "id and url"

t "open_pr --mcp-args: the request, and the one call printed"
sandbox 'BB_TRANSPORT=mcp'; use_test_profile
run "$OPEN" --mcp-args feature/x 'Add "x" & {title}'
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -r '.tool')" "$OT" "tool"
assert_eq "$(printf '%s' "$OUT" | jq -c '.args')" '{"workspace":"acme","repo_slug":"widgets","title":"Add \"x\" & {title}","source_branch":"feature/x","destination_branch":"main","close_source_branch":true}' "args (a literal brace title is data)"
assert_eq "$(jq -r '[.v, .kind, .op, .server, .tool, .id_path, .url_path] | join(" ")' plans/.mcp/bb/request.json)" "1 bb open_pr $SRV testOpenPullRequest id links.html.href" "request"
assert_eq "$(jq '.expires_epoch - .created_epoch' plans/.mcp/bb/request.json)" "600" "ten minutes"
run "$OPEN" --mcp-args feature/x "Add x" release; assert_eq "$(printf '%s' "$OUT" | jq -r '.args.destination_branch')" "release" "dest argument"
run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "no capture yet"; assert_contains "$ERR" "no valid capture"

t "open_pr: the hook captures only id and url, hands back a receipt, and --from-mcp keeps the '<id> <url>' contract"
sandbox 'BB_TRANSPORT=mcp'; use_test_profile
"$OPEN" --mcp-args feature/x "Add x" >/dev/null
bbhook "$(hook_in "$OT" "$(reqargs)" "$OK_RESP")"
assert_eq "$CODE" "0" "hook exit"; assert_contains "$(receipt)" "captured the Bitbucket response (id 42)" "receipt"
assert_not_contains "$OUT" "SENTINEL-PR-BODY" "response text"; assert_eq "$(ncap)" "1" "one capture"
assert_eq "$(jq -c '.response' plans/.mcp/bb/cap-*.json)" "{\"id\":\"42\",\"url\":\"$URL\"}" "only id and url stored"
assert_not_contains "$(cat plans/.mcp/bb/cap-*.json)" "SENTINEL-PR-BODY" "capture text"
run "$OPEN" --from-mcp; assert_eq "$CODE/$OUT" "0/42 $URL" "contract"
[ ! -e plans/.mcp/bb ] && ok || nok "request and capture used up"
run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "use once"

t "the default hook mode never touches a bb request, and bb mode never touches a Jira call"
sandbox 'BB_TRANSPORT=mcp'; use_test_profile
"$OPEN" --mcp-args feature/x "Add x" >/dev/null
bbhook "$(hook_in "$OT" "$(reqargs)" "$OK_RESP")" capture; assert_eq "$CODE/$OUT" "0/" "default mode: silent"; assert_eq "$(ncap)" "0" "no capture"
bbhook "$(hook_in "mcp__${SRV}__getJiraIssue" '{"issueIdOrKey":"PROJ-1"}' '{}')"; assert_eq "$CODE/$OUT" "0/" "another tool: silent"
bbhook "$(hook_in "mcp__other__testOpenPullRequest" "$(reqargs)" "$OK_RESP")"; assert_eq "$CODE/$OUT" "0/" "another server: silent"
assert_eq "$(ncap)" "0" "nothing stored"
sandbox; bbhook "$(hook_in "$OT" '{}' "$OK_RESP")"; assert_eq "$CODE/$OUT/$ERR" "0//" "no request: a no-op"
[ ! -e plans ] && ok || nok "no request: no files"

t "open_pr: rejections give a receipt with no response text and store nothing"
sandbox 'BB_TRANSPORT=mcp'; use_test_profile
"$OPEN" --mcp-args feature/x "Add x" >/dev/null
bbhook "$(hook_in "$OT" "$(reqargs | jq -c '.title = "other"')" "$OK_RESP")"
assert_contains "$(receipt)" "arguments differ"; assert_eq "$(ncap)" "0" "args differ: stored"
bbhook "$(hook_in "$OT" "$(reqargs)" '{"error":true,"message":"nope","statusCode":403}')"
assert_contains "$(receipt)" "tool reported an error"; assert_eq "$(ncap)" "0" "error: stored"
bbhook "$(hook_in "$OT" "$(reqargs)" '{"title":"SENTINEL-PR-BODY"}')"
assert_contains "$(receipt)" "no PR or comment id"; assert_not_contains "$OUT" "SENTINEL-PR-BODY" "no id: text"; assert_eq "$(ncap)" "0" "no id: stored"
bbhook "$(hook_in "$OT" "$(reqargs)" 'not json')"; assert_contains "$(receipt)" "not valid JSON"
bbhook "$(hook_in "$OT" "$(reqargs)" '{"id":"../../x","links":{"html":{"href":"https://a.test/p"}}}')"
assert_contains "$(receipt)" "no PR or comment id"; assert_eq "$(ncap)" "0" "bad id: stored"
ASDLC_MCP_MAX_BYTES=50 bbhook "$(hook_in "$OT" "$(reqargs)" "$OK_RESP")"; assert_contains "$(receipt)" "larger than the capture limit"
jq '.expires_epoch = 1' plans/.mcp/bb/request.json > r.tmp && mv r.tmp plans/.mcp/bb/request.json
bbhook "$(hook_in "$OT" "$(reqargs)" "$OK_RESP")"; assert_contains "$(receipt)" "request has expired"; assert_eq "$(ncap)" "0" "expired: stored"
"$OPEN" --mcp-args feature/x "Add x" >/dev/null; mv plans/.mcp/bb "$SB/real-bb"; ln -s "$SB/real-bb" plans/.mcp/bb
bbhook "$(hook_in "$OT" "$(reqargs)" "$OK_RESP")"; assert_contains "$(receipt)" "symbolic link"
rm plans/.mcp/bb; mv "$SB/real-bb" plans/.mcp/bb

t "open_pr: --from-mcp ignores a stale capture, another nonce, another tool, and a missing url; an expired request"
sandbox 'BB_TRANSPORT=mcp'; use_test_profile
"$OPEN" --mcp-args feature/x "Add x" >/dev/null
req=plans/.mcp/bb/request.json; nonce="$(jq -r .nonce $req)"; created="$(jq -r .created_epoch $req)"
mkcap() {  # <file> <nonce> <tool_name> <captured_epoch> <response json>
  jq -n --arg n "$2" --arg t "$3" --argjson c "$4" --argjson r "$5" '{nonce:$n, tool_name:$t, session_id:"s", captured_epoch:$c, role:"bb", response:$r}' > "plans/.mcp/bb/$1"
}
mkcap cap-1-a.json "$nonce" "$OT" $((created - 5)) "{\"id\":\"1\",\"url\":\"$URL\"}"
mkcap cap-1-b.json "ffffffffffffffff" "$OT" $((created + 1)) "{\"id\":\"2\",\"url\":\"$URL\"}"
mkcap cap-1-c.json "$nonce" "mcp__${SRV}__somethingElse" $((created + 1)) "{\"id\":\"3\",\"url\":\"$URL\"}"
run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "none valid"; assert_not_contains "$OUT" "$URL" "nothing printed"
mkcap cap-1-d.json "$nonce" "$OT" $((created + 1)) '{"id":"4","url":""}'
run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "no url"; assert_contains "$ERR" "no PR URL"
mkcap cap-1-e.json "$nonce" "$OT" $((created + 2)) "{\"id\":\"5\",\"url\":\"$URL\"}"
run "$OPEN" --from-mcp; assert_eq "$CODE/$OUT" "0/5 $URL" "the valid one"
"$OPEN" --mcp-args feature/x "Add x" >/dev/null; jq '.expires_epoch = 1' $req > r.tmp && mv r.tmp $req
run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "expired"; assert_contains "$ERR" "expired"
"$CMT" --mcp-args 7 "hi" >/dev/null; run "$OPEN" --from-mcp; assert_eq "$CODE" "1" "a comment request is not an open_pr request"; assert_contains "$ERR" "is for pr_comment"

t "pr_comment: --mcp-args, capture and --from-mcp"
sandbox 'BB_TRANSPORT=mcp'; use_test_profile
run "$CMT" --mcp-args 7 "looks good"
assert_eq "$CODE" "0" "exit"; assert_eq "$(printf '%s' "$OUT" | jq -r '.tool')" "$CT" "tool"
assert_eq "$(printf '%s' "$OUT" | jq -c '.args')" '{"workspace":"acme","repo_slug":"widgets","pull_request_id":"7","content":"looks good"}' "args"
run "$CMT" --mcp-args 7 <<<"from stdin"; assert_contains "$OUT" '"content":"from stdin' "text from stdin"
run "$CMT" --mcp-args 7x "hi"; assert_eq "$CODE" "2" "pr id must be a number"
"$CMT" --mcp-args 7 "looks good" >/dev/null
run "$CMT" --from-mcp 7; assert_eq "$CODE" "1" "no capture"
bbhook "$(hook_in "$CT" "$(reqargs)" '{"id": 501, "links": {"html": {"href": "https://bitbucket.example.test/c/501"}}}')"
assert_contains "$(receipt)" "(id 501)" "receipt"
run "$CMT" --from-mcp 7; assert_eq "$CODE/$OUT" "0/Posted comment to PR 7" "the REST contract line"
run "$CMT" --from-mcp 7; assert_eq "$CODE" "1" "use once"

finish
