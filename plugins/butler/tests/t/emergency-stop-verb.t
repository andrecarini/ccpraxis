#!/usr/bin/env perl
# platform: any
# ORACLE for package 06-emergency-stop (blueprint judged-continuity-disarm),
# specs/06-emergency-stop-spec.md AC1-AC13 of section 4: the new
# `butler-continuity emergency-stop` verb and `BpHook::file_stop_bug`.
#
# NEITHER EXISTS YET at the time this file is written: `emergency-stop` is
# not in the verb whitelist (butler-continuity.pl:239), so every subprocess
# call below is expected to fail usage_die() with the unknown-verb usage
# line, and every in-process call that would depend on `file_stop_bug` or on
# ContinuityOffCheck recognizing `emergency-stop` is expected to see no bug
# filed / no ticket written -- never a Perl crash.
#
# House pattern (reused, not reinvented): tickets written in-process through
# BpHook::write_ticket (continuity-command-verbs.t), the CLI run as a real
# subprocess via fork/exec (continuity-command-verbs.t's spawn_cmd/run_cmd),
# thread fixtures created directly through Almanac::Thread
# (continuity-threads.t), and the lease-follows-arm idiom for AC11(b)
# (continuity-lease-follows-arm.t:381-431).
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
use Cwd ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $CMD = "$S/butler-continuity.pl";

require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";

{
    local $@;
    eval { require "$S/BpHook/ContinuityOffCheck.pm"; 1 }
        or diag("BpHook::ContinuityOffCheck did not load: $@");
}

BEGIN {
    my $dir = "$FindBin::Bin/../../../almanac/scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}
require Almanac::Thread;
require Almanac::Store;

# ---------------------------------------------------------------------------
# AC8 self-check: the repo's REAL bug-reports store. Snapshotted now, before
# any env mutation below, and again at the very end of this file. Every
# filing assertion in this file reads only the tempdir store (CCPRAXIS_
# DATA_DIR, set below); this list proves none of them leaked.
# ---------------------------------------------------------------------------
(my $REPO_ROOT = Cwd::abs_path("$Bin/../../../../")) =~ s{\\}{/}g;
my $REAL_STORE = "$REPO_ROOT/.ccpraxis-local-data/bug-reports";
sub real_store_snapshot {
    return () unless -d $REAL_STORE;
    opendir(my $dh, $REAL_STORE) or return ();
    my @f = sort grep { /\.md\z/ } readdir($dh);
    closedir $dh;
    return @f;
}
my @AC8_BEFORE = real_store_snapshot();

# ---------------------------------------------------------------------------
# process bookkeeping (house pattern)
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
# Isolation preamble (spec section 4 lead-in, DC7).
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_|BUTLER_)/ } keys %ENV;

my $TMPROOT = tempdir(CLEANUP => 1);
(my $PROJECT = "$TMPROOT/project") =~ s{\\}{/}g;
make_path("$PROJECT/.ccpraxis-local-data");
(my $DATA_DIR = "$PROJECT/.ccpraxis-local-data") =~ s{\\}{/}g;
(my $LEGACY = "$TMPROOT/legacy") =~ s{\\}{/}g;

my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME}        = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;
$ENV{ALMANAC_HOME} = $FAKE_HOME;

$ENV{CLAUDE_PROJECT_DIR}           = $PROJECT;
$ENV{CCPRAXIS_DATA_DIR}            = $DATA_DIR;
$ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $LEGACY;
$ENV{CCPRAXIS_NO_WAKELOCK}         = 1;

my $CURRENT_STATE_BASE;
sub use_state_dir {
    my ($dir) = @_;
    $ENV{BUTLER_STATE_DIR} = $dir;
    $CURRENT_STATE_BASE    = $dir;
    return $dir;
}
sub fresh_state_dir {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/state") =~ s{\\}{/}g;
    return use_state_dir($d);
}
fresh_state_dir();

sub state_root { return "$CURRENT_STATE_BASE/continuity" }

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

