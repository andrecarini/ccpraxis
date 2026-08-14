#!/usr/bin/env bash
# mark-wakeup.sh — PreToolUse hook for Task, Agent and Bash, in a DRIVE-SOLO
# DRIVER session (never in a coordinator).
#
# Records that this turn started something that will wake the session up again:
#   * any Task or Agent dispatch (a subagent; its completion notification
#     comes back), or
#   * a Bash call with run_in_background=true (its exit notification comes back).
#
# gate-drive-loop.sh (Stop) CONSUMES this marker. The pair encodes one rule:
#
#     A driver turn may end EITHER because something will wake it,
#     OR because the director says the run is settled. Never for any
#     other reason.
#
# Why this exists. /butler:drive-solo describes the driver as "a thin loop over
# the director": call `bp-drive-next.pl next`, dispatch the action it returns,
# call `next` again. That is prose, and prose decays over a long context. The
# observed failure — three times in one 12-hour run on 2026-08-07 — is a turn
# that ends right after a ledger write, with text promising the next step and
# nothing scheduled to perform it. A dispatched agent notifies; a finished Bash
# call does not. So the run dies silently, mid-package, looking finished.
#
# This is the same argument gate-stop.sh already makes for coordinators ("converts
# ledger discipline from a prompt rule (which decays over long contexts) into a
# mechanical gate"), and the same one guard-git-mutations.sh makes in this repo's
# CLAUDE.md: a written instruction is not an enforcement mechanism.
#
# NEVER blocks anything: it only writes a marker. Exit 0 on every path.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$HOOK_DIR/lib.sh"

# Coordinator sessions are gate-stop.sh's business, not ours. BP_LEDGER is
# exported only into coordinator processes, so its ABSENCE is what identifies
# an interactive driver.
[ -n "${BP_LEDGER:-}" ] && exit 0

PAYLOAD=$(cat 2>/dev/null || true)

# Resolve the drive-solo state dir exactly as bp-drive-next.pl does: an explicit
# CCPRAXIS_DATA_DIR wins, else <project>/.ccpraxis-local-data. No .drive-solo dir
# means no drive-solo run is in progress here and this hook is irrelevant.
#
# ⚠ bp_find_data_dir, NOT a local while-loop. The loop that used to live here
# did not terminate on Windows: dirname("C:") is "C:", which is neither empty
# nor "/", so any session whose cwd had no .ccpraxis-local-data ancestor spun
# until the 15s hook timeout — on EVERY Bash call and EVERY Task dispatch, in
# every unrelated project on the machine. See bp_find_data_dir in lib.sh.
CWD=$(bp_json_get "$PAYLOAD" cwd 2>/dev/null || true); CWD=${CWD:-$PWD}
DATA=$(bp_find_data_dir "$CWD" 2>/dev/null || true)

TOOL=$(bp_json_get "$PAYLOAD" tool_name 2>/dev/null || true)

