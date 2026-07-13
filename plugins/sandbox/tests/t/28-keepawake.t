#!/usr/bin/env perl
# KeepAwake.pm (B5) — the keep-awake decision + the seam-injected lifecycle
# holder. The actual Windows wake-lock (keep-awake.ps1 / SetThreadExecutionState)
# and whether the machine really stays awake are verified on a real desktop
# (attended); here we pin the deterministic logic:
#
#   should_stay_awake   freshness-of-busy-lease decision; absent lease -> sleep,
#                       a negative age (clock skew on a fresh lease) -> stay awake
#   holder lifecycle    start-when-wanted / stop-when-not / idempotent / release
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('KeepAwake') or BAIL_OUT('KeepAwake.pm did not load');

# ---- should_stay_awake ----------------------------------------------------
is(KeepAwake::should_stay_awake(undef, 180), 0, 'absent lease (undef age) -> sleep');
is(KeepAwake::should_stay_awake(0,     180), 1, 'just-touched lease (age 0) -> awake');
is(KeepAwake::should_stay_awake(60,    180), 1, 'fresh lease (age < stale) -> awake');
is(KeepAwake::should_stay_awake(180,   180), 1, 'lease exactly at stale threshold -> awake');
is(KeepAwake::should_stay_awake(181,   180), 0, 'stale lease (age > stale) -> sleep');
is(KeepAwake::should_stay_awake(99999, 180), 0, 'very stale lease -> sleep');
is(KeepAwake::should_stay_awake(-5,    180), 1, 'negative age (clock skew on a fresh lease) -> stay awake (active-run safety)');
is(KeepAwake::should_stay_awake(-9999, 180), 1, 'large negative age (big skew) -> still stay awake');
# stale defaulting / garbage guard
is(KeepAwake::should_stay_awake(120),        1, 'default stale (180): age 120 -> awake');
is(KeepAwake::should_stay_awake(120, undef),  1, 'undef stale -> default 180 -> awake');
is(KeepAwake::should_stay_awake(120, 'x'),    1, 'garbage stale -> default 180 -> awake');
is(KeepAwake::should_stay_awake(300, 600),    1, 'custom larger stale window respected');

# ---- holder lifecycle (seam-injected) -------------------------------------
{
    my @ev;                       # records start/stop with the handle
    my $next_pid = 4100;
    my $h = KeepAwake->new(
        start => sub { my $pid = $next_pid++; push @ev, "start:$pid"; $pid },
        stop  => sub { push @ev, "stop:$_[0]" },
    );

    is($h->running, 0, 'holder starts not-running');
    is($h->sync(0), 'noop',  'sync(0) when idle -> noop (no helper spawned)');
    is(scalar @ev, 0, 'no seam fired on noop');

    is($h->sync(1), 'start', 'sync(1) when idle -> start');
    is($h->running, 1, 'holder now running');
    is($h->handle, 4100, 'holder tracks the started handle (pid)');
    is_deeply(\@ev, ['start:4100'], 'start seam fired once with a fresh pid');

    is($h->sync(1), 'noop', 'sync(1) again -> noop (idempotent; no double-spawn)');
    is(scalar @ev, 1, 'no extra seam on idempotent sync');

    is($h->sync(0), 'stop', 'sync(0) when running -> stop');
    is($h->running, 0, 'holder stopped');
    is($h->handle, undef, 'handle cleared after stop');
    is_deeply(\@ev, ['start:4100', 'stop:4100'], 'stop seam fired with the right handle');

    is($h->sync(0), 'noop', 'sync(0) again -> noop');

    # restart gets a fresh handle
    is($h->sync(1), 'start', 're-start after stop');
    is($h->handle, 4101, 'restart spawns a new helper (new pid)');
    is($h->release, 'stop', 'release() stops a running holder');
    is($h->running, 0, 'release left it stopped');
    is($h->release, 'noop', 'release() on a stopped holder -> noop (safe at teardown)');
}

# ---- defaults are safe (no seams supplied) --------------------------------
{
    my $h = KeepAwake->new;            # no start/stop -> safe no-ops
    is($h->sync(1), 'start', 'default holder: sync(1) flips running even with no seam');
    is($h->running, 1, 'default holder running');
    is($h->release, 'stop', 'default holder: release is safe');
}

# ---- a start seam that returns undef still flips running (seam owns failure) -
{
    my $stops = 0;
    my $h = KeepAwake->new(start => sub { undef }, stop => sub { $stops++ });
    is($h->sync(1), 'start', 'start seam returning undef still -> start');
    is($h->running, 1, 'running even though handle is undef');
    is($h->handle, undef, 'handle is undef when the seam returns undef');
    is($h->sync(0), 'stop', 'stop still fires (with undef handle)');
    is($stops, 1, 'stop seam called once');
}

# ---- orphan_is_ours($cmdline, $marker) ------------------------------------
# Decision #10: returns 1 iff $cmdline contains $marker as a case-insensitive
# substring; 0 otherwise. undef/empty $cmdline -> 0 (must not warn/die).
SKIP: {
    skip 'orphan_is_ours not yet defined in KeepAwake', 7
        unless KeepAwake->can('orphan_is_ours');

    is(KeepAwake::orphan_is_ours(
            'powershell.exe -NoProfile -File C:\\path\\keep-awake.ps1 -PidFile x',
            'keep-awake.ps1'),
        1, 'cmdline containing marker -> 1');

    is(KeepAwake::orphan_is_ours(
            uc('powershell.exe -NoProfile -File C:\\path\\keep-awake.ps1 -PidFile x'),
            'keep-awake.ps1'),
        1, 'uppercased cmdline still matches (case-insensitive) -> 1');

    is(KeepAwake::orphan_is_ours(
            'powershell.exe -NoProfile -Command Do-Something-Else',
            'keep-awake.ps1'),
        0, 'cmdline without marker -> 0');

    is(KeepAwake::orphan_is_ours('', 'keep-awake.ps1'),
        0, 'empty cmdline -> 0');

    # undef must not die or warn
    my $result = eval { KeepAwake::orphan_is_ours(undef, 'keep-awake.ps1') };
    is($@, '', 'undef cmdline does not die');
    is($result, 0, 'undef cmdline -> 0');

    # marker appears as substring mid-string (not only at end)
    is(KeepAwake::orphan_is_ours(
            'C:\\tools\\keep-awake.ps1.bak is not the target',
            'keep-awake.ps1'),
        1, 'marker as strict substring mid-string -> 1 (substring match)');
}

# Announce skipped tests when the sub is missing so the fail reason is visible
if (!KeepAwake->can('orphan_is_ours')) {
    # Emit one explicit failure so the test file exits non-zero and the
    # run-tests.pl harness reports FAIL — right reason: sub not yet defined.
    fail('orphan_is_ours is not yet defined in KeepAwake — implement Decision #10');
}

done_testing();
