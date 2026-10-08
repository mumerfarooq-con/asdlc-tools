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

finish
