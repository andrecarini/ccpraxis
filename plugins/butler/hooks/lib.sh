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
