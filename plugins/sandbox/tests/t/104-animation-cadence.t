#!/usr/bin/env perl
# The spinner shipped with ten frames and could only ever show TWO of them.
#
# THE DEFECT
#
#   $now      = sub { time };            # INTEGER seconds
#   $spin_div = $tick_int;               # 0.2 by default
#   spinner_idx = int($t / $spin_div);   # int(<integer> / 0.2)
#
# int(N / 0.2) for integer N is always a multiple of 5, so `% 10` over the ten
# braille frames could only ever produce index 0 or 5. The dashboard alternated
# between exactly two glyphs, once per second, for as long as it ran. Nine of
# the ten frames were unreachable by ARITHMETIC -- not by configuration, not by
# a missing glyph -- which is why it presented as a glyph-table problem and was
# not one.
#
# WHY NO EXISTING ORACLE CAUGHT IT
#
# t/100 AC-6b and t/25 block E both assert the spinner index AGREES WITH A
# FORMULA they compute themselves, and t/100 AC-1 asserts the ten frames are
# distinct when indices 0..9 are passed in BY HAND. Every one of those passes
# with a live loop that never generates more than two distinct indices. Agreement
# and reachability are different properties, and only the first was pinned.
#
# So this file asserts REACHABILITY over the real derivation, and it does so
# without hard-coding the period OR the frame count: it reads the production
# constants, so raising or lowering a cadence -- or re-styling the sequence, as
# 2026-08-25 did when the ten uneven-dot frames became eight uniform ones --
# stays legal, while making most of the frames unreachable does not.
#
# It also pins the two things that made the defect possible, so it cannot be
# reintroduced by the same route:
#   * animation is driven by a SUB-SECOND clock, not by $now's integer seconds
#   * animation cadence is NOT the render tick (the render tick is an
#     input-latency decision; coupling them is what set the period to 0.2 in
#     the first place)
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');
require tui::DashboardScreen;
require Theme;   # SPINNER_FRAMES -- the frame count, derived like the periods

# ---------------------------------------------------------------------------
# A. The production cadences are sane and independent of the render tick.
# ---------------------------------------------------------------------------
my $SPIN  = Dashboard::SPINNER_PERIOD_SECS();
my $TITLE = Dashboard::TITLE_SPINNER_PERIOD_SECS();

ok($SPIN > 0,  'A1: the in-screen spinner period is a positive number');
ok($TITLE > 0, 'A2: the title spinner period is a positive number');
# A3 REVISED 2026-08-25. This asserted the title advances MORE SLOWLY than the
# in-screen spinner, on the reasoning that a title is glanced at rather than
# watched and each change costs an OSC write. The operator watched it and asked
# for it faster, which settles the design question: the write is a dozen-odd
# bytes, emitted only when the title STRING changes, so it is not a cost worth
# a slower spinner.
#
# What still deserves pinning is that the title cadence is a real, bounded
# number rather than something that drifted to zero or to a value nobody would
# notice -- so it is bounded on both sides instead of ranked against the other.
cmp_ok($TITLE, '<=', 2.0,
    'A3: the OS window title advances at least once every two seconds -- fast enough to read as alive');
cmp_ok($TITLE, '>=', 0.1,
    'A3: ...and not so fast that it rewrites the title faster than a terminal can usefully show it');

# ---------------------------------------------------------------------------
# B. THE REGRESSION ITSELF: all ten frames must be reachable from the real
#    derivation, driven by a sub-second clock.
#
# Deliberately derived from the production constant rather than a literal, so
# changing the cadence is legal and breaking reachability is not.
# ---------------------------------------------------------------------------
sub distinct_frames {
    my ($period, $span_secs, $step) = @_;
    my %seen;
    for (my $t = 0; $t < $span_secs; $t += $step) {
        my $f = tui::DashboardScreen::_spinner_frame(int($t / $period));
        $seen{$f}++ if defined $f;
    }
    return scalar keys %seen;
}

# The frame count is DERIVED for the same reason the period is. It was the
# literal 10 until 2026-08-25, when the sequence became eight uniform-dot
# frames; the claim -- EVERY frame is reachable in one cycle -- is unchanged and
# is what this file exists for.
my $N = Theme::SPINNER_FRAMES();

is(distinct_frames($SPIN, $SPIN * $N + $SPIN / 2, $SPIN / 8), $N,
    "B1: all $N spinner frames are reachable within one full cycle at the production period "
  . '(this is the assertion that fails against the shipped two-frame arithmetic)');

is(distinct_frames($TITLE, $TITLE * $N + $TITLE / 2, $TITLE / 8), $N,
    "B2: all $N title frames are reachable within one full cycle at the title period");

