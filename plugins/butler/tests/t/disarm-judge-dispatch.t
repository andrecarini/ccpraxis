#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint judged-continuity-disarm, package 03-disarm-judge
# (specs/03-disarm-judge-spec.md, acceptance AC1-AC8, AC13-AC19, AC21-AC22,
# AC25 as it touches this file's own call sites -- AC9-AC12 live in the
# sibling disarm-judge-guard.t; AC23/AC24/AC26 live in their own named
# files/checks per the spec's AC table).
#
# NONE OF THE FOLLOWING EXIST YET: plugins/butler/scripts/bp-judge-disarm.sh,
# plugins/butler/agents/bp-disarm-judge.md, the butler-continuity.pl edits
# (_judge_disarm, _judged_log_text, the off-confirm E3 replacement). Every
# assertion below that depends on these is expected to fail for exactly that
# reason (a missing file, an empty/undef read, or an unexpected exit code),
# never a Perl syntax error in THIS file.
#
# DC7 (no real `claude -p` from this file, ever): every scenario below sets
# CCPRAXIS_DISARM_JUDGE_STUB explicitly to approve/reject/hang/bogus. AC16
# additionally proves this mechanically: a PATH whose first entry is a
# `claude` shim that logs its own invocation and exits 1 sits in front of
# the real PATH for this whole file, and that log is checked empty at the
# very end.
#
# House pattern/fixture conventions follow continuity-disarm-otp.t (same
# blueprint family, package 02) -- isolated HOME/state-dir per block via
# fresh_state_dir(), Test::More, no harness config, write_ticket_argv()/
# run_cmd() for CLI-level cases, a parallel dispatch_wrapper() helper for
# direct bp-judge-disarm.sh invocations (AC2-4, AC13 n/a here, AC19/AC22).
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
my $CMD   = "$S/butler-continuity.pl";
my $WRAP  = "$S/bp-judge-disarm.sh";
(my $AGENTS_DIR = "$Bin/../../agents") =~ s{\\}{/}g;
my $AGENT_MD = "$AGENTS_DIR/bp-disarm-judge.md";

require "$S/BpHook.pm";

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

# ---------------------------------------------------------------------------
# AC16: a hostile `claude` shim, first on PATH, for the WHOLE file. Logs its
# own invocation line and exits 1. If anything in stub mode ever resolved or
# executed `claude`, this log would be non-empty at the end.
# ---------------------------------------------------------------------------
my $SHIM_DIR = tempdir(CLEANUP => 1);
(my $SHIM_DIR_N = $SHIM_DIR) =~ s{\\}{/}g;
my $CLAUDE_LOG = "$TMPROOT/claude-shim-calls.log";
{
    my $shim = "$SHIM_DIR_N/claude";
    open(my $fh, '>', $shim) or die "cannot write claude shim: $!";
    print {$fh} "#!/bin/sh\n";
    print {$fh} "printf 'CALLED: %s\\n' \"\$*\" >> " . quotemeta($CLAUDE_LOG) . "\n";
    print {$fh} "exit 1\n";
    close $fh;
    chmod(0755, $shim);
}
my $REAL_PATH = $ENV{PATH} // '';
$ENV{PATH} = "$SHIM_DIR_N:$REAL_PATH";

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

sub state_root       { return "$STATE_BASE/continuity" }
sub otp_dir           { return state_root() . '/disarm-otps' }
sub disarm_judge_dir  { return state_root() . '/disarm-judge' }

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

# spawn_cmd/wait_cmd/run_cmd -- house pattern, matches continuity-disarm-otp.t.
# The per-call env override ALWAYS carries this file's PATH (with the AC16
# shim prepended), never the ambient test-runner's PATH.
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
        $ENV{PATH}                 = "$SHIM_DIR_N:$REAL_PATH";
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
    my @r = wait_cmd($pid, $o, $e, timeout => 30);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return @r;
}

