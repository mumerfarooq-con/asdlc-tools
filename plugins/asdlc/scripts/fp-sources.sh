# shellcheck shell=bash
# The one list of ticket-fingerprint sources a plan header may name (fingerprint_source:).
# Sourced by plan-lib.sh (read_fingerprint) and by jira/scripts/jira-context.sh; never run.
# Add a source here and nowhere else.
FP_SOURCES="rest mcp"

fp_source_ok() {  # <source>: 0 if it is a known source
  local s
  for s in $FP_SOURCES; do [ "$s" = "${1:-}" ] && return 0; done
  return 1
}
