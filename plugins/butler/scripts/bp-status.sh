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
STRAYS=()

for BPDIR in "$DATA"/blueprints/*/; do
  [ -d "$BPDIR" ] || continue
  BP_NAME=$(basename "$BPDIR")
  [ -z "$ONLY_BP" ] || [ "$BP_NAME" = "$ONLY_BP" ] || continue

  if [ ! -f "${BPDIR}blueprint.md" ]; then
    if [ -n "$ONLY_BP" ]; then
      echo "bp-status: '$BP_NAME' is not a blueprint -- $DATA/blueprints/$BP_NAME/blueprint.md does not exist." >&2
      echo "bp-status: the directory exists but was not run and was not removed; inspect it by hand." >&2
      exit 3
    fi
    if [ "$BP_NAME" != "_archive" ]; then
      STRAYS+=("$BP_NAME")
    fi
    continue
  fi

  FOUND=1
  echo "== $BP_NAME"
  printf '%-26s %-11s %-10s %-6s %-4s %s\n' PACKAGE STATUS PROC AGE ATT "NEXT ACTION"
  for LEDGER in "$BPDIR"packages/*.md; do
    [ -f "$LEDGER" ] || continue
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

if [ -n "$ONLY_BP" ] && [ "$FOUND" -eq 0 ]; then
  echo "bp-status: no blueprint named '$ONLY_BP' under $DATA/blueprints." >&2
  exit 3
fi

[ "$FOUND" -eq 1 ] || echo "no blueprints found under $DATA/blueprints"

if [ "${#STRAYS[@]}" -gt 0 ]; then
  echo
  echo "!! UNRECOGNISED DIRECTORIES (no blueprint.md) -- NOT blueprints, NOT running:"
  for NAME in "${STRAYS[@]}"; do
    printf '%s\n' "!!   $NAME"
  done
  echo "!! Under $DATA/blueprints. Nothing was removed -- inspect and delete by hand if stale."
fi
