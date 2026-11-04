#!/usr/bin/env bash
# impact-scan.sh over the shared core (asdlc 1.7.2): the core is a link into shared/, .ovo is
# skipped at the root like plans/, and every secret glob in the core keeps its file out.
. "$(dirname "$0")/helpers.sh"
SCAN="$SHARED/impact-scan.sh"
export ASDLC_IMPACT_NOW="2000-01-01T00:00:00Z"
RGDIR=""; if [ -n "$(type -P rg 2>/dev/null)" ]; then RGDIR=found; fi

t "the core is a link into shared/, and prints its one glob list"
L="$ROOT/plugins/asdlc/scripts/impact-core.sh"
[ -L "$L" ] && ok || nok "plugins/asdlc/scripts/impact-core.sh is not a link"
assert_eq "$(readlink "$L")" "../../../shared/scripts/impact-core.sh" "link target"
G="$("$L" --secret-globs)"
assert_contains "$G" ".env*" "globs"; assert_eq "$(printf '%s\n' "$G" | wc -l | tr -d ' ')" "17" "17 globs"
run "$L"; assert_eq "$CODE" "2" "the core without its flags"; assert_contains "$ERR" "usage: impact-core.sh" "usage"

for mode in grep rg; do
  if [ "$mode" = rg ] && [ -z "$RGDIR" ]; then echo "  note: no rg binary on PATH; rg checks skipped"; continue; fi
  scan() { if [ "$mode" = grep ]; then ASDLC_IMPACT_NO_RG=1 run "$SCAN" "$@"; else run "$SCAN" "$@"; fi; }

  t "$mode: .ovo is skipped at the root, like plans/ (a named 1.7.2 change); a nested .ovo is searched"
  sandbox; mkdir -p plans/PROJ-1 .ovo/impact/x src/.ovo
  printf 'access\n' > plans/PROJ-1/terms.txt
  printf 'access in an ovo report\n' > .ovo/impact/x/hits.md
  printf 'access nested\n' > src/.ovo/n.py
  printf 'access real\n' > src/a.py
  scan PROJ-1
  assert_eq "$CODE" "0" "exit"
  M="$(cat plans/PROJ-1/impact.md)"
  assert_not_contains "$M" "- .ovo/" "root .ovo skipped"
  assert_contains "$M" "- src/.ovo/n.py:1: access nested" "nested .ovo found"
  assert_contains "$M" "- src/a.py:1: access real" "real code found"

  t "$mode: every secret glob keeps its file out"
  sandbox; mkdir -p plans/PROJ-1 deploy/keys .envs/prod
  printf 'API_SECRET\n' > plans/PROJ-1/terms.txt
  for f in .env .env.local deploy/a.pem deploy/a.key a.p12 a.pfx a.jks a.keystore deploy/keys/id_rsa id_dsa \
           id_ecdsa id_ed25519.pub .netrc .npmrc .pypirc .git-credentials .pgpass prod.tfvars .envs/prod/x; do
    printf 'API_SECRET=abc\n' > "$f"
  done
  printf 'use API_SECRET here\n' > src.py
  scan PROJ-1
  assert_eq "$CODE" "0" "exit"
  M="$(cat plans/PROJ-1/impact.md)"
  assert_contains "$M" "(1 hits)" "only the normal file"
  assert_not_contains "$M" "API_SECRET=abc" "no secret value quoted"
done

finish
