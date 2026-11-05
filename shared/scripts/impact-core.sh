#!/usr/bin/env bash
# The impact scan, shared by asdlc (scripts/impact-scan.sh) and ovo (scripts/impact.sh). Each
# plugin reaches it through a link next to its own wrapper. It sources nothing: the wrappers own
# the paths, the config and the excludes, and pass them as flags.
#   impact-core.sh --id <id> --terms <file> --out <file> --top <dir> [options]
#   impact-core.sh --secret-globs     print the secret-file globs, one per line (the one list)
# Reads <terms> (one term per line; blank and # lines ignored), searches <top> and each --also
# dir (read-only) for each term as a fixed, whole word, and writes <out> atomically. On success
# it prints one line: "pass <n>, <m> term(s) -> <out>".
# Options:
#   --also <dir>               an extra root, searched read-only; relative to --top (repeatable)
#   --exclude <name>           a file or directory name skipped at any depth (repeatable)
#   --always-exclude <name>    a name skipped at the top of each root only (repeatable)
#   --sensitive-paths <regex>  a hit whose path matches gets " [sensitive path]" (case-insensitive)
#   --sensitive-words <csv>    single words; a hit line with one gets " [topic: <word>]"
#   --pass-file <file>         where the previous pass number is read (default: --out)
#   --max-passes <n>           passes allowed before --reset is needed (default 2, at most 9)
#   --reset                    start again at pass 1
#   --header-line <text>       a line written after the Pass line (repeatable)
#   --prog <name>              the prefix of error messages (default impact-core.sh)
#   --hint <text>              added in parentheses to the failed-search message
#   --label <flag>=<name>      the name a warning uses for also, sensitive-paths or sensitive-words
#   --no-rg                    search with grep even when rg is on PATH
#   --now <time>               the Generated time (tests)
# Uses ripgrep when a real rg binary is on PATH, else grep. Both give the same output for the
# same tree. Exit: 0 written; 2 bad usage, bad input or refused (bad term, no terms, pass limit),
# or a failed search (nothing written).
set -euo pipefail
# Byte semantics everywhere, so rg, grep, sort and awk agree on word characters and ordering.
export LC_ALL=C

CAP=50; MAX_TERMS=200; MAX_TERM_LEN=100; MAX_LINE=200
# Secret files, never searched at any depth or in any root: hit lines are copied verbatim into
# the output. Not an --exclude, because a wrapper's excludes can be replaced by a project. rg's
# -g '!glob' prunes files and directories alike; grep gets both --exclude and --exclude-dir so a
# directory named like a secret (.envs/, x.keystore/) is pruned there too.
SECRET_GLOBS=(".env*" "*.pem" "*.key" "*.p12" "*.pfx" "*.jks" "*.keystore"
  "id_rsa*" "id_dsa*" "id_ecdsa*" "id_ed25519*" ".netrc" ".npmrc" ".pypirc"
  ".git-credentials" ".pgpass" "*.tfvars")

