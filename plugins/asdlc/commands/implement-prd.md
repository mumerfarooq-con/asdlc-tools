---
description: Orchestrate PRD implementation (plan → execute → review → test), plan only and stop for file-based approval, execute an approved plan, or run a retrospective review of an already-completed PRD
argument-hint: <path-to-prd | path-to-plan> [--plan-only | --execute | --review-only]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh stamp:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh progress:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh:*)
---

You are orchestrating work for: $ARGUMENTS

Parse the arguments and pick a mode:
- `--review-only` present → **Retrospective mode** (arg is a PRD).
- `--plan-only` present   → **Plan-only mode** (arg is a PRD).
- `--execute` present     → **Execute mode** (arg is a PLAN file).
- otherwise               → **Pipeline mode** (arg is a PRD).

You coordinate only — route all planning, coding, review, and testing through subagents to keep your context small.

## Pipeline mode (fresh PRD implementation)

1. **Plan** — Invoke `prd-planner` on the PRD. Wait for the plan file path and status.
   - If `STATUS: BLOCKED`, surface the open questions to the user and STOP.

2. **Execute → Review → Test loop** — For each task in dependency order:
   a. Invoke `prd-executor` with the plan path and task name.
      - If BLOCKED, surface to the user and pause.
   b. Invoke `prd-reviewer` in task mode on the same task.
      - On `REVIEW: CHANGES_REQUESTED`, re-invoke `prd-executor` with the findings. Max 2 fix attempts, then escalate to the user.
   c. On `REVIEW: APPROVED`, invoke `prd-tester` on the task.
      - On `TEST: FAIL`, re-invoke `prd-executor` with the failure report, then re-run the reviewer ONLY if the fix touched files beyond the original task scope; otherwise go straight back to the tester. Max 2 fix attempts, then escalate.
   d. On `TEST: PASS`, proceed to the next task.

   Independent tasks (no shared files, no dependency edge) may execute in parallel; review and test steps still run per task.

3. **Wrap up** — When all tasks are DONE + APPROVED + PASS:
   - Run the full test suite once from the main session as a sanity check.
   - Summarize: tasks completed, files changed, tests added, review findings deferred (MINORs), anything flagged.
   - Suggest a commit message (do not commit unless asked).

## Plan-only mode (--plan-only) — produce a plan and STOP
Nothing is implemented in this mode. Approval is never yours and never interactive: the user answers
the open questions in the plan file, then approves with `/asdlc:plan approve <ID>`.
You write files only where a step says so. Never edit the plan except to insert the critic's rows
in step 5; every other change to it is the planner's.
1. Pick the plan id `<ID>`: the ticket key in the PRD's title if it has one (e.g. `PROJ-142`),
   else the PRD file's basename. The plan path is `./plans/<ID>.plan.md`. If
   `./plans/<ID>.plan.prev.md` exists, this is a re-plan: pass that path to the planner as earlier
   context (its answered questions are reused).
2. Invoke `prd-planner` with step `terms`, the PRD path, `<ID>`, and the `.prev` path if there is one.
   It writes `./plans/<ID>/terms.txt` and no plan.
3. Run the impact scan from the repo root: `${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh <ID>`,
   adding `--reset` if this is a re-plan (a `.prev` exists). If it exits non-zero, report its
   message and STOP.
4. Invoke `prd-planner` with step `plan`, the PRD path, `<ID>`, the template path
   `./plans/<ID>/plan-template.md` (step 3 copied it there; subagents may not be allowed to read the
   plugin dir), and the exact output path `./plans/<ID>.plan.md`
   (plus the `.prev` path on a re-plan).
   - If it replies `RESCAN`, run `${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh <ID>` again (pass 2,
     no `--reset`), then invoke step `plan` once more. A second `RESCAN` is not allowed: report it and STOP.
5. Invoke `plan-critic` with only these paths: the plan, the PRD, `./plans/<ID>/impact.md`, and the
   access-rules and known-traps paths from impact.md's header. Pass nothing else, and never the
   planner's notes. Insert its rows, unchanged, into the plan's "Critic notes" table with Edit
   (replace the placeholder row if the table has one). Do not touch any other line.
