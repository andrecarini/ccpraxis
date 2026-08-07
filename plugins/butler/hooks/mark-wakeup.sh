#!/usr/bin/env bash
# mark-wakeup.sh — PreToolUse hook for Task and Bash, in a DRIVE-SOLO DRIVER
# session (never in a coordinator).
#
# Records that this turn started something that will wake the session up again:
#   * any Task dispatch (a subagent; its completion notification comes back), or
#   * a Bash call with run_in_background=true (its exit notification comes back).
#
# gate-drive-loop.sh (Stop) CONSUMES this marker. The pair encodes one rule:
#
#     A driver turn may end EITHER because something will wake it,
#     OR because the director says the run is settled. Never for any
#     other reason.
#
# Why this exists. /butler:drive-solo describes the driver as "a thin loop over
# the director": call `bp-drive-next.pl next`, dispatch the action it returns,
# call `next` again. That is prose, and prose decays over a long context. The
# observed failure — three times in one 12-hour run on 2026-08-07 — is a turn
# that ends right after a ledger write, with text promising the next step and
# nothing scheduled to perform it. A dispatched agent notifies; a finished Bash
# call does not. So the run dies silently, mid-package, looking finished.
#
# This is the same argument gate-stop.sh already makes for coordinators ("converts
# ledger discipline from a prompt rule (which decays over long contexts) into a
# mechanical gate"), and the same one guard-git-mutations.sh makes in this repo's
# CLAUDE.md: a written instruction is not an enforcement mechanism.
#
# NEVER blocks anything: it only writes a marker. Exit 0 on every path.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

# Coordinator sessions are gate-stop.sh's business, not ours. BP_LEDGER is
# exported only into coordinator processes, so its ABSENCE is what identifies
# an interactive driver.
[ -n "${BP_LEDGER:-}" ] && exit 0

PAYLOAD=$(cat 2>/dev/null || true)

# Resolve the drive-solo state dir exactly as bp-drive-next.pl does: an explicit
# CCPRAXIS_DATA_DIR wins, else <project>/.ccpraxis-local-data. No .drive-solo dir
# means no drive-solo run is in progress here and this hook is irrelevant.
CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null || true); CWD=${CWD:-$PWD}
DATA="${CCPRAXIS_DATA_DIR:-}"
if [ -z "$DATA" ]; then
  d=$CWD
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -d "$d/.ccpraxis-local-data" ] && { DATA="$d/.ccpraxis-local-data"; break; }
    d=$(dirname "$d")
  done
fi
[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0

TOOL=$(bp_json_get "$PAYLOAD" tool_name 2>/dev/null || true)

case "$TOOL" in
  Task)
    : ;;                                  # always a wake-up
  Bash)
    # Only a BACKGROUNDED Bash call schedules a wake-up. A foreground command
    # returns into the same turn and schedules nothing, so it must not count.
    #
    # Matched with a raw regex rather than bp_json_get: run_in_background is a
    # JSON *boolean*, and bp_json_get returns EMPTY for booleans (verified
    # 2026-08-07 — it resolves string scalars only). Using it here would have
    # silently classified every backgrounded Bash call as foreground, so the
    # gate would have blocked turns that legitimately scheduled a wake-up.
    printf '%s' "$PAYLOAD" | grep -q '"run_in_background"[[:space:]]*:[[:space:]]*true' || exit 0 ;;
  *)
    exit 0 ;;
esac

mkdir -p "$DATA/.drive-solo" 2>/dev/null || exit 0
printf '%s %s\n' "$TOOL" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
  > "$DATA/.drive-solo/.wakeup-pending" 2>/dev/null || true
exit 0
