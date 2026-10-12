#!/usr/bin/env perl
# platform: windows
# THE ORACLE for blueprint sandbox-launcher-lifecycle, package
# 01-launcher-and-its-terminal, written from
#   .ccpraxis-local-data/blueprints/sandbox-launcher-lifecycle/specs/01-launcher-and-its-terminal-spec.md
# BEFORE the implementation exists.
#
# WHY THIS FILE EXISTS. launcher.pl opens a Windows Terminal window via a
# fire-and-forget wt.exe spawn with no pid captured anywhere (launcher.pl:8791).
# A full, correct teardown chain already exists and runs on INT/TERM/HUP -- but
# HUP is not reliably delivered when the terminal window itself is destroyed on
# Windows. Report 20260917-032028-b91b measured two launchers surviving 37 hours
# after their terminals were gone, still rendering into consoles they no longer
# owned. This package makes the launcher notice its console host is gone and run
# the SAME teardown the TERM handler already runs.
#
# WHY A SENTINEL-DELIMITED EVAL REGION. launcher.pl is NEVER require'd/do'ne by
# this suite -- it is a top-level script with real side effects (raw-mode
# terminal, live subprocess launch, blocking keypress) and cannot be safely
# executed by a test. The house technique (precedent: wt-profile-spawn.t:18-26,
# itself precedented by container-health-detect.t) is to slurp launcher.pl as
# SOURCE TEXT, locate a sentinel-delimited region, and eval just that region
# into a fresh package. self_winpid / console_host_winpid / winpid_alive are
# pure, seam-driven functions precisely so this is possible: the production
# path and the tested path are the same subs, never a parallel reimplementation.
#
# WHAT IS EXPECTED TO FAIL TODAY. The 'console-liveness:BEGIN'/'console-liveness:END'
# sentinel comments do not exist in launcher.pl yet, _teardown_and_exit does not
# exist yet (INT/TERM are still inline one-liner subs), and
# $CONSOLE_LIVENESS_POLL_SECONDS / the gather-round wiring do not exist yet.
# Every assertion that depends on those is EXPECTED to report "not ok" until
# this package is implemented. Do not weaken any assertion below to make that
# future implementation's life easier.
#
# REAL-PROCESS SAFETY (AC-1 / AC-3). Two tests below spawn a real, native,
# console-owning cmd.exe child -- never wt.exe, never the full sandbox launch
# path (Decision 7 / this package's ledger explicitly forbids spawning
# launcher.pl's own image-build/container-start path unguarded). Every spawn is
# tracked in @SPAWNED_WINPIDS and force-killed in an END block, so a failed run
# (assertion death, BAIL_OUT, or an unexpected die) never leaves an orphaned
# console process behind. Poll loops are bounded by wall-clock elapsed time, not
# alarm(), so a hung backtick call cannot leave state half-updated.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $LAUNCHER      = "$SCRIPTS_DIR/launcher.pl";
my $WTPROFILE_PM  = "$SCRIPTS_DIR/WtProfile.pm";
my $DASHBOARD_PM  = "$SCRIPTS_DIR/Dashboard.pm";
my $MINIMIZE_DOC  = "$Bin/../../docs/terminal-minimize-investigation.md";

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

my $SRC = slurp($LAUNCHER);
ok(defined($SRC) && length($SRC), 'prereq: launcher.pl source read as text (never require/do-ed)')
    or BAIL_OUT("cannot read $LAUNCHER");

# =============================================================================
# CLEANUP HARNESS -- shared by AC-1 and AC-3. Never left running, even on
# assertion failure or an early die elsewhere in this file.
# =============================================================================
my @SPAWNED_WINPIDS;

# _taskkill_winpid($wp) -- portability fix alongside spawn_console_process's
# (2026-09-18). The single-string form `system("taskkill /PID $wp /F ...")`
# goes through this host's MSYS shell layer, which treats the bare `/PID`
# argument as a POSIX-style path and rewrites it (observed: `/PID` became
# `C:/Program Files/Git/PID`, so real taskkill.exe rejected it as an unknown
# option and never killed anything) -- the same MSYS argv-mangling landmine
# documented for `-v HOST:CONTAINER`, just triggered by a leading `/` instead
# of an embedded `:`. List-form system() alone does not avoid it (confirmed
# empirically: the same rewrite happens with `system('taskkill','/PID',...)`
# too), so both the shell-string route and plain list-form are unsafe here.
# Fix: scope $ENV{MSYS2_ARG_CONV_EXCL}='*' to this one call (CLAUDE.md's
# documented safe pattern -- never set shell-wide) so the native taskkill.exe
# argv reaches it unmangled; verified against a real spawned+killed process.
sub _taskkill_winpid {
    my ($wp) = @_;
    return unless defined $wp && $wp =~ /^\d+$/;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    open(my $saved_out, '>&', \*STDOUT) or return;
    open(my $saved_err, '>&', \*STDERR) or return;
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
    system('taskkill', '/PID', $wp, '/F');
    open(STDOUT, '>&', $saved_out);
    open(STDERR, '>&', $saved_err);
}

