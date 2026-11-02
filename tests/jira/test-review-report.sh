#!/usr/bin/env bash
# review-report.sh: the "Human must read" section parsed to JSON, fail-closed cases, the skim
# check against the diff, and the prompt hygiene for the five review agents.
. "$(dirname "$0")/helpers.sh"
RR="$SHARED/review-report.sh"; FX="$FIXTURES/review-report"; P="$ROOT/plugins/asdlc"

t "high: rows, distinct reasons, no why text"
run "$RR" must-read "$FX/high.md"
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '{tier, reasons, skim, warnings}')" \
  '{"tier":"high","reasons":["migration","api-contract"],"skim":null,"warnings":[]}' "summary"
assert_eq "$(printf '%s' "$OUT" | jq -c '.rows[0], .rows[1]')" \
  "$(printf '%s\n%s' '{"n":1,"file":"app/migrations/0002_add_col.py","start":1,"end":30,"reason":"migration"}' \
     '{"n":2,"file":"app/api/views.py","start":40,"end":58,"reason":"api-contract"}')" "rows (backticks read through)"
assert_eq "$(printf '%s' "$OUT" | jq '.rows | length')" "4" "row count"
assert_not_contains "$OUT" "SECRET-WHY" "why text"; assert_not_contains "$ERR" "SECRET-WHY" "why text on stderr"

t "a one-line hunk (path:line) reads as line-line"
sandbox
printf '## Human must read\nRisk tier: high\n| # | Hunk | Reason | Why |\n|---|---|---|---|\n| 1 | `app/settings.py:7` | env-config | x |\n' > "$SB/one-line.md"
run "$RR" must-read "$SB/one-line.md"
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '.rows[0]')" '{"n":1,"file":"app/settings.py","start":7,"end":7,"reason":"env-config"}' "row"

t "normal: only other rows"
run "$RR" must-read "$FX/normal.md"
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '{tier, reasons, skim}')" '{"tier":"normal","reasons":[],"skim":null}'
assert_not_contains "$OUT" "SECRET-WHY" "why text"

t "skim: no rows, the claim reported"
run "$RR" must-read "$FX/skim-docs.md"
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '{tier, reasons, rows, skim}')" '{"tier":"skim","reasons":[],"rows":[],"skim":"docs-only"}'
run "$RR" must-read "$FX/skim-tests.md"
assert_eq "$(printf '%s' "$OUT" | jq -r '.skim')" "tests-only"

t "fail closed: exit 3, tier high, a warning, no why text"
failcase() {  # <fixture> <warning fragment>
  run "$RR" must-read "$FX/$1.md"
  assert_eq "$CODE" "3" "$1 exit"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "high" "$1 tier"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.warnings[0]')" "$2" "$1 warning"
  assert_eq "$(printf '%s' "$OUT" | jq -c '.rows')" "[]" "$1 rows"
}
failcase bad-no-section          "no '## Human must read' section"
failcase bad-unknown-reason      "unknown reason"
failcase bad-six-rows            "more than 5 rows"
failcase bad-hunk                "malformed hunk"
failcase bad-hunk-range          "malformed hunk range"
failcase bad-hunk-path           "malformed hunk path"
failcase bad-high-only-other     "tier high"
failcase bad-normal-with-reason  "tier normal"
failcase bad-skim-with-rows      "tier skim but the table has rows"
failcase bad-skim-no-line        "Skim OK"
failcase bad-no-tier             "Risk tier"
failcase bad-unknown-tier        "unknown risk tier"
failcase bad-high-no-rows        "tier high"
run "$RR" must-read "$FX/does-not-exist.md"
assert_eq "$CODE" "3" "missing report"; assert_contains "$OUT" "report not found"
run "$RR" must-read "$FX"
assert_eq "$CODE" "3" "a directory is not a report"
assert_not_contains "$(run "$RR" must-read "$FX/bad-unknown-reason.md"; echo "$OUT")" "vibes" "an unknown reason is not echoed"

