#!/usr/bin/env bash
# review-record.sh: the human-review record store (add, last, parse-comment). No network.
. "$(dirname "$0")/helpers.sh"
RR="$S/review-record.sh"
SHA1=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
SHA3=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

t "add: appends a JSON line, writes the comment file, prints its path"
sandbox
run "$RR" add PROJ-1 7 "$SHA1" app/models.py:10-20 'web/[id]/page.tsx:3-3'
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "plans/PROJ-1/human-review.comment.md" "printed path"
assert_eq "$(wc -l < plans/PROJ-1/human-review.jsonl | tr -d ' ')" "1" "one line"
assert_eq "$(jq -c 'del(.at) + {at_is_int: (.at | type == "number")}' plans/PROJ-1/human-review.jsonl)" \
  "{\"v\":1,\"pr\":7,\"sha\":\"$SHA1\",\"hunks\":[\"app/models.py:10-20\",\"web/[id]/page.tsx:3-3\"],\"at_is_int\":true}" "record"
assert_eq "$(cat plans/PROJ-1/human-review.comment.md)" "$(printf '[asdlc] Human review: hunks app/models.py:10-20, web/[id]/page.tsx:3-3 at %s\nReviewed in /asdlc:review-tour. This record is written by the reviewer'"'"'s own tooling.' "$SHA1")" "comment text"
run "$RR" add PROJ-1 7 "$SHA2" b.py:1-1
assert_eq "$(wc -l < plans/PROJ-1/human-review.jsonl | tr -d ' ')" "2" "appended, not replaced"
assert_contains "$(head -1 plans/PROJ-1/human-review.comment.md)" "hunks b.py:1-1 at $SHA2" "comment file is the latest"

t "add: the comment's first line parses back to the sha"
assert_eq "$(head -1 plans/PROJ-1/human-review.comment.md | "$RR" parse-comment)" "$SHA2" "round trip"

t "add: validation refuses, and writes nothing"
sandbox
bad() {  # <what> <args...>
  local what="$1"; shift
  run "$RR" add "$@"; assert_eq "$CODE" "2" "$what"
  assert_eq "$([ -e plans ] && echo made || echo none)" "none" "$what: nothing written"
}
bad "lowercase key"          proj-1 7 "$SHA1" a.py:1-2
bad "non-numeric PR"         PROJ-1 x "$SHA1" a.py:1-2
bad "short sha"              PROJ-1 7 "${SHA1%?}" a.py:1-2
bad "41-char sha"            PROJ-1 7 "${SHA1}0" a.py:1-2
bad "uppercase sha"          PROJ-1 7 "$(printf '%s' "$SHA1" | tr a-f A-F)" a.py:1-2
bad "no hunks"               PROJ-1 7 "$SHA1"
bad "too few args"           PROJ-1 7
bad "absolute path"          PROJ-1 7 "$SHA1" /etc/passwd:1-2
bad "dot-dot"                PROJ-1 7 "$SHA1" ../x.py:1-2
bad "dot-dot inside"         PROJ-1 7 "$SHA1" a/../../x.py:1-2
bad "leading dash"           PROJ-1 7 "$SHA1" -rf:1-2
bad "no range"               PROJ-1 7 "$SHA1" a.py
bad "no end"                 PROJ-1 7 "$SHA1" a.py:5
bad "start after end"        PROJ-1 7 "$SHA1" a.py:9-2
bad "zero start"             PROJ-1 7 "$SHA1" a.py:0-2
bad "non-numeric range"      PROJ-1 7 "$SHA1" a.py:x-y
bad "space in path"          PROJ-1 7 "$SHA1" 'a b.py:1-2'
bad "comma in path"          PROJ-1 7 "$SHA1" 'a,b.py:1-2'
bad "newline in path"        PROJ-1 7 "$SHA1" "$(printf 'a\nb.py'):1-2"
bad "empty path component"   PROJ-1 7 "$SHA1" a//b.py:1-2
bad "one bad hunk of two"    PROJ-1 7 "$SHA1" a.py:1-2 ../b.py:1-2
run "$RR" add PROJ-1 7 "$SHA1" a.py:1-2 ../b.py:1-2; assert_contains "$ERR" "bad hunk '../b.py:1-2'" "names the hunk"
run "$RR" add PROJ-1 7 "$SHA1" a..b.py:1-2; assert_eq "$CODE" "0" "'..' inside a name is not a path step"