END {
    for my $wp (@SPAWNED_WINPIDS) {
        _taskkill_winpid($wp);
    }
}

# spawn_console_process() -> ($msys_pid, $winpid) | (undef, undef)
# Spawns a plain, distinct, native cmd.exe that owns its own console and stays
# alive for ~2 minutes (ping as a portable sleep with no extra tooling). NOT
# wt.exe, NOT conhost.exe directly, NOT the sandbox launch path.
#
# PORTABILITY NOTE (fixed 2026-09-18). The original implementation used
# Perl's Win32-only asynchronous-spawn calling convention, system(1, LIST)
# (perlport) to get the pid back immediately without waiting. That form is
# recognized ONLY on native MSWin32 Perl builds; this host runs Cygwin-
# flavored perl ($^O eq 'cygwin'), where system(1, LIST) is not special-cased
# at all -- it silently falls through and nothing is spawned, so both
# assertions that depend on this helper (AC-1, AC-3) failed with an
# empty/undef WINPID before ever reaching the winpid_alive/console_host_winpid
# code under test. Confirmed empirically (not by inspection alone) that
# system(1, @cmd) returns undef and spawns no process on this host.
#
# Fix: use `powershell.exe Start-Process -PassThru`, which does the real
# work here -- allocates cmd.exe its own native console window (started
# MINIMIZED since 2026-10-12: a minimized window still owns a real console, so
# AC-1/AC-3 hold, and a sweep no longer pops focus-stealing windows on the
# operator's desktop -- bug 20261012-030623-74af), returns immediately without waiting for the child to exit, and
# hands back the child's real Win32 PID (== WINPID) directly via .Id, with
# no msys-pid-to-WINPID resolution step needed at all. This is portable
# across both native-Windows and Cygwin perl (it shells out to a real
# powershell.exe process either way) and was verified empirically: the
# spawned process shows Name=cmd.exe with a distinct ParentProcessId via
# Get-CimInstance, and a subsequent taskkill /PID <id> /F followed by the
# same CIM query returns no rows.
sub spawn_console_process {
    my $marker = 'ccpx_console_liveness_test_' . $$ . '_' . time();
    my $inner  = "title $marker & ping -n 90 127.0.0.1 >NUL";
    my $ps = q{powershell.exe -NoProfile -NonInteractive -Command }
           . qq{"(Start-Process -FilePath cmd.exe -ArgumentList '/c','$inner' -WindowStyle Minimized -PassThru).Id"};
    my $raw = `$ps 2>/dev/null`;
    my $exec_ok = ($? != -1);
    return (undef, undef) unless $exec_ok && defined $raw;

    ($raw) = $raw =~ /(\d+)/;
    my $winpid = $raw;
    return (undef, undef) unless defined($winpid) && $winpid =~ /^\d+$/;

    push @SPAWNED_WINPIDS, $winpid;
    # no MSYS pid is produced by this spawn mechanism -- the WINPID is
    # captured directly from Start-Process, never resolved from one.
    return (undef, $winpid);
}

# real_cim_probe_seam($winpid) -> a cim_probe seam using the EXACT pinned
# command shape from spec 2.2, with NO seam substitution -- this is the real
# powershell.exe invocation, not a stub, which is what makes AC-1/AC-3 a proof
# rather than an inference from source.
sub real_cim_probe_seam {
    my ($winpid) = @_;
    return sub {
        my $ps = q{powershell.exe -NoProfile -NonInteractive -Command }
               . qq{"Get-CimInstance Win32_Process -Filter 'ProcessId=$winpid' -ErrorAction SilentlyContinue | Select-Object ProcessId,Name | ConvertTo-Json -Compress -Depth 3"};
        my $raw = `$ps 2>/dev/null`;
        my $exec_ok = ($? != -1);
        return ($exec_ok ? $raw : undef, $exec_ok);
    };
}

