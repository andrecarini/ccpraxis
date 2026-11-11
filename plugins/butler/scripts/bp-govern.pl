#!/usr/bin/env perl
# bp-govern.pl — the deterministic usage-governance decision functions for the
# orchestrator (A3). Pure, side-effect-free, unit-tested (Decision #25: every
# decision the orchestrator makes is unit-tested). A3 assembles these; the
# process-management (watch/launch/relaunch, busy-lease) and A1-integration are
# separate and live in the orchestrator proper.
#
# Decisions encoded here:
#   #8  burn-rate-adaptive poll cadence
#   #9  derived trip point BELOW the ceiling (pause before the wall), fed a WINDOWED burn
#       estimate (pause_burn_per_sec) and labelled by trigger (pause_trigger)
#   #11 token refresh timing (1-2h band; cross the 1h floor unrefreshed -> pause)
#   usage resets_at is ISO-8601 (A0) -> epoch for the runs/.paused contract
#
# require:  require "<path>/bp-govern.pl"; BpGovern::should_pause(...)
# CLI:      perl bp-govern.pl iso <iso8601>        # -> epoch seconds
#           perl bp-govern.pl refresh <exp_ms> <now_ms>   # -> ok|refresh|pause-floor

package BpGovern;
use strict;
use warnings;

sub clamp { my ($x,$lo,$hi)=@_; $x < $lo ? $lo : $x > $hi ? $hi : $x }

# b30-usage-poll-cadence-floor: named constants for window_cadence (spec §2). No bare
# literals in window_cadence's expression body — the oracle (t/81) greps for these.
use constant {
    CADENCE_MIN_S           => 60,
    CADENCE_MAX_S           => 1800,
    CADENCE_NEAR_CEIL_UTIL  => 75,
    CADENCE_NEAR_CEIL_MAX_S => 120,
    BURN_MIN_SPAN_S         => 180,
};

# burn_per_sec(\@samples) — samples = [[epoch_sec, utilization_pct], ...] (>=2,
# time-ordered). Uses the most recent two points. undef if <2 samples, no dt, or the
# sample span is under BURN_MIN_SPAN_S (too short a window to trust a slope from —
# b30: "unknown" has exactly one definition, shared with window_cadence).
#
# This is the CADENCE's slope. The pause decision no longer uses it: since 2026-11-11 the
# orchestrator and the usage gate hand should_pause pause_burn_per_sec (below), because a
# two-point slope turns one jump into a sustained rate. See the comment above that sub.
sub burn_per_sec {
    my ($s) = @_;
    return undef unless ref $s eq 'ARRAY' && @$s >= 2;
    my ($a, $b) = @{$s}[-2, -1];
    my $dt = $b->[0] - $a->[0];
    return undef if $dt <= 0;
    my $delta = $b->[1] - $a->[1];
    # DELIBERATELY PURE: no short-span rule here. `undef` from this sub means only "not
    # computable" (fewer than two samples, or dt <= 0), never "computable but untrustworthy".
    #
    # The span rule lives in window_cadence alone, because "unknown" means OPPOSITE things to
    # this sub's two callers: to the cadence it means poll FAST (safe), but should_pause does
    # `$burn = 0 if !defined $burn`, so to the pause decision it means ZERO BURN — do not pause.
    # A span check here therefore made the governor MORE likely to miss a pause, which is the
    # exact incident this package exists to prevent. should_pause's undef handling is pinned by
    # t/18 and is not ours to change.
    return $delta / $dt;                          # %/sec (can be <=0 if flat/decreasing)
}

# Decision #9: pause when projected post-drain peak would cross the ceiling.
#   current% + max(burn,0) * drain_secs >= ceiling  ->  pause now.
sub should_pause {
    my ($current, $burn, $drain_secs, $ceiling) = @_;
    $burn = 0 if !defined $burn || $burn < 0;
    return ($current + $burn * $drain_secs >= $ceiling) ? 1 : 0;
}

