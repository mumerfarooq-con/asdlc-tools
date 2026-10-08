---
description: Set up /asdlc:jira-run in this repo — project config, token check, test calls, docs templates
argument-hint: "[--force]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-setup.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh:*), Bash(git rev-parse:*), Read, Edit
---

# /asdlc:jira-setup

Prepare this repo (run from its root) for `/asdlc:jira-run`. Scripts live in
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/`; call them by that full path. Never print, echo or write a
token value: tokens stay in env vars (`JIRA_EMAIL`, `JIRA_TOKEN`, `BITBUCKET_TOKEN`, and
`BITBUCKET_EMAIL` with `BB_AUTH=basic`), never in a file.

1. **Config.** Run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-setup.sh init $ARGUMENTS`.
   - It writes `.asdlc/jira.conf` from the plugin template, pre-filling values from the env vars
     older in-repo setups used (`JIRA_URL`, `JIRA_PROJECT`, `BITBUCKET_*`...). An existing config
     is left alone unless `--force` was passed.
   - If it reports keys still empty, ask me for each value, then set them with Edit in
     `.asdlc/jira.conf`. Don't guess values.
2. **Docs.** Run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-setup.sh docs`. It creates the access-rules
   and known-traps files (paths from the config) from templates if they're missing. Filling them is
   a human task; don't add entries.
3. **Check.** Run `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-setup.sh check`. It verifies the config, that
   the token env vars are set, makes one Jira and one Bitbucket test call, and checks every
   configured status exists in the project's workflow.
   - A `FAIL` about a value in the config: show me the line, ask for the right value, fix it, re-run.
   - A `FAIL` about an env var or auth: tell me which variable to set in my shell profile
     (e.g. `export JIRA_TOKEN=...` in `~/.zshrc`), then STOP — you can't fix that for me.
   - `warn` lines: relay them; they don't block. A missing `STATUS_NEEDS_INFO` needs a Jira admin.
4. **Wrap up.** Suggest adding `plans/.jira-run.lock` to `.gitignore`, and committing
   `.asdlc/jira.conf` plus the two docs files. Then show the final config
   (`${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh`) and say the repo is ready for `/asdlc:jira-run`.
