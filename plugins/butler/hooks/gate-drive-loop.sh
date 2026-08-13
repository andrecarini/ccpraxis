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

# --- SCOPING, and it must be cheap for the 99% who are not driving ----------
#
# THE OLD TEST WAS WRONG AND EXPENSIVE. It asked "does an ancestor of my cwd
# contain .ccpraxis-local-data/.drive-solo/order.json". That is yes for every
# session in a tree where drive-solo has EVER run — order.json was never
# deleted when a run finished — and yes for sessions that are not the driver
# at all. Worse, the ancestor walk did not terminate on a Windows drive-letter
# cwd (dirname("C:") == "C:"), so an unrelated session hung here until the
# hook timeout on every single stop.
#
# The right question is "is THIS session driving", and mark-wakeup.sh answers
# it by registering a session the moment it calls the director. Two stats and
# no subprocess when nothing is driving anywhere.
bp_drive_any_active || exit 0

PAYLOAD=$(cat 2>/dev/null || true)

SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
[ -n "$SID" ] || exit 0
MARK=$(bp_drive_marker "$SID" 2>/dev/null) || exit 0
[ -f "$MARK" ] || exit 0

# --- staleness: a driver that died must not gate its session id forever -----
# Belt to the disarm-on-settle braces below. A crashed or killed driver leaves
# its marker behind, and without a TTL that id would be gated until someone
# noticed. Refreshed on every stop of a live driver, so only genuine silence
# ages it out.
TTL_H="${CCPRAXIS_DRIVE_TTL_H:-12}"
case "$TTL_H" in ''|*[!0-9]*) TTL_H=12 ;; esac
MNOW=$(date +%s 2>/dev/null || echo 0)
MMT=$(stat -c %Y "$MARK" 2>/dev/null || echo 0)
if [ "$MNOW" -gt 0 ] && [ "$MMT" -gt 0 ] \
   && [ $(( (MNOW - MMT) / 3600 )) -ge "$TTL_H" ]; then
  rm -f "$MARK" 2>/dev/null
  exit 0
fi

# The marker holds the data dir the driver was working in, so this hook needs
# no path walk of its own — the walk that used to be here is the one that hung.
DATA=$(head -n 1 "$MARK" 2>/dev/null || true)
[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || { rm -f "$MARK" 2>/dev/null; exit 0; }
DS="$DATA/.drive-solo"

# A drive-solo run is only "in progress" once an order has been recorded.
[ -f "$DS/order.json" ] || exit 0

touch "$MARK" 2>/dev/null || true

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

# Run the director in the PROJECT the marker recorded, not in whatever the
# payload's cwd happens to be. The marker is the authoritative statement of
# which project this session is driving; a driver that has cd'd into a
# subdirectory (or anywhere else) must still get its own run's verdict. The
# payload cwd is kept only as a fallback for a marker written before this
# field existed.
RUN_DIR=$(dirname "$DATA" 2>/dev/null || true)
if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  RUN_DIR=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null || true)
fi
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || exit 0

# THE DIRECTOR CALL IS ALWAYS BOUNDED. It used to be `timeout 20` when timeout
# existed and UNBOUNDED when it did not — and stock macOS ships no `timeout`
# (only `gtimeout`, via coreutils). An unbounded subprocess inside a Stop hook
# is precisely the shape that hung this hook in the first place, so it must not
# be reachable on any platform.
#
# The fallback bounds it in perl, which this whole project already requires.
#
# ⚠ IT MUST FORK, NOT EXEC. The obvious one-liner —
#     perl -e 'alarm 20; exec @ARGV' perl "$DRIVE" next
# — DOES NOT BOUND ANYTHING HERE, despite alarm() being nominally a process
# property that survives exec. Measured on this host: a 60-second child ran all
# 60 seconds and exited 0. Git-for-Windows perl emulates exec by spawning and
# waiting, so the alarm applies to a wrapper that is merely waiting. Forking and
# killing the child from the parent's SIGALRM handler bounds it correctly (3s,
# exit 124, verified). Recorded because the exec form LOOKS right and silently
# does nothing.
if command -v timeout >/dev/null 2>&1; then
  OUT=$(cd "$RUN_DIR" 2>/dev/null && timeout 20 perl "$DRIVE" next 2>/dev/null) || exit 0
