#!/usr/bin/env bash
# plan-state.sh: header block, hash binding, states, transitions, injection, legacy markers.
. "$(dirname "$0")/helpers.sh"
PS="$SHARED/plan-state.sh"

body() { printf '# PROJ-1: plan\n\n## Changes\n1. do it\n'; }
bodyhash() { body | shasum -a 256 | awk '{print $1}'; }
# stamp appends a blank line, the progress line and "## Progress"; the hash covers the body
# plus that blank line, i.e. everything above the progress line.
PROGRESS='<!-- asdlc:progress -->'
# plan_hash is sha256("asdlc-plan-v2\n" + approved part), computed here independently.
approvedhash() { { printf 'asdlc-plan-v2\n'; body; echo; } | shasum -a 256 | awk '{print $1}'; }
stamped_body() { body; echo; echo "$PROGRESS"; echo "## Progress"; }
# Edit the approved part: insert a line just above the progress line (or append if none).
edit_approved() {  # <plan> <line>
  L="$2" awk -v p="$PROGRESS" '!done && index($0, p) == 1 {print ENVIRON["L"]; done=1} {print} END {if (!done) print ENVIRON["L"]}' \
    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
log_progress() { printf '%s\n' "$2" >> "$1"; }  # <plan> <line>: what an agent appends during a run

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
assert_eq "$("$PS" get plans/PROJ-1.plan.md plan_hash)" "sha256:$(approvedhash)" "hash of the approved part"
assert_eq "$(sed '1,/^-->$/d' plans/PROJ-1.plan.md)" "$(stamped_body)" "body kept, progress section added"

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

t "editing the body after approval -> EDITED (11)"
edit_approved plans/PROJ-1.plan.md "2. sneak in"
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "EDITED/11"
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
mk T; approve "$P"; edit_approved "$P" "3. sneak in"; cp "$P" "$SB/orig"
run "$PS" set "$P" status executing
assert_eq "$CODE" "2" "executing from EDITED"
assert_same "$P" "$SB/orig" "plan after refused executing from EDITED"

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
edit_approved "$P" "- [x] task 1 (ticked inside the approved part)"; cp "$P" "$SB/orig"
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

t "a second status: line in the header -> EDITED (11), not RUNNABLE"
mk D; P=plans/D.plan.md
# the forgery: an approved line above the real (pending) one; the first match used to win
awk '/^status:/ && !d {print "status: approved"; d=1} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" check "$P"
assert_eq "$OUT/$CODE" "EDITED/11"
assert_contains "$ERR" "duplicate header field" "message"
assert_contains "$ERR" "re-stamp and re-approve" "message"
run "$PS" set "$P" status executing
assert_eq "$CODE" "2" "set executing on a tampered header"

t "a second plan_hash: line in the header -> EDITED (11)"
mk D; approve "$P"
awk '/^plan_hash:/ && !d {print "plan_hash: sha256:0"; d=1} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" check "$P"
assert_eq "$OUT/$CODE" "EDITED/11"
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
  assert_eq "$("$PS" get plans/PROJ-9.plan.md plan_hash)" "sha256:$(approvedhash)" "$marker re-stamped over the approved part"
done

# ---- The progress log: outside the approval hash, so a crashed run can resume ----------

t "progress logged below the progress line keeps the plan RUNNABLE"
mk G; P=plans/G.plan.md; approve "$P"
log_progress "$P" "- Task 1: DONE — files a.py"
log_progress "$P" "- Task 1: TEST: PASS (3 tests)"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "RUNNABLE/0"

t "a crash after progress: reset-executing restores the approval"
mk G; approve "$P"; "$PS" set "$P" status executing >/dev/null
log_progress "$P" "- Task 1: DONE — files a.py"
run "$PS" reset-executing "$P"
assert_eq "$CODE" "0" "exit"; assert_status "$P" approved
run "$PS" check "$P"; assert_eq "$OUT" "RUNNABLE" "after reset"
assert_contains "$(cat "$P")" "- Task 1: DONE — files a.py" "progress kept"

t "a task edited above the progress line still invalidates the approval"
mk G; approve "$P"; edit_approved "$P" "### Task 9: something new"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "EDITED/11"

t "a second progress line is tampering: check says EDITED, stamp refuses"
mk G; approve "$P"; edit_approved "$P" "$PROGRESS"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "EDITED/11"
assert_contains "$ERR" "more than one" "message"
cp "$P" "$SB/orig"
run "$PS" stamp "$P"
assert_eq "$CODE" "3" "stamp exit"; assert_same "$P" "$SB/orig" "plan after refused stamp"

t "re-stamp keeps one progress section but empties what it logged (MF-2)"
mk G; log_progress "$P" "- Task 1: TEST PASS — ok"; log_progress "$P" "- Task 2: EXECUTOR DONE — x"
run "$PS" stamp "$P"
assert_eq "$CODE" "0" "exit"
assert_contains "$ERR" "dropped 2 progress log line(s)" "stderr"
assert_eq "$(grep -c "^$PROGRESS" "$P")" "1" "one progress line"
assert_not_contains "$(cat "$P")" "TEST PASS" "log emptied"
assert_eq "$(sed '1,/^-->$/d' "$P")" "$(stamped_body)" "body, canonical line, empty section"
assert_eq "$("$PS" get "$P" plan_hash)" "sha256:$(approvedhash)" "same approved hash"
mk G; run "$PS" stamp "$P"
assert_eq "$ERR" "" "no drop message for an empty log"

t "the stored hash is the v2 hash of the approved part"
mk G
want="$({ printf 'asdlc-plan-v2\n'; sed '1,/^-->$/d' "$P" | awk -v p="$PROGRESS" '$0==p {exit} {print}'; } | shasum -a 256 | awk '{print $1}')"
assert_eq "$("$PS" get "$P" plan_hash)" "sha256:$want" "v2 hash"
legacy="$(sed '1,/^-->$/d' "$P" | awk -v p="$PROGRESS" '$0==p {exit} {print}' | shasum -a 256 | awk '{print $1}')"
[ "$("$PS" get "$P" plan_hash)" != "sha256:$legacy" ] && ok || nok "hash is still the legacy form"

t "MF-1: first stamp refuses a progress line already in the body (fenced, plain, CRLF)"
for kind in fenced plain crlf indented; do
  case "$kind" in
    fenced)   { body; printf '```\n%s\n```\n3. below\n' "$PROGRESS"; } > plans/M.plan.md ;;
    plain)    { body; printf '%s\n3. below\n' "$PROGRESS"; } > plans/M.plan.md ;;
    crlf)     { body; printf '%s\r\n## Progress\r\n' "$PROGRESS"; } > plans/M.plan.md ;;
    indented) { body; printf '  %s \n3. below\n' "$PROGRESS"; } > plans/M.plan.md ;;
  esac
  cp plans/M.plan.md "$SB/orig"
  run "$PS" stamp plans/M.plan.md
  assert_eq "$CODE" "3" "$kind exit"
  assert_contains "$ERR" "stamp adds the progress line itself" "$kind message"
  assert_same plans/M.plan.md "$SB/orig" "$kind plan after refused stamp"
