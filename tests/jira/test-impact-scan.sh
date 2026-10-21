#!/usr/bin/env bash
# impact-scan.sh: terms in, plans/<ID>/impact.md out. Offline; builds a fixture repo per test.
. "$(dirname "$0")/helpers.sh"
SCAN="$SHARED/impact-scan.sh"
TD="$(dirname "$(mktemp -u)")"; TD="$(cd "$TD" && pwd -P)"
export ASDLC_IMPACT_NOW="2000-01-01T00:00:00Z"
RGDIR=""; if [ -n "$(type -P rg 2>/dev/null)" ]; then RGDIR=found; fi

# A repo with a terms file and a few source files; extra args are config lines.
repo() {
  sandbox "$@"
  mkdir -p plans/PROJ-1 src/auth node_modules/dep prds docs
  printf 'access\n' > plans/PROJ-1/terms.txt
  printf 'def access(x):\n    return access_level + access\n' > src/views.py
  printf 'access granted\n' > src/auth/gate.py
  printf 'access\n' > node_modules/dep/index.js
  printf 'access\n' > plans/other.plan.md
  printf 'access\n' > prds/p.md
  echo 'access' > .asdlc/note.txt
}

t "whole words only, sorted by path then line, sensitive path marked"
repo
run "$SCAN" PROJ-1
assert_eq "$CODE" "0" "exit"
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "# Impact scan: PROJ-1" "title"
assert_contains "$M" "Pass: 1 | Terms: 1 | Roots: . | Generated: 2000-01-01T00:00:00Z" "header"
assert_contains "$M" "## \`access\` (3 hits)" "count"
assert_contains "$M" "- src/auth/gate.py:1: access granted [sensitive path]" "sensitive path"
assert_contains "$M" "- src/views.py:1: def access(x):" "plain hit has no marker"
assert_not_contains "$M" "access_level + access [" "no marker on a plain hit"
order="$(printf '%s\n' "$M" | grep '^- src' | cut -d: -f1,2 | tr '\n' ' ')"
assert_eq "$order" "- src/auth/gate.py:1 - src/views.py:1 - src/views.py:2 " "sort order"
t "excluded dirs and plans/prds/.asdlc are not scanned"
assert_not_contains "$M" "node_modules" "IMPACT_EXCLUDE default"
assert_not_contains "$M" "- plans/" "plans"
assert_not_contains "$M" "- prds/" "prds"
assert_not_contains "$M" "- .asdlc/" ".asdlc"
t "a substring is not a hit"
printf 'xaccessx\naccessor\n' > src/sub.py
run "$SCAN" PROJ-1 --reset
assert_not_contains "$(cat plans/PROJ-1/impact.md)" "sub.py" "substring"

t "no config file: defaults work, access/known-traps shown as missing"
repo; rm .asdlc/jira.conf
run "$SCAN" PROJ-1
assert_eq "$CODE" "0" "exit"
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "Access rules: docs/access-rules.md (missing) | Known traps: docs/known-traps.md (missing)" "missing"
assert_contains "$M" "Sensitive topics: none" "no topics"
t "access rules present"
echo x > docs/access-rules.md
run "$SCAN" PROJ-1 --reset
assert_contains "$(cat plans/PROJ-1/impact.md)" "docs/access-rules.md (present)" "present"

t "a term with no hits"
repo; printf 'nothingmatches\n' > plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "## \`nothingmatches\` (0 hits)
- none" "zero hits"

t "cap at 50 with a more-hits line"
repo; printf 'many\n' > plans/PROJ-1/terms.txt
for i in $(seq 1 60); do echo "many $i"; done > src/many.txt
run "$SCAN" PROJ-1
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "## \`many\` (60 hits)" "total"
assert_contains "$M" "- … 10 more hits not shown (cap 50)" "cap note"
assert_eq "$(printf '%s\n' "$M" | grep -c '^- src/many.txt:')" "50" "shown hits"
t "exactly 50 hits: no cap note"
head -n 50 src/many.txt > src/m2 && mv src/m2 src/many.txt
run "$SCAN" PROJ-1 --reset
assert_not_contains "$(cat plans/PROJ-1/impact.md)" "more hits not shown" "no note at the cap"