my $TUID_N = 0;
sub next_tuid { return sprintf('tu%06x', ++$TUID_N) }

sub sess_id {
    my ($tag) = @_;
    my $safe = defined $tag ? $tag : '';
    $safe =~ s/[^A-Za-z0-9_-]/-/g;
    my $id = substr('s' . $safe . sha1_hex((defined $tag ? $tag : '') . rand() . time()), 0, 24);
    die "sess_id($tag) produced an invalid session id: $id" unless $id =~ /^[A-Za-z0-9_-]{1,128}$/;
    return $id;
}
sub s8 { my ($sid) = @_; return substr($sid, 0, 8) }

sub write_ticket_argv {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path} // "$TMPROOT/transcripts/$sid.jsonl",
        cwd             => $o{cwd} // $PROJECT,
    };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    my $ok = BpHook::write_ticket($p, 'butler-continuity', $argv,
        operator => ($o{operator} ? 1 : 0), background => ($o{background} ? 1 : 0));
    return ($ok, $tuid, $p);
}

sub find_ticket_file {
    my ($sid, $tuid) = @_;
    my $root = state_root();
    my @found = glob("$root/tickets/*/$sid.$tuid.json");
    return $found[0];
}

sub read_json_file {
    my ($p) = @_;
    my $raw = slurp($p);
    return undef unless length $raw;
    return eval { JSON::PP->new->decode($raw) };
}

sub reasons_log_lines {
    my $p = state_root() . '/reasons.log';
    return () unless -f $p;
    open my $fh, '<:raw', $p or return ();
    my @lines = <$fh>;
    close $fh;
    return @lines;
}

# store_dir(%o) -- the bug-reports store for the CURRENT CCPRAXIS_DATA_DIR
# (or an explicit override, for AC7's "store unwritable" fixture).
sub store_dir {
    my (%o) = @_;
    my $dd = $o{data_dir} // $ENV{CCPRAXIS_DATA_DIR};
    return "$dd/bug-reports";
}
sub store_snapshot {
    my (%o) = @_;
    my $dir = store_dir(%o);
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { /\.md\z/ } readdir($dh);
    closedir $dh;
    return @f;
}
sub new_reports {
    my ($before, %o) = @_;
    my %seen = map { $_ => 1 } @$before;
    return grep { !$seen{$_} } store_snapshot(%o);
}

# spawn_cmd(\%env_over, @args) -> ($pid, $outfile, $errfile)
sub spawn_cmd {
    my ($env_over, @args) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my %eo = %$env_over;
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_|BUTLER_)/ } keys %ENV;
        $ENV{BUTLER_STATE_DIR}               = $CURRENT_STATE_BASE;
        $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $LEGACY;
        $ENV{CLAUDE_PROJECT_DIR}             = $PROJECT;
        $ENV{CCPRAXIS_DATA_DIR}              = $DATA_DIR;
        $ENV{HOME}                            = $FAKE_HOME;
        $ENV{USERPROFILE}                     = $FAKE_HOME;
        $ENV{ALMANAC_HOME}                    = $FAKE_HOME;
        $ENV{CCPRAXIS_NO_WAKELOCK}           = 1;
        for my $k (keys %eo) {
            if (defined $eo{$k}) { $ENV{$k} = $eo{$k} }
            else                 { delete $ENV{$k} }
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, $CMD, @args);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
}

