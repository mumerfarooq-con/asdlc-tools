#!/usr/bin/env bash
# Set up the Jira leg in a project repo. Used by /asdlc:jira-setup.
# Usage:
#   jira-setup.sh init [--force]   # write .asdlc/jira.conf from the template; values
#                                  # pre-filled from the env vars older setups used
#   jira-setup.sh check            # config complete, tokens set, one Jira + one
#                                  # Bitbucket call, workflow statuses exist
#   jira-setup.sh docs             # create the access-rules and known-traps files if missing
# Exit 1 when a check fails; warnings alone exit 0.
set -euo pipefail
# Snapshot legacy env vars whose names are also config keys: loading the
# config's defaults below overwrites them.
LEGACY_BOARD_ID="${JIRA_BOARD_ID:-}"
LEGACY_COUNCIL_FILES="${REVIEW_COUNCIL_FILES:-}"
LEGACY_COUNCIL_LINES="${REVIEW_COUNCIL_LINES:-}"
LEGACY_COUNCIL_PATHS="${REVIEW_COUNCIL_PATHS:-}"
. "$(dirname "$0")/lib.sh"
ASDLC_CONF_OPTIONAL=1 asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}
TEMPLATES="$ASDLC_JIRA_HOME/templates"
cmd="${1:?usage: jira-setup.sh <init|check|docs>}"
TOP="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

fails=0
ok()   { echo "ok    $*"; }
warn() { echo "warn  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }

# Jira project keys are upper-case letters, digits and underscores (PROJ, AB2).
is_project_key() { printf '%s' "$1" | grep -qE '^[A-Z][A-Z0-9_]+$'; }

# Older in-repo setups kept project values in these env vars. JIRA_PROJECT
# held either the key or the display name (JQL accepts both, the REST
# endpoints don't), so it fills whichever one it looks like.
legacy_value() {  # <conf key> -> value from the matching legacy env var, if any
  case "$1" in
    JIRA_BASE_URL)        v="${JIRA_URL:-}"; printf '%s' "${v%/}" ;;
    JIRA_PROJECT_KEY)     is_project_key "${JIRA_PROJECT:-}" && printf '%s' "$JIRA_PROJECT" ;;
    JIRA_PROJECT_NAME)    [ -n "${JIRA_PROJECT:-}" ] && ! is_project_key "$JIRA_PROJECT" && printf '%s' "$JIRA_PROJECT" ;;
    JIRA_BOARD_ID)        printf '%s' "$LEGACY_BOARD_ID" ;;
    STATUS_DEFAULT)       printf '%s' "${JIRA_TODO_STATUS:-}" ;;
    STATUS_TODO)          [ -n "${JIRA_TODO_STATUS:-}" ] && asdlc_split_csv "$JIRA_TODO_STATUS" | head -n1 | tr -d '\n' ;;
    STATUS_TESTING)       printf '%s' "${JIRA_TESTING_STATUS:-}" ;;
    NOTIFY_ACCOUNT_IDS)   printf '%s' "${JIRA_NOTIFY_ACCOUNTIDS:-}" ;;
    BB_WORKSPACE)         printf '%s' "${BITBUCKET_WORKSPACE:-}" ;;
    BB_REPO)              printf '%s' "${BITBUCKET_REPO:-}" ;;
    TARGET_BRANCH)        printf '%s' "${BITBUCKET_DEST_BRANCH:-}" ;;
    REVIEW_COUNCIL_FILES) printf '%s' "$LEGACY_COUNCIL_FILES" ;;
    REVIEW_COUNCIL_LINES) printf '%s' "$LEGACY_COUNCIL_LINES" ;;
    REVIEW_COUNCIL_PATHS) printf '%s' "$LEGACY_COUNCIL_PATHS" ;;
  esac
  return 0
}

do_init() {
  local force=0; [ "${1:-}" = "--force" ] && force=1
  if [ -f "$ASDLC_CONF_FILE" ] && [ "$force" -eq 0 ]; then
    echo "exists: $ASDLC_CONF_FILE (left unchanged; --force to rewrite from the template)"
    return 0
  fi
  mkdir -p "$(dirname "$ASDLC_CONF_FILE")"
  local out filled="" k v
  out="$(mktemp)"; cp "$TEMPLATES/jira.conf" "$out"
  for k in $ASDLC_CONF_KEYS; do
    v="$(legacy_value "$k")"
    [ -n "$v" ] || continue
    K="$k" V="$v" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]}
      index($0, k "=") == 1 { print k "=" v; next } { print }' "$out" > "$out.n" && mv "$out.n" "$out"
    filled="$filled $k"
  done
  mv "$out" "$ASDLC_CONF_FILE"
  echo "wrote: $ASDLC_CONF_FILE"
  [ -n "$filled" ] && echo "pre-filled from env:$filled"
  asdlc_load_conf
  local missing=""
  for k in JIRA_BASE_URL JIRA_PROJECT_KEY BB_WORKSPACE BB_REPO TARGET_BRANCH; do
    [ -n "${!k}" ] || missing="$missing $k"
  done
  [ -n "$missing" ] && echo "still empty (fill these in):$missing"
  return 0
}

do_docs() {
  local pair src dst
  for pair in "access-rules.md:$ACCESS_RULES_PATH" "known-traps.md:$KNOWN_TRAPS_PATH"; do
    src="$TEMPLATES/docs/${pair%%:*}"; dst="$TOP/${pair#*:}"
    if [ -f "$dst" ]; then echo "exists: ${pair#*:}"; continue; fi
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; echo "created: ${pair#*:}"
  done
}

