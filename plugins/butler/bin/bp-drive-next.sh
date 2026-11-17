#!/bin/bash
# bp-drive-next.sh — thin shim so the drive-next verbs are reachable by name
# instead of by a path nobody can type. All logic lives in
# ../scripts/bp-drive-next.pl; this only locates it and exec's it.
#
# RESOLVED FROM THIS FILE'S OWN LOCATION, not from $HOME. claude-sandbox.sh
# hardcodes ~/.claude/ccpraxis/... because it only ever runs on the host. This
# one is also read inside a sandbox, where the plugin tree is bind-mounted at
# /root/.claude/plugins/marketplaces/ccpraxis-local/, so a $HOME assumption
# would point at nothing. BASH_SOURCE follows the file wherever it lives.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -e

BIN_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SCRIPT=$(cd -P "$BIN_DIR/.." && pwd -P)/scripts/bp-drive-next.pl

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: bp-drive-next.pl not found at $SCRIPT" >&2
  echo "       This shim expects to sit in <plugin>/bin next to <plugin>/scripts." >&2
  exit 1
fi

exec perl "$SCRIPT" "$@"
