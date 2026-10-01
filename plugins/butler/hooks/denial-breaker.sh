#!/usr/bin/env bash
# denial-breaker.sh -- PreToolUse/PostToolUse/PostToolUseFailure circuit
# breaker (never-halt package 07). Logic lives in BpHook/DenialBreaker.pm;
# contract in docs/hook-architecture.md. Deny-only: prints nothing on
# abstain, denies via exit 2 with a short stderr message when a driver or
# coordinator agent's auto-mode denial budget is nearly exhausted.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" DenialBreaker --pre ledger,driver -- "$@"
