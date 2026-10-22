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

# classify_lease_stat_failure($output, $expected_path) -> $verdict | undef
#
# THE THIRD THING A `stat` FAILURE CAN MEAN. The busy-lease probe runs
# `stat -c %Y <lease>` inside the container and, until 2026-09-16, read ANY
# "No such file or directory" as 'lease-absent' -- a fact about the CONTAINER,
# which on_probe releases the wake-lock for immediately and without tolerance.
#
# On Windows that was wrong often enough to cost a night's fleet run. MSYS2
# rewrites argv elements that look like POSIX paths on their way into a native
# binary, so podman was handed the HOST's Windows temp directory and stat
# truthfully reported that no such file existed -- there. The container's lease
# was being refreshed every few seconds the whole time.
#
# Every stat implementation in play (GNU coreutils, busybox) quotes the
# offending path back in its message, so a quoted path that is NOT the one we
# asked for is positive evidence that the argument was rewritten in flight.
# That is a fact about US, and belongs in 'probe-failed' where on_probe holds
# through a tolerance rather than giving up.
#
# Returns:
#   undef            -- not a "no such file" failure; the caller's other
#                       classification paths still apply, unchanged.
#   'lease-absent'   -- a genuine absence: the message names our path, or names
#                       none at all.
#   'path-rewritten' -- the message names a DIFFERENT path.
#
# The no-path-named case deliberately falls back to 'lease-absent' rather than
# to the failure verdict: a stat variant that stays quiet must not be able to
# strand the wake-lock held forever after a run ends. Only positive evidence of
# rewriting diverges.
sub classify_lease_stat_failure {
    my ($output, $expected_path) = @_;
    return undef unless defined $output && $output =~ /no such file or directory/i;
    return 'lease-absent' unless defined $expected_path && length $expected_path;
    my ($named) = ($output =~ /['"]([^'"]+)['"]/);
    return 'lease-absent' unless defined $named && length $named;
    return ($named eq $expected_path) ? 'lease-absent' : 'path-rewritten';
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

# filetime_ticks($unix_seconds) -> decimal string | undef
#   UTC FILETIME ticks (100ns units since 1601-01-01) for a Unix time, as
#   keep-awake.ps1's -OwnerStartedBeforeTicks expects. Pure arithmetic: no
#   process is spawned (asking Windows for the owner's exact start time costs a
#   powershell.exe on the spawn path, measured to slow helper handover enough
#   to break lease-refresher-hygiene.t under load). Fractional
#   seconds are kept to 100ns resolution as far as a double allows; the helper
#   applies a 2s slack, so the rounding never matters. undef for anything that
#   is not a non-negative number.
#
#   CALLER CONTRACT: pass your own clock reading, taken while the owner is
#   certainly alive and before forking the helper -- for a self-owned helper,
#   simply "now" in the parent. A WINPID reused after the owner dies belongs to
#   a process created after that reading, which the helper then rejects.
sub filetime_ticks {
    my ($t) = @_;
    return undef unless defined($t) && !ref($t) && $t =~ /\A\d+(?:\.\d+)?\z/;
    return sprintf('%.0f', ($t + 11644473600) * 10_000_000);
}

1;
