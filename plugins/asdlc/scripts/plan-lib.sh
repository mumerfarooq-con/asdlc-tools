#!/usr/bin/env bash
# Shared by plan-state.sh and plan-approve.sh (sourced, never run): header and hash helpers,
# the state computation, and the plan validator. Both scripts must agree on the hash and the
# state, so they use one copy. It sets no shell options; the sourcing script owns those.
# The sourcing script sets the global "plan" (the plan file path) before calling anything here.
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
  # The fingerprint fields are read by the stale check, so a second line is tampering too.
  if [ "$(hdr_count "$plan" status)" -gt 1 ] || [ "$(hdr_count "$plan" plan_hash)" -gt 1 ] \
     || [ "$(hdr_count "$plan" ticket_fingerprint)" -gt 1 ] || [ "$(hdr_count "$plan" fingerprint_at)" -gt 1 ] \
     || [ "$(hdr_count "$plan" fingerprint_source)" -gt 1 ]; then
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

# The fingerprint file jira-context.sh build writes: exactly three lines, each once, in any
# order. Prints them in header order and returns 0, or prints nothing and returns 1.
read_fingerprint() {  # <file>
  local line k v fp="" at="" src="" n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    k="${line%%: *}"; v="${line#*: }"
    [ "$k" != "$line" ] || return 1
    has_eol "$v" && return 1
    case "$k" in
      ticket_fingerprint) [ -z "$fp" ] || return 1; re_ok "$v" '^sha256:[0-9a-f]{64}$' || return 1; fp="$v" ;;
      fingerprint_at) [ -z "$at" ] || return 1; re_ok "$v" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || return 1; at="$v" ;;
      fingerprint_source) [ -z "$src" ] || return 1; case "$v" in rest|mcp) src="$v" ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
  done < "$1"
  [ "$n" -eq 3 ] && [ -n "$fp" ] && [ -n "$at" ] && [ -n "$src" ] || return 1
  printf 'ticket_fingerprint: %s\nfingerprint_at: %s\nfingerprint_source: %s\n' "$fp" "$at" "$src"
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
