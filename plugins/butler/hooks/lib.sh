#!/usr/bin/env bash
# lib.sh — shared helpers for butler hooks.
#
# Scoping mechanism: every hook calls bp_hook_gate first. The env contract
# (BP_LEDGER etc.) is exported only by bp-launch.sh into coordinator processes,
# so in the orchestrator's interactive session — and in any unrelated session —
# these hooks exit 0 immediately and cost nothing.

bp_hook_gate() {
  [ -n "${BP_LEDGER:-}" ] || exit 0
  [ -n "${BP_DIR:-}" ] || exit 0
  [ -n "${BP_PROJECT_ROOT:-}" ] || exit 0
}

bp_hook_require_jq() {
  # Fail-closed: enforcement hooks must not silently degrade.
  command -v jq >/dev/null 2>&1 || {
    echo "butler hook: jq is required but missing — blocking to avoid unenforced operation. Install jq in the container." >&2
    exit 2
  }
}

# match_any REL_PATH PATTERNS — colon-separated bash-glob patterns,
# '*' crosses '/', trailing '/' means prefix.
match_any() {
  local p="$1" pats="$2" pat
  [ -n "$pats" ] || return 1
  local IFS=':'
  # shellcheck disable=SC2086
  for pat in $pats; do
    [ -n "$pat" ] || continue
    case "$pat" in
      */) if [[ "$p" == "$pat"* || "$p/" == "$pat" ]]; then return 0; fi ;;
      *)  # shellcheck disable=SC2053
          if [[ "$p" == $pat ]]; then return 0; fi ;;
    esac
  done
  return 1
}

marker_path() { printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.active-worker"; }

ledger_lock() { printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.ledger.lock"; }

# --- graceful-stop gate (Decision #10/#18, package A4) -----------------------

# bp_active_stop_signal — which fleet stop signal (if any) is in force for THIS
# coordinator, by precedence (most directive first): a graceful-shutdown-all wins
# over a per-package force-stop wins over a usage/telemetry pause. Echoes one of
# "shutdown" | "forcestop" | "paused" | "" (empty = no stop in progress).
# I/O helper (reads runs/); keep the decision in bp_gate_verdict pure.
bp_active_stop_signal() {
  local runs="$BP_DIR/runs"
  if [ -f "$runs/.shutdown" ]; then printf '%s\n' shutdown; return 0; fi
  if [ -f "$runs/${BP_PACKAGE:-pkg}.force-stop" ]; then printf '%s\n' forcestop; return 0; fi
  if [ -f "$runs/.paused" ]; then printf '%s\n' paused; return 0; fi
  printf '%s\n' ""
}

# bp_gate_verdict TOOL PATHCLASS SIGNAL_ACTIVE -> echoes "allow" | "deny"
# Pure decision (no I/O — unit-tested as the allow-park/deny-work matrix). When a
# fleet stop signal is active, deny NEW work so the coordinator funnels to a clean
# park; always allow the ledger park-write and non-mutating tools (Decision #10).
#   TOOL          : Task | Edit | Write | MultiEdit | NotebookEdit | Bash | <read tools>
#   PATHCLASS     : for edit tools, "ledger" (BP_DIR/tmp park-write) | "worksite"
#                   (project files = new work); "-"/"" for non-path tools
#   SIGNAL_ACTIVE : 1 if any stop signal is in force, else 0
bp_gate_verdict() {
  local tool="$1" pclass="$2" sig="$3"
  [ "$sig" = 1 ] || { printf '%s\n' allow; return 0; }
  case "$tool" in
    Task)
      printf '%s\n' deny ;;                       # no new workers while stopping
    Edit|Write|MultiEdit|NotebookEdit)
      case "$pclass" in
        ledger) printf '%s\n' allow ;;            # the park-write is always permitted
        *)      printf '%s\n' deny ;;             # edits into the worksite are new work
      esac ;;
    *)
      printf '%s\n' allow ;;                       # Bash / read tools: finalize & park
  esac
}

# --- mechanical repeat-command guard (b10) -----------------------------------
#
# Five pure helpers backing repeat-guard.sh. All are sourceable with no
# filesystem or clock access apart from bp_repeat_state_path (env-vars only)
# and bp_repeat_hash (needs jq). See
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b10-repeat-command-guard-spec.md
# §2.3 for the exact contracts these implement.

# bp_repeat_verdict RUNLEN FIRED THRESHOLD ACTION -> echoes "fire" | "pass"
# PURE — no I/O. Any unparseable/missing argument -> pass (fail-open bias).
bp_repeat_verdict() {
  local runlen="$1" fired="$2" thresh="$3" action="$4"

  case "$runlen" in
    ''|*[!0-9]*) printf '%s\n' pass; return 0 ;;
  esac
  case "$thresh" in
    ''|*[!0-9]*) printf '%s\n' pass; return 0 ;;
  esac

  case "$action" in
    off)
      printf '%s\n' pass
      ;;
    deny)
      # deny is sticky: fires on every call past threshold, ignoring FIRED.
      if [ "$runlen" -ge "$thresh" ]; then printf '%s\n' fire; else printf '%s\n' pass; fi
      ;;
    nudge)
      case "$fired" in
        0|1) ;;
        *) printf '%s\n' pass; return 0 ;;
      esac
      if [ "$runlen" -ge "$thresh" ]; then
        if [ "$fired" = 1 ]; then printf '%s\n' pass; else printf '%s\n' fire; fi
      else
        printf '%s\n' pass
      fi
      ;;
    *)
      # unrecognised action -> disabled (a typo must never produce a block)
      printf '%s\n' pass
      ;;
  esac
}

