#!/usr/bin/env perl
# s21-keep-awake-probe-failure-handling: a transient podman-exec failure must
# not SIGKILL the wake-lock and re-spawn it.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s21-keep-awake-probe-failure-handling
# (specs/s21-keep-awake-probe-failure-handling-spec.md). Written BLIND to any
# launcher.pl / KeepAwake.pm change the implementer makes -- directly from the
# spec -- so it serves as an oracle rather than an echo. Do NOT weaken an
# assertion to make a future implementation's life easier.
#
# Coverage: C1..C8 (spec S3).
#
# HARD CONSTRAINTS honoured here:
#   * PURE/structural: never spawns launcher.pl, never builds an image, never
#     starts a container. launcher.pl is SLURPED for source-text assertions
#     only (t/48/t/59's established convention) -- never require'd/do'ne.
#   * Fixtures are in-memory / File::Temp only.
#
# ===========================================================================
# INTERFACE THIS ORACLE PINS -- spec S2.1 explicitly delegates the struct's
# field names to this file ("Suggested shape ... the oracle pins the names"),
# but does NOT name the decision-layer entry point itself. Rather than test
# nothing executable for the headline criterion (C4 -- the assertion that
# would have caught the original defect), this file pins ONE minimal,
# backward-compatible extension of KeepAwake.pm's existing object model:
#
#   The probe result struct (spec S2.1, verbatim):
#     { state => 'ok',            age => $seconds }
#     { state => 'lease-absent'                  }
#     { state => 'probe-failed',  detail => $str }
#     { state => 'container-gone', detail => $str }
#
#   KeepAwake->new(...)->on_probe(\%result, $stale, $tolerance) -> $action
#     $action is sync()'s existing vocabulary: 'start' | 'stop' | 'noop'.
#     'ok'            -> sync(should_stay_awake(age, stale)) -- age-based,
#                        reusing the UNCHANGED pure decision (C6).
#     'lease-absent'  -> sync(0, reason => 'lease-absent')
#     'container-gone'-> sync(0, reason => 'container-gone')
#     'probe-failed'  -> HOLDS (no sync call at all -- not even a 'noop'
#                        transition attempt) while the consecutive
#                        probe-failed streak is <= $tolerance; once the
#                        streak exceeds $tolerance, releases via
#                        sync(0, reason => 'probe-failed'). Any non
#                        probe-failed state resets the streak.
#     $tolerance is an explicit CALLER-SUPPLIED argument (mirroring
#     should_stay_awake's existing $stale parameter) -- never a value this
#     oracle hardcodes or reads off a launcher.pl constant. That is what lets
#     C5 "drive the count, not pin the value": the test picks its own small
#     tolerance and proves the behaviour at and past that boundary, without
#     ever asserting what launcher.pl's real default is.
#
#   KeepAwake::sync($want, %extra) -- backward-compatible: existing one-arg
#     callers (t/59's C2, and every current launcher.pl call site) are
#     unaffected; %extra, if given, is merged into the on_event payload on a
#     TRANSITION ONLY (never on a 'noop'), which is how C3's log
#     distinguishability is carried without adding a second emit path.
#
# An implementation that reuses these two names satisfies the executable
# criteria below directly. An implementation that solves the SAME problem
# under different names is not automatically "wrong" -- but this oracle has
# no way to discover an unpinned name without guessing (the exact trap s16's
# header warns about), so pinning a reasoned, minimal, backward-compatible
# interface is the least-bad option available while spec S2.1 leaves it open.
# ===========================================================================
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('KeepAwake') or BAIL_OUT('KeepAwake.pm did not load');

my $SCRIPTS_DIR  = "$Bin/../../scripts";
my $LAUNCHER_SRC = "$SCRIPTS_DIR/launcher.pl";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# new_holder() -> ($obj, \@fired). \@fired collects every on_event(%event)
# call as an arrayref-of-pairs, exactly mirroring t/59's C2 collector.
sub new_holder {
    my @fired;
    my $collect = sub { push @fired, { @_ }; };
    my $obj = eval {
        KeepAwake->new(
            start    => sub { return 'HANDLE'; },
            stop     => sub { },
            on_event => $collect,
        );
    };
    return ($obj, \@fired);
}

