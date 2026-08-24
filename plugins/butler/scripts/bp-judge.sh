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
#
# b11-progress-heuristic-turns-backstop: when bp-progress.pl's semantic tail-read
# (bp-orchestrator.pl's watchdog, gated on BP_PROGRESS_MODEL_CMD) returns a confident
# `looping`/`stuck` verdict, the orchestrator kills that coordinator and escalates it
# through the SAME `resolve` path this script already serves (_escalate_stuck ->
# spawn_judge kind=resolve) — no new judge kind, no change here. `bp-progress.pl`'s
# OWN `capped` condition (the turn cap reached before the heuristic got a confident
# read) is a distinct, guard-level log line in runs/orchestrator.log; it never queues
# a resolve judge and never touches this script's inputs.
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
case "$KIND" in harvest|resolve|conformance|escalation-resolve) ;; *) echo "bp-judge: unknown kind '$KIND' (want harvest|resolve|conformance|escalation-resolve)" >&2; exit 2 ;; esac

PROJECT_ROOT=$(bp_project_root)
BPDIR=$(bp_dir "$BP_NAME")
LEDGER=$(bp_ledger "$BP_NAME" "$PKG")
# conformance is INITIATIVE-scoped: its pseudo-package `_run` has no ledger, so the
# per-package ledger requirement is skipped for that kind only (harvest/resolve keep it).
if [ "$KIND" != conformance ]; then
  [ -f "$LEDGER" ] || { echo "bp-judge: no ledger at $LEDGER" >&2; exit 1; }
fi
BLUEPRINT_FILE="$BPDIR/blueprint.md"
# The bp-$KIND-judge.md convention holds for three kinds and not the fourth.
# escalation-resolve's agent is bp-escalation-resolver.md -- different stem, no
# `-judge` suffix -- so the derived name was agents/bp-escalation-resolve-judge.md,
# which has never existed. Combined with the allow-list above (which rejected the
# kind before this line was even reached) that path had never once executed.
# Almanac 20260824-170753-01b8.
case "$KIND" in
  escalation-resolve) AGENT_FILE="$PLUGIN_ROOT/agents/bp-escalation-resolver.md" ;;
  *)                  AGENT_FILE="$PLUGIN_ROOT/agents/bp-$KIND-judge.md" ;;
esac
[ -f "$AGENT_FILE" ] || { echo "bp-judge: no agent file at $AGENT_FILE" >&2; exit 1; }
# templates/ is NOT in b05's write set, so the conformance prompt is built inline
# (heredoc) below instead of from a templates/judge-conformance.md file.
if [ "$KIND" != conformance ]; then
  TEMPLATE="$PLUGIN_ROOT/templates/judge-$KIND.md"
  [ -f "$TEMPLATE" ] || { echo "bp-judge: no template at $TEMPLATE" >&2; exit 1; }
fi

# escalation-resolve triages ONE named record, and the orchestrator names it by
# writing runs/escalation-resolve/<pkg>.decision before spawning us. Refuse
# rather than launch a judge with nothing to judge: a one-shot agent given no
# target burns its whole budget discovering that, writes no verdict, and is
# indistinguishable from a crash in the log.
DECISION_ID=""
DECISION_FILE=""
if [ "$KIND" = escalation-resolve ]; then
  DECISION_ID=$(tr -d '\r\n' < "$BPDIR/runs/escalation-resolve/$PKG.decision" 2>/dev/null || true)
  [ -n "$DECISION_ID" ] || { echo "bp-judge: no decision id at $BPDIR/runs/escalation-resolve/$PKG.decision" >&2; exit 1; }
  DECISION_FILE="$BPDIR/runs/needs-you/$DECISION_ID.json"
  [ -f "$DECISION_FILE" ] || { echo "bp-judge: decision record missing at $DECISION_FILE" >&2; exit 1; }
fi

WRITE_SET=$([ -f "$LEDGER" ] && fm_get "$LEDGER" write_set || echo "")
TEST_PATHS=$([ -f "$LEDGER" ] && fm_get "$LEDGER" test_paths || echo "")

