#!/usr/bin/env bash
# review-queue.sh: which of the plugin's own PRs still wait for a human review, and the cap.
# Bitbucket answers come from fixtures (documented shapes, not verified live); origin is a local bare repo.
. "$(dirname "$0")/helpers.sh"
Q="$S/review-queue.sh"; PS="$SHARED/plan-state.sh"; RR="$S/review-record.sh"
RAW="https://bitbucket.org/acme/widgets/pull-requests"
AUTHOR=aaaa-author; MATE=bbbb-mate

# A sandbox with a local bare origin and fixtures; $SB/fx is the Bitbucket fixture tree.
qbox() {
  sandbox "$@"
  echo base > README; git add README; git commit -qm base
  git init -q --bare "$SB/origin.git"; git remote add origin "$SB/origin.git"; git push -q -u origin main
  mkdir -p plans; use_fixtures basic
  PRD="$SB/fx/bb/repositories/acme/widgets/pullrequests"; mkdir -p "$PRD"
}
# branch <name> [file]: push a branch with one commit to origin; prints nothing, sets HEAD40.
branch() {
  local f="${2:-f-$(echo "$1" | tr '/' '_')}"
  git checkout -q -b "$1" main; echo "$1" > "$f"; git add -- "$f"; git commit -qm "c $1"
  HEAD40="$(git rev-parse HEAD)"; git push -q origin "$1"; git checkout -q main
}
# plan <KEY> <pr url or id> [branch]: a stamped plan with pr (and branch) recorded.
plan() {
  local k="$1" u="$2" b="${3:-}"
  case "$u" in http*) ;; *) u="$RAW/$u" ;; esac
  printf '# %s: plan\n\n## Changes\n### Task 1\nDo it.\n' "$k" > "plans/$k.plan.md"
  "$PS" stamp "plans/$k.plan.md" >/dev/null
  "$PS" set "plans/$k.plan.md" pr "$u" >/dev/null
  [ -z "$b" ] || "$PS" set "plans/$k.plan.md" branch "$b" >/dev/null
}
# pr_fx <id> <state> <head> [approver account ids...]: GET pullrequests/<id>
pr_fx() {
  local id="$1" st="$2" hd="$3"; shift 3
  local parts='[{"approved":false,"user":{"account_id":"'$AUTHOR'"}}]' a
  for a in "$@"; do parts="$(jq -c --arg a "$a" '. + [{approved:true, user:{account_id:$a}}]' <<<"$parts")"; done
  jq -n --arg s "$st" --arg h "$hd" --arg au "$AUTHOR" --argjson p "$parts" \
    '{id:1, title:"SECRET-TITLE", state:$s, author:{account_id:$au}, source:{commit:{hash:$h}, branch:{name:"x"}}, participants:$p}' > "$PRD/$id.json"
}
# comments_fx <id> <file-suffix or ""> <next or ""> <created raw>...: a page of comments (created|raw pairs)
comments_fx() {
  local id="$1" suf="$2" next="$3"; shift 3
  local vals='[]' pair
  for pair in "$@"; do
    vals="$(jq -c --arg c "${pair%%|*}" --arg r "${pair#*|}" '. + [{created_on:$c, deleted:false, content:{raw:$r}}]' <<<"$vals")"
  done
  mkdir -p "$PRD/$id"
  jq -n --argjson v "$vals" --arg n "$next" '{values:$v} + (if $n == "" then {} else {next:$n} end)' > "$PRD/$id/comments$suf.json"
}
rec() { printf '[asdlc] Human review: hunks a.py:1-5 at %s\nReviewed in /asdlc:review-tour.' "$1"; }
SHA_OLD=1111111111111111111111111111111111111111

# ---- states ---------------------------------------------------------------------------------
t "open PR, no record: waiting, QUEUE line, one PR line, exit 0 under the cap"
qbox; branch feature/PROJ-1-x; H1="$HEAD40"; plan PROJ-1 7 feature/PROJ-1-x
pr_fx 7 OPEN "${H1:0:12}"; comments_fx 7 "" ""
run "$Q"
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "QUEUE 1/3
PR 7 PROJ-1 OPEN human=none teammate=no tier=unknown reasons=-" "output"
assert_not_contains "$OUT$ERR" "SECRET-TITLE" "no PR title printed"

t "read-only: every request is a GET"
assert_eq "$(requests | jq -r '[.[].method] | unique | join(",")')" "GET" "methods"

t "merged and declined PRs are not waiting; --all lists them"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x; plan PROJ-2 8 feature/PROJ-1-x; plan PROJ-3 9 feature/PROJ-1-x
pr_fx 7 MERGED "${HEAD40:0:12}"; pr_fx 8 DECLINED "${HEAD40:0:12}"; pr_fx 9 SUPERSEDED "${HEAD40:0:12}"
for i in 7 8 9; do comments_fx $i "" ""; done
run "$Q"; assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "QUEUE 0/3" "nothing waiting"
run "$Q" --all
assert_contains "$OUT" "PR 7 PROJ-1 MERGED " "merged"; assert_contains "$OUT" "PR 8 PROJ-2 DECLINED " "declined"
assert_contains "$OUT" "PR 9 PROJ-3 SUPERSEDED " "superseded"

t "unknown: REST fails and there is no git remote: waiting, with the reason"
sandbox; mkdir -p plans; use_fixtures basic
plan PROJ-1 7 feature/PROJ-1-x
run "$Q"
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "QUEUE 1/3
PR 7 PROJ-1 UNKNOWN human=none teammate=no tier=unknown reasons=-" "output"
assert_contains "$ERR" "neither Bitbucket nor git could tell" "reason"

t "REST fails but the branch exists on origin: OPEN (git); branch gone: CLOSED, not waiting"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x; plan PROJ-2 8 feature/PROJ-2-gone
run "$Q" --all
assert_contains "$OUT" "PR 7 PROJ-1 OPEN human=none" "branch there"
assert_contains "$OUT" "PR 8 PROJ-2 CLOSED human=none" "branch gone"
assert_contains "$OUT" "QUEUE 1/3" "only the open one waits"

t "a PR whose branch is gone gets no REST call (merged plans cost nothing); one ls-remote per run"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x; plan PROJ-2 8 feature/PROJ-2-gone; plan PROJ-3 9 feature/PROJ-3-gone
pr_fx 7 OPEN "${HEAD40:0:12}"; comments_fx 7 "" ""; pr_fx 8 OPEN "${HEAD40:0:12}"; pr_fx 9 OPEN "${HEAD40:0:12}"
: > "$ASDLC_FIXTURE_LOG"
run "$Q"
assert_eq "$OUT" "QUEUE 1/3
PR 7 PROJ-1 OPEN human=none teammate=no tier=unknown reasons=-" "only the open branch waits"
assert_eq "$(requests | jq -r '[.[].path | select(test("pullrequests/(8|9)"))] | length')" "0" "no REST call for a gone branch"
assert_eq "$(requests | jq -r '[.[].path | select(test("pullrequests/7"))] | length')" "2" "the open one is read (PR + comments)"
mkdir -p gitlog; cat > gitlog/git <<'SH'
#!/usr/bin/env bash
case "$1" in ls-remote) echo x >> "$GITLOG";; esac
exec "$REALGIT" "$@"
SH
chmod +x gitlog/git
GITLOG="$SB/gitlog/n" REALGIT="$(command -v git)" PATH="$SB/gitlog:$PATH" run "$Q"
assert_eq "$(wc -l < gitlog/n | tr -d ' ')" "1" "one ls-remote for three plans"

