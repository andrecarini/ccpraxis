#!/usr/bin/env bash
# log-dispatch.sh — PostToolUse hook for Task inside coordinator sessions.
#
# Appends a mechanical dispatch record to the package ledger and clears the
# active-worker marker. The model adds narrative in its own ledger updates;
# this hook guarantees the skeleton exists even if the model forgets —
# deterministic code can't skip a log line.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
# Logging is best-effort: degrade silently rather than block work.
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD=$(cat)
TYPE=$(jq -r '.tool_input.subagent_type // "task"' <<<"$PAYLOAD")
DESC=$(jq -r '.tool_input.description // (.tool_input.prompt // "" | split("\n")[0]) // ""' <<<"$PAYLOAD" | cut -c1-100)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LOCK=$(ledger_lock)
(
  flock -w 5 9 || exit 0
  # Ledger template keeps "## Dispatch log (auto)" as the LAST section,
  # so appending at EOF lands entries in the right place.
  if ! grep -q '^## Dispatch log (auto)' "$BP_LEDGER" 2>/dev/null; then
    printf '\n## Dispatch log (auto)\n' >> "$BP_LEDGER"
  fi
  printf -- '- %s · %s · %s\n' "$TS" "$TYPE" "$DESC" >> "$BP_LEDGER"
) 9>"$LOCK" 2>/dev/null

MARKER=$(marker_path)
if [ -f "$MARKER" ]; then
  CURRENT=$(cat "$MARKER" 2>/dev/null || true)
  [ "$CURRENT" = "$TYPE" ] && rm -f "$MARKER"
fi

exit 0
