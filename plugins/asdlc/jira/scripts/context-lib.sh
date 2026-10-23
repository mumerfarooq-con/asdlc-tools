# shellcheck shell=bash
# The ticket-facts half of jira-context.sh: the jq definitions, the comment helpers, the one
# "facts" program, and what renders from it (the fingerprint and the change snapshot).
# Sourced by jira-context.sh; not meant to be run on its own. It sets no shell options.
# Needs PIPELINE_COMMENT_MARKER (from the config) set before the fingerprint or snapshot run.

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }

# jq definitions shared by the fingerprint and the context, so both treat a comment the
# same way. $m is the pipeline marker. A pipeline comment starts with the marker once
# leading whitespace is gone and Jira's wiki escapes (\[ and \]) are undone.
JQ_COMMON='
def one: (if . == null then "" else tostring end) | gsub("[\r\n]+"; " ");
def cell: one | split("|") | join("\\|");
def text: if . == null then "" elif type == "string" then . else tojson end;
def unesc: split("\\[") | join("[") | split("\\]") | join("]");
def ispipe: (.body | text | sub("^\\s+"; "") | unesc | startswith($m));
def num: tostring | if test("\\A[0-9]+\\z") then . else error("bad id") end;
def key: if type == "string" and test("\\A[A-Z][A-Z0-9_]*-[0-9]+\\z") then . else error("bad key") end;
def norm: text | split("\r\n") | join("\n") | split("\r") | join("\n") | split("\n")
  | map(sub("[ \t]+\\z"; ""))
  | until(length == 0 or .[0] != ""; .[1:]) | until(length == 0 or .[-1] != ""; .[:-1])
  | join("\n");
