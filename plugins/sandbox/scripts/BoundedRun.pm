package BoundedRun;
# BoundedRun -- run one external command with a ceiling on how long it may
# take, and kill it (its whole process tree) when it goes past that ceiling.
#
# WHY THIS EXISTS (bug report 20261110-165535-d71b). On 2026-11-10 the WSL VM
# under podman wedged: `podman machine list`, `podman ps` and
# `wsl -d podman-machine-default -- echo` all hung. The launcher's
# `podman image inspect claude-sandbox:latest` was a bare backtick, so it hung
# too, and the operator watched "skills, plugins and MCP: pending" with
# "(no output yet)" forever -- indistinguishable from a slow build. Every
# podman call the launcher makes before the dashboard now goes through here.
#
# TWO KINDS OF BOUND, because two kinds of podman call exist:
#
#   timeout       wall clock. For calls that answer in a second or two when
#                 healthy (inspect, ps, info, machine list) and for state
#                 changes that finish in seconds (create, start, rm -f).
#   idle_timeout  INACTIVITY. For calls whose healthy duration is unbounded
#                 but which stream output while they work (podman build, a
#                 backpack install over podman exec). A wall clock there would
#                 kill a legitimate twenty-minute build; "no output for M
#                 minutes" kills only a call that has stopped making progress.
#
# WHY A FILE AND NOT A PIPE. The child's stdout/stderr go to temp files that
# the parent polls. A pipe would be simpler to read, but a grandchild that
# inherited its write end (podman.exe can spawn helpers) keeps it open after
# the child is killed, and the parent's read would then block forever -- the
# very hang this module exists to remove. A file cannot block a reader.
#
# KILLING ON WINDOWS (Git-for-Windows perl, $^O cygwin/msys). Measured on this
# host, 2026-11-10: kill('KILL', $msys_pid) DOES terminate the native exe the
# fork exec'd -- but not its children; a `cmd.exe /c ping.exe` tree left
# ping.exe running. So the tree is killed with `taskkill /F /T /PID <winpid>`.
# taskkill takes a WINPID, and perl's pids are MSYS pids (repo CLAUDE.md,
# "A pid is only meaningful in the namespace that produced it"), so the WINPID
# is read from /proc/<msys pid>/winpid -- the one place MSYS itself maps one to
# the other. kill('KILL', $msys_pid) then follows as a backstop, and the
# result is verified the only way that is honest: waitpid on the MSYS pid, in
# the namespace it came from.
#
# The Windows tree is NOT the whole tree. A shell-string command (the
# backtick form) runs as sh -> podman; MSYS's fork+exec gives that grandchild a
# Windows parent that has already exited, so `taskkill /T` from sh's WINPID
# never reaches it. Measured, same day: every timed-out shell-string fake
# survived the first version of this. So descendants are ALSO collected in the
# MSYS namespace (/proc/<pid>/ppid) before anything is killed, and each gets
# both treatments. The child also leads its own process group (POSIX and
# MSYS alike), and the group is killed.
#
# PURE ENOUGH TO TEST. The clock, the sleep and the tree-kill are seams;
# everything else is real processes, so a test drives it with fake podman
# scripts that sleep forever, answer at once, or stream slowly.
use strict;
use warnings;
use POSIX ();
use File::Spec ();
use File::Temp ();
use IO::Handle ();

my $HIRES = eval { require Time::HiRes; 1 } ? 1 : 0;

sub _now   { return $HIRES ? Time::HiRes::time() : time() }
sub _sleep { my ($s) = @_; select(undef, undef, undef, $s); return 1 }

# The exit status a timed-out run reports, in $? convention: 124 is GNU
# timeout's own "timed out" code, which the launcher's other bounded probes
# (`timeout N podman ...`) already produce, so one number means one thing.
sub TIMEOUT_RC { return 124 << 8 }

