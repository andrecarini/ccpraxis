#!/usr/bin/env perl
# platform: windows
# 187 — an unattended run does not stop to ask.
#
# THE PATTERN THIS EXISTS TO END, in the operator's own words: "a whole
# unattended run halt because of some blocking user input. 99% of the times it
# was not actually necessary and could have progressed while batching the
# question to the end or having the agent decide by itself when it's a
# non-product question."
#
# Both halves matter. The stopping is expensive -- hours of idle time where work
# was available -- and the question usually did not need an operator at all.
# There has been a standing ruling to exactly this effect
# (guidance/escalate-product-decisions-only.md) and it kept being violated,
# which is this repo's recurring lesson: a written instruction is not an
# enforcement mechanism.
#
# UNATTENDED MEANS EITHER OF TWO THINGS, and both trip the guard: a RUN is
# active, or CONTINUITY IS ARMED for the session. The first version checked only
# the run, which missed the case actually described -- a plain armed overnight
# session sets no run state at all.
#
# WHAT MUST NOT HAPPEN IS OVER-BLOCKING. A session that is neither armed nor
# driving a run is free to ask; AC3 and AC4 are the counter-checks that keep
# this from becoming a blanket ban on talking to the operator.
#
# AC1  AskUserQuestion is denied while a run is ACTIVE
# AC2  ...and the question text is queued, not lost
# AC3  ...and it is ALLOWED when the run is inert / paused / finished
# AC4  an ARMED session is unattended too, and an unarmed one may still ask
# AC5  ...with the question queued either way
# AC6  the turn-ending verb (await-operator) is GONE; `ask` replaces it
# AC7  the queue APPENDS -- several questions over a long run all survive
use strict;
use warnings;

# A TEST MUST NEVER ACTUATE A REAL WAKE-LOCK. This file drives butler-continuity /
# bp-runstate.pl / stop-gate.sh, which hold the machine awake for an armed
# session -- and they do it as SUBPROCESSES, where bp-keepawake.pl's `$0 =~ /\.t\z/`
# guard cannot reach (its $0 is the .pl). CCPRAXIS_NO_WAKELOCK is the supported
# opt-out and IS inherited across exec. Enforced by t/test-wakelock-hygiene.t.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Cwd qw(getcwd abs_path);

# Queue assertions re-pointed at the almanac decision store by package 09
# (Decision 108); reason codes below.
my $GUARD = "$Bin/../../hooks/guard-ask-operator.sh";
# butler-continuity was the CLI here; it is on the deletion list and gone
# (package 16 batch E1). butler-continuity.pl is the one continuity CLI
# left, and shares the same BpProjectRoot::resolve() ladder (reason DEL).
my $CONT  = "$Bin/../../scripts/butler-continuity.pl";

# spec 01-inbox-rename 2.7: GuardAskOperator now files into Almanac::Inbox
# (almanac-inbox.pl), not Almanac::Decision -- guarded, house not-yet-built
# pattern.
{
    local $@;
    eval { require("$Bin/../../../almanac/scripts/almanac-inbox.pl"); 1 }
        or diag("almanac-inbox.pl did not load (expected until package 01-inbox-rename renames it): $@");
}

# filed($root) -- the almanac inbox store's own records for $root.
sub filed {
    my ($root) = @_;
    return [] unless -d "$root/.ccpraxis-local-data/almanac/inbox";
    return [] unless defined &Almanac::Inbox::list_items;
    my $list = eval { Almanac::Inbox::list_items(root => $root) };
    return (ref $list eq 'ARRAY') ? $list : [];
}
sub no_legacy { return !-e "$_[0]/.ccpraxis-local-data/.subagent-guard/questions.md" }

ok(-f $GUARD, 'guard-ask-operator.sh exists') or BAIL_OUT('guard missing');
# The old ok(-f $RUNSTATE...) or BAIL_OUT is RETIRED along with $RUNSTATE
# itself (package 03-retire-runstate, spec §2.3(a)): the guard's own
# `[ -f "$RUNSTATE" ] || exit 0` early-exit is deleted in the same edit that
# removes its "status" read (that early-exit, left behind, would silently
# turn the whole guard into a no-op the moment bp-runstate.pl is deleted --
# exactly the fail-open failure mode this blueprint exists to prevent), so
# nothing in this file should assert that file's presence either.

sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub run_guard {
    my ($root, @questions) = @_;
    # Optional trailing hashref: { state => <BUTLER_STATE_DIR> } -- makes
    # the session ARMED (the guard's one remaining unattended signal, per
    # package 03-retire-runstate §2.3(a)) for callers that need a real
    # denial to happen so the queue actually gets written to.
    #
    # Package 16 batch-B fix round: BpHook::Guards::GuardAskOperator (the
    # hooks/guard-ask-operator.sh successor, package 14) reads armed state
    # ONLY from BpHook::is_armed() against the NEW store (bug
    # 20260922-210421-0468 / Decision 3: no legacy .continuity-active/
    # registry is ever consulted any more). The old CCPRAXIS_CONTINUITY_
    # ACTIVE_DIR fixture this sub used to set is retired with that read;
    # arm_state() below builds the new store's on-disk shape instead.
    my %opt = (ref $questions[-1] eq 'HASH') ? %{ pop @questions } : ();
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-q', cwd => $root, tool_name => 'AskUserQuestion',
        tool_input => { questions => [ map { { question => $_ } } @questions ] },
    });
    my $env = "CLAUDE_PROJECT_DIR='$root'";
    $env .= " BUTLER_STATE_DIR='$opt{state}'" if defined $opt{state};
    my $out = `$env bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out // '');
}

# arm_state(ROOT, SID) -> STATE_DIR -- the new store's on-disk shape
# (<STATE_DIR>/continuity/armed/<SID>), suitable for BUTLER_STATE_DIR.
# Defaults SID to 'sess-q' (run_guard's fixed session_id) so existing call
# sites need only pass ROOT. BpHook::is_armed() only checks -e on this path,
# so any non-empty content is enough to arm.
sub arm_state {
    my ($root, $sid) = @_;
    $sid = 'sess-q' unless defined $sid && length $sid;
    my $state = "$root/state";
    my $dir   = "$state/continuity/armed";
    make_path($dir);
    open my $fh, '>', "$dir/$sid" or die $!;
    print {$fh} qq({"role":"manual","by":"operator","since":"2026-09-10T00:00:00Z"}\n);
    close $fh;
    return $state;
}

sub queue_contents {
    my ($root) = @_;
    return join("\n", map { $_->{fields}{title} } @{ filed($root) });
}

# ── AC1/AC2 — RETIRED (package 03-retire-runstate, spec §2.3(a)/§6) ───────
#
# These pinned the guard's "a run is ACTIVE" arm: `bp-runstate.pl activate`
# followed by a DENY. `active` was never WRITTEN directly by any production
# caller, but it WAS produced on READ: `BpRunState::effective` manufactured
# it from any stale `paused` record (dead watcher pid, mismatched
# fingerprint, or elapsed `until`), and `paused` records were written by the
# now-retired `butler-hold --self-pause`, doctrinal until package 12 -- so
# the arm genuinely fired, on real sessions, once such a lease went stale.
# Package 03 deletes the arm outright anyway (not merely disables it): the
# `[ -f "$RUNSTATE" ] || exit 0` early-exit and the
# `STATE=$(perl "$RUNSTATE" status ...)` read both go, and UNATTENDED is now
# set by the continuity-ARMED check alone. Spec §6 records this as a
# deliberate, named degradation: "a drive-solo run that is NOT continuity-
# armed and asks a question will now be allowed to ask, even one that
# previously carried a stale self-paused lease -- that is a real narrowing
# of the guard's STATED contract, not the removal of dead code, and must be
# written into the ledger rather than discovered later." There is no
# probe-based fixture this
# migrates onto because the property itself ("a run being active denies the
# question") is gone, not relocated. AC2's surviving half -- "a denied
# question's text is queued, not lost" -- is not lost either: it is what
# AC4/AC5 below (the ARMED case, the guard's one remaining denial path)
# already assert on a real denial.

# ── AC3 — RETIRED in its run-state-driven form, same reason as AC1/AC2 ────
#
# The three sub-fixtures here (inert/finished/paused, via bp-runstate.pl)
# existed to prove the run-based arm was not over-blocking. With that arm
# gone, "a non-active run state does not block" is vacuously true --
# there is no run-state read left to over-block on. Only the paused
# sub-case named an actual mechanism (`pause`) that is itself deleted by
# this package (§2.1), so it has no successor to migrate onto either. The
# real "not a blanket ban" property -- an UNARMED session may still ask --
# is what AC4's second half (below) proves against the guard's one
# remaining signal.

# ── AC4/AC5 — ARMED counts as unattended, and `ask` is the way through ────
#
# The first version of this guard keyed only on a RUN being active. That missed
# the case the operator actually described: a plain armed overnight session,
# which sets no run state at all and so sailed straight past the guard.
#
# Arming IS the operator saying "watch this, I am not here", so it is unattended
# by definition. And the verb that used to end a turn for a question
# (await-operator) is gone -- an armed session ending its turn to ask something
# is the halt, not the remedy.
{
    my $root  = new_project();
    my $state = arm_state($root, 'sess-armed');   # No run at all. Only the arm.

    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-armed', cwd => $root, tool_name => 'AskUserQuestion',
        tool_input => { questions => [ { question => 'Should I rename it?' } ] },
    });
    my $out = `CLAUDE_PROJECT_DIR='$root' BUTLER_STATE_DIR='$state' bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;

    is($rc, 2, 'AC4 CANONICAL: an ARMED session is unattended -- the question is denied even '
             . 'with no run active, which is the overnight case the run-only check missed');
    like($out, qr/ARMED/, 'AC4 and the refusal names the real reason rather than claiming a run');
    like(queue_contents($root), qr/Should I rename it\?/, 'AC5 the question is queued');
    ok(no_legacy($root), 'AC4: no legacy questions.md was written');

    # AC8/B10 (spec §2.3(c)): the denial stops naming a dead verb. Reason MSG
    # (Decision 68(c)): package 14's GuardAskOperator.pm dropped the old
    # remedy text entirely rather than swap it for another verb -- there is
    # no ".run-finished"/"only the operator" wording left to pin, so those
    # two checks are retargeted to the module's actual remedy sentences
    # (BpHook::Guards::GuardAskOperator::run: "Decide it yourself..." /
    # "escalate-product-decisions-only.md"), which the old wording's own
    # intent (do not hand out a dead verb; point at real guidance) survives.
    unlike($out, qr/bp-runstate/,
        'AC8: the denial never names bp-runstate -- no verb, flag or argument ends a run any more');
    like($out, qr/Decide it yourself/i,
        'AC8: ...and tells the agent to decide it itself');
    like($out, qr/escalate-product-decisions-only\.md/,
        'AC8: ...naming the real product-decision guidance instead of a dead verb');

    # An UNARMED session with no run is free to ask. Over-blocking is the real
    # risk with a guard like this.
    my $root2 = new_project();
    my $p2 = JSON::PP->new->canonical->encode({
        session_id => 'sess-free', cwd => $root2, tool_name => 'AskUserQuestion',
        tool_input => { questions => [ { question => 'Fine?' } ] },
    });
    `CLAUDE_PROJECT_DIR='$root2' bash "$GUARD" <<'PAYLOAD_EOF' 2>&1
$p2
PAYLOAD_EOF`;
    is($? >> 8, 0, 'AC4 CANONICAL: an unarmed session with no run may still ask -- talking to '
                 . 'the operator is normal when nothing unattended is in flight');
}

