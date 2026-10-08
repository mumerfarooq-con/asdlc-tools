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

t "notify: watchers + one ADF mention comment"
sandbox 'NOTIFY_ACCOUNT_IDS= acc-1 , acc-2 ,'; use_fixtures basic
run "$S/jira-notify.sh" PROJ-1 "Ready."
assert_eq "$CODE" "0" "exit"
assert_eq "$(posts | jq -c '[.[] | select(.path | endswith("/watchers")) | .body]')" '["acc-1","acc-2"]'
comment="$(posts | jq -c '[.[] | select(.path == "/rest/api/3/issue/PROJ-1/comment")]')"
assert_eq "$(jq 'length' <<<"$comment")" "1" "one comment"
assert_eq "$(jq -c '.[0].body.body.content[0].content' <<<"$comment")" \
  '[{"type":"text","text":"Ready. "},{"type":"mention","attrs":{"id":"acc-1"}},{"type":"mention","attrs":{"id":"acc-2"}}]'

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

finish
