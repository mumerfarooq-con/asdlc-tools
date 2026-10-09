#!/usr/bin/env bash
# jira-setup.sh: init from template + legacy env, docs templates, checks.
. "$(dirname "$0")/helpers.sh"
SETUP="$S/jira-setup.sh"

t "init pre-fills from the env vars older setups used"
sandbox; rm .asdlc/jira.conf
JIRA_URL=https://legacy.atlassian.net/ JIRA_PROJECT=LEG JIRA_TODO_STATUS="Open, Idea" \
JIRA_TESTING_STATUS=QA JIRA_NOTIFY_ACCOUNTIDS=a,b JIRA_BOARD_ID=12 \
BITBUCKET_WORKSPACE=ws BITBUCKET_REPO=rp BITBUCKET_DEST_BRANCH=trunk REVIEW_COUNCIL_FILES=7 \
  run "$SETUP" init
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "wrote: $SB/.asdlc/jira.conf"
for kv in JIRA_BASE_URL=https://legacy.atlassian.net JIRA_PROJECT_KEY=LEG "STATUS_DEFAULT=Open, Idea" \
          STATUS_TODO=Open STATUS_TESTING=QA NOTIFY_ACCOUNT_IDS=a,b JIRA_BOARD_ID=12 \
          BB_WORKSPACE=ws BB_REPO=rp TARGET_BRANCH=trunk REVIEW_COUNCIL_FILES=7; do
  assert_eq "$("$S/jira-conf.sh" "${kv%%=*}")" "${kv#*=}" "${kv%%=*}"
done
assert_not_contains "$OUT" "still empty"

t "init: a legacy JIRA_PROJECT holding the display name fills the name, not the key"
sandbox; rm .asdlc/jira.conf
JIRA_PROJECT="Widget Works" run "$SETUP" init
assert_eq "$("$S/jira-conf.sh" JIRA_PROJECT_NAME)" "Widget Works" "name"
assert_eq "$("$S/jira-conf.sh" JIRA_PROJECT_KEY)" "" "key"
assert_contains "$OUT" "still empty (fill these in): JIRA_BASE_URL JIRA_PROJECT_KEY"

t "init leaves an existing config alone unless --force"
echo "# mine" >> .asdlc/jira.conf
run "$SETUP" init; assert_contains "$OUT" "exists:"
assert_contains "$(cat .asdlc/jira.conf)" "# mine"
run "$SETUP" init --force; assert_not_contains "$(cat .asdlc/jira.conf)" "# mine" "after --force"

t "init without env names the keys still to fill"
sandbox; rm .asdlc/jira.conf
run "$SETUP" init
assert_contains "$OUT" "still empty (fill these in): JIRA_BASE_URL JIRA_PROJECT_KEY BB_WORKSPACE BB_REPO TARGET_BRANCH"
assert_eq "$("$S/jira-conf.sh" STATUS_IN_PROGRESS)" "In Progress" "template default"

t "the template parses cleanly and covers every config key"
run "$S/jira-conf.sh"
assert_eq "$ERR" "" "no parse warnings"
for k in $(. "$S/lib.sh"; echo $ASDLC_CONF_KEYS); do
  grep -q "^$k=" .asdlc/jira.conf && ok || nok "template lacks $k"
done

t "docs: created once from templates at the configured paths"
sandbox 'KNOWN_TRAPS_PATH=notes/traps.md'
run "$SETUP" docs
assert_file docs/access-rules.md; assert_file notes/traps.md
assert_contains "$(cat notes/traps.md)" "## T-<nnn>"
echo "edited" >> docs/access-rules.md
run "$SETUP" docs; assert_contains "$OUT" "exists: docs/access-rules.md"
assert_contains "$(cat docs/access-rules.md)" "edited"

t "check: all good against fixtures; tokens never printed"
sandbox 'JIRA_PROJECT_NAME=Widgets' 'STATUS_DEFAULT=To Do,Idea'; use_fixtures basic
"$SETUP" docs >/dev/null
JIRA_TOKEN=s3cr3t-value run "$SETUP" check
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "All checks passed."
assert_contains "$OUT" "Jira: signed in as Test User at example.atlassian.net" "destination host"
assert_contains "$OUT" 'status STATUS_DEFAULT: "To Do"'
assert_contains "$OUT" 'status STATUS_DEFAULT: "Idea"'
assert_contains "$OUT" 'status STATUS_NEEDS_INFO: "Needs info"'
assert_contains "$OUT" "Bitbucket: acme/widgets"
assert_contains "$OUT" "Bitbucket branch: main"
assert_not_contains "$OUT$ERR" "s3cr3t-value" "token value"

t "check: missing Needs info is a warning; a missing used status fails"
sandbox 'STATUS_NEEDS_INFO=Waiting' 'STATUS_TESTING=testing'; use_fixtures basic
run "$SETUP" check
assert_contains "$OUT" 'warn  status STATUS_NEEDS_INFO: "Waiting" is not in the PROJ workflow'
assert_contains "$OUT" "a Jira admin must add it"
assert_contains "$OUT" 'FAIL  status STATUS_TESTING: "testing" differs in case'
assert_contains "$OUT" "warn  JIRA_PROJECT_NAME is empty"
assert_eq "$CODE" "1" "exit"

t "check: auth failure and empty required keys"
sandbox; use_fixtures basic; echo 401 > fx/jira/rest/api/2/myself.code
run "$SETUP" check
assert_contains "$OUT" "FAIL  Jira test call (HTTP 401)"; assert_contains "$OUT" "Auth failed"
sandbox 'JIRA_PROJECT_KEY=Widgets'; use_fixtures basic
run "$SETUP" check
assert_contains "$OUT" "FAIL  Jira project Widgets (HTTP 404)"; assert_contains "$OUT" "not its display name"
sandbox 'TARGET_BRANCH=' 'TICKET_CHECK_MODE=loud'; use_fixtures basic
run "$SETUP" check
assert_contains "$OUT" "FAIL  TARGET_BRANCH is empty"; assert_contains "$OUT" "TICKET_CHECK_MODE must be strict or warn"
assert_eq "$CODE" "1" "exit"

t "check: warns (never fails) when plans/ and prds/ are not git-ignored"
sandbox; use_fixtures basic
run "$SETUP" check
assert_eq "$CODE" "0" "exit without .gitignore"
assert_contains "$OUT" "warn  not git-ignored: plans/.jira-run.lock plans/x.plan.md prds/x.md" "warning"
assert_contains "$OUT" "plans/*.plan.md" "suggested pattern"
printf '%s\n' 'plans/.jira-run.lock' 'plans/*.plan.md' 'prds/' > .gitignore
run "$SETUP" check
assert_eq "$CODE" "0" "exit with .gitignore"
assert_not_contains "$OUT" "not git-ignored" "no warning"
printf '%s\n' 'prds/' > .gitignore
run "$SETUP" check
assert_contains "$OUT" "warn  not git-ignored: plans/.jira-run.lock plans/x.plan.md" "partial"
assert_not_contains "$OUT" "prds/x.md" "prds ignored"

t "check: token env vars required outside fixture mode"
sandbox
run "$SETUP" check
assert_contains "$OUT" "FAIL  env JIRA_TOKEN is not set"; assert_eq "$CODE" "1" "exit"

finish
