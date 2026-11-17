#!/usr/bin/env bash
# guard-sleep-control.sh -- denies a Bash-tool command that changes the
# machine's sleep behaviour by hand (caffeinate in any spelling, pmset writes,
# powercfg changes, systemd-inhibit, SetThreadExecutionState through
# PowerShell, a hand-started keep-awake holder) and names the one sanctioned
# path: arming continuity, whose lease holds and releases the managed
# wake-lock. Every session, main thread and subagents. Logic in
# BpHook/Guards/GuardSleepControl.pm; contract in docs/hook-architecture.md.
# The prefilter is case-insensitive (itext:): macOS and Windows find commands
# case-insensitively, so "CAFFEINATE" runs caffeinate there. "keepawake.p"
# covers bp-keepawake.pl and KeepAwake.pm. An ordinary command names none of
# these and exits in bash before perl starts.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" Guards::GuardSleepControl --pre itext:caffeinate,itext:pmset,itext:powercfg,itext:systemd-inhibit,itext:setthreadexecutionstate,itext:keep-awake.ps1,itext:keepawake.p -- "$@"
