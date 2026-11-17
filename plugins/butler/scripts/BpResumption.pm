# BpResumption.pm — WILL ANYTHING ACTUALLY BRING THIS SESSION BACK?
#
# One question, asked by two guards that were answering it separately:
#
#   * wait-shape-guard.sh + bp-runstate.pl guard a RUN. `pause` records a
#     watcher pid and a deadline; `effective` re-verifies both on every read.
#   * stop-gate.sh + butler-continuity guard a SESSION. `hold` records a
#     deadline and a pid; the Stop gate re-verifies them.
#
# They guard different SCOPES and should stay separate -- a run outlives a
# session, and a session can be armed with no run. What was duplicated was the
# MECHANISM, and the duplication was not free: the run side had already learned
# two things the session side had not, and rediscovering them cost a fix batch.
#
# LESSON ONE: kill(0) IS NOT LIVENESS ON WINDOWS. Perl cannot signal a native
# process it did not create and reports a healthy one as dead. A watcher that
# cannot be verified must not hold a gate open, so the fallback asks tasklist.
#
# LESSON TWO, AND THE ONE THAT MATTERS MOST HERE: A LIVE PID IS NOT THE SAME
# PID. `hold` and `butler-hold` both EXIT when their wait ends -- that is their
# whole purpose -- and the OS is then free to hand that number to anything. A
# bare liveness check cannot tell the difference. The run side's red-team
# demonstrated it concretely: an unrelated `sleep &` occupying the recorded pid
# made a pause read as verified with nothing watching. The session side shipped
# with exactly that hole: kill a hold early and its deadline is still in the
# future, so a recycled pid would satisfy the gate.
#
# So identity is pinned by a FINGERPRINT captured when the promise is made and
# re-derived when it is checked -- a value the OS assigns once at process
# creation and never touches again. undef means "could not be determined", and
# every caller MUST treat that as UNVERIFIED rather than as a match.
#
# The gate is bash and this is perl. Rather than translate the rules a second
# time and re-open the parity gap this module exists to close, callers on the
# perl side load this module directly. One implementation, one place to fix.
package BpResumption;
use strict;
use warnings;

# ── liveness ───────────────────────────────────────────────────────────────
sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return kill(0, $pid) ? 1 : 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 1 if kill(0, $pid);
    my $out = do { local $ENV{MSYS2_ARG_CONV_EXCL} = '*'; `tasklist /FI "PID eq $pid" /NH` };
    return 0 unless defined $out;
    return ($out =~ /\b\Q$pid\E\b/) ? 1 : 0;
}

# ── identity ───────────────────────────────────────────────────────────────
#
# TWO PROCESS DOMAINS, NEITHER TOOL SEEING BOTH. An MSYS/cygwin-spawned process
# (which every perl process in this family is) exposes a virtual /proc/$pid/stat
# whose 20th field after the ")" is the kernel's start-time counter for that
# specific instance. A genuinely native Windows process is invisible to /proc
# and is fingerprinted through wmic's CreationDate instead.
sub pid_fingerprint {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;

    if (open my $fh, '<', "/proc/$pid/stat") {
        local $/;
        my $raw = <$fh>;
        close $fh;
        if (defined $raw && $raw =~ /\)\s*(.*)$/s) {
            my @f = split ' ', $1;
            return "proc:$f[19]" if defined $f[19] && $f[19] =~ /^\d+$/;
        }
        return undef;
    }

    if ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        my $out = do {
            local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
            `wmic process where "ProcessId=$pid" get CreationDate 2>/dev/null`;
        };
        return undef unless defined $out;
        $out =~ s/\x00//g;   # wmic's console output is UTF-16LE seen through the pipe
        return "wmic:$1" if $out =~ /(\d{14}\.\d+[+-]\d+)/;
        return undef;
    }

    # macOS/BSD fallback: no /proc, not Windows. lstart is a DATE STRING
    # ("Thu Oct 29 22:10:01 2026"): its words follow the locale, so it is read
    # under LC_ALL=C to stay the same value from one call to the next, and its
    # spaces are folded to '_' because the marker line is space-separated --
    # marker_line drops a fingerprint with whitespace in it, which left every
    # Mac marker with no identity at all and the gate refusing all of them.
    my $out = do {
        local $ENV{LC_ALL} = 'C';
        local $ENV{LANG}   = 'C';
        `ps -o lstart= -p $pid 2>/dev/null`;
    };
    return undef unless defined $out && length $out;
    $out =~ s/^\s+|\s+$//g;
    $out =~ s/\s+/_/g;
    return length($out) ? "ps:$out" : undef;
}

