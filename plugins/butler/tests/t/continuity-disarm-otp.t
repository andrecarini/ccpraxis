#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint judged-continuity-disarm, package 02-disarm-otp-
# skeleton: specs/02-disarm-otp-skeleton-spec.md's AC-1 through AC-30 and
# AC-32 (AC-31 is a regression claim about OTHER files, not this one).
#
# THE DISARM-OTP MECHANICS DO NOT EXIST YET: BpHook::mint_disarm_otp,
# BpHook::revoke_disarm_otp and BpHook::take_disarm_otp are not defined;
# butler-continuity.pl's `off` verb for an agent actor still disarms
# immediately instead of minting; the `off-confirm` verb does not exist at
# all (an unknown-verb usage error); ContinuityOffCheck.pm's recognized-verb
# list does not include off-confirm. Every assertion below that depends on
# these is expected to fail for exactly that reason -- a defined-ness or
# exit-code mismatch, never a syntax error. Unit-level calls to the missing
# BpHook subs are wrapped in eval (see MINT/TAKE/REVOKE below) so a missing
# sub degrades to undef rather than crashing this whole file.
#
# House pattern/fixture conventions follow continuity-command-verbs.t and
# continuity-threads.t (same blueprint family, package 03/04 of
# hook-continuity-remake) -- isolated HOME/state-dir per block via
# fresh_state_dir(), Test::More, no harness config, write_ticket_argv()/
# run_cmd() for CLI-level cases, Almanac::Thread fixtures attached directly
# for the thread-dependent cases (AC-7, AC-9).
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
use Fcntl qw(:flock O_WRONLY O_CREAT O_EXCL);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $CMD  = "$S/butler-continuity.pl";
my $COPM = "$S/BpHook/ContinuityOffCheck.pm";

require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
{
    local $@;
    eval { require $COPM; 1 }
        or diag("BpHook::ContinuityOffCheck did not load (unexpected -- package 03/04 already ships it): $@");
}

BEGIN {
    my $dir = "$FindBin::Bin/../../../almanac/scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}
require Almanac::Thread;
require Almanac::Store;

# ---------------------------------------------------------------------------
# process bookkeeping (house pattern, matches continuity-command-verbs.t)
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
# hygiene / isolation (house pattern)
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
my $DECOY_ROOT = tempdir(CLEANUP => 1);
(my $DECOY = "$DECOY_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($DECOY);
$ENV{HOME}                 = $DECOY;
$ENV{USERPROFILE}          = $DECOY;
$ENV{ALMANAC_HOME}         = $DECOY;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $TMPROOT = tempdir(CLEANUP => 1);

my ($PROJECT, $STATE_BASE, $CFG_DIR);

sub fresh_state_dir {
    my $pt = tempdir(CLEANUP => 1);
    (my $p = "$pt/project") =~ s{\\}{/}g;
    make_path("$p/.ccpraxis-local-data");
    my $st = tempdir(CLEANUP => 1);
    (my $state = "$st/state") =~ s{\\}{/}g;
    my $ct = tempdir(CLEANUP => 1);
    (my $cfg = "$ct/config") =~ s{\\}{/}g;

    $PROJECT    = $p;
    $STATE_BASE = $state;
    $CFG_DIR    = $cfg;
    $ENV{CLAUDE_PROJECT_DIR} = $PROJECT;
    $ENV{BUTLER_STATE_DIR}   = $STATE_BASE;
    $ENV{CLAUDE_CONFIG_DIR}  = $CFG_DIR;
    return ($PROJECT, $STATE_BASE, $CFG_DIR);
}

sub state_root { return "$STATE_BASE/continuity" }
sub otp_dir    { return state_root() . '/disarm-otps' }

sub s8 { my ($sid) = @_; return substr($sid, 0, 8) }

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

my $SID_N = 0;
sub sess_id {
    my ($tag) = @_;
    my $safe = defined $tag ? $tag : '';
    $safe =~ s/[^A-Za-z0-9_-]/-/g;
    my $id = substr('s' . $safe . sha1_hex((defined $tag ? $tag : '') . rand() . time() . (++$SID_N)), 0, 24);
    die "sess_id($tag) produced an invalid session id: $id" unless $id =~ /^[A-Za-z0-9_-]{1,128}$/;
    return $id;
}

sub ensure_transcript {
    my ($sid) = @_;
    my $dir = "$TMPROOT/transcripts";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
    print {$fh} "{}\n";
    close $fh;
    return $path;
}

my $TUID_N = 0;
sub next_tuid { return sprintf('tu%06x', ++$TUID_N) }

# write_ticket_argv(sid, argv, %opts) -- agent-actor by default (operator=>0,
# no agent_id), matching continuity-command-verbs.t's own convention.
sub write_ticket_argv {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path} // ensure_transcript($sid),
        cwd             => $o{cwd} // $PROJECT,
    };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    my $ok = BpHook::write_ticket($p, 'butler-continuity', $argv,
        operator => ($o{operator} ? 1 : 0), background => ($o{background} ? 1 : 0));
    return ($ok, $tuid, $p);
}

sub read_json_file {
    my ($p) = @_;
    my $raw = slurp($p);
    return undef unless length $raw;
    return eval { JSON::PP->new->decode($raw) };
}

sub reasons_log_lines {
    my $p = state_root() . '/reasons.log';
    my @lines = ();
    return @lines unless -f $p;
    open my $fh, '<:raw', $p or return @lines;
    @lines = <$fh>;
    close $fh;
    return @lines;
}

