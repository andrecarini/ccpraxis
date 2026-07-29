#!/usr/bin/env bash
# repeat-guard.sh — PreToolUse mechanical repeat-command guard (b10).
#
# Hashes (tool_name, normalised tool_input), appends the hash to a bounded
# per-session, per-package rolling window under $BP_DIR/runs/, and counts the
# TRAILING CONSECUTIVE run of that hash. When the run reaches a threshold, it
# emits one advisory block (exit 2 + stderr) and gets out of the way. See
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b10-repeat-command-guard-spec.md
# for the full contract (§2.4 is this script's pseudocode; this is the
# implementation of it).
#
# FAIL-OPEN IS ABSOLUTE: the only non-zero exit this hook may ever produce is
# the deliberate `exit 2` of a confirmed detection. No `set -e` at top level;
# `set -u` applies only inside the guarded command substitution below, whose
# non-zero status is swallowed by `|| RESULT=""`. Do NOT use
# bp_hook_require_jq (fail-CLOSED) or a `trap ... EXIT` (would clobber the
# deliberate exit 2).
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate                                    # inert outside a butler session

command -v jq >/dev/null 2>&1 || exit 0         # fail-OPEN; NOT bp_hook_require_jq

ACTION=$(bp_repeat_action_of "${BP_REPEAT_ACTION:-}")

PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# Everything that can fail runs inside one command substitution whose
# non-zero status is swallowed. It emits either "" (=> allow) or
# "fire<TAB>TOOL<TAB>RUNLEN".
RESULT=$( set -u
  TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
  [ -n "$TOOL" ] || exit 0

  HASH=$(bp_repeat_hash <<<"$PAYLOAD") || exit 0
  [ -n "$HASH" ] || exit 0

  SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
  TOKEN=$(bp_repeat_session_token "$SID")
  FILE=$(bp_repeat_state_path "$TOKEN")

  THRESH=$(bp_repeat_config_int "${BP_REPEAT_THRESHOLD:-}" 4 2)
  WIN=$(bp_repeat_config_int "${BP_REPEAT_WINDOW:-}" 64 1)
  SECS=$(bp_repeat_config_int "${BP_REPEAT_WINDOW_SECONDS:-}" 300 0)

  NOW=$(date +%s) || exit 0
  [ -n "$NOW" ] || exit 0

  read -r RUNLEN FIRED < <(bp_repeat_runlen "$HASH" "$NOW" "$SECS" < "$FILE" 2>/dev/null \
                            || bp_repeat_runlen "$HASH" "$NOW" "$SECS" < /dev/null)

  VERDICT=$(bp_repeat_verdict "$RUNLEN" "$FIRED" "$THRESH" "$ACTION")
  NEWFIRED=0
  [ "$VERDICT" = fire ] && NEWFIRED=1

  RETAIN=$WIN
  [ "$THRESH" -gt "$RETAIN" ] && RETAIN=$THRESH

  # Append + trim atomically; if this fails, we MUST NOT fire (RULING 4).
  mkdir -p "$(dirname "$FILE")" 2>/dev/null || exit 0

  # A state path that is a directory (not a plain file) can never be safely
  # overwritten by an atomic rename -- treat as an unwritable state and bail.
  if [ -e "$FILE" ] && [ ! -f "$FILE" ]; then
    exit 0
  fi

  LINE_RE=$'^[0-9]+\t[^\t]+\t[01]$'
  declare -a OLDLINES=()
  if [ -f "$FILE" ]; then
    while IFS= read -r oline || [ -n "$oline" ]; do
      [[ "$oline" =~ $LINE_RE ]] && OLDLINES+=("$oline")
    done < "$FILE" 2>/dev/null
  fi
  OLDLINES+=("$(printf '%s\t%s\t%s' "$NOW" "$HASH" "$NEWFIRED")")

  TOTAL=${#OLDLINES[@]}
  START=0
  [ "$TOTAL" -gt "$RETAIN" ] && START=$(( TOTAL - RETAIN ))

  TMP="$FILE.tmp.$$"
  : > "$TMP" 2>/dev/null || exit 0
  IDX=$START
  while [ "$IDX" -lt "$TOTAL" ]; do
    printf '%s\n' "${OLDLINES[$IDX]}" >> "$TMP" 2>/dev/null || exit 0
    IDX=$(( IDX + 1 ))
  done
  mv "$TMP" "$FILE" 2>/dev/null || { rm -f "$TMP" 2>/dev/null; exit 0; }

  [ "$VERDICT" = fire ] && printf 'fire\t%s\t%s\n' "$TOOL" "$RUNLEN"
  exit 0
) || RESULT=""

case "$RESULT" in
  fire*)
    IFS=$'\t' read -r _ FTOOL FRUNLEN <<<"$RESULT"
    echo "REPEAT-GUARD: this is identical call #$FRUNLEN in a row to $FTOOL with identical arguments — nothing changed between them, so this one will not change anything either. Do NOT retry it. Change approach: inspect the actual output you already have, try a different command, or record the blocker under '## Next action' in the ledger and stop. (This advisory fires once; an immediate retry is allowed. Tune with BP_REPEAT_THRESHOLD / disable with BP_REPEAT_ACTION=off.)" >&2
    exit 2
    ;;
esac
exit 0
