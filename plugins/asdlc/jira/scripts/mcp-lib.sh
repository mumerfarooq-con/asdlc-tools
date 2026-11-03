# shellcheck shell=bash
# The MCP request library of the Jira leg: how a script opens a capture request, reads it back and
# picks the capture the hook stored. Sourced by lib.sh; not meant to be run on its own.
# The protocol (request schema, envelope, receipts, exit codes, TTL, who opens and who takes what)
# is written down once, in jira/README.md ("Capture protocol"). Written for bash 3.2.
#
# Openers:   asdlc_mcp_ticket_request (kind fetch|check|transition|comment), jira-mine.sh (search),
#            asdlc_bb_mcp_open in lib.sh (bb). All three go through mcp_request_open.
# Consumers: asdlc_mcp_take (the ticket requests), jira-mine.sh --from-mcp and asdlc_bb_mcp_take.
#            All three go through mcp_request_load and mcp_pick_capture.

MCP_TTL=600                                   # seconds a request stays open: the one place it is written
MCP_PARENT_FIELDS="summary,description,status,issuetype"

# The host of JIRA_BASE_URL, which the Atlassian MCP accepts as its cloudId. Returns 1 when unusable.
asdlc_mcp_cloud() {
  local h="${JIRA_BASE_URL#https://}"; h="${h%%[:/]*}"
  [[ $h =~ ^[A-Za-z0-9.-]+$ ]] || { echo "JIRA_BASE_URL has no usable host for the MCP cloudId" >&2; return 1; }
  printf '%s' "$h"
}