# =============================================================================
# AC-7 -- region purity, extraction (supports all other ACs' testability)
# =============================================================================
my $BEGIN_SENTINEL = '# >>> console-liveness:BEGIN';
my $END_SENTINEL   = '# <<< console-liveness:END';
my ($begin_idx, $end_idx, $region);
{
    my $begin_count = () = $SRC =~ /\Q$BEGIN_SENTINEL\E/g;
    my $end_count   = () = $SRC =~ /\Q$END_SENTINEL\E/g;
    is($begin_count, 1, "AC-7: sentinel '$BEGIN_SENTINEL' occurs exactly once in launcher.pl");
    is($end_count, 1,   "AC-7: sentinel '$END_SENTINEL' occurs exactly once in launcher.pl");
    $begin_idx = index($SRC, $BEGIN_SENTINEL);
    $end_idx   = index($SRC, $END_SENTINEL);
    ok(($begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx),
        'AC-7: sentinel BEGIN appears before END');
    ($region) = $SRC =~ /\Q$BEGIN_SENTINEL\E.*?\n(.*?)\Q$END_SENTINEL\E/s
        if $begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx;
}

my ($SELF_WINPID, $CONSOLE_HOST_WINPID, $WINPID_ALIVE);
if (!defined $region) {
    ok(0, 'AC-7: the console-liveness:BEGIN/END region evals cleanly into a fresh package (region not found -- not yet implemented)');
    ok(0, "AC-7: the resulting package ->can('self_winpid') (region not found)");
    ok(0, "AC-7: the resulting package ->can('console_host_winpid') (region not found)");
    ok(0, "AC-7: the resulting package ->can('winpid_alive') (region not found)");
} else {
    my $harness = "package ConsoleLiveness;\nuse strict;\nuse warnings;\n" . $region . "\n1;\n";
    my $eval_ok = eval $harness;   ## no critic
    my $eval_err = $@;
    ok($eval_ok, 'AC-7: the console-liveness:BEGIN/END region evals cleanly into a fresh package under use strict/warnings')
        or diag("eval error: $eval_err");
    if ($eval_ok) {
        $SELF_WINPID        = ConsoleLiveness->can('self_winpid');
        $CONSOLE_HOST_WINPID = ConsoleLiveness->can('console_host_winpid');
        $WINPID_ALIVE        = ConsoleLiveness->can('winpid_alive');
        ok(defined $SELF_WINPID,         "AC-7: the resulting package ->can('self_winpid')");
        ok(defined $CONSOLE_HOST_WINPID, "AC-7: the resulting package ->can('console_host_winpid')");
        ok(defined $WINPID_ALIVE,        "AC-7: the resulting package ->can('winpid_alive')");
    } else {
        ok(0, "AC-7: the resulting package ->can('self_winpid') (region failed to eval)");
        ok(0, "AC-7: the resulting package ->can('console_host_winpid') (region failed to eval)");
        ok(0, "AC-7: the resulting package ->can('winpid_alive') (region failed to eval)");
    }
}

