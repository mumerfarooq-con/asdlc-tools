#!/usr/bin/env bash
# Scripts that write to Jira/Bitbucket: transition, notify, open PR, PR comment.
# Writes are captured in the fixture request log, never sent.
. "$(dirname "$0")/helpers.sh"

posts() { requests | jq -c '[.[] | select(.method == "POST")]'; }

t "transition by target status name"
sandbox; use_fixtures basic
run "$S/jira-transition.sh" PROJ-1 "In Progress"
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" 'Moved PROJ-1 to "In Progress"'
assert_eq "$(posts | jq -c '.[0] | [.path, .body]')" '["/rest/api/3/issue/PROJ-1/transitions",{"transition":{"id":"21"}}]'

t "transition by name, and by :alias from the config"
sandbox 'STATUS_TESTING=QA'; use_fixtures basic
run "$S/jira-transition.sh" PROJ-1 "Back to backlog"
assert_eq "$(posts | jq -r '.[0].body.transition.id')" "11" "by transition name"
: > "$ASDLC_FIXTURE_LOG"
run "$S/jira-transition.sh" PROJ-1 :testing
assert_eq "$OUT" 'Moved PROJ-1 to "QA"'; assert_eq "$(posts | jq -r '.[0].body.transition.id')" "31"
: > "$ASDLC_FIXTURE_LOG"
run "$S/jira-transition.sh" PROJ-1 :in-progress
assert_eq "$(posts | jq -r '.[0].body.transition.id')" "21" ":in-progress default"

t "unavailable transition lists the options and posts nothing"
: > "$ASDLC_FIXTURE_LOG"
run "$S/jira-transition.sh" PROJ-1 Done
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "Start work  ->  In Progress"
assert_eq "$(posts)" "[]" "no POST"
run "$S/jira-transition.sh" PROJ-1 :bogus
assert_eq "$CODE" "1" "alias exit"; assert_contains "$ERR" "unknown status alias"

t "transition is a no-op when the ticket is already in the target status"
sandbox; use_fixtures basic
jq '.fields.status.name = "In Progress"' fx/jira/rest/api/3/issue/PROJ-1.json > fx/t && mv fx/t fx/jira/rest/api/3/issue/PROJ-1.json
run "$S/jira-transition.sh" PROJ-1 :in-progress
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" 'PROJ-1 is already in "In Progress"'
assert_eq "$(posts)" "[]" "no POST"
assert_eq "$(requests | jq -r '[.[] | select(.path | endswith("/transitions"))] | length')" "0" "transitions not even listed"
run "$S/jira-transition.sh" PROJ-1 "in PROGRESS"
assert_eq "$CODE" "0" "case-insensitive exit"; assert_contains "$OUT" "already in"
assert_eq "$(posts)" "[]" "case-insensitive: no POST"
run "$S/jira-transition.sh" PROJ-1 "QA"
assert_eq "$(posts | jq -r '.[0].body.transition.id')" "31" "a different target still transitions"

t "notify: watchers + one ADF mention comment"
sandbox 'NOTIFY_ACCOUNT_IDS= acc-1 , acc-2 ,'; use_fixtures basic
run "$S/jira-notify.sh" PROJ-1 "Ready."
assert_eq "$CODE" "0" "exit"
assert_eq "$(posts | jq -c '[.[] | select(.path | endswith("/watchers")) | .body]')" '["acc-1","acc-2"]'
comment="$(posts | jq -c '[.[] | select(.path == "/rest/api/3/issue/PROJ-1/comment")]')"
assert_eq "$(jq 'length' <<<"$comment")" "1" "one comment"
assert_eq "$(jq -c '.[0].body.body.content[0].content' <<<"$comment")" \
  '[{"type":"text","text":"[asdlc] Ready. "},{"type":"mention","attrs":{"id":"acc-1"}},{"type":"mention","attrs":{"id":"acc-2"}}]'

t "notify: the comment text starts with the marker, and an empty or multi-line marker is refused before any call"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1' 'PIPELINE_COMMENT_MARKER=[bot]'; use_fixtures basic
run "$S/jira-notify.sh" PROJ-1 "Ready."
assert_eq "$(posts | jq -r '[.[] | select(.path | endswith("/comment"))][0].body.body.content[0].content[0].text')" "[bot] Ready. " "custom marker"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1' 'PIPELINE_COMMENT_MARKER='; use_fixtures basic
run "$S/jira-notify.sh" PROJ-1 "Ready."
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "PIPELINE_COMMENT_MARKER" "reason"; assert_eq "$(requests)" "[]" "no request"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1'; use_fixtures basic
PIPELINE_COMMENT_MARKER=$'a\nb' run bash -c '. "$1/lib.sh"; ASDLC_CONF_FILE=x; asdlc_need_marker' _ "$S"
assert_eq "$CODE" "1" "multi-line marker refused"
PIPELINE_COMMENT_MARKER='  '$'\t' run bash -c '. "$1/lib.sh"; ASDLC_CONF_FILE=x; asdlc_need_marker' _ "$S"
assert_eq "$CODE" "1" "whitespace-only marker refused"; assert_contains "$ERR" "whitespace" "reason"
PIPELINE_COMMENT_MARKER='[a]' run bash -c '. "$1/lib.sh"; ASDLC_CONF_FILE=x; asdlc_need_marker' _ "$S"
assert_eq "$CODE" "0" "a normal marker passes"