done

t "MF-1: re-stamp with the line followed by something other than ## Progress -> exit 3, unchanged"
mk G; { sed '/^## Progress$/,$d' "$P"; printf '## Tasks\n- Task 1: a\n'; } > "$P.tmp" && mv "$P.tmp" "$P"; cp "$P" "$SB/orig"
run "$PS" stamp "$P"
assert_eq "$CODE" "3" "exit"; assert_contains "$ERR" "## Progress" "message"
assert_same "$P" "$SB/orig" "plan after refused re-stamp"
mk G; { sed '/^## Progress$/,$d' "$P"; printf '\n\n## Progress\n- Task 1: TEST PASS\n'; } > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" stamp "$P"; assert_eq "$CODE" "0" "blank lines before the heading are fine"

t "probe: stamp, approve, then a fenced progress line mid-plan hides an edited task -> not RUNNABLE"
mk G; approve "$P"
awk '/^2\. |^1\. do it/ && !d {print; print "```"; print "'"$PROGRESS"'"; print "```"; d=1; next} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
printf '3. sneak in below the fake line\n' > "$SB/add"
awk -v add="$(cat "$SB/add")" '{print} /^```$/ {c++; if (c==2) print add}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
run "$PS" check "$P"
assert_eq "$OUT/$CODE" "EDITED/11" "state"
run "$PS" set "$P" status executing; assert_eq "$CODE" "2" "executing refused"

