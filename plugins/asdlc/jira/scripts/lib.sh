# shellcheck shell=bash
# Shared helpers for the Jira leg: project config, fixture mode, HTTP calls.
# Sourced by the scripts in this directory; not meant to be run on its own.
# Written for bash 3.2 (macOS): no associative arrays, and never expand a
# possibly-empty array under `set -u` without the ${a[@]+"${a[@]}"} guard.

ASDLC_JIRA_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASDLC_JIRA_HOME="$(dirname "$ASDLC_JIRA_SCRIPTS")"

# Keys a project's .asdlc/jira.conf may set. The file is parsed, never sourced,
# and anything outside this list is ignored with a warning, so a committed
# config can't run code or override PATH and friends.
ASDLC_CONF_KEYS="JIRA_BASE_URL JIRA_PROJECT_KEY JIRA_PROJECT_NAME JIRA_BOARD_ID
BB_WORKSPACE BB_REPO BB_AUTH TARGET_BRANCH
STATUS_DEFAULT STATUS_TODO STATUS_IN_PROGRESS STATUS_NEEDS_INFO STATUS_TESTING
NOTIFY_ACCOUNT_IDS TEMPLATE_BUG_TYPES TICKET_CHECK_MODE PIPELINE_COMMENT_MARKER
LINK_BLOCKER_TYPES LINK_DUPLICATE_TYPES SENSITIVE_TOPICS
ACCESS_RULES_PATH KNOWN_TRAPS_PATH IMPACT_EXTRA_PATHS IMPACT_EXCLUDE
MAX_IMAGES MAX_IMAGE_MB REVIEW_COUNCIL_FILES REVIEW_COUNCIL_LINES REVIEW_COUNCIL_PATHS"

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

# asdlc_http <jira|bb> <METHOD> <path> <outfile> [curl args...]
# Writes the response body to <outfile> and prints the HTTP status code
# (000 when the host can't be reached). Paths are relative to the service's
# API root: "/rest/api/2/..." for Jira, "/repositories/..." for Bitbucket.
asdlc_http() {
  local svc="$1" method="$2" path="$3" out="$4"; shift 4
  if [ -n "$ASDLC_FIXTURES" ]; then asdlc_fixture_http "$svc" "$method" "$path" "$out" "$@"; return; fi
  local args=(-sS -o "$out" -w '%{http_code}' -H "Accept: application/json")
  case "$svc" in
    jira) args+=(--user "$JIRA_EMAIL:$JIRA_TOKEN"); path="$JIRA_BASE_URL$path" ;;
    bb)   if [ "$BB_AUTH" = "basic" ]; then args+=(--user "$BITBUCKET_EMAIL:$BITBUCKET_TOKEN")
          else args+=(-H "Authorization: Bearer $BITBUCKET_TOKEN"); fi
          path="https://api.bitbucket.org/2.0$path" ;;
    *)    asdlc_die "asdlc_http: unknown service $svc" ;;
  esac
  if [ "$method" = "GET" ]; then args+=(-G); else args+=(-X "$method"); fi
  local code
  # "--" ends option parsing, so the URL can never be read as a curl option.
  code="$(curl "${args[@]}" "$@" -- "$path")" || code="000"
  printf '%s' "${code:-000}"
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