sub spawn_cmd {
    my ($env_over, @args) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my %eo = %$env_over;
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{BUTLER_STATE_DIR}     = $STATE_BASE;
        $ENV{CLAUDE_PROJECT_DIR}   = $PROJECT;
        $ENV{CLAUDE_CONFIG_DIR}    = $CFG_DIR;
        $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
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

# ---------------------------------------------------------------------------
# unit-level seams: never let a missing BpHook sub crash this whole file.
# ---------------------------------------------------------------------------
sub MINT {
    my (@a) = @_;
    my $r;
    my $ok = eval { $r = BpHook::mint_disarm_otp(@a); 1 };
    return $ok ? $r : undef;
}
sub TAKE {
    my (@a) = @_;
    my ($rec, $code);
    my $ok = eval { ($rec, $code) = BpHook::take_disarm_otp(@a); 1 };
    return $ok ? ($rec, $code) : (undef, 'eval-died');
}
sub REVOKE {
    my (@a) = @_;
    my $r;
    my $ok = eval { $r = BpHook::revoke_disarm_otp(@a); 1 };
    return $ok ? $r : undef;
}

# otp_current($sid) -- the live OTP string named by disarm-otps/<sid>.current,
# or undef.
sub otp_current {
    my ($sid) = @_;
    my $p = otp_dir() . "/$sid.current";
    return undef unless -f $p;
    my $t = slurp($p);
    $t =~ s/\s+$//;
    return length($t) ? $t : undef;
}

# extract_otp($stderr) -- the 8-hex OTP printed by 2.2.2's off-confirm
# invocation line, or undef.
sub extract_otp {
    my ($err) = @_;
    my ($otp) = ($err // '') =~ /^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m;
    return $otp;
}

# write_otp_file_direct($sid, %rec) -- hand-write a disarm-otps/<otp> JSON
# file (sysopen O_EXCL, mirroring the spec's own mint layout) WITHOUT going
# through BpHook::mint_disarm_otp (used for AC-20's race fixture and AC-11's
# equivalent-unit form, where the record's gate_result must name a thread
# that is never actually created). Returns the otp string.
sub write_otp_file_direct {
    my ($sid, %rec) = @_;
    my $dir = otp_dir();
    make_path($dir);
    my $otp;
    for (1 .. 5) {
        $otp = substr(sha1_hex(time() . $$ . rand()), 0, 8);
        if (sysopen(my $fh, "$dir/$otp", O_WRONLY | O_CREAT | O_EXCL)) {
            binmode($fh, ':raw');
            my $json = JSON::PP->new->utf8->canonical->encode({
                session_id   => $sid,
                minted_at    => $rec{minted_at} // time(),
                reason       => $rec{reason} // 'a b',
                gate_result  => $rec{gate_result} // { thread => undef, broken => 0 },
            });
            print {$fh} $json . "\n";
            close $fh;
            last;
        }
    }
    return $otp;
}

# set_current_otp($sid, $otp) -- tmp+rename write of disarm-otps/<sid>.current.
sub set_current_otp {
    my ($sid, $otp) = @_;
    my $dir = otp_dir();
    make_path($dir);
    my $tmp = "$dir/.$sid.current.tmp.$$";
    open(my $fh, '>:raw', $tmp) or die "$!";
    print {$fh} "$otp\n";
    close $fh;
    rename($tmp, "$dir/$sid.current") or die "$!";
    return 1;
}

# ===========================================================================
# AC-1 [DC1] operator off --reason: byte-identical to today, no OTP text.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac1');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-1 setup: session armed');
    write_ticket_argv($sid, ['off', '--reason', 'two words'], operator => 1);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'two words');
    is($rc, 0, 'AC-1: operator off --reason exits 0') or diag("stderr: $err");
    is($out, 'continuity off for session ' . s8($sid) . " (actor operator); reason logged.\n",
        'AC-1: stdout is exactly the operator off line');
    ok(!-e state_root() . "/armed/$sid", 'AC-1: armed/<sid> removed');
    ok(!-e otp_dir() . "/$sid.current", 'AC-1: no disarm-otps/<sid>.current exists');
    unlike($out . $err, qr/--otp|otp/i, 'AC-1: no --otp text anywhere in output');
}

# ===========================================================================
# AC-2 [DC1] operator bare off: unchanged, reason recorded as (operator).
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac2');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-2 setup: session armed');
    write_ticket_argv($sid, ['off'], operator => 1);
    my ($out, $err, $rc) = run_cmd({}, 'off');
    is($rc, 0, 'AC-2: operator bare off exits 0') or diag("stderr: $err");
    my $off = read_json_file(state_root() . "/off/$sid");
    is(ref $off eq 'HASH' ? $off->{reason} : undef, '(operator)', 'AC-2: reason recorded as (operator)');
}

# ===========================================================================
# AC-3 [DC1] mint an OTP via agent off, then operator off disarms and
# revokes it.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac3');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-3 setup: session armed');
    write_ticket_argv($sid, ['off', '--reason', 'mint one please']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'mint one please');
    is($arc, 1, 'AC-3: agent off exits 1 (mints)') or diag("stdout: $aout");
    ok(defined otp_current($sid), 'AC-3: a live OTP exists for the session') or diag("stderr: $aerr");

    write_ticket_argv($sid, ['off'], operator => 1);
    my ($out, $err, $rc) = run_cmd({}, 'off');
    is($rc, 0, 'AC-3: operator off exits 0') or diag("stderr: $err");
    ok(!-e otp_dir() . "/$sid.current", 'AC-3: disarm-otps/<sid>.current is gone (disarm revokes)');
    my @remaining = glob(otp_dir() . '/*');
    ok(!(grep { !/\.current$/ && !/\.taken\./ } @remaining),
        'AC-3: no live (non-.current, non-.taken.*) OTP file remains');
}

