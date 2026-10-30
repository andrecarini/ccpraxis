#!/usr/bin/env perl
# platform: host
#
# 01-execution-power-request (host-wake-and-suspend blueprint).
#
# keep-awake.ps1 currently holds SetThreadExecutionState(ES_CONTINUOUS |
# ES_SYSTEM_REQUIRED) which produces DISPLAY/SYSTEM rows in `powercfg
# /requests` but leaves EXECUTION: None. This package adds a real Win32
# Power Request (PowerCreateRequest/PowerSetRequest/PowerClearRequest via
# P/Invoke) acquired right after the existing SetThreadExecutionState call
# succeeds and released from the existing `finally` block.
#
# No test in this repo previously exercised a .ps1 file's Add-Type/P-Invoke
# path (scout-confirmed) -- this is the first. Chosen approach (spec section
# 5): spawn the REAL script as a real child process and assert on its
# -LogFile output; no mocking of Win32 APIs. Creating/setting/clearing a
# power request for the calling process needs no elevation (only reading
# ALL holders via `powercfg /requests` does) -- so the happy path and the
# degrade path (forced via -SimulatePowerRequestFailure, a test-only seam)
# are both safely exercisable unattended. Only AC7 (elevated `powercfg
# /requests` observation, Decision 8) is explicitly manual -- see spec
# section 6. Not tested here by design.
#
# Cleanup discipline: every spawned keep-awake.ps1's WINPID (the real
# Windows pid it writes about itself into -PidFile -- NOT any pid Perl's
# open() tracked; see this project's CLAUDE.md on the MSYS-pid/WINPID
# landmine) is registered in @LIVE_WINPIDS the moment it is known. An END
# block force-kills anything still alive there, on top of the per-test
# force_kill_if_alive() backstop, so a failed run can never leave a real
# wake-lock holder running on this machine.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep time);
use FindBin qw($Bin);

my $SCRIPT = "$Bin/../../scripts/keep-awake.ps1";

# ---------------------------------------------------------------------------
# static/structural checks (AC1, AC2, AC8, AC9) -- run unconditionally, no
# SKIP, matching keepawake-decision-core.t's convention for static checks.
# ---------------------------------------------------------------------------

my $src;
{
    local $/;
    open(my $fh, '<:raw', $SCRIPT) or BAIL_OUT("cannot read $SCRIPT: $!");
    $src = <$fh>;
    close $fh;
}

ok(defined($src) && length($src) > 0, 'keep-awake.ps1 is readable and non-empty');

# AC1 [DC2, static]: SetThreadExecutionState flags expression unchanged, and
# its ASSERT-FAILED / exit 1 failure path is still present, unmodified in
# shape.
like($src, qr/\$ES_CONTINUOUS\s*-bor\s*\$ES_SYSTEM_REQUIRED/,
    'AC1: ES_CONTINUOUS -bor ES_SYSTEM_REQUIRED flags expression still present verbatim');

like($src, qr/ASSERT-FAILED/,
    'AC1: ASSERT-FAILED event token still present (SetThreadExecutionState failure path)');

like($src, qr/ASSERT-FAILED[^\n]*\n(?:[^\n]*\n){0,6}?[^\n]*exit\s+1/s,
    'AC1: ASSERT-FAILED path still followed (within a few lines) by exit 1');

# AC2 [DC2, static]: ES_DISPLAY_REQUIRED must not reappear anywhere as LIVE
# CODE. The baseline file already carries historical comment lines
# documenting the 2026-09-17 removal (e.g. "ES_DISPLAY_REQUIRED WAS DROPPED
# 2026-09-17, on measurement") -- those are pre-existing narrative, not a
# reintroduction, and this package's own write set does not touch them. The
# spec's concern ("must not reintroduce it as a side effect of adding the
# Power Request") is about the flag coming back as an active constant/usage,
# so non-comment lines are what this check pins.
{
    my @live_hits;
    for my $line (split /\n/, $src) {
        next unless $line =~ /ES_DISPLAY_REQUIRED/;
        (my $stripped = $line) =~ s/^\s+//;
        push @live_hits, $line unless $stripped =~ /^#/;
    }
    is(scalar(@live_hits), 0,
        'AC2: ES_DISPLAY_REQUIRED does not reappear as live (non-comment) code')
        or diag("live-code hits:\n" . join("\n", @live_hits));
}

# AC8 [static]: exactly one Add-Type call site, and the new members live in
# it (no second Add-Type call).
my @addtype_hits = ($src =~ /\bAdd-Type\b/g);
is(scalar(@addtype_hits), 1, 'AC8: exactly one Add-Type call site in the file');

