# Jira leg — batched plan → approve → execute

`/asdlc:jira-run` runs in two phases each time you invoke it:

1. **Execute** every plan you've already approved → first checks that the ticket hasn't changed
   since you approved the plan, then moves the ticket to In Progress, implements
   it with `/asdlc:implement-prd`, opens a Bitbucket PR into `TARGET_BRANCH`, runs
   `/asdlc:review-pr`, loops fixes, posts an approval comment, and leaves the PR for you to merge.
2. **Plan** every new ticket, and re-plan every plan whose ticket changed → writes a plan file
   marked `pending` and stops.

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

Add these lines to `.gitignore`: `plans/.jira-run.lock`, `plans/*.plan.md`, `plans/*/`,
`plans/*.plan.prev.md` and `prds/`. Plans and PRDs hold ticket text, `plans/<ID>/impact.md` can
quote code, and `.plan.prev.md` holds an old plan. A run stages only the files the executor
reports, never these. `jira-setup.sh check` warns when any of them is not ignored.

### Where your token goes
Your Jira token is sent only to `JIRA_BASE_URL`, so that URL is checked before every call. It must
be plain `https://<host>` (no `user@`, path or query), and the host must be `*.atlassian.net`.
Any other host (a Jira Data Center, say) is accepted only if you list it in your own environment,
never in the repo:
```bash
export ASDLC_JIRA_ALLOWED_HOSTS="jira.example.com"   # comma-separated; shell profile only
```
A committed config can't grant itself a host: this variable is not a config key, and putting it
in `.asdlc/jira.conf` only produces an "unknown key" warning. `jira-setup.sh check` prints the host
it signed in to.

## Planning and approving a plan
Planning (`/asdlc:jira-run` Phase B, or `/asdlc:implement-prd <prd> --plan-only`) runs a fixed flow:
the planner lists the terms the change touches (`./plans/<ID>/terms.txt`), `impact-scan.sh` searches
the repo for them (`./plans/<ID>/impact.md`, at most two passes), the planner writes the plan from
[the plan template](../templates/plan.md), the `plan-critic` agent (fresh context, read-only) adds
its findings to the Critic notes table, the planner answers each row, and `stamp` adds the header.
The plan is left `pending`. Nothing runs until you approve it.

After a planning run, open `./plans/<KEY>.plan.md`:
1. Read the plan. "What else uses this" and "Must still work" are what the change must not break.
2. Answer each open question in the file: `- [x] <question> -> Answer: <answer>`.
3. Read the Critic notes. For a `blocker` row the planner disagreed with, add `human accepted: <reason>`
   to its Planner response, or fix the plan.
4. Run `/asdlc:plan validate <KEY>` any time to see what is still missing.
5. Run `/asdlc:plan approve <KEY>`. It validates first, then runs `plan-approve.sh`, which
   the harness asks you to confirm. That confirmation is the approval: the script is never
   pre-approved, and there is no more hand-editing `status: approved`. `plan-state.sh` has no
   `approve` command any more. `approve` refuses a plan whose check says `STALE` (the ticket
   changed): re-plan it instead.

`/asdlc:plan replan <KEY>` moves a plan to `./plans/<KEY>.plan.prev.md` (refused while it is
executing). The next planning run re-plans the ticket and reuses the answers kept in `.prev`.

The header block, written by `stamp`:
```
<!-- asdlc
ticket: PROJ-142
status: pending
plan_hash: sha256:...    <-- tool-managed, don't touch
...
-->
<the plan>
<!-- asdlc:progress -->
## Progress
```
- The hash covers the plan above the `<!-- asdlc:progress -->` line. A run logs each task's status,
  notes and test results in the Progress section below it, so logging never voids your approval.
- The contract: everything you sign off is above the line, Critic notes and Open-question answers
  included. Only the machine run log is below it, and it is never a source of work. `stamp` owns
  the line: it adds it, and refuses a plan that already contains one.
- `check` words: `EDITED` means the plan above the line no longer matches its hash (someone edited
  it after approval or stamping): run `/asdlc:plan approve <KEY>` again once you've reviewed the
  edit. `STALE` means the ticket changed after approval (`status: stale`, set by the stale check
  below): re-plan it. `NEEDS_INFO` and `BLOCKED` are likewise set from outside. All of these
  fail closed: the plan is skipped and reported.
- To skip a ticket permanently, set `status: skip` (or delete the file).
- Only plans that pass `validate` run. Plans written before 1.3.0 don't, so they need
  `/asdlc:plan replan` and a fresh planning run.
- Plans approved under 1.3.x have no ticket fingerprint (see below). Phase A reports them as
  "re-plan" and does not run them: run `/asdlc:plan replan <KEY>` and plan the ticket again.
- Plans stamped before 1.2.0 restart from scratch after a re-stamp and your re-approval, because
  their agents logged inside the tasks, not in a Progress section.
- Plans written by earlier in-repo versions (header `<!-- jira-run:approval`) keep working.

