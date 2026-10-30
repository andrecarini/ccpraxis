#!/usr/bin/env perl
# platform: host
# t/111 — the wake-lock is ONE definition, and the FLEET
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
#
# MACOS (bottom of the file): the same apply() contract with `caffeinate -i`
# held by this file's own `hold` command. Every holder started here runs a
# FAKE caffeinate (CCPRAXIS_CAFFEINATE_BIN) that asserts nothing, and the
# holder refuses to start a real one under CCPRAXIS_NO_WAKELOCK.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();

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
    SKIP: {
        # Only an MSYS path has a drive-letter form to translate to; on macOS
        # and Linux there is no powershell.exe to hand it and a temp dir is
        # legitimately "/...".
        skip 'winify_out maps MSYS paths to drive letters; only a Windows host has them', 2
            unless $^O =~ /^(MSWin32|msys|cygwin)$/;
        unlike($out, qr{^/},      'winify_out never yields a leading-slash POSIX path');
        like($out,   qr{^[A-Za-z]:/}, 'winify_out yields a drive-letter path even though the file does not exist');
    }
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

# ---- a host that cannot hold a lock says so ONCE ------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my @logged;
    my %o = (spawn => sub { 1 }, powershell_available => sub { 0 }, log => sub { push @logged, $_[0] });
    BpKeepAwake::apply('active', $dir, {%o}) for 1 .. 3;
    if ($^O =~ /^(MSWin32|msys|cygwin)$/ || $^O eq 'darwin') {
        is(scalar @logged, 1, 'no helper on a host: one warning across three director ticks, not three');
        like($logged[0] // '', qr/WARN keepawake unsupported here/, '...naming the gap');
    } else {
        is(scalar @logged, 0, 'no helper in the Linux sandbox: silent (keep-awake is a documented no-op there)');
        pass('(no warning to inspect)');
    }
    ok(!-e "$dir/keepawake.pid", 'no helper: still no pid file');
}

# ---- macOS: the release path checks identity before signalling ----------------
{
    my @signalled;
    my $r = BpKeepAwake::stop_holder_darwin(424242,
        command_of => sub { '/usr/bin/vim notes.txt' }, pid_f => '/x/keepawake.pid');
    is($r, 'not-ours', 'macOS release: a reused pid running something else is not signalled');
    $r = BpKeepAwake::stop_holder_darwin(424242, command_of => sub { undef });
    is($r, 'gone', 'macOS release: a pid that no longer exists is simply gone');
    $r = BpKeepAwake::stop_holder_darwin(424242,
        command_of => sub { "/usr/bin/perl /p/bp-keepawake.pl hold --pid-file /other/keepawake.pid" },
        pid_f => '/x/keepawake.pid');
    is($r, 'not-ours', 'macOS release: a holder for ANOTHER pid file is not ours to stop');
}

# ---- macOS: the holder itself, against a fake caffeinate ----------------------
SKIP: {
    skip 'the caffeinate holder runs on macOS (exercised wherever POSIX ps/fork exist)', 12
        if $^O =~ /^(MSWin32|msys|cygwin)$/;
    my $dir  = tempdir(CLEANUP => 1);
    my $fake = "$dir/fake-caffeinate";
    my $args = "$dir/caffeinate.args";
    open my $f, '>', $fake or die $!;
    print {$f} "#!/bin/sh\nprintf '%s\\n' \"\$@\" > '$args'\nexec sleep 300\n";
    close $f;
    chmod 0755, $fake;
    local $ENV{CCPRAXIS_CAFFEINATE_BIN} = $fake;

    my $slurp = sub { open my $h, '<', $_[0] or return ''; local $/; my $x = <$h>; close $h; $x // '' };
    my $wait_for = sub {
        my ($cond, $secs) = @_;
        my $end = Time::HiRes::time() + $secs;
        while (Time::HiRes::time() < $end) { return 1 if $cond->(); Time::HiRes::sleep(0.05) }
        return $cond->() ? 1 : 0;
    };
    my $start = sub {
        my ($pid_f, @extra) = @_;
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            exec($^X, "$S/bp-keepawake.pl", 'hold', '--pid-file', $pid_f,
                 '--log-file', "$dir/keepawake.log", '--poll', '0.1', @extra) or exit 127;
        }
        return $pid;
    };

    # (a) lease expiry: nobody refreshes the pid file, so the hold lets go.
    my $pid_f = "$dir/keepawake.pid";
    my $h = $start->($pid_f, '--lease', '2');
    ok($wait_for->(sub { $slurp->("$dir/keepawake.log") =~ /pid=$h ASSERTED/ }, 5),
        'holder: logs ASSERTED once caffeinate is up (what replace() waits for)');
    is($slurp->($pid_f), "$h\n", 'holder: writes ITS OWN pid into the pid file, as keep-awake.ps1 does');
    is($slurp->($args), "-i\n-w\n$h\n", 'holder: runs caffeinate -i -w <holder pid>, so the assertion dies with it');
    ok($wait_for->(sub { waitpid($h, 1) == $h }, 8), 'holder: exits once the lease goes stale');
    ok(!-e $pid_f, 'holder: removes the pid file it owned');
    like($slurp->("$dir/keepawake.log"), qr/RELEASE reason=lease-expired/, 'holder: says why it let go');

    # (b) the director's release path: identity check, TERM, clean exit.
    my $h2 = $start->($pid_f, '--lease', '600');
    ok($wait_for->(sub { $slurp->($pid_f) eq "$h2\n" }, 5), 'holder 2: up');
    my @logged;
    BpKeepAwake::apply('settled', $dir, { log => sub { push @logged, $_[0] } });
    ok($wait_for->(sub { waitpid($h2, 1) == $h2 }, 8), 'release: apply(settled) stops the holder');
    ok(!-e $pid_f, 'release: the pid file is gone');
    like(join("\n", @logged), qr/keepawake stop winpid=$h2 result=gone/, 'release: logged as a clean stop');
    like($slurp->("$dir/keepawake.log"), qr/pid=$h2 RELEASE reason=signal-term/, 'release: the holder released on TERM');

    # (c) never a real caffeinate from a test environment.
    local $ENV{CCPRAXIS_CAFFEINATE_BIN};
    delete $ENV{CCPRAXIS_CAFFEINATE_BIN};
    my $rc = system($^X, "$S/bp-keepawake.pl", 'hold', '--pid-file', "$dir/never.pid") >> 8;
    is($rc, 3, 'holder: refuses the real caffeinate under CCPRAXIS_NO_WAKELOCK');
}

done_testing();
