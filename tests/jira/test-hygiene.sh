#!/usr/bin/env bash
# The plugin is public and project-agnostic: no project values outside
# templates, no secrets, every script runnable and documented.
. "$(dirname "$0")/helpers.sh"
P="$ROOT/plugins/asdlc"

t "no project-specific values in plugin files outside templates"
# Branch names belong in the config. Add your own project's names and keys
# locally (never commit them here): ASDLC_HYGIENE_WORDS="NAME,KEY" tests/jira/run.sh
words="develop"
[ -n "${ASDLC_HYGIENE_WORDS:-}" ] && words="$words|$(printf '%s' "$ASDLC_HYGIENE_WORDS" | tr ',' '|')"
hits="$(grep -rnIiwE "$words" "$P" --exclude-dir=templates || true)"
assert_eq "$hits" "" "project-specific words"
hits="$(grep -rnIE '[a-z0-9-]+\.atlassian\.net' "$P" --exclude-dir=templates | grep -vE 'your-team|example' || true)"
assert_eq "$hits" "" "real Jira site URLs"

t "no secret-looking values in the Jira leg"
hits="$(grep -rnIE '(TOKEN|SECRET|PASSWORD)=[A-Za-z0-9_-]{8,}' "$P/jira" "$P/scripts" "$P/commands" || true)"
assert_eq "$hits" "" "hardcoded secrets"

t "scripts are executable, use bash, and set strict mode"
for f in "$P"/jira/scripts/*.sh "$P"/scripts/*.sh "$P"/hooks/*.sh; do
  case "$f" in */lib.sh|*/plan-lib.sh|*/context-lib.sh|*/mcp-lib.sh|*/review-lib.sh|*/fp-sources.sh) continue ;; esac   # sourced libraries, never run
  [ -x "$f" ] && ok || nok "$(basename "$f") not executable"
  [ "$(head -n1 "$f")" = "#!/usr/bin/env bash" ] && ok || nok "$(basename "$f") shebang"
  grep -q '^set -euo pipefail' "$f" && ok || nok "$(basename "$f") lacks set -euo pipefail"
  bash -n "$f" && ok || nok "$(basename "$f") syntax"
done

t "the list of fingerprint sources lives in fp-sources.sh only (SF-1)"
hits="$(grep -rnE 'rest\|mcp|mcp\|rest' "$P" | grep -v '/scripts/fp-sources.sh:' || true)"
assert_eq "$hits" "" "a second copy of the source list"
assert_contains "$(cat "$P/scripts/fp-sources.sh")" 'FP_SOURCES=' "the one list"
assert_contains "$(cat "$P/scripts/plan-lib.sh")" "fp_source_ok" "plan-lib reads it"
assert_contains "$(cat "$P/jira/scripts/jira-context.sh")" "fp_source_ok" "jira-context reads it"
for f in context-lib.sh; do assert_not_contains "$(head -n1 "$P/jira/scripts/$f")" "#!" "$f is sourced, not run"; done

t "the plugin's hooks: valid hooks.json, every command exists, the capture is a no-op without a request"
HJ="$P/hooks/hooks.json"
jq -e . "$HJ" >/dev/null 2>&1 && ok || nok "hooks.json is not valid JSON"
for ref in $(jq -r '.. | .command? // empty' "$HJ" | awk '{print $1}' | tr -d '"' | sort -u); do
  [ -x "$P/${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}" ] && ok || nok "hooks.json names a missing or non-executable $ref"
done
assert_not_contains "$(jq -r '.. | .command? // empty' "$HJ")" "/Users/" "no personal path in hooks.json"
# a public plugin must not be handed other tools' outputs: no catch-all matcher, every matcher names Jira tools or a bitbucket server
while IFS= read -r m; do
  case "$m" in
    ""|".*"|"^.*"|"^mcp__"|"^mcp__.*"|"^mcp__.+"|"^mcp__.*__.*"|"^mcp__.+__.+"|"^mcp__.*__.+"|"^mcp__.+__.*") nok "hooks.json has a catch-all matcher: $m" ;;
    *Jira*|*[Bb]itbucket*|*"[Bb][Ii][Tt][Bb][Uu][Cc][Kk][Ee][Tt]"*) ok ;;
    *) nok "hooks.json matcher names neither Jira tools nor a bitbucket server: $m" ;;
  esac
done < <(jq -r '.hooks[][].matcher' "$HJ")
BBM="$(jq -r '.hooks.PostToolUse[] | select(.hooks[0].command | endswith(" bb")) | .matcher' "$HJ")"
for s in mcp__bitbucket__createPR mcp__claude_ai_Bitbucket__x mcp__my-bitbucket-server__t mcp__BitBucket_x__t; do
  printf '%s' "$s" | grep -qE "$BBM" && ok || nok "bb matcher misses server in $s"
done
for s in mcp__claude_ai_Gmail__search mcp__claude_ai_Atlassian__getJiraIssue mcp__gmail__bitbucketThing mcp__x__Bitbucket__y; do
  printf '%s' "$s" | grep -qE "$BBM" && nok "bb matcher takes $s" || ok
done
assert_contains "$(sed -n '/^compgen/p' "$P/hooks/mcp-capture.sh")" "plans/*/.mcp/request.json" "the one-glob fast path"
assert_eq "$(grep -cE 'curl|wget|asdlc_http' "$P/hooks/mcp-capture.sh")" "0" "the hook makes no network calls"
assert_eq "$(grep -c 'lib.sh' "$P/hooks/mcp-capture.sh")" "0" "the hook parses no config"