t "SF-1: a legacy approved plan (no line, plain body hash) is RUNNABLE; with the line and a new task it is EDITED"
{ echo "<!-- asdlc"; echo "ticket: PROJ-8"; echo "status: approved"
  echo "plan_hash: sha256:$(bodyhash)"; echo "branch:"; echo "pr:"
  echo "updated: 2026-01-01T00:00:00Z"; echo "-->"; body; } > plans/L.plan.md
run "$PS" check plans/L.plan.md; assert_eq "$OUT/$CODE" "RUNNABLE/0" "legacy"
{ echo "3. appended task"; echo "$PROGRESS"; echo "## Progress"; } >> plans/L.plan.md
run "$PS" check plans/L.plan.md; assert_eq "$OUT/$CODE" "EDITED/11" "legacy plan that gained a line"
sed 's/^3\. appended task$//' plans/L.plan.md > plans/L2.plan.md
run "$PS" check plans/L2.plan.md; assert_eq "$OUT" "EDITED" "even without a new task the v2 hash differs"

t "N-1: executing + duplicated progress line (EDITED): set failed works, executing does not"
mk G; approve "$P"; "$PS" set "$P" status executing >/dev/null
edit_approved "$P" "$PROGRESS"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "EDITED/11"
assert_contains "$ERR" "delete the extra" "message"
assert_not_contains "$ERR" "re-stamp" "message no longer says re-stamp"
run "$PS" set "$P" status failed; assert_eq "$CODE" "0" "failed from executing+EDITED"
mk G; approve "$P"; edit_approved "$P" "$PROGRESS"
run "$PS" set "$P" status failed; assert_eq "$CODE" "2" "failed from approved+EDITED still refused"

t "stamp refuses a plan whose approved part is empty"
printf '<!-- asdlc\nticket: PROJ-4\nstatus: approved\n-->\n%s\n%s\n- Task 1: DONE\n' "$PROGRESS" "## Progress" > plans/E.plan.md; cp plans/E.plan.md "$SB/orig"
run "$PS" stamp plans/E.plan.md
assert_eq "$CODE" "3" "exit"; assert_contains "$ERR" "empty plan body"
assert_same plans/E.plan.md "$SB/orig" "plan after refused stamp"

# ---- M2: new statuses, ID resolution, validate, approve, replan, progress ------------------

t "new statuses map to their word and exit code, and set allows them from any state"
mk N; P=plans/N.plan.md
for pair in stale/STALE/17 needs-info/NEEDS_INFO/18 blocked/BLOCKED/19; do
  human_status "$P" "${pair%%/*}"
  run "$PS" check "$P"; assert_eq "$OUT/$CODE" "${pair#*/}" "status ${pair%%/*}"
done
for v in stale needs-info blocked; do
  for s in pending approved executing done failed skip; do
    mk N; human_status "$P" "$s"
    run "$PS" set "$P" status "$v"
    assert_eq "$CODE" "0" "$v from $s"
    assert_status "$P" "$v" "status $v from $s"
  done
done

t "a bare ID and a path give the same result; a bad bare ID is refused"
mk PROJ-5; P=plans/PROJ-5.plan.md
for c in check get validate progress; do
  case "$c" in get) a="status" ;; *) a="" ;; esac
  run "$PS" $c PROJ-5 $a; o1="$OUT/$CODE/$ERR"
  run "$PS" $c "$P" $a;   o2="$OUT/$CODE/$ERR"
  assert_eq "$o1" "$o2" "$c by id vs path"
done
run "$PS" check 'PROJ 5'; assert_eq "$CODE" "2" "bad bare id"
run "$PS" check '-x';     assert_eq "$CODE" "2" "bare id with a leading dash"
run "$PS" check nope.md;  assert_eq "$OUT/$CODE" "MISSING/16" "a .md argument is a path"

