#!/usr/bin/env bash
# HUMAN ONLY. The one place a plan becomes approved: validate, re-hash the approved part,
# status=approved. It is in its own script so that "never pre-approved" is one plain rule:
# no command's allowed-tools may mention plan-approve.sh (tests/jira/test-hygiene.sh checks
# every command). /asdlc:plan approve is its only caller, so the harness asks the human to
# confirm each call. Nothing an agent runs may call it, and plan-state.sh has no approve.
# Usage: plan-approve.sh <plan>   (<plan> is a path, or a bare id meaning ./plans/<ID>.plan.md)
# Exit codes: 0 approved; 2 refused or bad input; 16 no header block; 20 plan INVALID (nothing
# written).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/plan-lib.sh"

# Explicit, not ${1:?}: the EXIT trap in plan-lib.sh would turn that failure into exit 0.
[ $# -eq 1 ] || die 2 "usage: plan-approve.sh <plan file or ticket id>"
plan="$1"
# Same id rule as plan-state.sh: a bare ID (no '/', not ending .md) means ./plans/<ID>.plan.md.
case "$plan" in
  */*|*.md) ;;
  *) if has_eol "$plan" || ! re_ok "$plan" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
       die 2 "refusing: a bare plan id must match [A-Za-z0-9][A-Za-z0-9._-]* (or pass a path)"
     fi
     plan="./plans/$plan.plan.md" ;;
esac

[ -f "$plan" ] || die 2 "no such plan: $plan"
vrc=0; do_validate || vrc=$?
[ "$vrc" -eq 0 ] || exit 20
compute_state
can=0
case "$STATE" in
  PENDING|NEEDS_INFO|BLOCKED) can=1 ;;
  # The ticket changed after approval: the plan was built from text that is gone, so it is
  # re-planned, not re-approved.
  STALE) die 2 "refusing: $plan is STALE (the ticket changed after approval) — re-plan it ('/asdlc:plan replan'), then approve the new plan" ;;
  # a human edit of an approved plan: re-approvable, but not a tampered header or progress line
  EDITED) if [ "$(hdr_get "$plan" status)" = approved ] && [ "$(hdr_count "$plan" status)" -eq 1 ] \
             && [ "$(hdr_count "$plan" plan_hash)" -eq 1 ] && [ "$(progress_count "$plan")" -le 1 ] \
             && [ "$(hdr_count "$plan" ticket_fingerprint)" -le 1 ] && [ "$(hdr_count "$plan" fingerprint_at)" -le 1 ] \
             && [ "$(hdr_count "$plan" fingerprint_source)" -le 1 ]; then can=1; fi ;;
  MISSING) die 16 "no header block in $plan — run 'plan-state.sh stamp' first" ;;
esac
[ "$can" -eq 1 ] || die 2 "refusing: $plan is $STATE; approve needs a pending, needs-info or blocked plan, or an approved plan the human edited"
# Hash first, status second: a crash between them leaves the plan EDITED, never RUNNABLE by accident.
write_field plan_hash "sha256:$CUR_HASH"
write_field status approved
echo "approved $(hdr_get "$plan" ticket) (sha256:${CUR_HASH:0:12}…)"
