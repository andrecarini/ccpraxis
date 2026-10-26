#!/usr/bin/env perl
# platform: any
# ORACLE for package 05-holder (blueprint hook-continuity-remake), H1-H16 of
# specs/05-holder-spec.md: the one continuity holder -- become/extend under a
# lock (bug 6382, stacked holders), a fingerprinted own-pid record so a
# process that never forks is the only thing counted as live (bug 2cad), the
# 50-minute deadline with no timeout parameter, item resolution against a
# transcript/output-file, and the off/signal/deadline/all-finished exits.
#
# butler-hold.pl AND bin/butler-hold DO NOT EXIST YET. Every case below spawns
# real subprocesses through `bash <repo>/bin/butler-hold ...` per the test
# rules; with the shim absent, bash reports "No such file or directory" to
# stderr and exits 127, which every case below fails on legibly (wrong exit
# code / empty or wrong stdout) rather than hanging or crashing this file.
#
# Test hygiene, mirroring plugins/butler/tests/t/continuity-command-verbs.t:
# tickets are written in-process through BpHook (real, already implemented in
# package 03); the command itself always runs as a real subprocess, spawned
# with fork + exec('bash', <shim>, @argv) per the spec's "Test rules". Every
# spawned pid is pushed onto @KILL_PIDS; the END block TERMs then KILLs
# anything left standing, routed through exit() so END always runs. HOME,
# USERPROFILE and BUTLER_STATE_DIR are pinned to tempdirs for the whole file;
# BP_*/CCPRAXIS_*/CLAUDE_* are stripped from every child. A guard assertion at
# the bottom confirms the real ~/.claude/butler-state tree was never touched.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);
use Fcntl qw(:flock);

my $S    = "$Bin/../../scripts"; $S    =~ s{\\}{/}g;
my $BIN  = "$Bin/../../bin";     $BIN  =~ s{\\}{/}g;
my $SCRIPT = "$S/butler-hold.pl";
my $SHIM   = "$BIN/butler-hold";

require "$S/BpHook.pm";   # package 03 -- real and already implemented

# ---------------------------------------------------------------------------
# process bookkeeping
# ---------------------------------------------------------------------------
my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('TERM', $pid) }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid) if kill(0, $pid) }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, 0) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ---------------------------------------------------------------------------
# fixtures / environment
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
(my $PROJECT = "$TMPROOT/proj") =~ s{\\}{/}g;
make_path($PROJECT);

# "André" as raw UTF-8 bytes (C3 A9), not the ANSI single byte -- this is the
# exact byte sequence H14 checks transcript_path is stored with, and BpHook's
# _to_bytes leaves already-valid-UTF-8 byte strings alone (never re-encodes).
my $ANDRE_SEG = "Andr\xC3\xA9";
(my $ANDRE_ROOT = "$TMPROOT/$ANDRE_SEG") =~ s{\\}{/}g;
(my $STATE_DIR  = "$ANDRE_ROOT/state") =~ s{\\}{/}g;

# A decoy HOME/USERPROFILE, never the operator's real profile, for defense in
# depth even though BUTLER_STATE_DIR is set explicitly for almost every case.
my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};
my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
{
    my $rh = (defined $REAL_HOME && length $REAL_HOME) ? $REAL_HOME
           : (defined $REAL_USERPROFILE && length $REAL_USERPROFILE) ? $REAL_USERPROFILE
           : undef;
    if (defined $rh) {
        (my $rh_n = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE = "$rh_n/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
    }
}
my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME}             = $FAKE_HOME;
$ENV{USERPROFILE}      = $FAKE_HOME;
$ENV{BUTLER_STATE_DIR} = $STATE_DIR;
$ENV{BUTLER_HOLD_TEST_MODE} = 1;
# never-halt 06 (AC-19): a fixture, never-existing data root, so
# butler-hold's prompt-watch resolution (BpDataRoot::resolve) is exercised
# hermetically and stays OFF, leaving this file's own assertions unchanged.
$ENV{CCPRAXIS_DATA_DIR} = "$TMPROOT/no-prompt-watch-data";

my $CONT_ROOT = "$STATE_DIR/continuity";

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
my $TUID_N = 0;
sub next_tuid { return sprintf('tu%06x', ++$TUID_N) }

sub sid8 { return substr($_[0], 0, 8) }

sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub lines_of {
    my ($text) = @_;
    my @l = split /\n/, $text;
    pop @l while @l && $l[-1] eq '';
    return @l;
}

# write_ticket_for(sid, argv, %opts) -- in-process, exactly as the caller
# would through BpHook::write_ticket.
sub write_ticket_for {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path},
        cwd             => $o{cwd} // $PROJECT,
    };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    my $ok = BpHook::write_ticket($p, 'butler-hold', $argv,
        operator => ($o{operator} ? 1 : 0), background => (exists $o{background} ? $o{background} : 1));
    return ($ok, $tuid);
}

sub find_ticket_file {
    my ($sid, $tuid) = @_;
    my @found = glob("$CONT_ROOT/tickets/*/$sid.$tuid.json");
    return $found[0];
}

# spawn_hold(\@argv, \%env_over) -> ($pid, $outfile, $errfile). Exactly the
# invocation shape the spec's "Test rules" require: fork + exec('bash',
# <shim>, @argv). Never waits.
sub spawn_hold {
    my ($argv, $env_over) = @_;
    $env_over //= {};
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME}                  = $FAKE_HOME;
        $ENV{USERPROFILE}           = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE} = 1;
        $ENV{CCPRAXIS_DATA_DIR}     = "$TMPROOT/no-prompt-watch-data";
        for my $k (keys %$env_over) {
            if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} }
            else                          { delete $ENV{$k} }
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('bash', $SHIM, @$argv);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
}

sub wait_pid_bounded {
    my ($pid, $timeout) = @_;
    my $deadline = time() + $timeout;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    return $rc;
}

my %STDERR_LOG;

# run_hold(label, \@argv, \%env_over, %o) -> (out, err, rc). Spawns, waits to
# exit (bounded), reaps, records stderr under label for the H15 sweep.
sub run_hold {
    my ($label, $argv, $env_over, %o) = @_;
    my ($pid, $outfile, $errfile) = spawn_hold($argv, $env_over);
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, $o{timeout} // 30);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    $STDERR_LOG{$label} = $err;
    return ($out, $err, $rc);
}

# reap_and_log(label, pid, outfile, errfile, sig) -- for long-lived "become"
# processes started with spawn_hold() and left running; sends $sig (default
# TERM), waits, reaps, logs stderr.
sub reap_and_log {
    my ($label, $pid, $outfile, $errfile, $sig) = @_;
    $sig //= 'TERM';
    kill($sig, $pid) if kill(0, $pid);
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    $STDERR_LOG{$label} = $err;
    return ($out, $err, $rc);
}

# wait_for_holder(sid, timeout) -> hash or undef. Polls BpHook::holder().
sub wait_for_holder {
    my ($sid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $h = BpHook::holder($sid);
        return $h if ref $h eq 'HASH';
        sleep(0.02);
    }
    return undef;
}

# wait_for_new_holder(sid, old_pid, timeout) -> hash or undef. Like
# wait_for_holder, but rejects a stale record left behind by a dead holder
# (e.g. after SIGKILL, §5 "holder killed" -- the record stays but fails
# proc_alive): it only returns once the record's pid differs from $old_pid,
# so callers actually observe the NEW holder rather than the old corpse.
sub wait_for_new_holder {
    my ($sid, $old_pid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $h = BpHook::holder($sid);
        return $h if ref $h eq 'HASH' && $h->{pid} != $old_pid;
        sleep(0.02);
    }
    return undef;
}

sub wait_for_no_holder {
    my ($sid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 unless ref BpHook::holder($sid) eq 'HASH';
        sleep(0.02);
    }
    return 0;
}

# wait_for_stdout_line(outfile, pattern, timeout) -> the file's content once
# it matches $pattern (or the last content read, on timeout). The holder
# writes its holder/<sid>.json record BEFORE printing the "holding session
# ... until"/"extended holder of session ..." line -- the correct order, so
# BpHook::holder() (polled by wait_for_holder/wait_for_new_holder) can observe
# the record microseconds before the child's own stdout write actually lands
# on disk. Under load that gap is real, not theoretical (bug: H10b flaked
# under `scripts/run-tests.pl`'s parallel workers). Poll the file itself,
# bounded, rather than trusting a single slurp right after wait_for_holder().
sub wait_for_stdout_line {
    my ($outfile, $pattern, $timeout) = @_;
    $timeout //= 10;
    my $deadline = time() + $timeout;
    my $content = '';
    while (time() < $deadline) {
        $content = slurp($outfile);
        return $content if $content =~ $pattern;
        sleep(0.05);
    }
    return $content;
}

# ---------------------------------------------------------------------------
# transcript / evidence fixtures (§2.7, DC2)
# ---------------------------------------------------------------------------