prog="impact-core.sh"
usage() {
  echo "usage: impact-core.sh --id <id> --terms <file> --out <file> --top <dir> [--also <dir>]... [--exclude <name>]... [--always-exclude <name>]... [--sensitive-paths <regex>] [--sensitive-words <csv>] [--pass-file <file>] [--max-passes <n>] [--reset] [--header-line <text>]... [--prog <name>] [--hint <text>] [--label <flag>=<name>]... [--no-rg] [--now <time>]" >&2
  exit 2
}
warn() { echo "warn: $*" >&2; }
trim() {  # <string> -> string without leading/trailing whitespace
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
split_csv() { printf '%s' "$1" | tr ',' '\n' | while IFS= read -r i || [ -n "$i" ]; do i="$(trim "$i")"; [ -n "$i" ] && printf '%s\n' "$i"; done; return 0; }

id=""; terms_file=""; out=""; top=""; pass_file=""; max_passes=2; reset=0; no_rg=0; now=""
sens_paths=""; sens_words=""; hint=""
also_label="--also"; paths_label="--sensitive-paths"; words_label="--sensitive-words"
ALSO=(); EXCLUDES=(); HEADER_LINES=(); ALWAYS_EXCLUDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --secret-globs) printf '%s\n' "${SECRET_GLOBS[@]}"; exit 0 ;;
    --reset) reset=1; shift; continue ;;
    --no-rg) no_rg=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || usage
  case "$1" in
    --id) id="$2" ;;
    --terms) terms_file="$2" ;;
    --out) out="$2" ;;
    --top) top="$2" ;;
    --also) ALSO+=("$2") ;;
    --exclude) EXCLUDES+=("$2") ;;
    --always-exclude)
      case "$2" in ''|*[[:space:]/]*) echo "$prog: refusing --always-exclude '$2': want one name, no spaces or slashes" >&2; exit 2 ;; esac
      ALWAYS_EXCLUDE="$ALWAYS_EXCLUDE${ALWAYS_EXCLUDE:+ }$2" ;;
    --sensitive-paths) sens_paths="$2" ;;
    --sensitive-words) sens_words="$2" ;;
    --pass-file) pass_file="$2" ;;
    --max-passes)
      case "$2" in [1-9]) max_passes="$2" ;; *) echo "$prog: --max-passes wants 1 to 9" >&2; exit 2 ;; esac ;;
    --header-line) HEADER_LINES+=("$2") ;;
    --prog) prog="$2" ;;
    --hint) hint="$2" ;;
    --label)
      case "$2" in
        also=?*) also_label="${2#*=}" ;;
        sensitive-paths=?*) paths_label="${2#*=}" ;;
        sensitive-words=?*) words_label="${2#*=}" ;;
        *) usage ;;
      esac ;;
    --now) now="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$id" ] && [ -n "$terms_file" ] && [ -n "$out" ] && [ -n "$top" ] || usage
[ -n "$pass_file" ] || pass_file="$out"
[ -f "$terms_file" ] || { echo "$prog: $terms_file not found" >&2; exit 2; }

# Terms: validated whole before any search runs.
TERMS=(); nterms=0; seen=$'\n'
while IFS= read -r line || [ -n "$line" ]; do
  line="$(trim "${line%$'\r'}")"
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in *[[:cntrl:]]*) echo "$prog: refusing a term with control characters in $terms_file" >&2; exit 2 ;; esac
  if [ "${#line}" -gt "$MAX_TERM_LEN" ]; then
    echo "$prog: refusing a term longer than $MAX_TERM_LEN characters in $terms_file" >&2; exit 2
  fi
  case "$seen" in *$'\n'"$line"$'\n'*) continue ;; esac
  seen="$seen$line"$'\n'
  nterms=$((nterms + 1))
  if [ "$nterms" -gt "$MAX_TERMS" ]; then
    echo "$prog: refusing: more than $MAX_TERMS terms in $terms_file" >&2; exit 2
  fi
  TERMS+=("$line")
done < "$terms_file"
[ "$nterms" -gt 0 ] || { echo "$prog: no terms in $terms_file" >&2; exit 2; }

# Pass number: from the previous output, unless --reset.
pass=1
if [ "$reset" -eq 0 ] && [ -f "$pass_file" ]; then
  prev="$(sed -n 's/^Pass: \([0-9][0-9]*\) |.*/\1/p' "$pass_file" | head -n1)"
  [ -n "$prev" ] || { echo "$prog: cannot read the pass number in $pass_file (use --reset to start over)" >&2; exit 2; }
  if [ "$prev" -ge "$max_passes" ]; then
    case "$max_passes" in 1) maxw="one pass" ;; 2) maxw="two passes" ;; 3) maxw="three passes" ;; *) maxw="$max_passes passes" ;; esac
    echo "$prog: $maxw max; $pass_file is already pass $prev (use --reset to re-plan)" >&2; exit 2
  fi
  pass=$((prev + 1))
fi