t "commands only reference scripts that exist (jira/scripts and the shared scripts/)"
for ref in $(grep -ohE '\$\{CLAUDE_PLUGIN_ROOT\}/(jira/)?scripts/[a-z-]+\.sh' "$P"/commands/*.md | sort -u); do
  [ -f "$P/${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}" ] && ok || nok "missing $ref"
done

t "jira-run's pre-approved tools exclude plan approval, Bitbucket writes, commit and push"
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/jira-run.md")"
assert_not_contains "$fm" "plan-state.sh:*" "blanket plan-state"
assert_not_contains "$fm" "plan-state.sh approve" "plan-state approve"
assert_not_contains "$fm" "plan-approve" "plan-approve"
assert_not_contains "$fm" "bb-open-pr.sh" "bb-open-pr"
assert_not_contains "$fm" "bb-pr-comment.sh" "bb-pr-comment"
assert_not_contains "$fm" "Bash(git:*)" "blanket git"
assert_not_contains "$fm" "git commit" "git commit"
assert_not_contains "$fm" "git push" "git push"
assert_contains "$fm" "Bash(git add:*)" "explicit git add"
assert_not_contains "$fm" "git log" "git log"
assert_not_contains "$fm" "git diff" "git diff"
assert_not_contains "$fm" "git pull" "git pull"
# A new git grant must be added here on purpose.
for g in $(printf '%s' "$fm" | grep -oE 'Bash\(git [a-z-]+' | sed 's/Bash(git //'); do
  case "$g" in status|add) ok ;; *) nok "unexpected git grant: $g" ;; esac
done

# Plan approval (plan-approve.sh; plan-state.sh no longer has approve) and clearing another run's lock are human-only.
# Permission rules match by prefix, so check every command, and check that no pre-approved
# subcommand is a prefix of a human-only one ("unlock:*" must not cover "unlock-force" etc.).
t "no command pre-approves plan approval or force-unlock, even by prefix"
for cmdfile in "$P"/commands/*.md; do
  name="$(basename "$cmdfile" .md)"
  fm="$(sed -n '/^---$/,/^---$/p' "$cmdfile")"
  assert_not_contains "$fm" "plan-state.sh:*" "$name: blanket plan-state"
  assert_not_contains "$fm" "plan-state.sh approve" "$name: plan-state approve"
  assert_not_contains "$fm" "plan-approve" "$name: plan-approve.sh"
  assert_not_contains "$fm" "run-state.sh:*" "$name: blanket run-state"
  assert_not_contains "$fm" "run-state.sh force-unlock" "$name: force-unlock"
  assert_not_contains "$fm" "git commit" "$name: git commit"
  assert_not_contains "$fm" "git push" "$name: git push"
  # a pre-approved "plan-approve.sh..." rule of any kind, or a bare scripts/ directory rule, would cover it
  for rule in $(printf '%s' "$fm" | grep -oE 'Bash\([^)]*\)' | sed -E 's/^Bash\(//; s/\)$//; s/:?\*$//'); do
    case '${CLAUDE_PLUGIN_ROOT}/scripts/plan-approve.sh' in "$rule"*) nok "$name: rule '$rule' covers plan-approve.sh" ;; *) ok ;; esac
  done
  for pair in "plan-state.sh:approve" "run-state.sh:force-unlock"; do
    script="${pair%%:*}"; human="${pair#*:}"
    for sub in $(printf '%s' "$fm" | grep -oE "$script [a-z-]+:\\*" | sed -E "s/^$script ([a-z-]+):\\*$/\\1/"); do
      case "$human" in "$sub"*) nok "$name: pre-approved '$script $sub' is a prefix of human-only '$human'" ;; *) ok ;; esac
    done
  done
done

t "plan.md calls plan-approve.sh for approve, in an unapproved line, and nothing else approves"
pl="$(cat "$P/commands/plan.md")"
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/plan.md")"
assert_contains "$pl" '${CLAUDE_PLUGIN_ROOT}/scripts/plan-approve.sh <ID>' "approve step uses plan-approve.sh"
assert_not_contains "$pl" "plan-state.sh approve" "no plan-state approve left in plan.md"
assert_not_contains "$fm" "plan-approve" "plan.md does not pre-approve it"
assert_contains "$fm" "plan-state.sh validate:*" "plan.md pre-approves only validate and replan"
assert_contains "$fm" "plan-state.sh replan:*" "replan"
t "the only script that can approve is plan-approve.sh: no other script re-writes plan_hash"
for f in "$P"/jira/scripts/*.sh "$P"/scripts/*.sh "$P"/hooks/*.sh; do
  case "$f" in */plan-approve.sh) continue ;; esac
  if grep -qE "write_field +plan_hash" "$f"; then nok "$(basename "$f") can approve"; else ok; fi
done
assert_eq "$(grep -c 'write_field plan_hash' "$P/scripts/plan-approve.sh")" "1" "plan-approve.sh is where the hash is re-written"

