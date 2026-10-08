#!/usr/bin/env bash
# plan-state.sh: header block, hash binding, states, legacy markers.
. "$(dirname "$0")/helpers.sh"
PS="$S/plan-state.sh"

body() { printf '# PROJ-1: plan\n\n## Changes\n1. do it\n'; }
bodyhash() { body | shasum -a 256 | awk '{print $1}'; }

t "stamp writes the header over the body hash"
sandbox; mkdir plans; body > plans/PROJ-1.plan.md
run "$PS" stamp plans/PROJ-1.plan.md
assert_eq "$CODE" "0" "exit"
assert_eq "$(head -n1 plans/PROJ-1.plan.md)" "<!-- asdlc" "marker"
assert_eq "$("$PS" get plans/PROJ-1.plan.md ticket)" "PROJ-1" "ticket from filename"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "pending"
assert_eq "$("$PS" get plans/PROJ-1.plan.md plan_hash)" "sha256:$(bodyhash)"
assert_eq "$(sed '1,/^-->$/d' plans/PROJ-1.plan.md)" "$(body)" "body untouched"

t "pending -> PENDING (10); approved -> RUNNABLE (0)"
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "PENDING/10"
"$PS" set plans/PROJ-1.plan.md status approved >/dev/null
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "RUNNABLE/0"

t "set branch/pr keeps the hash valid and bumps updated"
"$PS" set plans/PROJ-1.plan.md branch feature/PROJ-1-x >/dev/null
"$PS" set plans/PROJ-1.plan.md pr https://example.org/pr/1 >/dev/null
assert_eq "$("$PS" get plans/PROJ-1.plan.md branch)" "feature/PROJ-1-x"
assert_eq "$("$PS" get plans/PROJ-1.plan.md pr)" "https://example.org/pr/1"
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT" "RUNNABLE"

t "editing the body after approval -> STALE (11)"
echo "2. sneak in" >> plans/PROJ-1.plan.md
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "STALE/11"
assert_contains "$ERR" "plan body changed"

t "re-stamp resets to pending over the edited body"
"$PS" stamp plans/PROJ-1.plan.md PROJ-1 >/dev/null
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT" "PENDING"

t "other statuses"
for pair in executing/EXECUTING/12 done/DONE/13 failed/FAILED/14 skip/SKIP/15 rejected/SKIP/15 weird/PENDING/10; do
  "$PS" set plans/PROJ-1.plan.md status "${pair%%/*}" >/dev/null
  run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "${pair#*/}" "status ${pair%%/*}"
done

t "missing file or no header -> MISSING (16)"
run "$PS" check plans/nope.plan.md; assert_eq "$OUT/$CODE" "MISSING/16"
body > plans/PROJ-2.plan.md
run "$PS" check plans/PROJ-2.plan.md; assert_eq "$OUT/$CODE" "MISSING/16"
run "$PS" set plans/PROJ-2.plan.md status approved
assert_eq "$CODE" "16" "set without header"
assert_eq "$(cat plans/PROJ-2.plan.md)" "$(body)" "file untouched"

t "set rejects other fields"
run "$PS" set plans/PROJ-1.plan.md plan_hash sha256:0; assert_eq "$CODE" "2"

t "legacy markers from in-repo versions still check and set"
for marker in '<!-- jira-run:approval' '<!-- jira_ticket_templates-run:approval'; do
  { echo "$marker"; echo "ticket: PROJ-9"; echo "status: approved"
    echo "plan_hash: sha256:$(bodyhash)"; echo "branch:"; echo "pr:"
    echo "updated: 2026-01-01T00:00:00Z"; echo "-->"; body; } > plans/PROJ-9.plan.md
  run "$PS" check plans/PROJ-9.plan.md; assert_eq "$OUT" "RUNNABLE" "$marker check"
  "$PS" set plans/PROJ-9.plan.md status executing >/dev/null
  assert_eq "$("$PS" get plans/PROJ-9.plan.md status)" "executing" "$marker set"
  assert_eq "$(head -n1 plans/PROJ-9.plan.md)" "$marker" "$marker kept by set"
  "$PS" stamp plans/PROJ-9.plan.md >/dev/null
  assert_eq "$(head -n1 plans/PROJ-9.plan.md)" "<!-- asdlc" "$marker upgraded by stamp"
  assert_eq "$("$PS" get plans/PROJ-9.plan.md plan_hash)" "sha256:$(bodyhash)" "$marker same hash"
done

finish
