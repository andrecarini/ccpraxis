#!/usr/bin/env bash
# gate-stop.sh — Stop hook inside coordinator sessions.
#
# A coordinator may only go idle when its ledger says so. Concretely:
#   * frontmatter status is terminal: done | blocked | parked
#   * the ledger was touched recently (default: last 15 min, BP_LEDGER_FRESH_MIN)
#   * blocked/parked additionally require a non-empty "## Next action" section
#
# This converts ledger discipline from a prompt rule (which decays over long
# contexts) into a mechanical gate. Escape hatch for the orchestrator:
# touch runs/<pkg>.force-stop to let the session end unconditionally.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
# Coordinator-only discipline. A judge (harvest/resolve) carries the same env
# contract so guard-writes can scope its writes, but it is a one-shot task that
# must end when done — holding it to coordinator stop-discipline (terminal ledger
# status, Next-action, freshness) would wedge it. Skip any non-coordinator role.
[ "${BP_ROLE:-coordinator}" = "coordinator" ] || exit 0

FORCE="$BP_DIR/runs/${BP_PACKAGE:-pkg}.force-stop"
if [ -f "$FORCE" ]; then rm -f "$FORCE"; exit 0; fi

# Graceful fleet pause (Decision #12, package A4): runs/.paused — WITHOUT a
# graceful-shutdown — means the orchestrator paused the fleet to preserve the usage
# reserve / weather a telemetry gap and WILL auto-resume this package. The
# orchestrator only relaunches DEAD + NON-TERMINAL packages, so permit a clean,
# non-terminal stop here (the gate-shutdown hook has already drained the worker and
# denied new work) rather than forcing a terminal park that would strand it. A
# concrete Next action is still required so the warm resume has a clean handoff. A
# graceful-shutdown (.shutdown) instead wants a terminal park, so it falls through
# to the normal terminal-status requirement below.
if [ -f "$BP_DIR/runs/.paused" ] && [ ! -f "$BP_DIR/runs/.shutdown" ]; then
  if [ ! -f "$BP_LEDGER" ]; then
    echo "STOP BLOCKED: ledger $BP_LEDGER does not exist. Even under a fleet pause, write the ledger (status, '## Next action') before stopping so the resume has a clean handoff." >&2
    exit 2
  fi
  # The orchestrator only relaunches DEAD + NON-TERMINAL packages, so ENFORCE
  # non-terminal here (don't merely instruct it): a terminal status under a pause
  # would strand this package — never relaunched, never resumed.
  PSTATUS=$(awk 'BEGIN{infm=0} /^---[[:space:]]*$/{infm++; if(infm==2)exit; next} infm==1 && /^status:/{sub(/^status:[[:space:]]*/,""); print; exit}' "$BP_LEDGER")
  case "$PSTATUS" in
    parked|done|blocked)
      echo "STOP BLOCKED: a fleet pause is active and WILL auto-resume this package, but the ledger status is '$PSTATUS' (terminal) — a terminal package is never relaunched and would be stranded. Set status back to a non-terminal value (running/converging) with a concrete '## Next action', then stop." >&2
      exit 2 ;;
  esac
  PNEXT=$(awk '/^## Next action/{while ((getline)>0){if ($0 ~ /^[[:space:]]*$/) continue; if ($0 !~ /^#/) print; exit} exit}' "$BP_LEDGER")
  if [ -z "${PNEXT:-}" ] || grep -q '^<' <<<"$PNEXT"; then
    echo "STOP BLOCKED: a fleet pause is active but '## Next action' is empty or still a template placeholder. The auto-resume needs the exact pick-up point. Fill it, then stop." >&2
    exit 2
  fi
  # A paused stop must hand off CURRENT state — a stale ledger means the coordinator
  # didn't refresh before parking. Same freshness limit as the terminal path below.
  PNOW=$(date +%s); PMT=$(stat -c %Y "$BP_LEDGER" 2>/dev/null || echo 0)
  PAGE_MIN=$(( (PNOW - PMT) / 60 )); PFRESH="${BP_LEDGER_FRESH_MIN:-15}"
  if [ "$PAGE_MIN" -gt "$PFRESH" ]; then
    echo "STOP BLOCKED: a fleet pause is active but the ledger is ${PAGE_MIN}m stale (limit ${PFRESH}m). Refresh '## Next action' and last_updated to the current state so the warm resume is clean, then stop." >&2
    exit 2
  fi
  exit 0
fi

if [ ! -f "$BP_LEDGER" ]; then
  echo "STOP BLOCKED: ledger $BP_LEDGER does not exist. Create/update it (status, Next action, outputs) before stopping." >&2
  exit 2
fi

STATUS=$(awk '
  BEGIN { infm=0 }
  /^---[[:space:]]*$/ { infm++; if (infm==2) exit; next }
  infm==1 && /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }' "$BP_LEDGER")

case "$STATUS" in
  done|blocked|parked) : ;;
  *)
    echo "STOP BLOCKED: ledger status is '${STATUS:-unset}', not terminal. Before stopping: finish or park the work, update the ledger (frontmatter status -> done|blocked|parked, last_updated, 'Next action', 'Outputs'), then stop. If genuinely stuck, status: blocked with a precise Next action is a valid terminal state." >&2
    exit 2 ;;
esac

NOW=$(date +%s); MT=$(stat -c %Y "$BP_LEDGER" 2>/dev/null || echo 0)
AGE_MIN=$(( (NOW - MT) / 60 ))
FRESH="${BP_LEDGER_FRESH_MIN:-15}"
if [ "$AGE_MIN" -gt "$FRESH" ]; then
  echo "STOP BLOCKED: ledger status is terminal but the file is ${AGE_MIN}m stale (limit ${FRESH}m). Re-verify the final state on disk, refresh last_updated and the closing summary, then stop." >&2
  exit 2
fi

if [ "$STATUS" != "done" ]; then
  NEXT=$(awk '/^## Next action/{while ((getline)>0){if ($0 ~ /^[[:space:]]*$/) continue; if ($0 !~ /^#/) print; exit} exit}' "$BP_LEDGER")
  if [ -z "${NEXT:-}" ] || grep -q '^<' <<<"$NEXT"; then
    echo "STOP BLOCKED: status is '$STATUS' but '## Next action' is empty or still a template placeholder. A blocked/parked ledger must tell a fresh coordinator exactly where to pick up." >&2
    exit 2
  fi
fi

# Best-effort: sync registry status so bp-status/sweep see the terminal state
# without parsing every ledger again.
REG="$BP_DIR/runs/registry.json"
if command -v jq >/dev/null 2>&1 && [ -s "$REG" ] && [ -n "${BP_PACKAGE:-}" ]; then
  # Same-dir temp so the rename is an atomic same-volume move (cross-device mv is
  # not atomic — matters on Windows/Git-Bash where mktemp's default is elsewhere).
  TMP=$(mktemp "$(dirname "$REG")/.reg.XXXXXX" 2>/dev/null || mktemp)
  jq --arg pkg "$BP_PACKAGE" --arg st "$STATUS" \
     '.packages[$pkg] = ((.packages[$pkg] // {}) + {status:$st})' "$REG" > "$TMP" 2>/dev/null \
    && mv "$TMP" "$REG" || rm -f "$TMP"
fi

exit 0
