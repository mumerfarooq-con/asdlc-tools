#!/usr/bin/env bash
# jira-context.sh fetch / build / fingerprint: the context bundle and the ticket fingerprint.
# Fixture mode only: no network. PNG bytes are generated here, never committed.
. "$(dirname "$0")/helpers.sh"
JC="$S/jira-context.sh"
PS="$SHARED/plan-state.sh"
API=jira/rest/api/2
# The stale check refuses fixture mode unless a test says otherwise (see the refusal test below).
export ASDLC_TEST_FIXTURE_CHECK=1

ctx_sandbox() {  # [conf lines...]: a sandbox with the context fixtures and a tiny PNG for attachment 10001
  sandbox "$@"; use_fixtures context
  mkdir -p "fx/$API/attachment/content"
  printf '\211PNG\r\n\032\n\000\001' > "fx/$API/attachment/content/10001.json"
}
gets() { requests | jq -r '[.[] | select(.method == "GET") | .path] | join(" ")'; }
plan_file() {  # <KEY> <status>: a plan with a header block, written directly
  mkdir -p plans; printf '<!-- asdlc\nticket: %s\nstatus: %s\nplan_hash: sha256:00\n-->\n# plan\n' "$1" "$2" > "plans/$1.plan.md"
}
fp() { run "$JC" fingerprint "$1"; echo "$OUT"; }
# A copy of the fetched raw dir at $SB/<name> with a jq filter applied to one of its files.
variant() {  # <name> <jq filter over issue.json>
  rm -rf "${SB:?}/${1:?}"; cp -R plans/PROJ-1/raw "$SB/$1"
  jq -c "$2" plans/PROJ-1/raw/issue.json > "$SB/$1/issue.json"
}
variant_comments() {  # <name> <jq filter over comments-0.json>
  rm -rf "${SB:?}/${1:?}"; cp -R plans/PROJ-1/raw "$SB/$1"
  jq -c "$2" plans/PROJ-1/raw/comments-0.json > "$SB/$1/comments-0.json"
}

# Captures as the MCP hook writes them (see the mcp tests below); the hook itself is tested in test-mcp-capture.sh.
MCPFX="$FIXTURES/context-mcp"
write_cap() {  # <KEY> <role> <response file> [epoch offset from the request] [nonce override] [jq filter on the issue node]
  local req="plans/$1/.mcp/request.json" node="${6:-.}"
  jq -n --slurpfile r "$3" --slurpfile q "$req" --arg role "$2" --argjson off "${4:-0}" --arg nonce "${5:-}" '
    {nonce: (if $nonce == "" then $q[0].nonce else $nonce end), tool_name: "mcp__\($q[0].server)__getJiraIssue",
     session_id: "s1", captured_epoch: ($q[0].created_epoch + $off), role: $role, response: ($r[0] | del(.context))}
    | .response.issues.nodes[0] |= ('"$node"')' \
    > "plans/$1/.mcp/cap-$(jq -r '.created_epoch' "$req")-$RANDOM$RANDOM.json"
}
mcp_caps() {  # [issue filter]: open a fetch request for PROJ-1 and capture the issue and its parent
  run "$JC" mcp-request PROJ-1 --for fetch
  write_cap PROJ-1 issue "$MCPFX/issue.response.json" 0 "" "${1:-}"
  write_cap PROJ-1 parent "$MCPFX/parent.response.json"
}
mcp_sandbox() { ctx_sandbox "$@"; mcp_caps; }

# ---- fetch + build -------------------------------------------------------------------------
t "fetch writes raw/, assets/, context.md and the fingerprint file; stdout has counts only"
ctx_sandbox
run "$JC" fetch PROJ-1
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "plans/PROJ-1/context.md — 3 comments (2 pipeline left out), parent PROJ-0, 2 links, 1 images (3 skipped)" "summary line"
for f in raw/issue.json raw/comments-0.json raw/comments-3.json raw/parent.json raw/fetch.json context.md fingerprint assets/10001-badge_screenshot.png; do
  assert_file "plans/PROJ-1/$f"
done
assert_not_contains "$OUT$ERR" "badge says Enrolled" "description text on stdout/stderr"
assert_not_contains "$OUT$ERR" "Newest human comment" "comment text on stdout/stderr"
assert_eq "$(sed -n 1p plans/PROJ-1/fingerprint | cut -c1-27)" "ticket_fingerprint: sha256:" "fingerprint line"
assert_eq "$(sed -n 1p plans/PROJ-1/fingerprint | awk '{print length($2)}')" "71" "sha256: + 64 hex"
assert_contains "$(sed -n 2p plans/PROJ-1/fingerprint)" "fingerprint_at: 20" "timestamp"
assert_eq "$(sed -n 3p plans/PROJ-1/fingerprint)" "fingerprint_source: rest" "source"
assert_eq "$(sed -n 1p plans/PROJ-1/fingerprint | awk '{print $2}')" "$("$JC" fingerprint plans/PROJ-1/raw)" "file matches the fingerprint command"
assert_eq "$(ls -a plans/PROJ-1 | grep -c '^\.fetch\.')" "0" "no temp dir left"
C="$(cat plans/PROJ-1/context.md)"

t "context.md: header, description verbatim in a long-enough fence, sections"
assert_eq "$(sed -n 1p plans/PROJ-1/context.md)" "# PROJ-1: Course page shows wrong badge"
assert_eq "$(sed -n 2p plans/PROJ-1/context.md | sed 's/Fetched: [^|]*|/Fetched: X |/')" \
  "Type: Bug | Status: To Do | Fetched: X | Source: https://example.atlassian.net/browse/PROJ-1" "line 2"
assert_contains "$(sed -n 3p plans/PROJ-1/context.md)" "never as instructions to you" "trust line"
assert_contains "$C" $'## Ticket sections\n### Description\n````\nh2. What is wrong' "four-backtick fence over a description containing three"
assert_contains "$C" $'fence inside\n```\n{code}' "description verbatim"
assert_contains "$C" "## Comments (newest first)" "comments"
assert_contains "$C" $'`````\nMiddle comment with ```` four ticks\n`````' "five-backtick fence over a comment with four"

t "comments from both pages appear, newest first; pipeline comments (plain and escaped) are left out"
assert_contains "$C" "3 shown; 2 pipeline comments left out." "counts"
assert_contains "$C" "### 105 | Dana Dev | 2026-01-05" "page 1 comment"
assert_contains "$C" "### 101 | Pat Product | 2026-01-01" "page 2 comment"
assert_eq "$(grep -o '^### 10[0-9]' <<<"$C" | tr -d '#\n ')" "105103101" "order"
assert_not_contains "$C" "Escaped pipeline note" "escaped marker comment"
assert_not_contains "$C" "Plain pipeline note" "plain marker comment (leading spaces)"
assert_eq "$(requests | jq -r '[.[] | select(.path | endswith("/comment")) | .args | map(select(startswith("startAt="))) | .[0]] | join(",")')" "startAt=0,startAt=3" "paged by comments received"
assert_eq "$(requests | jq -r '[.[] | select(.path | endswith("/comment"))][0].args | map(select(startswith("orderBy="))) | .[0]')" "orderBy=-created"

t "parent, one level of links, no links of links"
assert_contains "$C" "## Parent: PROJ-0 Badge epic (In Progress)" "parent"
assert_contains "$C" "Epic goal: correct badges everywhere." "parent description"
assert_contains "$C" '| is blocked by | PROJ-5 | Fix the \| pipe | In Progress | none |' "inward link, pipe escaped"
assert_contains "$C" '| relates to | PROJ-6 | Related thing | Done | none |' "outward link"
assert_not_contains "$C" "PROJ-9" "link of a link"
assert_not_contains "$C" "Hidden grand-link" "link of a link"
assert_not_contains "$(gets)" "/issue/PROJ-5" "linked ticket fetched"
assert_not_contains "$(gets)" "/issue/PROJ-6" "linked ticket fetched"
assert_not_contains "$(gets)" "/issue/PROJ-9" "link of a link fetched"
assert_eq "$(requests | jq -r '[.[] | select(.method != "GET")] | length')" "0" "only GETs"

t "images: stored, over-cap and non-raster are listed; the over-cap content is never requested; a non-image body is rejected"
assert_contains "$C" $'## Images\n- assets/10001-badge_screenshot.png' "stored image"
assert_contains "$C" "- Skipped: huge.png (over the 5 MB cap)" "over the cap"
assert_contains "$C" "- Skipped: logo.svg (not a raster image)" "svg"
assert_contains "$C" "- Skipped: fake.png (not a raster image)" "html body behind a png name, leading dots stripped"
assert_not_contains "$(gets)" "attachment/content/10002" "over-cap content requested"
assert_not_contains "$(gets)" "attachment/content/10003" "svg content requested"
assert_contains "$(gets)" "attachment/content/10004" "html body is only found out by downloading"
assert_eq "$(ls plans/PROJ-1/assets | tr '\n' ' ')" "10001-badge_screenshot.png " "only the real image is kept"

t "figma links, and a linked ticket's earlier plan"
assert_contains "$C" $'## Figma links\n- https://www.figma.com/file/AbC123/badge?node-id=1' "figma stops at ]"
assert_not_contains "${C#*## Figma links}" "example.org" "non-figma url in the figma list"

t "figma links: one with a backtick, < or >, or over 300 characters is dropped; a normal one stays"
ctx_sandbox
LONG="https://www.figma.com/file/$(printf 'x%.0s' $(seq 1 1000))"
OK300="https://www.figma.com/file/$(printf 'y%.0s' $(seq 1 270))"
jq --arg l "$LONG" --arg k "$OK300" '.fields.description += "\nTick: https://www.figma.com/file/BAD`TICK/x Angle: https://www.figma.com/file/BAD<ANGLE/x Close: https://www.figma.com/file/BAD>CLOSE/x Long: \($l) Edge: \($k) Good: https://www.figma.com/file/GOOD789/ok"' \
  "fx/$API/issue/PROJ-1.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1.json"