# ---------------------------------------------------------------------------
# REPORTER REGISTRATION (g03-reporter-stop-gate). A reporter session never
# calls the director, so the driver-arm regex below can never see it -- see
# the package spec §1.2 for why the trigger is exactly this shape. It keys
# off the exact Bash command `bp-watch.pl --arm ... --blueprint <bp>` (Mode
# B), which is PROVABLY DISJOINT from the driver's own `--package` shape:
# bp-watch.pl's own arg parser refuses --package and --blueprint together
# (pinned by 142-reporter-registration.t section B), so the flag that
# selects Mode B cannot appear in a driver's own invocation.
#
# MUST run BEFORE the `.drive-solo` early-exit below: a project where
# drive-solo has never run (the common case for a reporter-only project)
# would otherwise never reach this block at all (spec §2.1's load-bearing
# ordering note).
#
# Mirrors bp_drive_marker's shape (lib.sh) but inlined -- lib.sh is outside
# this package's write set. The match requires the literal invocation, not
# merely the string: a Read of reporter/SKILL.md, a grep for bp-watch.pl, or
# an echoed/greped command naming it never executes it, so none of those
# arm a session -- same discipline the driver's own regex below already
# relies on (a command that merely NAMES the script does not run it).
#
# Uses bp_json_get throughout, like the rest of this file -- the house idiom,
# reliable on a correctly-escaped payload (verified: 142-reporter-registration.t
# builds every fixture with a real JSON encoder, not string interpolation).
if [ "$TOOL" = "Bash" ]; then
  RCMD=$(bp_json_get "$PAYLOAD" tool_input.command 2>/dev/null || true)
  # A plain 'bp-watch.pl[^"]*--arm[^"]*--blueprint' substring match on $RCMD
  # is NOT enough on its own: it also matches an ECHOED/GREPPED string naming
  # the invocation (e.g. `echo "run bp-watch.pl --arm --blueprint later"`),
  # because no `"` happens to fall BETWEEN bp-watch.pl and --blueprint in
  # that case either -- the surrounding quotes are further out, around the
  # whole echoed phrase. Verified live against the DRIVER's own analogous
  # arm regex below, on a correctly JSON-escaped payload (not a malformed
  # one): `bp-drive-next\.pl[^"]*(next|record-order|park)` matches an
  # equivalent echoed `bp-drive-next.pl next` command too, for the identical
  # reason -- that regex is NOT reliable prior art for this problem, only a
  # superficially similar one whose own oracle (t/142 section H) happens to
  # assert an unrelated file, not the arm marker.
  #
  # What DOES distinguish a real invocation from a quoted reference is QUOTE
  # PARITY immediately before "bp-watch.pl" in the DECODED command text (the
  # actual bash command bytes bp_json_get returns, already un-escaped -- so
  # this check does not depend on any JSON-escaping convention at all): in
  # the real call (`perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm
  # --blueprint ...`) there are 0 or 2 quote chars before it (fully closed
  # pairs, e.g. the CLAUDE_PLUGIN_ROOT expansion) -- EVEN, so "bp-watch.pl"
  # sits OUTSIDE any open quote, i.e. it is the literal command being run.
  # In an echoed/grepped reference the whole phrase sits INSIDE one
  # still-open quoted argument (`echo "run bp-watch.pl ...`) -- exactly ONE
  # quote char precedes it -- ODD. Checked with perl (already required by
  # this hook family) rather than reimplemented as bash arithmetic.
  ARMED=$(printf '%s' "$RCMD" | perl -0777 -ne '
      my $armed = 0;
      if (/^(.*?)(bp-watch\.pl.*)$/s) {
        my ($prefix, $tail) = ($1, $2);
        my $quotes = () = $prefix =~ /"/g;
        if ($quotes % 2 == 0 && $tail =~ /^bp-watch\.pl[^"]*--arm[^"]*--blueprint\b/) {
          $armed = 1;
        }
      }
      print $armed ? "1" : "0";
    ' 2>/dev/null || echo 0)
  if [ "$ARMED" = "1" ]; then
    RSID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
    case "$RSID" in ''|*/*|*\**|.|..|*..*) RSID="" ;; esac
    if [ -n "$RSID" ] && [ -n "$DATA" ]; then
      RDIR="${CCPRAXIS_REPORTER_ACTIVE_DIR:-${HOME:-$PWD}/.claude/ccpraxis/.reporter-active}"
      mkdir -p "$RDIR" 2>/dev/null && printf '%s\n' "$DATA" > "$RDIR/$RSID" 2>/dev/null || true
    fi
  fi
fi
# --- end reporter registration block ----------------------------------------

[ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ] || exit 0

# ---------------------------------------------------------------------------
# ARMING: this hook is what registers a session as a drive-solo DRIVER.
#
# A driver is not "a session in a directory where drive-solo once ran" — that
# was the old, wrong test, and it armed the Stop gate permanently for every
# session in the tree. A driver is a session that CALLS THE DIRECTOR. Nothing
# else does, and a session that never calls it is not driving no matter where
# it is running. So: see bp-drive-next.pl in a Bash command, register this
# session id; gate-drive-loop.sh then gates exactly that session and no other.
#
# Self-arming, so no skill or script has to remember to do it, and impossible
# to arm a session that never drove. The marker holds the data dir so the Stop
# hook needs no path walk of its own.
# The match requires the script AND one of its subcommands, so a command that
# merely NAMES the file -- a grep for it, an ls of the scripts dir, a sed over
# the source -- does not arm a session that is only reading about the director.
# The script rejects an empty subcommand ("usage: next|record-order|park"), so
# every real invocation carries one and nothing is lost by requiring it.
#
# The bias is deliberate and one-directional: a false POSITIVE arms a session
# that is not driving, which costs it one director call per stop and then
# disarms itself the moment the director answers 'done'. A false NEGATIVE
# leaves a real driver ungated, which is the silent mid-run death this whole
# pair exists to prevent. When in doubt, arm.
SID=$(bp_json_get "$PAYLOAD" session_id 2>/dev/null || true)
if [ "$TOOL" = "Bash" ] && [ -n "$SID" ]; then
  if printf '%s' "$PAYLOAD" | grep -Eq 'bp-drive-next\.pl[^"]*(next|record-order|park)'; then
    if MARK=$(bp_drive_marker "$SID" 2>/dev/null); then
      mkdir -p "$(dirname "$MARK")" 2>/dev/null \
        && printf '%s\n' "$DATA" > "$MARK" 2>/dev/null || true
    fi
  fi
fi

case "$TOOL" in
  Task|Agent)
    : ;;                                  # always a wake-up -- unchanged for Task, NEW for Agent.
                                           # Deliberately reads NO field off the payload (e.g. no
                                           # subagent_type): that field is verified present for
                                           # Task (track-dispatch.sh:24 and others) but UNVERIFIED
                                           # for Agent (h01 spec §2.3/§6), so this arm is a wake-up
                                           # purely by virtue of the tool name matching.
  Bash)
    # Only a BACKGROUNDED Bash call schedules a wake-up. A foreground command
    # returns into the same turn and schedules nothing, so it must not count.
    #
    # Matched with a raw regex rather than bp_json_get: run_in_background is a
    # JSON *boolean*, and bp_json_get returns EMPTY for booleans (verified
    # 2026-08-07 — it resolves string scalars only). Using it here would have
    # silently classified every backgrounded Bash call as foreground, so the
    # gate would have blocked turns that legitimately scheduled a wake-up.
    printf '%s' "$PAYLOAD" | grep -q '"run_in_background"[[:space:]]*:[[:space:]]*true' || exit 0 ;;
  *)
    exit 0 ;;
esac

mkdir -p "$DATA/.drive-solo" 2>/dev/null || exit 0
printf '%s %s\n' "$TOOL" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
  > "$DATA/.drive-solo/.wakeup-pending" 2>/dev/null || true
exit 0
