#!/usr/bin/env perl
# platform: any
# ORACLE for package 11-ac-loss-clean-suspend-cycle (blueprint tooling-backlog),
# AC-6 of .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md sec 2.7/3.4: butler-hold.pl's
# grace-expiry probe during its wait loop (exit 4, "ACLOSS").
#
# butler-hold.pl does NOT yet have this behavior, and BpAcWatch.pm does not
# exist at all. Every case below spawns a REAL subprocess through
# `bash <repo>/bin/butler-hold ...` (mirroring continuity-holder.t's own
# "Test rules" spawn shape); with BpAcWatch.pm absent, the require inside
# butler-hold.pl's AC check is swallowed per spec 2.7's own "a die inside
# the check is swallowed" rule -- so TODAY this file's holder behaves
# exactly like a holder with no AC watching at all (never exits 4, no
# ACLOSS line, no log file), which is exactly what every assertion below is
# written to fail against.
#
# Written BLIND to any implementation file: derived only from spec 2.7 (the
# five numbered holder-wake steps) and 3.4 ("Holder wake").
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

my $S    = "$Bin/../../scripts"; $S    =~ s{\\}{/}g;
my $BIN  = "$Bin/../../bin";     $BIN  =~ s{\\}{/}g;
my $SHIM = "$BIN/butler-hold";

require "$S/BpHook.pm";   # already real/implemented

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

my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
(my $PROJECT = "$TMPROOT/proj") =~ s{\\}{/}g;
make_path($PROJECT);
(my $STATE_DIR = "$TMPROOT/state") =~ s{\\}{/}g;
(my $DATA_DIR  = "$TMPROOT/data") =~ s{\\}{/}g;
make_path("$DATA_DIR/.drive-solo");

my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME}             = $FAKE_HOME;
$ENV{USERPROFILE}      = $FAKE_HOME;
$ENV{BUTLER_STATE_DIR} = $STATE_DIR;

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

my $TUID_N = 0;
sub next_tuid { return sprintf('acw%06x', ++$TUID_N) }

sub write_ticket_for {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path},
        cwd             => $o{cwd} // $PROJECT,
    };
    my $ok = BpHook::write_ticket($p, 'butler-hold', $argv, operator => 0, background => 1);
    return ($ok, $tuid);
}

sub write_transcript {
    my ($path) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} "placeholder\n";
    close $fh;
}

sub arm_session {
    my ($sid, $role) = @_;
    return BpHook::arm($sid, role => $role, by => 'ac-watch-test');
}

# spawn_hold(\@argv, \%env_over) -> ($pid, $outfile, $errfile)
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
        $ENV{CCPRAXIS_DATA_DIR}     = $DATA_DIR;
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

sub write_probe_file {
    my ($reading) = @_;
    my (undef, $pf) = tempfile();
    open my $fh, '>', $pf or die $!;
    print {$fh} "$reading\n";
    close $fh;
    return $pf;
}

my $CNT = 0;
sub next_sid { return 'acw-sid-' . (++$CNT) }

# ===========================================================================
# AC-6: a driver-armed holder, probe file reading dc, grace=1s -> exits 4,
# the ACLOSS line, the released line + item report, the record gone,
# HOLDER-WAKE logged.
# ===========================================================================
{
    my $sid = next_sid();
    my $tp = "$PROJECT/$sid.jsonl";
    write_transcript($tp);
    ok(arm_session($sid, 'driver'), 'AC-6: precondition -- the session armed as driver');
    write_ticket_for($sid, ['Z'], transcript_path => $tp, background => 1);
    my $pf = write_probe_file('dc');

    my ($pid, $outfile, $errfile) = spawn_hold(['Z'], {
        BUTLER_HOLD_TEST_SECONDS => 5, BUTLER_HOLD_TEST_TICK => 0.2,
        CCPRAXIS_AC_PROBE_FILE => $pf, CCPRAXIS_AC_GRACE_SECONDS => 1,
    });
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 20);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;

    is($rc, 4, 'AC-6: a driver-armed holder on battery past grace exits 4');
    my @l = lines_of($out);
    ok((grep { /^ACLOSS on battery since/ } @l), 'AC-6: an "ACLOSS on battery since" line is present');
    ok((grep { /\breleased:\s/ } @l), 'AC-6: a "released:" line is present');
    ok(!-f "$STATE_DIR/continuity/holder/$sid.json", 'AC-6: the holder record is gone');

    my $log = slurp("$DATA_DIR/.drive-solo/ac-cycle.log");
    like($log, qr/HOLDER-WAKE/, 'AC-6: the ac-cycle.log carries a HOLDER-WAKE line') if length $log;
}

# ===========================================================================
# AC-6: a non-driver-armed holder never exits 4, even with the same dc probe
# file and 1s grace.
# ===========================================================================
{
    my $sid = next_sid();
    my $tp = "$PROJECT/$sid.jsonl";
    write_transcript($tp);
    ok(arm_session($sid, 'reporter'), 'AC-6: precondition -- the session armed as reporter (non-driver)');
    write_ticket_for($sid, ['Z'], transcript_path => $tp, background => 1);
    my $pf = write_probe_file('dc');

    my ($pid, $outfile, $errfile) = spawn_hold(['Z'], {
        BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2,
        CCPRAXIS_AC_PROBE_FILE => $pf, CCPRAXIS_AC_GRACE_SECONDS => 1,
    });
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;

    isnt($rc, 4, 'AC-6: a non-driver-armed holder never exits 4');
    unlike($out, qr/ACLOSS/, 'AC-6: a non-driver-armed holders stdout never carries ACLOSS');
}

# ===========================================================================
# AC-6: a driver-armed holder with NO probe file configured never exits 4
# (BUTLER_HOLD_TEST_MODE alone is not enough; spec 2.7's 4th precondition).
# ===========================================================================
{
    my $sid = next_sid();
    my $tp = "$PROJECT/$sid.jsonl";
    write_transcript($tp);
    ok(arm_session($sid, 'driver'), 'AC-6: precondition -- the session armed as driver');
    write_ticket_for($sid, ['Z'], transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_hold(['Z'], {
        BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2,
        CCPRAXIS_AC_PROBE_FILE => undef,
    });
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    unlink $outfile, $errfile;

    isnt($rc, 4, 'AC-6: without a probe file, a driver-armed holder never exits 4');
    unlike($out, qr/ACLOSS/, 'AC-6: without a probe file, stdout never carries ACLOSS');
}

done_testing();