# ---- AC-7: region purity, checked whether or not it evaluated cleanly ----
if (!defined $region) {
    ok(0, 'AC-7: region purity (region not found)') for 1 .. 9;
} else {
    unlike($region, qr/\bsystem\s*\(/, 'AC-7: region has no live-subprocess call');
    unlike($region, qr/\x60/,          'AC-7: region has no backtick character');
    unlike($region, qr/\bexit\s*\(/,   'AC-7: region has no literal exit(');
    unlike($region, qr/\bprint\b/,     'AC-7: region has no print');
    unlike($region, qr/\blog_ev\b/,    'AC-7: region has no log_ev call');
    unlike($region, qr/\bDashboard::/, 'AC-7: region has no Dashboard:: reference');
    unlike($region, qr/\bWtProfile::/, 'AC-7: region has no WtProfile:: reference');
    unlike($region, qr/\$ENV\{/,       'AC-7: region has no $ENV{ reference');
    unlike($region, qr/\bdie\b/,       'AC-7: region has no literal die keyword');
}

# =============================================================================
# AC-6 -- seam-injected unit tests on all three sentinel-region functions.
# =============================================================================

# ---- self_winpid ----
SKIP: {
    skip 'AC-6/self_winpid: not available -- not yet implemented', 18
        unless defined $SELF_WINPID;

    # NOTE: fixtures below use the REAL 8-column `ps -W` header this host's
    # Cygwin/Git-for-Windows ps actually prints -- "PID PPID PGID WINPID TTY
    # UID STIME COMMAND" -- verified live against `ps -W | head`. A pre-fix
    # bug read column index 2 (PGID) believing it was WINPID; every fixture
    # here deliberately gives PGID a value distinct from both PID and WINPID
    # so an implementation that regresses to the old hardcoded index fails
    # loudly instead of passing vacuously.
    my $HDR = "      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n";

    {
        my $raw = $HDR
                . "832282       1  223010     159020   ?         197609 22:36:17 /usr/bin/perl\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 832282 },
        );
        is($wp, 159020, 'AC-6: self_winpid matching row returns the WINPID column');
        is($reason, 'ok', 'AC-6: self_winpid matching row reason is ok');
    }
    {
        my $raw = $HDR
                . "111111       1  333333     222222   ?         197609 22:36:17 /usr/bin/perl\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 999999 },
        );
        is($wp, undef, 'AC-6: self_winpid with no matching row returns undef');
        is($reason, 'no-matching-row', 'AC-6: self_winpid no-matching-row reason');
    }
    {
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { '' }, self_pid => sub { 100 },
        );
        is($wp, undef, 'AC-6: self_winpid with empty ps_w output returns undef');
        is($reason, 'ps-w-unavailable', 'AC-6: self_winpid empty-output reason');
    }
    {
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { undef }, self_pid => sub { 100 },
        );
        is($wp, undef, 'AC-6: self_winpid with undef ps_w seam result returns undef');
        is($reason, 'ps-w-unavailable', 'AC-6: self_winpid undef-seam reason');
    }
    {
        my $raw = $HDR
                . "100       1  777     abc   ?         197609 22:36:17 /usr/bin/perl\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 100 },
        );
        is($wp, undef, 'AC-6: self_winpid with non-numeric WINPID column returns undef');
        is($reason, 'winpid-not-numeric', 'AC-6: self_winpid non-numeric-WINPID reason');
    }
    {
        # no WINPID column at all (fabricated degenerate header) -- must
        # fail safe rather than guess a wrong index.
        my $raw = "      PID    PPID    PGID     TTY         UID    STIME COMMAND\n"
                . "100       1  777     ?         197609 22:36:17 /usr/bin/perl\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 100 },
        );
        is($wp, undef, 'AC-6: self_winpid with no WINPID column in header returns undef');
        is($reason, 'winpid-column-not-found', 'AC-6: self_winpid missing-WINPID-column reason');
    }
    {
        # redteam-02 repro: header (line 0) is missing WINPID entirely, but a
        # DATA row's COMMAND field happens to contain the literal token
        # "WINPID" -- a column-discovery loop not confined to the header row
        # could coincidentally match that token in the data row and produce
        # a wrong index instead of failing safe. Must still return undef.
        my $raw = "      PID    PPID    PGID     TTY         UID    STIME COMMAND\n"
                . "100       1  777     ?         197609 22:36:17 /usr/bin/grep WINPID foo.log\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 100 },
        );
        is($wp, undef, 'AC-6/redteam-02: COMMAND field containing literal WINPID token does not fool column discovery');
        is($reason, 'winpid-column-not-found', 'AC-6/redteam-02: reason is still winpid-column-not-found, not a coincidental match');
    }

    # ---- AC-4(a) -- pid namespace never crossed, distinct PID/PGID/WINPID fixtures ----
    {
        my $raw = $HDR
                . "100       1  555     999   ?         197609 22:36:17 /usr/bin/perl\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 100 },
        );
        is($wp, 999, 'AC-4(a): self_winpid returns the WINPID column (999), not the PGID (555)');
        isnt($wp, 100, 'AC-4(a): self_winpid never returns the matched PID column (100)');
    }
    {
        # a second, disjoint fixture: swap which value is larger, to rule out
        # an implementation that just returns "the bigger number" by accident,
        # AND makes PGID equal to PID -- the exact real-world shape from the
        # redteam report (PGID == self pid for a process-group leader) that
        # caused the original bug to silently return the matched PID's own
        # value instead of failing.
        my $raw = $HDR
                . "500000       1  500000     12   ?         197609 22:36:17 /usr/bin/perl\n";
        my ($wp, $reason) = $SELF_WINPID->(
            ps_w => sub { $raw }, self_pid => sub { 500000 },
        );
        is($wp, 12, 'AC-4(a): self_winpid returns the WINPID column (12) even when PGID == PID');
        isnt($wp, 500000, 'AC-4(a): self_winpid never returns the raw self_pid() input (500000)');
    }
}

