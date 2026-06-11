#!/usr/bin/env bash
# gate-stop.sh — Stop hook inside coordinator sessions.
#
# A coordinator may only go idle when its ledger says so. Concretely:
#   * frontmatter status is terminal: done | blocked | parked
#   * the ledger was touched recently (default: last 15 min, BP_LEDGER_FRESH_MIN)
#   * blocked/parked additionally require a non-empty "## Next action" section
#
# This converts ledger discipline from a prompt rule (which decays over long
# contexts) into a mechanical gate. Escape hatch for the orchestrator:
# touch runs/<pkg>.force-stop to let the session end unconditionally.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate

FORCE="$BP_DIR/runs/${BP_PACKAGE:-pkg}.force-stop"
if [ -f "$FORCE" ]; then rm -f "$FORCE"; exit 0; fi

if [ ! -f "$BP_LEDGER" ]; then
  echo "STOP BLOCKED: ledger $BP_LEDGER does not exist. Create/update it (status, Next action, outputs) before stopping." >&2
  exit 2
fi

STATUS=$(awk '
  BEGIN { infm=0 }
  /^---[[:space:]]*$/ { infm++; if (infm==2) exit; next }
  infm==1 && /^status:/ { sub(/^status:[[:space:]]*/, ""); print; exit }' "$BP_LEDGER")

case "$STATUS" in
  done|blocked|parked) : ;;
  *)
    echo "STOP BLOCKED: ledger status is '${STATUS:-unset}', not terminal. Before stopping: finish or park the work, update the ledger (frontmatter status -> done|blocked|parked, last_updated, 'Next action', 'Outputs'), then stop. If genuinely stuck, status: blocked with a precise Next action is a valid terminal state." >&2
    exit 2 ;;
esac

NOW=$(date +%s); MT=$(stat -c %Y "$BP_LEDGER" 2>/dev/null || echo 0)
AGE_MIN=$(( (NOW - MT) / 60 ))
FRESH="${BP_LEDGER_FRESH_MIN:-15}"
if [ "$AGE_MIN" -gt "$FRESH" ]; then
  echo "STOP BLOCKED: ledger status is terminal but the file is ${AGE_MIN}m stale (limit ${FRESH}m). Re-verify the final state on disk, refresh last_updated and the closing summary, then stop." >&2
  exit 2
fi

if [ "$STATUS" != "done" ]; then
  NEXT=$(awk '/^## Next action/{getline; while ($0 ~ /^[[:space:]]*$/) getline; if ($0 !~ /^#/) print; exit}' "$BP_LEDGER")
  if [ -z "${NEXT:-}" ] || grep -q '^<' <<<"$NEXT"; then
    echo "STOP BLOCKED: status is '$STATUS' but '## Next action' is empty or still a template placeholder. A blocked/parked ledger must tell a fresh coordinator exactly where to pick up." >&2
    exit 2
  fi
fi

# Best-effort: sync registry status so bp-status/sweep see the terminal state
# without parsing every ledger again.
REG="$BP_DIR/runs/registry.json"
if command -v jq >/dev/null 2>&1 && [ -s "$REG" ] && [ -n "${BP_PACKAGE:-}" ]; then
  TMP=$(mktemp)
  jq --arg pkg "$BP_PACKAGE" --arg st "$STATUS" \
     '.packages[$pkg] = ((.packages[$pkg] // {}) + {status:$st})' "$REG" > "$TMP" 2>/dev/null \
    && mv "$TMP" "$REG" || rm -f "$TMP"
fi

exit 0