# ---------------------------------------------------------------------------
# Limits per call kind.
#
#   probe   20 s  the preflight responsiveness probe. Healthy: under a second.
#                 The bug report measured the wedged calls "hung past 20-25 s",
#                 and a cold-but-healthy socket answers in a few seconds.
#   query   30 s  inspect / ps / info / machine list. Healthy: 0.1-2 s. 30 s
#                 is an order of magnitude of slack for a loaded VM.
#   mutate 180 s  create / start / rm -f / exec of a short command. Healthy:
#                 seconds; rm -f of a running container waits podman's own
#                 10 s stop timeout first. 180 s matches the launcher's
#                 existing `podman machine start` bound, the slowest healthy
#                 podman operation it already measured.
#   stream        build / pull / a backpack install. NO wall clock; idle
#                 watchdog of 15 min. A build step streams output as it goes,
#                 but some steps are silent for minutes (a large download with
#                 no progress bar, committing a multi-GB layer), so the bound
#                 is generous: it exists to end "forever", not to police speed.
#
# Each is overridable from the environment, digits only, so a slow host can
# widen one without a code change.
# ---------------------------------------------------------------------------
my %LIMITS = (
    probe  => { timeout => 20 },
    query  => { timeout => 30 },
    mutate => { timeout => 180 },
    stream => { idle_timeout => 900 },
);
my %ENV_KEY = (
    probe  => 'SANDBOX_PODMAN_PROBE_TIMEOUT',
    query  => 'SANDBOX_PODMAN_QUERY_TIMEOUT',
    mutate => 'SANDBOX_PODMAN_MUTATE_TIMEOUT',
    stream => 'SANDBOX_PODMAN_IDLE_TIMEOUT',
);

sub KINDS { return [ sort keys %LIMITS ] }

# limits($kind, \%env) -> (timeout => S) or (idle_timeout => S). An unknown
# kind is treated as 'query': a bound that is too tight fails loudly, while no
# bound at all is the bug.
sub limits {
    my ($kind, $env) = @_;
    $kind = 'query' unless defined $kind && exists $LIMITS{$kind};
    $env  = {} unless ref $env eq 'HASH';
    my %l = %{ $LIMITS{$kind} };
    my $v = $env->{ $ENV_KEY{$kind} };
    if (defined $v && $v =~ /\A\d+\z/ && $v > 0) {
        my ($k) = keys %l;
        $l{$k} = $v + 0;
    }
    return %l;
}

