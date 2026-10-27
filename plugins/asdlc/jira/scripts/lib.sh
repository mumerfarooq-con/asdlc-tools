# shellcheck shell=bash
# Shared helpers for the Jira leg: project config, fixture mode, HTTP calls.
# Sourced by the scripts in this directory; not meant to be run on its own.
# Written for bash 3.2 (macOS): no associative arrays, and never expand a
# possibly-empty array under `set -u` without the ${a[@]+"${a[@]}"} guard.

ASDLC_JIRA_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASDLC_JIRA_HOME="$(dirname "$ASDLC_JIRA_SCRIPTS")"
# The plugin's shared scripts (plan-state.sh): absolute, so no caller keeps a ../ path in use.
ASDLC_SHARED_SCRIPTS="$(cd "$ASDLC_JIRA_HOME/../scripts" && pwd)"

# Keys a project's .asdlc/jira.conf may set. The file is parsed, never sourced,
# and anything outside this list is ignored with a warning, so a committed
# config can't run code or override PATH and friends.
ASDLC_CONF_KEYS="JIRA_BASE_URL JIRA_PROJECT_KEY JIRA_PROJECT_NAME JIRA_BOARD_ID
BB_WORKSPACE BB_REPO BB_AUTH TARGET_BRANCH
STATUS_DEFAULT STATUS_TODO STATUS_IN_PROGRESS STATUS_NEEDS_INFO STATUS_TESTING
NOTIFY_ACCOUNT_IDS TEMPLATE_BUG_TYPES TICKET_CHECK_MODE PIPELINE_COMMENT_MARKER
LINK_BLOCKER_TYPES LINK_DUPLICATE_TYPES SENSITIVE_TOPICS
ACCESS_RULES_PATH KNOWN_TRAPS_PATH IMPACT_EXTRA_PATHS IMPACT_EXCLUDE
MAX_IMAGES MAX_IMAGE_MB REVIEW_COUNCIL_FILES REVIEW_COUNCIL_LINES REVIEW_COUNCIL_PATHS
JIRA_TRANSPORT BB_TRANSPORT"

# Defaults: generic values only. Project values (site, keys, branch) have none.
asdlc_conf_defaults() {
  JIRA_BASE_URL=""; JIRA_PROJECT_KEY=""; JIRA_PROJECT_NAME=""; JIRA_BOARD_ID=""
  BB_WORKSPACE=""; BB_REPO=""; BB_AUTH="bearer"; TARGET_BRANCH=""
  STATUS_DEFAULT="To Do"; STATUS_TODO="To Do"; STATUS_IN_PROGRESS="In Progress"
  STATUS_NEEDS_INFO="Needs info"; STATUS_TESTING="Testing"
  NOTIFY_ACCOUNT_IDS=""; TEMPLATE_BUG_TYPES="Bug"; TICKET_CHECK_MODE="warn"
  PIPELINE_COMMENT_MARKER="[asdlc]"
  LINK_BLOCKER_TYPES="Blocks"; LINK_DUPLICATE_TYPES="Duplicate,Cloners"
  SENSITIVE_TOPICS=""
  ACCESS_RULES_PATH="docs/access-rules.md"; KNOWN_TRAPS_PATH="docs/known-traps.md"
  IMPACT_EXTRA_PATHS=""; IMPACT_EXCLUDE=".git,node_modules,.venv"
  MAX_IMAGES="10"; MAX_IMAGE_MB="5"
  JIRA_TRANSPORT="auto"; BB_TRANSPORT="rest"
  REVIEW_COUNCIL_FILES="10"; REVIEW_COUNCIL_LINES="400"
  REVIEW_COUNCIL_PATHS='(migration|migrations|auth|security|secret|credential|password|payment|billing|Dockerfile|\.github/|\.asdlc/|terraform|helm|k8s|deploy|infra)'
}

asdlc_die()  { echo "$*" >&2; exit 1; }
asdlc_warn() { echo "warn: $*" >&2; }

asdlc_trim() {  # <string> -> string without leading/trailing whitespace
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

asdlc_is_conf_key() {
  case " $(printf '%s' "$ASDLC_CONF_KEYS" | tr '\n' ' ') " in *" $1 "*) return 0 ;; esac
  return 1
}

# Path of the project's config: --conf / ASDLC_JIRA_CONF, else .asdlc/jira.conf
# at the git root, else in the current directory.
asdlc_conf_path() {
  if [ -n "${ASDLC_JIRA_CONF:-}" ]; then printf '%s' "$ASDLC_JIRA_CONF"; return; fi
  local top; top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  printf '%s' "$top/.asdlc/jira.conf"
}

