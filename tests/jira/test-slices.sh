#!/usr/bin/env bash
# PR slices (item 7, D-H9): the "## PR slices" table and its validation, the slice header and the
# waiting status, run-state.sh next-slice (a compare-and-set that follows a REST-confirmed merge),
# per-slice branch names, and the stale check before a later slice. Bitbucket answers come from
# fixtures (the documented shape, not verified live); origin is a local bare repo.
. "$(dirname "$0")/helpers.sh"
# These gates refuse test modes unless this opt-in is set (SF-1); the refusal tests unset it with env -u.
export ASDLC_TEST_FIXTURE_CHECK=1
PS="$SHARED/plan-state.sh"; PA="$SHARED/plan-approve.sh"; RS="$S/run-state.sh"; JC="$S/jira-context.sh"
URL="https://bitbucket.org/acme/widgets/pull-requests/7"

human_status() { sed "1,/^-->/s/^status: .*/status: $2/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }
assert_same() { if cmp -s "$1" "$2"; then ok; else nok "${3:-file} changed"; fi; }

# A complete plan that validates, with <n> tasks and the given "## PR slices" block ("" = none).
mkplan() {  # <KEY> <ntasks> <slices block or "">
  local k="$1" n="$2" blk="$3" i
  {
    printf '# %s: plan\n\n## Goal\nDo the thing.\n\n## Context used\n- Ticket sections: all\n\n'
    printf '## What else uses this\n| Usage | What it does | Verdict | Why |\n|---|---|---|---|\n| a.py:1 | reads it | fine | read only |\n\n'
    printf '## Must still work\n- As a user, when I log in, I still can.\n\n## Changes\n'
    for i in $(seq 1 "$n"); do printf '### Task %s: step %s\n- Goal: do step %s\n\n' "$i" "$i" "$i"; done
    if [ -n "$blk" ]; then printf '## PR slices\n| Slice | Tasks | Why separate |\n|---|---|---|\n%s\n\n' "$blk"; fi
    printf '## Tests\n- a test\n\n## Risk\nLow.\n\n## Open questions\nNone\n\n## Critic notes\n| # | Severity | Finding | Evidence | Planner response |\n|---|---|---|---|---|\n| 1 | note | none | n/a | n/a |\n'
  } > "plans/$k.plan.md"
}
stamped() { mkplan "$@"; "$PS" stamp "plans/$1.plan.md" >/dev/null; }
approved() { stamped "$@"; human_status "plans/$1.plan.md" approved; }
ROWS3='| 1 | 1 | migration |
| 2 | 2 | behaviour |
| 3 | 3 | follow-up |'

# ---- validate ------------------------------------------------------------------------------------
t "validate: no section, and a template hint row, are one slice and VALID"
sandbox; mkdir plans
mkplan PROJ-1 3 ""; run "$PS" validate PROJ-1; assert_eq "$OUT/$CODE" "VALID/0" "no section"
run "$PS" slice PROJ-1; assert_eq "$CODE" "16" "slice needs a header"          # not stamped yet: no header block
"$PS" stamp plans/PROJ-1.plan.md >/dev/null
run "$PS" slice PROJ-1; assert_eq "$OUT/$CODE" "SLICE 1/1 tasks all/0" "no section is slice 1 of 1"
mkplan PROJ-2 2 '| <1> | <1-2> | <why this is its own PR> |'
run "$PS" validate PROJ-2; assert_eq "$OUT/$CODE" "VALID/0" "hint row only"; assert_not_contains "$ERR" "PR slices" "no slice problem"

t "validate: a good split (a list, a range, both)"
mkplan PROJ-3 3 '| 1 | 1 | migration |
| 2 | 2-3 | behaviour |'
run "$PS" validate PROJ-3; assert_eq "$OUT/$CODE" "VALID/0" "1 / 2-3"
mkplan PROJ-3 4 '| 1 | 1, 2 | migrations |
| 2 | 3-4 | behaviour |'
run "$PS" validate PROJ-3; assert_eq "$OUT/$CODE" "VALID/0" "1, 2 / 3-4"
mkplan PROJ-3 5 '| 1 | 1-2, 3 | a |
| 2 | 4 | b |
| 3 | 5 | c |'
run "$PS" validate PROJ-3; assert_eq "$OUT/$CODE" "VALID/0" "three rows, mixed list and range"
mkplan PROJ-3 3 "$ROWS3"; run "$PS" validate PROJ-3; assert_eq "$OUT/$CODE" "VALID/0" "3 slices"

t "validate: a task in two slices"
mkplan PROJ-4 3 '| 1 | 1-2 | a |
| 2 | 2-3 | b |'
run "$PS" validate PROJ-4; assert_eq "$OUT/$CODE" "INVALID/20" "exit"; assert_contains "$ERR" "PR slices: task 2 is in more than one slice" "problem"
mkplan PROJ-4 3 '| 1 | 1, 1 | a |
| 2 | 2-3 | b |'
run "$PS" validate PROJ-4; assert_contains "$ERR" "task 1 is in more than one slice" "listed twice"

t "validate: a missing task, and a task with no heading"
mkplan PROJ-4 3 '| 1 | 1 | a |
| 2 | 3 | b |'
run "$PS" validate PROJ-4; assert_eq "$CODE" "20" "exit"; assert_contains "$ERR" "PR slices: task 2 is in no slice" "missing"
mkplan PROJ-4 2 '| 1 | 1 | a |
| 2 | 2, 9 | b |'
run "$PS" validate PROJ-4; assert_contains "$ERR" "task 9, which has no \"### Task 9\" heading" "no such task"

t "validate: out of order"
mkplan PROJ-4 3 '| 1 | 2-3 | a |
| 2 | 1 | b |'
run "$PS" validate PROJ-4; assert_eq "$CODE" "20" "exit"; assert_contains "$ERR" "PR slices: slice 2 has a task (1) ahead of a task of slice 1 (3)" "order"
mkplan PROJ-4 3 '| 1 | 1, 3 | a |
| 2 | 2 | b |'
run "$PS" validate PROJ-4; assert_contains "$ERR" "slice 2 has a task (2) ahead of a task of slice 1 (3)" "interleaved"

t "validate: four slices, bad numbering, bad cells"
mkplan PROJ-4 4 '| 1 | 1 | a |
| 2 | 2 | b |
| 3 | 3 | c |
| 4 | 4 | d |'
run "$PS" validate PROJ-4; assert_eq "$CODE" "20" "exit"; assert_contains "$ERR" "PR slices: at most 3 slices, found 4" "4 slices"
mkplan PROJ-4 2 '| 1 | 1 | a |
| 3 | 2 | b |'
run "$PS" validate PROJ-4; assert_contains "$ERR" "the Slice cell must be 2" "numbering"
mkplan PROJ-4 2 '| 1 | 2-1 | a |
| 2 | one | b |'
run "$PS" validate PROJ-4; assert_contains "$ERR" "runs backwards" "backwards range"; assert_contains "$ERR" "is not a task number or a range" "word"
mkplan PROJ-4 2 '| 1 |  | a |
| 2 | 1-2 | b |'
run "$PS" validate PROJ-4; assert_contains "$ERR" "slice 1 has no tasks" "empty cell"
mkplan PROJ-4 2 '| 1 | 1-2 | a |'
printf '\n## PR slices\n| Slice | Tasks | Why |\n|---|---|---|\n| 1 | 1 | x |\n' >> plans/PROJ-4.plan.md
run "$PS" validate PROJ-4; assert_contains "$ERR" "more than one \"## PR slices\" heading" "duplicate heading"

t "validate: a duplicated task heading makes slices ambiguous"
mkplan PROJ-4 2 '| 1 | 1 | a |
| 2 | 2 | b |'
printf '### Task 2: again\n' >> plans/PROJ-4.plan.md   # lands in the last section, not Changes: ignored
run "$PS" validate PROJ-4; assert_eq "$CODE" "0" "a heading outside Changes is not a task"

t "the template documents the Tasks cell format and validates as before"
TPL="$ROOT/plugins/asdlc/templates/plan.md"
assert_contains "$(cat "$TPL")" '"1-2, 4"' "template shows the format"
assert_contains "$(cat "$TPL")" "at most 3 rows" "template names the cap"
sandbox; mkdir plans; cp "$TPL" plans/PROJ-1.plan.md
run "$PS" validate PROJ-1; assert_eq "$CODE" "20" "unfilled template"; assert_not_contains "$ERR" "PR slices:" "the hint row is not data"

# ---- the slice header ----------------------------------------------------------------------------
t "stamp: slice: 1 for a plan with a slices section, no line for any other plan"
sandbox; mkdir plans
stamped PROJ-1 3 "$ROWS3"; stamped PROJ-2 3 ""
assert_eq "$("$PS" get plans/PROJ-1.plan.md slice)" "1" "with a section"
assert_eq "$(sed '1,/^-->/!d' plans/PROJ-2.plan.md | grep -c '^slice:')" "0" "without a section: no line"
assert_eq "$(sed '1,/^-->/!d' plans/PROJ-1.plan.md | grep -c '^slice:')" "1" "exactly one line"
stamped PROJ-4 2 '| <1> | <1-2> | <why this is its own PR> |'
assert_eq "$(sed '1,/^-->/!d' plans/PROJ-4.plan.md | grep -c '^slice:')" "0" "a kept hint row only: no line (N-3)"

t "the header is outside plan_hash: changing slice leaves the hash and the state alone"
approved PROJ-1 3 "$ROWS3"
H0="$("$PS" get plans/PROJ-1.plan.md plan_hash)"; run "$PS" check PROJ-1; assert_eq "$OUT" "RUNNABLE" "before"
sed '1,/^-->/s/^slice: .*/slice: 2/' plans/PROJ-1.plan.md > plans/t && mv plans/t plans/PROJ-1.plan.md
run "$PS" check PROJ-1; assert_eq "$OUT/$CODE" "RUNNABLE/0" "after a header-only slice change"
assert_eq "$("$PS" get plans/PROJ-1.plan.md plan_hash)" "$H0" "stored hash unchanged"
run "$PS" slice PROJ-1; assert_eq "$OUT" "SLICE 2/3 tasks 2" "the header value is read"
sed '1,/^-->/s/^slice: .*/slice: 1/' plans/PROJ-1.plan.md > plans/t && mv plans/t plans/PROJ-1.plan.md

t "set refuses slice (exit 2, file untouched); an unknown status is still refused"
cp plans/PROJ-1.plan.md "$SB/before"
run "$PS" set plans/PROJ-1.plan.md slice 2; assert_eq "$CODE" "2" "exit"; assert_contains "$ERR" "run-state.sh next-slice" "names the only way"
assert_same plans/PROJ-1.plan.md "$SB/before" "plan"

t "a second slice line, or a malformed one, is EDITED (like any duplicated header field)"
sed '1,/^-->/s/^slice: 1$/slice: 1\nslice: 2/' plans/PROJ-1.plan.md > plans/PROJ-9.plan.md
run "$PS" check plans/PROJ-9.plan.md; assert_eq "$OUT/$CODE" "EDITED/11" "duplicate"; assert_contains "$ERR" "duplicate header field" "message"
for bad in "x" "0" "" "1 2" "-1" "1000"; do
  sed "1,/^-->/s/^slice: .*/slice: $bad/" plans/PROJ-1.plan.md > plans/PROJ-9.plan.md
  run "$PS" check plans/PROJ-9.plan.md; assert_eq "$OUT/$CODE" "EDITED/11" "slice '$bad'"
done
run "$PS" check plans/PROJ-9.plan.md; assert_contains "$ERR" "slice header" "message"
rm -f plans/PROJ-9.plan.md

t "an older plan with no slice line reads as slice 1 and stays RUNNABLE"
sed '1,/^-->/{/^slice:/d;}' plans/PROJ-1.plan.md > plans/PROJ-9.plan.md
run "$PS" check plans/PROJ-9.plan.md; assert_eq "$OUT/$CODE" "RUNNABLE/0" "state"
run "$PS" slice plans/PROJ-9.plan.md; assert_eq "$OUT" "SLICE 1/3 tasks 1" "slice 1"
rm -f plans/PROJ-9.plan.md

# ---- the waiting status ----------------------------------------------------------------------------
t "waiting: only from executing, only with a later slice; check prints WAITING (21); not runnable"
sandbox; mkdir plans
approved PROJ-1 3 "$ROWS3"
cp plans/PROJ-1.plan.md "$SB/before"
run "$PS" set PROJ-1 status waiting; assert_eq "$CODE" "2" "from approved"; assert_contains "$ERR" "only follows executing"
assert_same plans/PROJ-1.plan.md "$SB/before" "plan"
"$PS" set PROJ-1 status executing >/dev/null
run "$PS" set PROJ-1 status waiting; assert_eq "$CODE" "0" "from executing, slice 1 of 3"
run "$PS" check PROJ-1; assert_eq "$OUT/$CODE" "WAITING/21" "check"
run "$PS" set PROJ-1 status executing; assert_eq "$CODE" "2" "waiting is not runnable"
run "$PS" set PROJ-1 status done; assert_eq "$CODE" "2" "done only follows executing"
run "$PS" set PROJ-1 status failed; assert_eq "$CODE" "2" "failed only follows executing"
run "$PS" reset-executing PROJ-1; assert_eq "$CODE" "2" "reset-executing is for crashed runs"
run "$PS" set PROJ-1 status approved; assert_eq "$CODE" "2" "approved is never set"
run "$PA" PROJ-1; assert_eq "$CODE" "2" "plan-approve refuses a waiting plan"; assert_contains "$ERR" "WAITING"
run "$PS" set PROJ-1 status pending; assert_eq "$CODE" "0" "pending is always allowed (fails closed)"

t "waiting: refused on the last slice and on a plan with no slices"
approved PROJ-2 3 ""; "$PS" set PROJ-2 status executing >/dev/null
run "$PS" set PROJ-2 status waiting; assert_eq "$CODE" "2" "no slices"; assert_contains "$ERR" "needs a later slice"
approved PROJ-3 3 "$ROWS3"; sed '1,/^-->/s/^slice: .*/slice: 3/' plans/PROJ-3.plan.md > plans/t && mv plans/t plans/PROJ-3.plan.md
"$PS" set PROJ-3 status executing >/dev/null
run "$PS" set PROJ-3 status waiting; assert_eq "$CODE" "2" "last slice"; assert_contains "$ERR" "slice 3 of 3"
run "$PS" set PROJ-3 status done; assert_eq "$CODE" "0" "done from executing on the last slice"
run "$PS" slice PROJ-3; assert_eq "$OUT/$CODE" "SLICE 3/3 tasks 3/0" "last slice"
sed '1,/^-->/s/^slice: .*/slice: 4/' plans/PROJ-3.plan.md > plans/t && mv plans/t plans/PROJ-3.plan.md
run "$PS" slice PROJ-3; assert_eq "$CODE" "2" "past the last slice"; assert_contains "$ERR" "only 3 slice"

t "progress ignores a slice marker line; plans with no slices are unchanged"
printf -- '- Task 1: TEST PASS — ok\n- slice 1: %s merged\n- Task 2: EXECUTOR DONE — x\n' "$URL" >> plans/PROJ-1.plan.md
run "$PS" progress PROJ-1; assert_eq "$OUT" "Task 1: TEST PASS
Task 2: EXECUTOR DONE" "latest entry per task"

# ---- next-slice ------------------------------------------------------------------------------------
# A sandbox with a local bare origin, fixtures, and a plan one slice into a three-slice run.
git_box() {
  sandbox; echo base > README; git add README; git commit -qm base
  git init -q --bare "$SB/origin.git"; git remote add origin "$SB/origin.git"; git push -q -u origin main
  mkdir -p plans; use_fixtures basic
  PRD="$SB/fx/bb/repositories/acme/widgets/pullrequests"; mkdir -p "$PRD"
}
# pr_state <state> [source branch]: the PR's source branch defaults to PROJ-1's recorded branch (D-H9 check).
pr_state() {
  local b="${2-$("$PS" get plans/PROJ-1.plan.md branch 2>/dev/null)}"
  jq -nc --arg s "$1" --arg b "$b" '{id:7,state:$s,source:{branch:{name:$b}}}' > "$PRD/7.json"
}
# waiting_plan <KEY>: approved, slice-1 branch created, slice-1 work logged, PR recorded, status waiting.
waiting_plan() {
  approved "$1" 3 "$ROWS3"
  B="$("$RS" start-branch "plans/$1.plan.md" "Add the thing" 2>/dev/null)"
  printf -- '- Task 1: TEST PASS — migrated\n' >> "plans/$1.plan.md"
  "$PS" set "plans/$1.plan.md" pr "$URL" >/dev/null
  "$PS" set "plans/$1.plan.md" status executing >/dev/null; "$PS" set "plans/$1.plan.md" status waiting >/dev/null
  git checkout -q main
}
untouched() { assert_same "plans/$1.plan.md" "$SB/before" "the plan"; assert_eq "$(requests | jq -r '[.[] | select(.method != "GET")] | length')" "0" "only GETs"; }

t "next-slice: a MERGED PR moves the plan to slice 2, approved, with a log line, no branch, no pr"
git_box; waiting_plan PROJ-1; pr_state MERGED
H0="$("$PS" get plans/PROJ-1.plan.md plan_hash)"
run "$RS" next-slice plans/PROJ-1.plan.md
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "slice 1 merged; now on slice 2 of 3"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "approved" "status"
assert_eq "$("$PS" get plans/PROJ-1.plan.md slice)" "2" "slice"
assert_eq "$("$PS" get plans/PROJ-1.plan.md branch)" "" "branch cleared"
assert_eq "$("$PS" get plans/PROJ-1.plan.md pr)" "" "pr cleared"
assert_eq "$("$PS" get plans/PROJ-1.plan.md plan_hash)" "$H0" "the approved hash is the one the human approved"
run "$PS" check PROJ-1; assert_eq "$OUT/$CODE" "RUNNABLE/0" "RUNNABLE again, same hash"
assert_eq "$(tail -n1 plans/PROJ-1.plan.md)" "- slice 1: $URL merged" "log line, last under Progress"
assert_eq "$(awk '/asdlc:progress/{f=1} f' plans/PROJ-1.plan.md | grep -c '^- slice')" "1" "one line, below the progress line"
run "$PS" progress PROJ-1; assert_eq "$OUT" "Task 1: TEST PASS" "progress ignores the marker"
run "$PS" slice PROJ-1; assert_eq "$OUT" "SLICE 2/3 tasks 2" "current slice"
assert_eq "$(requests | jq -r '[.[] | "\(.method) \(.path)"] | join(",")')" "GET /repositories/acme/widgets/pullrequests/7" "one GET of the PR"
assert_eq "$(sed '1,/^-->/!d' plans/PROJ-1.plan.md | grep -c '^updated:')" "1" "one updated line"
assert_eq "$("$PS" validate PROJ-1)" "VALID" "still VALID"

t "next-slice: the next branch is feature/<KEY>-<slug>-s2, cut from the target, and the old log no longer blocks it"
echo merged > merged.txt; git checkout -q main; git add merged.txt; git commit -qm "slice 1 merged"; git push -q origin main
run "$RS" start-branch plans/PROJ-1.plan.md "Add the thing"
assert_eq "$CODE" "0" "exit (not 15)"; assert_eq "$OUT" "feature/PROJ-1-add-the-thing-s2" "branch"
assert_eq "$(git symbolic-ref --short HEAD)" "feature/PROJ-1-add-the-thing-s2" "checked out"
[ -f merged.txt ] && ok || nok "slice 2 was not cut from the updated target"
assert_eq "$("$PS" get plans/PROJ-1.plan.md branch)" "feature/PROJ-1-add-the-thing-s2" "recorded"
printf -- '- Task 2: TEST PASS — done\n' >> plans/PROJ-1.plan.md
git checkout -q main; "$PS" set PROJ-1 branch "" >/dev/null
run "$RS" start-branch plans/PROJ-1.plan.md "x"
assert_eq "$CODE" "15" "work logged for slice 2 on a cleared branch still stops (exit 15)"
"$PS" set PROJ-1 branch feature/PROJ-1-add-the-thing >/dev/null     # slice 1's name
run "$RS" start-branch plans/PROJ-1.plan.md "x"; assert_eq "$CODE" "2" "a slice 1 branch is refused on slice 2"; assert_contains "$ERR" "not a slice 2 branch"
"$PS" set PROJ-1 branch feature/PROJ-1-add-the-thing-s2 >/dev/null
run "$RS" start-branch plans/PROJ-1.plan.md "x"; assert_eq "$CODE/$OUT" "0/feature/PROJ-1-add-the-thing-s2" "resumes its own slice branch"

t "next-slice: slice 2 can wait again, and slice 3 branches as -s3"
git checkout -q main; "$PS" set PROJ-1 status executing >/dev/null
run "$PS" set PROJ-1 status waiting; assert_eq "$CODE" "0" "slice 2 of 3 can wait"
"$PS" set PROJ-1 pr "$URL" >/dev/null; pr_state MERGED
run "$RS" next-slice PROJ-1; assert_eq "$CODE" "0" "second advance (bare id)"
assert_eq "$("$PS" get plans/PROJ-1.plan.md slice)" "3" "slice 3"
git checkout -q main; run "$RS" start-branch plans/PROJ-1.plan.md "Add the thing"
assert_eq "$OUT" "feature/PROJ-1-add-the-thing-s3" "slice 3 branch"
assert_eq "$(grep -c '^- slice ' plans/PROJ-1.plan.md)" "2" "two markers"
"$PS" set PROJ-1 status executing >/dev/null
run "$PS" set PROJ-1 status waiting; assert_eq "$CODE" "2" "the last slice never waits"
git checkout -q main

t "next-slice: OPEN, DECLINED and SUPERSEDED refuse with exit 19 and leave the plan byte-identical"
for st in OPEN DECLINED SUPERSEDED; do
  git_box; waiting_plan PROJ-1; pr_state "$st"; cp plans/PROJ-1.plan.md "$SB/before"
  run "$RS" next-slice plans/PROJ-1.plan.md
  assert_eq "$CODE" "19" "$st exit"; assert_contains "$ERR" "is $st, not MERGED" "$st reason"; untouched PROJ-1
done

t "next-slice: unreachable Bitbucket, a missing or odd answer, and no token all refuse with 19"
git_box; waiting_plan PROJ-1; cp plans/PROJ-1.plan.md "$SB/before"
run "$RS" next-slice plans/PROJ-1.plan.md          # no fixture for PR 7: a 404
assert_eq "$CODE" "19" "404"; assert_contains "$ERR" "Bitbucket REST failed" "reason"; untouched PROJ-1
printf '{"id":7,"state":"OPEN"}' > "$PRD/7.json"; printf '500' > "$PRD/7.code"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "500"; untouched PROJ-1
rm -f "$PRD/7.code"; printf '{}' > "$PRD/7.json"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "no state"; assert_contains "$ERR" "no usable state"; untouched PROJ-1
printf 'not json' > "$PRD/7.json"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "not JSON"; untouched PROJ-1
pr_state '"MERGED"'; printf '{"id":7,"state":["MERGED"]}' > "$PRD/7.json"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "state is not a string"
pr_state merged; run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "lower-case state is not MERGED"
pr_state MERGED; cp plans/PROJ-1.plan.md "$SB/before"
run env -u ASDLC_FIXTURES "$RS" next-slice plans/PROJ-1.plan.md
assert_eq "$CODE" "19" "no token"; assert_contains "$ERR" "no Bitbucket token" "reason"; assert_same plans/PROJ-1.plan.md "$SB/before" "plan"

t "next-slice: a git-only merge (the branch is gone from origin) does not count"
git_box; waiting_plan PROJ-1; pr_state OPEN; cp plans/PROJ-1.plan.md "$SB/before"
assert_eq "$(git ls-remote --heads origin | grep -c PROJ-1)" "0" "the branch was never pushed, as after close_source_branch"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "refused"; untouched PROJ-1

t "next-slice: a changed approved part is exit 11 and no request is made"
git_box; waiting_plan PROJ-1; pr_state MERGED
sed 's/^- Goal: do step 2$/- Goal: do something else/' plans/PROJ-1.plan.md > plans/t && mv plans/t plans/PROJ-1.plan.md
cp plans/PROJ-1.plan.md "$SB/before"
run "$RS" next-slice plans/PROJ-1.plan.md
assert_eq "$CODE" "11" "exit"; assert_contains "$ERR" "re-stamp and have a human re-approve" "advice"
assert_same plans/PROJ-1.plan.md "$SB/before" "plan"; assert_eq "$(requests | jq -r 'length')" "0" "no request"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "waiting" "still waiting"

t "next-slice: refuses anything but a waiting plan with a later slice and a Bitbucket PR; no request"
git_box; pr_state MERGED
approved PROJ-1 3 "$ROWS3"; cp plans/PROJ-1.plan.md "$SB/before"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "2" "approved"; assert_contains "$ERR" "not WAITING"
assert_same plans/PROJ-1.plan.md "$SB/before" "plan"
for st in pending executing done failed stale; do
  human_status plans/PROJ-1.plan.md "$st"; run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "2" "$st"
done
run "$RS" next-slice plans/nope.plan.md; assert_eq "$CODE" "16" "no plan"
run "$RS" next-slice 'a b'; assert_eq "$CODE" "2" "bad bare id"
waiting_plan PROJ-2; "$PS" set PROJ-2 pr "" >/dev/null; cp plans/PROJ-2.plan.md "$SB/before"
run "$RS" next-slice plans/PROJ-2.plan.md; assert_eq "$CODE" "19" "no PR recorded"; assert_contains "$ERR" "no PR recorded"
assert_same plans/PROJ-2.plan.md "$SB/before" "plan"
for u in "https://github.com/acme/widgets/pull/7" "https://bitbucket.org/other/widgets/pull-requests/7" "https://bitbucket.org/acme/widgets/pull-requests/x" "https://bitbucket.org/acme/widgets/pull-requests/7/../8"; do
  "$PS" set PROJ-2 pr "$u" >/dev/null; cp plans/PROJ-2.plan.md "$SB/before"
  run "$RS" next-slice plans/PROJ-2.plan.md; assert_eq "$CODE" "19" "pr $u"; assert_same plans/PROJ-2.plan.md "$SB/before" "plan"
done
assert_eq "$(requests | jq -r 'length')" "0" "no request for any of them"
git_box; pr_state MERGED; approved PROJ-3 3 ""; "$PS" set PROJ-3 status executing >/dev/null    # no slices: it can never wait
run "$RS" next-slice PROJ-3; assert_eq "$CODE" "2" "a plan with no slices"
approved PROJ-4 3 "$ROWS3"; sed '1,/^-->/s/^slice: .*/slice: 3/' plans/PROJ-4.plan.md > plans/t && mv plans/t plans/PROJ-4.plan.md
human_status plans/PROJ-4.plan.md waiting; "$PS" set PROJ-4 pr "$URL" >/dev/null; cp plans/PROJ-4.plan.md "$SB/before"
run "$RS" next-slice PROJ-4; assert_eq "$CODE" "2" "last slice"; assert_contains "$ERR" "no next slice"; assert_same plans/PROJ-4.plan.md "$SB/before" "plan"

t "next-slice: a plan edited while waiting is not carried over (the hash must still match)"
git_box; pr_state MERGED; approved PROJ-1 3 "$ROWS3"; human_status plans/PROJ-1.plan.md waiting; "$PS" set PROJ-1 pr "$URL" >/dev/null
sed 's/^- Goal: do step 3$/- Goal: do step 3 and more/' plans/PROJ-1.plan.md > plans/t && mv plans/t plans/PROJ-1.plan.md
run "$RS" next-slice PROJ-1; assert_eq "$CODE" "11" "an edited plan"; assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "waiting" "not approved"

t "a plan with no slices: list, reset-executing and start-branch are unchanged"
git_box; approved PROJ-1 3 ""
run "$RS" start-branch plans/PROJ-1.plan.md "Plain change"; assert_eq "$OUT" "feature/PROJ-1-plain-change" "no suffix"
"$PS" set PROJ-1 status executing >/dev/null; run "$RS" reset-executing; assert_eq "$CODE" "0" "reset-executing"
assert_eq "$("$PS" check PROJ-1)" "RUNNABLE" "back to approved"
approved PROJ-2 3 "$ROWS3"; "$PS" set PROJ-2 status executing >/dev/null; "$PS" set PROJ-2 status waiting >/dev/null
run "$RS" list; assert_contains "$OUT" "WAITING" "list shows the waiting plan"

# ---- the stale check before a later slice --------------------------------------------------------
t "stale check: a ticket that changed while slice 1's PR was open is STALE before slice 2 starts"
export ASDLC_TEST_FIXTURE_CHECK=1
API=jira/rest/api/2
sandbox; use_fixtures context; mkdir -p plans
run "$JC" fetch PROJ-1 >/dev/null 2>&1
approved PROJ-1 3 "$ROWS3"            # stamp picks up the fingerprint of the fetch
assert_contains "$(sed -n '1,/^-->/p' plans/PROJ-1.plan.md)" "ticket_fingerprint: sha256:" "fingerprinted"
PRD="$SB/fx/bb/repositories/acme/widgets/pullrequests"; mkdir -p "$PRD"; "$PS" set PROJ-1 branch feature/PROJ-1-x >/dev/null; pr_state MERGED
"$PS" set PROJ-1 pr "$URL" >/dev/null; "$PS" set PROJ-1 status executing >/dev/null; "$PS" set PROJ-1 status waiting >/dev/null
run "$RS" next-slice PROJ-1; assert_eq "$CODE" "0" "advance"
: > "$ASDLC_FIXTURE_LOG"
jq '.total = 6' "fx/$API/issue/PROJ-1/comment.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1/comment.json"
jq '.total = 6 | .comments += [{"id":"106","author":{"displayName":"Pat Product"},"body":"Also the dark theme.","created":"2026-02-03T00:00:00.000+0000"}]' \
  "fx/$API/issue/PROJ-1/comment.startAt-3.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1/comment.startAt-3.json"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "17" "exit"; assert_contains "$OUT" "STALE" "verdict"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "stale" "the plan is stale, so slice 2 does not run"
run "$PS" check PROJ-1; assert_eq "$OUT/$CODE" "STALE/17" "plan-state agrees"
run "$RS" start-branch plans/PROJ-1.plan.md "x"; assert_eq "$CODE" "2" "start-branch refuses a stale plan"

# ---- test modes are refused at the gate (SF-1) ---------------------------------------------------------
t "next-slice: --fixtures, --conf and ASDLC_FIXTURES are refused without the opt-in, plan untouched"
git_box; waiting_plan PROJ-1; pr_state MERGED; cp plans/PROJ-1.plan.md "$SB/before"
run env -u ASDLC_TEST_FIXTURE_CHECK "$RS" next-slice plans/PROJ-1.plan.md --fixtures "$SB/fx"
assert_eq "$CODE" "2" "--fixtures exit"; assert_contains "$ERR" "test modes" "reason"; untouched PROJ-1
run env -u ASDLC_TEST_FIXTURE_CHECK "$RS" next-slice plans/PROJ-1.plan.md --conf "$SB/.asdlc/jira.conf"
assert_eq "$CODE" "2" "--conf exit"; untouched PROJ-1
run env -u ASDLC_TEST_FIXTURE_CHECK "$RS" next-slice plans/PROJ-1.plan.md
assert_eq "$CODE" "2" "ASDLC_FIXTURES in the environment"; untouched PROJ-1
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "0" "with the opt-in it advances"

t "next-slice: a MERGED PR from another branch is refused with exit 19, plan byte-identical"
git_box; waiting_plan PROJ-1; cp plans/PROJ-1.plan.md "$SB/before"
pr_state MERGED "feature/PROJ-9-other"
run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "other branch"; assert_contains "$ERR" "source branch" "reason"; untouched PROJ-1
pr_state MERGED ""; run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "empty source branch"; untouched PROJ-1
printf '{"id":7,"state":"MERGED"}' > "$PRD/7.json"; run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "19" "no source branch field"; untouched PROJ-1
pr_state MERGED; run "$RS" next-slice plans/PROJ-1.plan.md; assert_eq "$CODE" "0" "its own branch advances"

# ---- the queue finds a slice PR's own report ------------------------------------------------------------
t "review-queue: a plan on slice 2 reads plans/pr-review-<KEY>-s2.md, a plan on slice 1 reads pr-review-<KEY>.md"
git_box; conf_set REVIEW_QUEUE_MAX 0
approved PROJ-1 3 "$ROWS3"; "$PS" set PROJ-1 pr "$URL" >/dev/null; "$PS" set PROJ-1 branch feature/PROJ-1-x >/dev/null
git checkout -q -b feature/PROJ-1-x; echo x > x.txt; git add x.txt; git commit -qm x; git push -q origin feature/PROJ-1-x; git checkout -q main
pr_state OPEN
rpt() { printf '# review\n\n## Human must read\nRisk tier: %s\n| # | Hunk | Reason | Why a human must read it |\n|---|---|---|---|\n%s\n' "$1" "$2" > "plans/$3"; }
rpt high '| 1 | a.py:1-5 | migration | drops a column |' pr-review-PROJ-1.md
rpt high '| 1 | b.py:1-5 | authz | role check |' pr-review-PROJ-1-s2.md
run "$S/review-queue.sh"; assert_contains "$OUT" "tier=high reasons=migration" "slice 1 report"
sed '1,/^-->/s/^slice: .*/slice: 2/' plans/PROJ-1.plan.md > plans/t && mv plans/t plans/PROJ-1.plan.md
run "$S/review-queue.sh"; assert_contains "$OUT" "tier=high reasons=authz" "slice 2 report"
rm -f plans/pr-review-PROJ-1-s2.md
run "$S/review-queue.sh"; assert_contains "$OUT" "tier=unknown" "no -s2 report: unknown, not slice 1's tier"

# ---- the prompts ------------------------------------------------------------------------------------------
t "prompts: template, planner, critic, implement-prd and jira-run carry the slice rules"
P="$ROOT/plugins/asdlc"
JR="$(cat "$P/commands/jira-run.md")"; IP="$(cat "$P/commands/implement-prd.md")"
jfm="$(sed -n '/^---$/,/^---$/p' "$P/commands/jira-run.md")"; ifm="$(sed -n '/^---$/,/^---$/p' "$P/commands/implement-prd.md")"
assert_contains "$jfm" "run-state.sh next-slice:*" "jira-run pre-approves next-slice"
assert_not_contains "$jfm" "run-state.sh:*" "but never run-state blanket"
assert_contains "$jfm" "plan-state.sh slice:*" "jira-run reads the slice"
assert_contains "$ifm" "plan-state.sh slice:*" "implement-prd reads the slice"
assert_contains "$JR" "feature/<KEY>-<slug>-s<k>" "per-slice branch"
assert_contains "$JR" "--id <KEY>-s<k>" "per-slice review id"
assert_contains "$JR" "plans/pr-review-<ID>.md" "per-slice report path"
assert_contains "$JR" "run-state.sh next-slice <plan>" "Phase A calls next-slice"
assert_contains "$JR" "slice <k> PR not merged yet" "the exit 19 report"
assert_contains "$JR" "it runs before EVERY slice" "stale check before each slice"
assert_contains "$JR" "do NOT set \`done\`" "done only after the last slice"
assert_contains "$IP" "Run only the tasks of the current slice" "implement-prd runs one slice"
assert_contains "$IP" "Never set \`waiting\` here" "implement-prd leaves waiting to the caller (after the PR exists)"
assert_contains "$JR" "plan-state.sh set <plan> status waiting\` (the PR is recorded" "jira-run sets waiting in step 6, after the PR"
assert_contains "$(cat "$P/agents/prd-planner.md")" "at most 3 slices" "planner cap"
assert_contains "$(cat "$P/agents/prd-planner.md")" "Never put a migration in the same slice" "planner migration rule"
assert_contains "$(cat "$P/agents/plan-critic.md")" "should-fix" "critic severity"
assert_contains "$(cat "$P/agents/plan-critic.md")" "both a schema or data migration and a behaviour change" "critic migration-with-behaviour rule"
assert_not_contains "$JR" "plan-approve" "jira-run never approves"
assert_not_contains "$IP" "plan-approve" "implement-prd never approves"

finish
