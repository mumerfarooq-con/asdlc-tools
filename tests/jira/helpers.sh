# shellcheck shell=bash
# Shared setup + assertions for the Jira-leg script tests. Sourced by test-*.sh.
# Tests run offline: every Jira/Bitbucket call is served from fixture JSON.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$ROOT/plugins/asdlc/jira/scripts"
FIXTURES="$ROOT/tests/jira/fixtures"

# Tests must never depend on (or leak) a developer's real Jira setup.
unset JIRA_EMAIL JIRA_TOKEN BITBUCKET_TOKEN BITBUCKET_EMAIL JIRA_URL JIRA_PROJECT \
      JIRA_TODO_STATUS JIRA_TESTING_STATUS JIRA_NOTIFY_ACCOUNTIDS JIRA_BOARD_ID \
      BITBUCKET_WORKSPACE BITBUCKET_REPO BITBUCKET_DEST_BRANCH \
      REVIEW_COUNCIL_FILES REVIEW_COUNCIL_LINES REVIEW_COUNCIL_PATHS \
      ASDLC_JIRA_CONF ASDLC_FIXTURES ASDLC_FIXTURE_LOG ASDLC_JIRA_ALLOWED_HOSTS \
      FAKECURL_LOG FAKECURL_BODY FAKECURL_CODE FAKECURL_EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

PASS=0; FAIL=0; CURRENT=""
SANDBOXES=()
cleanup() { local d; for d in ${SANDBOXES[@]+"${SANDBOXES[@]}"}; do rm -rf "$d"; done; }
trap cleanup EXIT

t()   { CURRENT="$1"; }
ok()  { PASS=$((PASS + 1)); }
nok() { FAIL=$((FAIL + 1)); echo "  FAIL [$CURRENT] $*"; }

assert_eq() {        # <actual> <expected> [what]
  if [ "$1" = "$2" ]; then ok; else nok "${3:-value}: expected [$2], got [$1]"; fi
}
assert_contains() {  # <haystack> <needle> [what]
  case "$1" in *"$2"*) ok ;; *) nok "${3:-output} lacks [$2]: $1" ;; esac
}
assert_not_contains() {
  case "$1" in *"$2"*) nok "${3:-output} has unexpected [$2]: $1" ;; *) ok ;; esac
}
assert_file() { if [ -f "$1" ]; then ok; else nok "missing file $1"; fi; }

# A fresh git repo with a test config at .asdlc/jira.conf; cd's into it.
# Extra KEY=value lines in $@ are appended to the config.
sandbox() {
  unset ASDLC_FIXTURES ASDLC_FIXTURE_LOG
  SB="$(cd "$(mktemp -d)" && pwd -P)"; SANDBOXES+=("$SB")
  cd "$SB" || exit 1
  git init -q -b main . 2>/dev/null || { git init -q .; git checkout -q -b main; }
  mkdir -p .asdlc
  {
    echo "JIRA_BASE_URL=https://example.atlassian.net"
    echo "JIRA_PROJECT_KEY=PROJ"
    echo "BB_WORKSPACE=acme"
    echo "BB_REPO=widgets"
    echo "TARGET_BRANCH=main"
    local line; for line in "$@"; do echo "$line"; done
  } > .asdlc/jira.conf
}

# Copy a fixture set into the sandbox so a test can add or change responses,
# and point the scripts at it with a fresh request log.
use_fixtures() {  # <set name>
  rm -rf "$SB/fx"; cp -R "$FIXTURES/$1" "$SB/fx"
  export ASDLC_FIXTURES="$SB/fx" ASDLC_FIXTURE_LOG="$SB/requests.log"
  : > "$ASDLC_FIXTURE_LOG"
}

# The requests log as a JSON array.
requests() { jq -s '.' "$ASDLC_FIXTURE_LOG"; }

# Run a command, capturing stdout, stderr and exit code into OUT, ERR, CODE.
run() {
  local o e; o="$(mktemp)"; e="$(mktemp)"
  "$@" >"$o" 2>"$e"; CODE=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"; rm -f "$o" "$e"
}

finish() {
  echo "$(basename "$0"): $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