# The named exception (item 7): reset-executing and next-slice are the only two scripted paths back to
# approved, both compare-and-set on the human-approved hash through restore_approved in plan-lib.sh.
# plan-approve.sh stays the only way a NEW hash is approved. Anything else that writes the status
# "approved" fails this check. $1 = a copy or the real plugin dir; prints one line per violation.
approver_violations() {
  local d="$1" f b n
  for f in "$d"/jira/scripts/*.sh "$d"/scripts/*.sh "$d"/hooks/*.sh; do
    [ -f "$f" ] || continue; b="$(basename "$f")"
    # code lines only: a comment may name any of these
    n="$(grep -vE '^[[:space:]]*#' "$f" | grep -cE 'write_field[[:space:]]+"?status"?[[:space:]]+"?approved' || true)"
    if [ "$n" -gt 0 ] && [ "$b" != plan-approve.sh ]; then echo "$b writes status approved with write_field"; fi
    n="$(grep -vE '^[[:space:]]*#' "$f" | grep -cE 'status=approved|status: approved|"status"[[:space:]]*,[[:space:]]*"approved"' || true)"
    if [ "$n" -gt 0 ] && [ "$b" != plan-lib.sh ]; then echo "$b writes status approved outside restore_approved"; fi
    # every call of restore_approved (not its definition): where it sits
    awk -v b="$b" '
      /^[[:space:]]*#/ {next}
      /^  [a-z-]+\)/ {arm = $1; sub(/\)$/, "", arm)}
      /restore_approved\(\)/ {next}
      /restore_approved[[:space:]]/ {
        ok = (b == "plan-state.sh" && arm == "reset-executing") || (b == "run-state.sh" && arm == "next-slice")
        if (!ok) print b ": restore_approved called in " (arm == "" ? "no case arm" : arm) ", not by reset-executing or next-slice"
        calls++
      }
      END { if ((b == "plan-state.sh" || b == "run-state.sh") && calls != 1) print b ": expected exactly one restore_approved call, found " calls + 0 }
    ' "$f"
  done
}
t "only plan-approve.sh writes a new approval: status approved is written by it, and by restore_approved for reset-executing and next-slice alone"
assert_eq "$(approver_violations "$P")" "" "violations in the plugin"
assert_eq "$(grep -c 'write_field status approved' "$P/scripts/plan-approve.sh")" "1" "plan-approve.sh writes it"
assert_eq "$(grep -vE '^[[:space:]]*#' "$P/scripts/plan-lib.sh" | grep -c 'status=approved')" "1" "restore_approved is the one other writer"
assert_contains "$(cat "$P/scripts/plan-lib.sh")" "compare-and-set on the hash the" "restore_approved's comment names the compare-and-set"
assert_contains "$(cat "$P/scripts/plan-lib.sh")" "run-state.sh next-slice" "restore_approved's comment names next-slice"
assert_contains "$(cat "$P/scripts/plan-state.sh")" "only two scripted paths back to approved" "plan-state.sh names both paths"
assert_contains "$(cat "$P/jira/scripts/run-state.sh")" "only two scripted paths back to approved" "run-state.sh names both paths"
assert_not_contains "$(sed -n '/^---$/,/^---$/p' "$P/commands/jira-run.md" | grep '^allowed-tools:')" "plan-approve" "jira-run still cannot approve"
# a third writer must fail: each of these is a copy of the plugin with one extra writer
for variant in 'scripts/third.sh|write_field status approved' 'jira/scripts/third.sh|write_field "status" approved' \
               'jira/scripts/third.sh|restore_approved EXECUTING ""' 'scripts/third.sh|sed -i s/status:.*/status=approved/ "$plan"'; do
  tmp="$(mktemp -d)"; cp -R "$P/scripts" "$P/jira" "$tmp/"; mkdir -p "$tmp/hooks"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "${variant#*|}" > "$tmp/${variant%%|*}"
  if [ -n "$(approver_violations "$tmp")" ]; then ok; else nok "a third writer passed: ${variant#*|}"; fi
  rm -rf "$tmp"
done
# a second call inside the allowed scripts, in another case arm, fails too
tmp="$(mktemp -d)"; cp -R "$P/scripts" "$P/jira" "$tmp/"; mkdir -p "$tmp/hooks"
sed 's/^  list)$/  list)\n    restore_approved EXECUTING ""/' "$P/jira/scripts/run-state.sh" > "$tmp/jira/scripts/run-state.sh"
if [ -n "$(approver_violations "$tmp")" ]; then ok; else nok "a restore_approved call in run-state.sh list passed"; fi
rm -rf "$tmp"
# and a commented-out mention is not a writer
tmp="$(mktemp -d)"; cp -R "$P/scripts" "$P/jira" "$tmp/"; mkdir -p "$tmp/hooks"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# restore_approved EXECUTING and write_field status approved are not called here\n' > "$tmp/scripts/third.sh"
assert_eq "$(approver_violations "$tmp")" "" "a comment is not a writer"
rm -rf "$tmp"

t "/asdlc:plan is human-invoked only; planning and execute commands pre-approve the new scripts"
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/plan.md")"
assert_contains "$fm" "disable-model-invocation: true" "plan.md disable-model-invocation"
for cmdname in implement-prd jira-run; do
  fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/$cmdname.md")"
  assert_contains "$fm" "scripts/impact-scan.sh:*" "$cmdname pre-approves impact-scan"
  assert_contains "$fm" "plan-state.sh validate:*" "$cmdname pre-approves validate"
  assert_contains "$fm" "plan-state.sh progress:*" "$cmdname pre-approves progress"
done

t "implement-prd and jira-run never hand an agent a plugin-dir template path; the planner gets the in-repo copy"
for cmdname in implement-prd jira-run; do
  assert_not_contains "$(cat "$P/commands/$cmdname.md")" 'CLAUDE_PLUGIN_ROOT}/templates/' "$cmdname has no plugin-dir template path"
done
assert_not_contains "$(cat "$P/docs/plan-only-flow.md")" 'CLAUDE_PLUGIN_ROOT}/templates/' "plan-only-flow.md has no plugin-dir template path"
assert_contains "$(cat "$P/docs/plan-only-flow.md")" "plans/<ID>/plan-template.md" "the plan-only flow names the in-repo template copy"

t "the plan template has every heading validate requires, no header and no progress line"
tpl="$P/templates/plan.md"
req="$(sed -n "s/^REQUIRED_SECTIONS='\(.*\)'\$/\1/p" "$P/scripts/plan-lib.sh")"
assert_contains "$req" "Goal" "REQUIRED_SECTIONS readable from plan-lib.sh"
for h in $(printf '%s' "$req" | tr ' ' '_' | tr '|' ' '); do
  h="$(printf '%s' "$h" | tr '_' ' ')"
  if grep -qixF "## $h" "$tpl"; then ok; else nok "template lacks a '## $h' heading"; fi
done
assert_not_contains "$(cat "$tpl")" "asdlc:progress -->" "template has no progress line"
assert_not_contains "$(head -n1 "$tpl")" "<!-- asdlc" "template has no header block"
t "validate on the unfilled template: INVALID, naming the sections still empty"
sandbox; mkdir plans; cp "$tpl" plans/PROJ-1.plan.md
run "$SHARED/plan-state.sh" validate PROJ-1
assert_eq "$CODE" "20" "template exit"
assert_eq "$OUT" "INVALID" "template output"
for sec in Goal "Must still work" Changes Tests; do assert_contains "$ERR" "$sec:" "template problem names $sec"; done
cd "$ROOT"

t "plan-critic is read-only on Opus; the planner's plan-only section names all three steps"
cfm="$(sed -n '/^---$/,/^---$/p' "$P/agents/plan-critic.md")"
ctools="$(printf '%s\n' "$cfm" | grep '^tools:' || true)"
assert_contains "$ctools" "Read" "plan-critic has a tools line"
for bad in Write Edit Bash NotebookEdit; do assert_not_contains "$ctools" "$bad" "plan-critic tools include $bad"; done
assert_contains "$cfm" "model: opus" "plan-critic model"
pl="$(cat "$P/agents/prd-planner.md")"
assert_contains "$pl" "Plan-only mode" "planner plan-only section"
for step in '`terms`' '`plan`' '`revise`'; do assert_contains "$pl" "Step $step" "planner step $step"; done

t "the progress contract is byte-identical in the three agents, and the docs quote its grammar"
contract() { sed -n '/<!-- progress-contract:start -->/,/<!-- progress-contract:end -->/p' "$1"; }
ref="$(contract "$P/agents/prd-executor.md")"
assert_contains "$ref" "TEST PASS" "executor contract block present"
for a in prd-reviewer prd-tester; do
  assert_eq "$(contract "$P/agents/$a.md")" "$ref" "$a progress contract differs from prd-executor"
done
assert_contains "$(cat "$P/commands/implement-prd.md")" "TEST PASS" "implement-prd quotes TEST PASS"
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/jira-run.md")"
assert_not_contains "$fm" "run-state.sh list" "jira-run pre-approves run-state list"
assert_not_contains "$fm" "run-state.sh status" "jira-run pre-approves run-state status"

t "jira-run runs the stale check before start-branch, pre-approves jira-context.sh, and re-plans STALE plans"
jr="$(cat "$P/commands/jira-run.md")"
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/jira-run.md")"
assert_contains "$fm" "jira/scripts/jira-context.sh:*" "jira-run pre-approves jira-context.sh"
assert_not_contains "$fm" "ticket-to-prd" "jira-run no longer pre-approves ticket-to-prd.sh"
assert_not_contains "$jr" "ticket-to-prd" "jira-run body no longer calls ticket-to-prd.sh"
chk="$(grep -n 'jira-context.sh check' "$P/commands/jira-run.md" | head -n1 | cut -d: -f1)"
sb="$(grep -n 'run-state.sh start-branch <plan>' "$P/commands/jira-run.md" | head -n1 | cut -d: -f1)"
[ -n "$chk" ] && [ -n "$sb" ] && [ "$chk" -lt "$sb" ] && ok || nok "jira-context.sh check (line '$chk') must come before start-branch (line '$sb')"
phb="$(sed -n '/^## Phase B/,/^## Standing/p' "$P/commands/jira-run.md")"
assert_contains "$phb" "STALE" "Phase B names STALE plans"
assert_contains "$phb" "jira-context.sh fetch" "Phase B fetches the context bundle"
assert_contains "$phb" "context.md" "Phase B plans from context.md"
assert_contains "$jr" "RUNNABLE, VALID and FRESH" "Phase A needs FRESH"
assert_contains "$jr" "or in the next planning run under \`--execute-only\`" "Phase A STALE line says when --execute-only re-plans"
assert_contains "$(cat "$P/commands/implement-prd.md")" "ticket_fingerprint" "implement-prd warns on a fingerprinted plan (D10)"
assert_contains "$(cat "$P/docs/plan-only-flow.md")" "changes.md" "the plan-only flow passes changes.md on a re-plan"

t "the plan template, planner and critic know the ticket bundle and what changed"
tp="$(cat "$P/templates/plan.md")"
for b in "Ticket sections:" "Comments followed:" "Parent and linked tickets:" "Images:" "Access rules and traps:" "Changed since the previous plan:"; do
  assert_contains "$tp" "$b" "template Context used has '$b'"
done
assert_contains "$(cat "$P/agents/prd-planner.md")" "context.md" "planner mentions context.md"
assert_contains "$(cat "$P/agents/prd-planner.md")" "changes.md" "planner mentions changes.md"
assert_contains "$(cat "$P/agents/plan-critic.md")" "changes.md" "critic checks changes.md"

t "commands pre-approve exactly the expected Atlassian MCP tools: the reads and transitionJiraIssue, never a write, a worklog or a whole server (D-M8)"
EXPECT_MCP="mcp__claude_ai_Atlassian__getJiraIssue mcp__claude_ai_Atlassian__getTransitionsForJiraIssue mcp__claude_ai_Atlassian__searchJiraIssuesUsingJql mcp__claude_ai_Atlassian__transitionJiraIssue"
for cf in "$P"/commands/*.md; do
  cn="$(basename "$cf" .md)"
  fm="$(sed -n '/^---$/,/^---$/p' "$cf" | grep '^allowed-tools:' || true)"
  got="$(printf '%s' "$fm" | tr ',' '\n' | sed 's/^ *//; s/^allowed-tools: *//; s/ *$//' | grep -E '^mcp__' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
  if [ "$cn" = jira-run ]; then assert_eq "$got" "$EXPECT_MCP" "jira-run's pre-approved MCP tools"
  else assert_eq "$got" "" "$cn pre-approves no MCP tool"; fi
  for bad in addCommentToJiraIssue editJiraIssue createJiraIssue Worklog worklog createIssueLink; do assert_not_contains "$fm" "$bad" "$cn pre-approves $bad"; done
  # every mcp__ rule names a tool (mcp__<server>__<tool>): no bare server rule, no wildcard
  bare="$(printf '%s' "$fm" | tr ',' '\n' | sed 's/^ *//; s/^allowed-tools: *//' | grep -E '^mcp__' | grep -vE '^mcp__[A-Za-z0-9_-]+__[A-Za-z]+$' || true)"
  assert_eq "$bare" "" "$cn: an mcp rule that is not one exact tool (whole server or wildcard)"
done

t "jira-run.md carries the MCP rule, the transport step and both MCP sequences"
JR="$(cat "$P/commands/jira-run.md")"
assert_contains "$JR" "call an Atlassian MCP tool ONLY with the args a script" "the args-a-script-printed rule"
assert_contains "$JR" "never read its raw" "the never-read-raw rule"
assert_contains "$JR" "jira-context.sh transport" "step 0 transport resolution"
assert_contains "$JR" "connect the Atlassian MCP (/mcp)" "the STOP message"
assert_contains "$JR" "jira-context.sh mcp-request <KEY> --for check" "the check sequence"
assert_contains "$JR" "jira-context.sh mcp-request <KEY> --for fetch" "the fetch sequence"
assert_contains "$JR" "fetch <KEY> --source mcp" "fetch from the capture"
assert_contains "$JR" "Exit 3" "exit 3 falls back to a REST fetch"
assert_contains "$JR" "jira-mine.sh --mcp-args" "the search sequence"
assert_contains "$JR" "jira-mine.sh --from-mcp" "the search read"

t "jira-setup.md has the read-only MCP step; the server names stay out of the config (task 6)"
JS="$(cat "$P/commands/jira-setup.md")"
assert_contains "$JS" "atlassianUserInfo" "the sign-in check"
assert_contains "$JS" 'Report only "signed in"' "no names or emails echoed"
assert_contains "$JS" "project = <JIRA_PROJECT_KEY>" "the count query"
assert_contains "$JS" '"unverified"' "a 0-count status is unverified"
assert_contains "$JS" "never create, edit, comment, transition or log work" "read-only"
assert_contains "$(cat "$P/commands/review-pr.md")" "ASDLC_BB_MCP_SERVER" "review-pr names the same server variable"
conf_keys="$(. "$P/jira/scripts/lib.sh"; echo $ASDLC_CONF_KEYS)"
for v in ASDLC_JIRA_MCP_SERVER ASDLC_BB_MCP_SERVER ASDLC_BB_MCP_PROFILE; do
  case " $conf_keys " in *" $v "*) nok "$v must stay env-only, not a config key" ;; *) ok ;; esac
