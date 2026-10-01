#!/usr/bin/env perl
# platform: any
# ORACLE for never-halt package 06-prompt-watch (specs/06-prompt-watch-spec.md,
# Decisions 2, 9, 11 and 40 -- 40 is authoritative where it differs from the
# spec). Written blind to this package's own implementation: record-prompt.sh,
# record-denial.sh, BpHook/PromptWatch.pm, bp-denials.pl, bin/bp-denials and
# the PROMPT exit in butler-hold.pl DO NOT EXIST / ARE NOT WIRED YET at the
# time this file is written. Every AC below that exercises the new behaviour
# is expected to fail red for exactly that reason (a missing file, a missing
# module, an unrecognised exit code) -- never a harness crash. A few ACs that
# exercise unchanged behaviour (the bash-level driver/ledger prefilter itself,
# butler-hold's behaviour when watching is OFF) may already be green; that is
# fine (see fork-guard-bash-cost.t's header for the same rule).
#
# Hermetic per spec sec 3/4: every fixture lives under File::Temp; the real
# ~/.claude, the real butler-state and the repo's own .ccpraxis-local-data are
# never touched (guarded at the end); every spawned process is `bash` or
# `perl` on the shims/scripts under test, bounded by a fork + waitpid(WNOHANG)
# loop with a kill backstop, never launcher/podman/claude/another .t.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path getcwd);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);
use Encode ();

(my $BUTLER = abs_path("$Bin/../..")) =~ s{\\}{/}g;
my $S    = "$BUTLER/scripts";
my $HOOKS = "$BUTLER/hooks";
my $BIN   = "$BUTLER/bin";

my $RECORD_PROMPT_SH = "$HOOKS/record-prompt.sh";
my $RECORD_DENIAL_SH = "$HOOKS/record-denial.sh";
my $PROMPTWATCH_PM   = "$S/BpHook/PromptWatch.pm";
my $BP_DENIALS_PL    = "$S/bp-denials.pl";
my $BP_DENIALS_BIN   = "$BIN/bp-denials";
my $BUTLER_HOLD_SHIM = "$BIN/butler-hold";
my $DRIVE_NEXT_PL    = "$S/bp-drive-next.pl";

require "$S/BpHook.pm";   # real, already implemented (package 03)

# ---------------------------------------------------------------------------
# process bookkeeping (continuity-holder.t pattern)
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

my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};
my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
my ($REAL_DATA, $REAL_DATA_EXISTS, $REAL_DATA_MTIME);
{
    my $rh = (defined $REAL_HOME && length $REAL_HOME) ? $REAL_HOME
           : (defined $REAL_USERPROFILE && length $REAL_USERPROFILE) ? $REAL_USERPROFILE
           : undef;
    if (defined $rh) {
        (my $rhn = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE = "$rhn/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
    }
    $REAL_DATA = "$BUTLER/../../.ccpraxis-local-data";
    (my $rd = abs_path($REAL_DATA) // $REAL_DATA) =~ s{\\}{/}g;
    $REAL_DATA = $rd;
    $REAL_DATA_EXISTS = -d $REAL_DATA ? 1 : 0;
    $REAL_DATA_MTIME  = $REAL_DATA_EXISTS ? (stat($REAL_DATA))[9] : undef;
}

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
sub next_sid { return sprintf('pw%08x', ++$SID_N) }

sub fresh_dir {
    my $d = tempdir(DIR => $TMPROOT, CLEANUP => 1);
    $d =~ s{\\}{/}g;
    return $d;
}

sub fresh_existing_data_dir {
    my $d = fresh_dir();
    make_path($d);
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

sub lines_of {
    my ($text) = @_;
    return () unless defined $text;
    my @l = split /\n/, $text;
    pop @l while @l && $l[-1] eq '';
    return @l;
}

# read_jsonl_file($path) -- OWN reader, independent of the implementation
# under test: every "\n"-terminated line that decodes as a JSON object, in
# file order; a malformed or trailing partial line is skipped. [] on a
# missing file. This is deliberately not PromptWatch::read_records -- an
# oracle must not judge the code by its own reader.
sub read_jsonl_file {
    my ($path) = @_;
    my $raw = slurp($path);
    return [] unless defined $raw;
    my @out;
    while ($raw =~ /\G([^\n]*)\n/gc) {
        my $line = $1;
        my $obj = eval { JSON::PP->new->utf8->decode($line) };
        push @out, $obj if !$@ && ref $obj eq 'HASH';
    }
    return \@out;
}

sub arm_driver {
    my ($sid) = @_;
    local $ENV{BUTLER_STATE_DIR} = $STATE_DIR;
    return BpHook::arm($sid, role => 'driver', by => 'test');
}

sub arm_role {
    my ($sid, $role) = @_;
    local $ENV{BUTLER_STATE_DIR} = $STATE_DIR;
    return BpHook::arm($sid, role => $role, by => 'test');
}

# encode_payload(\%fields) -- compact canonical JSON, keys with an undef
# value OMITTED entirely (so "no agent_id" really means the key is absent,
# not present-and-null).
sub encode_payload {
    my ($h) = @_;
    my %clean = map { ($_ => $h->{$_}) } grep { defined $h->{$_} } keys %$h;
    return JSON::PP->new->utf8->canonical->encode(\%clean);
}

# run_hook($shim, $stdin_bytes, %opts) -> ($rc, $out, $err)
# %opts: cwd (process cwd for the child; default a fresh empty dir), env
# (hashref of overrides; undef value deletes), timeout (backstop, default 15).
# Every child: fork + exec('bash', $shim); bounded wait with a KILL backstop.
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

# wait_pid_bounded / spawn_hold / wait_for_holder -- continuity-holder.t
# pattern, needed for AC-11/AC-12/AC-13.
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

sub spawn_hold {
    my ($argv, $env_over) = @_;
    $env_over //= {};
    my (undef, $outfile) = tempfile(DIR => $TMPROOT);
    my (undef, $errfile) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{CCPRAXIS_NO_WAKELOCK}  = 1;
        $ENV{HOME}                  = $FAKE_HOME;
        $ENV{USERPROFILE}           = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE} = 1;
        for my $k (keys %$env_over) {
            if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} }
            else                          { delete $ENV{$k} }
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('bash', $BUTLER_HOLD_SHIM, @$argv);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    return ($pid, $outfile, $errfile);
}

sub reap_and_log {
    my ($pid, $outfile, $errfile, $sig) = @_;
    $sig //= 'TERM';
    kill($sig, $pid) if kill(0, $pid);
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile) // '';
    my $err = slurp($errfile) // '';
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
}

