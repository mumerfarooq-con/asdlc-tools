#!/usr/bin/env bash
# Impact scan for the planner: where else are the things this change touches used?
#   impact-scan.sh <ID> [--conf <file>] [--reset]     (run from the repo root)
# Reads ./plans/<ID>/terms.txt (one term per line; blank and # lines ignored), searches the repo
# (and IMPACT_EXTRA_PATHS, read-only) for each term as a fixed, whole word, and rewrites
# ./plans/<ID>/impact.md. Every run also copies the plan template to
# ./plans/<ID>/plan-template.md, so the planner reads it from inside the repo (subagents may not
# be allowed to read the plugin dir). At most two passes per plan (the planner may add terms after
# reading the first hits); --reset starts again at pass 1 for a re-plan. Works with no .asdlc/jira.conf.
# Uses ripgrep when a real rg binary is on PATH, else grep; ASDLC_IMPACT_NO_RG=1 forces grep.
# Both give the same output for the same tree. ASDLC_IMPACT_NOW overrides the timestamp (tests).
# Exit: 0 written; 2 bad input or refused (bad term, no terms, third pass, plugin template missing)
# or a failed search (nothing written).
set -euo pipefail
# Byte semantics everywhere, so rg, grep, sort and awk agree on word characters and ordering.
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASDLC_CONF_OPTIONAL=1
# shellcheck source=../jira/scripts/lib.sh
. "$HERE/jira/scripts/lib.sh"

CAP=50; MAX_TERMS=200; MAX_TERM_LEN=100; MAX_LINE=200
# Skipped only at the root being searched (a nested src/plans is real code).
ALWAYS_EXCLUDE="plans prds .asdlc"
# Secret files, never searched at any depth or in any root: hit lines are copied verbatim into
# impact.md, which is not gitignored. Not part of IMPACT_EXCLUDE, because a project value replaces
# that default. File globs, so rg uses -g '!glob' and grep --exclude (not --exclude-dir).
SECRET_GLOBS=(".env" ".env.*" "*.pem" "*.key" "*.p12" "*.pfx" "*.jks" "*.keystore"
  "id_rsa*" "id_dsa*" "id_ecdsa*" "id_ed25519*" ".netrc" ".npmrc" ".pypirc")

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

# Terms: validated whole before any search runs.
TERMS=(); nterms=0; seen=$'\n'
while IFS= read -r line || [ -n "$line" ]; do
  line="$(asdlc_trim "${line%$'\r'}")"
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in *[[:cntrl:]]*) echo "impact-scan.sh: refusing a term with control characters in $terms_file" >&2; exit 2 ;; esac
  if [ "${#line}" -gt "$MAX_TERM_LEN" ]; then
    echo "impact-scan.sh: refusing a term longer than $MAX_TERM_LEN characters in $terms_file" >&2; exit 2
  fi
  case "$seen" in *$'\n'"$line"$'\n'*) continue ;; esac
  seen="$seen$line"$'\n'
  nterms=$((nterms + 1))
  if [ "$nterms" -gt "$MAX_TERMS" ]; then
    echo "impact-scan.sh: refusing: more than $MAX_TERMS terms in $terms_file" >&2; exit 2
  fi
  TERMS+=("$line")
done < "$terms_file"
[ "$nterms" -gt 0 ] || { echo "impact-scan.sh: no terms in $terms_file" >&2; exit 2; }

# Pass number: from the existing impact.md, unless --reset.
pass=1
if [ "$reset" -eq 0 ] && [ -f "$out" ]; then
  prev="$(sed -n 's/^Pass: \([0-9][0-9]*\) |.*/\1/p' "$out" | head -n1)"
  [ -n "$prev" ] || { echo "impact-scan.sh: cannot read the pass number in $out (use --reset to start over)" >&2; exit 2; }
  if [ "$prev" -ge 2 ]; then
    echo "impact-scan.sh: two passes max; $out is already pass $prev (use --reset to re-plan)" >&2; exit 2
  fi
  pass=$((prev + 1))
fi