# Read KEY=value lines into shell variables. Blank lines and lines starting
# with # are skipped; one pair of surrounding quotes is stripped from values.
asdlc_conf_parse() {  # <file>
  local line key val n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="$(asdlc_trim "${line%$'\r'}")"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) asdlc_warn "$1:$n: no '=', line ignored"; continue ;; esac
    key="$(asdlc_trim "${line%%=*}")"; val="$(asdlc_trim "${line#*=}")"
    case "$val" in
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    if ! asdlc_is_conf_key "$key"; then asdlc_warn "$1:$n: unknown key '$key' ignored"; continue; fi
    printf -v "$key" '%s' "$val"
  done < "$1"
}

# Load defaults + the project config. A missing config is fatal unless
# ASDLC_CONF_OPTIONAL=1 (for scripts that can run on defaults and arguments).
asdlc_load_conf() {
  asdlc_conf_defaults
  ASDLC_CONF_FILE="$(asdlc_conf_path)"
  if [ -f "$ASDLC_CONF_FILE" ]; then
    asdlc_conf_parse "$ASDLC_CONF_FILE"
  elif [ "${ASDLC_CONF_OPTIONAL:-0}" != "1" ]; then
    asdlc_die "No Jira config at $ASDLC_CONF_FILE — run /asdlc:jira-setup in the project repo first."
  fi
  while [ "${JIRA_BASE_URL%/}" != "$JIRA_BASE_URL" ]; do JIRA_BASE_URL="${JIRA_BASE_URL%/}"; done
}

# Strip the shared flags (--fixtures DIR, --conf FILE) from a script's
# arguments and load the config. Remaining arguments land in ASDLC_ARGS;
# restore them with: set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
asdlc_init() {
  ASDLC_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --fixtures) ASDLC_FIXTURES="${2:?--fixtures needs a directory}"; shift 2 ;;
      --conf)     ASDLC_JIRA_CONF="${2:?--conf needs a file}"; shift 2 ;;
      *)          ASDLC_ARGS+=("$1"); shift ;;
    esac
  done
  ASDLC_FIXTURES="${ASDLC_FIXTURES:-}"
  if [ -n "$ASDLC_FIXTURES" ] && [ ! -d "$ASDLC_FIXTURES" ]; then
    asdlc_die "fixtures directory not found: $ASDLC_FIXTURES"
  fi
  asdlc_load_conf
}

# The Jira token is sent to JIRA_BASE_URL, and a committed config sets that, so
# the config alone must never decide where credentials go. The URL must be a
# bare https://host[:port], and the host must be *.atlassian.net or be listed
# in ASDLC_JIRA_ALLOWED_HOSTS (comma-separated). That variable is read from the
# user's environment only and is deliberately not a config key, so a repo can't
# grant itself a host. Exits with the reason if the URL may not get credentials.
# Matching uses [[ =~ ]] rather than grep, which works per line and would pass a
# multi-line value if one of its lines looked fine.
asdlc_check_jira_url() {  # <url>
  local url="$1" host h shape cloud
  while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
  shape='^https://[A-Za-z0-9.-]+(:[0-9]+)?$'
  cloud='^[A-Za-z0-9-]+\.atlassian\.net$'
  if ! [[ $url =~ $shape ]]; then
    asdlc_die "JIRA_BASE_URL '$(printf '%s' "$url" | tr -cd '[:print:]')' is refused: it must be just https://<host> (https only; no user@, path, query or fragment). Nothing was sent."
  fi
  host="${url#https://}"; host="$(printf '%s' "${host%%:*}" | tr '[:upper:]' '[:lower:]')"
  if [[ $host =~ $cloud ]]; then return 0; fi
  while IFS= read -r h; do
    if [ "$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')" = "$host" ]; then return 0; fi
  done < <(asdlc_split_csv "${ASDLC_JIRA_ALLOWED_HOSTS:-}")
  asdlc_die "JIRA_BASE_URL host '$host' is not an *.atlassian.net site, so your Jira token is not sent there. If it is your own Jira Data Center, run: export ASDLC_JIRA_ALLOWED_HOSTS=$host in your shell profile (never in the repo's config)."
}