sub wait_cmd {
    my ($pid, $outfile, $errfile, %o) = @_;
    my $deadline = time() + ($o{timeout} // 30);
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
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
}

sub run_cmd {
    my ($env_over, @args) = @_;
    my ($pid, $o, $e) = spawn_cmd($env_over, @args);
    push @KILL_PIDS, $pid;
    my @r = wait_cmd($pid, $o, $e);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return @r;
}

# OC(name, @args) -- call BpHook::ContinuityOffCheck::<name> without ever
# crashing this file when the sub or the module is not yet wired for
# emergency-stop.
sub OC {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpHook::ContinuityOffCheck::$name"} }
    my $ret;
    my $ok = eval { $ret = $code->(@args); 1 };
    return $ok ? $ret : undef;
}

# ===========================================================================
# AC1 / AC3 / AC4 / AC5 -- happy path, non-coordinator, no thread attached
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac1');
    ok(BpHook::arm($sid, role => 'manual', by => 'on', goal => 'ship the emergency-stop verb'),
        'AC1 setup: session armed with a goal');

    my @before = store_snapshot();
    write_ticket_argv($sid, ['emergency-stop', '--reason', 'tooling is broken here']);
    my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', 'tooling is broken here');
    is($rc, 0, 'AC1: emergency-stop --reason exits 0') or diag("stdout=$out stderr=$err");

    ok(!-e state_root() . "/armed/$sid", 'AC1: armed/<sid> is gone');
    ok(-e state_root() . "/off/$sid", 'AC1: off/<sid> exists');

    my ($otp_rec, $otp_code) = BpHook::take_disarm_otp('deadbeef', $sid);
    is($otp_code, 'no-live-otp', 'AC1: no disarm-OTP record exists for the session');
    unlike($out, qr/off-confirm/, 'AC1: output mentions no off-confirm');
    unlike($out, qr/--otp/, 'AC1: output mentions no --otp');

    my @lines = split /\n/, $out;
    is($lines[0], "continuity off for session " . s8($sid) . " (actor agent); reason logged.",
        'AC1: stdout line 1 is the disarm line');

    my @new = new_reports(\@before);
    is(scalar(@new), 1, 'AC3: exactly one new *.md report in the tempdir store') or diag("new=@new");
    my ($id) = $new[0] =~ /^(.*)\.md\z/;

    like($lines[-1] // '', qr/^emergency-stop: bug report \Q$id\E filed \(severity high, area butler\)\.$/,
        'AC1/B5: the last stdout line names the filed report');

    my $off = read_json_file(state_root() . "/off/$sid");
    is(ref $off eq 'HASH' ? $off->{actor} : undef, 'agent', 'AC1: off/<sid> has actor agent');
    is(ref $off eq 'HASH' ? $off->{reason} : undef,
        "tooling is broken here; bug report: $id",
        'AC4: off/<sid> reason is "<reason>; bug report: <id>"');

    my @sidlines = grep { /\Q$sid\E/ } reasons_log_lines();
    is(scalar(@sidlines), 1, 'AC5: exactly one new reasons.log line for this session');
    if (@sidlines) {
        chomp(my $line = $sidlines[0]);
        my @f = split /\t/, $line;
        is($f[2], 'agent', 'AC5: log line actor is agent');
        is($f[3], 'emergency-stop', 'AC5: log line verb/tag is emergency-stop');
        is($f[5], "tooling is broken here; bug report: $id",
            'AC4: reasons.log text column matches "<reason>; bug report: <id>"');
        like($line, qr/\tagent\temergency-stop\t/, 'AC5: the line matches the agent/emergency-stop shape');
    }

    my $report = slurp(store_dir() . "/$id.md");
    like($report, qr/^severity: high$/m, 'AC3: report frontmatter has severity: high');
    like($report, qr/^area: butler$/m, 'AC10: default area is butler');
    like($report, qr/^title: emergency-stop: tooling is broken here$/m, 'AC3/B2: report title');
    like($report, qr/^Reason: tooling is broken here$/m, 'AC3/B2: report body has the reason line');
    like($report, qr/^Session goal: ship the emergency-stop verb$/m, 'AC3/B2: report body has the goal line');
}