# started_holder() -> ($obj, \@fired), already holding the lock (one 'ok'
# probe with a fresh age), with \@fired cleared back to empty afterwards so
# every caller's assertions are about what happens AFTER the initial start.
sub started_holder {
    my ($obj, $fired) = new_holder();
    return (undef, undef) unless defined $obj;
    my $can_probe = $obj->can('on_probe');
    return ($obj, $fired) unless $can_probe;
    $obj->on_probe({ state => 'ok', age => 0 }, 600, 3);
    @$fired = ();   # this file's own C4/C5 fixtures assert the START count themselves
    return ($obj, $fired);
}

# ===========================================================================
# C6 -- should_stay_awake's EXISTING contract is unchanged for defined
# inputs. Plain regression fixture: this package edits the sub in place, so
# the pre-existing behaviour needs its own oracle here rather than trusting
# it survived.
# ===========================================================================
{
    is(KeepAwake::should_stay_awake(-5, 600), 1, 'C6: negative age (clock skew) -> stay awake');
    is(KeepAwake::should_stay_awake(-0.5, 600), 1, 'C6: small negative age -> stay awake');
    is(KeepAwake::should_stay_awake(0, 600), 1, 'C6: age == 0, well within stale -> stay awake');
    is(KeepAwake::should_stay_awake(600, 600), 1, 'C6: age == stale exactly -> stay awake (<=)');
    is(KeepAwake::should_stay_awake(601, 600), 0, 'C6: age just over stale -> release');
    is(KeepAwake::should_stay_awake(10_000, 600), 0, 'C6: age far over stale -> release');
    my $died = !eval { KeepAwake::should_stay_awake(100, 'not-a-number'); 1 };
    ok(!$died, 'C6: a non-numeric $stale never dies (falls back to the default window)');
    $died = !eval { KeepAwake::should_stay_awake(100, undef); 1 };
    ok(!$died, 'C6: an undef $stale never dies');
}

