#!/usr/bin/env bash
# bp-launch.sh — launch (or resume) a headless coordinator session for one package.
#
# Usage:
#   bp-launch.sh <blueprint> <package> [--model M] [--max-turns N] [--force]
#   bp-launch.sh <blueprint> <package> --resume-session <SESSION_ID>
#
# Fresh launch: generates a dispatch prompt from templates/dispatch-prompt.md.
# Resume: short nudge prompt + `claude --resume <sid>` (only economical while
# the prompt cache is warm — the resume-vs-cold decision lives in bp-resume-sweep.sh).
#
# The coordinator's discipline is enforced by hooks gated on the env contract
# exported here: BP_LEDGER, BP_WRITE_SET, BP_TEST_PATHS, BP_DIR, BP_PROJECT_ROOT.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"
bp_require_sandbox
require_cmd jq flock claude setsid realpath

BP_NAME="${1:?usage: bp-launch.sh <blueprint> <package> [opts]}"
PKG="${2:?usage: bp-launch.sh <blueprint> <package> [opts]}"
shift 2

MODEL="" ; MAXT="" ; FORCE=0 ; RESUME_SID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model)          MODEL="$2"; shift 2 ;;
    --max-turns)      MAXT="$2"; shift 2 ;;
    --force)          FORCE=1; shift ;;
    --resume-session) RESUME_SID="$2"; shift 2 ;;
    *) echo "bp-launch: unknown option $1" >&2; exit 1 ;;
  esac
done

PROJECT_ROOT=$(bp_project_root)
BPDIR=$(bp_dir "$BP_NAME")
LEDGER=$(bp_ledger "$BP_NAME" "$PKG")
[ -f "$LEDGER" ] || { echo "bp-launch: no ledger at $LEDGER" >&2; exit 1; }
BLUEPRINT_FILE="$BPDIR/blueprint.md"
mkdir -p "$BPDIR/runs" "$BPDIR/dispatch" "$BPDIR/reports/$PKG" "$BPDIR/specs"

# -------- read package parameters from the ledger frontmatter (single source)
WRITE_SET=$(fm_get "$LEDGER" write_set)
TEST_PATHS=$(fm_get "$LEDGER" test_paths)
[ -n "$MODEL" ] || MODEL=$(fm_get "$LEDGER" model)
[ -n "$MODEL" ] || MODEL="${BP_DEFAULT_MODEL:-sonnet}"
[ -n "$MAXT" ]  || MAXT=$(fm_get "$LEDGER" max_turns)
[ -n "$MAXT" ]  || MAXT="${BP_DEFAULT_MAX_TURNS:-80}"
[ -n "$WRITE_SET" ] || { echo "bp-launch: ledger has empty write_set — refusing to launch an unscoped coordinator" >&2; exit 1; }

# -------- global parallelism cap (usage-limit protection)
MAX_PAR="${BP_MAX_PARALLEL:-2}"
if [ "$FORCE" -ne 1 ]; then
  RUNNING=$(count_running_global)
  if [ "$RUNNING" -ge "$MAX_PAR" ]; then
    echo "bp-launch: $RUNNING coordinators already running (BP_MAX_PARALLEL=$MAX_PAR). Use --force to override." >&2
    exit 3
  fi
fi

# -------- build the prompt
PROMPT_FILE="$BPDIR/dispatch/$PKG.md"
if [ -n "$RESUME_SID" ]; then
  KIND="resume"
  PROMPT="Resuming after an interruption. Re-read your ledger at $LEDGER, verify every recorded output actually exists on disk, then continue from the 'Next action' section. All standing rules from the coordinator protocol still apply. Do not redo work the ledger marks as verified."
else
  KIND="fresh"
  sed -e "s|{{PLUGIN_ROOT}}|$PLUGIN_ROOT|g" \
      -e "s|{{PROJECT_ROOT}}|$PROJECT_ROOT|g" \
      -e "s|{{BP_DIR}}|$BPDIR|g" \
      -e "s|{{LEDGER}}|$LEDGER|g" \
      -e "s|{{BLUEPRINT_FILE}}|$BLUEPRINT_FILE|g" \
      -e "s|{{PACKAGE}}|$PKG|g" \
      -e "s|{{BLUEPRINT}}|$BP_NAME|g" \
      "$PLUGIN_ROOT/templates/dispatch-prompt.md" > "$PROMPT_FILE"
  PROMPT=$(cat "$PROMPT_FILE")
fi

LOG="$BPDIR/runs/$PKG.jsonl"
PIDFILE="$BPDIR/runs/$PKG.pid"
rm -f "$BPDIR/runs/$PKG.force-stop" "$BPDIR/runs/$PKG.active-worker"

# -------- launch detached
ATTEMPT=$(registry_get "$BP_NAME" "$PKG" attempt); ATTEMPT=$(( ${ATTEMPT:-0} + 1 ))
(
  cd "$PROJECT_ROOT"
  export CCPRAXIS_DATA_DIR="$(bp_data_dir)"
  export BP_PROJECT_ROOT="$PROJECT_ROOT" BP_BLUEPRINT="$BP_NAME" BP_PACKAGE="$PKG"
  export BP_DIR="$BPDIR" BP_LEDGER="$LEDGER"
  export BP_WRITE_SET="$WRITE_SET" BP_TEST_PATHS="$TEST_PATHS"
  export BP_ROLE="coordinator"
  if [ -n "$RESUME_SID" ]; then
    setsid nohup claude -p "$PROMPT" --resume "$RESUME_SID" \
      --output-format stream-json --verbose \
      --model "$MODEL" --max-turns "$MAXT" \
      --dangerously-skip-permissions >> "$LOG" 2>&1 &
  else
    setsid nohup claude -p "$PROMPT" \
      --output-format stream-json --verbose \
      --model "$MODEL" --max-turns "$MAXT" \
      --dangerously-skip-permissions > "$LOG" 2>&1 &
  fi
  echo $! > "$PIDFILE"
)
PID=$(cat "$PIDFILE")

# -------- capture session id from the stream (init event), up to 60s
SID="$RESUME_SID"
if [ -z "$SID" ]; then
  for _ in $(seq 1 60); do
    SID=$(grep -m1 -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$LOG" 2>/dev/null \
          | head -n1 | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    [ -n "$SID" ] && break
    pid_alive "$PID" || break
    sleep 1
  done
fi

registry_merge "$BP_NAME" "$PKG" "$(jq -n \
  --arg sid "${SID:-}" --arg pid "$PID" --arg model "$MODEL" \
  --arg kind "$KIND" --arg at "$(iso_now)" --argjson attempt "$ATTEMPT" \
  '{session_id:$sid, pid:($pid|tonumber), model:$model, attempt:$attempt,
    last_launch_kind:$kind, launched_at:$at, status:"running"}')"

if pid_alive "$PID"; then
  echo "launched $BP_NAME/$PKG  kind=$KIND model=$MODEL max_turns=$MAXT pid=$PID session=${SID:-pending} attempt=$ATTEMPT"
  echo "log: $LOG"
else
  echo "bp-launch: coordinator process died immediately — inspect $LOG" >&2
  exit 1
fi