t "topic markers: whole word, case-insensitive, one per topic"
repo "SENSITIVE_TOPICS=refund, Token"
printf 'term\n' > plans/PROJ-1/terms.txt
printf 'term REFUND flow\nterm tokens only\nterm token and refund\n' > src/t.py
run "$SCAN" PROJ-1
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "Sensitive topics: refund, Token" "topics header"
assert_contains "$M" "- src/t.py:1: term REFUND flow [topic: refund]" "topic case-insensitive"
assert_contains "$M" "- src/t.py:2: term tokens only
" "tokens is not token"
assert_contains "$M" "- src/t.py:3: term token and refund [topic: refund] [topic: Token]" "two topics, config order"
t "REVIEW_COUNCIL_PATHS from config, case-insensitive"
repo "REVIEW_COUNCIL_PATHS=(views)"
run "$SCAN" PROJ-1
assert_contains "$(cat plans/PROJ-1/impact.md)" "- src/views.py:1: def access(x): [sensitive path]" "custom paths"

t "long and control characters in hit text"
repo
printf 'access\x01\tX %0260d\n' 0 > src/long.txt
run "$SCAN" PROJ-1
line="$(grep '^- src/long.txt' plans/PROJ-1/impact.md)"
assert_eq "$(printf '%s' "$line" | tr -d '[:print:]' | wc -c | tr -d ' ')" "0" "no control chars"
assert_eq "$(printf '%s' "${line#- src/long.txt:1: }" | wc -c | tr -d ' ')" "200" "trimmed to 200"

t "extra paths: included, missing one warned and skipped"
repo "IMPACT_EXTRA_PATHS=../extra-$$, nope-dir"
mkdir -p "$TD/extra-$$"; EX="$(cd "$TD/extra-$$" && pwd)"; SANDBOXES+=("$EX")
printf 'access in sibling\n' > "$EX/lib.py"
run "$SCAN" PROJ-1
assert_eq "$CODE" "0" "exit"
assert_contains "$ERR" "nope-dir" "warn names the path"
assert_contains "$ERR" "skipped" "warn says skipped"
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "Roots: ., ../extra-$$" "roots"
assert_contains "$M" "- ../extra-$$/lib.py:1: access in sibling" "extra hit"

t "two passes max; --reset starts over"
repo
run "$SCAN" PROJ-1; assert_contains "$(sed -n 2p plans/PROJ-1/impact.md)" "Pass: 1 |" "pass 1"
run "$SCAN" PROJ-1; assert_eq "$CODE" "0" "second pass ok"
assert_contains "$(sed -n 2p plans/PROJ-1/impact.md)" "Pass: 2 |" "pass 2"
SANDBOXES+=("$TD/before-$$.md"); cp plans/PROJ-1/impact.md "$TD/before-$$.md"
run "$SCAN" PROJ-1
assert_eq "$CODE" "2" "third pass refused"
assert_contains "$ERR" "two passes max" "message"
assert_eq "$(cat plans/PROJ-1/impact.md)" "$(cat "$TD/before-$$.md")" "impact.md untouched by the refusal"
run "$SCAN" PROJ-1 --reset
assert_eq "$CODE" "0" "reset ok"
assert_contains "$(sed -n 2p plans/PROJ-1/impact.md)" "Pass: 1 |" "back to pass 1"

t "bad input is refused with exit 2 and writes nothing"
repo
printf 'ok\n%0101d\n' 0 > plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1; assert_eq "$CODE" "2" "long term"; assert_contains "$ERR" "longer than 100" "long msg"
printf 'ok\nbad\x07term\n' > plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1; assert_eq "$CODE" "2" "control char"; assert_contains "$ERR" "control" "control msg"
seq 1 201 | sed 's/^/term/' > plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1; assert_eq "$CODE" "2" "201 terms"; assert_contains "$ERR" "200" "cap msg"
seq 1 200 | sed 's/^/term/' > plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1; assert_eq "$CODE" "0" "200 terms ok"
rm plans/PROJ-1/impact.md plans/PROJ-1/plan-template.md
printf '# only a comment\n\n' > plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1; assert_eq "$CODE" "2" "no terms"
rm plans/PROJ-1/terms.txt
run "$SCAN" PROJ-1; assert_eq "$CODE" "2" "no terms file"
run "$SCAN" 'a/b'; assert_eq "$CODE" "2" "bad ID"
assert_eq "$(ls plans/PROJ-1)" "" "nothing written"

t "terms are fixed strings, not patterns; a leading dash is fine"
repo
printf 'a.c\n-flag\n' > plans/PROJ-1/terms.txt
printf 'abc\na.c here\nuse -flag now\n' > src/p.txt
run "$SCAN" PROJ-1
M="$(cat plans/PROJ-1/impact.md)"
assert_contains "$M" "## \`a.c\` (1 hits)" "dot is literal"
assert_contains "$M" "## \`-flag\` (1 hits)" "leading dash"

t "rg and grep give byte-identical output"
repo "IMPACT_EXTRA_PATHS=../extra2-$$" "SENSITIVE_TOPICS=granted"
mkdir -p "$TD/extra2-$$"; SANDBOXES+=("$(cd "$TD/extra2-$$" && pwd)")
printf 'access x\n' > "$TD/extra2-$$/e.py"
printf 'access\nxaccess\n_access\nfoo.access\nACCESS\n' > plans/PROJ-1/terms.txt
for i in $(seq 1 55); do echo "access $i"; done > src/many.txt
printf 'access \x00 binary\n' > src/bin.dat
mkdir -p src/.hidden; echo 'access hidden' > src/.hidden/h.txt
printf 'src/ignored.txt\n' > .gitignore; echo 'access ignored' > src/ignored.txt
mkdir -p a/plans lib/prds deploy
echo 'access nested plans' > a/plans/x.py; echo 'access nested prds' > lib/prds/y.py
echo 'access secret' > .env; echo 'access secret' > deploy/id_rsa; echo 'access secret' > "$TD/extra2-$$/server.key"
ASDLC_IMPACT_NO_RG=1 run "$SCAN" PROJ-1; assert_eq "$CODE" "0" "grep run"
SANDBOXES+=("$TD/grep-$$.md"); cp plans/PROJ-1/impact.md "$TD/grep-$$.md"
assert_contains "$(cat "$TD/grep-$$.md")" "- a/plans/x.py:1:" "nested plans found"
assert_contains "$(cat "$TD/grep-$$.md")" "- lib/prds/y.py:1:" "nested prds found"
assert_not_contains "$(cat "$TD/grep-$$.md")" "id_rsa" "secret skipped in identity fixture"
assert_contains "$(cat "$TD/grep-$$.md")" "ignored.txt" "grep ignores .gitignore"
if [ -n "$RGDIR" ]; then
  run "$SCAN" PROJ-1 --reset; assert_eq "$CODE" "0" "rg run"
  assert_eq "$(cmp "$TD/grep-$$.md" plans/PROJ-1/impact.md && echo same)" "same" "rg output == grep output"
else
  echo "  note: no rg binary on PATH; rg/grep comparison skipped"
fi

t "secret files are never searched, in the repo or an extra root; normal files still are"
for mode in grep rg; do
  if [ "$mode" = rg ] && [ -z "$RGDIR" ]; then echo "  note: no rg binary on PATH; rg secret check skipped"; continue; fi
  repo "IMPACT_EXTRA_PATHS=../extra3-$$"
  mkdir -p deploy "$TD/extra3-$$"; SANDBOXES+=("$(cd "$TD/extra3-$$" && pwd)")
  printf 'API_SECRET=abc\n' > .env; printf 'API_SECRET=abc\n' > .env.local
  printf 'API_SECRET=abc\n' > server.key; printf 'API_SECRET=abc\n' > deploy/id_rsa
  printf 'API_SECRET=abc\n' > "$TD/extra3-$$/.env"; printf 'API_SECRET=abc\n' > "$TD/extra3-$$/ca.pem"
  printf 'API_SECRET=abc\n' > .npmrc
  printf 'use API_SECRET here\n' > src/cfg.py; printf 'use API_SECRET too\n' > "$TD/extra3-$$/ok.py"
  printf 'API_SECRET\n' > plans/PROJ-1/terms.txt
  if [ "$mode" = grep ]; then ASDLC_IMPACT_NO_RG=1 run "$SCAN" PROJ-1; else run "$SCAN" PROJ-1; fi
  assert_eq "$CODE" "0" "$mode exit"
  M="$(cat plans/PROJ-1/impact.md)"
  assert_contains "$M" "(2 hits)" "$mode only the two normal files"
  assert_contains "$M" "- src/cfg.py:1: use API_SECRET here" "$mode normal source found"
  assert_contains "$M" "- ../extra3-$$/ok.py:1:" "$mode normal extra file found"
  assert_not_contains "$M" "API_SECRET=abc" "$mode no secret value quoted"
  assert_not_contains "$M" ".env" "$mode .env not listed"
  assert_not_contains "$M" "server.key" "$mode key not listed"
  assert_not_contains "$M" "id_rsa" "$mode ssh key not listed"
  assert_not_contains "$M" "ca.pem" "$mode extra-root pem not listed"
done

t "plans/prds/.asdlc are skipped at the root only"
for mode in grep rg; do
  if [ "$mode" = rg ] && [ -z "$RGDIR" ]; then echo "  note: no rg binary on PATH; rg nesting check skipped"; continue; fi
  repo
  mkdir -p src/plans lib/prds
  echo 'access nested' > src/plans/x.py; echo 'access nested' > lib/prds/y.py
  if [ "$mode" = grep ]; then ASDLC_IMPACT_NO_RG=1 run "$SCAN" PROJ-1; else run "$SCAN" PROJ-1; fi
  M="$(cat plans/PROJ-1/impact.md)"
  assert_contains "$M" "- src/plans/x.py:1: access nested" "$mode nested plans found"
  assert_contains "$M" "- lib/prds/y.py:1: access nested" "$mode nested prds found"
  assert_not_contains "$M" "- plans/" "$mode root plans skipped"
  assert_not_contains "$M" "- prds/" "$mode root prds skipped"
  assert_not_contains "$M" "- .asdlc/" "$mode root .asdlc skipped"
done

t "a failed search exits 2, says so, and writes no impact.md"
if [ "$(id -u)" -eq 0 ]; then
  echo "  note: running as root, chmod 000 cannot force a failure; skipped"
else
  for mode in grep rg; do
    if [ "$mode" = rg ] && [ -z "$RGDIR" ]; then echo "  note: no rg binary on PATH; rg failure check skipped"; continue; fi
    repo "IMPACT_EXTRA_PATHS=../extra4-$$"
    mkdir -p "$TD/extra4-$$"; X4="$(cd "$TD/extra4-$$" && pwd -P)"; SANDBOXES+=("$X4")
    chmod 111 "$X4"
    if [ "$mode" = grep ]; then ASDLC_IMPACT_NO_RG=1 run "$SCAN" PROJ-1; else run "$SCAN" PROJ-1; fi
    chmod 755 "$X4"
    assert_eq "$CODE" "2" "$mode exit"
    assert_contains "$ERR" "impact-scan.sh: search failed in ../extra4-$$ for term 'access'" "$mode message"
    assert_eq "$(ls plans/PROJ-1)" "terms.txt" "$mode no impact.md, no template copy"
  done
  # A root that cannot even be entered fails closed too.
  repo "IMPACT_EXTRA_PATHS=../extra4-$$"
  chmod 000 "$X4"; run "$SCAN" PROJ-1; chmod 755 "$X4"
  assert_eq "$CODE" "2" "unenterable root exit"
  assert_contains "$ERR" "search failed in ../extra4-$$" "unenterable root message"
  assert_eq "$(ls plans/PROJ-1)" "terms.txt" "unenterable root writes nothing"
fi

t "the plan template is copied into plans/<ID>/ on every run, and a stale copy is overwritten"
TPL="$ROOT/plugins/asdlc/templates/plan.md"
repo
run "$SCAN" PROJ-1; assert_eq "$CODE" "0" "pass 1"
assert_eq "$(cmp "$TPL" plans/PROJ-1/plan-template.md && echo same)" "same" "copy after pass 1"
echo "edited" > plans/PROJ-1/plan-template.md
run "$SCAN" PROJ-1; assert_eq "$CODE" "0" "pass 2"
assert_eq "$(cmp "$TPL" plans/PROJ-1/plan-template.md && echo same)" "same" "edited copy overwritten after pass 2"
echo "stale" > plans/PROJ-1/plan-template.md
run "$SCAN" PROJ-1 --reset; assert_eq "$CODE" "0" "reset"
assert_eq "$(cmp "$TPL" plans/PROJ-1/plan-template.md && echo same)" "same" "stale copy overwritten after --reset"
assert_not_contains "$(cat plans/PROJ-1/impact.md)" "plan-template" "the copy is not scanned"
assert_eq "$(ls -A plans/PROJ-1 | tr '\n' ' ')" "impact.md plan-template.md terms.txt " "no temp files left"

t "plugin template missing: refused with exit 2, nothing written"
repo
PL="$TD/plug-$$"; SANDBOXES+=("$PL"); mkdir -p "$PL"
cp -R "$ROOT/plugins/asdlc/scripts" "$ROOT/plugins/asdlc/jira" "$PL/"
run "$PL/scripts/impact-scan.sh" PROJ-1
assert_eq "$CODE" "2" "exit"
assert_contains "$ERR" "plan template" "message"
assert_eq "$(ls plans/PROJ-1)" "terms.txt" "neither impact.md nor the copy written"

finish
