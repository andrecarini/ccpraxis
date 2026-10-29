#!/usr/bin/env perl
# bp-watch-child.pl -- the intermediary watcher process for package
# 03-deaths-are-diagnosable (fleet-cost-accounting). Invoked ONLY by
# bp-launch.sh's detached-launch block.
#
# Usage:
#   bp-watch-child.pl PIDFILE STATUSFILE ATTEMPT -- CMD...
#
# bp-orchestrator.pl's run() only ever system()s bp-launch.sh, which itself
# backgrounds and detaches the real coordinator (`claude`) -- so no ancestor
# of the coordinator process is ever in its wait-parent chain, and no OS exit
# status is observable anywhere in that chain today. This process exists
# solely to BECOME that parent: it fork()s, the child setsid()s and exec()s
# into CMD (unchanged process-group topology -- the child's own pgid becomes
# its own pid, exactly like today's bare `setsid nohup claude ...`), and the
# parent (this process, which stays alive for the coordinator's whole
# lifetime) writes the child's pid to PIDFILE, waitpid()s on it, and writes a
# classified exit-status record to STATUSFILE.
#
# THE LOAD-BEARING INVARIANT: PIDFILE always carries the CHILD's pid (the
# process that execs into CMD), never this watcher's own pid. That is what
# preserves the $!-identity invariant bp-launch.sh's callers (pid_alive,
# kill_pid, registry_merge) depend on -- see
# specs/03-deaths-are-diagnosable-spec.md §2.1/§2.2.
#
# Every exit path is defined; nothing is left to "shouldn't happen":
#   - malformed argv                    -> stderr, exit 2, nothing written
#   - fork() failure                    -> stderr, exit 3, nothing written
#   - setsid() failure (in the child)   -> warn, child exit(126)
#   - exec() failure (in the child)     -> warn (inherited fds), child exit(127)
#   - PIDFILE write failure             -> stderr, the already-exec()'d child
#     is TERM'd then KILL'd (whole process group, best-effort) so it is never
#     left running untracked, reaped via waitpid, then exit 4
#   - normal parent path                -> PIDFILE written, then STATUSFILE
#     written atomically (temp + rename) once the child exits, then exit(0)
use strict;
use warnings;
use POSIX ();
use JSON::PP ();
use Config;
use Time::HiRes ();

sub _fail {
    my ($msg, $code) = @_;
    print STDERR "bp-watch-child.pl: $msg\n";
    exit $code;
}

# ---- argv validation (total: PIDFILE STATUSFILE ATTEMPT -- CMD...) ----
my ($pidfile, $statusfile, $attempt, $sep, @cmd) = @ARGV;
_fail('usage: PIDFILE STATUSFILE ATTEMPT -- CMD...', 2)
    unless defined $pidfile   && length $pidfile
        && defined $statusfile && length $statusfile
        && defined $attempt
        && defined $sep;
_fail("missing required '--' separator (got '$sep')", 2) unless $sep eq '--';
_fail("ATTEMPT must be a non-negative integer (got '$attempt')", 2) unless $attempt =~ /\A\d+\z/;
_fail('no CMD tokens after --', 2) unless @cmd;
my $attempt_num = $attempt + 0;

# ---- fork ----
my $pid = fork();
_fail("fork failed: $!", 3) unless defined $pid;

if ($pid == 0) {
    # ---- child: new session/process group (pgid == own pid, exactly the
    # mechanism that already makes `kill -$pid` hit the whole group today),
    # then exec straight into CMD. Never returns on success.
    if (POSIX::setsid() < 0) {
        warn "bp-watch-child.pl: setsid failed: $!\n";
        POSIX::_exit(126);
    }
    exec { $cmd[0] } @cmd;
    # exec() failed (e.g. binary not found) -- goes to the coordinator's own
    # $LOG, already redirected onto this process's inherited fds.
    warn "bp-watch-child.pl: exec failed for '$cmd[0]': $!\n";
    POSIX::_exit(127);
}

# ---- parent (the watcher): stays alive for the coordinator's whole lifetime
if (!open(my $pf, '>', $pidfile)) {
    warn "bp-watch-child.pl: cannot write PIDFILE $pidfile: $!\n";
    # The child is already running but nothing on disk will ever name its
    # pid -- leaving it running here is exactly the "orphaned, untracked
    # coordinator" failure mode this whole package exists to prevent. Kill
    # it before we exit. This mirrors this repo's existing kill_pid
    # term-then-kill idiom (bp-orchestrator.pl) but with one difference:
    # at this early point the child may not have reached its own setsid()
    # yet, so its process GROUP (-$pid) may not exist as a group leader at
    # all -- a group-only signal can silently no-op (ESRCH). Always
    # attempt the plain pid too (not only as an "or" fallback -- eval{...;1}
    # always reports success and would mask that no-op): both forms, both
    # signals, each independently eval-guarded so one failing/dying never
    # skips the others. A very freshly fork()'d process can also fail to
    # take a signal at all for a brief window on this host's fork
    # emulation (observed directly: a same-tick kill() can silently no-op,
    # neither dying nor raising) -- so retry both signals against a
    # liveness check for a bounded ~2s rather than firing once and hoping.
    for (1 .. 20) {
        last unless kill(0, $pid);   # kill(0,...) == pure liveness probe, no signal sent
        eval { kill('TERM', -$pid) };
        eval { kill('TERM', $pid) };
        eval { kill('KILL', -$pid) };
        eval { kill('KILL', $pid) };
        Time::HiRes::sleep(0.1);
    }
    # Reap it so it does not linger as a zombie under the watcher.
    waitpid($pid, 0);
    exit 4;
}
else {
    print $pf "$pid\n";
    close $pf;
}

waitpid($pid, 0);
my $wait_status = $?;

my @signame = split ' ', $Config{sig_name};

my %rec = (
    pid            => $pid,
    attempt        => $attempt_num,
    classification => 'other',
    exit_code      => undef,
    signal         => undef,
    signal_name    => undef,
);

if (POSIX::WIFEXITED($wait_status)) {
    my $code = POSIX::WEXITSTATUS($wait_status);
    $rec{exit_code}      = $code;
    $rec{classification} = ($code == 0) ? 'exited-zero' : 'exited-nonzero';
}
elsif (POSIX::WIFSIGNALED($wait_status)) {
    my $sig = POSIX::WTERMSIG($wait_status);
    $rec{signal}      = $sig;
    $rec{signal_name} = $signame[$sig] ? ('SIG' . $signame[$sig]) : undef;
    $rec{classification} = ($sig == 9)  ? 'killed-sigkill'
                          : ($sig == 15) ? 'killed-sigterm'
                          :                'killed-other';
}
# else: neither exited nor signaled (should not happen without WUNTRACED) --
# stays 'other', matching §2.1's total classification table.

my @g = gmtime(time());
$rec{finished_at} = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
    $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);

# ---- atomic write: temp + rename, mirroring bp-orchestrator.pl's
# _write_json_atomic convention (:5327-5340).
my $tmp = "$statusfile.tmp.$$";
if (open(my $w, '>', $tmp)) {
    print $w JSON::PP->new->canonical->encode(\%rec);
    close $w;
    unless (rename($tmp, $statusfile)) {
        warn "bp-watch-child.pl: rename $tmp -> $statusfile failed: $!\n";
        unlink $tmp;
    }
}
else {
    warn "bp-watch-child.pl: cannot write STATUSFILE $statusfile: $!\n";
}

exit 0;