run "$JC" fetch PROJ-1; assert_eq "$CODE" "0" "exit"
C="$(cat plans/PROJ-1/context.md)"; FIG="${C#*## Figma links}"
assert_contains "$FIG" "- https://www.figma.com/file/GOOD789/ok" "normal link kept"
assert_contains "$FIG" "- https://www.figma.com/file/AbC123/badge?node-id=1" "the fixture link kept"
assert_contains "$FIG" "- $OK300" "a link under the cap kept"
assert_not_contains "$FIG" "BAD" "backtick, < and > links dropped"
assert_not_contains "$FIG" "xxxxxxxxxx" "1000-character link dropped"
assert_not_contains "$FIG" '`TICK' "backtick link dropped"
ctx_sandbox; mkdir plans; plan_file PROJ-5 pending; run "$JC" fetch PROJ-1
assert_contains "$(cat plans/PROJ-1/context.md)" "| PROJ-5 | Fix the \\| pipe | In Progress | plans/PROJ-5.plan.md |" "earlier plan path"
assert_contains "$(cat plans/PROJ-1/context.md)" "| PROJ-6 | Related thing | Done | none |" "no plan for the other"

t "image caps: MAX_IMAGES=0 downloads nothing; MAX_IMAGE_MB=0 and MAX_IMAGES=1 skip with the reason"
ctx_sandbox MAX_IMAGES=0; run "$JC" fetch PROJ-1
assert_not_contains "$(gets)" "attachment/content" "downloads off"; assert_contains "$(cat plans/PROJ-1/context.md)" $'## Images\n(none)'
ctx_sandbox MAX_IMAGE_MB=0; run "$JC" fetch PROJ-1
assert_contains "$(cat plans/PROJ-1/context.md)" "- Skipped: badge_screenshot.png (over the 0 MB cap)" "MB cap on metadata"
ctx_sandbox MAX_IMAGES=1
jq '.fields.attachment += [{"id":"10005","filename":"b.png","mimeType":"image/png","size":10,"created":"2026-01-01T10:00:00.000+0000"}]' \
  "fx/$API/issue/PROJ-1.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1.json"
run "$JC" fetch PROJ-1
assert_contains "$(cat plans/PROJ-1/context.md)" "- Skipped: b.png (over the 1-image cap)" "count cap"
assert_not_contains "$(gets)" "attachment/content/10005" "capped image requested"

t "a parent that returns 403 gives a note and exit 0"
ctx_sandbox; echo 403 > "fx/$API/issue/PROJ-0.code"
run "$JC" fetch PROJ-1
assert_eq "$CODE" "0" "exit"; assert_contains "$ERR" "parent PROJ-0 could not be read (HTTP 403)" "note"
assert_contains "$(cat plans/PROJ-1/context.md)" "## Parent: PROJ-0 (could not be read: HTTP 403)" "context"
assert_not_contains "$(cat plans/PROJ-1/context.md)" "Epic goal" "no parent text"
assert_file plans/PROJ-1/fingerprint

t "a failed image download only produces a Skipped line"
ctx_sandbox; echo 503 > "fx/$API/attachment/content/10001.code"
run "$JC" fetch PROJ-1
assert_eq "$CODE" "0" "exit"; assert_contains "$(cat plans/PROJ-1/context.md)" "- Skipped: badge_screenshot.png (download failed: HTTP 503)"

t "a null description, and a non-string description"
ctx_sandbox; jq '.fields.description = null' "fx/$API/issue/PROJ-1.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1.json"
run "$JC" fetch PROJ-1
assert_contains "$(cat plans/PROJ-1/context.md)" $'### Description\n(no description)'
ctx_sandbox; jq '.fields.description = {"type":"doc"}' "fx/$API/issue/PROJ-1.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1.json"
run "$JC" fetch PROJ-1
assert_contains "$(cat plans/PROJ-1/context.md)" $'### Description\n(not plain text — open the ticket)'

t "a custom marker filters its own comments; an empty marker is refused before any request"
ctx_sandbox 'PIPELINE_COMMENT_MARKER=Newest'; run "$JC" fetch PROJ-1
assert_not_contains "$(cat plans/PROJ-1/context.md)" "### 105" "comment starting with the custom marker left out"
assert_contains "$(cat plans/PROJ-1/context.md)" "### 104" "the default marker no longer applies"
ctx_sandbox 'PIPELINE_COMMENT_MARKER='; run "$JC" fetch PROJ-1
assert_eq "$CODE" "1" "empty marker exit"; assert_contains "$ERR" "PIPELINE_COMMENT_MARKER"; assert_eq "$(requests)" "[]" "no request"

t "bad inputs: not a key, non-integer caps"
ctx_sandbox
for bad in proj-1 PROJ-1x '../x' 'PROJ-1/../x' ''; do
  run "$JC" fetch "$bad"; assert_eq "$CODE" "2" "refused [$bad]"
done
assert_eq "$(requests)" "[]" "no request"
ctx_sandbox MAX_IMAGES=ten; run "$JC" fetch PROJ-1; assert_eq "$CODE" "2" "MAX_IMAGES"; assert_contains "$ERR" "MAX_IMAGES"
ctx_sandbox MAX_IMAGE_MB=1.5; run "$JC" fetch PROJ-1; assert_eq "$CODE" "2" "MAX_IMAGE_MB"
assert_eq "$(requests)" "[]" "no request"

t "an existing pending or approved plan is refused and left byte-identical; nothing is fetched"
for st in pending approved executing done; do
  ctx_sandbox; plan_file PROJ-1 $st; cp plans/PROJ-1.plan.md "$SB/before"
  run "$JC" fetch PROJ-1
  assert_eq "$CODE" "2" "exit ($st)"; assert_contains "$ERR" "refusing" "message ($st)"
  cmp -s plans/PROJ-1.plan.md "$SB/before" && ok || nok "plan changed ($st)"
  assert_eq "$(requests)" "[]" "no request ($st)"; [ ! -e plans/PROJ-1 ] && ok || nok "wrote a bundle ($st)"
done
ctx_sandbox; plan_file PROJ-1 pending; run "$JC" build PROJ-1 --source rest; assert_eq "$CODE" "2" "build refuses too"

t "a STALE plan is moved to .prev and its own changes.md is kept; a fresh context deletes an old changes.md"
FPA="sha256:$(printf 'a%.0s' $(seq 1 64))"
ctx_sandbox; plan_file PROJ-1 stale; sed "s/^status: stale/&\nticket_fingerprint: $FPA/" plans/PROJ-1.plan.md > plans/t && mv plans/t plans/PROJ-1.plan.md
cp plans/PROJ-1.plan.md "$SB/before"
mkdir -p plans/PROJ-1; printf 'old changes\nApproved fingerprint: %s\n' "$FPA" > plans/PROJ-1/changes.md
run "$JC" fetch PROJ-1
assert_eq "$CODE" "0" "exit"; [ ! -e plans/PROJ-1.plan.md ] && ok || nok "plan still in place"
cmp -s plans/PROJ-1.plan.prev.md "$SB/before" && ok || nok ".prev differs from the stale plan"
assert_eq "$(head -n1 plans/PROJ-1/changes.md)" "old changes" "changes.md kept"
ctx_sandbox; mkdir -p plans/PROJ-1; echo "old changes" > plans/PROJ-1/changes.md; run "$JC" fetch PROJ-1
[ ! -e plans/PROJ-1/changes.md ] && ok || nok "old changes.md kept for a fresh context"
ctx_sandbox; plan_file PROJ-1 stale; mkdir -p plans/PROJ-1; printf 'old changes\nApproved fingerprint: %s\n' "$FPA" > plans/PROJ-1/changes.md
run "$JC" fetch PROJ-1
[ ! -e plans/PROJ-1/changes.md ] && ok || nok "changes.md kept for a .prev with no fingerprint"

t "fetch removes an old fingerprint first: a failed fetch leaves none"
ctx_sandbox; run "$JC" fetch PROJ-1; assert_file plans/PROJ-1/fingerprint
echo 503 > "fx/$API/issue/PROJ-1/comment.startAt-3.code"
run "$JC" fetch PROJ-1; assert_eq "$CODE" "1" "exit"
[ ! -e plans/PROJ-1/fingerprint ] && ok || nok "fingerprint survived a failed fetch"
assert_file plans/PROJ-1/raw/issue.json; assert_eq "$(ls -a plans/PROJ-1 | grep -c '^\.fetch\.')" "0" "temp dir cleaned up"

t "comments that do not add up to the total: retried once, then an error and nothing written"
ctx_sandbox
for f in comment comment.startAt-3; do
  jq '.total = 6' "fx/$API/issue/PROJ-1/$f.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1/$f.json"
done
echo '{"startAt":5,"maxResults":3,"total":6,"comments":[]}' > "fx/$API/issue/PROJ-1/comment.startAt-5.json"
run "$JC" fetch PROJ-1
assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "did not add up"
assert_eq "$(requests | jq '[.[] | select(.path | endswith("/comment"))] | length')" "6" "two passes of three pages"
[ ! -e plans/PROJ-1/context.md ] && ok || nok "wrote a context"

t "a moved key is an error, nothing written"
ctx_sandbox; jq '.key = "PROJ-2"' "fx/$API/issue/PROJ-1.json" > fx/t && mv fx/t "fx/$API/issue/PROJ-1.json"
run "$JC" fetch PROJ-1; assert_eq "$CODE" "1" "exit"; [ ! -e plans/PROJ-1/raw ] && ok || nok "wrote raw/"

t "the issue and parent requests ask for the documented fields"
ctx_sandbox; run "$JC" fetch PROJ-1
assert_eq "$(requests | jq -r '.[0].args | map(select(startswith("fields="))) | .[0]')" "fields=summary,description,status,issuetype,parent,issuelinks,attachment"
assert_eq "$(requests | jq -r '[.[] | select(.path == "/rest/api/2/issue/PROJ-0")][0].args | map(select(startswith("fields="))) | .[0]')" "fields=summary,description,status,issuetype"

