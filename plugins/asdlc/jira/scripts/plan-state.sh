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
# Plans written by earlier in-repo versions open with "<!-- jira-run:approval"
# (or "<!-- jira_ticket_templates-run:approval"); those are read the same way and
# get the current marker the next time they are stamped.
#
# Usage:
#   plan-state.sh stamp <plan> [ticket]      # (re)write block: status=pending, fresh hash
#   plan-state.sh check <plan>               # RUNNABLE|PENDING|STALE|EXECUTING|DONE|FAILED|SKIP|MISSING
#   plan-state.sh set   <plan> <field> <val> # field: status|branch|pr
#   plan-state.sh get   <plan> <field>
set -euo pipefail
MARKER='<!-- asdlc'
MARKER_RE='^<!-- (asdlc|jira-run:approval|jira_ticket_templates-run:approval)[ \t]*$'

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
        else shasum -a 256 | awk '{print $1}'; fi; }

has_block() { head -n1 "$1" 2>/dev/null | grep -qE "$MARKER_RE"; }

# plan body = everything after the block's closing "-->"; whole file if no block.
# Always piped through awk so hashing is byte-identical between stamp and check.
body_of() {
  if has_block "$1"; then
    awk 'BEGIN{inb=1} inb && /^-->[ \t]*$/ {inb=0; next} !inb {print}' "$1"
  else
    awk '{print}' "$1"
  fi
}

hdr_get() {  # <file> <field>
  awk -v k="$2:" '/^-->[ \t]*$/ {exit} $1==k {sub(/^[^:]*:[ \t]*/,""); print; exit}' "$1"
}

cmd="${1:?usage: plan-state.sh <stamp|check|set|get> <plan> ...}"
plan="${2:?plan file required}"

case "$cmd" in
  stamp)
    ticket="${3:-$(basename "$plan" .plan.md)}"
    btmp="$(mktemp)"; body_of "$plan" > "$btmp"
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
    mv "$otmp" "$plan"; rm -f "$btmp"
    echo "stamped $plan (pending, sha256:${h:0:12}…)"
    ;;
  check)
    if [ ! -f "$plan" ] || ! has_block "$plan"; then echo "MISSING"; exit 16; fi
    st="$(hdr_get "$plan" status)"
    stored="$(hdr_get "$plan" plan_hash)"; stored="${stored#sha256:}"
    cur="$(body_of "$plan" | sha)"
    case "$st" in
      approved) if [ "$cur" = "$stored" ]; then echo "RUNNABLE"; exit 0
                else echo "STALE"
                     echo "  plan body changed since it was stamped — re-plan, or 'plan-state.sh stamp' then re-approve" >&2
                     exit 11; fi ;;
      pending)       echo "PENDING";   exit 10 ;;
      executing)     echo "EXECUTING"; exit 12 ;;
      done)          echo "DONE";      exit 13 ;;
      failed)        echo "FAILED";    exit 14 ;;
      skip|rejected) echo "SKIP";      exit 15 ;;
      *)             echo "PENDING";   exit 10 ;;
    esac
    ;;
  set)
    field="${3:?field required (status|branch|pr)}"; val="${4-}"
    case "$field" in status|branch|pr) ;; *) echo "field must be status|branch|pr" >&2; exit 2 ;; esac
    has_block "$plan" || { echo "no header block in $plan — run 'plan-state.sh stamp' first" >&2; exit 16; }
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; otmp="$(mktemp)"
    awk -v k="$field:" -v v="$val" -v now="$now" '
      NR==1 {inb=1; print; next}
      inb && /^-->[ \t]*$/ {inb=0; print; next}
      inb && $1==k        {print k" "v; next}
      inb && $1=="updated:" {print "updated: " now; next}
      {print}
    ' "$plan" > "$otmp"
    mv "$otmp" "$plan"
    echo "set $field=$val on $plan"
    ;;
  get) hdr_get "$plan" "${3:?field required}" ;;
  *)   echo "unknown command: $cmd" >&2; exit 2 ;;
esac