# _cont_ask($cwd, \%env, $text) -- runs butler-continuity ask --text $text,
# chdir'd into $cwd first. Spec 01-inbox-rename 2.6 retires this verb
# entirely (exit 1, a one-line pointer at `almanac inbox file`), so this
# helper now returns the (out, rc) pair for a retirement assertion rather
# than a successful filing -- used by AC6 below.
sub _cont_ask {
    my ($cwd, $env, $text) = @_;
    local %ENV = %ENV;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} }
        else                    { delete $ENV{$k} }
    }
    my $here = getcwd();
    chdir $cwd or die "chdir $cwd: $!";
    my $out = `"$^X" "$CONT" ask --text "$text" 2>&1`;
    my $rc = $? >> 8;
    chdir $here or die "chdir back: $!";
    return (defined($out) ? $out : '', $rc);
}

# ── AC6 — the halting verb is gone, and so is its retired-but-still-filing
#    successor ──────────────────────────────────────────────────────────
#
# MIGRATED (reason DEL, package 16 batch E1): butler-continuity is on the
# deletion list and gone. butler-continuity.pl is the one continuity CLI
# left, and it never grew an await-operator verb either.
#
# AC22 (spec 01-inbox-rename 2.6): `ask` itself is now ALSO retired -- it no
# longer records and returns; it exits 1 with a one-line pointer at
# `almanac inbox file`, before anything is filed. The remaining escape hatch
# for "something needs the operator, keep working" is GuardAskOperator's own
# filing (guards-remake-ask-operator.t), or an agent filing `almanac inbox
# file` directly -- never a CLI verb that ends the turn.
{
    my $root = new_project();
    my $here = getcwd();
    chdir $root or die "chdir $root: $!";
    my $out = `"$^X" "$CONT" await-operator --reason 'x' 2>&1`;
    my $rc_await = $? >> 8;
    chdir $here or die "chdir back: $!";
    isnt($rc_await, 0,
         'AC6 CANONICAL: await-operator is REMOVED. A retired escape hatch that still works '
       . 'is not retired, and this one ended turns for questions -- the exact halt being '
       . 'designed out');

    # ...and `ask`, its retired-but-still-working successor, is now ALSO gone.
    my ($q, $rc_ask) = _cont_ask($root, {}, 'A or B?');
    is($rc_ask, 1, 'AC6/AC22: ask is now ALSO retired (exit 1), never a quiet filing-and-return');
    is($q, "butler-continuity: 'butler-continuity ask' is retired; use 'almanac inbox file' instead\n",
        'AC6/AC22: ...with the exact 2.6 retirement line on stdout+stderr combined');
    unlike($q, qr/queued/i, 'AC6/AC22: ask never reports a question queued any more');
}

