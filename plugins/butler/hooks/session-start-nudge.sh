#!/usr/bin/env bash
# session-start-nudge.sh -- SessionStart nudge (never-halt package 12, Decision 43: N6, N1-now).
# Logic lives in BpHook/SessionStartNudge.pm; contract in docs/hook-architecture.md. Prints at
# most one additionalContext line on an armed session's compact or resume; never blocks.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" SessionStartNudge --pre armed -- "$@"
