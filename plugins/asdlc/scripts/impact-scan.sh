#!/usr/bin/env bash
# Impact scan for the planner: where else are the things this change touches used?
#   impact-scan.sh <ID> [--conf <file>] [--reset]     (run from the repo root)
# Reads ./plans/<ID>/terms.txt (one term per line; blank and # lines ignored), searches the repo
# (and IMPACT_EXTRA_PATHS, read-only) for each term as a fixed, whole word, and rewrites
# ./plans/<ID>/impact.md. Every run also copies the plan template to
# ./plans/<ID>/plan-template.md, so the planner reads it from inside the repo (subagents may not
# be allowed to read the plugin dir). At most two passes per plan (the planner may add terms after
# reading the first hits); --reset starts again at pass 1 for a re-plan. Works with no .asdlc/jira.conf.
# The search is impact-core.sh (shared with the ovo plugin; a link next to this script): this
# wrapper owns the config, the plans/<ID>/ paths, the root-only excludes and the template copy.
# Uses ripgrep when a real rg binary is on PATH, else grep; ASDLC_IMPACT_NO_RG=1 forces grep.
# Both give the same output for the same tree. ASDLC_IMPACT_NOW overrides the timestamp (tests).
# Exit: 0 written; 2 bad input or refused (bad term, no terms, third pass, plugin template missing)
# or a failed search (nothing written).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASDLC_CONF_OPTIONAL=1
# shellcheck source=../jira/scripts/lib.sh
. "$HERE/jira/scripts/lib.sh"

# Skipped only at the root being searched (a nested src/plans is real code). .ovo holds the ovo
# plugin's reports.
ALWAYS_EXCLUDE="plans prds .asdlc .ovo"

reset=0
args=()
for a in "$@"; do
  case "$a" in --reset) reset=1 ;; *) args+=("$a") ;; esac
done
asdlc_init ${args[@]+"${args[@]}"}
set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
id="${1:-}"
[ -n "$id" ] || { echo "usage: impact-scan.sh <ID> [--conf <file>] [--reset]" >&2; exit 2; }
[ $# -eq 1 ] || { echo "impact-scan.sh: unexpected argument '$2'" >&2; exit 2; }
if ! [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "impact-scan.sh: refusing: ID must match [A-Za-z0-9][A-Za-z0-9._-]*" >&2; exit 2
fi

top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir="plans/$id"
terms_file="$dir/terms.txt"
out="$dir/impact.md"
tpl_src="$HERE/templates/plan.md"
tpl_out="$dir/plan-template.md"
[ -f "$tpl_src" ] || { echo "impact-scan.sh: plan template $tpl_src not found (broken plugin install?)" >&2; exit 2; }
[ -f "$terms_file" ] || { echo "impact-scan.sh: $terms_file not found (the planner writes it first)" >&2; exit 2; }

present() { if [ -f "$1" ]; then echo present; else echo missing; fi; }
core=("$HERE/scripts/impact-core.sh" --prog impact-scan.sh --id "$id" --terms "$terms_file" --out "$out" --top "$top"
  --hint "an unreadable file or directory? add it to IMPACT_EXCLUDE, keeping the defaults"
  --label also=IMPACT_EXTRA_PATHS --label sensitive-paths=REVIEW_COUNCIL_PATHS --label sensitive-words=SENSITIVE_TOPICS
  --sensitive-paths "$REVIEW_COUNCIL_PATHS" --sensitive-words "$SENSITIVE_TOPICS"
  --header-line "$(printf 'Access rules: %s (%s) | Known traps: %s (%s)' \
    "$ACCESS_RULES_PATH" "$(present "$top/$ACCESS_RULES_PATH")" "$KNOWN_TRAPS_PATH" "$(present "$top/$KNOWN_TRAPS_PATH")")")
for x in $ALWAYS_EXCLUDE; do core+=(--always-exclude "$x"); done
while IFS= read -r x; do [ -n "$x" ] && core+=(--exclude "$x"); done < <(asdlc_split_csv "$IMPACT_EXCLUDE")
while IFS= read -r p; do [ -n "$p" ] && core+=(--also "$p"); done < <(asdlc_split_csv "$IMPACT_EXTRA_PATHS")
[ "$reset" -eq 0 ] || core+=(--reset)
[ "${ASDLC_IMPACT_NO_RG:-0}" != "1" ] || core+=(--no-rg)
[ -z "${ASDLC_IMPACT_NOW:-}" ] || core+=(--now "$ASDLC_IMPACT_NOW")
done_line="$("${core[@]}")" || exit $?

# The template copy, only after the scan succeeded.
ttmp=""
trap '[ -z "$ttmp" ] || rm -f "$ttmp"' EXIT
ttmp="$(mktemp "$dir/.template.XXXXXX")"
cat "$tpl_src" > "$ttmp"
mv "$ttmp" "$tpl_out"; ttmp=""
echo "impact-scan: $done_line (+ $tpl_out)"
