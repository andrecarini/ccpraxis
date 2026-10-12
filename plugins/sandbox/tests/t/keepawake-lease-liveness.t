#!/usr/bin/env perl
# platform: windows
#
# 02-lease-distinguishes-quiet-from-gone (host-wake-and-suspend blueprint).
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/02-lease-distinguishes-quiet-from-gone-spec.md
# (11 ACs) plus Decision 15 (blueprint.md), which folds the pre-existing
# -LeaseSeconds 0 clamp defect into this package's scope: 0 must mean "hold
# until killed or until the owner is gone", never a silent 60s clamp. NOT
# derived from keep-awake.ps1's implementation -- at the time this file is
# written the script has no -OwnerWinPid parameter at all, so every
# integration assertion below is expected to fail for that reason (missing
# behavior), not a scaffolding bug.
#
# Every process this file starts is a REAL Windows process: a throwaway
# "owner" powershell.exe that writes its own $PID (already a WINPID -- a
# native process, not something Perl's fork/open touched) to a file and
# sleeps, and the real keep-awake.ps1 spawned as a real child. Every WINPID
# is registered in @LIVE_WINPIDS the moment it is known; the END block
# force-kills whatever is still alive there regardless of pass/fail, on top
# of per-test backstops -- the same discipline execution-power-request.t
# uses, and for the same reason (CLAUDE.md's MSYS-pid/WINPID landmine: a pid
# is only meaningful in the namespace that produced it, so liveness is
# always checked by WINPID via `tasklist`, never by Perl's own pid).
#
# This file never touches the operator's real wake-lock state: every helper
# and owner gets its own File::Temp tempdir (-PidFile/-LogFile inside it,
# CLEANUP => 1), its own -PollSeconds/-LeaseSeconds, and nothing here calls
# bp-keepawake.pl, BpContinuityLease.pm or launcher.pl (the actuators
# test-wakelock-hygiene.t polices) -- it drives keep-awake.ps1 directly, the
# same shape execution-power-request.t already uses for the same script.
# CCPRAXIS_NO_WAKELOCK is never read or written here.
#
# Several groups below run CONCURRENTLY (their own helper, owner, tempdir
# and assertions each -- DC4/AC-* "each case uses its OWN ... ", never a
# combined scenario) to bound total wall time, matching the spec's explicit
# allowance ("may run their helpers concurrently to bound wall time").
#
# Decision 16 (2026-09-26, review 02-review.md) revises the plain Decision
# 15 reading of -LeaseSeconds 0: it is "hold until killed or until the owner
# is gone" ONLY when there is a verifiable owner. Without one (no
# -OwnerWinPid, or an owner that cannot be pinned), 0 falls back to the
# pre-02 60s lease, logged as such -- LS0-a/LS0-a2 below assert the
# fallback; LS0-c asserts the positive case (verified owner, held past 60s,
# released only on owner-gone). Decision 16 also wires launcher.pl's own
# keep-awake exec to pass -OwnerWinPid (checked statically below, read-only:
# launcher.pl is not in this package's write set), and adds the S4 cleanup
# discipline right below (an END block plus SIGINT/SIGTERM handlers, keyed
# on the pid files this test itself created, so a hard-killed run cannot
# leave any of ITS OWN helpers/owners holding the machine -- and, by
# construction, never touches a keep-awake process this test did not
# start).

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use Time::HiRes qw(sleep time);
use FindBin qw($Bin);

my $SCRIPT = "$Bin/../../scripts/keep-awake.ps1";

# File::Temp's ambient tmpdir() resolution (File::Spec->tmpdir(), driven by
# $ENV{TMPDIR}/$ENV{TMP}) has been observed on this host to intermittently
# resolve to a bare "/tmp" fallback instead of the real
# C:/Users/.../AppData/Local/Temp -- reproducibly, on some but not all calls
# within the SAME process. A tempdir under "/tmp" handed to a native
# powershell.exe is resolved against the current drive root as
# "C:\tmp\...", which does not exist, and every Set-Content/-PidFile/-LogFile
# write into it fails outright (DirectoryNotFoundException) -- a scaffolding
# failure, not a missing-behavior one. Passing an explicit, already-Windows-
# style DIR (Get's $ENV{TEMP}, which Windows always sets) makes every
# tempdir()/tempfile() call in this file deterministic instead of ambient.
my $WIN_TMP = $ENV{TEMP} || $ENV{TMP} || 'C:/Windows/Temp';

# ---------------------------------------------------------------------------
# static/structural checks (AC8, AC9) -- unconditional, no SKIP.
# ---------------------------------------------------------------------------

my $src;
{
    local $/;
    open(my $fh, '<:raw', $SCRIPT) or BAIL_OUT("cannot read $SCRIPT: $!");
    $src = <$fh>;
    close $fh;
}

ok(defined($src) && length($src) > 0, 'keep-awake.ps1 is readable and non-empty');

# AC8 [static]: param() declares [int]$OwnerWinPid = 0; the new literal
# tokens are present; the pre-existing tokens this package must not disturb
# are still present too.
like($src, qr/\[int\]\s*\$OwnerWinPid\s*=\s*0/,
    'AC8: param() declares [int]$OwnerWinPid = 0');

for my $token (qw(HOLD-QUIET OWNER-UNVERIFIABLE), 'reason=owner-gone') {
    like($src, qr/\Q$token\E/, "AC8: literal token '$token' present in source");
}

for my $token (qw(reason=lease-expired reason=pidfile-gone SUSPEND-DETECTED GRACE)) {
    like($src, qr/\Q$token\E/, "AC8: pre-existing token '$token' still present");
}

# AC9 [static]: ASCII-only; exactly one Add-Type call site (package 01's
# AC8 must keep passing); the owner probe path spawns no process.
{
    my $has_non_ascii = ($src =~ /[^\x00-\x7f]/) ? 1 : 0;
    ok(!$has_non_ascii, 'AC9: file contains no byte outside \\x00-\\x7f (BOM-less ASCII)');
}

my @addtype_hits = ($src =~ /\bAdd-Type\b/g);
is(scalar(@addtype_hits), 1, 'AC9: exactly one Add-Type call site in the file (package 01 regression)');

for my $forbidden (qw(tasklist), 'Get-CimInstance', 'Get-WmiObject', 'Start-Process') {
    unlike($src, qr/\Q$forbidden\E/,
        "AC9: the owner probe path spawns no process -- '$forbidden' does not appear anywhere in the file");
}

# ---------------------------------------------------------------------------
# AC-W1 [static, DC2]: the pin-time/probe-time identity-anchor seam exists.
# Derived ONLY from specs/05-keepawake-liveness-winpid-race-spec.md section
# 2 -- not from reading any implementation, since at the time this file is
# written keep-awake.ps1 has none of this: no -OwnerStartTicks param, no
# -SimulateOwnerStartTicksFile param, no Get-KaOwnerStartTicks function, and
# neither new log token. Every assertion below is expected to fail for that
# reason (missing behavior).
# ---------------------------------------------------------------------------
like($src, qr/\[long\]\s*\$OwnerStartTicks\s*=\s*0/,
    'AC-W1: param() declares [long]$OwnerStartTicks = 0');
like($src, qr/\[string\]\s*\$SimulateOwnerStartTicksFile/,
    'AC-W1: param() declares [string]$SimulateOwnerStartTicksFile');
like($src, qr/function\s+Get-KaOwnerStartTicks/,
    'AC-W1: Get-KaOwnerStartTicks is defined as its own function');
like($src, qr/reason=start-time-mismatch/,
    'AC-W1: literal token "reason=start-time-mismatch" present in source');
like($src, qr/OWNER-REPLACED/,
    'AC-W1: literal token "OWNER-REPLACED" present in source');