t "no token, no fixtures: git only, with a warning; no curl"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x
unset ASDLC_FIXTURES ASDLC_FIXTURE_LOG
PATH="$ROOT/tests/jira/fakebin:$PATH" FAKECURL_LOG="$SB/curl.log" run "$Q"
assert_contains "$OUT" "PR 7 PROJ-1 OPEN" "state from git"; assert_contains "$ERR" "no Bitbucket token" "warning"
assert_eq "$([ -e "$SB/curl.log" ] && wc -l < "$SB/curl.log" | tr -d ' ' || echo 0)" "0" "curl calls"

t "a branch name starting with '-' is not sent to git"
qbox; plan PROJ-1 7 -oops; pr_fx 7 OPEN abcdef1234; comments_fx 7 "" ""
run "$Q"; assert_contains "$OUT" "PR 7 PROJ-1 OPEN" "REST answers alone"

# ---- the human record -----------------------------------------------------------------------
t "a remote record at the head (short hash on the PR) makes it current: not waiting"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x
pr_fx 7 OPEN "${HEAD40:0:12}"
comments_fx 7 "" "" "2026-01-01T10:00:00+00:00|$(rec "$HEAD40")"
run "$Q" --all
assert_contains "$OUT" "PR 7 PROJ-1 OPEN human=current teammate=no" "current"; assert_contains "$OUT" "QUEUE 0/3" "not waiting"

