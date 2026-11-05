#!/usr/bin/env bash
# Ovo is public, read-only and runs only when its own commands start it. shared/ is scanned here
# too: grep -r does not follow symlinks, so the files linked into the plugins are read at source.
. "$(dirname "$0")/helpers.sh"
O="$OVO"; SH="$SHARED_DIR"
RROOT="$(cd "$ROOT" && pwd -P)"

t "no project-specific values, real Jira sites or secrets in Ovo or shared/"
# Same rule as asdlc: branch names are never hard-coded. Add your own project's words locally
# (never commit them): ASDLC_HYGIENE_WORDS="NAME,KEY" tests/ovo/run.sh
words="develop"
[ -n "${ASDLC_HYGIENE_WORDS:-}" ] && words="$words|$(printf '%s' "$ASDLC_HYGIENE_WORDS" | tr ',' '|')"
assert_eq "$(grep -rnIiwE "$words" "$O" "$SH" || true)" "" "project-specific words"
assert_eq "$(grep -rnIE '[a-z0-9-]+\.atlassian\.net' "$O" "$SH" | grep -vE 'your-team|example' || true)" "" "real Jira site URLs"
assert_eq "$(grep -rnIE '(TOKEN|SECRET|PASSWORD)=[A-Za-z0-9_-]{8,}' "$O" "$SH" || true)" "" "hardcoded secrets"

t "nothing asks to be used proactively (D-O8)"
assert_eq "$(grep -rn 'PROACTIVELY' "$O" "$SH" || true)" "" "PROACTIVELY"

t "agents: invoked only by an Ovo command, an explicit read-only tools line, at most 6 (D-O8, critic 8)"
BASH_AGENTS=""   # agents allowed a Bash tool; empty: none needs one
n=0
for f in "$O"/agents/*.md; do
  [ -f "$f" ] || continue
  n=$((n + 1)); b="$(basename "$f" .md)"
  d="$(agent_desc "$f")"
  case "$d" in "Invoked only by /ovo:"*) ok ;; *) nok "$b: the description does not start with 'Invoked only by /ovo:': $d" ;; esac
  tl="$(fm "$f" | sed -n 's/^tools:[[:space:]]*//p')"
  [ -n "$tl" ] && ok || nok "$b has no tools line"
  for tool in $(printf '%s' "$tl" | tr ',' ' '); do
    case "$tool" in
      Read|Glob|Grep|Write) ok ;;
      Bash) case " $BASH_AGENTS " in *" $b "*) ok ;; *) nok "$b has Bash, which no Ovo agent needs" ;; esac ;;
      *) nok "$b has tool '$tool' (allowed: Read, Glob, Grep, Write)" ;;
    esac
  done
  assert_not_contains "$tl" '(' "$b tools line has a scope"
  if printf '%s' "$tl" | grep -qE 'Glob|Grep'; then
    assert_contains "$(cat "$f")" 'If Glob or Grep is missing, use Read on known paths.' "$b has the fallback note"
  fi
done
[ "$n" -le 6 ] && ok || nok "$n agents; Ovo ships at most 6"

t "no jq outside the review target resolver (D-O5)"
hits="$(grep -rnIw 'jq' "$O" "$SH" | grep -v -e "^$O/scripts/review-target.sh:" -e "^$O/README.md:" -e "^$O/CHANGELOG.md:" || true)"
assert_eq "$hits" "" "jq outside scripts/review-target.sh"

t "no provider writes and no MCP (D-O3, D-O7)"
pat='gh +pr +(comment|review|merge|close|create|edit|ready)|gh +api[^|]*(-X|--method) *(POST|PUT|PATCH|DELETE)|curl[^|]*(-X|--request) *(POST|PUT|PATCH|DELETE)|curl[^|]*(--data|--form|--upload-file|-d |-F |-T )|mcp__'
assert_eq "$(grep -rnIE "$pat" "$O" "$SH" || true)" "" "a provider write or an MCP tool"

t "Ovo never names the asdlc plans directory (D-O6)"
assert_eq "$(grep -rnI 'plans/' "$O" "$SH" || true)" "" "a plans/ path"

