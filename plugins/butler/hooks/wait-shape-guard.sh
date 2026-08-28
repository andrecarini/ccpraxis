#!/usr/bin/env bash
# wait-shape-guard.sh — PreToolUse guard for four wait/poll pathologies b10's exact-repeat
# hash structurally cannot see (b15). See
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b15-wait-shape-and-pipe-guards-spec.md
# for the full contract (§2.13 is this file's pseudocode).
#
# D1 (§2.1): pure helpers live at top level so this file can be SOURCED (no enforcement,
# no I/O, no exit) for unit testing, and the enforcement body runs only when EXECUTED via
# bp_ws_main, invoked from the mandated bottom-of-file main-guard idiom.
#
# D7 (§2.7): FAIL-OPEN on every infrastructure uncertainty (missing jq, bad payload,
# unwritable state, unextractable id) — never a deny. Only a confirmed detection produces
# `exit 2`. No top-level error trap of any kind is used, since one would clobber that
# deliberate exit 2. The fail-CLOSED jq-requiring helper from lib.sh is deliberately unused.

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

# --- §2.3 R1: the wait-shape matcher (verbatim, mandated) --------------------------------
BP_WS_LOOP_RE='(^|[^A-Za-z0-9_-])(while|until|for)[[:space:]]'
BP_WS_SLEEP_RE='(^|[^A-Za-z0-9_-])sleep[[:space:]]+[0-9]'

# --- §2.4 R2: the false-green-pipe matcher (verbatim, mandated) --------------------------
BP_WS_PIPE_RE='\|[[:space:]]*(tail|head)([[:space:]][^;&|]*)?[;&]+[^;&|]*\$\?'

# --- §2.5 R3b: the task-output artifact poll matcher (verbatim, mandated) ----------------
BP_WS_TASKOUT_RE='tasks/[A-Za-z0-9_-]+\.output'

# bp_ws_is_wait_loop CMD -> yes|no. PURE.
bp_ws_is_wait_loop() {
  local cmd="$1"
  if grep -Eq "$BP_WS_LOOP_RE" <<<"$cmd" && grep -Eq "$BP_WS_SLEEP_RE" <<<"$cmd"; then
    printf '%s\n' yes
  else
    printf '%s\n' no
  fi
}

# bp_ws_is_false_green_pipe CMD -> yes|no. PURE. Flattens newlines to ';' first (§5.1).
bp_ws_is_false_green_pipe() {
  local cmd="$1" flat
  flat=$(printf '%s' "$cmd" | tr '\n\r' ';;')
  if grep -Eq "$BP_WS_PIPE_RE" <<<"$flat"; then
    printf '%s\n' yes
  else
    printf '%s\n' no
  fi
}

# bp_ws_is_task_artifact_poll CMD -> yes|no. PURE.
bp_ws_is_task_artifact_poll() {
  local cmd="$1"
  if grep -Eq "$BP_WS_TASKOUT_RE" <<<"$cmd" && grep -Eq "$BP_WS_SLEEP_RE" <<<"$cmd"; then
    printf '%s\n' yes
  else
    printf '%s\n' no
  fi
}

# bp_ws_action_of RAW -> deny|off. PURE. C-5 inversion of bp_repeat_action_of: any
# unrecognised value -> deny (a typo must never silently disarm this guard).
bp_ws_action_of() {
  local raw="$1"
  case "$raw" in
    off) printf '%s\n' off ;;
    *)   printf '%s\n' deny ;;
  esac
}

# bp_ws_state_path TOKEN -> $BP_DIR/runs/${BP_PACKAGE:-pkg}.taskpoll-<TOKEN>.log. PURE
# apart from env vars. Deliberately a distinct filename from b10's own state helper (§2.6).
bp_ws_state_path() {
  local token="$1"
  printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.taskpoll-${token}.log"
}

