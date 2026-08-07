#!/usr/bin/env bash
# gate-drive-loop.sh — Stop hook inside a /butler:drive-solo DRIVER session.
#
# THE RULE IT ENFORCES
#
#   A driver turn may end EITHER because something will wake the session
#   (a dispatched subagent, a backgrounded Bash call), OR because the
#   director says the run is settled. Never for any other reason.
#
# WHY IT EXISTS
#
# drive-solo casts the driver as "a thin loop over the director": call
# `bp-drive-next.pl next`, dispatch the action, call `next` again. That is
# prose, and prose decays over a long context. Observed three times in one
# 12-hour run (2026-08-07): a turn ends immediately after a ledger write,
# the text promises the next step, and nothing is scheduled to perform it.
# A dispatched agent notifies; a finished foreground Bash call does not. The
# run dies silently, mid-package, LOOKING finished — which is the worst
# property an unattended run can have, because the operator only discovers it
# by asking.
#
# gate-stop.sh already makes this exact argument one level down, for
# coordinators: it "converts ledger discipline from a prompt rule (which
# decays over long contexts) into a mechanical gate". But every butler hook
# begins with bp_hook_gate, which requires BP_LEDGER — exported only into
# coordinator processes. So the DRIVER, the one session nothing supervises,
# was the only participant with no stop discipline at all. This closes that.
#
# POSTURE: FAIL OPEN, ALWAYS BOUNDED
#
# A stop gate that misfires traps a human's session, which is far worse than
# a missed nudge. So: every error path exits 0; the director is called under a
# timeout; consecutive blocks are capped (MAX_BLOCKS) and then the stop is
# allowed with an explanation; and there are two explicit escape hatches.
#
# ESCAPE HATCHES
#   * touch <data>/.drive-solo/.stop-ok   — one-shot; consumed on use
#   * export CCPRAXIS_DRIVE_STOP_OK=1     — session-wide
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0

MAX_BLOCKS=3          # never nag more than this many times in a row

# Coordinators are gate-stop.sh's business. BP_LEDGER is exported only into
# coordinator processes, so its ABSENCE identifies an interactive driver.
[ -n "${BP_LEDGER:-}" ] && exit 0
[ "${CCPRAXIS_DRIVE_STOP_OK:-}" = "1" ] && exit 0

PAYLOAD=$(cat 2>/dev/null || true)

CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null || true); CWD=${CWD:-$PWD}
DATA="${CCPRAXIS_DATA_DIR:-}"
if [ -z "$DATA" ]; then
  d=$CWD
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -d "$d/.ccpraxis-local-data" ] && { DATA="$d/.ccpraxis-local-data"; break; }
    d=$(dirname "$d")
  done
fi
# No drive-solo state dir => no run in progress here => not our business.
[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0
DS="$DATA/.drive-solo"

# A drive-solo run is only "in progress" once an order has been recorded.
[ -f "$DS/order.json" ] || exit 0

# --- escape hatch: one-shot file, consumed ----------------------------------
if [ -f "$DS/.stop-ok" ]; then
  rm -f "$DS/.stop-ok" "$DS/.stop-blocks" "$DS/.wakeup-pending" 2>/dev/null
  exit 0
fi

# --- a wake-up is already scheduled: this turn end is legitimate -------------
# mark-wakeup.sh wrote this on a Task dispatch or a backgrounded Bash call.
# CONSUME it: the next turn must schedule its own wake-up or settle the run.
if [ -f "$DS/.wakeup-pending" ]; then
  rm -f "$DS/.wakeup-pending" "$DS/.stop-blocks" 2>/dev/null
  exit 0
fi

# --- bounded nagging --------------------------------------------------------
BLOCKS=0
[ -f "$DS/.stop-blocks" ] && BLOCKS=$(cat "$DS/.stop-blocks" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
if [ "$BLOCKS" -ge "$MAX_BLOCKS" ]; then
  rm -f "$DS/.stop-blocks" 2>/dev/null
  echo "butler drive-loop: allowing this stop after $BLOCKS consecutive blocks — the loop is not advancing and a gate that will not yield is worse than a stalled run. Re-invoke /butler:drive-solo to resume; the director is stateless-from-disk and resumes losslessly." >&2
  exit 0
fi

# --- ask the director whether anything is still actionable -------------------
# Any failure here exits 0. A gate that cannot reach its oracle must not trap
# the session.
DRIVE="$HOOK_DIR/../scripts/bp-drive-next.pl"
[ -r "$DRIVE" ] || exit 0
command -v perl >/dev/null 2>&1 || exit 0

RUNNER=""
command -v timeout >/dev/null 2>&1 && RUNNER="timeout 20"
OUT=$(cd "$CWD" 2>/dev/null && $RUNNER perl "$DRIVE" next 2>/dev/null) || exit 0
[ -n "$OUT" ] || exit 0

ACTION=$(printf '%s' "$OUT" | perl -ne 'print $1 if /"action"\s*:\s*"([a-z-]+)"/' 2>/dev/null || true)
[ -n "$ACTION" ] || exit 0

case "$ACTION" in
  done)
    # Run settled. Clean up our own state so a later run starts fresh.
    rm -f "$DS/.stop-blocks" "$DS/.wakeup-pending" 2>/dev/null
    exit 0 ;;
  pause)
    # A usage pause is waited out with Monitor/ScheduleWakeup (its own wake-up);
    # a token pause is a terminal relogin park. Both are legitimate stops.
    rm -f "$DS/.stop-blocks" 2>/dev/null
    exit 0 ;;
esac

# --- still actionable, and nothing will wake us: BLOCK ----------------------
DETAIL=$(printf '%s' "$OUT" | perl -ne 'my @m; while (/"(?:blueprint|package)"\s*:\s*"([^"]+)"/g) { push @m, $1 } print join " / ", @m' 2>/dev/null || true)
echo $((BLOCKS + 1)) > "$DS/.stop-blocks" 2>/dev/null

cat >&2 <<EOF
BLOCKED (butler drive-loop): this turn is ending with nothing scheduled to
continue the run, and the director still returns actionable work:

    action: $ACTION ${DETAIL:+($DETAIL)}

A driver turn may end for exactly two reasons: something will wake the session
(a dispatched subagent, or a backgrounded Bash call), or the run is settled.
Neither holds right now — so if this turn ends, the run stops silently
mid-package while appearing finished.

Do the next thing NOW, in this turn, rather than describing it:
  * dispatch the worker the action calls for, or
  * run 'perl plugins/butler/scripts/bp-drive-next.pl next' and act on it, or
  * if the run really should stop here, touch $DS/.stop-ok and stop again.

(Announcing the next step in prose is what this gate exists to catch. This
will not block more than $MAX_BLOCKS times in a row.)
EOF
exit 2