# A complete, valid plan body. vbody <open-questions block>; vplan <ID> [block] writes the file.
vbody() {
  cat <<EOF
# PROJ-7: widget

## Goal
Let users export widgets.

## Context used
- ticket description

## What else uses this
| # | Where | Verdict | Why |
|---|-------|---------|-----|
| 1 | api/export.py:10 | needs change | reads the flag |

## Must still work
- An admin can still list widgets.

## Changes
### Task 1: add export
Goal: do it
Files: api/export.py

## Tests
- test_export covers the flag

## Risk
- low

## Open questions
$1

## Critic notes
| # | Severity | Finding | Evidence | Planner response |
|---|----------|---------|----------|------------------|
| 1 | note | nothing missing | PROJ-7 | addressed in Changes |
EOF
}
vplan() { vbody "${2:-None}" > "plans/$1.plan.md"; }

t "validate: a complete plan is VALID (exit 0); the unsure warning is not a failure"
vplan V; run "$PS" validate V; assert_eq "$OUT/$CODE" "VALID/0" "valid"; assert_eq "$ERR" "" "no stderr"
vbody None | sed 's/needs change/unsure/' > plans/V.plan.md
run "$PS" validate V; assert_eq "$OUT/$CODE" "VALID/0" "valid with unsure"
assert_contains "$ERR" 'warn: 1 row(s) in "What else uses this" marked unsure' "warning"

t "validate: a stamped plan is checked above the progress line only"
vplan V; "$PS" stamp plans/V.plan.md >/dev/null
printf '%s\n' '## Goal' '' >> plans/V.plan.md     # junk below the line must not matter
run "$PS" validate V; assert_eq "$OUT/$CODE" "VALID/0" "stamped, valid"

t "validate: each rule fails INVALID (20) and names its section"
for sec in "Goal" "Context used" "What else uses this" "Must still work" "Changes" "Tests" "Risk" "Open questions" "Critic notes"; do
  vbody None | awk -v h="## $sec" '$0==h {skip=1; next} /^## / {skip=0} !skip {print}' > plans/X.plan.md
  run "$PS" validate X
  assert_eq "$OUT/$CODE" "INVALID/20" "missing $sec"
  assert_contains "$ERR" "$sec: missing section" "missing $sec"
done
vbody None | sed 's/^## Goal$/## GOAL/' > plans/X.plan.md
run "$PS" validate X; assert_eq "$OUT" "VALID" "headings are case-insensitive"
vbody None | sed 's/^Let users export widgets\.$/<describe the goal>/' > plans/X.plan.md
run "$PS" validate X; assert_contains "$ERR" "Goal: section is empty" "placeholder-only Goal"
vbody None | sed '/^- An admin can still/d' > plans/X.plan.md
run "$PS" validate X; assert_contains "$ERR" "Must still work: section is empty" "empty Must still work"
vbody None | sed '/^### Task 1/d;/^Goal: do it/d;/^Files: api/d' > plans/X.plan.md
run "$PS" validate X; assert_contains "$ERR" "Changes: section is empty" "empty Changes"
vbody None | sed '/^- test_export/d' > plans/X.plan.md
run "$PS" validate X; assert_contains "$ERR" "Tests: section is empty" "empty Tests"
vbody None | sed 's/^### Task 1: add export/Do the export./' > plans/X.plan.md
run "$PS" validate X; assert_eq "$OUT/$CODE" "INVALID/20" "no Task heading"
assert_contains "$ERR" 'Changes: no "### Task <n>" heading' "no Task heading"
vbody None | sed '/^| 1 | api\/export.py/d' > plans/X.plan.md
run "$PS" validate X; assert_contains "$ERR" "What else uses this: no table rows" "no usage rows"
vbody None | sed 's/^| 1 | api\/export.py.*$/No other uses found./' | sed '/^|---/d;/^| # | Where/d' > plans/X.plan.md
run "$PS" validate X; assert_contains "$ERR" "What else uses this: says" "No other uses found without impact.md"
mkdir -p plans/X; echo "# Impact scan: X" > plans/X/impact.md
run "$PS" validate X; assert_eq "$OUT/$CODE" "VALID/0" "No other uses found with impact.md"
rm -rf plans/X

