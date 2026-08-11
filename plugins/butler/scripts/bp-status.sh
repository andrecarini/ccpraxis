#!/usr/bin/env bash
# bp-status.sh — one-line-per-package rollup across blueprints.
# Usage: bp-status.sh [blueprint]
# This is the orchestrator's monitoring surface: ledger frontmatter + process
# liveness + the first line of "Next action". It never reads stream logs.
# A directory under blueprints/ with no blueprint.md is a stray, never removed,
# and is reported in a trailing "!!"-prefixed section; a named-arg lookup that
# resolves to a stray or to nothing fails loudly (exit 3) instead of listing.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"

# jq is used for ONE thing here: the pid/attempt columns, which come from
# runs/registry.json. It used to be a hard require, which made the whole status
# surface unusable on the host (Git-for-Windows ships no jq) — so the one
# command an operator reaches for to find out whether a run is stale was itself
# the thing that could not run. Degrade instead: without jq the two registry
# columns read "?" and everything sourced from the ledgers still prints.
HAVE_JQ=0
command -v jq > /dev/null 2>&1 && HAVE_JQ=1

ONLY_BP="${1:-}"
DATA=$(bp_data_dir)
FOUND=0
STRAYS=()

# Reconcile before reporting. The ledgers are the truth; blueprint.md's own
# `status:`, its package-status table, runs/registry.json and runs/.orchestrator
# are all derived, and every one of them has been observed stale (see the header
# of bp-lifecycle.pl). Repairing on observation is what makes "finished but
# still marked running" unrepresentable rather than merely unlikely.
#
# --no-archive: filing a finished blueprint away is a decision for the verbs
# that own the lifecycle (/blueprint:manage, the drive loop), not a side effect
# of asking for status. A `status` that silently moved directories would be a
# nasty surprise, and it would race a fleet that is about to be relaunched.
# Failure here is never fatal — a status read must still work if reconciliation
# cannot.
if [ -x "$SCRIPT_DIR/bp-lifecycle.pl" ] || [ -f "$SCRIPT_DIR/bp-lifecycle.pl" ]; then
  if [ -n "$ONLY_BP" ]; then
    perl "$SCRIPT_DIR/bp-lifecycle.pl" reconcile --blueprint "$ONLY_BP" \
         --no-archive --quiet > /dev/null 2>&1 || true
  else
    perl "$SCRIPT_DIR/bp-lifecycle.pl" reconcile --all \
         --no-archive --quiet > /dev/null 2>&1 || true
  fi
fi

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

  # The blueprint's OWN lifecycle status was never shown here, which is exactly
  # how `sandbox-butler-overhaul` sat at `running` with all 77 packages done
  # until a human read the ledgers by hand. A per-package rollup that omits the
  # rollup's own state cannot surface that class of staleness.
  BP_LIFECYCLE=$(awk '
    /^```[[:space:]]*$/ { fence++; if (fence==2) exit; next }
    fence==1 && /^status:/ { sub("^status:[[:space:]]*", ""); sub("[[:space:]]*#.*$", ""); print; exit }
  ' "${BPDIR}blueprint.md" 2>/dev/null)
  # A live orchestrator is the marker PLUS a live pid. Existence alone is not
  # liveness: the marker is removed on CLEAN exit only, so one that died with
  # its container leaves it behind forever.
  RUN_NOTE=""
  if [ -f "${BPDIR}runs/.orchestrator" ]; then
    ORCH_PID=$(tr -dc '0-9' < "${BPDIR}runs/.orchestrator" 2>/dev/null || true)
    if pid_alive "$ORCH_PID"; then RUN_NOTE="  [orchestrator pid $ORCH_PID LIVE]"
    else                          RUN_NOTE="  [stale orchestrator marker pid ${ORCH_PID:-?}]"
    fi
  fi
  echo "== $BP_NAME  (blueprint status: ${BP_LIFECYCLE:-unknown})${RUN_NOTE}"
  printf '%-26s %-11s %-10s %-6s %-4s %s\n' PACKAGE STATUS PROC AGE ATT "NEXT ACTION"
  for LEDGER in "$BPDIR"packages/*.md; do
    [ -f "$LEDGER" ] || continue
    PKG=$(basename "$LEDGER" .md)
    STATUS=$(fm_get "$LEDGER" status); STATUS=${STATUS:-pending}
    if [ "$HAVE_JQ" -eq 1 ]; then
      PID=$(registry_get "$BP_NAME" "$PKG" pid)
      ATT=$(registry_get "$BP_NAME" "$PKG" attempt); ATT=${ATT:-0}
    else
      PID=""; ATT="?"
    fi
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
    # A stray directory's basename is untrusted (created by other subprocesses,
    # possibly malformed). Neutralize embedded newlines/carriage returns so this
    # name can never split into an extra output line lacking the "!!" prefix --
    # that would defeat the whole point of this section (redteam-step6.md).
    SAFE_NAME=${NAME//$'\r'/'\r'}
    SAFE_NAME=${SAFE_NAME//$'\n'/'\n'}
    printf '%s\n' "!!   $SAFE_NAME"
  done
  echo "!! Under $DATA/blueprints. Nothing was removed -- inspect and delete by hand if stale."
fi