# bp_ws_count_window TASKTOK NOW WINDOW_SECONDS (state lines TS<TAB>TASKTOK on stdin)
# -> integer >= 1. PURE apart from stdin. Cumulative count within a window, never breaks
# the scan on a mismatch (§2.2/§2.6 — the deliberate divergence from b10's trailing run).
bp_ws_count_window() {
  local tasktok="$1" now="$2" winsecs="$3"
  case "$now" in
    ''|*[!0-9]*) printf '%s\n' 1; return 0 ;;
  esac
  case "$winsecs" in
    ''|*[!0-9]*) printf '%s\n' 1; return 0 ;;
  esac
  local count=1
  local re=$'^([0-9]+)\t([^\t]+)$'
  local line ts tok
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $re ]]; then
      ts="${BASH_REMATCH[1]}"; tok="${BASH_REMATCH[2]}"
      [ "$tok" = "$tasktok" ] || continue
      if [ "$winsecs" -gt 0 ] 2>/dev/null; then
        (( now - ts <= winsecs )) || continue
      fi
      count=$(( count + 1 ))
    fi
  done
  printf '%s\n' "$count"
}

# §2.10 D9: one line on stderr, the mandated prefix, the command echoed back — flattened
# (newline/CR/tab -> single space) and truncated to 200 chars with an ASCII '...' marker.
BP_WS_PREFIX="WAIT-SHAPE-GUARD: BLOCKED $(printf '\xe2\x80\x94') "

bp_ws_flatten_cmd() {
  local cmd="$1"
  printf '%s' "$cmd" | tr '\n\r\t' '   '
}

bp_ws_truncate_cmd() {
  local flat="$1"
  if [ "${#flat}" -gt 200 ]; then
    printf '%s' "${flat:0:200}..."
  else
    printf '%s' "$flat"
  fi
}

bp_ws_deny_r1() {
  local cmd="$1" flat trunc
  flat=$(bp_ws_flatten_cmd "$cmd")
  trunc=$(bp_ws_truncate_cmd "$flat")
  printf '%s' "${BP_WS_PREFIX}wait-loop: this command polls in a shell loop (a while/until/for containing a sleep). Waiting this way burns your turn budget and your context and produces no information. Do not poll: run the work in the FOREGROUND and read its result, or dispatch it and let the completion notification come back to you, or record what you are waiting for under '## Next action' in the ledger and stop. See the waiting discipline in plugins/butler/skills/coordinator-protocol/SKILL.md. Command: ${trunc}" >&2
  echo >&2
  exit 2
}

bp_ws_deny_r2() {
  local cmd="$1" flat trunc
  flat=$(bp_ws_flatten_cmd "$cmd")
  trunc=$(bp_ws_truncate_cmd "$flat")
  printf '%s' "${BP_WS_PREFIX}false-green-pipe: this pipes a command into tail/head and then reads \$?, which is the exit status of tail/head, not of the command $(printf '\xe2\x80\x94') a failing command reads as green. Correct form: run it unpiped and capture the status on the very next statement, e.g. cmd > /tmp/out.txt 2>&1; echo \"exit=\$?\"; tail -20 /tmp/out.txt. A command substitution also preserves the status: out=\$(cmd 2>&1); rc=\$?. See the waiting discipline in plugins/butler/skills/coordinator-protocol/SKILL.md. Command: ${trunc}" >&2
  echo >&2
  exit 2
}

bp_ws_deny_r3b() {
  local cmd="$1" flat trunc
  flat=$(bp_ws_flatten_cmd "$cmd")
  trunc=$(bp_ws_truncate_cmd "$flat")
  printf '%s' "${BP_WS_PREFIX}task-output-poll: this command sleeps while probing a subagent's tasks/<id>.output transcript. That file is the subagent's full JSONL stream: reading it overflows your context, and watching it grow tells you nothing you can act on. Wait for the worker's own report file instead, or record what you are waiting for under '## Next action' in the ledger and stop. See the waiting discipline in plugins/butler/skills/coordinator-protocol/SKILL.md. Command: ${trunc}" >&2
  echo >&2
  exit 2
}

