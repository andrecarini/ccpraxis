#!/usr/bin/env bash
# untrack-worker-solo.sh — PostToolUse hook for Task|Agent, INTERACTIVE
# drive-solo sessions only. Clears the marker track-worker-solo.sh wrote.
#
# Implements
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/w03-validation-interlock-spec.md
# §2.4.
#
# fixbatch step7 / F1: the original unconditional `rm -f` let ANY Task/Agent
# return clear the marker, including a read-only worker (bp-scout) returning
# while a different write-capable worker was still live in the same session,
# and a second terminal/session's return clearing a marker it never armed.
# Red-team verified both live. Now a COMPARE-AND-CLEAR, mirroring
# log-dispatch.sh's headless twin (which already compares marker content
# against the returning TYPE for an analogous reason), gated on two
# independent checks:
#   1. The RETURNING dispatch's own type must itself be writer-shaped — a
#      read-only worker's return never clears anything (fixes the
#      same-session read-only-return repro).
#   2. If a session sidecar (MARKER.session, written by track-worker-solo.sh)
#      exists, the returning event's own session_id must match it — a
#      different session's return cannot clear this session's marker (fixes
#      the two-terminal repro). A marker written WITHOUT a sidecar (e.g. by a
#      test fixture, or anything that predates this fix) has no session
#      identity to check and clears on a writer-typed return exactly as
#      before — this is what keeps the pre-existing unconditional-clear tests
#      green.
#
# STALENESS IS HANDLED ELSEWHERE, NOT HERE. guard-validation-interlock.sh's
# own STALE_MIN read-time check (mtime of the marker file itself) already
# lets validation through once the marker ages out, REGARDLESS of whether any
# session's PostToolUse ever returns to clear it — so a marker whose armer
# crashed, or whose session never sends a matching untrack, still self-heals
# without a human or a second gate: the same "reap independent of the owner
# returning" property lib.sh's bp_drive_any_active uses for driver markers.
# This hook only decides who is ALLOWED to clear early; it never affects
# whether a stale marker eventually stops blocking.
#
# NEVER blocks anything. Exit 0 on every path.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

[ -n "${BP_LEDGER:-}" ] && exit 0

bp_read_payload open
CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null); CWD=${CWD:-$PWD}
DATA=$(bp_find_data_dir "$CWD" 2>/dev/null) || exit 0
[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0

MARKER="$DATA/.drive-solo/.active-worker"
[ -f "$MARKER" ] || exit 0

TYPE=$(bp_json_get "$PAYLOAD" tool_input.subagent_type 2>/dev/null)
if [ -z "$TYPE" ]; then
  # Same defensive fallback as track-worker-solo.sh (spec §2.3.1) — required
  # here too: a return whose subagent_type is missing must not be treated as
  # "not a writer" purely because the field didn't resolve, or a real writer's
  # own return would never clear its marker either.
  DESC=$(bp_json_get "$PAYLOAD" tool_input.description tool_input.prompt 2>/dev/null)
  DESC="${DESC:0:200}"
  case "$DESC" in
    *bp-implementer*)  TYPE='bp-implementer' ;;
    *bp-test-writer*)  TYPE='bp-test-writer' ;;
    *bp-ui-prober*)    TYPE='bp-ui-prober' ;;
    *)                 TYPE='' ;;
  esac
fi
case "$TYPE" in
  *bp-implementer*|*bp-test-writer*|*bp-ui-prober*) : ;;
  *) exit 0 ;;   # a non-writer return (e.g. bp-scout) never clears anything
esac

SESSION_SIDECAR="$MARKER.session"
if [ -f "$SESSION_SIDECAR" ]; then
  RECORDED_SESSION=$(cat "$SESSION_SIDECAR" 2>/dev/null || true)
  SESSION=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null)
  SESSION="${SESSION:-nosession}"
  [ "$SESSION" = "$RECORDED_SESSION" ] || exit 0   # a different session's return: leave it live
fi

rm -f "$MARKER" "$SESSION_SIDECAR" 2>/dev/null || true
exit 0
