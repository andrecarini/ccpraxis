#!/usr/bin/env bash
# ac-standdown-gate.sh -- denies every subagent tool call while an AC-loss
# stand-down is active (package 11 of blueprint tooling-backlog). Registered
# with NO matcher (every tool). Logic in BpHook/Guards/AcStandDown.pm;
# contract in docs/hook-architecture.md.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::AcStandDown --pre acstanddown -- "$@"
