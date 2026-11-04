#!/usr/bin/env bash
# shared/ holds files that both plugins link to. grep -r does not follow those links, so the
# asdlc hygiene rules are applied to shared/ here, at the source.
. "$(dirname "$0")/helpers.sh"
SH="$ROOT/shared"
RROOT="$(cd "$ROOT" && pwd -P)"

t "shared/: no project-specific values, real Jira sites or secrets"
words="develop"
[ -n "${ASDLC_HYGIENE_WORDS:-}" ] && words="$words|$(printf '%s' "$ASDLC_HYGIENE_WORDS" | tr ',' '|')"
assert_eq "$(grep -rnIiwE "$words" "$SH" || true)" "" "project-specific words"
assert_eq "$(grep -rnIE '[a-z0-9-]+\.atlassian\.net' "$SH" | grep -vE 'your-team|example' || true)" "" "real Jira site URLs"
assert_eq "$(grep -rnIE '(TOKEN|SECRET|PASSWORD)=[A-Za-z0-9_-]{8,}' "$SH" || true)" "" "hardcoded secrets"
assert_eq "$(grep -rn 'PROACTIVELY' "$SH" || true)" "" "PROACTIVELY"

t "shared/ scripts: executable, bash, strict mode, valid syntax"
for f in "$SH"/scripts/*.sh; do
  [ -f "$f" ] || continue
  b="$(basename "$f")"
  [ -x "$f" ] && ok || nok "$b not executable"
  [ "$(head -n1 "$f")" = "#!/usr/bin/env bash" ] && ok || nok "$b shebang"
  grep -q '^set -euo pipefail' "$f" && ok || nok "$b lacks set -euo pipefail"
  bash -n "$f" && ok || nok "$b syntax"
done

t "asdlc's links resolve into shared/, and asdlc never names ../shared at runtime"
while IFS= read -r l; do
  [ -n "$l" ] || continue
  tg="$(readlink "$l")"; rel="${l#"$ROOT"/}"
  case "$tg" in /*) nok "$rel is an absolute link: $tg"; continue ;; esac
  if dir="$(cd "$(dirname "$l")" 2>/dev/null && cd "$(dirname "$tg")" 2>/dev/null && pwd -P)" \
     && [ -e "$dir/$(basename "$tg")" ] && [ ! -L "$dir/$(basename "$tg")" ]; then
    case "$dir/" in "$RROOT/shared/"*) ok ;; *) nok "$rel points outside shared/: $tg" ;; esac
  else
    nok "$rel dangles: $tg"
  fi
done <<EOF
$(find "$ROOT/plugins/asdlc" -type l | LC_ALL=C sort)
EOF
assert_eq "$(grep -rnI '\.\./shared' "$ROOT/plugins/asdlc" || true)" "" "asdlc names ../shared"
assert_file "$SH/README.md"

finish
