#!/usr/bin/env bash
# gate-continuity.sh — Stop hook for an EXPLICITLY-ARMED continuity session.
#
# THE RULE IT ENFORCES
#
#   Once a session has been explicitly armed (perl bp-continuity.pl arm, or
#   /butler:continuity on), a turn may end EITHER because something will wake
#   the session (a dispatched Task/Agent, a backgrounded Bash call), OR
#   because the session has been explicitly DISARMED. Never for any other
#   reason.
#
# WHY THIS IS A NEW, DIRECTOR-FREE GATE, not a re-arming of gate-drive-loop.sh
# or gate-headless-background.sh: see
# specs/g01-explicit-continuity-arming-spec.md SS1/SS2.5. There is no oracle
# for "is this non-blueprint session's work done" — settlement is explicit
# disarm only. This file never stubs, requires, or reads bp-drive-next.pl,
# and reads BP_LEDGER in exactly one place, below, as a top-of-file
# short-circuit — never as a branching signal for block/allow.
#
# WHY THERE IS NO bp_hook_gate CALL HERE (fix-batch F2) — this is DELIBERATE,
# not an omission to "fix" by adding one. Every butler hook begins with
# bp_hook_gate, which requires BP_LEDGER — exported only into coordinator
# processes (see gate-drive-loop.sh's own header for the identical argument
# one level down, for the driver). This gate exists PRECISELY for the
# opposite case: a session with NO blueprint, NO drive-solo, NO reporter —
# i.e. one bp_hook_gate would refuse outright. Adding a bp_hook_gate call
# here would make this file live ONLY inside a coordinator process, which is
# the one class of session that arm already refuses to watch (cmd_arm's
# BP_LEDGER check, and the defense-in-depth BP_LEDGER check a few lines
# below) — i.e. it would silently disable this entire package for every
# session it was built to cover, while still compiling, still registered,
# still "correct" by every check that doesn't actually invoke it live.
#
# POSTURE: FAIL OPEN, ALWAYS BOUNDED — same discipline as gate-drive-loop.sh.
# `source lib.sh 2>/dev/null || exit 0`: a Stop gate cannot function at all
# without the registry helpers, so failing open explicitly here is correct.
#
# ESCAPE HATCHES
#   * touch <marker>.stop-ok              — one-shot; consumed on use
#   * export CCPRAXIS_CONTINUITY_STOP_OK=1 — session-wide
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh" 2>/dev/null || exit 0

MAX_BLOCKS=3

# Coordinators are gate-stop.sh's business, and arm itself already refuses
# BP_LEDGER at the source (spec SS2.2). This is defense in depth, independent
# of that refusal — a marker could predate a session later becoming a
# coordinator, or be planted directly by a test fixture.
[ -n "${BP_LEDGER:-}" ] && exit 0

[ "${CCPRAXIS_CONTINUITY_STOP_OK:-}" = "1" ] && exit 0

# Cheap pre-check + THE reap point (bp_continuity_any_active, lib.sh): the
# overwhelming common case (no one armed anywhere) costs stats only, and this
# is where a stale marker belonging to ANY session gets reaped, regardless of
# who is calling right now.
bp_continuity_any_active || exit 0

bp_read_payload open
SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
[ -n "$SID" ] || exit 0
MARK=$(bp_continuity_marker "$SID" 2>/dev/null) || exit 0
[ -f "$MARK" ] || exit 0

# Per-marker TTL — belt to the sweep's braces (mirrors gate-drive-loop.sh's
# own per-session TTL check). The sweep above already reaped anything stale
# that it found; this catches the case where THIS session's own marker just
# crossed the TTL between the sweep and this read.
TTL_H=$(bp_continuity_ttl_hours)
MNOW=$(date +%s 2>/dev/null || echo 0)
MMT=$(stat -c %Y "$MARK" 2>/dev/null || echo 0)
if [ "$MNOW" -gt 0 ] && [ "$MMT" -gt 0 ] \
   && [ $(( (MNOW - MMT) / 3600 )) -ge "$TTL_H" ]; then
  rm -f "$MARK" "$MARK.wakeup-pending" "$MARK.stop-blocks" "$MARK.stop-ok" 2>/dev/null
  exit 0
fi

touch "$MARK" 2>/dev/null || true

# --- escape hatch: one-shot file, consumed ----------------------------------
if [ -f "$MARK.stop-ok" ]; then
  rm -f "$MARK.stop-ok" "$MARK.wakeup-pending" "$MARK.stop-blocks" 2>/dev/null
  exit 0
fi

# --- a wake-up is already scheduled: this turn end is legitimate -----------
# mark-wakeup.sh's extended write (independent of .drive-solo) wrote this on
# a Task/Agent dispatch or a backgrounded Bash call. CONSUME it.
if [ -f "$MARK.wakeup-pending" ]; then
  rm -f "$MARK.wakeup-pending" "$MARK.stop-blocks" 2>/dev/null
  exit 0
fi

# --- bounded nagging ---------------------------------------------------------
BLOCKS=0
[ -f "$MARK.stop-blocks" ] && BLOCKS=$(cat "$MARK.stop-blocks" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0 ;; esac
if [ "$BLOCKS" -ge "$MAX_BLOCKS" ]; then
  rm -f "$MARK.stop-blocks" 2>/dev/null
  echo "butler continuity-gate: allowing this stop after $BLOCKS consecutive blocks — a gate that will not yield is worse than a stalled run." >&2
  exit 0
fi

echo $((BLOCKS + 1)) > "$MARK.stop-blocks" 2>/dev/null

cat >&2 <<EOF
BLOCKED (butler continuity-gate): this turn is ending with nothing scheduled
to resume this armed session, and it has not been disarmed.

This session was explicitly armed to be watched. A turn may end only if
something will wake it, or the arm is explicitly lifted. Neither holds now.

Do one of these NOW, in this turn:
  * dispatch a subagent or background a Bash call before this turn ends, or
  * explicitly disarm: perl plugins/butler/scripts/bp-continuity.pl disarm
    (or /butler:continuity off) if the watched work is actually finished, or
  * touch $MARK.stop-ok to skip just this once.

(This will not block more than $MAX_BLOCKS times in a row.)
EOF
exit 2
