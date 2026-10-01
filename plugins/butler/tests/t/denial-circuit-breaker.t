#!/usr/bin/env perl
# platform: any
# ORACLE for never-halt package 07-denial-circuit-breaker
# (specs/07-denial-circuit-breaker-spec.md). Written blind to this package's
# own implementation: BpHook::DenialBreaker, denial-breaker.sh, the three new
# hooks.json registrations, PromptWatch.pm's agent_denial_counts/agent_key/
# drive_solo_dir, and claude-internals.json's auto-mode-denial-limits
# relied_by/new entries DO NOT EXIST / ARE NOT WIRED YET at the time this
# file is written. Every AC below that exercises new behaviour is expected
# to fail red for exactly that reason (a missing file, a missing sub, an
# unrecognised exit code) -- never a harness crash.
#
# Hermetic per spec sec 3: every fixture lives under File::Temp; the real
# ~/.claude, the real state and the repo's own .ccpraxis-local-data are
# never touched. Every spawned process is `bash` on the one shim under test,
# bounded by a fork + waitpid(WNOHANG) loop with a <=15s kill backstop.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

(my $BUTLER = abs_path("$Bin/../..")) =~ s{\\}{/}g;
my $S     = "$BUTLER/scripts";
my $HOOKS = "$BUTLER/hooks";

my $DENIAL_BREAKER_SH = "$HOOKS/denial-breaker.sh";
my $DENIALBREAKER_PM  = "$S/BpHook/DenialBreaker.pm";
my $PROMPTWATCH_PM    = "$S/BpHook/PromptWatch.pm";
my $BPHOOK_PM         = "$S/BpHook.pm";
my $CLAUDE_INTERNALS_JSON = abs_path("$Bin/../../../steward/scripts/claude-internals.json");

require $BPHOOK_PM;   # real, already implemented (package 03)

# ---------------------------------------------------------------------------
# process bookkeeping (prompt-watch.t pattern)
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
my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
(my $STATE_DIR = "$TMPROOT/state") =~ s{\\}{/}g;

$ENV{HOME}             = $FAKE_HOME;
$ENV{USERPROFILE}      = $FAKE_HOME;
$ENV{BUTLER_STATE_DIR} = $STATE_DIR;

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
my $SID_N = 0;
sub next_sid { return sprintf('db%08x', ++$SID_N) }

sub fresh_dir {
    my $d = tempdir(DIR => $TMPROOT, CLEANUP => 1);
    $d =~ s{\\}{/}g;
    return $d;
}

# a data root with .drive-solo already present (drive_solo_dir never
# creates .drive-solo itself; it must pre-exist for anything but the "data
# root missing" edge cases).
sub fresh_data_dir {
    my $d = fresh_dir();
    make_path("$d/.drive-solo");
    return $d;
}

sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub arm_driver {
    my ($sid) = @_;
    local $ENV{BUTLER_STATE_DIR} = $STATE_DIR;
    return BpHook::arm($sid, role => 'driver', by => 'test');
}

sub encode_payload {
    my ($h) = @_;
    my %clean = map { ($_ => $h->{$_}) } grep { defined $h->{$_} } keys %$h;
    return JSON::PP->new->utf8->canonical->encode(\%clean);
}

# run_hook($shim, $stdin_bytes, %opts) -> ($rc, $out, $err)
sub run_hook {
    my ($shim, $stdin_bytes, %opts) = @_;
    my $cwd = $opts{cwd} // fresh_dir();
    make_path($cwd) unless -d $cwd;
    my $env_over = $opts{env} // {};
    my $timeout  = $opts{timeout} // 15;

    my (undef, $stdin_path) = tempfile(DIR => $TMPROOT);
    open my $sfh, '>:raw', $stdin_path or die "write $stdin_path: $!";
    print {$sfh} (defined $stdin_bytes ? $stdin_bytes : '');
    close $sfh;
    my (undef, $out_path) = tempfile(DIR => $TMPROOT);
    my (undef, $err_path) = tempfile(DIR => $TMPROOT);

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        $ENV{HOME}             = $FAKE_HOME;
        $ENV{USERPROFILE}      = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR} = $STATE_DIR;
        for my $k (keys %$env_over) {
            if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} }
            else                          { delete $ENV{$k} }
        }
        unless (chdir($cwd)) { POSIX::_exit(125) }
        open(STDIN,  '<:raw', $stdin_path) or POSIX::_exit(126);
        open(STDOUT, '>:raw', $out_path)   or POSIX::_exit(126);
        open(STDERR, '>:raw', $err_path)   or POSIX::_exit(126);
        exec('bash', $shim);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $deadline = time() + $timeout;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.02);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($out_path) // '';
    my $err = slurp($err_path) // '';
    unlink $stdin_path, $out_path, $err_path;
    return ($rc, $out, $err);
}

sub db_hook {
    my ($payload, %opts) = @_;
    return run_hook($DENIAL_BREAKER_SH, encode_payload($payload), %opts);
}

# ---------------------------------------------------------------------------
# denials.jsonl fixture writer -- OWN writer, independent of PromptWatch
# (an oracle must not use the implementation under test, nor package 06's
# module, to build its own fixtures).
# ---------------------------------------------------------------------------
sub append_raw {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $fh, '>>:raw', $path or die "open $path: $!";
    print {$fh} $bytes;
    close $fh;
}

sub denial_line {
    my (%o) = @_;
    my %rec = (
        ts                   => $o{ts} // '2026-01-01T00:00:00Z',
        session_id           => $o{session_id},
        agent_id             => $o{agent_id} // 'main',
        tool_name            => $o{tool_name} // 'Bash',
        tool_input           => $o{tool_input} // 'rm -rf x',
        tool_input_truncated => JSON::PP::false,
        reason               => $o{reason} // 'auto mode escalated',
    );
    return JSON::PP->new->utf8->canonical->encode(\%rec) . "\n";
}

sub denial_for {
    my ($data, %o) = @_;
    append_raw("$data/.drive-solo/denials.jsonl", denial_line(%o));
}

# ---------------------------------------------------------------------------
# payload builders
# ---------------------------------------------------------------------------
sub bti { return { command => $_[0] } }

sub ev_payload {
    my (%o) = @_;
    my %h = (
        hook_event_name => $o{event},
        permission_mode => exists $o{permission_mode} ? $o{permission_mode} : 'auto',
        session_id      => $o{session_id},
        cwd             => $o{cwd},
        agent_id        => $o{agent_id},
        tool_name       => $o{tool_name},
        tool_input      => $o{tool_input},
        tool_use_id     => $o{tool_use_id},
    );
    return \%h;
}

