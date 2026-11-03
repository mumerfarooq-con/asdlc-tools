# shellcheck shell=bash
# Small helpers shared by the review scripts (review-brief.sh, review-record.sh, review-report.sh,
# review-queue.sh, run-state.sh, bb-pr-comment.sh). Sourced, never run. It needs nothing else: lib.sh
# sources it, and review-report.sh (which has no other library) sources it directly. bash 3.2 safe.
# asdlc_need_key and asdlc_need_dir also use asdlc_is_key (lib.sh) and a die2 function the caller defines.

# <KEY> -> exit 2 through the caller's die2 unless it is a ticket key like PROJ-1.
asdlc_need_key() { asdlc_is_key "${1:-}" || die2 "'${1:-}' is not a ticket key like PROJ-1"; }

# asdlc_plain_walk <relative path> <die function>: every part is a real name (no '', '.', '..') and none
# is a symlink, so a path is never followed out of the tree. Parts are checked as written (no globbing).
asdlc_plain_walk() {
  local f="$1" die="$2" rest acc="" part
  rest="$f"
  while :; do
    part="${rest%%/*}"
    case "$part" in ''|.|..) "$die" "'$f' must be a plain path (no '..', '.' or '//')" ;; esac
    acc="${acc:+$acc/}$part"
    [ ! -L "$acc" ] || "$die" "$acc is a symlink"
    [ "$part" != "$rest" ] || break
    rest="${rest#*/}"
  done
  return 0
}

# <KEY> -> prints plans/<KEY>; refuses a symlinked plans or plans/<KEY> (through the caller's die2).
asdlc_need_dir() {
  asdlc_plain_walk "plans/$1" die2
  printf '%s' "plans/$1"
}

# <pull-request URL> -> prints the numeric id (at most 9 digits, a trailing / allowed), or fails. The URL
# must be a pull request of BB_WORKSPACE/BB_REPO on bitbucket.org.
asdlc_pr_id_from_url() {
  local url="${1:-}" id
  id="${url#"https://bitbucket.org/${BB_WORKSPACE:-}/${BB_REPO:-}/pull-requests/"}"; id="${id%/}"
  [ "$id" != "$url" ] && [[ $id =~ ^[0-9]{1,9}$ ]] || return 1
  printf '%s' "$((10#$id))"
}

# asdlc_valid_hunk <path:start-end>: the grammar of a hunk in a review record. Sets HUNK_PATH, HUNK_START,
# HUNK_END, and on failure HUNK_ERR = form (not path:start-end, or a number over 9 digits), range, or path.
# The path stays free of whitespace, commas and control characters, so the record comment line
# "hunks <h1>, <h2> at <sha>" always parses back; no leading / or -, and no '', '.' or '..' part.
asdlc_valid_hunk() {
  local h="$1" rest comp
  HUNK_PATH=""; HUNK_START=""; HUNK_END=""; HUNK_ERR=form
  [[ $h =~ ^(.+):([0-9]+)-([0-9]+)$ ]] || return 1
  HUNK_PATH="${BASH_REMATCH[1]}"; HUNK_START="${BASH_REMATCH[2]}"; HUNK_END="${BASH_REMATCH[3]}"
  [ "${#HUNK_START}" -le 9 ] && [ "${#HUNK_END}" -le 9 ] || return 1
  HUNK_START=$((10#$HUNK_START)); HUNK_END=$((10#$HUNK_END))
  HUNK_ERR=range
  [ "$HUNK_START" -ge 1 ] && [ "$HUNK_START" -le "$HUNK_END" ] || return 1
  HUNK_ERR=path
  case "$HUNK_PATH" in /*|-*|*[[:space:],]*) return 1 ;; esac
  [ -z "$(printf '%s' "$HUNK_PATH" | tr -d '[:print:]')" ] || return 1
  rest="$HUNK_PATH"
  while :; do
    comp="${rest%%/*}"
    case "$comp" in ''|.|..) return 1 ;; esac
    [ "$comp" != "$rest" ] || break
    rest="${rest#*/}"
  done
  HUNK_ERR=""
  return 0
}
