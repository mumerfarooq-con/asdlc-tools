#!/usr/bin/env bash
# Deterministic state + hashing for /asdlc:jira-run plan files.
# Header block (HTML comment) at the TOP of ./plans/<KEY>.plan.md:
#   <!-- asdlc
#   ticket: PROJ-142
#   status: pending          # you change this to: approved
#   plan_hash: sha256:<hex>  # tool-stamped over the plan body — do not edit
#   branch:
#   pr:
#   updated: <iso8601>
#   -->
#   <plan body>
# Plans written by the pre-plugin in-repo version open with "<!-- jira-run:approval";
# those are read the same way and get the current marker the next time they are stamped.
#
# Usage:
#   plan-state.sh stamp <plan> [ticket]      # (re)write block: status=pending, fresh hash
#   plan-state.sh check <plan>               # RUNNABLE|PENDING|STALE|EXECUTING|DONE|FAILED|SKIP|MISSING
#   plan-state.sh set   <plan> <field> <val> # field: status|branch|pr
#   plan-state.sh reset-executing <plan>     # crashed run: executing -> approved, only if the body is unchanged
#   plan-state.sh get   <plan> <field>
#
# Approval is a human edit of the plan file. Nothing callable here can set "approved"
# except reset-executing, which only undoes an executing run whose body hash still matches.
# "set <plan> status <v>" refuses (exit 2) unless the move is allowed:
#   approved               never
#   executing              only while check says RUNNABLE (approved + hash matches)
#   done | failed          only from executing
#   pending|skip|rejected  always (they fail closed)
# Exit codes: check = 0 RUNNABLE, 10 PENDING, 11 STALE, 12 EXECUTING, 13 DONE, 14 FAILED,
# 15 SKIP, 16 MISSING. Elsewhere: 2 = refused or bad input; 3 = stamp wrote nothing (header
# not closed, or empty body); 11 = reset-executing found the body changed; 16 = no header block.
set -euo pipefail
MARKER='<!-- asdlc'
# jira-run:approval is read so plans written by the pre-plugin in-repo version keep working;
# drop that alternation once those plans are retired.
MARKER_RE='^<!-- (asdlc|jira-run:approval)[ \t]*$'

die() { echo "$2" >&2; exit "$1"; }

# Temp files are removed on every exit path, including a refused or failed stamp.
btmp=""; otmp=""
cleanup() {
  if [ -n "$btmp" ]; then rm -f "$btmp"; fi
  if [ -n "$otmp" ]; then rm -f "$otmp"; fi
}
trap cleanup EXIT

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
        else shasum -a 256 | awk '{print $1}'; fi; }

has_block() { head -n1 "$1" 2>/dev/null | grep -qE "$MARKER_RE"; }

# True if the whole value matches the ERE. [[ =~ ]] anchors on the whole string, so a value
# with a newline in it cannot pass by matching only its first line (grep would).
re_ok() { ( LC_ALL=C; [[ $1 =~ $2 ]] ); }
has_eol() { case "$1" in *$'\n'*|*$'\r'*) return 0 ;; esac; return 1; }

# plan body = everything after the block's closing "-->"; whole file if no block.
# Always piped through awk so hashing is byte-identical between stamp and check.
body_of() {
  if has_block "$1"; then
    awk 'BEGIN{inb=1} inb && /^-->[ \t]*$/ {inb=0; next} !inb {print}' "$1"
  else
    awk '{print}' "$1"
  fi
}

# Does the file have a closing "-->" line (same pattern body_of uses)?
has_close() { awk '/^-->[ \t]*$/ {f=1} END{exit !f}' "$1"; }

hdr_get() {  # <file> <field>
  awk -v k="$2:" '/^-->[ \t]*$/ {exit} $1==k {sub(/^[^:]*:[ \t]*/,""); print; exit}' "$1"
}

hdr_count() {  # <file> <field>: how many header lines carry this field
  awk -v k="$2:" '/^-->[ \t]*$/ {exit} $1==k {n++} END {print n+0}' "$1"
}

# Shared by check, set and reset-executing so they cannot disagree about the state.
# Sets STATE, STATE_CODE, STATE_MSG (stderr text, may be empty), CUR_HASH, STORED_HASH.
compute_state() {
  STATE_MSG=""; CUR_HASH=""; STORED_HASH=""
  if [ ! -f "$plan" ] || ! has_block "$plan"; then STATE=MISSING; STATE_CODE=16; return 0; fi
  # hdr_get takes the first match, so a second status:/plan_hash: line is tampering.
  if [ "$(hdr_count "$plan" status)" -gt 1 ] || [ "$(hdr_count "$plan" plan_hash)" -gt 1 ]; then
    STATE=STALE; STATE_CODE=11
    STATE_MSG="  duplicate header field — re-stamp and re-approve"
    return 0
  fi
  local st
  st="$(hdr_get "$plan" status)"
  STORED_HASH="$(hdr_get "$plan" plan_hash)"; STORED_HASH="${STORED_HASH#sha256:}"
  CUR_HASH="$(body_of "$plan" | sha)"
  case "$st" in
    approved) if [ "$CUR_HASH" = "$STORED_HASH" ]; then STATE=RUNNABLE; STATE_CODE=0
              else STATE=STALE; STATE_CODE=11
                   STATE_MSG="  plan body changed since it was stamped — re-plan, or 'plan-state.sh stamp' then re-approve"
              fi ;;
    pending)       STATE=PENDING;   STATE_CODE=10 ;;
    executing)     STATE=EXECUTING; STATE_CODE=12 ;;
    done)          STATE=DONE;      STATE_CODE=13 ;;
    failed)        STATE=FAILED;    STATE_CODE=14 ;;
    skip|rejected) STATE=SKIP;      STATE_CODE=15 ;;
    *)             STATE=PENDING;   STATE_CODE=10 ;;
  esac
  return 0
}

