# platform: any
# Regression for red-team H1's extend half (commit 4294be8,
# plugins/butler/scripts/butler-hold.pl): the running holder's own
# background-task id is now recorded in its own record as `self_task` at
# become time (resolve_self_task_id() -- the basename, minus ".output", of
# whatever file the holder process's own stdout is redirected to). A later
# FOREGROUND "butler-hold <ids>" call -- necessarily a DIFFERENT process, so
# its own stdout says nothing about the running holder's task id -- that
# names that id used to be accepted as an ordinary extend, and the holder
# would then be holding itself until the deadline: the H1 defence butler-
# hold.pl already has for a BECOME (an item list that mentions the calling
# process's own id) had no counterpart on the EXTEND path. butler-hold.pl
# now refuses such an extend with "a holder cannot hold itself." and leaves
# the record unchanged; an extend naming any OTHER id still works, and the
# extended record keeps carrying `self_task`.
#
# Test hygiene mirrors plugins/butler/tests/t/hold-prunes-unseen-ids.t:
# tickets are written in-process through BpHook (real); butler-hold is
# always spawned as a real subprocess (fork + exec('bash', <shim>, @argv));
# every spawned pid goes on @KILL_PIDS, reaped in END with a bounded
# TERM-then-KILL; HOME/USERPROFILE point at a decoy tempdir;
# BUTLER_STATE_DIR is an absolute tempdir; every BP_*/CCPRAXIS_*/CLAUDE_*
# except CCPRAXIS_NO_WAKELOCK is stripped from this process and every
# child. BUTLER_HOLD_TEST_TICK/_SECONDS are kept small so this file runs in
# well under a minute.
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
# helpers (trimmed from hold-prunes-unseen-ids.t / holder-observability.t)
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

# spawn_cmd(shim, argv, env_over) -- spawns with stdout/stderr redirected to
# fresh anonymous tempfiles (used for the plain foreground extend calls,
# which never need to resolve their own self-task id).
sub spawn_cmd {
    my ($shim, $argv, $env_over) = @_;
    $env_over //= {};
    my (undef, $outfile) = tempfile(DIR => $TMPROOT);
    my (undef, $errfile) = tempfile(DIR => $TMPROOT);
    return spawn_cmd_to($shim, $argv, $env_over, $outfile, $errfile);
}

# spawn_cmd_named(shim, argv, env_over, outfile) -- spawns with stdout
# redirected to a CALLER-CHOSEN path, so resolve_self_task_id() (which reads
# readlink("/proc/$$/fd/1") and strips ".output") resolves this process's
# own self-task id to the basename of that exact path.
sub spawn_cmd_named {
    my ($shim, $argv, $env_over, $outfile) = @_;
    $env_over //= {};
    my (undef, $errfile) = tempfile(DIR => $TMPROOT);
    return spawn_cmd_to($shim, $argv, $env_over, $outfile, $errfile);
}