# ===========================================================================
# AC-4/AC-5/AC-6 [DC2] agent off mints: exact stderr shape, state untouched.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac4');
    ok(BpHook::arm($sid, role => 'manual', by => 'on', goal => 'ship the parser'), 'AC-4 setup: armed with a goal');
    write_ticket_argv($sid, ['off', '--reason', 'work all done']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'work all done');
    is($rc, 1, 'AC-4: agent off exits 1') or diag("stdout: $out");
    my @elines = split /\n/, $err;
    is($elines[0] // '',
        "butler-continuity: off not done yet: disarming takes two steps, and continuity is unchanged for session " . s8($sid) . ".",
        'AC-4: stderr first line is exactly the FIXED 2.2.2 line');
    ok((grep { $_ eq 'goal: ship the parser' } @elines), 'AC-4: stderr contains the goal line');
    ok((grep { $_ eq 'reason: work all done' } @elines), 'AC-4: stderr contains the reason line');
    like($err, qr/^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m,
        'AC-4: stderr matches the off-confirm invocation shape');
    is($out, '', 'AC-4: stdout is empty');

    # AC-5: state is otherwise untouched; the OTP printed matches .current.
    ok(-e state_root() . "/armed/$sid", 'AC-5: armed/<sid> still exists');
    ok(!-e state_root() . "/off/$sid", 'AC-5: off/<sid> does not exist');
    is(scalar(reasons_log_lines()), 0, 'AC-5: reasons.log gained no line');
    my $otp = extract_otp($err);
    ok(defined $otp, 'AC-5: an OTP was printed') or diag("stderr: $err");
    is(otp_current($sid), $otp, 'AC-5: disarm-otps/<sid>.current contains the printed OTP');
}
{
    # AC-6: role reporter (no goal) -> "(no goal recorded)", still mints.
    fresh_state_dir();
    my $sid = sess_id('ac6');
    ok(BpHook::arm($sid, role => 'reporter', by => 'on'), 'AC-6 setup: armed with role reporter, no goal');
    write_ticket_argv($sid, ['off', '--reason', 'all done here']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'all done here');
    is($rc, 1, 'AC-6: agent off exits 1');
    like($err, qr/^goal: \(no goal recorded\)$/m, 'AC-6: stderr prints the no-goal-recorded line');
    ok(defined otp_current($sid), 'AC-6: it still mints');
}

# ===========================================================================
# AC-7 [DC2] unlinked doing task: unchanged R13 refusal, nothing minted.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac7');
    write_ticket_argv($sid, ['on', '--new-thread', 't-ac7', '--goal', 'write the tests for this feature']);
    run_cmd({}, 'on', '--new-thread', 't-ac7', '--goal', 'write the tests for this feature');

    my $task = eval {
        Almanac::Thread::add_task('t-ac7', title => 'write the tests', actor => 'session', root => $PROJECT);
    };
    eval {
        Almanac::Thread::set_task_status('t-ac7', $task->{id}, 'doing', actor => 'session', root => $PROJECT);
    };

    write_ticket_argv($sid, ['off', '--reason', 'stopping here now']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'stopping here now');
    is($rc, 1, 'AC-7: off refuses (R13) while an unlinked task is doing');
    like($err, qr/still has a task doing/, 'AC-7: stderr names the doing task (R13 unchanged)');
    ok(!-e otp_dir() . "/$sid.current", 'AC-7: no disarm-otps/<sid>.current was minted');
}

# ===========================================================================
# AC-8/AC-9 [DC3] agent off then off-confirm disarms; hand-off fires from
# off-confirm, not off.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac8');
    write_ticket_argv($sid, ['on', '--new-thread', 't-ac8', '--goal', 'write the first slice of work']);
    run_cmd({}, 'on', '--new-thread', 't-ac8', '--goal', 'write the first slice of work');

    write_ticket_argv($sid, ['off', '--reason', 'first slice is done']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'first slice is done');
    is($arc, 1, 'AC-8: agent off exits 1 (mints)') or diag("stdout: $aout");

    # Still attached, no hand-off event yet (AC-9 first half).
    my $th_before = eval { Almanac::Thread::read_thread('t-ac8', root => $PROJECT) };
    is(ref $th_before eq 'HASH' ? $th_before->{state} : undef, 'live',
        'AC-9: after off (step one) the thread is still active, not handed off');
    my $log_before = eval { Almanac::Thread::log_entries('t-ac8', root => $PROJECT) };
    ok(!(ref $log_before eq 'ARRAY' && grep { $_->{event} eq 'handed-off' } @$log_before),
        'AC-9: after off (step one) there is no handed-off log event');

    my $otp = extract_otp($aerr);
    ok(defined $otp, 'AC-8: off printed an OTP') or diag("stderr: $aerr");

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-8: off-confirm exits 0') or diag("stderr: $err");
    like($out, qr/continuity off for session \Q@{[s8($sid)]}\E \(actor agent\); reason logged\./,
        'AC-8: stdout contains the off line with actor agent');
    ok(!-e state_root() . "/armed/$sid", 'AC-8: armed/<sid> is gone');
    my $off = read_json_file(state_root() . "/off/$sid");
    is(ref $off eq 'HASH' ? $off->{actor} : undef, 'agent', 'AC-8: off/<sid> actor is agent');
    is(ref $off eq 'HASH' ? $off->{reason} : undef, 'first slice is done', 'AC-8: off/<sid> reason matches');
    my @lines = reasons_log_lines();
    ok(@lines, 'AC-8: a reasons.log line exists') or diag('no reasons.log line written');
    if (@lines) {
        my @f = split /\t/, $lines[-1];
        is($f[3], 'off', 'AC-8: last reasons.log line 4th field is off');
        chomp(my $r = $f[5] // '');
        # judged-continuity-disarm package 03 (spec sec 2.6 E5 / DC2 / sec
        # 4.1's exact guidance for this assertion): the text column is now
        # _judged_log_text(reason, goal, justification, otp), not the plain
        # reason, because off-confirm's successful claim now routes through
        # the judge before _complete_disarm.
        like($r, qr/^first slice is done; goal: .*; justification: goal is met; verdict: disarm-judge\/[0-9a-f]{8}\.verdict\.json$/,
            'AC-8: last reasons.log line 6th field is the judged log text (E5 format)');
    }

    # AC-9 second half: hand-off fires from off-confirm.
    my $th_after = eval { Almanac::Thread::read_thread('t-ac8', root => $PROJECT) };
    is(ref $th_after eq 'HASH' ? $th_after->{state} : undef, 'handed-off',
        'AC-9: after off-confirm the thread is handed-off');
    like($out, qr/Thread t-ac8 handed off/, 'AC-9: stdout names the hand-off');
}