t "add: refuses a symlinked plans or plans/<KEY>, and symlinked store files"
sandbox; mkdir real; ln -s real plans
run "$RR" add PROJ-1 7 "$SHA1" a.py:1-2; assert_eq "$CODE" "2" "symlinked plans"; assert_contains "$ERR" "plans is a symlink"
assert_eq "$(ls real | wc -l | tr -d ' ')" "0" "nothing written through it"
sandbox; mkdir -p plans real; ln -s ../real plans/PROJ-1
run "$RR" add PROJ-1 7 "$SHA1" a.py:1-2; assert_eq "$CODE" "2" "symlinked plans/KEY"; assert_contains "$ERR" "symlink"
assert_eq "$(ls real | wc -l | tr -d ' ')" "0" "nothing written through it"
run "$RR" last PROJ-1; assert_eq "$CODE" "2" "last refuses it too"
sandbox; mkdir -p plans/PROJ-1; : > elsewhere; ln -s ../../elsewhere plans/PROJ-1/human-review.jsonl
run "$RR" add PROJ-1 7 "$SHA1" a.py:1-2; assert_eq "$CODE" "2" "symlinked jsonl"; assert_eq "$(wc -c < elsewhere | tr -d ' ')" "0" "target untouched"
sandbox; mkdir -p plans/PROJ-1; : > elsewhere; ln -s ../../elsewhere plans/PROJ-1/human-review.comment.md
run "$RR" add PROJ-1 7 "$SHA1" a.py:1-2; assert_eq "$CODE" "2" "symlinked comment file"; assert_eq "$(wc -c < elsewhere | tr -d ' ')" "0" "target untouched"

t "last: nothing when there is no record; newest per PR"
sandbox
run "$RR" last PROJ-1; assert_eq "$CODE/$OUT" "0/" "no store"
run "$RR" add PROJ-1 7 "$SHA1" a.py:1-2 >/dev/null
run "$RR" add PROJ-1 8 "$SHA2" a.py:1-2 >/dev/null
run "$RR" add PROJ-1 7 "$SHA3" a.py:3-4 >/dev/null
run "$RR" last PROJ-1;   assert_eq "$OUT" "$SHA3" "newest overall"
run "$RR" last PROJ-1 7; assert_eq "$OUT" "$SHA3" "newest for PR 7"
run "$RR" last PROJ-1 8; assert_eq "$OUT" "$SHA2" "PR 8"
run "$RR" last PROJ-1 9; assert_eq "$CODE/$OUT" "0/" "PR with no record"
run "$RR" last PROJ-2;   assert_eq "$CODE/$OUT" "0/" "other ticket"
run "$RR" last PROJ-1 x; assert_eq "$CODE" "2" "bad PR id"
run "$RR" last nope;     assert_eq "$CODE" "2" "bad key"
printf 'not json\n{"v":1,"pr":7,"sha":"short","hunks":[],"at":1}\n' >> plans/PROJ-1/human-review.jsonl
run "$RR" last PROJ-1 7; assert_eq "$OUT" "$SHA3" "garbage lines and bad shas are skipped"

t "parse-comment: accepts the exact format"
run "$RR" parse-comment <<<"[asdlc] Human review: hunks a.py:1-2 at $SHA1"
assert_eq "$CODE/$OUT" "0/$SHA1" "one hunk"
run "$RR" parse-comment <<<"[asdlc] Human review: hunks a.py:1-2, b/c.py:5-9 at $SHA1"
assert_eq "$CODE/$OUT" "0/$SHA1" "two hunks"
run "$RR" parse-comment < <(printf '[asdlc] Human review: hunks a.py:1-2 at %s\nReviewed in /asdlc:review-tour.\n' "$SHA1")
assert_eq "$CODE/$OUT" "0/$SHA1" "only the first line counts"
run "$RR" parse-comment < <(printf '[asdlc] Human review: hunks a.py:1-2 at %s\r\n' "$SHA1")
assert_eq "$CODE/$OUT" "0/$SHA1" "CRLF"

t "parse-comment: rejects near-misses (exit 1, no output)"
nope() {  # <what> <line>
  run "$RR" parse-comment < <(printf '%s\n' "$2"); assert_eq "$CODE/$OUT" "1/" "$1"
}
nope "short sha"            "[asdlc] Human review: hunks a.py:1-2 at ${SHA1%?}"
nope "long sha"             "[asdlc] Human review: hunks a.py:1-2 at ${SHA1}0"
nope "uppercase sha"        "[asdlc] Human review: hunks a.py:1-2 at $(printf '%s' "$SHA1" | tr a-f A-F)"
nope "trailing text"        "[asdlc] Human review: hunks a.py:1-2 at $SHA1 (trusted)"
nope "missing at"           "[asdlc] Human review: hunks a.py:1-2 $SHA1"
nope "missing hunks word"   "[asdlc] Human review: a.py:1-2 at $SHA1"
nope "no hunks"             "[asdlc] Human review: hunks  at $SHA1"
nope "no marker"            "Human review: hunks a.py:1-2 at $SHA1"
nope "leading space"        " [asdlc] Human review: hunks a.py:1-2 at $SHA1"
nope "wrong prefix"         "[asdlc] Reviewer brief: hunks a.py:1-2 at $SHA1"
nope "empty line"           ""
run "$RR" parse-comment < <(printf 'intro\n[asdlc] Human review: hunks a.py:1-2 at %s\n' "$SHA1"); assert_eq "$CODE/$OUT" "1/" "record on a later line"
run "$RR" parse-comment < /dev/null; assert_eq "$CODE/$OUT" "1/" "empty stdin"

