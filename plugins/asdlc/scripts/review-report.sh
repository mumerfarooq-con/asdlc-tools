#!/usr/bin/env bash
# Reads the "## Human must read" section of a review report (the chair's canonical report or the
# solo reviewer's) and prints what it says as one JSON object. Never prints a row's "why" text:
# that is free text a reviewer may have copied from the PR.
#
# Usage:
#   review-report.sh must-read <report> [--diff <base> <head>]
# Prints {tier, reasons:[...], rows:[{n, file, start, end, reason}], skim, warnings:[...]}:
#   tier     high | normal | skim
#   reasons  the distinct reasons other than "other", in row order
#   skim     "docs-only" | "tests-only" | null
# The section is the heading "## Human must read", a line "Risk tier: high|normal|skim", then
# a table "| # | Hunk | Reason | Why a human must read it |" of at most 5 rows. Hunk is
# path:start-end (path:line is read as line-line). Reason is one of: migration authz irreversible billing infra concurrency
# api-contract env-config other. The tier is high if any row has a reason other than "other",
# normal if every row is "other", skim with no rows and a line "Skim OK: docs-only|tests-only".
# --diff checks a skim claim against the merge-base diff of <base>..<head>: any changed path that
# is not docs or tests turns skim into normal (with a warning).
# Fails closed: exit 3 with {tier:"high", warnings:[...]} when the report or section is missing,
# has more than 5 rows, an unknown reason, a malformed hunk, or a tier the rows contradict.
# Exit 2 = bad usage. Needs jq.
set -euo pipefail

MAX_ROWS=5
REASONS=" migration authz irreversible billing infra concurrency api-contract env-config other "

usage() { echo "usage: review-report.sh must-read <report> [--diff <base> <head>]" >&2; exit 2; }
command -v jq >/dev/null || { echo "review-report.sh: jq is required" >&2; exit 2; }

# Fail closed: print the high-tier object with one warning and exit 3.
fail() {
  jq -nc --arg w "$1" '{tier: "high", reasons: [], rows: [], skim: null, warnings: [$w]}'
  exit 3
}