{
    my ($get_owner_state_body) = ($src =~ /function Get-OwnerState\s*\{(.*?)\n\}\n/s);
    SKIP: {
        skip 'AC-W1: no Get-OwnerState function found to isolate (missing behavior)', 1
            unless defined $get_owner_state_body;
        like($get_owner_state_body, qr/Get-KaOwnerStartTicks/,
            'AC-W1: Get-OwnerState\'s own body calls Get-KaOwnerStartTicks (probe-time re-check)');
    }
}

{
    my ($pin_block_body) = ($src =~ /if\s*\(\s*\$OwnerWinPid\s*-gt\s*0\s*\)\s*\{(.*?)function Get-OwnerState/s);
    SKIP: {
        skip 'AC-W1: could not isolate the text between "if ($OwnerWinPid -gt 0) {" and Get-OwnerState (missing behavior)', 1
            unless defined $pin_block_body;
        like($pin_block_body, qr/Get-KaOwnerStartTicks/,
            'AC-W1: the pin block (between "if ($OwnerWinPid -gt 0) {" and Get-OwnerState) calls Get-KaOwnerStartTicks');
    }
}

# ---------------------------------------------------------------------------
# Decision 16 (c): launcher.pl's own keep-awake exec must pass -OwnerWinPid,
# sourced from /proc/<pid>/winpid in the PARENT before it forks, and never
# from the bare MSYS pid ($$). Static/source-level only -- this file's write
# set is keep-awake.ps1 + this test, so launcher.pl itself is read-only here,
# never edited or driven as a subprocess (that would collide with
# test-wakelock-hygiene.t's actuator sweep and this file's own no-real-
# wake-lock discipline stated in the header above).
# ---------------------------------------------------------------------------
{
    my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
    my $lsrc;
    if (open(my $lfh, '<:raw', $LAUNCHER)) {
        local $/;
        $lsrc = <$lfh>;
        close $lfh;
    }

    SKIP: {
        skip 'Decision 16(c): launcher.pl not found -- cannot check its keep-awake wiring', 4
            unless defined $lsrc;

        # Isolate the keep-awake start routine's own body (up to the next
        # top-level `sub `), so the "before fork()" ordering check below is
        # anchored to the right function rather than the whole 9000-line file.
        my ($start_sub_body) = ($lsrc =~ /sub\s+_keepawake_start\s*\{(.*?)\n\}\n/s);

        SKIP: {
            skip 'Decision 16(c): no _keepawake_start subroutine found in launcher.pl -- the wiring this '
               . 'decision requires may live under a different name/shape', 4
                unless defined $start_sub_body;

            like($start_sub_body, qr/-OwnerWinPid/,
                "Decision 16(c): launcher.pl's keep-awake exec passes -OwnerWinPid");

            # The value must be sourced from /proc/<pid>/winpid, not a bare $$.
            # Written loosely (no fixed variable name) since this is derived
            # from the decision's plain-English requirement, not from reading
            # the implementer's exact code.
            like($lsrc, qr{/proc/\$\$/winpid},
                'Decision 16(c): launcher.pl reads the owner WINPID via /proc/$$/winpid '
              . '(the cygwin/MSYS native-pid seam), not by any other means');

            # Ordering: the /proc/.../winpid read must happen textually BEFORE
            # fork() is called inside _keepawake_start's own body -- "read in
            # the parent... before forking".
            my $proc_read_pos = ($start_sub_body =~ /\/proc\/\$\$\/winpid|_keepawake_owner_winpid\s*\(/) ? $-[0] : undef;
            my $fork_pos      = ($start_sub_body =~ /\bfork\s*\(/) ? $-[0] : undef;
            ok(defined($proc_read_pos) && defined($fork_pos) && $proc_read_pos < $fork_pos,
                'Decision 16(c): the owner WINPID is read before fork() is called, i.e. in the PARENT, '
              . 'never re-derived in the child after forking')
                or diag(sprintf('proc_read_pos=%s fork_pos=%s',
                    defined($proc_read_pos) ? $proc_read_pos : 'undef',
                    defined($fork_pos)      ? $fork_pos      : 'undef'));

            # The value handed to -OwnerWinPid must never be the bare MSYS pid
            # ($$) itself -- forbid the exact shape of passing it directly as
            # that flag's argument (list form or an interpolated command
            # string), which is precisely the CLAUDE.md MSYS-pid/WINPID
            # landmine this decision exists to avoid.
            unlike($start_sub_body, qr/-OwnerWinPid['"]?\s*,\s*\$\$\b/,
                'Decision 16(c): -OwnerWinPid is never handed the bare MSYS pid ($$) directly');
        }
    }
}

# ---------------------------------------------------------------------------
# integration: spawn the real script (and real owner processes) as real
# child processes.
# ---------------------------------------------------------------------------

my @LIVE_WINPIDS;   # every winpid we have EVER spawned in this run (owners
                     # AND helpers); the END block force-kills whatever is
                     # still alive there, pass or fail.

# S4 (redteam-01.md / review 02-review.md): a KILLED run must still leave no
# helper or owner holding the machine awake. @LIVE_WINPIDS alone only helps
# on a normal exit, because a raw SIGTERM/SIGINT's default action skips
# every END block. Cleanup here is keyed on the PID FILES THIS TEST ITSELF
# CREATED (spawn_owner's owner.pid, spawn_keepawake's -PidFile) -- never a
# blind sweep of "every keep-awake.ps1 on the box" -- so a killed run can
# never touch a keep-awake process this test did not start.
my @LIVE_PIDFILES;

sub _winpid_from_pidfile_now {
    my ($file) = @_;
    return undef unless defined $file && -e $file;
    open(my $fh, '<', $file) or return undef;
    my $content = <$fh>;
    close $fh;
    return undef unless defined $content;
    $content =~ s/\s+//g;
    return ($content =~ /^\d+$/) ? $content : undef;
}

sub _cleanup_everything_this_test_started {
    # Every winpid we ever confirmed directly (covers processes whose own
    # pid file may since have been deleted as part of a deliberate-release
    # assertion).
    for my $winpid (@LIVE_WINPIDS) {
        next unless defined $winpid && $winpid =~ /^\d+$/;
        force_kill_if_alive($winpid);
    }
    # Belt-and-suspenders re-read of every pid file THIS TEST wrote, in case
    # a helper/owner's winpid was never captured into @LIVE_WINPIDS (e.g. a
    # kill landed between spawn and the confirming read).
    for my $file (@LIVE_PIDFILES) {
        my $winpid = _winpid_from_pidfile_now($file);
        force_kill_if_alive($winpid) if defined $winpid;
    }
    return;
}

END {
    _cleanup_everything_this_test_started();
}

for my $sig (qw(INT TERM)) {
    $SIG{$sig} = sub {
        _cleanup_everything_this_test_started();
        exit(1);
    };
}

sub tasklist_shows_alive {
    my ($winpid) = @_;
    return 0 unless defined $winpid && $winpid =~ /^\d+$/;
    # MSYS2_ARG_CONV_EXCL local to this one call -- without it, Git-for-Windows
    # mangles the bare /FI flag (CLAUDE.md's documented landmine), so
    # `tasklist` errors on every invocation and every live pid reads absent.
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $out = `tasklist /FI "PID eq $winpid" 2>&1`;
    return 0 unless defined $out;
    return ($out =~ /\b\Q$winpid\E\b/) ? 1 : 0;
}

sub force_kill_if_alive {
    my ($winpid) = @_;
    return unless defined $winpid && $winpid =~ /^\d+$/;
    return unless tasklist_shows_alive($winpid);
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    system('taskkill', '/F', '/PID', $winpid);
    return;
}

sub wait_for_file_numeric {
    my ($file, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        if (-e $file) {
            open(my $fh, '<', $file) or goto SLEEP;
            my $content = <$fh>;
            close $fh;
            if (defined $content) {
                $content =~ s/\s+//g;
                return $content if $content =~ /^\d+$/;
            }
        }
      SLEEP:
        sleep(0.25);
    }
    return undef;
}

sub slurp_log {
    my ($logfile) = @_;
    return '' unless -e $logfile;
    local $/;
    open(my $fh, '<', $logfile) or return '';
    my $content = <$fh>;
    close $fh;
    return defined($content) ? $content : '';
}

sub wait_for_log_event {
    my ($logfile, $regex, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        my $content = slurp_log($logfile);
        return 1 if $content =~ $regex;
        sleep(0.25);
    }
    return 0;
}

# spawn_owner() -- a REAL, throwaway powershell.exe that writes its OWN
# $PID (a genuine WINPID, since powershell.exe is a native process; there
# is no MSYS layer between it and the OS) to a file, then sleeps for up to
# 10 minutes so the test controls its lifetime entirely via taskkill.
sub spawn_owner {
    my $dir       = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    my $file      = "$dir/owner.pid";
    my $startfile = "$dir/owner.start";   # AC-W2/W3/W4: the owner's own
                                           # StartTime.ToFileTimeUtc(), written
                                           # BEFORE the pid file, so by the
                                           # time owner.pid is readable the
                                           # start ticks are already there.
    my @cmd = (
        'powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-Command',
        "Set-Content -LiteralPath '$startfile' -Value ([System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()) -Encoding ascii; "
      . "Set-Content -LiteralPath '$file' -Value \$PID -Encoding ascii; Start-Sleep -Seconds 600",
    );
    push @LIVE_PIDFILES, $file;   # S4: known before the process even exists.
    open(my $fh, '-|', @cmd) or die "spawn owner failed: $!";
    # 30s, not 15s: several owners are spawned back-to-back/concurrently in
    # the groups below, and process-creation contention under that load has
    # been observed to push a single powershell.exe startup past 15s on this
    # host (CLAUDE.md: process creation, not CPU, dominates cost here).
    my $winpid = wait_for_file_numeric($file, 30);
    push @LIVE_WINPIDS, $winpid if defined $winpid;
    my $start_ticks = wait_for_file_numeric($startfile, 5);
    return ($winpid, $fh, $dir, $start_ticks);
}

# spawn_keepawake(%opts) -> ($logfile, $pidfile, $fh, $dir)
sub spawn_keepawake {
    my (%opts) = @_;

    my $dir     = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    my $pidfile = "$dir/keepawake.pid";
    my $logfile = "$dir/keepawake.log";

    my @cmd = (
        'powershell.exe', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File', $SCRIPT,
        '-PidFile', $pidfile, '-LogFile', $logfile,
        '-PollSeconds', $opts{poll} // 5,
        '-LeaseSeconds', defined($opts{lease}) ? $opts{lease} : 60,
    );
    push @cmd, '-OwnerWinPid', $opts{owner_winpid} if defined $opts{owner_winpid};
    push @cmd, '-OwnerStartTicks', $opts{owner_start_ticks} if defined $opts{owner_start_ticks};
    push @cmd, '-SimulateOwnerStartTicksFile', $opts{sim_ticks_file} if defined $opts{sim_ticks_file};

    push @LIVE_PIDFILES, $pidfile;   # S4: known before the process even exists.
    open(my $fh, '-|', @cmd) or die "spawn keep-awake failed: $!";

    return ($logfile, $pidfile, $fh, $dir);
}

sub wait_gone_bounded {
    my ($winpid, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if !defined($winpid) || !tasklist_shows_alive($winpid);
        sleep(0.25);
    }
    return 0;
}

SKIP: {
    my $n_integration_tests = 65;
    skip 'keep-awake.ps1 spawn tests are Windows-only', $n_integration_tests
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    skip "keep-awake.ps1 not found at $SCRIPT", $n_integration_tests
        unless -f $SCRIPT;

    my $t_suite_start = time();

    # -----------------------------------------------------------------
    # Spawn every group's owner(s) up front, so the groups genuinely
    # overlap in wall time rather than running back-to-back.
    # -----------------------------------------------------------------

    # AC1/AC2/AC7-carrier group: a quiet, live owner that stays alive and
    # untouched throughout.
    my ($owner1_winpid, $owner1_fh, $owner1_dir, $owner1_start) = spawn_owner();
    ok(defined($owner1_winpid), 'AC1 setup: owner process started with a real WINPID');

    # AC3 group: an owner killed ~10s after its helper starts.
    my ($owner3_winpid, $owner3_fh, $owner3_dir) = spawn_owner();
    ok(defined($owner3_winpid), 'AC3 setup: owner process started with a real WINPID');

    # AC4 group: an owner killed the instant its helper's first HOLD-QUIET
    # line appears.
    my ($owner4_winpid, $owner4_fh, $owner4_dir) = spawn_owner();
    ok(defined($owner4_winpid), 'AC4 setup: owner process started with a real WINPID');

    # AC6 group: an owner started, recorded, then killed BEFORE its helper
    # is even spawned -- "orphan, owner already gone at start".
    my ($owner6_winpid, $owner6_fh, $owner6_dir, $owner6_start) = spawn_owner();
    ok(defined($owner6_winpid), 'AC6 setup: owner process started with a real WINPID');
    force_kill_if_alive($owner6_winpid);
    ok(wait_gone_bounded($owner6_winpid, 15), 'AC6 setup: owner is confirmed gone before its helper is spawned');

    # LS0-b group (Decision 15): -LeaseSeconds 0 with a live owner, killed
    # ~10s after its helper starts.
    my ($ownerL_winpid, $ownerL_fh, $ownerL_dir) = spawn_owner();
    ok(defined($ownerL_winpid), 'LS0-b setup: owner process started with a real WINPID');

    # LS0-a2 group (Decision 16, review S2/S3): -LeaseSeconds 0 with an
    # UNVERIFIABLE owner (already gone before the helper even starts) --
    # must fall back the same way as LS0-a (no -OwnerWinPid at all), never
    # to an unconditional hold.
    my ($ownerA2_winpid, $ownerA2_fh, $ownerA2_dir, $ownerA2_start) = spawn_owner();
    ok(defined($ownerA2_winpid), 'LS0-a2 setup: owner process started with a real WINPID');
    force_kill_if_alive($ownerA2_winpid);
    ok(wait_gone_bounded($ownerA2_winpid, 15), 'LS0-a2 setup: owner is confirmed gone before its helper is spawned');

    # LS0-c group (Decision 16 (b)): -LeaseSeconds 0 with a VERIFIED, live
    # owner that survives well past the legacy 60s clamp before being
    # killed -- proves the hold is not time-bounded while the owner lives,
    # and that owner-gone still ends it once the owner actually exits.
    my ($ownerC_winpid, $ownerC_fh, $ownerC_dir) = spawn_owner();
    ok(defined($ownerC_winpid), 'LS0-c setup: owner process started with a real WINPID');

    # -----------------------------------------------------------------
    # Spawn every group's helper, now that owner identities are known.
    # Each group gets its OWN helper/tempdir per DC4.
    # -----------------------------------------------------------------

    # AC-W2 (DC1, DC3): anchored with owner1's OWN correct start ticks --
    # a regression guard proving the new strictness never rejects a real,
    # correctly-anchored owner.
    my ($log1, $pid1, $fh1, $dir1) = spawn_keepawake(owner_winpid => $owner1_winpid, owner_start_ticks => $owner1_start);
    my $t1_0 = time();
    my $winpid1 = wait_for_file_numeric($pid1, 15);
    push @LIVE_WINPIDS, $winpid1 if defined $winpid1;
    ok(defined($winpid1), 'AC1: helper pidfile appears with a numeric WINPID')
        or diag("log so far:\n" . slurp_log($log1));

    my ($log3, $pid3, $fh3, $dir3) = spawn_keepawake(owner_winpid => $owner3_winpid);
    my $t3_0 = time();
    my $winpid3 = wait_for_file_numeric($pid3, 15);
    push @LIVE_WINPIDS, $winpid3 if defined $winpid3;
    ok(defined($winpid3), 'AC3: helper pidfile appears with a numeric WINPID')
        or diag("log so far:\n" . slurp_log($log3));

    my ($log4, $pid4, $fh4, $dir4) = spawn_keepawake(owner_winpid => $owner4_winpid);
    my $winpid4 = wait_for_file_numeric($pid4, 15);
    push @LIVE_WINPIDS, $winpid4 if defined $winpid4;
    ok(defined($winpid4), 'AC4: helper pidfile appears with a numeric WINPID')
        or diag("log so far:\n" . slurp_log($log4));

    my ($log5, $pid5, $fh5, $dir5) = spawn_keepawake();   # AC5: no -OwnerWinPid at all (orphan)
    my $t5_0 = time();
    my $winpid5 = wait_for_file_numeric($pid5, 15);
    push @LIVE_WINPIDS, $winpid5 if defined $winpid5;
    ok(defined($winpid5), 'AC5: helper pidfile appears with a numeric WINPID (no -OwnerWinPid)')
        or diag("log so far:\n" . slurp_log($log5));

    # AC-W4 (DC2): anchored with owner6's own (pre-kill) start ticks.
    my ($log6, $pid6, $fh6, $dir6) = spawn_keepawake(owner_winpid => $owner6_winpid, owner_start_ticks => $owner6_start);
    my $t6_0 = time();
    my $winpid6 = wait_for_file_numeric($pid6, 15);
    push @LIVE_WINPIDS, $winpid6 if defined $winpid6;
    ok(defined($winpid6), 'AC6: helper pidfile appears with a numeric WINPID (owner already gone)')
        or diag("log so far:\n" . slurp_log($log6));

    my ($logA, $pidA, $fhA, $dirA) = spawn_keepawake(lease => 0);   # LS0-a: lease 0, no owner
    my $tA_0 = time();
    my $winpidA = wait_for_file_numeric($pidA, 15);
    push @LIVE_WINPIDS, $winpidA if defined $winpidA;
    ok(defined($winpidA), 'LS0-a: helper pidfile appears with a numeric WINPID (-LeaseSeconds 0, no owner)')
        or diag("log so far:\n" . slurp_log($logA));

    my ($logL, $pidL, $fhL, $dirL) = spawn_keepawake(lease => 0, owner_winpid => $ownerL_winpid);
    my $tL_0 = time();
    my $winpidL = wait_for_file_numeric($pidL, 15);
    push @LIVE_WINPIDS, $winpidL if defined $winpidL;
    ok(defined($winpidL), 'LS0-b: helper pidfile appears with a numeric WINPID (-LeaseSeconds 0, live owner)')
        or diag("log so far:\n" . slurp_log($logL));

    # AC-W3 (DC1): LS0-a2 is anchored with ownerA2's OWN start ticks (read
    # while it was still alive, before the kill above). If those ticks were
    # never confirmed, refuse to spawn an UNANCHORED LS0-a2 helper (spec:
    # "rather than spawning without the anchor") -- its dependent assertions
    # SKIP below instead.
    my ($logA2, $pidA2, $fhA2, $dirA2, $tA2_0, $winpidA2);
    SKIP: {
        skip 'LS0-a2: owner A2 start ticks were never confirmed (spawn contention) -- '
           . 'refusing to spawn an unanchored LS0-a2 helper', 1
            unless defined $ownerA2_start;

        ($logA2, $pidA2, $fhA2, $dirA2) = spawn_keepawake(
            lease => 0, owner_winpid => $ownerA2_winpid, owner_start_ticks => $ownerA2_start);
        $tA2_0 = time();
        $winpidA2 = wait_for_file_numeric($pidA2, 15);
        push @LIVE_WINPIDS, $winpidA2 if defined $winpidA2;
        ok(defined($winpidA2), 'LS0-a2: helper pidfile appears with a numeric WINPID (-LeaseSeconds 0, unverifiable owner, anchored)')
            or diag("log so far:\n" . slurp_log($logA2));
    }

    my ($logC, $pidC, $fhC, $dirC) = spawn_keepawake(lease => 0, owner_winpid => $ownerC_winpid);
    my $tC_0 = time();
    my $winpidC = wait_for_file_numeric($pidC, 15);
    push @LIVE_WINPIDS, $winpidC if defined $winpidC;
    ok(defined($winpidC), 'LS0-c: helper pidfile appears with a numeric WINPID (-LeaseSeconds 0, verified live owner)')
        or diag("log so far:\n" . slurp_log($logC));

    # -----------------------------------------------------------------
    # Scheduled actions and the shared poll loop. Every deadline below is
    # bounded; the loop itself is bounded to 90s of wall time from the
    # first helper's pidfile appearance.
    # -----------------------------------------------------------------

    my $owner3_killed = 0;
    my $ownerL_killed = 0;
    my $ac4_hold_quiet_seen_at;
    my $owner4_killed = 0;

    # LS0-c (b): the owner must be seen surviving PAST the legacy 60s clamp
    # BEFORE it is killed -- otherwise this group would look identical to
    # LS0-b and would not prove "holds past 60s". Snapshot at >=65s, then
    # kill; both the snapshot and the kill happen at most once.
    my $ownerC_confirmed_past_60 = 0;
    my $ownerC_killed = 0;
    my $ownerC_log_snapshot;   # captured at the moment of confirmation, BEFORE the kill

    my $shared_deadline = time() + 130;
    while (time() < $shared_deadline) {
        my $now = time();

        if (!$owner3_killed && defined($t3_0) && ($now - $t3_0) >= 10) {
            force_kill_if_alive($owner3_winpid);
            $owner3_killed = 1;
        }
        if (!$ownerL_killed && defined($tL_0) && ($now - $tL_0) >= 10) {
            force_kill_if_alive($ownerL_winpid);
            $ownerL_killed = 1;
        }
        if (!defined($ac4_hold_quiet_seen_at) && slurp_log($log4) =~ /HOLD-QUIET/) {
            $ac4_hold_quiet_seen_at = $now;
            force_kill_if_alive($owner4_winpid);
            $owner4_killed = 1;
        }
        if (!$ownerC_confirmed_past_60 && defined($tC_0) && ($now - $tC_0) >= 65) {
            if (defined($winpidC) && tasklist_shows_alive($winpidC)
                && defined($ownerC_winpid) && tasklist_shows_alive($ownerC_winpid)) {
                # Snapshot BEFORE the kill below -- this is the only point that
                # can prove "no RELEASE yet" meaningfully; slurping the log
                # after the loop (and after the kill scheduled right below)
                # would race the helper's own owner-gone RELEASE and read it
                # as if it had already happened before confirmation, which is
                # backwards.
                $ownerC_log_snapshot = slurp_log($logC);
                $ownerC_confirmed_past_60 = 1;
            }
        }
        if ($ownerC_confirmed_past_60 && !$ownerC_killed) {
            force_kill_if_alive($ownerC_winpid);
            $ownerC_killed = 1;
        }

        last if defined($ac4_hold_quiet_seen_at)
             && $owner3_killed
             && $ownerL_killed
             && $ownerC_killed
             && ($now - $t1_0) >= 81
             && ($now - $t3_0) >= 81
             && ($now - $t5_0) >= 81
             && ($now - $t6_0) >= 81
             && ($now - $tA_0) >= 76
             && (!defined($tA2_0) || ($now - $tA2_0) >= 76);

        sleep(1);
    }

    # If LS0-c's owner was never confirmed past 60s (e.g. its own spawn was
    # never confirmed), kill it now so cleanup still proceeds; the group's
    # own assertions below SKIP if the "past 60s, still alive" proof never
    # happened.
    if (!$ownerC_killed) {
        force_kill_if_alive($ownerC_winpid);
        $ownerC_killed = 1;
    }

    # If AC4's owner was never killed (no HOLD-QUIET seen within the shared
    # window), kill it now so cleanup/AC4's own assertions still proceed.
    if (!$owner4_killed) {
        force_kill_if_alive($owner4_winpid);
        $owner4_killed = 1;
    }

    # =====================================================================
    # AC1 [DC1, DC4]: quiet owner holds.
    # =====================================================================
    {
        ok((time() - $t1_0) >= 80, 'AC1: at least 80s elapsed since the helper pidfile appeared');
        ok(defined($winpid1) && tasklist_shows_alive($winpid1),
            "AC1: helper's WINPID is still alive after 80s of a quiet (untouched pidfile) owner")
            or diag("log:\n" . slurp_log($log1));
        ok(-e $pid1, 'AC1: the pidfile still exists (no release)');

        my $log1_text = slurp_log($log1);
        like($log1_text, qr/\bOWNER\b.*winpid=\Q$owner1_winpid\E/,
            'AC1: the log carries an OWNER line naming the owner winpid')
            or diag("log:\n$log1_text");
        like($log1_text, qr/HOLD-QUIET.*owner=\Q$owner1_winpid\E/,
            'AC1: at least one HOLD-QUIET line names owner=<W>')
            or diag("log:\n$log1_text");
        unlike($log1_text, qr/\bRELEASE\b/, 'AC1: no RELEASE line appears while the owner is quiet-but-alive');
    }

    # =====================================================================
    # AC2 [DC1]: deliberate release still wins in owner mode (continues
    # AC1's helper).
    # =====================================================================
    {
        unlink $pid1;
        my $got_release = wait_for_log_event($log1, qr/RELEASE\s+reason=pidfile-gone/, 15);
        ok($got_release, 'AC2: RELEASE reason=pidfile-gone appears within 15s of deleting the pidfile')
            or diag("log:\n" . slurp_log($log1));
        my $got_exit = wait_for_log_event($log1, qr/\bEXIT\b/, 10);
        ok($got_exit, 'AC2: EXIT follows the deliberate release')
            or diag("log:\n" . slurp_log($log1));
        ok(wait_gone_bounded($winpid1, 15), 'AC2: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpid1);
        close $fh1;
    }

    # =====================================================================
    # AC3 [DC2, DC4]: dead owner, died before expiry.
    # =====================================================================
    {
        ok($owner3_killed, 'AC3: the owner was killed ~10s after the helper started');
        # Bookkeeping only, not a functional criterion: the concurrent
        # design deliberately extends total wall time past the spec's
        # single-case 80s bound, so this is generous rather than tight --
        # a real regression is caught by the RELEASE/EXIT assertions below,
        # not by this line.
        diag(sprintf('AC3: %.0fs elapsed since the helper pidfile appeared', time() - $t3_0));

        SKIP: {
            skip 'AC3: owner process was never confirmed with a real WINPID (spawn contention) -- '
               . 'cannot assert an owner-naming RELEASE without one', 4
                unless defined $owner3_winpid;

            my $got_release = wait_for_log_event($log3, qr/RELEASE\s+reason=owner-gone.*owner=\Q$owner3_winpid\E/, 10);
            ok($got_release, "AC3: RELEASE reason=owner-gone naming owner=$owner3_winpid appears")
                or diag("log:\n" . slurp_log($log3));
            my $got_exit = wait_for_log_event($log3, qr/\bEXIT\b/, 10);
            ok($got_exit, 'AC3: EXIT follows the owner-gone release')
                or diag("log:\n" . slurp_log($log3));

            my $log3_text = slurp_log($log3);
            unlike($log3_text, qr/HOLD-QUIET/, 'AC3: no HOLD-QUIET line appears (owner died before the heartbeat went stale)');

            ok(!-e $pid3, 'AC3: the pidfile was removed on exit');
        }

        ok(wait_gone_bounded($winpid3, 15), 'AC3: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpid3);
        close $fh3;
    }

    # =====================================================================
    # AC4 [DC2, DC4]: dead owner, died during a quiet hold.
    # =====================================================================
    {
        ok(defined($ac4_hold_quiet_seen_at), 'AC4: a first HOLD-QUIET line was observed before the owner was killed')
            or diag("log:\n" . slurp_log($log4));

        SKIP: {
            skip 'AC4: no HOLD-QUIET was ever observed, cannot test the kill-during-quiet-hold path', 2
                unless defined $ac4_hold_quiet_seen_at;
            skip 'AC4: owner process was never confirmed with a real WINPID (spawn contention)', 2
                unless defined $owner4_winpid;

            my $got_release = wait_for_log_event($log4, qr/RELEASE\s+reason=owner-gone.*owner=\Q$owner4_winpid\E/, 15);
            ok($got_release, "AC4: RELEASE reason=owner-gone naming owner=$owner4_winpid appears within 15s of the kill")
                or diag("log:\n" . slurp_log($log4));

            ok(wait_gone_bounded($winpid4, 15), 'AC4: the helper WINPID is gone within a bounded wait');
        }
        force_kill_if_alive($winpid4);
        close $fh4;
    }

    # =====================================================================
    # AC5 [DC3, DC4]: orphan, no owner identity.
    # =====================================================================
    {
        ok((time() - $t5_0) >= 80, 'AC5: at least 80s elapsed since the helper pidfile appeared');
        my $log5_text = slurp_log($log5);
        like($log5_text, qr/RELEASE\s+reason=lease-expired/, 'AC5: RELEASE reason=lease-expired appears')
            or diag("log:\n$log5_text");
        unlike($log5_text, qr/\bOWNER\b/, 'AC5: no OWNER line appears (no -OwnerWinPid given)');
        unlike($log5_text, qr/HOLD-QUIET/, 'AC5: no HOLD-QUIET line appears');
        ok(wait_gone_bounded($winpid5, 15), 'AC5: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpid5);
        close $fh5;
    }

    # =====================================================================
    # AC6 [DC3, DC4]: orphan, owner already gone at start.
    # =====================================================================
    {
        ok((time() - $t6_0) >= 80, 'AC6: at least 80s elapsed since the helper pidfile appeared');
        my $log6_text = slurp_log($log6);
        like($log6_text, qr/OWNER-UNVERIFIABLE/, 'AC6: OWNER-UNVERIFIABLE appears (owner was already gone at start)')
            or diag("log:\n$log6_text");
        like($log6_text, qr/RELEASE\s+reason=lease-expired/, 'AC6: RELEASE reason=lease-expired follows (today\'s B3 behavior)')
            or diag("log:\n$log6_text");
        unlike($log6_text, qr/HOLD-QUIET/, 'AC6: no HOLD-QUIET line appears');

        my $unverif_pos = index($log6_text, 'OWNER-UNVERIFIABLE');
        my $release_pos = index($log6_text, 'reason=lease-expired');
        ok($unverif_pos >= 0 && $release_pos > $unverif_pos,
            'AC6: OWNER-UNVERIFIABLE precedes the lease-expired release in the log');

        ok(wait_gone_bounded($winpid6, 15), 'AC6: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpid6);
        close $fh6;
    }

    # =====================================================================
    # LS0-a (Decision 16, review S2/S3 -- SUPERSEDES the plain Decision 15
    # reading this file used before): -LeaseSeconds 0 with NO -OwnerWinPid at
    # all falls back to the pre-02 60s lease, WITH a log line saying so.
    # "0 means hold until killed or until the owner is gone" only holds when
    # there is a verifiable owner to be gone FROM (see Decision 16: "a
    # lease-0 helper started without a verifiable owner falls back to the
    # pre-02 60s lease with a log line, so no caller can hold the machine
    # forever unowned").
    #
    # The exact log wording is not pinned by any spec/decision text seen so
    # far, so this checks for the word "fallback" (case-insensitive) plus
    # the effective 60s figure, rather than a literal token -- the
    # implementer's chosen wording should still satisfy this unless it
    # avoids saying either.
    # =====================================================================
    {
        my $got_release = wait_for_log_event($logA, qr/RELEASE\s+reason=lease-expired/, 15);
        ok($got_release,
            'LS0-a: -LeaseSeconds 0 with NO -OwnerWinPid falls back to a 60s lease -- '
          . 'RELEASE reason=lease-expired appears (Decision 16), never an unconditional hold')
            or diag("log:\n" . slurp_log($logA));

        my $logA_text = slurp_log($logA);
        like($logA_text, qr/fallback/i,
            'LS0-a: the log states that it fell back to the bounded lease (Decision 16: '
          . '"with a log line")')
            or diag("log:\n$logA_text");
        like($logA_text, qr/60/,
            'LS0-a: the fallback is to a 60s lease specifically, not some other bound')
            or diag("log:\n$logA_text");

        ok(wait_gone_bounded($winpidA, 15), 'LS0-a: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpidA);
        close $fhA;
    }

    # =====================================================================
    # LS0-a2 (Decision 16, review S2/S3, "or with an unverifiable owner"):
    # -LeaseSeconds 0 with an owner that is ALREADY GONE before the helper
    # even starts (OWNER-UNVERIFIABLE) must fall back exactly like LS0-a --
    # never an unconditional hold just because -OwnerWinPid was *passed*.
    # =====================================================================
    {
        SKIP: {
            skip 'LS0-a2: owner A2 start ticks were never confirmed (spawn contention) -- '
               . 'no anchored helper was spawned for this group', 4
                unless defined $ownerA2_start;

            my $got_unverif = wait_for_log_event($logA2, qr/OWNER-UNVERIFIABLE/, 15);
            ok($got_unverif, 'LS0-a2: OWNER-UNVERIFIABLE appears (the named owner was already gone)')
                or diag("log:\n" . slurp_log($logA2));

            my $got_release = wait_for_log_event($logA2, qr/RELEASE\s+reason=lease-expired/, 15);
            ok($got_release,
                'LS0-a2: -LeaseSeconds 0 with an UNVERIFIABLE owner falls back to a 60s lease -- '
              . 'RELEASE reason=lease-expired appears, never an unconditional hold')
                or diag("log:\n" . slurp_log($logA2));

            my $logA2_text = slurp_log($logA2);
            like($logA2_text, qr/fallback/i,
                'LS0-a2: the log states that it fell back to the bounded lease')
                or diag("log:\n$logA2_text");

            ok(wait_gone_bounded($winpidA2, 15), 'LS0-a2: the helper WINPID is gone within a bounded wait');
        }
        force_kill_if_alive($winpidA2);
        close $fhA2 if $fhA2;
    }

    # =====================================================================
    # LS0-b (Decision 15): -LeaseSeconds 0 WITH a live owner that then dies
    # -- must still release on owner-gone, even though the numeric lease is
    # "infinite".
    # =====================================================================
    {
        ok($ownerL_killed, 'LS0-b: the owner was killed ~10s after the helper started');

        SKIP: {
            skip 'LS0-b: owner process was never confirmed with a real WINPID (spawn contention)', 2
                unless defined $ownerL_winpid;

            my $got_release = wait_for_log_event($logL, qr/RELEASE\s+reason=owner-gone.*owner=\Q$ownerL_winpid\E/, 30);
            ok($got_release,
                "LS0-b: RELEASE reason=owner-gone naming owner=$ownerL_winpid appears even with -LeaseSeconds 0 -- "
              . '0 means "hold until killed OR until the owner is gone", never an unconditional hold')
                or diag("log:\n" . slurp_log($logL));
            my $got_exit = wait_for_log_event($logL, qr/\bEXIT\b/, 10);
            ok($got_exit, 'LS0-b: EXIT follows the owner-gone release')
                or diag("log:\n" . slurp_log($logL));
        }

        ok(wait_gone_bounded($winpidL, 15), 'LS0-b: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpidL);
        close $fhL;
    }

    # =====================================================================
    # LS0-c (Decision 16 (b)): -LeaseSeconds 0 WITH a VERIFIED, live owner
    # holds PAST the legacy 60s clamp (proven directly, not inferred from
    # LS0-b's early kill), then releases with reason=owner-gone once that
    # owner actually exits.
    # =====================================================================
    {
        ok($ownerC_confirmed_past_60,
            'LS0-c: the owner and helper were both directly confirmed still alive at >=65s '
          . '(past the legacy 60s clamp) BEFORE the owner was killed')
            or diag("log:\n" . slurp_log($logC));

        SKIP: {
            skip 'LS0-c: never confirmed the helper holding past 60s with a live owner -- cannot test the '
               . 'subsequent owner-gone release meaningfully', 3
                unless $ownerC_confirmed_past_60;

            unlike($ownerC_log_snapshot, qr/\bRELEASE\b/,
                'LS0-c: no RELEASE had occurred by the time the owner was confirmed alive past 60s');

            ok($ownerC_killed, 'LS0-c: the owner was killed after being confirmed alive past 60s');

            my $got_release = wait_for_log_event($logC, qr/RELEASE\s+reason=owner-gone.*owner=\Q$ownerC_winpid\E/, 30);
            ok($got_release,
                "LS0-c: RELEASE reason=owner-gone naming owner=$ownerC_winpid appears once the owner actually "
              . 'exits, even though it was held well past the legacy 60s clamp beforehand')
                or diag("log:\n" . slurp_log($logC));
        }

        ok(wait_gone_bounded($winpidC, 15), 'LS0-c: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($winpidC);
        close $fhC;
    }

    cmp_ok(time() - $t_suite_start, '<', 400,
        'the whole concurrent integration group completed within a 400s wall-clock ceiling');
}

# ---------------------------------------------------------------------------
# SIM-PIN / SIM-PROBE (AC-W5, AC-W6, DC2). Run sequentially, AFTER the main
# concurrent group above, deliberately NOT folded into its shared loop:
# that loop already runs 9 owner/helper pairs concurrently, and measurement
# (two back-to-back runs while this file was being written) showed that
# adding 2 more pairs to the SAME pre-loop sequential spawn chain pushed
# process-creation contention far enough to delay owner3's scheduled
# ~10s kill (AC3) past the helper's own ~60s quiet threshold -- a real
# regression in an EXISTING, unrelated assertion, caused purely by this
# package's own added load, not by anything under test. Running this pair
# in its own block after the main one returns the main block's concurrency
# profile to exactly what it was, which is what AC-W7 requires.
# ---------------------------------------------------------------------------
SKIP: {
    my $n_sim_tests = 20;
    skip 'keep-awake.ps1 spawn tests are Windows-only', $n_sim_tests
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    skip "keep-awake.ps1 not found at $SCRIPT", $n_sim_tests
        unless -f $SCRIPT;

    my $t_sim_suite_start = time();

    # SIM-PIN (AC-W5): a dedicated live owner S, pinned with its OWN correct
    # -OwnerStartTicks, but the seam file is pre-seeded with a bogus value
    # BEFORE the helper is spawned -- the pin-time mismatch path.
    my ($ownerS_winpid, $ownerS_fh, $ownerS_dir, $ownerS_start) = spawn_owner();
    ok(defined($ownerS_winpid), 'SIM-PIN setup: owner process S started with a real WINPID');
    my $dirSP     = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    my $simfileSP = "$dirSP/sim.ticks";
    {
        open(my $simfh, '>', $simfileSP) or die "cannot write $simfileSP: $!";
        print {$simfh} "1\n";
        close $simfh;
    }

    # SIM-PROBE (AC-W6): a dedicated live owner R, pinned normally (no
    # anchor); the seam file does NOT exist yet, so the pin reads the real
    # value and succeeds -- this exercises the PROBE-time re-check.
    my ($ownerR_winpid, $ownerR_fh, $ownerR_dir, $ownerR_start) = spawn_owner();
    ok(defined($ownerR_winpid), 'SIM-PROBE setup: owner process R started with a real WINPID');
    my $dirR         = tempdir(DIR => $WIN_TMP, CLEANUP => 1);
    my $simfileR     = "$dirR/sim.ticks";
    my $simfileR_tmp = "$dirR/sim.ticks.tmp";

    my ($logSP, $pidSP, $fhSP, $dirSP_kw);
    my $tSP_0 = time();
    my $winpidSP;
    SKIP: {
        skip 'SIM-PIN: owner S start ticks were never confirmed (spawn contention) -- cannot anchor', 1
            unless defined $ownerS_start;
        ($logSP, $pidSP, $fhSP, $dirSP_kw) = spawn_keepawake(
            lease => 0, owner_winpid => $ownerS_winpid,
            owner_start_ticks => $ownerS_start, sim_ticks_file => $simfileSP);
        $tSP_0 = time();
        $winpidSP = wait_for_file_numeric($pidSP, 15);
        push @LIVE_WINPIDS, $winpidSP if defined $winpidSP;
        ok(defined($winpidSP), 'SIM-PIN: helper pidfile appears with a numeric WINPID')
            or diag("log so far:\n" . slurp_log($logSP));
    }

    my ($logR, $pidR, $fhR, $dirR_kw) = spawn_keepawake(
        lease => 0, owner_winpid => $ownerR_winpid, sim_ticks_file => $simfileR);
    my $tR_0 = time();
    my $winpidR = wait_for_file_numeric($pidR, 15);
    push @LIVE_WINPIDS, $winpidR if defined $winpidR;
    ok(defined($winpidR), 'SIM-PROBE: helper pidfile appears with a numeric WINPID')
        or diag("log so far:\n" . slurp_log($logR));

    # SIM-PROBE state: when the OWNER winpid=R line was first seen, the log
    # snapshot taken right then (before the seam write), whether the seam
    # file has been written yet, and when.
    my $simR_owner_seen_at;
    my $simR_snapshot;
    my $simR_written = 0;
    my $tR_written;

    my $sim_deadline = time() + 130;
    while (time() < $sim_deadline) {
        my $now = time();

        if (!defined($simR_owner_seen_at)) {
            my $logR_now = slurp_log($logR);
            if (defined($ownerR_winpid) && $logR_now =~ /\bOWNER\s+winpid=\Q$ownerR_winpid\E/) {
                $simR_owner_seen_at = $now;
                $simR_snapshot = $logR_now;
            }
        }
        if (defined($simR_owner_seen_at) && !$simR_written) {
            open(my $tfh, '>', $simfileR_tmp) or die "cannot write $simfileR_tmp: $!";
            print {$tfh} "1\n";
            close $tfh;
            rename($simfileR_tmp, $simfileR) or die "cannot rename $simfileR_tmp -> $simfileR: $!";
            $tR_written   = $now;
            $simR_written = 1;
        }

        last if ($now - $tSP_0) >= 76
             && $simR_written && ($now - $tR_written) >= 20;

        sleep(1);
    }

    # =====================================================================
    # SIM-PIN (AC-W5, DC2): simulated pin-time identity mismatch. A real,
    # live owner S is anchored with its OWN correct -OwnerStartTicks, but
    # the seam file (-SimulateOwnerStartTicksFile) was pre-seeded with a
    # bogus value (1) BEFORE the helper was even spawned, so the FIRST read
    # the pin block makes already disagrees with -OwnerStartTicks. This
    # proves the mismatch path fires on pin, deterministically, while S
    # itself never dies -- the deterministic "reports dead, not alive"
    # shape for a race otherwise unreproducible on a real host (see
    # architect-1.md).
    # =====================================================================
    {
        SKIP: {
            skip 'SIM-PIN: owner S start ticks were never confirmed (spawn contention) -- cannot anchor', 7
                unless defined $ownerS_start;

            my $got_unverif = wait_for_log_event($logSP,
                qr/OWNER-UNVERIFIABLE\s+winpid=\Q$ownerS_winpid\E\s+reason=start-time-mismatch/, 15);
            ok($got_unverif, 'SIM-PIN: OWNER-UNVERIFIABLE winpid=S reason=start-time-mismatch appears')
                or diag("log:\n" . slurp_log($logSP));

            my $logSP_text = slurp_log($logSP);
            unlike($logSP_text, qr/\bOWNER\s+winpid=/,
                'SIM-PIN: no bare OWNER winpid= line appears (the pin was rejected)');
            like($logSP_text, qr/fallback/i,
                'SIM-PIN: the log states that it fell back to the bounded lease');

            my $got_release = wait_for_log_event($logSP, qr/RELEASE\s+reason=lease-expired/, 15);
            ok($got_release,
                'SIM-PIN: RELEASE reason=lease-expired appears -- the mismatch forced the 60s fallback')
                or diag("log:\n" . slurp_log($logSP));

            my $logSP_text2 = slurp_log($logSP);
            unlike($logSP_text2, qr/HOLD-QUIET/, 'SIM-PIN: no HOLD-QUIET line appears');

            ok(tasklist_shows_alive($ownerS_winpid),
                'SIM-PIN: owner S is STILL ALIVE after the helper released on lease-expired -- '
              . 'the release came from identity mismatch, never from the real owner exiting');

            ok(wait_gone_bounded($winpidSP, 15), 'SIM-PIN: the helper WINPID is gone within a bounded wait');
        }
        force_kill_if_alive($ownerS_winpid);
        force_kill_if_alive($winpidSP);
        close $fhSP if $fhSP;
    }

    # =====================================================================
    # SIM-PROBE (AC-W6, DC2): simulated identity-replaced-at-probe. A real,
    # live owner R is pinned normally (no anchor -- this exercises the
    # PROBE-time re-check, not the pin-time one). Once the helper has
    # visibly pinned R (a bare OWNER line names it), the seam file is
    # created so every SUBSEQUENT Get-KaOwnerStartTicks call returns a value
    # that disagrees with what was pinned, while R itself is never touched.
    # This is the deterministic proof for done-criterion 2 that the
    # liveness check can report "gone" for a process that never actually
    # exited.
    # =====================================================================
    {
        SKIP: {
            skip 'SIM-PROBE: owner R process was never confirmed with a real WINPID (spawn contention)', 7
                unless defined $ownerR_winpid;
            skip 'SIM-PROBE: no OWNER winpid=R line was ever observed in the helper log -- '
               . 'cannot test the probe-time path', 7
                unless defined $simR_owner_seen_at;

            unlike($simR_snapshot, qr/OWNER-REPLACED/,
                'SIM-PROBE: the snapshot taken before the seam write contains no OWNER-REPLACED');
            unlike($simR_snapshot, qr/\bRELEASE\b/,
                'SIM-PROBE: the snapshot taken before the seam write contains no RELEASE -- '
              . 'the helper held R as alive while the seam was still inert');

            my $got_replaced = wait_for_log_event($logR,
                qr/OWNER-REPLACED\s+winpid=\Q$ownerR_winpid\E\s+pinned_start=\d+\s+probed_start=1\b/, 30);
            ok($got_replaced, 'SIM-PROBE: OWNER-REPLACED winpid=R pinned_start=<p> probed_start=1 appears')
                or diag("log:\n" . slurp_log($logR));

            my $got_release = wait_for_log_event($logR,
                qr/RELEASE\s+reason=owner-gone.*owner=\Q$ownerR_winpid\E/s, 15);
            ok($got_release, "SIM-PROBE: RELEASE reason=owner-gone naming owner=$ownerR_winpid appears")
                or diag("log:\n" . slurp_log($logR));

            my $logR_text    = slurp_log($logR);
            my $replaced_pos = index($logR_text, 'OWNER-REPLACED');
            my $release_pos  = index($logR_text, 'RELEASE');
            ok($replaced_pos >= 0 && $release_pos > $replaced_pos,
                'SIM-PROBE: RELEASE follows OWNER-REPLACED in the log')
                or diag("log:\n$logR_text");

            my $got_exit = wait_for_log_event($logR, qr/\bEXIT\b/, 10);
            ok($got_exit, 'SIM-PROBE: EXIT follows the owner-gone release')
                or diag("log:\n" . slurp_log($logR));

            ok(tasklist_shows_alive($ownerR_winpid),
                'SIM-PROBE: owner R is STILL ALIVE after the helper reported it gone and exited -- '
              . 'the liveness check reported "gone" for a live process whose identity no longer '
              . 'matches (done-criterion 2)');
        }
        ok(wait_gone_bounded($winpidR, 15), 'SIM-PROBE: the helper WINPID is gone within a bounded wait');
        force_kill_if_alive($ownerR_winpid);
        force_kill_if_alive($winpidR);
        close $fhR if $fhR;
    }

    cmp_ok(time() - $t_sim_suite_start, '<', 400,
        'SIM-PIN/SIM-PROBE completed within a 400s wall-clock ceiling');
}

# ---------------------------------------------------------------------------
# AC7 [DC1, Decision 2]: frozen owner holds. Run sequentially, after the
# concurrent group above, so a failed suspend attempt cannot strand a
# process the shared loop was still tracking. Skips (does not fail) if the
# NtSuspendProcess call cannot be made or returns a non-zero NTSTATUS --
# AC1 remains the DC1 carrier regardless.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'keep-awake.ps1 spawn tests are Windows-only', 6
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    skip "keep-awake.ps1 not found at $SCRIPT", 6
        unless -f $SCRIPT;
    # Quarantined (host-wake-and-suspend Decision 18): the host hard-froze on
    # 2026-09-26 within seconds of this block suspending a process, so it only
    # runs when explicitly requested, never in an unattended sweep.
    skip 'AC7 suspends a process with NtSuspendProcess; set CCPRAXIS_TEST_SUSPEND_PROCESS=1 to run it', 6
        unless ($ENV{CCPRAXIS_TEST_SUSPEND_PROCESS} // '') eq '1';

    my ($owner7_winpid, $owner7_fh, $owner7_dir) = spawn_owner();
    unless (defined $owner7_winpid) {
        skip 'AC7: could not start an owner process', 6;
    }

    my ($status_out, $status_err) = run_ps_snippet(<<"PS");
Add-Type -Namespace T -Name P -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);'
try {
    \$p = Get-Process -Id $owner7_winpid -ErrorAction Stop
    \$r = [T.P]::NtSuspendProcess(\$p.Handle)
    Write-Output \$r
} catch {
    Write-Output "EXCEPTION:\$(\$_.Exception.Message)"
}
PS

    my $suspend_status;
    if (defined($status_out) && $status_out =~ /^\s*(-?\d+)\s*$/) {
        $suspend_status = $1;
    }

    if (!defined($suspend_status) || $suspend_status != 0) {
        force_kill_if_alive($owner7_winpid);
        my $reason = defined($status_out) ? $status_out : ($status_err // 'no output');
        skip "AC7: NtSuspendProcess did not return STATUS_SUCCESS (environmental: $reason)", 6;
    }

    my ($log7, $pid7, $fh7, $dir7) = spawn_keepawake(owner_winpid => $owner7_winpid);
    my $t7_0 = time();
    my $winpid7 = wait_for_file_numeric($pid7, 15);
    push @LIVE_WINPIDS, $winpid7 if defined $winpid7;
    ok(defined($winpid7), 'AC7: helper pidfile appears with a numeric WINPID (owner frozen)')
        or diag("log so far:\n" . slurp_log($log7));

    while (time() - $t7_0 < 81) { sleep(1); }

    ok(defined($winpid7) && tasklist_shows_alive($winpid7),
        "AC7: helper's WINPID is still alive after 80s while the owner is SUSPENDED (frozen, not gone)")
        or diag("log:\n" . slurp_log($log7));
    ok(-e $pid7, 'AC7: the pidfile still exists (no release for a frozen owner)');

    my $log7_text = slurp_log($log7);
    like($log7_text, qr/HOLD-QUIET.*owner=\Q$owner7_winpid\E/,
        'AC7: at least one HOLD-QUIET line names the frozen owner')
        or diag("log:\n$log7_text");
    unlike($log7_text, qr/\bRELEASE\b/, 'AC7: no RELEASE line appears for a frozen (suspended, not exited) owner');

    # Resume-or-kill in cleanup, regardless of outcome above.
    run_ps_snippet(<<"PS");
Add-Type -Namespace T -Name P -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);'
try {
    \$p = Get-Process -Id $owner7_winpid -ErrorAction Stop
    [T.P]::NtResumeProcess(\$p.Handle) | Out-Null
} catch {}
PS
    force_kill_if_alive($owner7_winpid);
    force_kill_if_alive($winpid7);
    close $fh7;
}

# run_ps_snippet($ps_code) -> ($stdout, $error)
#
# Writes $ps_code to a real .ps1 file and runs it with -File, sidestepping
# the Windows quoting hazards of an inline -Command string. Used only by
# AC7, which needs a one-shot ntdll P/Invoke call the main script does not
# make itself.
sub run_ps_snippet {
    my ($code) = @_;
    my ($fh, $filename) = tempfile(DIR => $WIN_TMP, SUFFIX => '.ps1');
    print {$fh} $code;
    close $fh;
    my @cmd = ('powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $filename);
    my $pfh;
    unless (open($pfh, '-|', @cmd)) {
        unlink $filename;
        return (undef, "spawn failed: $!");
    }
    local $/;
    my $out = <$pfh>;
    close $pfh;
    unlink $filename;
    return (defined($out) ? $out : '', undef);
}

# ---------------------------------------------------------------------------
# AC10 [regression]: this package's write set does not touch
# execution-power-request.t, and this file spawns no -OwnerWinPid-less run
# (B3) through any path that file itself does not already cover. Not
# re-asserted here as a subprocess call (that test's own oracle is the
# authority for its own ACs); recorded so the mapping is traceable.
# ---------------------------------------------------------------------------
pass('AC10: execution-power-request.t is unmodified by this package\'s write set '
   . '(plugins/sandbox/scripts/keep-awake.ps1:plugins/sandbox/tests/t/keepawake-lease-liveness.t only) '
   . '-- its own regression is verified by running it directly, not from inside this file');

# ---------------------------------------------------------------------------
# AC11 [powershell-syntax check]: enforced by the blueprint's own
# `powershell-syntax` check command, not re-implemented here (this file has
# no PowerShell parser available to it that the check does not already
# run more authoritatively).
# ---------------------------------------------------------------------------
pass('AC11: PowerShell-5.1 parse validity is enforced by the blueprint\'s powershell-syntax check, '
   . 'not duplicated here');

done_testing();
