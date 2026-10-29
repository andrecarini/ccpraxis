#!/usr/bin/env perl
# bounded-run.pl SECONDS COMMAND [ARG]...
#
# Run COMMAND, and if it has not finished after SECONDS, terminate it (TERM to
# its process group, then KILL a second later) and exit 124 -- the exit code
# GNU coreutils' `timeout` uses, so callers cannot tell the two apart.
# Otherwise exit with COMMAND's own status (128+N if a signal ended it).
#
# WHY THIS EXISTS. The resources sampler bounds each podman/host probe with a
# `timeout N` prefix so one wedged probe cannot stall every later round (see
# launcher.pl _timeout_prefix). macOS ships no `timeout`, so on a Mac every
# probe ran unbounded. This is the fallback launcher.pl uses when no GNU
# timeout is installed. It is perl only, so it needs nothing the host does
# not already have, and stdout/stderr are inherited, so the caller's capture
# and `2>file` redirects keep working unchanged.
#
# Not a general timeout(1) replacement: one form, whole seconds, no options.
use strict;
use warnings;
use POSIX ();

my $secs = shift @ARGV;
unless (defined $secs && $secs =~ /\A\d+\z/ && $secs > 0 && @ARGV) {
    print STDERR "usage: bounded-run.pl SECONDS COMMAND [ARG]...\n";
    exit 125;
}

my $pid = fork();
unless (defined $pid) {
    print STDERR "bounded-run.pl: fork failed: $!\n";
    exit 125;
}
if ($pid == 0) {
    # Own process group, so a timeout reaches anything the command started.
    POSIX::setpgid(0, 0);
    { no warnings qw(exec); exec { $ARGV[0] } @ARGV; }
    print STDERR "bounded-run.pl: cannot run $ARGV[0]: $!\n";
    POSIX::_exit($!{ENOENT} ? 127 : 126);
}
# Set it from this side too: whichever of the two runs first, the group exists
# before any signal below is sent.
POSIX::setpgid($pid, $pid);

# First alarm: TERM the group. If anything ignores TERM, the second alarm, a
# second later, KILLs it, so the wait below always ends.
my $timed_out = 0;
local $SIG{ALRM} = sub {
    if (!$timed_out) { $timed_out = 1; kill 'TERM', -$pid; alarm 1 }
    else             { kill 'KILL', -$pid }
};
alarm $secs;
my $r;
do { $r = waitpid($pid, 0) } while ($r == -1 && $!{EINTR}) || ($r == 0);
my $status = $?;
alarm 0;
if ($timed_out) {
    # Anything in the group still alive after TERM gets KILL.
    kill 'KILL', -$pid;
    exit 124;
}
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