# ===========================================================================
# AC-10 [DC3] lease/plan side effects move from off to off-confirm.
# The plan_after_off/reconcile half of this AC is covered end-to-end (with
# the full powercfg fixture) by plan-restored-on-last-off.t's AC11-AC15,
# which this same package rewrote to the two-step off/off-confirm shape.
# This block covers the lease half directly, mirroring
# continuity-lease-follows-arm.t's own L7 fixture.
# ===========================================================================
{
    fresh_state_dir();
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = "$TMPROOT/ac10-legacy";
    make_path($ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR});
    my $legacy = $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    my $sid = sess_id('ac10');

    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    my ($oout, $oerr, $orc) = run_cmd({ CCPRAXIS_CONTINUITY_ACTIVE_DIR => $legacy }, 'on', '--role', 'reporter');
    is($orc, 0, 'AC-10 setup: on --role reporter exits 0') or diag("stderr: $oerr");
    is(BpContinuityLease::any_active($legacy), 1, 'AC-10 setup: the wake-lock lease is active after on');

    write_ticket_argv($sid, ['off', '--reason', 'wrapping up now']);
    my ($aout, $aerr, $arc) = run_cmd({ CCPRAXIS_CONTINUITY_ACTIVE_DIR => $legacy }, 'off', '--reason', 'wrapping up now');
    is($arc, 1, 'AC-10: agent off exits 1 (mints)') or diag("stdout: $aout");
    is(BpContinuityLease::any_active($legacy), 1, 'AC-10: after off (step one) the lease is still active');

    my $otp = extract_otp($aerr);
    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_CONTINUITY_ACTIVE_DIR => $legacy, CCPRAXIS_DISARM_JUDGE_STUB => "approve" },
        'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-10: off-confirm exits 0') or diag("stderr: $err");
    is(BpContinuityLease::any_active($legacy), 0, 'AC-10: after off-confirm the lease is inactive');
}

# ===========================================================================
# AC-11 [DC3] gate result reused, not recomputed (CLI form and unit form).
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac11');
    write_ticket_argv($sid, ['on', '--new-thread', 't-ac11', '--goal', 'write a slice then detach']);
    run_cmd({}, 'on', '--new-thread', 't-ac11', '--goal', 'write a slice then detach');

    write_ticket_argv($sid, ['off', '--reason', 'detaching before confirm']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'detaching before confirm');
    is($arc, 1, 'AC-11: agent off exits 1 (mints, capturing thread t-ac11)') or diag("stdout: $aout");
    my $otp = extract_otp($aerr);

    # detach the thread from the session before confirming, so a FRESH gate
    # would find nothing attached.
    eval { Almanac::Thread::detach('t-ac11', session => $sid, actor => 'session', root => $PROJECT) };

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-11: off-confirm still exits 0') or diag("stderr: $err");
    ok(($out =~ /handed off/ || $err =~ /was not handed off/),
        'AC-11: off-confirm still attempted the hand-off of the STORED thread t-ac11');
}
{
    # Unit form: mint directly naming a thread that never existed.
    fresh_state_dir();
    my $sid = sess_id('ac11unit');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-11 unit setup: armed');
    my $otp = MINT($sid, reason => 'a b', gate_result => { thread => 'zz-none', broken => 0 });
    ok(defined $otp, 'AC-11 unit: mint_disarm_otp with an explicit gate_result succeeds');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-11 unit: off-confirm exits 0') or diag("stderr: $err");
    like($err, qr/thread zz-none was not handed off/, 'AC-11 unit: stderr names zz-none');
}

# ===========================================================================
# AC-12 [DC3] broken=>1/2 stored directly: off-confirm still disarms, warns.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac12broken1');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-12 (broken=1) setup: armed');
    my $otp = MINT($sid, reason => 'a b', gate_result => { thread => undef, broken => 1 });
    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-12 (broken=1): off-confirm exits 0') or diag("stderr: $err");
    like($err, qr/the almanac thread library did not load; no thread was handed off\./,
        'AC-12 (broken=1): the exact warning is printed');
}
{
    fresh_state_dir();
    my $sid = sess_id('ac12broken2');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-12 (broken=2) setup: armed');
    my $otp = MINT($sid, reason => 'a b', gate_result => { thread => undef, broken => 2 });
    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-12 (broken=2): off-confirm exits 0') or diag("stderr: $err");
    like($err, qr/the thread store could not be read/, 'AC-12 (broken=2): the exact warning is printed');
}

# ===========================================================================
# AC-13 [DC4] wrong OTP while a live one exists: "not live"; the live one
# still succeeds afterwards.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac13');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-13 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'a b');
    my $live_otp = extract_otp($aerr);
    ok(defined $live_otp, 'AC-13 setup: a live OTP was minted') or diag("stderr: $aerr");
    my $wrong = ($live_otp eq 'deadbeef') ? 'deadbeee' : 'deadbeef';

    write_ticket_argv($sid, ['off-confirm', '--otp', $wrong, '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $wrong, '--justification', 'goal is met');
    is($rc, 1, 'AC-13: the wrong OTP refuses');
    like($err, qr/not live/, 'AC-13: stderr contains "not live"');
    ok(-e state_root() . "/armed/$sid", 'AC-13: the session is still armed');

    write_ticket_argv($sid, ['off-confirm', '--otp', $live_otp, '--justification', 'goal is met']);
    my ($out2, $err2, $rc2) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $live_otp, '--justification', 'goal is met');
    is($rc2, 0, 'AC-13: the live OTP still succeeds afterwards') or diag("stderr: $err2");
}