sub wait_for_holder {
    my ($sid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        local $ENV{BUTLER_STATE_DIR} = $STATE_DIR;
        my $h = BpHook::holder($sid);
        return $h if ref $h eq 'HASH';
        sleep(0.02);
    }
    return undef;
}

sub write_ticket_for {
    my ($sid, $argv, %o) = @_;
    my $p = {
        session_id      => $sid,
        tool_use_id     => 'tu' . $sid,
        transcript_path => $o{transcript_path},
        cwd             => $o{cwd},
    };
    local $ENV{BUTLER_STATE_DIR} = $STATE_DIR;
    return BpHook::write_ticket($p, 'butler-hold', $argv, operator => 0, background => 1);
}

sub write_transcript {
    my ($path) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    close $fh;
}

# append_raw($path, $bytes) -- append raw bytes to a jsonl fixture file
# WITHOUT going through PromptWatch (an oracle must not use the
# implementation under test to build its own fixtures).
sub append_raw {
    my ($path, $bytes) = @_;
    make_path(dirname($path));
    open my $fh, '>>:raw', $path or die "open $path: $!";
    print {$fh} $bytes;
    close $fh;
}

sub prompt_line {
    my (%o) = @_;
    my %rec = (
        ts         => '2026-01-01T00:00:00Z',
        session_id => $o{session_id},
        agent_id   => $o{agent_id},
        agent_type => $o{agent_type},
        message    => $o{message} // 'need permission',
    );
    return JSON::PP->new->utf8->canonical->encode(\%rec) . "\n";
}

# ---------------------------------------------------------------------------
# payload builders (Decision 40 shapes: Notification has NO agent_id;
# PermissionDenied carries agent_id for a subagent)
# ---------------------------------------------------------------------------
sub notif_payload {
    my (%o) = @_;
    return {
        session_id        => $o{session_id},
        cwd               => $o{cwd},
        transcript_path   => $o{transcript_path},
        permission_mode   => $o{permission_mode} // 'default',
        agent_type        => $o{agent_type},
        agent_id          => $o{agent_id},   # undef -> omitted by encode_payload
        message           => $o{message} // 'need permission to run this',
        title             => $o{title} // 'Permission required',
        notification_type => exists $o{notification_type}
            ? $o{notification_type}
            : 'permission_prompt',
    };
}

sub denial_payload {
    my (%o) = @_;
    return {
        session_id      => $o{session_id},
        cwd             => $o{cwd},
        transcript_path => $o{transcript_path},
        permission_mode => $o{permission_mode} // 'default',
        agent_id        => $o{agent_id},
        tool_name       => $o{tool_name} // 'Bash',
        tool_input      => $o{tool_input},
        tool_use_id     => $o{tool_use_id} // 'tu-denial-1',
        reason          => $o{reason} // 'auto mode escalated',
    };
}

sub utf8_len { return length(Encode::encode_utf8($_[0])) }

# ===========================================================================
# AC-16 -- syntax and the permissionDecision ban. Runs first: if the shims
# and module simply do not exist yet, every later AC's non-existence is
# already explained, and this AC documents it precisely.
# ===========================================================================
{
    my @files = ($RECORD_PROMPT_SH, $RECORD_DENIAL_SH, $BP_DENIALS_BIN);
    for my $f (@files) {
        ok(-f $f, "AC-16 precondition: $f exists");
    }
    SKIP: {
        skip 'AC-16: bash -n needs the files to exist', scalar(@files) unless (grep { -f $_ } @files) == @files;
        for my $f (@files) {
            system('bash', '-n', $f);
            my $rc = ($? == -1) ? -1 : ($? >> 8);
            is($rc, 0, "AC-16: bash -n passes on $f");
        }
    }
    my @scan = grep { -f $_ } ($RECORD_PROMPT_SH, $RECORD_DENIAL_SH, $PROMPTWATCH_PM);
    my @bad;
    for my $f (@scan) {
        my $body = slurp($f) // '';
        push @bad, $f if index($body, 'permissionDecision') >= 0;
    }
    is(scalar(@bad), 0, 'AC-16: no string permissionDecision in PromptWatch.pm or the two shims')
        or diag(join(', ', @bad));
}

# ===========================================================================
# AC-1 (B1) -- driver session, permission_prompt Notification with agent_id:
# one well-formed appended line; exit 0; empty stdout/stderr.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $payload = notif_payload(
        session_id => $sid, cwd => $project, agent_id => 'a1b2c3d4',
        agent_type => 'general-purpose', message => 'need to run rm -rf /x',
    );
    my ($rc, $out, $err) = run_hook($RECORD_PROMPT_SH, encode_payload($payload),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'AC-1: record-prompt.sh exits 0 for a driver permission_prompt Notification');
    is($out, '', 'AC-1: stdout is empty');
    is($err, '', 'AC-1: stderr is empty');

    my $recs = read_jsonl_file("$data/.drive-solo/prompts.jsonl");
    is(scalar(@$recs), 1, 'AC-1: exactly one line was appended to prompts.jsonl');
    SKIP: {
        skip 'AC-1: no record to inspect', 5 unless @$recs;
        my $r = $recs->[0];
        ok(exists $r->{ts} && length($r->{ts} // ''), 'AC-1: record has ts');
        is($r->{session_id}, $sid, 'AC-1: record session_id matches');
        is($r->{agent_id}, 'a1b2c3d4', 'AC-1: record agent_id equals the payloads agent_id');
        is($r->{agent_type}, 'general-purpose', 'AC-1: record agent_type equals the payloads agent_type');
        is($r->{message}, 'need to run rm -rf /x', 'AC-1: record message equals the payloads message');
    }
    # raw-bytes check: file ends with exactly one "\n" and nothing after it.
    my $raw = slurp("$data/.drive-solo/prompts.jsonl") // '';
    like($raw, qr/\n\z/, 'AC-1: the file ends with a trailing newline') if length $raw;
}

# ===========================================================================
# AC-2 (B2) -- without agent_id: recorded agent_id is 'main', agent_type null.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $payload = notif_payload(session_id => $sid, cwd => $project, message => 'main session prompt');
    my ($rc, $out, $err) = run_hook($RECORD_PROMPT_SH, encode_payload($payload),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'AC-2: exit 0 without agent_id');
    my $recs = read_jsonl_file("$data/.drive-solo/prompts.jsonl");
    is(scalar(@$recs), 1, 'AC-2: one line appended');
    SKIP: {
        skip 'AC-2: no record', 2 unless @$recs;
        is($recs->[0]{agent_id}, 'main', 'AC-2: agent_id defaults to main when the payload carries none');
        ok(exists $recs->[0]{agent_type} && !defined $recs->[0]{agent_type}, 'AC-2: agent_type is JSON null');
    }
}