# bp_repeat_runlen HASH NOW WINDOW_SECONDS (window lines on STDIN) -> "RUNLEN FIRED"
# PURE apart from reading stdin — no filesystem, no clock (NOW is a parameter).
# Walks stdin lines newest -> oldest starting from a virtual new entry
# (NOW, HASH, 0). Invalid lines (not matching TS\tHASH\t[01]) are skipped
# without breaking the run. A hash mismatch or a staleness gap (when
# WINDOW_SECONDS > 0) stops the walk.
bp_repeat_runlen() {
  local hash="$1" now="$2" winsecs="$3"
  local runlen=1 fired=0 prevts="$now"
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done
  local re=$'^([0-9]+)\t([^\t]+)\t([01])$'
  local i ts h f
  for (( i=${#lines[@]}-1; i>=0; i-- )); do
    line="${lines[$i]}"
    if [[ "$line" =~ $re ]]; then
      ts="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"; f="${BASH_REMATCH[3]}"
      [ "$h" = "$hash" ] || break
      if [ "$winsecs" -gt 0 ] 2>/dev/null; then
        if (( prevts - ts > winsecs )); then
          break
        fi
      fi
      runlen=$(( runlen + 1 ))
      [ "$f" = 1 ] && fired=1
      prevts="$ts"
    fi
  done
  printf '%s %s\n' "$runlen" "$fired"
}

# bp_repeat_hash (payload on STDIN) -> echoes a hash token, or nothing on failure
# Deterministic, no filesystem writes, but needs jq. Applies the RULING-2(a)
# canonicalisation program (sorted keys, compact, whitespace-scrubbed strings),
# then digests with sha1sum (else cksum). Falls back once to a key-order-only
# canonicalisation if the primary jq program fails (older jq lacking walk/gsub).
bp_repeat_hash() {
  local payload
  payload=$(cat 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1

  local out
  out=$(jq -S -c '
    def scrub: walk(
      if type == "string"
      then (if length > 2048
            then (.[0:2048] | gsub("[[:space:]]+"; " ")) + "#" + (length|tostring)
            else (gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")) end)
      else . end);
    [ (.tool_name // ""), ((.tool_input // {}) | scrub) ]
  ' <<<"$payload" 2>/dev/null)

  if [ -z "$out" ]; then
    out=$(jq -S -c '[.tool_name // "", .tool_input // {}]' <<<"$payload" 2>/dev/null)
  fi
  [ -n "$out" ] || return 1

  local digest=""
  if command -v sha1sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$out" | sha1sum 2>/dev/null)
    digest="${digest%% *}"
  elif command -v cksum >/dev/null 2>&1; then
    digest=$(printf '%s' "$out" | cksum 2>/dev/null)
    digest="${digest%% *}"
  fi
  [ -n "$digest" ] || return 1

  digest=$(printf '%s' "$digest" | tr -cd 'A-Za-z0-9')
  [ -n "$digest" ] || return 1

  printf '%s\n' "$digest"
}

# bp_repeat_session_token RAW -> echoes sanitised token, or "nosid"
# PURE. Replaces every char outside [A-Za-z0-9_-] with '_', truncates to 16.
bp_repeat_session_token() {
  local raw="$1"
  local token
  token=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '_')
  token="${token:0:16}"
  if [ -z "$token" ]; then
    printf '%s\n' nosid
  else
    printf '%s\n' "$token"
  fi
}

# bp_repeat_state_path TOKEN -> echoes "$BP_DIR/runs/${BP_PACKAGE:-pkg}.repeat-<TOKEN>.log"
# PURE — reads only env vars.
bp_repeat_state_path() {
  local token="$1"
  printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.repeat-${token}.log"
}

# bp_repeat_config_int RAW DEFAULT MIN -> echoes RAW if a decimal integer >= MIN, else DEFAULT
# PURE.
bp_repeat_config_int() {
  local raw="$1" def="$2" min="$3"
  case "$raw" in
    ''|*[!0-9]*) printf '%s\n' "$def"; return 0 ;;
  esac
  if [ "$raw" -ge "$min" ] 2>/dev/null; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$def"
  fi
}

# bp_repeat_action_of RAW -> echoes "nudge" | "deny" | "off"
# PURE. Unset/empty -> nudge (default). Any other unrecognised value -> off
# (an unrecognised action disables the guard; a typo must never produce a block).
bp_repeat_action_of() {
  local raw="$1"
  case "$raw" in
    ''|nudge) printf '%s\n' nudge ;;
    deny)     printf '%s\n' deny ;;
    off)      printf '%s\n' off ;;
    *)        printf '%s\n' off ;;
  esac
}