t "an older record is stale: still waiting"
comments_fx 7 "" "" "2026-01-01T10:00:00+00:00|$(rec "$SHA_OLD")"
run "$Q"; assert_contains "$OUT" "PR 7 PROJ-1 OPEN human=stale" "stale"; assert_contains "$OUT" "QUEUE 1/3" "waiting"

t "the newest record wins, whatever order the API returns them in"
comments_fx 7 "" "" "2026-01-01T10:00:00+00:00|$(rec "$HEAD40")" "2026-02-01T10:00:00+00:00|$(rec "$SHA_OLD")"
run "$Q"; assert_contains "$OUT" "human=stale" "newer record is the old sha"
comments_fx 7 "" "" "2026-02-01T10:00:00+00:00|$(rec "$HEAD40")" "2026-01-01T10:00:00+00:00|$(rec "$SHA_OLD")"
run "$Q"; assert_contains "$OUT" "QUEUE 0/3" "newer record is the head"

t "a comment that only mentions the prefix, or a malformed record, is not a record"
comments_fx 7 "" "" "2026-01-01T10:00:00+00:00|[asdlc] Human review: hunks a.py:1-5 at ${HEAD40:0:12}" \
  "2026-01-02T10:00:00+00:00|see [asdlc] Human review: hunks a.py:1-5 at $HEAD40"
run "$Q"; assert_contains "$OUT" "human=none" "no valid record"

t "a deleted record comment is ignored"
comments_fx 7 "" "" "2026-01-01T10:00:00+00:00|$(rec "$HEAD40")"
jq '.values[0].deleted = true' "$PRD/7/comments.json" > "$SB/c.json" && mv "$SB/c.json" "$PRD/7/comments.json"
run "$Q"; assert_contains "$OUT" "human=none" "deleted"

t "a local record at the head counts (review-record.sh add)"
comments_fx 7 "" ""
"$RR" add PROJ-1 7 "$HEAD40" a.py:1-5 >/dev/null
run "$Q"; assert_contains "$OUT" "QUEUE 0/3" "local current"
git checkout -q feature/PROJ-1-x; echo more >> f-feature_PROJ-1-x; git commit -qam more; git push -q origin feature/PROJ-1-x; git checkout -q main
pr_fx 7 OPEN "$(git rev-parse feature/PROJ-1-x | cut -c1-12)"
run "$Q"; assert_contains "$OUT" "PR 7 PROJ-1 OPEN human=stale" "the head moved on, the record is stale"

