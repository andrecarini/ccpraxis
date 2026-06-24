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

# burn_per_sec(\@samples) — samples = [[epoch_sec, utilization_pct], ...] (>=2,
# time-ordered). Uses the most recent two points. undef if <2 samples or no dt.
sub burn_per_sec {
    my ($s) = @_;
    return undef unless ref $s eq 'ARRAY' && @$s >= 2;
    my ($a, $b) = @{$s}[-2, -1];
    my $dt = $b->[0] - $a->[0];
    return undef if $dt <= 0;
    return ($b->[1] - $a->[1]) / $dt;            # %/sec (can be <=0 if flat/decreasing)
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

# Decision #8 (one window): next poll interval in seconds.
#   <2 samples -> 5min; burn<=0 -> 30min; else clamp(headroom/burn * 0.5, 60s, 30min).
sub window_cadence {
    my ($samples, $trip) = @_;
    return 300 unless ref $samples eq 'ARRAY' && @$samples >= 2;
    my $burn = burn_per_sec($samples);
    return 1800 if !defined $burn || $burn <= 0;
    my $current  = $samples->[-1][1];
    my $headroom = $trip - $current;
    return clamp(($headroom / $burn) * 0.5, 60, 1800);
}

# Decision #8: min cadence over both windows (the tighter constraint wins).
sub next_cadence {
    my ($s5, $trip5, $s7, $trip7) = @_;
    my $c5 = window_cadence($s5, $trip5);
    my $c7 = window_cadence($s7, $trip7);
    return $c5 < $c7 ? $c5 : $c7;
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