elif command -v gtimeout >/dev/null 2>&1; then
  OUT=$(cd "$RUN_DIR" 2>/dev/null && gtimeout 20 perl "$DRIVE" next 2>/dev/null) || exit 0
else
  OUT=$(cd "$RUN_DIR" 2>/dev/null && perl -e '
      my $pid = fork();
      exit 127 unless defined $pid;
      if ($pid == 0) { exec @ARGV; exit 127 }
      $SIG{ALRM} = sub { kill 9, $pid };
      alarm 20;
      waitpid($pid, 0);
      my $rc = $?;
      alarm 0;
      exit($rc == 0 ? 0 : 124);
    ' perl "$DRIVE" next 2>/dev/null) || exit 0
fi
[ -n "$OUT" ] || exit 0

ACTION=$(printf '%s' "$OUT" | perl -ne 'print $1 if /"action"\s*:\s*"([a-z-]+)"/' 2>/dev/null || true)
[ -n "$ACTION" ] || exit 0

case "$ACTION" in
  done)
    # Run settled. DISARM: drop this session's marker as well as the run state.
    # Leaving it is exactly how the old design rotted — a finished run kept the
    # gate armed for every later session in the tree, forever, because nothing
    # ever cleaned up after success. A later /butler:drive-solo re-arms on its
    # first director call, so re-arming costs nothing and staying armed costs
    # every unrelated session a director spawn on every stop.
    rm -f "$DS/.stop-blocks" "$DS/.wakeup-pending" "$MARK" 2>/dev/null
    exit 0 ;;
  pause)
    # A usage pause is waited out with Monitor/ScheduleWakeup (its own wake-up);
    # a token pause is a terminal relogin park. Both are legitimate stops.
    #
    # The marker STAYS: a usage pause is resumed by this same session once the
    # window rolls over, so disarming here would drop the gate for the rest of
    # a run that is still very much in progress. The TTL above is what reaps it
    # if the session never comes back.
    rm -f "$DS/.stop-blocks" 2>/dev/null
    exit 0 ;;
esac

# --- w02 fold: a VERIFIED live pause escapes the BLOCK below -----------------
# ADDITIVE ONLY. Touches no existing branch above (.stop-ok, .wakeup-pending,
# MAX_BLOCKS, done, pause) and no other file. bp-runstate.pl's `status`
# already computes exactly the checkable claim: state is "paused" IFF a
# specific pid, recorded at the moment someone called
# `pause --watcher-pid P --until U`, is alive RIGHT NOW and U has not yet
# passed (effective() re-verifies both and reverts a stale pause to "active"
# on its own). This adds NO new liveness logic — it only reads that already-
# verified answer, immediately before the unconditional BLOCK below.
#
# PROVABLY INERT against t/94-drive-loop-gate.t section H's own fixture: that
# fixture has no .subagent-guard/run-state.json at all, so bp-runstate.pl
# status returns "inert", never "paused" — the case arm below matches
# nothing and execution falls through to the unchanged BLOCK.
RS="$HOOK_DIR/../scripts/bp-runstate.pl"
if [ -r "$RS" ] && command -v perl >/dev/null 2>&1; then
  RST=$(perl "$RS" status --root "$RUN_DIR" 2>/dev/null) || RST=""
  case "$RST" in
    *'"state":"paused"'*)
      # A live watcher is CONFIRMED. Allow the stop; do not fall through
      # to BLOCK. Any failure of the status call itself (perl missing,
      # unreadable file, malformed JSON) leaves RST empty/unparseable, so
      # the case matches nothing and falls through to BLOCK — the safe
      # direction: an error in this check must never silently grant an
      # escape it did not earn.
      rm -f "$DS/.stop-blocks" 2>/dev/null
      exit 0 ;;
  esac
fi

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