# ===========================================================================
# AC5 contrast -- a regular off/off-confirm flow logs \toff\t, not
# \temergency-stop\t, so the two are distinguishable by grep alone.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac5contrast');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC5 contrast setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'work all done']);
    my (undef, $err0, $rc0) = run_cmd({}, 'off', '--reason', 'work all done');
    is($rc0, 1, 'AC5 contrast setup: off mints an OTP first (exit 1)');
    my ($otp) = ($err0 =~ /^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m);
    ok(defined $otp, 'AC5 contrast setup: off printed a disarm OTP') or diag("stderr: $err0");

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my (undef, $errc, $rcc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => 'approve' }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rcc, 0, 'AC5 contrast: off-confirm exits 0') or diag("stderr: $errc");

    my @sidlines = grep { /\Q$sid\E/ } reasons_log_lines();
    ok((grep { /\toff\t/ } @sidlines), 'AC5 contrast: a plain off/off-confirm logs \toff\t, not \temergency-stop\t');
    ok(!(grep { /\temergency-stop\t/ } @sidlines), 'AC5 contrast: and never \temergency-stop\t');
}

# ===========================================================================
# AC2 -- a thread with an unlinked doing task: off refuses, emergency-stop
# still exits 0 and disarms (B3), with the hand-off degrading to a warning.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac2');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac2-thread', '--goal', 'exercise the doing-task gate']);
    my ($oon, $eon, $rcon) = run_cmd({}, 'on', '--new-thread', 'ac2-thread', '--goal', 'exercise the doing-task gate');
    is($rcon, 0, 'AC2 setup: on --new-thread exits 0') or diag("stderr: $eon");

    my $task;
    eval {
        $task = Almanac::Thread::add_task('ac2-thread', title => 'write the tests', actor => 'session', root => $PROJECT);
        Almanac::Thread::set_task_status('ac2-thread', $task->{id}, 'doing', actor => 'session', root => $PROJECT);
    };
    ok(!$@, 'AC2 setup: an unlinked doing task was created') or diag($@);

    write_ticket_argv($sid, ['off', '--reason', 'stopping here now']);
    my ($ooff, $eoff, $rcoff) = run_cmd({}, 'off', '--reason', 'stopping here now');
    is($rcoff, 1, 'AC2: off refuses while the thread has a task doing');
    like($eoff, qr/off refused:/, 'AC2: off refusal says "off refused:"');
    ok(-e state_root() . "/armed/$sid", 'AC2: off left armed/<sid> in place');

    my @before = store_snapshot();
    write_ticket_argv($sid, ['emergency-stop', '--reason', 'genuine defect blocks this run']);
    my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', 'genuine defect blocks this run');
    is($rc, 0, 'AC2: emergency-stop exits 0 despite the doing task') or diag("stdout=$out stderr=$err");
    ok(!-e state_root() . "/armed/$sid", 'AC2: emergency-stop disarms anyway (armed/<sid> gone)');
    ok(-e state_root() . "/off/$sid", 'AC2: off/<sid> exists');
    like($err, qr/thread ac2-thread was not handed off/, 'AC2: the hand-off degrades to a warning');

    my @new = new_reports(\@before);
    is(scalar(@new), 1, 'AC2: exactly one bug report was still filed');

    my $th = eval { Almanac::Thread::read_thread('ac2-thread', root => $PROJECT) };
    isnt(ref $th eq 'HASH' ? $th->{state} : undef, 'handed-off',
        'AC2: the thread stays live (never handed off under the doing-task lock)');
}

