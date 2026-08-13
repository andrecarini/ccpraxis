#!/usr/bin/env perl
# t/111-keepawake-shared.t — the wake-lock is ONE definition, and the FLEET
# holds it too.
#
# WHAT THIS PINS, AND WHY IT IS NOT PARANOIA.
#
# The keep-awake mechanism existed only in bp-drive-next.pl — the SOLO driver,
# the path where a human is sitting in the session and would notice a suspended
# host. bp-orchestrator.pl, which runs headless coordinators for hours with
# nobody watching, held no wake-lock at all. The lock was on the path that needs
# it least and absent from the one that needs it most, and a suspend on the
# fleet is both unrecoverable and unwitnessed. 3c661a0 records the real event:
# a watchdog armed for 1800s reported 7962s elapsed because the host suspended.
#
# The obvious fix — copy the helpers into the orchestrator — is a mistake this
# repo has already paid for twice: match_any needed t/108 to guard its two
# copies, and the token floor lived in three places (one an invisible default),
# which is how the keeper silently ran a 1-hour floor after the gate had moved
# to ten minutes. So this file pins BOTH properties: one definition, and both
# drivers using it.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;

require "$S/bp-keepawake.pl";

# ---------------------------------------------------------------- phases ----
is(BpKeepAwake::should_be_on('active'),        1, 'active -> lock held');
is(BpKeepAwake::should_be_on('pause-pending'), 1, 'timed pause -> lock HELD (it must be awake when the window reopens)');
is(BpKeepAwake::should_be_on('settled'),       0, 'settled -> lock released');
is(BpKeepAwake::should_be_on(undef),           0, 'undef phase -> released, never a held lock by accident');
is(BpKeepAwake::should_be_on('nonsense'),      0, 'unknown phase -> released (fail toward NOT holding the machine awake)');

# ------------------------------------------------------------- apply() ------
{
    my $dir = tempdir(CLEANUP => 1);
    my @spawned;
    BpKeepAwake::apply('active', $dir, {
        spawn                => sub { push @spawned, $_[0]; open my $w,'>',$_[0] or die; print $w "999999\n"; close $w; 999999 },
        powershell_available => sub { 1 },
    });
    is(scalar @spawned, 1, 'apply(active): spawns once');
    ok(-e "$dir/keepawake.pid", 'apply(active): records a pid file');

    # Idempotence: a LIVE lock is not doubled. $$ is definitely alive.
    open my $w, '>', "$dir/keepawake.pid" or die; print $w "$$\n"; close $w;
    my @again;
    BpKeepAwake::apply('active', $dir, {
        spawn                => sub { push @again, 1 },
        powershell_available => sub { 1 },
    });
    is(scalar @again, 0, 'apply(active): a live lock is left alone, not doubled');
}

{
    my $dir = tempdir(CLEANUP => 1);
    open my $w, '>', "$dir/keepawake.pid" or die; print $w "424242\n"; close $w;
    my @killed;
    BpKeepAwake::apply('settled', $dir, { kill_pid => sub { push @killed, $_[0] } });
    is_deeply(\@killed, ['424242'], 'apply(settled): kills the recorded pid');
    ok(!-e "$dir/keepawake.pid", 'apply(settled): clears the pid file');
}

{
    # No powershell -> no lock, and NO false claim of one. This is the exact
    # shape of the defect 3c661a0 fixed: the mechanism looked wired while the
    # production spawn/kill defaults were empty subs, so the driver reported
    # holding a lock it did not hold.
    my $dir = tempdir(CLEANUP => 1);
    my @spawned;
    BpKeepAwake::apply('active', $dir, {
        spawn                => sub { push @spawned, 1 },
        powershell_available => sub { 0 },
    });
    is(scalar @spawned, 0, 'no powershell -> no spawn attempted');
    ok(!-e "$dir/keepawake.pid", 'no powershell -> no pid file, so nothing later mistakes it for a held lock');
}

{
    # A spawn that dies is reported, not swallowed into a silent no-lock.
    my $dir = tempdir(CLEANUP => 1);
    my @logged;
    BpKeepAwake::apply('active', $dir, {
        spawn                => sub { die "fork refused\n" },
        powershell_available => sub { 1 },
        log                  => sub { push @logged, $_[0] },
    });
    is(scalar @logged, 1, 'a failed spawn logs exactly one warning');
    like($logged[0], qr/fork refused/, 'the warning carries the cause');
}