t "hygiene: only /asdlc:review-tour records, and it asks before it posts"
RT="$(cat "$ROOT/plugins/asdlc/commands/review-tour.md")"
RTA="$(sed -n '/^allowed-tools:/p' "$ROOT/plugins/asdlc/commands/review-tour.md")"
assert_not_contains "$RTA" "review-record.sh add" "tour: add is not pre-approved"
assert_not_contains "$RTA" "bb-pr-comment" "tour: bb-pr-comment is not pre-approved"
assert_not_contains "$RTA" "review-record.sh:*" "tour: no blanket review-record.sh"
assert_contains "$RTA" "review-record.sh last:*" "tour: last is allowed"
assert_contains "$RTA" "review-report.sh" "tour: review-report is allowed"
assert_eq "$(grep -c 'bb-pr-comment.sh' "$ROOT/plugins/asdlc/commands/review-tour.md")" "1" "tour: one bb-pr-comment.sh call"
assert_contains "$(grep 'bb-pr-comment.sh' "$ROOT/plugins/asdlc/commands/review-tour.md")" "--record --file" "tour: that call has --record"
assert_contains "$RT" "STOP and wait for my answer" "tour: stops and waits"
assert_contains "$RT" "Never record a hunk the user did not answer" "tour: never records an unanswered hunk"
assert_contains "$RT" "Never approve, decline or merge" "tour: never approves"
assert_contains "$RT" "local-only" "tour: local-only scope"
assert_contains "$RT" "not the working tree" "tour: shows the head version, not the checkout"
assert_contains "$RTA" "scripts/tour-git.sh:*" "tour: the read-only git wrapper is allowed"
assert_not_contains "$RTA" "Bash(git " "tour: no bare git pre-approved"
assert_not_contains "$RTA" "review-queue.sh" "tour: review-queue.sh is not pre-approved"
assert_contains "$RT" "tour-git.sh show <branch> <path>" "tour: the head version comes from the wrapper"
assert_contains "$RT" "tour-git.sh changed <last> <branch>" "tour: the re-review filter uses the wrapper"
assert_contains "$RT" "plans/pr-review-<ID>.md" "tour: reads the report by its id"
assert_contains "$RT" "<KEY>-s<k>" "tour: a later slice has its own report id"
assert_contains "$RT" "plan-state.sh get <plan> slice" "tour: reads the slice"
assert_contains "$RT" "<file>:<start>-<end>" "tour: hunks are built from the JSON row"
assert_contains "$RT" "one command per Bash call" "tour: no compound commands"
assert_contains "$RT" "scripts/plan-state.sh get <plan> pr" "tour: plan-state.sh has its path"
assert_contains "$RT" "ask once whether I mean an" "tour: a non-answer is asked about, not checked"
for f in "$ROOT"/plugins/asdlc/commands/*.md "$ROOT"/plugins/asdlc/agents/*.md "$ROOT"/plugins/asdlc/skills/*/SKILL.md; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = review-tour.md ] && continue
  if grep -q -e '--record' "$f"; then nok "$f mentions --record"; else ok; fi
  if grep -v -i 'never' "$f" | grep -q 'review-record.sh add'; then nok "$f calls review-record.sh add"; else ok; fi
  if sed -n '/^allowed-tools:/p;/^tools:/p' "$f" | grep -q 'review-record.sh add'; then nok "$f allows review-record.sh add"; else ok; fi
done

t "round trip: every must-read row built as <file>:<start>-<end> is recorded and read back"
sandbox
for rep in high normal; do
  hunks=()
  while IFS= read -r h; do hunks+=("$h"); done < <("$SHARED/review-report.sh" must-read "$FIXTURES/review-report/$rep.md" | jq -r '.rows[] | "\(.file):\(.start)-\(.end)"')
  [ "${#hunks[@]}" -gt 0 ] && ok || nok "$rep.md has no rows"
  run "$RR" add PROJ-1 7 "$SHA1" "${hunks[@]}"; assert_eq "$CODE" "0" "$rep.md: add accepts the rows"
  assert_eq "$(head -1 plans/PROJ-1/human-review.comment.md | "$RR" parse-comment)" "$SHA1" "$rep.md: parse-comment reads it back"
  assert_eq "$(tail -n1 plans/PROJ-1/human-review.jsonl | jq -c .hunks)" "$(printf '%s\n' "${hunks[@]}" | jq -R . | jq -sc .)" "$rep.md: hunks recorded as built"
done

t "usage"
run "$RR"; assert_eq "$CODE" "2" "no subcommand"; run "$RR" bogus; assert_eq "$CODE" "2" "unknown subcommand"

finish
