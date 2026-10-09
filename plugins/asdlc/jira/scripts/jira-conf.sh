#!/usr/bin/env bash
# Print the project's resolved Jira-leg config (defaults + .asdlc/jira.conf).
# Usage: jira-conf.sh          # every key as KEY=value
#        jira-conf.sh <KEY>    # one value, nothing else (for use in commands)
# Never prints tokens: they live in env vars, not in the config.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
asdlc_init "$@"; set -- ${ASDLC_ARGS[@]+"${ASDLC_ARGS[@]}"}

if [ $# -gt 0 ]; then
  asdlc_is_conf_key "$1" || asdlc_die "unknown key: $1"
  printf '%s\n' "${!1}"
  exit 0
fi
echo "# config: $ASDLC_CONF_FILE"
for k in $ASDLC_CONF_KEYS; do printf '%s=%s\n' "$k" "${!k}"; done