# Roots: the top itself (label "."), then each --also path that is a directory.
ROOT_DIRS=("$top"); ROOT_LABELS=(".")
for p in ${ALSO[@]+"${ALSO[@]}"}; do
  [ -n "$p" ] || continue
  case "$p" in /*) cand="$p" ;; *) cand="$top/$p" ;; esac
  if [ -d "$cand" ]; then
    lab="$p"; while [ "${lab%/}" != "$lab" ] && [ "$lab" != "/" ]; do lab="${lab%/}"; done
    real="$(cd "$cand" 2>/dev/null && pwd -P)" || { echo "$prog: search failed in $lab: cannot enter it" >&2; exit 2; }
    ROOT_DIRS+=("$real"); ROOT_LABELS+=("$lab")
  else
    warn "$also_label: '$p' is not a directory, skipped"
  fi
done

use_rg=0
if [ "$no_rg" -eq 0 ]; then
  rgbin="$(type -P rg 2>/dev/null || true)"
  [ -n "$rgbin" ] && use_rg=1
fi

# Hits for one term in one root, as <prefix><path>:<line>:<text>. Searches ".", so both tools
# print "./path"; hidden files are searched and ignore files are not honoured, matching grep.
# Status 0/1 is normal; 2+ with output is partial results (an unreadable file); 2+ with no output
# left after the root-only filter, or an unreadable root, is a failed search and must not read as
# "0 hits": exit 2. The test runs on the filtered output so grep (which walks the root-only
# excludes) and rg (which does not) decide alike.
search_root() {  # <dir> <prefix> <term> <label>
  local d="$1" prefix="$2" term="$3" label="$4" x rc=0 raw="$work/raw" flt="$work/flt"
  if [ "$use_rg" -eq 1 ]; then
    local ra=(--no-config --no-messages --no-heading --with-filename --line-number -F -w --no-ignore --hidden --color never)
    for x in $ALWAYS_EXCLUDE; do ra+=(-g "!/$x"); done
    for x in "${SECRET_GLOBS[@]}" ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do ra+=(-g "!$x"); done
    (cd "$d" 2>/dev/null || exit 3; "$rgbin" "${ra[@]}" -e "$term" -- . 2>/dev/null) > "$raw" || rc=$?
  else
    # --exclude-dir matches base names only, so the root-only names are filtered from the output below.
    local ga=(-rnwFI -s)
    for x in "${SECRET_GLOBS[@]}"; do ga+=("--exclude=$x" "--exclude-dir=$x"); done
    for x in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do ga+=("--exclude-dir=$x"); done
    (cd "$d" 2>/dev/null || exit 3; grep "${ga[@]}" -e "$term" -- . 2>/dev/null) > "$raw" || rc=$?
  fi
  P="$prefix" R="$ALWAYS_EXCLUDE" awk '
    BEGIN { n = split(ENVIRON["R"], r, " ") }
    { for (i = 1; i <= n; i++) if (index($0, "./" r[i] "/") == 1 || index($0, "./" r[i] ":") == 1) next
      sub(/^\.\//, ""); print ENVIRON["P"] $0 }' "$raw" > "$flt"
  if [ "$rc" -ge 2 ] && { [ "$rc" -eq 3 ] || [ ! -s "$flt" ]; }; then
    echo "$prog: search failed in $label for term '$term'${hint:+ ($hint)}" >&2; exit 2
  fi
  cat "$flt"
}

# Marker setup. nocasematch makes [[ =~ ]] case-insensitive without a fork per hit.
sens_re="$sens_paths"
if [ -n "$sens_re" ]; then
  rc=0; ( [[ x =~ $sens_re ]] ) 2>/dev/null || rc=$?
  if [ "$rc" -eq 2 ]; then warn "$paths_label is not a valid regex, [sensitive path] marks disabled"; sens_re=""; fi
fi
TOPICS=()
while IFS= read -r tp; do
  [ -n "$tp" ] || continue
  if [[ $tp =~ ^[A-Za-z0-9_]+$ ]]; then TOPICS+=("$tp"); else warn "$words_label: '$tp' is not a single word, skipped"; fi
done < <(split_csv "$sens_words")

work="$(mktemp -d)"; otmp=""
trap 'rm -rf "$work"; [ -z "$otmp" ] || rm -f "$otmp"' EXIT

now="${now:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
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

otmp="$(mktemp "$(dirname "$out")/.impact.XXXXXX")"
{
  printf '# Impact scan: %s\n' "$id"
  printf 'Pass: %s | Terms: %s | Roots: %s | Generated: %s\n' "$pass" "$nterms" "$roots_txt" "$now"
  for hl in ${HEADER_LINES[@]+"${HEADER_LINES[@]}"}; do printf '%s\n' "$hl"; done
  printf 'Sensitive topics: %s | Sensitive paths: %s\n' "${topics_txt:-none}" "$sens_paths"
  cat "$body"
} > "$otmp"
mv "$otmp" "$out"; otmp=""
echo "pass $pass, $nterms term(s) -> $out"