# ---- console_host_winpid ----
sub _json_encode { return JSON::PP->new->canonical->encode($_[0]) }

# wraps the call with a bounded, non-alarm-based watchdog is unnecessary here
# (the function is pure and seam-driven -- no I/O to hang on), but a buggy
# not-yet-written implementation could still loop; guard with alarm() as a
# pure defensive measure so a runaway future implementation cannot hang this
# suite forever.
sub call_console_host {
    my (@args) = @_;
    my @result;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "console_host_winpid did not return within 5s (unbounded loop?)\n" };
        alarm(5);
        @result = $CONSOLE_HOST_WINPID->(@args);
        alarm(0);
        1;
    };
    alarm(0);
    diag("console_host_winpid died: $@") unless $ok;
    return @result;
}

SKIP: {
    skip 'AC-6/console_host_winpid: not available -- not yet implemented', 12
        unless defined $CONSOLE_HOST_WINPID;

    # host at hop 1: self(500)'s immediate parent (400) is conhost.exe
    {
        my $json = _json_encode([
            { ProcessId => 500, ParentProcessId => 400, Name => 'perl.exe' },
            { ProcessId => 400, ParentProcessId => 1,   Name => 'conhost.exe' },
        ]);
        my ($host, $reason) = call_console_host(500, cim_ancestry => sub { $json });
        is($host, 400, 'AC-6: console_host_winpid finds the console host at hop 1');
        is($reason, 'ok', 'AC-6: console_host_winpid hop-1 reason is ok');
    }

    # host at hop N>1 (hop 2): immediate parent is a plain perl.exe, grandparent
    # is WindowsTerminal.exe
    {
        my $json = _json_encode([
            { ProcessId => 500, ParentProcessId => 450, Name => 'perl.exe' },
            { ProcessId => 450, ParentProcessId => 400, Name => 'perl.exe' },
            { ProcessId => 400, ParentProcessId => 1,   Name => 'WindowsTerminal.exe' },
        ]);
        my ($host, $reason) = call_console_host(500, cim_ancestry => sub { $json });
        is($host, 400, 'AC-6: console_host_winpid finds the console host at hop N>1 (hop 2)');
    }

    # nearest, not farthest: two console-host-named processes in the chain
    {
        my $json = _json_encode([
            { ProcessId => 500, ParentProcessId => 450, Name => 'perl.exe' },
            { ProcessId => 450, ParentProcessId => 400, Name => 'OpenConsole.exe' },
            { ProcessId => 400, ParentProcessId => 1,   Name => 'WindowsTerminal.exe' },
        ]);
        my ($host, $reason) = call_console_host(500, cim_ancestry => sub { $json });
        is($host, 450, 'AC-6/edge-case: console_host_winpid returns the NEAREST console-host match, not the farthest');
    }

    # chain exhausted, no match anywhere
    {
        my $json = _json_encode([
            { ProcessId => 500, ParentProcessId => 450, Name => 'perl.exe' },
            { ProcessId => 450, ParentProcessId => 999, Name => 'perl.exe' },
            # 999 is deliberately absent -- the chain ends with no console host.
        ]);
        my ($host, $reason) = call_console_host(500, cim_ancestry => sub { $json });
        is($host, undef, 'AC-6: console_host_winpid with an exhausted chain returns undef');
        is($reason, 'no-console-host-in-chain', 'AC-6: exhausted-chain reason');
    }

    # malformed JSON
    {
        my ($host, $reason) = call_console_host(500, cim_ancestry => sub { '{not valid json' });
        is($host, undef, 'AC-6: console_host_winpid with malformed JSON returns undef');
        is($reason, 'cim-parse-failed', 'AC-6: malformed-JSON reason');
    }

    # cim_ancestry seam returns undef (exec failure)
    {
        my ($host, $reason) = call_console_host(500, cim_ancestry => sub { undef });
        is($host, undef, 'AC-6: console_host_winpid with cim_ancestry returning undef returns undef');
        is($reason, 'cim-query-failed', 'AC-6: cim_ancestry-undef reason');
    }

    # cycle / >64-hop chain: bounded, never loops forever, and reports
    # no-console-host-in-chain rather than hanging (edge case, section 5).
    {
        my @rows;
        for my $i (0 .. 70) {
            push @rows, { ProcessId => $i, ParentProcessId => $i + 1, Name => 'perl.exe' };
        }
        # close the cycle so an unguarded walk would loop forever.
        push @rows, { ProcessId => 71, ParentProcessId => 0, Name => 'perl.exe' };
        my $json = _json_encode(\@rows);
        my ($host, $reason) = call_console_host(0, cim_ancestry => sub { $json });
        is($host, undef, 'AC-6/edge-case: console_host_winpid on a cyclical/>64-hop chain returns undef rather than hanging');
        is($reason, 'no-console-host-in-chain', 'AC-6/edge-case: bounded-walk reason');
    }

    # ---- AC-4(c) -- WINPID space only, never mixing in $self_winpid's own
    # value except as the walk's starting key. Here self_winpid=999 does NOT
    # appear anywhere in the ancestry data itself; if the implementation ever
    # substituted the self_winpid argument's value for a real ProcessId/
    # ParentProcessId lookup, this walk would falsely "succeed" against
    # fabricated data instead of correctly reporting no match.
    {
        my $json = _json_encode([
            { ProcessId => 500, ParentProcessId => 400, Name => 'perl.exe' },
            { ProcessId => 400, ParentProcessId => 1,   Name => 'conhost.exe' },
        ]);
        my ($host, $reason) = call_console_host(999, cim_ancestry => sub { $json });
        is($host, undef,
            "AC-4(c): console_host_winpid(999, ...) against ancestry data that does not contain 999 "
            . "anywhere finds no match -- self_winpid is used only as the walk's starting key, never "
            . "substituted into the WINPID-space data itself");
        is($reason, 'no-console-host-in-chain', 'AC-4(c): reason for the non-matching starting key');
    }
}