done
for v in JIRA_TRANSPORT BB_TRANSPORT; do
  case " $conf_keys " in *" $v "*) ok ;; *) nok "$v is a config key" ;; esac
done
assert_eq "$(grep -hc '^ASDLC_JIRA_MCP_SERVER=\|^ASDLC_BB_MCP_SERVER=' "$P/jira/templates/jira.conf")" "0" "no server name in the template"

t "docs and release: every command is in the READMEs, the changelog's top version is the plugin's"
for cmdfile in "$P"/commands/*.md; do
  c="$(basename "$cmdfile" .md)"
  assert_contains "$(cat "$ROOT/README.md")" "/asdlc:$c" "README lists /asdlc:$c"
  assert_contains "$(cat "$P/README.md")" "/asdlc:$c" "plugin README lists /asdlc:$c"
done
pv="$(jq -r .version "$P/.claude-plugin/plugin.json")"
top="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$ROOT/CHANGELOG.md" | head -n1)"
assert_eq "$top" "$pv" "CHANGELOG top version equals plugin.json"
assert_contains "$(cat "$P/jira/README.md")" "REVIEW_QUEUE_MAX" "the Jira guide documents the cap"
assert_contains "$(cat "$P/commands/jira-setup.md")" "REVIEW_QUEUE_MAX" "jira-setup explains the cap"

t "no command or agent pre-approves a bare git subcommand beyond the known ones"
# A bare `Bash(git <sub>:*)` lets a model pass any option. Allowed: git status, git add (jira-run), git rev-parse (jira-setup).
for f in "$P"/commands/*.md "$P"/agents/*.md; do
  [ -f "$f" ] || continue
  bare="$(sed -n '/^allowed-tools:/p;/^tools:/p' "$f" | grep -o 'Bash(git [a-z-]*:\*)' | grep -v -e 'Bash(git status:\*)' || true)"
  case "$(basename "$f")" in
    jira-run.md)   bare="$(printf '%s\n' "$bare" | grep -v -e 'Bash(git add:\*)' || true)" ;;
    jira-setup.md) bare="$(printf '%s\n' "$bare" | grep -v -e 'Bash(git rev-parse:\*)' || true)" ;;
  esac
  assert_eq "$bare" "" "$(basename "$f") has no bare git pre-approval"
done

t "the capture protocol is written once: one TTL, one request writer, one reader, and the receipts name real script commands (SF-3, N-10)"
HOOK="$P/hooks/mcp-capture.sh"; JS="$P/jira/scripts"
ttl="$(grep -rnw '600' "$P/jira" "$P/hooks" "$P/scripts" --include='*.sh' | grep -v '/mcp-lib.sh:' || true)"
assert_eq "$ttl" "" "a second copy of the request TTL outside mcp-lib.sh"
assert_eq "$(grep -c '^MCP_TTL=' "$JS/mcp-lib.sh")" "1" "the one TTL constant"
assert_contains "$(cat "$JS/mcp-lib.sh")" '--argjson ttl "$MCP_TTL"' "the opener uses it"
w="$(grep -ln 'expires_epoch:' "$P"/jira/scripts/*.sh "$P"/scripts/*.sh "$P"/hooks/*.sh | grep -v '/mcp-lib.sh$' || true)"
assert_eq "$w" "" "a request written outside mcp_request_open"
assert_contains "$(sed -n '/^mcp_request_open()/,/^}/p' "$JS/mcp-lib.sh")" 'kind: $kind' "every request carries a kind"
for f in lib.sh jira-context.sh jira-mine.sh jira-transition.sh jira-notify.sh bb-open-pr.sh bb-pr-comment.sh; do
  assert_eq "$(grep -cE 'nonce="\$\(od|\.nonce[^ ]* *== *\$n' "$JS/$f")" "0" "$f keeps its own nonce or capture loop"
done
# Every script command line the hook puts in a receipt names a script that exists (and, for a subcommand
# or flag, one that script knows).
n=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  n=$((n + 1)); sc="${ref%% *}"; arg=""; case "$ref" in *" "*) arg="${ref#* }" ;; esac
  found=""; for d in "$JS" "$P/scripts" "$P/hooks"; do [ -f "$d/$sc" ] && found="$d/$sc"; done
  if [ -z "$found" ]; then nok "a hook receipt names $sc, which is not a script of the plugin"; continue; fi
  ok
  case "$arg" in
    --*|fetch|check|build|mcp-request|fingerprint|transport|guard|bb)
      grep -q -- "$arg" "$found" && ok || nok "a hook receipt says '$sc $arg', which $sc does not know" ;;
  esac
done < <(grep -oE '[a-z][a-z-]*\.sh( (--)?[a-z-]+)?' "$HOOK" | sort -u)
[ "$n" -ge 6 ] && ok || nok "found only $n script references in the hook"
for ref in "jira-context.sh mcp-request" "jira-context.sh fetch" "jira-context.sh check" "jira-notify.sh --from-mcp" "jira-mine.sh --from-mcp"; do
  assert_contains "$(cat "$HOOK")" "$ref" "the hook's receipts still say: $ref"
done
assert_contains "$(cat "$P/jira/README.md")" "### Capture protocol" "the README section"
for f in "$HOOK" "$P/commands/jira-run.md" "$JS/mcp-lib.sh" "$JS/jira-mine.sh"; do
  assert_contains "$(cat "$f")" "Capture protocol" "$(basename "$f") cites the README section"
done

t "one report id, one hunk grammar, one pr-id parser, one need_key (M4a Task 2)"
for f in "$P/commands/review-tour.md" "$P/commands/jira-run.md"; do
  assert_not_contains "$(cat "$f")" '<KEY>-s<k>' "$(basename "$f") does not spell out the report id rule"
  assert_contains "$(cat "$f")" 'plan-state.sh report-id <plan>' "$(basename "$f") asks plan-state.sh report-id"
  assert_contains "$(sed -n '/^---$/,/^---$/p' "$f" | grep '^allowed-tools:')" 'plan-state.sh report-id:*' "$(basename "$f") pre-approves report-id"
done
assert_contains "$(grep '^allowed-tools:' "$P/commands/review-tour.md")" 'plan-state.sh get:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh report-id:*)' "the tour reads get and report-id"
for f in review-report.sh review-record.sh review-brief.sh review-queue.sh run-state.sh bb-pr-comment.sh; do
  g="$(ls "$P/scripts/$f" "$JS/$f" 2>/dev/null | head -n1)"
  assert_eq "$(grep -cE '^(need_key|need_dir|valid_hunk)\(\)' "$g")" "0" "$f defines no local need_key/need_dir/valid_hunk"
done
assert_contains "$(cat "$P/scripts/review-report.sh" "$JS/review-record.sh")" "asdlc_valid_hunk" "both hunk readers use the shared check"
assert_eq "$(grep -c 'pull-requests/' "$JS/run-state.sh" "$JS/review-queue.sh" | grep -v ':0' | grep -cv 'review-queue.sh:[0-9]*$' || true)" "0" "no PR id parsing left in run-state.sh"
assert_not_contains "$(grep -n 'pid="${url#' "$JS/run-state.sh" || true)" "pid=" "run-state.sh strips no URL prefix itself"
assert_not_contains "$(grep -n 'id="${url#' "$JS/review-queue.sh" || true)" "id=" "review-queue.sh strips no URL prefix itself"

t "the plan-only flow is one shared file, both commands read it, and Phase A has its named parts (M4a Task 3)"
flow="$P/docs/plan-only-flow.md"
[ -f "$flow" ] && ok || nok "docs/plan-only-flow.md is missing"
for f in "$P/commands/implement-prd.md" "$P/commands/jira-run.md"; do
  assert_contains "$(cat "$f")" 'Read `${CLAUDE_PLUGIN_ROOT}/docs/plan-only-flow.md` and follow it' "$(basename "$f") reads the plan-only flow"
done
assert_not_contains "$(sed -n '/^## Plan-only mode/,/^## Execute mode/p' "$P/commands/implement-prd.md")" "prd-planner" "implement-prd no longer carries the plan-only steps"
for f in "$P"/docs/*.md; do
  assert_not_contains "$(head -n1 "$f")" "---" "$(basename "$f") has command frontmatter"
done
for h in "### Review queue" "### Which plans run" "### Stale check" "### Run a plan" "### After APPROVE: brief, then AI summary" "## Jira over MCP"; do
  assert_contains "$(grep -E '^##+ ' "$P/commands/jira-run.md")" "$h" "jira-run has the heading: $h"
done

t "progress lines come from plan-state.sh log: no agent edits the plan, implement-prd logs each verdict, meta feeds review-mode"
for a in prd-executor prd-reviewer prd-tester; do
  c="$(contract "$P/agents/$a.md")"
  assert_contains "$c" 'Never edit the plan file' "$a contract: never edit the plan"
  assert_contains "$c" 'plan-state.sh log' "$a contract names the logger"
  assert_contains "$c" '<ROLE> <VERDICT> — <note>' "$a contract: return the verdict line"
  assert_not_contains "$c" 'Append one entry' "$a contract no longer tells the agent to append"
  assert_not_contains "$(cat "$P/agents/$a.md")" 'a Progress entry in a stamped plan' "$a has no Progress-entry instruction"
done
assert_not_contains "$(cat "$P/agents/prd-reviewer.md")" 'append to the task in the plan' "reviewer does not write the plan"
rtools="$(sed -n 's/^tools: //p' "$P/agents/prd-reviewer.md")"
assert_contains "$rtools" "Write" "the reviewer keeps Write: it writes its own retrospective review file"
assert_contains "$(cat "$P/agents/prd-reviewer.md")" './plans/<prd-slug>.review.md' "the reviewer names that file"
assert_contains "$(cat "$P/agents/prd-reviewer.md")" 'the only file you write' "and says it is the only file"
ip="$(cat "$P/commands/implement-prd.md")"; ipfm="$(sed -n '/^---$/,/^---$/p' "$P/commands/implement-prd.md")"
assert_contains "$ip" 'plan-state.sh log <plan> <n> <ROLE> <VERDICT> "<note>"' "implement-prd names the log call"
assert_contains "$ipfm" 'plan-state.sh log:*' "implement-prd pre-approves plan-state.sh log"
for v in 'EXECUTOR DONE' 'EXECUTOR BLOCKED' 'REVIEW APPROVED' 'REVIEW CHANGES_REQUESTED' 'TEST PASS' 'TEST FAIL'; do
  assert_contains "$ip" "\`$v\`" "implement-prd quotes the contract string $v"
done
assert_not_contains "$ip" 'REVIEWER' "implement-prd never calls a role REVIEWER"
assert_not_contains "$ip" 'TESTER ' "implement-prd never calls a role TESTER"
# jira-run pre-approves log (the skill it runs needs it), but its own steps never call it.
assert_not_contains "$(awk 'f>=2; /^---$/{f++}' "$P/commands/jira-run.md")" 'plan-state.sh log' "jira-run's steps do not log: the implement-prd skill does"
assert_contains "$jr" 'jira-context.sh meta <KEY>' "jira-run step 5 gets the type and labels from meta"
assert_contains "$jr" 'review-mode.sh <TARGET_BRANCH> HEAD "<issue_type>" "<labels_csv>"' "and passes them to review-mode.sh"
assert_not_contains "$(grep -rn 'plan-state.sh log\|asdlc:progress' "$P/docs/plan-only-flow.md" | grep -v 'stamp')" 'plan-state.sh log' "the plan-only flow never logs"

t "unstamped plans: Pipeline mode does not log or stamp, and each agent says what it does there (PR #10 SF-1)"
assert_contains "$ip" 'If `log` exits 16 ("no header block")' "implement-prd names log's exit 16"
assert_contains "$ip" 'never run `plan-state.sh stamp` here' "implement-prd says never to stamp"
assert_contains "$ip" 'so Pipeline mode' "implement-prd says Pipeline mode does not log"
efm="$(sed -n '/^---$/,/^---$/p' "$P/agents/prd-executor.md")"
assert_not_contains "$efm" "updates the plan's task status" "the executor's description no longer says it always updates the plan"
assert_contains "$efm" 'only when the' "the executor's description says when it marks the task"
for a in prd-executor prd-reviewer prd-tester; do
  assert_contains "$(contract "$P/agents/$a.md")" 'A plan without that line: see your *Verdict* or *On completion* section below.' "$a contract points unstamped plans at its own section"
done
assert_contains "$(cat "$P/agents/prd-reviewer.md")" 'In a plan that is not stamped, nothing records your verdict' "the reviewer says nothing records its verdict there"
assert_contains "$jr" 'A non-zero exit, or any other output, means `council`.' "jira-run step 5: a failing review-mode.sh means council"

t "no Glob or Grep for commands, no pre-approved rg or find, no agent Bash scope (M4a Task 5)"
for f in "$P"/commands/*.md; do
  assert_not_contains "$(sed -n '/^allowed-tools:/p' "$f")" 'Glob' "$(basename "$f") allowed-tools has no Glob"
  assert_not_contains "$(sed -n '/^allowed-tools:/p' "$f")" 'Grep' "$(basename "$f") allowed-tools has no Grep"
  assert_not_contains "$(cat "$f")" 'Glob' "$(basename "$f") never mentions Glob"
  assert_not_contains "$(cat "$f")" 'Grep' "$(basename "$f") never mentions Grep"
done
assert_not_contains "$(cat "$P/docs/plan-only-flow.md")" 'Glob' "the plan-only flow never mentions Glob"
assert_not_contains "$(cat "$P/docs/plan-only-flow.md")" 'Grep' "the plan-only flow never mentions Grep"
assert_eq "$(grep -rnIE 'Bash\((rg|find)' "$P" || true)" "" "no plugin file pre-approves Bash(rg or Bash(find"
for f in "$P"/agents/*.md; do
  assert_not_contains "$(sed -n 's/^tools: //p' "$f")" '(' "$(basename "$f") tools line has no scope"
done
for a in pr-reviewer pr-reviewer-security pr-reviewer-architecture pr-reviewer-correctness; do
  assert_eq "$(grep -c '^tools:' "$P/agents/$a.md")" "0" "$a has no tools line"
  assert_contains "$(cat "$P/agents/$a.md")" 'Search with `grep -rn` or `find` through Bash; `rg` may not be installed.' "$a has the search note"
done
for f in "$P"/agents/*.md; do
  if grep -q '^tools:.*\(Glob\|Grep\)' "$f"; then
    assert_contains "$(cat "$f")" 'If Glob or Grep is missing, use Read on known paths.' "$(basename "$f") has the fallback note"
  fi
done
assert_contains "$(grep '^allowed-tools:' "$P/commands/review-tour.md")" 'plan-state.sh find-branch:*' "the tour pre-approves find-branch"
assert_contains "$(cat "$P/commands/review-tour.md")" 'plan-state.sh find-branch <branch>' "the tour calls find-branch"
assert_contains "$(cat "$P/jira/README.md")" 'verify interactively' "the README notes the allowed-tools lapse"

t "jira-run pre-approves everything the skills it runs pre-approve"
# A skill run from inside jira-run gets only jira-run's pre-approvals (the 1.7.0 smoke: every
# implement-prd "plan-state.sh log" call was refused until jira-run listed it).
jr_tools="$(sed -n 's/^allowed-tools: //p' "$P/commands/jira-run.md" | tr ',' '\n' | sed 's/^ *//')"
# The skills are jira-run's own Skill(asdlc:<name>) entries, so a new one is checked too.
jr_skills="$(printf '%s\n' "$jr_tools" | sed -n 's/^Skill(asdlc:\([a-z0-9-]*\))$/\1/p')"
for sk in implement-prd review-pr; do
  printf '%s\n' "$jr_skills" | grep -qxF "$sk" && ok || nok "jira-run's Skill entries miss $sk (the list is not being read)"
