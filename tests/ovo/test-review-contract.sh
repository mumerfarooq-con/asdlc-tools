#!/usr/bin/env bash
# The Ovo review report keeps asdlc's "Human must read" contract (D-O9): asdlc's own
# review-report.sh must-read reads an Ovo report and gives the JSON shape it gives for an asdlc
# report. Ovo never runs review-report.sh itself (critic 1); this test does.
. "$(dirname "$0")/helpers.sh"
RR="$ROOT/plugins/asdlc/scripts/review-report.sh"
OVO_REPORT="$ROOT/tests/ovo/fixtures/review/report.md"
ASDLC_REPORT="$ROOT/tests/jira/fixtures/review-report/high.md"

t "asdlc's parser reads an Ovo report: exit 0, tier, reasons, rows"
run "$RR" must-read "$OVO_REPORT"
assert_eq "$CODE" "0" "exit"
assert_eq "$(printf '%s' "$OUT" | jq -c '{tier, reasons, skim, warnings}')" \
  '{"tier":"high","reasons":["billing","authz","env-config"],"skim":null,"warnings":[]}' "summary"
assert_eq "$(printf '%s' "$OUT" | jq -c '.rows')" \
  '[{"n":1,"file":"app/refunds.py","start":10,"end":20,"reason":"billing"},{"n":2,"file":"app/refunds.py","start":12,"end":12,"reason":"authz"},{"n":3,"file":"app/settings.py","start":5,"end":9,"reason":"env-config"}]' "rows"
assert_not_contains "$OUT" "refunds move money" "no why text"

t "the same JSON shape as an asdlc report"
shape() { printf '%s' "$1" | jq -c '[keys, (.rows[0] | keys), (.reasons | type), (.warnings | type)]'; }
ovo="$OUT"; run "$RR" must-read "$ASDLC_REPORT"; assert_eq "$CODE" "0" "asdlc fixture exit"
assert_eq "$(shape "$ovo")" "$(shape "$OUT")" "keys and types"

t "the Ovo report's findings are numbered 1..n across severities"
assert_eq "$(grep -oE '^[0-9]+\. \*\*(BLOCKER|MAJOR|MINOR)\*\*' "$OVO_REPORT" | cut -d. -f1 | tr '\n' ' ')" "1 2 3 " "numbering"

finish