t "a build that fails while rendering leaves no fingerprint (the fingerprint file is written last)"
ctx_sandbox; run "$JC" fetch PROJ-1; assert_file plans/PROJ-1/fingerprint
echo 'not json' > plans/PROJ-1/raw/parent.json
run "$JC" build PROJ-1 --source rest
assert_eq "$CODE" "2" "exit"; [ ! -e plans/PROJ-1/fingerprint ] && ok || nok "fingerprint written before the context was complete"

t "build refuses other sources; malformed ids fail closed"
ctx_sandbox; run "$JC" fetch PROJ-1
run "$JC" build PROJ-1 --source mcp; assert_eq "$CODE" "2" "mcp not available"
run "$JC" build PROJ-1; assert_eq "$CODE" "2" "no source"
variant bad '.fields.attachment[0].id = "10001x"'
run "$JC" fingerprint "$SB/bad"; assert_eq "$CODE" "2" "bad attachment id"; assert_eq "$OUT" "" "no value printed"
variant bad '.fields.issuelinks[0].inwardIssue.key = "nope"'
run "$JC" fingerprint "$SB/bad"; assert_eq "$CODE" "2" "bad link key"
variant bad '.fields.parent.key = "x y"'
run "$JC" fingerprint "$SB/bad"; assert_eq "$CODE" "2" "bad parent key"
variant_comments bad '.comments[0].id = "abc"'
run "$JC" fingerprint "$SB/bad"; assert_eq "$CODE" "2" "bad comment id"
run "$JC" fingerprint "$SB/nonexistent"; assert_eq "$CODE" "2" "no raw dir"

# ---- fingerprint ---------------------------------------------------------------------------
t "fingerprint: the same raw input twice gives the same value; the command needs no site config"
ctx_sandbox; run "$JC" fetch PROJ-1
BASE="$(fp plans/PROJ-1/raw)"
assert_contains "$BASE" "sha256:" "value"; assert_eq "$(fp plans/PROJ-1/raw)" "$BASE" "repeat"
mv .asdlc/jira.conf "$SB/jira.conf.off"
assert_eq "$("$JC" fingerprint plans/PROJ-1/raw)" "$BASE" "no config needed"
mv "$SB/jira.conf.off" .asdlc/jira.conf
run "$JC" fetch PROJ-1 >/dev/null 2>&1
assert_eq "$(fp plans/PROJ-1/raw)" "$BASE" "a second fetch of the same ticket"

# Pinned values: one literal per fixture, so a run on another machine (or another jq, awk, sort
# or sha) that hashes differently fails here instead of turning approved plans STALE. If the
# preimage changes on purpose, change asdlc-ticket-fp-v1 with it and update these.
t "fingerprint: pinned values (the fixture ticket, and a non-text description through tojson)"
assert_eq "$BASE" "sha256:539f9a45a7671f6d28c14e97aea583810ddf093a1c1f90c95cadaa107d957c64" "pinned fingerprint of the fixture raw dir"
assert_eq "$(fp "$FIXTURES/context/fp-nonstring")" "sha256:cae23bca8ac7b58d5a02c75fecd7a172178e2f08132ba3435e4249b3d10fdb0a" "pinned fingerprint with a non-string description"
differs_from() { :; }

same() {  # <what> <raw dir>
  assert_eq "$(fp "$2")" "$BASE" "$1 must not change the fingerprint"
}
differs() {  # <what> <raw dir>
  local v; v="$(fp "$2")"
  if [ "$v" != "$BASE" ] && [ -n "$v" ]; then ok; else nok "$1 must change the fingerprint"; fi
}

t "fingerprint: unchanged by a new pipeline comment, in both marker forms"
variant_comments x '.comments += [{"id":"900","body":"[asdlc] new bot note","created":"2026-02-01T00:00:00.000+0000"},{"id":"901","body":"\\[asdlc\\] escaped","created":"2026-02-02T00:00:00.000+0000"}]'
same "pipeline comments" "$SB/x"

t "fingerprint: unchanged by status, assignee, sprint, rank, updated, author, type, labels, priority, linked summaries"
variant x '.fields.status.name = "Done" | .fields.assignee = {"displayName":"Zed"} | .fields.customfield_10020 = [{"name":"Sprint 9"}]
           | .fields.customfield_10019 = "0|i0002z:" | .fields.updated = "2030-01-01T00:00:00.000+0000"
           | .fields.issuetype.name = "Story" | .fields.labels = ["x"] | .fields.priority = {"name":"Low"}
           | .fields.issuelinks[0].inwardIssue.fields.summary = "renamed" | .fields.issuelinks[0].inwardIssue.fields.status.name = "Done"'
same "ticket metadata" "$SB/x"
variant_comments x '.comments[0].author.displayName = "Someone else" | .comments[0].created = "2030-01-01T00:00:00.000+0000"'
same "comment author and timestamp" "$SB/x"

t "fingerprint: unchanged by a reversed comment order, CRLF line endings and trailing whitespace"
variant_comments x '.comments |= reverse'; same "reversed comment order" "$SB/x"
variant x '.fields.description |= gsub("\n"; "\r\n")'; same "CRLF description" "$SB/x"
variant x '.fields.description |= (split("\n") | map(. + "  \t") | join("\n"))'; same "trailing whitespace" "$SB/x"
variant x '.fields.description |= ("\n\n" + . + "\n\n  \n")'; same "surrounding blank lines" "$SB/x"
variant_comments x '.comments |= map(.body |= gsub("\n"; "\r\n"))'; same "CRLF comments" "$SB/x"
variant x '.fields.summary += "   "'; same "trailing spaces in the summary" "$SB/x"
# a comment that shows up on two pages counts once
rm -rf "${SB:?}/x"; cp -R plans/PROJ-1/raw "$SB/x"; cp plans/PROJ-1/raw/comments-0.json "$SB/x/comments-99.json"
same "a comment seen on two pages" "$SB/x"

t "fingerprint: changes with a new human comment, an edited comment, an edited description"
variant_comments x '.comments += [{"id":"900","body":"human follow-up","created":"2026-02-01T00:00:00.000+0000"}]'; differs "new human comment" "$SB/x"
variant_comments x '(.comments[] | select(.id == "105") | .body) += " (edited)"'; differs "edited comment" "$SB/x"
variant_comments x '.comments |= map(select(.id != "105"))'; differs "removed comment" "$SB/x"
variant x '.fields.description += " more"'; differs "edited description" "$SB/x"
variant x '.fields.description = null'; differs "removed description" "$SB/x"
variant x '.fields.summary += "!"'; differs "edited summary" "$SB/x"

t "fingerprint: changes with a new link, a new attachment, a changed parent"
variant x '.fields.issuelinks += [{"type":{"name":"Relates","inward":"relates to","outward":"relates to"},"outwardIssue":{"key":"PROJ-7","fields":{}}}]'
differs "new link" "$SB/x"
variant x '.fields.issuelinks |= map(select(.outwardIssue.key != "PROJ-6"))'; differs "removed link" "$SB/x"
variant x '.fields.issuelinks[0].type.name = "Relates"'; differs "changed link type" "$SB/x"
variant x '.fields.attachment += [{"id":"10099","filename":"n.png","mimeType":"image/png","size":1}]'; differs "new attachment" "$SB/x"
variant x '.fields.parent.key = "PROJ-8"'; differs "changed parent" "$SB/x"
variant x 'del(.fields.parent)'; differs "removed parent" "$SB/x"
variant x '.fields.parent.fields.summary = "renamed epic"'; same "the parent's own summary (only its key counts)" "$SB/x"

t "fingerprint: a different marker changes which comments count"
echo 'PIPELINE_COMMENT_MARKER=[other]' >> .asdlc/jira.conf
if [ "$("$JC" fingerprint plans/PROJ-1/raw)" != "$BASE" ]; then ok; else nok "marker ignored"; fi

# ---- check (the stale check) ---------------------------------------------------------------
# An approved plan whose header carries the fingerprint of a fetch of the fixture ticket.
approved_plan() {  # [KEY]: fetch, write a plan, stamp it (picks up the fingerprint), approve by hand
  local k="${1:-PROJ-1}"
  run "$JC" fetch "$k" >/dev/null 2>&1
  printf '# %s: plan\n\n## Changes\n1. do it\n' "$k" > "plans/$k.plan.md"
  "$PS" stamp "plans/$k.plan.md" >/dev/null
  sed "1,/^-->/s/^status: .*/status: approved/" "plans/$k.plan.md" > "plans/$k.plan.md.t" && mv "plans/$k.plan.md.t" "plans/$k.plan.md"
  : > "$ASDLC_FIXTURE_LOG"
}
edit_fx() {  # <fixture file under fx/jira/rest/api/2/> <jq filter>
  jq "$2" "fx/$API/$1" > fx/t && mv fx/t "fx/$API/$1"
}
unchanged_plan() {  # <what>: the plan is byte-identical to $SB/before and nothing else was written
  cmp -s plans/PROJ-1.plan.md "$SB/before" && ok || nok "plan changed ($1)"
  [ ! -e plans/PROJ-1.plan.prev.md ] && ok || nok ".prev written ($1)"
  [ ! -e plans/PROJ-1/changes.md ] && ok || nok "changes.md written ($1)"
}

