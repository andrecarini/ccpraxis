#!/usr/bin/env perl
# A3 governance decision functions (bp-govern.pl): burn-rate cadence (#8),
# derived trip point (#9), refresh timing (#11), ISO->epoch (A0). Pure + exact.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use Time::Local qw(timegm);

require "$Bin/../../scripts/bp-govern.pl";

plan tests => 25;

sub near { my ($a,$b,$msg,$eps)=@_; $eps//=1e-6; ok(abs($a-$b) < $eps, $msg) or diag("got $a want $b"); }

# ---- burn_per_sec ---------------------------------------------------------
near(BpGovern::burn_per_sec([[0,50],[100,52]]), 0.02, 'burn: rising 2%/100s = 0.02%/s');
is(BpGovern::burn_per_sec([[0,50]]), undef, 'burn: <2 samples = undef');
near(BpGovern::burn_per_sec([[0,50],[100,50]]), 0, 'burn: flat = 0');
ok(BpGovern::burn_per_sec([[0,52],[100,50]]) < 0, 'burn: decreasing = negative');
is(BpGovern::burn_per_sec([[5,50],[5,60]]), undef, 'burn: zero dt = undef');

# ---- should_pause / trip_point (#9) ---------------------------------------
is(BpGovern::should_pause(80, 0.01,  600, 85), 1, 'pause: 80 + 0.01*600 = 86 >= 85');
is(BpGovern::should_pause(80, 0.005, 600, 85), 0, 'no pause: 80 + 0.005*600 = 83 < 85');
is(BpGovern::should_pause(80, -0.5,  600, 85), 0, 'no pause: negative burn never crosses');
near(BpGovern::trip_point(0.01, 600, 85), 79, 'trip: 85 - 0.01*600 = 79');
is(BpGovern::trip_point(1, 600, 85), 0, 'trip: floored at 0 for huge burn');

# ---- window_cadence / next_cadence (#8) -----------------------------------
is(BpGovern::window_cadence([[0,50]], 85), 300, 'cadence: <2 samples = 5min');
is(BpGovern::window_cadence([[0,50],[100,50]], 85), 1800, 'cadence: flat burn = 30min');
is(BpGovern::window_cadence([[0,52],[100,50]], 85), 1800, 'cadence: decreasing = 30min');
near(BpGovern::window_cadence([[0,50],[100,52]], 85), 825, 'cadence: headroom 33 / 0.02 * 0.5 = 825s');
is(BpGovern::window_cadence([[0,84],[100,84.5]], 85), 60, 'cadence: near trip floors at 60s');
is(BpGovern::window_cadence([[0,10],[100,10.01]], 85), 1800, 'cadence: tiny burn caps at 30min');
# min over both windows
is(BpGovern::next_cadence([[0,84],[100,84.5]], 85, [[0,10],[100,11]], 90), 60,
   'next_cadence: takes the tighter (5h) window');

# ---- refresh_state (#11) --------------------------------------------------
my $H = 3_600_000;
is(BpGovern::refresh_state(3*$H, 0), 'ok',          'refresh: 3h life = ok (too early)');
is(BpGovern::refresh_state(1.5*$H, 0), 'refresh',   'refresh: 1.5h life = refresh (in band)');
is(BpGovern::refresh_state(0.5*$H, 0), 'pause-floor','refresh: 0.5h life = pause-floor');
is(BpGovern::refresh_state(1*$H, 0), 'pause-floor', 'refresh: exactly 1h = pause-floor (<=floor)');

# ---- iso_to_epoch (A0) ----------------------------------------------------
is(BpGovern::iso_to_epoch('1970-01-01T00:00:00Z'), 0, 'iso: epoch zero (Z)');
is(BpGovern::iso_to_epoch('1970-01-01T01:00:00+01:00'), 0, 'iso: +01:00 offset applied to UTC');
is(BpGovern::iso_to_epoch('2026-06-22T05:59:59.764433+00:00'),
   timegm(59,59,5,22,5,2026), 'iso: real usage resets_at w/ microseconds + offset');
is(BpGovern::iso_to_epoch('not-a-date'), undef, 'iso: garbage = undef');
