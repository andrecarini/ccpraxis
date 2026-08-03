#!/usr/bin/env perl
# s15-input-latency: oracle for the new `wait_input` seam in Dashboard::run().
#
# Spec: .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/s15-input-latency-spec.md
#
# THE CHANGE (not made by this file): replace the unconditional tail
#   $sleep_for->($tick_int);
# with an interruptible wait behind a new injected seam
#   my $wait_input = $o{wait_input} || sub { $sleep_for->($_[0]); undef };
# so a keypress wakes the loop immediately (drained + rendered THAT SAME
# TICK), while an idle loop still waits ~tick_int with no busy-spin. The
# default (no wait_input injected) must be byte-for-byte today's behaviour.
#
# This file is a READ-ONLY consumer of Dashboard::run()'s seam contract; it
# does not modify Dashboard.pm, launcher.pl, or t/25-dashboard.t.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Encode ();

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# Harness: drive_wi(%args) -- a fake-clock/scripted-key driver mirroring
# t/25-dashboard.t's `drive()` style exactly (now/sleep_for/read_key/
# term_size/gather/heartbeat/out all injected), extended with an optional
# `wait_input` closure so tests can script the new seam's behaviour and
# observe (a) how much wall-clock each wait_input call consumed, (b) how
# many times it was called, and (c) the exact ordering of side effects
# (heartbeats/gathers/spawns/frames) around each call.
#
# $args{wait_input}, if given, is a sub($timeout, \$clock, \%eff) -> key|undef
# that the harness wraps so every call is logged (timeout requested, wall-
# clock elapsed, and the returned value) into $eff{wait_call_log}.
# ===========================================================================
sub drive_wi {
    my (%args) = @_;
    my @keys  = @{ $args{keys}     || [] };
    my @rkeys = @{ $args{read_key} || [] };   # separate scripted queue for read_key
    my $clock = 1000;
    # NOTE on read_key/keys/read_key_fn precedence: $args{read_key_fn}, when
    # given, is a sub(\%eff) -> key|undef with full access to the harness's
    # live effect counters (e.g. wait_calls) so a test can gate WHICH bytes
    # become available on WHEN wait_input has already fired, rather than a
    # flat queue that would be consumed in whatever order read_key happens
    # to be called (which does not distinguish "before the wait" from
    # "after the wait" -- a flat queue can be silently mis-ordered).
    my %eff = (
        heartbeats => 0, spawns => 0, gathers => 0, frames => 0,
        wait_calls => 0, wait_call_log => [], spawn_heartbeat_snapshot => [],
        sleep_calls => 0, sleep_elapsed => 0,
    );
    my @chunks;   # one entry per out() call, in emission order

    my %params = (
        beat_interval  => $args{beat_interval}  // 9999,
        state_interval => $args{state_interval} // 999,
        tick_interval  => $args{tick_interval}  // 0.25,
        color          => 0,
        max_ticks      => $args{max_ticks} // 20,
        now            => sub {
            push @{ $eff{now_log} }, $clock;
            return $clock;
        },
        sleep_for => sub {
            $eff{sleep_calls}++;
            $eff{sleep_elapsed} += $_[0];
            $clock += $_[0];
        },
        read_key => ($args{read_key_fn}
            ? sub { $args{read_key_fn}->(\%eff) }
            : sub { @rkeys ? shift @rkeys : (@keys ? shift @keys : undef) }),
        term_size => sub { ($args{cols} // 60, $args{rows} // 24) },
        gather => sub {
            $eff{gathers}++;
            return {
                project_name => 'demo', container => 'c1',
                status => ($args{status} // 'running'),
                events => ($args{events} // []),
            };
        },
        heartbeat => sub { $eff{heartbeats}++; 'ok' },
        spawn     => sub {
            $eff{spawns}++;
            push @{ $eff{spawn_heartbeat_snapshot} }, $eff{heartbeats};
            undef;
        },
        enter_raw => sub { $eff{entered} = 1 },
        leave_raw => sub { $eff{left} = ($eff{left} || 0) + 1 },
        keepawake => sub { },
        out       => sub { push @chunks, $_[0]; $eff{frames}++ },
    );

    if ($args{wait_input}) {
        my $cb = $args{wait_input};
        $params{wait_input} = sub {
            my ($timeout) = @_;
            $eff{wait_calls}++;
            my $before = $clock;
            my $ret = $cb->($timeout, \$clock, \%eff);
            push @{ $eff{wait_call_log} },
                { timeout => $timeout, elapsed => $clock - $before, ret => $ret };
            return $ret;
        };
    }

    my $rc = Dashboard::run(%params);
    $eff{rc}     = $rc;
    $eff{chunks} = \@chunks;
    $eff{out}    = join('', @chunks);
    return \%eff;
}

my $TICK = 0.25;   # tick_interval used throughout this file, matches t/25's style

# ===========================================================================
# C1 -- a keypress delivered by wait_input is NOT made to wait for the tick.
# ===========================================================================
# wait_input reports a key ('c') on its very first call with ZERO wall-clock
# consumed (an immediate keypress). beat_interval=>0 makes heartbeats fire on
# EVERY top-of-loop iteration unconditionally, which we use as a same-tick
# sentinel below (see spawn_heartbeat_snapshot).
my $c1 = drive_wi(
    max_ticks     => 2,
    beat_interval => 0,
    wait_input    => sub {
        my ($timeout, $clock_ref, $eff) = @_;
        if ($eff->{wait_calls} == 1) {
            return 'c';   # immediate key, no clock advance
        }
        $$clock_ref += $timeout;   # subsequent calls: idle
        return undef;
    },
);

ok($c1->{wait_calls} >= 1, 'C1: wait_input seam was actually consulted by the loop');
is($c1->{wait_call_log}[0]{elapsed}, 0,
   'C1: wall-clock consumed by an immediate-key wait_input call is ~0, not tick_interval');
is($c1->{spawns}, 1, 'C1: the immediately-reported key was drained and dispatched (spawn fired)');
is($c1->{spawn_heartbeat_snapshot}[0], 1,
   'C1: the spawn happened while heartbeats==1 -- i.e. within the SAME tick the key arrived in, ' .
   'not after a fresh next-tick heartbeat check (heartbeats==2 would mean it waited for the next tick)');

# ===========================================================================
# C2 -- an idle loop still waits ~tick_interval and does not busy-spin.
# ===========================================================================
# wait_input NEVER reports a key; every call advances the clock by the full
# requested timeout, exactly like the default fallback `sub { $sleep_for->
# ($_[0]); undef }` would. Over a bounded run the number of wait_input calls
# must be proportional to ticks (not unbounded), and the elapsed wall-clock
# must be proportional to (calls * tick_interval) -- not ~0, which would be
# a busy-spin.
my $C2_TICKS = 8;
my $c2 = drive_wi(
    max_ticks     => $C2_TICKS,
    beat_interval => 9999,
    wait_input    => sub {
        my ($timeout, $clock_ref, $eff) = @_;
        $$clock_ref += $timeout;
        return undef;
    },
);

is($c2->{spawns}, 0, 'C2: idle loop never spawns (no key ever delivered)');
# The loop's own max_ticks guard skips the tail call on the very last tick
# (see Dashboard.pm: "$ticks++; last if ... ; $sleep_for->($tick_int);"), so
# a bounded run of N ticks calls the tail exactly N-1 times -- proportional
# to elapsed ticks, never open-ended.
is($c2->{wait_calls}, $C2_TICKS - 1,
   'C2: wait_input is called exactly once per completed tick (bounded by max_ticks, no busy-spin)');
my $c2_elapsed = 0;
$c2_elapsed += $_->{elapsed} for @{ $c2->{wait_call_log} };
is($c2_elapsed, ($C2_TICKS - 1) * $TICK,
   'C2: total wall-clock consumed by idle waits == (calls * tick_interval) exactly -- proportional to elapsed time');
ok($c2_elapsed > 0, 'C2: an idle loop actually consumes wall-clock time (does not return instantly every call)');

# ---------------------------------------------------------------------------
# MANDATORY VACUITY GATE: C1 and C2 are opposites. Assert them TOGETHER with
# an explicit cross-check, so no constant-behaviour implementation (e.g. one
# that never waits, or one that always waits the full tick_interval
# regardless of whether a key arrived) can pass both.
# ---------------------------------------------------------------------------
isnt($c1->{wait_call_log}[0]{elapsed}, $c2->{wait_call_log}[0]{elapsed},
     'VACUITY C1 vs C2: the SAME seam reports different elapsed wall-clock depending on whether a key ' .
     'arrived (~0) or the wait was idle (~tick_interval) -- a loop that never waits would make these equal ' .
     'at 0 and fail C2; a loop that always waits the full interval would make these equal at tick_interval ' .
     'and fail C1');
is($c1->{wait_call_log}[0]{elapsed}, 0,               'VACUITY cross-check: key-delivered wait stays ~0');
is($c2->{wait_call_log}[0]{elapsed}, $TICK,           'VACUITY cross-check: idle wait stays ~tick_interval');

# ===========================================================================
# C3 -- pushback: no byte is lost. A wait that consumes one byte to detect
# readiness hands it back; the drain sees the complete input including that
# first byte. Here read_key's OWN scripted queue is entirely empty (all
# undef) -- the ONLY possible source of the 'c' key is the value wait_input
# hands back. If pushback drops it, spawns stays 0 (key genuinely lost).
# ===========================================================================
my $c3 = drive_wi(
    max_ticks  => 3,
    read_key   => [],   # nothing available through the normal drain at all
    wait_input => sub {
        my ($timeout, $clock_ref, $eff) = @_;
        if ($eff->{wait_calls} == 1) { return 'c'; }   # the pushed-back byte
        $$clock_ref += $timeout;
        return undef;
    },
);
# POSITIVE first: a key was actually delivered at all (guards against a seam
# that silently delivers nothing yet trivially "passes" an absence check).
is($c3->{spawns}, 1, 'C3 (positive): the wait-consumed byte reached the drain at all (spawn fired exactly once)');
# Then the specific "nothing lost / nothing duplicated" claim.
is($c3->{wait_call_log}[0]{ret}, 'c', 'C3: wait_input reported the exact byte it consumed');

# ===========================================================================
# C4 -- ESC/arrow sequences assemble ACROSS the wait boundary. wait_input
# consumes only the ESC byte to detect readiness and hands it back; the
# remaining raw bytes ('[' then the final letter) are still sitting in the
# input stream and must be pulled via the ordinary read_key seam and stitched
# into the correct decoded action. Asserted PER SEQUENCE (down, then up),
# never in aggregate -- a dropped arrow sequence is a hard failure.
# ===========================================================================

# Both sub-cases below gate the post-ESC bytes ('[' then the final letter) on
# $eff->{wait_calls} having already reached 1 (i.e. the ESC has genuinely
# been consumed by a wait_input call already) rather than a flat queue --
# a flat queue cannot distinguish "available before the wait fired" from
# "available only after", and could be silently mis-consumed by an
# unrelated earlier drain.

# -- DOWN: ESC [ B, from a fresh offset of 0. -------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);   # overflow the Activity capacity
    my @post_esc = ('[', 'B');
    my $post_esc_idx = 0;
    my $d = drive_wi(
        max_ticks    => 4,
        events       => \@evs,
        rows         => 24,   # matches t/25-dashboard.t's PART 9 fixture exactly
        read_key_fn  => sub {
            my ($eff) = @_;
            return undef unless $eff->{wait_calls} >= 1;   # nothing until the ESC was consumed
            return $post_esc_idx < @post_esc ? $post_esc[$post_esc_idx++] : undef;
        },
        wait_input => sub {
            my ($timeout, $clock_ref, $eff) = @_;
            if ($eff->{wait_calls} == 1) { return "\e"; }   # wait consumed only the ESC
            $$clock_ref += $timeout;
            return undef;
        },
    );
    my $tri_up = Encode::encode('UTF-8', "\x{25B2}");
    # POSITIVE first: something scrolled at all (offset moved off 0). Any row
    # ever emitting this text proves a real transition happened somewhere in
    # the run (cumulative $out, not diff-sensitive).
    like($d->{out}, qr/\Q$tri_up\E 1 more/,
         'C4 down (positive): the ESC-consumed-by-wait + [ + B sequence produced a scroll (offset 0 -> 1)');
    # SPECIFIC: it was interpreted as an arrow, not a literal '[' (which
    # dispatch_key treats as inert -- no scroll at all, so the very presence
    # of the overlay above already rules out a literal-'[' misread; a broken
    # implementation that drops or misreads the sequence leaves offset at 0
    # forever and the positive assertion above fails instead).
}

# -- UP: ESC [ A, returning a previously-scrolled offset back to 0. ---------
# A "last chunk lacks the overlay" check would be a FALSE pass here: the
# render model only emits a diff for CHANGED rows, so once offset is frozen
# (assembly never happened) later idle ticks legitimately emit no row for
# that text at all -- indistinguishable from "correctly returned to 0" by
# just inspecting output. Instead we force a THIRD, unambiguous transition
# (a probe scroll-down) after the assembly attempt: if the assembly worked,
# offset is back at 0 and the probe takes it 0 -> 1 ("1 more" again); if the
# assembly was dropped/misread, offset was still 1 and the probe takes it
# 1 -> 2 ("2 more"). The LAST such count in the output is unambiguous either
# way and is forced to be freshly emitted regardless of textual novelty
# (scroll-down always marks the frame dirty when it moves the offset).
{
    my @evs = map { "evt$_" } (1 .. 20);
    my @post_esc = ('[', 'A');
    my $post_esc_idx = 0;
    my $probe_sent = 0;
    my $seed_sent = 0;
    my $u = drive_wi(
        max_ticks   => 8,
        events      => \@evs,
        rows        => 24,
        read_key_fn => sub {
            my ($eff) = @_;
            if ($eff->{wait_calls} == 0 && !$seed_sent) {
                # before ANY wait_input call: the trusted, already-decoded
                # seed key (not testing assembly) -- offset 0 -> 1.
                $seed_sent = 1;
                return 'DOWN';
            }
            if ($eff->{wait_calls} >= 1 && $post_esc_idx < @post_esc) {
                return $post_esc[$post_esc_idx++];
            }
            # The probe fires once a fixed number of ticks have elapsed
            # (via the injected `now` seam's call log, which grows by
            # exactly one per top-of-loop iteration), NEVER gated on
            # wait_calls -- it must fire whether or not the ESC assembly
            # ever actually happened, or an unimplemented seam (wait_calls
            # stuck at 0 forever) would silently never reach this branch
            # and the test would vacuously "pass" by never disambiguating
            # anything.
            if (!$probe_sent && scalar(@{ $eff->{now_log} || [] }) >= 5) {
                $probe_sent = 1;
                return 'DOWN';
            }
            return undef;
        },
        wait_input => sub {
            my ($timeout, $clock_ref, $eff) = @_;
            if ($eff->{wait_calls} == 1) { return "\e"; }   # ESC consumed on the FIRST wait_input call
            $$clock_ref += $timeout;
            return undef;
        },
    );
    my $tri_up = Encode::encode('UTF-8', "\x{25B2}");
    my @counts = ($u->{out} =~ /\Q$tri_up\E\s*(\d+)\s*more/g);
    # POSITIVE first: the seed is observable at all (some "N more" appeared).
    ok(scalar(@counts) > 0, 'C4 up (positive/seed): the DOWN seed produced an observable overlay (offset reached 1)');
    # SPECIFIC: the LAST observed count is 1 (probe went 0->1, i.e. the ESC
    # [ A sequence correctly assembled into UP and returned offset to 0
    # first) -- not 2 (which would mean the sequence was lost/misread and
    # the probe just continued scrolling down from the still-frozen 1).
    is($counts[-1], 1,
       'C4 up (specific): final overlay count is 1, not 2 -- ESC [ A assembled into UP-ARROW ' .
       '(offset correctly returned to 0 before the probe), not dropped/misread as a literal [');
}

# ===========================================================================
# C5 -- the gather (state refresh) cadence stays WALL-CLOCK-gated even under
# an irregular tick pattern (a burst of instantly-delivered keys interleaved
# with idle waits). This mirrors the ALREADY-CORRECT, must-not-regress rule
# at Dashboard.pm's "$t - $last_state >= $state_int" gate (spec s0): the test
# computes the expected gather count from the ACTUAL $t sequence the loop
# observed (via the injected `now` seam), not from a hardcoded tick count --
# so it fails if gathering ever becomes iteration-counted instead of wall-
# clock-gated, regardless of how irregular the ticks turn out to be.
# ===========================================================================
{
    my $STATE_INT = 1.0;
    my @burst_then_idle = (
        (1) x 3,   # 3 "scroll burst" ticks: wait_input returns instantly, no clock advance
        (0) x 6,   # 6 "idle" ticks: wait_input advances the clock by the full tick_interval
    );
    my $i = 0;
    my $c5 = drive_wi(
        max_ticks      => scalar(@burst_then_idle) + 1,
        state_interval => $STATE_INT,
        wait_input     => sub {
            my ($timeout, $clock_ref, $eff) = @_;
            my $is_burst = $burst_then_idle[$i++] // 0;
            if ($is_burst) { return 'k'; }   # 'k' is a scroll-up alias, harmless no-op at offset 0
            $$clock_ref += $timeout;
            return undef;
        },
    );

    # Recompute the expected gather count from the SAME rule the production
    # code uses, applied to the actual observed $t sequence (one entry per
    # top-of-loop iteration, via the injected `now` seam).
    my @t_log = @{ $c5->{now_log} || [] };
    my ($expected_gathers, $expected_last_state) = (0, undef);
    for my $t (@t_log) {
        if (!defined($expected_last_state) || $t - $expected_last_state >= $STATE_INT) {
            $expected_gathers++;
            $expected_last_state = $t;
        }
    }
    is($c5->{gathers}, $expected_gathers,
       'C5: gather count matches the wall-clock gate ($t - $last_state >= state_interval) applied to the ' .
       'actual observed clock sequence -- not a fixed per-N-iterations count');
    # An iteration-counted (broken) cadence firing every fixed number of
    # ticks regardless of elapsed time would NOT generally equal this
    # wall-clock-derived count once burst ticks (zero elapsed time) are
    # interleaved with idle ticks -- this is the regression this guards.
    ok($expected_gathers < scalar(@t_log),
       'C5 (sanity): the burst+idle mix is long enough that NOT every tick gathers (the cadence is doing real gating)');
}

# ===========================================================================
# C6 -- the default seam is byte-for-byte today's behaviour: with NO
# wait_input injected, the loop sleeps tick_interval via sleep_for exactly as
# now. This is the regression proof; t/25-dashboard.t itself is untouched and
# must stay green (verified separately by running that file, not here).
# ===========================================================================
{
    my $MAX = 6;
    my $c6 = drive_wi(max_ticks => $MAX);   # no wait_input key at all
    # Dashboard.pm's own max_ticks guard runs "$ticks++; last if ...; $sleep_for->(...)"
    # -- so a bounded run of N ticks calls sleep_for exactly N-1 times.
    is($c6->{sleep_calls}, $MAX - 1,
       'C6: with no wait_input injected, sleep_for is called exactly once per completed tick (unchanged)');
    is($c6->{sleep_elapsed}, ($MAX - 1) * $TICK,
       'C6: total wall-clock slept via sleep_for is exactly (ticks * tick_interval), unchanged from today');
    ok(!$c6->{wait_calls}, 'C6: wait_input is never invoked when the caller supplies none');
}

# ===========================================================================
# C7 -- Windows mechanism: the real implementation (in launcher.pl) must be
# built on Term::ReadKey::ReadKey with a TIMEOUT, and must NOT use 4-arg
# `select` to watch STDIN for readiness (select is socket-only on Windows and
# cannot watch the console handle there). Asserted on source, since this
# cannot be exercised on Linux. The regex is scoped to the wait_input
# CONSTRUCTION specifically (a variable timeout arg, not a literal -1/0,
# which are the pre-existing non-blocking/blocking polls already in the
# file) so it cannot false-match an unrelated neighbouring ReadKey call.
# ===========================================================================
{
    my $launcher_path = "$Bin/../../scripts/launcher.pl";
    ok(-f $launcher_path, "C7: found launcher.pl at $launcher_path") or BAIL_OUT('cannot locate launcher.pl');
    open my $fh, '<', $launcher_path or BAIL_OUT("cannot read launcher.pl: $!");
    local $/;
    my $src = <$fh>;
    close $fh;

    # Isolate the wait_input construction specifically (a `wait_input => sub
    # { ... }` assignment), so we don't accidentally match the file's other,
    # pre-existing ReadKey(-1)/ReadKey(0) polling blocks used by read_key.
    my ($wait_body) = $src =~ /wait_input\s*=>\s*sub\s*\{(.*?)\n\s{0,8}\},?\s*\n/s;

    ok(defined $wait_body,
       'C7 (existence): launcher.pl defines a wait_input => sub {...} seam construction')
        or diag('wait_input is not yet built in launcher.pl -- expected pre-implementation');

    # NO SKIP HERE, DELIBERATELY (coordinator, 2026-08-03). This was a
    #   SKIP: { skip '... not yet built ...', 2 unless defined $wait_body; ... }
    # whose condition IS the failure state — the exact shape this blueprint's standing rule
    # forbids. Pre-implementation it stays quiet instead of failing, and worse: if the
    # implementation is built in a shape this regex does not match, the two checks below skip
    # FOREVER and can never fail. A criterion that cannot fail is not a criterion.
    #
    # Substituting the empty string makes both assertions run unconditionally: they fail loudly
    # now (nothing to match), and they keep failing if the seam is ever built in an unmatchable
    # shape — which is precisely when someone needs to be told.
    my $wait_src = defined $wait_body ? $wait_body : '';
    like($wait_src, qr/Term::ReadKey::ReadKey\s*\(\s*\$/,
         'C7: wait_input is built on Term::ReadKey::ReadKey with a VARIABLE timeout argument ' .
         '(not the pre-existing literal -1/0 non-blocking polls elsewhere in the file)');
    unlike($wait_src, qr/\bselect\s*\(/,
           'C7: wait_input does not use select() at all')
        if length $wait_src;   # an empty body vacuously satisfies `unlike`; the `like` above is the real gate
    ok(length $wait_src,
       'C7 (anti-vacuity): the wait_input body was actually located, so the checks above were real');

    # File-wide (not just wait_input's body): no 4-arg select watching STDIN
    # for readiness via a vec()/fileno(STDIN) bitmask. The file's existing
    # `select(undef, undef, undef, $secs)` calls are a harmless sleep-only
    # idiom (all three bit-vectors are undef, nothing is being watched) and
    # must not false-trip this -- the forbidden shape specifically builds a
    # bitmask against STDIN's file descriptor.
    unlike($src, qr/vec\([^,]*,\s*fileno\s*\(\s*STDIN\s*\)/s,
           'C7: no 4-arg select() is used to watch STDIN for readiness anywhere in launcher.pl ' .
           '(select cannot watch the console handle on Windows)');
}

done_testing();
