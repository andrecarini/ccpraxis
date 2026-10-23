#!/usr/bin/env bash
# guard-continuity-state.sh -- steers an agent away from hand-editing the
# continuity state dir or its own transcript, toward butler-continuity and
# butler-hold (guidance, not a security boundary). Logic in
# BpHook/Guards/GuardContinuityState.pm; contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GuardContinuityState --pre text:continuity,text:Continuity,text:CONTINUITY -- "$@"
