#!/usr/bin/env bash
# bp-status.sh — one-line-per-package rollup across blueprints.
# Usage: bp-status.sh [blueprint]
# This is the orchestrator's monitoring surface: ledger frontmatter + process
# liveness + the first line of "Next action". It never reads stream logs.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"
require_cmd jq

ONLY_BP="${1:-}"
DATA=$(bp_data_dir)
FOUND=0

for BPDIR in "$DATA"/blueprints/*/; do
  [ -d "$BPDIR" ] || continue
  BP_NAME=$(basename "$BPDIR")
  [ "$BP_NAME" = "_archive" ] && continue
  [ -z "$ONLY_BP" ] || [ "$BP_NAME" = "$ONLY_BP" ] || continue
  echo "== $BP_NAME"
  printf '%-26s %-11s %-10s %-6s %-4s %s\n' PACKAGE STATUS PROC AGE ATT "NEXT ACTION"
  for LEDGER in "$BPDIR"packages/*.md; do
    [ -f "$LEDGER" ] || continue
    FOUND=1
    PKG=$(basename "$LEDGER" .md)
    STATUS=$(fm_get "$LEDGER" status); STATUS=${STATUS:-pending}
    PID=$(registry_get "$BP_NAME" "$PKG" pid)
    ATT=$(registry_get "$BP_NAME" "$PKG" attempt); ATT=${ATT:-0}
    AGE="$(file_age_min "$LEDGER")m"
    if pid_alive "$PID"; then PROC="pid $PID"; else PROC="—"; fi
    NEXT=$(awk '/^## Next action/{getline; while ($0 ~ /^[[:space:]]*$/) getline; print; exit}' "$LEDGER" 2>/dev/null | cut -c1-60)
    printf '%-26s %-11s %-10s %-6s %-4s %s\n' "$PKG" "$STATUS" "$PROC" "$AGE" "$ATT" "${NEXT:-}"
  done
  echo
done

[ "$FOUND" -eq 1 ] || echo "no blueprints found under $DATA/blueprints"