# ── AC7 — the queue accumulates ───────────────────────────────────────────
#
# MIGRATED (package 03-retire-runstate): the fixture used to call
# `bp-runstate.pl activate` to make the session unattended, so the guard
# would deny and actually write to the queue. The guard's only unattended
# signal now is continuity-ARMED (§2.3(a)), so arm_state() takes its
# place -- same shape as AC4's fixture above, reused rather than duplicated.
{
    my $root  = new_project();
    my $state = arm_state($root);
    run_guard($root, 'First question?', { state => $state });
    run_guard($root, 'Second question?', { state => $state });
    run_guard($root, 'Third question?', 'And a fourth in the same call?', { state => $state });

    my $q = queue_contents($root);
    like($q, qr/First question\?/,  'AC7 first survives');
    like($q, qr/Second question\?/, 'AC7 second survives');
    like($q, qr/Third question\?/,  'AC7 third survives');
    like($q, qr/And a fourth in the same call\?/,
         'AC7 CANONICAL: and multiple questions in ONE call are all captured -- the payload '
       . 'nests them in an array, which is why this is not read with a scalar path');
    ok(no_legacy($root), 'AC7: no legacy questions.md was written');
}

# ── ROOT-A/B/C/D — RETIRED (spec 01-inbox-rename 2.6), same reason pattern
#    as AC1/AC2/AC3 above ─────────────────────────────────────────────────
#
# This section pinned a dual-path round-trip: a WRITER (`butler-continuity
# ask`, a driver's own Bash tool, no CLAUDE_PROJECT_DIR) and a READER (the
# guard hook, CLAUDE_PROJECT_DIR always set) resolving to the SAME project
# root via the cwd walk. `ask` is now retired outright -- it no longer files
# anything, so there is no second codepath left to round-trip against. The
# property this protected (a driver's own filing and the hook's own filing
# landing on the same project) no longer has two production callers to
# compare: GuardAskOperator (the hook) is the only filer left, and its own
# root-resolution ladder (walk up from cwd; else CLAUDE_PROJECT_DIR; else
# cwd; the walk winning over CLAUDE_PROJECT_DIR) is pinned directly by
# guards-remake-ask-operator.t's AO-6, which this file explicitly does not
# duplicate. Nothing below is deleted silently: this comment is itself the
# record, same house convention as AC1/AC2/AC3's retirement notes above.

done_testing();
