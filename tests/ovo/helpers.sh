# shellcheck shell=bash
# Shared setup for the Ovo script tests. Sourced by tests/ovo/test-*.sh.
# The assertions, run() and the cleanup trap come from the Jira suite's helpers (sourced, not
# copied). Use fixture_repo() here, not sandbox(): Ovo has no config, and sandbox() writes one.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../jira" && pwd)/helpers.sh"

OVO="$ROOT/plugins/ovo"
OS="$OVO/scripts"
SHARED_DIR="$ROOT/shared"            # the repo's shared/ (the Jira helpers' SHARED is asdlc's scripts/)
OVO_FAKEBIN="$ROOT/tests/ovo/fakebin"

# Tests never depend on a developer's GitHub login or Ovo test knobs.
unset OVO_IMPACT_NO_RG OVO_IMPACT_NOW GH_TOKEN GITHUB_TOKEN GH_HOST \
      FAKEGH_LOG FAKEGH_OUT FAKEGH_EXIT FAKECURL_STDIN_LOG
export GIT_TERMINAL_PROMPT=0

# A fresh git repo with one commit on main; cd's into it. FR is its path.
#   fixture_repo            origin/main and origin/HEAD point at that commit, with no real remote
#                           (a fetch fails, as when offline)
#   fixture_repo --remote   a real bare origin next to it, with HEAD -> main (ORIGIN is its path)
#   fixture_repo --no-head  like the default, but no origin/HEAD
fixture_repo() {
  local mode="${1:-}"
  FR="$(cd "$(mktemp -d)" && pwd -P)"; SANDBOXES+=("$FR")
  cd "$FR" || exit 1
  git init -q -b main . 2>/dev/null || { git init -q .; git checkout -q -b main; }
  printf '# fixture\n' > README.md
  git add -A; git commit -qm init
  case "$mode" in
    --remote)
      ORIGIN="$(cd "$(mktemp -d)" && pwd -P)"; SANDBOXES+=("$ORIGIN")
      git init -q --bare "$ORIGIN"
      git remote add origin "$ORIGIN"
      git push -q origin main 2>/dev/null
      git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
      git fetch -q origin
      git remote set-head origin -a >/dev/null 2>&1 ;;
    *)
      git remote add origin "https://example.invalid/acme/widgets.git"
      git update-ref refs/remotes/origin/main HEAD
      [ "$mode" = --no-head ] || git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main ;;
  esac
}

# The frontmatter block of a command or agent file (between the first two --- lines).
fm() { awk 'NR == 1 && $0 != "---" {exit} /^---$/ {n++; if (n == 2) exit; next} n == 1 {print}' "$1"; }

# An agent's description as one line: a plain value, or a folded/literal block (>, |, >-) joined.
agent_desc() {
  fm "$1" | awk '
    /^description:/ { v = $0; sub(/^description:[ \t]*/, "", v)
                      if (v ~ /^[>|][-+]?$/) { blk = 1; v = ""; next } print v; exit }
    blk && /^[ \t]/ { s = $0; sub(/^[ \t]+/, "", s); out = out (out == "" ? "" : " ") s; next }
    blk { print out; exit }
    END { if (blk && out != "") print out }' | head -n1
}
