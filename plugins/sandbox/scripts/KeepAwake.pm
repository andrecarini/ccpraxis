package KeepAwake;
# B5 — keep-awake held by the dashboard, gated by the orchestrator's busy-lease
# (Decisions #16/#21). While the dashboard is open the PC stays awake ONLY when
# there is active work or a pending auto-resume; it is allowed to sleep when idle
# OR when the only outstanding work is parked-waiting-for-a-human.
#
# The "active vs parked" judgement lives in the orchestrator (A3): it refreshes
# the busy-lease (`/tmp/.butler-busy`) every ~60s while work is active or an
# auto-resume is pending, and STOPS touching it when idle or only-parked. So the
# host-side dashboard does not re-derive that state — **busy-lease freshness is
# the keep-awake signal**. This module is the pure decision + a small lifecycle
# holder; the actual Windows wake-lock is asserted by `keep-awake.ps1`
# (SetThreadExecutionState via PowerShell, since Win32::API is absent in the host
# perl), started/stopped through injected seams so the lifecycle is testable.
#
# Split (mirrors Dashboard.pm / BackpackReview.pm): pure logic + seam-injected
# lifecycle here (unit-tested); the real spawn/kill of the PS helper + the lease
# read live in the launcher; whether the machine ACTUALLY stays awake is verified
# on a real desktop (attended).
#
# On macOS the helper is this module's own holder (hold_main, below): a small
# process that runs `caffeinate -i -w <its own pid>` only while the Mac is on AC
# power, and exits when the launcher does, so nothing can be orphaned. Butler's
# managed wake-lock (bp-keepawake.pl) runs the same holder: one macOS
# assertion, not one per owner. Hosts with neither mechanism get no helper, and
# held() below says so.
use strict;
use warnings;

# ---------------------------------------------------------------------------
# THE macOS ASSERTION -- one definition, one holder process, for every owner.
#
# Two owners take it: the launcher's dashboard lock (launcher.pl
# _keepawake_start_caffeinate, owner = the launcher) and butler's managed
# wake-lock (bp-keepawake.pl, owner = the continuity refresher or a driver).
# They used to build their own caffeinate command lines and had drifted (the
# launcher -i -s, the managed lock -i). Both now run the holder below,
# hold_main, and it builds the command line with caffeinate_argv.
#
# THE OPERATOR'S RULE (2026-10-30): caffeinate must never take effect while
# the Mac is off AC power, and closing the lid must always sleep it. So:
#
# -i  is the ONLY assertion: it prevents idle system sleep, and nothing else.
#     Closing the lid still sleeps the machine, on AC or battery. Measured
#     2026-10-29 on this host, the flag this rules out: a hand-run
#     `caffeinate -i -s -m -t 50400` kept a lid-closed Mac on AC in DarkWake
#     ("Entering DarkWake state due to 'Clamshell Sleep'") from 23:01, when
#     its work ended, to 08:52. -s (system sleep, AC only), -d (display),
#     -u (user activity: wakes the display and resets the idle timer) and
#     -m (disk) are never passed: none is needed to stop idle sleep, and -s
#     and -u are exactly the flags that override a closed lid or a sleeping
#     display.
# -w  ties the assertion to its owner's pid: caffeinate exits by itself when
#     its owner does, whatever killed it (SIGKILL included), so nothing can
#     orphan the assertion. There is no -t: an assertion lasts exactly as long
#     as its holder decides, never a guessed duration.
#
# AC ONLY. hold_main reads the power source every $POWER_POLL_SECONDS and runs
# caffeinate only while it reads 'AC Power'. It never starts one on battery,
# stops a running one within one poll of the switch (see hold_main for the
# bound), and takes it again when AC returns while its lease is still live.
# An unreadable power source counts as battery: the failure is a Mac that may
# sleep, never one held awake off AC.
#
# Nothing here decides WHETHER work wants the machine awake. That is the
# owner's business (the dashboard's busy-lease probe; the continuity lease's
# in-flight check), and it says so by keeping the holder alive (and, for a
# leased holder, by touching its pid file).
# ---------------------------------------------------------------------------
our @CAFFEINATE_FLAGS = ('-i');