t "every symlink in the plugins resolves inside shared/, relative, not dangling (D-O9, critic 12)"
nl=0
while IFS= read -r l; do
  [ -n "$l" ] || continue
  nl=$((nl + 1)); tg="$(readlink "$l")"; rel="${l#"$ROOT"/}"
  case "$tg" in /*) nok "$rel is an absolute link: $tg"; continue ;; esac
  if ! dir="$(cd "$(dirname "$l")" 2>/dev/null && cd "$(dirname "$tg")" 2>/dev/null && pwd -P)"; then
    nok "$rel dangles: $tg"; continue
  fi
  real="$dir/$(basename "$tg")"
  if [ ! -e "$real" ] || [ -L "$real" ]; then nok "$rel dangles or points at another link: $tg"; continue; fi
  case "$real" in "$RROOT/shared/"*) ok ;; *) nok "$rel points outside shared/: $tg" ;; esac
done <<EOF
$(find "$ROOT/plugins/ovo" "$ROOT/plugins/asdlc" -type l | LC_ALL=C sort)
EOF
assert_eq "$(find "$SH" -type l)" "" "shared/ holds no links"
assert_eq "$(grep -rnI '\.\./shared' "$ROOT/plugins" || true)" "" "a plugin file names ../shared at runtime"
assert_contains "$(cat "$SH/README.md")" "Never reference this directory at runtime" "shared/README.md says so"

t "scripts: executable, bash, strict mode, valid syntax, no bash 4 features (Ground rules)"
for f in "$O"/scripts/*.sh "$SH"/scripts/*.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ -x "$f" ] && ok || nok "$b not executable"
  [ "$(head -n1 "$f")" = "#!/usr/bin/env bash" ] && ok || nok "$b shebang"
  grep -q '^set -euo pipefail' "$f" && ok || nok "$b lacks set -euo pipefail"
  bash -n "$f" && ok || nok "$b syntax"
  assert_eq "$(grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)|&>>|\|&' "$f" || true)" "" "$b uses a bash 4 feature"
  if grep -qE '(^|[^a-z_-])(sort|grep|rg)([^a-z_-]|$)' "$f"; then
    grep -q 'LC_ALL=C' "$f" && ok || nok "$b sorts or searches without LC_ALL=C"
  fi
done

t "commands only reference scripts that exist in the plugin"
for ref in $(cat "$O"/commands/*.md 2>/dev/null | grep -ohE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/[a-z-]+\.sh' | sort -u); do
  [ -f "$O/${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}" ] && ok || nok "missing $ref"
done

t "commands pre-approve only Ovo's own scripts and Read: no git, curl, gh, rg, find, Glob, Grep, Write or Edit (critic 9)"
for f in "$O"/commands/*.md; do
  [ -f "$f" ] || continue
  b="$(basename "$f" .md)"
  at="$(fm "$f" | sed -n 's/^allowed-tools:[[:space:]]*//p')"
  [ -n "$at" ] && ok || nok "$b has no allowed-tools line"
  while IFS= read -r rule; do
    rule="$(trim_rule "$rule")"; [ -n "$rule" ] || continue
    case "$rule" in
      Read) ok ;;
      'Bash(${CLAUDE_PLUGIN_ROOT}/scripts/'*'.sh:*)')
        s="${rule#Bash(\$\{CLAUDE_PLUGIN_ROOT\}/scripts/}"; s="${s%:\*)}"
        if [[ $s =~ ^[a-z-]+\.sh$ ]] && [ -f "$O/scripts/$s" ]; then ok; else nok "$b pre-approves a script that is not Ovo's: $rule"; fi ;;
      *) nok "$b pre-approves '$rule' (allowed: Read and Ovo's own scripts)" ;;
    esac
  done <<EOF
$(printf '%s' "$at" | tr ',' '\n')
EOF
  for w in Glob Grep; do assert_not_contains "$(cat "$f")" "$w" "$b mentions $w"; done
done
assert_eq "$(grep -rnIE 'Bash\((rg|find|git|curl|gh)[ :)]' "$O" || true)" "" "a pre-approved rg, find, git, curl or gh"
for f in "$O"/commands/*.md; do
  [ -f "$f" ] || continue
  assert_contains "$(cat "$f")" 'as its own Bash call, exactly as shown: never chain it' "$(basename "$f") says one bare script call per Bash call (impact smoke: a chained echo was denied)"
done

t "/ovo:impact: model-invocable, the terms wording from asdlc's planner, the 25-line reply and Not searched (D-O12, Task 5)"
IMP="$O/commands/impact.md"
assert_not_contains "$(fm "$IMP")" "disable-model-invocation" "impact is model-invocable"
for s in 'ovo-dir.sh impact --new' 'base.sh --write impact/<id>' 'impact.sh <id>' 'At most 25 lines' 'Not searched' \
         'RESCAN' 'A second `RESCAN` is not allowed' 'patch-lines` is 400 or less' 'no default branch' '/ovo:impact --base <branch>'; do
  assert_contains "$(cat "$IMP")" "$s" "impact.md says: $s"
done
planner_terms='plus related names (for a serializer field, the model field or property it reads and any helper that computes it)'
assert_contains "$(cat "$ROOT/plugins/asdlc/agents/prd-planner.md")" "$planner_terms" "the planner's wording (the source)"
assert_contains "$(cat "$IMP")" "$planner_terms" "impact.md reuses it"
assert_contains "$(cat "$IMP")" "env or config key, permission class and FE-facing field name" "plus env, config and FE names"

t "impact-analyst: Read, Glob, Grep and Write only; writes its report, the Not searched rules, the FE hint (critic 7)"
IA="$O/agents/impact-analyst.md"
assert_eq "$(fm "$IA" | sed -n 's/^tools:[[:space:]]*//p')" "Read, Glob, Grep, Write" "tools"
for s in '.ovo/impact/<id>.md' '## What else uses this' '## Must still work' '## Not searched' 'FE not checked: re-run with `--also ../<fe-repo>`' \
         'reply `RESCAN`' 'says `Pass: 1`' 'needs change' 'unsure' 'At most 22 lines'; do
  assert_contains "$(cat "$IA")" "$s" "impact-analyst says: $s"