t "notify without people configured fails before any call"
sandbox; use_fixtures basic
run "$S/jira-notify.sh" PROJ-1
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "NOTIFY_ACCOUNT_IDS"; assert_eq "$(posts)" "[]"

t "open PR into TARGET_BRANCH; prints id and url"
sandbox; use_fixtures basic
run "$S/bb-open-pr.sh" feature/PROJ-1-x "PROJ-1 Fix badge"
assert_eq "$OUT" "7 https://bitbucket.org/acme/widgets/pull-requests/7"
assert_eq "$(posts | jq -c '.[0] | [.svc, .path, .body.destination.branch.name, .body.source.branch.name, .body.close_source_branch]')" \
  '["bb","/repositories/acme/widgets/pullrequests","main","feature/PROJ-1-x",true]'
: > "$ASDLC_FIXTURE_LOG"
run "$S/bb-open-pr.sh" feature/PROJ-1-x "t" release
assert_eq "$(posts | jq -r '.[0].body.destination.branch.name')" "release" "explicit dest"

t "PR comment from an argument or stdin"
: > "$ASDLC_FIXTURE_LOG"
run "$S/bb-pr-comment.sh" 7 "LGTM"
assert_eq "$OUT" "Posted comment to PR 7"
assert_eq "$(posts | jq -c '.[0] | [.path, .body]')" '["/repositories/acme/widgets/pullrequests/7/comments",{"content":{"raw":"LGTM"}}]'
: > "$ASDLC_FIXTURE_LOG"
printf 'multi\nline' | "$S/bb-pr-comment.sh" 7 >/dev/null
assert_eq "$(posts | jq -r '.[0].body.content.raw')" "$(printf 'multi\nline')" "stdin"

t "failed write exits non-zero with the service's message"
mkdir -p fx/bb/repositories/acme/widgets/pullrequests/7
echo 401 > fx/bb/repositories/acme/widgets/pullrequests/7/comments.POST.code
echo '{"error":{"message":"Token is invalid"}}' > fx/bb/repositories/acme/widgets/pullrequests/7/comments.POST.json
run "$S/bb-pr-comment.sh" 7 "x"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "Bitbucket returned HTTP 401"
assert_contains "$ERR" "Token is invalid"; assert_contains "$ERR" "BB_AUTH=basic"

t "Bitbucket scripts need the workspace and repo"
sandbox 'BB_REPO='; use_fixtures basic
run "$S/bb-open-pr.sh" a b
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "BB_REPO is not set"

# ---- the same writes over the Atlassian MCP: no token, no REST call ----------------------------
# The captures are synthetic: what the hook would have stored for the calls the scripts printed.
export ASDLC_JIRA_MCP_SERVER=fixture_atlassian
unset JIRA_EMAIL JIRA_TOKEN
mkcap() {  # <KEY> <tool> <role> <response json> [nonce override]: a capture under the open request
  jq -n --slurpfile r "plans/$1/.mcp/request.json" --arg tn "mcp__fixture_atlassian__$2" --arg role "$3" --argjson resp "$4" --arg n "${5:-}" '
    {nonce: (if $n == "" then $r[0].nonce else $n end), tool_name: $tn, session_id: "s", captured_epoch: ($r[0].created_epoch + 1),
     role: $role, response: $resp}' > "plans/$1/.mcp/cap-$RANDOM$RANDOM.json"
}
status_resp() { jq -nc --arg k "$1" --arg s "$2" '{issues: {nodes: [{key: $k, fields: {status: {name: $s}}}]}}'; }
TRANSITIONS='{"transitions":[{"id":"11","name":"Back to backlog","to":{"name":"To Do"}},{"id":"21","name":"Start work","to":{"name":"In Progress"}},{"id":"31","name":"Ready for QA","to":{"name":"QA"}}]}'
no_rest() { assert_file "${ASDLC_FIXTURE_LOG:-/nonexistent}"; assert_eq "$(requests)" "[]" "no REST request"; }

