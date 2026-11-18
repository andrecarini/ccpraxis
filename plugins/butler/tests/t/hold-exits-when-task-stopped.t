# platform: any
# Regression for bug 20261118-003338-92e7: stopping the background task a
# holder runs as left butler-hold.pl alive on Windows. TaskStop killed the
# shell Claude Code had started, but no signal reached the MSYS perl, so the
# holder kept its record live (continuity off was refused while it lived)
# and would have held to its deadline.
#
# butler-hold.pl now learns its own task id from its stdout (a background
# task's stdout is tasks/<id>.output) and, on the tick that reads the
# transcript tail anyway, exits 143 with "released: its background task was
# stopped" once the tail shows that task stopped: TaskStop's
# "Successfully stopped task: <id>" result, or a non-running notification.
#
#   case 1  a TaskStop result for this holder's task -> exit 143, released
#   case 2  a <status>killed</status> notification for it -> same
#   case 3  a TaskStop result for ANOTHER task -> held to the deadline (exit 0)
#   case 4  stdout not under tasks/ (no task id) -> a stop line changes nothing
#
# Test hygiene mirrors hold-prunes-unseen-ids.t: tickets written in-process
# through BpHook, butler-hold spawned as a real subprocess through its shim,
# every pid reaped in END, HOME/USERPROFILE on a decoy, BP_/CCPRAXIS_/CLAUDE_
# stripped, short test ticks.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

my $S   = "$Bin/../../scripts"; $S   =~ s{\\}{/}g;
my $BIN = "$Bin/../../bin";     $BIN =~ s{\\}{/}g;
my $HOLD_SHIM = "$BIN/butler-hold";

require "$S/BpHook.pm";

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

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
my $PROJECT = "$TMPROOT/proj";
make_path($PROJECT, "$TMPROOT/tasks", "$TMPROOT/plain");
my $STATE_DIR = "$TMPROOT/state";
my $DECOY_HOME = "$TMPROOT/decoy-home";
make_path($DECOY_HOME);

my %CHILD_ENV = (
    CCPRAXIS_NO_WAKELOCK  => 1,
    HOME                  => $DECOY_HOME,
    USERPROFILE           => $DECOY_HOME,
    BUTLER_STATE_DIR      => $STATE_DIR,
    BUTLER_HOLD_TEST_MODE => 1,
    CCPRAXIS_DATA_DIR     => "$TMPROOT/no-prompt-watch-data",
);
$ENV{$_} = $CHILD_ENV{$_} for keys %CHILD_ENV;

my $TUID_N = 0;

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub append_line {
    my ($path, $line) = @_;
    open my $fh, '>>:raw', $path or die "open $path: $!";
    print {$fh} "$line\n";
    close $fh;
}

# A transcript giving item 'work' real evidence (an output file it names), so
# it reads 'running' for the whole hold and only the stop can end it early.
sub start_transcript {
    my ($sid) = @_;
    my $tp = "$PROJECT/$sid.jsonl";
    my $work = "$PROJECT/$sid-work.output";
    open my $wf, '>:raw', $work or die "open $work: $!"; print {$wf} "output\n"; close $wf;
    open my $fh, '>:raw', $tp or die "open $tp: $!";
    print {$fh} "Output is being written to: $work\n";
    close $fh;
    return $tp;
}

sub spawn_holder {
    my ($sid, $tp, $outfile, $secs) = @_;
    my $ok = BpHook::write_ticket(
        { session_id => $sid, tool_use_id => sprintf('tu%06x', ++$TUID_N),
          transcript_path => $tp, cwd => $PROJECT },
        'butler-hold', ['work'], operator => 0, background => 1);
    die "write_ticket failed" unless $ok;
    my $errfile = "$TMPROOT/plain/$sid.err";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{$_} = $CHILD_ENV{$_} for keys %CHILD_ENV;
        $ENV{BUTLER_HOLD_TEST_SECONDS} = $secs;
        $ENV{BUTLER_HOLD_TEST_TICK}    = 0.2;
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('bash', $HOLD_SHIM, 'work');
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    return ($pid, $errfile);
}

sub wait_for_holder {
    my ($sid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if ref BpHook::holder($sid) eq 'HASH';
        sleep(0.05);
    }
    return 0;
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
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return $rc;
}

# TaskStop's tool result as Claude Code writes it into the transcript.
sub stop_result_line {
    my ($task_id) = @_;
    return qq({"type":"user","toolUseResult":{"message":"Successfully stopped task: $task_id (butler-hold work)","task_id":"$task_id","task_type":"local_bash","command":"butler-hold work"}});
}

# ---------------------------------------------------------------------------
for my $case (
    [ 1, 'a TaskStop result',         'bstop01', sub { stop_result_line('bstop01') } ],
    [ 2, 'a killed notification',     'bstop02',
      sub { q({"type":"queue-operation","content":"<task-notification>\n<task-id>bstop02</task-id>\n<status>killed</status>\n</task-notification>"}) } ],
) {
    my ($n, $what, $task_id, $line) = @$case;
    my $sid = "hets-case$n";
    my $tp  = start_transcript($sid);
    my $outfile = "$TMPROOT/tasks/$task_id.output";
    my ($pid, $errfile) = spawn_holder($sid, $tp, $outfile, 30);
    ok(wait_for_holder($sid, 10), "case$n: the holder is up");
    sleep(0.5);
    my $t0 = time();
    append_line($tp, $line->());
    my $rc = wait_pid_bounded($pid, 10);
    my $took = time() - $t0;
    my $out = slurp($outfile);
    is($rc, 143, "case$n: $what for its own task ends the holder with 143");
    cmp_ok($took, '<', 8, "case$n: ...within a few ticks, not at the 30s deadline");
    like($out, qr/released: its background task was stopped/, "case$n: ...and says why");
    like($out, qr/^work (?:still running|finished|unknown)/m, "case$n: the item report still names the held item");
    is(slurp($errfile), '', "case$n: stderr empty");
    ok(!BpHook::holder_live($sid), "case$n: no live holder remains, so continuity off is not refused");
}

{
    my $sid = 'hets-case3';
    my $tp  = start_transcript($sid);
    my $outfile = "$TMPROOT/tasks/bstop03.output";
    my ($pid, $errfile) = spawn_holder($sid, $tp, $outfile, 3);
    ok(wait_for_holder($sid, 10), 'case3: the holder is up');
    append_line($tp, stop_result_line('bother99'));
    my $rc = wait_pid_bounded($pid, 15);
    my $out = slurp($outfile);
    is($rc, 0, 'case3: a stop of another task does not end the holder');
    like($out, qr/released: deadline reached/, 'case3: it holds to its deadline');
    is(slurp($errfile), '', 'case3: stderr empty');
}

{
    my $sid = 'hets-case4';
    my $tp  = start_transcript($sid);
    my $outfile = "$TMPROOT/plain/bstop04.output";
    my ($pid, $errfile) = spawn_holder($sid, $tp, $outfile, 3);
    ok(wait_for_holder($sid, 10), 'case4: the holder is up');
    append_line($tp, stop_result_line('bstop04'));
    my $rc = wait_pid_bounded($pid, 15);
    my $out = slurp($outfile);
    is($rc, 0, 'case4: with stdout outside tasks/ there is no task id, so nothing matches');
    like($out, qr/released: deadline reached/, 'case4: it holds to its deadline');
}

done_testing();