t "validate: open questions (unchecked, checked without an answer, answered, None)"
vplan X '- [ ] Which format?'; run "$PS" validate X
assert_eq "$OUT/$CODE" "INVALID/20" "unchecked"; assert_contains "$ERR" "Open questions: unanswered: Which format?" "unchecked"
vplan X '- [x] Which format?'; run "$PS" validate X
assert_eq "$OUT/$CODE" "INVALID/20" "checked, no answer"; assert_contains "$ERR" "Open questions: checked but no" "checked, no answer"
assert_contains "$ERR" "Which format?" "names the question"
vplan X '- [x] Which format? -> Answer: CSV'; run "$PS" validate X; assert_eq "$OUT/$CODE" "VALID/0" "answered"

t "validate: critic blockers need a Planner response, and a disagree needs human accepted:"
crit() {  # <planner response>
  vbody None | sed "s/^| 1 | note | nothing missing | PROJ-7 | addressed in Changes |/| 1 | blocker | breaks export | api\/export.py:10 | $1 |/" > plans/X.plan.md
}
crit ''; run "$PS" validate X
assert_eq "$OUT/$CODE" "INVALID/20" "blocker, empty response"; assert_contains "$ERR" "Critic notes: blocker row 1 has no Planner response" "empty"
crit 'disagree: not an issue'; run "$PS" validate X
assert_eq "$OUT/$CODE" "INVALID/20" "blocker, disagree"; assert_contains "$ERR" "Critic notes: blocker row 1 is disagreed with" "disagree"
crit 'disagree: not an issue. human accepted: owner agrees'; run "$PS" validate X
assert_eq "$OUT/$CODE" "VALID/0" "blocker, human accepted"
crit 'addressed in Changes'; run "$PS" validate X; assert_eq "$OUT/$CODE" "VALID/0" "blocker, addressed"

# ---- approve --------------------------------------------------------------------------------

t "approve: answering the open questions, then approving, recomputes the hash and makes the plan RUNNABLE"
vplan A '- [ ] Which format?'; "$PS" stamp plans/A.plan.md >/dev/null; P=plans/A.plan.md
old="$("$PS" get "$P" plan_hash)"
cp "$P" "$SB/orig"; run "$PS" approve A
assert_eq "$CODE" "20" "refused while a question is open"; assert_contains "$OUT" "INVALID" "says INVALID"
assert_contains "$ERR" "Open questions: unanswered" "names the question"
assert_same "$P" "$SB/orig" "invalid plan after refused approve"
sed 's/^- \[ \] Which format?/- [x] Which format? -> Answer: CSV/' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
log_progress "$P" "- Task 1: EXECUTOR DONE — earlier note"
progress_before="$(sed -n '/^<!-- asdlc:progress -->/,$p' "$P")"
run "$PS" approve A
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "approved A (sha256:" "message"
assert_status "$P" approved
[ "$("$PS" get "$P" plan_hash)" != "$old" ] && ok || nok "hash not recomputed"
run "$PS" check "$P"; assert_eq "$OUT/$CODE" "RUNNABLE/0" "after approve"
assert_eq "$(sed -n '/^<!-- asdlc:progress -->/,$p' "$P")" "$progress_before" "progress section untouched"

t "approve: an approved plan edited by a human is re-approved with a new hash"
h1="$("$PS" get "$P" plan_hash)"
edit_approved "$P" "- an extra risk the human added"
run "$PS" check "$P"; assert_eq "$OUT" "EDITED" "edited"
run "$PS" approve A; assert_eq "$CODE" "0" "re-approve exit"
run "$PS" check "$P"; assert_eq "$OUT" "RUNNABLE" "runnable again"
[ "$("$PS" get "$P" plan_hash)" != "$h1" ] && ok || nok "hash unchanged after human edit"

t "approve: allowed from stale, needs-info, blocked; refused from RUNNABLE, executing, done, failed, skip"
for s in stale needs-info blocked; do
  vplan A; "$PS" stamp "$P" >/dev/null; human_status "$P" "$s"
  run "$PS" approve A; assert_eq "$CODE" "0" "from $s"
  run "$PS" check "$P"; assert_eq "$OUT" "RUNNABLE" "runnable after $s"
