#!/usr/bin/env perl
# platform: any
# Bug 20260826-121852-3570: a reporter whose fleet had settled turned
# continuity off, put a six-hour deploy in the background and ended its turn.
# Nothing woke it for 5 h 43 min. butler-continuity's agent `off` now refuses
# while this session's holder (butler-hold) is still waiting on running work:
# the work the session holds is unfinished work, and the holder already wakes
# the session when it ends.
#
# Checked here, through the real CLI:
#   - agent off with a live holder is refused, names the held ids, and mints
#     no disarm code;
#   - once the holder process is gone, agent off proceeds to the disarm code
#     as before;
#   - the operator's own off disarms even while the holder is live.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $CMD = "$S/butler-continuity.pl";
require "$S/BpHook.pm";

my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid); local $@; eval { waitpid($pid, 0) } }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
(my $DECOY = tempdir(CLEANUP => 1) . '/decoy-home') =~ s{\\}{/}g;
make_path($DECOY);
$ENV{$_} = $DECOY for qw(HOME USERPROFILE ALMANAC_HOME);
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
my $TMPROOT = tempdir(CLEANUP => 1);

my ($PROJECT, $STATE_BASE, $CFG_DIR);
sub fresh_state_dir {
    ($PROJECT    = tempdir(CLEANUP => 1) . '/project') =~ s{\\}{/}g;
    ($STATE_BASE = tempdir(CLEANUP => 1) . '/state')   =~ s{\\}{/}g;
    ($CFG_DIR    = tempdir(CLEANUP => 1) . '/config')  =~ s{\\}{/}g;
    make_path("$PROJECT/.ccpraxis-local-data");
    $ENV{CLAUDE_PROJECT_DIR} = $PROJECT;
    $ENV{BUTLER_STATE_DIR}   = $STATE_BASE;
    $ENV{CLAUDE_CONFIG_DIR}  = $CFG_DIR;
}
sub state_root { "$STATE_BASE/continuity" }

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

my $N = 0;
sub sess_id { my ($tag) = @_; substr('s' . $tag . sha1_hex($tag . rand() . time() . ++$N), 0, 24) }

sub ticket {
    my ($sid, $argv, %o) = @_;
    my $dir = "$TMPROOT/transcripts";
    make_path($dir);
    my $tp = "$dir/$sid.jsonl";
    open my $fh, '>', $tp or die "$tp: $!";
    print {$fh} "{}\n";
    close $fh;
    my $p = { session_id => $sid, tool_use_id => sprintf('tu%06x', ++$N),
              transcript_path => $tp, cwd => $PROJECT };
    BpHook::write_ticket($p, 'butler-continuity', $argv, operator => ($o{operator} ? 1 : 0), background => 0);
}

sub run_cmd {
    my (@args) = @_;
    my (undef, $of) = tempfile();
    my (undef, $ef) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $of) or POSIX::_exit(126);
        open(STDERR, '>', $ef) or POSIX::_exit(126);
        { exec($^X, $CMD, @args) };
        POSIX::_exit(127);
    }
    my $deadline = time() + 60;
    my $rc;
    while (time() < $deadline) {
        if (waitpid($pid, WNOHANG) == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    my ($out, $err) = (slurp($of), slurp($ef));
    unlink $of, $ef;
    return ($out, $err, $rc);
}

# A live process standing in for butler-hold, and its holder record in the
# shape butler-hold writes (pid plus the /proc cmdline fingerprint where
# /proc exists, a deadline inside the hour, the held ids).
sub start_holder {
    my ($sid, @items) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) { { exec($^X, q{-e}, q{sleep 120}) }; POSIX::_exit(127) }
    push @KILL_PIDS, $pid;
    my $fp = '';
    for (1 .. 40) {
        my $c = slurp("/proc/$pid/cmdline");
        if (length $c && $c =~ /sleep 120/) { $fp = sha1_hex($c); last }
        last unless -r '/proc/self/cmdline';
        sleep(0.05);
    }
    my $dir = state_root() . '/holder';
    make_path($dir);
    my $now = time();
    open my $fh, '>:raw', "$dir/$sid.json" or die "$!";
    print {$fh} JSON::PP->new->canonical->encode({
        session_id => $sid, token => 'tok', pid => $pid, fp => $fp,
        items => [@items], held => [@items], ext_seq => 0, outputs => {},
        started_at => $now, deadline => $now + 600, transcript_path => '',
    });
    close $fh;
    return $pid;
}

sub stop_holder {
    my ($pid) = @_;
    kill('KILL', $pid);
    waitpid($pid, 0);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
}

sub otp_current { my ($sid) = @_; -e state_root() . "/disarm-otps/$sid.current" }

{
    fresh_state_dir();
    my $sid = sess_id('held');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'setup: session armed');
    my $hp = start_holder($sid, 'bdeploy01');
    ok(BpHook::holder_live($sid, {}), 'setup: the holder reads as live');

    ticket($sid, ['off', '--reason', 'deploy started, all done']);
    my ($out, $err, $rc) = run_cmd('off', '--reason', 'deploy started, all done');
    is($rc, 1, 'agent off with a live holder is refused');
    like($err, qr/holder is still waiting on running work \(bdeploy01\)/, 'and names the held work');
    ok(!otp_current($sid), 'and mints no disarm code');
    ok(-e state_root() . "/armed/$sid", 'the session stays armed');

    stop_holder($hp);
    ok(!BpHook::holder_live($sid, {}), 'setup: the holder is gone');
    ticket($sid, ['off', '--reason', 'deploy finished, all done']);
    ($out, $err, $rc) = run_cmd('off', '--reason', 'deploy finished, all done');
    like($err, qr/off not done yet/, 'with the holder gone, agent off proceeds to the disarm code') or diag($err);
    ok(otp_current($sid), 'and mints one');
}

{
    fresh_state_dir();
    my $sid = sess_id('oper');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'setup: session armed');
    my $hp = start_holder($sid, 'bdeploy02');
    ticket($sid, ['off'], operator => 1);
    my ($out, $err, $rc) = run_cmd('off');
    is($rc, 0, "the operator's off disarms even with a live holder") or diag($err);
    ok(!-e state_root() . "/armed/$sid", 'and the session is disarmed');
    stop_holder($hp);
}

done_testing();