# ---- the PAUSE decision's burn estimate (2026-11-11 incident) ------------------------------
#
# burn_per_sec above is a two-point slope and stays that way: window_cadence and its oracles
# (t/usage-poll-cadence, t/bp-govern-decision-functions) are built on it. It must NOT feed the
# pause decision any more. On 2026-11-11 the 5h window sat flat at 27% for 30+ minutes, polled
# every ~64s; one poll then read 33% (very likely the operator's own interactive session --
# usage is account-wide). Two points made that 6%/64s, and 33 + (6/64)*600 = 89 >= 85 paused
# the fleet and slept it until the window reset: ~3.5 hours idle at 33% utilisation. One step
# was read as a sustained rate.
#
# pause_burn_per_sec is the estimate should_pause gets instead. It is the LARGER of two rates:
#
#   window rate     (newest - anchor) / dt, where anchor is the newest sample at least
#                   BURN_WINDOW_S older than the newest one. A one-off step is spread over the
#                   whole window: the incident's 6 points over 15+ minutes is ~4 points of
#                   projection, not 56. A burn that has lasted a whole window reads at its true
#                   rate, so the Decision #9 trip point (ceiling - burn*drain) is unchanged for
#                   it: +1%/min still trips at 75 against 85, exactly as before.
#
#   sustained rate  the SMALLER of the last two interval slopes (needs 3 samples). A single step
#                   has one fast interval next to a flat one, so its min is ~0 and it is filtered
#                   out; a real fast onset shows up in both intervals and trips within two polls,
#                   without waiting for the window to fill. This is the safety half: the window
#                   alone would let a 3%/min onset run to ~75 before tripping; with this term it
#                   trips at ~66, one poll later than the old two-point estimator did.
#
# SHORT HISTORY (span < BURN_WINDOW_S: right after start, or after the samples were reset) is
# where the earlier incident lives -- the governor that paused TOO LATE. "Unknown" must never
# collapse to zero burn here, because should_pause reads undef as zero and declines to pause.
# So with a short history the anchor is simply the OLDEST sample and the slope is NOT discounted
# for the missing time: the rate over the history that really exists is the best available
# estimate, and with exactly two samples it is identical to the old two-point slope. That is
# deliberately conservative -- a single step in the first minute after start can still pause --
# and its cost is now bounded: a projection-only pause re-checks within minutes (the
# orchestrator's projection recheck) instead of sleeping to the reset. Only fewer than two
# samples (or no positive dt) is undef, and then current >= ceiling still trips on its own.
#
# A gap (suspend, long cadence) needs no special case: the anchor is then the sample before the
# gap and the rate is the real average across it.
use constant {
    BURN_WINDOW_S    => 900,     # 15 minutes
    BURN_SAMPLES_MAX => 64,      # retention cap for trim_samples (60s polls: 16 per window)
};

sub pause_burn_per_sec {
    my ($s, $window) = @_;
    $window //= BURN_WINDOW_S;
    return undef unless ref $s eq 'ARRAY' && @$s >= 2;
    my $new = $s->[-1];

    my $anchor;
    for (my $i = $#$s - 1; $i >= 0; $i--) {
        if ($new->[0] - $s->[$i][0] >= $window) { $anchor = $s->[$i]; last; }
    }
    $anchor //= $s->[0];                          # short history: everything we have, undiscounted

    my @rates;
    my $dt = $new->[0] - $anchor->[0];
    push @rates, ($new->[1] - $anchor->[1]) / $dt if $dt > 0;

    if (@$s >= 3) {
        my ($x, $y, $z) = @{$s}[-3, -2, -1];
        my ($d1, $d2) = ($y->[0] - $x->[0], $z->[0] - $y->[0]);
        if ($d1 > 0 && $d2 > 0) {
            my ($r1, $r2) = (($y->[1] - $x->[1]) / $d1, ($z->[1] - $y->[1]) / $d2);
            push @rates, ($r1 < $r2 ? $r1 : $r2);
        }
    }
    return undef unless @rates;
    my ($max) = sort { $b <=> $a } @rates;
    return $max;                                  # %/sec, may be <= 0
}