done
for s in approved executing done failed skip; do
  vplan A; "$PS" stamp "$P" >/dev/null
  if [ "$s" = approved ]; then "$PS" approve A >/dev/null; else human_status "$P" "$s"; fi
  cp "$P" "$SB/orig"; run "$PS" approve A
  assert_eq "$CODE" "2" "approve from $s"; assert_same "$P" "$SB/orig" "plan after refused approve from $s"
done

t "approve: a duplicated header field or progress line is not re-approvable"
vplan A; "$PS" stamp "$P" >/dev/null; "$PS" approve A >/dev/null
awk '/^status:/ && !d {print "status: approved"; d=1} {print}' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
cp "$P" "$SB/orig"; run "$PS" approve A; assert_eq "$CODE" "2" "duplicate header"; assert_same "$P" "$SB/orig" "plan"
vplan A; "$PS" stamp "$P" >/dev/null; "$PS" approve A >/dev/null; edit_approved "$P" "$PROGRESS"
cp "$P" "$SB/orig"; run "$PS" approve A; assert_eq "$CODE" "2" "duplicate progress line"; assert_same "$P" "$SB/orig" "plan"

t "approve: no header block -> 16, nothing written"
vplan A; cp "$P" "$SB/orig"; run "$PS" approve A
assert_eq "$CODE" "16" "exit"; assert_same "$P" "$SB/orig" "plan"

# ---- replan ---------------------------------------------------------------------------------

t "replan: moves the plan to .prev (replacing an older one); refused while executing"
vplan R; "$PS" stamp plans/R.plan.md >/dev/null; echo old > plans/R.plan.prev.md
cp plans/R.plan.md "$SB/orig"
run "$PS" replan R
assert_eq "$CODE" "0" "exit"; assert_contains "$OUT" "re-plan" "message"; assert_contains "$OUT" "plans/R.plan.prev.md" "names .prev"
if [ ! -e plans/R.plan.md ]; then ok; else nok "plan still in place"; fi
assert_same plans/R.plan.prev.md "$SB/orig" "moved byte-identical"
vplan R; "$PS" stamp plans/R.plan.md >/dev/null; "$PS" approve R >/dev/null; "$PS" set R status executing >/dev/null
cp plans/R.plan.md "$SB/orig"; run "$PS" replan R
assert_eq "$CODE" "2" "refused while executing"; assert_same plans/R.plan.md "$SB/orig" "plan after refused replan"
run "$PS" replan plans/nope.plan.md; assert_eq "$CODE" "2" "missing plan"

# ---- progress -------------------------------------------------------------------------------

t "progress: latest entry per task wins, non-grammar lines are ignored, ordered by task"
vplan G; "$PS" stamp plans/G.plan.md >/dev/null; P=plans/G.plan.md
log_progress "$P" "- Task 10: EXECUTOR DONE — ten"
log_progress "$P" "- Task 2: EXECUTOR DONE — two"
log_progress "$P" "- Task 2: TEST FAIL — broke"
log_progress "$P" "  - Task 2: TEST PASS — indented sub-bullet is not an entry"
log_progress "$P" "- Task 2: TEST: PASS (not the grammar)"
log_progress "$P" "- Task 1: REVIEW APPROVED — one"
log_progress "$P" "- Task 2: TEST PASS — fixed"
log_progress "$P" "- Task 3: SOMETHING ELSE — nope"
log_progress "$P" "Task 4: TEST PASS — no bullet"
run "$PS" progress G
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "Task 1: REVIEW APPROVED
Task 2: TEST PASS
Task 10: EXECUTOR DONE" "output"
vplan G; "$PS" stamp "$P" >/dev/null
run "$PS" progress G; assert_eq "$OUT/$CODE" "/0" "no entries"
vplan H; run "$PS" progress H; assert_eq "$OUT/$CODE" "/0" "no progress line"
printf -- '- Task 1: TEST PASS — above the line\n' >> plans/H.plan.md
run "$PS" progress H; assert_eq "$OUT/$CODE" "/0" "entries without a line are ignored"
vplan G; "$PS" stamp "$P" >/dev/null; log_progress "$P" "- Task 1: TEST PASS — ok"
edit_approved "$P" "- Task 7: TEST FAIL — above the line, not progress"
run "$PS" progress G; assert_eq "$OUT" "Task 1: TEST PASS" "only below the line"

finish