done
for sk in $jr_skills; do
  if [ -f "$P/commands/$sk.md" ]; then ok; else nok "jira-run runs Skill(asdlc:$sk) but commands/$sk.md is missing"; continue; fi
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    if printf '%s\n' "$jr_tools" | grep -qxF -- "$rule"; then ok; else nok "jira-run lacks $sk's pre-approval: $rule"; fi
  done <<EOF
$(sed -n 's/^allowed-tools: //p' "$P/commands/$sk.md" | tr ',' '\n' | sed 's/^ *//')
EOF
done

t "plan-state.sh find-branch"
PS="$P/scripts/plan-state.sh"
sandbox; mkdir plans
printf '%s\n' '<!-- asdlc' 'ticket: A-1' 'status: pending' 'branch: feature/A-1-x' 'pr:' '-->' '# body' > plans/A-1.plan.md
printf '%s\n' '<!-- asdlc' 'ticket: A-2' 'status: pending' 'branch: feature/A-2-y' 'pr:' '-->' '# body' 'branch: feature/A-1-x' > plans/A-2.plan.md
printf '%s\n' '<!-- asdlc' 'ticket: A-3' 'status: pending' 'branch:' 'pr:' '-->' '# body' > plans/A-3.plan.md
run "$PS" find-branch feature/A-1-x; assert_eq "$CODE/$OUT" "0/plans/A-1.plan.md" "a match prints the one plan (body lines are not read)"
run "$PS" find-branch feature/A-1; assert_eq "$CODE/$OUT" "1/" "a prefix is not a match"
run "$PS" find-branch feature/none; assert_eq "$CODE/$OUT" "1/" "no match: exit 1, no output"
run "$PS" find-branch ""; assert_eq "$CODE" "2" "an empty branch is refused"
run "$PS" find-branch -x; assert_eq "$CODE" "2" "a branch starting with - is refused"
run "$PS" find-branch "$(printf 'a\tb')"; assert_eq "$CODE" "2" "a control character is refused"
run "$PS" find-branch "$(printf 'a\nb')"; assert_eq "$CODE" "2" "a newline is refused"
run "$PS" find-branch; assert_eq "$CODE" "2" "no argument is refused"
cp plans/A-1.plan.md plans/A-4.plan.md
run "$PS" find-branch feature/A-1-x; assert_eq "$CODE/$OUT" "2/" "two plans claiming one branch: exit 2, no path"
rm plans/A-4.plan.md
ln -s A-1.plan.md plans/A-5.plan.md
run "$PS" find-branch feature/A-1-x; assert_eq "$CODE/$OUT" "0/plans/A-1.plan.md" "a symlinked plan file is skipped"
rm plans/A-5.plan.md
before="$(cat plans/*.plan.md | cksum)"; run "$PS" find-branch feature/A-2-y; assert_eq "$before" "$(cat plans/*.plan.md | cksum)" "read-only"
mv plans realplans; ln -s realplans plans
run "$PS" find-branch feature/A-1-x; assert_eq "$CODE/$OUT" "2/" "a symlinked plans/ is refused"