# ===========================================================================
# AC-3 (B3) -- other notification types record nothing.
# ===========================================================================
{
    for my $ntype (qw(idle_prompt), undef) {
        my $sid = next_sid();
        arm_driver($sid);
        my $data = fresh_existing_data_dir();
        my $project = fresh_dir(); make_path($project);
        my $payload = notif_payload(session_id => $sid, cwd => $project, notification_type => $ntype);
        my ($rc, $out, $err) = run_hook($RECORD_PROMPT_SH, encode_payload($payload),
            env => { CCPRAXIS_DATA_DIR => $data });
        my $label = defined $ntype ? $ntype : '(absent)';
        is($rc, 0, "AC-3: notification_type $label -- exit 0");
        is($out, '', "AC-3: notification_type $label -- empty stdout");
        ok(!-e "$data/.drive-solo/prompts.jsonl", "AC-3: notification_type $label -- prompts.jsonl absent");
    }
}

# ===========================================================================
# AC-4 (B4) -- unarmed / manual / reporter, no BP_LEDGER: nothing written,
# for both hooks.
# ===========================================================================
{
    for my $case (
        ['unarmed',  undef],
        ['manual',   'manual'],
        ['reporter', 'reporter'],
    ) {
        my ($label, $role) = @$case;
        my $sid = next_sid();
        arm_role($sid, $role) if defined $role;
        my $data = fresh_existing_data_dir();
        my $project = fresh_dir(); make_path($project);

        my $np = notif_payload(session_id => $sid, cwd => $project, agent_id => 'sub1');
        my ($rc1) = run_hook($RECORD_PROMPT_SH, encode_payload($np), env => { CCPRAXIS_DATA_DIR => $data });
        is($rc1, 0, "AC-4: $label -- record-prompt.sh exits 0");
        ok(!-e "$data/.drive-solo/prompts.jsonl", "AC-4: $label -- prompts.jsonl not created");

        my $dp = denial_payload(session_id => $sid, cwd => $project, tool_input => 'ls');
        my ($rc2) = run_hook($RECORD_DENIAL_SH, encode_payload($dp), env => { CCPRAXIS_DATA_DIR => $data });
        is($rc2, 0, "AC-4: $label -- record-denial.sh exits 0");
        ok(!-e "$data/.drive-solo/denials.jsonl", "AC-4: $label -- denials.jsonl not created");
    }
}

# ===========================================================================
# AC-5 (B5) -- unarmed but BP_LEDGER set (coordinator context) records.
# ===========================================================================
{
    my $sid = next_sid();
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my ($fh, $ledger_path) = tempfile(DIR => $TMPROOT);
    print {$fh} "coordinator\n"; close $fh;

    my $payload = notif_payload(session_id => $sid, cwd => $project);
    my ($rc) = run_hook($RECORD_PROMPT_SH, encode_payload($payload),
        env => { CCPRAXIS_DATA_DIR => $data, BP_LEDGER => $ledger_path });
    is($rc, 0, 'AC-5: coordinator context (BP_LEDGER set, unarmed) exits 0');
    my $recs = read_jsonl_file("$data/.drive-solo/prompts.jsonl");
    is(scalar(@$recs), 1, 'AC-5: coordinator context records the prompt');
}