sub pre_bash {
    my (%o) = @_;
    return ev_payload(%o, event => 'PreToolUse', tool_name => 'Bash',
        tool_input => bti($o{cmd} // 'rm -rf x'));
}
sub pre_tool {
    my (%o) = @_;
    return ev_payload(%o, event => 'PreToolUse');
}
sub post_tool {
    my (%o) = @_;
    return ev_payload(%o, event => 'PostToolUse');
}
sub postf_tool {
    my (%o) = @_;
    return ev_payload(%o, event => 'PostToolUseFailure');
}

# reset_via_read($data, $cwd, $sid, $aid, $tuid, %extra) -- a Pre(Read,T)
# then Post(T) pair, run for real through the shim, the mechanism B3/B6
# describe for resetting the per-agent CONSECUTIVE count.
sub reset_via_read {
    my ($data, $cwd, $sid, $aid, $tuid, %extra) = @_;
    db_hook(pre_tool(session_id => $sid, agent_id => $aid, cwd => $cwd,
            tool_name => 'Read', tool_input => { file_path => '/x' }, tool_use_id => $tuid, %extra),
        env => { CCPRAXIS_DATA_DIR => $data });
    db_hook(post_tool(session_id => $sid, agent_id => $aid, cwd => $cwd,
            tool_name => 'Read', tool_use_id => $tuid, %extra),
        env => { CCPRAXIS_DATA_DIR => $data });
}

my $TUID_N = 0;
sub next_tuid { return sprintf('tu%08x', ++$TUID_N) }

# ---------------------------------------------------------------------------
# PRECONDITIONS -- files exist, bash -n passes, no permissionDecision string.
# Runs first: if denial-breaker.sh / DenialBreaker.pm simply do not exist
# yet, every later AC's failure is already explained by this block.
# ---------------------------------------------------------------------------
{
    ok(-f $DENIAL_BREAKER_SH, 'precondition: denial-breaker.sh exists');
    SKIP: {
        skip 'precondition: denial-breaker.sh does not exist; cannot bash -n it', 1 unless -f $DENIAL_BREAKER_SH;
        system('bash', '-n', $DENIAL_BREAKER_SH);
        my $rc = ($? == -1) ? -1 : ($? >> 8);
        is($rc, 0, 'precondition: bash -n passes on denial-breaker.sh');
    }
    ok(-f $DENIALBREAKER_PM, 'precondition: BpHook/DenialBreaker.pm exists');
    SKIP: {
        skip 'precondition: DenialBreaker.pm does not exist; cannot perl -c it', 1 unless -f $DENIALBREAKER_PM;
        system($^X, '-I', $S, '-c', $DENIALBREAKER_PM);
        my $rc = ($? == -1) ? -1 : ($? >> 8);
        is($rc, 0, 'precondition: perl -c passes on BpHook/DenialBreaker.pm');
    }
    my @scan = grep { -f $_ } ($DENIAL_BREAKER_SH, $DENIALBREAKER_PM);
    my @bad;
    for my $f (@scan) {
        my $body = slurp($f) // '';
        push @bad, $f if index($body, 'permissionDecision') >= 0;
    }
    is(scalar(@bad), 0, 'AC-10 precondition: no string permissionDecision in DenialBreaker.pm or denial-breaker.sh')
        or diag(join(', ', @bad));
}

# ===========================================================================
# AC-1 (B1) -- driver session, A has no denials. Pre(Bash) for A -> abstain,
# pending/<T> exists and holds the denials.jsonl size at call time.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    my $tuid = next_tuid();
    my ($rc, $out, $err) = db_hook(
        pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x', tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'AC-1: no prior denials -- Pre(Bash) for A abstains (exit 0)');
    is($out, '', 'AC-1: empty stdout');
    is($err, '', 'AC-1: empty stderr');
    my $pending = "$data/.drive-solo/denial-breaker/$sid/pending/$tuid";
    ok(-f $pending, 'AC-1: the pending snapshot file exists') or diag("looked at $pending");
    SKIP: {
        skip 'AC-1: no pending file to inspect', 1 unless -f $pending;
        my $content = slurp($pending) // '';
        like($content, qr/\A0\n?\z/, 'AC-1: the pending snapshot holds the pre-call denials.jsonl size (0, file absent)');
    }
}

# ===========================================================================
# AC-2 (B2) -- two denials for A, then Pre(Bash, T9) for A -> deny with the
# subagent message; <c>=2 and <t>=2 appear; pending/T9 is not created.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    my ($rc, $out, $err) = db_hook(
        pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x', tool_use_id => 'T9'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 2, 'AC-2: two denials for A -- Pre(Bash) for A exits 2 (deny)');
    is($out, '', 'AC-2: empty stdout');
    like($err, qr/denial budget is nearly exhausted/, 'AC-2: stderr contains the "denial budget is nearly exhausted" phrase');
    like($err, qr/report to the driver/, 'AC-2: stderr contains "report to the driver"');
    unlike($err, qr/would halt this session/, 'AC-2: stderr does not contain the main-session phrase');
    like($err, qr/\b2\b.*\b2\b|\b2 consecutive\b.*\b2 total\b/s, 'AC-2: stderr mentions the counts (2 consecutive, 2 total)');
    ok(!-f "$data/.drive-solo/denial-breaker/$sid/pending/T9", 'AC-2: no pending file for T9 (deny path writes none)');
}

# ===========================================================================
# AC-3 (B3) -- Denial, Pre(Read,T1), Post(T1), denial -> Pre(Bash) abstains
# (consecutive 1). Same with PostF(T1) in place of Post(T1).
# ===========================================================================
for my $variant (['Post', \&post_tool], ['PostF', \&postf_tool]) {
    my ($label, $builder) = @$variant;
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    my $tuid = next_tuid();

    denial_for($data, session_id => $sid, agent_id => 'A');
    db_hook(pre_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_name => 'Read',
            tool_input => { file_path => '/x' }, tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });
    my $snapshot = "$data/.drive-solo/denial-breaker/$sid/pending/$tuid";
    my $snap_val = slurp($snapshot) // '';
    db_hook($builder->(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });
    denial_for($data, session_id => $sid, agent_id => 'A');

    my ($rc, $out, $err) = db_hook(
        pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, "AC-3 ($label): after the reset, Pre(Bash) for A abstains (consecutive 1)");

    ok(!-f $snapshot, "AC-3 ($label): pending/T1 was deleted by $label");
    my $mirror = "$data/.drive-solo/denial-breaker/$sid/A.json";
    ok(-f $mirror, "AC-3 ($label): the mirror file exists after $label") or diag("looked at $mirror");
    SKIP: {
        skip "AC-3 ($label): no mirror to inspect", 1 unless -f $mirror;
        my $m = eval { JSON::PP->new->utf8->decode(slurp($mirror)) };
        $snap_val =~ s/\s+\z//;
        is(ref($m) eq 'HASH' ? $m->{reset_offset} : undef, ($snap_val + 0),
            "AC-3 ($label): the mirror's reset_offset equals T1's snapshot value");
    }
}

