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
# run clears (or at the grace deadline). No active run → reaps at the HB
# threshold. HB, the grace window, the tick, and the startup grace are all kept
# deliberately loose (10 min / 10 min / 60s / 10 min) so a transient blip — a
# host display-off drift, a slow tick, a momentary manager stall — never trips a
# reap; B6 only makes an actual prolonged-manager-loss reap gentler
# (Decisions #6 / #28).
#
# Sourcing this file (for tests) defines the functions but does NOT run the loop
# (the `main` guard at the bottom keys off BASH_SOURCE==$0).

set -u

# ----- tunables (env-overridable; defaults match the historical entrypoint) ---
ALIVE="${ALIVE:-/tmp/.launcher-alive}"        # manager heartbeat sentinel (host touches it)
BUSY="${BUSY:-/tmp/.butler-busy}"             # orchestrator busy-lease (A3)
HB="${HB:-600}"                               # staleness window (s) — 10 min; loose so a host display-off drift / manager stall never trips a reap
STARTUP_GRACE="${STARTUP_GRACE:-600}"         # startup grace before first check — 10 min (covers long backpack installs before the dashboard takes over)
GRACE_SHUTDOWN="${GRACE_SHUTDOWN:-600}"       # graceful-park window once a stale-with-run is detected — 10 min
TICK="${TICK:-60}"                            # loop poll interval (s)
DATA="${CCPRAXIS_DATA_DIR:-/project/.ccpraxis-local-data}"   # blueprint data root
SUSPEND_SLACK="${SUSPEND_SLACK:-120}"         # a tick overshooting TICK by this much means the world was suspended, not that the manager died
POST_WAKE_GRACE="${POST_WAKE_GRACE:-600}"     # after a detected resume, give the manager this long to re-touch the sentinel before staleness counts again
REAP_RECORD="${REAP_RECORD:-$DATA/claude-home/.launcher/last-reap.txt}"   # host-visible: WHY this container stopped

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
  local post_wake="${5:-0}"
  # A stale sentinel means "the manager is gone" ONLY if the manager had a
  # chance to touch it. After the host resumes from suspend it has not: the
  # whole world was frozen, the mtime is old for a reason that says nothing
  # about the manager's health, and the manager will re-touch within a tick.
  # Reaping here destroys a container whose manager is alive and about to
  # check in. See suspend_detected() for how this is established, and the
  # 2026-08-08 incident note below for what it cost. 5th arg is optional so
  # every pre-existing 4-arg caller keeps its exact meaning.
  if [ "$post_wake" = 1 ]; then echo keep; return; fi
  if [ "$hb_stale" != 1 ]; then echo keep; return; fi   # heartbeat alive -> keep
  if [ "$run_active" != 1 ]; then echo reap; return; fi  # stale + no run -> reap
  if [ "$grace_started" != 1 ]; then echo signal; return; fi
  if [ "$grace_expired" = 1 ]; then echo hardstop; return; fi
  echo keep
}

# suspend_detected ELAPSED TICK THRESHOLD -> 1 if the wall clock jumped far
# further than this loop's own sleep can explain, else 0. PURE.
#
# The loop sleeps TICK seconds per iteration, so a healthy iteration advances
# the clock by about TICK. If it advanced by TICK + THRESHOLD or more, time
# passed that this process did not spend sleeping: the machine was suspended
# (Windows "connected standby" / Modern Standby S0ix, a laptop lid, a VM
# pause). That is a fact about the WORLD, not about the manager, and it is the
# only signal available in-container -- the sentinel's mtime cannot distinguish
# "manager died an hour ago" from "everything was frozen for an hour".
suspend_detected() {
  local elapsed="$1" tick="$2" threshold="$3"
  [ "$elapsed" -ge $(( tick + threshold )) ] && echo 1 || echo 0
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

# reap_explanation VERDICT HB_AGE RUN_ACTIVE SUSPENDS -> the human sentence.
# PURE, so the wording is unit-testable and cannot drift from the decision it
# describes.
#
# Every branch says what happened AND what it implies, because the reader is
# someone who came back to a stopped container with no other evidence. "Exited
# (0)" is all podman will tell them, and an exit code of zero on a container
# that was supposed to still be running is the least informative true statement
# available.
reap_explanation() {
  local verdict="$1" hb_age="$2" run_active="$3" suspends="$4"
  case "$verdict" in
    reap)
      printf 'The host manager stopped touching the heartbeat sentinel %ss ago (limit %ss) and no butler run was active, so this container shut itself down.' "$hb_age" "$HB"
      if [ "$suspends" -gt 0 ]; then
        printf ' NOTE: %s host suspend(s) were detected during this container'"'"'s life. If the manager was alive the whole time, the sentinel was stale because the MACHINE was asleep, not because the manager died.' "$suspends"
      fi ;;
    hardstop)
      printf 'The host manager stopped touching the heartbeat sentinel %ss ago (limit %ss) while a butler run was still active. A graceful shutdown was signalled and coordinators were given %ss to park; that window expired with the run still live, so this container was stopped anyway.' "$hb_age" "$HB" "$GRACE_SHUTDOWN" ;;
    *)
      printf 'Container stopped with verdict "%s" (heartbeat %ss old).' "$verdict" "$hb_age" ;;
  esac
}

