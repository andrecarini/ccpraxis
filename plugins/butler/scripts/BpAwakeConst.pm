package BpAwakeConst;
# BpAwakeConst -- the single source for the six timing quantities that decide
# whether the machine stays awake (blueprint wake-and-pause-consolidation,
# Decision 2). Every butler site requires this file by its own directory; the
# sandbox plugin (KeepAwake.pm) mirrors LEASE_FRESH as a pinned fallback
# literal instead, because it must keep working with no butler plugin beside
# it (blueprint wake-and-pause-consolidation, Decision 13). heartbeat.sh and
# Almanac::SessionLive stay literal too (one has no Perl, the other may not
# load a butler module); all three are pinned equal by
# plugins/butler/tests/t/awake-constants-single-source.t. No I/O here, so it
# is cheap enough to load eagerly wherever it's needed.
use strict;
use warnings;
# How far ahead a sandboxed fleet's usage-pause relaunch may be and still hold
# the machine awake (blueprint wake-and-pause-consolidation, Decision 2);
# BP_PAUSE_HORIZON_SECS overrides it in the orchestrator.
use constant FLEET_PAUSE_HORIZON => 32 * 3600;   # 115200
# drive-solo's single horizon for both keep-awake and the pause-long handoff
# (blueprint wake-and-pause-consolidation, Decision 2); distinct from the
# fleet value on purpose; Almanac::SessionLive's armed window is this + 1 h.
use constant SOLO_PAUSE_HORIZON  => 12 * 3600;   # 43200
# The busy-lease freshness window: busy lease, sandbox-hold files, the
# launcher's BUSY_STALE default, KeepAwake's default; heartbeat.sh's HB mirrors it.
use constant LEASE_FRESH         => 600;
# keep-awake.ps1's -LeaseSeconds: how long the helper outlives the last refresh
# of its pid file; also how long BpAcWatch reads a drive-solo keepawake.pid as held.
use constant HELPER_LEASE        => 900;
# On-battery grace before the AC-loss stand-down.
use constant AC_GRACE            => 300;
# BpAcWatch's fallback staleness for the wake-lock refresher's pid file, used
# only when BpContinuityLease cannot answer.
use constant AC_STALE            => 1800;
1;
