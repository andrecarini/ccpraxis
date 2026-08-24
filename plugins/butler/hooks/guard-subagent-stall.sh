#!/usr/bin/env bash
# guard-subagent-stall.sh — refuse to end a turn that dispatched a background
# subagent without arming a stall guard for it.
#
# WHY THIS EXISTS
#
# A background subagent that hangs or dies silently never wakes the session. The
# harness notifies on completion; it does not notify on "never completed". So an
# unattended run dispatches a worker, ends the turn, and simply stops — and the
# operator finds it hours later. This has happened repeatedly, and the fix was
# repeatedly written down as guidance: dispatch, then arm a bounded guard.
#
# Guidance did not hold. That is not a surprise in this repo: guard-git-mutations.sh
# exists because a prohibited `git stash` destroyed a completed fix-batch that a
# written instruction was supposed to protect. The thesis there applies here —
# A WRITTEN INSTRUCTION IS NOT AN ENFORCEMENT MECHANISM. So this is a gate.
#
# HOW IT WORKS — A STATE MACHINE, NOT A DETECTOR
#
# Two earlier versions of this gate were detectors, and both were wrong in the
# same way. The first cleared the alarm when a Bash command merely CONTAINED a
# token, so a guard that died on launch satisfied it. The second read the
# closing prose for "next I'll ...", which can be sidestepped by rephrasing a
# sentence. A detector is only ever as good as its guesses.
#
# So the default is inverted. The gate is INERT until a run demonstrably
# starts, and from then on the turn may not end until the agent RESOLVES the
# run — explicitly, with a verb:
#
#   PostToolUse/Task  — a background dispatch ACTIVATES the run (and is
#                       recorded by name, so the denial can name it).
#   PostToolUse/Bash  — a director tick whose RESPONSE handed back work also
#                       activates. Activation is never something the agent must
#                       remember to do.
#   Stop              — state active? DENY. Only `bp-runstate.pl finish` or a
#                       verified `bp-runstate.pl pause` resolves it.
#
# Silence is not a resolution, and neither is a plausible sentence. A pause
# must name a watcher pid that is RUNNING and a deadline in the FUTURE, both
# verified at read time; a pause whose watcher dies reverts to active by
# itself, so it cannot hold the gate open after it stops meaning anything.
#
# DELIBERATELY NOT GATED. There is no bp_hook_gate call here, by design and for
# the same reason guard-git-mutations.sh has none: bp_hook_gate exits 0 unless
# BP_LEDGER/BP_DIR/BP_PROJECT_ROOT are set, and those are exported only by
# bp-launch.sh into headless coordinators. A drive-solo run — the exact place
# subagents are dispatched by hand and the exact place this failure has bitten —
# would open the gate and enforce nothing. See coordinator-protocol/SKILL.md,
# "…but only inside a butler-LAUNCHED coordinator".
#
# FAIL-OPEN, ON PURPOSE. Every unexpected condition (no JSON parser, unwritable
# state dir, unreadable payload) exits 0 and allows the turn to end. A guard that
# can wedge a session is worse than the stall it prevents: the stall costs
# latency, a wedge costs the run. The one thing it will not do is fail open
# SILENTLY on the case it exists for — a pending dispatch always denies.
set -u
HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
# Sourced for bp_json_get ONLY -- NO bp_hook_gate here, by design (see above).
source "$HOOK_DIR/lib.sh"

PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

EVENT=$(bp_json_get "$PAYLOAD" hook_event_name) || exit 0
SESSION=$(bp_json_get "$PAYLOAD" session_id) || SESSION=""
[ -n "$SESSION" ] || SESSION="nosession"
# Session ids are uuid-shaped; refuse anything else rather than build a path
# from unvalidated input.
case "$SESSION" in
  *[!A-Za-z0-9._-]*) SESSION="nosession" ;;
esac

# State lives beside the project's other local data, never in the repo proper.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$HOOK_DIR/../../.." && pwd)}"
STATE_DIR="$ROOT/.ccpraxis-local-data/.subagent-guard"
STATE="$STATE_DIR/$SESSION"

mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

