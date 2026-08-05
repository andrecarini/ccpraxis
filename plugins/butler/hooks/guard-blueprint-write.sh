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
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY. bp_hook_gate is deliberately NOT called here --
# see the header above; sourcing lib.sh does not call it.
source "$HOOK_DIR/lib.sh"

PAYLOAD=$(cat)

# bp_json_get prefers jq and falls back to perl+JSON::PP, so this guard also runs
# on the jq-less Windows host. It used to `command -v jq || exit 2`, which meant
# that on the host it blocked EVERY Edit/Write in EVERY session rather than
# guarding blueprint.md. Only the total absence of BOTH parsers still fails closed.
TOOL=$(bp_json_get "$PAYLOAD" tool_name) || {
  echo "BLUEPRINT-GUARD: BLOCKED -- no JSON parser available (neither jq nor perl+JSON::PP); blocking to avoid unenforced operation." >&2
  exit 2
}
case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

FP=$(bp_json_get "$PAYLOAD" tool_input.file_path tool_input.notebook_path)
[ -n "$FP" ] || exit 0

CWD=$(bp_json_get "$PAYLOAD" cwd)
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
