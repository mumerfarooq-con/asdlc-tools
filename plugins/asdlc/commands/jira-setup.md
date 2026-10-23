---
description: Set up /asdlc:jira-run in this repo — project config, token check, test calls, docs templates
argument-hint: "[--force]"
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-setup.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh:*), Bash(${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh transport), Bash(git rev-parse:*), Read, Edit
---

# /asdlc:jira-setup

Prepare this repo (run from its root) for `/asdlc:jira-run`. Scripts live in
`${CLAUDE_PLUGIN_ROOT}/jira/scripts/`; call them by that full path. Never print, echo or write a
token value: tokens stay in env vars (`JIRA_EMAIL`, `JIRA_TOKEN`, `BITBUCKET_TOKEN`, and
`BITBUCKET_EMAIL` with `BB_AUTH=basic`), never in a file. Jira tokens are optional when the
Atlassian MCP connector does the Jira work (`JIRA_TRANSPORT=mcp`, or `auto` with no token).

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
   - With `JIRA_TRANSPORT=mcp`, or `auto` and no Jira token, check skips the Jira REST calls and warns
     what is lost (images, watchers, sprints, the status-name check, the REST fallback for truncated
     comment threads). Do step 3b then. With `BB_TRANSPORT=mcp` it needs `ASDLC_BB_MCP_SERVER` (and a
     profile) in my shell environment; never put a server name in the config.
3b. **MCP step** (only when check said the Jira REST calls were skipped). Read-only Atlassian MCP calls,
   nothing else; never create, edit, comment, transition or log work. Get the server name from
   `${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-context.sh transport` (`mcp_server=`); the tools are
   `mcp__<server>__<tool>`. If a tool is not in your tool list, load it with ToolSearch first.
   - **Tool present.** `mcp__<server>__getJiraIssue` and `searchJiraIssuesUsingJql` exist. If not: tell me to connect the
     Atlassian MCP (`/mcp`) or set `ASDLC_JIRA_MCP_SERVER` to its name, then STOP.
   - **Signed in.** Call `atlassianUserInfo`. Report only "signed in" (or that it failed). Never print or
     write the name, email or account id it returns, and never put them in a file.
   - **Project.** Call `searchJiraIssuesUsingJql` with `jql: project = <JIRA_PROJECT_KEY>`, `maxResults: 1`,
     `fields: ["summary"]`, `cloudId` = the host of `JIRA_BASE_URL`. Report only whether it found more
     than 0 tickets. 0 means a wrong key or no access: show me the key and ask.
   - **Statuses.** For each distinct `STATUS_*` value (`STATUS_DEFAULT` is a list), run the same query with
     `AND status = "<name>"`. Say a status with 0 results is "unverified": over MCP an unknown status
     matches nothing without an error, so 0 may just mean no ticket is in it yet. Don't change the config on that alone.
4. **Wrap up.** Suggest adding these lines to `.gitignore` (plans and PRDs hold ticket text and
   must never be staged by a run): `plans/.jira-run.lock`, `plans/*.plan.md`, `plans/*/` (impact.md can quote code),
   `plans/*.plan.prev.md` (an old plan), `prds/`. A `warn` from
   check about them means they're missing. Also suggest committing
   `.asdlc/jira.conf` plus the two docs files. Then show the final config
   (`${CLAUDE_PLUGIN_ROOT}/jira/scripts/jira-conf.sh`) and say the repo is ready for `/asdlc:jira-run`.