if [ "$KIND" = conformance ]; then
  # initiative-scoped, judgment-heavy: it reads blueprint.md + every ledger's
  # mandated_means + the delivered code, which is strictly more work than a harvest
  # judge's single contracted slice. Read-only: empty write_set, so only the verdict
  # (which lands under BP_DIR) is writable.
  MODEL="${BP_CONFORMANCE_MODEL:-opus}"; MAXT="${BP_CONFORMANCE_MAX_TURNS:-600}"
  ROLE="conformance-judge"; J_WRITE_SET=""; J_TEST_PATHS=""
elif [ "$KIND" = resolve ]; then
  MODEL="${BP_RESOLVE_MODEL:-opus}";   MAXT="${BP_RESOLVE_MAX_TURNS:-800}"
  ROLE="resolve-judge"; J_WRITE_SET="$WRITE_SET"; J_TEST_PATHS="$TEST_PATHS"
elif [ "$KIND" = escalation-resolve ]; then
  # READ-ONLY, like the harvest and conformance judges: this judge CLASSIFIES a
  # queued escalation and writes a verdict. Every mutation it proposes is applied
  # afterwards, deterministically, by bp-resolve.pl -- so an empty write set here
  # is the contract, not an oversight.
  #
  # 800, canonical in turn-caps.json, which this surface is now drift-checked
  # against (almanac 20260823-211302-7d5a: the role had no canonical cap at all
  # and t/93 had been red for it).
  #
  # 800 rather than the 400 band its read-only tool list would suggest, for two
  # reasons that both outrank the shape heuristic. e03's DC4 pins this role to
  # bp-resolve-judge EXACTLY -- they are the pair that decides what happens to a
  # stuck package, and a resolver capped below the judge it feeds starves on
  # precisely the hard cases the pair exists for (t/126 AG5 enforces the
  # equality). And turn-caps.json's own header: a cap is a RUNAWAY BACKSTOP, not
  # a budget, so lowering it to match expected cost saves nothing on a healthy
  # run and throws away a dispatch that had almost finished.
  #
  # Both smaller values tried here on 2026-08-24 (40, then 400) were reasoned
  # from typical cost. That is the mistake that file exists to warn against.
  MODEL="${BP_ESCALATION_MODEL:-sonnet}"; MAXT="${BP_ESCALATION_MAX_TURNS:-800}"
  case "$MAXT" in ''|*[!0-9]*|0) MAXT=800 ;; esac
  ROLE="escalation-resolver"; J_WRITE_SET=""; J_TEST_PATHS=""
else
  MODEL="${BP_HARVEST_MODEL:-sonnet}"
  MAXT="${BP_HARVEST_MAX_TURNS:-}"                       # explicit override WINS
  if [ -z "$MAXT" ]; then
    MAXT=$(perl -e 'require $ARGV[0]; print BpJudge::harvest_max_turns($ARGV[1],$ARGV[2])' \
             "$SCRIPT_DIR/bp-judge.pl" "$WRITE_SET" "$TEST_PATHS" 2>/dev/null || true)
  fi
  # Validate BOTH the computed value AND an ambient BP_HARVEST_MAX_TURNS override
  # (moved outside the `[ -z "$MAXT" ]` branch, which used to guard the computed
  # value only): non-numeric, negative or explicitly 0 must never reach `claude
  # --max-turns` — a 0 budget starves every judge instantly, and this package's
  # own operator-facing decision text tells a human to raise this exact variable,
  # so an unvalidated override here is directly reachable.
  case "$MAXT" in ''|*[!0-9]*|0) MAXT=28 ;; esac       # pinned floor if perl is unavailable or override is bad
  ROLE="harvest-judge"; J_WRITE_SET=""; J_TEST_PATHS=""   # read-only; only the verdict (under BP_DIR) is writable
fi