# ===========================================================================
# AC6 -- validation refusals (B7): exit 1, exact message, nothing filed,
# nothing disarmed, the ticket not consumed (where applicable).
# ===========================================================================
{
    my $REASON_MSG  = '--reason needs at least two words saying why.';
    my $LENGTH_MSG  = '--reason is at most 200 bytes; it goes into the thread log.';
    my $AREA_MSG    = '--area takes a short one-line area name, e.g. butler, sandbox or claude-code.';

    my @cases = (
        { label => 'no --reason at all',        argv => [] },
        { label => '--reason with no value',     argv => ['--reason'] },
        { label => '--reason empty',             argv => ['--reason', ''] },
        { label => '--reason one word',          argv => ['--reason', 'done'] },
        { label => '--reason whitespace/zero-width only',
          argv => ['--reason', "\xe2\x80\x8b \xe2\x80\x8b"] },
    );
    for my $c (@cases) {
        fresh_state_dir();
        my $sid = sess_id('ac6' . $c->{label});
        ok(BpHook::arm($sid, role => 'manual', by => 'on'), "AC6 setup ($c->{label}): armed");
        my @argv = ('emergency-stop', @{ $c->{argv} });
        my @before = store_snapshot();
        my $before_log = scalar(grep { /\Q$sid\E/ } reasons_log_lines());
        write_ticket_argv($sid, \@argv);
        my ($out, $err, $rc) = run_cmd({}, @argv);
        is($rc, 1, "AC6 ($c->{label}): exits 1") or diag("stdout=$out stderr=$err");
        is($err, "butler-continuity: $REASON_MSG\n", "AC6 ($c->{label}): exact refusal message");
        ok(-e state_root() . "/armed/$sid", "AC6 ($c->{label}): session is still armed");
        is_deeply([ new_reports(\@before) ], [], "AC6 ($c->{label}): nothing filed");
        my $after_log = scalar(grep { /\Q$sid\E/ } reasons_log_lines());
        is($after_log, $before_log, "AC6 ($c->{label}): reasons.log unchanged");
    }

    # a two-word reason padded past 200 UTF-8 bytes with real multi-byte
    # characters ("\xc3\xa9" = the two-byte UTF-8 encoding of e-acute).
    {
        fresh_state_dir();
        my $sid = sess_id('ac6-toolong');
        ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC6 setup (too long): armed');
        my $padded = "a " . ("\xc3\xa9" x 102);
        my @before = store_snapshot();
        write_ticket_argv($sid, ['emergency-stop', '--reason', $padded]);
        my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', $padded);
        is($rc, 1, 'AC6 (too long): exits 1') or diag("stdout=$out stderr=$err");
        is($err, "butler-continuity: $LENGTH_MSG\n", 'AC6 (too long): exact refusal message');
        ok(-e state_root() . "/armed/$sid", 'AC6 (too long): session is still armed');
        is_deeply([ new_reports(\@before) ], [], 'AC6 (too long): nothing filed');
    }

    # bad --area (AC10's refusal half).
    for my $bad (['--area', '-x'], ['--area', ''], ['--area', 'x' x 65]) {
        fresh_state_dir();
        my $sid = sess_id('ac10bad' . join('', @$bad));
        ok(BpHook::arm($sid, role => 'manual', by => 'on'), "AC10 setup (bad area @$bad): armed");
        my @argv = ('emergency-stop', '--reason', 'a defect here', @$bad);
        my @before = store_snapshot();
        write_ticket_argv($sid, \@argv);
        my ($out, $err, $rc) = run_cmd({}, @argv);
        is($rc, 1, "AC10 (bad area @$bad): exits 1") or diag("stdout=$out stderr=$err");
        is($err, "butler-continuity: $AREA_MSG\n", "AC10 (bad area @$bad): exact refusal message");
        ok(-e state_root() . "/armed/$sid", "AC10 (bad area @$bad): session is still armed");
        is_deeply([ new_reports(\@before) ], [], "AC10 (bad area @$bad): nothing filed");
    }

    # unknown flag / repeated flag / stray positional -> usage_die.
    for my $bad_argv (
        ['emergency-stop', '--reason', 'a b', '--token', 'x'],
        ['emergency-stop', '--reason', 'a b', '--severity', 'high'],
        ['emergency-stop', '--reason', 'a b', '--reason', 'c d'],
        ['emergency-stop', 'extra', '--reason', 'a b'],
    ) {
        fresh_state_dir();
        my $sid = sess_id('ac6usage' . join('', @$bad_argv));
        write_ticket_argv($sid, $bad_argv);
        my ($out, $err, $rc) = run_cmd({}, @$bad_argv);
        is($rc, 1, "AC6 (usage: @$bad_argv): exits 1") or diag("stdout=$out stderr=$err");
        like($err, qr/^butler-continuity: usage: butler-continuity /,
            "AC6 (usage: @$bad_argv): the usage line");
    }
}