# ===========================================================================
# AC-6 (B6) -- long/short/multi-byte tool_input truncation, bound read from
# the package variable (require the .pm).
# ===========================================================================
{
    my $PW_LOADED = do { local $@; eval { require $PROMPTWATCH_PM; 1 } };
    ok($PW_LOADED, 'AC-6 precondition: BpHook::PromptWatch loads') or diag($@ // 'require failed');
    my $BOUND = $PW_LOADED ? $BpHook::PromptWatch::TOOL_INPUT_MAX_BYTES : undef;
    ok(defined $BOUND && $BOUND > 0, 'AC-6 precondition: $TOOL_INPUT_MAX_BYTES is a positive number')
        if $PW_LOADED;

    SKIP: {
        skip 'AC-6: PromptWatch.pm did not load; cannot read the bound', 6 unless $PW_LOADED && defined $BOUND;

        # long: 10000 ASCII bytes starting "rm -rf /x "
        {
            my $sid = next_sid();
            arm_driver($sid);
            my $data = fresh_existing_data_dir();
            my $project = fresh_dir(); make_path($project);
            my $cmd = 'rm -rf /x ' . ('a' x (10000 - length('rm -rf /x ')));
            my $dp = denial_payload(session_id => $sid, cwd => $project, tool_name => 'Bash', tool_input => { command => $cmd });
            my ($rc) = run_hook($RECORD_DENIAL_SH, encode_payload($dp), env => { CCPRAXIS_DATA_DIR => $data });
            is($rc, 0, 'AC-6: long Bash denial exits 0');
            my $recs = read_jsonl_file("$data/.drive-solo/denials.jsonl");
            is(scalar(@$recs), 1, 'AC-6: long Bash denial appended one line');
            SKIP: {
                skip 'AC-6: no record', 3 unless @$recs;
                my $r = $recs->[0];
                is(index($cmd, $r->{tool_input}), 0, 'AC-6: tool_input is a PREFIX of the command')
                    if defined $r->{tool_input};
                cmp_ok(utf8_len($r->{tool_input} // ''), '<=', $BOUND, 'AC-6: tool_input byte length <= the bound');
                is($r->{tool_input_truncated}, JSON::PP::true, 'AC-6: tool_input_truncated is true');
            }
        }
        # short: unchanged, flag false
        {
            my $sid = next_sid();
            arm_driver($sid);
            my $data = fresh_existing_data_dir();
            my $project = fresh_dir(); make_path($project);
            my $dp = denial_payload(session_id => $sid, cwd => $project, tool_name => 'Bash', tool_input => { command => 'rm -rf x' });
            run_hook($RECORD_DENIAL_SH, encode_payload($dp), env => { CCPRAXIS_DATA_DIR => $data });
            my $recs = read_jsonl_file("$data/.drive-solo/denials.jsonl");
            SKIP: {
                skip 'AC-6: no short record', 2 unless @$recs;
                is($recs->[0]{tool_input}, 'rm -rf x', 'AC-6: short command is unchanged');
                is($recs->[0]{tool_input_truncated}, JSON::PP::false, 'AC-6: short command -- truncated flag false');
            }
        }
        # multi-byte straddling the bound
        {
            my $sid = next_sid();
            arm_driver($sid);
            my $data = fresh_existing_data_dir();
            my $project = fresh_dir(); make_path($project);
            my $unit = "\x{00e9}";   # 2-byte UTF-8
            my $cmd = $unit x ($BOUND + 50);
            my $dp = denial_payload(session_id => $sid, cwd => $project, tool_name => 'Bash', tool_input => { command => $cmd });
            run_hook($RECORD_DENIAL_SH, encode_payload($dp), env => { CCPRAXIS_DATA_DIR => $data });
            my $recs = read_jsonl_file("$data/.drive-solo/denials.jsonl");
            SKIP: {
                skip 'AC-6: no multi-byte record', 2 unless @$recs;
                my $ti = $recs->[0]{tool_input} // '';
                cmp_ok(utf8_len($ti), '<=', $BOUND, 'AC-6: multi-byte prefix stays within the bound');
                my $ok_utf8 = eval { Encode::decode('UTF-8', Encode::encode_utf8($ti), Encode::FB_CROAK); 1 };
                ok($ok_utf8, 'AC-6: multi-byte prefix is valid UTF-8 (never splits a character)');
            }
        }
    }
}

# ===========================================================================
# AC-7 (B7) -- non-Bash tool_input is the canonical JSON text of the object.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $dp = denial_payload(session_id => $sid, cwd => $project, tool_name => 'Write',
        tool_input => { file_path => '/x/y', content => 'z' });
    run_hook($RECORD_DENIAL_SH, encode_payload($dp), env => { CCPRAXIS_DATA_DIR => $data });
    my $recs = read_jsonl_file("$data/.drive-solo/denials.jsonl");
    is(scalar(@$recs), 1, 'AC-7: one denial line appended');
    SKIP: {
        skip 'AC-7: no record', 1 unless @$recs;
        my $expect = JSON::PP->new->canonical->encode({ file_path => '/x/y', content => 'z' });
        is($recs->[0]{tool_input}, $expect, 'AC-7: tool_input is the canonical JSON text of the non-Bash tool_input');
    }
}

# ===========================================================================
# AC-8 (B8) -- every failure path: exit 0, empty stdout/stderr, no data file.
# ===========================================================================
{
    my @fail_cases;

    push @fail_cases, ['nonexistent data dir', sub {
        my $missing = fresh_dir() . '/does-not-exist';
        return (undef, { CCPRAXIS_DATA_DIR => $missing }, $missing);
    }];
    push @fail_cases, ['.drive-solo is a regular file', sub {
        my $data = fresh_existing_data_dir();
        open my $fh, '>', "$data/.drive-solo" or die $!;
        close $fh;
        return ($data, { CCPRAXIS_DATA_DIR => $data });
    }];
    push @fail_cases, ['target jsonl is a directory', sub {
        my $data = fresh_existing_data_dir();
        make_path("$data/.drive-solo/prompts.jsonl");
        make_path("$data/.drive-solo/denials.jsonl");
        return ($data, { CCPRAXIS_DATA_DIR => $data });
    }];
    push @fail_cases, ['empty stdin', sub {
        my $data = fresh_existing_data_dir();
        return ($data, { CCPRAXIS_DATA_DIR => $data }, undef, '');
    }];
    push @fail_cases, ['non-JSON stdin', sub {
        my $data = fresh_existing_data_dir();
        return ($data, { CCPRAXIS_DATA_DIR => $data }, undef, 'not json at all {');
    }];
    push @fail_cases, ['payload without session_id', sub {
        my $data = fresh_existing_data_dir();
        return ($data, { CCPRAXIS_DATA_DIR => $data }, undef, undef, 1);
    }];

    for my $c (@fail_cases) {
        my ($label, $setup) = @$c;
        for my $mode (['prompt', $RECORD_PROMPT_SH], ['denial', $RECORD_DENIAL_SH]) {
            my ($mname, $shim) = @$mode;
            my ($data, $envh, $missing_check, $stdin_override, $no_sid) = $setup->();
            my $sid = next_sid();
            arm_driver($sid);
            my $project = fresh_dir(); make_path($project);
            my $stdin_bytes;
            if (defined $stdin_override) {
                $stdin_bytes = $stdin_override;
            } else {
                my $payload = ($mname eq 'prompt')
                    ? notif_payload(session_id => $no_sid ? undef : $sid, cwd => $project)
                    : denial_payload(session_id => $no_sid ? undef : $sid, cwd => $project, tool_input => 'ls');
                $stdin_bytes = encode_payload($payload);
            }
            my ($rc, $out, $err) = run_hook($shim, $stdin_bytes, env => $envh);
            is($rc, 0, "AC-8: $label ($mname) -- exit 0");
            is($out, '', "AC-8: $label ($mname) -- empty stdout");
            is($err, '', "AC-8: $label ($mname) -- empty stderr");
            if (defined $missing_check) {
                ok(!-e $missing_check, "AC-8: $label ($mname) -- the nonexistent data dir still does not exist");
            }
        }
    }
}

# ===========================================================================
# AC-9 (B9) -- payload cwd resolution: CCPRAXIS_DATA_DIR and BP_PROJECT_ROOT
# unset; payload cwd names an existing project with .ccpraxis-local-data
# (not a git repo); process cwd is a DIFFERENT empty temp dir -> the line
# lands under the PROJECT's data dir, nothing under the process cwd.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $project = fresh_dir();
    make_path("$project/.ccpraxis-local-data");
    my $proc_cwd = fresh_dir(); make_path($proc_cwd);

    my $payload = notif_payload(session_id => $sid, cwd => $project);
    my ($rc, $out, $err) = run_hook($RECORD_PROMPT_SH, encode_payload($payload),
        cwd => $proc_cwd, env => { CCPRAXIS_DATA_DIR => undef, BP_PROJECT_ROOT => undef });
    is($rc, 0, 'AC-9: exit 0 with payload-cwd resolution');
    ok(-f "$project/.ccpraxis-local-data/.drive-solo/prompts.jsonl",
        'AC-9: the line lands under the PAYLOAD cwds .ccpraxis-local-data/.drive-solo/');
    ok(!-e "$proc_cwd/.ccpraxis-local-data", 'AC-9: nothing was created under the PROCESS cwd');
}

