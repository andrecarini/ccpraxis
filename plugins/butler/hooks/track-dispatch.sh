#!/usr/bin/env bash
# track-dispatch.sh — PreToolUse hook for Task inside coordinator sessions.
#
# Records which worker is in flight (marker file used by guard-writes.sh for
# role-scoped write rules) and mechanically enforces the protocol rule that at
# most ONE write-capable worker runs at a time. Read-only workers may run in
# parallel freely.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
# Coordinator-only: judges carry the env contract (for guard-writes scoping) but
# never dispatch workers, so the one-write-capable-worker bookkeeping is not theirs.
[ "${BP_ROLE:-coordinator}" = "coordinator" ] || exit 0
# A fleet stop is in force: the graceful-stop gate (gate-shutdown.sh) denies new
# Task dispatch, so do NOT record an active-worker marker for a worker that won't
# launch — a phantom marker would survive into the warm resume and wedge the next
# dispatch ("a write-capable worker is already in flight"). (Package A4.)
[ -z "$(bp_active_stop_signal)" ] || exit 0
bp_hook_require_jq

PAYLOAD=$(cat)
TYPE=$(jq -r '.tool_input.subagent_type // empty' <<<"$PAYLOAD")
[ -n "$TYPE" ] || exit 0

MARKER=$(marker_path)
mkdir -p "$(dirname "$MARKER")"

is_writer() { [[ "$1" == *bp-implementer* || "$1" == *bp-test-writer* || "$1" == *bp-ui-prober* ]]; }

if is_writer "$TYPE"; then
  if [ -f "$MARKER" ]; then
    CURRENT=$(cat "$MARKER" 2>/dev/null || true)
    if [ -n "$CURRENT" ] && is_writer "$CURRENT"; then
      echo "BLOCKED: a write-capable worker ($CURRENT) is already in flight. The protocol allows at most one write-capable worker at a time — wait for it to return before dispatching $TYPE." >&2
      exit 2
    fi
  fi
  printf '%s' "$TYPE" > "$MARKER"
fi

exit 0