# ===========================================================================
# AC-4 (B4) -- two denials for A, then Post(T2) with no prior Pre for T2 ->
# no reset; Pre(Bash) for A still denies.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    db_hook(post_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_use_id => 'T2'),
        env => { CCPRAXIS_DATA_DIR => $data });
    my ($rc) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 2, 'AC-4: a Post without its own Pre performs no reset -- Pre(Bash) for A still denies');
}

# ===========================================================================
# AC-5 (B5) -- parallel race: D1, Pre(Read,T1) (snapshot after D1), D2,
# Post(T1), Pre(Bash) -> abstain (consecutive 1: D2 survives). D3,
# Pre(Bash) -> deny.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    my $tuid = next_tuid();

    denial_for($data, session_id => $sid, agent_id => 'A');   # D1
    db_hook(pre_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_name => 'Read',
            tool_input => { file_path => '/x' }, tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });
    denial_for($data, session_id => $sid, agent_id => 'A');   # D2 -- after the snapshot
    db_hook(post_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });

    my ($rc1) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc1, 0, 'AC-5: parallel race -- D2 survives the reset, Pre(Bash) abstains (consecutive 1)');

    denial_for($data, session_id => $sid, agent_id => 'A');   # D3
    my ($rc2) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc2, 2, 'AC-5: parallel race -- a further denial (D3) trips A, Pre(Bash) denies');
}

# ===========================================================================
# AC-6 (B6) -- denials interleaved with Read Pre/Post pairs so consecutive
# never exceeds 1: abstain at total MAX_TOTAL-1 (16), deny at MAX_TOTAL
# (17), still deny after a further Read Pre/Post pair.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();

    for my $i (1 .. 16) {
        denial_for($data, session_id => $sid, agent_id => 'A');
        reset_via_read($data, $cwd, $sid, 'A', next_tuid());
    }
    my ($rc1) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc1, 0, 'AC-6: total 16 (< MAX_TOTAL=17), consecutive reset each time -- Pre(Bash) abstains');

    denial_for($data, session_id => $sid, agent_id => 'A');   # total -> 17
    my ($rc2) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc2, 2, 'AC-6: total reaches MAX_TOTAL=17 -- Pre(Bash) denies');

    reset_via_read($data, $cwd, $sid, 'A', next_tuid());
    my ($rc3) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc3, 2, 'AC-6: total never resets -- still denies after a further Read Pre/Post pair');
}