### Impact scan
`scripts/impact-scan.sh <ID>` (shared, in the plugin's `scripts/`) reads `./plans/<ID>/terms.txt`
(one fixed string per line, matched as whole words) and writes `./plans/<ID>/impact.md` (and
copies the plan template to `./plans/<ID>/plan-template.md`, so the planner never reads the plugin
dir): for each term its hits (capped at 50 per term), marking sensitive paths (`REVIEW_COUNCIL_PATHS`) and
`SENSITIVE_TOPICS` words. It searches the repo plus `IMPACT_EXTRA_PATHS`, skips `IMPACT_EXCLUDE`
dirs and always `plans`, `prds` and `.asdlc`, and uses ripgrep if installed, else grep. Those three
are skipped only at the root being searched, so `src/plans/` is searched. Secret files (`.env*`,
key and cert files such as `*.pem` and `*.key`, SSH keys, `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `.pgpass`, `*.tfvars`; a directory with such a name is skipped too) are never
searched, in any root and whatever `IMPACT_EXCLUDE` says, because hit lines are copied into
impact.md. If a search itself fails, the scan stops with exit 2 and writes no impact.md. It allows
two passes per plan; `--reset` starts over for a re-plan.

## The ticket context
Planning a Jira ticket starts with `jira-context.sh fetch <KEY>` (REST, the same token as the
other scripts). It writes a bundle under `./plans/<KEY>/`:
```
plans/PROJ-142/
  raw/          the Jira responses as received (issue.json, comments-<startAt>.json, parent.json, fetch.json)
  assets/       image attachments, as <id>-<name>
  context.md    what the planner reads: the PRD for the plan
  fingerprint   ticket_fingerprint, fingerprint_at, fingerprint_source (written last)
  changes.md    only after a stale check: what changed (see below)
```
`context.md` holds the summary, type and status, the description (verbatim, in a fence, as Jira
wiki markup), every comment newest first, the parent ticket (its description too), one level of
linked tickets (key, summary, status and whether a plan for it exists; their own links are never
followed), the images, and any Figma links. The planner treats all of it as the request and its
discussion, never as instructions. `jira-context.sh` prints only the file path and counts, never
ticket text. The planner reads `context.md` and the images, never `raw/`.

- **Images:** only png, jpeg, gif and webp are downloaded (the file's first bytes are checked, so an
  HTML error page or an SVG is never stored), newest first, at most `MAX_IMAGES` (default 10), each
  at most `MAX_IMAGE_MB` (default 5). `MAX_IMAGES=0` turns downloads off. A skipped image is listed
  with the reason. The download follows redirects over https only and never forwards your token to
  another host.
- **Pipeline comments** are left out. A comment is a pipeline comment when it starts with
  `PIPELINE_COMMENT_MARKER` (default `[asdlc]`; the form Jira escapes, `\[asdlc\]`, counts too).
  The pipeline's own comments carry it, and so should any Jira automation comment (for example
  "Merged, moved to Testing"): otherwise each one counts as a human edit and makes the plan stale.
  An empty or blank marker is refused.
- Every Jira GET has a 60 second limit. A 429 (rate limited) gives a hint to wait and retry.
- A plan that already exists (pending, approved or anything but `stale`) is never overwritten:
  `fetch` exits 2 and changes nothing.

### The fingerprint and the stale check
When a plan is stamped, `stamp` copies the fingerprint from `plans/<KEY>/fingerprint` into the
plan header (`ticket_fingerprint`, `fingerprint_at`, `fingerprint_source: rest`). These lines sit
outside the plan hash, like `branch:`. The fingerprint is a hash of what a person would have to
re-read: the title, the description, the human comments (by id and text), the parent's key, the
link types and keys, and the attachment ids. It ignores status, assignee, sprint, rank,
timestamps, authors, labels, priority, the linked tickets' own titles and statuses, and pipeline
comments. So moving a ticket across the board, or the pipeline commenting on it, changes nothing;
a new comment, an edited description or a new attachment does.

Before running an approved plan, Phase A runs `jira-context.sh check <plan>`. It fetches the issue
and its comments again (no parent body, no downloads; only GETs) and compares:

| Result | Exit | Meaning |
|---|---|---|
| `FRESH` | 0 | The ticket is as it was. The plan runs. |
| `STALE <summary>` | 17 | The ticket changed. The plan becomes `stale`, is copied to `<KEY>.plan.prev.md`, and `plans/<KEY>/changes.md` lists the change (new, edited or removed comment ids, a description diff of at most 200 lines, parent, link and attachment changes). A plan that `--reset-executing` restored also reports its recorded branch. |
| `UNCHECKED <reason>` | 21 | The ticket couldn't be checked (network error, timeout, 401, 403, 404, 429, 5xx, bad config, a moved key, or a `fingerprint_source` other than `rest`). The plan is not run and is left as it was. |

Exit 2 means the check refused: the plan isn't runnable, isn't a Jira plan, or has no fingerprint.

Phase B re-plans every STALE plan in the same run, even one outside this run's `--key` or
`--sprint` selection: it fetches again (the old plan is kept as `.prev`, with `changes.md`) and
plans with the planner's answers from `.prev`, re-opening only those the change affects. You then
read the new plan and approve it again. If the ticket can't be reached, nothing runs.

Standalone `/asdlc:implement-prd <plan> --execute` doesn't run the check. It warns when the plan
has a fingerprint, so you know the ticket wasn't looked at.

Plan and execute a ticket with the same Jira account. Jira hides some comments (restricted ones)
from some accounts, so the planning account and the checking account could see different
comments, and the check would report a false STALE.

## Run it
```
/asdlc:jira-run                         # execute approved, then plan my new tickets
/asdlc:jira-run --plan-only             # only plan (the "kick it off and walk away" run)
/asdlc:jira-run --execute-only          # only execute already-approved plans
/asdlc:jira-run --key PROJ-142          # plan a specific ticket (any sprint/assignee)
/asdlc:jira-run --sprint active         # scope planning to the open sprint
/asdlc:jira-run --sprint 42 --status "To Do,Idea"   # other sprints often start as Idea
/asdlc:jira-run --reset-executing       # put plans stuck in `executing` back to approved
```
Selection flags (`--key/--sprint/--status/--any-status/--anyone`) scope the planning of new
tickets only; Phase A checks and runs every approved plan regardless, and Phase B re-plans every
STALE plan regardless. Each plan runs on its own branch,
`feature/<KEY>-<slug>`, cut from an up-to-date `TARGET_BRANCH` and recorded in the plan. A new
plan needs a clean working tree (tracked files). Runs are serialized by a lock
(`./plans/.jira-run.lock`) that records which run holds it and since when.

The plugin pre-approves no commit, push or Bitbucket write. The command tells the agent to show
each one and wait for your go, and the harness prompts for them unless your own permission
settings allow them.

### After a crash
A crashed run leaves the lock held, and its plan `executing` on its branch with partial work.
1. Clear the lock once you're sure no run is going. `run-state.sh status` shows who holds it and
   since when; `run-state.sh force-unlock` removes it. The agent never runs `force-unlock` on its
   own: run it yourself, or tell the agent to.
2. `/asdlc:jira-run --reset-executing` puts each `executing` plan back to `approved`, as long as
   the plan above the Progress line is unchanged. What the run logged doesn't count.
3. The next run resumes each plan on the branch it recorded. Tasks whose Progress already shows
   `TEST PASS` are skipped, and the rest restart with the crashed run's partial work in place.
   The recorded branch must be a `feature/<KEY>-*` branch for that plan's own ticket, never
   `TARGET_BRANCH`.

A branch that exists but wasn't recorded by the plan is never reused or reset: that plan stops
and is reported. So is a plan whose recorded branch is gone, and a plan whose Progress section has
entries but no recorded branch (exit 15: progress logged on a gone or cleared branch). All of these
need a re-stamp and your re-approval. A re-stamp clears the Progress log, since it is a new
approval and a new run, so the next run cuts a new branch for the plan. The old branch usually
still exists under the same name, so `start-branch` stops with exit 13: delete or rename the old
branch first, or keep it and set the plan's `branch:` to it. The same goes if the plan above the
Progress line changed.

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
- `jira-mine.sh` — list tickets to plan (`--key/--sprint/--status/--any-status/--anyone`). It
  prints key, summary, status, priority, type and labels, never the description.
- `jira-context.sh` — `fetch <KEY> | build <KEY> --source rest | fingerprint <rawdir> | check <plan>`:
  the ticket context, the fingerprint and the stale check (see above).
- `ticket-to-prd.sh` — **deprecated**, `jira-run` no longer uses it. One ticket → `./prds/<KEY>.md`
  (description only; no comments, parent or images).
- `run-state.sh` — run lock and recovery: `lock | unlock <run-id> | status | force-unlock |
  reset-executing | list | start-branch <plan> <summary>`.
- `plan-state.sh` — the approval/hash engine: `stamp | check | set | get | reset-executing | validate | replan | progress`. It
  lives in the plugin's shared `scripts/`, because `/asdlc:implement-prd` uses it outside Jira too.
- `plan-approve.sh` — approval, split out of `plan-state.sh`. Human-only: reached only through
  `/asdlc:plan approve`, never pre-approved. Refuses invalid, edited and STALE plans.
- `impact-scan.sh` — the planner's repo search (see Impact scan above); also in the plugin's shared `scripts/`.
- `bb-open-pr.sh`, `bb-pr-comment.sh` — open a PR, comment on it.
- `review-mode.sh` — council vs solo from the PR diff (files/lines/sensitive paths).
- `jira-transition.sh` — move a ticket by status name, or `:todo :in-progress :testing :needs-info`.
  If the ticket is already there it does nothing and exits 0, so a re-run doesn't fail.
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