sub spawn_cmd_to {
    my ($shim, $argv, $env_over, $outfile, $errfile) = @_;
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

sub run_cmd {
    my ($shim, $argv, $env_over, $timeout) = @_;
    my ($pid, $outfile, $errfile) = spawn_cmd($shim, $argv, $env_over);
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, $timeout // 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
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

# ===========================================================================
# Setup -- one holder, become'd with its own stdout redirected to a file
# named "<dir>/selfh0ld1.output", holding a made-up id "realx" (no
# BUTLER_HOLD_TEST_UNSEEN_GRACE is set, so "realx" is never pruned for
# being unseen -- irrelevant to this file, which is only about the self-id
# refusal, but kept exactly like hold-prunes-unseen-ids.t's unset default).
# ===========================================================================
my $sid = 'hrse-case-sid';
my $tp  = transcript_path_for($sid);
open my $fh, '>:raw', $tp or die "open $tp: $!";
close $fh;
write_ticket_for($sid, ['realx'], transcript_path => $tp, background => 1);

(my $SELF_OUT = "$TMPROOT/selfh0ld1.output") =~ s{\\}{/}g;
my ($pid, $outfile, $errfile) = spawn_cmd_named($HOLD_SHIM, ['realx'],
    { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 }, $SELF_OUT);
push @KILL_PIDS, $pid;

my $h = wait_for_holder($sid, 30);
ok(ref $h eq 'HASH', 'setup: a holder record appears after become');

# ===========================================================================
# Case 1 -- the become'd holder's own record carries self_task = selfh0ld1,
# resolved from the basename of its own stdout redirect target.
# ===========================================================================
SKIP: {
    skip 'case1: no record to inspect', 2 unless ref $h eq 'HASH';
    is($h->{self_task}, 'selfh0ld1', 'case1: the holder record carries self_task = selfh0ld1');
    is_deeply($h->{items}, ['realx'], 'case1: items = [realx] at become time');
}
my $ext_seq_before = (ref $h eq 'HASH') ? ($h->{ext_seq} // 0) : undef;

# ===========================================================================
# Case 2 -- H1 extend-half defect: a foreground "butler-hold selfh0ld1" from
# a DIFFERENT process (this test, standing in for red-team H1's attacker)
# names the running holder's own self_task id. Before the fix this was an
# ordinary extend that merged "selfh0ld1" into items and held the holder on
# itself until the deadline; now it is refused outright and the record is
# left byte-for-byte unchanged.
# ===========================================================================
write_ticket_for($sid, ['selfh0ld1'], transcript_path => $tp, background => 0);
my ($out2, $err2, $rc2) = run_cmd($HOLD_SHIM, ['selfh0ld1'], {}, 10);

isnt($rc2, 0, 'case2: a foreground extend naming the holder\'s own self_task id exits non-zero');
like($out2, qr/a holder cannot hold itself\./,
    'case2: refusal names "a holder cannot hold itself."');

my $h2 = BpHook::holder($sid);
ok(ref $h2 eq 'HASH', 'case2: the holder record still exists after the refusal');
SKIP: {
    skip 'case2: no record to inspect', 3 unless ref $h2 eq 'HASH';
    is_deeply($h2->{items}, ['realx'], 'case2: items is still exactly [realx] -- the refused extend changed nothing');
    is(($h2->{ext_seq} // 0), $ext_seq_before, 'case2: ext_seq is unchanged by the refused extend');
    is($h2->{self_task}, 'selfh0ld1', 'case2: self_task is still selfh0ld1 after the refusal');
}

# ===========================================================================
# Case 3 -- an extend naming a DIFFERENT, ordinary id still works exactly
# like any other extend: it succeeds, merges into items, and the record
# keeps carrying self_task.
# ===========================================================================
write_ticket_for($sid, ['other2'], transcript_path => $tp, background => 0);
my ($out3, $err3, $rc3) = run_cmd($HOLD_SHIM, ['other2'], {}, 10);

is($rc3, 0, 'case3: a foreground extend naming a different id exits 0');
is($err3, '', 'case3: case3 extend stderr is empty');
like($out3, qr/extended the running holder/, 'case3: the usual "extended the running holder" line is printed');

my $h3 = BpHook::holder($sid);
ok(ref $h3 eq 'HASH', 'case3: the holder record still exists after the accepted extend');
SKIP: {
    skip 'case3: no record to inspect', 2 unless ref $h3 eq 'HASH';
    is_deeply($h3->{items}, ['realx', 'other2'], 'case3: items is now [realx, other2]');
    is($h3->{self_task}, 'selfh0ld1', 'case3: self_task is still selfh0ld1 after the accepted extend');
}

# ---------------------------------------------------------------------------
# teardown -- kill the still-running holder
# ---------------------------------------------------------------------------
if (defined $pid) {
    kill('TERM', $pid);
    wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
}
unlink $outfile, $errfile if defined $outfile;

done_testing();