# ===========================================================================
# AC-7 (B7) -- A tripped (two consecutive). Agent B, main (no agent_id), and
# a different session_id (also armed driver) are all unaffected.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');

    my ($rc_b) = db_hook(pre_bash(session_id => $sid, agent_id => 'B', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc_b, 0, 'AC-7: agent B in the same session is unaffected by A\'s counts -- abstains');

    my ($rc_main) = db_hook(pre_bash(session_id => $sid, cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc_main, 0, 'AC-7: the main session (no agent_id) is unaffected by A\'s counts -- abstains');

    my $sid2 = next_sid();
    arm_driver($sid2);
    my ($rc_other) = db_hook(pre_bash(session_id => $sid2, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc_other, 0, 'AC-7: agent A in a DIFFERENT session_id starts clean -- abstains');

    # main's denials leave A untripped and vice versa.
    my $sid3 = next_sid();
    arm_driver($sid3);
    my $data3 = fresh_data_dir();
    denial_for($data3, session_id => $sid3, agent_id => 'main');
    denial_for($data3, session_id => $sid3, agent_id => 'main');
    my ($rc_a_untripped) = db_hook(pre_bash(session_id => $sid3, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data3 });
    is($rc_a_untripped, 0, "AC-7: main's denials leave agent A untripped");

    my $data4 = fresh_data_dir();
    denial_for($data4, session_id => $sid3, agent_id => 'A2');
    denial_for($data4, session_id => $sid3, agent_id => 'A2');
    my ($rc_main_untripped) = db_hook(pre_bash(session_id => $sid3, cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data4 });
    is($rc_main_untripped, 0, "AC-7: agent A2's denials leave the main session untripped");
}

# ===========================================================================
# AC-8 (B8) -- a tripped agent: each exempt tool abstains, each non-exempt
# tool denies. @CLASSIFIER_EXEMPT_TOOLS equals spec sec 2.7's exempt rows
# exactly (as a set), read in-process.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');

    for my $tool (qw(Read Grep Glob TaskStop SendMessage SubagentHandback)) {
        my ($rc) = db_hook(pre_tool(session_id => $sid, agent_id => 'A', cwd => $cwd,
                tool_name => $tool, tool_input => {}, tool_use_id => next_tuid()),
            env => { CCPRAXIS_DATA_DIR => $data });
        is($rc, 0, "AC-8: tripped A -- Pre($tool) abstains (exempt)");
    }
    for my $tool (qw(Edit Write Agent WebFetch Skill AskUserQuestion)) {
        my ($rc) = db_hook(pre_tool(session_id => $sid, agent_id => 'A', cwd => $cwd,
                tool_name => $tool, tool_input => {}, tool_use_id => next_tuid()),
            env => { CCPRAXIS_DATA_DIR => $data });
        is($rc, 2, "AC-8: tripped A -- Pre($tool) denies (not exempt)");
    }

    my $DB_LOADED = do { local $@; eval { require $DENIALBREAKER_PM; 1 } };
    ok($DB_LOADED, 'AC-8 precondition: BpHook::DenialBreaker loads') or diag($@ // 'require failed');
    SKIP: {
        skip 'AC-8: DenialBreaker.pm did not load; cannot read @CLASSIFIER_EXEMPT_TOOLS', 1 unless $DB_LOADED;
        my @got = @BpHook::DenialBreaker::CLASSIFIER_EXEMPT_TOOLS;
        my @want = qw(
            Read Grep Glob
            LSP ToolSearch
            ListMcpResourcesTool ReadMcpResourceTool ReadMcpResourceDirTool RefreshMcpTools WaitForMcpServers
            TodoWrite TaskCreate TaskGet TaskUpdate TaskList GetTask TaskStop
            EnterPlanMode ExitPlanMode ReportFindings ConnectGitHub ShowOnboardingRolePicker
            SubagentHandback
            SendMessage
        );
        is_deeply([ sort @got ], [ sort @want ],
            'AC-8: @CLASSIFIER_EXEMPT_TOOLS equals spec sec 2.7\'s exempt rows exactly (as a set)')
            or diag('got: ' . join(',', sort @got));
    }
}

# ===========================================================================
# AC-9 (B9) -- Bash command vs permissions.allow/ask matcher table.
# ===========================================================================
{
    my @ALLOW = ('Bash(perl scripts/run-tests.pl *)', 'Bash(git status)', 'Bash(ls:*)',
                 'Bash(git * main)', 'Bash(git *)');
    my @ASK   = ('Bash(git push *)');

    my @TABLE = (
        [ 'perl scripts/run-tests.pl --fast',                       0, 'wildcard' ],
        [ 'perl scripts/run-tests.pl',                               0, 'single trailing " *" is optional' ],
        [ '  perl scripts/run-tests.pl --fast  ',                    0, 'trimmed' ],
        [ 'perl scripts/run-tests.plx',                              2, '" *" needs the space' ],
        [ 'perl scripts/run-tests.pl --fast && rm -rf x',            2, 'metachar &' ],
        [ 'perl scripts/run-tests.pl x > out',                       2, 'metachar >' ],
        [ 'perl scripts/run-tests.pl $(cat f)',                      2, 'metachar $' ],
        [ 'git status',                                              0, 'exact (also git *)' ],
        [ 'ls',                                                      0, 'legacy prefix ls:*' ],
        [ 'ls -la',                                                  0, 'legacy prefix ls:*' ],
        [ 'lsof',                                                    2, 'prefix needs a following space' ],
        [ 'git push origin main',                                    2, 'ask rule git push * matches' ],
        [ 'git log -1',                                              0, 'git *' ],
        [ 'rm -rf x',                                                2, 'no rule' ],
        [ "perl scripts/run-tests.pl\nrm x",                         2, 'metachar newline' ],
    );

    sub settings_file {
        my ($dir, $name, $allow, $ask) = @_;
        make_path("$dir/.claude");
        open my $fh, '>:raw', "$dir/.claude/$name" or die $!;
        print {$fh} JSON::PP->new->canonical->encode({ permissions => { allow => $allow, ask => $ask } });
        close $fh;
    }

    # --- primary case: rules in the project's .claude/settings.json, CLAUDE_PROJECT_DIR set.
    {
        my $sid = next_sid();
        arm_driver($sid);
        my $data = fresh_data_dir();
        my $project = fresh_dir();
        settings_file($project, 'settings.json', \@ALLOW, \@ASK);
        denial_for($data, session_id => $sid, agent_id => 'A');
        denial_for($data, session_id => $sid, agent_id => 'A');

        for my $row (@TABLE) {
            my ($cmd, $want_rc, $why) = @$row;
            my ($rc) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => $cmd),
                env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
            is($rc, $want_rc, "AC-9: [$why] command [$cmd] -> " . ($want_rc ? 'deny' : 'abstain'));
        }
    }

    # --- variant: the same rules in settings.local.json ONLY give the same verdicts.
    {
        my $sid = next_sid();
        arm_driver($sid);
        my $data = fresh_data_dir();
        my $project = fresh_dir();
        settings_file($project, 'settings.local.json', \@ALLOW, \@ASK);
        denial_for($data, session_id => $sid, agent_id => 'A');
        denial_for($data, session_id => $sid, agent_id => 'A');

        for my $row (@TABLE[0, 3, 7, 11, 13]) {
            my ($cmd, $want_rc, $why) = @$row;
            my ($rc) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => $cmd),
                env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
            is($rc, $want_rc, "AC-9 (settings.local.json only): [$why] command [$cmd] -> " . ($want_rc ? 'deny' : 'abstain'));
        }
    }

    # --- variant: rules in $HOME/.claude/settings.json ONLY (no CLAUDE_PROJECT_DIR).
    {
        my $sid = next_sid();
        arm_driver($sid);
        my $data = fresh_data_dir();
        my $project = fresh_dir();   # no .claude/settings.json here
        settings_file($FAKE_HOME, 'settings.json', \@ALLOW, \@ASK);
        denial_for($data, session_id => $sid, agent_id => 'A');
        denial_for($data, session_id => $sid, agent_id => 'A');

        for my $row (@TABLE[0, 3, 7, 11, 13]) {
            my ($cmd, $want_rc, $why) = @$row;
            my ($rc) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => $cmd),
                env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => undef });
            is($rc, $want_rc, "AC-9 (\$HOME/.claude/settings.json only): [$why] command [$cmd] -> " . ($want_rc ? 'deny' : 'abstain'));
        }
        unlink "$FAKE_HOME/.claude/settings.json";   # avoid leaking into later ACs
    }

    # --- variant: a corrupt project settings.json beside a valid local one
    # still lets the local rules apply.
    {
        my $sid = next_sid();
        arm_driver($sid);
        my $data = fresh_data_dir();
        my $project = fresh_dir();
        make_path("$project/.claude");
        open my $fh, '>:raw', "$project/.claude/settings.json" or die $!;
        print {$fh} '{ this is not valid json ';
        close $fh;
        settings_file($project, 'settings.local.json', \@ALLOW, \@ASK);
        denial_for($data, session_id => $sid, agent_id => 'A');
        denial_for($data, session_id => $sid, agent_id => 'A');

        for my $row (@TABLE[0, 13]) {
            my ($cmd, $want_rc, $why) = @$row;
            my ($rc) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => $cmd),
                env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
            is($rc, $want_rc, "AC-9 (corrupt project settings.json beside valid local): [$why] command [$cmd] -> " . ($want_rc ? 'deny' : 'abstain'));
        }
    }
}

# ===========================================================================
# AC-11 (B11) -- bypassPermissions / dontAsk: never deny even at 20 denials;
# no denial-breaker/ dir created by Pre, Post or PostF.
# ===========================================================================
for my $mode (qw(bypassPermissions dontAsk)) {
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    for (1 .. 20) { denial_for($data, session_id => $sid, agent_id => 'A') }

    my $tuid = next_tuid();
    my ($rc1) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x',
            tool_use_id => $tuid, permission_mode => $mode),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc1, 0, "AC-11: $mode -- Pre(Bash) abstains at 20 denials");

    db_hook(post_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_use_id => $tuid, permission_mode => $mode),
        env => { CCPRAXIS_DATA_DIR => $data });
    db_hook(postf_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_use_id => next_tuid(), permission_mode => $mode),
        env => { CCPRAXIS_DATA_DIR => $data });

    ok(!-d "$data/.drive-solo/denial-breaker", "AC-11: $mode -- Pre/Post/PostF write nothing under denial-breaker/");
}

