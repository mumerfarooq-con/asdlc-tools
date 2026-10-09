#!/usr/bin/env bash
# review-mode.sh: council vs solo from the real diff, thresholds from the config.
. "$(dirname "$0")/helpers.sh"

# Sandbox repo with one commit on main and a feature branch checked out.
repo() {
  sandbox "$@"
  echo base > README; git add -A; git commit -qm base; git checkout -qb feature
}
commit_file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-x}" > "$1"; git add -A; git commit -qm "$1"; }

t "small change -> solo, with the reason"
repo; commit_file app/views.py
run "$S/review-mode.sh"
assert_eq "$OUT" "solo"; assert_contains "$ERR" "review-mode: solo — 1 files / 1 lines"

t "sensitive path -> council"
repo; commit_file app/migrations/0002_add.py
run "$S/review-mode.sh" main; assert_eq "$OUT" "council"
assert_contains "$ERR" "sensitive paths: app/migrations/0002_add.py"

t "file and line thresholds come from the config"
repo 'REVIEW_COUNCIL_FILES=2'; commit_file a.py; commit_file b.py
run "$S/review-mode.sh"; assert_eq "$OUT" "council"; assert_contains "$ERR" "2 files changed (>= 2)"
repo 'REVIEW_COUNCIL_LINES=3'; commit_file a.py "$(printf '1\n2\n3')"
run "$S/review-mode.sh"; assert_eq "$OUT" "council"; assert_contains "$ERR" "3 lines changed (>= 3)"
repo 'REVIEW_COUNCIL_PATHS=(views)'; commit_file app/views.py
run "$S/review-mode.sh"; assert_eq "$OUT" "council" "custom path regex"

t "issue type and labels"
repo; commit_file a.py
run "$S/review-mode.sh" main HEAD Story;            assert_eq "$OUT" "council" "Story"
run "$S/review-mode.sh" main HEAD Bug "ui, large";  assert_eq "$OUT" "council" "large label"
run "$S/review-mode.sh" main HEAD Bug "ui,larger";  assert_eq "$OUT" "solo" "label must match whole"

t "base branch: argument works without a config; neither is an error"
repo; commit_file a.py; rm .asdlc/jira.conf
run "$S/review-mode.sh" main; assert_eq "$OUT/$CODE" "solo/0"
run "$S/review-mode.sh"; assert_eq "$CODE" "1" "no base"; assert_contains "$ERR" "TARGET_BRANCH"

t "option-like refs are refused (exit 2), never reach git as options"
repo; commit_file a.py
echo "TARGET_BRANCH=--output=$SB/pwned" >> .asdlc/jira.conf
run "$S/review-mode.sh"
assert_eq "$CODE" "2" "TARGET_BRANCH=--output=..."; assert_eq "$OUT" "" "nothing on stdout"
assert_contains "$ERR" "invalid base ref"
assert_eq "$([ -e "$SB/pwned" ] && echo created || echo absent)" "absent" "no file written"
run "$S/review-mode.sh" "--output=$SB/pwned2"
assert_eq "$CODE" "2" "base arg"; assert_eq "$([ -e "$SB/pwned2" ] && echo created || echo absent)" "absent"
run "$S/review-mode.sh" main "--output=$SB/pwned3"
assert_eq "$CODE" "2" "head arg"; assert_eq "$OUT" ""; assert_contains "$ERR" "invalid head ref"
assert_eq "$([ -e "$SB/pwned3" ] && echo created || echo absent)" "absent"
run "$S/review-mode.sh" "bad..name"
assert_eq "$CODE/$OUT" "2/" "bad ref syntax"; assert_contains "$ERR" "not a valid branch name"

t "fail closed: an unresolvable ref or a missing merge base is council, with the reason"
repo; commit_file db/migrations/0001.sql
run "$S/review-mode.sh" mian
assert_eq "$CODE/$OUT" "0/council" "typo in base"; assert_contains "$ERR" "review-mode: council — base 'mian' not found"
run "$S/review-mode.sh" main no-such-head
assert_eq "$CODE/$OUT" "0/council" "head"; assert_contains "$ERR" "review-mode: council — head 'no-such-head' not found"
repo 'TARGET_BRANCH=origin/main'; commit_file a.py   # remote never fetched
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "unfetched origin/main"; assert_contains "$ERR" "base 'origin/main' not found"
repo; commit_file a.py; git checkout -q --orphan unrelated; commit_file b.py; git checkout -q feature
run "$S/review-mode.sh" main unrelated
assert_eq "$CODE/$OUT" "0/council" "no common ancestor"; assert_contains "$ERR" "no merge base"

t "fail closed: a failing git diff is council, never solo"
repo; commit_file a.py
mkdir "$SB/shim"; REAL_GIT="$(command -v git)"
printf '#!/bin/sh\n[ "$1" = diff ] && exit 1\nexec "%s" "$@"\n' "$REAL_GIT" > "$SB/shim/git"; chmod +x "$SB/shim/git"
run env PATH="$SB/shim:$PATH" "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "diff fails"; assert_contains "$ERR" "git diff failed"

t "fail closed: a bad regex or threshold is council, with the reason"
repo 'REVIEW_COUNCIL_PATHS=('; commit_file a.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "invalid regex"; assert_contains "$ERR" "REVIEW_COUNCIL_PATHS is not a valid regex"
repo 'REVIEW_COUNCIL_FILES=abc'; commit_file a.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "FILES=abc"; assert_contains "$ERR" "REVIEW_COUNCIL_FILES 'abc' is not a positive integer"
repo 'REVIEW_COUNCIL_LINES=1.5'; commit_file a.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "LINES=1.5"; assert_contains "$ERR" "REVIEW_COUNCIL_LINES '1.5' is not a positive integer"
repo 'REVIEW_COUNCIL_FILES=0'; commit_file a.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "FILES=0"; assert_contains "$ERR" "positive integer"
repo 'REVIEW_COUNCIL_LINES='; commit_file a.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "empty LINES"; assert_contains "$ERR" "positive integer"
repo 'REVIEW_COUNCIL_LINES=99999999999999999999'; commit_file a.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/council" "LINES overflow"; assert_contains "$ERR" "positive integer"

t "empty REVIEW_COUNCIL_PATHS means no path rule"
repo 'REVIEW_COUNCIL_PATHS='; commit_file app/views.py
run "$S/review-mode.sh"
assert_eq "$CODE/$OUT" "0/solo" "small change"; assert_contains "$ERR" "review-mode: solo — 1 files / 1 lines"
repo 'REVIEW_COUNCIL_PATHS=' 'REVIEW_COUNCIL_FILES=2'; commit_file a.py; commit_file b.py
run "$S/review-mode.sh"; assert_eq "$OUT" "council" "thresholds still apply"

t "a change under .asdlc/ is council by default"
repo; commit_file .asdlc/jira.conf 'TARGET_BRANCH=main'
run "$S/review-mode.sh"; assert_eq "$OUT" "council"; assert_contains "$ERR" "sensitive paths: .asdlc/jira.conf"
repo; commit_file plugins/asdlc/readme.md
run "$S/review-mode.sh"; assert_eq "$OUT" "solo" "plugins/asdlc/ is not .asdlc/"

finish