t "check: an interrupted re-plan keeps changes.md; a .prev with another fingerprint drops it"
ctx_sandbox; approved_plan
edit_fx issue/PROJ-1/comment.json '.total = 6'
edit_fx issue/PROJ-1/comment.startAt-3.json '.total = 6 | .comments += [{"id":"106","author":{"displayName":"Pat Product"},"body":"Please also cover the dark theme.","created":"2026-02-03T00:00:00.000+0000"}]'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "17" "exit"
assert_contains "$(cat plans/PROJ-1/changes.md)" "Approved fingerprint: $(sed -n 's/^ticket_fingerprint: //p' plans/PROJ-1.plan.prev.md)" "changes.md names the fingerprint it compared against"
run "$JC" fetch PROJ-1; assert_eq "$CODE" "0" "re-plan fetch"
[ ! -e plans/PROJ-1.plan.md ] && ok || nok "plan still in place"
assert_contains "$(cat plans/PROJ-1/changes.md)" $'## New comments (ids)\n- 106' "kept by the first fetch"
cp plans/PROJ-1/changes.md "$SB/changes.kept"
run "$JC" fetch PROJ-1; assert_eq "$CODE" "0" "fetch after the interrupted re-plan"
cmp -s plans/PROJ-1/changes.md "$SB/changes.kept" && ok || nok "changes.md lost after an interrupted re-plan"
sed "s/^ticket_fingerprint: .*/ticket_fingerprint: sha256:$(printf 'b%.0s' $(seq 1 64))/" plans/PROJ-1.plan.prev.md > plans/t && mv plans/t plans/PROJ-1.plan.prev.md
run "$JC" fetch PROJ-1; assert_eq "$CODE" "0" "fetch after a newer manual replan"
[ ! -e plans/PROJ-1/changes.md ] && ok || nok "an old changes.md was carried into a later replan"

t "check: an unchanged ticket is FRESH (exit 0), the plan is byte-identical, and nothing but GETs is sent"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "0" "exit"; assert_eq "$OUT" "FRESH" "verdict"; unchanged_plan fresh
assert_eq "$(requests | jq -r '[.[] | select(.method != "GET")] | length')" "0" "only GETs"
assert_not_contains "$(gets)" "PROJ-0" "the parent was fetched"; assert_not_contains "$(gets)" "attachment/content" "a download"
assert_eq "$(requests | jq -r '[.[] | select(.path | endswith("/comment"))] | length')" "2" "both comment pages"
assert_eq "$(ls -a "$SB" | grep -c '^\.fetch\.')" "0" "no stray temp dir"

t "check: FRESH despite a status change, a new pipeline comment (both forms) and a new updated time"
edit_fx issue/PROJ-1.json '.fields.status.name = "Done" | .fields.updated = "2031-01-01T00:00:00.000+0000"'
edit_fx issue/PROJ-1/comment.startAt-3.json '.total = 7 | .comments += [{"id":"900","body":"[asdlc] note","created":"2026-02-01T00:00:00.000+0000"},{"id":"901","body":"\\[asdlc\\] note","created":"2026-02-01T00:00:00.000+0000"}]'
edit_fx issue/PROJ-1/comment.json '.total = 7'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "FRESH/0"; unchanged_plan "metadata only"

t "check: a new human comment is STALE (exit 17): stale status, .prev, changes.md, only GETs"
ctx_sandbox; approved_plan
edit_fx issue/PROJ-1/comment.json '.total = 6'
edit_fx issue/PROJ-1/comment.startAt-3.json '.total = 6 | .comments += [{"id":"106","author":{"displayName":"Pat Product"},"body":"Please also cover the dark theme.","created":"2026-02-03T00:00:00.000+0000"}]'
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "17" "exit"; assert_eq "$OUT" "STALE 1 new comment" "verdict line"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "stale" "status"
run "$PS" check plans/PROJ-1.plan.md; assert_eq "$OUT/$CODE" "STALE/17" "plan-state agrees"
assert_file plans/PROJ-1.plan.prev.md; assert_eq "$("$PS" get plans/PROJ-1.plan.prev.md status)" "stale" ".prev was copied after the status change"
assert_eq "$(sed '1,/^-->/d' plans/PROJ-1.plan.prev.md)" "$(sed '1,/^-->/d' plans/PROJ-1.plan.md)" ".prev body"
CH="$(cat plans/PROJ-1/changes.md)"
assert_contains "$CH" "# Changes to PROJ-1 since the plan was approved" "heading"
assert_contains "$CH" $'## New comments (ids)\n- 106' "comment id"
assert_not_contains "$CH" "dark theme" "comment text is not copied"
assert_not_contains "$CH" "Description edited" "no description section"
assert_eq "$(requests | jq -r '[.[] | select(.method != "GET")] | length')" "0" "only GETs"
assert_eq "$(ls -a plans | grep -c 'XXXXXX\|\.tmp')" "0" "no temp files left in plans/"

t "check: an edited description and a removed comment: summary, 200-line-capped diff"
ctx_sandbox; approved_plan
edit_fx issue/PROJ-1.json '.fields.description += "\nA brand new requirement line."'
edit_fx issue/PROJ-1/comment.json '.total = 4'
edit_fx issue/PROJ-1/comment.startAt-3.json '.total = 4 | .comments |= map(select(.id != "101"))'
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "17" "exit"; assert_eq "$OUT" "STALE 1 removed comment, description edited" "verdict line"
CH="$(cat plans/PROJ-1/changes.md)"
assert_contains "$CH" $'## Removed comments (ids)\n- 101' "removed id"
assert_contains "$CH" "## Description edited (diff, old to new)" "diff heading"
assert_contains "$CH" "+A brand new requirement line." "diff line"
assert_not_contains "$CH" "--- " "no diff file header"
ctx_sandbox; approved_plan
edit_fx issue/PROJ-1.json '.fields.description = ([range(300) | "line \(.)"] | join("\n"))'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "17" "exit"
assert_contains "$(cat plans/PROJ-1/changes.md)" "(diff cut at 200 lines)" "cap"
assert_eq "$(grep -c '^[-+ ]line\|^[-+]' plans/PROJ-1/changes.md | awk '{print ($1 <= 202) ? "ok" : $1}')" "ok" "at most 200 diff lines"

t "check: an edited comment, a new link, a new attachment, a changed parent, an edited title"
ctx_sandbox; approved_plan
edit_fx issue/PROJ-1/comment.json '(.comments[] | select(.id == "105") | .body) += " (edited)"'
edit_fx issue/PROJ-1.json '.fields.issuelinks += [{"type":{"name":"Relates","inward":"relates to","outward":"relates to"},"outwardIssue":{"key":"PROJ-7","fields":{}}}] | .fields.attachment += [{"id":"10099","filename":"n.png","mimeType":"image/png","size":1}] | .fields.parent.key = "PROJ-8" | .fields.summary += " v2"'
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$OUT" "STALE 1 edited comment, title edited, parent changed, 1 link added, 1 attachment added" "verdict line"
CH="$(cat plans/PROJ-1/changes.md)"
assert_contains "$CH" $'## Edited comments (ids)\n- 105'; assert_contains "$CH" "- from PROJ-0 to PROJ-8"
assert_contains "$CH" "- outward Relates PROJ-7"; assert_contains "$CH" "- 10099"
assert_contains "$CH" "+Course page shows wrong badge v2" "title diff"

t "check: a plan that was reset from executing is checked like any approved plan; the report names its branch"
ctx_sandbox; approved_plan
"$PS" set plans/PROJ-1.plan.md branch feature/PROJ-1-badge >/dev/null
"$PS" set plans/PROJ-1.plan.md status executing >/dev/null; "$PS" reset-executing plans/PROJ-1.plan.md >/dev/null
edit_fx issue/PROJ-1.json '.fields.description += " more"'
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "17" "exit"; assert_eq "$OUT" $'STALE description edited\nbranch: feature/PROJ-1-badge' "verdict and branch"
assert_contains "$(cat plans/PROJ-1/changes.md)" "Branch: feature/PROJ-1-badge" "branch in changes.md"

t "check: when the plan's own raw/ is gone or altered, STALE still holds and says details are unavailable"
ctx_sandbox; approved_plan; rm -rf plans/PROJ-1/raw
edit_fx issue/PROJ-1.json '.fields.description += " more"'
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE/$OUT" "17/STALE ticket changed (details unavailable)"; assert_contains "$(cat plans/PROJ-1/changes.md)" "cannot be listed"
ctx_sandbox; approved_plan; jq -c '.fields.description += " tampered"' plans/PROJ-1/raw/issue.json > "$SB/t" && mv "$SB/t" plans/PROJ-1/raw/issue.json
edit_fx issue/PROJ-1.json '.fields.description += " more"'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE/$OUT" "17/STALE ticket changed (details unavailable)" "raw/ no longer hashes to the header value"

t "check: HTTP failures on the issue are UNCHECKED (exit 21); the plan, .prev and changes.md are untouched"
for c in 000 401 403 404 429 500 503; do
  ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
  echo "$c" > "fx/$API/issue/PROJ-1.code"
  edit_fx issue/PROJ-1.json '.fields.description += " changed too"'   # even a changed ticket must not be judged on a failed read
  run "$JC" check plans/PROJ-1.plan.md
  assert_eq "$CODE" "21" "exit ($c)"; assert_contains "$OUT" "UNCHECKED" "verdict ($c)"; assert_not_contains "$OUT" "FRESH"; unchanged_plan "$c"
done
ctx_sandbox; approved_plan; echo 429 > "fx/$API/issue/PROJ-1.code"
run "$JC" check plans/PROJ-1.plan.md; assert_contains "$ERR" "rate limiting" "429 hint"

t "check: a failure on comment page 2, a short page and a malformed page are UNCHECKED"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
echo 503 > "fx/$API/issue/PROJ-1/comment.startAt-3.code"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "503 on page 2"; assert_contains "$OUT" "UNCHECKED comments of PROJ-1 could not be read completely"; assert_contains "$OUT" "HTTP 503"; unchanged_plan "page 2 503"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
edit_fx issue/PROJ-1/comment.json '.total = 6'; edit_fx issue/PROJ-1/comment.startAt-3.json '.total = 6'
echo '{"startAt":5,"maxResults":3,"total":6,"comments":[]}' > "fx/$API/issue/PROJ-1/comment.startAt-5.json"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "pages short of the total"; assert_contains "$OUT" "did not add up"; unchanged_plan "short pages"
assert_eq "$(requests | jq '[.[] | select(.path | endswith("/comment"))] | length')" "6" "retried once"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
echo '{"startAt":3,"total":5,"comments":"nope"}' > "fx/$API/issue/PROJ-1/comment.startAt-3.json"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "malformed page"; unchanged_plan "malformed page"

