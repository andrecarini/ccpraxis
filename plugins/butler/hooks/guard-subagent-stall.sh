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
# HOW IT WORKS (three events, one script)
#
#   PostToolUse/Task  — a background dispatch marks the turn UNGUARDED.
#   PostToolUse/Bash  — a command containing the token BP_STALL_GUARD clears it.
#   Stop              — if the turn is still UNGUARDED, DENY the stop and say so.
#
# The token is the contract, and it is deliberately explicit rather than clever:
# a heuristic that tried to recognise "looks like a guard" would either miss real
# guards or accept things that never wake anyone. An armed guard must literally
# say BP_STALL_GUARD, and that string is what this hook counts.
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
        # A guard now proves itself instead: it writes its OWN pid and deadline
        # into $STATE_DIR/armed, and the Stop branch below verifies that process
        # is ALIVE and that deadline is in the FUTURE. A guard that died on
        # launch cannot satisfy that, no matter what its text said.
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;

  Stop)
    # ---- (a) ANNOUNCED-BUT-DIDN'T: ending a turn by promising work ----------
    #
    # "Next I'll commit these" as a closing line silently kills an unattended
    # run: nothing is scheduled, so the promise is never kept and the session
    # just stops. This is a SEPARATE failure from the unguarded-dispatch one
    # below -- no subagent is involved, so that marker is empty and the branch
    # below never fires.
    #
    # HONEST LIMIT: this half is a HEURISTIC over prose, unlike the structural
    # check below. It reads the last assistant message and looks for a
    # first-person promise of imminent work. It can misfire on a legitimate
    # "I'll pick this up when the worker reports" -- which is why it only fires
    # when NOTHING is scheduled to wake the session, and why it is bounded by
    # the same TTL and force-stop as everything else here. A misfire costs one
    # extra turn; the failure it prevents costs the whole run.
    if [ -z "${BP_NO_PROMISE_GATE:-}" ] && [ ! -f "$STATE_DIR/force-stop" ]; then
      TP=$(bp_json_get "$PAYLOAD" transcript_path) || TP=""
      # A live guard or a pending dispatch means something WILL wake us, so a
      # forward-looking sentence is fine. Only an unscheduled promise is a bug.
      SCHEDULED=0
      if [ -f "$STATE_DIR/armed" ]; then
        A_PID=$(sed -n '1p' "$STATE_DIR/armed" 2>/dev/null | tr -d ' \r')
        case "$A_PID" in ''|*[!0-9]*) A_PID="" ;; esac
        [ -n "$A_PID" ] && kill -0 "$A_PID" 2>/dev/null && SCHEDULED=1
      fi
      if [ "$SCHEDULED" = "0" ] && [ -n "$TP" ] && [ -f "$TP" ] && [ ! -f "$STATE_DIR/promise-denied" ]; then
        PROMISE=$(perl -MJSON::PP -e '
            my ($tp) = @ARGV;
            open my $fh, "<", $tp or exit 0;
            my $last = "";
            while (my $l = <$fh>) {
                my $j = eval { JSON::PP->new->decode($l) } or next;
                next unless ($j->{type} // "") eq "assistant";
                my $c = eval { $j->{message}{content} } or next;
                next unless ref $c eq "ARRAY";
                my $t = join " ", map { $_->{text} // "" } grep { ($_->{type}//"") eq "text" } @$c;
                $last = $t if length $t;
            }
            close $fh;
            exit 0 unless length $last;
            # Only the CLOSING stretch matters: a promise mid-message that the
            # message then fulfils is not the failure.
            my $tail = length($last) > 400 ? substr($last, -400) : $last;
            my @pat = (
                qr/\bnext(?:,| I| step)?[^.]{0,40}\bI(?:\x27ll| will)\b/i,
                qr/\bI(?:\x27ll| will)\s+(?:now\s+)?(?:commit|run|dispatch|fix|write|implement|continue|start|kick off|re-?run|take|pick up|proceed)\b/i,
                qr/\b(?:then|after that|once .{0,30} lands?)\s+I(?:\x27ll| will)\b/i,
                qr/\bdoing (?:it|that) now\b/i,
                qr/\bon it now\b/i,
            );
            for my $p (@pat) { if ($tail =~ $p) { print "1"; exit 0 } }
            exit 0;
        ' "$TP" 2>/dev/null) || PROMISE=""
        if [ "$PROMISE" = "1" ]; then
          : > "$STATE_DIR/promise-denied" 2>/dev/null || true
          cat >&2 <<'PEOF'
BLOCKED: this turn ends by announcing work it did not do, and nothing is scheduled to continue.

"Next I'll ..." as a closing line is how an unattended run dies: the turn ends,
nothing wakes the session, and the promised work never happens. If you are about
to do it, DO IT NOW in this turn. If it genuinely must wait on something, arm a
guard so the session actually resumes, or ask the operator a direct question and
stop on that instead.

This fires once; stopping again is allowed, so it corrects rather than traps.
Set BP_NO_PROMISE_GATE=1 to disable, or touch force-stop to override.
PEOF
          exit 2
        fi
      fi
    fi
    rm -f "$STATE_DIR/promise-denied" 2>/dev/null || true

    # ---- (b) UNGUARDED BACKGROUND DISPATCH ---------------------------------
    [ -s "$STATE" ] || exit 0

    # Escape hatch, mirroring gate-stop.sh's force-stop: a gate that cannot be
    # overridden is a gate that can strand the operator.
    if [ -f "$STATE_DIR/force-stop" ]; then
      rm -f "$STATE" 2>/dev/null || true
      exit 0
    fi

    # TTL. The marker is NOT cleared on deny — clearing meant one missed guard
    # was caught once and every retry sailed through, which is advice, not
    # enforcement. Instead it expires, so it can neither be bypassed by simply
    # stopping again nor wedge the session forever.
    TTL="${BP_STALL_GUARD_TTL_S:-900}"
    AGE=$(perl -e 'my @s = stat($ARGV[0]); print defined $s[9] ? (time - $s[9]) : 0' "$STATE" 2>/dev/null) || AGE=0
    case "$AGE" in ''|*[!0-9]*) AGE=0 ;; esac
    if [ "$AGE" -gt "$TTL" ]; then
      rm -f "$STATE" 2>/dev/null || true
      exit 0
    fi

    # Is a guard genuinely ARMED — a live process with a deadline still ahead?
    # This is the check the token-matching version could not make.
    ARMED="$STATE_DIR/armed"
    if [ -f "$ARMED" ]; then
      G_PID=$(sed -n '1p' "$ARMED" 2>/dev/null | tr -d ' \r')
      G_DL=$(sed -n '2p' "$ARMED" 2>/dev/null | tr -d ' \r')
      case "$G_PID" in ''|*[!0-9]*) G_PID="" ;; esac
      case "$G_DL"  in ''|*[!0-9]*) G_DL=0  ;; esac
      NOW=$(date +%s 2>/dev/null || echo 0)
      if [ -n "$G_PID" ] && kill -0 "$G_PID" 2>/dev/null && [ "$G_DL" -gt "$NOW" ]; then
        rm -f "$STATE" 2>/dev/null || true
        exit 0
      fi
      # A registration whose process is gone, or whose deadline has passed, is
      # WORSE than none: it looks like cover while watching nothing. Say so.
      rm -f "$ARMED" 2>/dev/null || true
    fi

    PENDING=$(wc -l < "$STATE" 2>/dev/null | tr -d ' ') || PENDING="?"
    NAMES=$(tr '\n' ';' < "$STATE" 2>/dev/null | sed 's/;$//')
    cat >&2 <<EOF
