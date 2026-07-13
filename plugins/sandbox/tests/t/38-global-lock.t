#!/usr/bin/env perl
# SandboxLock.pm (04-build-race-lock) — unit tests for the NEW module.
# Acceptance criteria L1–L6 (spec: 04-build-race-lock-spec.md).
#
# IMPORTANT: SandboxLock.pm does not exist yet.  L1–L5 will be skipped with
# a "missing module" diagnostic.  L6 fails because launcher.pl is not yet
# migrated.  All failures are the intended fail-first state.
#
# Use timeout=>0 everywhere (Decision #9) so the suite never waits.

use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Test::More;

plan tests => 11;

# ---------------------------------------------------------------------------
# Load SandboxLock.pm — guard so a missing module produces a clean skip for
# L1–L5 rather than a crash, while still allowing L6 to execute.
# ---------------------------------------------------------------------------
my $HAVE_LOCK_MODULE = eval {
    require "$Bin/../../scripts/SandboxLock.pm";
    1;
};
my $LOAD_ERR = $@;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Returns the path for a lock dir that does NOT yet exist inside a temp
# parent that will be cleaned up automatically.
sub fresh_lock_dir {
    my $parent = tempdir(CLEANUP => 1);
    return File::Spec->catdir($parent, 'lock');
}

# Definitely-dead pid: 2_000_000_000 is far beyond the pid-space ceiling on
# both Linux (4_194_304) and Windows.  Verified at test time via kill(0,...).
my $DEAD_PID = 2_000_000_000;

# ---------------------------------------------------------------------------
# L1 — acquire / reject
# ---------------------------------------------------------------------------

SKIP: {
    skip("SandboxLock.pm absent or failed to load ($LOAD_ERR) — L1..L5 skipped", 9)
        unless $HAVE_LOCK_MODULE;

    my $d1 = fresh_lock_dir();

    my $got = SandboxLock::acquire($d1, timeout => 0);
    is($got, 1, 'L1a: acquire of unheld lock returns 1');

    my $got2 = SandboxLock::acquire($d1, timeout => 0);
    is($got2, 0, 'L1b: second acquire of already-held lock returns 0');

    # L5 — timeout=0 non-blocking (measured against the same reject path)
    my $d_timing = fresh_lock_dir();
    SandboxLock::acquire($d_timing, timeout => 0);      # hold it

    my $t0 = time();
    SandboxLock::acquire($d_timing, timeout => 0);      # should reject instantly
    my $elapsed = time() - $t0;

    ok($elapsed <= 2, "L5: reject with timeout=>0 returns within 2s (got ${elapsed}s)");

    SandboxLock::release($d_timing);

    # L2 — release + re-acquire
    SandboxLock::release($d1);

    my $got3 = SandboxLock::acquire($d1, timeout => 0);
    is($got3, 1, 'L2: after release, re-acquire of same dir returns 1');

    SandboxLock::release($d1);

    # L3 — stale-owner reclaim
    SKIP: {
        my $alive = kill(0, $DEAD_PID);
        skip("DEAD_PID $DEAD_PID appears alive on this system — L3 skipped", 1) if $alive;

        my $d2_parent = tempdir(CLEANUP => 1);
        my $d2 = File::Spec->catdir($d2_parent, 'stale-lock');

        make_path($d2);
        open(my $fh, '>', File::Spec->catfile($d2, 'pid'))
            or die "Cannot write pid file: $!";
        print $fh $DEAD_PID;
        close $fh;

        my $reclaimed = SandboxLock::acquire($d2, timeout => 0);
        is($reclaimed, 1, "L3: stale lock (dead pid $DEAD_PID) reclaimed — returns 1");

        SandboxLock::release($d2);
    }

    # L4 — owned-set / release_all
    my $d4a = fresh_lock_dir();
    my $d4b = fresh_lock_dir();

    is(SandboxLock::acquire($d4a, timeout => 0), 1, 'L4 setup: acquire d4a returns 1');
    is(SandboxLock::acquire($d4b, timeout => 0), 1, 'L4 setup: acquire d4b returns 1');

    SandboxLock::release_all();

    ok(!-e $d4a, 'L4a: after release_all, d4a lock dir is gone');
    ok(!-e $d4b, 'L4b: after release_all, d4b lock dir is gone');
}

# ---------------------------------------------------------------------------
# L6 — source-text assertions on launcher.pl (independent; always runs)
# ---------------------------------------------------------------------------

my $launcher = File::Spec->catfile($Bin, '..', '..', 'scripts', 'launcher.pl');

SKIP: {
    skip("launcher.pl not found at $launcher", 2) unless -f $launcher;

    open(my $lfh, '<', $launcher) or die "Cannot read launcher.pl: $!";
    my $src = do { local $/; <$lfh> };
    close $lfh;

    # L6a: old inline functions must be gone (currently NOT gone → expect FAIL)
    unlike($src, qr/\b(acquire_lock|release_lock)\b/,
        'L6a: launcher.pl has no acquire_lock / release_lock (migrated to SandboxLock::)');

    # L6b: new module reference + global build-lock path must be present
    # (currently absent → expect FAIL)
    ok(
        ($src =~ /SandboxLock::/ && $src =~ /image-build/),
        'L6b: launcher.pl references SandboxLock:: AND the global image-build lock path'
    );
}

done_testing();