# ---- winpid_alive ----
SKIP: {
    skip 'AC-6/winpid_alive: not available -- not yet implemented', 10
        unless defined $WINPID_ALIVE;

    {
        my $json = _json_encode({ ProcessId => 12345, Name => 'conhost.exe' });
        my $verdict = $WINPID_ALIVE->(12345, cim_probe => sub { ($json, 1) });
        is($verdict, 'alive', 'AC-6: winpid_alive with exactly one matching process returns alive');
    }
    {
        my $verdict = $WINPID_ALIVE->(12345, cim_probe => sub { ('', 1) });
        is($verdict, 'gone', 'AC-6: winpid_alive with zero matches and exec_ok true returns gone');
    }
    {
        my $verdict = $WINPID_ALIVE->(12345, cim_probe => sub { (undef, 0) });
        is($verdict, 'unknown', 'AC-6: winpid_alive with exec_ok false returns unknown');
    }
    {
        my $verdict = $WINPID_ALIVE->(12345, cim_probe => sub { ('{not valid json', 1) });
        is($verdict, 'unknown', 'AC-6: winpid_alive with malformed JSON returns unknown');
    }
    {
        # exec_ok true but raw undef -- still must NOT collapse into 'gone'.
        my $verdict = $WINPID_ALIVE->(12345, cim_probe => sub { (undef, 1) });
        is($verdict, 'unknown', 'AC-6: winpid_alive with raw undef (even if exec_ok true) returns unknown, never gone');
    }
    {
        # whitespace-only raw with exec_ok true is still "zero matches" -> gone.
        my $verdict = $WINPID_ALIVE->(12345, cim_probe => sub { ("   \n", 1) });
        is($verdict, 'gone', 'AC-6: winpid_alive with whitespace-only raw and exec_ok true returns gone');
    }
}

# =============================================================================
# AC-1 (DC-1, bounded exit against a real console)
# =============================================================================
SKIP: {
    skip 'AC-1: winpid_alive not available -- not yet implemented', 5
        unless defined $WINPID_ALIVE;

    my ($msys_pid, $winpid) = spawn_console_process();
    ok(defined($winpid), 'AC-1 prereq: a real, distinct console-owning cmd.exe child was spawned and its WINPID resolved')
        or diag("could not resolve a WINPID for the spawned console process (msys_pid=" . (defined $msys_pid ? $msys_pid : 'undef') . ')');

  SKIP: {
        skip 'AC-1: could not spawn/resolve a real console process to test against', 4
            unless defined $winpid;

        my $verdict_before = $WINPID_ALIVE->($winpid, cim_probe => real_cim_probe_seam($winpid));
        is($verdict_before, 'alive',
            'AC-1: winpid_alive() reports alive for the real WINPID, using the pinned command shape with NO seam substitution');

        _taskkill_winpid($winpid);

        my $deadline = time() + 30;
        my $verdict_after = 'alive';
        while (time() < $deadline) {
            $verdict_after = $WINPID_ALIVE->($winpid, cim_probe => real_cim_probe_seam($winpid));
            last if $verdict_after eq 'gone';
            select(undef, undef, undef, 1);
        }
        is($verdict_after, 'gone',
            'AC-1: after taskkill /PID <winpid> /F, winpid_alive() reports gone within the 30s bound');

        ok((time() < $deadline || $verdict_after eq 'gone'),
            'AC-1: the gone verdict was observed within the 30s window (Decision 7 bound)');

        # this WINPID is already dead; remove it from the cleanup list so the
        # END block does not waste a taskkill call against a pid that is
        # already gone (harmless either way, but keeps the cleanup log honest).
        @SPAWNED_WINPIDS = grep { !defined($winpid) || $_ ne $winpid } @SPAWNED_WINPIDS;
    }
}

