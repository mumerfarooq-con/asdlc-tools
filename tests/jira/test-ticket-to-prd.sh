#!/usr/bin/env bash
# ticket-to-prd.sh: one ticket -> ./prds/<KEY>.md, byte-for-byte format.
. "$(dirname "$0")/helpers.sh"

t "writes the PRD and prints its path"
sandbox; use_fixtures basic
run "$S/ticket-to-prd.sh" PROJ-1
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "./prds/PROJ-1.md" "stdout"
cat > expected.md <<'EOF'
# PROJ-1: Course page shows wrong badge

- Source: https://example.atlassian.net/browse/PROJ-1
- Type: Bug

## Description / Requirements

h2. What's wrong
The badge says Enrolled for guests.

h2. Must still work
Not sure

## Acceptance criteria

Treat any checklist items or "AC:" lines in the description above as required.
EOF
assert_eq "$(cat prds/PROJ-1.md)" "$(cat expected.md)" "PRD body"
assert_eq "$(requests | jq -r '.[0].path')" "/rest/api/2/issue/PROJ-1" "v2 endpoint"

t "non-text description falls back to a pointer"
run "$S/ticket-to-prd.sh" PROJ-3
assert_contains "$(cat prds/PROJ-3.md)" "See ticket for full formatted description."

t "missing ticket fails with the status"
run "$S/ticket-to-prd.sh" PROJ-404
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "HTTP 404"
[ ! -f prds/PROJ-404.md ] && ok || nok "wrote a PRD for a missing ticket"

finish