# ===========================================================================
# AC-14 [DC4] expired OTP; boundary unit case at 890s succeeds.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac14');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-14 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'a b');
    my $otp = extract_otp($aerr);
    ok(defined $otp, 'AC-14 setup: a live OTP was minted') or diag("stderr: $aerr");

    my $rec = read_json_file(otp_dir() . "/$otp");
    ok(ref $rec eq 'HASH', 'AC-14 setup: the OTP record is readable JSON');
    if (ref $rec eq 'HASH') {
        $rec->{minted_at} = time() - 960;
        open my $fh, '>:raw', otp_dir() . "/$otp" or die $!;
        print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
        close $fh;
    }

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-14: an expired OTP refuses');
    like($err, qr/expired/, 'AC-14: stderr contains "expired"');
    ok(-e state_root() . "/armed/$sid", 'AC-14: the session is still armed');
    ok(!-e otp_dir() . "/$sid.current", 'AC-14: disarm-otps/<sid>.current is gone');
}
{
    # Boundary (unit): minted_at = now - 890 still claims successfully.
    fresh_state_dir();
    my $sid = sess_id('ac14boundary');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-14 boundary setup: armed');
    my $otp = write_otp_file_direct($sid, minted_at => time() - 890, reason => 'a b');
    set_current_otp($sid, $otp);
    my ($rec, $code) = TAKE($otp, $sid);
    ok(defined $rec, 'AC-14 boundary: take_disarm_otp at 890s succeeds') or diag("code: " . ($code // 'undef'));
}

# ===========================================================================
# AC-15 [DC4] already-claimed OTP, re-arm in between: "no disarm code is
# live".
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac15');
    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    run_cmd({}, 'on', '--role', 'reporter');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'a b');
    my $otp = extract_otp($aerr);
    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($cout, $cerr, $crc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($crc, 0, 'AC-15 setup: first off-confirm succeeds') or diag("stderr: $cerr");

    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    run_cmd({}, 'on', '--role', 'reporter');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-15: re-presenting the same OTP after re-arm refuses');
    like($err, qr/no disarm code is live/, 'AC-15: stderr contains "no disarm code is live"');
    ok(-e state_root() . "/armed/$sid", 'AC-15: the session is still armed');
}

# ===========================================================================
# Red-team L3 (todo 20261022-214010-ebf40000): an UNCLAIMED OTP does not
# survive an explicit `on`. It was minted under the previous arm's reason, so
# it must not end the new arm. A director re-arm (by ne 'on') keeps it: one
# can land between a legitimate `off` and its `off-confirm`.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('l3on');
    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    run_cmd({}, 'on', '--role', 'reporter');
    write_ticket_argv($sid, ['off', '--reason', 'old arm done']);
    my (undef, $aerr) = run_cmd({}, 'off', '--reason', 'old arm done');
    my $otp = extract_otp($aerr);
    ok(defined $otp && -e otp_dir() . "/$otp", 'L3 setup: off minted a live OTP') or diag("stderr: $aerr");

    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    run_cmd({}, 'on', '--role', 'reporter');
    ok(!-e otp_dir() . "/$otp" && !-e otp_dir() . "/$sid.current", 'L3: `on` revoked the OTP and its .current pointer');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my (undef, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm',
                                    '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'L3: the pre-`on` OTP no longer confirms an off');
    like($err, qr/no disarm code is live/, 'L3: refused as "no disarm code is live"');
    ok(-e state_root() . "/armed/$sid", 'L3: the new arm stands');
}
{
    fresh_state_dir();
    my $sid = sess_id('l3dir');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'L3 (director) setup: armed');
    my $otp = MINT($sid, reason => 'a b', gate_result => { thread => 'zz-none', broken => 0 });
    ok(defined $otp, 'L3 (director) setup: OTP minted');
    ok(BpHook::arm($sid, role => 'driver', by => 'drive-solo'), 'L3 (director): a director re-arm succeeds');
    my ($rec, $code) = TAKE($otp // 'deadbeef', $sid);
    ok(defined $rec, 'L3 (director): the OTP survives a director re-arm') or diag("code: " . ($code // 'undef'));
}

# ===========================================================================
# AC-16 [DC4] already-rejected (expired) OTP re-presented: same refusal.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac16');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-16 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my ($aout, $aerr, $arc) = run_cmd({}, 'off', '--reason', 'a b');
    my $otp = extract_otp($aerr);
    my $rec = read_json_file(otp_dir() . "/$otp");
    if (ref $rec eq 'HASH') {
        $rec->{minted_at} = time() - 960;
        open my $fh, '>:raw', otp_dir() . "/$otp" or die $!;
        print {$fh} JSON::PP->new->utf8->canonical->encode($rec) . "\n";
        close $fh;
    }
    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    run_cmd({}, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');   # consumes it (expired)

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-16: re-presenting the same (already-rejected) OTP refuses');
    like($err, qr/no disarm code is live/, 'AC-16: stderr contains "no disarm code is live"');
    ok(-e state_root() . "/armed/$sid", 'AC-16: still armed');
}

# ===========================================================================
# AC-17 [DC4, DC10] another session's OTP via the CLI: "another session".
# ===========================================================================
{
    fresh_state_dir();
    my $sidA = sess_id('ac17a');
    my $sidB = sess_id('ac17b');
    ok(BpHook::arm($sidA, role => 'manual', by => 'on'), 'AC-17 setup: A armed');
    ok(BpHook::arm($sidB, role => 'manual', by => 'on'), 'AC-17 setup: B armed');

    write_ticket_argv($sidB, ['off', '--reason', 'b is done']);
    my ($bout, $berr, $brc) = run_cmd({}, 'off', '--reason', 'b is done');
    my $otpB = extract_otp($berr);
    ok(defined $otpB, 'AC-17 setup: B minted an OTP') or diag("stderr: $berr");

    write_ticket_argv($sidA, ['off-confirm', '--otp', $otpB // 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $otpB // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-17: A presenting B\'s OTP refuses');
    like($err, qr/another session/, 'AC-17: stderr contains "another session"');
    ok(-e state_root() . "/armed/$sidA", 'AC-17: A is still armed');
    ok(-e state_root() . "/armed/$sidB", 'AC-17: B is still armed');

    write_ticket_argv($sidB, ['off-confirm', '--otp', $otpB // 'deadbeef', '--justification', 'goal is met']);
    my ($out2, $err2, $rc2) = run_cmd({}, 'off-confirm', '--otp', $otpB // 'deadbeef', '--justification', 'goal is met');
    is($rc2, 1, 'AC-17: a subsequent B off-confirm with the same (now-consumed) OTP refuses');
    like($err2, qr/not live/, 'AC-17: stderr contains "not live"');
}

# ===========================================================================
# AC-18 [DC5] agent off twice: first OTP absent, .current = second; first
# refuses, second succeeds.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac18');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-18 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'first mint']);
    my (undef, $err1) = run_cmd({}, 'off', '--reason', 'first mint');
    my $otp1 = extract_otp($err1);
    ok(defined $otp1, 'AC-18: first off minted an OTP') or diag("stderr: $err1");

    write_ticket_argv($sid, ['off', '--reason', 'second mint']);
    my (undef, $err2) = run_cmd({}, 'off', '--reason', 'second mint');
    my $otp2 = extract_otp($err2);
    ok(defined $otp2, 'AC-18: second off minted an OTP') or diag("stderr: $err2");
    isnt($otp1, $otp2, 'AC-18: the two OTPs differ');

    ok(!-e otp_dir() . "/$otp1", 'AC-18: disarm-otps/O1 is absent');
    is(otp_current($sid), $otp2, 'AC-18: .current is O2');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp1, '--justification', 'goal is met']);
    my ($out1, $errc1, $rc1) = run_cmd({}, 'off-confirm', '--otp', $otp1, '--justification', 'goal is met');
    is($rc1, 1, 'AC-18: off-confirm --otp O1 exits 1');
    like($errc1, qr/not live/, 'AC-18: stderr for O1 contains "not live"');
    ok(-e state_root() . "/armed/$sid", 'AC-18: still armed after O1 refusal');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp2, '--justification', 'goal is met']);
    my ($out2, $errc2, $rc2) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp2, '--justification', 'goal is met');
    is($rc2, 0, 'AC-18: off-confirm --otp O2 exits 0 and disarms') or diag("stderr: $errc2");
}

# ===========================================================================
# AC-19 [DC5] unit: mint twice -> two OTPs, only second has a file;
# take(first) -> unknown; take(second) -> success.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac19');
    my $otp1 = MINT($sid, reason => 'a b', gate_result => { thread => undef, broken => 0 });
    my $otp2 = MINT($sid, reason => 'c d', gate_result => { thread => undef, broken => 0 });
    ok(defined $otp1 && defined $otp2, 'AC-19: both mints succeeded') or diag('mint_disarm_otp missing/failed');
    if (defined $otp1 && defined $otp2) {
        isnt($otp1, $otp2, 'AC-19: the two OTPs differ');
        ok(!-e otp_dir() . "/$otp1", 'AC-19: only the second OTP has a file (first is gone)');
        ok(-e otp_dir() . "/$otp2", 'AC-19: the second OTP file exists');
        my ($rec1, $code1) = TAKE($otp1, $sid);
        is($code1, 'unknown', 'AC-19: take_disarm_otp(first, sid) -> unknown');
        is($rec1, undef, 'AC-19: ...and undef record');
        my ($rec2, $code2) = TAKE($otp2, $sid);
        ok(defined $rec2, 'AC-19: take_disarm_otp(second, sid) succeeds') or diag("code: " . ($code2 // 'undef'));
    }
}

# ===========================================================================
# AC-20 [DC5] unit race guard: an orphan OTP file (not named by .current) ->
# superseded, and the file is gone afterwards.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac20');
    my $live = write_otp_file_direct($sid, reason => 'live one');
    set_current_otp($sid, $live);
    my $orphan = write_otp_file_direct($sid, reason => 'orphan one');
    # $orphan is NOT named by .current (which still names $live).

    my ($rec, $code) = TAKE($orphan, $sid);
    is($code, 'superseded', 'AC-20: take_disarm_otp(orphan, sid) -> superseded');
    is($rec, undef, 'AC-20: ...and undef record');
    ok(!-e otp_dir() . "/$orphan" && !-e otp_dir() . "/$orphan.taken.$$",
        'AC-20: the orphan file is gone afterwards');
}

# ===========================================================================
# AC-21 [DC6] armed, never ran off: off-confirm with a made-up OTP ->
# "no disarm code is live".
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac21');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-21 setup: armed');
    write_ticket_argv($sid, ['off-confirm', '--otp', 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-21: off-confirm with no mint ever done exits 1');
    like($err, qr/no disarm code is live/, 'AC-21: stderr contains "no disarm code is live"');
    ok(-e state_root() . "/armed/$sid", 'AC-21: still armed');
}

# ===========================================================================
# AC-22 [DC7] OTP record JSON shape: sanitized reason, session_id, integer
# minted_at within 5s, gate_result with exactly thread/broken keys.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac22');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-22 setup: armed');
    my $before = time();
    write_ticket_argv($sid, ['off', '--reason', "  work\tall  done  "]);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', "  work\tall  done  ");
    is($rc, 1, 'AC-22: agent off exits 1');
    my $otp = extract_otp($err);
    ok(defined $otp, 'AC-22: an OTP was printed') or diag("stderr: $err");
    my $rec = read_json_file(otp_dir() . "/$otp");
    ok(ref $rec eq 'HASH', 'AC-22: the OTP record is readable JSON') or diag("not JSON: " . slurp(otp_dir() . "/$otp"));
    if (ref $rec eq 'HASH') {
        is($rec->{reason}, 'work all done', 'AC-22: reason is sanitized');
        is($rec->{session_id}, $sid, 'AC-22: session_id matches');
        ok(($rec->{minted_at} =~ /^\d+$/), 'AC-22: minted_at looks like an integer');
        cmp_ok(abs(($rec->{minted_at} // 0) - $before), '<=', 5, 'AC-22: minted_at is within 5s of now');
        is_deeply([ sort keys %{ $rec->{gate_result} // {} } ], [ 'broken', 'thread' ],
            'AC-22: gate_result has exactly the keys thread and broken');
    }
}

# ===========================================================================
# AC-23 [DC7] unit: take_disarm_otp's returned reason/gate_result round-trip
# exactly, including a non-ASCII reason.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac23');
    my $reason = "Andr\x{e9} fixed it";
    my $gr = { thread => 'zz-thread', broken => 0 };
    my $otp = MINT($sid, reason => $reason, gate_result => $gr);
    ok(defined $otp, 'AC-23: mint succeeded') or diag('mint_disarm_otp missing/failed');
    if (defined $otp) {
        my ($rec, $code) = TAKE($otp, $sid);
        ok(defined $rec, 'AC-23: take succeeded') or diag("code: " . ($code // 'undef'));
        if (defined $rec) {
            is($rec->{reason}, $reason, 'AC-23: reason round-trips exactly (including non-ASCII)');
            is_deeply($rec->{gate_result}, $gr, 'AC-23: gate_result round-trips exactly');
        }
    }
}

# ===========================================================================
# AC-24 [DC8] ContinuityOffCheck::run writes one ticket for an off-confirm
# Bash payload, keyed on the exact argv, operator false; off-confirmx writes
# none. (Primary assertions live in continuity-off-check.t; mirrored here
# per the spec's own "primary home" note covering AC-1..AC-30.)
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac24');
    my $tp = ensure_transcript($sid);
    my $tuid = next_tuid();
    my $p = { tool_name => 'Bash',
              tool_input => { command => q{butler-continuity off-confirm --otp deadbeef --justification 'goal is met'} },
              session_id => $sid, tool_use_id => $tuid, transcript_path => $tp, cwd => $PROJECT };
    my $ret = eval { BpHook::ContinuityOffCheck::run($p) };
    is($ret, 0, 'AC-24: ContinuityOffCheck::run returns 0');
    my $key = sha1_hex(join("\0", 'butler-continuity', 'off-confirm', '--otp', 'deadbeef',
                            '--justification', 'goal is met'));
    my @found = glob(state_root() . "/tickets/$key/$sid.$tuid.json");
    is(scalar(@found), 1, 'AC-24: exactly one ticket keyed on sha1_hex(argv)')
        or diag('no ticket found -- off-confirm not yet in the recognized-verb list');
    if (@found) {
        my $tdata = read_json_file($found[0]);
        is(ref $tdata eq 'HASH' ? ($tdata->{operator} ? 1 : 0) : undef, 0, 'AC-24: operator is false');
    }

    my $tuid2 = next_tuid();
    my $p2 = { tool_name => 'Bash',
               tool_input => { command => 'butler-continuity off-confirmx --otp deadbeef --justification "goal is met"' },
               session_id => $sid, tool_use_id => $tuid2, transcript_path => $tp, cwd => $PROJECT };
    eval { BpHook::ContinuityOffCheck::run($p2) };
    my @found2 = glob(state_root() . "/tickets/*/$sid.$tuid2.json");
    is(scalar(@found2), 0, 'AC-24: off-confirmx (not off-confirm) writes no ticket');
}

# ===========================================================================
# AC-25 [DC8] end to end via the hook module: ContinuityOffCheck writes the
# ticket, then the script binds and disarms.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac25');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-25 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'done via hook']);
    my (undef, $aerr) = run_cmd({}, 'off', '--reason', 'done via hook');
    my $otp = extract_otp($aerr);
    ok(defined $otp, 'AC-25 setup: an OTP was minted') or diag("stderr: $aerr");

    my $tp = ensure_transcript($sid);
    my $tuid = next_tuid();
    my $p = { tool_name => 'Bash',
              tool_input => { command => "butler-continuity off-confirm --otp $otp --justification 'goal is met'" },
              session_id => $sid, tool_use_id => $tuid, transcript_path => $tp, cwd => $PROJECT };
    eval { BpHook::ContinuityOffCheck::run($p) };

    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 0, 'AC-25: off-confirm bound via ContinuityOffCheck exits 0') or diag("stderr: $err");
    ok(!-e state_root() . "/armed/$sid", 'AC-25: the session is disarmed');
}

# ===========================================================================
# AC-26 [DC8] off-confirm, valid args, no ticket: binding refusal; the OTP
# is still claimable afterwards. Comparison: bare-ticketless off also
# refuses "no session binding".
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac26');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-26 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my (undef, $aerr) = run_cmd({}, 'off', '--reason', 'a b');
    my $otp = extract_otp($aerr);
    ok(defined $otp, 'AC-26 setup: an OTP was minted') or diag("stderr: $aerr");

    # no ticket written for off-confirm this time.
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-26: off-confirm with no ticket exits 1');
    like($err, qr/^butler-continuity: no session binding/, 'AC-26: stderr starts with the no-binding line');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out2, $err2, $rc2) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc2, 0, 'AC-26: the OTP is still claimable afterwards') or diag("stderr: $err2");

    # comparison: bare-ticketless off.
    fresh_state_dir();
    my $sid2 = sess_id('ac26cmp');
    ok(BpHook::arm($sid2, role => 'manual', by => 'on'), 'AC-26 cmp setup: armed');
    my ($outc, $errc, $rcc) = run_cmd({}, 'off', '--reason', 'two words');
    is($rcc, 1, 'AC-26 cmp: bare-ticketless off exits 1');
    like($errc, qr/no session binding/, 'AC-26 cmp: stderr contains "no session binding"');
}

# ===========================================================================
# AC-27 [DC9] subagent ticket (agent_id set): refuses; OTP claimable
# afterwards by a main-session ticket.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac27');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-27 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my (undef, $aerr) = run_cmd({}, 'off', '--reason', 'a b');
    my $otp = extract_otp($aerr);

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met'], agent_id => 'sub1');
    my ($out, $err, $rc) = run_cmd({}, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-27: a subagent ticket for off-confirm refuses');
    is($err, "butler-continuity: only the main session changes continuity; a subagent may not.\n",
        'AC-27: exact subagent refusal line');
    ok(-e state_root() . "/armed/$sid", 'AC-27: still armed');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out2, $err2, $rc2) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc2, 0, 'AC-27: the OTP is claimable afterwards by a main-session ticket') or diag("stderr: $err2");
}

