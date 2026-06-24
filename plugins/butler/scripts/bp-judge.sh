#!/usr/bin/env bash
# bp-judge.sh — fire ONE scoped, throwaway judge for a package and detach it.
#
# Usage:
#   bp-judge.sh <harvest|resolve> <blueprint> <package> <verdict_path>
#
# Called by the deterministic orchestrator (bp-orchestrator.pl's spawn_judge seam),
# never by hand. The judge is a fresh headless `claude -p` that reads its scoped
# slice, writes a verdict JSON to <verdict_path>, and exits — the orchestrator polls
# for that file (it never blocks its watch tick on the judge).
#
# Hook scoping: judges export the same BP_* env contract as coordinators so
# guard-writes.sh contains their writes — but with BP_ROLE != coordinator, so
# gate-stop.sh / track-dispatch.sh skip them (a judge is one-shot; coordinator
# stop-discipline would wedge it). The harvest judge gets an EMPTY write_set
# (read-only: only its verdict, which lands under BP_DIR, is writable); the resolve
# judge gets the package's real write_set so its fix is contained.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"
bp_require_sandbox
require_cmd jq flock claude setsid realpath

KIND="${1:?usage: bp-judge.sh <harvest|resolve> <blueprint> <package> <verdict_path>}"
BP_NAME="${2:?usage: bp-judge.sh <harvest|resolve> <blueprint> <package> <verdict_path>}"
PKG="${3:?usage: bp-judge.sh <harvest|resolve> <blueprint> <package> <verdict_path>}"
VERDICT_PATH="${4:?usage: bp-judge.sh <harvest|resolve> <blueprint> <package> <verdict_path>}"
case "$KIND" in harvest|resolve) ;; *) echo "bp-judge: unknown kind '$KIND' (want harvest|resolve)" >&2; exit 2 ;; esac

PROJECT_ROOT=$(bp_project_root)
BPDIR=$(bp_dir "$BP_NAME")
LEDGER=$(bp_ledger "$BP_NAME" "$PKG")
[ -f "$LEDGER" ] || { echo "bp-judge: no ledger at $LEDGER" >&2; exit 1; }
BLUEPRINT_FILE="$BPDIR/blueprint.md"
AGENT_FILE="$PLUGIN_ROOT/agents/bp-$KIND-judge.md"
[ -f "$AGENT_FILE" ] || { echo "bp-judge: no agent file at $AGENT_FILE" >&2; exit 1; }
TEMPLATE="$PLUGIN_ROOT/templates/judge-$KIND.md"
[ -f "$TEMPLATE" ] || { echo "bp-judge: no template at $TEMPLATE" >&2; exit 1; }

WRITE_SET=$(fm_get "$LEDGER" write_set)
TEST_PATHS=$(fm_get "$LEDGER" test_paths)

if [ "$KIND" = resolve ]; then
  MODEL="${BP_RESOLVE_MODEL:-opus}";   MAXT="${BP_RESOLVE_MAX_TURNS:-50}"
  ROLE="resolve-judge"; J_WRITE_SET="$WRITE_SET"; J_TEST_PATHS="$TEST_PATHS"
else
  MODEL="${BP_HARVEST_MODEL:-sonnet}"; MAXT="${BP_HARVEST_MAX_TURNS:-20}"
  ROLE="harvest-judge"; J_WRITE_SET=""; J_TEST_PATHS=""   # read-only; only the verdict (under BP_DIR) is writable
fi

mkdir -p "$(dirname "$VERDICT_PATH")" "$BPDIR/dispatch" "$BPDIR/runs/$KIND"
rm -f "$VERDICT_PATH"

# -------- build the prompt from the per-kind template
PROMPT_FILE="$BPDIR/dispatch/$PKG.$KIND-judge.md"
sed -e "s|{{PLUGIN_ROOT}}|$PLUGIN_ROOT|g" \
    -e "s|{{PROJECT_ROOT}}|$PROJECT_ROOT|g" \
    -e "s|{{BP_DIR}}|$BPDIR|g" \
    -e "s|{{LEDGER}}|$LEDGER|g" \
    -e "s|{{BLUEPRINT_FILE}}|$BLUEPRINT_FILE|g" \
    -e "s|{{AGENT_FILE}}|$AGENT_FILE|g" \
    -e "s|{{PACKAGE}}|$PKG|g" \
    -e "s|{{BLUEPRINT}}|$BP_NAME|g" \
    -e "s|{{VERDICT_PATH}}|$VERDICT_PATH|g" \
    -e "s|{{WRITE_SET}}|${WRITE_SET:-—}|g" \
    -e "s|{{TEST_PATHS}}|${TEST_PATHS:-—}|g" \
    "$TEMPLATE" > "$PROMPT_FILE"
PROMPT=$(cat "$PROMPT_FILE")

LOG="$BPDIR/runs/$KIND/$PKG.jsonl"
PIDFILE="$BPDIR/runs/$KIND/$PKG.pid"

# -------- launch detached
(
  cd "$PROJECT_ROOT"
  export CCPRAXIS_DATA_DIR="$(bp_data_dir)"
  export BP_PROJECT_ROOT="$PROJECT_ROOT" BP_BLUEPRINT="$BP_NAME" BP_PACKAGE="$PKG"
  export BP_DIR="$BPDIR" BP_LEDGER="$LEDGER"
  export BP_WRITE_SET="$J_WRITE_SET" BP_TEST_PATHS="$J_TEST_PATHS"
  export BP_ROLE="$ROLE"
  setsid nohup claude -p "$PROMPT" \
    --output-format stream-json --verbose \
    --model "$MODEL" --max-turns "$MAXT" \
    --dangerously-skip-permissions > "$LOG" 2>&1 &
  echo $! > "$PIDFILE"
)
PID=$(cat "$PIDFILE")

if pid_alive "$PID"; then
  echo "judge $KIND $BP_NAME/$PKG launched pid=$PID model=$MODEL max_turns=$MAXT verdict=$VERDICT_PATH"
  echo "log: $LOG"
else
  echo "bp-judge: judge process died immediately — inspect $LOG" >&2
  exit 1
fi