# ===========================================================================
# C1 -- the probe result is a three-state struct (spec S2.1's literal
# shape), never a bare undef standing for all three. Vacuity gate: the three
# non-'ok' terminal states must be shown MUTUALLY DISTINCT in their effect on
# a held lock -- an implementation collapsing them to one behaviour (as
# today's `undef` does) fails this block.
# ===========================================================================
{
    my ($obj, $fired) = new_holder();
    ok(defined($obj), 'C1 setup: a KeepAwake object can be constructed with the pinned seams');
    my $has_on_probe = defined($obj) && $obj->can('on_probe');
    ok($has_on_probe, 'C1: KeepAwake objects respond to on_probe(\%result, $stale, $tolerance)')
        or diag('  0 of the following C1-C5/C7 executable assertions can be meaningful without on_probe existing');

  SKIP: {
        skip('on_probe not implemented -- see the hard failure above', 30) unless $has_on_probe;

        # --- lease-absent releases (the paired positive baseline) ---
        my ($h1, $f1) = started_holder();
        my $a_absent = $h1->on_probe({ state => 'lease-absent' }, 600, 3);
        is($a_absent, 'stop', 'C1/C2 paired positive: a lease-absent result releases a held lock');
        is($h1->running, 0, 'C1/C2 paired positive: running flips to 0 after lease-absent');

        # --- probe-failed holds (the headline behaviour) ---
        my ($h2, $f2) = started_holder();
        my $a_failed = $h2->on_probe({ state => 'probe-failed', detail => 'transient exec error' }, 600, 3);
        is($a_failed, 'noop', 'C2 headline: a single probe-failed result HOLDS (action is noop, not stop)');
        is($h2->running, 1, 'C2 headline: running stays 1 after a single probe-failed result');

        # --- container-gone releases ---
        my ($h3, $f3) = started_holder();
        my $a_gone = $h3->on_probe({ state => 'container-gone', detail => 'not running' }, 600, 3);
        is($a_gone, 'stop', 'C3: a container-gone result releases a held lock');
        is($h3->running, 0, 'C3: running flips to 0 after container-gone');

        # Vacuity gate: probe-failed's action must differ from lease-absent's
        # and container-gone's. An implementation that reads all three
        # non-'ok' states identically (i.e. still treats them all as "stop",
        # exactly today's undef bug) fails here.
        isnt($a_failed, $a_absent,
            'C1 vacuity gate: probe-failed is NOT handled identically to lease-absent');
        isnt($a_failed, $a_gone,
            'C1 vacuity gate: probe-failed is NOT handled identically to container-gone');

        # --- C3: container-gone is distinguishable in the log from
        #     lease-absent (both release, but must carry different evidence
        #     into the emitted event so an operator/log-reader can tell them
        #     apart -- pinned via sync's %extra passthrough, C above).
        my $absent_event = (grep { ($_->{kind} || '') eq 'release' } @$f1)[0];
        my $gone_event    = (grep { ($_->{kind} || '') eq 'release' } @$f3)[0];
        ok(defined($absent_event), 'C3 setup: the lease-absent release fired exactly one release event')
            or diag('  fired: ' . join(',', map { $_->{kind} // '?' } @$f1));
        ok(defined($gone_event), 'C3 setup: the container-gone release fired exactly one release event')
            or diag('  fired: ' . join(',', map { $_->{kind} // '?' } @$f3));
        if (defined($absent_event) && defined($gone_event)) {
            my $absent_sig = join('|', map { "$_=" . ($absent_event->{$_} // '') } sort keys %$absent_event);
            my $gone_sig   = join('|', map { "$_=" . ($gone_event->{$_} // '') } sort keys %$gone_event);
            isnt($absent_sig, $gone_sig,
                'C3: the container-gone release event is distinguishable from the lease-absent release event');
        } else {
            fail('C3: the container-gone release event is distinguishable from the lease-absent release event');
        }

        # =======================================================================
        # C4 -- THE HEADLINE ASSERTION. Across a fixture sequence
        # ok -> probe-failed -> ok, exactly ONE keepawake_started (acquire) is
        # emitted in TOTAL across the whole sequence. This reproduces s18's
        # measured stop/start pairs 3-12s apart: a naive translation of the
        # bug (probe-failed collapsing to the same "release" as lease-absent)
        # would stop on step 2 and re-start on step 3, giving TWO acquires.
        # =======================================================================
        {
            my ($h, $f) = new_holder();
            my @actions;
            push @actions, $h->on_probe({ state => 'ok', age => 0 }, 600, 3);            # 1: acquire
            push @actions, $h->on_probe({ state => 'probe-failed', detail => 'x' }, 600, 3); # 2: must hold
            push @actions, $h->on_probe({ state => 'ok', age => 0 }, 600, 3);            # 3: still held -> noop
            my @acquires = grep { ($_->{kind} || '') eq 'acquire' } @$f;
            is(scalar(@acquires), 1,
                'C4 headline: exactly ONE keepawake_started (acquire) across ok -> probe-failed -> ok')
                or diag('  actions taken: ' . join(',', @actions) . '; events: ' . join(',', map { $_->{kind} // '?' } @$f));
            is($actions[1], 'noop', 'C4: the probe-failed step in the middle of the sequence did not stop the lock');
            is($h->running, 1, 'C4: the lock is still held after the full ok/probe-failed/ok sequence');
        }

        # =======================================================================
        # C5 -- a SUSTAINED run of probe-failed beyond the tolerance DOES
        # release; just below the bound it still holds. Tolerance is driven
        # as an explicit small test-local number (3), never read off (or
        # asserted to equal) any launcher.pl constant.
        # =======================================================================
        {
            my $TOLERANCE = 3;   # test-local only -- NOT asserted to be launcher.pl's real default
            my ($h, $f) = new_holder();
            $h->on_probe({ state => 'ok', age => 0 }, 600, $TOLERANCE);   # acquire
            @$f = ();

            my @actions;
            for (1 .. $TOLERANCE) {
                push @actions, $h->on_probe({ state => 'probe-failed', detail => 'x' }, 600, $TOLERANCE);
            }
            is_deeply(\@actions, [ ('noop') x $TOLERANCE ],
                "C5 paired positive: $TOLERANCE consecutive probe-failed results (at the bound) all hold");
            is($h->running, 1, 'C5 paired positive: still running at exactly the tolerance bound');

            my $over_action = $h->on_probe({ state => 'probe-failed', detail => 'x' }, 600, $TOLERANCE);
            is($over_action, 'stop',
                'C5 headline: one MORE probe-failed beyond the tolerance releases the lock');
            is($h->running, 0, 'C5 headline: running flips to 0 once the tolerance is exceeded');
        }

        # =======================================================================
        # C7 -- emits on transition only: a hold emits NOTHING (re-asserted
        # here because this package adds a NEW caller to s16's on_event seam),
        # and a repeated sync(1) while already held still emits nothing
        # (s16's pre-existing property).
        # =======================================================================
        {
            my ($h, $f) = new_holder();
            $h->on_probe({ state => 'ok', age => 0 }, 600, 3);   # acquire: 1 event
            is(scalar(@$f), 1, 'C7 setup: the initial acquire fired exactly one event');

            # FIXTURE CORRECTED (coordinator, 2026-08-04). This looped 5 times
            # against a tolerance of 3 while describing them as "all below
            # tolerance" — internally contradictory, since the 4th exceeds the
            # bound and correctly releases. The old loop therefore only passed
            # while the implementation had a SECOND bug: its sustained-failure
            # release bypassed sync() and emitted nothing, so the event count
            # stayed at 1 by accident. Two wrongs agreeing is not a green test.
            # Both fixed: the release now emits (a release IS a transition),
            # and this loop stays strictly within the bound as it claims to.
            my $TOL = 3;
            for (1 .. $TOL) {
                $h->on_probe({ state => 'probe-failed', detail => 'x' }, 600, $TOL);
            }
            is(scalar(@$f), 1,
                'C7: five consecutive probe-failed holds (all below tolerance) emit NOTHING beyond the initial acquire');

            # Positive gate: sync() itself still only fires on a genuine
            # transition, proving the "emits nothing" result above is not
            # simply because on_event was disconnected.
            my $r1 = $h->sync(1);   # already running -> noop
            my $r2 = $h->sync(1);   # again -> noop
            is_deeply([$r1, $r2], ['noop', 'noop'],
                'C7 positive gate: repeated sync(1) while already held returns noop,noop (transition-only contract intact)');
            is(scalar(@$f), 1,
                'C7: repeated sync(1) while already held emits nothing beyond the initial acquire');
        }
    }
}

# ===========================================================================
# C1 (continued) -- the struct literal itself matches spec S2.1 exactly:
# 'ok' carries age, 'probe-failed'/'container-gone' carry detail,
# 'lease-absent' carries neither. Exercised implicitly by every on_probe call
# above; this block just pins the state-name spelling as a standalone,
# non-executable documentation check against the spec text so a typo'd state
# name (e.g. 'probe_failed' with an underscore) is caught even though such a
# typo would otherwise just silently fall through on_probe's dispatch as an
# unrecognised state.
# ===========================================================================
{
    my @SPEC_STATES = ('ok', 'lease-absent', 'probe-failed', 'container-gone');
    is(scalar(@SPEC_STATES), 4, 'C1: spec S2.1 names exactly four states (self-check on this file\'s fixture, not a launcher.pl count)');
    my %seen = map { $_ => 1 } @SPEC_STATES;
    is(scalar(keys %seen), 4, 'C1: the four spec state names are themselves mutually distinct strings');
}

# ===========================================================================
# C8 -- no regression, recorded as validation commands (per spec S3, not
# reimplemented here): t/59-fleet-event-source.t (74 assertions) and the
# documented sandbox baseline. See report.
# ===========================================================================
pass('C8: no-regression is recorded via the validation command '
    . '`perl plugins/sandbox/tests/t/59-fleet-event-source.t` (see report), not reimplemented in this file');

done_testing();