mkdir -p "$(dirname "$VERDICT_PATH")" "$BPDIR/dispatch" "$BPDIR/runs/$KIND"
# The delete below is a CORRECTNESS requirement (clears the verdict path before
# the new judge launches, so the orchestrator can never later read a stale
# verdict and attribute it to this launch) — it stays unconditional even if
# archiving fails. What was wrong was OBSERVABILITY: archive_judge_verdict's
# own diagnostics (and any uncaught `require`/runtime failure in this one-liner)
# were sent to /dev/null. Now stderr lands in orchestrator.log, and a failed
# archive attempt gets an explicit, greppable line naming kind+package.
if ! perl -e 'require $ARGV[0]; BpOrch::archive_judge_verdict($ARGV[1],$ARGV[2],$ARGV[3],time,$ARGV[4])' \
     "$SCRIPT_DIR/bp-orchestrator.pl" "$BPDIR/runs" "$KIND" "$PKG" "$BPDIR/runs/orchestrator.log" \
     >/dev/null 2>>"$BPDIR/runs/orchestrator.log"; then
  printf '%s bp-judge: archive_judge_verdict FAILED kind=%s package=%s (see perl stderr just above in this log)\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$KIND" "$PKG" >> "$BPDIR/runs/orchestrator.log"
fi
rm -f "$VERDICT_PATH"

# -------- build the prompt: inline for conformance (templates/ is unwritable for
# b05), from the per-kind template for harvest/resolve (unchanged).
PROMPT_FILE="$BPDIR/dispatch/$PKG.$KIND-judge.md"
if [ "$KIND" = conformance ]; then
  cat > "$PROMPT_FILE" <<EOF
Read your agent contract at $AGENT_FILE and follow it exactly.

You are the INITIATIVE-scoped conformance judge for blueprint '$BP_NAME'.
Blueprint file: $BLUEPRINT_FILE
Package ledgers: $BPDIR/packages/
Dependency report (may be absent; read-only): $BPDIR/runs/deps-check.json
Write your verdict JSON to exactly this path and nothing else: $VERDICT_PATH

Scope: read the blueprint's Objective + Decisions and EVERY package ledger's
explicit \`mandated_means:\` list, then verify against the delivered code on disk
that each listed means is genuinely used — present and wired, not a hand-rolled
substitute. Check methodology claims too (e.g. a real emulator where one was
mandated, not a forbidden mock).

Rules:
- Judge the EXPLICIT \`mandated_means:\` list only. Prose in a ledger is NOT a
  source of mandated means.
- For each deviation you find, report {package, means, observed, files[]}. Do NOT
  decide whether it is justified — the orchestrator reads the ledger's
  MEANS-DEVIATION marker and classifies it deterministically.
- Do NOT write review or notice files; the orchestrator writes those.
- Disk is truth; a coordinator's say-so is not. When in doubt, fail with a precise
  reason: a false pass ships broken work, a false fail costs one cheap re-check.
EOF
  PROMPT=$(cat "$PROMPT_FILE")
else
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
    -e "s|{{DECISION_ID}}|${DECISION_ID:-—}|g" \
    -e "s|{{DECISION_FILE}}|${DECISION_FILE:-—}|g" \
    "$TEMPLATE" > "$PROMPT_FILE"
PROMPT=$(cat "$PROMPT_FILE")
fi

LOG="$BPDIR/runs/$KIND/$PKG.jsonl"
PIDFILE="$BPDIR/runs/$KIND/$PKG.pid"

# b09: a re-fire for the SAME package (the widened GATE/AUDIT re-audit) must not
# destroy the previous judge's stream log — the starvation-park decision text
# explicitly tells the operator to read this file to see how far the earlier
# audit got. Rotate any existing log to a numbered backup ($PKG.1.jsonl,
# $PKG.2.jsonl, ...) before truncating; $PKG.jsonl always stays the CURRENT
# attempt, which is the exact path judge_log_path() in bp-orchestrator.pl (and
# every reader built on it) expects — do not change that path.
if [ -e "$LOG" ]; then
  n=1
  while [ -e "$BPDIR/runs/$KIND/$PKG.$n.jsonl" ]; do n=$((n+1)); done
  mv -f "$LOG" "$BPDIR/runs/$KIND/$PKG.$n.jsonl"
fi

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
