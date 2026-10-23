#!/usr/bin/env bash
# jira-mine.sh: JQL built from flags + config, v2 search endpoint, output shape.
. "$(dirname "$0")/helpers.sh"

jql() { requests | jq -r '.[0].args | map(select(startswith("jql="))) | .[0] | ltrimstr("jql=")'; }

t "default selection: my STATUS_DEFAULT tickets in the project"
sandbox; use_fixtures basic
run "$S/jira-mine.sh"
assert_eq "$CODE" "0" "exit"
assert_eq "$(jql)" 'project = "PROJ" AND assignee = currentUser() AND status in ("To Do") ORDER BY created ASC'
assert_eq "$(requests | jq -r '.[0].path')" "/rest/api/2/search/jql" "endpoint"

t "output shape"
assert_eq "$(jq -r '.[0].url' <<<"$OUT")" "https://example.atlassian.net/browse/PROJ-1" "url"
assert_eq "$(jq -r '.[0].type + "|" + .[0].status + "|" + .[0].priority' <<<"$OUT")" "Bug|To Do|High"
assert_eq "$(jq -r '.[1].priority' <<<"$OUT")" "None" "null priority"
assert_eq "$(jq -c 'map(keys)|.[0]' <<<"$OUT")" '["key","labels","priority","status","summary","type","url"]'

t "descriptions are neither requested nor printed (ticket text stays out of the orchestrator)"
assert_not_contains "$OUT" "badge says Enrolled" "description text"
assert_not_contains "$OUT" "description" "description key"
assert_not_contains "$(requests | jq -r '.[0].args | map(select(startswith("fields="))) | .[0]')" "description" "fields requested"

t "STATUS_DEFAULT list from the config"
sandbox 'STATUS_DEFAULT=To Do, Idea'; use_fixtures basic
run "$S/jira-mine.sh"
assert_contains "$(jql)" 'status in ("To Do","Idea")'

t "--key ignores assignee/status/sprint and upper-cases"
sandbox; use_fixtures basic
run "$S/jira-mine.sh" --key proj-1,PROJ-2 --sprint active
assert_eq "$(jql)" 'key in ("PROJ-1","PROJ-2") ORDER BY created ASC'

t "--sprint forms, --anyone, --any-status, --status, positional project"
for pair in 'active|sprint in openSprints()' 'past|sprint in closedSprints()' \
            'next|sprint in futureSprints()' '42|sprint = 42' 'Sprint 7|sprint = "Sprint 7"'; do
  sandbox; use_fixtures basic
  run "$S/jira-mine.sh" --sprint "${pair%%|*}"
  assert_contains "$(jql)" "${pair#*|}" "sprint ${pair%%|*}"
done
sandbox; use_fixtures basic
run "$S/jira-mine.sh" OTHER --anyone --any-status
assert_eq "$(jql)" 'project = "OTHER" ORDER BY created ASC'
sandbox; use_fixtures basic
run "$S/jira-mine.sh" --status "Idea"
assert_contains "$(jql)" 'status in ("Idea")'

t "HTTP error reports the code and the JQL"
sandbox; use_fixtures basic
echo 400 > fx/jira/rest/api/2/search/jql.code
echo '{"errorMessages":["Field sprint does not exist"]}' > fx/jira/rest/api/2/search/jql.json
run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"
assert_contains "$ERR" "Jira returned HTTP 400"
assert_contains "$ERR" "Field sprint does not exist"
assert_contains "$ERR" 'JQL was: project = "PROJ"'

t "unknown option"
sandbox; use_fixtures basic
run "$S/jira-mine.sh" --bogus
assert_eq "$CODE" "2" "exit"

# ---- over the Atlassian MCP -----------------------------------------------------------------
HOOK="$ROOT/plugins/asdlc/hooks/mcp-capture.sh"; MS=fixture_atlassian; export ASDLC_JIRA_MCP_SERVER="$MS"
SEARCH_JQL='project = "PROJ" AND assignee = currentUser() AND status in ("To Do") ORDER BY created ASC'
search_resp() {  # [hasNextPage true|false] [count]: a searchJiraIssuesUsingJql response, issue fields in the verified shape
  jq -nc --argjson more "${1:-false}" --argjson n "${2:-2}" '
    {issues: {nodes: [range(0; $n) | {key: "PROJ-\(. + 1)", fields: {summary: "Ticket \(. + 1)", issuetype: {name: "Bug"}, status: {name: "To Do"},
       priority: (if . == 0 then {name: "High"} else null end), labels: ["web"]}}],
       pageInfo: {hasNextPage: $more, endCursor: (if $more then "c1" else null end)}},
     context: {cloudId: "per-call-id"}}'
}
search_call() {  # <response text> [jql override]: the hook, as the harness runs it after the model's call
  local in; in="$(jq -nc --arg tn "mcp__${MS}__searchJiraIssuesUsingJql" --arg r "$1" --arg q "${2:-$SEARCH_JQL}" '
    {session_id: "s", hook_event_name: "PostToolUse", tool_name: $tn,
     tool_input: {cloudId: "example.atlassian.net", jql: $q, fields: ["summary","status","priority","issuetype","labels"], maxResults: 40},
     tool_response: [{type: "text", text: $r}], tool_use_id: "t"}')"
  run env CLAUDE_PROJECT_DIR="$SB" bash -c 'printf "%s" "$1" | "$2"' _ "$in" "$HOOK"
}

