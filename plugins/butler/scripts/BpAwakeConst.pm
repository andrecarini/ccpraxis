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

# state_root() -> $path | undef (Decision 22/26(a), package
# 08-host-awake-actuator). BYTE-IDENTICAL to BpHook::state_dir() for every
# environment (spec 2.1), re-implemented here rather than called through
# BpHook.pm so this one rule can be loaded with no rest of butler beside it
# (Decision 13): the sandbox launcher loads HostAwake.pm, which loads this
# file, with no guarantee the rest of the butler plugin is present. The two
# helpers below (path-is-absolute, bytes-normalisation, mirroring BpHook's
# own `_to_bytes` rule: a utf8-flagged string is encoded once, an unflagged
# one only if it is not already valid UTF-8, then backslashes become forward
# slashes) are closures kept out of the package stash on purpose -- AC-1/AC-2
# of awake-constants-single-source.t admit exactly the six constants plus
# this one sub, nothing else named in %BpAwakeConst::.
sub state_root {
    my $is_abs = sub {
        my ($p) = @_;
        return 0 unless defined $p && length $p;
        return 1 if $p =~ m{^/};
        return 1 if $p =~ m{^[A-Za-z]:[\\/]};
        return 0;
    };
    my $to_bytes = sub {
        my ($s) = @_;
        return undef unless defined $s;
        my $v = "$s";
        if (utf8::is_utf8($v)) {
            utf8::encode($v);
        } else {
            my $probe = $v;
            my $already_utf8 = utf8::decode($probe);
            utf8::encode($v) unless $already_utf8;
        }
        $v =~ tr{\\}{/};
        return $v;
    };

    my $bsd = $ENV{BUTLER_STATE_DIR};
    if (defined $bsd && length $bsd) {
        return undef unless $is_abs->($bsd);
        my $v = $to_bytes->($bsd);
        $v =~ s{/+$}{};
        return "$v/continuity";
    }
    for my $var (qw(HOME USERPROFILE)) {
        my $val = $ENV{$var};
        next unless defined $val && length $val && $is_abs->($val);
        my $v = $to_bytes->($val);
        $v =~ s{/+$}{};
        return "$v/.claude/butler-state/continuity";
    }
    return undef;
}
1;