# write_transcript(path, %opts) -- raw-mode lines. finished => [ids marked
# completed via <task-id>/<status> tags], bg_output => [id, real_path] for an
# "Output is being written to:" line, pad_bytes => bytes of filler appended
# after everything else (to push earlier lines out of the TAIL_BYTES window).
sub write_transcript {
    my ($path, %o) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    for my $fid (@{ $o{finished} // [] }) {
        print {$fh} "<task-notification><task-id>$fid</task-id><status>completed</status></task-notification>\n";
    }
    if (my $bg = $o{bg_output}) {
        my ($id, $real_path) = @$bg;
        # Only rewrite to backslash form when $real_path already carries a
        # drive letter (a genuine Windows absolute path) -- converting EVERY
        # slash, including a bare leading "/", destroys the only anchor the
        # spec's output-path regex requires (`(?:[A-Za-z]:|/)...`), leaving a
        # string that matches neither the Windows nor the POSIX form. On
        # this host File::Temp's tempdir() can return a bare "/tmp/..." path
        # (no drive letter) even though the OS is Windows, so a real_path
        # without a drive letter is left in its (equally valid, per the
        # regex's own "/" alternative) forward-slash form instead.
        my $winpath = ($real_path =~ m{^[A-Za-z]:}) ? do { (my $w = $real_path) =~ s{/}{\\}g; $w }
                                                     : $real_path;
        print {$fh} "Output is being written to: $winpath\n";
    }
    if (my $n = $o{pad_bytes}) {
        print {$fh} ('.' x $n) . "\n";
    }
    close $fh;
}

sub append_transcript {
    my ($path, $text) = @_;
    open my $fh, '>>:raw', $path or die "open $path: $!";
    print {$fh} $text;
    close $fh;
}

sub write_output_file {
    my ($path, $mtime) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} "output\n";
    close $fh;
    utime($mtime, $mtime, $path) if defined $mtime;
    return $path;
}

sub write_subagent_files {
    my ($sessiondir, $agent_id, $mtime) = @_;
    make_path("$sessiondir/subagents");
    for my $ext (qw(jsonl meta.json)) {
        my $p = "$sessiondir/subagents/agent-$agent_id.$ext";
        open my $fh, '>:raw', $p or die "open $p: $!";
        print {$fh} "{}\n";
        close $fh;
        utime($mtime, $mtime, $p) if defined $mtime;
    }
    return "$sessiondir/subagents/agent-$agent_id.jsonl";
}

sub transcript_path_for { my ($sid) = @_; return "$PROJECT/$sid.jsonl" }
sub sessiondir_for      { my ($sid) = @_; return "$PROJECT/$sid" }

