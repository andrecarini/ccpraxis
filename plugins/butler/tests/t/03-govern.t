#!/usr/bin/env perl
# A3 governance decision functions (bp-govern.pl): burn-rate cadence (#8),
# derived trip point (#9), refresh timing (#11), ISO->epoch (A0). Pure + exact.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use Time::Local qw(timegm);

require "$Bin/../../scripts/bp-govern.pl";

plan tests => 30;

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
#
# RETARGETED by b30-usage-poll-cadence-floor, 2026-08-03. These assertions pinned the cadence
# semantics that CAUSED a live incident: on 2026-07-29 the five-hour window went 78% -> outright
# API rejection with no pause in between, because the poll had relaxed to its 30-minute floor.
# The run was dead for 5.6 hours.
#
# Every fixture below uses a 100-SECOND span, which is under the new BURN_MIN_SPAN_S (180s). A
# slope measured over 100s is not evidence about the next thirty minutes, so such a window is now
# UNKNOWN, and unknown holds the FAST cadence rather than relaxing. Recorded verbatim per b26:
#
#   OLD: is(window_cadence([[0,50]], 85), 300, 'cadence: <2 samples = 5min');
#   NEW: ... CADENCE_MIN_S (60)   -- <2 samples is the least-informed state there is; 300s was
#                                    the fail-UNSAFE direction and is the defect in miniature.
#   OLD: is(window_cadence([[0,50],[100,50]], 85), 1800, 'cadence: flat burn = 30min');
#   NEW: ... 60                   -- a FLAT short window is exactly the incident (78,78 65s apart).
#   OLD: is(window_cadence([[0,52],[100,50]], 85), 1800, 'cadence: decreasing = 30min');
#   NEW: ... 60                   -- decreasing over 100s is unmeasured, not falling.
#   OLD: near(window_cadence([[0,50],[100,52]], 85), 825, 'headroom 33 / 0.02 * 0.5');
#   NEW: ... 60                   -- the projection needs a trustworthy slope; 100s is not one.
#   OLD: is(window_cadence([[0,10],[100,10.01]], 85), 1800, 'cadence: tiny burn caps at 30min');
#   NEW: ... 60                   -- a "tiny burn" over 100s is indistinguishable from noise.
#
# The one assertion NOT changed is the 60s near-trip floor below: it already held, and it is the
# behaviour the fix generalises. The long-span equivalents of the relaxation cases are asserted in
# t/81 (C4), so "an idle fleet still relaxes to 30min" remains pinned — just at a span where the
# measurement means something.
is(BpGovern::window_cadence([[0,50]], 85), 60, 'cadence: <2 samples -> FAST (unknown is never slow)');
is(BpGovern::window_cadence([[0,50],[100,50]], 85), 60, 'cadence: flat over a SHORT span -> FAST (the incident shape)');
is(BpGovern::window_cadence([[0,52],[100,50]], 85), 60, 'cadence: decreasing over a SHORT span -> FAST (unmeasured, not falling)');
is(BpGovern::window_cadence([[0,50],[100,52]], 85), 60, 'cadence: projection needs a trustworthy slope; 100s span -> FAST');
is(BpGovern::window_cadence([[0,84],[100,84.5]], 85), 60, 'cadence: near trip floors at 60s');
is(BpGovern::window_cadence([[0,10],[100,10.01]], 85), 60, 'cadence: tiny burn over a SHORT span -> FAST (noise, not signal)');
# The relaxation property still holds at a span long enough to mean something (t/81 C4 pins this too).
is(BpGovern::window_cadence([[0,10],[600,10]], 85), 1800, 'cadence: flat over a LONG span at low util -> still relaxes to 30min');
# min over both windows
is(BpGovern::next_cadence([[0,84],[100,84.5]], 85, [[0,10],[100,11]], 90), 60,
   'next_cadence: takes the tighter (5h) window');

# ---- refresh_state (#11) --------------------------------------------------
my $H = 3_600_000;
is(BpGovern::refresh_state(3*$H, 0), 'ok',          'refresh: 3h life = ok (too early)');
is(BpGovern::refresh_state(1.5*$H, 0), 'refresh',   'refresh: 1.5h life = refresh (in band)');
# The DEFAULT floor is 10 minutes, not 1 hour (BpGovern::TOKEN_FLOOR_H,
# operator decision 2026-08-12). These two used to assert 0.5h and exactly 1h
# were under the floor, which was true only of the old default. Keeping them
# unchanged would have re-pinned the very value the change moved.
is(BpGovern::refresh_state(0.5*$H, 0), 'refresh',
   'refresh: 0.5h life = refresh — above the 10-minute floor, still in band');
is(BpGovern::refresh_state(1*$H, 0), 'refresh',
   'refresh: exactly 1h = refresh — the old floor is now well inside the band');

# The floor itself, at and just either side of it.
my $FL = BpGovern::TOKEN_FLOOR_H() * $H;
is(BpGovern::refresh_state($FL, 0), 'pause-floor',
   'refresh: exactly at the floor = pause-floor (<=, not <)');
is(BpGovern::refresh_state($FL - 60_000, 0), 'pause-floor',
   'refresh: a minute under the floor = pause-floor');
is(BpGovern::refresh_state($FL + 60_000, 0), 'refresh',
   'refresh: a minute over the floor = refresh, not pause');

# An explicit lo_h still overrides, so callers that need a different floor
# (the keeper's tests do) are not forced onto the default.
is(BpGovern::refresh_state(0.5*$H, 0, 1), 'pause-floor',
   'refresh: an explicit 1h floor still puts 0.5h under it');

# ---- iso_to_epoch (A0) ----------------------------------------------------
is(BpGovern::iso_to_epoch('1970-01-01T00:00:00Z'), 0, 'iso: epoch zero (Z)');
is(BpGovern::iso_to_epoch('1970-01-01T01:00:00+01:00'), 0, 'iso: +01:00 offset applied to UTC');
is(BpGovern::iso_to_epoch('2026-06-22T05:59:59.764433+00:00'),
   timegm(59,59,5,22,5,2026), 'iso: real usage resets_at w/ microseconds + offset');
is(BpGovern::iso_to_epoch('not-a-date'), undef, 'iso: garbage = undef');
