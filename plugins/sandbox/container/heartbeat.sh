#!/usr/bin/env bash
# heartbeat.sh — the sandbox container's entrypoint keep-alive loop (B6).
#
# Extracted from the former inline Containerfile one-liner so the reap decision
# is a PURE, unit-testable function (reap_decision) instead of untestable inline
# bash. Behavior vs. the old entrypoint is unchanged EXCEPT: when the heartbeat
# goes stale (`/tmp/.launcher-alive` older than HB) AND a butler run is live, the
# container no longer HARD-kills the run — it signals a fleet-wide graceful
# shutdown (the A4 gate's `runs/.shutdown`, written into every active blueprint),
# waits a grace window for coordinators to park cleanly, and reaps as soon as the
# run clears (or at the grace deadline). No active run → reaps at the same
# threshold as before. The trigger threshold (HB) is identical to the old loop,
# so a transient blip (< HB) never triggers anything — B6 only makes the same
# reap gentler (Decisions #6 / #28).
#
# Sourcing this file (for tests) defines the functions but does NOT run the loop
# (the `main` guard at the bottom keys off BASH_SOURCE==$0).

set -u

# ----- tunables (env-overridable; defaults match the historical entrypoint) ---
ALIVE="${ALIVE:-/tmp/.launcher-alive}"        # manager heartbeat sentinel (host touches it)
BUSY="${BUSY:-/tmp/.butler-busy}"             # orchestrator busy-lease (A3)
HB="${HB:-300}"                               # staleness window (s) — unchanged
STARTUP_GRACE="${STARTUP_GRACE:-10}"          # startup grace before first check — unchanged
GRACE_SHUTDOWN="${GRACE_SHUTDOWN:-300}"       # graceful-park window once a stale-with-run is detected
TICK="${TICK:-10}"                            # loop poll interval (s)
DATA="${CCPRAXIS_DATA_DIR:-/project/.ccpraxis-local-data}"   # blueprint data root

# =============================================================================
# PURE DECISION (unit-tested in plugins/butler/tests/t/14-reap.t via a sourced
# bash harness — no container, no real clock)
# =============================================================================
# reap_decision HB_STALE RUN_ACTIVE GRACE_STARTED GRACE_EXPIRED -> one of:
#   keep      heartbeat fresh, or in-grace with the run still active & not expired
#             -> sleep and loop
#   reap      stale with no active run (nothing to protect: never had a run, or
#             the run cleared/parked during the grace window) -> exit, reap now
#   signal    first detection of stale-with-active-run -> write the graceful
#             shutdown signal, start the grace window, then keep waiting
#   hardstop  grace window elapsed while a run is still active -> exit, reap
reap_decision() {
  local hb_stale="$1" run_active="$2" grace_started="$3" grace_expired="$4"
  if [ "$hb_stale" != 1 ]; then echo keep; return; fi   # heartbeat alive -> keep
  if [ "$run_active" != 1 ]; then echo reap; return; fi  # stale + no run -> reap
  if [ "$grace_started" != 1 ]; then echo signal; return; fi
  if [ "$grace_expired" = 1 ]; then echo hardstop; return; fi
  echo keep
}

# =============================================================================
# I/O helpers (the impure edges the pure decision is fed from)
# =============================================================================

# now_epoch — current unix time.
now_epoch() { date +%s; }

# mtime_age FILE NOW -> seconds since FILE's mtime, or a huge number if absent.
mtime_age() {
  local f="$1" now="$2" last
  [ -f "$f" ] || { echo 999999999; return; }
  last=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  echo $(( now - last ))
}

# hb_stale NOW -> 1 if the manager heartbeat is older than HB (or absent), else 0.
hb_stale() {
  local age; age=$(mtime_age "$ALIVE" "$1")
  [ "$age" -ge "$HB" ] && echo 1 || echo 0
}

# busy_fresh NOW -> 1 if the orchestrator busy-lease is fresh (< HB), else 0.
busy_fresh() {
  local age; age=$(mtime_age "$BUSY" "$1")
  [ "$age" -lt "$HB" ] && echo 1 || echo 0
}

# coordinators_live -> 1 if any blueprint registry lists a live coordinator pid.
# Self-contained (does not source butler's bp-lib): a generic sandbox project
# with no blueprints simply matches nothing and yields 0.
coordinators_live() {
  local reg pid
  command -v jq >/dev/null 2>&1 || { echo 0; return; }
  for reg in "$DATA"/blueprints/*/runs/registry.json; do
    [ -s "$reg" ] || continue
    while read -r pid; do
      [ -n "$pid" ] || continue
      if kill -0 "$pid" 2>/dev/null; then echo 1; return; fi
    done < <(jq -r '.packages[]?.pid // empty' "$reg" 2>/dev/null)
  done
  echo 0
}

# run_active NOW -> 1 if a butler run is live (busy-lease fresh OR a live
# coordinator). This is the whole definition of "active run" (B6 out-of-scope:
# anything beyond the busy-lease / live-coordinator check).
run_active() {
  [ "$(busy_fresh "$1")" = 1 ] && { echo 1; return; }
  coordinators_live
}

# signal_graceful_shutdown — touch the A4 graceful-shutdown signal in every
# active blueprint's runs dir (idempotent). The A4 gate (per-blueprint
# runs/.shutdown) funnels each coordinator to a clean terminal park.
signal_graceful_shutdown() {
  local d count=0
  for d in "$DATA"/blueprints/*/runs; do
    [ -d "$d" ] || continue
    : > "$d/.shutdown" 2>/dev/null && count=$((count+1))
  done
  return 0
}

# =============================================================================
# MAIN LOOP
# =============================================================================
main() {
  # socat bridges for 9000-9009 only (unchanged; see Containerfile rationale).
  local p
  for p in {9000..9009}; do
    socat TCP-LISTEN:"$p",fork,reuseaddr TCP:127.0.0.1:"$p" 2>/dev/null &
  done

  local start; start=$(now_epoch)
  local grace_started=0 grace_start=0

  while true; do
    local now; now=$(now_epoch)

    # startup grace: give the manager time to land the first heartbeat touch.
    if [ $(( now - start )) -lt "$STARTUP_GRACE" ]; then sleep 1; continue; fi

    local stale active grace_expired=0
    stale=$(hb_stale "$now")
    active=$(run_active "$now")
    if [ "$grace_started" = 1 ] && [ $(( now - grace_start )) -ge "$GRACE_SHUTDOWN" ]; then
      grace_expired=1
    fi

    case "$(reap_decision "$stale" "$active" "$grace_started" "$grace_expired")" in
      keep)
        sleep "$TICK" ;;
      signal)
        signal_graceful_shutdown
        grace_started=1
        grace_start="$now"
        sleep "$TICK" ;;
      hardstop|reap)
        break ;;
    esac
  done
}

# Run the loop only when executed, not when sourced (so tests can source us).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