# Workspace and repo slugs go straight into API paths: allow only what
# Bitbucket uses, and refuse a leading '-' or a '.'/'..' path segment.
asdlc_check_bb_target() {
  local k v slug='^[A-Za-z0-9._-]+$'
  for k in BB_WORKSPACE BB_REPO; do
    v="${!k}"
    if ! [[ $v =~ $slug ]] || [ "$v" = "." ] || [ "$v" = ".." ] || [ "${v#-}" != "$v" ]; then
      asdlc_die "$k '$(printf '%s' "$v" | tr -cd '[:print:]')' is refused: use only letters, digits, '.', '_' and '-', not starting with '-', and not '.' or '..'."
    fi
  done
}

asdlc_need_jira() {
  [ -n "$JIRA_BASE_URL" ] || asdlc_die "JIRA_BASE_URL is not set in $ASDLC_CONF_FILE"
  asdlc_check_jira_url "$JIRA_BASE_URL"
  [ -n "$ASDLC_FIXTURES" ] && return 0
  : "${JIRA_EMAIL:?set JIRA_EMAIL (your Atlassian login email)}"
  : "${JIRA_TOKEN:?set JIRA_TOKEN (a Jira API token)}"
}

asdlc_need_bb() {
  [ -n "$BB_WORKSPACE" ] || asdlc_die "BB_WORKSPACE is not set in $ASDLC_CONF_FILE"
  [ -n "$BB_REPO" ]      || asdlc_die "BB_REPO is not set in $ASDLC_CONF_FILE"
  asdlc_check_bb_target
  [ -n "$ASDLC_FIXTURES" ] && return 0
  : "${BITBUCKET_TOKEN:?set BITBUCKET_TOKEN}"
  if [ "$BB_AUTH" = "basic" ]; then : "${BITBUCKET_EMAIL:?set BITBUCKET_EMAIL (BB_AUTH=basic)}"; fi
}

# asdlc_curl_args <jira|bb> <METHOD> <path> <outfile> [curl args...]
# Builds curl's whole argument list into the global array ASDLC_CURL_ARGV
# (bash 3.2 can't return an array). Tests look the arguments up by name.
# ASDLC_CURL_ACCEPT overrides the Accept header (downloads send */*).
asdlc_curl_args() {
  local svc="$1" method="$2" path="$3" out="$4"; shift 4
  ASDLC_CURL_ARGV=(-sS -o "$out" -w '%{http_code}' -H "Accept: ${ASDLC_CURL_ACCEPT:-application/json}")
  case "$svc" in
    jira) ASDLC_CURL_ARGV+=(--user "$JIRA_EMAIL:$JIRA_TOKEN"); path="$JIRA_BASE_URL$path" ;;
    bb)   if [ "$BB_AUTH" = "basic" ]; then ASDLC_CURL_ARGV+=(--user "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN")
          else ASDLC_CURL_ARGV+=(-H "Authorization: Bearer $BITBUCKET_TOKEN"); fi
          path="https://api.bitbucket.org/2.0$path" ;;
    *)    asdlc_die "asdlc_http: unknown service $svc" ;;
  esac
  if [ "$method" = "GET" ]; then ASDLC_CURL_ARGV+=(-G); else ASDLC_CURL_ARGV+=(-X "$method"); fi
  # "--" ends option parsing, so the URL can never be read as a curl option.
  ASDLC_CURL_ARGV+=(${@+"$@"} -- "$path")
}

# asdlc_http <jira|bb> <METHOD> <path> <outfile> [curl args...]
# Writes the response body to <outfile> and prints the HTTP status code
# (000 when the host can't be reached). Paths are relative to the service's
# API root: "/rest/api/2/..." for Jira, "/repositories/..." for Bitbucket.
# curl's exit status is left in ASDLC_CURL_RC for callers that don't run this
# in a $(...) subshell.
asdlc_http() {
  local svc="$1" method="$2" path="$3" out="$4"; shift 4
  ASDLC_CURL_RC=0
  if [ -n "$ASDLC_FIXTURES" ]; then asdlc_fixture_http "$svc" "$method" "$path" "$out" "$@"; return; fi
  asdlc_curl_args "$svc" "$method" "$path" "$out" "$@"
  local code
  code="$(curl "${ASDLC_CURL_ARGV[@]}")" || { ASDLC_CURL_RC=$?; code="000"; }
  printf '%s' "${code:-000}"
}