t "plan-state.sh find-pr"
sandbox; mkdir plans
U=https://bitbucket.org/acme/widgets/pull-requests
printf '%s\n' '<!-- asdlc' 'ticket: A-1' 'status: waiting' 'branch: feature/A-1-x' "pr: $U/7" '-->' '# body' > plans/A-1.plan.md
printf '%s\n' '<!-- asdlc' 'ticket: A-2' 'status: done' 'branch: feature/A-2-y' "pr: $U/17/" '-->' '# body' "pr: $U/8" > plans/A-2.plan.md
printf '%s\n' '<!-- asdlc' 'ticket: A-3' 'status: pending' 'branch:' 'pr:' '-->' '# body' > plans/A-3.plan.md
run "$PS" find-pr 7; assert_eq "$CODE/$OUT" "0/plans/A-1.plan.md" "a match prints the one plan"
run "$PS" find-pr 17; assert_eq "$CODE/$OUT" "0/plans/A-2.plan.md" "a trailing slash on the recorded pr still matches"
run "$PS" find-pr 007; assert_eq "$CODE/$OUT" "0/plans/A-1.plan.md" "leading zeros are read as the number"
run "$PS" find-pr 1; assert_eq "$CODE/$OUT" "1/" "17 is not 1, and 7 is not 17: no match"
run "$PS" find-pr 8; assert_eq "$CODE/$OUT" "1/" "a pr line in the body is not read"
for bad in "" -7 7a "1234567890" "$(printf '7\n')x"; do
  run "$PS" find-pr "$bad"; assert_eq "$CODE" "2" "bad id refused: $(printf '%s' "$bad" | tr -cd '[:print:]')"
done
cp plans/A-1.plan.md plans/A-4.plan.md
run "$PS" find-pr 7; assert_eq "$CODE/$OUT" "2/" "two plans claiming one PR: exit 2, no path"
rm plans/A-4.plan.md
assert_contains "$(grep '^allowed-tools:' "$P/commands/review-tour.md")" 'plan-state.sh find-pr:*' "the tour pre-approves find-pr"
assert_contains "$(cat "$P/commands/review-tour.md")" 'plan-state.sh find-pr <id>' "the tour calls find-pr"
assert_contains "$(cat "$P/commands/review-tour.md")" 'more than one plan claims it, STOP' "the tour stops when two plans claim the PR"
assert_not_contains "$(cat "$P/commands/review-tour.md")" 'ask me for the ticket KEY' "the tour does not ask for the KEY when it has a PR id"

finish