# ===========================================================================
# AC-12 (B13) -- a corrupt mirror (truncated JSON / a JSON array / a negative
# reset_offset) abstains (fails open); a directory existing at the mirror
# path is instead treated as reset_offset=0 -- the safe over-count direction,
# same as a missing mirror -- because a directory can never self-heal via
# the Post rename (it always fails), so the old "corrupt mirror abstains"
# reading made that abstain PERMANENT for the agent. Corrected per the
# reconciliation decision recorded alongside FIX-4, 2026-10-01T11:17:22Z:
# done criterion 8 means fails open the safe way, not fails-open-to-abstain-
# forever. A later Pre(Read,T)/Post(T) pair rewrites a valid (non-directory)
# mirror.
# ===========================================================================
for my $shape (['{oops', 'truncated-json'], ['[]', 'json-array'], ['{"reset_offset":-1}', 'negative-offset'], [undef, 'a-directory']) {
    my ($content, $label) = @$shape;
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');   # 2 consecutive denials -- trips MAX_CONSECUTIVE=2

    my $mirror = "$data/.drive-solo/denial-breaker/$sid/A.json";
    make_path(dirname($mirror));
    if (defined $content) {
        open my $fh, '>:raw', $mirror or die $!;
        print {$fh} $content;
        close $fh;
    } else {
        make_path($mirror);   # the directory shape
    }

    my ($rc) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    if ($label eq 'a-directory') {
        is($rc, 2, "AC-12 ($label): a directory at the mirror path is treated as reset_offset=0 (fresh count), not an indefinite abstain -- 2 consecutive denials still trip -> deny");
    } else {
        is($rc, 0, "AC-12 ($label): a corrupt mirror abstains (fails open)");
    }

    if ($label ne 'a-directory') {
        my $tuid = next_tuid();
        reset_via_read($data, $cwd, $sid, 'A', $tuid);
        ok(-f $mirror, "AC-12 ($label): the later Pre(Read)/Post(Read) pair rewrites the mirror as a regular file");
        SKIP: {
            skip "AC-12 ($label): no mirror to decode", 1 unless -f $mirror;
            my $m = eval { JSON::PP->new->utf8->decode(slurp($mirror)) };
            ok(ref($m) eq 'HASH' && defined($m->{reset_offset}) && $m->{reset_offset} =~ /\A\d+\z/,
                "AC-12 ($label): the rewritten mirror is valid canonical JSON with a non-negative integer reset_offset");
        }
    }
}

# ===========================================================================
# AC-13 (B14) -- every listed failure case: exit 0, empty stdout/stderr,
# nothing created, the data dir still absent where applicable.
# ===========================================================================
{
    my @cases;
    push @cases, ['CCPRAXIS_DATA_DIR nonexistent', sub {
        my $missing = fresh_dir() . '/does-not-exist';
        return ({ CCPRAXIS_DATA_DIR => $missing }, undef, undef, $missing);
    }];
    push @cases, ['.drive-solo absent', sub {
        my $d = fresh_dir();   # no .drive-solo made
        return ({ CCPRAXIS_DATA_DIR => $d }, undef, undef, undef);
    }];
    push @cases, ['empty stdin', sub {
        my $d = fresh_data_dir();
        return ({ CCPRAXIS_DATA_DIR => $d }, '', undef, undef);
    }];
    push @cases, ['non-JSON stdin', sub {
        my $d = fresh_data_dir();
        return ({ CCPRAXIS_DATA_DIR => $d }, 'not json at all {', undef, undef);
    }];
    push @cases, ['no session_id', sub {
        my $d = fresh_data_dir();
        return ({ CCPRAXIS_DATA_DIR => $d }, undef, 1, undef);
    }];
    push @cases, ['no hook_event_name', sub {
        my $d = fresh_data_dir();
        return ({ CCPRAXIS_DATA_DIR => $d }, undef, undef, undef, 1);
    }];
    push @cases, ['hook_event_name is Stop', sub {
        my $d = fresh_data_dir();
        return ({ CCPRAXIS_DATA_DIR => $d }, undef, undef, undef, undef, 1);
    }];

    for my $c (@cases) {
        my ($label, $setup) = @$c;
        my ($envh, $stdin_override, $no_sid, $missing_check, $no_event, $stop_event) = $setup->();
        my $sid = next_sid();
        arm_driver($sid);
        my $cwd = fresh_dir();
        my $stdin_bytes;
        if (defined $stdin_override) {
            $stdin_bytes = $stdin_override;
        } else {
            my $p = pre_bash(session_id => $no_sid ? undef : $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x');
            delete $p->{hook_event_name} if $no_event;
            $p->{hook_event_name} = 'Stop' if $stop_event;
            $stdin_bytes = encode_payload($p);
        }
        my ($rc, $out, $err) = db_hook_raw($stdin_bytes, env => $envh);
        is($rc, 0, "AC-13: $label -- exit 0");
        is($out, '', "AC-13: $label -- empty stdout");
        is($err, '', "AC-13: $label -- empty stderr");
        if (defined $missing_check) {
            ok(!-e $missing_check, "AC-13: $label -- the nonexistent data dir still does not exist");
        }
    }
}

sub db_hook_raw {
    my ($stdin_bytes, %opts) = @_;
    return run_hook($DENIAL_BREAKER_SH, $stdin_bytes, %opts);
}

# ===========================================================================
# AC-14 (B10) -- main session trip uses the main-session message, both
# causes of L2.
# ===========================================================================
{
    # cause 1: a consecutive trip, total < MAX_TOTAL.
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'main');
    denial_for($data, session_id => $sid, agent_id => 'main');
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 2, 'AC-14: tripped main session (consecutive) -- exit 2');
    like($err, qr/would halt this session behind a permission prompt/, 'AC-14: main message phrase present');
    like($err, qr/bp-denials/, 'AC-14: stderr names bp-denials');
    unlike($err, qr/report to the driver/, 'AC-14: subagent phrase absent');
    like($err, qr/resets the consecutive count/, 'AC-14: consecutive-cause L2 phrase present');

    # cause 2: total >= MAX_TOTAL.
    my $sid2 = next_sid();
    arm_driver($sid2);
    my $data2 = fresh_data_dir();
    for (1 .. 17) {
        denial_for($data2, session_id => $sid2, agent_id => 'main');
        reset_via_read($data2, $cwd, $sid2, 'main', next_tuid()) if $_ < 17;
    }
    my ($rc2, undef, $err2) = db_hook(pre_bash(session_id => $sid2, cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data2 });
    is($rc2, 2, 'AC-14: tripped main session (total) -- exit 2');
    like($err2, qr/never resets/, 'AC-14: total-cause L2 phrase present');
}

# ===========================================================================
# AC-15 (B12) -- unarmed, no BP_LEDGER: writes nothing. Coordinator via
# BP_LEDGER (unarmed): denies as B2 does.
# ===========================================================================
{
    my $sid = next_sid();   # deliberately NOT armed
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'AC-15: unarmed, no BP_LEDGER -- abstains (exit 0)');
    ok(!-d "$data/.drive-solo/denial-breaker", 'AC-15: unarmed, no BP_LEDGER -- writes nothing');

    my ($fh, $ledger_path) = tempfile(DIR => $TMPROOT);
    print {$fh} "coordinator\n"; close $fh;
    my ($rc2) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data, BP_LEDGER => $ledger_path });
    is($rc2, 2, 'AC-15: coordinator context (BP_LEDGER set, unarmed) -- denies, same as B2');
}

