#!/usr/bin/env bash
# guard-blueprint-write.sh — PreToolUse hook (b43-blueprint-write-api).
#
# Denies a direct Write/Edit/MultiEdit/NotebookEdit targeting any blueprint.md path,
# forcing every mutation through bp-blueprint.pl's typed, validated, atomic write API
# (add-package/set-status/set-deps/add-decision/set-field). Every hand-splice of
# blueprint.md to date has been correct by luck, never by construction (b43 spec
# preamble) — this hook is what makes "correct by construction" the only legal path.
#
# Deliberately UNLIKE ledger-guard.sh/guard-writes.sh: this hook does NOT call
# bp_hook_gate and is NOT scoped to a coordinator session. A hand-edit to
# blueprint.md is dangerous in ANY session, not only inside a running coordinator,
# and the b43 oracle (t/86) invokes this hook directly with no BP_* env vars set —
# gating on BP_LEDGER here would make every G9 assertion vacuously pass (always
# allow) rather than actually proving denial.
#
# Must NOT deny the API's own writer: bp-blueprint.pl is invoked via Bash, and this
# hook only inspects Write/Edit/MultiEdit/NotebookEdit tool_name payloads, so a Bash
# invocation of the writer is never even inspected -- it exits 0 immediately.
#
# Exit 0 = allow. Exit 2 = block; stderr fed back to the model.
set -u

command -v jq >/dev/null 2>&1 || {
  echo "BLUEPRINT-GUARD: BLOCKED — jq is required but missing; blocking to avoid unenforced operation. Install jq in the container." >&2
  exit 2
}

PAYLOAD=$(cat)

TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null)
case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FP=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$PAYLOAD" 2>/dev/null)
[ -n "$FP" ] || exit 0

CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD" 2>/dev/null)
[ -n "$CWD" ] || CWD=$PWD
case "$FP" in
  /*) ABS="$FP" ;;
  *)  ABS="$CWD/$FP" ;;
esac
ABS=$(realpath -m "$ABS" 2>/dev/null || printf '%s' "$ABS")

case "$ABS" in
  */blueprint.md)
    printf '%s\n' "BLUEPRINT-GUARD: BLOCKED — a direct $TOOL to $ABS is not permitted; blueprint.md must be mutated only through plugins/butler/scripts/bp-blueprint.pl (add-package, set-status, set-deps, add-decision, set-field), which validates and writes atomically under flock. Use bp-blueprint.pl via Bash instead, then retry." >&2
    exit 2
    ;;
  *) exit 0 ;;
esac