trim() { local x="$1"; x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"; printf '%s' "$x"; }
# A value wrapped in backticks (models like them) is read without them.
unquote() { local x; x="$(trim "$1")"; case "$x" in \`*\`) x="${x#\`}"; x="${x%\`}" ;; esac; printf '%s' "$x"; }

[ "${1:-}" = must-read ] || usage
shift
[ $# -ge 1 ] || usage
report="$1"; shift
base=""; head=""; want_diff=0
if [ $# -gt 0 ]; then
  [ $# -eq 3 ] && [ "$1" = --diff ] || usage
  want_diff=1; base="$2"; head="$3"
  case "$base" in -*) echo "review-report.sh: invalid base ref: must not start with '-'" >&2; exit 2 ;; esac
  case "$head" in -*) echo "review-report.sh: invalid head ref: must not start with '-'" >&2; exit 2 ;; esac
fi

[ -f "$report" ] && [ -r "$report" ] || fail "report not found"
# Strip CRs so a CRLF report reads the same.
text="$(tr -d '\r' < "$report")"
heads="$(printf '%s\n' "$text" | grep -c '^## Human must read[[:space:]]*$' || true)"
[ "$heads" -ge 1 ] || fail "no '## Human must read' section"
[ "$heads" -eq 1 ] || fail "more than one '## Human must read' section"
section="$(printf '%s\n' "$text" | awk '
  f && /^## / {exit}
  f {print}
  /^## Human must read[ \t]*$/ {f=1}')"

tiers="$(printf '%s\n' "$section" | grep -c '^Risk tier:' || true)"
[ "$tiers" -eq 1 ] || fail "want exactly one 'Risk tier:' line, found $tiers"
tier="$(trim "$(printf '%s\n' "$section" | sed -n 's/^Risk tier:[[:space:]]*//p')")"
case "$tier" in high|normal|skim) ;; *) fail "unknown risk tier" ;; esac
skim=""
skims="$(printf '%s\n' "$section" | grep -c '^Skim OK:' || true)"
if [ "$skims" -gt 0 ]; then
  [ "$skims" -eq 1 ] || fail "more than one 'Skim OK:' line"
  skim="$(trim "$(printf '%s\n' "$section" | sed -n 's/^Skim OK:[[:space:]]*//p')")"
  case "$skim" in docs-only|tests-only) ;; *) fail "'Skim OK:' must say docs-only or tests-only" ;; esac
fi

# Table rows: lines starting with '|'; the header and the |---| separator are skipped.
rows_tsv=""; nrows=0; has_non_other=0; reasons=""
# path:start-end, or path:line (a one-line hunk, read as line-line: models sometimes write it).
hunk_re='^([^[:space:]]+):([0-9]{1,9})(-([0-9]{1,9}))?$'
while IFS= read -r line; do
  case "$line" in '|'*) ;; *) continue ;; esac
  IFS='|' read -r _ n hunk reason _ <<EOT
$line
EOT
  n="$(trim "$n")"
  case "$n" in '#') continue ;; esac
  if [[ $n =~ ^:?-+:?$ ]]; then continue; fi
  nrows=$((nrows + 1))
  [ "$nrows" -le "$MAX_ROWS" ] || fail "more than $MAX_ROWS rows"
  [[ $n =~ ^[0-9]{1,3}$ ]] || fail "row $nrows: the # column is not a number"
  hunk="$(unquote "$hunk")"; reason="$(unquote "$reason")"
  [[ $hunk =~ $hunk_re ]] || fail "row $nrows: malformed hunk (want path:start-end)"
  file="${BASH_REMATCH[1]}"; start=$((10#${BASH_REMATCH[2]})); end=$((10#${BASH_REMATCH[4]:-${BASH_REMATCH[2]}}))
  case "$file" in -*|/*) fail "row $nrows: malformed hunk path" ;; esac
  case "/$file/" in */../*|*/./*|*//*) fail "row $nrows: malformed hunk path" ;; esac
  [[ $file =~ [[:cntrl:]] ]] && fail "row $nrows: malformed hunk path"
  [ "$start" -ge 1 ] && [ "$end" -ge "$start" ] || fail "row $nrows: malformed hunk range"
  case "$REASONS" in *" $reason "*) ;; *) fail "row $nrows: unknown reason" ;; esac
  if [ "$reason" != other ]; then
    has_non_other=1
    case " $reasons " in *" $reason "*) ;; *) reasons="$reasons $reason" ;; esac
  fi
  rows_tsv="$rows_tsv$n	$file	$start	$end	$reason
"
done <<EOS
$section
EOS

# The tier must agree with the rows.
case "$tier" in
  skim)   [ "$nrows" -eq 0 ] || fail "tier skim but the table has rows"
          [ -n "$skim" ] || fail "tier skim needs a 'Skim OK: docs-only|tests-only' line" ;;
  high)   [ "$has_non_other" -eq 1 ] || fail "tier high but no row has a reason other than 'other'" ;;
  normal) [ "$nrows" -gt 0 ] && [ "$has_non_other" -eq 0 ] || fail "tier normal needs rows that are all 'other'" ;;
esac
if [ "$tier" != skim ] && [ -n "$skim" ]; then fail "a 'Skim OK:' line with tier $tier"; fi

warnings=""   # one warning per line
if [ "$tier" = skim ] && [ "$want_diff" -eq 1 ]; then
  # Fail closed: a skim claim that can't be checked, or that the diff contradicts, is "normal".
  not_skim=""
  mb=""; files=""
  if mb="$(git merge-base "$base" "$head" 2>/dev/null)" \
     && files="$(git diff --name-only "$mb" "$head" 2>/dev/null)"; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        *.md|*.rst|*.txt|docs/*|*/docs/*|doc/*|*/doc/*) continue ;;
        tests/*|*/tests/*|test/*|*/test/*|__tests__/*|*/__tests__/*) continue ;;
      esac
      b="${f##*/}"
      case "$b" in test_*|*_test.*|*.test.*|*.spec.*) continue ;; esac
      not_skim="x"; break
    done <<EOF2
$files
EOF2
    [ -z "$not_skim" ] || warnings="the report says skim ($skim) but the diff changes a path that is not docs or tests"
  else
    not_skim="x"; warnings="the report says skim ($skim) but the diff could not be checked"
  fi
  if [ -n "$not_skim" ]; then tier=normal; skim=""; fi
fi

reasons_json="$(printf '%s\n' $reasons | jq -R . | jq -sc 'map(select(. != ""))')"
rows_json="$(printf '%s' "$rows_tsv" | jq -Rnc '[inputs | select(. != "") | split("\t")
  | {n: (.[0] | tonumber), file: .[1], start: (.[2] | tonumber), end: (.[3] | tonumber), reason: .[4]}]')"
warn_json="$(printf '%s' "$warnings" | jq -Rnc '[inputs | select(. != "")]')"
jq -nc --arg tier "$tier" --arg skim "$skim" --argjson reasons "$reasons_json" \
  --argjson rows "$rows_json" --argjson warnings "$warn_json" \
  '{tier: $tier, reasons: $reasons, rows: $rows, skim: (if $skim == "" then null else $skim end), warnings: $warnings}'