sub extract_otp {
    my ($err) = @_;
    my ($otp) = ($err // '') =~ /^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m;
    return $otp;
}

# off_mint($sid, $reason) -> otp (or undef) -- agent `off --reason` mints.
sub off_mint {
    my ($sid, $reason) = @_;
    write_ticket_argv($sid, ['off', '--reason', $reason]);
    my (undef, $err, $rc) = run_cmd({}, 'off', '--reason', $reason);
    return undef unless $rc == 1;
    return extract_otp($err);
}

# off_confirm($sid, $otp, $just, %env_extra) -> ($out, $err, $rc)
sub off_confirm {
    my ($sid, $otp, $just, %extra) = @_;
    write_ticket_argv($sid, ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', $just]);
    return run_cmd({ %extra }, 'off-confirm', '--otp', $otp // 'deadbeef', '--justification', $just);
}

# dispatch_wrapper(%o) -- a direct `bash bp-judge-disarm.sh` invocation,
# bypassing butler-continuity.pl entirely (AC2-4, AC13 n/a, AC19/AC22-level
# assertions that want the wrapper's own argv/verdict without the off-
# confirm wait loop on top).
sub dispatch_wrapper {
    my (%o) = @_;
    my $otp = $o{otp} // substr(sha1_hex(time() . $$ . rand()), 0, 8);
    my $dir = disarm_judge_dir();
    make_path($dir);
    my $vpath = "$dir/$otp.verdict.json";
    unlink $vpath;
    my $proot  = $o{project_root} // $PROJECT;
    my $goal   = $o{goal} // 'ship the parser';
    my $reason = $o{reason} // 'all done here';
    my $just   = $o{justification} // 'goal is met';

    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        if (defined $o{stub}) { $ENV{CCPRAXIS_DISARM_JUDGE_STUB} = $o{stub} }
        else                  { delete $ENV{CCPRAXIS_DISARM_JUDGE_STUB} }
        if (defined $o{timeout}) { $ENV{CCPRAXIS_DISARM_JUDGE_TIMEOUT_SECONDS} = $o{timeout} }
        else                      { delete $ENV{CCPRAXIS_DISARM_JUDGE_TIMEOUT_SECONDS} }
        delete $ENV{IS_SANDBOX} unless $o{keep_is_sandbox};
        $ENV{PATH} = "$SHIM_DIR_N:$REAL_PATH";
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('bash', $WRAP, $otp, $vpath, $proot, $goal, $reason, $just);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $deadline = time() + ($o{wait} // 20);
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return { otp => $otp, vpath => $vpath, dir => $dir, out => $out, err => $err, rc => $rc,
             goal => $goal, reason => $reason, justification => $just, project_root => $proot };
}

# read_argv($path) -> list of NUL-separated elements, trailing empty dropped.
sub read_argv {
    my ($path) = @_;
    my $raw = slurp($path);
    return () unless length $raw;
    my @elems = split /\0/, $raw;
    pop @elems if @elems && $elems[-1] eq '';
    return @elems;
}

# ===========================================================================
# AC1: successful claim dispatches the judge; STUB=approve -> rc 0; argv
# exists; armed/<sid> gone afterwards.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac1');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC1 setup: armed');
    my $otp = off_mint($sid, 'the work here is done');
    ok(defined $otp, 'AC1 setup: an OTP was minted') or diag('off did not mint');

    my ($out, $err, $rc) = off_confirm($sid, $otp, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'approve');
    is($rc, 0, 'AC1: off-confirm with STUB=approve exits 0') or diag("stderr: $err");
    ok(-e disarm_judge_dir() . "/$otp.argv", 'AC1: <otp>.argv exists') if defined $otp;
    ok(!-e state_root() . "/armed/$sid", 'AC1: armed/<sid> is gone afterwards');
}

# ===========================================================================
# AC2: <otp>.argv split on NUL equals the 2.3.3 vector exactly for elements
# 0-4, and contains no --dangerously-skip-permissions anywhere.
# ===========================================================================
{
    fresh_state_dir();
    my $r = dispatch_wrapper(stub => 'approve');
    my @argv = read_argv($r->{dir} . "/$r->{otp}.argv");
    ok(@argv >= 5, 'AC2: argv has at least 5 elements') or diag("rc=$r->{rc} err=$r->{err}");
    is($argv[0] // '', 'env',                  'AC2: argv[0] is env');
    is($argv[1] // '', 'CCPRAXIS_DISARM_JUDGE=1', 'AC2: argv[1] is CCPRAXIS_DISARM_JUDGE=1');
    is($argv[2] // '', 'claude',                'AC2: argv[2] is claude');
    is($argv[3] // '', '-p',                    'AC2: argv[3] is -p');
    ok(length($argv[4] // ''), 'AC2: argv[4] (the prompt) is non-empty');
    ok(!(grep { $_ eq '--dangerously-skip-permissions' } @argv),
        'AC2: argv contains no --dangerously-skip-permissions');
}

# ===========================================================================
# AC3: --disallowedTools superset/disjoint check; --strict-mcp-config;
# --permission-mode default; no --mcp-config/--allowedTools.
# ===========================================================================
{
    fresh_state_dir();
    my $r = dispatch_wrapper(stub => 'approve');
    my @argv = read_argv($r->{dir} . "/$r->{otp}.argv");
    my ($dt_i) = grep { $argv[$_] eq '--disallowedTools' } 0 .. $#argv;
    ok(defined $dt_i, 'AC3: --disallowedTools is present in argv') or diag(join('|', @argv));
    my %dt = defined $dt_i ? map { $_ => 1 } split(/,/, $argv[$dt_i + 1] // '') : ();
    for my $must (qw(Write Edit MultiEdit NotebookEdit Task Agent WebFetch WebSearch)) {
        ok($dt{$must}, "AC3: --disallowedTools denies $must");
    }
    for my $must_not (qw(Read Grep Glob Bash)) {
        ok(!$dt{$must_not}, "AC3: --disallowedTools does not deny $must_not");
    }
    ok((grep { $_ eq '--strict-mcp-config' } @argv), 'AC3: argv contains --strict-mcp-config');
    my ($pm_i) = grep { $argv[$_] eq '--permission-mode' } 0 .. $#argv;
    is(defined $pm_i ? $argv[$pm_i + 1] : undef, 'default', 'AC3: --permission-mode default');
    ok(!(grep { $_ eq '--mcp-config' }   @argv), 'AC3: no --mcp-config');
    ok(!(grep { $_ eq '--allowedTools' } @argv), 'AC3: no --allowedTools');
}

# ===========================================================================
# AC4: no bp_require_sandbox/bp-lib.sh source anywhere in bp-judge-disarm.sh;
# with STUB=approve, IS_SANDBOX unset, no sandbox env, exits 0 and writes a
# verdict.
# ===========================================================================
{
    SKIP: {
        skip('bp-judge-disarm.sh does not exist yet', 2) unless -f $WRAP;
        my $src = slurp($WRAP);
        unlike($src, qr/\bbp_require_sandbox\b/, 'AC4: no bp_require_sandbox call in the wrapper');
        unlike($src, qr/\bbp-lib\.sh\b/,          'AC4: no bp-lib.sh source in the wrapper');
    }
    fresh_state_dir();
    delete local $ENV{IS_SANDBOX};
    delete local $ENV{CCPRAXIS_SANDBOX};
    my $r = dispatch_wrapper(stub => 'approve');
    is($r->{rc}, 0, 'AC4: wrapper exits 0 outside any sandbox context') or diag("err: $r->{err}");
    ok(-f $r->{vpath}, 'AC4: a verdict file was written outside any sandbox context');
}

# ===========================================================================
# AC5: approve -- reasons.log text equals _judged_log_text(reason, goal,
# justification, otp); off/<sid>.reason stays the plain reason.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac5');
    ok(BpHook::arm($sid, role => 'manual', by => 'on', goal => 'ship the parser'), 'AC5 setup: armed with a goal');
    my $otp = off_mint($sid, 'first slice is done');
    ok(defined $otp, 'AC5 setup: minted');
    my ($out, $err, $rc) = off_confirm($sid, $otp, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'approve');
    is($rc, 0, 'AC5: off-confirm exits 0') or diag("stderr: $err");

    my @lines = reasons_log_lines();
    ok(@lines, 'AC5: a reasons.log line exists');
    my $text = '';
    if (@lines) {
        my @f = split /\t/, $lines[-1];
        chomp($text = $f[5] // '');
    }
    like($text, qr/^first slice is done; goal: ship the parser; justification: goal is met; verdict: disarm-judge\/[0-9a-f]{8}\.verdict\.json$/,
        'AC5: the logged text is the E5 format with goal/justification/pointer');
    my ($vrel) = $text =~ m{verdict: (disarm-judge/[0-9a-f]{8}\.verdict\.json)};
    if (defined $vrel) {
        my $vfull = state_root() . "/$vrel";
        ok(-f $vfull, 'AC5: the pointed-to verdict file exists under the state root');
        my $v = read_json_file($vfull);
        is(ref $v eq 'HASH' ? $v->{verdict} : undef, 'approve', 'AC5: that verdict file says approve');
    }
    my $off = read_json_file(state_root() . "/off/$sid");
    is(ref $off eq 'HASH' ? $off->{reason} : undef, 'first slice is done', 'AC5: off/<sid>.reason is the plain reason');
}

# ===========================================================================
# AC6: 200-byte reason/goal/justification -- logged text <= 300 chars and
# still names all four components (each cut with '...' when > 70 chars).
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac6');
    my $long_goal = ('g' x 99) . ' ' . ('g' x 100);
    ok(BpHook::arm($sid, role => 'manual', by => 'on', goal => $long_goal), 'AC6 setup: armed with a 200-byte goal');
    my $long_reason = ('r' x 99) . ' ' . ('r' x 100);
    my $long_just   = ('j' x 99) . ' ' . ('j' x 100);
    my $otp = off_mint($sid, $long_reason);
    ok(defined $otp, 'AC6 setup: minted');
    my ($out, $err, $rc) = off_confirm($sid, $otp, $long_just, CCPRAXIS_DISARM_JUDGE_STUB => 'approve');
    is($rc, 0, 'AC6: off-confirm exits 0') or diag("stderr: $err");

    my @lines = reasons_log_lines();
    my $text = '';
    if (@lines) {
        my @f = split /\t/, $lines[-1];
        chomp($text = $f[5] // '');
    }
    cmp_ok(length($text), '<=', 300, 'AC6: the logged text is at most 300 characters');
    like($text, qr/^r{67}\.\.\.; goal: g{67}\.\.\.; justification: j{67}\.\.\.; verdict: disarm-judge\/[0-9a-f]{8}\.verdict\.json$/,
        'AC6: all four components are present, each cut to 67 chars + "..."');
}

# ===========================================================================
# AC7: STUB=reject -- exit 1; exact stderr substring; armed/<sid> still
# exists; off/<sid> absent; no new reasons.log line.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac7');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC7 setup: armed');
    my $otp = off_mint($sid, 'stopping here');
    ok(defined $otp, 'AC7 setup: minted');
    my $before_lines = scalar reasons_log_lines();
    my ($out, $err, $rc) = off_confirm($sid, $otp, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'reject');
    is($rc, 1, 'AC7: off-confirm with STUB=reject exits 1');
    like($err, qr/disarm rejected by the judge: stub judge rejects this disarm: open work remains/,
        'AC7: stderr contains the verbatim rejection text');
    ok(-e state_root() . "/armed/$sid", 'AC7: armed/<sid> still exists');
    ok(!-e state_root() . "/off/$sid", 'AC7: off/<sid> is absent');
    is(scalar(reasons_log_lines()), $before_lines, 'AC7: no new reasons.log line was appended');
}

# ===========================================================================
# AC8: after a reject, the (now-consumed) OTP refuses "not live"; a fresh
# off + off-confirm (STUB=approve) succeeds.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac8');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC8 setup: armed');
    my $otp1 = off_mint($sid, 'round one');
    ok(defined $otp1, 'AC8 setup: first OTP minted');
    off_confirm($sid, $otp1, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'reject');

    my ($out1, $err1, $rc1) = off_confirm($sid, $otp1, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'approve');
    is($rc1, 1, 'AC8: re-presenting the consumed OTP refuses');
    like($err1, qr/no disarm code is live/, 'AC8: stderr names the no-live-otp refusal');

    my $otp2 = off_mint($sid, 'round two');
    ok(defined $otp2, 'AC8: a fresh off mints a second OTP');
    my ($out2, $err2, $rc2) = off_confirm($sid, $otp2, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'approve');
    is($rc2, 0, 'AC8: the fresh off-confirm with STUB=approve succeeds') or diag("stderr: $err2");
}

# ===========================================================================
# AC13: bp-disarm-judge.md frontmatter.
# ===========================================================================
{
    SKIP: {
        skip('bp-disarm-judge.md does not exist yet', 6) unless -f $AGENT_MD;
        my $raw = slurp($AGENT_MD);
        my @lines = split /\n/, $raw;
        my %fm;
        if (@lines && $lines[0] eq '---') {
            for my $i (1 .. $#lines) {
                last if $lines[$i] eq '---';
                if ($lines[$i] =~ /^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/) {
                    $fm{$1} = $2 unless exists $fm{$1};
                }
            }
        }
        is($fm{name}, 'bp-disarm-judge', 'AC13: frontmatter name is bp-disarm-judge');
        ok(length($fm{description} // ''), 'AC13: frontmatter description is non-empty');
        is($fm{model}, 'sonnet', 'AC13: frontmatter model is sonnet');
        is($fm{effort}, 'medium', 'AC13: frontmatter effort is medium');
        cmp_ok($fm{maxTurns} // 0, '>=', 400, 'AC13: frontmatter maxTurns is at least 400');
        my @tools = sort(split(/\s*,\s*/, $fm{tools} // ''));
        is_deeply(\@tools, [sort qw(Read Grep Glob Bash)], 'AC13: tools is exactly Read, Grep, Glob, Bash');
    }
}

# ===========================================================================
# AC14: STUB=hang, T=2 -- off-confirm exits 1 within 12s; stderr names the
# missing verdict; armed/<sid> still exists; no verdict file; <otp>.pid
# names a pid that is no longer alive; 3s later still no verdict file.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac14');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC14 setup: armed');
    my $otp = off_mint($sid, 'hanging judge test');
    ok(defined $otp, 'AC14 setup: minted');

    my $t0 = time();
    my ($out, $err, $rc) = off_confirm($sid, $otp, 'goal is met',
        CCPRAXIS_DISARM_JUDGE_STUB => 'hang', CCPRAXIS_DISARM_JUDGE_TIMEOUT_SECONDS => 2);
    my $elapsed = time() - $t0;
    is($rc, 1, 'AC14: off-confirm with STUB=hang/T=2 exits 1');
    cmp_ok($elapsed, '<', 12, 'AC14: off-confirm returns within 12s');
    like($err, qr/judge did not return a verdict/, 'AC14: stderr names the missing verdict');
    ok(-e state_root() . "/armed/$sid", 'AC14: armed/<sid> still exists');
    ok(!-e disarm_judge_dir() . "/$otp.verdict.json", 'AC14: no verdict file exists');

    my $pidfile = disarm_judge_dir() . "/$otp.pid";
    if (-f $pidfile) {
        my $pid = slurp($pidfile);
        $pid =~ s/\s+//g;
        ok(length($pid) && $pid =~ /^\d+$/ && !kill(0, $pid),
            'AC14: the pid recorded in <otp>.pid is no longer alive') if length $pid;
    } else {
        fail('AC14: <otp>.pid exists');
    }
    sleep(3);
    ok(!-e disarm_judge_dir() . "/$otp.verdict.json", 'AC14: still no verdict file 3s later');
}

# ===========================================================================
# AC15: STUB=bogus -- off-confirm refuses "judge did not return a verdict";
# no .pid file; still armed.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac15');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC15 setup: armed');
    my $otp = off_mint($sid, 'bogus stub test');
    ok(defined $otp, 'AC15 setup: minted');
    my ($out, $err, $rc) = off_confirm($sid, $otp, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'bogus');
    is($rc, 1, 'AC15: off-confirm with STUB=bogus exits 1');
    like($err, qr/judge did not return a verdict/, 'AC15: stderr names the missing verdict');
    ok(!-e disarm_judge_dir() . "/$otp.pid", 'AC15: no .pid file was written');
    ok(-e state_root() . "/armed/$sid", 'AC15: still armed');
}

# ===========================================================================
# AC17: DC8 -- a reject verdict later overwritten with approve for the SAME
# (already-consumed) OTP is never read by a later OTP's hang.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac17');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC17 setup: armed');
    my $otp1 = off_mint($sid, 'O1 round');
    ok(defined $otp1, 'AC17 setup: O1 minted');
    off_confirm($sid, $otp1, 'goal is met', CCPRAXIS_DISARM_JUDGE_STUB => 'reject');
    my $v1path = disarm_judge_dir() . "/$otp1.verdict.json";
    SKIP: {
        skip('O1 verdict file was never written (upstream missing)', 1) unless -f $v1path;
        my $doc = JSON::PP->new->utf8->canonical->encode({
            otp => $otp1, verdict => 'approve', reason => 'planted approve',
            goal => 'g', off_reason => 'r', justification => 'j', project_root => $PROJECT,
            judge => 'stub', decided_at => '2026-01-01T00:00:00Z',
        });
        open(my $fh, '>:raw', $v1path) or die $!;
        print {$fh} $doc;
        close $fh;
        pass('AC17: O1 verdict file overwritten with a planted approve');
    }

    my $otp2 = off_mint($sid, 'O2 round');
    ok(defined $otp2, 'AC17: O2 minted');
    isnt($otp2, $otp1, 'AC17: O2 differs from O1');
    my ($out, $err, $rc) = off_confirm($sid, $otp2, 'goal is met',
        CCPRAXIS_DISARM_JUDGE_STUB => 'hang', CCPRAXIS_DISARM_JUDGE_TIMEOUT_SECONDS => 2);
    is($rc, 1, 'AC17: off-confirm O2 (hang) refuses -- O1\'s planted approve is never read');
    like($err, qr/judge did not return a verdict/, 'AC17: stderr names the missing verdict for O2');
    ok(-e state_root() . "/armed/$sid", 'AC17: still armed (O1\'s approve never applied to O2)');
}

# ===========================================================================
# AC18: DC8, stale same-path -- a valid approve verdict planted at O2's OWN
# path BEFORE dispatch must be cleared; a hanging O2 run still refuses.
# ===========================================================================
{
    fresh_state_dir();
    my $sid = sess_id('ac18');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC18 setup: armed');
    my $otp2 = off_mint($sid, 'O2 stale test');
    ok(defined $otp2, 'AC18 setup: O2 minted');

    make_path(disarm_judge_dir());
    my $v2path = disarm_judge_dir() . "/$otp2.verdict.json";
    my $doc = JSON::PP->new->utf8->canonical->encode({
        otp => $otp2, verdict => 'approve', reason => 'stale planted approve',
        goal => 'g', off_reason => 'r', justification => 'j', project_root => $PROJECT,
        judge => 'stub', decided_at => '2026-01-01T00:00:00Z',
    });
    open(my $fh, '>:raw', $v2path) or die $!;
    print {$fh} $doc;
    close $fh;

    my ($out, $err, $rc) = off_confirm($sid, $otp2, 'goal is met',
        CCPRAXIS_DISARM_JUDGE_STUB => 'hang', CCPRAXIS_DISARM_JUDGE_TIMEOUT_SECONDS => 2);
    is($rc, 1, 'AC18: off-confirm refuses even though a valid verdict pre-existed at its own path');
    like($err, qr/judge did not return a verdict/, 'AC18: stderr names the missing verdict');
    ok(-e state_root() . "/armed/$sid", 'AC18: still armed (the stale file was cleared before dispatch)');
}

# ===========================================================================
# AC19/AC21: DC10 -- the prompt names the project root, the blueprints dir,
# a fixture ledger under it, and never mentions bp-drive-next; it also
# carries goal/reason/justification and the agent-file path plus both
# VERDICT:/REASON: tokens.
# ===========================================================================
{
    fresh_state_dir();
    make_path("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages");
    open(my $bfh, '>', "$PROJECT/.ccpraxis-local-data/blueprints/fx/blueprint.md") or die $!;
    print {$bfh} "# fx blueprint\n";
    close $bfh;
    open(my $pfh, '>', "$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/01-x.md") or die $!;
    print {$pfh} "---\nstatus: done\n---\n";
    close $pfh;

    my $r = dispatch_wrapper(stub => 'approve', project_root => $PROJECT,
        goal => 'ship the fixture', reason => 'all slices complete', justification => 'nothing left to do');
    my @argv = read_argv($r->{dir} . "/$r->{otp}.argv");
    my $prompt = $argv[4] // '';
    ok(length($prompt), 'AC19/21 setup: the prompt (argv[4]) is non-empty') or diag("rc=$r->{rc} err=$r->{err}");
    like($prompt, qr/\QProject root (your working directory): $PROJECT\E/,
        'AC19: the prompt names the project root exactly');
    like($prompt, qr/\Q$PROJECT\E\/\.ccpraxis-local-data\/blueprints\//,
        'AC19: the prompt names the project\'s blueprints directory');
    unlike($prompt, qr/bp-drive-next/, 'AC19: the prompt never names bp-drive-next');
    ok(-f "$PROJECT/.ccpraxis-local-data/blueprints/fx/blueprint.md",
        'AC19: the fixture blueprint.md the prompt points at actually exists');

    like($prompt, qr/goal: ship the fixture/,              'AC21: prompt contains goal: <goal>');
    like($prompt, qr/reason: all slices complete/,         'AC21: prompt contains reason: <off_reason>');
    like($prompt, qr/justification: nothing left to do/,   'AC21: prompt contains justification: <justification>');
    like($prompt, qr{agents/bp-disarm-judge\.md},           'AC21: prompt names the agent-file path');
    like($prompt, qr/VERDICT:/,                              'AC21: prompt mentions VERDICT:');
    like($prompt, qr/REASON:/,                               'AC21: prompt mentions REASON:');
}

# ===========================================================================
# AC20: Read/Grep/Glob are not in the AC3 denial set (re-asserted here from
# the same argv used above), and bp-drive-next.pl is denied by name in the
# prompt text (never offered as an allowlisted call) -- the guard's own
# matcher-exactness (Bash only) is proven in disarm-judge-guard.t/AC9.
# ===========================================================================
{
    fresh_state_dir();
    my $r = dispatch_wrapper(stub => 'approve');
    my @argv = read_argv($r->{dir} . "/$r->{otp}.argv");
    my ($dt_i) = grep { $argv[$_] eq '--disallowedTools' } 0 .. $#argv;
    my %dt = defined $dt_i ? map { $_ => 1 } split(/,/, $argv[$dt_i + 1] // '') : ();
    for my $must_not (qw(Read Grep Glob)) {
        ok(!$dt{$must_not}, "AC20: --disallowedTools does not deny $must_not (reachable for blueprint status)");
    }
}

# ===========================================================================
# AC22: parse rule, stub mode -- verdict reason matches the canned REASON
# exactly for approve and reject; judge is stub; otp matches.
# ===========================================================================
{
    fresh_state_dir();
    my $ra = dispatch_wrapper(stub => 'approve');
    is($ra->{rc}, 0, 'AC22 approve: wrapper exits 0') or diag("err: $ra->{err}");
    my $va = read_json_file($ra->{vpath});
    is(ref $va eq 'HASH' ? $va->{otp}     : undef, $ra->{otp}, 'AC22 approve: verdict otp matches');
    is(ref $va eq 'HASH' ? $va->{verdict} : undef, 'approve',  'AC22 approve: verdict is approve');
    is(ref $va eq 'HASH' ? $va->{reason}  : undef, 'stub judge approves this disarm',
        'AC22 approve: reason equals the canned REASON exactly');
    is(ref $va eq 'HASH' ? $va->{judge}   : undef, 'stub', 'AC22 approve: judge is stub');

    fresh_state_dir();
    my $rr = dispatch_wrapper(stub => 'reject');
    is($rr->{rc}, 0, 'AC22 reject: wrapper exits 0 (it still writes a verdict file)') or diag("err: $rr->{err}");
    my $vr = read_json_file($rr->{vpath});
    is(ref $vr eq 'HASH' ? $vr->{otp}     : undef, $rr->{otp}, 'AC22 reject: verdict otp matches');
    is(ref $vr eq 'HASH' ? $vr->{verdict} : undef, 'reject',   'AC22 reject: verdict is reject');
    is(ref $vr eq 'HASH' ? $vr->{reason}  : undef, 'stub judge rejects this disarm: open work remains',
        'AC22 reject: reason equals the canned REASON exactly');
    is(ref $vr eq 'HASH' ? $vr->{judge}   : undef, 'stub', 'AC22 reject: judge is stub');
}

# ===========================================================================
# AC16 (final check): across this ENTIRE file, the hostile `claude` shim was
# never invoked -- its log is absent or empty.
# ===========================================================================
{
    my $log_content = -f $CLAUDE_LOG ? slurp($CLAUDE_LOG) : '';
    is($log_content, '', 'AC16: the claude PATH shim log is empty/absent -- claude was never spawned');
}

done_testing();