BLOCKED: $PENDING background subagent dispatch(es) this turn with no LIVE stall guard: $NAMES

A background subagent that hangs or dies silently NEVER wakes this session. The
harness notifies on completion; it does not notify on "never completed". Ending
the turn here is how an unattended run stops dead and is found hours later.

Arm a real guard before you stop: one Bash call with run_in_background: true.
It must REGISTER ITSELF (pid + deadline) so this gate can verify it is alive --
a command that merely mentions a guard proves nothing, and a guard that died on
launch must not pass. It must also exit on EITHER outcome, so silence is never
mistaken for progress:

  REPORT="<the worker's report path>"
  DEADLINE=\$(( \$(date +%s) + 1500 ))
  printf '%s\n%s\n' "\$\$" "\$DEADLINE" > "$STATE_DIR/armed"
  while [ ! -f "\$REPORT" ] && [ "\$(date +%s)" -lt "\$DEADLINE" ]; do sleep 15; done
  rm -f "$STATE_DIR/armed"
  if [ -f "\$REPORT" ]; then echo "GUARD: REPORT-PRESENT"; else
    echo "GUARD: STALL-DEADLINE, no report on disk"
    find plugins -type f -mmin -25 -not -path '*/.git/*' -printf '  %TH:%TM %p\n' | head
    echo "(no lines above = the worker is dead, not slow)"
  fi

This marker is NOT cleared by being denied -- stopping again will be denied too.
It expires on its own after ${TTL}s so it cannot wedge the session, and
touching $STATE_DIR/force-stop overrides it outright.
EOF
    exit 2
    ;;

  *) exit 0 ;;
esac