# Jira issue keys, and the marker that tags the pipeline's own comments.
asdlc_is_key() { [[ ${1:-} =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]]; }
asdlc_need_marker() {
  case "${PIPELINE_COMMENT_MARKER:-}" in
    '') asdlc_die "PIPELINE_COMMENT_MARKER is empty in $ASDLC_CONF_FILE; the pipeline's comments must start with a marker." ;;
    *$'\n'*) asdlc_die "PIPELINE_COMMENT_MARKER in $ASDLC_CONF_FILE must be one line." ;;
  esac
  # Whitespace only would match every comment's leading text, so it is as bad as empty.
  [ -n "$(asdlc_trim "$PIPELINE_COMMENT_MARKER")" ] ||
    asdlc_die "PIPELINE_COMMENT_MARKER is only whitespace in $ASDLC_CONF_FILE; the pipeline's comments must start with a marker."
}

# asdlc_download <path> <dest> <max_bytes>
# Fetch a Jira attachment (only /rest/api/2/attachment/content/<numeric id>, so
# the token goes only to JIRA_BASE_URL) and keep it as <dest> if it is a png,
# jpeg, gif or webp within <max_bytes>. Prints one word: the HTTP status when
# stored or when the call failed, "size" or "type" when the bytes were
# rejected. Returns 0 only when <dest> was written. Redirects are followed
# (attachments live on a media host) but never with --location-trusted, so
# credentials stay with JIRA_BASE_URL.
asdlc_download() {
  local path="$1" dest="$2" max="$3" tmp codef code size hex
  if ! [[ $path =~ ^/rest/api/2/attachment/content/[0-9]+$ ]] || ! [[ $max =~ ^[0-9]+$ ]]; then
    echo "asdlc_download: refused path or limit" >&2; printf 'path'; return 1
  fi
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp "$dest.XXXXXX")"; codef="$(mktemp)"
  ASDLC_CURL_ACCEPT='*/*' asdlc_http jira GET "$path" "$tmp" \
    -L --max-redirs 3 --proto =https --proto-redir =https \
    --max-filesize "$max" --max-time 60 >"$codef"
  code="$(cat "$codef")"; rm -f "$codef"
  if [ "$ASDLC_CURL_RC" = "63" ]; then rm -f "$tmp"; printf 'size'; return 1; fi  # curl: file too large
  if ! asdlc_http_ok "$code"; then rm -f "$tmp"; printf '%s' "$code"; return 1; fi
  size="$(wc -c < "$tmp" | tr -d ' ')"
  if [ "$size" -gt "$max" ]; then rm -f "$tmp"; printf 'size'; return 1; fi
  hex="$(head -c 12 "$tmp" | od -An -tx1 | tr -d ' \n')"
  case "$hex" in
    89504e470d0a1a0a*|ffd8ff*|474946383761*|474946383961*) ;;
    52494646????????57454250*) ;;
    *) rm -f "$tmp"; printf 'type'; return 1 ;;
  esac
  mv "$tmp" "$dest"
  printf '%s' "$code"
}