# ===========================================================================
# AC10 (good half) -- explicit --area sandbox is recorded in the frontmatter.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac10good');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC10 setup: armed');
    my @before = store_snapshot();
    write_ticket_argv($sid, ['emergency-stop', '--reason', 'needs a sandbox area', '--area', 'sandbox']);
    my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', 'needs a sandbox area', '--area', 'sandbox');
    is($rc, 0, 'AC10: emergency-stop --area sandbox exits 0') or diag("stdout=$out stderr=$err");
    my @new = new_reports(\@before);
    is(scalar(@new), 1, 'AC10: exactly one new report');
    if (@new) {
        my $report = slurp(store_dir() . "/$new[0]");
        like($report, qr/^area: sandbox$/m, 'AC10: report frontmatter has area: sandbox');
    }
}

# ===========================================================================
# AC7 (B6) -- the store directory occupied by a regular file: filing fails,
# the disarm still happens, and the error shapes are exact.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac7');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC7 setup: armed');

    my $dd_root = tempdir(CLEANUP => 1);
    (my $dd = "$dd_root/.ccpraxis-local-data") =~ s{\\}{/}g;
    make_path($dd);
    open(my $fh, '>', "$dd/bug-reports") or die $!;
    print {$fh} "not a directory\n";
    close $fh;

    write_ticket_argv($sid, ['emergency-stop', '--reason', 'store is occupied']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DATA_DIR => $dd }, 'emergency-stop', '--reason', 'store is occupied');
    is($rc, 0, 'AC7: emergency-stop still exits 0 when filing fails') or diag("stdout=$out stderr=$err");
    ok(!-e state_root() . "/armed/$sid", 'AC7: the session is disarmed anyway');
    like($err, qr/WARNING: emergency-stop could not file its bug report \(/, 'AC7: the exact WARNING prefix');
    like($err, qr/could not claim a report id/, 'AC7: the raw filing error names the claim failure');

    my $off = read_json_file(state_root() . "/off/$sid");
    my $offreason = ref $off eq 'HASH' ? $off->{reason} : '';
    like($offreason, qr/; bug report: FAILED \(/, 'AC7: off/<sid> reason ends in the FAILED note');
    like($offreason, qr/could not claim a report id/, 'AC7: and names the raw error');

    my @sidlines = grep { /\Q$sid\E/ } reasons_log_lines();
    if (@sidlines) {
        chomp(my $line = $sidlines[-1]);
        like($line, qr/; bug report: FAILED \(/, 'AC7: reasons.log text ends in the FAILED note');
        like($line, qr/could not claim a report id/, 'AC7: and names the raw error');
    }
    else {
        fail('AC7: no reasons.log line found for this session');
    }
}

# ===========================================================================
# AC9 (B8) -- coordinator path.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac9');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC9 setup: armed WITHOUT BP_LEDGER');

    my @before = store_snapshot();
    write_ticket_argv($sid, ['emergency-stop', '--reason', 'coordinator hit a defect']);
    my ($out, $err, $rc) = run_cmd({ BP_LEDGER => '/x/ledger.md' },
        'emergency-stop', '--reason', 'coordinator hit a defect');
    is($rc, 0, 'AC9: emergency-stop under BP_LEDGER exits 0') or diag("stdout=$out stderr=$err");
    like($out, qr/continuity was NOT turned off/, 'AC9: stdout says continuity was NOT turned off');
    like($out, qr/blocked or parked/, 'AC9: stdout mentions blocked or parked');

    ok(-e state_root() . "/armed/$sid", 'AC9: armed/<sid> still exists');
    ok(!-e state_root() . "/off/$sid", 'AC9: no off/<sid> was created');

    my @new = new_reports(\@before);
    is(scalar(@new), 1, 'AC9: one bug report was filed');
    my ($id) = ($new[0] // '') =~ /^(.*)\.md\z/;

    my @sidlines = grep { /\Q$sid\E/ } reasons_log_lines();
    is(scalar(@sidlines), 1, 'AC9: one new reasons.log line');
    if (@sidlines) {
        chomp(my $line = $sidlines[0]);
        like($line, qr/\tcoordinator\temergency-stop\t/, 'AC9: log line is actor coordinator, tag emergency-stop');
        like($line, qr/; bug report: \Q$id\E$/, 'AC9: log text ends with the filed id') if defined $id;
    }

    # Contrast: off under BP_LEDGER still refuses as before.
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my ($oout, $oerr, $orc) = run_cmd({ BP_LEDGER => '/x/ledger.md' }, 'off', '--reason', 'a b');
    is($orc, 1, 'AC9 contrast: off under BP_LEDGER refuses');
    is($oerr, "butler-continuity: a coordinator cannot turn continuity off; it stops when its ledger is terminal.\n",
        'AC9 contrast: exact coordinator-off refusal');
}

# ===========================================================================
# AC11(a) -- hand-off: a thread attached with nothing doing is handed off.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac11a');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac11-thread', '--goal', 'exercise the hand-off path']);
    my ($oon, $eon, $rcon) = run_cmd({}, 'on', '--new-thread', 'ac11-thread', '--goal', 'exercise the hand-off path');
    is($rcon, 0, 'AC11a setup: on --new-thread exits 0') or diag("stderr: $eon");

    write_ticket_argv($sid, ['emergency-stop', '--reason', 'defect with nothing doing']);
    my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', 'defect with nothing doing');
    is($rc, 0, 'AC11a: emergency-stop exits 0') or diag("stdout=$out stderr=$err");
    like($out, qr/Thread ac11-thread handed off/, 'AC11a: stdout reports the hand-off');

    my $th = eval { Almanac::Thread::read_thread('ac11-thread', root => $PROJECT) };
    is(ref $th eq 'HASH' ? $th->{state} : undef, 'handed-off',
        'AC11a: the thread is no longer live-owned by the (now disarmed) session');
}

# ===========================================================================
# AC11(b) -- the lease-follows-arm idiom (continuity-lease-follows-arm.t:
# 381-431): the wake-lock goes inactive exactly when emergency-stop disarms.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac11b');
    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    my ($oon, $eon, $rcon) = run_cmd({}, 'on', '--role', 'reporter');
    is($rcon, 0, 'AC11b setup: on --role reporter exits 0') or diag("stderr: $eon");
    is(BpContinuityLease::any_active($LEGACY), 1, 'AC11b: after on, any_active(legacy_dir) is 1');

    write_ticket_argv($sid, ['emergency-stop', '--reason', 'lease must follow disarm']);
    my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', 'lease must follow disarm');
    is($rc, 0, 'AC11b: emergency-stop exits 0') or diag("stdout=$out stderr=$err");
    is(BpContinuityLease::any_active($LEGACY), 0, 'AC11b: after emergency-stop, any_active(legacy_dir) is 0');
}

