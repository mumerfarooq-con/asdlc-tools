#!/usr/bin/env bash
# Deterministic state + hashing for plan files (/asdlc:implement-prd --plan-only and
# --execute, /asdlc:jira-run). Header block (HTML comment) at the TOP of ./plans/<ID>.plan.md:
#   <!-- asdlc
#   ticket: PROJ-142
#   status: pending          # you change this to: approved
#   plan_hash: sha256:<hex>  # tool-stamped over the plan body — do not edit
#   branch:
#   pr:
#   updated: <iso8601>
#   -->
#   <plan body: the approved part>
#   <!-- asdlc:progress -->
#   ## Progress
#   <run log: agents append task status, notes and verdicts here>
# Plans written by the pre-plugin in-repo version open with "<!-- jira-run:approval";
# those are read the same way and get the current marker the next time they are stamped.
#
# Usage:
#   plan-state.sh stamp <plan> [ticket]      # (re)write block: status=pending, fresh hash, empty log
#   plan-state.sh check <plan>               # RUNNABLE|PENDING|EDITED|STALE|NEEDS_INFO|BLOCKED|EXECUTING|DONE|FAILED|SKIP|MISSING
#   plan-state.sh set   <plan> <field> <val> # field: status|branch|pr
#   plan-state.sh reset-executing <plan>     # crashed run: executing -> approved, only if the body is unchanged
#   plan-state.sh get   <plan> <field>
#   plan-state.sh validate <plan>            # VALID|INVALID: is the approved part a complete plan?
#   plan-state.sh approve  <plan>            # HUMAN ONLY: validate, re-hash, status=approved
#   plan-state.sh replan   <plan>            # move the plan to <ID>.plan.prev.md (not while executing)
#   plan-state.sh progress <plan>            # latest Progress entry per task, ordered by task
# <plan> is a path, or a bare ticket id (no '/', not ending .md) meaning ./plans/<ID>.plan.md.
#
# The contract: above the progress line is everything a human signs off on (M2's Critic notes
# and Open-question answers included); below it is only the machine run log, never a source of
# work. stamp places the line (and refuses a plan that already has one, so plan templates must
# not contain it); approve recomputes the hash over the part above the line.
# plan_hash covers only the approved part, the body up to the progress line, taken as sha256 of
# "asdlc-plan-v2\n" + that part. Agents log a run's progress below the line, so ticking tasks
# never invalidates the approval and a crashed run can be resumed. A plan with no line (stamped
# before 1.2.0) keeps the plain whole-body hash and stays RUNNABLE; once such a plan gains a
# line it is EDITED, because the line is never hashed the legacy way again. A progress line is
# any line matching: optional blanks, <!--, asdlc:progress, -->, optional blanks or CR.
# Re-stamping is a new approval and a new run, so it empties the log.
#
# Approval is a human act: "set status approved" is refused, and "approve" is human-only (see
# below). reset-executing restores approved for a plan whose header says executing and whose
# approved part is unchanged. A real guarantee still needs a run record.
# "set <plan> status <v>" refuses (exit 2) unless the move is allowed:
#   approved               never
#   executing              only while check says RUNNABLE (approved + hash matches)
#   done | failed          only from executing
#   pending|skip|rejected|stale|needs-info|blocked  always (they fail closed)
# EDITED means the approved part no longer matches its hash (or a header field / progress line
# is duplicated). STALE means the ticket changed after approval (status: stale, set by the
# ticket check); NEEDS_INFO and BLOCKED are likewise set from outside.
# Exit codes: check = 0 RUNNABLE, 10 PENDING, 11 EDITED, 12 EXECUTING, 13 DONE, 14 FAILED,
# 15 SKIP, 16 MISSING, 17 STALE, 18 NEEDS_INFO, 19 BLOCKED. Elsewhere: 2 = refused or bad input;
# 3 = stamp wrote nothing (header not closed, or empty body); 11 = reset-executing found the
# body changed; 16 = no header block; 20 = validate found the plan INVALID (approve exits 20 too,
# and writes nothing).
set -euo pipefail
MARKER='<!-- asdlc'
# jira-run:approval is read so plans written by the pre-plugin in-repo version keep working;
# drop that alternation once those plans are retired.
MARKER_RE='^<!-- (asdlc|jira-run:approval)[ \t]*$'
PROGRESS='<!-- asdlc:progress -->'

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