t "REST head and git head disagree: stale"
pr_fx 7 OPEN deadbeef0123
"$RR" add PROJ-1 7 "$(git rev-parse feature/PROJ-1-x)" a.py:1-5 >/dev/null
run "$Q"; assert_contains "$OUT" "human=stale" "disagree"

# ---- teammate approval ----------------------------------------------------------------------
t "someone other than the author approved: leaves the queue"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x; comments_fx 7 "" ""
pr_fx 7 OPEN "${HEAD40:0:12}" "$MATE"
run "$Q" --all; assert_contains "$OUT" "PR 7 PROJ-1 OPEN human=none teammate=yes" "teammate"; assert_contains "$OUT" "QUEUE 0/3" "not waiting"

t "the author's own approval does not count"
pr_fx 7 OPEN "${HEAD40:0:12}" "$AUTHOR"
run "$Q"; assert_contains "$OUT" "teammate=no" "author approval"; assert_contains "$OUT" "QUEUE 1/3" "still waiting"

t "no author account id in the response: nobody counts as a teammate"
jq 'del(.author)' "$PRD/7.json" > "$SB/p.json"; mv "$SB/p.json" "$PRD/7.json"
run "$Q"; assert_contains "$OUT" "teammate=no" "fail closed"

# ---- pagination -----------------------------------------------------------------------------
t "the record on page 2 is found; the next link must be under the API"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x; pr_fx 7 OPEN "${HEAD40:0:12}"
NEXT="https://api.bitbucket.org/2.0/repositories/acme/widgets/pullrequests/7/comments?sort=-created_on&pagelen=50&page=2"
comments_fx 7 "" "$NEXT" "2026-03-01T10:00:00+00:00|[asdlc] AI review (not a human review): ok"
comments_fx 7 ".page-2" "" "2026-01-01T10:00:00+00:00|$(rec "$HEAD40")"
run "$Q"; assert_contains "$OUT" "QUEUE 0/3" "found on page 2"
assert_eq "$(requests | jq -r '[.[] | select(.path | test("comments")) | .path] | length')" "2" "two comment pages read"
comments_fx 7 "" "https://evil.example.com/2.0/repositories/acme/widgets/pullrequests/7/comments?page=2" "2026-03-01T10:00:00+00:00|x"
run "$Q"; assert_contains "$OUT" "human=none" "foreign next not followed"; assert_contains "$ERR" "not under the Bitbucket API" "warned"
assert_eq "$(requests | jq -r '[.[] | select(.path | test("evil"))] | length')" "0" "no request to the foreign host"

t "at most 5 comment pages"
for n in 2 3 4 5 6 7; do
  nx="https://api.bitbucket.org/2.0/repositories/acme/widgets/pullrequests/7/comments?sort=-created_on&pagelen=50&page=$((n + 1))"
  comments_fx 7 ".page-$n" "$nx" "2026-01-0${n}T10:00:00+00:00|x"
done
comments_fx 7 "" "https://api.bitbucket.org/2.0/repositories/acme/widgets/pullrequests/7/comments?sort=-created_on&pagelen=50&page=2" "2026-01-01T10:00:00+00:00|x"
: > "$ASDLC_FIXTURE_LOG"
run "$Q"
assert_eq "$(requests | jq -r '[.[] | select(.path | test("comments"))] | length')" "5" "five pages"
assert_contains "$ERR" "more than 5 pages" "warned"

