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

# new(start => \&start, stop => \&stop, on_event => \&on_event) — a lifecycle
# holder.
#   start->()        spawns the wake-lock helper, returns an opaque handle (PID).
#   stop->($handle)  releases it (kills the helper).
#   on_event->(%event) — s16-fleet-event-source: an optional emit seam, called
#     ONLY on a state TRANSITION (acquire/release), never on a repeated sync(1)
#     while already held nor a repeated sync(0) while already released -- that
#     would flood the activity panel with duplicates (the exact heartbeat-noise
#     problem s17 fixes elsewhere). Defaults to a no-op so existing callers that
#     don't pass it are unaffected. Never dies: a broken on_event coderef must
#     not take down the keep-awake lifecycle it's merely observing.
# All three default to no-ops so a holder is always safe to construct/sync.
sub new {
    my ($class, %a) = @_;
    return bless {
        start    => $a{start}    || sub { undef },
        stop     => $a{stop}     || sub { },
        on_event => $a{on_event} || sub { },
        running  => 0,
        handle   => undef,
        # s21: consecutive 'probe-failed' streak seen by on_probe. Reset by
        # any non-probe-failed result; never touched by plain sync() callers.
        probe_fail_streak => 0,
    }, $class;
}

sub running { return $_[0]{running} ? 1 : 0 }
sub handle  { return $_[0]{handle} }

# sync($want, %extra) — converge the helper to the desired state. Idempotent:
# starts when wanted and not running, stops when running and not wanted, else
# does nothing. Returns the action taken: 'start' | 'stop' | 'noop'. A start
# whose seam returns undef still flips to running (the seam owns its own
# failure logging); callers that need start-failure detection should check
# the handle.
#
# s21: %extra is an OPTIONAL trailing pairs list, backward-compatible with
# every existing one-argument call site (defaults to empty, changing nothing
# for them). When given, it is merged into the on_event payload -- but ONLY
# on a genuine transition (acquire/release), never on a 'noop' -- so on_probe
# can carry a release REASON (e.g. lease-absent vs container-gone, C3) into
# the log without adding a second emit path.
sub sync {
    my ($self, $want, %extra) = @_;
    if ($want && !$self->{running}) {
        $self->{handle}  = $self->{start}->();
        $self->{running} = 1;
        eval { $self->{on_event}->(kind => 'acquire', %extra); 1 };
        return 'start';
    }
    if (!$want && $self->{running}) {
        $self->{stop}->($self->{handle});
        $self->{handle}  = undef;
        $self->{running} = 0;
        eval { $self->{on_event}->(kind => 'release', %extra); 1 };
        return 'stop';
    }
    return 'noop';
}

# on_probe(\%result, $stale, $tolerance) -> 'start' | 'stop' | 'noop'
#   $result    : the three(+ok)-state probe struct (spec S2.1):
#                  { state => 'ok',            age => $seconds }
#                  { state => 'lease-absent'                  }
#                  { state => 'probe-failed',  detail => $str }
#                  { state => 'container-gone', detail => $str }
#   $stale     : the freshness window, forwarded to should_stay_awake unchanged.
#   $tolerance : consecutive 'probe-failed' results to HOLD through before
#                releasing (S2.3). Caller-supplied, never defaulted off a
#                launcher.pl constant -- mirrors should_stay_awake's $stale.
#
# This is a layer ABOVE should_stay_awake/sync, not a replacement (C6): it is
# the one piece of new decision logic this package adds, and it is the only
# thing that ever sees the three-state struct. A bare 'ok' delegates straight
# to the unchanged pure decision; the other three states are handled here.
#
# 'probe-failed' HOLDS (returns 'noop' with NO sync() call at all -- not even
# a no-op transition attempt, and critically no on_event emission) while the
# consecutive streak is <= $tolerance. Once the streak exceeds $tolerance, it
# releases the lock directly (bypassing sync()/on_event) -- the sustained-
# failure release is a safety valve, not an operator-visible transition; it
# only ever fires once (subsequent probe-failed calls see !running and stay a
# silent 'noop'). Any non-probe-failed result resets the streak to 0.
sub on_probe {
    my ($self, $result, $stale, $tolerance) = @_;
    my $state = (ref $result eq 'HASH') ? ($result->{state} // '') : '';

    if ($state eq 'ok') {
        $self->{probe_fail_streak} = 0;
        my $stay = should_stay_awake($result->{age}, $stale);
        return $self->sync($stay ? 1 : 0);
    }
    if ($state eq 'lease-absent') {
        $self->{probe_fail_streak} = 0;
        return $self->sync(0, reason => 'lease-absent');
    }
    if ($state eq 'container-gone') {
        $self->{probe_fail_streak} = 0;
        my %extra = (reason => 'container-gone');
        $extra{detail} = $result->{detail} if defined $result->{detail};
        return $self->sync(0, %extra);
    }
    if ($state eq 'probe-failed') {
        $tolerance = 0 unless defined $tolerance && $tolerance =~ /^\d+(?:\.\d+)?$/;
        $self->{probe_fail_streak}++;
        if ($self->{probe_fail_streak} > $tolerance) {
            # Route through sync() rather than stopping directly. A sustained
            # failure giving up on the lock IS a state transition, so it must
            # emit like every other one -- an earlier version called stop()
            # inline and emitted nothing, which would have made the single most
            # interesting release in this package invisible in the activity
            # panel. sync() is also the one place that owns handle/running, so
            # bypassing it risked those drifting apart.
            return $self->sync(0, reason => 'probe-failed-sustained',
                                   streak => $self->{probe_fail_streak});
        }
        return 'noop';
    }
    # Unrecognised state (e.g. a typo'd spelling): the safest response is to
    # do nothing rather than guess -- never touch the streak or the lock.
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