t "check: a moved key and malformed ticket data are UNCHECKED"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
edit_fx issue/PROJ-1.json '.key = "PROJ-2"'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "moved key"; assert_contains "$OUT" "different ticket"; unchanged_plan "moved key"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
edit_fx issue/PROJ-1.json '.fields.attachment[0].id = "10001x"'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "bad attachment id"; assert_contains "$OUT" "malformed"; unchanged_plan "malformed data"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
echo '<html>gateway</html>' > "fx/$API/issue/PROJ-1.json"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "HTML instead of JSON"; unchanged_plan "html"

t "check: a timeout (curl exit 28) and a missing config are UNCHECKED"
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
unset ASDLC_FIXTURES; export FAKECURL_LOG="$SB/curl.log"; : > "$FAKECURL_LOG"
PATH="$ROOT/tests/jira/fakebin:$PATH" JIRA_EMAIL=me@example.com JIRA_TOKEN=s3cr3t-value FAKECURL_EXIT=28 FAKECURL_CODE=000 run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "timeout"; assert_contains "$OUT" "UNCHECKED could not reach Jira"; unchanged_plan "timeout"
assert_contains "$(cat "$FAKECURL_LOG")" "--max-time" "requests carry a time limit"
assert_not_contains "$OUT$ERR" "s3cr3t-value" "token on output"
unset FAKECURL_LOG
ctx_sandbox; approved_plan; cp plans/PROJ-1.plan.md "$SB/before"; mv .asdlc/jira.conf "$SB/jira.conf.off"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "no config"; assert_contains "$OUT" "UNCHECKED"; unchanged_plan "no config"
mv "$SB/jira.conf.off" .asdlc/jira.conf
sed 's/^JIRA_BASE_URL=.*/JIRA_BASE_URL=http:\/\/evil.example.com/' .asdlc/jira.conf > "$SB/c" && mv "$SB/c" .asdlc/jira.conf
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "refused URL"; unchanged_plan "refused URL"
assert_eq "$(requests)" "[]" "no request"

t "check: an mcp plan with no MCP request is UNCHECKED (connect or replan), never over REST; an unknown source is UNCHECKED"
ctx_sandbox; approved_plan
sed 's/^fingerprint_source: .*/fingerprint_source: mcp/' plans/PROJ-1.plan.md > "$SB/t" && mv "$SB/t" plans/PROJ-1.plan.md; cp plans/PROJ-1.plan.md "$SB/before"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "exit"; assert_contains "$OUT" "UNCHECKED no open MCP request for PROJ-1" "reason"
assert_contains "$OUT" "connect the Atlassian MCP (/mcp), or /asdlc:plan replan PROJ-1 to plan over REST" "the connect-or-replan message"
assert_eq "$(requests)" "[]" "no request"; unchanged_plan "mcp"
sed 's/^fingerprint_source: .*/fingerprint_source: x y/' plans/PROJ-1.plan.md > "$SB/t" && mv "$SB/t" plans/PROJ-1.plan.md
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "odd source"

t "check: not applicable gives exit 2 and no request (no fingerprint, not RUNNABLE, not a Jira ticket, no plan, bad usage)"
ctx_sandbox; run "$JC" fetch PROJ-1 >/dev/null 2>&1; printf '# p\n\n## Changes\n1. x\n' > plans/PROJ-1.plan.md
rm plans/PROJ-1/fingerprint; "$PS" stamp plans/PROJ-1.plan.md >/dev/null
assert_eq "$("$PS" get plans/PROJ-1.plan.md ticket_fingerprint)" "" "stamped without a fingerprint"
sed "1,/^-->/s/^status: .*/status: approved/" plans/PROJ-1.plan.md > "$SB/t" && mv "$SB/t" plans/PROJ-1.plan.md; : > "$ASDLC_FIXTURE_LOG"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "2" "no fingerprint"; assert_contains "$ERR" "re-plan"; assert_eq "$OUT" "" "stdout"
ctx_sandbox; approved_plan; sed "1,/^-->/s/^status: .*/status: pending/" plans/PROJ-1.plan.md > "$SB/t" && mv "$SB/t" plans/PROJ-1.plan.md
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "2" "pending"; assert_contains "$ERR" "not RUNNABLE"
for st in executing done stale needs-info; do
  sed "1,/^-->/s/^status: .*/status: $st/" plans/PROJ-1.plan.md > "$SB/t" && mv "$SB/t" plans/PROJ-1.plan.md
  run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "2" "$st"
done
ctx_sandbox; mkdir plans; printf '# prd plan\n\n## Changes\n1. x\n' > plans/my-prd.plan.md; "$PS" stamp plans/my-prd.plan.md >/dev/null
sed "1,/^-->/s/^status: .*/status: approved/" plans/my-prd.plan.md > "$SB/t" && mv "$SB/t" plans/my-prd.plan.md
run "$JC" check plans/my-prd.plan.md; assert_eq "$CODE" "2" "non-Jira id"; assert_contains "$ERR" "not a Jira key"
run "$JC" check plans/PROJ-9.plan.md; assert_eq "$CODE" "2" "no plan file"
run "$JC" check; assert_eq "$CODE" "2" "no argument"; run "$JC" check a b; assert_eq "$CODE" "2" "two arguments"
run "$JC" check plans/my-prd.md; assert_eq "$CODE" "2" "not a plan file name"
assert_eq "$(requests)" "[]" "no request on any refusal"

# ---- one issue read, one entry point (SF-1, N-8, N-9, N-10, N-5) -----------------------------
issue_fields() {  # the fields= of the first issue GET in the request log
  requests | jq -r '[.[] | select(.method == "GET" and .path == "/rest/api/2/issue/PROJ-1")][0].args | map(select(startswith("fields="))) | .[0]'
}

t "fetch and check read the issue with an identical fields= (one ISSUE_FIELDS)"
ctx_sandbox; run "$JC" fetch PROJ-1; FF="$(issue_fields)"
assert_contains "$FF" "fields=summary,description" "fetch asks for fields"
approved_plan; run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "0" "check exit"
assert_eq "$(issue_fields)" "$FF" "check's issue request carries fetch's fields="

t "every source build can write is accepted by stamp, and is what the fingerprint file says"
BS="$(sed -n 's/^BUILD_SOURCES="\(.*\)"$/\1/p' "$S/jira-context.sh")"
assert_contains "$BS" "rest" "BUILD_SOURCES readable"
for src in $BS; do
  ctx_sandbox
  if [ "$src" = mcp ]; then mcp_caps; run "$JC" fetch PROJ-1 --source mcp; else run "$JC" fetch PROJ-1; fi
  run "$JC" build PROJ-1 --source "$src"; assert_eq "$CODE" "0" "build --source $src"
  assert_eq "$(sed -n 3p plans/PROJ-1/fingerprint)" "fingerprint_source: $src" "written source ($src)"
  printf '# PROJ-1: plan\n\n## Changes\n1. do it\n' > plans/PROJ-1.plan.md
  run "$PS" stamp plans/PROJ-1.plan.md; assert_eq "$CODE" "0" "stamp accepts $src"
  assert_eq "$("$PS" get plans/PROJ-1.plan.md fingerprint_source)" "$src" "stamped source ($src)"
done

t "build refuses an unknown or missing --source with exit 2"
ctx_sandbox; run "$JC" fetch PROJ-1
for bad in soap "" "rest mcp"; do
  run "$JC" build PROJ-1 --source "$bad"; assert_eq "$CODE" "2" "source [$bad]"; assert_contains "$ERR" "--source" "usage"
done
run "$JC" build PROJ-1 --source; assert_eq "$CODE" "2" "--source without a value"

t "fetch: a 503 on comment page 2 exits 1 and writes nothing"
ctx_sandbox; echo 503 > "fx/$API/issue/PROJ-1/comment.startAt-3.code"
run "$JC" fetch PROJ-1; assert_eq "$CODE" "1" "exit"; assert_contains "$ERR" "HTTP 503"
[ ! -e plans/PROJ-1/raw ] && [ ! -e plans/PROJ-1/context.md ] && [ ! -e plans/PROJ-1/fingerprint ] && ok || nok "something was written"
assert_eq "$(ls -a plans/PROJ-1 | grep -c '^\.fetch\.')" "0" "temp dir cleaned up"

t "fixture mode: said on stderr whenever fixtures are used; the stale check refuses it unless a test says so"
ctx_sandbox; run "$JC" fetch PROJ-1; assert_contains "$ERR" "fixture mode: Jira was not contacted" "fetch notice"
approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
run env -u ASDLC_TEST_FIXTURE_CHECK "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "refused"; assert_contains "$OUT" "UNCHECKED fixture mode is for tests" "verdict"
assert_not_contains "$OUT" "FRESH"; assert_eq "$(requests)" "[]" "no request"; unchanged_plan "fixture refusal"
run env ASDLC_TEST_FIXTURE_CHECK=1 "$JC" check plans/PROJ-1.plan.md
assert_eq "$OUT/$CODE" "FRESH/0" "allowed for tests"; assert_contains "$ERR" "fixture mode: Jira was not contacted" "check notice"
run env ASDLC_TEST_FIXTURE_CHECK=0 "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "only the value 1 allows it"
cd "$SB" && ASDLC_FIXTURES="$SB/fx" run env -u ASDLC_TEST_FIXTURE_CHECK "$JC" check --fixtures "$SB/fx" plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "--fixtures is refused the same way"

t "the transport functions never end the script (N-9): no exit in them"
for fn in fetch_comments rest_read_issue source_read; do
  body="$(awk -v f="$fn" '$0 ~ "^" f "\\(\\)" {on=1} on {print} on && /^}/ {exit}' "$S/jira-context.sh")"
  assert_contains "$body" "$fn()" "found $fn"
  if printf '%s\n' "$body" | grep -qE '(^|[^A-Za-z_-])exit([^A-Za-z_-]|$)'; then nok "$fn calls exit"; else ok; fi
done

t "N-10: the fingerprint and the change report both come from the facts program"
assert_eq "$(grep -c 'facts(' "$S/context-lib.sh")" "3" "definition, fingerprint and snapshot"
ctx_sandbox; run "$JC" fetch PROJ-1; run "$JC" fingerprint plans/PROJ-1/raw; assert_contains "$OUT" "sha256:"