# ===========================================================================
# AC-16 (B15) -- two valid denials plus one malformed line plus one partial
# last line -> trips with <t>=2 (malformed/partial lines are not counted).
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    append_raw("$data/.drive-solo/denials.jsonl", "{not valid json at all\n");
    denial_for($data, session_id => $sid, agent_id => 'A');
    # a partial last line (no trailing "\n"): a near-complete denial record
    # for the SAME agent, truncated mid-way, so it must not be double-counted.
    my $partial = JSON::PP->new->utf8->canonical->encode({
        ts => '2026-01-01T00:00:00Z', session_id => $sid, agent_id => 'A', tool_name => 'Bash',
        tool_input => 'rm -rf y', tool_input_truncated => JSON::PP::false, reason => 'auto mode escalated',
    });
    append_raw("$data/.drive-solo/denials.jsonl", substr($partial, 0, int(length($partial) / 2)));

    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 2, 'AC-16: two valid denials plus a malformed line plus a partial last line -- trips (exit 2)');
    like($err, qr/\(2 consecutive, 2 total/, 'AC-16: the malformed and partial lines are not counted (<t>=2)');
}

# ===========================================================================
# AC-17 -- agent_denial_counts($path, $sid, $aid, $since) in-process: the
# exact ($total, $since_count) for a table of fixture files.
# ===========================================================================
{
    my $PW_LOADED = do { local $@; eval { require $PROMPTWATCH_PM; 1 } };
    ok($PW_LOADED, 'AC-17 precondition: BpHook::PromptWatch loads') or diag($@ // 'require failed');
    my $HAS_SUB = $PW_LOADED && defined &BpHook::PromptWatch::agent_denial_counts;
    ok($HAS_SUB, 'AC-17 precondition: BpHook::PromptWatch::agent_denial_counts is defined');

    SKIP: {
        skip 'AC-17: agent_denial_counts is not defined', 7 unless $HAS_SUB;

        # missing file
        my $missing = fresh_dir() . '/no-such-denials.jsonl';
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($missing, 'S1', 'A', 0) ], [0, 0],
            'AC-17: a missing file gives (0, 0)');

        # empty file
        my $empty = fresh_dir() . '/empty.jsonl';
        open my $efh, '>', $empty or die $!; close $efh;
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($empty, 'S1', 'A', 0) ], [0, 0],
            'AC-17: an empty file gives (0, 0)');

        # a file with records for another sid / another agent / the target.
        my $path = fresh_dir() . '/denials.jsonl';
        append_raw($path, denial_line(session_id => 'OTHER',  agent_id => 'A'));
        append_raw($path, denial_line(session_id => 'S1',     agent_id => 'OTHERAGENT'));
        my $off1 = -s $path;
        append_raw($path, denial_line(session_id => 'S1', agent_id => 'A'));
        my $off2 = -s $path;
        append_raw($path, denial_line(session_id => 'S1', agent_id => 'A'));
        my $off3 = -s $path;

        is_deeply([ BpHook::PromptWatch::agent_denial_counts($path, 'S1', 'A', 0) ], [2, 2],
            'AC-17: total=2 for the target sid/agent; records for another sid/agent are excluded');
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($path, 'S1', 'A', $off1) ], [2, 2],
            'AC-17: $since at the first qualifying record\'s start -- since_count=2');
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($path, 'S1', 'A', $off2) ], [2, 1],
            'AC-17: $since mid-file (between the two qualifying records) -- since_count=1');
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($path, 'S1', 'A', $off3) ], [2, 0],
            'AC-17: $since past the last qualifying record -- since_count=0');

        my $past_eof = $off3 + 10_000;
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($path, 'S1', 'A', $past_eof) ], [2, 2],
            'AC-17: $since past EOF is treated as 0 -- since_count equals total');

        # a trailing partial line must not be counted.
        my $path2 = fresh_dir() . '/denials2.jsonl';
        append_raw($path2, denial_line(session_id => 'S1', agent_id => 'A'));
        my $full = denial_line(session_id => 'S1', agent_id => 'A');
        append_raw($path2, substr($full, 0, int(length($full) / 2)));   # no trailing newline
        is_deeply([ BpHook::PromptWatch::agent_denial_counts($path2, 'S1', 'A', 0) ], [1, 1],
            'AC-17: a trailing partial line is skipped, not counted');
    }
}

# ===========================================================================
# AC-18 -- agent_key($p) and drive_solo_dir($p) in-process.
# ===========================================================================
{
    my $PW_LOADED = defined &BpHook::PromptWatch::read_from;   # already required by AC-17 if it ran
    $PW_LOADED ||= do { local $@; eval { require $PROMPTWATCH_PM; 1 } };
    my $HAS_KEY = $PW_LOADED && defined &BpHook::PromptWatch::agent_key;
    my $HAS_DSD = $PW_LOADED && defined &BpHook::PromptWatch::drive_solo_dir;
    ok($HAS_KEY, 'AC-18 precondition: BpHook::PromptWatch::agent_key is defined');
    ok($HAS_DSD, 'AC-18 precondition: BpHook::PromptWatch::drive_solo_dir is defined');

    SKIP: {
        skip 'AC-18: agent_key is not defined', 3 unless $HAS_KEY;
        is(BpHook::PromptWatch::agent_key({ session_id => 'S1' }), 'main', 'AC-18: agent_key -- no agent_id -> main');
        is(BpHook::PromptWatch::agent_key({ session_id => 'S1', agent_id => 'abc123' }), 'abc123', 'AC-18: agent_key -- a valid id is returned verbatim');
        is(BpHook::PromptWatch::agent_key({ session_id => 'S1', agent_id => "bad id!" }), '?', 'AC-18: agent_key -- an invalid id -> ?');
    }
    SKIP: {
        skip 'AC-18: drive_solo_dir is not defined', 2 unless $HAS_DSD;
        my $data = fresh_dir();   # no .drive-solo
        my $r1 = BpHook::PromptWatch::drive_solo_dir({ cwd => $data });
        ok(!defined $r1, 'AC-18: drive_solo_dir returns undef when .drive-solo is absent');
        ok(!-d "$data/.drive-solo", 'AC-18: drive_solo_dir never creates .drive-solo');

        my $data2 = fresh_data_dir();   # .drive-solo pre-exists
        local $ENV{CCPRAXIS_DATA_DIR} = $data2;
        my $r2 = BpHook::PromptWatch::drive_solo_dir({ cwd => $data2 });
        is($r2, "$data2/.drive-solo", 'AC-18: drive_solo_dir returns the existing .drive-solo path');
    }
}

