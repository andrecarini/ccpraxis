#!/usr/bin/env bash
# record-denial.sh -- PermissionDenied hook (never-halt package 06). Logic
# lives in BpHook/PromptWatch.pm; contract in docs/hook-architecture.md.
# Record-only: prints nothing, never blocks.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
exec bash "$d/run-hook.sh" PromptWatch --pre ledger,driver -- denial "$@"