# ===========================================================================
# AC-28 [DC10] unit: mint for sess-B, take(otp, sess-A) -> foreign-session;
# take(otp, sess-B) afterwards -> unknown.
# ===========================================================================
{
    fresh_state_dir();
    my $otp = MINT('ac28-sess-b', reason => 'a b', gate_result => { thread => undef, broken => 0 });
    ok(defined $otp, 'AC-28: mint succeeded') or diag('mint_disarm_otp missing/failed');
    if (defined $otp) {
        my ($recA, $codeA) = TAKE($otp, 'ac28-sess-a');
        is($codeA, 'foreign-session', 'AC-28: take(otp, sess-A) -> foreign-session');
        is($recA, undef, 'AC-28: ...and undef record');
        my ($recB, $codeB) = TAKE($otp, 'ac28-sess-b');
        is($codeB, 'unknown', 'AC-28: afterwards take(otp, sess-B) -> unknown (consumed)');
    }
}

# ===========================================================================
# AC-29 [DC4] validation, nothing consumed: bad --justification/--otp
# shapes, and --token (usage error); the live OTP remains claimable.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac29');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-29 setup: armed');
    write_ticket_argv($sid, ['off', '--reason', 'a b']);
    my (undef, $aerr) = run_cmd({}, 'off', '--reason', 'a b');
    my $otp = extract_otp($aerr);
    ok(defined $otp, 'AC-29 setup: an OTP was minted') or diag("stderr: $aerr");

    my $long201 = 'x' x 201;
    my @cases = (
        { label => 'one-word justification',   args => ['--otp', $otp, '--justification', 'one'] },
        { label => '201-byte justification',    args => ['--otp', $otp, '--justification', $long201] },
        { label => 'missing justification',     args => ['--otp', $otp] },
        { label => 'bad --otp shape',           args => ['--otp', 'XYZ12345', '--justification', 'goal is met'] },
        { label => 'missing --otp',             args => ['--justification', 'goal is met'] },
        { label => '--token usage error',       args => ['--otp', $otp, '--justification', 'goal is met', '--token', 'deadbeef'] },
    );
    for my $c (@cases) {
        write_ticket_argv($sid, ['off-confirm', @{ $c->{args} }]);
        my ($out, $err, $rc) = run_cmd({}, 'off-confirm', @{ $c->{args} });
        is($rc, 1, "AC-29: $c->{label} exits 1") or diag("stdout: $out stderr: $err");
    }
    ok(-e state_root() . "/armed/$sid", 'AC-29: still armed after all the above');

    write_ticket_argv($sid, ['off-confirm', '--otp', $otp, '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ CCPRAXIS_DISARM_JUDGE_STUB => "approve" }, 'off-confirm', '--otp', $otp, '--justification', 'goal is met');
    is($rc, 0, 'AC-29: the live OTP remains claimable after all the invalid attempts') or diag("stderr: $err");
}

# ===========================================================================
# AC-30 [DC2, DC3] coordinator: BP_LEDGER set, off-confirm refuses.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac30');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC-30 setup: armed');
    write_ticket_argv($sid, ['off-confirm', '--otp', 'deadbeef', '--justification', 'goal is met']);
    my ($out, $err, $rc) = run_cmd({ BP_LEDGER => '/x/ledger.md' },
        'off-confirm', '--otp', 'deadbeef', '--justification', 'goal is met');
    is($rc, 1, 'AC-30: off-confirm under BP_LEDGER exits 1');
    like($err, qr/a coordinator cannot turn continuity off/, 'AC-30: exact coordinator phrase');
}

