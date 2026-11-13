# Ovo

**Don't count your PRs before they hatch.**

One command for the Claude chat you already use: see what else a change touches before you make it, or before you open the PR. No config, no token, nothing to set up.

| Command | What it does |
|---|---|
| `/ovo:impact [what you're about to change]` | Finds every place the changed fields, functions and config keys are used, says which still work, lists what must keep working, and names what it could not search. |

Then say what to do next in the same chat: "fix 1 and 3". Before you open the PR, run the built-in `/code-review` on the diff: the two look in different places (see the FAQ).

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
- Your repo's default branch: Ovo diffs against `origin/HEAD`. If there isn't one, pass a base: `/ovo:impact --base main`.

## What Ovo never does

- **Edit your code.** Fixing is your next message, in your own chat.
- **Post anywhere.** No PR comments, reviews, approvals, merges or Jira updates, and no network calls.
- **Need a token or a config file.** Nothing to set up, and no `.gitignore` to edit.
- **Write outside `.ovo/`.** Reports go to `.ovo/` at the repo root, which ignores itself (Ovo writes `.ovo/.gitignore` with `*` on first use).
- **Run unasked.** Its agent runs only from `/ovo:impact`, which Claude may start when you ask what else uses something.
- **Search secrets.** Files like `.env*`, `*.pem` and `*.key` are never searched or quoted, and untracked ones are left out of the diff.

## Cost and time

Measured on the small example above: about $0.35 and 45 seconds. On real feature branches of 10 to 50 files it took one to two minutes and well under a dollar. Larger diffs cost more.

## FAQ

**How is this different from the built-in `/code-review`?**
Use both. `/code-review` reads the diff you wrote and finds what is wrong in it. `/ovo:impact` looks outside the diff: every other place that uses what you changed, including other repos with `--also`, such as the frontend. A broken caller that the diff never touches is the kind of bug a diff review can't see. Run `/ovo:impact` before or while you code, and `/code-review` before you open the PR.

**Is there an Ovo review command?**
Not in 0.1.0. We tested a review command and a three-lens council against the built-in `/code-review` on real merged PRs, and they did not beat it, so they were left out.

**Why does it say "FE not checked"?**
The change touches something a frontend reads (a response field, a URL), and you didn't pass the frontend repo. Run it again with `--also ../<fe-repo>`.

**Does it work without a remote?**
Yes, with a base: `/ovo:impact --base main`. Without any change or description, `/ovo:impact` asks what you're about to change.

**Where are the full reports?**
In `.ovo/impact/` at the repo root. They stay on your machine.

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
