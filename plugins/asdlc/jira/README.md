# Jira leg — batched plan → approve → execute

`/asdlc:jira-run` runs in two phases each time you invoke it:

1. **Execute** every plan you've already approved → moves the ticket to In Progress, implements
   it with `/asdlc:implement-prd`, opens a Bitbucket PR into `TARGET_BRANCH`, runs
   `/asdlc:review-pr`, loops fixes, posts an approval comment, and leaves the PR for you to merge.
2. **Plan** every new ticket → writes a plan file marked `pending` and stops.

So the rhythm is: run it (plans get written), walk away, come back and approve the good plans,
run it again (approved ones execute, new ones get planned). Approval is durable state in the plan
file, hard-bound to a hash so an "approved" marker can only ever run the exact plan you read.
No Jira or Bitbucket MCP anywhere — every call is a REST call from a script, using your API tokens.

Needs `bash`, `curl`, `jq` and `git`.

## Set up a repo

Run `/asdlc:jira-setup` from the repo root. It:
- writes `.asdlc/jira.conf` from [the template](templates/jira.conf) — one per project, committed,
  plain `KEY=value` (parsed, never executed). If your shell still has the env vars older in-repo
  versions used (`JIRA_URL`, `JIRA_PROJECT`, `BITBUCKET_*`...), their values are pre-filled;
- checks the token env vars, makes one test call each to Jira and Bitbucket, and checks every
  configured status exists in the project's workflow;
- creates `docs/access-rules.md` and `docs/known-traps.md` from templates if missing.

Tokens never go in the config. Keep them in your shell profile, out of git:
```bash
export JIRA_EMAIL="you@example.com"     # your Atlassian login
export JIRA_TOKEN="..."                 # id.atlassian.com > Security > API tokens
export BITBUCKET_TOKEN="..."            # workspace/repo access token or user API token
# export BITBUCKET_EMAIL="..."          # only with BB_AUTH=basic in the config
```

Add `plans/.jira-run.lock` to `.gitignore`.

## Approving a plan
After a planning run, open `./plans/<KEY>.plan.md`. At the top is a header block:
```
<!-- asdlc
ticket: PROJ-142
status: pending          <-- change to: approved
plan_hash: sha256:...    <-- tool-managed, don't touch
...
-->
<the plan>
```
Read the plan, change `status: pending` to `status: approved`, save. That's the whole gate.
- Don't hand-edit the plan body: it breaks the hash and the next run refuses it as STALE. If you
  really want to edit it, re-stamp it (`plan-state.sh stamp ./plans/<KEY>.plan.md` — resets it to
  pending over your edit), then approve.
- To skip a ticket permanently, set `status: skip` (or delete the file).
- Plans written by earlier in-repo versions (header `<!-- jira-run:approval`) keep working.

## Run it
```
/asdlc:jira-run                         # execute approved, then plan my new tickets
/asdlc:jira-run --plan-only             # only plan (the "kick it off and walk away" run)
/asdlc:jira-run --execute-only          # only execute already-approved plans
/asdlc:jira-run --key PROJ-142          # plan a specific ticket (any sprint/assignee)
/asdlc:jira-run --sprint active         # scope planning to the open sprint
/asdlc:jira-run --sprint 42 --status "To Do,Idea"   # other sprints often start as Idea
/asdlc:jira-run --reset-executing       # clear a stale lock left by a crashed run
```
Selection flags (`--key/--sprint/--status/--any-status/--anyone`) scope Phase B planning only;
Phase A runs every approved plan regardless. Runs are serialized by a lock (`./plans/.jira-run.lock`).
Commit, push, opening the PR and commenting on it always wait for your go.

Finding a sprint ID: a bare number in `--sprint N` is the sprint's internal ID, not the board
label. List IDs with `jira-sprints.sh`, or pass the exact name in quotes.

## Merge → Testing
The ticket moves to `STATUS_TESTING` only when the PR is **merged**, via Jira automation:
project automation → "Pull request merged" trigger → transition to Testing + a comment that
@mentions your people. It links automatically because the key is in the branch and PR title.
Needs project-admin rights.

## Scripts (`scripts/`)
All read `.asdlc/jira.conf` (or `--conf <file>`), and all Jira/Bitbucket scripts accept
`--fixtures <dir>` to answer from saved JSON instead of the network (see `tests/jira/` in the
plugin repo for the layout).
- `jira-mine.sh` — list tickets to plan (`--key/--sprint/--status/--any-status/--anyone`).
- `ticket-to-prd.sh` — one ticket → `./prds/<KEY>.md`.
- `plan-state.sh` — the approval/hash engine: `stamp | check | set | get`.
- `bb-open-pr.sh`, `bb-pr-comment.sh` — open a PR, comment on it.
- `review-mode.sh` — council vs solo from the PR diff (files/lines/sensitive paths).
- `jira-transition.sh` — move a ticket by status name, or `:todo :in-progress :testing :needs-info`.
- `jira-notify.sh` — add `NOTIFY_ACCOUNT_IDS` as watchers + @mention comment.
- `jira-sprints.sh` — list sprint IDs/names. `jira-people.sh` — list accountIds.
- `jira-conf.sh` — print the resolved config. `jira-setup.sh` — `init | check | docs`.

The Jira search endpoint used is `/rest/api/2/search/jql` (`/rest/api/3/search` returns 410), and
v2 returns ticket descriptions as plain wiki text. `user/assignable/search` needs the project
KEY, not its display name — JQL accepts either.

## Tune
- Status names (`STATUS_*`) must match your board exactly; `jira-setup.sh check` verifies them.
- Bitbucket auth defaults to Bearer; set `BB_AUTH=basic` (plus `BITBUCKET_EMAIL`) if yours is a
  personal API token that Bearer rejects.
- Council review is ~4x solo. It's chosen by `review-mode.sh` from the actual diff — tune with
  `REVIEW_COUNCIL_FILES` (default 10), `REVIEW_COUNCIL_LINES` (default 400), and
  `REVIEW_COUNCIL_PATHS` (regex of paths that always force council).