# Roots: the repo itself (label "."), then each extra path that is a directory.
ROOT_DIRS=("$top"); ROOT_LABELS=(".")
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in /*) cand="$p" ;; *) cand="$top/$p" ;; esac
  if [ -d "$cand" ]; then
    lab="$p"; while [ "${lab%/}" != "$lab" ] && [ "$lab" != "/" ]; do lab="${lab%/}"; done
    real="$(cd "$cand" 2>/dev/null && pwd -P)" || { echo "impact-scan.sh: search failed in $lab: cannot enter it" >&2; exit 2; }
    ROOT_DIRS+=("$real"); ROOT_LABELS+=("$lab")
  else
    asdlc_warn "IMPACT_EXTRA_PATHS: '$p' is not a directory, skipped"
  fi
done < <(asdlc_split_csv "$IMPACT_EXTRA_PATHS")

EXCLUDES=()
while IFS= read -r x; do [ -n "$x" ] && EXCLUDES+=("$x"); done < <(asdlc_split_csv "$IMPACT_EXCLUDE")

use_rg=0
if [ "${ASDLC_IMPACT_NO_RG:-0}" != "1" ]; then
  rgbin="$(type -P rg 2>/dev/null || true)"
  [ -n "$rgbin" ] && use_rg=1
fi

# Hits for one term in one root, as <prefix><path>:<line>:<text>. Searches ".", so both tools
# print "./path"; hidden files are searched and ignore files are not honoured, matching grep.
# Status 0/1 is normal; 2+ with output is partial results (an unreadable file); 2+ with no output,
# or an unreadable root, is a failed search and must not read as "0 hits": exit 2.
search_root() {  # <dir> <prefix> <term> <label>
  local d="$1" prefix="$2" term="$3" label="$4" x rc=0 raw="$work/raw"
  if [ "$use_rg" -eq 1 ]; then
    local ra=(--no-config --no-messages --no-heading --with-filename --line-number -F -w --no-ignore --hidden --color never)
    for x in $ALWAYS_EXCLUDE; do ra+=(-g "!/$x"); done
    for x in "${SECRET_GLOBS[@]}" ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do ra+=(-g "!$x"); done
    (cd "$d" 2>/dev/null || exit 3; "$rgbin" "${ra[@]}" -e "$term" -- . 2>/dev/null) > "$raw" || rc=$?
  else
    # --exclude-dir matches base names only, so the root-only dirs are filtered from the output below.
    local ga=(-rnwFI -s)
    for x in "${SECRET_GLOBS[@]}"; do ga+=("--exclude=$x"); done
    for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do ga+=("--exclude-dir=$x"); done
    (cd "$d" 2>/dev/null || exit 3; grep "${ga[@]}" -e "$term" -- . 2>/dev/null) > "$raw" || rc=$?
  fi
  if [ "$rc" -ge 2 ] && { [ "$rc" -eq 3 ] || [ ! -s "$raw" ]; }; then
    echo "impact-scan.sh: search failed in $label for term '$term'" >&2; exit 2
  fi
  P="$prefix" R="$ALWAYS_EXCLUDE" awk '
    BEGIN { n = split(ENVIRON["R"], r, " ") }
    { for (i = 1; i <= n; i++) if (index($0, "./" r[i] "/") == 1) next
      sub(/^\.\//, ""); print ENVIRON["P"] $0 }' "$raw"
}

# Marker setup. nocasematch makes [[ =~ ]] case-insensitive without a fork per hit.
sens_re="$REVIEW_COUNCIL_PATHS"
if [ -n "$sens_re" ]; then
  rc=0; ( [[ x =~ $sens_re ]] ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then asdlc_warn "REVIEW_COUNCIL_PATHS is not a valid regex, [sensitive path] marks disabled"; sens_re=""; fi
fi
TOPICS=()
while IFS= read -r tp; do
  [ -n "$tp" ] || continue
  if [[ $tp =~ ^[A-Za-z0-9_]+$ ]]; then TOPICS+=("$tp"); else asdlc_warn "SENSITIVE_TOPICS: '$tp' is not a single word, skipped"; fi
done < <(asdlc_split_csv "$SENSITIVE_TOPICS")

work="$(mktemp -d)"; otmp=""; ttmp=""
trap 'rm -rf "$work"; [ -z "$otmp" ] || rm -f "$otmp"; [ -z "$ttmp" ] || rm -f "$ttmp"' EXIT

present() { if [ -f "$1" ]; then echo present; else echo missing; fi; }
now="${ASDLC_IMPACT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
roots_txt=""; i=0
while [ "$i" -lt "${#ROOT_LABELS[@]}" ]; do roots_txt="$roots_txt${roots_txt:+, }${ROOT_LABELS[$i]}"; i=$((i + 1)); done
topics_txt=""
for tp in ${TOPICS[@]+"${TOPICS[@]}"}; do topics_txt="$topics_txt${topics_txt:+, }$tp"; done

body="$work/body"
shopt -s nocasematch
for term in "${TERMS[@]}"; do
  : > "$work/hits"
  i=0
  while [ "$i" -lt "${#ROOT_DIRS[@]}" ]; do
    prefix=""; [ "$i" -gt 0 ] && prefix="${ROOT_LABELS[$i]}/"
    search_root "${ROOT_DIRS[$i]}" "$prefix" "$term" "${ROOT_LABELS[$i]}" >> "$work/hits"
    i=$((i + 1))
  done
  sort -t: -k1,1 -k2,2n "$work/hits" > "$work/sorted"
  total=$(( $(wc -l < "$work/sorted") ))
  printf '\n## `%s` (%s hits)\n' "$term" "$total" >> "$body"
  if [ "$total" -eq 0 ]; then echo "- none" >> "$body"; continue; fi
  head -n "$CAP" "$work/sorted" | awk -v max="$MAX_LINE" '
    { i = index($0, ":"); path = substr($0, 1, i - 1); r = substr($0, i + 1)
      j = index(r, ":"); n = substr(r, 1, j - 1); t = substr(r, j + 1)
      gsub(/\t/, " ", t); gsub(/[[:cntrl:]]/, "", t)
      gsub(/^ +/, "", t); gsub(/ +$/, "", t)
      if (length(t) > max) { t = substr(t, 1, max); gsub(/ +$/, "", t) }
      print path ":" n ":" t }' > "$work/shown"
  while IFS= read -r h; do
    path="${h%%:*}"; r="${h#*:}"; n="${r%%:*}"; text="${r#*:}"
    m=""
    if [ -n "$sens_re" ] && [[ $path =~ $sens_re ]]; then m=" [sensitive path]"; fi
    for tp in ${TOPICS[@]+"${TOPICS[@]}"}; do
      if [[ $text =~ (^|[^A-Za-z0-9_])$tp([^A-Za-z0-9_]|$) ]]; then m="$m [topic: $tp]"; fi
    done
    printf -- '- %s:%s: %s%s\n' "$path" "$n" "$text" "$m" >> "$body"
  done < "$work/shown"
  if [ "$total" -gt "$CAP" ]; then
    printf -- '- … %s more hits not shown (cap %s)\n' "$((total - CAP))" "$CAP" >> "$body"
  fi
done
shopt -u nocasematch

# Template copy first, so a finished impact.md always has its template next to it.
ttmp="$(mktemp "$dir/.template.XXXXXX")"
cat "$tpl_src" > "$ttmp"
mv "$ttmp" "$tpl_out"; ttmp=""
otmp="$(mktemp "$dir/.impact.XXXXXX")"
{
  printf '# Impact scan: %s\n' "$id"
  printf 'Pass: %s | Terms: %s | Roots: %s | Generated: %s\n' "$pass" "$nterms" "$roots_txt" "$now"
  printf 'Access rules: %s (%s) | Known traps: %s (%s)\n' \
    "$ACCESS_RULES_PATH" "$(present "$top/$ACCESS_RULES_PATH")" "$KNOWN_TRAPS_PATH" "$(present "$top/$KNOWN_TRAPS_PATH")"
  printf 'Sensitive topics: %s | Sensitive paths: %s\n' "${topics_txt:-none}" "$REVIEW_COUNCIL_PATHS"
  cat "$body"
} > "$otmp"
mv "$otmp" "$out"; otmp=""
echo "impact-scan: pass $pass, $nterms term(s) -> $out (+ $tpl_out)"
