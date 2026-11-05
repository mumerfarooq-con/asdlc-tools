# Ovo

**Don't count your PRs before they hatch.**

Two commands for the Claude chat you already use: see what else a change touches before you make it, and get a real review before a teammate does. No config, no token, nothing to set up.

| Command | What it does |
|---|---|
| `/ovo:impact [what you're about to change]` | Finds every place the changed fields, functions and config keys are used, says which still work, lists what must keep working, and names what it could not search. |
| `/ovo:review [<branch> [<base>] \| <pr-url>] [--council]` | Reviews your branch (with uncommitted and untracked files), another branch, or a PR. One reviewer by default; `--council` adds security, correctness and architecture lenses and a chair. Numbered findings, plus the hunks a human must read. |

Then say what to do next in the same chat: "fix 1 and 3".

## Examples

These come from a small synthetic shop backend, not from a real project.

### `/ovo:impact`

You renamed the `display_name` property to `full_name`, and its key in the customer serializer, but haven't committed yet:

```
/ovo:impact
```

```
Diff mode: feature/rename-name (working tree) against origin/main, 2 files.
1. app/emails.py:2 — needs change — welcome_subject still reads c.display_name, which is gone
2. tests/test_serializers.py:7 — needs change — asserts ["display_name"]; the key is now full_name
3. app/views.py:5 — needs change — the API response key changes; clients reading display_name break
4. app/models.py, app/serializers.py — fine — the two edits agree
Not searched: FE not checked (re-run with --also ../<fe-repo>); other API consumers.
Report: .ovo/impact/feature-rename-name-202611042114/impact.md
```

Run it again with `--also ../web` to search the frontend too. With free text (`/ovo:impact rename display_name to full_name`) it works from what you describe, before you write any code.

### `/ovo:review`

```
/ovo:review feature/refund main --council
```

```
Reviewing origin/feature/refund against origin/main, 2 files (9 lines)
Verdict: REQUEST_CHANGES
1. BLOCKER app/refunds.py:6 — amount is not validated, and it overwrites order.refunded instead of adding to it
2. BLOCKER app/refunds.py:4-8 — request is never read: no permission or ownership check on a refund
3. MAJOR app/refunds.py:6-7 — no transaction, lock or idempotency key; a retry can refund twice
4. MAJOR app/settings.py:3 — CORS_ALLOW_ALL_ORIGINS = True opens the whole app, unrelated to refunds
...
Risk tier: high — app/refunds.py:4-8 (authz), app/refunds.py:6-7 (billing), app/settings.py:1-3 (env-config)
Report: .ovo/review/feature-refund-202611050536/review.md
Say which to fix, e.g. `fix 1 and 3`.
```

## Install

Ovo lives in the `asdlc-tools` marketplace, next to the ASDLC plugin. You need only Ovo.

### Claude Code (terminal, IDE, or the desktop app's Code tab)

```
/plugin marketplace add mumerfarooq-con/asdlc-tools
/plugin install ovo@asdlc-tools
/reload-plugins
```

The terminal, the IDE extensions and the desktop app's **Code** tab share one plugin install on each machine. In the desktop app you can also click **+** next to the prompt and choose **Plugins**. If adding the marketplace fails with an authentication or SSH error, use `https://github.com/mumerfarooq-con/asdlc-tools.git`.

### Claude desktop app: Customize → Plugins

1. Open **Customize** in the left sidebar and go to **Plugins**.
2. Click **Add**, then **Add marketplace**, then **Add from a repository**.
3. Enter `mumerfarooq-con/asdlc-tools`.
4. Find **Ovo** in the list and click **Add**.

Install it one way on each machine, either here or with `/plugin`. Ovo runs `git` and small shell scripts in your repository, so use it where Claude Code runs: the terminal, an IDE, or the desktop app's Code tab.

### Update

```
/plugin marketplace update asdlc-tools
/reload-plugins
```

## Requirements

- `bash` and `git`. [ripgrep](https://github.com/BurntSushi/ripgrep) is optional: without it the scan uses `grep`, with the same output.
- Reviewing by PR URL is optional. For a Bitbucket PR, `curl`, `jq` and `BITBUCKET_TOKEN` in your shell (plus `BITBUCKET_EMAIL` if your token needs it). For a GitHub PR, the `gh` CLI, signed in. Without them, pass the branch: `/ovo:review <branch> [base]`.
- Your repo's default branch: Ovo diffs against `origin/HEAD`. If there isn't one, pass a base (`/ovo:review <branch> main`, `/ovo:impact --base main`).

## What Ovo never does

- **Edit your code.** Fixing is your next message, in your own chat.
- **Post anywhere.** No PR comments, reviews, approvals, merges or Jira updates. A PR URL is read with one GET.
- **Need a token or a config file.** Nothing to set up, and no `.gitignore` to edit.
- **Write outside `.ovo/`.** Reports go to `.ovo/` at the repo root, which ignores itself (Ovo writes `.ovo/.gitignore` with `*` on first use). The only other write is `git fetch` when you review a branch or PR.
- **Run unasked.** Its agents run only from its two commands. Claude may start `/ovo:impact` when you ask what else uses something; only you start `/ovo:review`.
- **Search secrets.** Files like `.env*`, `*.pem` and `*.key` are never searched or quoted, and untracked ones are left out of a review diff.

## Cost and time

Measured on the small examples above: `/ovo:impact` about $0.35 and 45 seconds; `/ovo:review --council` about $1.10 and 4 minutes. A single reviewer costs less. Larger diffs cost more.

<!-- Before release: replace with the bake-off numbers (catches, false positives, cost and time per arm). -->

## FAQ

**How is this different from the built-in `/code-review`?**
The built-in review is a quick check of your diff. Ovo's review adds the council (three lenses that each stay in their lane, and a chair that removes duplicates and overrules weak blockers), numbers every finding so you can say "fix 2", and always ends with the hunks a human must read and a risk tier. It also takes a Bitbucket PR URL. `/ovo:impact` has no built-in counterpart: it searches every usage before the change, including other repos with `--also`.

<!-- Before release: answer with the bake-off results on the team's own PRs. -->

**Why does it say "FE not checked"?**
The change touches something a frontend reads (a response field, a URL), and you didn't pass the frontend repo. Run it again with `--also ../<fe-repo>`.

**Does it work without a remote?**
Yes, with a base: `/ovo:impact --base main`, or `/ovo:review <branch> main`. Without any change or description, `/ovo:impact` asks what you're about to change.

**Where are the full reports?**
In `.ovo/impact/` and `.ovo/review/` at the repo root. They stay on your machine.

**Do I need ASDLC?**
No. ASDLC is the bigger pipeline in the same marketplace (approved plans, the Jira leg, a pre-delivery check). See the [repository README](../../README.md).

```
      .-"""-.
     /  o o  \
    |    v    |
    |\/\/\/\/\|
     \       /
      '-----'
```

Licensed under the [MIT License](../../LICENSE).
