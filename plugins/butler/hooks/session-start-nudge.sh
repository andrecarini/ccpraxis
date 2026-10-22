#!/usr/bin/env bash
# session-start-nudge.sh -- the one SessionStart route (blueprint
# where-things-go, package 10-gatherer-and-digest; originally never-halt
# package 12, Decision 43: N6, N1-now). Logic lives in
# BpHook/SessionStartNudge.pm; contract in docs/hook-architecture.md. Runs on
# every source (startup, resume, clear, compact), armed or not: re-attach,
# then the project digest, then the armed nudges -- at most one
# additionalContext line; never blocks.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" SessionStartNudge -- "$@"
