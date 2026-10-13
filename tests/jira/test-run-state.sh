#!/usr/bin/env bash
# run-state.sh: run lock, crash recovery across plans, feature-branch create/resume.
. "$(dirname "$0")/helpers.sh"
RS="$S/run-state.sh"; PS="$SHARED/plan-state.sh"

# A sandbox repo with one commit on main, pushed to a local bare "origin".
git_sandbox() {
  sandbox "$@"
  echo base > README; git add README; git commit -qm base
  git init -q --bare "$SB/origin.git"; git remote add origin "$SB/origin.git"; git push -q -u origin main
  mkdir -p plans
}
human_status() { sed "1,/^-->/s/^status: .*/status: $2/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
plan() {  # <ID> [status]: a stamped plan, human-set to status (default approved)
  printf '# %s: plan\n\n## Changes\n### Task 1\nDo it.\n' "$1" > "plans/$1.plan.md"
  "$PS" stamp "plans/$1.plan.md" >/dev/null; human_status "plans/$1.plan.md" "${2:-approved}"
}
branch_now() { git symbolic-ref --short -q HEAD; }

# ---- lock --------------------------------------------------------------------------------

t "lock prints a run id; status names the holder; a second lock is refused"
git_sandbox
run "$RS" lock; assert_eq "$CODE" "0" "exit"; ID="$OUT"
assert_contains "$ID" "-" "run id"
run "$RS" status; assert_eq "$CODE" "10" "status exit"
assert_contains "$OUT" "held by run $ID"
run "$RS" lock; assert_eq "$CODE" "10" "second lock"
assert_contains "$ERR" "held by run $ID"; assert_contains "$ERR" "force-unlock" "hint"

t "unlock only releases the run that took the lock"
run "$RS" unlock "someone-else"; assert_eq "$CODE" "2" "wrong id"
assert_contains "$ERR" "refusing"; [ -d plans/.jira-run.lock ] && ok || nok "lock removed by the wrong id"
run "$RS" unlock "$ID"; assert_eq "$CODE/$OUT" "0/unlocked (run $ID)"
[ ! -e plans/.jira-run.lock ] && ok || nok "lock still there"
run "$RS" unlock "$ID"; assert_eq "$CODE/$OUT" "0/not locked" "idempotent"
run "$RS" status; assert_eq "$CODE/$OUT" "0/unlocked"

t "force-unlock clears a crashed run's lock, including one with no owner record"
"$RS" lock >/dev/null
run "$RS" force-unlock; assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "removing a lock held by run"
[ ! -e plans/.jira-run.lock ] && ok || nok "lock still there"
mkdir plans/.jira-run.lock                              # what the older version left behind
run "$RS" status; assert_contains "$OUT" "no owner record"
run "$RS" unlock anything; assert_eq "$CODE" "2" "unlock without an owner record"
run "$RS" force-unlock; assert_eq "$CODE" "0" "force-unlock"; [ ! -e plans/.jira-run.lock ] && ok || nok "legacy lock kept"

# ---- reset-executing across plans ----------------------------------------------------------

t "reset-executing: plans that only logged progress reset; a changed plan is refused"
git_sandbox
plan PROJ-1; "$PS" set plans/PROJ-1.plan.md status executing >/dev/null
printf -- '- Task 1: DONE — a.py\n' >> plans/PROJ-1.plan.md          # progress, below the line
plan PROJ-2; "$PS" set plans/PROJ-2.plan.md status executing >/dev/null
sed 's/^Do it\.$/Do something else./' plans/PROJ-2.plan.md > t && mv t plans/PROJ-2.plan.md   # approved part
plan PROJ-3 pending
run "$RS" reset-executing
assert_eq "$CODE" "11" "exit (one refused)"
assert_contains "$OUT" "reset PROJ-1: executing -> approved"
assert_contains "$OUT" "PROJ-2: its approved part changed"
assert_eq "$("$PS" check plans/PROJ-1.plan.md)" "RUNNABLE" "PROJ-1"
assert_eq "$("$PS" get plans/PROJ-2.plan.md status)" "executing" "PROJ-2 untouched"
assert_eq "$("$PS" get plans/PROJ-3.plan.md status)" "pending" "PROJ-3 untouched"
human_status plans/PROJ-2.plan.md failed
run "$RS" reset-executing; assert_eq "$CODE/$OUT" "0/no plan is executing" "nothing left"

t "list shows each plan's id, state, branch and pr"
"$PS" set plans/PROJ-1.plan.md branch feature/PROJ-1-x >/dev/null
run "$RS" list
assert_contains "$OUT" "PROJ-1"; assert_contains "$OUT" "RUNNABLE"; assert_contains "$OUT" "feature/PROJ-1-x"
assert_contains "$OUT" "PROJ-3"; assert_contains "$OUT" "PENDING"

# ---- start-branch ------------------------------------------------------------------------

t "start-branch: a new plan gets feature/<KEY>-<slug> off an up-to-date target branch"
git_sandbox
git clone -q "$SB/origin.git" "$SB/other" && (cd "$SB/other" && git checkout -q main && echo up > upstream.txt \
  && git add upstream.txt && git commit -qm upstream && git push -q origin main)
plan PROJ-1
run "$RS" start-branch plans/PROJ-1.plan.md "Fix the Badge: guests/see 'Visitor'!"
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "feature/PROJ-1-fix-the-badge-guests-see-visitor" "branch"
assert_eq "$(branch_now)" "feature/PROJ-1-fix-the-badge-guests-see-visitor" "checked out"
[ -f upstream.txt ] && ok || nok "target branch was not fast-forwarded first"
assert_eq "$("$PS" get plans/PROJ-1.plan.md branch)" "feature/PROJ-1-fix-the-badge-guests-see-visitor" "recorded in the plan"
assert_eq "$("$PS" check plans/PROJ-1.plan.md)" "RUNNABLE" "still runnable"

t "start-branch: slug is [a-z0-9-] only, at most 40 chars; empty summary -> work"
git checkout -q main; plan PROJ-2
run "$RS" start-branch plans/PROJ-2.plan.md "$(printf 'a%.0s' $(seq 1 60)) --upload-pack=x ../../etc"
slug="${OUT#feature/PROJ-2-}"
assert_eq "$CODE" "0" "exit"; [ "${#slug}" -le 40 ] && ok || nok "slug too long: $slug"
case "$slug" in *[!a-z0-9-]*) nok "slug has other chars: $slug" ;; *) ok ;; esac
git checkout -q main; plan PROJ-3
run "$RS" start-branch plans/PROJ-3.plan.md ""; assert_eq "$OUT" "feature/PROJ-3-work"

