#!/usr/bin/env bash
# plan-state.sh: header block, hash binding, states, transitions, injection, legacy markers.
. "$(dirname "$0")/helpers.sh"
PS="$S/plan-state.sh"

body() { printf '# PROJ-1: plan\n\n## Changes\n1. do it\n'; }
bodyhash() { body | shasum -a 256 | awk '{print $1}'; }

# The human edit that approves a plan (or forces any state): rewrite the status line through
# a temp file, because sed -i differs between BSD and GNU.
human_status() {  # <plan> <status>
  sed "1,/^-->/s/^status: .*/status: $2/" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
approve() { human_status "$1" approved; }
mk() { body > "plans/$1.plan.md"; "$PS" stamp "plans/$1.plan.md" >/dev/null; }  # <KEY>: fresh, pending
assert_status() { assert_eq "$("$PS" get "$1" status)" "$2" "${3:-status}"; }
assert_same() { if cmp -s "$1" "$2"; then ok; else nok "${3:-file} changed"; fi; }

t "stamp writes the header over the body hash"
sandbox; mkdir plans; body > plans/PROJ-1.plan.md
run "$PS" stamp plans/PROJ-1.plan.md
assert_eq "$CODE" "0" "exit"
assert_eq "$(head -n1 plans/PROJ-1.plan.md)" "<!-- asdlc" "marker"
assert_eq "$("$PS" get plans/PROJ-1.plan.md ticket)" "PROJ-1" "ticket from filename"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "pending"
assert_eq "$("$PS" get plans/PROJ-1.plan.md plan_hash)" "sha256:$(bodyhash)"
assert_eq "$(sed '1,/^-->$/d' plans/PROJ-1.plan.md)" "$(body)" "body untouched"

t "pending -> PENDING (10); a human-approved plan -> RUNNABLE (0)"
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "PENDING/10"
approve plans/PROJ-1.plan.md
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

t "check maps every status to its word and exit code"
for pair in executing/EXECUTING/12 done/DONE/13 failed/FAILED/14 skip/SKIP/15 rejected/SKIP/15 weird/PENDING/10; do
  human_status plans/PROJ-1.plan.md "${pair%%/*}"
  run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "${pair#*/}" "status ${pair%%/*}"
done

t "missing file or no header -> MISSING (16)"
run "$PS" check plans/nope.plan.md; assert_eq "$OUT/$CODE" "MISSING/16"
body > plans/PROJ-2.plan.md
run "$PS" check plans/PROJ-2.plan.md; assert_eq "$OUT/$CODE" "MISSING/16"
run "$PS" set plans/PROJ-2.plan.md status pending
assert_eq "$CODE" "16" "set without header"
assert_eq "$(cat plans/PROJ-2.plan.md)" "$(body)" "file untouched"
run "$PS" reset-executing plans/PROJ-2.plan.md
assert_eq "$CODE" "16" "reset-executing without header"

t "set rejects other fields"
run "$PS" set plans/PROJ-1.plan.md plan_hash sha256:0; assert_eq "$CODE" "2"

# ---- SF-1: the state machine behind "set <plan> status <v>" ----------------------------

t "set status approved is refused from every state, and changes nothing"
for s in pending approved executing done failed skip; do
  mk T; P=plans/T.plan.md; human_status "$P" "$s"; cp "$P" "$SB/orig"
  run "$PS" set "$P" status approved
  assert_eq "$CODE" "2" "approved from $s"
  assert_contains "$ERR" "human edit" "approved from $s"
  assert_same "$P" "$SB/orig" "plan after refused approve from $s"
done

t "executing needs RUNNABLE: refused from pending, stale, executing, done, failed, skip"
mk T; P=plans/T.plan.md
for s in pending executing done failed skip; do
  human_status "$P" "$s"; cp "$P" "$SB/orig"
  run "$PS" set "$P" status executing
  assert_eq "$CODE" "2" "executing from $s"
  assert_contains "$ERR" "RUNNABLE" "executing from $s"
  assert_same "$P" "$SB/orig" "plan after refused executing from $s"
done
mk T; approve "$P"; echo "3. sneak in" >> "$P"; cp "$P" "$SB/orig"
run "$PS" set "$P" status executing
assert_eq "$CODE" "2" "executing from STALE"
assert_same "$P" "$SB/orig" "plan after refused executing from STALE"

t "executing from RUNNABLE is allowed"
mk T; approve "$P"
run "$PS" set "$P" status executing
assert_eq "$CODE" "0" "exit"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "EXECUTING/12"

t "done and failed only follow executing"
for v in done failed; do
  for s in pending approved done failed skip; do
    mk T; human_status "$P" "$s"; cp "$P" "$SB/orig"
    run "$PS" set "$P" status "$v"
    assert_eq "$CODE" "2" "$v from $s"
    assert_contains "$ERR" "executing" "$v from $s"
    assert_same "$P" "$SB/orig" "plan after refused $v from $s"
  done
  mk T; approve "$P"; "$PS" set "$P" status executing >/dev/null
  run "$PS" set "$P" status "$v"
  assert_eq "$CODE" "0" "$v from executing"
  assert_status "$P" "$v" "status after $v"
done

t "pending, skip and rejected are always allowed (they fail closed)"
for v in pending skip rejected; do
  for s in pending approved executing done failed skip; do
    mk T; human_status "$P" "$s"
    run "$PS" set "$P" status "$v"
    assert_eq "$CODE" "0" "$v from $s"
    assert_status "$P" "$v" "status $v from $s"
  done
done

t "an unknown or empty status value is refused"
for v in weird Approved ' approved' EXECUTING ''; do
  mk T; cp "$P" "$SB/orig"
  run "$PS" set "$P" status "$v"
  assert_eq "$CODE" "2" "status [$v]"
  assert_same "$P" "$SB/orig" "plan after refused status [$v]"
done
mk T; run "$PS" set "$P" status
assert_eq "$CODE" "2" "status with no value"

# ---- SF-1: reset-executing (compare-and-set) --------------------------------------------

t "reset-executing: executing with an unchanged body -> approved, RUNNABLE"
mk R; P=plans/R.plan.md; approve "$P"; "$PS" set "$P" status executing >/dev/null
"$PS" set "$P" branch feature/R-1 >/dev/null     # branch/pr are outside the hash
run "$PS" reset-executing "$P"
assert_eq "$CODE" "0" "exit"
assert_status "$P" approved
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "RUNNABLE/0"
assert_eq "$("$PS" get "$P" branch)" "feature/R-1" "branch kept"

t "reset-executing: edited body -> exit 11, status unchanged"
mk R; approve "$P"; "$PS" set "$P" status executing >/dev/null
echo "- [x] task 1" >> "$P"; cp "$P" "$SB/orig"
run "$PS" reset-executing "$P"
assert_eq "$CODE" "11" "exit"
assert_contains "$ERR" "changed during the crashed run" "message"
assert_contains "$ERR" "re-approve" "message"
assert_status "$P" executing
assert_same "$P" "$SB/orig" "plan after refused reset"

t "reset-executing: any other status -> exit 2, nothing changed"
for s in pending approved done failed skip; do
  mk R; human_status "$P" "$s"; cp "$P" "$SB/orig"
  run "$PS" reset-executing "$P"
  assert_eq "$CODE" "2" "reset from $s"
  assert_same "$P" "$SB/orig" "plan after refused reset from $s"
done

# ---- SF-1: header injection --------------------------------------------------------------

t "stamp refuses a ticket with a newline or odd characters; the file is unchanged"
for bad in $'PROJ-1\nstatus: approved' $'PROJ-1\r' 'PROJ 1' '-x' '.x' '../x' 'a;b' 'PROJ-1<!--'; do
  body > plans/I.plan.md; cp plans/I.plan.md "$SB/orig"
  run "$PS" stamp plans/I.plan.md "$bad"
  assert_eq "$CODE" "2" "ticket [$bad]"
  assert_same plans/I.plan.md "$SB/orig" "plan after refused ticket [$bad]"
done
body > "plans/a b.plan.md"
run "$PS" stamp "plans/a b.plan.md"
assert_eq "$CODE" "2" "ticket taken from an odd filename"

t "stamp accepts ticket keys and PRD basenames"
for good in PROJ-142 my-prd.v2_final 7; do
  body > plans/I.plan.md
  run "$PS" stamp plans/I.plan.md "$good"
  assert_eq "$CODE" "0" "ticket [$good]"
  assert_eq "$("$PS" get plans/I.plan.md ticket)" "$good" "ticket [$good] stored"
done

t "set refuses a newline or CR in any value; the file is unchanged"
mk I; P=plans/I.plan.md
for pair in "pr:$(printf 'https://x\nstatus: approved')" "pr:$(printf 'https://x\r')" \
            "branch:$(printf 'a\nstatus: approved')" "branch:$(printf 'a\rb')" "status:$(printf 'pending\nstatus: approved')"; do
  cp "$P" "$SB/orig"
  run "$PS" set "$P" "${pair%%:*}" "${pair#*:}"
  assert_eq "$CODE" "2" "set ${pair%%:*} with newline/CR"
  assert_same "$P" "$SB/orig" "plan after refused ${pair%%:*}"
done
run "$PS" check "$P"; assert_eq "$OUT" "PENDING" "still pending"

t "set refuses a real-newline pr and a literal backslash-n branch"
cp "$P" "$SB/orig"
run "$PS" set "$P" pr $'https://x\nstatus: approved'; assert_eq "$CODE" "2" "newline pr"
run "$PS" set "$P" pr 'https://x\nstatus: approved'; assert_eq "$CODE" "2" "backslash-n pr with a space"
run "$PS" set "$P" branch 'a\nstatus: approved';     assert_eq "$CODE" "2" "backslash-n branch"
run "$PS" set "$P" branch 'a\nb';                    assert_eq "$CODE" "2" "backslash-n branch, no space"
assert_same "$P" "$SB/orig" "plan after refused values"

t "set pr and branch charset rules"
for v in 'http://x' 'https://' 'ftp://x' 'https://x y' 'javascript:alert(1)'; do
  run "$PS" set "$P" pr "$v"; assert_eq "$CODE" "2" "pr [$v]"
done
for v in 'a b' 'a;b' 'a$b' 'a`b' '-x ' 'a\b'; do
  run "$PS" set "$P" branch "$v"; assert_eq "$CODE" "2" "branch [$v]"
done
run "$PS" set "$P" branch feature/PROJ-1_x.y; assert_eq "$CODE" "0" "valid branch"
run "$PS" set "$P" pr https://example.org/pr/2?x=1; assert_eq "$CODE" "0" "valid pr"
run "$PS" set "$P" branch ''; assert_eq "$CODE" "0" "empty branch clears it"
run "$PS" set "$P" pr '';     assert_eq "$CODE" "0" "empty pr clears it"
assert_eq "$("$PS" get "$P" branch)" "" "branch cleared"

t "set passes values to awk without expanding backslashes (ENVIRON, not -v)"
mk I
run "$PS" set "$P" pr 'https://x\nfoo:bar\tbaz'
assert_eq "$CODE" "0" "exit"
assert_eq "$("$PS" get "$P" pr)" 'https://x\nfoo:bar\tbaz' "stored literally"
assert_eq "$(awk '/^-->/ {print NR; exit}' "$P")" "8" "header is still 8 lines"
assert_eq "$(grep -c '^foo:' "$P")" "0" "no injected header line"
run "$PS" check "$P"; assert_eq "$OUT" "PENDING" "still pending"

# ---- SF-1: duplicate header fields -------------------------------------------------------

t "a second status: line in the header -> STALE (11), not RUNNABLE"
mk D; P=plans/D.plan.md
# the forgery: an approved line above the real (pending) one; the first match used to win
awk '/^status:/ && !d {print "status: approved"; d=1} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" check "$P"
assert_eq "$OUT/$CODE" "STALE/11"
assert_contains "$ERR" "duplicate header field" "message"
assert_contains "$ERR" "re-stamp and re-approve" "message"
run "$PS" set "$P" status executing
assert_eq "$CODE" "2" "set executing on a tampered header"

t "a second plan_hash: line in the header -> STALE (11)"
mk D; approve "$P"
awk '/^plan_hash:/ && !d {print "plan_hash: sha256:0"; d=1} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" check "$P"
assert_eq "$OUT/$CODE" "STALE/11"
assert_contains "$ERR" "duplicate header field" "message"

t "status: and plan_hash: lines in the BODY are not header duplicates"
{ body; printf 'status: draft\nplan_hash: sha256:0\n'; } > plans/D.plan.md
"$PS" stamp "$P" >/dev/null; approve "$P"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "RUNNABLE/0"

t "re-stamp clears a duplicated header"
mk D
awk '/^status:/ && !d {print "status: approved"; d=1} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" stamp "$P"; assert_eq "$CODE" "0" "stamp exit"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "PENDING/10"

# ---- SF-7: stamp must never eat the plan --------------------------------------------------

t "stamp refuses a header with no closing --> at column 0 (exit 3) and writes nothing"
printf '<!-- asdlc\nticket: PROJ-3\nstatus: approved\n  -->\n# the plan\n1. keep me\n' > plans/U1.plan.md
printf '<!-- asdlc\nticket: PROJ-3\nstatus: approved\n# the plan, header never closed\n' > plans/U2.plan.md
printf '<!-- jira-run:approval\nticket: PROJ-3\n# legacy, never closed\n' > plans/U3.plan.md
for f in U1 U2 U3; do
  cp "plans/$f.plan.md" "$SB/orig"
  run "$PS" stamp "plans/$f.plan.md"
  assert_eq "$CODE" "3" "$f exit"
  assert_contains "$ERR" "header block not closed" "$f message"
  assert_same "plans/$f.plan.md" "$SB/orig" "$f plan after refused stamp"
done

t "stamp refuses an empty or whitespace-only body (exit 3) and writes nothing"
: > plans/E1.plan.md
printf '  \n\t\n\n' > plans/E2.plan.md
printf '<!-- asdlc\nticket: PROJ-4\nstatus: approved\nplan_hash: sha256:0\n-->\n' > plans/E3.plan.md
printf '<!-- asdlc\nticket: PROJ-4\nstatus: approved\n-->\n \n\t\n' > plans/E4.plan.md
for f in E1 E2 E3 E4; do
  cp "plans/$f.plan.md" "$SB/orig"
  run "$PS" stamp "plans/$f.plan.md"
  assert_eq "$CODE" "3" "$f exit"
  assert_contains "$ERR" "empty plan body" "$f message"
  assert_same "plans/$f.plan.md" "$SB/orig" "$f plan after refused stamp"
done

t "a refused stamp leaves no temp files behind"
mkdir "$SB/tmp"
TMPDIR="$SB/tmp" "$PS" stamp plans/E1.plan.md >/dev/null 2>&1
TMPDIR="$SB/tmp" "$PS" stamp plans/U1.plan.md >/dev/null 2>&1
assert_eq "$(ls "$SB/tmp" | wc -l | tr -d ' ')" "0" "temp files left in TMPDIR"

# ---- legacy marker ------------------------------------------------------------------------

t "the legacy in-repo marker still checks, sets and resets"
for marker in '<!-- jira-run:approval'; do
  { echo "$marker"; echo "ticket: PROJ-9"; echo "status: approved"
    echo "plan_hash: sha256:$(bodyhash)"; echo "branch:"; echo "pr:"
    echo "updated: 2026-01-01T00:00:00Z"; echo "-->"; body; } > plans/PROJ-9.plan.md
  run "$PS" check plans/PROJ-9.plan.md; assert_eq "$OUT" "RUNNABLE" "$marker check"
  "$PS" set plans/PROJ-9.plan.md status executing >/dev/null
  assert_eq "$("$PS" get plans/PROJ-9.plan.md status)" "executing" "$marker set"
  assert_eq "$(head -n1 plans/PROJ-9.plan.md)" "$marker" "$marker kept by set"
  "$PS" reset-executing plans/PROJ-9.plan.md >/dev/null
  run "$PS" check plans/PROJ-9.plan.md; assert_eq "$OUT" "RUNNABLE" "$marker reset-executing"
  "$PS" stamp plans/PROJ-9.plan.md >/dev/null
  assert_eq "$(head -n1 plans/PROJ-9.plan.md)" "<!-- asdlc" "$marker upgraded by stamp"
  assert_eq "$("$PS" get plans/PROJ-9.plan.md plan_hash)" "sha256:$(bodyhash)" "$marker same hash"
done

finish
