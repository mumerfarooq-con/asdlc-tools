# Changelog

All notable changes to the `ovo` plugin are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the plugin adheres to [Semantic Versioning](https://semver.org/).

Every change to Ovo's content bumps `plugins/ovo/.claude-plugin/plugin.json` and adds an entry here. A change in `shared/` changes both plugins: bump both.

## [0.1.0] - 2026-11-05

The first release.

### Added

- **`/ovo:impact [what you're about to change] [--also <dir>]... [--base <ref>]`.** It works from your uncommitted diff, or from what you describe. It writes the changed identifiers as terms, scans the repo (and each `--also` dir, read-only) for every whole-word use, and has the `impact-analyst` agent mark each use fine, needs change or unsure. You get what must still work, and a "Not searched" line that names the frontend when you didn't pass it. Claude may start it when you ask what else uses something.
- **`/ovo:review [<branch> [<base>] | <pr-url>] [--council]`.** It reviews the current branch with its uncommitted and untracked files, another branch, or a Bitbucket or GitHub PR, against the merge-base with the default branch. One `reviewer` by default; `--council` runs `lens-security`, `lens-correctness` and `lens-architecture` in parallel, then the `chair`. Findings are numbered across severities, and the report ends with the "Human must read" section in the same format as the asdlc plugin's. Only you can start it.
- **Zero setup.** No config and no token. Reports go to `.ovo/` at the repo root, which ignores itself. A Bitbucket PR URL is resolved with one read-only GET when `BITBUCKET_TOKEN` is set, and the token is never on a command line. A diff of more than 60 files stops and asks for a base.
- **The impact scan is shared with asdlc** through `shared/scripts/impact-core.sh`: the same caps, secret-file exclusions and rg/grep parity.