# ===========================================================================
# AC-10 (B10) -- 8 concurrent denial-hook processes, one driver session:
# denials.jsonl holds exactly 8 lines, each a JSON object.
# ===========================================================================
{
    my $sid = next_sid();
    arm_driver($sid);
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);

    my @pids;
    my @outpaths;
    for my $i (1 .. 8) {
        my (undef, $stdin_path) = tempfile(DIR => $TMPROOT);
        my $dp = denial_payload(session_id => $sid, cwd => $project, tool_input => "cmd$i", tool_use_id => "tu$i");
        open my $sfh, '>:raw', $stdin_path or die $!;
        print {$sfh} encode_payload($dp);
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
            $ENV{CCPRAXIS_DATA_DIR} = $data;
            chdir($project) or POSIX::_exit(125);
            open(STDIN,  '<:raw', $stdin_path) or POSIX::_exit(126);
            open(STDOUT, '>:raw', $out_path)   or POSIX::_exit(126);
            open(STDERR, '>:raw', $err_path)   or POSIX::_exit(126);
            exec('bash', $RECORD_DENIAL_SH);
            POSIX::_exit(127);
        }
        push @pids, $pid;
        push @KILL_PIDS, $pid;
    }
    my $deadline = time() + 20;
    my %reaped;
    while (time() < $deadline && scalar(keys %reaped) < @pids) {
        for my $pid (@pids) {
            next if $reaped{$pid};
            my $w = waitpid($pid, WNOHANG);
            $reaped{$pid} = 1 if $w == $pid;
        }
        sleep(0.05);
    }
    for my $pid (@pids) {
        unless ($reaped{$pid}) { kill('KILL', $pid); waitpid($pid, 0) }
    }
    @KILL_PIDS = grep { my $p = $_; !(grep { $_ == $p } @pids) } @KILL_PIDS;

    my $recs = read_jsonl_file("$data/.drive-solo/denials.jsonl");
    is(scalar(@$recs), 8, 'AC-10: 8 concurrent denial-hook processes produce exactly 8 lines');
    my $all_objects = (grep { ref $_ eq 'HASH' } @$recs) == @$recs;
    ok($all_objects, 'AC-10: every line decodes as a JSON object');
}

# ===========================================================================
# AC-11 (B11 + B12) -- butler-hold with a fixture ticket: a pre-existing
# qualifying line does not trigger; a later-appended qualifying line
# (session_id own, agent_id a valid non-main id), completed by its trailing
# newline, exits 3 within the 10s backstop with the exact line, no
# "released:" line, empty stderr, the record still present with the same
# token.
# ===========================================================================
{
    my $sid = next_sid();
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $tp = "$project/$sid.jsonl";
    write_transcript($tp);
    write_ticket_for($sid, ['S1'], transcript_path => $tp, cwd => $project);

    my $prompts_path = "$data/.drive-solo/prompts.jsonl";
    # B11: a pre-existing qualifying line, written BEFORE become.
    append_raw($prompts_path, prompt_line(session_id => $sid, agent_id => 'preexisting1', message => 'stale prompt'));

    my ($pid, $outfile, $errfile) = spawn_hold(['S1'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2, CCPRAXIS_DATA_DIR => $data });
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'AC-11: precondition -- the holder became');
    my $token_before = ref $h eq 'HASH' ? $h->{token} : undef;

    # Still alive after several ticks -- the pre-existing line did not fire (B11).
    sleep(1.2);   # >= 5 ticks at 0.2s
    ok(kill(0, $pid), 'AC-11 (B11): the holder is still alive after several ticks with only the pre-existing line present');

    # A different session's qualifying line -- ignored.
    append_raw($prompts_path, prompt_line(session_id => 'someone-elses-sid', agent_id => 'other1', message => 'not mine'));
    sleep(0.6);
    ok(kill(0, $pid), 'AC-11 (B12): another sessions qualifying line does not trigger an exit');

    # Malformed line -- ignored.
    append_raw($prompts_path, "{not valid json\n");
    sleep(0.6);
    ok(kill(0, $pid), 'AC-11 (B12): a malformed line does not trigger an exit');

    # A qualifying line WITHOUT its trailing newline yet -- ignored.
    my $qualifying_no_nl = JSON::PP->new->utf8->canonical->encode(
        { ts => '2026-01-01T00:00:01Z', session_id => $sid, agent_id => 'sub-target-1', agent_type => 'general-purpose', message => 'need permission for rm -rf /x' });
    append_raw($prompts_path, $qualifying_no_nl);   # no trailing "\n"
    sleep(0.6);
    ok(kill(0, $pid), 'AC-11 (B12): a qualifying line without its trailing newline does not trigger an exit');

    # Completing it with "\n" -- exits 3 within the 10s backstop.
    append_raw($prompts_path, "\n");
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile) // '';
    my $err = slurp($errfile) // '';
    unlink $outfile, $errfile;

    is($rc, 3, 'AC-11: exits with code 3 once the qualifying line is completed by its trailing newline');
    my @l = lines_of($out);
    is($l[-1] // '', 'PROMPT sub-target-1: need permission for rm -rf /x',
        'AC-11: the exact last stdout line names the agent and the (whitespace-collapsed) message');
    ok(!(grep { /^released:/ } @l), 'AC-11: no "released:" line follows the PROMPT exit');
    is($err, '', 'AC-11: stderr is empty');

    my $h2 = wait_for_holder($sid, 2) // BpHook::holder($sid);
    ok(ref $h2 eq 'HASH', 'AC-11: the holder record is still present after the PROMPT exit');
    SKIP: {
        skip 'AC-11: no record to compare tokens', 1 unless ref $h2 eq 'HASH' && defined $token_before;
        is($h2->{token}, $token_before, 'AC-11: the record still carries the same token as before the exit');
    }
}

