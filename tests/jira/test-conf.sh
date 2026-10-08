#!/usr/bin/env bash
# Config loading: parse rules, allowlist, defaults, lookup order.
. "$(dirname "$0")/helpers.sh"

t "parse: quotes, comments, CRLF, spaces, '=' and '#' inside values"
sandbox
printf '%s\r\n' '# a comment' '' '  JIRA_PROJECT_NAME = "Widget Works"  ' \
  "STATUS_DEFAULT='To Do, Idea'" 'REVIEW_COUNCIL_PATHS=(a=b|#c)' >> .asdlc/jira.conf
run "$S/jira-conf.sh" JIRA_PROJECT_NAME;    assert_eq "$OUT" "Widget Works"
run "$S/jira-conf.sh" STATUS_DEFAULT;       assert_eq "$OUT" "To Do, Idea"
run "$S/jira-conf.sh" REVIEW_COUNCIL_PATHS; assert_eq "$OUT" "(a=b|#c)"
assert_eq "$ERR" "" "stderr"

t "allowlist: unknown keys and shell variables are ignored with a warning"
sandbox 'PATH=/nowhere' 'IFS=x' 'STATUS_TESTNG=QA' 'not a pair'
run "$S/jira-conf.sh" STATUS_TESTING
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "Testing" "default kept"
assert_contains "$ERR" "unknown key 'PATH' ignored"
assert_contains "$ERR" "unknown key 'STATUS_TESTNG' ignored"
assert_contains "$ERR" "no '=', line ignored"

t "values never execute"
sandbox 'JIRA_PROJECT_NAME=$(touch pwned)' 'BB_REPO=`touch pwned2`'
run "$S/jira-conf.sh" JIRA_PROJECT_NAME
assert_eq "$OUT" '$(touch pwned)'
[ ! -e pwned ] && [ ! -e pwned2 ] && ok || nok "a config value was executed"

t "defaults fill keys the config leaves out"
sandbox
run "$S/jira-conf.sh"
assert_contains "$OUT" "STATUS_IN_PROGRESS=In Progress"
assert_contains "$OUT" "PIPELINE_COMMENT_MARKER=[asdlc]"
assert_contains "$OUT" "REVIEW_COUNCIL_FILES=10"
assert_contains "$OUT" "TICKET_CHECK_MODE=warn"
assert_contains "$OUT" "# config: $SB/.asdlc/jira.conf"

t "trailing slash on the site URL is dropped"
sandbox 'JIRA_BASE_URL=https://example.atlassian.net/'
run "$S/jira-conf.sh" JIRA_BASE_URL; assert_eq "$OUT" "https://example.atlassian.net"

t "found from a subdirectory via the git root"
sandbox 'JIRA_PROJECT_NAME=Root'
mkdir -p a/b && cd a/b
run "$S/jira-conf.sh" JIRA_PROJECT_NAME; assert_eq "$OUT" "Root"

t "--conf and ASDLC_JIRA_CONF override the lookup"
sandbox
printf 'JIRA_PROJECT_NAME=Other\n' > other.conf
run "$S/jira-conf.sh" --conf other.conf JIRA_PROJECT_NAME; assert_eq "$OUT" "Other" "--conf"
ASDLC_JIRA_CONF=other.conf run "$S/jira-conf.sh" JIRA_PROJECT_NAME; assert_eq "$OUT" "Other" "env"

t "missing config points at /asdlc:jira-setup"
sandbox; rm .asdlc/jira.conf
run "$S/jira-conf.sh"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "/asdlc:jira-setup"

t "unknown key lookup fails"
sandbox
run "$S/jira-conf.sh" JIRA_TOKEN
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "unknown key: JIRA_TOKEN"

t "Jira scripts need token env vars outside fixture mode"
sandbox
run "$S/jira-mine.sh"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "JIRA_EMAIL"

t "missing fixtures directory is an error"
sandbox
run "$S/jira-mine.sh" --fixtures "$SB/nope"
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "fixtures directory not found"

finish