# ===========================================================================
# AC-19 -- constants. $MAX_CONSECUTIVE=2, $MAX_TOTAL=17, each below its
# AUTO_MODE twin; the AUTO_MODE values equal claude-internals.json's
# auto-mode-denial-limits signature example; that entry's relied_by names
# BpHook::DenialBreaker.
# ===========================================================================
{
    my $DB_LOADED = defined &BpHook::DenialBreaker::run;
    $DB_LOADED ||= do { local $@; eval { require $DENIALBREAKER_PM; 1 } };
    ok($DB_LOADED, 'AC-19 precondition: BpHook::DenialBreaker loads') or diag($@ // 'require failed');

    SKIP: {
        skip 'AC-19: DenialBreaker.pm did not load', 4 unless $DB_LOADED;
        is($BpHook::DenialBreaker::MAX_CONSECUTIVE, 2, 'AC-19: $MAX_CONSECUTIVE is 2');
        is($BpHook::DenialBreaker::MAX_TOTAL, 17, 'AC-19: $MAX_TOTAL is 17');
        cmp_ok($BpHook::DenialBreaker::MAX_CONSECUTIVE, '<', $BpHook::DenialBreaker::AUTO_MODE_MAX_CONSECUTIVE,
            'AC-19: $MAX_CONSECUTIVE < $AUTO_MODE_MAX_CONSECUTIVE');
        cmp_ok($BpHook::DenialBreaker::MAX_TOTAL, '<', $BpHook::DenialBreaker::AUTO_MODE_MAX_TOTAL,
            'AC-19: $MAX_TOTAL < $AUTO_MODE_MAX_TOTAL');
    }

    ok(-f $CLAUDE_INTERNALS_JSON, 'AC-19 precondition: claude-internals.json exists')
        or diag("looked at $CLAUDE_INTERNALS_JSON");
    SKIP: {
        skip 'AC-19: claude-internals.json missing or unreadable', 2 unless -f $CLAUDE_INTERNALS_JSON;
        my $raw = slurp($CLAUDE_INTERNALS_JSON);
        my $doc = eval { JSON::PP->new->decode($raw) };
        my ($entry) = ref($doc) eq 'HASH' && ref($doc->{entries}) eq 'ARRAY'
            ? grep { ($_->{id} // '') eq 'auto-mode-denial-limits' } @{ $doc->{entries} }
            : ();
        ok($entry, 'AC-19: claude-internals.json has an auto-mode-denial-limits entry');
        SKIP: {
            skip 'AC-19: no entry to inspect', 2 unless $entry;
            my ($sig) = grep { ($_->{type} // '') eq 'regex' } @{ $entry->{signatures} // [] };
            my $example = $sig ? $sig->{example} : undef;
            my ($ac, $at) = (defined $example && $example =~ /maxConsecutive:(\d+),maxTotal:(\d+)/) ? ($1, $2) : (undef, undef);
            SKIP: {
                skip 'AC-19: cannot parse the signature example', 2 unless $DB_LOADED && defined $ac && defined $at;
                is($BpHook::DenialBreaker::AUTO_MODE_MAX_CONSECUTIVE, $ac,
                    'AC-19: $AUTO_MODE_MAX_CONSECUTIVE equals the signature example\'s maxConsecutive');
                is($BpHook::DenialBreaker::AUTO_MODE_MAX_TOTAL, $at,
                    'AC-19: $AUTO_MODE_MAX_TOTAL equals the signature example\'s maxTotal');
            }
            like(($entry->{relied_by} // ''), qr/BpHook::DenialBreaker/,
                'AC-19: the auto-mode-denial-limits entry\'s relied_by contains BpHook::DenialBreaker');
        }
    }
}

#############################################################################
# FIX-BATCH PIN TESTS -- added ahead of the implementer's 6-item fix-batch
# (ledger packages/07-denial-circuit-breaker.md, driver reconciliation entry
# 2026-10-01T11:17:22Z). Each block below is a NEW red case: it must FAIL
# against the current (unfixed) DenialBreaker.pm/denial-breaker.sh for the
# specific behaviour the fix-batch item describes, never for a harness or
# scaffolding bug. Numbered FIX-1..FIX-6 to match the fix-batch dispatch.
#############################################################################

# ===========================================================================
# FIX-1 (matcher hardening: reviewer M1 + red-team L5/L6) -- allow_listed /
# _bash_rule_matches must: reject commands with internal whitespace runs
# beyond a single space (tab, 2+ consecutive spaces, \x0b/\x0c) rather than
# matching them against a rule after only end-trimming; reject commands
# containing quotes (' or ") or a backslash; reject (not allow-list) when
# any ask rule is configured AND the command's first word is a NAME=value
# env-assignment (the harness strips env assignments before matching its
# ask rule, so an unstripped match here is a false allow-list).
# ===========================================================================
{
    # (a) two internal spaces: "git  push origin main" must NOT be treated
    # as allow-listed against Bash(git *) by matching after only end-trim.
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $project = fresh_dir();
    settings_file($project, 'settings.json', ['Bash(git *)'], []);
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => 'git  push origin main'),
        env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
    is($rc, 2, 'FIX-1a: "git  push origin main" (2 internal spaces) must NOT be allow-listed against Bash(git *) -- deny')
        or diag("expected deny (rc=2): a run of 2+ internal spaces must be rejected, not matched after end-trimming; got rc=$rc, stdout=[$out], stderr=[$err]");
}
{
    # (b) a tab: "rm<TAB>-rf x" must NOT match a bare Bash allow.
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $project = fresh_dir();
    settings_file($project, 'settings.json', ['Bash'], []);
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => "rm\t-rf x"),
        env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
    is($rc, 2, 'FIX-1b: "rm<TAB>-rf x" must NOT be allow-listed even against a bare Bash allow -- deny')
        or diag("expected deny (rc=2): an internal tab must be rejected; got rc=$rc, stdout=[$out], stderr=[$err]");
}
{
    # (c) an unterminated quote: 'git log "x' must NOT match Bash(git log *).
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $project = fresh_dir();
    settings_file($project, 'settings.json', ['Bash(git log *)'], []);
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => 'git log "x'),
        env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
    is($rc, 2, 'FIX-1c: git log "x (unterminated quote) must NOT be allow-listed against Bash(git log *) -- deny')
        or diag("expected deny (rc=2): a command containing a quote must be rejected; got rc=$rc, stdout=[$out], stderr=[$err]");
}
{
    # (d) ask-rule bypass via env-assignment: with an ask rule for
    # Bash(git push *) and an allow for bare Bash, "FOO=1 git push origin
    # main" must NOT be allow-listed.
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $project = fresh_dir();
    settings_file($project, 'settings.json', ['Bash'], ['Bash(git push *)']);
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => 'FOO=1 git push origin main'),
        env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => $project });
    is($rc, 2, 'FIX-1d: "FOO=1 git push origin main" must NOT be allow-listed -- an ask rule exists and the first word is a NAME=value env-assignment -- deny')
        or diag("expected deny (rc=2): when any ask rule is configured, a NAME=value-prefixed command must be refused rather than matched against the bare Bash allow; got rc=$rc, stdout=[$out], stderr=[$err]");
}

