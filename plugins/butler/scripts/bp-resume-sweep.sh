#!/usr/bin/env bash
# bp-resume-sweep.sh — find interrupted coordinators and resume them economically.
#
# Usage: bp-resume-sweep.sh [blueprint] [--apply]
#
# Default is a dry run (prints the plan). --apply executes it.
#
# Policy (per non-terminal package whose coordinator process is dead):
#   gap = minutes since the ledger was last touched
#   gap <= BP_RESUME_THRESHOLD_MIN (default 60) AND session_id known
#       -> warm resume:  claude --resume <sid>   (prompt cache plausibly warm)
#   otherwise
#       -> cold start:   fresh coordinator seeded from the ledger
#          (re-ingesting a 100k+ token transcript past the cache window costs
#           an order of magnitude more than a ledger cold-start)
#
# Terminal ledgers (done/blocked/parked) and live processes are reported, not
# touched. Packages never launched (no registry entry) are reported as PENDING —
# wave scheduling belongs to /butler:launch, not the sweep.
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

THRESHOLD="${BP_RESUME_THRESHOLD_MIN:-60}"
DATA=$(bp_data_dir)
FOUND=0

revive() {  # BP_NAME PKG SID PID AGE STATUS
  local bp="$1" pkg="$2" sid="$3" pid="$4" age="$5" status="$6"
  if pid_alive "$pid"; then
    printf '%-28s %-12s RUNNING (pid %s, ledger age %sm)\n' "$bp/$pkg" "$status" "$pid" "$age"
    return 0
  fi
  local mode args=()
  if [ "$age" -le "$THRESHOLD" ] && [ -n "$sid" ]; then
    mode="warm-resume (gap ${age}m <= ${THRESHOLD}m)"
    args=(--resume-session "$sid")
  else
    mode="cold-start (gap ${age}m > ${THRESHOLD}m or no session id)"
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
        registry_merge "$BP_NAME" "$PKG" '{"status":"done"}'
        printf '%-28s %-12s DONE\n' "$BP_NAME/$PKG" "$STATUS" ;;
      blocked|parked)
        NEXT=$(awk '/^## Next action/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$LEDGER" 2>/dev/null || true)
        printf '%-28s %-12s NEEDS ATTENTION — %s\n' "$BP_NAME/$PKG" "$STATUS" "${NEXT:-see ledger}" ;;
      pending)
        if [ -z "$SID$PID" ]; then
          printf '%-28s %-12s PENDING (never launched — use /butler:launch)\n' "$BP_NAME/$PKG" "$STATUS"
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
