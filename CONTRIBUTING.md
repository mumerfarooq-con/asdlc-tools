# Contributing to asdlc-tools

1. **Branch off `main`.**

2. **Local test loop.**

   ```
   /plugin marketplace add ./asdlc-tools
   /plugin install asdlc@asdlc-tools
   /reload-plugins
   ```

   Run the changed workflow against a scratch repo; iterate.

3. **Validate before pushing.**

   ```
   claude plugin validate --strict .
   ```

4. **Bump the version and changelog.** Any change to plugin content (commands, agents, PDQC assets) bumps `plugins/asdlc/.claude-plugin/plugin.json` per semver — patch for fixes/wording, minor for new capability (agents, profiles, modes), major for breaking workflow contracts — and adds a `CHANGELOG.md` entry. `/plugin update` delivers changes reliably only when the version moves.

5. **Open a GitHub PR.** Reviewers nitpick inline and/or run `/asdlc:review-pr` on the diff.

6. **On merge**, a maintainer tags the release (`claude plugin tag --push .` from the repo root); teammates run `/plugin marketplace update asdlc-tools` then `/reload-plugins`.

6. **Reminders:** kebab-case names; no `../` paths; use `${CLAUDE_PLUGIN_ROOT}` for scripts and support files. This is a public repo — never commit ticket keys, internal URLs, real seed checklists, or anything mined from company project-management data.
