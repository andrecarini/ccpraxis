# platform: any
# Regression for red-team SF-2 (judged-continuity-disarm/05, todo
# 20261023-082209-24290000): "butler-hold <made-up-id>" used to let every
# Stop through for the full 50-minute hold on a name alone -- an id nothing
# can see (no subagents/agent-<id>.jsonl, no output file, nothing in the
# transcript tail: item_status() => 'unknown') was held to the deadline
# exactly like a real, running one. butler-hold.pl's item_gone() now also
# prunes an id that has read 'unknown' continuously for
# unseen_grace_seconds(): 2 x tick in production, or in test mode only when
# BUTLER_HOLD_TEST_UNSEEN_GRACE=<seconds> is set (unset keeps older fixtures
# that hold bare made-up ids to exercise unrelated behaviour working, by
# never pruning on unseen-ness alone).
#
# Test hygiene mirrors plugins/butler/tests/t/holder-observability.t and
# plugins/butler/tests/t/continuity-holder.t: tickets are written in-process
# through BpHook (real); butler-hold is always spawned as a real subprocess
# (fork + exec('bash', <shim>, @argv)); every spawned pid goes on
# @KILL_PIDS, reaped in END with a bounded TERM-then-KILL; HOME/USERPROFILE
# point at a decoy tempdir; BUTLER_STATE_DIR is an absolute tempdir; every
# BP_*/CCPRAXIS_*/CLAUDE_* except CCPRAXIS_NO_WAKELOCK is stripped from this
# process and every child. BUTLER_HOLD_TEST_TICK/_SECONDS are kept small so
# this file runs in well under a minute.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

my $S   = "$Bin/../../scripts"; $S   =~ s{\\}{/}g;
my $BIN = "$Bin/../../bin";     $BIN =~ s{\\}{/}g;
my $HOLD_SHIM = "$BIN/butler-hold";

require "$S/BpHook.pm";

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
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
(my $PROJECT = "$TMPROOT/proj") =~ s{\\}{/}g;
make_path($PROJECT);
(my $STATE_DIR = "$TMPROOT/state") =~ s{\\}{/}g;

my $DECOY_ROOT = tempdir(CLEANUP => 1);
(my $DECOY_HOME = "$DECOY_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($DECOY_HOME);
$ENV{HOME}                  = $DECOY_HOME;
$ENV{USERPROFILE}           = $DECOY_HOME;
$ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
$ENV{BUTLER_HOLD_TEST_MODE} = 1;
# never-halt 06: a fixture, never-existing data root, so butler-hold's
# prompt-watch resolution (BpDataRoot::resolve) stays OFF hermetically.
$ENV{CCPRAXIS_DATA_DIR}     = "$TMPROOT/no-prompt-watch-data";

my $CONT_ROOT = "$STATE_DIR/continuity";

# ---------------------------------------------------------------------------
# helpers (trimmed from holder-observability.t / continuity-holder.t)
# ---------------------------------------------------------------------------
my $TUID_N = 0;
sub next_tuid { return sprintf('tu%06x', ++$TUID_N) }

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

sub write_ticket_for {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path},
        cwd             => $o{cwd} // $PROJECT,
    };
    my $ok = BpHook::write_ticket($p, 'butler-hold', $argv,
        operator => 0, background => (exists $o{background} ? $o{background} : 1));
    return ($ok, $tuid);
}

sub spawn_cmd {
    my ($shim, $argv, $env_over) = @_;
    $env_over //= {};
    my (undef, $outfile) = tempfile(DIR => $TMPROOT);
    my (undef, $errfile) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{CCPRAXIS_NO_WAKELOCK}  = 1;
        $ENV{HOME}                  = $DECOY_HOME;
        $ENV{USERPROFILE}           = $DECOY_HOME;
        $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE} = 1;
        $ENV{CCPRAXIS_DATA_DIR}     = "$TMPROOT/no-prompt-watch-data";
        for my $k (keys %$env_over) {
            if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} }
            else                          { delete $ENV{$k} }
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('bash', $shim, @$argv);
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

sub wait_for_stdout_match {
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

sub transcript_path_for { my ($sid) = @_; return "$PROJECT/$sid.jsonl" }

# write_transcript_with_output(path, id, real_path) -- an "Output is being
# written to:" line referencing a real, existing file, so item_status()
# resolves $id as a task item with real (non-subagent) evidence: 'running',
# never 'unknown' -- exactly how holder-observability.t / continuity-holder.t
# give a made-up-looking id real evidence (write_output_file / bg_output).
sub write_transcript_with_output {
    my ($path, $id, $real_path) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    my $winpath = ($real_path =~ m{^[A-Za-z]:}) ? do { (my $w = $real_path) =~ s{/}{\\}g; $w }
                                                 : $real_path;
    print {$fh} "Output is being written to: $winpath\n";
    close $fh;
    return $path;
}

sub write_output_file {
    my ($path) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} "output\n";
    close $fh;
    return $path;
}