# Replace one header line and bump "updated". Values go into awk through ENVIRON, not -v,
# because -v expands backslash escapes ('a\nb' would inject a header line).
write_field() {  # <field> <val>
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; otmp="$(mktemp)"
  K="$1:" V="$2" NOW="$now" awk '
    NR==1 {inb=1; print; next}
    inb && /^-->[ \t]*$/ {inb=0; print; next}
    inb && $1==ENVIRON["K"] {print ENVIRON["K"] " " ENVIRON["V"]; next}
    inb && $1=="updated:" {print "updated: " ENVIRON["NOW"]; next}
    {print}
  ' "$plan" > "$otmp"
  mv "$otmp" "$plan"
}

cmd="${1:?usage: plan-state.sh <stamp|check|set|reset-executing|get> <plan> ...}"
plan="${2:?plan file required}"

case "$cmd" in
  stamp)
    ticket="${3:-$(basename "$plan" .plan.md)}"
    # The ticket lands in the header, so it must not carry a newline or anything odd.
    if has_eol "$ticket" || ! re_ok "$ticket" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
      die 2 "refusing: ticket must match [A-Za-z0-9][A-Za-z0-9._-]* (a key like PROJ-142 or a PRD basename)"
    fi
    # Guards first; the plan is only replaced after every one passes.
    if has_block "$plan" && ! has_close "$plan"; then
      die 3 "header block not closed in $plan — no line is exactly '-->' at column 0; nothing written"
    fi
    btmp="$(mktemp)"; body_of "$plan" > "$btmp"
    if [ -z "$(LC_ALL=C tr -d ' \t\r\n\f\v' < "$btmp")" ]; then
      die 3 "empty plan body in $plan — nothing to stamp; nothing written"
    fi
    h="$(sha < "$btmp")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    otmp="$(mktemp)"
    { printf '%s\n' "$MARKER"
      printf 'ticket: %s\n' "$ticket"
      printf 'status: pending\n'
      printf 'plan_hash: sha256:%s\n' "$h"
      printf 'branch:\n'; printf 'pr:\n'
      printf 'updated: %s\n' "$now"
      printf '%s\n' '-->'
      cat "$btmp"; } > "$otmp"
    mv "$otmp" "$plan"
    echo "stamped $plan (pending, sha256:${h:0:12}…)"
    ;;
  check)
    compute_state
    echo "$STATE"
    if [ -n "$STATE_MSG" ]; then echo "$STATE_MSG" >&2; fi
    exit "$STATE_CODE"
    ;;
  set)
    field="${3:?field required (status|branch|pr)}"; val="${4-}"
    case "$field" in status|branch|pr) ;; *) echo "field must be status|branch|pr" >&2; exit 2 ;; esac
    # Validate the value before touching the file: it is written into the header.
    if has_eol "$val"; then die 2 "refusing: the $field value contains a newline or carriage return"; fi
    case "$field" in
      status)
        case "$val" in
          approved) die 2 "refusing: approval is a human edit of the plan file" ;;
          executing|done|failed|pending|skip|rejected) ;;
          *) die 2 "refusing: unknown status '$val' (allowed: pending|executing|done|failed|skip|rejected)" ;;
        esac ;;
      branch)
        re_ok "$val" '^[A-Za-z0-9._/-]*$' || die 2 "refusing: branch may only contain [A-Za-z0-9._/-]" ;;
      pr)
        [ -z "$val" ] || re_ok "$val" '^https://[^[:space:]]+$' || die 2 "refusing: pr must be empty or an https:// URL with no whitespace" ;;
    esac
    has_block "$plan" || die 16 "no header block in $plan — run 'plan-state.sh stamp' first"
    if [ "$field" = status ]; then
      compute_state
      case "$val" in
        executing)
          [ "$STATE" = RUNNABLE ] || die 2 "refusing: executing needs a RUNNABLE plan (this one is $STATE)" ;;
        done|failed)
          [ "$STATE" = EXECUTING ] || die 2 "refusing: '$val' only follows executing (this plan is $STATE)" ;;
      esac
    fi
    write_field "$field" "$val"
    echo "set $field=$val on $plan"
    ;;
  reset-executing)
    compute_state
    case "$STATE" in
      EXECUTING) ;;
      MISSING) die 16 "no header block in $plan — nothing to reset" ;;
      *) die 2 "refusing: $plan is $STATE, not EXECUTING — reset-executing only recovers a crashed run" ;;
    esac
    # Compare-and-set: the approval only carries over if the approved body is untouched.
    if [ "$CUR_HASH" != "$STORED_HASH" ]; then
      die 11 "plan body changed during the crashed run — re-stamp ('plan-state.sh stamp') and have a human re-approve"
    fi
    write_field status approved
    echo "reset $plan: executing -> approved"
    ;;
  get) hdr_get "$plan" "${3:?field required}" ;;
  *)   echo "unknown command: $cmd" >&2; exit 2 ;;
esac
