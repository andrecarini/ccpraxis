#!/usr/bin/env perl
# bp-keepawake.pl — the wake-lock, shared by every long-running butler driver.
#
# WHY THIS FILE EXISTS AS A FILE.
#
# The keep-awake mechanism was implemented in bp-drive-next.pl, for the SOLO
# driver — the path where a human is sitting in the session and would notice a
# suspended host. The FLEET orchestrator, which runs headless coordinators for
# hours with nobody watching, held no wake-lock at all. The lock existed on the
# path that needs it least and was absent from the one that needs it most.
#
# That is not hypothetical. 3c661a0 records a host suspending mid-run: a
# watchdog armed for 1800s reported 7962s elapsed (2h13m). It fixed solo only.
#
# The obvious fix — copy the six helpers into bp-orchestrator.pl — is the same
# mistake this repo has already paid for twice: match_any lives in two files and
# needed t/108 to guard the copies, and the token floor lived in three places
# (one of them an invisible default), which is exactly how the keeper silently
# ran a 1-hour floor for hours after the gate had moved to ten minutes. So the
# wake-lock gets ONE definition and both drivers call it.
#
# WHAT IT ACTUATES. The sandbox plugin's keep-awake.ps1, rather than
# re-deriving the P/Invoke. That helper documents the non-obvious part:
# ES_DISPLAY_REQUIRED is load-bearing on Modern Standby (S0) machines, where
# ES_SYSTEM_REQUIRED alone does NOT hold the box out of connected standby. Both
# plugins ship from the same tree, so the relative path holds in the clone, in
# the live install, and under the container's marketplace mount.
#
# We deliberately do NOT pass the helper's -PidFile: it would write its own
# Windows pid over ours, and the liveness check is perl's kill(0,$pid) against
# the pid WE forked. The fork child execs powershell, so that one pid is the
# wake-lock's whole lifetime — killing it releases the lock (ES_CONTINUOUS is
# tied to the calling thread, so no explicit undo is needed).
#
# Degrades honestly: no Windows, no helper, or a failed fork means no lock and a
# logged warning — never a false claim of holding one. That failure mode is the
# whole reason 3c661a0 exists (the production spawn/kill defaults were empty
# subs, so the director REPORTED managing a lock while holding none).

package BpKeepAwake;
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });

# should_be_on($phase) -> 0|1
# active / pause-pending -> hold the lock; settled -> release it.
# A timed pause still holds it: the whole point is to be awake when it ends.
sub should_be_on {
    my ($phase) = @_;
    return (defined $phase && ($phase eq 'active' || $phase eq 'pause-pending')) ? 1 : 0;
}

sub helper_path { return "$DIR/../../sandbox/scripts/keep-awake.ps1" }

# POSIX -> forward-slash Windows form ("/c/x" -> "C:/x").
#
# Hand-translated on purpose. powershell.exe accepts this form whether or not
# MSYS2 path conversion is active, so the result is correct under EITHER
# conversion state — the technique CLAUDE.md prefers, because it cannot be
# broken by a caller's environment. Do NOT "simplify" this by setting
# MSYS2_ARG_CONV_EXCL instead: the opt-out and the translation are one
# technique, and splitting them is how paths end up created at the drive root.
sub winify {
    my ($p) = @_;
    $p = Cwd::abs_path($p) // $p;
    $p =~ s{\\}{/}g;
    $p =~ s{^/([a-zA-Z])/}{\u$1:/};
    return $p;
}

# Detect whether powershell.exe is resolvable.
sub ps_available {
    # Windows-only concern; in the Linux sandbox this is a documented no-op.
    # Probing off-Windows only spams stderr with "Can't exec" on every tick.
    return 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    # List-form system() spawns powershell.exe directly (no shell), so there is
    # no /dev/null-vs-NUL redirect hazard (CLAUDE.md house rule).
    my $rc = eval { system('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', 'exit 0') };
    return (defined $rc && $rc == 0 && !$@) ? 1 : 0;
}

# spawn($pid_file) -> pid | undef. DIES if the helper is missing or fork fails.
sub spawn {
    my ($pid_f) = @_;
    return undef unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    my $ps1 = helper_path();
    unless (-f $ps1) { die "keep-awake helper missing: $ps1\n" }
    require POSIX;
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-WindowStyle', 'Hidden', '-File', winify($ps1))
            or POSIX::_exit(127);
    }
    if (open my $w, '>', $pid_f) { print $w "$pid\n"; close $w }
    return $pid;
}

sub kill_pid {
    my ($pid) = @_;
    return unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    kill('KILL', $pid);
    waitpid($pid, 0);
}

sub _read_pid {
    my ($pid_f) = @_;
    open my $fh, '<', $pid_f or return undef;
    my $t = do { local $/; <$fh> };
    close $fh;
    return ($t && $t =~ /^(\d+)/) ? $1 : undef;
}

# apply($phase, $dir, \%opts) — idempotent. $dir is where keepawake.pid lives.
#
# %opts seams (all optional; production defaults actuate for real):
#   spawn / kill_pid / powershell_available — injectable for tests
#   log — coderef ->($message), so each driver logs to its own place
sub apply {
    my ($phase, $dir, $opts) = @_;
    $opts //= {};
    my $spawn = $opts->{spawn}                // \&spawn;
    my $killp = $opts->{kill_pid}             // \&kill_pid;
    my $ps_ok = $opts->{powershell_available} // \&ps_available;
    my $log   = $opts->{log}                  // sub { };
    my $pid_f = "$dir/keepawake.pid";

    if (should_be_on($phase)) {
        return unless $ps_ok->();
        # Idempotent: a live lock is left alone rather than doubled.
        if (-e $pid_f) {
            my $pid = _read_pid($pid_f);
            return if defined $pid && kill(0, $pid);
        }
        eval { $spawn->($pid_f) };
        $log->("WARN keepawake spawn failed: $@") if $@;
    } else {
        if (-e $pid_f) {
            my $pid = _read_pid($pid_f);
            if (defined $pid) {
                eval { $killp->($pid) };
                $log->("WARN keepawake kill failed: $@") if $@;
            }
            unlink $pid_f;
        }
    }
}

package main;
1;
