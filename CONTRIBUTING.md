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
   claude plugin validate .
   ```

4. **Open a GitHub PR.** Reviewers nitpick inline and/or run `/asdlc:review-pr` on the diff.

5. **On merge**, teammates run `/plugin marketplace update asdlc-tools` then `/reload-plugins`.

6. **Reminders:** kebab-case names; no `../` paths; use `${CLAUDE_PLUGIN_ROOT}` for scripts and support files. This is a public repo — never commit ticket keys, internal URLs, real seed checklists, or anything mined from company project-management data.
