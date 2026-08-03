#!/usr/bin/env perl
# bp-govern.pl — the deterministic usage-governance decision functions for the
# orchestrator (A3). Pure, side-effect-free, unit-tested (Decision #25: every
# decision the orchestrator makes is unit-tested). A3 assembles these; the
# process-management (watch/launch/relaunch, busy-lease) and A1-integration are
# separate and live in the orchestrator proper.
#
# Decisions encoded here:
#   #8  burn-rate-adaptive poll cadence
#   #9  derived trip point BELOW the ceiling (pause before the wall)
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
sub refresh_state {
    my ($expires_ms, $now_ms, $lo_h, $hi_h) = @_;
    $lo_h //= 1; $hi_h //= 2;
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