# ===========================================================================
# AC-32 [DC1-10, hygiene] perl -c on the write set; revoke_disarm_otp called
# from gc_sessions() (the disarm() half is AC-3).
# ===========================================================================
{
    for my $f ($CMD, "$S/BpHook.pm", $COPM) {
        my $rc = system($^X, '-c', $f) >> 8;
        is($rc, 0, "AC-32: perl -c passes for $f");
    }
}
{
    fresh_state_dir();
    my $sid = sess_id('ac32gc');
    my $gone_tp = "$TMPROOT/gone-$sid.jsonl";   # never created -> gc_sessions() reaps it
    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $gone_tp),
        'AC-32 setup: armed with a transcript path that does not exist');
    my $otp = MINT($sid, reason => 'a b', gate_result => { thread => undef, broken => 0 });
    ok(defined $otp, 'AC-32 setup: a live OTP was minted') or diag('mint_disarm_otp missing/failed');
    BpHook::gc_sessions();
    my @remaining = glob(otp_dir() . "/*$sid*");
    @remaining = (@remaining, otp_dir() . "/$sid.current") if -e otp_dir() . "/$sid.current";
    ok(!-e otp_dir() . "/$sid.current", 'AC-32: gc_sessions() leaves no disarm-otps/<sid>.current');
    ok(!(defined $otp && -e otp_dir() . "/$otp"), 'AC-32: gc_sessions() leaves no live OTP file for the session');
}

done_testing();
