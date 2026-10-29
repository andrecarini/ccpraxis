#!/usr/bin/env bash
# bp-resume-sweep.sh — find interrupted coordinators and resume them economically.
#
# Usage: bp-resume-sweep.sh [blueprint] [--apply]
#
# Default is a dry run (prints the plan). --apply executes it.
#
# Policy (per non-terminal package whose coordinator process is dead):
#   verdict = bp-cache-state.pl verdict <bp> <pkg>   (warm | cold)
#       -- derived from the TRANSCRIPT's (runs/<pkg>.jsonl) last API event, NEVER
#          the ledger's mtime (b41: the ledger is human/reporter/judge-touched and
#          drifts from the transcript in both directions; a missed warm resume
#          re-ingests a multi-MB transcript at cache-WRITE rates, so uncertainty
#          must bias cold — see bp-cache-state.pl's own header for the full case).
#   warm + session_id known -> warm resume:  claude --resume <sid>
#   otherwise                -> cold start:   fresh coordinator seeded from the ledger
#
# ONE RULE, TWO CALLERS (b41 spec §2): this sweep and bp-orchestrator.pl's
# resume_mode both consume bp-cache-state.pl's `verdict` — neither keeps a
# second copy of the warm/cold policy or the cache-TTL window.
#
# ONE RULE, TWO CALLERS, again (b16 spec §2): a dead coordinator whose own
# terminal jsonl event classifies as `max_turns` (via bp-orchestrator.pl's
# shared `terminal_verdict` — reused through its `--exit-reason` CLI seam, NOT
# re-derived here) is ALWAYS revived cold, regardless of the b41 verdict above:
# a warm --resume would restore the exact context that contained the loop.
# Every other exit reason (success, error, unknown) leaves the b41 verdict
# above untouched.
#
# Terminal ledgers (done/blocked/parked) and live processes are reported, not
# touched. Packages never launched (no registry entry) are reported as PENDING —
# wave scheduling belongs to the deterministic orchestrator (bp-orchestrator.pl),
# not the sweep. This sweep is the warm-vs-cold recovery helper the orchestrator
# applies on a start-or-continue; it is no longer a user-facing "resume" verb.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"
require_cmd jq

APPLY=0; ONLY_BP=""
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    *) ONLY_BP="$a" ;;
  esac
done

DATA=$(bp_data_dir)
FOUND=0

revive() {  # BP_NAME PKG SID PID AGE STATUS
  local bp="$1" pkg="$2" sid="$3" pid="$4" age="$5" status="$6"
  if pid_alive "$pid"; then
    printf '%-28s %-12s RUNNING (pid %s, ledger age %sm)\n' "$bp/$pkg" "$status" "$pid" "$age"
    return 0
  fi
  local verdict mode args=() exit_reason bpdir
  verdict=$(CCPRAXIS_DATA_DIR="$DATA" perl "$SCRIPT_DIR/bp-cache-state.pl" verdict "$bp" "$pkg" 2>/dev/null || echo cold)
  bpdir="$DATA/blueprints/$bp"
  exit_reason=$(perl "$SCRIPT_DIR/bp-orchestrator.pl" --exit-reason "$bpdir" "$pkg" 2>/dev/null || echo unknown)
  if [ "$exit_reason" = "max_turns" ]; then
    # b16: turn exhaustion forces cold, always -- regardless of how warm the
    # cache measures. b41's verdict is not consulted for this package once
    # exit_reason is max_turns; the resumed context IS the loop.
    mode="cold-start (exit_reason: max_turns forces cold, bp-cache-state.pl verdict was: ${verdict})"
    args=()
  elif [ "$verdict" = "warm" ] && [ -n "$sid" ]; then
    mode="warm-resume (bp-cache-state.pl verdict: warm, exit_reason: ${exit_reason})"
    args=(--resume-session "$sid")
  else
    mode="cold-start (bp-cache-state.pl verdict: ${verdict}, exit_reason: ${exit_reason}, session_id=${sid:-none})"
    args=()
  fi
  printf '%-28s %-12s DEAD -> %s\n' "$bp/$pkg" "$status" "$mode"
  if [ "$APPLY" -eq 1 ]; then
    "$SCRIPT_DIR/bp-launch.sh" "$bp" "$pkg" "${args[@]}" || \
      printf '%-28s %-12s LAUNCH FAILED (parallel cap? see message above)\n' "$bp/$pkg" "$status"
  fi
}

for BPDIR in "$DATA"/blueprints/*/; do
  [ -d "$BPDIR" ] || continue
  BP_NAME=$(basename "$BPDIR")
  [ "$BP_NAME" = "_archive" ] && continue
  [ -z "$ONLY_BP" ] || [ "$BP_NAME" = "$ONLY_BP" ] || continue
  for LEDGER in "$BPDIR"packages/*.md; do
    [ -f "$LEDGER" ] || continue
    FOUND=1
    PKG=$(basename "$LEDGER" .md)
    STATUS=$(fm_get "$LEDGER" status); STATUS=${STATUS:-pending}
    SID=$(registry_get "$BP_NAME" "$PKG" session_id)
    PID=$(registry_get "$BP_NAME" "$PKG" pid)
    AGE=$(file_age_min "$LEDGER")

    case "$STATUS" in
      done)
        printf '%-28s %-12s DONE\n' "$BP_NAME/$PKG" "$STATUS" ;;
      blocked|parked)
        NEXT=$(awk '/^## Next action/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$LEDGER" 2>/dev/null || true)
        printf '%-28s %-12s NEEDS ATTENTION — %s\n' "$BP_NAME/$PKG" "$STATUS" "${NEXT:-see ledger}" ;;
      pending)
        if [ -z "$SID$PID" ]; then
          printf '%-28s %-12s PENDING (never launched — the orchestrator schedules it)\n' "$BP_NAME/$PKG" "$STATUS"
        else
          revive "$BP_NAME" "$PKG" "$SID" "$PID" "$AGE" "$STATUS"
        fi ;;
      *)
        revive "$BP_NAME" "$PKG" "$SID" "$PID" "$AGE" "$STATUS" ;;
    esac
  done
done

if [ "$FOUND" -eq 0 ]; then echo "no blueprints found under $DATA/blueprints"; fi
if [ "$APPLY" -eq 0 ]; then echo; echo "(dry run — pass --apply to execute)"; fi
