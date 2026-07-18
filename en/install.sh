#!/usr/bin/env bash
# Local install (non-plugin): symlink the cc-* commands onto PATH + create the runtime dir + print activation steps.
# If you install this repo via the Claude Code plugin system, the skill and hooks are taken over
# automatically (see README); but the cc-* commands still need this step to be symlinked onto PATH
# so the agent can run them as bare commands.
set -euo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
exec bash "$REPO/scripts/cc-bus-install.sh" "$@"