t "start-branch: resumes the branch this plan recorded, even with its uncommitted work"
git checkout -q main; plan PROJ-4
B="$("$RS" start-branch plans/PROJ-4.plan.md "resume me" 2>/dev/null)"
echo "half done" >> README                            # the crashed run's partial work
run "$RS" start-branch plans/PROJ-4.plan.md "resume me"
assert_eq "$CODE/$OUT" "0/$B" "resume in place"; assert_contains "$ERR" "resuming"
git stash -q; git checkout -q main; git stash pop -q 2>/dev/null || true
git checkout -q -- README                              # clean main again
run "$RS" start-branch plans/PROJ-4.plan.md "resume me"
assert_eq "$CODE/$(branch_now)" "0/$B" "resume from another branch"

t "start-branch: uncommitted changes elsewhere stop the plan (exit 12)"
git checkout -q main; echo dirty >> README
run "$RS" start-branch plans/PROJ-4.plan.md "resume me"; assert_eq "$CODE" "12" "resume, dirty main"
plan PROJ-5
run "$RS" start-branch plans/PROJ-5.plan.md "new"; assert_eq "$CODE" "12" "new, dirty main"
assert_eq "$(branch_now)" "main" "stayed on main"; git checkout -q -- README

t "start-branch: an existing branch the plan didn't record is never reused (exit 13)"
git branch feature/PROJ-5-new
run "$RS" start-branch plans/PROJ-5.plan.md "new"
assert_eq "$CODE" "13" "exit"; assert_contains "$ERR" "already exists"
assert_eq "$(branch_now)" "main" "stayed on main"; assert_eq "$("$PS" get plans/PROJ-5.plan.md branch)" "" "nothing recorded"

t "start-branch: a recorded branch that is gone stops the plan (exit 14)"
plan PROJ-6; "$PS" set plans/PROJ-6.plan.md branch feature/PROJ-6-deleted >/dev/null
run "$RS" start-branch plans/PROJ-6.plan.md "x"; assert_eq "$CODE" "14" "exit"; assert_contains "$ERR" "no longer exists"

t "start-branch: refuses a plan that isn't RUNNABLE, and a bad target branch"
plan PROJ-7 pending
run "$RS" start-branch plans/PROJ-7.plan.md "x"; assert_eq "$CODE" "2" "pending plan"
git_sandbox 'TARGET_BRANCH=-upload-pack'; plan PROJ-8
run "$RS" start-branch plans/PROJ-8.plan.md "x"; assert_eq "$CODE" "2" "option-like target"
assert_eq "$(branch_now)" "main" "nothing checked out"

finish