# write_reap_record — leave a durable, HOST-VISIBLE note saying why this
# container stopped. Best-effort and never fatal: failing to explain must not
# change whether we stop.
#
# WHY THIS EXISTS (incident 2026-08-08). A dispatch fleet was left unattended.
# The host entered Windows connected standby at 20:23:33 and resumed at
# 02:03:50 -- five hours forty minutes -- and this loop reaped the container at
# 02:03:52, two seconds after the resume, before the manager could re-touch the
# sentinel. The operator returned to a dead container and there was NOTHING to
# read: the loop simply `break`s, the container exits 0, and podman reports
# "Exited (0)". A clean exit code on a container that was supposed to still be
# running is the least useful true statement available. The reap is now loud.
#
# REAP_RECORD lives under the project's bind-mounted data dir, so it survives
# the container and the host TUI can surface it on the next launch.
write_reap_record() {
  local verdict="$1" hb_age="$2" run_active="$3" suspends="$4"
  local dir; dir=$(dirname "$REAP_RECORD" 2>/dev/null) || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  {
    printf 'when=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf 'verdict=%s\n' "$verdict"
    printf 'heartbeat_age_s=%s\n' "$hb_age"
    printf 'heartbeat_limit_s=%s\n' "$HB"
    printf 'run_active=%s\n' "$run_active"
    printf 'host_suspends_detected=%s\n' "$suspends"
    printf 'why=%s\n' "$(reap_explanation "$verdict" "$hb_age" "$run_active" "$suspends")"
  } > "$REAP_RECORD" 2>/dev/null || return 0
  return 0
}

# =============================================================================
# PURE PORT RANGE (unit-tested — defined at file scope so sourcing exposes it)
# =============================================================================
# bridged_ports -> space-separated list of ports to socat-bridge.
# Priority:
#   1. SANDBOX_BRIDGED_PORTS=lo-hi  (explicit range from launcher)
#   2. SANDBOX_PORT_BASE=N          (base; bridges N..N+9)
#   3. default                      (9000..9009, back-compat)
bridged_ports() {
  if [[ -n "${SANDBOX_BRIDGED_PORTS:-}" && "${SANDBOX_BRIDGED_PORTS}" =~ ^[0-9]+-[0-9]+$ ]]; then
    local lo hi
    lo="${SANDBOX_BRIDGED_PORTS%-*}"
    hi="${SANDBOX_BRIDGED_PORTS#*-}"
    local ports=()
    local p
    for (( p=lo; p<=hi; p++ )); do ports+=("$p"); done
    echo "${ports[*]}"
  elif [[ -n "${SANDBOX_PORT_BASE:-}" && "${SANDBOX_PORT_BASE}" =~ ^[0-9]+$ ]]; then
    local ports=()
    local p
    for (( p=SANDBOX_PORT_BASE; p<=SANDBOX_PORT_BASE+9; p++ )); do ports+=("$p"); done
    echo "${ports[*]}"
  else
    echo "9000 9001 9002 9003 9004 9005 9006 9007 9008 9009"
  fi
}

# =============================================================================
# MAIN LOOP
# =============================================================================
main() {
  # socat bridges for the assigned port block (env-driven; default 9000-9009 back-compat).
  local p
  for p in $(bridged_ports); do
    socat TCP-LISTEN:"$p",fork,reuseaddr TCP:127.0.0.1:"$p" 2>/dev/null &
  done

  local start; start=$(now_epoch)
  local grace_started=0 grace_start=0
  local last_tick; last_tick=$(now_epoch)
  local wake_until=0 suspends=0

  while true; do
    local now; now=$(now_epoch)

    # Did the world stop while we were sleeping? A tick that advanced the clock
    # far past our own sleep means the machine was suspended. The sentinel is
    # then stale for a reason that says nothing about the manager, so open a
    # post-wake window and let the manager check in before staleness counts.
    local elapsed=$(( now - last_tick ))
    if [ "$(suspend_detected "$elapsed" "$TICK" "$SUSPEND_SLACK")" = 1 ]; then
      suspends=$(( suspends + 1 ))
      wake_until=$(( now + POST_WAKE_GRACE ))
    fi
    last_tick="$now"

    # startup grace: give the manager time to land the first heartbeat touch.
    if [ $(( now - start )) -lt "$STARTUP_GRACE" ]; then sleep 1; continue; fi

    local stale active grace_expired=0 post_wake=0
    stale=$(hb_stale "$now")
    active=$(run_active "$now")
    [ "$now" -lt "$wake_until" ] && post_wake=1
    if [ "$grace_started" = 1 ] && [ $(( now - grace_start )) -ge "$GRACE_SHUTDOWN" ]; then
      grace_expired=1
    fi

    local verdict
    verdict=$(reap_decision "$stale" "$active" "$grace_started" "$grace_expired" "$post_wake")
    case "$verdict" in
      keep)
        sleep "$TICK" ;;
      signal)
        signal_graceful_shutdown
        grace_started=1
        grace_start="$now"
        sleep "$TICK" ;;
      hardstop|reap)
        # Say why, durably and where the host can read it, BEFORE stopping.
        write_reap_record "$verdict" "$(mtime_age "$ALIVE" "$now")" "$active" "$suspends"
        break ;;
    esac
  done
}

# Run the loop only when executed, not when sourced (so tests can source us).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