# ---- the tier -------------------------------------------------------------------------------
t "tier and reasons come from the report; a skim claim is checked against the diff"
qbox; branch feature/PROJ-1-x; plan PROJ-1 7 feature/PROJ-1-x; pr_fx 7 OPEN "${HEAD40:0:12}"; comments_fx 7 "" ""
cp "$FIXTURES/review-report/high.md" plans/pr-review-PROJ-1.md
run "$Q"; assert_contains "$OUT" "tier=high reasons=migration,api-contract" "high"
cp "$FIXTURES/review-report/normal.md" plans/pr-review-PROJ-1.md
run "$Q"; assert_contains "$OUT" "tier=normal reasons=-" "normal"
cp "$FIXTURES/review-report/skim-docs.md" plans/pr-review-PROJ-1.md
run "$Q"; assert_contains "$OUT" "tier=normal" "skim over a code change becomes normal"
git checkout -q -b feature/PROJ-9-docs main; echo x > notes.md; git add notes.md; git commit -qm docs; git push -q origin feature/PROJ-9-docs; git checkout -q main
plan PROJ-9 9 feature/PROJ-9-docs; pr_fx 9 OPEN "$(git rev-parse feature/PROJ-9-docs | cut -c1-12)"; comments_fx 9 "" ""; cp "$FIXTURES/review-report/skim-docs.md" plans/pr-review-PROJ-9.md
run "$Q"; assert_contains "$OUT" "PR 9 PROJ-9 OPEN human=none teammate=no tier=skim" "a docs-only skim stays skim"
printf 'garbage\n' > plans/pr-review-PROJ-1.md
run "$Q"; assert_contains "$OUT" "PR 7 PROJ-1 OPEN human=none teammate=no tier=high" "an unreadable report is high"
assert_not_contains "$OUT$ERR" "SECRET-WHY" "no why text"

# ---- which PRs count ------------------------------------------------------------------------
t "a pr on another host or repo is skipped with a warning; a plan with no pr does not count"
qbox
plan PROJ-1 "https://github.com/acme/widgets/pull/5"; plan PROJ-2 "https://bitbucket.org/other/widgets/pull-requests/5"
plan PROJ-3 "https://bitbucket.org/acme/widgets/pull-requests/5/x"
printf '# PROJ-4: plan\n\n## Changes\n### Task 1\nDo it.\n' > plans/PROJ-4.plan.md; "$PS" stamp plans/PROJ-4.plan.md >/dev/null
run "$Q"; assert_eq "$OUT" "QUEUE 0/3" "nothing counted"
assert_contains "$ERR" "PROJ-1: pr 'https://github.com/acme/widgets/pull/5' is not a pull request of acme/widgets" "github"
assert_contains "$ERR" "PROJ-2: pr" "other workspace"; assert_contains "$ERR" "PROJ-3: pr" "suffix"
assert_eq "$(requests | jq length)" "0" "no request"

t "a trailing slash on the PR url is accepted; --plans-dir reads another folder"
qbox; branch feature/PROJ-1-x; mkdir other; plan PROJ-1 "$RAW/7/" feature/PROJ-1-x; mv plans/PROJ-1.plan.md other/
pr_fx 7 OPEN "${HEAD40:0:12}"; comments_fx 7 "" ""
run "$Q"; assert_eq "$OUT" "QUEUE 0/3" "plans/ is empty"
run "$Q" --plans-dir other; assert_contains "$OUT" "PR 7 PROJ-1 OPEN" "other folder"
run "$Q" --bogus; assert_eq "$CODE" "2" "unknown option"

# ---- the cap --------------------------------------------------------------------------------
# N open PRs waiting, under the config's REVIEW_QUEUE_MAX (a value of "" leaves the default).
cap_box() {  # <n waiting> [REVIEW_QUEUE_MAX]
  local n="$1" i; if [ -n "${2:-}" ]; then qbox "REVIEW_QUEUE_MAX=$2"; else qbox; fi
  i=0; while [ "$i" -lt "$n" ]; do i=$((i + 1))
    branch "feature/PROJ-$i-x"; plan "PROJ-$i" "$i" "feature/PROJ-$i-x"; pr_fx "$i" OPEN "${HEAD40:0:12}"; comments_fx "$i" "" ""
  done
}
t "default cap is 3: 2 waiting exits 0, 3 waiting exits 18, and still prints the queue"
cap_box 2; run "$Q"; assert_eq "$CODE" "0" "2 of 3"; assert_contains "$OUT" "QUEUE 2/3" "line"
cap_box 3; run "$Q"; assert_eq "$CODE" "18" "3 of 3"; assert_contains "$OUT" "QUEUE 3/3" "line"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '^PR ')" "3" "one line per waiting PR"
run "$S/jira-conf.sh" REVIEW_QUEUE_MAX; assert_eq "$OUT" "3" "default"