# ===========================================================================
# AC-11 (B12, Decision 40) -- a same-session line with agent_id "main" DOES
# trigger a PROMPT exit. Decision 40 (read from claude.exe 2.1.282):
# Notification hook payloads never carry an agent_id -- it is ALWAYS absent
# from the raw payload -- so PromptWatch's documented fallback ("main" when
# absent/null, spec sec 2.4) means every real-world prompts.jsonl record for
# the main agent IS agent_id "main". The holder must fire on session_id
# alone, never filtering on agent_id; if main-agent lines were skipped the
# PROMPT exit could never fire in production at all.
# ===========================================================================
{
    my $sid = next_sid();
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $tp = "$project/$sid.jsonl";
    write_transcript($tp);
    write_ticket_for($sid, ['M1'], transcript_path => $tp, cwd => $project);

    my $prompts_path = "$data/.drive-solo/prompts.jsonl";

    my ($pid, $outfile, $errfile) = spawn_hold(['M1'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2, CCPRAXIS_DATA_DIR => $data });
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'AC-11 (B12-main, Decision 40): precondition -- the holder became');

    append_raw($prompts_path, prompt_line(session_id => $sid, agent_id => 'main', message => 'main session prompt'));

    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile) // '';
    my $err = slurp($errfile) // '';
    unlink $outfile, $errfile;

    is($rc, 3, 'AC-11 (B12-main, Decision 40): a same-session agent_id=main line DOES trigger exit code 3');
    my @l = lines_of($out);
    is($l[-1] // '', 'PROMPT main: main session prompt',
        'AC-11 (B12-main, Decision 40): the exact PROMPT line names "main" and the message, per Decision 9\'s "<agent_id or main>" convention');
    ok(!(grep { /^released:/ } @l), 'AC-11 (B12-main): no "released:" line follows the PROMPT exit');
    is($err, '', 'AC-11 (B12-main): stderr is empty');
}

# ===========================================================================
# AC-11 (non-ASCII PROMPT message) -- the red-team and reviewer found
# butler-hold.pl's PROMPT line printed inconsistently: Latin-1 bytes for
# characters <= U+00FF, UTF-8 bytes for wider characters, under :raw STDOUT
# (a single character like U+00E9 reproduced as the raw byte 0xE9 instead of
# its 2-byte UTF-8 encoding 0xC3 0xA9). A prompt message with a non-ASCII
# character in that <= U+00FF range must still come out as valid,
# correctly-encoded UTF-8 bytes on stdout.
# ===========================================================================
{
    my $sid = next_sid();
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $tp = "$project/$sid.jsonl";
    write_transcript($tp);
    write_ticket_for($sid, ['U1'], transcript_path => $tp, cwd => $project);

    my $prompts_path = "$data/.drive-solo/prompts.jsonl";

    my ($pid, $outfile, $errfile) = spawn_hold(['U1'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2, CCPRAXIS_DATA_DIR => $data });
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'AC-11 (non-ASCII PROMPT): precondition -- the holder became');

    # "café" -- the 'e' with acute accent is U+00E9, the red-team's exact
    # reproduced case (mis-encodes to the raw byte 0xE9 under the current bug).
    my $msg = "need permission for caf\x{e9}";
    append_raw($prompts_path, prompt_line(session_id => $sid, agent_id => 'sub-nonascii-1', message => $msg));

    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out_bytes = slurp($outfile) // '';
    unlink $outfile, $errfile;

    is($rc, 3, 'AC-11 (non-ASCII PROMPT): exits 3 for the qualifying line with a non-ASCII message');

    my $decoded = eval { Encode::decode('UTF-8', $out_bytes, Encode::FB_CROAK) };
    ok(!$@ && defined $decoded,
        'AC-11 (non-ASCII PROMPT): stdout is valid, correctly-encoded UTF-8 bytes (not Latin-1 or mixed encoding)');

    my @l = lines_of($decoded // '');
    is($l[-1] // '', "PROMPT sub-nonascii-1: need permission for caf\x{e9}",
        'AC-11 (non-ASCII PROMPT): the decoded PROMPT line names the agent and the message with the correct character');
}

# ===========================================================================
# AC-12 (B13) -- EXTEND re-base: a qualifying line appended before an EXTEND
# the holder had not yet read is skipped; one appended AFTER the EXTEND
# triggers the exit, naming the NEW agent.
# ===========================================================================
{
    my $sid = next_sid();
    my $data = fresh_existing_data_dir();
    my $project = fresh_dir(); make_path($project);
    my $tp = "$project/$sid.jsonl";
    write_transcript($tp);
    write_ticket_for($sid, ['E1'], transcript_path => $tp, cwd => $project);

    my ($pid, $outfile, $errfile) = spawn_hold(['E1'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 8, CCPRAXIS_DATA_DIR => $data });
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'AC-12: precondition -- the holder became (slow 8s tick)');

  SKIP: {
    skip 'AC-12: holder never became', 1 unless defined $h;

    my $prompts_path = "$data/.drive-solo/prompts.jsonl";
    # Right after the record appears: append a qualifying line for a "stale" agent...
    append_raw($prompts_path, prompt_line(session_id => $sid, agent_id => 'stale-agent-1', message => 'stale, pre-extend prompt'));

    # ...then a foreground EXTEND, which should re-base the read offset to
    # the file's end at that moment (Decision 11 (10)) -- so the stale line
    # above is skipped, never read from a fresh 0 offset.
    write_ticket_for($sid, ['E2'], transcript_path => $tp, cwd => $project);
    my ($ext_pid, $ext_out, $ext_err) = spawn_hold(['E2'],
        { BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2, CCPRAXIS_DATA_DIR => $data });
    my $ext_deadline = time() + 15;
    my $extended_seen = 0;
    my $ext_rc;
    while (time() < $ext_deadline) {
        my $txt = slurp($ext_out) // '';
        if ($txt =~ /extended the running holder/) { $extended_seen = 1; last }
        my $w = waitpid($ext_pid, WNOHANG);
        if ($w == $ext_pid) { $ext_rc = $? >> 8; @KILL_PIDS = grep { $_ != $ext_pid } @KILL_PIDS; last }
        sleep(0.05);
    }
    unless (defined $ext_rc) {
        # if the extender process itself is still alive, reap it now
        if (kill(0, $ext_pid)) { ($ext_rc) = (reap_and_log($ext_pid, $ext_out, $ext_err))[2] }
    }
    unlink $ext_out, $ext_err if -e $ext_out;

  SKIP: {
    skip "AC-12: extend line never observed (extreme load) -- $ext_rc", 3 unless $extended_seen;

    ok(kill(0, $pid), 'AC-12: the original holder is still alive right after the extend');

    # Append a NEW qualifying line -- should be the one that fires.
    append_raw($prompts_path, prompt_line(session_id => $sid, agent_id => 'fresh-agent-2', message => 'fresh, post-extend prompt'));

    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile) // '';
    unlink $outfile, $errfile;

    if ($rc == 3) {
        my @l = lines_of($out);
        is($l[-1] // '', 'PROMPT fresh-agent-2: fresh, post-extend prompt',
            'AC-12: the exit names the NEW (post-extend) agent, not the stale pre-extend one');
    } else {
        skip 'AC-12: the holder exited with code 3 before the extends record write landed (extreme load only)', 1
            if 0;   # placeholder branch kept for clarity; real assertion below always runs
        is($rc, 3, 'AC-12: exits 3 for the post-extend qualifying line');
    }
  }
  }
}

