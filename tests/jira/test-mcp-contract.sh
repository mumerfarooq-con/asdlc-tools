#!/usr/bin/env bash
# The MCP capture contract, end to end (PR #8 SF-3). Every chain here is real on all three sides:
# the script that opens the request prints the call, the REAL hooks/mcp-capture.sh stores what that
# call returned, and the REAL consumer reads what the hook stored. Nothing in a chain is written by
# hand except the (synthetic) tool_response, so a change to the envelope, the request schema, the
# expiry or the nonce on one side fails here even when each half still passes its own tests.
# No MCP server, no network, no Jira: the stdin JSON the hook gets is built from the printed call.
. "$(dirname "$0")/helpers.sh"
JC="$S/jira-context.sh"; PS="$SHARED/plan-state.sh"; HOOK="$ROOT/plugins/asdlc/hooks/mcp-capture.sh"
MCPFX="$FIXTURES/context-mcp"
SERVER=fixture_atlassian
export ASDLC_JIRA_MCP_SERVER="$SERVER" ASDLC_TEST_FIXTURE_CHECK=1
unset JIRA_EMAIL JIRA_TOKEN

# Feed the hook the call the opener printed ({tool, args}) and a tool_response body. Sets OUT/ERR/CODE.
hook_call() {  # <printed call json> <response json> [hook mode]
  local in; in="$(jq -nc --argjson c "$1" --arg r "$2" '
    {session_id: "sess-1", cwd: "/x", hook_event_name: "PostToolUse", tool_name: $c.tool, tool_input: $c.args,
     tool_response: [{type: "text", text: $r}], tool_use_id: "toolu_x"}')"
  run env CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "$1" | "$2" "${@:3}"' _ "$in" "$HOOK" ${3:+"$3"}
}
receipt_text() { printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedMCPToolOutput // empty' 2>/dev/null; }
# After a hook run: it captured (its receipt says so) and withheld the response.
captured() {  # <what>
  assert_eq "$CODE" "0" "$1: hook exit"
  assert_contains "$(receipt_text)" "captured" "$1: receipt"
}
ctx_sandbox() { sandbox "$@"; use_fixtures context; mkdir -p "fx/jira/rest/api/2/attachment/content"; printf '\211PNG\r\n\032\n\000\001' > "fx/jira/rest/api/2/attachment/content/10001.json"; }

# ---- jira-context.sh: mcp-request -> hook (issue, then the parent it names) -> fetch -> build ----
t "contract: mcp-request, the hook's issue and parent captures, then fetch --source mcp and build"
ctx_sandbox
run "$JC" mcp-request PROJ-1 --for fetch; assert_eq "$CODE" "0" "mcp-request exit"; CALL="$OUT"
hook_call "$CALL" "$(cat "$MCPFX/issue.response.json")"; captured "issue"
NEXTCALL="$(receipt_text | sed -n 's/.*exactly these args, then run [^:]*: //p')"
assert_eq "$(printf '%s' "$NEXTCALL" | jq -r '.args.issueIdOrKey' 2>/dev/null)" "PROJ-0" "the receipt names the parent call"
hook_call "$NEXTCALL" "$(cat "$MCPFX/parent.response.json")"; captured "parent"
run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "0" "fetch exit"; assert_contains "$OUT" "parent PROJ-0" "fetch saw the parent the hook captured"
assert_eq "$(sed -n 3p plans/PROJ-1/fingerprint)" "fingerprint_source: mcp" "source"
assert_eq "$(jq -r '.source' plans/PROJ-1/raw/fetch.json)" "mcp" "fetch.json"
run "$JC" build PROJ-1 --source mcp; assert_eq "$CODE" "0" "build exit"
assert_contains "$(cat plans/PROJ-1/context.md)" "# PROJ-1:" "context.md built"

# ---- jira-context.sh check on an approved mcp plan: FRESH, then STALE after a changed capture ----
t "contract: check over MCP is FRESH on the same ticket and STALE after the hook stores a changed one"
printf '# PROJ-1: plan\n\n## Changes\n1. do it\n' > plans/PROJ-1.plan.md
"$PS" stamp plans/PROJ-1.plan.md >/dev/null
sed "1,/^-->/s/^status: .*/status: approved/" plans/PROJ-1.plan.md > plans/PROJ-1.plan.md.t && mv plans/PROJ-1.plan.md.t plans/PROJ-1.plan.md
assert_eq "$("$PS" get plans/PROJ-1.plan.md fingerprint_source)" "mcp" "an mcp plan"
run "$JC" mcp-request PROJ-1 --for check; CALL="$OUT"
hook_call "$CALL" "$(cat "$MCPFX/issue.response.json")"; captured "check capture"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE/$OUT" "0/FRESH" "unchanged ticket"
run "$JC" mcp-request PROJ-1 --for check; CALL="$OUT"
hook_call "$CALL" "$(jq -c '.issues.nodes[0].fields.comment.comments[0].body = "Edited: the copy changed."' "$MCPFX/issue.response.json")"; captured "changed capture"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "17" "exit"; assert_eq "$(printf '%s' "$OUT" | head -n1)" "STALE 1 edited comment" "verdict"
assert_not_contains "$OUT$ERR" "Edited: the copy changed." "no comment text on stdout/stderr"

# ---- jira-transition.sh --mcp-args -> hook (both reads) -> --from-mcp ----------------------
t "contract: transition --mcp-args, the hook's two captures, then --from-mcp prints the write"
sandbox 'STATUS_TESTING=QA'; use_fixtures basic
run "$S/jira-transition.sh" --mcp-args PROJ-1; assert_eq "$CODE" "0" "--mcp-args exit"
READ1="$(printf '%s\n' "$OUT" | sed -n 1p)"; READ2="$(printf '%s\n' "$OUT" | sed -n 2p)"
hook_call "$READ1" '{"issues":{"nodes":[{"key":"PROJ-1","fields":{"status":{"name":"To Do"}}}]}}'; captured "status read"
hook_call "$READ2" '{"transitions":[{"id":"21","name":"Start work","to":{"name":"In Progress"}},{"id":"31","name":"Ready for QA","to":{"name":"QA"}}]}'; captured "transitions read"
run "$S/jira-transition.sh" --from-mcp PROJ-1 :testing
assert_eq "$CODE" "0" "--from-mcp exit"; assert_eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "TRANSITION 31" "the id the hook-stored list gave"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 2p | jq -c '.args.transition')" '{"id":"31"}' "the write call"

