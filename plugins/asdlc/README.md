# ASDLC

Agentic SDLC workflows for Claude Code. ASDLC takes a spec or a Jira ticket, writes a reviewed plan, builds it once you approve it, reviews the pull request, and checks the whole codebase before release. Specialised subagents do the work, and nothing runs without your approval.

## Use it

| Command | What it does |
|---|---|
| `/asdlc:implement-prd <prd>` | Plans, builds, reviews and tests a spec. `--plan-only` stops for your approval; given a plan file, `--execute` runs it once approved. |
| `/asdlc:plan approve <ID>` | Approves a plan, after checking that it is complete. Only you can run it. `replan` and `validate` are also available. |
| `/asdlc:jira-run` | Builds the Jira tickets whose plans you approved, opens a Bitbucket PR for each and reviews it, then plans your new tickets. |
| `/asdlc:jira-setup` | Sets up `/asdlc:jira-run` in a repository. |
| `/asdlc:review-pr <pr>` | Reviews a GitHub or Bitbucket PR, or a local branch. Add `--council` for a security, correctness and architecture panel with a chair. |
| `/asdlc:pdqc` | Runs a pre-delivery quality check across the whole codebase and produces findings and remediation work items. |

ASDLC is built for Claude Code: the terminal, an IDE, or the desktop app's Code tab. Its workflows run shell scripts and `git` in your repository. In regular chat, commands load only as skills, and the subagents are ignored.

## Data

- Plans, reviews and reports are written to your repository (`plans/`, `prds/`).
- The Jira workflow calls your Jira Cloud and Bitbucket Cloud APIs with tokens from your shell environment. The Jira token is sent only to your configured Jira URL.
- `/asdlc:review-pr` reads PRs through the `gh` CLI or your Bitbucket MCP server.
- The plugin sends nothing anywhere else.

Full documentation: https://github.com/mumerfarooq-con/asdlc-tools