do_check() {
  [ -f "$ASDLC_CONF_FILE" ] || { fail "no config at $ASDLC_CONF_FILE — run: jira-setup.sh init"; return; }
  ok "config: $ASDLC_CONF_FILE"
  local k
  for k in JIRA_BASE_URL JIRA_PROJECT_KEY BB_WORKSPACE BB_REPO TARGET_BRANCH; do
    [ -n "${!k}" ] || fail "$k is empty in the config"
  done
  case "$TICKET_CHECK_MODE" in strict|warn) ;; *) fail "TICKET_CHECK_MODE must be strict or warn (is '$TICKET_CHECK_MODE')" ;; esac
  case "$BB_AUTH" in bearer|basic) ;; *) fail "BB_AUTH must be bearer or basic (is '$BB_AUTH')" ;; esac
  [ "$fails" -eq 0 ] || return 0

  # Token env vars: report presence only, never values.
  for k in JIRA_EMAIL JIRA_TOKEN BITBUCKET_TOKEN; do
    if [ -n "${!k:-}" ] || [ -n "$ASDLC_FIXTURES" ]; then ok "env $k is set"; else fail "env $k is not set"; fi
  done
  if [ "$BB_AUTH" = "basic" ] && [ -z "${BITBUCKET_EMAIL:-}" ] && [ -z "$ASDLC_FIXTURES" ]; then
    fail "env BITBUCKET_EMAIL is not set (BB_AUTH=basic)"
  fi
  [ "$fails" -eq 0 ] || return 0

  local tmp code; tmp="$(mktemp)"
  code=$(asdlc_http jira GET /rest/api/2/myself "$tmp")
  if asdlc_http_ok "$code"; then ok "Jira: signed in as $(jq -r '.displayName // .emailAddress // "?"' "$tmp")"
  else fail "Jira test call (HTTP $code)"; asdlc_http_fail jira "$code" "$tmp" 2>&1 | sed 's/^/      /'; fi

  code=$(asdlc_http jira GET "/rest/api/2/project/$JIRA_PROJECT_KEY" "$tmp")
  if asdlc_http_ok "$code"; then
    local name; name="$(jq -r '.name' "$tmp")"
    ok "Jira project $JIRA_PROJECT_KEY: $name"
    if [ -z "$JIRA_PROJECT_NAME" ]; then warn "JIRA_PROJECT_NAME is empty; the project is called \"$name\""
    elif [ "$JIRA_PROJECT_NAME" != "$name" ]; then warn "JIRA_PROJECT_NAME is \"$JIRA_PROJECT_NAME\"; Jira calls it \"$name\""; fi
  else
    fail "Jira project $JIRA_PROJECT_KEY (HTTP $code)"
    is_project_key "$JIRA_PROJECT_KEY" || \
      echo "      JIRA_PROJECT_KEY must be the project KEY (as in PROJ-123), not its display name"
  fi

  code=$(asdlc_http jira GET "/rest/api/2/project/$JIRA_PROJECT_KEY/statuses" "$tmp")
  if asdlc_http_ok "$code"; then
    local names s; names="$(jq -r '[.[].statuses[].name] | unique[]' "$tmp")"
    check_status() {  # <label> <status> <fail|warn>
      if printf '%s\n' "$names" | grep -qxF "$2"; then ok "status $1: \"$2\""
      elif printf '%s\n' "$names" | grep -qixF "$2"; then "$3" "status $1: \"$2\" differs in case from Jira's \"$(printf '%s\n' "$names" | grep -ixF "$2" | head -n1)\""
      else "$3" "status $1: \"$2\" is not in the $JIRA_PROJECT_KEY workflow"; fi
    }
    while IFS= read -r s; do check_status STATUS_DEFAULT "$s" fail; done < <(asdlc_split_csv "$STATUS_DEFAULT")
    check_status STATUS_TODO "$STATUS_TODO" fail
    check_status STATUS_IN_PROGRESS "$STATUS_IN_PROGRESS" fail
    check_status STATUS_TESTING "$STATUS_TESTING" fail
    check_status STATUS_NEEDS_INFO "$STATUS_NEEDS_INFO" warn
    printf '%s\n' "$names" | grep -qxF "$STATUS_NEEDS_INFO" || \
      echo "      (a Jira admin must add it before TICKET_CHECK_MODE=strict can move tickets there)"
  else fail "Jira workflow statuses (HTTP $code)"; fi

  code=$(asdlc_http bb GET "/repositories/$BB_WORKSPACE/$BB_REPO" "$tmp")
  if asdlc_http_ok "$code"; then ok "Bitbucket: $(jq -r '.full_name' "$tmp")"
  else fail "Bitbucket test call (HTTP $code)"; asdlc_http_fail bb "$code" "$tmp" 2>&1 | sed 's/^/      /'; fi

  code=$(asdlc_http bb GET "/repositories/$BB_WORKSPACE/$BB_REPO/refs/branches/$TARGET_BRANCH" "$tmp")
  if asdlc_http_ok "$code"; then ok "Bitbucket branch: $TARGET_BRANCH"
  else fail "Bitbucket branch $TARGET_BRANCH not found (HTTP $code)"; fi
  rm -f "$tmp"

  for k in ACCESS_RULES_PATH KNOWN_TRAPS_PATH; do
    if [ -f "$TOP/${!k}" ]; then ok "${!k} exists"; else warn "${!k} missing — run: jira-setup.sh docs"; fi
  done
}

case "$cmd" in
  init)  do_init "${2:-}" ;;
  docs)  asdlc_load_conf; do_docs ;;
  check) asdlc_load_conf; do_check
         if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed."; exit 1; fi
         echo "All checks passed." ;;
  *)     echo "unknown command: $cmd" >&2; exit 2 ;;
esac
