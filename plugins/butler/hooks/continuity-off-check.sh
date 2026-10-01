#!/usr/bin/env bash
# continuity-off-check.sh -- writes command tickets for butler-continuity, butler-hold, butler-fork-ok and almanac-bug (package 12, 12-bug-claimant-and-triaging); flags an operator-typed /butler:continuity off. Logic in BpHook/ContinuityOffCheck.pm.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" ContinuityOffCheck --pre text:butler-continuity,text:butler-hold,text:butler-fork-ok,text:almanac -- "$@"