case "$EVENT" in
  PostToolUse)
    TOOL=$(bp_json_get "$PAYLOAD" tool_name) || exit 0
    case "$TOOL" in
      Task|Agent)
        # Only BACKGROUND dispatches can strand the session. A synchronous run
        # (run_in_background:false) holds the turn open, so the harness is still
        # waiting and a hang is visible. The Agent tool defaults to background,
        # so absence of the field counts as background.
        #
        # bp_json_get CANNOT answer this one: it yields the first NON-EMPTY
        # scalar, so a JSON `false` and an absent key both come back empty, and
        # every synchronous dispatch would be recorded as background. This needs
        # a tri-state read — true / false / absent — so it gets its own decode.
        #
        # Undeterminable (no perl, unparseable payload) is treated as BACKGROUND,
        # i.e. a guard is required. That is the safe direction for THIS decision
        # even though the hook is fail-open overall: guessing "synchronous" would
        # silently disable the gate, which is the defect, not a degradation of it.
        BG=$(printf '%s' "$PAYLOAD" | perl -MJSON::PP -0777 -ne '
            my $j = eval { JSON::PP->new->decode($_) } or exit 0;
            my $v = eval { $j->{tool_input}{run_in_background} };
            exit 0 unless defined $v;
            print( (ref $v ? !!$v : ($v ne "" && $v ne "0" && $v ne "false")) ? "true" : "false" );
        ' 2>/dev/null) || BG=""
        [ "$BG" = "false" ] && exit 0
        DESC=$(bp_json_get "$PAYLOAD" tool_input.description) || DESC="(unnamed)"
        printf '%s\n' "$DESC" >> "$STATE" 2>/dev/null || true
        # ACTIVATE on the observable fact that a run started. Activation must
        # never be a thing the agent remembers to do -- anything it must
        # remember is a thing it will eventually forget, which is the entire
        # reason this gate exists.
        [ -f "$HOOK_DIR/../scripts/bp-runstate.pl" ] && \
          perl "$HOOK_DIR/../scripts/bp-runstate.pl" activate --root "$ROOT" \
               --reason "background subagent dispatched: $DESC" >/dev/null 2>&1
        exit 0
        ;;
      Bash)
        # NOTHING is cleared here, deliberately.
        #
        # The first version of this hook cleared the pending set when it saw a
        # Bash command containing the token BP_STALL_GUARD. That verified
        # CEREMONY, NOT FUNCTION: a guard that exits immediately, watches the
        # wrong path, or is syntactically broken contains the token just as well
        # as a working one. It is the same vacuity trap this repo keeps paying
        # for -- a check that cannot fail (see bp-ledger.pl's
        # INSTALLED+SKIPPED+FAILED==ITEMS identity, package a03).
        #
        # A guard now proves itself instead, through bp-runstate.pl's `pause`,
        # which refuses a watcher pid that is not running or a deadline that is
        # not in the future. Ceremony cannot satisfy it.
        #
        # What DOES happen here is the second activation trigger: a director
        # tick that handed back work means a run is underway, whether or not a
        # subagent was dispatched. Reading the RESPONSE (not the command) is
        # deliberate -- the command only says what was asked, the response says
        # what came back.
        #
        # `run-package` ONLY. `need-order` used to activate here too, and that
        # was wrong in a way that produced a closed loop.
        #
        # `need-order` is not work handed back -- it is the director DECLINING
        # to choose, because the answer belongs to the operator (e.g. two
        # delivered blueprints and no order covering them: `scope-extends-order`).
        # Nothing is underway, so there is nothing for a Stop gate to protect.
        # Worse: an agent that consults the director to CHECK whether anything
        # is pending was reactivating the very run it had just finished. The
        # diagnostic mutated the thing being diagnosed, and the session could
        # not leave: finish -> consult -> reactivate -> blocked stop -> finish.
        # Observed 2026-08-24.
        #
        # This loses nothing. When a drive is genuinely underway and hits
        # need-order, the run is ALREADY active and activation is a no-op --
        # activation only has an effect on a run that is idle or finished, and
        # that is exactly the false positive.
        RESP=$(bp_json_get "$PAYLOAD" tool_response.stdout tool_response) || RESP=""
        case "$RESP" in
          *'"action":"run-package"'*)
            [ -f "$HOOK_DIR/../scripts/bp-runstate.pl" ] && \
              perl "$HOOK_DIR/../scripts/bp-runstate.pl" activate --root "$ROOT" \
                   --reason "director handed back work" >/dev/null 2>&1
            ;;
        esac
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;

  Stop)
    # THE GATE. Inert until a run starts; once active, the turn may not end
    # until the agent RESOLVES it. See bp-runstate.pl for why this is a state
    # machine rather than a detector: the two previous attempts both asked
    # "does anything look wrong?", and a detector is only as good as its
    # guesses -- one accepted a guard that had already died, the other could be
    # sidestepped by rephrasing a sentence.
    # THE PENDING SET IS CLEARED WHEN THE TURN IS ALLOWED TO END, AND ONLY THEN.
    #
    # Closes almanac report 20260819-014748-0b41, filed against this hook: the
    # state file was append-only and nothing ever truncated it, so the denial
    # message below listed EVERY background dispatch of the whole session under
    # the heading "this turn". By the end of a long unattended run that is fifty
    # entries, most of them hours old and already resolved -- noise that buries
    # the two lines an operator actually needs to read.
    #
    # It is the same shape as the defect package t07 exists to fix in
    # runs/needs-you/: broad write, no clear. The rule that resolves both is the
    # same one -- clear when the thing the record was tracking is demonstrably
    # over -- and here that moment is unambiguous: an ALLOWED Stop means the run
    # was resolved (finished, or paused behind a watcher whose pid and deadline
    # bp-runstate.pl verified), so every dispatch recorded up to now is
    # accounted for.
    #
    # DELIBERATELY NOT CLEARED ON A DENIED STOP. A dispatch made two turns ago
    # and still unresolved is still unresolved, and dropping it would hide
    # exactly the thing this hook exists to surface. That is why the heading now
    # says "since the last resolved turn" rather than "this turn" -- the old
    # wording was a second, smaller defect in the same report: it described a
    # window the file never had.
    _clear_pending() { : > "$STATE" 2>/dev/null || true; }

    [ -f "$STATE_DIR/force-stop" ] && { _clear_pending; exit 0; }

    RS="$HOOK_DIR/../scripts/bp-runstate.pl"
    [ -f "$RS" ] || exit 0                      # fail open: no state machine, no gate
    ST=$(perl "$RS" status --root "$ROOT" 2>/dev/null) || exit 0
    case "$ST" in
      *'"state":"active"'*) ;;                 # fall through to the denial
      *) _clear_pending; exit 0 ;;              # inert / paused / finished -> allow
    esac

    PENDING=""
    [ -s "$STATE" ] && PENDING=$(tr '\n' ';' < "$STATE" 2>/dev/null | sed 's/;$//')
    STALE=""
    case "$ST" in *'"stale_pause":1'*) STALE=" (a previous pause went stale: its watcher is gone)";; esac
    # t10-run-continuity-gaps: if the pause that just went stale never named
    # anything it was waiting for, say so HERE -- at the moment the failure is
    # visible -- rather than leaving the reader to work out why a well-formed
    # pause achieved nothing. bp-runstate.pl already warned when the pause was
    # granted; this is the same fact arriving a second time, when it has
    # actually cost something.
    case "$ST" in
      *'"hollow_pause":1'*)
        case "$STALE" in
          ?*) STALE="$STALE
       That pause named no work: a live pid is not evidence anything was in
       flight, so it idled to its deadline. Pass --watching '<what>' next time." ;;
        esac
        ;;
    esac

    cat >&2 <<EOF
