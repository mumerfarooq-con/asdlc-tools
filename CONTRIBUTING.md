# Contributing to asdlc-tools

This repository holds two plugins and their marketplace: `plugins/ovo` (Ovo) and `plugins/asdlc` (ASDLC). Files both use live in `shared/`, and each plugin links to them (see [shared/README.md](shared/README.md)).

1. **Branch off `main`.** On Windows, clone with `git clone -c core.symlinks=true …`: the plugins reach `shared/` through symlinks, and without it they check out as text files.

2. **Local test loop.**

   ```
   /plugin marketplace add ./asdlc-tools
   /plugin install ovo@asdlc-tools       # and/or asdlc@asdlc-tools
   /reload-plugins
   ```

   Run the changed workflow against a scratch repo; iterate. `claude --plugin-dir plugins/ovo` (or `plugins/asdlc`) loads one plugin straight from your checkout.

3. **Validate before pushing.**

   ```
   claude plugin validate --strict .
   claude plugin validate --strict plugins/asdlc
   claude plugin validate --strict plugins/ovo
   bash tests/jira/run.sh        # asdlc's offline script tests (needs jq)
   bash tests/ovo/run.sh         # Ovo's offline script tests (needs jq)
   ```

   The scripts are written for macOS's bash 3.2 as well as bash 5; run a changed test file under `/bin/bash` too. CI runs bash 5 only.

4. **Bump the version and changelog of each plugin you changed.** Any change to plugin content (commands, agents, scripts, PDQC assets) bumps that plugin's `.claude-plugin/plugin.json` per semver — patch for fixes/wording, minor for new capability (agents, profiles, modes), major for breaking workflow contracts — and adds an entry to its changelog: `CHANGELOG.md` at the root for ASDLC, `plugins/ovo/CHANGELOG.md` for Ovo. A change in `shared/` changes both plugins: bump both, with an entry in each. `/plugin update` delivers changes reliably only when the version moves.

5. **Open a GitHub PR.** Reviewers nitpick inline and/or run `/code-review` or `/asdlc:review-pr` on the diff.

6. **On merge**, a maintainer tags each changed plugin from the repo root, then publishes a GitHub Release for each tag:

   ```
   claude plugin tag --push -m "asdlc %s" plugins/asdlc
   claude plugin tag --push -m "ovo %s" plugins/ovo
   ```

   The path must be the plugin directory, not `.`. Tags are `asdlc--v<version>` and `ovo--v<version>`. Teammates run `/plugin marketplace update asdlc-tools` then `/reload-plugins`.

7. **Reminders:** kebab-case names; no `../` paths at runtime (a plugin never reads `shared/` directly, only its own links); use `${CLAUDE_PLUGIN_ROOT}` for scripts and support files. This is a public repo — never commit ticket keys, internal URLs, real seed checklists, or anything mined from company project-management data.