# ---- jira-notify.sh --adf -> the guard and the hook -> --from-mcp --------------------------
t "contract: notify --adf arms the guard, the hook stores the comment id, --from-mcp prints it"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1'; use_fixtures basic
run "$S/jira-notify.sh" --adf PROJ-1 "Ready."; assert_eq "$CODE" "0" "--adf exit"; ADF="$OUT"
CLOUD="$(jq -r '.cloud_id' plans/PROJ-1/.mcp/request.json)"
WRITE="$(jq -nc --arg t "mcp__${SERVER}__addCommentToJiraIssue" --arg c "$CLOUD" --arg b "$ADF" \
  '{tool: $t, args: {cloudId: $c, issueIdOrKey: "PROJ-1", contentFormat: "adf", commentBody: $b}}')"
run env CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "$1" | "$2" guard' _ \
  "$(jq -nc --argjson w "$WRITE" '{session_id: "s", hook_event_name: "PreToolUse", tool_name: $w.tool, tool_input: $w.args}')" "$HOOK"
assert_eq "$CODE/$ERR" "0/" "the guard lets the printed body through"
hook_call "$WRITE" '{"id":"10042","body":"never stored"}'; captured "comment write"
run "$S/jira-notify.sh" --from-mcp PROJ-1; assert_eq "$CODE/$OUT" "0/COMMENT 10042" "the id the hook stored"

# ---- jira-mine.sh --mcp-args -> hook -> --from-mcp -----------------------------------------
t "contract: mine --mcp-args, the hook's search capture, then --from-mcp lists the tickets"
sandbox
run "$S/jira-mine.sh" --mcp-args --anyone --any-status; assert_eq "$CODE" "0" "--mcp-args exit"; CALL="$OUT"
hook_call "$CALL" '{"issues":{"nodes":[{"key":"PROJ-1","fields":{"summary":"Ticket 1","status":{"name":"To Do"},"priority":{"name":"High"},"issuetype":{"name":"Bug"},"labels":["web"]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}'
captured "search"
run "$S/jira-mine.sh" --from-mcp --anyone --any-status
assert_eq "$CODE" "0" "--from-mcp exit"; assert_eq "$(jq -c '[.[].key]' <<<"$OUT")" '["PROJ-1"]' "the ticket the hook stored"

# ---- bb-open-pr.sh --mcp-args -> the hook's bb mode -> --from-mcp (test profile) -----------
t "contract: bb-open-pr --mcp-args, the hook's bb capture, then --from-mcp prints '<id> <url>'"
sandbox 'BB_TRANSPORT=mcp'
export ASDLC_BB_MCP_SERVER=bbfixture ASDLC_BB_MCP_PROFILE=test ASDLC_ALLOW_TEST_BB_PROFILE=1
URL="https://bitbucket.example.test/acme/widgets/pull-requests/42"
run "$S/bb-open-pr.sh" --mcp-args feature/x "Add x"; assert_eq "$CODE" "0" "--mcp-args exit"; CALL="$OUT"
hook_call "$CALL" "$(jq -nc --arg u "$URL" '{id: 42, title: "never stored", links: {html: {href: $u}}}')" bb
assert_contains "$(receipt_text)" "captured the Bitbucket response (id 42)" "bb receipt"
run "$S/bb-open-pr.sh" --from-mcp; assert_eq "$CODE/$OUT" "0/42 $URL" "the id and url the hook stored"
unset ASDLC_BB_MCP_SERVER ASDLC_BB_MCP_PROFILE ASDLC_ALLOW_TEST_BB_PROFILE

finish