t "N-5: fetch.json records a hash of the marker; a changed marker is named in the report"
assert_eq "$(jq -r '.marker_sha256' plans/PROJ-1/raw/fetch.json | awk '{print length($0)}')" "64" "marker_sha256 in fetch.json"
approved_plan; cp plans/PROJ-1.plan.md "$SB/before"
echo 'PIPELINE_COMMENT_MARKER=[other]' >> .asdlc/jira.conf
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE/$OUT" "17/STALE ticket changed (pipeline marker changed since the plan was made)" "named"
assert_contains "$(cat plans/PROJ-1/changes.md)" "PIPELINE_COMMENT_MARKER" "changes.md says why"

# ---- the mcp source: fetch / build from captured MCP responses -----------------------------
# The captures are written the way the capture hook writes them (tests/jira/test-mcp-capture.sh
# covers the hook); fixture mode serves the REST attachment content and counts as a Jira login.
t "mcp fetch: raw/, context.md and the fingerprint file; stdout has counts only; REST is only used for the image"
mcp_sandbox
run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "plans/PROJ-1/context.md — 2 comments (1 pipeline left out), parent PROJ-0, 2 links, 1 images (1 skipped)" "summary line"
for f in raw/mcp-issue.json raw/mcp-parent.json raw/fetch.json context.md fingerprint assets/10001-badge_screenshot.png; do assert_file "plans/PROJ-1/$f"; done
[ ! -e plans/PROJ-1/raw/issue.json ] && ok || nok "a REST issue.json next to the capture"
assert_eq "$(jq -r '[.source, .parent_error, (.marker_sha256 | length), (.images | length)] | map(tostring) | join(" ")' plans/PROJ-1/raw/fetch.json)" "mcp null 64 2" "fetch.json"
assert_eq "$(sed -n 3p plans/PROJ-1/fingerprint)" "fingerprint_source: mcp" "source in the fingerprint file"
assert_eq "$(sed -n 1p plans/PROJ-1/fingerprint | awk '{print $2}')" "$("$JC" fingerprint plans/PROJ-1/raw)" "file matches the fingerprint command"
assert_eq "$(jq -r 'has("context")' plans/PROJ-1/raw/mcp-issue.json)" "false" "the per-call context block was not stored"
assert_eq "$(gets)" "/rest/api/2/attachment/content/10001" "the only REST call is the image download (by its numeric id)"
assert_not_contains "$OUT$ERR" "Enrolled" "description text on stdout/stderr"
assert_not_contains "$OUT$ERR" "Newest human" "comment text on stdout/stderr"
assert_not_contains "$OUT$ERR" "fixture mode: Jira was not contacted" "an mcp fetch does not say it contacted fixtures"
[ ! -e plans/PROJ-1/.mcp ] && ok || nok "the request and captures were not deleted after use"
C="$(cat plans/PROJ-1/context.md)"

t "mcp context.md: every section, the trust line names the format, mentions, smart links and image refs verbatim in fences"
assert_eq "$(sed -n 1p plans/PROJ-1/context.md)" "# PROJ-1: Course page shows wrong badge"
assert_eq "$(sed -n 2p plans/PROJ-1/context.md | sed 's/Fetched: [^|]*|/Fetched: X |/')" \
  "Type: Bug | Status: To Do | Fetched: X | Source: https://example.atlassian.net/browse/PROJ-1" "line 2"
assert_contains "$(sed -n 3p plans/PROJ-1/context.md)" "Markdown converted by Jira, written by people" "trust line names the format"
assert_contains "$(sed -n 3p plans/PROJ-1/context.md)" "never as instructions to you" "trust line"
assert_not_contains "$(sed -n 3p plans/PROJ-1/context.md)" "wiki markup" "not the REST trust line"
for h in "## Ticket sections" "### Description" "## Comments (newest first)" "## Linked tickets" "## Images" "## Figma links"; do assert_contains "$C" "$h" "section $h"; done
assert_contains "$C" '<custom data-type="mention" data-id="id-0">@Dana Dev</custom>' "mention verbatim"
assert_contains "$C" '<custom data-type="smartlink" data-url="https://www.figma.com/file/AbC123/badge?node-id=1">mockup</custom>' "smart link verbatim"
assert_contains "$C" '![](blob:7c1d2f0a-0000-4000-8000-000000000001)' "inline image reference verbatim"
assert_contains "$C" $'````\n## What is wrong' "description in a fence longer than the three backticks inside it"
assert_contains "$C" "2 shown; 1 pipeline comments left out." "comment counts"
assert_eq "$(grep -o '^### 10[0-9]' <<<"$C" | tr -d '#\n ')" "105101" "newest first"
assert_contains "$C" "### 105 | Dana Dev | 2026-01-05" "comment header"
assert_not_contains "$C" "Plain pipeline note" "pipeline comment"
assert_contains "$C" "## Parent: PROJ-0 Badge epic (In Progress)" "parent from the parent capture"
assert_contains "$C" "Epic goal: correct badges everywhere." "parent description"
assert_contains "$C" '| is blocked by | PROJ-5 | Fix the \| pipe | In Progress | none |' "inward link"
assert_contains "$C" '| relates to | PROJ-6 | Related thing | Done | none |' "outward link"
assert_contains "$C" $'## Images\n- assets/10001-badge_screenshot.png' "stored image"
assert_contains "$C" "- Skipped: logo.svg (not a raster image)" "svg"
assert_contains "$C" $'- https://www.figma.com/file/AbC123/badge?node-id=1\n' "figma link from the smart link, ending at the quote"
assert_contains "$C" "- https://www.figma.com/file/XyZ789/other" "figma link from a comment"

t "mcp fingerprint: one pinned literal (tag asdlc-ticket-fp-mcp-v1), next to the REST pins"
MBASE="$(fp plans/PROJ-1/raw)"
assert_eq "$MBASE" "sha256:abfe15f42a5072967a88b2a0d84572f43449922bd07081c36f4190b2622456f3" "pinned mcp fingerprint of the fixture capture"
assert_eq "$(fp "$FIXTURES/context/fp-nonstring")" "sha256:cae23bca8ac7b58d5a02c75fecd7a172178e2f08132ba3435e4249b3d10fdb0a" "the REST pin is still the REST pin"
assert_eq "$(grep -c "asdlc-ticket-fp-mcp-v1'" "$S/context-lib.sh")" "1" "the mcp tag is defined once"
assert_eq "$(grep -c "asdlc-ticket-fp-v1'" "$S/context-lib.sh")" "1" "the REST tag is still defined once"

mvariant() {  # <name> <jq filter over mcp-issue.json>
  rm -rf "${SB:?}/${1:?}"; cp -R plans/PROJ-1/raw "$SB/$1"; jq -c "$2" plans/PROJ-1/raw/mcp-issue.json > "$SB/$1/mcp-issue.json"
}
msame()   { assert_eq "$(fp "$2")" "$MBASE" "$1 must not change the fingerprint"; }
mdiffers() { local v; v="$(fp "$2")"; if [ "$v" != "$MBASE" ] && [ -n "$v" ]; then ok; else nok "$1 must change the fingerprint"; fi; }

t "mcp fingerprint: ignores key order, the context block, the wrapper, pipeline comments, status and comment order"
rm -rf "$SB/x"; cp -R plans/PROJ-1/raw "$SB/x"; jq -S . plans/PROJ-1/raw/mcp-issue.json > "$SB/x/mcp-issue.json"; msame "sorted key order" "$SB/x"
mvariant x '{context: {cloudId: "other-call-id", requestId: "r-9"}, issues: {nodes: [.]}}'; msame "the response wrapper and a different context block" "$SB/x"
mvariant x '.fields.status.name = "Done" | .fields.updated = "2030-01-01T00:00:00.000+0000" | .fields.comment.comments += [{"id":"900","body":"[asdlc] bot note"}]'
msame "status, updated and a new pipeline comment" "$SB/x"
mvariant x '.fields.comment.comments |= reverse'; msame "reversed comment order" "$SB/x"
mvariant x '.fields.description |= gsub("\n"; "\r\n")'; msame "CRLF description" "$SB/x"
mvariant x '.fields.comment.maxResults = 5'; msame "maxResults" "$SB/x"
rm -rf "$SB/x"; cp -R plans/PROJ-1/raw "$SB/x"; rm "$SB/x/mcp-parent.json"; msame "the parent capture (only the parent key counts)" "$SB/x"

t "mcp fingerprint: changes with an edited comment, a new comment, an added link, an edited description, a new attachment"
mvariant x '(.fields.comment.comments[] | select(.id == "105") | .body) += " (edited)"'; mdiffers "edited comment" "$SB/x"
mvariant x '.fields.comment.comments += [{"id":"900","body":"human follow-up"}]'; mdiffers "new human comment" "$SB/x"
mvariant x '.fields.issuelinks += [{"type":{"name":"Relates","inward":"relates to","outward":"relates to"},"outwardIssue":{"key":"PROJ-7","fields":{}}}]'; mdiffers "added link" "$SB/x"
mvariant x '.fields.description += " more"'; mdiffers "edited description" "$SB/x"
mvariant x '.fields.attachment += [{"id":"10099","filename":"n.png","mimeType":"image/png","size":1}]'; mdiffers "new attachment" "$SB/x"
mvariant x '.fields.parent.key = "PROJ-8"'; mdiffers "changed parent" "$SB/x"
# the same facts under the other source hash differently, so a REST plan can never match an MCP read
rm -rf "$SB/x"; cp -R plans/PROJ-1/raw "$SB/x"; jq 'del(.source)' plans/PROJ-1/raw/fetch.json > "$SB/x/fetch.json"
mkdir -p "$SB/y"; cp plans/PROJ-1/raw/fetch.json "$SB/y/fetch.json"
rm -rf "$SB/x/mcp-parent.json"; jq -c '(.issues.nodes[0] // .) | del(.fields.comment)' plans/PROJ-1/raw/mcp-issue.json > "$SB/x/issue.json"
jq -c '.fields.comment | {comments, total, startAt, maxResults}' plans/PROJ-1/raw/mcp-issue.json > "$SB/x/comments-0.json"; rm -f "$SB/x/mcp-issue.json"
mdiffers "the REST tag over the same facts" "$SB/x"
run "$JC" fingerprint "$SB/y"; assert_eq "$CODE" "2" "an mcp raw dir with no capture file is refused"
rm -rf "$SB/x"; cp -R plans/PROJ-1/raw "$SB/x"; jq '.source = "ftp"' plans/PROJ-1/raw/fetch.json > "$SB/x/fetch.json"
run "$JC" fingerprint "$SB/x"; assert_eq "$CODE" "2" "an unknown source is refused"

