#!/usr/bin/env bash
# impact.sh: terms in .ovo/impact/<id>/terms.txt, hits.md out, through the shared core.
. "$(dirname "$0")/helpers.sh"
IM="$OS/impact.sh"
export OVO_IMPACT_NOW="2000-01-01T00:00:00Z"
RGDIR=""; if [ -n "$(type -P rg 2>/dev/null)" ]; then RGDIR=found; fi

# A fixture repo with a few source files and terms for run <id> (default r1).
repo() {
  fixture_repo
  mkdir -p src/auth node_modules/dep vendor/lib dist build .venv/lib plans src/plans
  printf 'def access(x):\n    return access_level + access\n' > src/views.py
  printf 'access granted\n' > src/auth/gate.py
  for d in node_modules/dep vendor/lib dist build .venv/lib plans; do printf 'access\n' > "$d/f.txt"; done
  printf 'access nested plans\n' > src/plans/models.py
  git add -A; git commit -qm "fixture access"   # the message lands in .git/, which is never searched
  terms "${1:-r1}" access
}
terms() {  # <id> <term>...: write the run's terms.txt
  local d; d="$("$OS/ovo-dir.sh" "impact/$1")"; shift
  printf '%s\n' "$@" > "$d/terms.txt"
}
hits() { cat "$FR/.ovo/impact/${1:-r1}/hits.md"; }

t "whole words only, sorted, sensitive path marked, the summary line"
repo
printf 'xaccessx\naccessor\n' > src/sub.py; git add src/sub.py; git commit -qm sub
run "$IM" r1
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "impact: pass 1, 1 term(s) -> $FR/.ovo/impact/r1/hits.md" "summary"
M="$(hits)"
assert_contains "$M" "# Impact scan: r1" "title"
assert_contains "$M" "Pass: 1 | Terms: 1 | Roots: . | Generated: 2000-01-01T00:00:00Z" "header"
assert_contains "$M" "Sensitive topics: none | Sensitive paths: (migration|" "the asdlc default paths"
assert_contains "$M" "- src/auth/gate.py:1: access granted [sensitive path]" "sensitive path"
assert_contains "$M" "- src/views.py:2: return access_level + access" "second hit"
assert_not_contains "$M" "sub.py" "a substring is not a hit"

t "default excludes, .git and .ovo are never searched; plans only at the top"
for d in node_modules vendor dist build .venv; do assert_not_contains "$M" "- $d/" "$d"; done
assert_not_contains "$M" "- plans/" "top-level plans"
assert_contains "$M" "- src/plans/models.py:1: access nested plans" "a nested plans/ is real code"
assert_not_contains "$M" "- .git/" ".git"
assert_not_contains "$M" "- .ovo/" ".ovo (terms.txt there says access)"
assert_contains "$M" "## \`access\` (4 hits)" "count: views x2, gate, src/plans"

t "after a run: git status is clean, and nothing is written outside .ovo (TMPDIR untouched)"
assert_eq "$(git status --porcelain)" "" "git status"
WT="$(mktemp -d)"; SANDBOXES+=("$WT")
TMPDIR="$WT" run "$IM" r1 --reset; assert_eq "$CODE" "0" "exit"
assert_eq "$(ls -A "$WT")" "" "TMPDIR untouched"
assert_eq "$(ls -A .ovo/impact/r1 | tr '\n' ' ')" "hits.md terms.txt " "no scratch left in the run dir"
assert_eq "$(git status --porcelain)" "" "git status after the second run"

t "secret files are never searched, at any depth and in an --also root"
repo
mkdir -p deploy/keys .envs/prod
for f in .env .env.local deploy/a.pem deploy/a.key a.p12 a.pfx a.jks a.keystore deploy/keys/id_rsa id_dsa \
         id_ecdsa id_ed25519.pub .netrc .npmrc .pypirc .git-credentials .pgpass prod.tfvars .envs/prod/x; do
  printf 'API_SECRET=abc\n' > "$f"
done
printf 'use API_SECRET here\n' > src/cfg.py
EX="$(mktemp -d)"; SANDBOXES+=("$EX"); printf 'API_SECRET=abc\n' > "$EX/.env"; printf 'use API_SECRET too\n' > "$EX/ok.py"
terms r1 API_SECRET
for mode in grep rg; do
  if [ "$mode" = rg ] && [ -z "$RGDIR" ]; then echo "  note: no rg binary on PATH; rg secret check skipped"; continue; fi
  if [ "$mode" = grep ]; then OVO_IMPACT_NO_RG=1 run "$IM" r1 --also "$EX" --reset; else run "$IM" r1 --also "$EX" --reset; fi
  assert_eq "$CODE" "0" "$mode exit"
  M="$(hits)"
  assert_contains "$M" "(2 hits)" "$mode only the two normal files"
  assert_contains "$M" "- src/cfg.py:1: use API_SECRET here" "$mode normal file"
  assert_contains "$M" "- $EX/ok.py:1: use API_SECRET too" "$mode --also file"
  assert_not_contains "$M" "API_SECRET=abc" "$mode no secret value quoted"
