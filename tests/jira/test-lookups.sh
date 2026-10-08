#!/usr/bin/env bash
# Read-only helpers: jira-sprints.sh, jira-people.sh.
. "$(dirname "$0")/helpers.sh"

t "sprints: first board, with a note when there are several"
sandbox; use_fixtures basic
run "$S/jira-sprints.sh"
assert_eq "$CODE" "0" "exit"
assert_contains "$OUT" "42"; assert_contains "$OUT" "Sprint 7"
assert_contains "$ERR" "Project has 2 boards; using 5"
assert_eq "$(requests | jq -r '.[0].args[1]')" "projectKeyOrId=PROJ" "project key sent"

t "sprints: JIRA_BOARD_ID from the config skips the board lookup"
sandbox 'JIRA_BOARD_ID=9'; use_fixtures basic
run "$S/jira-sprints.sh"
assert_contains "$OUT" "Kanban 1"; assert_eq "$(requests | jq -r '.[0].path')" "/rest/agile/1.0/board/9/sprint"

t "people: active humans only, sorted by name, ids joined for the config"
sandbox; use_fixtures basic
run "$S/jira-people.sh"
assert_eq "$CODE" "0" "exit"
assert_not_contains "$OUT" "Automation" "app users"; assert_not_contains "$OUT" "Old Hand" "inactive users"
assert_eq "$(tail -n1 <<<"$OUT")" "acc-1,acc-2" "joined ids"
assert_contains "$OUT" "NOTIFY_ACCOUNT_IDS"
assert_eq "$(requests | jq -r '.[0].args[1]')" "project=PROJ" "project KEY, not name"

t "people: 403 explains the permission"
use_fixtures basic; echo 403 > fx/jira/rest/api/3/user/assignable/search.code
run "$S/jira-people.sh" PROJ
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "Browse users and groups"

finish
