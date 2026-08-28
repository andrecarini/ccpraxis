#!/usr/bin/env bash
# track-worker-solo.sh — PreToolUse hook for Task|Agent, INTERACTIVE drive-solo
# sessions only.
#
# Implements
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/w03-validation-interlock-spec.md
# §2.3. Feeds guard-validation-interlock.sh's interactive branch: records a
# write-capable worker dispatch to $DATA/.drive-solo/.active-worker so the
# interlock has something to read. Mirrors mark-wakeup.sh's inverse gate
# (fires only when BP_LEDGER is UNSET — headless coordinators are already
# covered by track-dispatch.sh), never mark-wakeup.sh's regular bp_hook_gate.
#
# NEVER blocks anything — recording only, same posture as mark-wakeup.sh.
# Does NOT enforce "one write-capable worker at a time" interactively —
# drive-solo's own documented discipline is the driver's job, not a hook's;
# re-litigating that serialization is out of this package's scope.
#
# fixbatch step7 / F1: also drops a session-id sidecar (MARKER.session) next
# to the marker, so untrack-worker-solo.sh can refuse to clear a marker armed
# by a DIFFERENT session (e.g. a second terminal in the same project). The
# marker's own content format is UNCHANGED (still just TYPE) — the sidecar is
# additive so a marker written directly by a test fixture (no sidecar) keeps
# clearing exactly as before; only a track/untrack pair that both went
# through these two hooks gets the extra scoping.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

# Coordinators: track-dispatch.sh already covers this surface.
[ -n "${BP_LEDGER:-}" ] && exit 0

bp_read_payload open
CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null); CWD=${CWD:-$PWD}
DATA=$(bp_find_data_dir "$CWD" 2>/dev/null) || exit 0
[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0

TYPE=$(bp_json_get "$PAYLOAD" tool_input.subagent_type 2>/dev/null)
if [ -z "$TYPE" ]; then
  # ⚠ UNVERIFIED, inherited from h01 (spec §2.3.1) — defensive fallback only.
  # A marker that is never written recreates the exact gap this package
  # exists to close; a marker written on a slightly over-eager match only
  # costs a delayed validation retry — biased toward the cheaper mistake.
  DESC=$(bp_json_get "$PAYLOAD" tool_input.description tool_input.prompt 2>/dev/null)
  DESC="${DESC:0:200}"
  case "$DESC" in
    *bp-implementer*)  TYPE='bp-implementer' ;;
    *bp-test-writer*)  TYPE='bp-test-writer' ;;
    *bp-ui-prober*)    TYPE='bp-ui-prober' ;;
    *)                 TYPE='' ;;
  esac
fi
[ -n "$TYPE" ] || exit 0

case "$TYPE" in
  *bp-implementer*|*bp-test-writer*|*bp-ui-prober*) : ;;
  *) exit 0 ;;
esac

MARKER="$DATA/.drive-solo/.active-worker"
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || exit 0
printf '%s' "$TYPE" > "$MARKER" 2>/dev/null || true

# fixbatch step7 / F1: record which session armed it. SESSION is whatever the
# payload carries (a UUID in real Claude Code sessions); "nosession" when
# absent, so an absent session_id never accidentally matches another absent one
# under a stricter comparison later — untrack treats "nosession" like any other
# concrete value, not as a wildcard.
SESSION=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null)
SESSION="${SESSION:-nosession}"
printf '%s' "$SESSION" > "$MARKER.session" 2>/dev/null || true
exit 0
