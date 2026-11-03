# Plan-only flow

`/asdlc:implement-prd --plan-only` and `/asdlc:jira-run` Phase B both read this file and follow it.
The caller passes the PRD path (for a Jira ticket, `./plans/<KEY>/context.md`). Where a step says STOP,
the flow ends there and the caller carries on.

## Plan-only mode (--plan-only) — produce a plan and STOP
Nothing is implemented in this mode. Approval is never yours and never interactive: the user answers
the open questions in the plan file, then approves with `/asdlc:plan approve <ID>`.
You write files only where a step says so. Never edit the plan except to insert the critic's rows
in step 5; every other change to it is the planner's.
1. Pick the plan id `<ID>`: for a PRD at `./plans/<KEY>/context.md` it is `<KEY>`; otherwise the
   ticket key in the PRD's title if it has one (e.g. `PROJ-142`), else the PRD file's basename. The
   plan path is `./plans/<ID>.plan.md`. If `./plans/<ID>.plan.prev.md` exists, this is a re-plan:
   pass that path to the planner as earlier context (its answered questions are reused). If
   `./plans/<ID>/changes.md` also exists (the ticket changed), pass it with the `.prev` path.
2. Invoke `prd-planner` with step `terms`, the PRD path, `<ID>`, and the `.prev` path if there is one.
   It writes `./plans/<ID>/terms.txt` and no plan.
3. Run the impact scan from the repo root: `${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh <ID>`,
   adding `--reset` if this is a re-plan (a `.prev` exists). If it exits non-zero, report its
   message and STOP.
4. Invoke `prd-planner` with step `plan`, the PRD path, `<ID>`, the template path
   `./plans/<ID>/plan-template.md` (step 3 copied it there; subagents may not be allowed to read the
   plugin dir), and the exact output path `./plans/<ID>.plan.md`
   (plus the `.prev` path, and `changes.md` if there is one, on a re-plan).
   - If it replies `RESCAN`, run `${CLAUDE_PLUGIN_ROOT}/scripts/impact-scan.sh <ID>` again (pass 2,
     no `--reset`); if it exits non-zero, report its message and STOP. Otherwise invoke step `plan` once more. A second `RESCAN` is not allowed: report it and STOP.
5. Invoke `plan-critic` with only these paths: the plan, the PRD (`context.md` for a Jira ticket),
   `./plans/<ID>/impact.md`, the access-rules and known-traps paths from impact.md's header, and
   `./plans/<ID>/changes.md` on a re-plan that has one. Pass nothing else, and never the
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