# ---------------------------------------------------------------------------
# C. THE COUNTER-FIXTURE -- the exact broken arithmetic, proving B1 is not
#    vacuously true of any period/clock combination.
#
# An INTEGER-seconds clock divided by a sub-second period lands on a coarse
# lattice. This is the shipped behaviour, reproduced, and it must be visibly
# different from what B1 measures -- otherwise B1 proves nothing.
# ---------------------------------------------------------------------------
{
    # THE PERIOD IS DERIVED, and it has to be. The shipped defect was period 0.2
    # against ten frames: an integer clock advances the index by exactly 1/period
    # = 5 per second, and 5 shares a factor with 10, so only 2 of the 10 frames
    # were ever reachable -- for ten minutes, or forever. With eight frames
    # (2026-08-25) 5 and 8 are coprime, so 0.2 happens to reach all of them and
    # the fixture stopped demonstrating anything at all: still green, proving
    # nothing, which is the worst state a counter-fixture can be in.
    #
    # What is being reproduced is the COARSE LATTICE, not the number 0.2. A
    # period of 1/$N makes the index advance by exactly $N per second, so an
    # integer clock lands on frame 0 and stays there -- the sharpest possible
    # form of the same defect, at whatever frame count is current.
    my $bad_period = 1 / $N;
    my %seen;
    for my $s (0 .. 600) {                      # ten minutes of integer seconds
        my $f = tui::DashboardScreen::_spinner_frame(int($s / $bad_period));
        $seen{$f}++ if defined $f;
    }
    is(scalar keys %seen, 1,
        "C1: COUNTER-FIXTURE -- integer seconds / (1/$N) yields exactly ONE distinct frame over TEN "
      . 'MINUTES, which is the defect this file exists to prevent recurring');
    cmp_ok(scalar(keys %seen), '<', $N,
        'C2: ...and is strictly worse than the production derivation, so B1 is not vacuous');
}

# ---------------------------------------------------------------------------
# D. The loop actually feeds a sub-second index.
#
# Drives the real run loop with a FRACTIONAL fake clock and collects the
# spinner indices it produces. With the old integer-seconds coupling these
# collapse; with the fix they walk.
# ---------------------------------------------------------------------------
{
    my $clock = 0;
    my %idx;
    my $tick = 0.05;
    Dashboard::run(
        color => 0, beat_interval => 9999, state_interval => 0,
        tick_interval => $tick, max_ticks => 40,
        spinner_period => $tick,       # many frames inside a short fake window
        now       => sub { $clock },
        sleep_for => sub { $clock += $_[0] },
        read_key  => sub { undef },
        term_size => sub { (80, 20) },
        gather    => sub { { project_name => 'p', container => 'c', status => 'running' } },
        heartbeat => sub { 'ok' },
        spawn     => sub { undef },
        stop_runs => sub { { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                             machine_stopped => 0, others => [], others_known => 0, summary => 'x' } },
        full_shutdown => sub { { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                             machine_stopped => 1, others => [], others_known => 1, summary => 'y' } },
        enter_raw => sub { }, leave_raw => sub { }, keepawake => sub { },
        out => sub {
            my ($s) = @_;
            # Count the distinct spinner glyphs that reach the terminal.
            $idx{$1}++ while $s =~ /\[(\S+) running\]/g;
        },
    );
    cmp_ok(scalar(keys %idx), '>=', 5,
        'D1: driving the real loop over a fractional clock puts at least 5 distinct spinner '
      . 'glyphs on screen (the shipped arithmetic could put at most 2 there, ever)');
}

# ---------------------------------------------------------------------------
# E. An INJECTED clock governs the animation too.
#
# hires_now falls back to `now` when the caller injected one. Without that, a
# test that holds time still would still see the animation advance underneath
# it from the real wall clock -- nondeterminism in precisely the tests written
# to be deterministic.
# ---------------------------------------------------------------------------
{
    my @out;
    my $frozen = 1000;
    Dashboard::run(
        color => 0, beat_interval => 9999, state_interval => 0,
        tick_interval => 0.1, max_ticks => 6,
        now       => sub { $frozen },        # time does not move
        sleep_for => sub { },                # ...and nothing advances it
        read_key  => sub { undef },
        term_size => sub { (80, 20) },
        gather    => sub { { project_name => 'p', container => 'c', status => 'running' } },
        heartbeat => sub { 'ok' },
        spawn     => sub { undef },
        stop_runs => sub { { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                             machine_stopped => 0, others => [], others_known => 0, summary => 'x' } },
        full_shutdown => sub { { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                             machine_stopped => 1, others => [], others_known => 1, summary => 'y' } },
        enter_raw => sub { }, leave_raw => sub { }, keepawake => sub { },
        out => sub { push @out, $_[0] },
    );
    my %glyphs;
    for my $s (@out) { $glyphs{$1}++ while $s =~ /\[(\S+) running\]/g }
    is(scalar(keys %glyphs), 1,
        'E1: with an injected, frozen clock the spinner does not advance -- the animation follows '
      . "the caller's clock, not a second one ticking underneath it");
}

# ---------------------------------------------------------------------------
# F. The period options are guarded. These values are DIVISORS.
# ---------------------------------------------------------------------------
{
    for my $bad (0, -1, 'abc', undef, [], {}) {
        my $label = !defined $bad ? 'undef' : (ref $bad ? ref $bad : "'$bad'");
        my $got = Dashboard::_period_opt($bad, 7);
        is($got, 7, "F1: _period_opt($label) falls back to the default (a 0 here is a division by zero)");
    }
    is(Dashboard::_period_opt(0.25, 7), 0.25, 'F2: a valid positive period is honoured');
}

done_testing();