done

t "/ovo:review: user-invoked only, never offers to post, the reply shape (D-O12, Task 7)"
RV="$O/commands/review.md"
assert_contains "$(fm "$RV")" "disable-model-invocation: true" "review is user-invoked only"
for s in 'ovo-dir.sh review --new' 'review-target.sh <id>' 'never `--council`' 'Start no reviewer' 'in parallel, in the foreground' \
         'invoke `chair`' 'BLOCKER first, at most 12' 'Risk tier: <tier>' 'Report: .ovo/review/<id>/report.md' 'Say which to fix, e.g. `fix 1 and 3`.' \
         'never offer to' 'at most 25 lines' '.ovo/review/<id>/security.md' '.ovo/review/<id>/correctness.md' \
         '.ovo/review/<id>/architecture.md' 'pass no other path' 'Never change a finding.'; do
  assert_contains "$(cat "$RV")" "$s" "review.md says: $s"
done
for a in reviewer lens-security lens-correctness lens-architecture chair; do
  [ -f "$O/agents/$a.md" ] && ok || nok "missing agent $a"
done

t "review agents: each writes only its own file under .ovo/review/<id>/, read-only tools, no fetching"
for pair in reviewer:report.md lens-security:security.md lens-correctness:correctness.md lens-architecture:architecture.md chair:report.md; do
  a="${pair%%:*}"; f="${pair#*:}"; A="$(cat "$O/agents/$a.md")"
  assert_contains "$A" "the only file you write is \`.ovo/review/<id>/$f\`" "$a writes only $f"
  assert_eq "$(fm "$O/agents/$a.md" | sed -n 's/^tools:[[:space:]]*//p')" "Read, Glob, Grep, Write" "$a tools"
  for w in 'gh pr' 'git fetch' 'Bitbucket MCP' 'pull-request tools'; do assert_not_contains "$A" "$w" "$a fetches ($w)"; done
done
for a in reviewer chair; do
  assert_contains "$(cat "$O/agents/$a.md")" "Number the findings 1..n across" "$a numbers findings across severities"
done

t "the Human must read contract is asdlc's, byte for byte (D-O9, critic 1 and 23)"
mustread() { awk '/^```$/ && !f { getline l; if (l == "## Human must read") { f = 1; print "```"; print l; next } } f { print } f && /^- The "why" is one line/ { exit }' "$1"; }
for pair in reviewer:pr-reviewer chair:pr-review-chair; do
  o="${pair%%:*}"; a="${pair#*:}"
  ref="$(mustread "$ROOT/plugins/asdlc/agents/$a.md")"
  assert_contains "$ref" "At most 5 rows" "asdlc $a block read"
  assert_eq "$(mustread "$O/agents/$o.md")" "$ref" "Ovo $o's block equals asdlc $a's"
  assert_contains "$(cat "$O/agents/$o.md")" "## Human must read" "$o names the section heading"
  assert_contains "$(cat "$O/agents/$o.md")" "At most 5 rows" "$o names the 5-row cap"
done
cand() { sed -n 's/.*\(`## Human-must-read candidates` — up to 5 rows.*No tier; the chair decides it\.\)$/\1/p' "$1"; }
for l in security correctness architecture; do
  ref="$(cand "$ROOT/plugins/asdlc/agents/pr-reviewer-$l.md")"
  assert_contains "$ref" "Human-must-read candidates" "asdlc $l candidates line read"
  assert_eq "$(cand "$O/agents/lens-$l.md")" "$ref" "Ovo lens-$l's candidates line equals asdlc's"
done

finish