# The approved part of a body on stdin: every line before the progress line. The hash is taken
# over this, so everything a run logs below the line stays outside the approval.
PROGRESS_AWK='^[ \t]*<!--[ \t]*asdlc:progress[ \t]*-->[ \t\r]*$'
# It keeps reading after the line (no early exit) so the writer upstream never gets SIGPIPE.
approved_part() { awk -v re="$PROGRESS_AWK" '$0 ~ re {done=1} !done {print}'; }

progress_count() { body_of "$1" | awk -v re="$PROGRESS_AWK" '$0 ~ re {n++} END {print n+0}'; }

# Hash of a body on stdin; $1 = number of progress lines in it. With a line: the v2 form over
# the approved part. Without: the legacy whole-body hash, byte-identical to pre-1.2.0.
hash_body() {
  if [ "$1" -gt 0 ]; then { printf 'asdlc-plan-v2\n'; approved_part; } | sha
  else approved_part | sha; fi
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
    STATE=EDITED; STATE_CODE=11
    STATE_MSG="  duplicate header field — re-stamp and re-approve"
    return 0
  fi
  # A second progress line could move part of the approved plan out of the hash.
  if [ "$(progress_count "$plan")" -gt 1 ]; then
    STATE=EDITED; STATE_CODE=11
    STATE_MSG="  more than one '$PROGRESS' line — delete the extra line, then re-approve"
    return 0
  fi
  local st
  st="$(hdr_get "$plan" status)"
  STORED_HASH="$(hdr_get "$plan" plan_hash)"; STORED_HASH="${STORED_HASH#sha256:}"
  CUR_HASH="$(body_of "$plan" | hash_body "$(progress_count "$plan")")"
  case "$st" in
    approved) if [ "$CUR_HASH" = "$STORED_HASH" ]; then STATE=RUNNABLE; STATE_CODE=0
              else STATE=EDITED; STATE_CODE=11
                   STATE_MSG="  plan body changed since it was stamped — re-plan, or 'plan-state.sh stamp' then re-approve"
              fi ;;
    pending)       STATE=PENDING;   STATE_CODE=10 ;;
    executing)     STATE=EXECUTING; STATE_CODE=12 ;;
    done)          STATE=DONE;      STATE_CODE=13 ;;
    failed)        STATE=FAILED;    STATE_CODE=14 ;;
    skip|rejected) STATE=SKIP;      STATE_CODE=15 ;;
    stale)         STATE=STALE;     STATE_CODE=17 ;;
    needs-info)    STATE=NEEDS_INFO; STATE_CODE=18 ;;
    blocked)       STATE=BLOCKED;   STATE_CODE=19 ;;
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

# Sections every plan must have (exact "## " text, case-insensitive), and the ones that must
# hold real content. Shared with the plan-template hygiene test: keep each on one line.
REQUIRED_SECTIONS='Goal|Context used|What else uses this|Must still work|Changes|Tests|Risk|Open questions|Critic notes'
NONEMPTY_SECTIONS='Goal|Must still work|Changes|Tests'