bp_ws_deny_r3a() {
  local n="$1" idtok="$2" win="$3"
  printf '%s' "${BP_WS_PREFIX}task-output-poll: this is TaskOutput call #${n} against task ${idtok} within the last ${win} seconds. The arguments differ between these calls but the target does not, so this is polling. This SUPERSEDES the REPEAT-GUARD advisory's \"keep polling with those\" carve-out for repeated polls at one target: that carve-out covers waiting, not re-reading the same target. Stop polling this task: wait for its report file, or record what you are waiting for under '## Next action' in the ledger and stop. See the waiting discipline in plugins/butler/skills/coordinator-protocol/SKILL.md. Target: task ${idtok}" >&2
  echo >&2
  exit 2
}

# bp_ws_main — the enforcement body (§2.13). Runs ONLY when this file is executed, never
# when sourced. Exits 0 or 2, always.
bp_ws_main() {
  bp_hook_gate                                     # inert outside a butler session

  # t09 (guard-hooks-stripping). THREAT MODEL: ACCIDENT, not ADVERSARY -- same
  # ruling already on record for mark-wakeup.sh/guard-validation-interlock.sh,
  # not re-derived here. This hook's real defect is a FALSE POSITIVE: a
  # while/sleep or tail/head-pipe shape merely QUOTED inside a doc string
  # (e.g. an echoed anti-pattern example) reads identically to a real
  # wait-loop under a raw grep. Residual left knowingly unfixed: a BARE,
  # unquoted MENTION (no reader-veto added -- spec SS6 out-of-scope).
  #
  # Sourced LAZILY here, inside bp_ws_main, never at file scope -- t/67
  # sources this file itself to unit-test the pure matcher helpers (D1), and
  # a file-scope source would run on every such sourcing, not only on real
  # enforcement.
  #
  # NOTE this is NOT D7. D7 (this file's own header) is fail-OPEN on
  # INFRASTRUCTURE uncertainty -- missing jq, bad payload, unwritable state,
  # unextractable id -- none of which stripping touches. Stripping-
  # unavailable degrades to the EXISTING raw-match behavior (a narrower,
  # already-understood fallback), never to a NEW fail-open path; D7's scope
  # does not extend to this layer.
  # shellcheck source=../scripts/bp-lib.sh
  [ -r "$HOOK_DIR/../scripts/bp-lib.sh" ] && source "$HOOK_DIR/../scripts/bp-lib.sh"

  local action
  action=$(bp_ws_action_of "${BP_WAITSHAPE_ACTION:-}")
  [ "$action" = off ] && exit 0

  command -v jq >/dev/null 2>&1 || exit 0          # fail-OPEN posture (D7); no fail-closed helper

  # BOUNDED read (lib.sh:bp_read_payload). `$(cat)` here was unbounded: with
  # stdin an inherited pipe that never closes it blocked forever at no CPU --
  # see bug report 20260828-095201-7c1e. 'open' preserves this hook's own
  # documented D7 fail-OPEN posture, the same direction the `|| exit 0` it
  # replaces already chose.
  #
  # Called from bp_ws_main, which the bottom-of-file main-guard invokes BARE --
  # not inside $(...) -- so the helper's exit reaches the process, as it must.
  local payload
  bp_read_payload open
  payload="$PAYLOAD"
  [ -n "$payload" ] || exit 0

  local tool
  tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null) || exit 0
  [ -n "$tool" ] || exit 0

  case "$tool" in
    Bash)
      local cmd
      cmd=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) || exit 0
      [ -n "$cmd" ] || exit 0

      # Fail direction: above BP_GUARD_MAX_STRIP_BYTES, or when
      # bp_strip_shell_noise is unavailable/empty, MATCH_TEXT stays the RAW
      # command -- never skip the match itself (see rationale above).
      local match_text="$cmd"
      : "${BP_GUARD_MAX_STRIP_BYTES:=8000}"
      case "$BP_GUARD_MAX_STRIP_BYTES" in
        ''|*[!0-9]*) BP_GUARD_MAX_STRIP_BYTES=8000 ;;
      esac
      if [ "${#cmd}" -le "$BP_GUARD_MAX_STRIP_BYTES" ] && command -v bp_strip_shell_noise >/dev/null 2>&1; then
        local stripped
        stripped=$(printf '%s' "$cmd" | bp_strip_shell_noise)
        [ -n "$stripped" ] && match_text="$stripped"
      fi

      [ "$(bp_ws_is_wait_loop "$match_text")" = yes ] && bp_ws_deny_r1 "$cmd"
      [ "$(bp_ws_is_task_artifact_poll "$match_text")" = yes ] && bp_ws_deny_r3b "$cmd"
      [ "$(bp_ws_is_false_green_pipe "$match_text")" = yes ] && bp_ws_deny_r2 "$cmd"
      exit 0
      ;;
    TaskOutput)
      local taskid
      taskid=$(jq -r '.tool_input.task_id // .tool_input.taskId // .tool_input.id // empty' <<<"$payload" 2>/dev/null) || exit 0
      [ -n "$taskid" ] || exit 0

      local idtok
      idtok=$(bp_repeat_session_token "$taskid")

      local sid token
      sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
      token=$(bp_repeat_session_token "$sid")

      local file
      file=$(bp_ws_state_path "$token")

      # F4 (b10 precedent): type-check the state path before any read -- a FIFO would
      # hang the read forever; a directory can never be safely rename()'d over either.
      if [ -e "$file" ] && [ ! -f "$file" ]; then
        exit 0
      fi

      local thresh win
      thresh=$(bp_repeat_config_int "${BP_WAITSHAPE_TASKPOLL_THRESHOLD:-}" 6 2)
      win=$(bp_repeat_config_int "${BP_WAITSHAPE_TASKPOLL_WINDOW_SECONDS:-}" 600 0)

      local now
      now=$(date +%s) || exit 0
      [ -n "$now" ] || exit 0

      local count
      if [ -f "$file" ]; then
        count=$(bp_ws_count_window "$idtok" "$now" "$win" < "$file" 2>/dev/null)
      else
        count=$(bp_ws_count_window "$idtok" "$now" "$win" < /dev/null)
      fi
      [ -n "$count" ] || exit 0

      # Append + trim atomically (b10's pattern); any failure at any step -> exit 0.
      mkdir -p "$(dirname "$file")" 2>/dev/null || exit 0

      local line_re=$'^[0-9]+\t[^\t]+$'
      local -a oldlines=()
      if [ -f "$file" ]; then
        local oline
        while IFS= read -r oline || [ -n "$oline" ]; do
          [[ "$oline" =~ $line_re ]] && oldlines+=("$oline")
        done < "$file" 2>/dev/null
      fi
      oldlines+=("$(printf '%s\t%s' "$now" "$idtok")")

      local total=${#oldlines[@]}
      local retain=256
      local start=0
      [ "$total" -gt "$retain" ] && start=$(( total - retain ))

      local tmp="$file.tmp.$$"
      : > "$tmp" 2>/dev/null || exit 0
      local idx=$start
      while [ "$idx" -lt "$total" ]; do
        printf '%s\n' "${oldlines[$idx]}" >> "$tmp" 2>/dev/null || exit 0
        idx=$(( idx + 1 ))
      done
      mv "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; exit 0; }

      if [ "$count" -ge "$thresh" ] 2>/dev/null; then
        bp_ws_deny_r3a "$count" "$idtok" "$win"
      fi
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
}

# The enforcement body runs only when EXECUTED, never when sourced (C-2): t/67 sources
# this file to unit-test the pure matchers, and bp_hook_gate inside bp_ws_main exits.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  bp_ws_main
fi