# The name of the Atlassian MCP server (per install, from the environment, never the repo).
asdlc_mcp_server() {
  local s="${ASDLC_JIRA_MCP_SERVER:-claude_ai_Atlassian}"
  [[ $s =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ASDLC_JIRA_MCP_SERVER must be letters, digits, _ and - only" >&2; return 1; }
  printf '%s' "$s"
}

# Return 1 with MCP_WHY set when <path> or any directory above it is a symbolic link.
mcp_path_clean() {  # <relative path>
  local rest="$1" acc="" seg
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"; acc="${acc:+$acc/}$seg"
    if [ -L "$acc" ]; then MCP_WHY="refusing: $acc is a symbolic link"; return 1; fi
    case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
}

# Open a request in <dir>: drop the earlier request and captures there, write <dir>/request.json
# with the fields every request carries (v, kind, server, nonce, created_epoch, expires_epoch) plus
# the members of <extra-json>. Returns 2 (MCP_WHY set) for a symbolic link, 1 for a failed write.
mcp_request_open() {  # <dir> <kind> <server> <extra-json>
  local dir="$1" kind="$2" server="$3" extra="$4" now nonce tmp
  MCP_WHY=""
  mcp_path_clean "$dir" || return 2
  mkdir -p "$dir"; rm -f "$dir"/request.json "$dir"/cap-*.json
  now="$(date +%s)"; nonce="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  tmp="$(mktemp "$dir/.request.XXXXXX")"
  jq -n --arg kind "$kind" --arg server "$server" --arg nonce "$nonce" --argjson now "$now" --argjson ttl "$MCP_TTL" --argjson extra "$extra" \
      '{v: 1, kind: $kind, server: $server, nonce: $nonce, created_epoch: $now, expires_epoch: ($now + $ttl)} + $extra' > "$tmp" ||
    { rm -f "$tmp"; MCP_WHY="could not write the request"; return 1; }
  mv "$tmp" "$dir/request.json"
}

# Open a ticket request (plans/<KEY>/.mcp) for <kind> (fetch|check|transition|comment) and print the
# one call the model may make: {"tool":...,"args":{...}}. Needs JIRA_BASE_URL and the pipeline
# marker. Returns what mcp_request_open does; MCP_WHY says why.
asdlc_mcp_ticket_request() {  # <KEY> <kind> <issue-fields csv>
  local key="$1" kind="$2" ifields="$3" server host extra
  host="$(asdlc_mcp_cloud)" || { MCP_WHY="JIRA_BASE_URL has no usable host for the MCP cloudId"; return 2; }
  server="$(asdlc_mcp_server)" || { MCP_WHY="ASDLC_JIRA_MCP_SERVER must be letters, digits, _ and - only"; return 2; }
  extra="$(jq -nc --arg key "$key" --arg purpose "$kind" --arg cloud "$host" --arg marker "$PIPELINE_COMMENT_MARKER" \
        --arg ifields "$ifields" --arg pfields "$MCP_PARENT_FIELDS" '
      def md($f): {fields: $f, format: "markdown"};
      {key: $key, purpose: $purpose, cloud_id: $cloud, marker: $marker,
       calls: (if $purpose == "fetch" then {getJiraIssue: md(($ifields | split(",")) + ["comment"]), parent: md($pfields | split(","))}
               elif $purpose == "check" then {getJiraIssue: md(($ifields | split(",")) + ["comment"])}
               elif $purpose == "transition" then {getJiraIssue: md(["status"]), getTransitionsForJiraIssue: {}, transitionJiraIssue: {}}
               else {addCommentToJiraIssue: {}} end),
       allow_keys: [$key]}')" || { MCP_WHY="could not write the request"; return 1; }
  mcp_request_open "plans/$key/.mcp" "$kind" "$server" "$extra" || return $?
  jq -nc --arg t "mcp__${server}__$(if [ "$kind" = comment ]; then echo addCommentToJiraIssue; else echo getJiraIssue; fi)" \
        --arg cloud "$host" --arg key "$key" --slurpfile r "plans/$key/.mcp/request.json" '
      {tool: $t, args: ({cloudId: $cloud, issueIdOrKey: $key}
        + (if $r[0].calls.getJiraIssue then {fields: $r[0].calls.getJiraIssue.fields, responseContentFormat: "markdown", updateHistory: false} else {} end))}'
}

# Read and check the request <req>. <what> names it in messages ("MCP request for PROJ-1"), <kind> is
# the kind the caller serves, <how> says how to open a new one ("with jira-mine.sh --mcp-args"), and
# <key>, when given, must be the request's key. Returns 1 with MCP_WHY set when the request is
# missing, unreadable, of another kind or expired. On success MCP_SERVER, MCP_NONCE, MCP_CREATED,
# MCP_EXPIRES, MCP_OP and MCP_TOOL hold its fields (MCP_OP and MCP_TOOL are "null" when it has none).
mcp_request_load() {
  local req="$1" what="$2" kind="$3" how="$4" key="${5:-}" line v rkind rkey
  MCP_WHY=""; MCP_SERVER=""; MCP_NONCE=""; MCP_CREATED=""; MCP_EXPIRES=""; MCP_OP=""; MCP_TOOL=""
  mcp_path_clean "$req" || return 1
  [ -f "$req" ] || { MCP_WHY="no open $what; open one $how, make the call it prints, then retry"; return 1; }
  line="$(jq -r '[.v, .kind, .server, .nonce, .created_epoch, .expires_epoch, .key, .op, .tool] | map(tostring) | join(" ")' "$req" 2>/dev/null)" || line=""
  read -r v rkind MCP_SERVER MCP_NONCE MCP_CREATED MCP_EXPIRES rkey MCP_OP MCP_TOOL <<<"$line" || true
  if ! { [ "${v:-}" = 1 ] && [[ ${rkind:-} =~ ^[a-z]+$ ]] && [[ ${MCP_SERVER:-} =~ ^[A-Za-z0-9_-]+$ ]] &&
         [[ ${MCP_NONCE:-} =~ ^[0-9a-f]{8,64}$ ]] && [[ ${MCP_CREATED:-} =~ ^[0-9]+$ ]] && [[ ${MCP_EXPIRES:-} =~ ^[0-9]+$ ]] &&
         { [ -z "$key" ] || [ "${rkey:-}" = "$key" ]; }; }; then
    MCP_WHY="the $what is unreadable; open a new one $how"; return 1
  fi
  [ "$rkind" = "$kind" ] || { MCP_WHY="the open $what is for $rkind, not $kind; open a new one $how"; return 1; }
  [ "$MCP_EXPIRES" -gt "$(date +%s)" ] || { MCP_WHY="the $what has expired; open a new one $how"; return 1; }
}

# Print the file of the newest valid capture in <dir> (nothing if none). Valid means: an object with
# the request's <nonce>, the <tool> name and <role>, taken no earlier than the request's <created>
# epoch, and satisfying <filter>, a jq condition over the capture (it may use $want). Ties on the
# second go to the later file name. Never exits.
mcp_pick_capture() {  # <dir> <nonce> <created> <tool> <role> <want> <filter>
  local dir="$1" nonce="$2" created="$3" tool="$4" role="$5" want="$6" filter="$7" f e best="" beste=-1
  for f in "$dir"/cap-*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    e="$(jq -r --arg n "$nonce" --argjson c "$created" --arg tool "$tool" --arg role "$role" --arg want "$want" '
          select(type == "object" and .nonce == $n and .tool_name == $tool and .role == $role
                 and (.captured_epoch | type) == "number" and .captured_epoch >= $c
                 and ('"$filter"'))
          | .captured_epoch | floor' "$f" 2>/dev/null)" || continue
    [[ $e =~ ^[0-9]+$ ]] || continue
    if [ "$e" -gt "$beste" ] || { [ "$e" = "$beste" ] && [[ $f > $best ]]; }; then best="$f"; beste="$e"; fi
  done
  printf '%s' "$best"
}

# Capture filters (jq conditions for mcp_pick_capture).
MCP_FILTER_ANY='(.response | type) != "null"'
MCP_FILTER_ISSUE='(.response | type) == "object" and ((.response.issues.nodes // []) | length) == 1
  and (.response.issues.nodes[0].fields | type) == "object" and .response.issues.nodes[0].key == $want'
MCP_FILTER_SEARCH='(.response.issues.nodes | type) == "array"'
MCP_FILTER_BB='(.response.id | type) == "string" and (.response.id | test("^[0-9]{1,18}$"))'

# Read the captures of plans/<KEY>/.mcp for <kind> into <outdir>/<role>.json (the stored response
# of each role: "issue" and "parent" are getJiraIssue nodes, any other role is the tool's own name
# and its whole response). The request must be of <kind>, be about <KEY> and not have expired; a
# capture counts only if its nonce is the request's, it came from the request's server and tool,
# it is not older than the request, and (issue) it is for <KEY>. Role "parent" is optional: it is
# the capture of the parent the issue names, if there is one. The newest valid capture per role
# wins. The captures are deleted once read (use once); the request stays, for asdlc_mcp_close.
# Never exits: returns 1 with MCP_WHY set. On success MCP_SERVER is the request's server name.
asdlc_mcp_take() {  # <KEY> <kind> <outdir> <role>...
  local key="$1" kind="$2" out="$3" dir role tool best want filter pk
  shift 3
  dir="plans/$key/.mcp"
  mcp_request_load "$dir/request.json" "MCP request for $key" "$kind" "with jira-context.sh mcp-request $key --for $kind" "$key" || return 1
  mkdir -p "$out"
  for role in "$@"; do
    tool="mcp__${MCP_SERVER}__$role"; want="$key"; filter="$MCP_FILTER_ANY"
    case "$role" in
      issue|parent) tool="mcp__${MCP_SERVER}__getJiraIssue"; filter="$MCP_FILTER_ISSUE" ;;
    esac
    if [ "$role" = parent ]; then
      pk="$(jq -r '.fields.parent.key // "" | tostring' "$out/issue.json" 2>/dev/null)" || pk=""
      asdlc_is_key "$pk" || continue
      want="$pk"
    fi
    best="$(mcp_pick_capture "$dir" "$MCP_NONCE" "$MCP_CREATED" "$tool" "$role" "$want" "$filter")"
    if [ -z "$best" ]; then
      [ "$role" != parent ] || continue
      MCP_WHY="no valid $role capture of $key under the open MCP request (make the call the request printed, with exactly those args; a capture from another or an older request is ignored)"; return 1
    fi
    case "$role" in issue|parent) jq -c '.response.issues.nodes[0]' "$best" > "$out/$role.json" 2>/dev/null ;; *) jq -c '.response' "$best" > "$out/$role.json" 2>/dev/null ;; esac ||
      { MCP_WHY="could not read the $role capture of $key"; return 1; }
  done
  rm -f "$dir"/cap-*.json
}

# Drop the request of <KEY> (and any capture still there): nothing more is expected of it.
asdlc_mcp_close() {  # <KEY>
  local dir="plans/$1/.mcp"
  [ -L plans ] || [ -L "plans/$1" ] || [ -L "$dir" ] && return 0
  rm -f "$dir"/request.json "$dir"/cap-*.json; rmdir "$dir" 2>/dev/null || true
}