t "mcp build: rebuilds from raw/; refuses a source that is not the raw dir's"
run "$JC" build PROJ-1 --source mcp; assert_eq "$CODE" "0" "rebuild exit"
assert_eq "$(sed -n 3p plans/PROJ-1/fingerprint)" "fingerprint_source: mcp" "source"
assert_eq "$(sed -n 1p plans/PROJ-1/fingerprint | awk '{print $2}')" "$MBASE" "same fingerprint"
run "$JC" build PROJ-1 --source rest; assert_eq "$CODE" "2" "rest over an mcp raw dir"; assert_contains "$ERR" "fetched from mcp"
ctx_sandbox; run "$JC" fetch PROJ-1 >/dev/null 2>&1; run "$JC" build PROJ-1 --source mcp
assert_eq "$CODE" "2" "mcp over a REST raw dir"; assert_contains "$ERR" "fetched from rest, not mcp"

t "mcp fetch: a plan that is not STALE is refused, left byte-identical, and the capture is kept"
for st in pending approved executing done; do
  mcp_sandbox; plan_file PROJ-1 $st; cp plans/PROJ-1.plan.md "$SB/before"
  run "$JC" fetch PROJ-1 --source mcp
  assert_eq "$CODE" "2" "exit ($st)"; assert_contains "$ERR" "refusing" "message ($st)"
  cmp -s plans/PROJ-1.plan.md "$SB/before" && ok || nok "plan changed ($st)"
  assert_file plans/PROJ-1/.mcp/request.json; [ ! -e plans/PROJ-1/raw ] && ok || nok "wrote a bundle ($st)"
done
mcp_sandbox; plan_file PROJ-1 pending; run "$JC" build PROJ-1 --source mcp; assert_eq "$CODE" "2" "build refuses too"

t "mcp fetch: a STALE plan is moved to .prev and the context is rebuilt from the new capture"
mcp_sandbox; plan_file PROJ-1 stale; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "0" "exit"; [ ! -e plans/PROJ-1.plan.md ] && [ -e plans/PROJ-1.plan.prev.md ] && ok || nok "stale plan not moved"

t "mcp fetch: truncated comments exit 3 under auto with a Jira login, exit 1 otherwise; nothing is written"
TRUNC='.fields.comment.total = 7'
ctx_sandbox; mcp_caps "$TRUNC"
run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "3" "exit with a login ready (auto)"; assert_contains "$ERR" "comments truncated (3 of 7); fetch over REST" "message"
assert_eq "$OUT" "" "stdout"; [ ! -e plans/PROJ-1/raw ] && [ ! -e plans/PROJ-1/context.md ] && [ ! -e plans/PROJ-1/fingerprint ] && ok || nok "wrote files"
assert_eq "$(ls -a plans/PROJ-1 | grep -c '^\.fetch\.')" "0" "no temp dir left"
assert_not_contains "$OUT$ERR" "Enrolled" "ticket text"
mcp_caps "$TRUNC"; conf_set JIRA_TRANSPORT auto; run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "3" "JIRA_TRANSPORT=auto spelled out"
mcp_caps "$TRUNC"; conf_set JIRA_TRANSPORT mcp; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "1" "JIRA_TRANSPORT=mcp never falls back"; assert_contains "$ERR" "comments truncated (3 of 7)" "message"
assert_not_contains "$ERR" "fetch over REST;" "no instruction to fetch over REST"
conf_set JIRA_TRANSPORT auto
mcp_caps "$TRUNC"; run env -u ASDLC_FIXTURES "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "1" "no Jira login"; assert_contains "$ERR" "comments truncated (3 of 7)" "message"; assert_contains "$ERR" "nothing was written" "says nothing was written"
mcp_caps '.fields.comment.startAt = 3'; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "3" "a later page"; assert_contains "$ERR" "comments truncated (3 of 3)" "message"
mcp_caps '.fields.comment.total = 2'; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "3" "more comments returned than the total says"
mcp_caps 'del(.fields.comment)'; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "1" "no comment list at all"; assert_contains "$ERR" "no readable comment list" "message"
mcp_caps; run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "0" "a whole thread is fine"

t "mcp images: without a Jira login the image is skipped with the reason and nothing is downloaded"
mcp_sandbox; run env -u ASDLC_FIXTURES "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "0" "exit"
assert_eq "$OUT" "plans/PROJ-1/context.md — 2 comments (1 pipeline left out), parent PROJ-0, 2 links, 0 images (2 skipped)" "summary line"
C="$(cat plans/PROJ-1/context.md)"
assert_contains "$C" "- Skipped: badge_screenshot.png (no Jira token: the MCP connector can't download attachments)" "skipped with the reason"
assert_contains "$C" "- Skipped: logo.svg (not a raster image)" "the metadata still rules out the svg"
assert_eq "$(ls plans/PROJ-1/assets | wc -l | tr -d ' ')" "0" "no asset"
mcp_sandbox MAX_IMAGES=0; run "$JC" fetch PROJ-1 --source mcp
assert_contains "$(cat plans/PROJ-1/context.md)" $'## Images\n(none)' "downloads off"; assert_not_contains "$(gets)" "attachment/content" "nothing requested"
mcp_sandbox; conf_set JIRA_TRANSPORT mcp; run "$JC" fetch PROJ-1 --source mcp
assert_contains "$(cat plans/PROJ-1/context.md)" $'## Images\n- assets/10001-badge_screenshot.png' "a ready login downloads, whatever the transport"

t "mcp parent: without a parent capture the context says so; a capture of another key is ignored"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "0" "exit"
assert_contains "$(cat plans/PROJ-1/context.md)" $'\n## Parent: PROJ-0 (not fetched)' "not fetched"
assert_not_contains "$(cat plans/PROJ-1/context.md)" "could not be read" "no HTTP wording"
assert_eq "$(ls plans/PROJ-1/raw | tr '\n' ' ')" "fetch.json mcp-issue.json " "no parent file"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
write_cap PROJ-1 parent "$MCPFX/parent.response.json" 0 "" '.key = "PROJ-9"'
run "$JC" fetch PROJ-1 --source mcp; assert_contains "$(cat plans/PROJ-1/context.md)" "## Parent: PROJ-0 (not fetched)" "a parent capture for another key"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json" 0 "" '.fields.parent = null'
write_cap PROJ-1 parent "$MCPFX/parent.response.json"
run "$JC" fetch PROJ-1 --source mcp; assert_not_contains "$(cat plans/PROJ-1/context.md)" "## Parent" "no parent on the ticket, so a stray parent capture is unused"
assert_contains "$OUT" "no parent" "summary"

t "mcp capture consumption: nonce, purpose, age, expiry, newest wins, use once"
ctx_sandbox; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "1" "no request"; assert_contains "$ERR" "no open MCP request for PROJ-1" "message"; [ ! -e plans/PROJ-1/raw ] && ok || nok "wrote raw"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "request but no capture"; assert_contains "$ERR" "no valid capture of PROJ-1" "message"
assert_file plans/PROJ-1/.mcp/request.json
write_cap PROJ-1 issue "$MCPFX/issue.response.json" 0 "ffffffffffffffffffffffff"
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "another request's nonce"; assert_contains "$ERR" "no valid capture" "message"
write_cap PROJ-1 issue "$MCPFX/issue.response.json" -1
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "a capture older than the request"
assert_file plans/PROJ-1/.mcp/request.json; assert_eq "$(ls plans/PROJ-1/.mcp | grep -c '^cap-')" "2" "rejected captures are left alone, not used"
write_cap PROJ-1 issue "$MCPFX/issue.response.json" 0 "" '.key = "PROJ-2"'
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "a capture of another ticket"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for check; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "a check request is not a fetch request"; assert_contains "$ERR" "is for check, not fetch" "message"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
jq '.expires_epoch = (.created_epoch - 1)' plans/PROJ-1/.mcp/request.json > plans/t && mv plans/t plans/PROJ-1/.mcp/request.json
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "expired request"; assert_contains "$ERR" "has expired" "message"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
jq '.v = 2' plans/PROJ-1/.mcp/request.json > plans/t && mv plans/t plans/PROJ-1/.mcp/request.json
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "unreadable request"; assert_contains "$ERR" "unreadable" "message"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch
write_cap PROJ-1 issue "$MCPFX/issue.response.json" 1 "" '.fields.summary = "Older capture"'
write_cap PROJ-1 issue "$MCPFX/issue.response.json" 5 "" '.fields.summary = "Newest capture"'
write_cap PROJ-1 issue "$MCPFX/issue.response.json" 3 "" '.fields.summary = "Middle capture"'
write_cap PROJ-1 parent "$MCPFX/parent.response.json"
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "0" "exit"
assert_eq "$(sed -n 1p plans/PROJ-1/context.md)" "# PROJ-1: Newest capture" "the newest valid capture wins"
[ ! -e plans/PROJ-1/.mcp ] && ok || nok "the request and every capture are deleted after use"
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "use once: the same capture cannot be used twice"; assert_contains "$ERR" "no open MCP request" "message"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
mv plans/PROJ-1/.mcp "$SB/mcpdir"; ln -s "$SB/mcpdir" plans/PROJ-1/.mcp
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "a symlinked .mcp"; assert_contains "$ERR" "symbolic link" "message"
ctx_sandbox; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
mv plans/PROJ-1/.mcp/cap-*.json "$SB/real.json"; ln -s "$SB/real.json" plans/PROJ-1/.mcp/cap-1-1.json
run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "1" "a symlinked capture is not read"