# podman_kind(@argv_after_binary) -> 'query' | 'mutate' | 'stream'.
# Classifies a podman (or docker) command line by its subcommand, skipping
# leading global options. Used where one helper runs many different podman
# calls (the launcher's _tee_system / _capture_out_err).
sub podman_kind {
    my @a = grep { defined } @_;
    # Skip global options; the ones that take a separate value skip it too.
    while (@a && $a[0] =~ /\A-/) {
        my $opt = shift @a;
        shift @a if @a && $opt =~ /\A--?(?:log-level|connection|c|url|identity|root|runroot|storage-driver|cgroup-manager|events-backend|tmpdir)\z/;
    }
    my $sub = lc(shift(@a) // '');
    if ($sub eq 'image' || $sub eq 'container' || $sub eq 'machine' || $sub eq 'system') {
        my $sub2 = lc(shift(@a) // '');
        return 'stream' if $sub eq 'image' && ($sub2 eq 'build' || $sub2 eq 'pull' || $sub2 eq 'push');
        return 'query'  if $sub2 =~ /\A(?:inspect|ls|list|exists|info|df)\z/;
        return 'mutate';
    }
    return 'stream' if $sub =~ /\A(?:build|buildx|pull|push|load|import|save)\z/;
    return 'query'  if $sub =~ /\A(?:inspect|ps|info|version|images|port|top|exists)\z/;
    return 'mutate';
}

sub _devnull { return File::Spec->devnull }

# _winpid($msys_pid) -> the Windows pid of the process MSYS knows as
# $msys_pid, or undef. /proc/<pid>/winpid is MSYS's own mapping.
sub _winpid {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /\A\d+\z/;
    open my $fh, '<', "/proc/$pid/winpid" or return undef;
    my $w = <$fh>;
    close $fh;
    return undef unless defined $w;
    $w =~ s/\s+//g;
    return $w =~ /\A\d+\z/ ? $w : undef;
}

sub _taskkill_bin {
    for my $root (grep { defined && length } ($ENV{SYSTEMROOT}, $ENV{SystemRoot}, 'C:/Windows')) {
        (my $r = $root) =~ s{\\}{/}g;
        my $p = "$r/System32/taskkill.exe";
        return $p if -e $p;
    }
    return 'taskkill.exe';
}

# _descendants($pid) -> every live descendant of $pid in the MSYS/POSIX pid
# namespace, read from /proc (cygwin/MSYS: /proc/<pid>/ppid; Linux: the 4th
# field of /proc/<pid>/stat). Empty where there is no /proc.
sub _descendants {
    my ($root) = @_;
    return () unless -d '/proc';
    my %kids;
    opendir(my $dh, '/proc') or return ();
    for my $p (grep { /\A\d+\z/ } readdir $dh) {
        my $pp;
        if (open my $fh, '<', "/proc/$p/ppid") { $pp = <$fh>; close $fh }
        elsif (open my $sh, '<', "/proc/$p/stat") { my $st = <$sh> // ''; close $sh; ($pp) = $st =~ /\)\s+\S+\s+(\d+)/ }
        next unless defined $pp;
        $pp =~ s/\s+//g;
        push @{ $kids{$pp} }, $p if $pp =~ /\A\d+\z/;
    }
    closedir $dh;
    my (@out, %seen);
    my @queue = ($root);
    while (@queue) {
        my $p = shift @queue;
        for my $k (@{ $kids{$p} || [] }) {
            next if $seen{$k}++;
            push @out, $k;
            push @queue, $k;
        }
    }
    return @out;
}

# _taskkill(@winpids) -- one bounded `taskkill /F /T` over all of them.
sub _taskkill {
    my (@wp) = grep { defined } @_;
    return 0 unless @wp;
    # MSYS would rewrite /F, /T and /PID as paths without this; scoped, never
    # shell-wide (repo CLAUDE.md, MSYS2 path conversion).
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $tk = fork();
    return 0 unless defined $tk;
    if ($tk == 0) {
        open(STDIN,  '<', _devnull());
        open(STDOUT, '>', _devnull());
        open(STDERR, '>', _devnull());
        no warnings 'exec';
        exec { _taskkill_bin() } 'taskkill.exe', '/F', '/T', map { ('/PID', $_) } @wp;
        POSIX::_exit(127);
    }
    my $until = _now() + 10;
    while (_now() < $until) {
        my $w = waitpid($tk, POSIX::WNOHANG());
        return 1 if $w == $tk || $w == -1;
        _sleep(0.05);
    }
    kill('KILL', $tk);
    waitpid($tk, POSIX::WNOHANG());
    return 1;
}

# kill_tree($pid, $windows) -> 1. Never blocks for more than ~10 s.
#
# Descendants are collected FIRST: once a parent dies its children are
# reparented to 1 and can no longer be found from it.
sub kill_tree {
    my ($pid, $windows) = @_;
    return 0 unless defined $pid && $pid =~ /\A\d+\z/ && $pid > 0;
    my @all = ($pid, _descendants($pid));
    kill('STOP', @all[1 .. $#all]) if @all > 1 && !$windows;   # no new forks while we work
    _taskkill(map { _winpid($_) } @all) if $windows;
    kill('KILL', -$pid);          # the child leads its own process group
    kill('KILL', reverse @all);   # backstop, MSYS/POSIX pids, same namespace as waitpid
    return 1;
}

# The children run() has spawned and not yet reaped. A Ctrl-C (or HUP) that
# ends the launcher mid-call must not leave them behind: the child leads its
# own process group, so the terminal's SIGINT no longer reaches it. The
# launcher's teardown and END call kill_active().
#
# kill_active may run from inside a run() (a signal handler, or a test's
# on_tick), so a status it reaps is handed back through %REAPED rather than
# lost: run()'s own waitpid would otherwise see -1 and report "not reaped".
my (%ACTIVE, %REAPED);
sub active_pids { return [ sort { $a <=> $b } keys %ACTIVE ] }
sub kill_active {
    for my $pid (keys %ACTIVE) {
        eval {
            kill_tree($pid, $ACTIVE{$pid});
            my $until = _now() + 2;
            while (_now() < $until) {
                my $w = waitpid($pid, POSIX::WNOHANG());
                if ($w == $pid) { $REAPED{$pid} = $?; last }
                last if $w == -1;
                _sleep(0.02);
            }
            1;
        };
        delete $ACTIVE{$pid};
    }
    return 1;
}

# _drain($fh, \$pos) -> the bytes appended to the file since the last call.
sub _drain {
    my ($fh, $posref) = @_;
    return '' unless $fh;
    my $acc = '';
    sysseek($fh, $$posref, 0);
    while (1) {
        my $n = sysread($fh, my $buf, 65536);
        last unless $n;
        $acc .= $buf;
        $$posref += $n;
    }
    return $acc;
}

# run(%o) -> \%result
#
#   cmd           ARRAY ref (list form, exec'd directly) or a STRING (exec'd
#                 the way a backtick is: through /bin/sh when it has shell
#                 metacharacters). Required.
#   timeout       wall-clock seconds, or undef for none.
#   idle_timeout  seconds without any new stdout/stderr byte, or undef.
#   merge         stderr joins stdout (one stream, in order).
#   on_output     coderef called with each complete line (and the final
#                 partial one) of stdout as it arrives.
#   on_tick       coderef called with the elapsed seconds about every poll,
#                 so a caller can repaint a "still running, 40s" display.
#   poll          seconds between polls (default 0.1).
#   reap_grace    seconds to wait for the killed child to be reaped (5).
#   windows       true on Git-for-Windows perl (defaults from $^O).
#   now, sleep, kill_tree   seams for tests.
#
# Result: rc ($? convention; TIMEOUT_RC on a timeout, -1 when the spawn
# failed), out, err, timed_out (0|1), reason ('timeout' | 'idle' | undef),
# limit (the seconds of the bound that fired), elapsed, reaped (0|1), pid.
sub run {
    my (%o) = @_;
    my $cmd = $o{cmd};
    my $res = { rc => -1, out => '', err => '', timed_out => 0, reason => undef,
                limit => undef, elapsed => 0, reaped => 0, pid => undef };
    unless ((ref $cmd eq 'ARRAY' && @$cmd) || (defined $cmd && !ref $cmd && length $cmd)) {
        $res->{err} = 'no command given';
        return $res;
    }
    my $windows = exists $o{windows} ? $o{windows} : ($^O =~ /\A(?:MSWin32|cygwin|msys)\z/ ? 1 : 0);
    my $now     = ref $o{now}       eq 'CODE' ? $o{now}       : \&_now;
    my $sleep   = ref $o{sleep}     eq 'CODE' ? $o{sleep}     : \&_sleep;
    my $killer  = ref $o{kill_tree} eq 'CODE' ? $o{kill_tree} : \&kill_tree;
    my $poll    = (defined $o{poll} && $o{poll} =~ /\A[\d.]+\z/ && $o{poll} > 0) ? $o{poll} : 0.1;
    my $grace   = (defined $o{reap_grace} && $o{reap_grace} =~ /\A[\d.]+\z/) ? $o{reap_grace} : 5;
    my $wall    = (defined $o{timeout}      && $o{timeout}      =~ /\A[\d.]+\z/ && $o{timeout}      > 0) ? $o{timeout}      : undef;
    my $idle    = (defined $o{idle_timeout} && $o{idle_timeout} =~ /\A[\d.]+\z/ && $o{idle_timeout} > 0) ? $o{idle_timeout} : undef;
    my $merge   = $o{merge} ? 1 : 0;

    my ($ofh, $opath) = eval { File::Temp::tempfile('ccpraxis-brun-XXXXXX', TMPDIR => 1, UNLINK => 0) };
    unless ($ofh) { $res->{err} = "cannot create a capture file: $@"; return $res }
    close $ofh;
    my $epath;
    unless ($merge) {
        my $efh;
        ($efh, $epath) = eval { File::Temp::tempfile('ccpraxis-brun-XXXXXX', TMPDIR => 1, UNLINK => 0) };
        unless ($efh) { unlink $opath; $res->{err} = "cannot create a capture file: $@"; return $res }
        close $efh;
    }

    # Flush before forking so buffered parent output is not written twice.
    eval { STDOUT->flush; STDERR->flush; 1 };
    my $pid = fork();
    unless (defined $pid) {
        unlink grep { defined } ($opath, $epath);
        $res->{err} = "fork failed: $!";
        return $res;
    }
    if ($pid == 0) {
        # A child that cannot set itself up must not run the parent's END
        # blocks (lock release, log close) -- hence _exit everywhere.
        POSIX::setpgid(0, 0);   # own group: kill_tree kills it as one
        open(STDIN, '<', _devnull()) or POSIX::_exit(126);
        open(STDOUT, '>', $opath)    or POSIX::_exit(126);
        if ($merge) { open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126) }
        else        { open(STDERR, '>', $epath)    or POSIX::_exit(126) }
        if (ref $cmd eq 'ARRAY') { exec { $cmd->[0] } @$cmd }
        else                     { exec $cmd }
        syswrite(STDERR, "exec failed: " . (ref $cmd ? $cmd->[0] : $cmd) . ": $!\n");
        POSIX::_exit(127);
    }
    $res->{pid} = $pid;
    $ACTIVE{$pid} = $windows;

    open(my $orf, '<:raw', $opath);
    my $erf;
    open($erf, '<:raw', $epath) if defined $epath;
    my ($opos, $epos) = (0, 0);
    my ($out, $err, $partial) = ('', '', '');
    my $emit = sub {
        my ($chunk, $final) = @_;
        return unless ref $o{on_output} eq 'CODE';
        $partial .= $chunk;
        while ($partial =~ s/\A([^\n]*\n)//) { eval { $o{on_output}->($1) } }
        if ($final && length $partial) { my $p = $partial; $partial = ''; eval { $o{on_output}->($p) } }
    };
    my $pull = sub {
        my ($final) = @_;
        my $o1 = _drain($orf, \$opos);
        my $e1 = _drain($erf, \$epos);
        $out .= $o1;
        $err .= $e1;
        $emit->($o1, $final);
        return length($o1) + length($e1);
    };

    my $t0 = $now->();
    my $last_activity = $t0;
    # Start polling fast and back off to $poll: most podman queries finish in
    # well under 100 ms, and a fixed 100 ms first sleep would tax every one.
    my $nap = $poll < 0.01 ? $poll : 0.01;
    my ($status, $reason);
    while (1) {
        my $w = waitpid($pid, POSIX::WNOHANG());
        if ($w == $pid) { $status = $?; $res->{reaped} = 1; last }
        if ($w == -1)   { if (exists $REAPED{$pid}) { $status = delete $REAPED{$pid}; $res->{reaped} = 1 } else { $status = -1 } last }
        my $t = $now->();
        $last_activity = $t if $pull->(0);
        if (defined $wall && ($t - $t0) >= $wall)          { $reason = 'timeout'; $res->{limit} = $wall; last }
        if (defined $idle && ($t - $last_activity) >= $idle) { $reason = 'idle';  $res->{limit} = $idle; last }
        eval { $o{on_tick}->($t - $t0) } if ref $o{on_tick} eq 'CODE';
        $sleep->($nap);
        $nap = ($nap * 2 > $poll) ? $poll : $nap * 2;
    }

    if ($reason) {
        eval { $killer->($pid, $windows) };
        my $until = _now() + $grace;
        while (1) {
            my $w = waitpid($pid, POSIX::WNOHANG());
            if ($w == $pid) { $res->{reaped} = 1; last }
            if ($w == -1)   { $res->{reaped} = exists $REAPED{$pid} ? 1 : 0; delete $REAPED{$pid}; last }
            last if _now() >= $until;
            _sleep(0.05);
        }
        $res->{timed_out} = 1;
        $res->{reason}    = $reason;
        $status = TIMEOUT_RC();
    }
    delete $ACTIVE{$pid};
    $pull->(1);
    close $orf if $orf;
    close $erf if $erf;
    unlink grep { defined } ($opath, $epath);

    $res->{rc}      = defined $status ? $status : -1;
    $res->{out}     = $out;
    $res->{err}     = $err;
    $res->{elapsed} = $now->() - $t0;
    return $res;
}

# describe($cmd) -> a short human form of the command, for messages.
sub describe {
    my ($cmd) = @_;
    my $s = ref $cmd eq 'ARRAY' ? join(' ', map { defined $_ ? $_ : '' } @$cmd) : (defined $cmd ? $cmd : '');
    $s =~ s/\s+2>(?:&1|\/dev\/null)//g;
    $s =~ s{\A\S*[/\\]}{};          # drop a binary's directory
    $s =~ s/\s+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    $s = substr($s, 0, 77) . '...' if length($s) > 80;
    return $s;
}

sub _secs_text {
    my ($s) = @_;
    return 'n/a' unless defined $s && $s =~ /\A[\d.]+\z/;
    $s = int($s + 0.5);
    return "${s}s" if $s < 120;
    return int($s / 60) . ' min';
}

# unresponsive_lines(%o) -> the operator-facing failure text for a podman call
# that timed out. %o: cmd, reason ('timeout'|'idle'), limit, stage (a label),
# windows.
#
# The remedy ladder is ordered cheapest first. `wsl --shutdown` alone hung on
# 2026-11-10 while `wsl -l -v` still said Running, which is why the ladder
# goes past it to the service and then to a reboot.
sub unresponsive_lines {
    my (%o) = @_;
    my $what   = describe($o{cmd});
    my $limit  = _secs_text($o{limit});
    my $stage  = defined $o{stage} && length $o{stage} ? $o{stage} : undef;
    my @l;
    push @l, $o{windows}
        ? 'ERROR: podman is not responding -- the WSL VM may be wedged.'
        : 'ERROR: podman is not responding -- the podman service may be wedged.';
    if (defined $o{reason} && $o{reason} eq 'idle') {
        push @l, "  `$what` produced no output for $limit, so it was stopped.";
    } else {
        push @l, "  `$what` did not answer within $limit, so it was stopped.";
    }
    push @l, "  The launch failed at '$stage' instead of waiting forever." if defined $stage;
    push @l, '';
    if ($o{windows}) {
        push @l, '  Try these in order, running claude-sandbox again after each:',
                 '    1. wsl --shutdown --force',
                 '    2. As administrator:  Restart-Service WSLService -Force',
                 '       (or end wslservice.exe and vmmem in Task Manager)',
                 '    3. Reboot.';
    } else {
        push @l, '  Try these in order, running claude-sandbox again after each:',
                 '    1. systemctl --user restart podman.socket   (or restart your container runtime)',
                 '    2. Reboot.';
    }
    return @l;
}

1;
