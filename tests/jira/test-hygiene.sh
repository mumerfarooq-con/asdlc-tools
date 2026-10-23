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
  case "$f" in */lib.sh|*/plan-lib.sh|*/context-lib.sh|*/fp-sources.sh) continue ;; esac   # sourced libraries, never run
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
assert_contains "$(cat "$P/commands/implement-prd.md")" "plans/<ID>/plan-template.md" "implement-prd names the in-repo template copy"

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
assert_contains "$(cat "$P/commands/implement-prd.md")" "changes.md" "implement-prd passes changes.md on a re-plan"

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

finish