# Table rows: "\|" is cell text. In Critic notes a row whose cell count differs from the header is a
# problem (fail closed), and severity "blocker" matches case- and markup-insensitively.
# Checks the approved part on stdin. $1 = 1 if ./plans/<ID>/impact.md exists. One stderr line per
# problem, each starting with the section name; "warn:" lines are not problems. Exit 1 if any.
validate_part() {
  awk -v req="$REQUIRED_SECTIONS" -v ne="$NONEMPTY_SECTIONS" -v has_impact="$1" '
    function trim(s) { gsub(/^[ \t\r]+/, "", s); gsub(/[ \t\r]+$/, "", s); return s }
    function problem(sec, msg) { print sec ": " msg > "/dev/stderr"; bad++ }
    # severity / response text without markup: no * _ `, trimmed, lower-case
    function norm(s) { gsub(/[*_`]/, "", s); return tolower(trim(s)) }
    # a hint line: the whole line is <...> text, optionally bulleted
    function isph(s) { return s ~ /^[ \t]*([-*][ \t]+)?<.*>[ \t\r]*$/ }
    BEGIN {
      PH = "\001"
      nreq = split(req, R, "|")
      for (i = 1; i <= nreq; i++) canon[tolower(R[i])] = 1
    }
    {
      line = $0
      # HTML comments (the template opens with one) are neither headings nor content
      if (incom) { if (index(line, "-->")) incom = 0; next }
      if (line ~ /^[ \t]*<!--/) { if (!index(line, "-->")) incom = 1; next }
      if (line ~ /^##[ \t]+[^#]/) {
        name = tolower(trim(substr(line, 3)))
        cur = (name in canon) ? name : "?"
        if (cur != "?") seen[cur] = 1
        tbl = 0; next
      }
      if (cur == "" || cur == "?") next
      if (trim(line) == "") { tbl = 0; next }
      if (line ~ /^[ \t]*\|/) {
        # an escaped pipe (\|) is cell text: hide it from the split; drop the closing pipe so
        # rows with and without one count the same
        gsub(/\\\|/, PH, line); sub(/\|[ \t\r]*$/, "", line)
        tbl++
        if (tbl == 1) {   # header row: not data; note where the critic columns are
          if (cur == "critic notes") {
            n = split(line, H, "|"); sevc = 0; respc = 0; hn = n; crow = 0
            for (i = 2; i <= n; i++) {
              h = tolower(trim(H[i]))
              if (index(h, "severity")) sevc = i
              if (index(h, "response")) respc = i
            }
          }
          next
        }
        if (line ~ /^[ \t]*\|[ \t\r:|-]+$/ && line ~ /-/) next   # separator row
        n = split(line, C, "|"); allph = 1
        for (i = 2; i <= n; i++) {
          c = trim(C[i])
          if (c != "" && c !~ /^<.*>$/) allph = 0
        }
        if (allph) next   # an unfilled hint row is not data
        data[cur]++; content[cur]++
        if (cur == "critic notes") {
          crow++
          # a split that disagrees with the header is unreadable: fail closed, not open
          if (hn && n != hn) {
            lbl = trim(C[2]); gsub(PH, "|", lbl)
            problem("Critic notes", "row " (lbl != "" ? lbl : crow) ": cell count differs from the header (unescaped |? write it as \\|)")
            next
          }
        }
        if (cur == "what else uses this") {
          for (i = 2; i <= n; i++) if (tolower(trim(C[i])) == "unsure") { unsure++; break }
        }
        if (cur == "critic notes") {
          sc = sevc ? sevc : 3; rc = respc ? respc : 6
          lbl = trim(C[2]); gsub(PH, "|", lbl)
          resp = trim(C[rc]); if (resp ~ /^<.*>$/) resp = ""
          # first word "blocker": blocker, Blocker., **Blocker**, blocker (access)
          if (norm(C[sc]) ~ /^blocker([^a-z]|$)/) {
            if (resp == "") problem("Critic notes", "blocker row " lbl " has no Planner response")
            else if (norm(resp) ~ /^disagree/ && index(norm(resp), "human accepted:") == 0)
              problem("Critic notes", "blocker row " lbl " is disagreed with but not accepted (add \"human accepted: <reason>\")")
          }
        }
        next
      }
      tbl = 0
      if (isph(line)) next
      content[cur]++
      if (cur == "what else uses this" && index(tolower(line), "no other uses found")) noother = 1
      if (cur == "changes" && tolower(line) ~ /^###[ \t]+task[ \t]+[0-9]+/) task = 1
      if (cur == "open questions") {
        q = line; sub(/^[ \t]*[-*][ \t]+\[.\][ \t]*/, "", q); q = trim(q)
        if (line ~ /^[ \t]*[-*][ \t]+\[ \]/) problem("Open questions", "unanswered: " q)
        else if (line ~ /^[ \t]*[-*][ \t]+\[[xX]\]/ && index(line, "Answer:") == 0)
          problem("Open questions", "checked but no \"Answer:\" on the line: " q)
      }
    }
    END {
      for (i = 1; i <= nreq; i++) {
        k = tolower(R[i])
        if (!(k in seen)) { problem(R[i], "missing section (## " R[i] ")"); miss[k] = 1 }
      }
      nn = split(ne, N, "|")
      for (i = 1; i <= nn; i++) {
        k = tolower(N[i])
        if (!(k in miss) && content[k] + 0 == 0) problem(N[i], "section is empty")
      }
      if (("what else uses this" in seen) && data["what else uses this"] + 0 == 0) {
        if (!noother) problem("What else uses this", "no table rows (list each usage, or write \"No other uses found\" after an impact scan)")
        else if (has_impact != 1) problem("What else uses this", "says \"No other uses found\" but ./plans/<ID>/impact.md does not exist")
      }
      if (("changes" in seen) && !task) problem("Changes", "no \"### Task <n>\" heading (the executor works task by task)")
      if (unsure > 0) print "warn: " unsure " row(s) in \"What else uses this\" marked unsure" > "/dev/stderr"
      exit (bad > 0)
    }'
}

# VALID (0) or INVALID (20) on stdout; the problems go to stderr. Checks only the approved part.
do_validate() {
  local id="" has=0 rc=0
  if has_block "$plan"; then id="$(hdr_get "$plan" ticket)"; fi
  [ -n "$id" ] || id="$(basename "$plan" .plan.md)"
  if ! has_eol "$id" && re_ok "$id" '^[A-Za-z0-9][A-Za-z0-9._-]*$' && [ -f "plans/$id/impact.md" ]; then has=1; fi
  body_of "$plan" | approved_part | validate_part "$has" || rc=$?
  if [ "$rc" -eq 0 ]; then echo VALID; return 0; fi
  echo INVALID; return 20
}

cmd="${1:?usage: plan-state.sh <stamp|check|set|reset-executing|get|validate|approve|replan|progress> <plan|ID> ...}"
plan="${2:?plan file or ticket id required}"
# A bare ID (no '/', not ending .md) means ./plans/<ID>.plan.md; it must look like a ticket id.
case "$plan" in
  */*|*.md) ;;
  *) if has_eol "$plan" || ! re_ok "$plan" '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
       die 2 "refusing: a bare plan id must match [A-Za-z0-9][A-Za-z0-9._-]* (or pass a path)"
     fi
     plan="./plans/$plan.plan.md" ;;
esac

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
    pc="$(progress_count "$plan")"
    if [ "$pc" -gt 1 ]; then
      die 3 "more than one '$PROGRESS' line in $plan — keep exactly one, after the plan; nothing written"
    fi
    if [ "$pc" -eq 1 ] && ! has_block "$plan"; then
      die 3 "stamp adds the progress line itself; remove it from the plan; nothing written"
    fi
    if [ -z "$(approved_part < "$btmp" | LC_ALL=C tr -d ' \t\r\n\f\v')" ]; then
      die 3 "empty plan body in $plan — nothing to stamp; nothing written"
    fi
    if [ "$pc" -eq 0 ]; then
      # Give the run a fixed place to log progress, outside the approved part.
      { if [ -n "$(tail -n1 "$btmp")" ]; then echo; fi
        printf '%s\n' "$PROGRESS" '## Progress'; } >> "$btmp"
    else
      # Re-stamp: the line must be followed by "## Progress" and then the log. The log is dropped
      # because a re-stamp is a new approval and a new run.
      dropped="$(awk -v re="$PROGRESS_AWK" '
        f==0 && $0 ~ re {f=1; next}
        f==1 && $0 ~ /^[ \t\r]*$/ {next}
        f==1 {if ($0 ~ /^## Progress[ \t\r]*$/) {f=2; next} else {f=-1; exit}}
        f==2 && $0 !~ /^[ \t\r]*$/ {n++}
        END {if (f==-1 || f==1) print "bad"; else print n+0}' "$btmp")"
      if [ "$dropped" = bad ]; then
        die 3 "the '$PROGRESS' line in $plan must be followed by '## Progress' — fix or remove it; nothing written"
      fi
      { approved_part < "$btmp"; printf '%s\n' "$PROGRESS" '## Progress'; } > "$btmp.new"
      mv "$btmp.new" "$btmp"
      if [ "$dropped" -gt 0 ]; then echo "dropped $dropped progress log line(s)" >&2; fi
    fi
    h="$(hash_body 1 < "$btmp")"
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
          executing|done|failed|pending|skip|rejected|stale|needs-info|blocked) ;;
          *) die 2 "refusing: unknown status '$val' (allowed: pending|executing|done|failed|skip|rejected|stale|needs-info|blocked)" ;;
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
          # failed never enables execution, so it is also allowed from executing + EDITED.
          [ "$STATE" = EXECUTING ] || { [ "$val" = failed ] && [ "$STATE" = EDITED ] && [ "$(hdr_get "$plan" status)" = executing ]; } || die 2 "refusing: '$val' only follows executing (this plan is $STATE)" ;;
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
      die 11 "the approved part of the plan changed during the crashed run — re-stamp ('plan-state.sh stamp') and have a human re-approve"
    fi
    write_field status approved
    echo "reset $plan: executing -> approved"
    ;;
  get) hdr_get "$plan" "${3:?field required}" ;;
  validate)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    do_validate || exit $?
    ;;
  approve)
    # HUMAN ONLY. This is the one place a plan becomes approved. It is never in any command's
    # allowed-tools; /asdlc:plan approve is its only caller, so the harness asks the human to
    # confirm each call. Nothing an agent runs may call it.
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    vrc=0; do_validate || vrc=$?
    [ "$vrc" -eq 0 ] || exit 20
    compute_state
    can=0
    case "$STATE" in
      PENDING|STALE|NEEDS_INFO|BLOCKED) can=1 ;;
      # a human edit of an approved plan: re-approvable, but not a tampered header or progress line
      EDITED) if [ "$(hdr_get "$plan" status)" = approved ] && [ "$(hdr_count "$plan" status)" -eq 1 ] \
                 && [ "$(hdr_count "$plan" plan_hash)" -eq 1 ] && [ "$(progress_count "$plan")" -le 1 ]; then can=1; fi ;;
      MISSING) die 16 "no header block in $plan — run 'plan-state.sh stamp' first" ;;
    esac
    [ "$can" -eq 1 ] || die 2 "refusing: $plan is $STATE; approve needs a pending, stale, needs-info or blocked plan, or an approved plan the human edited"
    # Hash first, status second: a crash between them leaves the plan EDITED, never RUNNABLE by accident.
    write_field plan_hash "sha256:$CUR_HASH"
    write_field status approved
    echo "approved $(hdr_get "$plan" ticket) (sha256:${CUR_HASH:0:12}…)"
    ;;
  replan)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    case "$plan" in *.plan.md) ;; *) die 2 "refusing: $plan is not a *.plan.md file" ;; esac
    if has_block "$plan" && [ "$(hdr_get "$plan" status)" = executing ]; then
      die 2 "refusing: $plan is executing — wait for the run, or 'run-state.sh reset-executing' after a crash"
    fi
    prev="${plan%.plan.md}.plan.prev.md"
    mv -f "$plan" "$prev"
    echo "moved $plan to $prev; the next planning run will re-plan it, reusing the answers in $prev"
    ;;
  progress)
    [ -f "$plan" ] || die 2 "no such plan: $plan"
    # Only the entry grammar counts; everything else below the line is ignored.
    body_of "$plan" | awk -v re="$PROGRESS_AWK" '
      f == 0 && $0 ~ re {f = 1; next}
      f == 1 && $0 ~ /^- Task [0-9]+: (EXECUTOR (DONE|BLOCKED)|REVIEW (APPROVED|CHANGES_REQUESTED)|TEST (PASS|FAIL)) — / {
        n = $3; sub(/:$/, "", n); n = n + 0
        v = $4 " " $5
        print n, v
      }' | awk '{ n = $1; sub(/^[0-9]+ /, ""); last[n] = $0; if (!(n in seen)) { seen[n] = 1; order[++c] = n } }
                END { for (i = 1; i <= c; i++) print order[i] "\t" last[order[i]] }' \
      | sort -n | awk -F'\t' '{ print "Task " $1 ": " $2 }'
    ;;
  *)   echo "unknown command: $cmd" >&2; exit 2 ;;
esac