# ===========================================================================
# AC-13 (B14) -- watching OFF (CCPRAXIS_DATA_DIR names a nonexistent dir):
# holder behaviour is unaffected by an appended qualifying line -- it stays
# alive for at least 5 ticks, then ends by its normal (deadline) path.
# ===========================================================================
{
    my $sid = next_sid();
    my $project = fresh_dir(); make_path($project);
    my $tp = "$project/$sid.jsonl";
    write_transcript($tp);
    write_ticket_for($sid, ['OFF1'], transcript_path => $tp, cwd => $project);
    my $missing_data = fresh_dir() . '/does-not-exist';

    my ($pid, $outfile, $errfile) = spawn_hold(['OFF1'],
        { BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2, CCPRAXIS_DATA_DIR => $missing_data });
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'AC-13: precondition -- the holder became with watching OFF');

    # Try to append a "qualifying" line directly under the (nonexistent) data
    # root -- since it does not exist, make the dir first only to prove even
    # a real file there is never consulted when CCPRAXIS_DATA_DIR itself
    # named a path that did not exist at holder start.
    make_path("$missing_data/.drive-solo");
    append_raw("$missing_data/.drive-solo/prompts.jsonl",
        prompt_line(session_id => $sid, agent_id => 'should-be-ignored', message => 'should never fire'));

    sleep(1.2);   # >= 5 ticks at 0.2s
    ok(kill(0, $pid), 'AC-13: the holder is still alive after several ticks -- watching OFF ignores the line');

    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile) // '';
    unlink $outfile, $errfile;
    is($rc, 0, 'AC-13: the holder ends via its normal (deadline) path, exit 0 -- unaffected by prompt watching');
    ok(!(grep { /^PROMPT /m } lines_of($out)), 'AC-13: no PROMPT line was ever printed');
}

# ===========================================================================
# AC-14 (B15) -- bp-denials summary: exact output on a fixture file; usage on
# bad argv; the zero-record/no-file case.
# ===========================================================================
{
    my $data = fresh_existing_data_dir();
    make_path("$data/.drive-solo");
    my $path = "$data/.drive-solo/denials.jsonl";
    my $j = JSON::PP->new->utf8->canonical;
    append_raw($path, $j->encode({ ts => '2026-01-01T00:00:00Z', session_id => 's1', agent_id => 'a1',
        tool_name => 'Bash', tool_input => 'rm -rf x', tool_input_truncated => JSON::PP::false, reason => 'r' }) . "\n");
    append_raw($path, $j->encode({ ts => '2026-01-01T00:00:01Z', session_id => 's1', agent_id => 'a1',
        tool_name => 'Bash', tool_input => 'rm y', tool_input_truncated => JSON::PP::false, reason => 'r' }) . "\n");
    append_raw($path, $j->encode({ ts => '2026-01-01T00:00:02Z', session_id => 's1', agent_id => 'main',
        tool_name => 'Bash', tool_input => '  git status', tool_input_truncated => JSON::PP::false, reason => 'r' }) . "\n");
    append_raw($path, $j->encode({ ts => '2026-01-01T00:00:03Z', session_id => 's1', agent_id => 'main',
        tool_name => 'Write', tool_input => '{}', tool_input_truncated => JSON::PP::false, reason => 'r' }) . "\n");
    append_raw($path, "{ this is not valid json\n");
    append_raw($path, $j->encode({ ts => '2026-01-01T00:00:04Z', session_id => 's1', agent_id => 'a1',
        tool_name => 'Bash', tool_input => 'rm partial' }));   # no trailing "\n" -- partial last line

    ok(-f $BP_DENIALS_PL, 'AC-14 precondition: bp-denials.pl exists') or diag('not yet implemented');
    SKIP: {
        skip 'AC-14: bp-denials.pl does not exist yet', 3 unless -f $BP_DENIALS_PL;
        my ($rc, $out, $err) = run_hook_perl($BP_DENIALS_PL, ['summary'], { CCPRAXIS_DATA_DIR => $data });
        my $expect = "denials: 4\n" .
                     "by agent:\n" .
                     "  2 a1\n" .
                     "  2 main\n" .
                     "by command:\n" .
                     "  2 Bash rm\n" .
                     "  1 Bash git\n" .
                     "  1 Write\n";
        is($out, $expect, 'AC-14: exact summary output on the fixture file');
        is($rc, 0, 'AC-14: exit 0');
        is($err, '', 'AC-14: stderr empty on success');
    }

    SKIP: {
        skip 'AC-14: bp-denials.pl does not exist yet', 6 unless -f $BP_DENIALS_PL;
        for my $bad_argv ([], ['bogus'], ['summary', 'extra']) {
            my ($rc, $out, $err) = run_hook_perl($BP_DENIALS_PL, $bad_argv, { CCPRAXIS_DATA_DIR => $data });
            is($rc, 2, 'AC-14: argv [' . join(',', @$bad_argv) . '] exits 2');
            is($out, '', 'AC-14: argv [' . join(',', @$bad_argv) . '] -- empty stdout');
        }
    }

    SKIP: {
        skip 'AC-14: bp-denials.pl does not exist yet', 2 unless -f $BP_DENIALS_PL;
        my $empty_data = fresh_existing_data_dir();
        my ($rc, $out, $err) = run_hook_perl($BP_DENIALS_PL, ['summary'], { CCPRAXIS_DATA_DIR => $empty_data });
        is($rc, 0, 'AC-14: missing-file case exits 0');
        is($out, "denials: 0\nby agent:\nby command:\n", 'AC-14: missing-file case prints denials: 0 plus both headers');
    }
}