# Fixture mode: GET <path> reads $ASDLC_FIXTURES/<svc><path>.json (a nonzero
# startAt query value reads <path>.startAt-<n>.json instead); an optional
# sibling .code file holds a non-200 status. Writes read <path>.<METHOD>.json
# if present, else answer {} with 200. Every request is appended as one JSON
# line to $ASDLC_FIXTURE_LOG when that is set, so tests can assert on calls.
asdlc_fixture_http() {
  local svc="$1" method="$2" path="$3" out="$4"; shift 4
  local start="" data="" a prev=""
  for a in "$@"; do
    case "$a" in startAt=*) start="${a#startAt=}" ;; esac
    case "$prev" in -d|--data|--data-raw|--data-binary) data="$a" ;; esac
    prev="$a"
  done
  case "$path" in *\?*startAt=*) start="${path##*startAt=}"; start="${start%%&*}" ;; esac
  local base="$ASDLC_FIXTURES/$svc${path%%\?*}" file code
  if [ "$method" = "GET" ]; then
    file="$base.json"
    if [ -n "$start" ] && [ "$start" != "0" ]; then file="$base.startAt-$start.json"; fi
  else
    file="$base.$method.json"
  fi
  if [ -n "${ASDLC_FIXTURE_LOG:-}" ]; then
    local argv="[]"
    [ $# -gt 0 ] && argv="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
    jq -nc --arg s "$svc" --arg m "$method" --arg p "$path" --arg d "$data" --argjson a "$argv" \
       '{svc:$s, method:$m, path:$p, args:$a,
         body:(if $d == "" then null else ($d | fromjson? // $d) end)}' \
       >> "$ASDLC_FIXTURE_LOG"
  fi
  if [ -f "$file" ]; then
    cp "$file" "$out"
    code="200"; [ -f "${file%.json}.code" ] && code="$(tr -d '[:space:]' < "${file%.json}.code")"
  elif [ "$method" = "GET" ]; then
    jq -n --arg f "$file" '{errorMessages:["no fixture: " + $f]}' > "$out"; code="404"
  else
    printf '{}' > "$out"; code="200"
  fi
  printf '%s' "$code"
}

asdlc_http_ok() { case "$1" in 2??) return 0 ;; esac; return 1; }

# Explain a failed call on stderr: status, the service's own error text, and
# a hint for the common auth/config mistakes.
asdlc_http_fail() {  # <jira|bb> <code> <bodyfile> [context]
  local svc="$1" code="$2" body="$3" ctx="${4:-}" name="Jira"
  [ "$svc" = "bb" ] && name="Bitbucket"
  if [ "$code" = "000" ]; then
    echo "Could not reach $name${ctx:+ ($ctx)} — check the URL in $ASDLC_CONF_FILE and your connection." >&2
    return 0
  fi
  echo "$name returned HTTP $code${ctx:+ for $ctx}." >&2
  jq -r '(.errorMessages[]?), (.errors? // {} | if type=="object" then to_entries[] | "\(.key): \(.value)" else . end),
         (.error?.message? // empty)' "$body" 2>/dev/null | sed 's/^/  /' >&2 || true
  case "$svc:$code" in
    jira:401) echo "  -> Auth failed. Check JIRA_EMAIL, and that JIRA_TOKEN is a Jira API token (not the Bitbucket one)." >&2 ;;
    jira:403) echo "  -> No permission for this call on the project." >&2 ;;
    jira:429) echo "  -> Jira is rate limiting this account. Wait a minute and run it again." >&2 ;;
    jira:404) echo "  -> Not found. Check JIRA_BASE_URL and JIRA_PROJECT_KEY in $ASDLC_CONF_FILE, and the issue key." >&2 ;;
    bb:401)   echo "  -> Auth failed. Check BITBUCKET_TOKEN; for a personal API token set BB_AUTH=basic and BITBUCKET_EMAIL." >&2 ;;
    bb:404)   echo "  -> Not found. Check BB_WORKSPACE and BB_REPO in $ASDLC_CONF_FILE." >&2 ;;
  esac
}

# GET a Jira/Bitbucket resource and print the body; exit with an explanation
# on any non-2xx status.
asdlc_get_json() {  # <jira|bb> <path> [curl args...]
  local svc="$1" path="$2"; shift 2
  local tmp code; tmp="$(mktemp)"
  code="$(asdlc_http "$svc" GET "$path" "$tmp" "$@")"
  if ! asdlc_http_ok "$code"; then asdlc_http_fail "$svc" "$code" "$tmp" "GET $path"; rm -f "$tmp"; exit 1; fi
  cat "$tmp"; rm -f "$tmp"
}

# POST/PUT a JSON body and print the response; exit on non-2xx.
asdlc_send_json() {  # <jira|bb> <METHOD> <path> <json>
  local svc="$1" method="$2" path="$3" json="$4"
  local tmp code; tmp="$(mktemp)"
  code="$(asdlc_http "$svc" "$method" "$path" "$tmp" -H "Content-Type: application/json" -d "$json")"
  if ! asdlc_http_ok "$code"; then asdlc_http_fail "$svc" "$code" "$tmp" "$method $path"; rm -f "$tmp"; exit 1; fi
  cat "$tmp"; rm -f "$tmp"
}

# "A, B ,C" -> one trimmed, non-empty item per line.
asdlc_split_csv() { printf '%s' "$1" | tr ',' '\n' | while IFS= read -r i || [ -n "$i" ]; do i="$(asdlc_trim "$i")"; [ -n "$i" ] && printf '%s\n' "$i"; done; return 0; }