# =============================================================================
# AC-3 (DC-3, false-positive guard, asserted separately from AC-1)
# A SEPARATE spawned process, never killed, polled across >=3 samples over
# >=10s -- every verdict must be 'alive'.
# =============================================================================
SKIP: {
    skip 'AC-3: winpid_alive not available -- not yet implemented', 4
        unless defined $WINPID_ALIVE;

    my ($msys_pid, $winpid) = spawn_console_process();
    ok(defined($winpid), 'AC-3 prereq: a second, distinct, real console-owning cmd.exe child was spawned (never killed by this test)')
        or diag('could not resolve a WINPID for the AC-3 spawned console process');

  SKIP: {
        skip 'AC-3: could not spawn/resolve a real console process to test against', 3
            unless defined $winpid;

        my @verdicts;
        my $start = time();
        while (time() - $start < 10 || @verdicts < 3) {
            push @verdicts, $WINPID_ALIVE->($winpid, cim_probe => real_cim_probe_seam($winpid));
            last if @verdicts >= 3 && time() - $start >= 10;
            select(undef, undef, undef, 3) if @verdicts < 3 || time() - $start < 10;
            last if @verdicts > 10;   # safety valve, should never trigger
        }

        ok(scalar(@verdicts) >= 3, 'AC-3: at least 3 samples were taken (found ' . scalar(@verdicts) . ')');
        ok((time() - $start) >= 10, 'AC-3: samples were taken over at least 10 seconds');
        my @not_alive = grep { $_ ne 'alive' } @verdicts;
        is(scalar(@not_alive), 0,
            'AC-3: a launcher whose console is alive is NEVER reaped -- every sampled verdict is alive, none gone/unknown (got: '
            . join(',', @verdicts) . ')');
    }
}

