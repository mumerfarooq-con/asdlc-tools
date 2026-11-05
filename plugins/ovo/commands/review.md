---
description: Review your branch or a PR before a teammate does - one reviewer, or a three-lens council with --council. Numbered findings and the hunks a human must read. Read-only; never posts.
argument-hint: "[<branch> [<base>] | <pr-url>] [--council]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ovo-dir.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review-target.sh:*), Read
---

# /ovo:review

You coordinate a code review of: $ARGUMENTS

Never edit code. Never post anywhere: no PR comments, reviews, approvals or merges, and never offer to. You write only under `.ovo/` in the repo root.

Run each script from the repo root as its own Bash call, exactly as shown: never chain it with `;`, `&&` or `|`, and never add `echo` (only the bare call is pre-approved, and the result already shows the exit code).

## 1. Arguments
- `--council` → **council mode** (three lenses and a chair). Without it → **solo mode** (one reviewer).
- Then one of: nothing (the current branch, with its uncommitted and untracked files, against the default branch); `<branch> [<base>]`; or a Bitbucket or GitHub PR URL.

## 2. Target
1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/ovo-dir.sh review --new`, adding `<branch>` as its last argument if one was given. It prints the run directory; its last part is `<id>`.
2. Run `${CLAUDE_PLUGIN_ROOT}/scripts/review-target.sh <id>`, followed by the branch and base, or the PR URL, exactly as given (never `--council`).
   - Exit 0: its first line ("Reviewing <head> against <base>, N files ...") is the first line of your reply. With `0 files`, say there is nothing to review, and STOP.
   - Any other exit: show its message as it is (it says what to pass instead), and STOP. Start no reviewer.

## 3. Review
Give each agent only `<id>` and the paths `.ovo/review/<id>/diff.patch`, `.ovo/review/<id>/diff.numbered` (the same change with line numbers; agents cite lines from it) and `.ovo/review/<id>/target.txt`, plus `CLAUDE.md` if the repo root has one. Do not review the code yourself.
- **Solo:** invoke `reviewer`. It writes `.ovo/review/<id>/review.md`.
- **Council:** invoke `lens-security`, `lens-correctness` and `lens-architecture` in parallel, in the foreground (one message with three calls). They write `.ovo/review/<id>/security.md`, `.ovo/review/<id>/correctness.md` and `.ovo/review/<id>/architecture.md`; pass no other path. When all three have returned, invoke `chair` with `<id>`. It writes `.ovo/review/<id>/review.md`.
- If an agent returns its report but says it could not write its file, write the text it returned to that exact path yourself, unchanged, under a first line `> Written by /ovo:review from the <agent> reply.` Never change a finding.

## 4. Reply
Read `.ovo/review/<id>/review.md`, then reply in at most 25 lines:
1. The "Reviewing ..." line.
2. The verdict.
3. The findings with the report's numbers, BLOCKER first, at most 12, one line each: `<n>. <SEVERITY> <file:line> — <issue>`. Copy each `file:line` and hunk as the report has it (they come from `diff.numbered`); never recount them from `diff.patch`.
4. `Risk tier: <tier>`, and each must-read hunk from the report's `## Human must read` section.
5. `Report: .ovo/review/<id>/review.md`
6. The line: Say which to fix, e.g. `fix 1 and 3`.

Then stop. Fixing is the user's call, in their next message.
