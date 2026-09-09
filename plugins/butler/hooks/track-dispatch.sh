#!/usr/bin/env bash
# track-dispatch.sh — PreToolUse hook for Task inside coordinator sessions.
#
# Records which worker is in flight (marker file used by guard-writes.sh for
# role-scoped write rules) and mechanically enforces the protocol rule that at
# most ONE write-capable worker runs at a time. Read-only workers may run in
# parallel freely.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"
bp_hook_gate
# Coordinator-only: judges carry the env contract (for guard-writes scoping) but
# never dispatch workers, so the one-write-capable-worker bookkeeping is not theirs.
[ "${BP_ROLE:-coordinator}" = "coordinator" ] || exit 0
# A fleet stop is in force: the graceful-stop gate (gate-shutdown.sh) denies new
# Task dispatch, so do NOT record an active-worker marker for a worker that won't
# launch — a phantom marker would survive into the warm resume and wedge the next
# dispatch ("a write-capable worker is already in flight"). (Package A4.)
[ -z "$(bp_active_stop_signal)" ] || exit 0
bp_hook_require_json_parser

bp_read_payload open
TYPE=$(bp_json_get "$PAYLOAD" tool_input.subagent_type)
[ -n "$TYPE" ] || exit 0

MARKER=$(marker_path)
mkdir -p "$(dirname "$MARKER")"

is_writer() { [[ "$1" == *bp-implementer* || "$1" == *bp-test-writer* || "$1" == *bp-ui-prober* ]]; }

if is_writer "$TYPE"; then
  if [ -f "$MARKER" ]; then
    CURRENT=$(cat "$MARKER" 2>/dev/null || true)
    if [ -n "$CURRENT" ] && is_writer "$CURRENT"; then
      echo "BLOCKED: a write-capable worker ($CURRENT) is already in flight. The protocol allows at most one write-capable worker at a time — wait for it to return before dispatching $TYPE." >&2
      exit 2
    fi
  fi
  printf '%s' "$TYPE" > "$MARKER"
fi

