---
description: What else uses the code you are about to change? Finds every place the changed fields, functions and config keys are used, says which still work, and lists what to check. Read-only; zero setup.
argument-hint: "[what you are about to change] [--also <dir>]... [--base <ref>]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ovo-dir.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/base.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/impact.sh:*), Read
---

# /ovo:impact

You map what else a change touches, for: $ARGUMENTS

Never edit code and never post anywhere. You write only under `.ovo/` in the repo root.

Run each script from the repo root as its own Bash call, exactly as shown: never chain it with `;`, `&&` or `|`, and never add `echo` (only the bare call is pre-approved, and the result already shows the exit code).

## 1. Arguments
- `--also <dir>` (repeatable): another repo or directory to search, read-only, relative to the repo root (for example the frontend: `--also ../web`).
- `--base <ref>`: the branch this work will merge into, for a repo with no default branch.
- Anything else is free text: what is about to change.

## 2. Mode
1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/ovo-dir.sh impact --new`. It prints the run directory; its last part is `<id>`.
2. Free text given → **intent mode**.
3. Otherwise run `${CLAUDE_PLUGIN_ROOT}/scripts/base.sh`, adding the `--base` value as its last argument if one was given:
   - it exits 2 saying "no default branch" → **intent mode**, and your reply says: "No default branch here, so I worked from the conversation. For the diff, run `/ovo:impact --base <branch>`." Any other non-zero exit → report its message and STOP;
   - `files:` above 0 → **diff mode**;
   - `files: 0` → **intent mode**, from the conversation.
4. Intent mode with nothing to go on (no free text, and the conversation names no change) → ask what is about to change, and STOP.

## 3. Terms
- **Intent mode:** write the change in 1–3 lines to `.ovo/impact/<id>/intent.md`.
- **Diff mode:** run `${CLAUDE_PLUGIN_ROOT}/scripts/base.sh --write impact/<id>` (plus the `--base` value, as in step 2), then read `.ovo/impact/<id>/target.txt`. If its `patch-lines` is 400 or less, read `.ovo/impact/<id>/diff.patch`. Otherwise use target.txt's `## files` and `## functions` lists, and read only the parts of the patch you need.

Then write `.ovo/impact/<id>/terms.txt`, one term per line: every field, model, function, property, serializer, URL name, setting, env or config key, permission class and FE-facing field name the change touches, plus related names (for a serializer field, the model field or property it reads and any helper that computes it). Exact identifiers only, no prose.

## 4. Scan
Run `${CLAUDE_PLUGIN_ROOT}/scripts/impact.sh <id>`, adding `--also <dir>` for each one given. If it exits non-zero, report its message and STOP.

## 5. Analyst
Invoke `impact-analyst` with only: `<id>`, the mode, the `--also` dirs (or "none"), and the paths `.ovo/impact/<id>/hits.md`, `.ovo/impact/<id>/terms.txt`, and `.ovo/impact/<id>/intent.md` (intent mode) or `.ovo/impact/<id>/diff.patch` (diff mode).
- It replies `RESCAN` → run step 4 again (pass 2, same flags), then invoke it once more.
- A second `RESCAN` is not allowed: say the scan wanted a third pass, give `.ovo/impact/<id>.md` if it exists, and STOP.

## 6. Reply
At most 25 lines, in this order:
1. One line: the mode; in diff mode, `<head> against <base>, <files> files` from base.sh, and any `skipped:` files.
2. The analyst's reply, unchanged: numbered rows (needs change and unsure first), the "Not searched" line, and the report path.

Then stop. The next message is the user's ("fix 2", "show me 3").