# trim_samples(\@samples [, $window]) -> list. The retention rule for the orchestrator's sample
# buffers: keep every sample inside the window plus the newest one at or beyond it (the anchor
# pause_burn_per_sec needs), and never fewer than 3 (the sustained rate needs 3). Capped at
# BURN_SAMPLES_MAX. The previous rule was "last 5", which at the usual 60s cadence held only
# ~4 minutes and could never give a 15-minute window.
sub trim_samples {
    my ($s, $window) = @_;
    $window //= BURN_WINDOW_S;
    return () unless ref $s eq 'ARRAY' && @$s;
    my $newest = $s->[-1][0];
    my $start = 0;
    for (my $i = $#$s; $i >= 0; $i--) {
        if ($newest - $s->[$i][0] >= $window) { $start = $i; last; }
    }
    $start = @$s - 3 if @$s - $start < 3 && @$s >= 3;
    $start = @$s - BURN_SAMPLES_MAX if @$s - $start > BURN_SAMPLES_MAX;
    $start = 0 if $start < 0;
    return @{$s}[$start .. $#$s];
}

# pause_trigger(current, burn, drain, ceiling) -> 'ceiling' | 'projection' | undef.
# Which rule tripped, because the two need different waits: at or above the ceiling only the
# window reset brings relief; below it, the trip was a forecast, and a forecast is re-checked.
sub pause_trigger {
    my ($current, $burn, $drain_secs, $ceiling) = @_;
    return 'ceiling' if $current >= $ceiling;
    return should_pause($current, $burn, $drain_secs, $ceiling) ? 'projection' : undef;
}

# The derived trip level (for headroom math / display): ceiling - burn*drain.
sub trip_point {
    my ($burn, $drain_secs, $ceiling) = @_;
    $burn = 0 if !defined $burn || $burn < 0;
    my $t = $ceiling - $burn * $drain_secs;
    return $t < 0 ? 0 : $t;
}

# Decision #8 (one window): next poll interval in seconds. b30-usage-poll-cadence-floor
# rewrite — rules in precedence order (spec §2):
#   1. Ceiling proximity wins ALWAYS: current >= CADENCE_NEAR_CEIL_UTIL caps the interval
#      at CADENCE_NEAR_CEIL_MAX_S regardless of burn (incl. burn == 0).
#   2. Unknown burn (too few samples / dt<=0 / span < BURN_MIN_SPAN_S, all captured by
#      burn_per_sec returning undef) holds the FAST cadence (CADENCE_MIN_S) — fail-safe,
#      never the slow floor.
#   3. Flat-or-negative burn with a sufficient (known) span may relax to CADENCE_MAX_S —
#      still subject to rule 1's cap.
#   4. Otherwise clamp(headroom/burn * 0.5, CADENCE_MIN_S, CADENCE_MAX_S), then rule 1's cap.
sub window_cadence {
    my ($samples, $trip) = @_;

    # Rule 2a: fewer than 2 samples -> burn cannot even be attempted. Unknown -> fast.
    return CADENCE_MIN_S unless ref $samples eq 'ARRAY' && @$samples >= 2;

    my $current = $samples->[-1][1];
    my $burn    = burn_per_sec($samples);

    # The short-span rule lives HERE, not in burn_per_sec, because "unknown" is safe for the
    # cadence (poll fast) and UNSAFE for should_pause (which reads undef as zero burn and then
    # declines to pause). Scoping it to this sub keeps the pause path honest.
    #
    # The span rule applies to ALL short windows, flat ones INCLUDED. The package's own criterion
    # is explicit: "does not reset its cadence on a short FLAT sample window ... treated as unknown,
    # which holds the current (tighter) cadence rather than relaxing it." Two polls 65s apart both
    # reading 78% say almost nothing about the next thirty minutes — four coordinators were in
    # flight, each able to consume several points on one long turn. Flatness measured over 65s is
    # not evidence of calm; it is absence of evidence.
    my $span = $samples->[-1][0] - $samples->[-2][0];
    my $short_span = $span < BURN_MIN_SPAN_S;

    my $interval;
    if (!defined $burn || $short_span) {
        # Rule 2: unknown burn (dt<=0, or any slope over too short a span) -> fast, never slow.
        $interval = CADENCE_MIN_S;
    }
    elsif ($burn <= 0) {
        # Rule 3: flat-or-negative burn with a known, sufficient span -> may relax fully.
        $interval = CADENCE_MAX_S;
    }
    else {
        # Rule 4: the projection clamp.
        my $headroom = $trip - $current;
        $interval = clamp(($headroom / $burn) * 0.5, CADENCE_MIN_S, CADENCE_MAX_S);
    }

    # Rule 1: ceiling proximity wins always, regardless of how $interval was derived.
    $interval = CADENCE_NEAR_CEIL_MAX_S if $current >= CADENCE_NEAR_CEIL_UTIL && $interval > CADENCE_NEAR_CEIL_MAX_S;

    return $interval;
}

# Decision #8: min cadence over both windows (the tighter constraint wins).
sub next_cadence {
    my ($s5, $trip5, $s7, $trip7) = @_;
    my $c5 = window_cadence($s5, $trip5);
    my $c7 = window_cadence($s7, $trip7);
    return $c5 < $c7 ? $c5 : $c7;
}

# b30-usage-poll-cadence-floor spec §3: a rate_limit_event with status "rejected" observed
# anywhere in the coordinator event stream is an IMMEDIATE pause trigger, independent of the
# poll schedule — the governor must never wait for its next poll to learn the API is already
# refusing it. Pure: no clock, no cadence, no samples — just the observed events.
sub immediate_pause_trigger {
    my ($events) = @_;
    return 0 unless ref $events eq 'ARRAY';
    for my $ev (@$events) {
        next unless ref $ev eq 'HASH';
        next unless ($ev->{type} // '') eq 'rate_limit_event';
        # A REAL coordinator event nests this as rate_limit_info.status:
        #   {"type":"rate_limit_event","rate_limit_info":{"status":"rejected",...}}
        # The first cut of this sub only read a TOP-LEVEL $ev->{status}, which no real event
        # carries — so it matched nothing in production and the immediate-rejection trigger was
        # inert. Its own oracle passed because the oracle used the flat shape too. Both shapes
        # are accepted now: nested is what the API emits, flat is what the existing tests use.
        my $status = $ev->{status};
        $status = $ev->{rate_limit_info}{status}
            if !defined $status && ref $ev->{rate_limit_info} eq 'HASH';
        return 1 if defined $status && $status eq 'rejected';
    }
    return 0;
}

# Decision #11: refresh timing from token expiry.
#   life > hi(2h)      -> 'ok'         (too early; premature refresh is 429'd, A0)
#   floor(1h) < life<=hi -> 'refresh'  (the band)
#   life <= floor(1h)  -> 'pause-floor'(crossed the floor unrefreshed -> graceful pause)
# THE token floor, in hours: 10 minutes (operator decision 2026-08-12).
#
# It lives HERE, next to its only consumer, because it previously did not live
# anywhere: bp-usage-gate.pl and bp-token-keeper.pl each carried their own
# notion of it, and refresh_state defaulted to a third value (1 hour) for any
# caller that passed none. That is exactly how the keeper ended up silently
# running an hour-long floor after the gate had been moved to ten minutes --
# two constants and a default, one of them invisible.
#
# Callers may still override per-call (tests do). What they must not do is
# re-declare the default; import it from here.
use constant TOKEN_FLOOR_H => 10 / 60;

sub refresh_state {
    my ($expires_ms, $now_ms, $lo_h, $hi_h) = @_;
    $lo_h //= TOKEN_FLOOR_H; $hi_h //= 2;
    my $life_h = ($expires_ms - $now_ms) / 3_600_000;
    return 'pause-floor' if $life_h <= $lo_h;
    return 'refresh'     if $life_h <= $hi_h;
    return 'ok';
}

# A0: usage resets_at is ISO-8601 w/ optional fractional secs + offset.
# Returns epoch seconds (UTC), or undef if unparseable.
sub iso_to_epoch {
    my ($iso) = @_;
    return undef unless defined $iso
        && $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|([+-])(\d{2}):?(\d{2}))?/;
    my ($Y,$Mo,$D,$h,$m,$s) = ($1,$2,$3,$4,$5,$6);
    require Time::Local;
    my $epoch = Time::Local::timegm($s,$m,$h,$D,$Mo-1,$Y);
    if (defined $8 && $8 ne '' && $8 ne 'Z') {        # apply numeric offset -> UTC
        my $off = ($9*3600 + $10*60); $off = -$off if $8 eq '+';
        $epoch += $off;
    }
    return $epoch;
}

# ---- CLI (only when run directly) ----------------------------------------
package main;
use strict; use warnings;
unless (caller) {
    my $cmd = shift @ARGV // '';
    if    ($cmd eq 'iso')     { my $e = BpGovern::iso_to_epoch($ARGV[0]); defined $e ? print "$e\n" : (print STDERR "unparseable\n"), exit 1; }
    elsif ($cmd eq 'refresh') { print BpGovern::refresh_state($ARGV[0], $ARGV[1]), "\n"; }
    else  { print STDERR "usage: bp-govern.pl <iso <iso8601> | refresh <exp_ms> <now_ms>>\n"; exit 2; }
}
1;
