#!/usr/bin/env bash
# bp-orchestrate.sh — start (or report on) the deterministic, token-free
# orchestrator (bp-orchestrator.pl) for a blueprint, detached, inside the sandbox.
#
# This is what /butler:dispatch-fleet runs. The orchestrator then does ALL of the
# watching / event-driven launching / relaunching / usage-governance / token-keeping
# / auto-resume with NO Claude (Decisions #5/#14). The user observes and answers
# decisions through /butler:reporter; closing that interactive session never stops
# the run — the orchestrator is detached and survives on the container's heartbeat.
#
# Idempotent start-or-continue: if a live orchestrator already holds the marker it
# reports that and exits 0 (the orchestrator's own resume-sweep folds in warm/cold
# recovery of interrupted coordinators — there is no separate "resume" verb).
#
# Usage:
#   bp-orchestrate.sh <blueprint>            # start (or report if already live)
#   bp-orchestrate.sh <blueprint> --status   # report only; never start
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"
bp_require_sandbox
require_cmd perl setsid

BP_NAME="${1:?usage: bp-orchestrate.sh <blueprint> [--status]}"
shift || true
STATUS_ONLY=0
[ "${1:-}" = "--status" ] && STATUS_ONLY=1

BPDIR=$(bp_dir "$BP_NAME")
[ -d "$BPDIR" ] || { echo "bp-orchestrate: no blueprint at $BPDIR" >&2; exit 1; }
RUNS="$BPDIR/runs"; mkdir -p "$RUNS"
MARKER="$RUNS/.orchestrator"
LOG="$RUNS/orchestrator.log"

marker_pid() { [ -s "$MARKER" ] && head -n1 "$MARKER" 2>/dev/null | tr -dc '0-9'; }

# Already running? (the marker holds the live orchestrator's PID + an flock)
PID=$(marker_pid || true)
if [ -n "${PID:-}" ] && pid_alive "$PID"; then
  echo "orchestrator already running for $BP_NAME (pid $PID) — observe with /butler:reporter $BP_NAME"
  exit 0
fi
if [ "$STATUS_ONLY" -eq 1 ]; then echo "no live orchestrator for $BP_NAME"; exit 0; fi

# A8 preflight (Decision #29): assert the environment supports a real run BEFORE
# launching the fleet. On any unsupported/failed assumption bp-preflight prints an
# itemized report and exits non-zero; we refuse to start rather than fly blind.
if ! perl "$SCRIPT_DIR/bp-preflight.pl" --quiet; then
  echo "bp-orchestrate: preflight failed — refusing to start the fleet (itemized report above)." >&2
  exit 5
fi

export CCPRAXIS_DATA_DIR="$(bp_data_dir)"

# A8 hooks self-test (Decision #31): before launching any worker, assert LIVE that
# a worker subagent's out-of-scope edit is actually DENIED — the write-containment
# that A4's graceful-gate depends on. Cached after the first pass (keyed by the
# hook scripts + claude version), so this only costs a real check when the hooks or
# claude change. Fail loud: containment unverified ⇒ do not fly the fleet blind.
if ! bash "$SCRIPT_DIR/bp-hooks-selftest.sh" --quiet; then
  echo "bp-orchestrate: hooks self-test failed — refusing to start the fleet (subagent write-containment is unverified, #31)." >&2
  exit 6
fi

# Start-or-continue: we confirmed above that no live orchestrator holds the marker,
# so a .shutdown still sitting in runs/ is a stale terminal signal from a prior
# graceful-reap (commonly: the host slept and the container reaped the run). Clear
# it before launching, or the new orchestrator would wind straight back down.
bp_clear_stale_shutdown "$RUNS"

setsid nohup perl "$SCRIPT_DIR/bp-orchestrator.pl" "$BP_NAME" --bp-dir "$BPDIR" >> "$LOG" 2>&1 &

# Confirm it acquired the flock marker (the real single-instance guard lives in
# bp-orchestrator.pl's acquire_marker; this is a bounded UX confirmation).
for _ in $(seq 1 20); do
  PID=$(marker_pid || true)
  [ -n "${PID:-}" ] && pid_alive "$PID" && break
  sleep 0.25
done
if [ -n "${PID:-}" ] && pid_alive "$PID"; then
  echo "orchestrator started for $BP_NAME (pid $PID) — observe with /butler:reporter $BP_NAME"
  echo "log: $LOG"
else
  echo "bp-orchestrate: orchestrator did not come up — inspect $LOG" >&2
  exit 1
fi