t "mcp transport: JIRA_TRANSPORT=rest refuses an mcp fetch; a bad value and a bad --source are usage errors; REST fetch is unchanged"
mcp_sandbox; conf_set JIRA_TRANSPORT rest; run "$JC" fetch PROJ-1 --source mcp
assert_eq "$CODE" "2" "rest transport"; assert_contains "$ERR" "JIRA_TRANSPORT=rest" "message"; assert_file plans/PROJ-1/.mcp/request.json
conf_set JIRA_TRANSPORT bogus; run "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "2" "bad transport"
run "$JC" fetch PROJ-1 --source ftp; assert_eq "$CODE" "2" "unknown source"
run "$JC" fetch PROJ-1 --source; assert_eq "$CODE" "2" "source without a value"
run "$JC" fetch PROJ-1 extra; assert_eq "$CODE" "2" "stray argument"
ctx_sandbox; conf_set JIRA_TRANSPORT mcp; run "$JC" fetch PROJ-1; assert_eq "$CODE" "0" "a plain fetch is still REST"
assert_eq "$(sed -n 3p plans/PROJ-1/fingerprint)" "fingerprint_source: rest" "source"
assert_eq "$(jq -r 'has("source")' plans/PROJ-1/raw/fetch.json)" "false" "REST fetch.json is unchanged"
mcp_sandbox; run env -u ASDLC_FIXTURES -u JIRA_EMAIL -u JIRA_TOKEN "$JC" fetch PROJ-1 --source mcp; assert_eq "$CODE" "0" "mcp fetch needs no token"

# ---- the stale check for mcp plans, and the transport report -------------------------------
mcp_approved_plan() {  # a plan made over MCP: fetch from captures, stamp, approve by hand
  ctx_sandbox; mcp_caps
  run "$JC" fetch PROJ-1 --source mcp >/dev/null 2>&1
  printf '# PROJ-1: plan\n\n## Changes\n1. do it\n' > plans/PROJ-1.plan.md
  "$PS" stamp plans/PROJ-1.plan.md >/dev/null
  sed "1,/^-->/s/^status: .*/status: approved/" plans/PROJ-1.plan.md > plans/PROJ-1.plan.md.t && mv plans/PROJ-1.plan.md.t plans/PROJ-1.plan.md
  : > "$ASDLC_FIXTURE_LOG"; cp plans/PROJ-1.plan.md "$SB/before"
}
check_caps() {  # [issue filter] [epoch offset]: open a check request and capture the issue under it
  run "$JC" mcp-request PROJ-1 --for check
  write_cap PROJ-1 issue "$MCPFX/issue.response.json" "${2:-0}" "" "${1:-}"
}

t "mcp check: FRESH from a check capture, no REST request, no token needed; the capture is used once"
mcp_approved_plan
assert_eq "$("$PS" get plans/PROJ-1.plan.md fingerprint_source)" "mcp" "an mcp plan"
check_caps; run env -u ASDLC_FIXTURES -u JIRA_EMAIL -u JIRA_TOKEN "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE/$OUT" "0/FRESH" "verdict"; assert_eq "$ERR" "" "stderr"
[ ! -e plans/PROJ-1/.mcp ] && ok || nok "the request and capture were not deleted after use"
cmp -s plans/PROJ-1.plan.md "$SB/before" && ok || nok "plan changed"
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "a second check without a new capture"; assert_contains "$OUT" "UNCHECKED no open MCP request" "reason"; unchanged_plan "second check"
check_caps; run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE/$OUT" "0/FRESH" "a new request and capture work again"
assert_eq "$(requests)" "[]" "no REST request at all"

t "mcp check: STALE on an edited comment; changes.md lists its id and says the text is Markdown"
mcp_approved_plan
check_caps '.fields.comment.comments[0].body = "Edited: the copy changed."'
run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "17" "exit"; assert_eq "$(printf '%s' "$OUT" | head -n1)" "STALE 1 edited comment" "verdict"
assert_eq "$("$PS" get plans/PROJ-1.plan.md status)" "stale" "plan marked stale"
assert_file plans/PROJ-1.plan.prev.md
CM="$(cat plans/PROJ-1/changes.md)"
assert_contains "$CM" "## Edited comments (ids)"$'\n'"- 105" "the edited comment id"
assert_contains "$CM" "Markdown converted by Jira, written by people" "the trust line names the format"
assert_not_contains "$CM" "wiki markup" "no wiki markup claim for an mcp plan"
assert_not_contains "$OUT$ERR" "Edited: the copy changed." "comment text on stdout/stderr"
[ ! -e plans/PROJ-1/.mcp ] && ok || nok "capture kept after a verdict"
mcp_approved_plan; check_caps '.fields.issuelinks += [{"id":"9","type":{"name":"Relates","inward":"relates to","outward":"relates to"},"outwardIssue":{"key":"PROJ-77","fields":{"summary":"x","status":{"name":"To Do"}}}}]'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "17" "an added link"; assert_contains "$OUT" "1 link added" "verdict"
t "a REST plan's changes.md still says wiki markup"
ctx_sandbox; approved_plan; edit_fx issue/PROJ-1/comment.json '.comments[0].body = "edited"'
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "17" "exit"
assert_contains "$(cat plans/PROJ-1/changes.md)" "Jira wiki markup written by people" "REST trust line"

t "mcp check: UNCHECKED, plan byte-identical, for no capture, no request, an old, an expired and a mismatched capture, truncation, and a wrong purpose"
mcp_approved_plan; run "$JC" mcp-request PROJ-1 --for check
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "request, no capture"; assert_contains "$OUT" "no valid capture of PROJ-1" "reason"
assert_contains "$OUT" "connect the Atlassian MCP (/mcp)" "connect or replan"; unchanged_plan "no capture"
assert_file plans/PROJ-1/.mcp/request.json
mcp_approved_plan; run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "no request"; assert_contains "$OUT" "no open MCP request for PROJ-1" "reason"; unchanged_plan "no request"
mcp_approved_plan; check_caps "" -1; run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "a capture older than its request"; assert_contains "$OUT" "no valid capture" "reason"; unchanged_plan "older capture"
mcp_approved_plan; check_caps; jq '.expires_epoch = (now | floor) - 5' plans/PROJ-1/.mcp/request.json > "$SB/r" && mv "$SB/r" plans/PROJ-1/.mcp/request.json
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "an expired request"; assert_contains "$OUT" "has expired" "reason"; unchanged_plan "expired"
mcp_approved_plan; check_caps '.key = "PROJ-2"'; run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "a capture of another ticket"; unchanged_plan "mismatch"
mcp_approved_plan; run "$JC" mcp-request PROJ-1 --for check; write_cap PROJ-1 issue "$MCPFX/issue.response.json" 0 "ffffffffffffffffffffffff"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "another request's nonce"; unchanged_plan "nonce"
mcp_approved_plan; check_caps '.fields.comment.total = 7'; run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "truncated comments"; assert_contains "$OUT" "comments truncated (3 of 7)" "reason"; unchanged_plan "truncated"
assert_eq "$(requests)" "[]" "truncation is not fetched over REST in a check"
mcp_approved_plan; run "$JC" mcp-request PROJ-1 --for fetch; write_cap PROJ-1 issue "$MCPFX/issue.response.json"
run "$JC" check plans/PROJ-1.plan.md; assert_eq "$CODE" "21" "a fetch request is not a check request"; assert_contains "$OUT" "is for fetch, not check" "reason"; unchanged_plan "purpose"
assert_eq "$(printf '%s' "$OUT" | wc -l | tr -d ' ')" "0" "one verdict line"

t "mcp check: JIRA_TRANSPORT=rest never checks an mcp plan over REST; a REST plan goes over REST under JIRA_TRANSPORT=mcp"
mcp_approved_plan; check_caps; conf_set JIRA_TRANSPORT rest; run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE" "21" "exit"; assert_contains "$OUT" "JIRA_TRANSPORT=rest forbids MCP" "reason"; unchanged_plan "rest transport"
assert_eq "$(requests)" "[]" "no REST request"
ctx_sandbox; approved_plan; conf_set JIRA_TRANSPORT mcp; run "$JC" check plans/PROJ-1.plan.md
assert_eq "$CODE/$OUT" "0/FRESH" "a rest plan under JIRA_TRANSPORT=mcp"; assert_contains "$(gets)" "/issue/PROJ-1" "went over REST"
[ ! -e plans/PROJ-1/.mcp ] && ok || nok "no request was opened"

t "transport: prints the settings with no network and no config"
sandbox; mv .asdlc/jira.conf "$SB/c.off"
run env -u JIRA_EMAIL -u JIRA_TOKEN -u JIRA_TRANSPORT -u ASDLC_JIRA_MCP_SERVER "$JC" transport
assert_eq "$CODE/$OUT" "0/transport=auto mcp_server=claude_ai_Atlassian rest_ready=no(JIRA_EMAIL and JIRA_TOKEN are not both set)" "defaults"
conf_set JIRA_TRANSPORT mcp
run env JIRA_EMAIL=a@example.com JIRA_TOKEN=tok ASDLC_JIRA_MCP_SERVER=fixture_atlassian "$JC" transport
assert_eq "$CODE/$OUT" "0/transport=mcp mcp_server=fixture_atlassian rest_ready=yes" "ready, mcp, own server"
assert_not_contains "$OUT$ERR" "tok" "the token is not printed"
run env JIRA_TRANSPORT=rest "$JC" transport; assert_contains "$OUT" "transport=mcp " "the environment does not override the config key"
conf_set JIRA_TRANSPORT bogus; run "$JC" transport; assert_eq "$CODE" "2" "bad transport"
run env ASDLC_JIRA_MCP_SERVER='a b' "$JC" transport; assert_eq "$CODE" "2" "bad server"
run "$JC" transport extra; assert_eq "$CODE" "2" "extra argument"

finish