# run_hook_perl($script, \@argv, \%env) -> ($rc, $out, $err). Bounded, no
# in-memory STDOUT reopen (Git-for-Windows perl fails that with "Bad file
# descriptor").
sub run_hook_perl {
    my ($script, $argv, $env) = @_;
    my (undef, $out_path) = tempfile(DIR => $TMPROOT);
    my (undef, $err_path) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        for my $k (keys %$env) {
            if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
        }
        open(STDOUT, '>:raw', $out_path) or POSIX::_exit(126);
        open(STDERR, '>:raw', $err_path) or POSIX::_exit(126);
        exec($^X, $script, @$argv);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($out_path) // '';
    my $err = slurp($err_path) // '';
    unlink $out_path, $err_path;
    return ($rc, $out, $err);
}

# ===========================================================================
# AC-15 (B16) -- bp-drive-next.pl's done action carries denials: N, equal to
# bp-denials summary's count for the same data dir (0 without a file).
# ===========================================================================
{
    my $J = JSON::PP->new->canonical;

    sub _pw_make_bp_dir {
        my ($data, $name, $pkgs) = @_;
        my $bp = "$data/blueprints/$name";
        make_path("$bp/packages");
        my $md = "# $name\n\n## Package status\n\n"
               . "| pkg | deliverable | depends_on | model | status |\n"
               . "|-----|-------------|------------|-------|--------|\n";
        for my $p (@$pkgs) {
            $md .= "| $p->{key} | thing | \xE2\x80\x94 | sonnet | $p->{status} |\n";
        }
        open my $bfh, '>:raw', "$bp/blueprint.md" or die $!;
        print $bfh $md; close $bfh;
        for my $p (@$pkgs) {
            open my $lfh, '>:raw', "$bp/packages/$p->{key}.md" or die $!;
            print $lfh "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
                     . "model: sonnet\nmax_turns: 80\nwrite_set: x/\n"
                     . "test_paths: x/\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $p->{key}\n";
            close $lfh;
        }
        return $bp;
    }

    my $LOADED = do { local $@; eval { require $DRIVE_NEXT_PL }; !$@ };
    ok($LOADED, 'AC-15 precondition: bp-drive-next.pl loads') or diag($@);

    SKIP: {
        skip 'AC-15: bp-drive-next.pl did not load', 2 unless $LOADED;

        for my $with_denials (1, 0) {
            my $data = tempdir(DIR => $TMPROOT, CLEANUP => 1); $data =~ s{\\}{/}g;
            # Mirrors drive-next.t's own AC-6 fixture exactly: a lone
            # already-done blueprint reports "blueprint-done" on the call
            # that settles it, not "done" -- two blueprints (one done, one
            # parked) are needed so the SCOPE resolves to nothing further.
            _pw_make_bp_dir($data, 'bp-a', [{ key => 'p1', status => 'done' }]);
            _pw_make_bp_dir($data, 'bp-b', [{ key => 'p1', status => 'pending' }]);
            my $dsdir = "$data/.drive-solo"; make_path($dsdir);
            open my $ofh, '>:raw', "$dsdir/order.json" or die $!;
            print $ofh $J->encode({ order => ['bp-a', 'bp-b'], recorded_at => 1_830_297_600 });
            close $ofh;
            open my $afh, '>:raw', "$dsdir/announced.json" or die $!;
            print $afh $J->encode({ announced => ['bp-a'] });
            close $afh;
            open my $pfh, '>:raw', "$dsdir/parks.json" or die $!;
            print $pfh $J->encode([{ blueprint => 'bp-b', reason => 'out of scope', at => 1_830_297_600 }]);
            close $pfh;

            my $expect_n = 0;
            if ($with_denials) {
                my $jj = JSON::PP->new->utf8->canonical;
                append_raw("$dsdir/denials.jsonl", $jj->encode({ ts => 't', session_id => 's', agent_id => 'a1',
                    tool_name => 'Bash', tool_input => 'x', tool_input_truncated => JSON::PP::false, reason => 'r' }) . "\n");
                append_raw("$dsdir/denials.jsonl", $jj->encode({ ts => 't', session_id => 's', agent_id => 'a1',
                    tool_name => 'Bash', tool_input => 'y', tool_input_truncated => JSON::PP::false, reason => 'r' }) . "\n");
                $expect_n = 2;
            }

            my ($ofh2, $out_path) = tempfile(DIR => $TMPROOT);
            my ($efh2, $err_path) = tempfile(DIR => $TMPROOT);
            close $ofh2; close $efh2;
            open my $oldout, '>&STDOUT' or die $!;
            open my $olderr, '>&STDERR' or die $!;
            open STDOUT, '>:raw', $out_path or die $!;
            open STDERR, '>:raw', $err_path or die $!;
            $| = 1;
            my $rc = eval {
                BpDrive::run(['next', '--scope', 'all'], {
                    data_dir => $data,
                    now                   => sub { 1_830_297_600 },
                    verdict               => sub { { action => 'ok' } },
                    spawn                 => sub { },
                    kill_pid              => sub { },
                    powershell_available  => sub { 0 },
                });
            };
            my $die_err = $@;
            open STDOUT, '>&', $oldout or die $!;
            open STDERR, '>&', $olderr or die $!;
            close $oldout; close $olderr;
            my $out = slurp($out_path) // '';
            unlink $out_path, $err_path;
            diag("AC-15: BpDrive::run died: $die_err") if $die_err;

            chomp(my $line = $out);
            my $act = eval { $J->decode($line) };
            my $label = $with_denials ? 'with a denials.jsonl file' : 'without a denials.jsonl file';
            ok(ref $act eq 'HASH' && ($act->{action} // '') eq 'done', "AC-15: $label -- action is done");
            SKIP: {
                skip "AC-15: $label -- no action to inspect", 1 unless ref $act eq 'HASH';
                is($act->{denials}, $expect_n, "AC-15: $label -- denials equals $expect_n");
            }
        }
    }
}

# ===========================================================================
# guard: the real ~/.claude/butler-state and the repo's own
# .ccpraxis-local-data are untouched by this whole file.
# ===========================================================================
if (defined $REAL_BSTATE) {
    is(($REAL_BSTATE_EXISTS ? 1 : 0), (-d $REAL_BSTATE ? 1 : 0),
        'guard: the real ~/.claude/butler-state existence is unchanged by this whole file');
    if ($REAL_BSTATE_EXISTS) {
        is((stat($REAL_BSTATE))[9], $REAL_BSTATE_MTIME, 'guard: the real ~/.claude/butler-state mtime is unchanged');
    }
}
if (defined $REAL_DATA) {
    is(($REAL_DATA_EXISTS ? 1 : 0), (-d $REAL_DATA ? 1 : 0),
        'guard: the repos own .ccpraxis-local-data existence is unchanged by this whole file');
}

done_testing();