t "usage errors exit 2"
run "$RR"; assert_eq "$CODE" "2" "no args"
run "$RR" nope x; assert_eq "$CODE" "2" "unknown command"
run "$RR" must-read; assert_eq "$CODE" "2" "no report"
run "$RR" must-read "$FX/high.md" --diff main; assert_eq "$CODE" "2" "--diff needs two refs"
run "$RR" must-read "$FX/high.md" --diff --output=x HEAD; assert_eq "$CODE" "2" "option-like base"
run "$RR" must-read "$FX/high.md" --diff main --output=x; assert_eq "$CODE" "2" "option-like head"

t "--diff: skim holds when only docs and tests changed"
sandbox
echo base > README.md; git add -A; git commit -qm base; git checkout -qb feature
mkdir -p docs tests/unit web/__tests__; echo a > docs/guide.rst; echo b > tests/unit/x.py
echo c > web/__tests__/a.js; echo d > NOTES.txt; echo e > src_test.go; echo f > a.spec.ts; echo g > test_b.py
git add -A; git commit -qm docs
run "$RR" must-read "$FX/skim-docs.md" --diff main feature
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '{tier, skim, warnings}')" '{"tier":"skim","skim":"docs-only","warnings":[]}'

t "--diff: skim becomes normal when a changed path is not docs or tests"
echo code > app.py; git add -A; git commit -qm code
run "$RR" must-read "$FX/skim-docs.md" --diff main feature
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '{tier, reasons, rows, skim}')" '{"tier":"normal","reasons":[],"rows":[],"skim":null}'
assert_contains "$(printf '%s' "$OUT" | jq -r '.warnings[0]')" "not docs or tests"
run "$RR" must-read "$FX/skim-tests.md" --diff main feature
assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "normal" "tests-only claim too"

t "--diff: a skim claim that cannot be checked becomes normal; other tiers are untouched"
run "$RR" must-read "$FX/skim-docs.md" --diff main no-such-branch
assert_eq "$CODE" "0" "exit"; assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "normal"
assert_contains "$(printf '%s' "$OUT" | jq -r '.warnings[0]')" "could not be checked"
run "$RR" must-read "$FX/high.md" --diff main feature
assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "high" "high stays high"
run "$RR" must-read "$FX/normal.md" --diff main feature
assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "normal" "normal stays normal"

t "hygiene: the five review agents name the section, the chair names the cap"
for a in pr-review-chair pr-reviewer; do
  assert_contains "$(cat "$P/agents/$a.md")" "## Human must read" "$a names the section heading"
done
for a in security architecture correctness; do
  assert_contains "$(cat "$P/agents/pr-reviewer-$a.md")" "## Human-must-read candidates" "$a names the candidates heading"
done
assert_contains "$(cat "$P/agents/pr-review-chair.md")" "At most 5 rows" "chair names the 5-row cap"
assert_contains "$(cat "$P/agents/pr-reviewer.md")" "At most 5 rows" "solo reviewer names the 5-row cap"
assert_contains "$(cat "$P/commands/review-pr.md")" "--id" "review-pr parses --id"

t "a comma in a hunk path fails closed"
printf '# R\n\n## Human must read\nRisk tier: high\n| # | Hunk | Reason | Why |\n|---|---|---|---|\n| 1 | app/a,b.py:1-2 | migration | x |\n' > "$SB/comma.md"
run "$RR" must-read "$SB/comma.md"
assert_eq "$CODE" "3" "exit"; assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "high" "tier high"
assert_contains "$(printf '%s' "$OUT" | jq -r '.warnings[0]')" "malformed hunk path" "warning"; assert_eq "$(printf '%s' "$OUT" | jq -c .rows)" "[]" "no rows"

t "--diff: a rename into docs/ or tests/ does not hide the old path (skim is normal)"
for dest in docs tests; do
  sandbox
  mkdir -p app; seq 1 30 > app/old.py; echo base > README.md; git add -A; git commit -qm base; git checkout -qb feature
  mkdir -p "$dest"; git mv app/old.py "$dest/old.py"; git commit -qm "move into $dest"
  run "$RR" must-read "$FX/skim-docs.md" --diff main feature
  assert_eq "$(printf '%s' "$OUT" | jq -r '.tier')" "normal" "rename into $dest/"
  assert_contains "$(printf '%s' "$OUT" | jq -r '.warnings[0]')" "not docs or tests" "warning for $dest/"
done

finish