# How often the holder reads the power source, i.e. the longest it can keep
# caffeinate running after the Mac switches to battery (plus one bounded
# pmset read and the stop itself; see hold_main). One `pmset -g ps` costs a
# few milliseconds on this host, so a 2-second cadence is ~30 cheap reads a
# minute for the life of a hold: the price of a bound in seconds rather than
# minutes. The lease and owner checks ride the same tick for free.
our $POWER_POLL_SECONDS = 2;

# The longest one power-source read may take before it counts as unreadable
# (and so as battery).
our $PMSET_TIMEOUT_SECONDS = 3;

# caffeinate_bin() -> path | undef. CCPRAXIS_CAFFEINATE_BIN names a substitute
# (the test seam: a fake that asserts nothing); otherwise the system binary at
# its fixed path, then PATH. undef when there is none (not a Mac).
sub caffeinate_bin {
    my $o = $ENV{CCPRAXIS_CAFFEINATE_BIN};
    return $o if defined $o && length $o;
    return '/usr/bin/caffeinate' if -x '/usr/bin/caffeinate';
    for my $d (split /:/, ($ENV{PATH} // '')) {
        next unless length $d;
        return "$d/caffeinate" if -x "$d/caffeinate";
    }
    return undef;
}

# caffeinate_argv($bin, $owner_pid) -> ($bin, '-i', '-w', $owner_pid) | ()
# The exec list for one assertion owned by $owner_pid. Empty list (and so
# nothing to exec) unless both are usable: an assertion with no owner is the
# orphan -w exists to rule out.
sub caffeinate_argv {
    my ($bin, $owner) = @_;
    return () unless defined $bin && length $bin;
    return () unless defined $owner && "$owner" =~ /\A[1-9][0-9]*\z/;
    return ($bin, @CAFFEINATE_FLAGS, '-w', "$owner");
}

# parse_pmset_ps($text) -> 'ac' | 'dc' | 'unknown'. PURE. Only the FIRST line
# decides ("Now drawing from 'AC Power'" / 'Battery Power' / 'UPS Power'); the
# battery rows below it describe a battery, not the source. A UPS is mains
# that has already been lost, so it counts as DC. The one parser: butler's
# AC-loss watch (BpAcWatch::parse_pmset_ps) delegates here.
sub parse_pmset_ps {
    my ($text) = @_;
    return 'unknown' unless defined $text && !ref $text;
    my ($first) = split /\r?\n/, $text, 2;
    return 'unknown' unless defined $first;
    return 'ac' if $first =~ /'AC Power'/;
    return 'dc' if $first =~ /'(?:Battery|UPS) Power'/;
    return 'unknown';
}

# power_source() -> 'ac' | 'dc' | 'unknown'. The test seam comes first, and it
# is the AC-loss watch's own: CCPRAXIS_AC_PROBE_FILE, an absolute path whose
# first line is ac, dc or unknown, read on every call so a test can switch the
# "power source" under a running holder. It is honoured only together with
# CCPRAXIS_CAFFEINATE_BIN (a substitute caffeinate that asserts nothing): a
# leaked or inherited seam must never let the REAL caffeinate run on battery.
# Otherwise one bounded `pmset -g ps` -- refused (unknown) under a .t and under
# CCPRAXIS_NO_WAKELOCK, the AC-loss watch's rule: a test reads the seam, never
# the real machine.
sub power_source {
    my $pf = $ENV{CCPRAXIS_AC_PROBE_FILE};
    my $fake = defined $ENV{CCPRAXIS_CAFFEINATE_BIN} && length $ENV{CCPRAXIS_CAFFEINATE_BIN};
    if ($fake && defined $pf && length $pf && $pf =~ m{\A/}) {
        open(my $fh, '<:raw', $pf) or return 'unknown';
        my $line = <$fh>;
        close $fh;
        return 'unknown' unless defined $line;
        $line =~ s/\A\s+|\s+\z//g;
        $line = lc $line;
        return ($line eq 'ac' || $line eq 'dc') ? $line : 'unknown';
    }
    return 'unknown' if defined $0 && $0 =~ /\.t\z/;
    return 'unknown' if $ENV{CCPRAXIS_NO_WAKELOCK};
    return parse_pmset_ps(_pmset_ps_bounded($PMSET_TIMEOUT_SECONDS));
}

# _pmset_ps_bounded($secs) -> stdout of `pmset -g ps` | undef. No shell; stderr
# to /dev/null; a read that outlasts $secs kills the child and returns undef.
sub _pmset_ps_bounded {
    my ($secs) = @_;
    my $bin = -x '/usr/bin/pmset' ? '/usr/bin/pmset' : 'pmset';
    require POSIX;
    my $pid = open(my $fh, '-|');
    return undef unless defined $pid;
    if (!$pid) {
        open(STDERR, '>', '/dev/null');
        { no warnings 'exec'; exec { $bin } 'pmset', '-g', 'ps'; }
        POSIX::_exit(127);
    }
    my $out;
    my $ok = eval {
        local $SIG{ALRM} = sub { die "pmset-timeout\n" };
        alarm($secs);
        local $/;
        $out = <$fh>;
        alarm(0);
        1;
    };
    alarm(0);
    kill('KILL', $pid) unless $ok;
    close $fh;
    return $ok ? $out : undef;
}

# state_path($pid_file) -> the holder's state file beside its pid file
# (keepawake.pid -> keepawake.state). One word: 'asserted' while caffeinate
# runs, 'standby' while the holder waits off AC power. Readers use it to
# report what is TRUE -- a live holder on battery holds nothing.
sub state_path {
    my ($pid_f) = @_;
    return undef unless defined $pid_f && length $pid_f;
    (my $s = $pid_f) =~ s/\.pid\z//;
    return "$s.state";
}

# holder_state($pid_file) -> 'asserted' | 'standby' | undef (no state file).
sub holder_state {
    my ($pid_f) = @_;
    my $sf = state_path($pid_f);
    return undef unless defined $sf;
    open(my $fh, '<:raw', $sf) or return undef;
    my $w = <$fh>;
    close $fh;
    return undef unless defined $w;
    $w =~ s/\s+//g;
    return ($w eq 'asserted' || $w eq 'standby') ? $w : undef;
}

sub _write_state {
    my ($pid_f, $word) = @_;
    my $sf = state_path($pid_f);
    return unless defined $sf;
    my $tmp = "$sf.tmp.$$";
    open(my $fh, '>', $tmp) or return;
    print {$fh} "$word\n";
    close $fh;
    rename($tmp, $sf) or unlink $tmp;
    return;
}

# holder_argv(%o) -> the exec list that starts the holder as its own process:
# perl KeepAwake.pm hold --pid-file F [--log-file L] [--lease S]
# [--owner-pid P]. For an owner that is not itself `bp-keepawake.pl hold`
# (the launcher). %o: pid_file (required), log_file, lease, owner_pid.
sub holder_argv {
    my (%o) = @_;
    return () unless defined $o{pid_file} && length $o{pid_file};
    (my $self = __FILE__) =~ s{\\}{/}g;
    require Cwd;
    $self = Cwd::abs_path($self) // $self;
    my @a = ($^X, $self, 'hold', '--pid-file', $o{pid_file});
    push @a, '--log-file', $o{log_file}  if defined $o{log_file} && length $o{log_file};
    push @a, '--lease', $o{lease}        if defined $o{lease};
    push @a, '--owner-pid', $o{owner_pid} if defined $o{owner_pid} && "$o{owner_pid}" =~ /\A[1-9][0-9]*\z/;
    return @a;
}

# hold_main(@argv) -> exit code. THE macOS holder. Blocks.
#
#   hold --pid-file F [--log-file L] [--lease S] [--owner-pid P]
#        [--owner-desc D] [--poll S]
#
# Writes ITS OWN pid into F (the identity readers check, and the lease's
# heartbeat: whoever wants the hold touches F), then loops every --poll
# seconds (default $POWER_POLL_SECONDS):
#
#   - lets go for good, and exits 0, when signalled (TERM/INT/HUP), when F
#     stops naming it (released or replaced), when F goes untouched for more
#     than --lease seconds (0 = no lease: an owner that holds until it stops
#     the holder), or when --owner-pid has exited;
#   - otherwise follows the power source: on AC it runs `caffeinate -i -w
#     <its own pid>` (caffeinate_argv), off AC it stops that caffeinate and
#     stands by, and it takes the assertion again when AC returns.
#
# THE BATTERY BOUND. A switch to battery stops caffeinate within one poll
# (2 s) plus one pmset read (milliseconds; at most $PMSET_TIMEOUT_SECONDS,
# 3 s, after which the read counts as battery) plus the stop (caffeinate exits
# on TERM at once; KILL after 1 s): normally about 2 seconds, never more than
# about 6.
#
# Log lines carry "pid=<holder pid>": ASSERTED when caffeinate starts (on AC),
# STANDBY when the holder is up off AC or stops caffeinate for battery,
# RELEASE reason=... on the way out, FAILED when caffeinate will not run.
# BpKeepAwake::replace waits for ASSERTED or STANDBY ("the new holder is
# working") before it stops the old one.
#
# Exit 0 after a release, 2 on bad arguments, 3 when refused (a test
# environment with no substitute caffeinate), 4 when caffeinate would not start.
sub hold_main {
    my (@argv) = @_;
    my %a = (lease => 900, poll => undef);
    while (@argv) {
        my $k = shift @argv;
        my $v = shift @argv;
        return 2 unless defined $v;
        if    ($k eq '--pid-file')   { $a{pid_f} = $v }
        elsif ($k eq '--log-file')   { $a{log_f} = $v }
        elsif ($k eq '--lease')      { return 2 unless $v =~ /^\d+(?:\.\d+)?$/; $a{lease} = $v }
        elsif ($k eq '--owner-pid')  { return 2 unless $v =~ /^[1-9]\d*$/; $a{owner} = $v }
        elsif ($k eq '--owner-desc') { ($a{desc} = $v) =~ s/[^A-Za-z0-9._,=#+-]/_/g; $a{desc} = substr($a{desc}, 0, 100) }
        elsif ($k eq '--poll')       { return 2 unless $v =~ /^\d+(?:\.\d+)?$/ && $v > 0; $a{poll} = $v }
        else                         { return 2 }
    }
    return 2 unless defined $a{pid_f} && length $a{pid_f};
    # The real assertion is never taken from a test environment; a substitute
    # binary asserts nothing, so it is what a test of this loop runs.
    return 3 if $ENV{CCPRAXIS_NO_WAKELOCK} && !(defined $ENV{CCPRAXIS_CAFFEINATE_BIN}
                                                && length $ENV{CCPRAXIS_CAFFEINATE_BIN});
    my $bin = caffeinate_bin();
    return 4 unless defined $bin;
    my $poll = $a{poll} // $POWER_POLL_SECONDS;
    $poll = $POWER_POLL_SECONDS if $poll > $POWER_POLL_SECONDS;

    require POSIX;
    require Time::HiRes;
    my $pid_f = $a{pid_f};
    my $log = sub {
        my ($msg) = @_;
        return unless defined $a{log_f};
        my @t = localtime(time);
        open(my $fh, '>>', $a{log_f}) or return;
        printf {$fh} "%04d-%02d-%02d %02d:%02d:%02d pid=%d %s\n",
            $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $$, $msg;
        close $fh;
    };
    my $read_pid = sub {
        open(my $fh, '<', $pid_f) or return undef;
        my $t = do { local $/; <$fh> };
        close $fh;
        return ($t && $t =~ /^(\d+)/) ? $1 : undef;
    };
    my $names_me = sub { my $p = $read_pid->(); return (defined $p && $p eq "$$") ? 1 : 0 };

    # Identity first, the way keep-awake.ps1 does it: overwrite whatever claim
    # or predecessor the file named. The mtime this sets is the lease's start.
    open(my $pfh, '>', $pid_f) or do { $log->("FAILED cannot write $pid_f: $!"); return 4 };
    print {$pfh} "$$\n";
    close $pfh;
    # Nothing is asserted until the first power read says AC: say so at once,
    # so a predecessor's stale 'asserted' can never speak for this holder.
    _write_state($pid_f, 'standby');

    my $stop = 0;
    local $SIG{TERM} = sub { $stop = 'signal-term' };
    local $SIG{INT}  = sub { $stop = 'signal-int' };
    local $SIG{HUP}  = sub { $stop = 'signal-hup' };

    my $caf;            # our caffeinate child, while one runs
    my $announced = 0;  # first ASSERTED/STANDBY written
    my $standby_why;    # why we are standing by, once announced
    my $desc = defined $a{desc} ? " desc=$a{desc}" : '';
    my $who  = sprintf('lease=%ss owner=%s%s', $a{lease}, $a{owner} // 'none', $desc);

    my $stop_caf = sub {
        return unless defined $caf;
        if (waitpid($caf, POSIX::WNOHANG()) == 0) {
            kill('TERM', $caf);
            my $deadline = Time::HiRes::time() + 1;
            my $reaped = 0;
            while (Time::HiRes::time() < $deadline) {
                if (waitpid($caf, POSIX::WNOHANG()) != 0) { $reaped = 1; last }
                Time::HiRes::sleep(0.02);
            }
            # KILL only a child not yet reaped: once reaped, its pid may
            # already belong to an unrelated process.
            unless ($reaped) { kill('KILL', $caf); waitpid($caf, 0) }
        }
        undef $caf;
    };
    my $finish = sub {
        my ($why, $rc) = @_;
        $stop_caf->();
        if ($names_me->()) {
            unlink $pid_f;
            my $sf = state_path($pid_f);
            unlink $sf if defined $sf;
        }
        $log->(($rc ? 'FAILED ' : 'RELEASE reason=') . $why);
        return $rc // 0;
    };

    while (1) {
        return $finish->($stop) if $stop;
        if (defined $caf && waitpid($caf, POSIX::WNOHANG()) == $caf) {
            my $rc = $? >> 8;
            undef $caf;
            return $finish->("caffeinate-exited rc=$rc");
        }
        unless ($names_me->()) {
            return $finish->(-e $pid_f ? 'replaced' : 'pid-file-removed');
        }
        if ($a{lease} > 0) {
            my $mtime = (stat($pid_f))[9];
            return $finish->('lease-expired') if defined $mtime && (time() - $mtime) > $a{lease};
        }
        return $finish->('owner-exited')
            if defined $a{owner} && !kill(0, $a{owner}) && $!{ESRCH};

        my $src = power_source();
        if ($src eq 'ac') {
            unless (defined $caf) {
                my @cmd = caffeinate_argv($bin, $$);
                my $kid = fork();
                return $finish->("fork: $!", 4) unless defined $kid;
                if ($kid == 0) {
                    open(STDIN,  '<', '/dev/null');
                    open(STDOUT, '>', '/dev/null');
                    open(STDERR, '>', '/dev/null');
                    exec(@cmd) or POSIX::_exit(127);
                }
                $caf = $kid;
                # A caffeinate that dies at once never asserted anything; say
                # so rather than log a hold that is not there.
                Time::HiRes::sleep(0.2);
                if (waitpid($caf, POSIX::WNOHANG()) == $caf) {
                    my $rc = $? >> 8;
                    undef $caf;
                    return $finish->("caffeinate exited at start rc=$rc", 4);
                }
                _write_state($pid_f, 'asserted') if $names_me->();
                # The log prefix already says pid=<us>, which makes this the
                # "pid=<pid> ASSERTED" line BpKeepAwake::replace waits for.
                $log->(sprintf('ASSERTED caffeinate=%d power=ac %s%s', $caf, $who,
                    $announced ? ' reason=ac-restored' : ''));
                $announced = 1;
                undef $standby_why;
            }
        } else {
            my $why = $src eq 'dc' ? 'battery' : 'power-unknown';
            if (defined $caf) {
                my $was = $caf;
                $stop_caf->();
                _write_state($pid_f, 'standby') if $names_me->();
                $log->("STANDBY reason=$why caffeinate-stopped=$was");
                $standby_why = $why;
            } elsif (!$announced || !defined $standby_why || $standby_why ne $why) {
                _write_state($pid_f, 'standby') if $names_me->();
                $log->("STANDBY reason=$why $who");
                $standby_why = $why;
            }
            $announced = 1;
        }
        Time::HiRes::sleep($poll);
    }
}

# should_stay_awake($lease_age_secs, $stale_secs) -> 1|0
#   $lease_age_secs = seconds since the busy-lease's mtime, or undef if the lease
#                     is absent / unreadable. $stale_secs = the freshness window
#                     (match the orchestrator's BUSY_STALE_SECS).
#   Awake iff the lease exists AND is fresh. Absent lease (undef) -> sleep.
#   A NEGATIVE age means the lease mtime is in the "future" — i.e. host/container
#   clock skew on a lease the orchestrator just wrote, which only happens while a
#   run is actively touching it. Treat that as fresh and STAY AWAKE: a wrong
#   "sleep" here lets the host drop into standby and kills the live run (observed),
#   whereas a wrong "stay awake" only wastes some idle power. (The launcher now
#   computes the age entirely in container time, so a negative age should be rare;
#   this is the belt-and-suspenders guard.)
sub should_stay_awake {
    my ($age, $stale) = @_;
    return 0 unless defined $age;
    $stale = 180 unless defined $stale && $stale =~ /^-?\d+(?:\.\d+)?$/;
    return 1 if $age < 0;          # clock-skew on a freshly-touched lease -> stay awake
    return ($age <= $stale) ? 1 : 0;
}

# classify_lease_stat_failure($output, $expected_path) -> $verdict | undef
#
# THE THIRD THING A `stat` FAILURE CAN MEAN. The busy-lease probe runs
# `stat -c %Y <lease>` inside the container and, until 2026-09-16, read ANY
# "No such file or directory" as 'lease-absent' -- a fact about the CONTAINER,
# which on_probe releases the wake-lock for immediately and without tolerance.
#
# On Windows that was wrong often enough to cost a night's fleet run. MSYS2
# rewrites argv elements that look like POSIX paths on their way into a native
# binary, so podman was handed the HOST's Windows temp directory and stat
# truthfully reported that no such file existed -- there. The container's lease
# was being refreshed every few seconds the whole time.
#
# Every stat implementation in play (GNU coreutils, busybox) quotes the
# offending path back in its message, so a quoted path that is NOT the one we
# asked for is positive evidence that the argument was rewritten in flight.
# That is a fact about US, and belongs in 'probe-failed' where on_probe holds
# through a tolerance rather than giving up.
#
# Returns:
#   undef            -- not a "no such file" failure; the caller's other
#                       classification paths still apply, unchanged.
#   'lease-absent'   -- a genuine absence: the message names our path, or names
#                       none at all.
#   'path-rewritten' -- the message names a DIFFERENT path.
#
# The no-path-named case deliberately falls back to 'lease-absent' rather than
# to the failure verdict: a stat variant that stays quiet must not be able to
# strand the wake-lock held forever after a run ends. Only positive evidence of
# rewriting diverges.
sub classify_lease_stat_failure {
    my ($output, $expected_path) = @_;
    return undef unless defined $output && $output =~ /no such file or directory/i;
    return 'lease-absent' unless defined $expected_path && length $expected_path;
    my ($named) = ($output =~ /['"]([^'"]+)['"]/);
    return 'lease-absent' unless defined $named && length $named;
    return ($named eq $expected_path) ? 'lease-absent' : 'path-rewritten';
}

# new(start => \&start, stop => \&stop, on_event => \&on_event) — a lifecycle
# holder.
#   start->()        spawns the wake-lock helper, returns an opaque handle (PID).
#   stop->($handle)  releases it (kills the helper).
#   on_event->(%event) — s16-fleet-event-source: an optional emit seam, called
#     ONLY on a state TRANSITION (acquire/release), never on a repeated sync(1)
#     while already held nor a repeated sync(0) while already released -- that
#     would flood the activity panel with duplicates (the exact heartbeat-noise
#     problem s17 fixes elsewhere). Defaults to a no-op so existing callers that
#     don't pass it are unaffected. Never dies: a broken on_event coderef must
#     not take down the keep-awake lifecycle it's merely observing.
#   alive->($handle) -- OPTIONAL. 1 while the helper behind $handle is still
#     running. Consulted only by held(); with no seam, a defined handle is
#     taken on trust (the pre-existing behaviour, kept for Windows).
# All of them default to no-ops so a holder is always safe to construct/sync.
sub new {
    my ($class, %a) = @_;
    return bless {
        start    => $a{start}    || sub { undef },
        stop     => $a{stop}     || sub { },
        on_event => $a{on_event} || sub { },
        alive    => (ref $a{alive} eq 'CODE' ? $a{alive} : undef),
        running  => 0,
        handle   => undef,
        # s21: consecutive 'probe-failed' streak seen by on_probe. Reset by
        # any non-probe-failed result; never touched by plain sync() callers.
        probe_fail_streak => 0,
    }, $class;
}

sub running { return $_[0]{running} ? 1 : 0 }
sub handle  { return $_[0]{handle} }

# held() -> 1|0: is a wake-lock ACTUALLY in force, as opposed to wanted?
#
# running() answers "did we decide to hold one", and it stays 1 even when the
# start seam produced nothing -- a missing helper, a failed fork, or a host
# with no wake-lock mechanism at all. The dashboard rendered running() as
# "held", so a Mac (whose start seam exec'd a powershell.exe that does not
# exist there) showed a wake-lock that was never taken. held() requires a real
# handle, and, when an alive seam was supplied, a helper that is still alive.
#
# A helper found dead has its handle dropped here, so the eventual stop() can
# never signal a pid the OS has since handed to an unrelated process. running
# stays 1 until the next sync(0); the following sync(1) then starts a fresh
# helper. Nothing is respawned from inside held() itself.
sub held {
    my ($self) = @_;
    return 0 unless $self->{running} && defined $self->{handle};
    my $alive = $self->{alive};
    return 1 unless $alive;
    my $ok = eval { $alive->($self->{handle}) };
    return 1 if $ok;
    $self->{handle} = undef;
    return 0;
}

# sync($want, %extra) — converge the helper to the desired state. Idempotent:
# starts when wanted and not running, stops when running and not wanted, else
# does nothing. Returns the action taken: 'start' | 'stop' | 'noop'. A start
# whose seam returns undef still flips to running (the seam owns its own
# failure logging); callers that need start-failure detection should check
# the handle.
#
# s21: %extra is an OPTIONAL trailing pairs list, backward-compatible with
# every existing one-argument call site (defaults to empty, changing nothing
# for them). When given, it is merged into the on_event payload -- but ONLY
# on a genuine transition (acquire/release), never on a 'noop' -- so on_probe
# can carry a release REASON (e.g. lease-absent vs container-gone, C3) into
# the log without adding a second emit path.
sub sync {
    my ($self, $want, %extra) = @_;
    if ($want && !$self->{running}) {
        $self->{handle}  = $self->{start}->();
        $self->{running} = 1;
        eval { $self->{on_event}->(kind => 'acquire', %extra); 1 };
        return 'start';
    }
    if (!$want && $self->{running}) {
        $self->{stop}->($self->{handle});
        $self->{handle}  = undef;
        $self->{running} = 0;
        eval { $self->{on_event}->(kind => 'release', %extra); 1 };
        return 'stop';
    }
    return 'noop';
}

# on_probe(\%result, $stale, $tolerance) -> 'start' | 'stop' | 'noop'
#   $result    : the three(+ok)-state probe struct (spec S2.1):
#                  { state => 'ok',            age => $seconds }
#                  { state => 'lease-absent'                  }
#                  { state => 'probe-failed',  detail => $str }
#                  { state => 'container-gone', detail => $str }
#   $stale     : the freshness window, forwarded to should_stay_awake unchanged.
#   $tolerance : consecutive 'probe-failed' results to HOLD through before
#                releasing (S2.3). Caller-supplied, never defaulted off a
#                launcher.pl constant -- mirrors should_stay_awake's $stale.
#
# This is a layer ABOVE should_stay_awake/sync, not a replacement (C6): it is
# the one piece of new decision logic this package adds, and it is the only
# thing that ever sees the three-state struct. A bare 'ok' delegates straight
# to the unchanged pure decision; the other three states are handled here.
#
# 'probe-failed' HOLDS (returns 'noop' with NO sync() call at all -- not even
# a no-op transition attempt, and critically no on_event emission) while the
# consecutive streak is <= $tolerance. Once the streak exceeds $tolerance, it
# releases the lock directly (bypassing sync()/on_event) -- the sustained-
# failure release is a safety valve, not an operator-visible transition; it
# only ever fires once (subsequent probe-failed calls see !running and stay a
# silent 'noop'). Any non-probe-failed result resets the streak to 0.
sub on_probe {
    my ($self, $result, $stale, $tolerance) = @_;
    my $state = (ref $result eq 'HASH') ? ($result->{state} // '') : '';

    if ($state eq 'ok') {
        $self->{probe_fail_streak} = 0;
        my $stay = should_stay_awake($result->{age}, $stale);
        return $self->sync($stay ? 1 : 0);
    }
    if ($state eq 'lease-absent') {
        $self->{probe_fail_streak} = 0;
        return $self->sync(0, reason => 'lease-absent');
    }
    if ($state eq 'container-gone') {
        $self->{probe_fail_streak} = 0;
        my %extra = (reason => 'container-gone');
        $extra{detail} = $result->{detail} if defined $result->{detail};
        return $self->sync(0, %extra);
    }
    if ($state eq 'probe-failed') {
        $tolerance = 0 unless defined $tolerance && $tolerance =~ /^\d+(?:\.\d+)?$/;
        $self->{probe_fail_streak}++;
        if ($self->{probe_fail_streak} > $tolerance) {
            # Route through sync() rather than stopping directly. A sustained
            # failure giving up on the lock IS a state transition, so it must
            # emit like every other one -- an earlier version called stop()
            # inline and emitted nothing, which would have made the single most
            # interesting release in this package invisible in the activity
            # panel. sync() is also the one place that owns handle/running, so
            # bypassing it risked those drifting apart.
            return $self->sync(0, reason => 'probe-failed-sustained',
                                   streak => $self->{probe_fail_streak});
        }
        return 'noop';
    }
    # Unrecognised state (e.g. a typo'd spelling): the safest response is to
    # do nothing rather than guess -- never touch the streak or the lock.
    return 'noop';
}

# release — unconditional stop (dashboard exit / signal / END). Safe to call when
# not running. Equivalent to sync(0) but reads clearer at teardown sites.
sub release { return $_[0]->sync(0) }

# orphan_is_ours($cmdline, $marker) -> 1|0  (Decision #10)
#   Returns 1 iff both arguments are defined and $marker is a case-insensitive
#   substring of $cmdline; 0 otherwise. undef or empty $cmdline -> 0, no warning.
#   Used by _keepawake_reap_orphan to confirm a recycled pid still owns our
#   keep-awake.ps1 before sending taskkill.
sub orphan_is_ours {
    my ($cmdline, $marker) = @_;
    return 0 unless defined $cmdline && defined $marker;
    return 0 unless length($cmdline) && length($marker);
    return index(lc($cmdline), lc($marker)) >= 0 ? 1 : 0;
}

# filetime_ticks($unix_seconds) -> decimal string | undef
#   UTC FILETIME ticks (100ns units since 1601-01-01) for a Unix time, as
#   keep-awake.ps1's -OwnerStartedBeforeTicks expects. Pure arithmetic: no
#   process is spawned (asking Windows for the owner's exact start time costs a
#   powershell.exe on the spawn path, measured to slow helper handover enough
#   to break lease-refresher-hygiene.t under load). Fractional
#   seconds are kept to 100ns resolution as far as a double allows; the helper
#   applies a 2s slack, so the rounding never matters. undef for anything that
#   is not a non-negative number.
#
#   CALLER CONTRACT: pass your own clock reading, taken while the owner is
#   certainly alive and before forking the helper -- for a self-owned helper,
#   simply "now" in the parent. A WINPID reused after the owner dies belongs to
#   a process created after that reading, which the helper then rejects.
sub filetime_ticks {
    my ($t) = @_;
    return undef unless defined($t) && !ref($t) && $t =~ /\A\d+(?:\.\d+)?\z/;
    return sprintf('%.0f', ($t + 11644473600) * 10_000_000);
}


# `perl KeepAwake.pm hold ...` -- the macOS holder's entry point for an owner
# that is not bp-keepawake.pl (the launcher; see holder_argv). Loading this
# module (every other use) never reaches it.
unless (caller) {
    if (@ARGV && $ARGV[0] eq 'hold') {
        shift @ARGV;
        exit hold_main(@ARGV);
    }
    print STDERR "usage: perl KeepAwake.pm hold --pid-file F [--log-file L] [--lease S] [--owner-pid P]\n";
    exit 2;
}

1;