# ------------------------------------------------- ONE definition, shared ----
{
    my $ka   = do { open my $f,'<',"$S/bp-keepawake.pl" or die; local $/; <$f> };
    my $solo = do { open my $f,'<',"$S/bp-drive-next.pl" or die; local $/; <$f> };
    my $fleet= do { open my $f,'<',"$S/bp-orchestrator.pl" or die; local $/; <$f> };

    like($ka, qr/sub\s+spawn\b/,       'bp-keepawake.pl defines the actuation');
    like($solo,  qr/require\s+"\$DIR\/bp-keepawake\.pl"/, 'solo requires the shared wake-lock');
    like($fleet, qr/require\s+"\$DIR\/bp-keepawake\.pl"/, 'the FLEET requires the shared wake-lock');

    # The drift guard. Neither driver may re-grow its own copy of the actuation
    # — that is the failure mode this extraction exists to prevent, and it is
    # how the token floor ended up with three declarations.
    unlike($solo,  qr/exec\(\s*'powershell\.exe'/,
        'solo does NOT carry its own copy of the powershell actuation');
    unlike($fleet, qr/exec\(\s*'powershell\.exe'/,
        'the fleet does NOT carry its own copy of the powershell actuation');

    # The fleet must both TAKE and RELEASE the lock. A driver that only takes it
    # leaves the machine awake forever after it exits.
    like($fleet, qr/BpKeepAwake::apply\(\s*\$ka_phase/,
        'the fleet applies the lock each tick, phase-driven');
    like($fleet, qr/BpKeepAwake::apply\(\s*'settled'/,
        'the fleet releases the lock on exit — including the error path');

    # A manual pause is waiting on an absent human; holding the machine awake
    # for them is cost without benefit.
    like($fleet, qr/\$paused->\{manual\}\s*\?\s*'settled'/,
        'a MANUAL fleet pause releases the lock; a timed one keeps it');
}

# ---- THE LEAK: the recorded pid must be valid to OTHER processes -------------
#
# Measured 2026-08-13: 52 orphaned keep-awake PowerShells, ~52 MB each, holding
# 2.7 GB and 52 simultaneous ES_CONTINUOUS wake-locks on the operator's host,
# very plausibly the difference that tipped Windows into the low-virtual-memory
# condition that killed the podman VM and both of their sandboxes.
#
# CAUSE: spawn() wrote perl's fork() return value into keepawake.pid. On
# Git-for-Windows perl fork is EMULATED and returns a PSEUDO-pid (e.g. 447298)
# meaningful only inside the process that forked. Every `bp-drive-next.pl next`
# is a fresh process, so its kill(0,$pid) always failed, the idempotency check
# never fired, and each invocation spawned another lock it could never release.
#
# The fix hands keep-awake.ps1 -PidFile so the HELPER records its own real
# Windows pid. These assertions pin that, because the symptom is invisible in a
# single process: a pseudo-pid validates fine inside the process that made it,
# which is exactly why this survived.
{
    my $src = do { open my $f,'<',"$S/bp-keepawake.pl" or die; local $/; <$f> };

    like($src, qr/-PidFile/,
        'spawn hands keep-awake.ps1 -PidFile so the HELPER records a real Windows pid');
    unlike($src, qr/print\s+\$w\s+"\$pid/,
        'spawn does NOT write perl\'s fork pid — that pseudo-pid is the leak');
    like($src, qr/winify_out/,
        'the -PidFile path is winified for a not-yet-existing file (a bare /c/... would be created at the drive root)');

    # winify_out must not hand a native binary a POSIX path. CLAUDE.md records
    # 576 drive-root strays from exactly that.
    my $dir  = tempdir(CLEANUP => 1);
    my $out  = BpKeepAwake::winify_out("$dir/keepawake.pid");
    unlike($out, qr{^/},      'winify_out never yields a leading-slash POSIX path');
    like($out,   qr{^[A-Za-z]:/}, 'winify_out yields a drive-letter path even though the file does not exist');
    like($out,   qr{/keepawake\.pid$}, '...and preserves the basename');

    # Behavioural: a pid file holding a pid from ANOTHER process must be
    # honoured. $$ is this test's pid — a real OS pid, not a pseudo one — so a
    # correct implementation treats the lock as live and does not respawn.
    my $d2 = tempdir(CLEANUP => 1);
    open my $w, '>', "$d2/keepawake.pid" or die; print $w "$$\n"; close $w;
    my @spawned;
    BpKeepAwake::apply('active', $d2, {
        spawn                => sub { push @spawned, 1 },
        powershell_available => sub { 1 },
    });
    is(scalar @spawned, 0,
       'a pid file holding a REAL, cross-process-valid pid suppresses the respawn');
}

done_testing();