# ── the wake-up marker's line format ───────────────────────────────────────
#
#   <written_epoch> bounded <deadline_epoch> <pid> <fingerprint>
#
# Field 1 is the write time, which the gate's own staleness TTL reads. Field 2
# is the literal `bounded`: its absence is what distinguishes a promise to
# return from a mere record that something was dispatched. Fields 4 and 5 pin
# WHICH process made the promise. A fingerprint that could not be determined is
# written as '-' rather than omitted, so a short line always means "older
# format" and never "this field happened to be empty".
sub marker_line {
    my (%o) = @_;
    my $now      = defined $o{now}      ? $o{now}      : time();
    my $deadline = $o{deadline};
    my $pid      = defined $o{pid} ? $o{pid} : $$;
    my $fp       = exists $o{fingerprint} ? $o{fingerprint} : pid_fingerprint($pid);
    $fp = '-' unless defined $fp && length $fp && $fp !~ /\s/;
    return "$now bounded $deadline $pid $fp\n";
}

sub parse_line {
    my ($line) = @_;
    return undef unless defined $line;
    $line =~ s/\r?\n\z//;
    my @f = split ' ', $line;
    return {
        written  => (defined $f[0] && $f[0] =~ /^\d+$/) ? $f[0] + 0 : undef,
        kind     => $f[1],
        deadline => (defined $f[2] && $f[2] =~ /^\d+$/) ? $f[2] + 0 : undef,
        pid      => (defined $f[3] && $f[3] =~ /^\d+$/) ? $f[3] + 0 : undef,
        fp       => (defined $f[4] && $f[4] ne '-')     ? $f[4]     : undef,
    };
}

# verify_line($line, %opts) -> (1) or (0, $reason).
#
# Every failure names itself, because the gate's whole value is that a refusal
# can be explained. Order matters only for the message.
sub verify_line {
    my ($line, %opts) = @_;
    my $now = defined $opts{now} ? $opts{now} : time();
    my $ttl = defined $opts{ttl} ? $opts{ttl} : 900;

    my $rec = parse_line($line);
    return (0, 'unreadable') unless ref $rec eq 'HASH';

    return (0, 'not bounded: a dispatch records that something started, never that '
              . 'anything will come back')
        unless defined $rec->{kind} && $rec->{kind} eq 'bounded';

    return (0, 'no write timestamp') unless defined $rec->{written};
    return (0, 'stale: written ' . ($now - $rec->{written}) . "s ago, past the ${ttl}s TTL")
        if $ttl > 0 && ($now - $rec->{written}) >= $ttl;

    return (0, 'no deadline') unless defined $rec->{deadline};
    return (0, 'deadline has passed') unless $rec->{deadline} > $now;

    # A marker with no pid predates this field. Unverifiable, and an
    # unverifiable promise fails toward NOT-scheduled -- the direction every
    # other unknown in this family takes.
    return (0, 'no pid: cannot verify anything will actually return')
        unless defined $rec->{pid};
    return (0, "process $rec->{pid} is not running") unless pid_alive($rec->{pid});

    # LIVE IS NOT ENOUGH -- see the header. Without a recorded fingerprint there
    # is nothing to compare against, so the identity is unverifiable.
    return (0, "process $rec->{pid} has no recorded identity, so a recycled pid "
              . 'cannot be told from the original')
        unless defined $rec->{fp};
    my $have = pid_fingerprint($rec->{pid});
    return (0, "process $rec->{pid} identity could not be determined")
        unless defined $have;
    return (0, "process $rec->{pid} is a DIFFERENT process than the one that made the "
              . 'promise (the pid was recycled)')
        unless $have eq $rec->{fp};

    return (1);
}

1;