# --- MCP writes: consuming the captures of a request (see jira-context.sh mcp-request) -------
# Can the REST API be used? A Jira login is set (fixture mode counts, for the tests).
asdlc_rest_ready() { [ -n "${ASDLC_FIXTURES:-}" ] || { [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_TOKEN:-}" ]; }; }

# The host of JIRA_BASE_URL, which the Atlassian MCP accepts as its cloudId.
asdlc_mcp_cloud() { local h="${JIRA_BASE_URL#https://}"; printf '%s' "${h%%[:/]*}"; }

# Read the captures of plans/<KEY>/.mcp for <purpose> into <outdir>/<role>.json (the stored
# response of each role: "issue" is getJiraIssue, any other role is the tool's own name).
# A capture counts only if its nonce is the request's, it came from the request's server and
# tool, it is not older than the request, and (for the issue) it is for <KEY>; the request must
# be for <purpose>, be about <KEY> and not have expired. The newest valid capture per role wins.
# The captures are deleted once read (use once); the request stays, for asdlc_mcp_close. Never
# exits: returns 1 with MCP_WHY set. On success MCP_SERVER is the request's server name.
asdlc_mcp_take() {  # <KEY> <purpose> <outdir> <role>...
  local key="$1" purpose="$2" out="$3" dir req line v rkey rp nonce created expires role tool f e best beste
  shift 3
  MCP_WHY=""; MCP_SERVER=""
  dir="plans/$key/.mcp"; req="$dir/request.json"
  if [ -L plans ] || [ -L "plans/$key" ] || [ -L "$dir" ] || [ -L "$req" ]; then
    MCP_WHY="refusing: plans/, plans/$key or its .mcp is a symbolic link"; return 1
  fi
  [ -f "$req" ] || { MCP_WHY="no open MCP request for $key; open one first, make the calls it printed, then retry"; return 1; }
  line="$(jq -r '[.v, .key, .purpose, .server, .nonce, .created_epoch, .expires_epoch] | map(tostring) | join(" ")' "$req" 2>/dev/null)" || line=""
  read -r v rkey rp MCP_SERVER nonce created expires <<<"$line" || true
  if ! { [ "${v:-}" = 1 ] && [ "${rkey:-}" = "$key" ] && [[ ${MCP_SERVER:-} =~ ^[A-Za-z0-9_-]+$ ]] &&
         [[ ${nonce:-} =~ ^[0-9a-f]{8,64}$ ]] && [[ ${created:-} =~ ^[0-9]+$ ]] && [[ ${expires:-} =~ ^[0-9]+$ ]]; }; then
    MCP_WHY="the MCP request for $key is unreadable; open a new one"; return 1
  fi
  [ "$rp" = "$purpose" ] || { MCP_WHY="the open MCP request for $key is for $rp, not $purpose; open a new one"; return 1; }
  [ "$expires" -gt "$(date +%s)" ] || { MCP_WHY="the MCP request for $key has expired; open a new one"; return 1; }
  mkdir -p "$out"
  for role in "$@"; do
    tool="mcp__${MCP_SERVER}__$role"; [ "$role" != issue ] || tool="mcp__${MCP_SERVER}__getJiraIssue"
    best=""; beste=-1
    for f in "$dir"/cap-*.json; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      e="$(jq -r --arg n "$nonce" --argjson c "$created" --arg tool "$tool" --arg role "$role" --arg k "$key" '
            select(type == "object" and .nonce == $n and .tool_name == $tool and .role == $role
                   and (.captured_epoch | type) == "number" and .captured_epoch >= $c
                   and (.response | type) != "null"
                   and ($role != "issue" or (((.response.issues.nodes // []) | length) == 1 and .response.issues.nodes[0].key == $k)))
            | .captured_epoch | floor' "$f" 2>/dev/null)" || continue
      [[ $e =~ ^[0-9]+$ ]] || continue
      if [ "$e" -gt "$beste" ] || { [ "$e" = "$beste" ] && [[ $f > $best ]]; }; then best="$f"; beste="$e"; fi
    done
    [ -n "$best" ] || { MCP_WHY="no valid $role capture of $key under the open MCP request (a capture from another or an older request is ignored)"; return 1; }
    case "$role" in issue) jq -c '.response.issues.nodes[0]' "$best" > "$out/$role.json" 2>/dev/null ;; *) jq -c '.response' "$best" > "$out/$role.json" 2>/dev/null ;; esac ||
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

# ---- Bitbucket over MCP (the seam, D-M7) -------------------------------------------------------
# BB_TRANSPORT=rest (default) is the token path. BB_TRANSPORT=mcp needs a profile for the team's
# Bitbucket MCP server: jira/mcp/bitbucket-<profile>.json maps open_pr and pr_comment to a tool
# name, an argument template ("{title}"-style placeholders) and the response paths of the id and
# URL. The server name (ASDLC_BB_MCP_SERVER) and the profile name (ASDLC_BB_MCP_PROFILE, default:
# the server name) are per install, so they come from the user's environment, never from the
# repo's config. The only profile shipped is "test" (synthetic tool names); it is refused unless
# ASDLC_ALLOW_TEST_BB_PROFILE=1, because it names no real server.
# The call is opened with a request (plans/.mcp/bb/request.json); the capture hook stores only the
# PR id and URL of the answer, and the --from-mcp scripts print them: "<id> <url>".

# Check BB_TRANSPORT and, for mcp, the server and profile. Sets BBM_SERVER and BBM_PROFILE_FILE.
# Prints the reason and returns 1 when mcp cannot be used.
asdlc_bb_mcp_check() {
  local pf
  case "${BB_TRANSPORT:-rest}" in rest) ;; mcp) ;; *) echo "BB_TRANSPORT must be rest or mcp (is '${BB_TRANSPORT:-}')" >&2; return 1 ;; esac
  [ "${BB_TRANSPORT:-rest}" = mcp ] || return 0
  BBM_SERVER="${ASDLC_BB_MCP_SERVER:-}"
  if [ -z "$BBM_SERVER" ]; then
    echo "BB_TRANSPORT=mcp needs ASDLC_BB_MCP_SERVER (the name of your Bitbucket MCP server) in your shell environment; it is never a config key" >&2; return 1
  fi
  [[ $BBM_SERVER =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ASDLC_BB_MCP_SERVER must be letters, digits, _ and - only" >&2; return 1; }
  BBM_PROFILE="${ASDLC_BB_MCP_PROFILE:-$BBM_SERVER}"
  [[ $BBM_PROFILE =~ ^[A-Za-z0-9_-]+$ ]] || { echo "ASDLC_BB_MCP_PROFILE must be letters, digits, _ and - only" >&2; return 1; }
  pf="$ASDLC_JIRA_HOME/mcp/bitbucket-$BBM_PROFILE.json"
  if [ ! -f "$pf" ]; then
    echo "BB_TRANSPORT=mcp: no Bitbucket MCP profile '$BBM_PROFILE' (expected jira/mcp/bitbucket-$BBM_PROFILE.json in the plugin). No profile for a real Bitbucket MCP server ships yet; use BB_TRANSPORT=rest (the token path)." >&2; return 1
  fi
  if [ "$(jq -r '.test // false' "$pf" 2>/dev/null)" = true ] && [ "${ASDLC_ALLOW_TEST_BB_PROFILE:-0}" != 1 ]; then
    echo "BB_TRANSPORT=mcp: the '$BBM_PROFILE' profile is for tests only (synthetic tool names), not a real Bitbucket MCP server; use BB_TRANSPORT=rest (the token path)." >&2; return 1
  fi
  jq -e '(.profile | type) == "string" and ([.open_pr, .pr_comment] | all(
          type == "object" and (.tool | type == "string" and test("^[A-Za-z][A-Za-z0-9_-]*$"))
          and (.args | type) == "object"
          and (.response.id | type == "string" and test("^[A-Za-z0-9_.]+$"))
          and (.response.url | type == "string" and test("^[A-Za-z0-9_.]+$"))))' "$pf" >/dev/null 2>&1 ||
    { echo "BB_TRANSPORT=mcp: the profile jira/mcp/bitbucket-$BBM_PROFILE.json is not valid (each of open_pr and pr_comment needs tool, args, response.id and response.url)" >&2; return 1; }
  BBM_PROFILE_FILE="$pf"
}

# Open a request for <op> (open_pr|pr_comment) with the placeholder values in <vars-json>, and print
# the one call to make: {"tool":"mcp__<server>__<tool>","args":{...}}. Dies on a bad setup.
asdlc_bb_mcp_open() {  # <op> <vars-json>
  local op="$1" vars="$2" dir=plans/.mcp/bb now nonce rtmp args
  asdlc_bb_mcp_check || exit 2
  [ "$BB_TRANSPORT" = mcp ] || { echo "BB_TRANSPORT is rest: the --mcp-args and --from-mcp options need BB_TRANSPORT=mcp" >&2; exit 2; }
  [ -n "$BB_WORKSPACE" ] || asdlc_die "BB_WORKSPACE is not set in $ASDLC_CONF_FILE"
  [ -n "$BB_REPO" ]      || asdlc_die "BB_REPO is not set in $ASDLC_CONF_FILE"
  asdlc_check_bb_target
  args="$(jq -c --argjson v "$vars" --arg op "$op" '
      def fill: if type == "string" and test("^\\{[a-z_]+\\}$") then ($v[.[1:-1]] // error("unknown placeholder " + .)) else . end;
      .[$op].args | walk(fill)' "$BBM_PROFILE_FILE")" || asdlc_die "the profile's $op arguments could not be filled in"
  if [ -L plans ] || [ -L plans/.mcp ] || [ -L "$dir" ]; then asdlc_die "refusing: plans/, plans/.mcp or $dir is a symbolic link"; fi
  mkdir -p "$dir"; rm -f "$dir"/request.json "$dir"/cap-*.json
  now=$(date +%s); nonce="$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  rtmp="$(mktemp "$dir/.request.XXXXXX")"
  jq -n --arg op "$op" --arg server "$BBM_SERVER" --arg nonce "$nonce" --argjson now "$now" --argjson args "$args" --slurpfile p "$BBM_PROFILE_FILE" \
        '{v: 1, kind: "bb", op: $op, server: $server, tool: $p[0][$op].tool, nonce: $nonce, created_epoch: $now,
          expires_epoch: ($now + 600), args: $args, id_path: $p[0][$op].response.id, url_path: $p[0][$op].response.url}' > "$rtmp" \
    || { rm -f "$rtmp"; asdlc_die "could not write the Bitbucket request"; }
  mv "$rtmp" "$dir/request.json"
  jq -c '{tool: ("mcp__" + .server + "__" + .tool), args: .args}' "$dir/request.json"
}

# Read the capture of the open <op> request and print "<id> <url>" (the REST contract); the request
# and captures are used up. Returns 1 with the reason on stderr when there is nothing valid.
asdlc_bb_mcp_take() {  # <op>
  local op="$1" dir=plans/.mcp/bb req=plans/.mcp/bb/request.json line v kind rop server tool nonce created expires f e best="" beste=-1 out
  asdlc_bb_mcp_check || return 1
  [ "$BB_TRANSPORT" = mcp ] || { echo "BB_TRANSPORT is rest: the --mcp-args and --from-mcp options need BB_TRANSPORT=mcp" >&2; return 1; }
  if [ -L plans ] || [ -L plans/.mcp ] || [ -L "$dir" ] || [ -L "$req" ]; then echo "refusing: plans/, plans/.mcp or $dir is a symbolic link" >&2; return 1; fi
  [ -f "$req" ] || { echo "no open Bitbucket MCP request; run with --mcp-args, make the call it prints, then retry" >&2; return 1; }
  line="$(jq -r '[.v, .kind, .op, .server, .tool, .nonce, .created_epoch, .expires_epoch] | map(tostring) | join(" ")' "$req" 2>/dev/null)" || line=""
  read -r v kind rop server tool nonce created expires <<<"$line" || true
  if ! { [ "${v:-}" = 1 ] && [ "${kind:-}" = bb ] && [[ ${nonce:-} =~ ^[0-9a-f]{8,64}$ ]] && [[ ${created:-} =~ ^[0-9]+$ ]] &&
         [[ ${expires:-} =~ ^[0-9]+$ ]] && [ "${server:-}" = "$BBM_SERVER" ]; }; then
    echo "the Bitbucket MCP request is unreadable (or for another server); open a new one with --mcp-args" >&2; return 1
  fi
  [ "$rop" = "$op" ] || { echo "the open Bitbucket MCP request is for $rop, not $op; open a new one" >&2; return 1; }
  [ "$expires" -gt "$(date +%s)" ] || { echo "the Bitbucket MCP request has expired; open a new one with --mcp-args" >&2; return 1; }
  for f in "$dir"/cap-*.json; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    e="$(jq -r --arg n "$nonce" --argjson c "$created" --arg t "mcp__${server}__${tool}" '
          select(type == "object" and .nonce == $n and .tool_name == $t and .role == "bb"
                 and (.captured_epoch | type) == "number" and .captured_epoch >= $c
                 and (.response.id | type) == "string" and (.response.id | test("^[0-9]{1,18}$")))
          | .captured_epoch | floor' "$f" 2>/dev/null)" || continue
    [[ $e =~ ^[0-9]+$ ]] || continue
    if [ "$e" -gt "$beste" ] || { [ "$e" = "$beste" ] && [[ $f > $best ]]; }; then best="$f"; beste="$e"; fi
  done
  [ -n "$best" ] || { echo "no valid capture under the open Bitbucket MCP request (make the call --mcp-args printed, with exactly those args)" >&2; return 1; }
  out="$(jq -r '"\(.response.id) \(.response.url // "")"' "$best" 2>/dev/null)" || { echo "could not read the capture" >&2; return 1; }
  if [ "$op" = open_pr ] && [ "${out#* }" = "" ]; then echo "the capture holds no PR URL (check response.url in the profile)" >&2; return 1; fi
  rm -f "$dir"/request.json "$dir"/cap-*.json; rmdir "$dir" 2>/dev/null || true
  printf '%s\n' "$out"
}
