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

bp_read_payload open
[ -n "$PAYLOAD" ] || exit 0

# Everything that can fail runs inside one command substitution whose
# non-zero status is swallowed. It emits either "" (=> allow) or
# "fire<TAB>TOOL<TAB>RUNLEN".
RESULT=$( set -u
  TOOL=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null) || exit 0
  [ -n "$TOOL" ] || exit 0

  # F2: wait/poll tools are the designed use of repeated identical calls -- exempt
  # them BEFORE any hashing or state I/O (an exempt tool must not pay for a hash,
  # and must not touch state). BP_REPEAT_EXEMPT_TOOLS is an ERE matched against the
  # whole tool name; empty/unset falls back to the built-in default list. A
  # malformed ERE must fail open: never exempt, never error, never leak stderr.
  EXEMPT_RE="${BP_REPEAT_EXEMPT_TOOLS:-}"
  [ -n "$EXEMPT_RE" ] || EXEMPT_RE='^(BashOutput|KillShell|Monitor|TaskGet|TaskList|TaskOutput)$'
  if [[ "$TOOL" =~ $EXEMPT_RE ]] 2>/dev/null; then
    exit 0
  fi

  HASH=$(bp_repeat_hash <<<"$PAYLOAD") || exit 0
  [ -n "$HASH" ] || exit 0

  SID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
  TOKEN=$(bp_repeat_session_token "$SID")
  FILE=$(bp_repeat_state_path "$TOKEN")

  # F4: type-check the state path BEFORE reading it (a FIFO would hang the read
  # forever; a symlink to a device node must not be treated as regular state).
  # A state path that is a directory (not a plain file) can never be safely
  # overwritten by an atomic rename either -- treat all of these as an
  # unwritable/unreadable state and bail out, fail-open.
  if [ -e "$FILE" ] && [ ! -f "$FILE" ]; then
    exit 0
  fi

  THRESH=$(bp_repeat_config_int "${BP_REPEAT_THRESHOLD:-}" 4 2)
  WIN=$(bp_repeat_config_int "${BP_REPEAT_WINDOW:-}" 64 1)
  SECS=$(bp_repeat_config_int "${BP_REPEAT_WINDOW_SECONDS:-}" 300 0)

  NOW=$(date +%s) || exit 0
  [ -n "$NOW" ] || exit 0

  # F6: only ever redirect from $FILE when it actually exists as a regular file
  # (checked above) -- attempting `< "$FILE"` on a nonexistent path leaks a
  # "No such file or directory" message to stderr BEFORE the command's own
  # `2>/dev/null` redirection takes effect, which broke the clean-path guarantee.
  if [ -f "$FILE" ]; then
    read -r RUNLEN FIRED < <(bp_repeat_runlen "$HASH" "$NOW" "$SECS" < "$FILE" 2>/dev/null)
  else
    read -r RUNLEN FIRED < <(bp_repeat_runlen "$HASH" "$NOW" "$SECS" < /dev/null)
  fi

  VERDICT=$(bp_repeat_verdict "$RUNLEN" "$FIRED" "$THRESH" "$ACTION")
  # F3: propagate the fired flag forward so a RETAIN trim can never evict it --
  # the newest entry always carries fired=1 whenever the trailing run has
  # ALREADY fired (by a prior entry) OR fires right now. The flag still dies
  # with the run: bp_repeat_runlen stops walking (and so never reports FIRED=1)
  # once it hits a hash mismatch, so a genuine reset (a different call breaking
  # the trailing run) starts the next run's FIRED back at 0.
  NEWFIRED=0
  [ "$FIRED" = 1 ] && NEWFIRED=1
  [ "$VERDICT" = fire ] && NEWFIRED=1

  RETAIN=$WIN
  [ "$THRESH" -gt "$RETAIN" ] && RETAIN=$THRESH

  # Append + trim atomically; if this fails, we MUST NOT fire (RULING 4).
  mkdir -p "$(dirname "$FILE")" 2>/dev/null || exit 0

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

# F5: the advisory is action-aware and self-consistent -- it must never claim
# both "do NOT retry" and "retry is allowed" at once (deny truly forbids it;
# nudge only lets it through because the guard fires once per run, not because
# retrying is a good idea), must not hand the nudged agent the
# BP_REPEAT_ACTION=off kill switch, must carve out the waiting/polling case
# explicitly, and must frame the collision as "these calls hashed identically"
# rather than asserting as fact that nothing changed (whitespace-only diffs
# can collide to the same hash).
case "$RESULT" in
  fire*)
    IFS=$'\t' read -r _ FTOOL FRUNLEN <<<"$RESULT"
    WAITNOTE="If you are waiting on a background job or polling for output, this advisory does not apply to you — that is what BashOutput/Monitor/TaskGet/TaskList/TaskOutput/KillShell are for; keep polling with those."
    if [ "$ACTION" = deny ]; then
      MSG="REPEAT-GUARD: this is identical call #$FRUNLEN in a row to $FTOOL with identical (normalised) arguments — these calls hashed identically. Do NOT retry it with the same arguments: this configuration blocks every call past the threshold, so a retry will keep being blocked. Change approach instead: inspect the output you already have, try a different command, or record the blocker under '## Next action' in the ledger and stop. $WAITNOTE Tune the threshold with BP_REPEAT_THRESHOLD."
    else
      MSG="REPEAT-GUARD: this is identical call #$FRUNLEN in a row to $FTOOL with identical (normalised) arguments — these calls hashed identically, so this one is unlikely to produce a different result. This advisory fires once per run: change approach now — inspect the output you already have, try a different command, or record the blocker under '## Next action' in the ledger and stop — rather than repeating the same call again. $WAITNOTE Tune the threshold with BP_REPEAT_THRESHOLD."
    fi
    echo "$MSG" >&2
    exit 2
    ;;
esac
exit 0