# ===========================================================================
# Case 1 -- a made-up id with no evidence, grace=1s: pruned well before the
# (far away) deadline; "dropped" line + "or was never seen" release; the
# holder record is gone.
# ===========================================================================
{
    my $sid = 'hpu-case1-sid';
    my $tp  = transcript_path_for($sid);
    open my $fh, '>:raw', $tp or die "open $tp: $!";
    close $fh;
    write_ticket_for($sid, ['ghost1'], transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['ghost1'],
        { BUTLER_HOLD_TEST_SECONDS => 8, BUTLER_HOLD_TEST_TICK => 0.2,
          BUTLER_HOLD_TEST_UNSEEN_GRACE => 1 });
    push @KILL_PIDS, $pid;

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'case1: exits 0, well before the 8s deadline');
    is($err, '', 'case1: stderr empty');
    like($out, qr/dropped, nothing shows it running: ghost1; still waiting on: nothing/,
        'case1: a "dropped" line names ghost1 and nothing left to wait on');
    like($out, qr/released: every held item finished or was never seen/,
        'case1: release reason credits the unseen prune');
    ok(!-f "$CONT_ROOT/holder/$sid.json", 'case1: the holder record is gone');
}

# ===========================================================================
# Case 2 -- mixed: one id with real, present evidence (an output file
# referenced from the transcript) plus one made-up id, grace=1s: the
# made-up id is dropped (still waiting on the real id), the real id is never
# dropped, and the holder goes on to release on "deadline reached".
# ===========================================================================
{
    my $sid  = 'hpu-case2-sid';
    my $tp   = transcript_path_for($sid);
    my $opath = write_output_file("$PROJECT/real2.output");
    write_transcript_with_output($tp, 'real2', $opath);
    write_ticket_for($sid, ['real2', 'ghost2'], transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['real2', 'ghost2'],
        { BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.2,
          BUTLER_HOLD_TEST_UNSEEN_GRACE => 1 });
    push @KILL_PIDS, $pid;

    my $out = wait_for_stdout_match($outfile,
        qr/dropped, nothing shows it running: ghost2; still waiting on: real2/, 10);
    like($out, qr/dropped, nothing shows it running: ghost2; still waiting on: real2/,
        'case2: ghost2 is dropped, waiting only on real2');

    my $h = BpHook::holder($sid);
    ok(ref $h eq 'HASH', 'case2: the holder record still exists after the prune');
    SKIP: {
        skip 'case2: no record to inspect', 1 unless ref $h eq 'HASH';
        is_deeply($h->{items}, ['real2'], 'case2: real2 is the only id still held');
    }

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'case2: exits 0 at the deadline');
    is($err, '', 'case2: stderr empty');
    like($out, qr/released: deadline reached/, 'case2: releases on "deadline reached"');
    unlike($out, qr/dropped, nothing shows it running: real2/, 'case2: real2 is never dropped');
    like($out, qr/real2 still running/, "case2: real2's item line reports still running");
}

# ===========================================================================
# Case 3 -- opt-in documented: BUTLER_HOLD_TEST_UNSEEN_GRACE left UNSET in
# test mode never prunes on unseen-ness alone; a made-up id is held to the
# deadline exactly like before this change (the fixtures this preserves).
# ===========================================================================
{
    my $sid = 'hpu-case3-sid';
    my $tp  = transcript_path_for($sid);
    open my $fh, '>:raw', $tp or die "open $tp: $!";
    close $fh;
    write_ticket_for($sid, ['ghost3'], transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['ghost3'],
        { BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'case3: exits 0 at the deadline');
    is($err, '', 'case3: stderr empty');
    unlike($out, qr/dropped,/, 'case3: no "dropped" line -- grace unset never prunes on unseen-ness');
    like($out, qr/released: deadline reached$/m, 'case3: releases on "deadline reached"');
    like($out, qr/^ghost3 unknown$/m, "case3: ghost3's item line reports unknown");
}

# ===========================================================================
# Case 4 -- grace respected: a grace (30s) larger than the hold (3s) means a
# made-up id is not dropped before the deadline arrives first.
# ===========================================================================
{
    my $sid = 'hpu-case4-sid';
    my $tp  = transcript_path_for($sid);
    open my $fh, '>:raw', $tp or die "open $tp: $!";
    close $fh;
    write_ticket_for($sid, ['ghost4'], transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['ghost4'],
        { BUTLER_HOLD_TEST_SECONDS => 3, BUTLER_HOLD_TEST_TICK => 0.2,
          BUTLER_HOLD_TEST_UNSEEN_GRACE => 30 });
    push @KILL_PIDS, $pid;

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'case4: exits 0 at the deadline');
    is($err, '', 'case4: stderr empty');
    unlike($out, qr/dropped,/, 'case4: a 30s grace outlives a 3s hold -- never dropped');
    like($out, qr/released: deadline reached$/m, 'case4: releases on "deadline reached"');
}

done_testing();