6. Invoke `prd-planner` with step `revise` and the plan path. It fixes the plan for each critic row
   and fills each row's Planner response.
7. Run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <ID>` and show the result. INVALID is
   expected while open questions remain; it is not an error here.
8. Stamp it: `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh stamp ./plans/<ID>.plan.md <ID>`
   (writes the header block, `status: pending` plus a hash of the plan, and adds an empty Progress
   section after a `<!-- asdlc:progress -->` line. The hash covers only what's above that line, so
   what a run logs there never voids the approval. Stamp adds that line itself and refuses a plan
   that already contains one, so the plan must not have it).
9. Tell the user the plan is written and awaiting their approval, and what to do:
   - read the plan;
   - answer each open question in the file: `- [x] <question> -> Answer: <answer>`;
   - for any critic blocker the planner disagreed with, add `human accepted: <reason>` to its
     Planner response, or fix the plan;
   - then run `/asdlc:plan approve <ID>`, and `/asdlc:implement-prd ./plans/<ID>.plan.md --execute`
     (`/asdlc:jira-run` also runs approved plans for Jira tickets).
   STOP.

## Execute mode (--execute) — run an approved plan
1. **Gate:** run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh check <plan>` and
   `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh validate <plan>`.
   - `check` prints `RUNNABLE` AND `validate` prints `VALID` → go to step 2.
   - Anything else → report it and STOP. `check` can print `PENDING` `EDITED` `STALE` `NEEDS_INFO`
     `BLOCKED` `EXECUTING` `DONE` `FAILED` `SKIP` `MISSING`. On `INVALID`, relay the problems and say
     the plan was written before 1.3.0 or is incomplete, and must be re-planned (`/asdlc:plan replan <ID>`,
     then `--plan-only`). Never implement a plan that is not RUNNABLE and VALID.
2. **Start:** run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh set <plan> status executing`.
   This command owns that transition, so the caller never sets it first. If it refuses, report why and STOP.
3. **Execute → Review → Test loop** — exactly as in Pipeline mode step 2, against this plan, with
   three rules for stamped plans:
   - The tasks are only those above the plan's `<!-- asdlc:progress -->` line. The Progress section
     below it is the run's log, never a source of work. The subagents log there, not in the tasks.
   - Entries have exactly the form `- Task <n>: <ROLE> <VERDICT> — <note>`. Resuming after a
     crashed run: run `${CLAUDE_PLUGIN_ROOT}/scripts/plan-state.sh progress <plan>`; it prints the
     latest entry per task as `Task <n>: <ROLE> <VERDICT>`. A task whose line says `TEST PASS` is
     finished — skip it. Restart every other task from the executor; it finds that run's partial
     work in place.
   - The log only ever describes the plan's recorded branch: a re-stamp clears it, and
     `run-state.sh start-branch` refuses to cut a fresh branch for a plan whose log has entries.
4. **Wrap up** — exactly as in Pipeline mode step 3.

## Retrospective mode (--review-only, already-completed PRD)

1. Invoke `prd-reviewer` in retrospective mode with the PRD path (pass the plan file path too if one exists in ./plans/).
2. Relay the report location (`./plans/<slug>.review.md`) and a severity summary (counts of BLOCKER/MAJOR/MINOR).
3. Do NOT auto-invoke the executor on findings — ask the user whether to:
   - turn the "Suggested follow-up tasks" into a fix-up plan via `prd-planner`, then run the normal pipeline on it, or
   - stop here.

## Rules
- Plan-only mode never implements and never approves. Execute mode never runs a plan that is not RUNNABLE and VALID.
- Never implement code yourself in this session; all changes go through `prd-executor`.
- Run subagents in the foreground and wait for each result (parallel calls in one message are fine). Don't background them: a turn that ends while a subagent works drops the calling command's pre-approved tools, and later steps stall on permission prompts.
- Keep per-task commentary to 2–3 lines; plan and review files in ./plans/ are the source of truth for state.
- If context grows large mid-pipeline, /compact and resume from the plan file's task statuses.