# ===========================================================================
# H1 (DC1) -- become writes a record with its own pid; holder_live agrees.
# ===========================================================================
my $H1_SID = 'hold-h1-sid';
{
    my $tp = transcript_path_for($H1_SID);
    write_transcript($tp, finished => [], bg_output => undef);
    write_subagent_files(sessiondir_for($H1_SID), 'S', time());

    my @argv = ('agent-S', 'B');
    write_ticket_for($H1_SID, \@argv, transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_hold(\@argv,
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    $main::H1_PID     = $pid;
    $main::H1_OUTFILE = $outfile;
    $main::H1_ERRFILE = $errfile;

    my $h = wait_for_holder($H1_SID, 10);
    ok(defined $h, 'H1: a live record appears after a valid background become');
    SKIP: {
        skip 'H1: no record to inspect', 4 unless defined $h;
        is($h->{pid}, $pid, 'H1: the record pid equals the spawned childs own pid -- it did not fork');
        is_deeply($h->{items}, ['S', 'B'], 'H1: items are [S,B] -- agent-S normalized to S');
        cmp_ok(abs(($h->{deadline} - $h->{started_at}) - 30), '<=', 1,
            'H1: deadline - started_at is (about) the 30s test-seam duration');
    }

    my $out = wait_for_stdout_line($outfile, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($H1_SID)]}\E until/m, 10);
    like($out, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($H1_SID)]}\E until/m,
        "H1: stdout's first line starts '<T> holding session <sid8> until'");

    is(BpHook::holder_live($H1_SID, { background_tasks => [{ id => 'S', type => 'subagent', status => 'running' }] }), 1,
        'H1: holder_live is 1 when p lists a held id as running');
    is(BpHook::holder_live($H1_SID, {}), 1, 'H1: holder_live is 1 with no background_tasks array at all');

    is(BpHook::holder_live('hold-h1-other-sid', { background_tasks => [{ id => 'S', type => 'subagent', status => 'running' }] }), 0,
        'H1: holder_live is 0 for an unrelated sid, empty store');

    # sid2 with its own unrelated holder present.
    my $sid2 = 'hold-h1-sid2';
    write_ticket_for($sid2, ['Q'], transcript_path => transcript_path_for($sid2), background => 1);
    my ($pid2, $out2f, $err2f) = spawn_hold(['Q'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid2;
    wait_for_holder($sid2, 10);
    is(BpHook::holder_live($H1_SID, { background_tasks => [{ id => 'S', type => 'subagent', status => 'running' }] }), 1,
        "H1: sid2's own unrelated holder present does not disturb this sid's holder_live");
    reap_and_log('H1-sid2-cleanup', $pid2, $out2f, $err2f);
    is(BpHook::holder_live($sid2, {}), 0, 'H1: sid2 holder_live is 0 after its own holder is TERM-ed and reaped');
}

# ===========================================================================
# H2 (DC1, handover) -- the zero-gap proof: sampled every 10ms across a whole
# second invocation, never 0, ends at exactly 1.
# ===========================================================================
{
    my $pid = $main::H1_PID;
    my $p_running = { background_tasks => [{ id => 'S', type => 'subagent', status => 'running' }] };

    ok(BpHook::holder_live($H1_SID, $p_running) == 1, 'H2: precondition -- H1s holder is alive going in');

    my @samples;
    push @samples, BpHook::holder_live($H1_SID, $p_running);   # sample BEFORE spawning the second invocation

    # RV-M3 fix: capture the pre-extend record so the fp/token/deadline
    # invariants spec H2 actually requires ("the record has the same pid, fp
    # and token ... and a deadline no lower than before") can be checked
    # below, rather than only pid and items.
    my $h_before = BpHook::holder($H1_SID);
    ok(ref $h_before eq 'HASH', 'H2: precondition -- captured the pre-extend record');

    # A binding is required or this invocation refuses with "no session
    # binding" instead of extending -- give it one exactly the way H1's first
    # invocation got one, so this really exercises the EXTEND path.
    write_ticket_for($H1_SID, ['B2'], transcript_path => transcript_path_for($H1_SID), background => 1);

    # RV-M3 fix: the extender's OWN seam must be SHORTER than the time still
    # remaining on the first holder's 30s hold, or max(existing, now+HOLD) is
    # never exercised -- a plain "deadline = now + HOLD" would pass just as
    # well. 2s against H1's 30s holder forces max() to keep the EXISTING
    # (larger) deadline, so "the deadline never moves backwards" is real.
    my ($pid2, $out2f, $err2f) = spawn_hold(['B2'],
        { BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid2;

    my $reaped    = 0;
    my $post_reap = 0;
    my $rc2;
    while (1) {
        sleep(0.01);
        push @samples, BpHook::holder_live($H1_SID, $p_running);
        if (!$reaped) {
            my $w = waitpid($pid2, WNOHANG);
            if ($w == $pid2) { $reaped = 1; $rc2 = $? >> 8; @KILL_PIDS = grep { $_ != $pid2 } @KILL_PIDS }
        }
        else {
            $post_reap++;
        }
        last if $reaped && $post_reap >= 20 && @samples >= 50;
        last if @samples >= 2000;   # hard stop -- never spin forever on a stuck extend
    }

    cmp_ok(scalar(@samples), '>=', 50, 'H2: took at least 50 samples in total');
    ok($reaped, 'H2: the second invocation was reaped within the sampling window');
    ok(!(grep { $_ == 0 } @samples), 'H2: every sample of holder_live is 1, never 0, across the whole handover');
    is($samples[-1], 1, 'H2: the final sample is exactly 1');

    my $out2 = slurp($out2f);
    my $err2 = slurp($err2f);
    unlink $out2f, $err2f;
    is($rc2, 0, 'H2: the second (extending) process exits 0');
    my @out2_lines = lines_of($out2);
    is(scalar(@out2_lines), 1, 'H2: the second process prints exactly one stdout line');
    like($out2_lines[0] // '', qr/^extended the running holder \(pid \d+\) until/,
        "H2: that line starts 'extended the running holder (pid N) until'");
    is($err2, '', 'H2: the extending process stderr is empty');

    my $h = BpHook::holder($H1_SID);
    ok(ref $h eq 'HASH', 'H2: the record still resolves after the extend');
    SKIP: {
        skip 'H2: no record to inspect', 5 unless ref $h eq 'HASH' && ref $h_before eq 'HASH';
        is($h->{pid}, $pid, 'H2: same pid after extend');
        is_deeply([sort @{ $h->{items} }], [sort qw(B B2 S)], 'H2: items are now [S,B,B2]');
        is($h->{fp}, $h_before->{fp}, 'H2: the fp is unchanged after the extend');
        is($h->{token}, $h_before->{token}, 'H2: the token is unchanged after the extend');
        cmp_ok($h->{deadline}, '>=', $h_before->{deadline},
            'H2: the deadline never moves backwards -- max() against a shorter extender seam keeps the longer existing deadline');
    }

    is(BpHook::holder_live($H1_SID, $p_running), 1, 'H2: the first holder is still alive after the extend');
    ok(kill(0, $pid), 'H2: exactly one spawned holder process (the original) is alive');

    is($STDERR_LOG{'H1-sid2-cleanup'}, $STDERR_LOG{'H1-sid2-cleanup'}, 'H2: (no-op) placeholder to keep case ordering visible');

    # H1's holder has done its job for both H1 and H2 -- end it now.
    reap_and_log('H1-holder', $pid, $main::H1_OUTFILE, $main::H1_ERRFILE);
}

# ===========================================================================
# H3 (6382) -- two becomes race; exactly one survives as the holder.
# ===========================================================================
{
    my $sid = 'hold-h3-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['X'], transcript_path => $tp, background => 1);
    write_ticket_for($sid, ['Y'], transcript_path => $tp, background => 1);

    my ($pid_x, $outx, $errx) = spawn_hold(['X'], { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    my ($pid_y, $outy, $erry) = spawn_hold(['Y'], { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid_x, $pid_y;

    # One becomes and stays running; the other extends and exits 0. (A
    # wait_pid_bounded() probe used to run here with a 0.01s timeout -- that
    # function SIGKILLs and reaps on timeout, so it could kill the survivor
    # outright rather than merely probing it. Removed; liveness is polled
    # non-destructively below via waitpid(..., WNOHANG).)
    my $other_pid;

    # Determine which one exited (the extender) by polling both non-destructively.
    my $deadline = time() + 15;
    my ($exited_pid, $exited_rc);
    while (time() < $deadline) {
        for my $cand ([$pid_x, $outx, $errx], [$pid_y, $outy, $erry]) {
            my ($p, $o, $e) = @$cand;
            my $w = waitpid($p, WNOHANG);
            if ($w == $p) { $exited_pid = $p; $exited_rc = $? >> 8; $other_pid = ($p == $pid_x) ? $pid_y : $pid_x; last }
        }
        last if defined $exited_pid;
        sleep(0.05);
    }
    ok(defined $exited_pid, 'H3: exactly one of the two racing becomes exits (the extender)');
    @KILL_PIDS = grep { $_ != $exited_pid } @KILL_PIDS if defined $exited_pid;

    SKIP: {
        skip 'H3: neither invocation exited', 3 unless defined $exited_pid;
        is($exited_rc, 0, 'H3: the extender exits 0');
        my ($exited_out, $exited_out_file) = ($exited_pid == $pid_x) ? (undef, $outx) : (undef, $outy);
        $exited_out_file = ($exited_pid == $pid_x) ? $outx : $outy;
        my $out = slurp($exited_out_file);
        like($out, qr/^extended the running holder \(pid \d+\) until/m, 'H3: with the extended line');

        ok(kill(0, $other_pid), 'H3: exactly one is alive -- the other');
        my $h = BpHook::holder($sid);
        ok(ref $h eq 'HASH', 'H3: a record exists');
        SKIP: {
            skip 'H3: no record', 2 unless ref $h eq 'HASH';
            is($h->{pid}, $other_pid, 'H3: the record pid is the survivors pid');
            is_deeply([sort @{ $h->{items} }], ['X', 'Y'], 'H3: items are {X,Y}');
        }
        reap_and_log('H3-survivor', $other_pid, ($other_pid == $pid_x ? $outx : $outy), ($other_pid == $pid_x ? $errx : $erry));
    }
    unlink $outx, $errx, $outy, $erry;
}

# ===========================================================================
# H4 (2cad) -- a killed holder counts as nothing; a forged/mismatched record
# never counts; a subagent ticket may not hold; completed items never count.
# ===========================================================================

# H4(a) -- SIGKILL, then a new become.
{
    my $sid = 'hold-h4a-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['Z0'], transcript_path => $tp, background => 1);
    my ($pid, $outf, $errf) = spawn_hold(['Z0'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'H4a: precondition -- the holder became');

    kill('KILL', $pid);
    waitpid($pid, 0);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    unlink $outf, $errf;

    # Give the OS a moment to actually reap the pid slot.
    sleep(0.2);
    is(BpHook::holder_live($sid, {}), 0, 'H4a: after SIGKILL, holder_live is 0');
    ok(-f "$CONT_ROOT/holder/$sid.json", 'H4a: the record is still present (killed, not cleaned up)');

    write_ticket_for($sid, ['Z'], transcript_path => $tp, background => 1);
    my ($pid2, $out2f, $err2f) = spawn_hold(['Z'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid2;
    # The stale record from the killed holder is still on disk (asserted
    # above), so a plain wait_for_holder() would return it immediately and
    # falsely satisfy "defined". Wait specifically for a record whose pid
    # differs from the dead one -- i.e. the NEW holder's own record.
    my $h2 = wait_for_new_holder($sid, $pid, 10);
    ok(defined $h2, 'H4a: a new butler-hold Z becomes the holder instead of extending the dead one');
    SKIP: {
        skip 'H4a: no new record', 2 unless defined $h2;
        isnt($h2->{pid}, $pid, 'H4a: the new record has a new pid, distinct from the killed one');
        is_deeply($h2->{items}, ['Z'], 'H4a: BECOME replaced the item set, it did not extend the dead ones');
    }
    my $out2 = wait_for_stdout_line($out2f, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/m, 10);
    like($out2, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/m, 'H4a: a fresh holding line');
    reap_and_log('H4a-new-holder', $pid2, $out2f, $err2f);
}

# H4(b) -- pid changed to a live, unrelated pid; fp left alone -> 0. /proc-dependent.
SKIP: {
    skip 'H4b: /proc/self/cmdline unavailable on this host', 1 unless -r '/proc/self/cmdline';
    my $sid = 'hold-h4b-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['Q0'], transcript_path => $tp, background => 1);
    my ($pid, $outf, $errf) = spawn_hold(['Q0'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);

    SKIP: {
        skip 'H4b: no record to forge from', 1 unless defined $h;
        my $forged = { %$h, pid => $$ };   # this test process: real, alive, unrelated cmdline
        my $path = "$CONT_ROOT/holder/$sid.json";
        open my $fh, '>:raw', $path or die $!;
        print {$fh} JSON::PP->new->utf8->canonical->encode($forged) . "\n";
        close $fh;
        is(BpHook::holder_live($sid, {}), 0,
            'H4b: a record whose pid points at a live, unrelated process (fp unchanged) is not live');
    }
    reap_and_log('H4b-cleanup', $pid, $outf, $errf);
}

# H4(c) -- a ticket whose agent_id is defined refuses; no record written.
{
    my $sid = 'hold-h4c-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['SUB1'], transcript_path => $tp, background => 1, agent_id => 'sub-agent-1');
    my ($out, $err, $rc) = run_hold('H4c', ['SUB1'], {});
    is($rc, 1, 'H4c: a subagent ticket (agent_id defined) refuses, exit 1');
    is($out, "butler-hold: only the main session holds; a subagent may not.\n",
        'H4c: the exact subagent refusal line, on stdout');
    ok(!-f "$CONT_ROOT/holder/$sid.json", 'H4c: no record was written');
}

# H4(d) (Decision 131) -- a live holder whose ids are ALL completed in
# background_tasks is still holder_live == 1: the holder's own non-empty
# items record is what counts while the holder process is alive (pid plus
# fingerprint); background_tasks status is irrelevant to a live holder.
{
    my $sid = 'hold-h4d-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['D1'], transcript_path => $tp, background => 1);
    my ($pid, $outf, $errf) = spawn_hold(['D1'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'H4d: precondition -- the holder became');
    is(BpHook::holder_live($sid, { background_tasks => [{ id => 'D1', type => 'subagent', status => 'completed' }] }), 1,
        'H4d: a live holder whose only id reports completed is still counted as live (Decision 131)');
    reap_and_log('H4d-cleanup', $pid, $outf, $errf);
}

# H4(e) -- after SIGTERM, no /proc/*/cmdline anywhere carries the nonce id.
SKIP: {
    skip 'H4e: /proc unavailable on this host', 1 unless -d '/proc' && -r '/proc/self/cmdline';
    my $sid   = 'hold-h4e-sid';
    my $nonce = 'nonce-e4-98234871';
    my $tp    = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, [$nonce], transcript_path => $tp, background => 1);
    my ($pid, $outf, $errf) = spawn_hold([$nonce], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    wait_for_holder($sid, 10);
    kill('TERM', $pid);
    wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    unlink $outf, $errf;

    my $found = 0;
    if (opendir(my $dh, '/proc')) {
        for my $e (readdir($dh)) {
            next unless $e =~ /^[0-9]+$/;
            my $cl = '';
            if (open(my $fh, '<:raw', "/proc/$e/cmdline")) { local $/; $cl = <$fh> // ''; close $fh }
            if (index($cl, $nonce) >= 0) { $found = 1; last }
        }
        closedir $dh;
    }
    is($found, 0, 'H4e: after SIGTERM, no /proc/*/cmdline anywhere still carries this holders nonce id');
}

# ===========================================================================
# H5 (DC1, deadline) -- exact stdout at the deadline, mixed item statuses.
# ===========================================================================
{
    my $sid = 'hold-h5-sid';
    my $tp = transcript_path_for($sid);
    my $sdir = sessiondir_for($sid);

    my $e1 = time() - 500;
    my $e2 = time() - 300;
    write_subagent_files($sdir, 'S', $e1);
    # basename must be exactly "<id>.output" with a path separator directly
    # in front (spec 2.7's regex requires (?:\\|/)ID\.output immediately) --
    # a per-case subdir keeps "B.output" unique across cases.
    my $bpath = write_output_file("$TMPROOT/h5/B.output", $e2);

    write_transcript($tp, finished => ['F'], bg_output => ['B', $bpath]);

    my @argv = ('agent-S', 'B', 'F', 'U');
    write_ticket_for($sid, \@argv, transcript_path => $tp, background => 1);

    my $t_spawn = time();
    my ($pid, $outfile, $errfile) = spawn_hold(\@argv, { BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;

    my $h = wait_for_holder($sid, 10);
    my $expected_deadline = ref $h eq 'HASH' ? $h->{deadline} : undef;

    my $rc = wait_pid_bounded($pid, 20);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'H5: the holder exits 0 at the deadline');
    ok(defined $expected_deadline, 'H5: precondition -- the record was seen with a deadline')
        or diag('no record observed before exit');
    if (defined $expected_deadline) {
        cmp_ok(time(), '>=', $expected_deadline, 'H5: it did not exit before the recorded deadline');
    }

    my @l = lines_of($out);
    is(scalar(@l), 7, 'H5: exactly seven stdout lines') or diag("stdout was:\n$out");
    like($l[0] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/,
        'H5: line 1 -- the holding line');
    like($l[1] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) finished: F; still waiting on: S, B, U$/,
        'H5: line 2 -- finished: F; still waiting on: S, B, U');
    like($l[2] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) released: deadline reached$/,
        'H5: line 3 -- released: deadline reached');
    is($l[3] // '', "S still running (last activity @{[iso_of($e1)]})", 'H5: line 4 -- S still running with E1');
    is($l[4] // '', "B still running (last activity @{[iso_of($e2)]})", 'H5: line 5 -- B still running with E2');
    is($l[5] // '', 'F finished', 'H5: line 6 -- F finished');
    is($l[6] // '', 'U unknown', 'H5: line 7 -- U unknown');
    is($err, '', 'H5: stderr is empty');
    ok(!-f "$CONT_ROOT/holder/$sid.json", 'H5: the record is gone');
}

# ===========================================================================
# H6 (DC2) -- all-finished exits early with the all-finished header.
# ===========================================================================
{
    my $sid = 'hold-h6-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp, finished => ['F1', 'F2']);
    my @argv = ('agent-F1', 'F2');
    write_ticket_for($sid, \@argv, transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_hold(\@argv, { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'H6: all-finished exits 0');
    my @l = lines_of($out);
    is(scalar(@l), 6, 'H6: holding line + two finished lines + released + two item lines') or diag("stdout:\n$out");
    like($l[1] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) finished: F1; still waiting on: nothing$/,
        'H6: finished: F1; still waiting on: nothing');
    like($l[2] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) finished: F2; still waiting on: nothing$/,
        'H6: finished: F2; still waiting on: nothing');
    like($l[3] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) released: every held item finished$/,
        'H6: the all-finished released line');
    is($l[4] // '', 'F1 finished', 'H6: F1 finished');
    is($l[5] // '', 'F2 finished', 'H6: F2 finished');
    is($err, '', 'H6: stderr empty');
}

# ===========================================================================
# H7 (DC2, unknown) -- unresolved ids never fail the command; a token-only
# binding with no transcript at all resolves everything to unknown too.
# ===========================================================================
{
    my $sid = 'hold-h7a-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    my @argv = ('UNK1', 'UNK2');
    write_ticket_for($sid, \@argv, transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_hold(\@argv, { BUTLER_HOLD_TEST_SECONDS => 1, BUTLER_HOLD_TEST_TICK => 0.1 });
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;
    is($rc, 0, 'H7a: unresolvable ids do not fail the command');
    my @l = lines_of($out);
    is($l[-2] // '', 'UNK1 unknown', 'H7a: UNK1 unknown');
    is($l[-1] // '', 'UNK2 unknown', 'H7a: UNK2 unknown');
}
{
    # token-only binding, no ticket, no armed file -> transcript_path null.
    my $sid = 'hold-h7b-sid';
    my $tok = BpHook::mint_stop_token($sid, { hook_event_name => 'Stop' });
    ok(defined $tok, 'H7b: precondition -- a stop token was minted');
    SKIP: {
        skip 'H7b: no token minted', 4 unless defined $tok;
        my @argv = ('--token', $tok, 'NOTP1');
        my ($pid, $outfile, $errfile) = spawn_hold(\@argv, { BUTLER_HOLD_TEST_SECONDS => 1, BUTLER_HOLD_TEST_TICK => 0.1 });
        push @KILL_PIDS, $pid;
        my $rc = wait_pid_bounded($pid, 10);
        @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
        my $out = slurp($outfile);
        unlink $outfile, $errfile;
        is($rc, 0, 'H7b: a token-only binding with no transcript at all does not refuse');
        my @l = lines_of($out);
        is($l[-1] // '', 'NOTP1 unknown', 'H7b: with no transcript, the item is reported unknown, not an error');
    }
}

# ===========================================================================
# H8 (DC2) -- the outputs cache resolves an id whose launch line has since
# scrolled out of the TAIL_BYTES tail window.
# ===========================================================================
{
    my $sid = 'hold-h8-sid';
    my $tp = transcript_path_for($sid);
    # See H5's note: basename must be exactly "<id>.output" preceded by a
    # path separator; a per-case subdir keeps it unique.
    my $opath = "$TMPROOT/h8/B.output";
    write_output_file($opath, time());
    write_transcript($tp, bg_output => ['B', $opath]);

    my @argv = ('B',);
    write_ticket_for($sid, \@argv, transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_hold(\@argv, { BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.3 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'H8: precondition -- the holder became (outputs should now be cached)');

    # Now push the launch line out of the last 8 MiB by padding well past it.
    # TAIL_BYTES itself is untouched -- this is real padding, not a shrunk
    # constant.
    append_transcript($tp, ('.' x (8 * 1024 * 1024 + 4096)) . "\n");

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;
    is($rc, 0, 'H8: exits 0 at the deadline');
    my @l = lines_of($out);
    like($l[-1] // '', qr/^B still running \(last activity /,
        'H8: B still resolves via the outputs cache even though the launch line has scrolled out of the tail window');
}

# ===========================================================================
# H9 (DC1, no timeout parameter) -- every disguised timeout flag refuses;
# the test seam is inert without BUTLER_HOLD_TEST_MODE=1 or without an
# absolute BUTLER_STATE_DIR.
# ===========================================================================
{
    my @bad = (
        ['--timeout', '5', 'W'],
        ['--timeout=5', 'W'],
        ['--seconds', '5', 'W'],
        ['--max-seconds', '5', 'W'],
        ['--deadline', '5', 'W'],
        ['-t', '5', 'W'],
        ['--session', 'some-sid', 'W'],
        ['--token', 'a', '--token', 'b', 'W'],
    );
    my $n = 0;
    for my $argv (@bad) {
        $n++;
        my $sid = "hold-h9-sid-$n";
        my $tp = transcript_path_for($sid);
        write_transcript($tp);
        my ($ok, $tuid) = write_ticket_for($sid, $argv, transcript_path => $tp, background => 1);
        my ($out, $err, $rc) = run_hold("H9-$n", $argv, {});
        is($rc, 1, "H9: '@$argv' refuses, exit 1");
        is($out, "butler-hold: takes ids only, plus --token from a stop message; the hold is always 50 minutes.\n",
            "H9: '@$argv' -- the exact row-1 refusal line");
        ok(!-f "$CONT_ROOT/holder/$sid.json", "H9: '@$argv' -- no record written");
        ok(defined find_ticket_file($sid, $tuid), "H9: '@$argv' -- the ticket is left unconsumed");
    }

    # The seam is honoured only with BUTLER_HOLD_TEST_MODE=1 AND an absolute
    # BUTLER_STATE_DIR: BUTLER_HOLD_TEST_SECONDS=1 with NO TEST_MODE -> real 3000.
    {
        my $sid = 'hold-h9-seam-a';
        my $tp = transcript_path_for($sid);
        write_transcript($tp);
        write_ticket_for($sid, ['SEAMA'], transcript_path => $tp, background => 1);
        my ($pid, $outf, $errf) = spawn_hold(['SEAMA'],
            { BUTLER_HOLD_TEST_SECONDS => 1, BUTLER_HOLD_TEST_MODE => undef });
        push @KILL_PIDS, $pid;
        my $h = wait_for_holder($sid, 10);
        ok(defined $h, 'H9: seam-off precondition -- became');
        SKIP: {
            skip 'H9: no record', 1 unless defined $h;
            is($h->{deadline} - $h->{started_at}, 3000,
                'H9: BUTLER_HOLD_TEST_SECONDS is ignored without BUTLER_HOLD_TEST_MODE=1 -- real 3000s duration');
        }
        reap_and_log('H9-seam-a-cleanup', $pid, $outf, $errf);
    }

    # TEST_MODE=1 but BUTLER_STATE_DIR unset, HOME pointed at a tempdir instead.
    {
        my $home_tmp = tempdir(CLEANUP => 1);
        (my $home = "$home_tmp/home") =~ s{\\}{/}g;
        make_path($home);
        my $sid = 'hold-h9-seam-b';
        (my $tp = "$home/.claude/projects/$sid.jsonl") =~ s{\\}{/}g;
        write_transcript($tp);
        # This ticket must be written against the SAME state root the child
        # will resolve (via HOME, since BUTLER_STATE_DIR is unset for it).
        {
            local $ENV{BUTLER_STATE_DIR} = undef;
            local $ENV{HOME} = $home;
            local $ENV{USERPROFILE} = $home;
            delete $ENV{BUTLER_STATE_DIR};
            write_ticket_for($sid, ['SEAMB'], transcript_path => $tp, background => 1);
        }
        my ($pid, $outf, $errf) = spawn_hold(['SEAMB'],
            { BUTLER_HOLD_TEST_SECONDS => 1, BUTLER_HOLD_TEST_TICK => 0.1,
              BUTLER_STATE_DIR => undef, HOME => $home, USERPROFILE => $home });
        push @KILL_PIDS, $pid;

        my $deadline = time() + 10;
        my $h;
        while (time() < $deadline) {
            local $ENV{BUTLER_STATE_DIR} = undef;
            local $ENV{HOME} = $home;
            delete $ENV{BUTLER_STATE_DIR};
            $h = BpHook::holder($sid);
            last if ref $h eq 'HASH';
            sleep(0.05);
        }
        ok(ref $h eq 'HASH', 'H9: seam-b precondition -- became under HOME fallback');
        SKIP: {
            skip 'H9: no record', 1 unless ref $h eq 'HASH';
            is($h->{deadline} - $h->{started_at}, 3000,
                'H9: with BUTLER_STATE_DIR unset, the seam is ignored (real 3000s) even with TEST_MODE=1');
        }
        reap_and_log('H9-seam-b-cleanup', $pid, $outf, $errf);
    }
}

# ===========================================================================
# H10 (binding) -- no ticket/no token refuses even with the env var set;
# a stop token binds once; a mismatched session token refuses; a foreground
# ticket refuses when nothing is running and extends when something is.
# ===========================================================================
{
    my $sid = 'hold-h10a-sid';
    my ($out, $err, $rc) = run_hold('H10a', ['A1'], { CLAUDE_CODE_SESSION_ID => $sid });
    is($rc, 1, 'H10: no ticket and no token refuses, even with CLAUDE_CODE_SESSION_ID exported');
    is($out, "butler-hold: no session binding; use the --token from the stop message, or quote ids plainly.\n",
        'H10: the exact no-binding refusal line');
    ok(!-f "$CONT_ROOT/holder/$sid.json", 'H10: no record written');
}
{
    my $sid = 'hold-h10b-sid';
    my $tok = BpHook::mint_stop_token($sid, { hook_event_name => 'Stop' });
    ok(defined $tok, 'H10b: precondition -- token minted');
    SKIP: {
        skip 'H10b: no token', 4 unless defined $tok;
        # This is a genuine BECOME with no test seam set, so it runs the real
        # 3000s deadline and never exits on its own -- run_hold() would wait
        # up to its 30s bound and then SIGKILL it, reporting rc -1 rather
        # than exercising the binding at all. Use spawn_hold/wait_for_holder
        # the way every other BECOME case does: observe the record and the
        # already-printed stdout line while it is still running, then
        # terminate it explicitly.
        my ($pid, $outf, $errf) = spawn_hold(['--token', $tok, 'B1'], {});
        push @KILL_PIDS, $pid;
        my $h = wait_for_holder($sid, 10);
        ok(defined $h, 'H10b: a --token from the stop message binds sid on first use (BECOME record appears)');
        my $out = wait_for_stdout_line($outf, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/, 10);
        like($out, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/, 'H10b: holding line for the token-bound sid');
        reap_and_log('H10b-cleanup', $pid, $outf, $errf);

        my ($out2, $err2, $rc2) = run_hold('H10b-second', ['--token', $tok, 'B2'], {});
        is($rc2, 1, 'H10b: reusing the same (already-consumed) token refuses');
    }
}
{
    my $sid1 = 'hold-h10c-sid1';
    my $sid2 = 'hold-h10c-sid2';
    my $tok2 = BpHook::mint_stop_token($sid2, { hook_event_name => 'Stop' });
    ok(defined $tok2, 'H10c: precondition -- token minted for sid2');
    SKIP: {
        skip 'H10c: no token', 2 unless defined $tok2;
        my $tp1 = transcript_path_for($sid1);
        write_transcript($tp1);
        my @argv = ('C1', '--token', $tok2);
        write_ticket_for($sid1, \@argv, transcript_path => $tp1, background => 1);
        my ($out, $err, $rc) = run_hold('H10c', \@argv, {});
        is($rc, 1, 'H10c: a ticket for sid1 plus a token minted for sid2 refuses');
        is($out, "butler-hold: the --token belongs to another session.\n", 'H10c: the exact other-session line');
    }
}
{
    my $sid = 'hold-h10d-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['D1'], transcript_path => $tp, background => 0);
    my ($out, $err, $rc) = run_hold('H10d-nolive', ['D1'], {});
    is($rc, 1, 'H10d: a foreground ticket refuses to BECOME when nothing is running');
    is($out, "butler-hold: start it with run_in_background: true.\n", 'H10d: the exact background-required line');

    # Now with a live holder for the same session, a foreground ticket extends.
    write_ticket_for($sid, ['D2first'], transcript_path => $tp, background => 1);
    my ($pid, $outf, $errf) = spawn_hold(['D2first'], { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'H10d: precondition -- a live holder for the same session');
    SKIP: {
        skip 'H10d: no live holder', 1 unless defined $h;
        write_ticket_for($sid, ['D2ext'], transcript_path => $tp, background => 0);
        my ($out2, $err2, $rc2) = run_hold('H10d-extend', ['D2ext'], {});
        is($rc2, 0, 'H10d: a foreground ticket EXTENDS when a live holder already exists');
        like($out2, qr/^extended the running holder \(pid \d+\) until/, 'H10d: extended line');
    }
    reap_and_log('H10d-cleanup', $pid, $outf, $errf);
}

# ===========================================================================
# R6-M5 (red-team MEDIUM-5, Decision 51 re-scope): a FOREGROUND butler-hold
# (a ticket with background=>0, same shape as H10d) that ALSO carries a
# --token from a Stop denial must be refused the SAME WAY H10d already is
# ("start it with run_in_background: true."), but WITHOUT burning that
# token. TODAY (butler-hold.pl ~437-448) take_stop_token runs unconditionally
# whenever a --token is present in a ticket-bound call, to check the token's
# owning session -- BEFORE the background=>0 refusal at line ~636 ever
# fires. So a refused foreground call silently consumes the escape: the
# token is gone, and no later background retry can use it. The token must
# still be takeable (usable by a background butler-hold) after the refusal.
# ===========================================================================
{
    my $sid = 'hold-r6m5-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    my $tok = BpHook::mint_stop_token($sid, { hook_event_name => 'Stop' });
    ok(defined $tok, 'R6-M5: precondition -- token minted');
    SKIP: {
        skip 'R6-M5: no token', 5 unless defined $tok;

        my @argv_fg = ('--token', $tok, 'M5');
        write_ticket_for($sid, \@argv_fg, transcript_path => $tp, background => 0);
        my ($out, $err, $rc) = run_hold('R6-M5-foreground', \@argv_fg, {});
        is($rc, 1, 'R6-M5: a foreground ticket (background=>0) carrying --token refuses to BECOME');
        is($out, "butler-hold: start it with run_in_background: true.\n",
            'R6-M5: the exact background-required line, same as H10d');
        ok(!-f "$CONT_ROOT/holder/$sid.json",
            'R6-M5: no holder record written by the refused foreground attempt');

        ok(-e "$CONT_ROOT/stop-tokens/$tok",
            'R6-M5: the stop-token file still exists after the refused foreground attempt (not burned)');
        is(slurp("$CONT_ROOT/stop-tokens/$sid.current") // '', "$tok\n",
            'R6-M5: ...and <sid>.current still points at it');

        # Usable by a background butler-hold: a discriminating check, NOT
        # via a fresh ticket (a ticket resolves $SID from ITSELF, so it
        # would succeed even if the token had been burned -- that would not
        # tell the fix apart from the bug). Instead reuse the SAME token
        # with NO ticket at all, exactly the token-only path H10b exercises:
        # that path can only resolve $SID by calling take_stop_token(tok),
        # so it fails ("no session binding...") if (and only if) the first,
        # refused, foreground attempt had already burned it.
        my ($pid, $outf, $errf) = spawn_hold(['--token', $tok, 'M5b'], {});
        push @KILL_PIDS, $pid;
        my $h = wait_for_holder($sid, 10);
        ok(defined $h, 'R6-M5: the SAME (never-burned) token still binds a genuine background BECOME afterward');
        reap_and_log('R6-M5-cleanup', $pid, $outf, $errf);
    }
}

# ===========================================================================
# H11 (cross-session) -- extending one session leaves another byte-identical;
# ambiguous identical-argv tickets refuse without --token.
# ===========================================================================
{
    my $sid_a = 'hold-h11a-sid';
    my $sid_b = 'hold-h11b-sid';
    my $tpa = transcript_path_for($sid_a);
    my $tpb = transcript_path_for($sid_b);
    write_transcript($tpa);
    write_transcript($tpb);

    write_ticket_for($sid_a, ['A1'], transcript_path => $tpa, background => 1);
    write_ticket_for($sid_b, ['B1'], transcript_path => $tpb, background => 1);
    my ($pid_a, $outa, $erra) = spawn_hold(['A1'], { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    my ($pid_b, $outb, $errb) = spawn_hold(['B1'], { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid_a, $pid_b;
    wait_for_holder($sid_a, 10);
    wait_for_holder($sid_b, 10);

    my $b_bytes_before = slurp("$CONT_ROOT/holder/$sid_b.json");

    write_ticket_for($sid_a, ['A2'], transcript_path => $tpa, background => 1);
    my ($pid_a2, $outa2, $erra2) = spawn_hold(['A2'], {});
    push @KILL_PIDS, $pid_a2;
    wait_pid_bounded($pid_a2, 10);
    @KILL_PIDS = grep { $_ != $pid_a2 } @KILL_PIDS;
    unlink $outa2, $erra2;

    my $b_bytes_after = slurp("$CONT_ROOT/holder/$sid_b.json");
    is($b_bytes_after, $b_bytes_before, "H11: extending sid_a leaves sid_b's record byte-identical");

    reap_and_log('H11-a-cleanup', $pid_a, $outa, $erra);
    reap_and_log('H11-b-cleanup', $pid_b, $outb, $errb);
}
{
    my $sid_a = 'hold-h11c-sid1';
    my $sid_b = 'hold-h11c-sid2';
    my $tpa = transcript_path_for($sid_a);
    write_ticket_for($sid_a, ['AMBIG1'], transcript_path => $tpa, background => 1);
    write_ticket_for($sid_b, ['AMBIG1'], transcript_path => $tpa, background => 1);

    is(BpHook::take_ticket('butler-hold', ['AMBIG1']), 'ambiguous',
        "H11: identical argv tickets for two sessions give 'ambiguous'");

    my ($out, $err, $rc) = run_hold('H11-ambig', ['AMBIG1'], {});
    is($rc, 1, 'H11: without --token to disambiguate, the command refuses');
    ok(!-f "$CONT_ROOT/holder/$sid_a.json", 'H11: no record for sid_a');
    ok(!-f "$CONT_ROOT/holder/$sid_b.json", 'H11: no record for sid_b');
}

# ===========================================================================
# H12 (off) -- BpHook::disarm while holding ends the holder at its next tick.
# ===========================================================================
{
    my $sid = 'hold-h12-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['OFF1'], transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_hold(['OFF1'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'H12: precondition -- the holder became');

    my $disarmed = BpHook::disarm($sid, actor => 'agent', reason => 'all done now');
    ok($disarmed, 'H12: disarm succeeds');

    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;
    is($rc, 0, 'H12: the holder exits 0 within tick + a few seconds of being disarmed');
    like($out, qr/released: continuity is off$/m, 'H12: the off header');
    like($out, qr/^OFF1 (?:finished|still running|unknown)/m, 'H12: the item line for OFF1 is present');
}

# ===========================================================================
# H13 (signal) -- SIGTERM: exit 143, item lines, record kept, not live.
# ===========================================================================
{
    my $sid = 'hold-h13-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['SIG1'], transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_hold(['SIG1'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'H13: precondition -- became');

    kill('TERM', $pid);
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 143, 'H13: SIGTERM gives exit 143');
    like($out, qr/^\d\d:\d\d \(\d\d:\d\dZ\) released: killed by a signal$/m, 'H13: the killed header');
    like($out, qr/^SIG1 (?:finished|still running|unknown)/m, 'H13: item line present');
    ok(-f "$CONT_ROOT/holder/$sid.json", 'H13: the record is left in place (coordinator rule)');
    is(BpHook::holder_live($sid, {}), 0, 'H13: holder_live is 0 once the process is gone');
}

# ===========================================================================
# H14 (roots) -- no state dir at all refuses; HOME-only lands under the
# André-bytes path; a subagent under an André session directory resolves.
# ===========================================================================
{
    my $sid = 'hold-h14a-sid';
    my ($out, $err, $rc) = run_hold('H14a', ['R1'], { BUTLER_STATE_DIR => undef, HOME => undef, USERPROFILE => undef });
    is($rc, 1, 'H14a: with BUTLER_STATE_DIR, HOME and USERPROFILE all unset, the command refuses');
    is($out, "butler-hold: no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).\n",
        'H14a: the exact no-state-directory line');
}
{
    my $home_root = tempdir(CLEANUP => 1);
    (my $home = "$home_root/$ANDRE_SEG") =~ s{\\}{/}g;
    make_path($home);
    my $sid = 'hold-h14b-sid';
    (my $tp = "$home/.claude/projects/$sid.jsonl") =~ s{\\}{/}g;
    my $sdir = "$home/.claude/projects/$sid";
    write_subagent_files($sdir, 'AS1', time());
    write_transcript($tp);

    my ($ok, $tuid);
    {
        local $ENV{BUTLER_STATE_DIR} = undef;
        local $ENV{HOME} = $home;
        local $ENV{USERPROFILE} = $home;
        delete $ENV{BUTLER_STATE_DIR};
        ($ok, $tuid) = write_ticket_for($sid, ['agent-AS1'], transcript_path => $tp, background => 1);
    }
    ok($ok, 'H14b: precondition -- ticket written under the HOME-derived root');

    my ($pid, $outfile, $errfile) = spawn_hold(['agent-AS1'],
        { BUTLER_STATE_DIR => undef, HOME => $home, USERPROFILE => $home,
          BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;

    my $rec_path = "$home/.claude/butler-state/continuity/holder/$sid.json";
    my $deadline = time() + 10;
    my $seen;
    while (time() < $deadline) { if (-f $rec_path) { $seen = 1; last } sleep(0.05) }
    ok($seen, 'H14b: the record lands under <HOME>/.claude/butler-state/continuity/holder/');
    SKIP: {
        skip 'H14b: no record', 2 unless $seen;
        my $raw = slurp($rec_path);
        # Check the RAW file bytes first: this is what "never re-encoded"
        # actually means on disk. JSON::PP->utf8->decode() below turns the
        # UTF-8 byte pair \xC3\xA9 into one Unicode codepoint (\x{e9}), so
        # searching the DECODED string for the raw byte sequence would never
        # match even when the file is correct -- that was the test bug.
        ok(index($raw, "Andr\xC3\xA9") >= 0,
            'H14b: the raw record bytes carry Andr\xC3\xA9 (the correct single UTF-8 encoding)');
        ok(index($raw, "\xC3\x83") < 0,
            'H14b: the raw record bytes never carry \xC3\x83 (the doubly-encoded-then-reencoded form)');

        my $data = eval { JSON::PP->new->utf8->decode($raw) };
        ok(ref $data eq 'HASH', 'H14b: the record parses as JSON');
        SKIP: {
            skip 'H14b: record did not parse', 1 unless ref $data eq 'HASH';
            my $tpath = $data->{transcript_path};
            ok(defined $tpath && index($tpath, "Andr\x{e9}") >= 0,
                'H14b: the JSON-decoded transcript_path contains the single Unicode character Andr\x{e9}');
        }
    }

    reap_and_log('H14b-cleanup', $pid, $outfile, $errfile);
}

# ===========================================================================
# H15 (shim, silence) -- the shim shape; every case above left stderr empty;
# the source avoids fork/setsid/proc-status/Getopt/CLAUDE_CODE_SESSION_ID.
# ===========================================================================
{
    ok(-f $SHIM, 'H15: bin/butler-hold exists') or diag("$SHIM missing -- package not implemented yet");
    unlike(basename($SHIM), qr/\./, 'H15: bin/butler-hold has no extension');

    SKIP: {
        skip 'H15: shim missing, cannot bash -n it', 1 unless -f $SHIM;
        system('bash', '-n', $SHIM);
        is($? >> 8, 0, 'H15: bin/butler-hold passes bash -n');
    }

    my @empty_stderr_fails;
    for my $label (sort keys %STDERR_LOG) {
        push @empty_stderr_fails, $label if length($STDERR_LOG{$label} // '');
    }
    unless (is(scalar(@empty_stderr_fails), 0, 'H15: every case above left its stderr file empty')) {
        diag("non-empty stderr for: @empty_stderr_fails");
    }

    ok(-f $SCRIPT, 'H15: scripts/butler-hold.pl exists') or diag("$SCRIPT missing -- package not implemented yet");
    SKIP: {
        skip 'H15: script missing, cannot scan its source', 1 unless -f $SCRIPT;
        my $src = slurp($SCRIPT);
        my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;
        unlike($code, qr/\bfork\b/, 'H15: source never forks (comments stripped)');
        unlike($code, qr/\bsetsid\b/, 'H15: source never setsid\'s');
        unlike($code, qr{/proc/[^'"]*/(?:stat|status|winpid)}, 'H15: source never reads /proc/*/stat|status|winpid');
        unlike($code, qr/\bGetopt\b/, 'H15: source never uses Getopt (argv parsed by hand)');
        unlike($code, qr/\bCLAUDE_CODE_SESSION_ID\b/, 'H15: source never reads CLAUDE_CODE_SESSION_ID');
    }
}

# ===========================================================================
# H16 (diag only) -- median cost of 200 holder_live calls against a live
# holder. Diagnostic, never asserted.
# ===========================================================================
{
    my $sid = 'hold-h16-sid';
    my $tp = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['PERF1'], transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_hold(['PERF1'], { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);

    if (defined $h) {
        my $p = { background_tasks => [{ id => 'PERF1', type => 'subagent', status => 'running' }] };
        my @deltas;
        for (1 .. 200) {
            my $t0 = time();
            BpHook::holder_live($sid, $p);
            push @deltas, time() - $t0;
        }
        my @sorted = sort { $a <=> $b } @deltas;
        my $median = $sorted[int(@sorted / 2)];
        diag(sprintf('H16: median cost of holder_live() against a live holder: %.3f ms (200 calls)', $median * 1000));
        ok(1, 'H16: median cost measured and reported via diag, not asserted');
    }
    else {
        ok(1, 'H16: (skipped measurement -- no live holder to measure against)');
    }
    reap_and_log('H16-cleanup', $pid, $outfile, $errfile);
}

# ===========================================================================
# R5-H1 (redteam H1) -- a become that names the holder's OWN background task
# id is refused. Modelled by pointing the spawned holder's own stdout at
# tasks/<id>.output inside the fixture session dir -- the exact shape the
# spec's own output-path resolution (2.7, "Output is being written to:")
# walks the transcript tail for -- and holding that same id.
# ===========================================================================
{
    my $sid    = 'hold-r5h1-sid';
    my $selfid = 'selftask-r5h1';
    my $tp     = transcript_path_for($sid);
    my $sdir   = sessiondir_for($sid);
    make_path("$sdir/tasks");
    my $self_output = "$sdir/tasks/$selfid.output";
    write_transcript($tp, bg_output => [$selfid, $self_output]);
    write_ticket_for($sid, [$selfid], transcript_path => $tp, background => 1);

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME}                  = $FAKE_HOME;
        $ENV{USERPROFILE}           = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE} = 1;
        $ENV{BUTLER_HOLD_TEST_SECONDS} = 5;
        $ENV{BUTLER_HOLD_TEST_TICK}    = 0.2;
        # This holder's OWN stdout is redirected to the exact path the
        # transcript names as $selfid's output -- the shape a real harness
        # gives a background task's stdout.
        open(STDOUT, '>', $self_output) or POSIX::_exit(126);
        open(STDERR, '>', "$self_output.err") or POSIX::_exit(126);
        exec('bash', $SHIM, $selfid);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;

    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($self_output);
    unlink "$self_output.err";

    is($rc, 1, 'R5-H1: a become naming the holders own background task id is refused, exit 1');
    unlike($out, qr/holding session/m,
        'R5-H1: no holding line -- the record is never written for a self-held id');
    ok(!-f "$CONT_ROOT/holder/$sid.json", 'R5-H1: no record written for a self-held id');
}

# ===========================================================================
# R5-H2 (redteam H2) -- resolving an item's output path in a transcript that
# carries a long, slash-heavy non-whitespace run (modelling a base64 image
# blob) must not go quadratic: it completes well under 2s, and a concurrent
# call started while the first is still working is answered (extended or
# busy) in under 2s too, rather than left blocked behind the same lock.
# Both waits are bounded so a stall fails the assertion instead of hanging
# the suite.
# ===========================================================================
{
    my $sid   = 'hold-r5h2-sid';
    my $tp    = transcript_path_for($sid);
    my $opath = "$TMPROOT/r5h2/BIGID.output";
    write_output_file($opath, time());

    # ~1 MiB of base64-shaped filler (plenty of '/', no whitespace) on one
    # line, immediately followed by the launch line the resolver must scan
    # past to find BIGID's own output path.
    my $unit = 'QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ejAxMjM0NTY3ODkrLy8=';
    my $blob = $unit x (int(1024 * 1024 / length($unit)) + 1);
    $blob = substr($blob, 0, 1024 * 1024);
    make_path(dirname($tp));
    open(my $bfh, '>:raw', $tp) or die "open $tp: $!";
    print {$bfh} "$blob\n";
    print {$bfh} "Output is being written to: $opath\n";
    close $bfh;

    write_ticket_for($sid, ['BIGID'], transcript_path => $tp, background => 1);

    my $t0 = time();
    my ($pid, $outf, $errf) = spawn_hold(['BIGID'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 30);
    my $elapsed1 = time() - $t0;
    ok(defined $h, 'R5-H2: precondition -- the become eventually completed (bounded wait)');
    cmp_ok($elapsed1, '<', 2,
        'R5-H2: resolving an items output path past a ~1 MiB blob completes in under 2s');

    # A concurrent extend, started right away, must get an answer (extended
    # or busy) quickly -- not be left blocked behind the first call's own
    # (possibly slow) scan under the same per-session lock.
    write_ticket_for($sid, ['BIGID2'], transcript_path => $tp, background => 1);
    my $t1 = time();
    my ($out2, $err2, $rc2) = run_hold('R5-H2-concurrent', ['BIGID2'], {}, timeout => 20);
    my $elapsed2 = time() - $t1;
    cmp_ok($elapsed2, '<', 2,
        'R5-H2: a concurrent call during the scan is answered (extended or busy) in under 2s, not left hanging');

    reap_and_log('R5-H2-cleanup', $pid, $outf, $errf);
}

# ===========================================================================
# R5-M1 / RT-M4 -- a forced internal error must never leak perl's die text
# to stderr, and must print exactly one line, "butler-hold: internal
# error.", to stdout, exiting nonzero (spec 2.8). Forced via a THROWAWAY
# COPY of the scripts, with the copy's BpHook.pm replaced by an unparsable
# file, simulating "a bad promotion" (review M1) -- the real
# plugins/butler/scripts/BpHook.pm is never touched.
# ===========================================================================
{
    my $copy_dir = tempdir(CLEANUP => 1);
    (my $copy_dir_n = $copy_dir) =~ s{\\}{/}g;
    for my $f (qw(butler-hold.pl BpHook.pm)) {
        my $src = "$S/$f";
        open(my $ifh, '<:raw', $src) or die "read $src: $!";
        local $/;
        my $c = <$ifh>;
        close $ifh;
        open(my $ofh, '>:raw', "$copy_dir_n/$f") or die "write $copy_dir_n/$f: $!";
        print {$ofh} $c;
        close $ofh;
    }
    # Corrupt the COPY of BpHook.pm only -- an unparsable file forces
    # `require "$Bin/BpHook.pm"` (butler-hold.pl, top of file, no top-level
    # eval around it) to die with a real perl compile error.
    open(my $bad, '>:raw', "$copy_dir_n/BpHook.pm") or die $!;
    print {$bad} "package BpHook;\nthis is not valid perl {{{\n";
    close $bad;

    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME}                  = $FAKE_HOME;
        $ENV{USERPROFILE}           = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE} = 1;
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('perl', "$copy_dir_n/butler-hold.pl", 'R5M1ITEM');
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($out, "butler-hold: internal error.\n",
        'R5-M1/RT-M4: a forced internal error prints exactly the one-line internal-error message to stdout');
    isnt($rc, 0, 'R5-M1/RT-M4: a forced internal error exits nonzero');
    is($err, '', 'R5-M1/RT-M4: a forced internal error leaves stderr empty -- no perl die text');
}

# ===========================================================================
# R5-M2 (review M2) -- an output path cached in the record's `outputs` map
# must be UTF-8-decoded before it is JSON-encoded, so a non-ASCII path is
# stored ONCE-encoded on disk (raw bytes carry C3 A9, never the
# doubly-encoded C3 83 C2 A9) -- and so it still resolves once the launch
# line has scrolled out of the tail window, exactly like H8.
# ===========================================================================
{
    my $sid           = 'hold-r5m2-sid';
    my $tp            = transcript_path_for($sid);
    my $andre_out_dir = "$TMPROOT/$ANDRE_SEG/r5m2out";
    my $opath         = "$andre_out_dir/BM2.output";
    write_output_file($opath, time());
    write_transcript($tp, bg_output => ['BM2', $opath]);

    write_ticket_for($sid, ['BM2'], transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_hold(['BM2'], { BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.3 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'R5-M2: precondition -- the holder became (output path should now be cached)');

    SKIP: {
        skip 'R5-M2: no record to inspect', 2 unless defined $h;
        my $raw = slurp("$CONT_ROOT/holder/$sid.json");
        ok(index($raw, "Andr\xC3\xA9") >= 0,
            'R5-M2: the cached output path carries the single, correct UTF-8 encoding (C3 A9) on disk');
        ok(index($raw, "\xC3\x83") < 0,
            'R5-M2: the cached output path is never doubly-encoded (C3 83) on disk');
    }

    # Now push the launch line out of the tail window, exactly like H8, so
    # the outputs cache is the ONLY way left to resolve BM2 -- if the cached
    # path was mangled on the way in, to_bytes_path's re-encoding on the way
    # out cannot land on the real file, and the item falls through to
    # "unknown" instead of "still running".
    append_transcript($tp, ('.' x (8 * 1024 * 1024 + 4096)) . "\n");

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;
    is($rc, 0, 'R5-M2: exits 0 at the deadline');
    my @l = lines_of($out);
    like($l[-1] // '', qr/^BM2 still running \(last activity /,
        'R5-M2: the non-ASCII cached output path still resolves once the launch line has scrolled out of the tail window');
}

# ===========================================================================
# R5-m1 (review m1) -- `butler-continuity off` racing an extend can never
# resurrect the holder record: become/extend serialise on holder/<sid>.lock,
# while disarm serialises on a DIFFERENT lock (armlock/<sid>) and unlinks
# holder/<sid>.json directly. Driven >=20 times to catch the window.
# ===========================================================================
{
    my $CONT_SHIM  = "$BIN/butler-continuity";
    my $ITERATIONS = 20;
    my @resurrected;

    for my $i (1 .. $ITERATIONS) {
        my $sid = "hold-r5m1-race-$i";
        my $tp  = transcript_path_for($sid);
        write_transcript($tp);

        # Minted before RACE1 becomes, too: an agent off is refused while
        # this session holds running work (bug 20260826-121852-3570), and
        # the race below is off-confirm against an extend, not off itself.
        # judged-continuity-disarm package 02: agent `off` now only mints a
        # disarm OTP (two-step). The race this block drives is about
        # BpHook::disarm()'s own lock discipline, which now runs inside
        # `off-confirm`, not `off` -- so mint the OTP BEFORE taking the test's
        # own holder/<sid>.lock (minting takes no armlock, and must not be
        # inside the window being raced), then race `off-confirm` instead.
        BpHook::write_ticket(
            { session_id => $sid, tool_use_id => next_tuid(), transcript_path => $tp, cwd => $PROJECT },
            'butler-continuity', ['off', '--reason', 'race off'],
            background => 1, operator => 0);
        my (undef, $out_mint) = tempfile();
        my (undef, $err_mint) = tempfile();
        my $pid_mint = fork();
        die "fork: $!" unless defined $pid_mint;
        if ($pid_mint == 0) {
            delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
            $ENV{HOME}                  = $FAKE_HOME;
            $ENV{USERPROFILE}           = $FAKE_HOME;
            $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
            $ENV{BUTLER_HOLD_TEST_MODE} = 1;
            open(STDOUT, '>', $out_mint) or POSIX::_exit(126);
            open(STDERR, '>', $err_mint) or POSIX::_exit(126);
            exec('bash', $CONT_SHIM, 'off', '--reason', 'race off');
            POSIX::_exit(127);
        }
        push @KILL_PIDS, $pid_mint;
        wait_pid_bounded($pid_mint, 10);
        @KILL_PIDS = grep { $_ != $pid_mint } @KILL_PIDS;
        my $mint_err = slurp($err_mint);
        unlink $out_mint, $err_mint;
        my ($otp) = ($mint_err =~ /^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m);
        ok(defined $otp, "R5-m1-$i: off minted an 8-hex-char disarm OTP") or diag("stderr: $mint_err");

        write_ticket_for($sid, ['RACE1'], transcript_path => $tp, background => 1);
        my ($pid, $outf, $errf) = spawn_hold(['RACE1'],
            { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
        my $h = wait_for_holder($sid, 10);
        unless (defined $h) {
            kill('KILL', $pid);
            waitpid($pid, 0);
            unlink $outf, $errf;
            push @resurrected, "$sid (no initial become)";
            next;
        }

        # Force the EXACT window review m1 names: hold the SAME lock
        # become/extend serialise on (holder/<sid>.lock) from the test
        # process itself, so a concurrent extend blocks INSIDE the lock
        # wait; run `off-confirm` to completion while the extend cannot
        # possibly observe it (disarm serialises on a DIFFERENT lock,
        # armlock/<sid>, and never touches this one); only then release the
        # lock, letting the extend read a now-empty slot and -- per current
        # behaviour -- BECOME a fresh holder anyway, resurrecting the record
        # `off-confirm` just removed.
        make_path("$CONT_ROOT/holder");
        my $lockpath = "$CONT_ROOT/holder/$sid.lock";
        open(my $test_lockfh, '>>', $lockpath) or die "open $lockpath: $!";
        flock($test_lockfh, LOCK_EX) or die "flock: $!";

        write_ticket_for($sid, ['RACE2'], transcript_path => $tp, background => 1);
        my ($pid2, $out2f, $err2f) = spawn_hold(['RACE2'],
            { BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.2 });
        push @KILL_PIDS, $pid2;
        sleep(0.3);   # let RACE2 actually reach and block on the lock wait

        BpHook::write_ticket(
            { session_id => $sid, tool_use_id => next_tuid(), transcript_path => $tp, cwd => $PROJECT },
            'butler-continuity', ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'race off confirmed'],
            background => 1, operator => 0);
        my (undef, $out_off) = tempfile();
        my (undef, $err_off) = tempfile();
        # judged-continuity-disarm package 03 (spec sec 4.1): this off-confirm
        # expects rc 0 once the OTP claim succeeds; stub the disarm judge to
        # approve so this race fixture never spawns a real `claude -p`
        # (DC7). Set in %ENV before the fork (this helper's exec takes no env
        # argument), and the 10 s wait_pid_bounded below must still hold.
        local $ENV{CCPRAXIS_DISARM_JUDGE_STUB} = 'approve';
        my $pid_off = fork();
        die "fork: $!" unless defined $pid_off;
        if ($pid_off == 0) {
            my $judge_stub = $ENV{CCPRAXIS_DISARM_JUDGE_STUB};
            delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
            $ENV{HOME}                        = $FAKE_HOME;
            $ENV{USERPROFILE}                 = $FAKE_HOME;
            $ENV{BUTLER_STATE_DIR}            = $STATE_DIR;
            $ENV{BUTLER_HOLD_TEST_MODE}       = 1;
            $ENV{CCPRAXIS_DISARM_JUDGE_STUB}  = $judge_stub;
            open(STDOUT, '>', $out_off) or POSIX::_exit(126);
            open(STDERR, '>', $err_off) or POSIX::_exit(126);
            exec('bash', $CONT_SHIM, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'race off confirmed');
            POSIX::_exit(127);
        }
        push @KILL_PIDS, $pid_off;
        wait_pid_bounded($pid_off, 10);   # off-confirm completes while extend is locked out
        @KILL_PIDS = grep { $_ != $pid_off } @KILL_PIDS;
        unlink $out_off, $err_off;

        # Release the test's own lock -- the blocked RACE2 can now proceed.
        flock($test_lockfh, LOCK_UN);
        close $test_lockfh;

        # Poll briefly for ANY record to reappear -- even a transient one is
        # the bug: the record "outlives" an off that had already completed.
        my $seen_after_off = 0;
        my $poll_deadline = time() + 2;
        while (time() < $poll_deadline) {
            if (-f "$CONT_ROOT/holder/$sid.json") { $seen_after_off = 1; last }
            sleep(0.02);
        }
        push @resurrected, $sid if $seen_after_off;

        reap_and_log("R5-m1-$i-race1", $pid, $outf, $errf);
        wait_pid_bounded($pid2, 8);
        @KILL_PIDS = grep { $_ != $pid2 } @KILL_PIDS;
        unlink $out2f, $err2f;
        unlink "$CONT_ROOT/holder/$sid.json";   # settle before the next iteration
    }

    is(scalar(@resurrected), 0,
        "R5-m1: butler-continuity off racing an extend never resurrects the holder record ($ITERATIONS iterations)")
        or diag('resurrected in: ' . join(', ', @resurrected));
}

# ===========================================================================
# R5-M5 (review M5) -- each become and each extend appends one reasons.log
# line naming the session, the verb (hold/extend) and the items (Decision 49
# accountability: a forged or mimicked record should be distinguishable from
# a genuine hold by a matching log line).
# ===========================================================================
{
    my $sid = 'hold-r5m5-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    my $reasons_log  = "$CONT_ROOT/reasons.log";
    my $before_lines = -f $reasons_log ? scalar(lines_of(slurp($reasons_log))) : 0;

    write_ticket_for($sid, ['M5A'], transcript_path => $tp, background => 1);
    my ($pid, $outf, $errf) = spawn_hold(['M5A'], { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'R5-M5: precondition -- the holder became');

    my @after_become = -f $reasons_log ? lines_of(slurp($reasons_log)) : ();
    my @new_become = (scalar(@after_become) > $before_lines)
        ? @after_become[$before_lines .. $#after_become] : ();
    my ($become_line) = grep { index($_, $sid) >= 0 } @new_become;
    ok(defined $become_line, 'R5-M5: become appended a reasons.log line naming the session');
    if (defined $become_line) {
        like($become_line, qr/\bhold\b/i, 'R5-M5: the become line names the verb (hold)');
        like($become_line, qr/\bM5A\b/, 'R5-M5: the become line names the item');
    }

    write_ticket_for($sid, ['M5B'], transcript_path => $tp, background => 1);
    my ($pid2, $out2f, $err2f) = spawn_hold(['M5B'], {});
    push @KILL_PIDS, $pid2;
    wait_pid_bounded($pid2, 10);
    @KILL_PIDS = grep { $_ != $pid2 } @KILL_PIDS;
    unlink $out2f, $err2f;

    my @after_extend = -f $reasons_log ? lines_of(slurp($reasons_log)) : ();
    my @new_extend = (scalar(@after_extend) > scalar(@after_become))
        ? @after_extend[scalar(@after_become) .. $#after_extend] : ();
    my ($extend_line) = grep { index($_, $sid) >= 0 } @new_extend;
    ok(defined $extend_line, 'R5-M5: extend appended a reasons.log line naming the session');
    if (defined $extend_line) {
        like($extend_line, qr/\bextend\b/i, 'R5-M5: the extend line names the verb (extend)');
        like($extend_line, qr/\bM5B\b/, 'R5-M5: the extend line names the (new) item');
    }

    reap_and_log('R5-M5-cleanup', $pid, $outf, $errf);
}

# ---------------------------------------------------------------------------
# guard: never touched the real ~/.claude/butler-state tree
# ---------------------------------------------------------------------------
if (defined $REAL_BSTATE) {
    my $now_exists = -d $REAL_BSTATE ? 1 : 0;
    my $now_mtime  = $now_exists ? (stat($REAL_BSTATE))[9] : undef;
    is($now_exists, $REAL_BSTATE_EXISTS,
        'guard: the real ~/.claude/butler-state existence is unchanged by this whole file');
    is($now_mtime, $REAL_BSTATE_MTIME,
        'guard: the real ~/.claude/butler-state mtime is unchanged by this whole file');
}
else {
    ok(1, 'guard: no real HOME/USERPROFILE resolvable in this environment to protect');
}

done_testing();