# ===========================================================================
# FIX-2 (red-team M1) -- _run_pre must only write the pending snapshot when
# permission_mode eq 'auto'. A Pre/Post pair taken in a different mode must
# not be able to advance the reset point: the harness only resets its own
# consecutive counter while actually IN auto mode, so resetting here on a
# non-auto Pre/Post pair undercounts vs the harness once back in auto mode.
# ===========================================================================
for my $other_mode (qw(acceptEdits plan)) {
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');   # A tripped (2 consecutive, recorded under auto mode)

    my $tuid = next_tuid();
    db_hook(pre_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_name => 'Read',
            tool_input => { file_path => '/x' }, tool_use_id => $tuid, permission_mode => $other_mode),
        env => { CCPRAXIS_DATA_DIR => $data });
    my $pending = "$data/.drive-solo/denial-breaker/$sid/pending/$tuid";
    ok(!-f $pending, "FIX-2 ($other_mode): Pre(Read) taken outside auto mode must not write a pending snapshot")
        or diag("found $pending written during a Pre in permission_mode=$other_mode -- it should only be written when permission_mode eq auto");

    db_hook(post_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_use_id => $tuid, permission_mode => $other_mode),
        env => { CCPRAXIS_DATA_DIR => $data });

    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 2, "FIX-2 ($other_mode): back in auto mode, A is still tripped -- a Pre/Post pair taken in $other_mode must not have reset the consecutive count")
        or diag("expected deny (rc=2): a Pre/Post pair taken in permission_mode=$other_mode must not advance the reset point; got rc=$rc, stdout=[$out], stderr=[$err]");
}

# ===========================================================================
# FIX-3 (red-team M2) -- a per-(session_id, agent_id) total_since offset,
# set at session start/resume via a SessionStart event, so a resumed
# session whose prior run already accumulated total>=MAX_TOTAL denials.jsonl
# records does not trip permanently the instant it resumes (the harness's
# own in-memory denial counter is fresh on resume; denials.jsonl persists
# across the whole data root).
#
# ASSUMPTION (spec text for this item does not exist yet -- it is the
# fix-batch's own addition, not yet in the spec file): this test exercises
# only the public, observable behaviour -- firing a SessionStart
# hook_event_name payload directly at the shim. It does NOT assert on
# hooks.json gaining a SessionStart registration (that routing is the
# implementer's to add) nor on any internal file format for the persisted
# total_since offset -- only the resulting trip/abstain verdict is pinned.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    for (1 .. 17) {
        denial_for($data, session_id => $sid, agent_id => 'main');
    }   # total already >= MAX_TOTAL=17, BEFORE SessionStart fires (a resumed session)

    my $ss_payload = { hook_event_name => 'SessionStart', session_id => $sid, cwd => $cwd,
        permission_mode => 'auto', source => 'resume' };
    my ($src) = db_hook($ss_payload, env => { CCPRAXIS_DATA_DIR => $data });
    is($src, 0, 'FIX-3: SessionStart itself exits 0');

    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'FIX-3: after SessionStart, total is computed relative to a new total_since offset -- the 17 pre-existing records do not immediately trip the resumed session')
        or diag("expected abstain (rc=0): SessionStart should set a total_since offset for (sid=$sid, aid=main) so the 17 pre-existing denials.jsonl records are not counted against the fresh/resumed session; got rc=$rc, stdout=[$out], stderr=[$err]");
}

# FIX-4 (red-team M4) -- _read_mirror must treat ANY corrupt/unreadable
# mirror shape, including a directory existing at the mirror file's path,
# the same as a missing mirror: reset_offset=0 (the safe over-count
# direction), never an indefinite abstain. This is now pinned by AC-12
# (B13)'s 'a-directory' sub-case above, which was corrected to expect the
# same reset_offset=0/deny outcome for the identical input (2 prior
# consecutive denials + a directory at the mirror path) -- reconciliation
# entry 2026-10-01T11:17:22Z. Kept there rather than duplicated here because
# AC-12's loop is the better-integrated home for this shape (it already
# iterates every corrupt-mirror shape with shared scaffolding).

# ===========================================================================
# FIX-5 (red-team L7) -- project settings resolution must NOT fall back to
# the payload's cwd when CLAUDE_PROJECT_DIR is unset: a cwd-controlling
# agent must not be able to steer the breaker into honouring a
# .claude/settings.json the harness itself would never consult.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $project = fresh_dir();
    settings_file($project, 'settings.json', ['Bash(rm *)'], []);
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');

    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $project, cmd => 'rm -rf x'),
        env => { CCPRAXIS_DATA_DIR => $data, CLAUDE_PROJECT_DIR => undef });
    is($rc, 2, 'FIX-5: CLAUDE_PROJECT_DIR unset -- the payload cwd\'s .claude/settings.json must NOT be honoured, so its allow rule does not abstain the deny')
        or diag("expected deny (rc=2): without CLAUDE_PROJECT_DIR set, the payload cwd ($project) must not be trusted as the project settings root; got rc=$rc, stdout=[$out], stderr=[$err]");
}

# ===========================================================================
# FIX-6 (red-team INFO hardening) -- the pending snapshot should record the
# agent_id it was written for; Post must verify that recorded agent_id
# matches the Post event's own agent_id before applying a reset. A
# mismatched Post (different agent_id, same tool_use_id) must not blindly
# apply the other agent's snapshot.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_data_dir();
    my $cwd = fresh_dir();
    denial_for($data, session_id => $sid, agent_id => 'A');
    denial_for($data, session_id => $sid, agent_id => 'A');   # A tripped (2 consecutive)

    my $tuid = next_tuid();
    db_hook(pre_tool(session_id => $sid, agent_id => 'A', cwd => $cwd, tool_name => 'Read',
            tool_input => { file_path => '/x' }, tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });   # writes pending/<tuid>, recorded for agent A

    # a Post for the SAME tool_use_id but claiming a DIFFERENT agent_id (B)
    db_hook(post_tool(session_id => $sid, agent_id => 'B', cwd => $cwd, tool_use_id => $tuid),
        env => { CCPRAXIS_DATA_DIR => $data });

    my $mirror_b = "$data/.drive-solo/denial-breaker/$sid/B.json";
    ok(!-f $mirror_b, "FIX-6: a Post claiming a DIFFERENT agent_id than the pending snapshot was recorded for must not apply that snapshot to the mismatched agent's mirror")
        or diag("found $mirror_b (B's mirror) written from A's pending snapshot -- the agent_id mismatch between the recorded pending file and the Post event was not detected");

    # A's own trip must stand: its pending snapshot was not validly
    # consumed by a Post event claiming to be a different agent.
    my ($rc, $out, $err) = db_hook(pre_bash(session_id => $sid, agent_id => 'A', cwd => $cwd, cmd => 'rm x'),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 2, "FIX-6: agent A remains tripped -- its pending snapshot was not validly consumed by the mismatched Post for agent B")
        or diag("expected deny (rc=2): got rc=$rc, stdout=[$out], stderr=[$err]");
}

done_testing();