# --- dispatch record write step (agent-telemetry/03-dispatch-write-path) ---
#
# The hook is an OBSERVER: every branch below falls through to the final
# `exit 0` at the bottom of this file. Nothing here may exit 2 or otherwise
# block the dispatch — a missing/broken/slow logger degrades to "no record
# written", never to "dispatch blocked" (spec S1.1).
#
# Only bp-* subagent types are recorded (Decision 6 vocabulary); the raw
# TYPE (e.g. "butler:bp-implementer") is normalized to its base name by
# stripping through the LAST ':'. --worker-type passes the NORMALIZED base,
# never the raw prefixed value.
if [ "${BP_DISPATCH_LOG_OFF:-}" != "1" ]; then
  BASE="${TYPE##*:}"
  if [[ "$BASE" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$BASE" == bp-* ]]; then
    NOW=$(date +%s 2>/dev/null || echo 0)
    if [[ "$NOW" =~ ^[0-9]+$ ]] && [ "$NOW" -gt 0 ] && bp_is_absolute_path "${BP_PROJECT_ROOT:-}"; then
      # Attribution: from the environment only, validated and OMITTED (never
      # guessed, never substituted) when unset/empty/malshaped. '.'/'..' are
      # explicitly rejected even though they match the character class.
      BPTOK=""
      if [[ "${BP_BLUEPRINT:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        && [ "${BP_BLUEPRINT}" != "." ] && [ "${BP_BLUEPRINT}" != ".." ]; then
        BPTOK="$BP_BLUEPRINT"
      fi
      PKGTOK=""
      if [[ "${BP_PACKAGE:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        && [ "${BP_PACKAGE}" != "." ] && [ "${BP_PACKAGE}" != ".." ]; then
        PKGTOK="$BP_PACKAGE"
      fi

      LOGDIR="$BP_PROJECT_ROOT/.ccpraxis-local-data/.dispatch-log"

      # Deduplication (spec S2.3): a `running` record whose normalized
      # worker_type equals BASE, whose package is absent or equals PKGTOK,
      # and whose started_at is within 120s of NOW in either direction,
      # means the coordinator already stamped this dispatch — write nothing.
      # Fork-free, bounded scan: over SCAN_CAP files, stand aside (treat as
      # claimed) rather than prove a negative in unbounded time.
      WT_RE='"worker_type":"([^"]*)"'
      PKG_RE='"package":"([^"]*)"'
      SA_RE='"started_at":([0-9]+)'
      CLAIMED=0
      if [ -d "$LOGDIR" ]; then
        n=0
        for f in "$LOGDIR"/*.json; do
          [ -f "$f" ] || continue
          n=$((n + 1))
          if [ "$n" -gt 2000 ]; then
            # Over SCAN_CAP: stand aside for THIS dispatch (correct -- proving
            # a negative in unbounded time is worse), but do not simply leave.
            #
            # Standing aside alone was a ONE-WAY DOOR (bug 20260908-225444-b9db):
            # the store only grew, so once past 2000 it stayed past 2000, and
            # this branch then blocked the only thing that could ever shrink it
            # -- the logger, whose `start` is where retention now runs. Recording
            # would have been off from that moment on, silently and forever.
            #
            # So the over-cap path RUNS THE PRUNE ITSELF. This dispatch still
            # goes unrecorded; the next one finds a store back under 256 and
            # records normally. The alarm line is what makes the incident
            # discoverable at all, and it is bounded twice over: the prune that
            # follows it stops this branch from firing again for hundreds of
            # dispatches, and the append is skipped once the file passes 64 KiB
            # (the same ceiling bp-dispatch-log.pl's own note_alarm applies).
            ALARM="$LOGDIR/retention-alarm.log"
            ASZ=0
            [ -f "$ALARM" ] && ASZ=$(wc -c < "$ALARM" 2>/dev/null || echo 0)
            [ "$ASZ" -lt 65536 ] 2>/dev/null && \
              printf '%s track-dispatch.sh stood aside: over 2000 records, this dispatch went unrecorded; running a prune\n' \
                "$NOW" >> "$ALARM" 2>/dev/null || :
            perl "$HOOK_DIR/../scripts/bp-dispatch-log.pl" prune \
                 --root "$BP_PROJECT_ROOT" </dev/null >/dev/null 2>&1 || :
            CLAIMED=1
            break
          fi
          LINE=""
          IFS= read -r -N 8192 LINE < "$f" 2>/dev/null || true
          case "$LINE" in
            *'"status":"running"'*) ;;
            *) continue ;;
          esac
          [[ "$LINE" =~ $WT_RE ]] || continue
          rt="${BASH_REMATCH[1]##*:}"
          [ "$rt" = "$BASE" ] || continue
          if [[ "$LINE" =~ $PKG_RE ]]; then
            [ "${BASH_REMATCH[1]}" = "$PKGTOK" ] || continue
          fi
          [[ "$LINE" =~ $SA_RE ]] || continue
          d=$((NOW - 10#${BASH_REMATCH[1]}))
          [ "$d" -lt 0 ] && d=$((-d))
          [ "$d" -le 120 ] && { CLAIMED=1; break; }
        done
      fi

      if [ "$CLAIMED" = 0 ]; then
        ID="hk-${BPTOK:-nobp}-${PKGTOK:-nopkg}-${BASE}-${NOW}-$$-${RANDOM}"
        LOGGER="$HOOK_DIR/../scripts/bp-dispatch-log.pl"
        ARGS=(start --id "$ID" --worker-type "$BASE" --role worker --root "$BP_PROJECT_ROOT")
        [ -n "$BPTOK" ]  && ARGS+=(--blueprint "$BPTOK")
        [ -n "$PKGTOK" ] && ARGS+=(--package "$PKGTOK")
        # </dev/null: the child can never inherit a pipe that never closes.
        # >/dev/null 2>&1: a PreToolUse hook's stdout is a protocol channel —
        # neither the logger's "started ..." line nor its diagnostics may
        # reach Claude Code. || :: the child's exit status is discarded.
        perl "$LOGGER" "${ARGS[@]}" </dev/null >/dev/null 2>&1 || :
      fi
    fi
  fi
fi

exit 0
