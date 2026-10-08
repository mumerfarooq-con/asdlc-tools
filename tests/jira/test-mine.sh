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
assert_eq "$(jq -r '.[1].priority + "|" + .[1].description' <<<"$OUT")" "None|" "nulls"
assert_eq "$(jq -c 'map(keys)|.[0]' <<<"$OUT")" '["description","key","labels","priority","status","summary","type","url"]'

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

finish