# ===========================================================================
# AC11(c) -- structural: the emergency-stop handler calls _complete_disarm(,
# whose own body calls lease_sync() and plan_after_off(.
# ===========================================================================
{
    my $src = slurp($CMD);
    my ($handler) = $src =~ /if\s*\(\s*\$verb\s+eq\s+'emergency-stop'\s*\)\s*\{(.*?)\n\}/s;
    ok(defined $handler, 'AC11c: the source has an emergency-stop verb handler block')
        or diag('no `if ($verb eq \'emergency-stop\')' . '{...}` block found in butler-continuity.pl yet');
    like($handler // '', qr/_complete_disarm\(/, 'AC11c: the handler calls _complete_disarm(');

    my ($body) = $src =~ /sub\s+_complete_disarm\s*\{(.*?)\n\}/s;
    ok(defined $body, 'AC11c: _complete_disarm exists in the source');
    like($body // '', qr/lease_sync\(\)/, 'AC11c: _complete_disarm calls lease_sync()');
    like($body // '', qr/plan_after_off\(/, 'AC11c: _complete_disarm calls plan_after_off(');
}

# ===========================================================================
# AC12 (B9) -- a ticket carrying agent_id refuses before any filing/disarm.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac12');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC12 setup: armed');
    my @before = store_snapshot();
    write_ticket_argv($sid, ['emergency-stop', '--reason', 'a defect here'], agent_id => 'sub1');
    my ($out, $err, $rc) = run_cmd({}, 'emergency-stop', '--reason', 'a defect here');
    is($rc, 1, 'AC12: exits 1 for a subagent ticket');
    is($err, "butler-continuity: only the main session changes continuity; a subagent may not.\n",
        'AC12: exact subagent refusal message');
    ok(-e state_root() . "/armed/$sid", 'AC12: the session is still armed');
    is_deeply([ new_reports(\@before) ], [], 'AC12: nothing was filed');
}

# ===========================================================================
# AC13 (B12) -- ContinuityOffCheck recognizes emergency-stop (operator
# false), and a near-miss verb name writes no ticket at all.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac13a');
    my $tp = "$TMPROOT/transcripts/$sid-ac13.jsonl";
    make_path("$TMPROOT/transcripts");
    open(my $fh, '>', $tp) or die $!;
    print {$fh} qq({"type":"user","message":{"role":"user","content":"start"}}\n);
    close $fh;

    my $tuid = next_tuid();
    my $p = {
        tool_name  => 'Bash',
        tool_input => { command => q{butler-continuity emergency-stop --reason 'a b c'} },
        session_id => $sid,
        tool_use_id => $tuid,
        transcript_path => $tp,
        cwd => $PROJECT,
    };
    OC('run', $p);
    my $tf = find_ticket_file($sid, $tuid);
    ok(defined $tf, 'AC13: ContinuityOffCheck wrote a ticket for the emergency-stop invocation')
        or diag('no ticket file found (expected until ContinuityOffCheck recognizes the verb)');
    my $tdata = defined $tf ? read_json_file($tf) : undef;
    is(ref $tdata eq 'HASH' ? ($tdata->{operator} ? 1 : 0) : undef, 0,
        'AC13: the ticket carries operator:false');

    my $sid2 = sess_id('ac13b');
    my $tuid2 = next_tuid();
    my $p2 = {
        tool_name  => 'Bash',
        tool_input => { command => q{butler-continuity emergency-stopx --reason 'a b c'} },
        session_id => $sid2,
        tool_use_id => $tuid2,
        transcript_path => $tp,
        cwd => $PROJECT,
    };
    OC('run', $p2);
    my $tf2 = find_ticket_file($sid2, $tuid2);
    ok(!defined $tf2, 'AC13: a near-miss verb name ("emergency-stopx") writes no ticket');
}

# ===========================================================================
# AC17 -- perl -c sanity on the four implementation files this package
# edits (no regression: just confirms this test file never references a
# file that fails to compile under -c; the actual edits are out of this
# test-writer's write set).
# ===========================================================================
for my $f (
    "$S/butler-continuity.pl",
    "$S/BpHook.pm",
    "$S/BpHook/ContinuityOffCheck.pm",
    "$S/BpHook/StopGate.pm",
) {
    SKIP: {
        skip "AC17: $f does not exist", 1 unless -f $f;
        my $rc = system($^X, '-I', $S, '-c', $f);
        is($rc, 0, "AC17: perl -c passes on $f");
    }
}

# ===========================================================================
# AC8 -- the repo's REAL bug-reports store is unchanged end to end.
# ===========================================================================
{
    my @after = real_store_snapshot();
    is_deeply(\@after, \@AC8_BEFORE, 'AC8: the real repo bug-reports store is unchanged by this file');
}

done_testing();