t "REVIEW_QUEUE_MAX=1: one waiting PR is at the cap"
cap_box 1 1; run "$Q"; assert_eq "$CODE" "18" "exit"; assert_contains "$OUT" "QUEUE 1/1" "line"
cap_box 0 1; run "$Q"; assert_eq "$CODE" "0" "none waiting"

t "REVIEW_QUEUE_MAX=0 never caps"
cap_box 4 0; run "$Q"; assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "QUEUE 4/0" "line"

t "a bad REVIEW_QUEUE_MAX is refused (exit 2), not guessed"
for bad in abc -1 2.5 3x 12345678901; do
  cap_box 1 "$bad"; run "$Q"
  assert_eq "$CODE" "2" "exit for [$bad]"; assert_contains "$ERR" "REVIEW_QUEUE_MAX" "reason for [$bad]"; assert_eq "$OUT" "" "no queue for [$bad]"
done

t "no BB_WORKSPACE: a config error"
qbox; echo "BB_WORKSPACE=" >> .asdlc/jira.conf; run "$Q"; assert_eq "$CODE" "2" "exit"

# ---- setup shows the key --------------------------------------------------------------------
t "jira-setup check shows REVIEW_QUEUE_MAX and fails a bad value"
qbox; run "$S/jira-setup.sh" check; assert_contains "$OUT" "ok    REVIEW_QUEUE_MAX=3" "shown"
cap_box 0 0; run "$S/jira-setup.sh" check; assert_contains "$OUT" "REVIEW_QUEUE_MAX=0: no review-queue cap" "off"
cap_box 0 many; run "$S/jira-setup.sh" check; assert_contains "$OUT" "FAIL  REVIEW_QUEUE_MAX must be a whole number" "bad"

# ---- hygiene --------------------------------------------------------------------------------
t "jira-run: the queue runs before start-branch, and review-record add never"
JR="$ROOT/plugins/asdlc/commands/jira-run.md"
body="$(sed '1,/^---$/{/^---$/!d;}' "$JR")"
qline="$(grep -n 'review-queue.sh`' "$JR" | head -1 | cut -d: -f1)"
sline="$(grep -n 'run-state.sh start-branch' "$JR" | sed -n 2p | cut -d: -f1)"
[ -n "$qline" ] && [ -n "$sline" ] && [ "$qline" -lt "$sline" ] && ok || nok "queue line $qline, start-branch line $sline"
assert_contains "$(cat "$JR")" "Exit 18" "handles exit 18"
assert_contains "$(head -5 "$JR")" "review-queue.sh:*" "allowed-tools has the queue"
assert_contains "$(head -5 "$JR")" "scripts/review-report.sh:*" "allowed-tools has the report reader"
# Task 4 pre-approves only the read-only `last` (for the re-review delta), never `add` or a blanket.
assert_not_contains "$(head -5 "$JR" | sed 's/review-record\.sh last:\*//')" "review-record" "no record script pre-approved except last"
assert_eq "$(grep -n 'review-record.sh add' "$JR" | grep -v 'Never run' | wc -l | tr -d ' ')" "0" "never runs add"
assert_contains "$(cat "$JR")" "[asdlc] AI review (not a human review):" "AI summary marker"
assert_contains "$(cat "$JR")" "--id <KEY>" "review-pr gets --id"
assert_contains "$(cat "$JR")" "AI-approved, awaiting your human review (tier <t>: <reasons>)" "D-H10 line"
assert_not_contains "$(cat "$JR")" "approved, awaiting merge" "old line gone"

finish