# =============================================================================
# AC-2 (DC-2, exact teardown path fires) -- source-pattern assertions.
# Mirrors reap-orphans.t's NS1-NS6 style: this asserts SOURCE, not behavior,
# because a live TERM/HUP delivery test would itself kill this test process.
# =============================================================================
{
    my $sub_count = () = $SRC =~ /\bsub\s+_teardown_and_exit\b/g;
    is($sub_count, 1, 'AC-2(a): exactly one sub named _teardown_and_exit exists');

    my ($body) = $SRC =~ /sub\s+_teardown_and_exit\s*\{(.*?)\r?\n\}/s;
    ok(defined $body, 'AC-2(b) prereq: _teardown_and_exit has an extractable body')
        or diag('_teardown_and_exit not found -- expected until this package is implemented');

  SKIP: {
        skip 'AC-2(b): _teardown_and_exit body not extractable', 7 unless defined $body;

        my @required_calls_in_order = qw(
            _keepawake_release_global
            _resources_sampler_release_global
            _spend_sampler_release_global
            _container_sampler_release_global
            SandboxLock::release_all
            reset_terminal
        );
        my @positions;
        for my $call (@required_calls_in_order) {
            my $idx = index($body, $call);
            push @positions, $idx;
            ok($idx >= 0, "AC-2(b): _teardown_and_exit body calls $call");
        }
        my $in_order = 1;
        for my $i (1 .. $#positions) {
            $in_order = 0 if $positions[$i] < 0 || $positions[$i - 1] < 0 || $positions[$i] <= $positions[$i - 1];
        }
        ok($in_order, 'AC-2(b): the six required calls appear in the documented relative order');
    }

    like($SRC, qr/\$SIG\{TERM\}\s*=\s*sub\s*\{\s*_teardown_and_exit\(/,
        'AC-2(c): $SIG{TERM} = sub { _teardown_and_exit(...) invokes the named sub, not a copy');
    like($SRC, qr/if\s*\(\s*\$verdict\s+eq\s+'gone'\s*\)\s*\{\s*_teardown_and_exit\(/,
        "AC-2(c): the console-liveness poll's if (\$verdict eq 'gone') { _teardown_and_exit(...) invokes the same named sub");
}

# =============================================================================
# AC-4(b) -- pid namespace never crossed: no $$ or getppid() anywhere in the
# new arming/polling/teardown-trigger code. Scoped to the console-liveness
# sentinel region (already covered by AC-7's own purity check for I/O in
# general) PLUS the production wiring code around it (2.3's arming block and
# the gather-round poll), since those live OUTSIDE the sentinel region and are
# exactly where a real self_pid seam gets bound -- the one place `$$` is
# legitimately allowed to appear is as the VALUE handed into the self_pid seam
# closure itself (2.3: `self_pid => sub { $$ }`), so this check targets the
# arming block specifically, not the whole file (which legitimately uses $$
# elsewhere, e.g. in log paths unrelated to this feature).
# =============================================================================
{
    my ($arming_block) = $SRC =~ /(my\s+\$CONSOLE_HOST_WINPID;.*?)(?=\n\S|\z)/s;
    ok(defined $arming_block,
        'AC-4(b) prereq: the $CONSOLE_HOST_WINPID arming block is extractable')
        or diag('arming block not found -- expected until this package is implemented');

  SKIP: {
        skip 'AC-4(b): arming block not extractable', 2 unless defined $arming_block;

        unlike($arming_block, qr/getppid\s*\(/,
            'AC-4(b): the arming/polling code never calls getppid() -- the pid-namespace rule');

        # self_pid => sub { $$ } is the one legitimate, spec-pinned use of $$ in
        # this block (2.3) -- outside that exact seam binding, no other $$
        # reference should appear in the arming code.
        (my $scrubbed = $arming_block) =~ s/self_pid\s*=>\s*sub\s*\{\s*\$\$\s*\}/self_pid => sub { SEAM_PID }/;
        unlike($scrubbed, qr/\$\$/,
            'AC-4(b): no bare $$ reference in the arming code outside the one pinned self_pid seam binding');
    }
}

# =============================================================================
# AC-5 (DC-5, ba38 closure, concrete)
# =============================================================================
{
    my $wt_src  = slurp($WTPROFILE_PM);
    my $dash_src = slurp($DASHBOARD_PM);
    ok(defined($wt_src) && length($wt_src), 'AC-5(a) prereq: WtProfile.pm is readable')
        or diag("cannot read $WTPROFILE_PM");
    ok(defined($dash_src) && length($dash_src), 'AC-5(a) prereq: Dashboard.pm is readable')
        or diag("cannot read $DASHBOARD_PM");

    my $combined = (defined $wt_src ? $wt_src : '') . "\n" . (defined $dash_src ? $dash_src : '');
    my $match_count = () = $combined =~ /minimi[sz]e|ShowWindow|SW_MINIMIZE|--maximized|focus/gi;
    is($match_count, 0,
        'AC-5(a): zero matches (case-insensitive) for /minimi[sz]e|ShowWindow|SW_MINIMIZE|--maximized|focus/ '
        . 'across the full text of WtProfile.pm and Dashboard.pm (found ' . $match_count . ')');

    my $doc = slurp($MINIMIZE_DOC);
    ok(defined($doc), "AC-5(b): $MINIMIZE_DOC exists and is readable")
        or diag("not found at $MINIMIZE_DOC");

  SKIP: {
        skip 'AC-5(c): investigation doc not present -- not yet written', 3 unless defined $doc;

        like($doc, qr/^Status:\s*(?:REPRODUCED|NOT-REPRODUCED|PARTIALLY-REPRODUCED)\s*$/m,
            "AC-5(c): '## Reproduction status' section carries a valid Status: token");
        like($doc, qr/^Cause identified:\s*(?:YES|NO)\s*$/m,
            "AC-5(c): '## Conclusion' section carries a valid Cause identified: token");
        like($doc, qr/^Recommendation:\s*(?:FIX|CLOSE-AS-OUT-OF-SCOPE)\s*$/m,
            "AC-5(c): '## Recommended fix' section carries a valid Recommendation: token");
    }
}

done_testing();
