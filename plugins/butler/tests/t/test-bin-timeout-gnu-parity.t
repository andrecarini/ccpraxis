#!/usr/bin/env perl
# platform: host
# The pure-perl `timeout` stand-in (scripts/test-bin/timeout) must behave like
# GNU timeout where the test suite relies on it: a command that left the
# process group (setsid) is still stopped, a TERM sent to timeout is forwarded
# to the command, a command killed by a signal is reported by re-raising that
# signal, and an inherited SIGCHLD=IGNORE does not break the wait.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Time::HiRes qw(time sleep);
use POSIX ();

plan skip_all => 'POSIX process groups and signals: not meaningful on the Windows host'
    if $^O =~ /^(MSWin32|cygwin|msys)$/;

my $T = "$Bin/../../../../scripts/test-bin/timeout";
ok(-x $T, 'stand-in is executable') or BAIL_OUT('no stand-in');

# run: spawn in a child so the wait status is observable, returns ($status, $secs, $stderr)
sub run {
    my (%o) = @_;
    my $err = "/tmp/timeout-parity-$$.err";
    my $t0 = time;
    my $pid = fork // die;
    if (!$pid) {
        $SIG{CHLD} = 'IGNORE' if $o{ignchld};
        open STDERR, '>', $err or POSIX::_exit(99);
        exec @{ $o{cmd} } or POSIX::_exit(98);
    }
    if ($o{signal_after}) { sleep $o{signal_after}; kill $o{signal} => $pid }
    my $r = waitpid($pid, 0);
    my $st = $?;
    my $e = do { local (@ARGV, $/) = ($err); <> } // '';
    unlink $err;
    return ($st, time - $t0, $e, $r);
}

# 1. setsid escapee: the command itself is signalled directly.
{
    my ($st, $secs, $e) = run(cmd => [$T, '1', $^X, '-MPOSIX', '-e', 'POSIX::setsid(); sleep 5']);
    is($st >> 8, 124, 'setsid child: exit 124');
    cmp_ok($secs, '<', 3, 'setsid child: stopped near the bound') or diag "took $secs s";
    is($e, '', 'setsid child: stderr clean');
}

# 2. A TERM sent to timeout is forwarded; the child's death by TERM is re-raised.
{
    my ($st, $secs) = run(cmd => [$T, '10', 'sleep', '10'], signal_after => 0.5, signal => 'TERM');
    cmp_ok($secs, '<', 5, 'TERM to timeout: command stopped promptly') or diag "took $secs s";
    ok(($st & 127) == POSIX::SIGTERM(), 'TERM to timeout: re-raised as signal 15') or diag "status $st";
}

# 3. Command killed by a signal: re-raised, not turned into 128+n.
{
    my ($st) = run(cmd => [$T, '5', 'sh', '-c', 'kill -KILL $$']);
    ok(($st & 127) == POSIX::SIGKILL(), 'KILLed command: re-raised as signal 9') or diag "status $st";
}

# 4. Ordinary exit codes, missing command, and a custom timeout signal.
{
    my ($st) = run(cmd => [$T, '5', 'sh', '-c', 'exit 7']);
    is($st >> 8, 7, 'plain exit code passes through');
    ($st) = run(cmd => [$T, '5', 'nonexistent-command-xyz']);
    is($st >> 8, 127, 'missing command: 127');
    ($st) = run(cmd => [$T, '-k', '1', '-s', 'HUP', '1', 'sleep', '5']);
    is($st >> 8, 124, 'timed out with -s HUP: 124');
}

# 5. SIGCHLD=IGNORE inherited from the parent must not read as an error/success mix-up.
{
    my ($st, undef, $e) = run(cmd => [$T, '5', 'sh', '-c', 'exit 3'], ignchld => 1);
    is($st >> 8, 3, 'SIGCHLD ignored by parent: command status still reported');
    is($e, '', 'SIGCHLD ignored by parent: stderr clean');
}

done_testing;