t "transition --mcp-args opens a request and prints the two read calls; no network"
sandbox; use_fixtures basic
run "$S/jira-transition.sh" --mcp-args PROJ-1
assert_eq "$CODE" "0" "exit"; assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "2" "two lines"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 1p | jq -c '[.tool, .args.cloudId, .args.issueIdOrKey, .args.fields, .args.responseContentFormat]')" \
  '["mcp__fixture_atlassian__getJiraIssue","example.atlassian.net","PROJ-1",["status"],"markdown"]' "first call"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 2p | jq -c '[.tool, .args]')" \
  '["mcp__fixture_atlassian__getTransitionsForJiraIssue",{"cloudId":"example.atlassian.net","issueIdOrKey":"PROJ-1"}]' "second call"
assert_eq "$(jq -r '.purpose' plans/PROJ-1/.mcp/request.json)" "transition" "request purpose"
no_rest

t "transition --from-mcp: ALREADY when the ticket is in the target status (case-insensitive), request closed"
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'In Progress')"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 "in PROGRESS"
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" 'ALREADY "In Progress"'
assert_eq "$(ls -A plans/PROJ-1 2>/dev/null)" "" "request and captures gone"
no_rest

t "transition --from-mcp: TRANSITION <id> and the transitionJiraIssue args, by name and by :alias"
sandbox 'STATUS_TESTING=QA'; use_fixtures basic
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'To Do')"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 :testing
assert_eq "$CODE" "0" "exit"; assert_eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "TRANSITION 31" "line 1"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 2p)" \
  '{"tool":"mcp__fixture_atlassian__transitionJiraIssue","args":{"cloudId":"example.atlassian.net","issueIdOrKey":"PROJ-1","transition":{"id":"31"}}}' "line 2"
assert_eq "$(ls plans/PROJ-1/.mcp | tr '\n' ' ')" "request.json " "captures used up, request kept for the write"
run "$S/jira-transition.sh" --from-mcp PROJ-1 :testing
assert_eq "$CODE" "1" "a second read without new captures fails"; assert_contains "$ERR" "no valid issue capture" "reason"
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'To Do')"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 "Back to backlog"
assert_eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "TRANSITION 11" "by transition name"
no_rest

t "transition --from-mcp: an unknown target lists the transitions on stderr and exits 1"
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'To Do')"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 Done
assert_eq "$CODE" "1" "exit"; assert_eq "$OUT" "" "nothing on stdout"
assert_contains "$ERR" "No transition to \"Done\"" "message"; assert_contains "$ERR" "Start work  ->  In Progress" "listing"
run "$S/jira-transition.sh" --from-mcp PROJ-1 :bogus
assert_eq "$CODE" "1" "alias exit"; assert_contains "$ERR" "unknown status alias"

t "transition --from-mcp refuses a capture for another ticket, another nonce, a wrong purpose, an expiry, a missing read"
sandbox; use_fixtures basic
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
run "$S/jira-transition.sh" --mcp-args PROJ-2 >/dev/null
# PROJ-2's request and captures dropped into PROJ-1's directory
mkcap PROJ-2 getJiraIssue issue "$(status_resp PROJ-2 'To Do')"
mkcap PROJ-2 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
rm -rf plans/PROJ-1/.mcp; cp -R plans/PROJ-2/.mcp plans/PROJ-1/.mcp
run "$S/jira-transition.sh" --from-mcp PROJ-1 "In Progress"
assert_eq "$CODE" "1" "a request and captures made for another key"; assert_contains "$ERR" "unreadable" "reason"
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-9 'To Do')"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 "In Progress"
assert_eq "$CODE" "1" "an issue capture for another key under the right request"; assert_contains "$ERR" "no valid issue capture"
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'To Do')" aaaaaaaaaaaaaaaa
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 "In Progress"
assert_eq "$CODE" "1" "another nonce"
run "$S/jira-transition.sh" --mcp-args PROJ-1 >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'To Do')"
run "$S/jira-transition.sh" --from-mcp PROJ-1 "In Progress"
assert_eq "$CODE" "1" "the transitions read is missing"; assert_contains "$ERR" "no valid getTransitionsForJiraIssue capture"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
jq '.expires_epoch = (now | floor) - 1' plans/PROJ-1/.mcp/request.json > r.tmp && mv r.tmp plans/PROJ-1/.mcp/request.json
run "$S/jira-transition.sh" --from-mcp PROJ-1 "In Progress"
assert_eq "$CODE" "1" "expired"; assert_contains "$ERR" "expired"
run "$S/jira-context.sh" mcp-request PROJ-1 --for comment >/dev/null
mkcap PROJ-1 getJiraIssue issue "$(status_resp PROJ-1 'To Do')"
mkcap PROJ-1 getTransitionsForJiraIssue getTransitionsForJiraIssue "$TRANSITIONS"
run "$S/jira-transition.sh" --from-mcp PROJ-1 "In Progress"
assert_eq "$CODE" "1" "a comment request"; assert_contains "$ERR" "is for comment, not transition"
run "$S/jira-transition.sh" --from-mcp PROJ-1; assert_eq "$CODE" "1" "no target"
run "$S/jira-transition.sh" --mcp-args '../x'; assert_eq "$CODE" "1" "bad key"; assert_contains "$ERR" "not a Jira key"
no_rest

