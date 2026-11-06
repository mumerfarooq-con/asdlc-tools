# Install guide: zsh, bash, PowerShell

Install ASDLC into your project's repo from any shell: create two tokens, save them the way your shell needs, then install the plugin inside Claude Code. Only step 2 differs per shell; do the one subsection that matches yours.

- [At a glance](#at-a-glance)
- [1. Create the two tokens (all shells)](#1-create-the-two-tokens-all-shells)
- [2a. zsh (macOS)](#2a-zsh-macos)
- [2b. bash (Linux, macOS bash, Git Bash)](#2b-bash-linux-macos-bash-git-bash)
- [2c. PowerShell (Windows)](#2c-powershell-windows)
- [3. Install the plugin (inside Claude Code, all shells)](#3-install-the-plugin-inside-claude-code-all-shells)
- [Troubleshooting](#troubleshooting)

## At a glance

Everything typed inside Claude Code is identical in every shell. These are the only differences:

| Shell | Typical OS | Tokens saved in | Load them without a new window | Prerequisites via |
|---|---|---|---|---|
| zsh | macOS (default since 10.15) | `~/.zshrc` | `source ~/.zshrc` | Homebrew |
| bash | Linux, older macOS, Git Bash on Windows | `~/.bashrc` (+ `~/.bash_profile` on macOS) | `source ~/.bashrc` | apt / dnf / Homebrew |
| PowerShell | Windows | User environment variables | None: close and reopen PowerShell and Claude Code | winget |

Claude Code reads the tokens from the shell it was started in. Start `claude` from the same shell you saved them in.

## 1. Create the two tokens (all shells)

Each token is shown only once. Keep the page open until you have saved it in step 2.

The Jira token is optional when the Atlassian MCP connector is connected in Claude Code; without it you lose image downloads, watchers, sprints and status-name checks. See [Transport](../plugins/asdlc/jira/README.md#transport).

**Jira API token** (on id.atlassian.com):

1. Open <https://id.atlassian.com/manage-profile/security/api-tokens> and log in.
2. Click **Create API token**, not the "with scopes" one: scoped tokens don't work with the site address (`your-team.atlassian.net`) ASDLC calls.
3. Name it `asdlc-<your-machine>`, pick an expiry, click **Create**, then **Copy to clipboard**.

**Bitbucket repository access token** (needs admin rights on the repo):

1. In your repo, open **Repository settings → Security → Access tokens** (`https://bitbucket.org/<workspace>/<repo>/admin/access-tokens`) and click **Create access token**.
2. Name it `asdlc-<your-machine>` and pick an expiry.
3. Tick **Repositories: Read** and **Pull requests: Write**.
4. Click **Create**, then copy the token.

## 2a. zsh (macOS)

**Prerequisites.** macOS ships `curl`, and macOS 15+ ships `jq` at `/usr/bin/jq`. Install what's missing and Claude Code:

```sh
xcode-select --install
brew install jq
curl -fsSL https://claude.ai/install.sh | bash
```

Skip `xcode-select` if `git --version` already works, and `brew install jq` on macOS 15+. Open a new terminal, then check that each line prints a version:

```sh
claude --version; git --version; curl --version | head -1; jq --version
```

Run `claude` once and log in through the browser. Then go to the repo ASDLC will manage:

```sh
cd path/to/your-repo && git status
```

**Save the tokens.** Use an editor, not `echo`, so the tokens stay out of shell history:

```sh
open -e ~/.zshrc
```

Add these lines, save, and make the file readable only by you:

```sh
export JIRA_EMAIL="your-atlassian-login-email"
export JIRA_TOKEN="paste-jira-token"
export BITBUCKET_TOKEN="paste-bitbucket-token"
```

```sh
chmod 600 ~/.zshrc
source ~/.zshrc
```

`source` loads the values into this terminal. A terminal opened before the edit keeps the old values and gets `401`.

**Test the tokens.** Each line prints `200` when the token works. Put in your own Jira site, Bitbucket workspace and repo first:

```sh
curl -s -o /dev/null -w 'jira %{http_code}\n' -u "$JIRA_EMAIL:$JIRA_TOKEN" https://your-team.atlassian.net/rest/api/2/myself
curl -s -o /dev/null -w 'bitbucket %{http_code}\n' -H "Authorization: Bearer $BITBUCKET_TOKEN" https://api.bitbucket.org/2.0/repositories/your-workspace/your-repo
```

Check all three are set without printing a value (prints `ok` or `MISSING`):

```sh
for v in BITBUCKET_TOKEN JIRA_EMAIL JIRA_TOKEN; do [[ -n ${(P)v} ]] && echo "$v ok" || echo "$v MISSING"; done
```

Next: [step 3](#3-install-the-plugin-inside-claude-code-all-shells).

## 2b. bash (Linux, macOS bash, Git Bash)

**Prerequisites.** Pick your package manager, then install Claude Code:

```sh
# Debian/Ubuntu
sudo apt update && sudo apt install -y git curl jq
# Fedora/RHEL
sudo dnf install -y git curl jq

curl -fsSL https://claude.ai/install.sh | bash
```

On macOS bash, use the Homebrew line from [2a](#2a-zsh-macos). On Git Bash, install the prerequisites and Claude Code from PowerShell ([2c](#2c-powershell-windows)), then come back here for the tokens. Open a new terminal and check that each line prints a version:

```sh
claude --version; git --version; curl --version | head -1; jq --version
```

Run `claude` once and log in through the browser. Then go to the repo ASDLC will manage:

```sh
cd path/to/your-repo && git status
```

**Save the tokens.** Use an editor, not `echo`, so the tokens stay out of shell history (`open -e ~/.bashrc` on macOS):

```sh
nano ~/.bashrc
```

Add these lines at the end and save:

```sh
export JIRA_EMAIL="your-atlassian-login-email"
export JIRA_TOKEN="paste-jira-token"
export BITBUCKET_TOKEN="paste-bitbucket-token"
```

**macOS and Git Bash only:** their terminals start login shells, which read `~/.bash_profile` and skip `~/.bashrc`. Make the profile load it (skip if `~/.bash_profile` already sources `~/.bashrc`):

```sh
echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> ~/.bash_profile
```

Lock the file and load the values into this terminal:

```sh
chmod 600 ~/.bashrc
source ~/.bashrc
```

**Test the tokens.** Each line prints `200` when the token works. Put in your own Jira site, Bitbucket workspace and repo first:

```sh
curl -s -o /dev/null -w 'jira %{http_code}\n' -u "$JIRA_EMAIL:$JIRA_TOKEN" https://your-team.atlassian.net/rest/api/2/myself
curl -s -o /dev/null -w 'bitbucket %{http_code}\n' -H "Authorization: Bearer $BITBUCKET_TOKEN" https://api.bitbucket.org/2.0/repositories/your-workspace/your-repo
```

Check all three are set without printing a value. bash uses `${!v}` where zsh uses `${(P)v}`:

```sh
for v in BITBUCKET_TOKEN JIRA_EMAIL JIRA_TOKEN; do [[ -n ${!v} ]] && echo "$v ok" || echo "$v MISSING"; done
```

On Git Bash, start `claude` from Git Bash so it sees these values; started from PowerShell, it needs 2c's user variables instead. Next: [step 3](#3-install-the-plugin-inside-claude-code-all-shells).

## 2c. PowerShell (Windows)

**Prerequisites.** ASDLC's scripts are bash, so Git for Windows is required, not optional:

```powershell
winget install Git.Git
winget install jqlang.jq
irm https://claude.ai/install.ps1 | iex
```

Close PowerShell and open a new one (winget only updates PATH for new windows). Check that each line prints a version:

```powershell
claude --version; git --version; curl.exe --version | Select-Object -First 1; jq --version
```

Run `claude` once and log in through the browser. If Claude Code says it can't find Git Bash, add this to `%USERPROFILE%\.claude\settings.json`:

```json
{ "env": { "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe" } }
```

Then go to the repo ASDLC will manage:

```powershell
cd path\to\your-repo; git status
```

**Save the tokens.** Windows has no `~/.zshrc`. Save them as user environment variables through the dialog, so they never land in shell history:

1. Start menu → type `environment` → open **Edit environment variables for your account**.
2. Under **User variables**, click **New** for each: `JIRA_EMAIL`, `JIRA_TOKEN`, `BITBUCKET_TOKEN`.
3. Click **OK**. Close every PowerShell window and Claude Code, then open fresh ones. This replaces `source ~/.zshrc`.

On PowerShell 7.1+ you can do the same from the prompt. Input is masked and not kept in history:

```powershell
'JIRA_EMAIL','JIRA_TOKEN','BITBUCKET_TOKEN' | ForEach-Object { [Environment]::SetEnvironmentVariable($_, (Read-Host $_ -MaskInput), 'User') }
```

**Test the tokens.** Type `curl.exe`, not `curl`: in Windows PowerShell, `curl` is a different command. Each line prints `200` when the token works. Put in your own Jira site, Bitbucket workspace and repo first:

```powershell
curl.exe -s -o NUL -w "jira %{http_code}\n" -u "${env:JIRA_EMAIL}:${env:JIRA_TOKEN}" https://your-team.atlassian.net/rest/api/2/myself
curl.exe -s -o NUL -w "bitbucket %{http_code}\n" -H "Authorization: Bearer $env:BITBUCKET_TOKEN" https://api.bitbucket.org/2.0/repositories/your-workspace/your-repo
```

Check all three are set without printing a value (prints `ok` or `MISSING`):

```powershell
'BITBUCKET_TOKEN','JIRA_EMAIL','JIRA_TOKEN' | ForEach-Object { if ([Environment]::GetEnvironmentVariable($_)) { "$_ ok" } else { "$_ MISSING" } }
```

Next: [step 3](#3-install-the-plugin-inside-claude-code-all-shells).

## 3. Install the plugin (inside Claude Code, all shells)

In the repo, start `claude` from the shell where you saved the tokens. Paste each command into Claude Code, one at a time, and wait for it to finish:

1. Add the marketplace: `/plugin marketplace add mumerfarooq-con/asdlc-tools`
2. Install the plugin: `/plugin install asdlc@asdlc-tools`
3. Reload plugins: `/reload-plugins`
4. Set up the project: `/asdlc:jira-setup`

`jira-setup` writes `.asdlc/jira.conf` and asks for each value it can't fill. It then creates `docs/access-rules.md` and `docs/known-traps.md`, makes one Jira and one Bitbucket test call, and checks that every status exists on the board. Have these answers ready:

| Prompt | What to enter |
|---|---|
| Jira site URL | `https://your-team.atlassian.net` |
| Project key | The prefix on your issue numbers (`PROJ` in PROJ-123) |
| Project name | The Jira project's display name |
| Bitbucket workspace | The first part of the repo URL: bitbucket.org/**your-workspace**/your-repo |
| Bitbucket repo | The second part: bitbucket.org/your-workspace/**your-repo** |
| Target branch | The branch pull requests merge into (`develop`, `main`) |
| Status names | Your board's columns, spelled exactly as on the board (To Do, In Progress, Testing) |

Check the result (works in all three shells):

```sh
cat .asdlc/jira.conf
```

The statuses (`STATUS_*`), `SENSITIVE_TOPICS` and the review council thresholds (`REVIEW_COUNCIL_FILES`, `REVIEW_COUNCIL_LINES`, `REVIEW_COUNCIL_PATHS`) can be edited there later. Tokens never go in this file: they stay in your shell. The [Jira leg guide](../plugins/asdlc/jira/README.md) covers every setting.

## Troubleshooting

| Symptom | Shell | Fix |
|---|---|---|
| `claude` or `jq` not recognized | PowerShell | Open a new PowerShell window; winget and the installer only update PATH for new windows |
| Claude Code can't find Git Bash, or ASDLC scripts fail to run | PowerShell | Install Git for Windows ([2c](#2c-powershell-windows)) and set `CLAUDE_CODE_GIT_BASH_PATH` |
| `curl` errors or asks for parameters | PowerShell | Type `curl.exe`; plain `curl` is a different command in Windows PowerShell |
| Token check prints `MISSING` in a new terminal | bash on macOS or Git Bash | The login shell skipped `~/.bashrc`: add the `~/.bash_profile` line from [2b](#2b-bash-linux-macos-bash-git-bash) |
| Jira test prints `401` | All | Wrong email, or the token was made "with scopes": create a plain API token ([step 1](#1-create-the-two-tokens-all-shells)) |
| Bitbucket test prints `401` | All | The token is missing Repositories: Read or Pull requests: Write, or has expired: create a new one ([step 1](#1-create-the-two-tokens-all-shells)). A personal API token that Bearer rejects needs `BB_AUTH=basic` in `.asdlc/jira.conf` and `BITBUCKET_EMAIL` in your shell |
| Marketplace add fails with an auth, SSH or clone error | All | Use the HTTPS URL: `/plugin marketplace add https://github.com/mumerfarooq-con/asdlc-tools.git` |
| Marketplace add is refused | All | Your organization restricts marketplaces: ask an Owner to allow `mumerfarooq-con/asdlc-tools` |
| `/asdlc:jira-setup` not found after install | All | Run `/reload-plugins` again |
| Tests print `200` but `jira-setup` auth fails | All | Claude Code started before the tokens were saved: quit it and start it from a new terminal |
| A status check fails | All | Status names must match the board exactly: fix the `STATUS_*` values in `.asdlc/jira.conf` |

Never paste a token into Claude Code, a commit or a shared screen. If one leaks, revoke it on the page where you made it and create a new one.
