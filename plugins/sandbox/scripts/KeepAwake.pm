package KeepAwake;
# B5 — keep-awake held by the dashboard, gated by the orchestrator's busy-lease
# (Decisions #16/#21). While the dashboard is open the PC stays awake ONLY when
# there is active work or a pending auto-resume; it is allowed to sleep when idle
# OR when the only outstanding work is parked-waiting-for-a-human.
#
# The "active vs parked" judgement lives in the orchestrator (A3): it refreshes
# the busy-lease (`/tmp/.butler-busy`) every ~60s while work is active or an
# auto-resume is pending, and STOPS touching it when idle or only-parked. So the
# host-side dashboard does not re-derive that state — **busy-lease freshness is
# the keep-awake signal**. This module is the pure decision + a small lifecycle
# holder; the actual Windows wake-lock is asserted by `keep-awake.ps1`
# (SetThreadExecutionState via PowerShell, since Win32::API is absent in the host
# perl), started/stopped through injected seams so the lifecycle is testable.
#
# Split (mirrors Dashboard.pm / BackpackReview.pm): pure logic + seam-injected
# lifecycle here (unit-tested); the real spawn/kill of the PS helper + the lease
# read live in the launcher; whether the machine ACTUALLY stays awake is verified
# on a real desktop (attended).
use strict;
use warnings;

# should_stay_awake($lease_age_secs, $stale_secs) -> 1|0
#   $lease_age_secs = seconds since the busy-lease's mtime, or undef if the lease
#                     is absent / unreadable. $stale_secs = the freshness window
#                     (match the orchestrator's BUSY_STALE_SECS).
#   Awake iff the lease exists AND is fresh. Absent lease (undef) -> sleep.
#   A NEGATIVE age means the lease mtime is in the "future" — i.e. host/container
#   clock skew on a lease the orchestrator just wrote, which only happens while a
#   run is actively touching it. Treat that as fresh and STAY AWAKE: a wrong
#   "sleep" here lets the host drop into standby and kills the live run (observed),
#   whereas a wrong "stay awake" only wastes some idle power. (The launcher now
#   computes the age entirely in container time, so a negative age should be rare;
#   this is the belt-and-suspenders guard.)
sub should_stay_awake {
    my ($age, $stale) = @_;
    return 0 unless defined $age;
    $stale = 180 unless defined $stale && $stale =~ /^-?\d+(?:\.\d+)?$/;
    return 1 if $age < 0;          # clock-skew on a freshly-touched lease -> stay awake
    return ($age <= $stale) ? 1 : 0;
}

# new(start => \&start, stop => \&stop) — a lifecycle holder.
#   start->()        spawns the wake-lock helper, returns an opaque handle (PID).
#   stop->($handle)  releases it (kills the helper).
# Both default to no-ops so a holder is always safe to construct/sync.
sub new {
    my ($class, %a) = @_;
    return bless {
        start   => $a{start} || sub { undef },
        stop    => $a{stop}  || sub { },
        running => 0,
        handle  => undef,
    }, $class;
}

sub running { return $_[0]{running} ? 1 : 0 }
sub handle  { return $_[0]{handle} }

# sync($want) — converge the helper to the desired state. Idempotent: starts when
# wanted and not running, stops when running and not wanted, else does nothing.
# Returns the action taken: 'start' | 'stop' | 'noop'. A start whose seam returns
# undef still flips to running (the seam owns its own failure logging); callers
# that need start-failure detection should check the handle.
sub sync {
    my ($self, $want) = @_;
    if ($want && !$self->{running}) {
        $self->{handle}  = $self->{start}->();
        $self->{running} = 1;
        return 'start';
    }
    if (!$want && $self->{running}) {
        $self->{stop}->($self->{handle});
        $self->{handle}  = undef;
        $self->{running} = 0;
        return 'stop';
    }
    return 'noop';
}

# release — unconditional stop (dashboard exit / signal / END). Safe to call when
# not running. Equivalent to sync(0) but reads clearer at teardown sites.
sub release { return $_[0]->sync(0) }

# orphan_is_ours($cmdline, $marker) -> 1|0  (Decision #10)
#   Returns 1 iff both arguments are defined and $marker is a case-insensitive
#   substring of $cmdline; 0 otherwise. undef or empty $cmdline -> 0, no warning.
#   Used by _keepawake_reap_orphan to confirm a recycled pid still owns our
#   keep-awake.ps1 before sending taskkill.
sub orphan_is_ours {
    my ($cmdline, $marker) = @_;
    return 0 unless defined $cmdline && defined $marker;
    return 0 unless length($cmdline) && length($marker);
    return index(lc($cmdline), lc($marker)) >= 0 ? 1 : 0;
}

1;