t "transition: the REST form still works with no MCP at all (the fallback)"
sandbox; use_fixtures basic
run "$S/jira-transition.sh" PROJ-1 "In Progress"
assert_eq "$OUT" 'Moved PROJ-1 to "In Progress"'

t "notify --adf: the ADF body starts with the marker, then the mentions; no network, a comment request is opened"
sandbox 'NOTIFY_ACCOUNT_IDS= acc-1 , acc-2 ,'; use_fixtures basic
run "$S/jira-notify.sh" --adf PROJ-1 "Ready."
assert_eq "$CODE" "0" "exit"
assert_eq "$(jq -c '.content[0].content' <<<"$OUT")" \
  '[{"type":"text","text":"[asdlc] Ready. "},{"type":"mention","attrs":{"id":"acc-1"}},{"type":"mention","attrs":{"id":"acc-2"}}]' "content"
assert_eq "$(jq -r '[.type, .version] | join(" ")' <<<"$OUT")" "doc 1" "a doc"
assert_eq "$(jq -r '.content[0].content[0].text | startswith("[asdlc] ")' <<<"$OUT")" "true" "starts with the marker and a space"
assert_contains "$ERR" "mcp__fixture_atlassian__addCommentToJiraIssue" "stderr names the tool"
assert_contains "$ERR" '"cloudId":"example.atlassian.net"' "stderr names the cloudId"
assert_eq "$(jq -r '.purpose' plans/PROJ-1/.mcp/request.json)" "comment" "request"
no_rest
run "$S/jira-notify.sh" --adf PROJ-1
assert_contains "$(jq -r '.content[0].content[0].text' <<<"$OUT")" "Moved to Testing" "default note"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1' 'PIPELINE_COMMENT_MARKER=[bot]'; use_fixtures basic
run "$S/jira-notify.sh" --adf PROJ-1 "Hi"
assert_eq "$(jq -r '.content[0].content[0].text' <<<"$OUT")" "[bot] Hi " "custom marker"

t "notify --adf: an empty or blank marker is refused before any output or request"
for m in '' '  '; do
  sandbox 'NOTIFY_ACCOUNT_IDS=acc-1' "PIPELINE_COMMENT_MARKER=$m"; use_fixtures basic
  run "$S/jira-notify.sh" --adf PROJ-1 "x"
  assert_eq "$CODE" "1" "exit [$m]"; assert_contains "$ERR" "PIPELINE_COMMENT_MARKER" "reason [$m]"; assert_eq "$OUT" "" "no output [$m]"
  assert_eq "$(ls plans 2>/dev/null)" "" "no request [$m]"
done
sandbox; use_fixtures basic
run "$S/jira-notify.sh" --adf PROJ-1
assert_eq "$CODE" "1" "no people"; assert_contains "$ERR" "NOTIFY_ACCOUNT_IDS"; assert_eq "$OUT" "" "no output"; assert_eq "$(ls plans 2>/dev/null)" "" "no request"

t "notify --from-mcp prints the recorded comment id; --watchers is REST when a login is ready, else skipped"
sandbox 'NOTIFY_ACCOUNT_IDS=acc-1'; use_fixtures basic
run "$S/jira-notify.sh" --from-mcp PROJ-1
assert_eq "$CODE" "1" "no request"; assert_contains "$ERR" "check the ticket before posting again"
run "$S/jira-notify.sh" --adf PROJ-1 "x" >/dev/null 2>&1
mkcap PROJ-1 addCommentToJiraIssue addCommentToJiraIssue '{"id":"10042"}'
run "$S/jira-notify.sh" --from-mcp PROJ-1
assert_eq "$CODE/$OUT" "0/COMMENT 10042" "id"
assert_eq "$(ls -A plans/PROJ-1 2>/dev/null)" "" "closed"
run env -u ASDLC_FIXTURES "$S/jira-notify.sh" --watchers PROJ-1
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "watchers skipped" "no login: skipped"
assert_eq "$(posts)" "[]" "no POST"
run env ASDLC_FIXTURES="$SB/fx" "$S/jira-notify.sh" --watchers PROJ-1
assert_contains "$OUT" "Watchers added" "login ready"
assert_eq "$(posts | jq -c '[.[] | select(.path | endswith("/watchers")) | .body]')" '["acc-1"]' "watchers over REST"
assert_eq "$(posts | jq -c '[.[] | select(.path | endswith("/comment"))]')" "[]" "no comment over REST"


finish
