#!/usr/bin/env perl
# platform: any
# A paused fleet holds the machine awake only when the relaunch is within 32 hours.
#
# Bug report 20261101-171529-1dd7: on 2026-11-01 fleet acxpraxis-step-2 paused on the seven_day
# window with relaunch_at 31 h ahead, and the laptop was held awake the whole wait. drive-solo has
# had a horizon since a pause 88 h out would have held a laptop awake Friday to Monday
# (bp-drive-next.pl pause_keepawake_phase, 6 h); the fleet path never got one. The operator set
# the fleet's horizon at 32 hours.
#
# AC1  pause_holds_awake: none/manual -> 0; timed within the horizon -> 1; beyond -> 0; no
#      relaunch_at (telemetry) -> 1; the boundary holds; a bad horizon falls back to 32 h
# AC2  the default tunable is 32 h and BP_PAUSE_HORIZON_SECS overrides it
# AC3  both wake decisions in the paused tick use it: the wake-lock phase and the busy lease
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
require "$Bin/../../scripts/bp-orchestrator.pl";

my $H   = 32 * 3600;
my $now = 1_793_531_812;
sub holds { BpOrch::pause_holds_awake(@_) }

# --- AC1 ---------------------------------------------------------------------------------------------
is(holds(undef, $now, $H), 0, 'AC1 not paused: nothing to hold for');
is(holds({ reason => 'auth', manual => 1 }, $now, $H), 0, 'AC1 a manual pause waits on a human: release');
is(holds({ reason => 'usage', relaunch_at => $now + 3600 }, $now, $H), 1, 'AC1 a usage pause 1 h out: hold');
is(holds({ reason => 'usage', relaunch_at => $now + 31 * 3600 }, $now, $H), 1, 'AC1 31 h out (the 2026-11-01 pause): hold');
is(holds({ reason => 'usage', relaunch_at => $now + $H }, $now, $H), 1, 'AC1 exactly on the horizon: hold');
is(holds({ reason => 'usage', relaunch_at => $now + $H + 1 }, $now, $H), 0, 'AC1 one second past it: release');
is(holds({ reason => 'usage', relaunch_at => $now + 88 * 3600 }, $now, $H), 0, 'AC1 THE BUG: 88 h out releases the machine');
is(holds({ reason => 'telemetry', manual => 0 }, $now, $H), 1, 'AC1 no relaunch_at (telemetry, cleared on recovery): hold');
is(holds({ reason => 'usage', relaunch_at => $now + 40 * 3600 }, $now, 'junk'), 0, 'AC1 a bad horizon falls back to 32 h');
is(holds({ reason => 'usage', relaunch_at => $now - 60 }, $now, $H), 1, 'AC1 an overdue relaunch: hold (resume is imminent)');

# --- AC2 ---------------------------------------------------------------------------------------------
{
    local $ENV{BP_PAUSE_HORIZON_SECS};
    delete $ENV{BP_PAUSE_HORIZON_SECS};
    is(BpOrch::_tunables_base()->{pause_horizon}, 32 * 3600, 'AC2 the default horizon is 32 hours');
    $ENV{BP_PAUSE_HORIZON_SECS} = 7200;
    is(BpOrch::_tunables_base()->{pause_horizon}, 7200, 'AC2 BP_PAUSE_HORIZON_SECS overrides it');
}

# --- AC3 ---------------------------------------------------------------------------------------------
my $src = do { open my $fh, '<:raw', "$Bin/../../scripts/bp-orchestrator.pl" or die $!; local $/; <$fh> };
like($src, qr/my \$ka_phase = !\$paused\s+\? 'active'\s*: BpAwakeIntent::want_awake\(\{\s*scope => 'fleet',\s*paused => \$paused,\s*now => \$now,\s*horizon => \$t->\{pause_horizon\}\s*\}\)->\{awake\} \? 'pause-pending'\s*:\s*'settled';/,
     'AC3 the wake-lock phase settles a pause beyond the horizon');
# 05 (blueprint Decision 18): the awake gate moved inside touch_busy itself, so the call site no
# longer tests ->{awake} externally; see spec 05-intent-in-busy-lease-spec.md section 6.3.
like($src, qr/touch_busy\(\$t->\{busy_path\}, BpAwakeIntent::want_awake\(\{\s*scope => 'fleet',\s*paused => \$paused,\s*now => \$now,\s*horizon => \$t->\{pause_horizon\},\s*shutdown => \$shutdown\s*\}\)\);/,
     'AC3 and the paused tick stops refreshing the busy lease beyond it, so the host launcher lets go too (05: touch_busy call shape per blueprint Decision 18)');

done_testing();