done
assert_eq "$("$OS/impact-core.sh" --secret-globs | wc -l | tr -d ' ')" "17" "17 globs, each with a file above"

t "--also: searched read-only, labelled as given; a missing dir is warned and skipped"
repo
EX2="$(mktemp -d)"; SANDBOXES+=("$EX2"); printf 'access in sibling\n' > "$EX2/lib.py"
before="$(ls -lAR "$EX2" | cksum)"
run "$IM" r1 --also "$EX2" --also ../nope-dir
assert_eq "$CODE" "0" "exit"
assert_contains "$ERR" "warn: --also: '../nope-dir' is not a directory, skipped" "warning"
assert_contains "$(hits)" "Roots: ., $EX2 |" "roots"
assert_contains "$(hits)" "- $EX2/lib.py:1: access in sibling" "extra hit"
assert_eq "$(ls -lAR "$EX2" | cksum)" "$before" "the --also dir is unchanged"

t "caps: 50 hits shown, 200 terms, 100 characters, control characters"
repo
for i in $(seq 1 60); do echo "many $i"; done > src/many.txt
terms r1 many
run "$IM" r1; M="$(hits)"
assert_contains "$M" "## \`many\` (60 hits)" "total"
assert_contains "$M" "- … 10 more hits not shown (cap 50)" "cap note"
assert_eq "$(printf '%s\n' "$M" | grep -c '^- src/many.txt:')" "50" "shown hits"
seq 1 201 | sed 's/^/term/' > .ovo/impact/r1/terms.txt
run "$IM" r1 --reset; assert_eq "$CODE" "2" "201 terms"; assert_contains "$ERR" "impact.sh: refusing: more than 200 terms" "message"
printf 'ok\n%0101d\n' 0 > .ovo/impact/r1/terms.txt
run "$IM" r1 --reset; assert_eq "$CODE" "2" "long term"; assert_contains "$ERR" "longer than 100" "message"
printf 'ok\nbad\x07term\n' > .ovo/impact/r1/terms.txt
run "$IM" r1 --reset; assert_eq "$CODE" "2" "control character"
printf '# only a comment\n' > .ovo/impact/r1/terms.txt
run "$IM" r1 --reset; assert_eq "$CODE" "2" "no terms"
assert_contains "$(hits)" "## \`many\` (60 hits)" "refusals left hits.md as it was"

t "two passes max: the third is refused, --reset starts over"
repo
run "$IM" r1; assert_contains "$(sed -n 2p .ovo/impact/r1/hits.md)" "Pass: 1 |" "pass 1"
run "$IM" r1; assert_eq "$CODE" "0" "pass 2 ok"; assert_contains "$(sed -n 2p .ovo/impact/r1/hits.md)" "Pass: 2 |" "pass 2"
before="$(hits)"
run "$IM" r1; assert_eq "$CODE" "2" "third pass refused"; assert_contains "$ERR" "two passes max" "message"
assert_eq "$(hits)" "$before" "hits.md untouched"
run "$IM" r1 --reset; assert_eq "$CODE" "0" "reset"; assert_contains "$(sed -n 2p .ovo/impact/r1/hits.md)" "Pass: 1 |" "back to pass 1"

t "bad input: usage, bad id, no terms file, outside a repo"
repo
run "$IM"; assert_eq "$CODE" "2" "no id"
run "$IM" r1 --bogus; assert_eq "$CODE" "2" "unknown flag"
run "$IM" r1 --also; assert_eq "$CODE" "2" "--also without a dir"
run "$IM" 'a/b'; assert_eq "$CODE" "2" "bad id"
run "$IM" r9; assert_eq "$CODE" "2" "no terms file"; assert_contains "$ERR" "terms.txt not found" "message"
ln -s "$FR/.ovo/impact/r1/terms.txt" .ovo/impact/r9/terms.txt
run "$IM" r9; assert_eq "$CODE" "2" "a symlinked terms file"
NR="$(mktemp -d)"; SANDBOXES+=("$NR"); cd "$NR"
run "$IM" r1; assert_eq "$CODE" "2" "outside a repo"; assert_contains "$ERR" "run inside a git repo" "message"
assert_eq "$(ls -A)" "" "nothing written outside a repo"

t "rg and grep give byte-identical output"
if [ -n "$RGDIR" ]; then
  repo
  mkdir -p src/.hidden; echo 'access hidden' > src/.hidden/h.txt
  printf 'src/ignored.txt\n' > .gitignore; echo 'access ignored' > src/ignored.txt
  printf 'access \x00 binary\n' > src/bin.dat; printf 'access x\n' > .env
  terms r1 access xaccess ACCESS
  OVO_IMPACT_NO_RG=1 run "$IM" r1; cp .ovo/impact/r1/hits.md .ovo/grep.md
  run "$IM" r1 --reset
  assert_eq "$(cmp .ovo/grep.md .ovo/impact/r1/hits.md && echo same)" "same" "rg output == grep output"
else
  echo "  note: no rg binary on PATH; rg/grep comparison skipped"
fi

finish
