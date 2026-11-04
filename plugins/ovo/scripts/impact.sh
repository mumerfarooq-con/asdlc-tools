#!/usr/bin/env bash
# /ovo:impact's scan: where else is what this change touches used?
#   impact.sh <id> [--also <dir>]... [--reset]
# Reads <top>/.ovo/impact/<id>/terms.txt (the command writes it, one term per line), searches the
# repo and each --also dir (read-only; relative to the repo root) for each term as a fixed, whole
# word with impact-core.sh (a link next to this script), and writes .ovo/impact/<id>/hits.md.
# Never searched: secret files (any depth), node_modules, .venv, vendor, dist, build and .git (any
# depth), and .ovo and plans at the top of each root. At most two passes per id; --reset starts
# again at pass 1. Its scratch files stay inside .ovo/impact/<id>/.
# OVO_IMPACT_NO_RG=1 forces grep and OVO_IMPACT_NOW sets the Generated time (tests).
# Exit: 0 written; 2 bad input, refused, or a failed search (nothing written).
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The same default as asdlc's REVIEW_COUNCIL_PATHS: a hit in one of these paths is marked.
SENSITIVE_PATHS='(migration|migrations|auth|security|secret|credential|password|payment|billing|Dockerfile|\.github/|\.asdlc/|terraform|helm|k8s|deploy|infra)'

usage() { echo "usage: impact.sh <id> [--also <dir>]... [--reset]" >&2; exit 2; }
id=""; reset=0; ALSO=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reset) reset=1; shift ;;
    --also) [ $# -ge 2 ] && [ -n "$2" ] || usage; ALSO+=("$2"); shift 2 ;;
    -*) usage ;;
    *) [ -z "$id" ] || usage; id="$1"; shift ;;
  esac
done
[ -n "$id" ] || usage
if ! [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "impact.sh: refusing: the id must match [A-Za-z0-9][A-Za-z0-9._-]*" >&2; exit 2
fi

dir="$("$HERE/ovo-dir.sh" "impact/$id")" || exit 2
top="$(git rev-parse --show-toplevel)"
terms="$dir/terms.txt"
[ -f "$terms" ] && [ ! -L "$terms" ] || { echo "impact.sh: $terms not found (the command writes it first)" >&2; exit 2; }
out="$dir/hits.md"
[ ! -L "$out" ] || { echo "impact.sh: refusing: $out is a symbolic link" >&2; exit 2; }

core=("$HERE/impact-core.sh" --prog impact.sh --id "$id" --terms "$terms" --out "$out" --top "$top"
  --always-exclude .ovo --always-exclude .git --always-exclude plans
  --sensitive-paths "$SENSITIVE_PATHS"
  --hint "an unreadable file or directory? make it readable, or leave that --also dir out")
for x in .git node_modules .venv vendor dist build; do core+=(--exclude "$x"); done
for p in ${ALSO[@]+"${ALSO[@]}"}; do core+=(--also "$p"); done
[ "$reset" -eq 0 ] || core+=(--reset)
[ "${OVO_IMPACT_NO_RG:-0}" != "1" ] || core+=(--no-rg)
[ -z "${OVO_IMPACT_NOW:-}" ] || core+=(--now "$OVO_IMPACT_NOW")
done_line="$(TMPDIR="$dir" "${core[@]}")" || exit $?
echo "impact: $done_line"
