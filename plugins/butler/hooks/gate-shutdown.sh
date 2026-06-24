#!/usr/bin/env bash
# gate-shutdown.sh — PreToolUse graceful-stop gate (Decision #10/#18, package A4).
#
# When a fleet stop signal is in force, DENY new work so the coordinator funnels to
# a clean park, while always allowing the ledger park-write. Three stop flavors
# share this one gate (Interface contracts):
#   runs/.shutdown          graceful-shutdown-all  -> park (terminal), stays down
#   runs/.paused            usage/telemetry pause  -> drain + resumable stop, auto-resumes
#   runs/<pkg>.force-stop   per-package force-stop -> stop this package
#
# Deny set (Decision #10): Task dispatch (new workers) and edits into the project
# worksite. Allow: the ledger/blueprint-dir/tmp park-write, Bash (finalize/park),
# and all read tools — so the coordinator's in-flight worker drains (≈1 tool-call),
# the result + Next action get recorded, and the session stops via gate-stop.sh.
#
# Fires only inside coordinator sessions (bp_hook_gate: BP_LEDGER/BP_DIR/... set);
# in the reporter / any unrelated session it exits 0 immediately and costs nothing.
# Exit 0 = allow. Exit 2 = block; stderr is fed back to the model.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate

SIGNAL=$(bp_active_stop_signal)
[ -n "$SIGNAL" ] || exit 0            # no stop in progress -> nothing to gate (fast path)

bp_hook_require_jq
PAYLOAD=$(cat)
TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD")
# A stop is in force (checked above); a payload with no identifiable tool_name is
# malformed — fail CLOSED rather than letting an unclassifiable call through.
if [ -z "$TOOL" ]; then
  echo "STOP-AND-PARK: a fleet stop is active and this tool call has no identifiable tool_name — denied. Record '## Next action' and stop." >&2
  exit 2
fi

# Normalize BP_DIR so the ledger/worksite comparison is path-form-consistent with
# realpath's output (drive-letter / slash forms differ on Git-Bash/Windows); match
# either form so a legitimate park-write is never misclassified as worksite.
BP_DIR_N=$(realpath -m "$BP_DIR" 2>/dev/null || printf '%s' "$BP_DIR")

# Classify the target path for edit tools: the ledger/blueprint-dir/tmp is the
# park-write (allowed); anything else is a worksite mutation (new work).
PCLASS="-"
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit)
    FP=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$PAYLOAD")
    if [ -n "$FP" ]; then
      CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD"); CWD=${CWD:-$PWD}
      case "$FP" in /*) ABS="$FP" ;; *) ABS="$CWD/$FP" ;; esac
      ABS=$(realpath -m "$ABS" 2>/dev/null || printf '%s' "$ABS")
      PCLASS=worksite
      case "$ABS" in "$BP_DIR_N"/*|"$BP_DIR"/*|/tmp/*) PCLASS=ledger ;; esac
    else
      PCLASS=worksite   # a mutating tool with no path is suspicious -> fail closed
    fi ;;
esac

VERDICT=$(bp_gate_verdict "$TOOL" "$PCLASS" 1)
[ "$VERDICT" = deny ] || exit 0

# Denied: emit the stop-and-park instruction matching the active signal.
case "$SIGNAL" in
  shutdown)
    echo "STOP-AND-PARK: a fleet-wide graceful shutdown is in progress (runs/.shutdown) — new work is denied. Record the in-flight result, set '## Next action' to where a fresh coordinator would resume, set frontmatter status: parked, refresh last_updated, then STOP. The run stays down (no auto-resume) until a human relaunches it." >&2 ;;
  paused)
    echo "STOP-AND-PARK: the fleet is paused to preserve the usage reserve / weather a telemetry gap (runs/.paused) and WILL auto-resume this package — new work is denied. Record the drained worker's result and a concrete '## Next action', LEAVE status non-terminal (running/converging — do NOT set parked or done, or the orchestrator won't resume you), refresh last_updated, then STOP. You are relaunched warm after the window resets." >&2 ;;
  forcestop)
    echo "STOP-AND-PARK: this package is being force-stopped (runs/${BP_PACKAGE:-pkg}.force-stop) — new work is denied. Record a concrete '## Next action', then STOP." >&2 ;;
esac
exit 2