t "--mcp-args: opens a search request and prints the one call, with the JQL built in bash; needs no token"
sandbox
run "$S/jira-mine.sh" --mcp-args
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '.')" "$OUT" "one JSON line"
assert_eq "$(jq -r '.tool' <<<"$OUT")" "mcp__${MS}__searchJiraIssuesUsingJql" "tool"
assert_eq "$(jq -r '.args.jql' <<<"$OUT")" "$SEARCH_JQL" "jql"
assert_eq "$(jq -c '.args | [.cloudId, .fields, .maxResults]' <<<"$OUT")" '["example.atlassian.net",["summary","status","priority","issuetype","labels"],40]' "args"
assert_not_contains "$OUT" "description" "no description requested"
R=plans/.mcp/search/request.json; assert_file "$R"
assert_eq "$(jq -r '[.v, .kind, .server, (.nonce | length), (.expires_epoch - .created_epoch), .jql] | map(tostring) | join("|")' "$R")" "1|search|$MS|24|600|$SEARCH_JQL" "request"
run "$S/jira-mine.sh" --mcp-args --key proj-1,PROJ-2 --sprint active
assert_eq "$(jq -r '.args.jql' <<<"$OUT")" 'key in ("PROJ-1","PROJ-2") ORDER BY created ASC' "selection flags build the JQL"
run "$S/jira-mine.sh" --mcp-args OTHER --anyone --any-status --status "Idea"
assert_eq "$(jq -r '.args.jql' <<<"$OUT")" 'project = "OTHER" ORDER BY created ASC' "positional project"
conf_set JIRA_TRANSPORT rest; run "$S/jira-mine.sh" --mcp-args; assert_eq "$CODE" "2" "JIRA_TRANSPORT=rest refuses MCP"
run env ASDLC_JIRA_MCP_SERVER='a b' "$S/jira-mine.sh" --mcp-args; assert_eq "$CODE" "2" "bad server name"

t "--from-mcp: the same JSON as the REST path, from the captured search; the request is used once"
sandbox; run "$S/jira-mine.sh" --mcp-args >/dev/null
search_call "$(search_resp false 2)"
assert_contains "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.updatedMCPToolOutput')" "asdlc captured the search (2 tickets, more pages: no)" "receipt has counts"
assert_not_contains "$OUT" "Ticket 1" "no ticket text in the receipt"
run "$S/jira-mine.sh" --from-mcp
assert_eq "$CODE" "0" "exit"; assert_eq "$ERR" "" "no warnings"
assert_eq "$(jq -c 'map(keys)|.[0]' <<<"$OUT")" '["key","labels","priority","status","summary","type","url"]' "same keys as REST"
assert_eq "$(jq -c '.[0]' <<<"$OUT")" '{"key":"PROJ-1","summary":"Ticket 1","type":"Bug","status":"To Do","priority":"High","labels":["web"],"url":"https://example.atlassian.net/browse/PROJ-1"}' "item"
assert_eq "$(jq -r '.[1].priority' <<<"$OUT")" "None" "null priority"
[ ! -e plans/.mcp ] && ok || nok "request and capture kept after use"
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "second read without a new capture"; assert_contains "$ERR" "no open MCP search request" "message"

t "--from-mcp: warns on a second page and on zero results; both leave stdout the plain list"
sandbox; run "$S/jira-mine.sh" --mcp-args >/dev/null; search_call "$(search_resp true 2)"
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "0" "exit"; assert_contains "$ERR" "more than 40 tickets match" "hasNextPage warning"
assert_eq "$(jq 'length' <<<"$OUT")" "2" "list"
sandbox; run "$S/jira-mine.sh" --mcp-args >/dev/null; search_call "$(search_resp false 0)"
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "[]" "empty list"
assert_contains "$ERR" "an unknown status or sprint name is not reported" "zero-result warning names the MCP blind spot"

t "--from-mcp: no capture, an expired request, another selection, a stale or foreign capture are all refused (exit 1)"
sandbox; run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "no request"
run "$S/jira-mine.sh" --mcp-args >/dev/null; run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "request, no capture"; assert_contains "$ERR" "no valid capture" "message"
search_call "$(search_resp false 1)"; run "$S/jira-mine.sh" --from-mcp --key PROJ-1; assert_eq "$CODE" "1" "another selection"; assert_contains "$ERR" "different selection" "message"
assert_file plans/.mcp/search/request.json
jq '.expires_epoch = (now | floor) - 5' plans/.mcp/search/request.json > "$SB/r" && mv "$SB/r" plans/.mcp/search/request.json
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "expired"; assert_contains "$ERR" "has expired" "message"
sandbox; run "$S/jira-mine.sh" --mcp-args >/dev/null; search_call "$(search_resp false 1)"
cap="$(ls plans/.mcp/search/cap-*.json)"
jq '.nonce = "ffffffffffffffffffffffff"' "$cap" > "$SB/c" && mv "$SB/c" "$cap"
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "another request's nonce"
jq '.nonce = "'"$(jq -r .nonce plans/.mcp/search/request.json)"'" | .captured_epoch -= 60' "$cap" > "$SB/c" && mv "$SB/c" "$cap"
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "a capture older than the request"
jq '.captured_epoch += 60 | .tool_name = "mcp__other__searchJiraIssuesUsingJql"' "$cap" > "$SB/c" && mv "$SB/c" "$cap"
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "another server's capture"
sandbox; run "$S/jira-mine.sh" --mcp-args >/dev/null; mkdir -p "$SB/elsewhere"; rm -rf plans/.mcp/search; ln -s "$SB/elsewhere" plans/.mcp/search
run "$S/jira-mine.sh" --from-mcp; assert_eq "$CODE" "1" "a symlinked search directory"
run "$S/jira-mine.sh" --mcp-args; assert_eq "$CODE" "1" "a symlinked search directory is refused when opening"

finish