BLOCKED: a run is ACTIVE and this turn did not resolve it.$STALE
${PENDING:+Unguarded background dispatch(es) since the last resolved turn: $PENDING
}
A turn that ends mid-run without resolving it is how an unattended run dies:
nothing is scheduled, nothing wakes the session, and the work simply stops.
Silence is not a resolution. There are exactly two, and you must pick one:

  1. The run is FINISHED -- nothing is pending:

       perl plugins/butler/scripts/bp-runstate.pl finish --reason "<why>"

  2. The run CONTINUES but something live will wake it. Arm a watcher first
     (Bash, run_in_background: true), then declare the pause. The pid must be
     RUNNING and the deadline in the FUTURE -- this is verified, not trusted:

       perl plugins/butler/scripts/bp-runstate.pl pause \
            --watcher-pid <pid> --until \$(( \$(date +%s) + 1800 )) \
            --watching "<the work in flight -- an agent, a task id, a command>" \
            --reason "<what will wake us>"

     ARM THE WATCHER AROUND REAL WORK, not the other way round. A live pid is
     verified; it is not evidence that anything is running. A pause with every
     dispatched worker already finished and nothing new dispatched satisfies
     every check here and still leaves nothing to wake the session -- it just
     fails later, when the deadline expires. --watching is not enforced and
     never refuses a pause; it exists so the emptiness is visible while you can
     still fix it.

If instead you are about to do the work, DO IT NOW in this turn.
A pause whose watcher dies reverts to active by itself, so a stale pause cannot
hold the gate open. touch $STATE_DIR/force-stop to override entirely.
EOF
    exit 2
    ;;

  *) exit 0 ;;
esac