# The four new DllImport signatures must be present, all against
# kernel32.dll, per spec section 2.2 (verbatim block).
for my $sig (
    qr/PowerCreateRequest\s*\(\s*ref\s+POWER_REQUEST_CONTEXT\s+Context\s*\)/,
    qr/PowerSetRequest\s*\(\s*IntPtr\s+PowerRequest\s*,\s*int\s+RequestType\s*\)/,
    qr/PowerClearRequest\s*\(\s*IntPtr\s+PowerRequest\s*,\s*int\s+RequestType\s*\)/,
    qr/CloseHandle\s*\(\s*IntPtr\s+hObject\s*\)/,
) {
    like($src, $sig, "AC8/2.2: DllImport signature present: $sig");
}

my $kernel32_count = () = ($src =~ /DllImport\("kernel32\.dll"/g);
cmp_ok($kernel32_count, '>=', 4,
    'AC8/2.2: at least 4 kernel32.dll DllImport declarations (the 4 new Power* + CloseHandle entries)');

like($src, qr/POWER_REQUEST_CONTEXT/,
    '2.2: POWER_REQUEST_CONTEXT struct referenced (Version/Flags/SimpleReasonString)');

like($src, qr/PowerRequestExecutionRequired\s*=\s*3/,
    '2.2: $PowerRequestExecutionRequired constant defined as 3 (POWER_REQUEST_TYPE)');

# AC9 [static]: no non-ASCII byte anywhere in the file.
{
    my $has_non_ascii = ($src =~ /[^\x00-\x7f]/) ? 1 : 0;
    ok(!$has_non_ascii, 'AC9: file contains no byte outside \\x00-\\x7f (BOM-less ASCII)');
}

# 2.1: the new -SimulatePowerRequestFailure switch parameter is declared.
like($src, qr/\[switch\]\s*\$SimulatePowerRequestFailure/,
    '2.1: -SimulatePowerRequestFailure switch parameter declared');

# Fix-batch 02 (redteam-01.md MEDIUM finding): -SimulatePowerRequestException
# is a second test-only seam that makes PowerSetRequest throw (rather than
# return $false) AFTER a real PowerCreateRequest handle exists, so the
# catch block's handle-close path can be exercised against a live handle.
like($src, qr/\[switch\]\s*\$SimulatePowerRequestException/,
    'fixbatch-02: -SimulatePowerRequestException switch parameter declared');

like($src, qr/handle-closed=true/,
    'fixbatch-02: catch block logs handle-closed=true when it closes a live handle');

# 2.6: the exact $Event tokens this package introduces must appear as
# string literals somewhere in the source (sanity check ahead of the
# integration tests below, which pin them via real log output).
for my $event (qw(POWER-REQUEST-CREATED POWER-REQUEST-DEGRADED POWER-REQUEST-RELEASED)) {
    like($src, qr/\Q$event\E/, "2.6: event token '$event' present in source");
}

# ---------------------------------------------------------------------------
# integration: spawn the real script as a real child process (AC3-AC6)
# ---------------------------------------------------------------------------

my @LIVE_WINPIDS;   # every winpid we have EVER spawned in this run; the END
                     # block force-kills whatever is still alive, pass or fail.

END {
    for my $winpid (@LIVE_WINPIDS) {
        next unless defined $winpid && $winpid =~ /^\d+$/;
        force_kill_if_alive($winpid);
    }
}

sub tasklist_shows_alive {
    my ($winpid) = @_;
    return 0 unless defined $winpid && $winpid =~ /^\d+$/;
    # MSYS2_ARG_CONV_EXCL local to this one call -- without it, Git-for-Windows
    # mangles the bare /FI flag into a POSIX-path guess (CLAUDE.md's documented
    # landmine), so `tasklist` errors on every invocation and every live pid
    # reads as absent. Confirmed empirically before landing this fix.
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $out = `tasklist /FI "PID eq $winpid" 2>&1`;
    return 0 unless defined $out;
    return ($out =~ /\b\Q$winpid\E\b/) ? 1 : 0;
}

sub force_kill_if_alive {
    my ($winpid) = @_;
    return unless defined $winpid && $winpid =~ /^\d+$/;
    return unless tasklist_shows_alive($winpid);
    system('taskkill', '/F', '/PID', $winpid);
    return;
}

# spawn_keepawake(%opts) -> ($logfile, $pidfile, $fh)
#
# Builds a tempdir (CLEANUP => 1), writes pidfile/logfile paths inside it,
# spawns keep-awake.ps1 via list-pipe open (no shell interpolation). Caller
# keeps $fh open for the process's lifetime; closing it does not kill the
# child (it is independent once spawned in list-pipe form).
sub spawn_keepawake {
    my (%opts) = @_;

    my $dir     = tempdir(CLEANUP => 1);
    my $pidfile = "$dir/keepawake.pid";
    my $logfile = "$dir/keepawake.log";

    my @cmd = (
        'powershell.exe', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File', $SCRIPT,
        '-PidFile', $pidfile, '-LogFile', $logfile,
        '-PollSeconds', 5, '-LeaseSeconds', 60,
    );
    push @cmd, '-SimulatePowerRequestFailure' if $opts{simulate_failure};
    push @cmd, '-SimulatePowerRequestException' if $opts{simulate_exception};

    open(my $fh, '-|', @cmd) or die "spawn failed: $!";

    return ($logfile, $pidfile, $fh, $dir);
}

# wait_for_log_event($logfile, $event_regex, $timeout_s) -> bool
sub wait_for_log_event {
    my ($logfile, $regex, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        if (-e $logfile) {
            local $/;
            open(my $fh, '<', $logfile) or goto SLEEP;
            my $content = <$fh>;
            close $fh;
            if (defined($content) && $content =~ $regex) {
                return 1;
            }
        }
      SLEEP:
        sleep(0.25);
    }
    return 0;
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

# winpid_from_pidfile($pidfile) -> $winpid
#
# The REAL Windows PID the script wrote about itself (its own $PID), not
# any pid Perl's open() tracked. Using this with taskkill/tasklist sidesteps
# the MSYS-pid vs WINPID landmine entirely.
sub wait_for_pidfile_winpid {
    my ($pidfile, $timeout_s) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        if (-e $pidfile) {
            open(my $fh, '<', $pidfile) or goto SLEEP;
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

SKIP: {
    my $n_integration_tests = 27;
    skip 'keep-awake.ps1 spawn tests are Windows-only', $n_integration_tests
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    skip "keep-awake.ps1 not found at $SCRIPT", $n_integration_tests
        unless -f $SCRIPT;

    # ---- AC3 + AC5: real create+set path, then deliberate release --------
    {
        my $t0 = time();
        my ($logfile, $pidfile, $fh, $dir) = spawn_keepawake();

        my $winpid = wait_for_pidfile_winpid($pidfile, 15);
        push @LIVE_WINPIDS, $winpid if defined $winpid;
        ok(defined($winpid), 'AC3: pidfile appears with a numeric WINPID')
            or diag("log so far:\n" . slurp_log($logfile));

        my $got_created = wait_for_log_event($logfile, qr/POWER-REQUEST-CREATED/, 15);
        ok($got_created, 'AC3: POWER-REQUEST-CREATED line appears in the log')
            or diag("log so far:\n" . slurp_log($logfile));

        SKIP: {
            skip 'no POWER-REQUEST-CREATED line to inspect', 2 unless $got_created;
            my $log = slurp_log($logfile);
            my ($line) = ($log =~ /^(.*POWER-REQUEST-CREATED.*)$/m);
            like($line, qr/handle=0x/,
                'AC3: POWER-REQUEST-CREATED detail contains handle=0x');
            like($line, qr/PowerRequestExecutionRequired/,
                'AC3: POWER-REQUEST-CREATED detail contains PowerRequestExecutionRequired');
        }

        # behavior 1: ASSERTED must appear before POWER-REQUEST-CREATED.
        SKIP: {
            skip 'no POWER-REQUEST-CREATED line to order against', 1 unless $got_created;
            my $log = slurp_log($logfile);
            my $asserted_pos = index($log, 'ASSERTED');
            my $created_pos  = index($log, 'POWER-REQUEST-CREATED');
            ok($asserted_pos >= 0 && $created_pos > $asserted_pos,
                'behavior 1: ASSERTED precedes POWER-REQUEST-CREATED in the log');
        }

        # AC5: deliberate release -- delete the pidfile, expect RELEASE,
        # then POWER-REQUEST-RELEASED, then EXIT, in that order, exit code 0.
        unlink $pidfile;

        my $got_released = wait_for_log_event($logfile, qr/POWER-REQUEST-RELEASED/, 20);
        ok($got_released, 'AC5: POWER-REQUEST-RELEASED line appears after pidfile deletion')
            or diag("log so far:\n" . slurp_log($logfile));

        my $got_exit = wait_for_log_event($logfile, qr/\bEXIT\b/, 10);
        ok($got_exit, 'AC5: EXIT line appears after release')
            or diag("log so far:\n" . slurp_log($logfile));

        SKIP: {
            skip 'ordering check requires both lines present', 1
                unless $got_released && $got_exit;
            my $log = slurp_log($logfile);
            my $release_pos      = index($log, 'RELEASE');
            my $power_rel_pos    = index($log, 'POWER-REQUEST-RELEASED');
            my $exit_pos         = index($log, 'EXIT');
            # last EXIT occurrence, in case EXIT substring appears earlier too
            my $last_exit_pos = -1;
            {
                my $pos = -1;
                while (($pos = index($log, 'EXIT', $pos + 1)) >= 0) {
                    $last_exit_pos = $pos;
                }
            }
            ok($release_pos >= 0
                && $power_rel_pos > $release_pos
                && $last_exit_pos > $power_rel_pos,
                'AC5: log order is RELEASE ... POWER-REQUEST-RELEASED ... EXIT')
                or diag("log:\n$log");
        }

        # wait (bounded) for the process to actually terminate; force-kill as
        # a backstop so nothing is left running regardless of outcome.
        my $gone = 0;
        my $wait_deadline = time() + 10;
        while (time() < $wait_deadline) {
            if (!defined($winpid) || !tasklist_shows_alive($winpid)) { $gone = 1; last; }
            sleep(0.25);
        }
        ok($gone, 'AC5: process is gone (or was never confirmed alive) within bounded wait')
            or diag('winpid still listed by tasklist after wait');

        force_kill_if_alive($winpid) if defined $winpid;
        close $fh;

        cmp_ok(time() - $t0, '<', 30, 'AC3/AC5 sub-test completed within the 30s wall-clock ceiling');
    }

    # ---- AC4 + AC6: -SimulatePowerRequestFailure path ---------------------
    {
        my $t0 = time();
        my ($logfile, $pidfile, $fh, $dir) = spawn_keepawake(simulate_failure => 1);

        my $winpid = wait_for_pidfile_winpid($pidfile, 15);
        push @LIVE_WINPIDS, $winpid if defined $winpid;
        ok(defined($winpid), 'AC4: pidfile appears with a numeric WINPID (simulated-failure run)')
            or diag("log so far:\n" . slurp_log($logfile));

        my $got_degraded = wait_for_log_event(
            $logfile, qr/POWER-REQUEST-DEGRADED\s+reason=simulated-failure/, 15);
        ok($got_degraded, 'AC4: POWER-REQUEST-DEGRADED reason=simulated-failure appears in the log')
            or diag("log so far:\n" . slurp_log($logfile));

        # behavior 2: ASSERTED must appear before POWER-REQUEST-DEGRADED.
        SKIP: {
            skip 'no POWER-REQUEST-DEGRADED line to order against', 1 unless $got_degraded;
            my $log = slurp_log($logfile);
            my $asserted_pos = index($log, 'ASSERTED');
            my $degraded_pos = index($log, 'POWER-REQUEST-DEGRADED');
            ok($asserted_pos >= 0 && $degraded_pos > $asserted_pos,
                'behavior 2: ASSERTED precedes POWER-REQUEST-DEGRADED in the log');
        }

        # Proves degrade, not abort: the process must still be alive right
        # after the degrade line appears -- it did NOT exit early, and did
        # NOT exit non-zero because of it.
        ok(defined($winpid) && tasklist_shows_alive($winpid),
            'AC4: process is still alive after POWER-REQUEST-DEGRADED (did not abort)');

        # AC6: deliberate release on a degraded run -- RELEASE then EXIT,
        # with NO POWER-REQUEST-RELEASED line (guarded no-op per 2.5).
        unlink $pidfile;

        my $got_exit = wait_for_log_event($logfile, qr/\bEXIT\b/, 20);
        ok($got_exit, 'AC6: EXIT line appears after pidfile deletion on a degraded run')
            or diag("log so far:\n" . slurp_log($logfile));

        my $log_after = slurp_log($logfile);
        unlike($log_after, qr/POWER-REQUEST-RELEASED/,
            'AC6: POWER-REQUEST-RELEASED does NOT appear on a degraded run (guarded no-op)');

        like($log_after, qr/RELEASE/,
            'AC6: RELEASE line still appears on a degraded run');

        SKIP: {
            skip 'ordering check requires RELEASE and EXIT both present', 1
                unless $got_exit;
            my $release_pos = index($log_after, 'RELEASE');
            my $last_exit_pos = -1;
            {
                my $pos = -1;
                while (($pos = index($log_after, 'EXIT', $pos + 1)) >= 0) {
                    $last_exit_pos = $pos;
                }
            }
            ok($release_pos >= 0 && $last_exit_pos > $release_pos,
                'AC6: log order is RELEASE ... EXIT (no POWER-REQUEST-RELEASED in between)');
        }

        my $gone = 0;
        my $wait_deadline = time() + 10;
        while (time() < $wait_deadline) {
            if (!defined($winpid) || !tasklist_shows_alive($winpid)) { $gone = 1; last; }
            sleep(0.25);
        }
        ok($gone, 'AC6: process is gone (or was never confirmed alive) within bounded wait')
            or diag('winpid still listed by tasklist after wait');

        force_kill_if_alive($winpid) if defined $winpid;
        close $fh;

        cmp_ok(time() - $t0, '<', 30, 'AC4/AC6 sub-test completed within the 30s wall-clock ceiling');
    }
    # ---- fix-batch 02: -SimulatePowerRequestException path ----------------
    # Reproduces the redteam-01.md MEDIUM finding directly: PowerCreateRequest
    # runs for real (a real, live OS handle exists), then PowerSetRequest is
    # simulated as THROWING (not returning $false). Before the fix, the
    # catch block never referenced $handle, so this real handle would leak
    # silently. After the fix, the catch block closes it and logs
    # handle-closed=true -- that log line is the observable proof (from
    # outside the process, with no elevation available to inspect the OS
    # handle table directly) that the close actually happened.
    {
        my $t0 = time();
        my ($logfile, $pidfile, $fh, $dir) = spawn_keepawake(simulate_exception => 1);

        my $winpid = wait_for_pidfile_winpid($pidfile, 15);
        push @LIVE_WINPIDS, $winpid if defined $winpid;
        ok(defined($winpid), 'fixbatch-02: pidfile appears with a numeric WINPID (simulated-exception run)')
            or diag("log so far:\n" . slurp_log($logfile));

        my $got_degraded = wait_for_log_event(
            $logfile, qr/POWER-REQUEST-DEGRADED\s+reason=exception:.*handle-closed=true/, 15);
        ok($got_degraded,
            'fixbatch-02: POWER-REQUEST-DEGRADED reason=exception...handle-closed=true appears (the leak is closed)')
            or diag("log so far:\n" . slurp_log($logfile));

        # Proves degrade, not abort: same shape as the AC4 assertion above.
        ok(defined($winpid) && tasklist_shows_alive($winpid),
            'fixbatch-02: process is still alive after the simulated-exception degrade (did not abort)');

        # Release on a degraded run: RELEASE then EXIT, no POWER-REQUEST-RELEASED
        # (the handle was never assigned to $script:PowerRequestHandle, so the
        # finally block's guard correctly no-ops -- it was already closed in
        # the catch block above, not here).
        unlink $pidfile;

        my $got_exit = wait_for_log_event($logfile, qr/\bEXIT\b/, 20);
        ok($got_exit, 'fixbatch-02: EXIT line appears after pidfile deletion on a simulated-exception run')
            or diag("log so far:\n" . slurp_log($logfile));

        my $log_after = slurp_log($logfile);
        unlike($log_after, qr/POWER-REQUEST-RELEASED/,
            'fixbatch-02: POWER-REQUEST-RELEASED does NOT appear (handle was already closed in the catch block, not the finally block)');

        my $gone = 0;
        my $wait_deadline = time() + 10;
        while (time() < $wait_deadline) {
            if (!defined($winpid) || !tasklist_shows_alive($winpid)) { $gone = 1; last; }
            sleep(0.25);
        }
        ok($gone, 'fixbatch-02: process is gone (or was never confirmed alive) within bounded wait')
            or diag('winpid still listed by tasklist after wait');

        force_kill_if_alive($winpid) if defined $winpid;
        close $fh;

        cmp_ok(time() - $t0, '<', 30, 'fixbatch-02 sub-test completed within the 30s wall-clock ceiling');
    }
}

# AC7 [DC1/DC2/DC4, manual -- spec section 6 / Decision 8]: an elevated
# `powercfg /requests` capture before and after a lock/release cycle,
# confirming the EXECUTION row names the process and DISPLAY/SYSTEM are
# unchanged. This is explicitly NOT automatable (elevation cannot be
# granted unattended) and is not asserted anywhere in this file by design.
# The operator must paste both `powercfg /requests` outputs into the
# package ledger's ## Outputs section before this package can move to done.

done_testing();
