#!/usr/bin/env bash
# The plugin is public and project-agnostic: no project values outside
# templates, no secrets, every script runnable and documented.
. "$(dirname "$0")/helpers.sh"
P="$ROOT/plugins/asdlc"

t "no project-specific values in plugin files outside templates"
# Branch names belong in the config. Add your own project's names and keys
# locally (never commit them here): ASDLC_HYGIENE_WORDS="NAME,KEY" tests/jira/run.sh
words="develop"
[ -n "${ASDLC_HYGIENE_WORDS:-}" ] && words="$words|$(printf '%s' "$ASDLC_HYGIENE_WORDS" | tr ',' '|')"
hits="$(grep -rnIiwE "$words" "$P" --exclude-dir=templates || true)"
assert_eq "$hits" "" "project-specific words"
hits="$(grep -rnIE '[a-z0-9-]+\.atlassian\.net' "$P" --exclude-dir=templates | grep -vE 'your-team|example' || true)"
assert_eq "$hits" "" "real Jira site URLs"

t "no secret-looking values in the Jira leg"
hits="$(grep -rnIE '(TOKEN|SECRET|PASSWORD)=[A-Za-z0-9_-]{8,}' "$P/jira" "$P/commands" || true)"
assert_eq "$hits" "" "hardcoded secrets"

t "scripts are executable, use bash, and set strict mode"
for f in "$P"/jira/scripts/*.sh; do
  case "$f" in */lib.sh) continue ;; esac
  [ -x "$f" ] && ok || nok "$(basename "$f") not executable"
  [ "$(head -n1 "$f")" = "#!/usr/bin/env bash" ] && ok || nok "$(basename "$f") shebang"
  grep -q '^set -euo pipefail' "$f" && ok || nok "$(basename "$f") lacks set -euo pipefail"
  bash -n "$f" && ok || nok "$(basename "$f") syntax"
done

t "commands only reference scripts that exist"
for ref in $(grep -ohE '\$\{CLAUDE_PLUGIN_ROOT\}/jira/scripts/[a-z-]+\.sh' "$P"/commands/*.md | sort -u); do
  [ -f "$P/${ref#\$\{CLAUDE_PLUGIN_ROOT\}/}" ] && ok || nok "missing $ref"
done

t "jira-run's pre-approved tools exclude plan approval, Bitbucket writes, commit and push"
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/jira-run.md")"
assert_not_contains "$fm" "plan-state.sh:*" "blanket plan-state"
assert_not_contains "$fm" "plan-state.sh approve" "plan-state approve"
assert_not_contains "$fm" "bb-open-pr.sh" "bb-open-pr"
assert_not_contains "$fm" "bb-pr-comment.sh" "bb-pr-comment"
assert_not_contains "$fm" "Bash(git:*)" "blanket git"
assert_not_contains "$fm" "git commit" "git commit"
assert_not_contains "$fm" "git push" "git push"
assert_contains "$fm" "Bash(git add:*)" "explicit git add"
assert_not_contains "$fm" "git log" "git log"
assert_not_contains "$fm" "git diff" "git diff"
assert_not_contains "$fm" "git pull" "git pull"
# A new git grant must be added here on purpose.
for g in $(printf '%s' "$fm" | grep -oE 'Bash\(git [a-z-]+' | sed 's/Bash(git //'); do
  case "$g" in status|rev-parse|merge-base|checkout|branch|add|check-ignore) ok ;; *) nok "unexpected git grant: $g" ;; esac
done
fm="$(sed -n '/^---$/,/^---$/p' "$P/commands/implement-prd.md")"
assert_not_contains "$fm" "plan-state.sh:*" "implement-prd blanket plan-state"
assert_not_contains "$fm" "git commit" "implement-prd git commit"
assert_not_contains "$fm" "git push" "implement-prd git push"

finish
