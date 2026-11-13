# Changelog

All notable changes to the `ovo` plugin are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the plugin adheres to [Semantic Versioning](https://semver.org/).

Every change to Ovo's content bumps `plugins/ovo/.claude-plugin/plugin.json` and adds an entry here. A change in `shared/` changes both plugins: bump both.

## [0.1.0] - 2026-11-13

The first release: `/ovo:impact` only. A review command and a three-lens council were built and tested against the built-in `/code-review` on real merged PRs; they did not beat it, so they are not in this release. Use `/code-review` for review.

### Added

- **`/ovo:impact [what you're about to change] [--also <dir>]... [--base <ref>]`.** It works from your uncommitted diff, or from what you describe. It writes the changed identifiers as terms, scans the repo (and each `--also` dir, read-only) for every whole-word use, and has the `impact-analyst` agent mark each use fine, needs change or unsure. You get what must still work, and a "Not searched" line that names the frontend when you didn't pass it. Claude may start it when you ask what else uses something.
- **Zero setup.** No config and no token. Reports go to `.ovo/` at the repo root, which ignores itself. No network calls. A diff of more than 60 files stops and asks for a base.
- **Rows cite the line where the fix goes,** with the line number in the file, not in the patch. A record looked up by a value that several records share is never marked `fine`, and a link the change builds for a frontend page that the `--also` repo doesn't have is `needs change` at the line that builds it.
- **The impact scan is shared with asdlc** through `shared/scripts/impact-core.sh`: the same caps, secret-file exclusions and rg/grep parity.
