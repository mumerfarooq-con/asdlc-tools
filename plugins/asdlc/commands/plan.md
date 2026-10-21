---
description: Approve, re-plan or validate a plan file (human-only; approval is never done by the model on its own)
argument-hint: approve|replan|validate <ID>
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh replan:*)
---

# /asdlc:plan

Arguments: $ARGUMENTS

The first word is the action (`approve`, `replan` or `validate`), the second is the plan id `<ID>`
(a ticket key or PRD basename; the plan is `./plans/<ID>.plan.md`). If either is missing or the
action is anything else, say so and STOP. Run from the repo root. You never edit the plan file
yourself, whatever the action.

## validate
Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <ID>`. Relay `VALID` or `INVALID` and
every problem line it prints, word for word. Nothing else.

## approve
1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <ID>` and show the result with every problem line.
2. `INVALID` → STOP. Tell me what to fix in the plan file (answer open questions, resolve critic
   blockers), then run this again. Do not fix it for me.
3. `VALID` → run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh approve <ID>`. This is not
   pre-approved on purpose: the harness asks me to confirm it, and only my confirmation approves.
   Report what it prints (the new hash). If it refuses, relay the reason.

## replan
Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh replan <ID>`. It moves the plan to
`./plans/<ID>.plan.prev.md`. Relay its output, then say: the next `/asdlc:jira-run` or
`/asdlc:implement-prd <prd> --plan-only` re-plans this one, reusing the answers kept in `.prev`.
It refuses while the plan is executing; relay that if so.
