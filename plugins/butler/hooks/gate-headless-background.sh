#!/usr/bin/env bash
# gate-headless-background.sh — PreToolUse hook for Bash, deny-when-headless.
#
# THE INCIDENT. A harvest judge backgrounded a Bash call and ended its turn
# reasoning "I'll just stop and wait for that notification" — three times in
# the 2026-08-11 GSA fleet run (sources/2026-08-11-gsa-fleet-collapse.md
# Bug 1). A headless `claude -p` process has no next turn: ending the turn
# ends the process, the notification has nowhere to arrive, and no verdict
# is ever written.
#
# THE MIRROR IMAGE (Bug 7): an INTERACTIVE driver legitimately dispatches
# workers in the background and ends its turn — that pattern must stay
# ALLOWED. So this hook branches on ONE thing: whether BP_LEDGER is present
# in the process environment (exported only by bp-launch.sh/bp-judge.sh into
# coordinator/judge processes, and inherited by any Task-dispatched worker —
# dispatch-prompt.md ships it along). Deny when set, allow when unset.
#
# DELIBERATELY NO bp_hook_gate CALL (spec h01 §2.1). bp_hook_gate can only
# make a hook SKIP (exit 0) when BP_LEDGER is absent — it cannot make a hook
# behave DIFFERENTLY on the two sides of that test, which is exactly what
# this hook needs (deny headless, allow-and-let-mark-wakeup.sh-record
# interactive). So it reads BP_LEDGER itself, deliberately alone — NOT the
# bp_hook_gate three-variable (BP_LEDGER && BP_DIR && BP_PROJECT_ROOT) AND,
# which would silently allow a headless call whenever BP_DIR or
# BP_PROJECT_ROOT happened to be unset even though BP_LEDGER was set.
#
# BP_ROLE customises the DENIAL MESSAGE ONLY — never the decision. Both a
# headless coordinator and a headless judge exit their process the same way
# when their turn ends, so both are denied identically; only the wording
# names which one it is.
#
# The verdict is a pure function of the REAL process environment, never of
# payload content the agent controls — a payload that fabricates
# interactivity-looking fields (e.g. a fake "session_type":"interactive")
# must not move the verdict.
#
# Exit 0 = allow (not this call's business, or genuinely interactive).
# Exit 2 = block. Never any other code.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY -- NO bp_hook_gate call here, by design (see above).
source "$HOOK_DIR/lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)

# Same detection mark-wakeup.sh already uses for the identical field: a raw
# grep on the literal JSON boolean, never bp_json_get (which returns empty
# for JSON booleans, verified 2026-08-07) and never jq (this hook must work
# with zero parser dependency, on the bare host and in the container alike).
printf '%s' "$PAYLOAD" | grep -q '"run_in_background"[[:space:]]*:[[:space:]]*true' || exit 0

if [ -n "${BP_LEDGER:-}" ]; then
  ROLE="${BP_ROLE:-coordinator}"
  if [ "$ROLE" = "coordinator" ]; then
    WHO="a headless coordinator (or the worker it dispatched)"
  else
    WHO="a headless \`$ROLE\`"
  fi
  echo "BLOCKED: run_in_background is forbidden here. This session is headless ($WHO) — ending the turn ends the process, so the notification will never arrive and there is no later turn to resume on. Run the command in the foreground instead and wait for its result in this same turn." >&2
  exit 2
fi

exit 0