def fence: ([match("`+"; "g").length] | max // 0) as $n | ([3, $n + 1] | max) as $k | ([range($k) | "`"] | join(""));
def fenced: fence as $f | $f + "\n" + . + "\n" + $f;
def body_md: if . == null or . == "" then "(no description)"
             elif type == "string" then fenced else "(not plain text — open the ticket)" end;
'

# The one list of what a person would notice about a ticket, and what the fingerprint hashes.
# Input: the issue (.fields...); $c is the array of ALL its comments. Output:
#   {summary, description, comments:[{id,body}] (human only), parent, links:[{dir,type,key}],
#    attachments:[id]}
# Every value is normalised. Bad ids or keys make jq fail, so the callers fail closed.
# A fact added here reaches the fingerprint and the snapshot together, never one of them.
JQ_FACTS='
def facts($c):
  .fields as $f
  | {summary: ($f.summary | norm), description: ($f.description | norm),
     comments: [$c[] | select(ispipe | not) | {id: (.id | num), body: (.body | norm)}],
     parent: (($f.parent // null) | if . == null then null else (.key | key) end),
     links: [($f.issuelinks // [])[]
             | (if .inwardIssue then ["inward", .inwardIssue.key]
                elif .outwardIssue then ["outward", .outwardIssue.key] else empty end) as $l
             | {dir: $l[0], type: (.type.name | norm), key: ($l[1] | key)}],
     attachments: [($f.attachment // [])[] | .id | num]};
'

# All comment pages in <rawdir> as one JSON array, de-duplicated by id.
comments_all() {  # <rawdir> <outfile>
  local files=("$1"/comments-*.json)
  [ -e "${files[0]}" ] || { echo "no comment pages in $1" >&2; return 2; }
  jq -s '[.[] | (.comments | if type == "array" then .[] else error("page without comments") end)]
         | unique_by(.id | tostring)' "${files[@]}" > "$2" 2>/dev/null || { echo "malformed comment pages in $1" >&2; return 2; }
}

# Which source a raw/ directory came from: fetch.json's "source", and "rest" when it has none
# (every REST fetch before the MCP source existed). Fails (status 2) on an unknown source.
raw_source() {  # <rawdir>
  local s=rest
  if [ -f "$1/fetch.json" ]; then s="$(jq -r '.source // "rest"' "$1/fetch.json" 2>/dev/null)" || return 2; fi
  fp_source_ok "$s" || return 2
  printf '%s' "$s"
}

# The preimage tag of a source. A source's tag never changes once plans carry its fingerprints.
fp_tag() {  # <source>
  case "$1" in
    rest) printf 'asdlc-ticket-fp-v1' ;;
    mcp)  printf 'asdlc-ticket-fp-mcp-v1' ;;
    *)    return 2 ;;
  esac
}

# A raw/ directory fetched over MCP (mcp-issue.json, optional mcp-parent.json) as the v2-like
# files the facts program and the renderer read: <outdir>/issue.json, comments-0.json and, when
# there is a parent, parent.json. The stored issue is a node, or the whole tool response
# ({issues:{nodes:[node]}, context}); either way only the node is used, so the per-call
# "context" block can never reach a fingerprint. Status 2 on malformed data.
mcp_view() {  # <rawdir> <outdir>
  local raw="$1" out="$2"
  [ -f "$raw/mcp-issue.json" ] || { echo "no $raw/mcp-issue.json" >&2; return 2; }
  mkdir -p "$out"
  jq -c '(.issues.nodes[0] // .) | if type == "object" and (.fields | type) == "object" then del(.fields.comment) else error("no issue") end' \
    "$raw/mcp-issue.json" > "$out/issue.json" 2>/dev/null || { echo "malformed $raw/mcp-issue.json" >&2; return 2; }
  jq -c '(.issues.nodes[0] // .).fields.comment
         | if type == "object" and (.comments | type) == "array" then {comments, total, startAt, maxResults} else error("no comments") end' \
    "$raw/mcp-issue.json" > "$out/comments-0.json" 2>/dev/null || { echo "no readable comments in $raw/mcp-issue.json" >&2; return 2; }
  if [ -f "$raw/mcp-parent.json" ]; then
    jq -c '(.issues.nodes[0] // .) | if type == "object" then . else error("no parent") end' "$raw/mcp-parent.json" > "$out/parent.json" 2>/dev/null ||
      { echo "malformed $raw/mcp-parent.json" >&2; return 2; }
  fi
}

# The ticket fingerprint of <rawdir>: sha256 over the facts of a ticket, one line per fact
# (see the plan file for the list). The source (REST or MCP) comes from raw/fetch.json and picks
# the preimage tag; the fact lines are the same. Fails closed (status 2) on bad data.
asdlc_fingerprint() {  # <rawdir>
  local raw="$1" d src tag
  src="$(raw_source "$raw")" || { echo "unknown ticket source in $raw/fetch.json; not fingerprinting" >&2; return 2; }
  tag="$(fp_tag "$src")" || return 2
  d="$(mktemp -d)"
  if [ "$src" = mcp ]; then mcp_view "$raw" "$d/view" || { rm -rf "$d"; return 2; }; raw="$d/view"; fi
  [ -f "$raw/issue.json" ] || { echo "no $raw/issue.json" >&2; rm -rf "$d"; return 2; }
  comments_all "$raw" "$d/c.json" || { rm -rf "$d"; return 2; }
  if ! jq -r --arg m "$PIPELINE_COMMENT_MARKER" --slurpfile c "$d/c.json" "$JQ_COMMON$JQ_FACTS"'
      facts($c[0])
      | ("summary\t" + (.summary | @base64)),
        ("description\t" + (.description | @base64)),
        (.comments[] | "comment\t\(.id)\t" + (.body | @base64)),
        (.parent | if . == null then empty else "parent\t" + . end),
        (.links[] | "link\t\(.dir)\t\(.type | @base64)\t\(.key)"),
        (.attachments[] | "attachment\t" + .)
    ' "$raw/issue.json" > "$d/lines" 2>/dev/null; then
    echo "malformed ticket data in $1 (bad id or key); not fingerprinting" >&2; rm -rf "$d"; return 2
  fi
  { printf '%s\n' "$tag"; LC_ALL=C sort "$d/lines"; } > "$d/all"
  printf 'sha256:%s\n' "$(sha < "$d/all")"; rm -rf "$d"
}

# <rawdir> <outfile>: the facts as JSON, for the change report (links read "<dir> <type> <key>").
snapshot() {
  local raw="$1" d src
  src="$(raw_source "$raw")" || return 1
  d="$(mktemp -d)"
  if [ "$src" = mcp ]; then mcp_view "$raw" "$d/view" 2>/dev/null || { rm -rf "$d"; return 1; }; raw="$d/view"; fi
  comments_all "$raw" "$d/c.json" || { rm -rf "$d"; return 1; }
  jq -n --arg m "$PIPELINE_COMMENT_MARKER" --slurpfile i "$raw/issue.json" --slurpfile c "$d/c.json" "$JQ_COMMON$JQ_FACTS"'
    $i[0] | facts($c[0]) | .links |= map("\(.dir) \(.type | one) \(.key)")' > "$2" 2>/dev/null || { rm -rf "$d"; return 1; }
  rm -rf "$d"
}
