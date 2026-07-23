---
description: Review a PR (GitHub or Bitbucket) — single reviewer by default, or a 3-panelist council with --council
argument-hint: <pr-number | pr-url | branch> [base-branch] [--council]
---

You are coordinating a PR review for: $ARGUMENTS

Parse arguments:
- A GitHub URL → **GitHub mode**. A Bitbucket URL → **Bitbucket mode**. A bare number → detect the provider from `git remote get-url origin` (github.com → GitHub mode, bitbucket.org → Bitbucket mode; ask the user if neither). A branch name → **local mode** (second token = base branch, default `develop`).
- `--council` present → **Council mode** (3 panelists + chair). Absent → **Solo mode** (single `pr-reviewer`).

## Preflight
- GitHub mode: confirm `gh` is authenticated (`gh auth status`). If not, tell the user to run `gh auth login`, and offer local mode.
- Bitbucket mode: confirm the Atlassian/Bitbucket MCP server is connected. If not, tell the user to run `/mcp`, and offer local mode.
- Local mode: `git rev-parse --verify` the branch and base; try `origin/<branch>` after a fetch if missing; ask the user if still missing.

## Solo mode (default — cheap, for routine PRs)
1. Invoke `pr-reviewer` with the PR id/URL and provider mode, or branch + base.
2. Relay verdict, severity counts, report path.
3. Continue to "Handle verdict".

## Council mode (--council — for critical / high-risk PRs)
1. Invoke these THREE panelists IN PARALLEL, each with the same PR id/URL and provider mode, or branch + base:
   - `pr-reviewer-security`
   - `pr-reviewer-architecture`
   - `pr-reviewer-correctness`
   Each writes its own lens report to `./plans/pr-review-<id-or-slug>.<lens>.md`. Do not review code yourself.
2. After all three return, invoke `pr-review-chair` with the same id/slug. The chair reads the three reports, reconciles them, and writes the canonical `./plans/pr-review-<id-or-slug>.md`.
3. Relay the chair's authoritative verdict, must-fix count, canonical report path, top 3 must-fixes.
4. Continue to "Handle verdict" using the CHAIR's verdict (panelist verdicts are inputs, not the decision).

## Handle verdict
- `REQUEST_CHANGES`: ask the user what to do —
  - fix findings now via `prd-executor` (must-fixes first; in council mode re-run only the chair after fixes unless a fix changed scope enough to warrant re-running a panelist — max 2 cycles, then escalate), or
  - post findings as comments on the PR (GitHub: `gh pr comment`; Bitbucket: MCP) — ONLY with explicit user approval, comment-posting only, never approve/decline/merge, or
  - leave the report local.
- `APPROVE`: list remaining MAJOR/MINOR notes. Offer (don't do) posting an approval summary.

## Rules
- Never modify code in this session; route fixes through `prd-executor` only with explicit user approval.
- Never perform any provider write action (comment, review, approve, decline, merge — GitHub or Bitbucket) without the user approving that specific action here.
- Council mode costs ~4x solo in tokens (3 fresh-context panelists + chair). Use it for high-stakes PRs; solo is fine for routine ones.
