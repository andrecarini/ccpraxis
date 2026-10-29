#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 19 (blueprint hook-continuity-remake),
# AC-1..AC-33 of specs/19-fork-guard-spec.md sec 4: a new PreToolUse deny
# rule on every Agent/Task dispatch whose tool_input.subagent_type is the
# literal string "fork", overridable exactly once per session by a CLI that
# records a reason.
#
# hooks/guard-fork.sh, BpHook/Guards/GuardFork.pm, scripts/butler-fork-ok.pl,
# bin/butler-fork-ok and the BpHook.pm one-line ticket-name change (Decision
# 91) DO NOT EXIST YET. Every in-process call goes through
# GuardHarness::run_module(), which fails open (rc 0) exactly as the real
# wrapper would when the module is missing -- legibly, never a crash in this
# file. Every wrapper/shim/CLI case spawns a real subprocess and gets a
# plain "No such file" until the implementer writes each piece.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above, never from reading any file this package's write set would create
# or edit.
#
# EDITED for package 28 (fork-guard-bash-cost): butler-fork-ok ticket writes
# moved from GuardFork's Bash branch to ContinuityOffCheck, so cases that
# exercise that write now go through tw() (ContinuityOffCheck) rather than
# gf() (GuardFork). This oracle's sha goes stale on purpose.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Glob qw(bsd_glob);
use File::Spec ();
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use Encode ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

(my $BUTLER_DIR = dirname(__FILE__) . '/../..') =~ s{\\}{/}g;
my $SCRIPTS_DIR   = "$BUTLER_DIR/scripts";
my $HOOKS_DIR     = "$BUTLER_DIR/hooks";
my $HOOKS_JSON    = "$HOOKS_DIR/hooks.json";
my $ARCH_DOC      = "$BUTLER_DIR/docs/hook-architecture.md";
my $GUARD_SH      = "$HOOKS_DIR/guard-fork.sh";
my $GUARD_PM      = "$SCRIPTS_DIR/BpHook/Guards/GuardFork.pm";
my $CLI_PL        = "$SCRIPTS_DIR/butler-fork-ok.pl";
my $CLI_BIN       = "$BUTLER_DIR/bin/butler-fork-ok";

my $REAL_BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH;
my $REAL_TIMEOUT = do { my $p = `bash -c "command -v timeout"`; chomp $p;
    # macOS has no GNU timeout: fall back to the repo's pure-perl stand-in
    # (scripts/run-tests.pl already puts it on PATH for a sweep).
    unless (length $p) { (my $d = __FILE__) =~ s{[^/\\]+\z}{}; my $s = "${d}../../../../scripts/test-bin/timeout"; $p = $s if -x $s; }
    $p };
BAIL_OUT('cannot resolve a real timeout utility on PATH') unless length $REAL_TIMEOUT;

# ---------------------------------------------------------------------------
# the exact deny text (spec 2.3.2), and the CLI's fixed lines (spec 2.6).
# ---------------------------------------------------------------------------
my @DENY_LINES = (
    q{Fork refused: a fork inherits this whole conversation and the parent's identity, and an agent that forked instead of dispatching once broke things.},
    q{Launch a fresh, context-free subagent (for example general-purpose) with a self-contained prompt instead.},
    q{If a fork is truly needed, first run: butler-fork-ok --reason '<why a fresh subagent will not do>' (allows one fork).},
);
my $DENY_TEXT = join('', map { "$_\n" } @DENY_LINES);

my $STEP1 = q{butler-fork-ok: usage: butler-fork-ok --reason '<why a fresh subagent will not do>'};
my $STEP2 = q{butler-fork-ok: --reason needs at least two words and 10 characters saying why.};
my $STEP3 = q{butler-fork-ok: no continuity state directory (set HOME, or an absolute BUTLER_STATE_DIR).};
my $STEP4 = q{butler-fork-ok: no session binding; run it as its own command with the reason in single quotes.};
my $STEP5 = q{butler-fork-ok: only the main session records a fork override.};
my $STEP6 = q{butler-fork-ok: could not record the override; nothing was recorded.};
my $STEP8 = q{butler-fork-ok: recorded; the next fork dispatch in this session is allowed once.};

# ---------------------------------------------------------------------------
# payload builders (spec 4: session ids/tool_use_ids/cwd/transcript paths
# never carry the substring "fork" except where an AC needs it -- none do).
# ---------------------------------------------------------------------------
sub payload_fork {
    my (%o) = @_;
    my $p = { hook_event_name => ($o{hook_event_name} // 'PreToolUse') };
    $p->{tool_name} = $o{tool_name} if exists $o{tool_name};
    if (exists $o{tool_input_override}) {
        $p->{tool_input} = $o{tool_input_override};
    }
    else {
        my $ti = { description => 'a task description', prompt => 'a self-contained prompt' };
        $ti->{subagent_type} = $o{subagent_type} if exists $o{subagent_type};
        $p->{tool_input} = $ti;
    }
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{tool_use_id}     = $o{tool_use_id}      if exists $o{tool_use_id};
    $p->{cwd}             = $o{cwd}              if exists $o{cwd};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    return $p;
}

sub payload_bash {
    my (%o) = @_;
    my $ti = { command => $o{cmd} };
    $ti->{run_in_background} = $o{run_in_background} if exists $o{run_in_background};
    my $p = { hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => $ti };
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{tool_use_id}     = $o{tool_use_id}      if exists $o{tool_use_id};
    $p->{cwd}             = $o{cwd}              if exists $o{cwd};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    return $p;
}

sub gf {
    my ($p, %env) = @_;
    return GuardHarness::run_module('Guards::GuardFork', $p, env => \%env);
}

# package 28: butler-fork-ok ticket writing moved to ContinuityOffCheck.
sub tw {
    my ($p, %env) = @_;
    return GuardHarness::run_module('ContinuityOffCheck', $p, env => \%env);
}

# ---------------------------------------------------------------------------
# CLI spawn helpers -- $^X direct (spec 4's "CLI calls spawn $^X ...
# argv as a list, no shell re-quoting"), and a bash spawn of the extensionless
# shim for AC-33. Both bounded by the real "timeout" utility, output captured
# through File::Temp files.
# ---------------------------------------------------------------------------
# _spawn_captured(\@cmd) -- list-form system() (no shell, so no re-quoting
# of a reason argument), bounded by the real "timeout" utility, with this
# PROCESS's own STDOUT/STDERR dup'd out and back around the call (the same
# technique GuardHarness::run_module uses in-process, applied here around a
# real subprocess) -- never fork()/exec(), which Windows perl does not
# support as a real subprocess primitive.
sub _spawn_captured {
    my (@cmd) = @_;
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();
    open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $out_path) or die "redirect STDOUT: $!";
    open(STDERR, '>', $err_path) or die "redirect STDERR: $!";
    system($REAL_TIMEOUT, 10, @cmd);
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or die "restore STDERR: $!";
    close $saved_out;
    close $saved_err;
    my $out = GuardHarness::read_bytes($out_path);
    my $err = GuardHarness::read_bytes($err_path);
    unlink $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err };
}

sub run_cli     { my (@args) = @_; return _spawn_captured($^X, $CLI_PL, @args) }
sub run_cli_bin { my (@args) = @_; return _spawn_captured($REAL_BASH, $CLI_BIN, @args) }

sub quoted_argv { return join(' ', map { /^-/ ? $_ : "'$_'" } @_) }

# ---------------------------------------------------------------------------
# raw ticket / token scaffolding -- derived from spec 2.2's exact path and
# key formula, so edge cases (a stale/malformed/foreign record) can be
# fixtured without depending on GuardFork's own writer existing yet.
# ---------------------------------------------------------------------------
sub ticket_dir_for {
    my ($base, $argv) = @_;
    my $k = sha1_hex(join("\0", 'butler-fork-ok', @$argv));
    return "$base/continuity/tickets/$k";
}

sub write_raw_ticket {
    my ($base, $sid, $tuid, $argv, %f) = @_;
    my $dir = ticket_dir_for($base, $argv);
    make_path($dir);
    my $rec = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        agent_id        => $f{agent_id},
        operator        => JSON::PP::false(),
        background      => JSON::PP::false(),
        transcript_path => $f{transcript_path},
        cwd             => $f{cwd},
        at              => ($f{at} // time()),
    };
    my $path = "$dir/$sid.$tuid.json";
    open(my $fh, '>:raw', $path) or die "cannot write fixture ticket: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec);
    close $fh;
    return $path;
}

sub write_raw_token {
    my ($base, $sid, $content) = @_;
    my $dir = "$base/continuity/fork-ok";
    make_path($dir);
    my $path = "$dir/$sid.json";
    open(my $fh, '>:raw', $path) or die "cannot write fixture token: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub find_ticket_files { my ($base) = @_; return sort(bsd_glob("$base/continuity/tickets/*/*.json")) }

# ===========================================================================
# AC-1 / AC-2 / AC-3 -- Agent (and Task) fork dispatch, no token -> deny,
# exact text, budget and vocabulary.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                               session_id => 'sess-a1', tool_use_id => 'T1'));
    is($res->{rc}, 2, 'AC-1: Agent fork dispatch, no token -> rc 2');
    is($res->{err}, $DENY_TEXT, 'AC-1: stderr equals the 2.3.2 text exactly');
    is($res->{out}, '', 'AC-1: stdout empty');
}
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res = gf(payload_fork(tool_name => 'Task', subagent_type => 'fork',
                               session_id => 'sess-a2', tool_use_id => 'T1'));
    is($res->{rc}, 2, 'AC-2: Task fork dispatch, no token -> rc 2 (same as Agent)');
    is($res->{err}, $DENY_TEXT, 'AC-2: same deny text');
}
{
    for my $i (0 .. $#DENY_LINES) {
        cmp_ok(length($DENY_LINES[$i]), '<=', 160, "AC-3: deny line $i is at most 160 characters");
    }
    like($DENY_TEXT, qr/\bfresh\b/,   'AC-3: deny text names "fresh"');
    like($DENY_TEXT, qr/\bsubagent\b/, 'AC-3: deny text names "subagent"');
    like($DENY_TEXT, qr/\binherits\b/, 'AC-3: deny text names "inherits"');
    like($DENY_TEXT, qr/butler-fork-ok --reason/, 'AC-3: deny text names the override command');
}

# ===========================================================================
# AC-4 / AC-5 -- everything that must allow, and leave no state.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    for my $st (qw(general-purpose Explore), 'butler:bp-implementer', 'Fork', ' fork') {
        my $res = gf(payload_fork(tool_name => 'Agent', subagent_type => $st,
                                   session_id => 'sess-a4', tool_use_id => 'T1'));
        is($res->{rc}, 0, "AC-4: subagent_type '$st' -> rc 0");
        is($res->{out}, '', "AC-4: subagent_type '$st' -> empty stdout");
        is($res->{err}, '', "AC-4: subagent_type '$st' -> empty stderr");
    }
    my $S = BpHook::state_dir();
    ok(!-e "$S/fork-ok", 'AC-4: no fork-ok directory was created');
    ok(!-e "$S/tickets", 'AC-4: no tickets directory was created');
}
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my @cases = (
        ['no subagent_type at all' => payload_fork(tool_name => 'Agent', session_id => 'sess-a5', tool_use_id => 'T1')],
        ['subagent_type is an array' => payload_fork(tool_name => 'Agent', subagent_type => ['fork'], session_id => 'sess-a5', tool_use_id => 'T1')],
        ['subagent_type is the number 1' => payload_fork(tool_name => 'Agent', subagent_type => 1, session_id => 'sess-a5', tool_use_id => 'T1')],
        ['subagent_type is JSON null' => payload_fork(tool_name => 'Agent', subagent_type => undef, session_id => 'sess-a5', tool_use_id => 'T1')],
        ['tool_input is a bare string' => payload_fork(tool_name => 'Agent', tool_input_override => 'fork', session_id => 'sess-a5', tool_use_id => 'T1')],
    );
    for my $c (@cases) {
        my ($label, $p) = @$c;
        my $res = gf($p);
        is($res->{rc}, 0, "AC-5: $label -> rc 0");
        is($res->{out} . $res->{err}, '', "AC-5: $label -> no output");
    }
}

# ===========================================================================
# AC-6 -- a fork dispatch carrying agent_id (a subagent) is denied exactly
# the same as the main thread.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', agent_id => 'ag1',
                               session_id => 'sess-a6', tool_use_id => 'T1'));
    is($res->{rc}, 2, 'AC-6: a fork dispatch from a subagent (agent_id set) -> rc 2');
    is($res->{err}, $DENY_TEXT, 'AC-6: same deny text as the main thread');
}

# ===========================================================================
# AC-7 -- CLI, no args.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $res = run_cli();
    is($res->{rc}, 1, 'AC-7: CLI with no args -> exit 1');
    is($res->{out}, "$STEP1\n", 'AC-7: stdout is exactly the step-1 line');
    is($res->{err}, '', 'AC-7: stderr empty');
    ok(!-e "$S/fork-ok", 'AC-7: nothing recorded (no fork-ok dir)');
    ok(!-e "$S/reasons.log", 'AC-7: nothing recorded (no reasons.log)');
}

# ===========================================================================
# AC-8 -- bad --reason shapes, each preceded by a ticket for its exact argv.
# ===========================================================================
{
    for my $c (
        ['--reason'],
        ['--reason', ''],
        ['--reason', '   '],
        ['--reason', 'short'],
        ['--reason', 'a b'],
    ) {
        local %ENV = %ENV;
        my $base = GuardHarness::fresh_state();
        my $S = BpHook::state_dir();
        my $argv = $c;
        tw(payload_bash(cmd => "butler-fork-ok " . quoted_argv(@$argv),
                         session_id => 'sess-a8', tool_use_id => 'T1', cwd => '/proj'));
        my $res = run_cli(@$argv);
        my $label = "AC-8: --reason " . join(' ', map { "'$_'" } @$argv[1..$#$argv]);
        is($res->{rc}, 1, "$label -> exit 1");
        is($res->{out}, "$STEP2\n", "$label -> the step-2 line");
        ok(!-e "$S/fork-ok/sess-a8.json", "$label -> nothing recorded");
    }
}

# ===========================================================================
# AC-9 -- shapes that never even reach step 2 (usage failures).
# ===========================================================================
{
    for my $c (
        ['--reason=why this matters'],
        ['--reason', 'x y z w q r', '--force'],
        ['--why', 'x y z w q r'],
    ) {
        local %ENV = %ENV;
        my $base = GuardHarness::fresh_state();
        my $S = BpHook::state_dir();
        my $res = run_cli(@$c);
        is($res->{rc}, 1, 'AC-9: malformed argv -> exit 1') or diag("argv: @$c");
        is($res->{out}, "$STEP1\n", 'AC-9: the step-1 line');
        ok(!-e "$S/fork-ok", 'AC-9: nothing recorded');
    }
}

# ===========================================================================
# AC-10 -- the happy path, end to end.
# ===========================================================================
my ($AC10_BASE, $AC10_S, $AC10_CWD, $AC10_REASON);
{
    local %ENV = %ENV;
    $AC10_BASE = GuardHarness::fresh_state();
    $AC10_S = BpHook::state_dir();
    my $tmp = tempdir(CLEANUP => 1);
    (my $cwd = $tmp) =~ s{\\}{/}g;
    $AC10_CWD = $cwd;
    my $reason = q{needs the parent conversation verbatim};
    $AC10_REASON = $reason;

    my $mres = tw(payload_bash(cmd => "butler-fork-ok --reason '$reason'",
                                session_id => 'A', tool_use_id => 'T1', cwd => $cwd));
    is($mres->{rc}, 0, 'AC-10: run_module on the Bash dispatch -> rc 0');
    is($mres->{out} . $mres->{err}, '', 'AC-10: ...and no output');

    my @tfiles = find_ticket_files($AC10_BASE);
    is(scalar(@tfiles), 1, 'AC-10: exactly one file under $S/tickets/*/');
    SKIP: {
        skip 'AC-10: no ticket file to inspect', 2 unless @tfiles;
        my $rec = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes($tfiles[0])) };
        is(ref($rec) eq 'HASH' ? $rec->{session_id}  : undef, 'A',  'AC-10: ticket session_id is A');
        is(ref($rec) eq 'HASH' ? $rec->{tool_use_id} : undef, 'T1', 'AC-10: ticket tool_use_id is T1');
    }

    my $cres = run_cli('--reason', $reason);
    is($cres->{rc}, 0, 'AC-10: CLI --reason <valid> -> exit 0');
    is($cres->{out}, "$STEP8\n", 'AC-10: the step-8 line');

    my $token_path = "$AC10_S/fork-ok/A.json";
    ok(-f $token_path, 'AC-10: a token file exists for session A')
        or diag("expected: $token_path");
    SKIP: {
        skip 'AC-10: no token file to inspect', 3 unless -f $token_path;
        my $tok = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes($token_path)) };
        is(ref($tok) eq 'HASH' ? $tok->{session_id} : undef, 'A', 'AC-10: token session_id is A');
        is(ref($tok) eq 'HASH' ? $tok->{reason}     : undef, $reason, 'AC-10: token reason matches');
        like(ref($tok) eq 'HASH' ? ($tok->{at} // '') : '', qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
             'AC-10: token "at" matches the ISO-8601 shape');
    }
    my @tf10 = find_ticket_files($AC10_BASE);
    is(scalar(@tf10), 0, 'AC-10: the ticket file is gone after the CLI call');
}

# ===========================================================================
# AC-11 -- the reasons.log line left by AC-10.
# ===========================================================================
{
    my $log = "$AC10_S/reasons.log";
    ok(-f $log, 'AC-11: reasons.log exists') or diag("expected: $log");
    SKIP: {
        skip 'AC-11: no reasons.log to inspect', 1 unless -f $log;
        my @lines = grep { length } split /\n/, GuardHarness::read_bytes($log);
        is(scalar(@lines), 1, 'AC-11: exactly one new line');
        SKIP: {
            skip 'AC-11: no line to split', 1 unless @lines;
            my @f = split /\t/, $lines[0];
            is_deeply([ @f[1..3] ], ['A', 'agent', 'fork-ok'],
                'AC-11: fields 2-4 are session, actor, verb (field 1 is the ISO time)') if @f >= 6;
            is($f[4], $AC10_CWD, 'AC-11: field 5 is the project/cwd') if @f >= 6;
            is($f[5], $AC10_REASON, 'AC-11: field 6 is the reason') if @f >= 6;
        }
    }
}

# ===========================================================================
# AC-12 -- the token from AC-10 allows exactly one fork, then denies the next.
# ===========================================================================
{
    local %ENV = %ENV;
    $ENV{BUTLER_STATE_DIR} = $AC10_BASE;
    my $res1 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'A', tool_use_id => 'T2'));
    is($res1->{rc}, 0, 'AC-12: fork dispatch after recording -> rc 0');
    is($res1->{out} . $res1->{err}, '', 'AC-12: no output');
    ok(!-f "$AC10_S/fork-ok/A.json", 'AC-12: the token file is gone');

    my $res2 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'A', tool_use_id => 'T3'));
    is($res2->{rc}, 2, 'AC-12: the next fork in the same session -> rc 2');
    is($res2->{err}, $DENY_TEXT, 'AC-12: the deny text');
}

# ===========================================================================
# AC-13 -- a token never crosses sessions.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    write_raw_token($base, 'A', JSON::PP->new->utf8->canonical->encode(
        { session_id => 'A', reason => 'needs parent context', at => '2026-01-01T00:00:00Z' }));

    my $resB = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'B', tool_use_id => 'T1'));
    is($resB->{rc}, 2, "AC-13: session B's fork dispatch denies while only A holds a token");
    ok(-f "$S/fork-ok/A.json", "AC-13: A's token file remains");

    my $resA = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'A', tool_use_id => 'T2'));
    is($resA->{rc}, 0, "AC-13: session A's own fork dispatch then allows");
}

# ===========================================================================
# AC-14 -- CLI with a valid reason but no ticket at all.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $res = run_cli('--reason', 'needs the parent context here');
    is($res->{rc}, 1, 'AC-14: CLI, valid reason, no ticket -> exit 1');
    is($res->{out}, "$STEP4\n", 'AC-14: the step-4 line');
    ok(!-e "$S/fork-ok", 'AC-14: nothing recorded');
}

# ===========================================================================
# AC-15 -- two sessions' tickets for the identical argv -> ambiguous -> the
# CLI refuses for both.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason = 'needs parent context badly';
    for my $sid ('A', 'B') {
        tw(payload_bash(cmd => "butler-fork-ok --reason '$reason'",
                         session_id => $sid, tool_use_id => 'T1', cwd => '/proj'));
    }
    my $res = run_cli('--reason', $reason);
    is($res->{rc}, 1, 'AC-15: identical-argv tickets for A and B -> CLI exit 1');
    is($res->{out}, "$STEP4\n", 'AC-15: the step-4 line');
    ok(!-e "$S/fork-ok/A.json", 'AC-15: no token for A');
    ok(!-e "$S/fork-ok/B.json", 'AC-15: no token for B');
}

# ===========================================================================
# AC-16 -- a ticket older than the core's 30s window.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    write_raw_ticket($base, 'A', 'T1', ['--reason', 'a stale ticket reason'],
        at => (time() - 31), cwd => '/proj');
    my $res = run_cli('--reason', 'a stale ticket reason');
    is($res->{rc}, 1, 'AC-16: a ticket older than 30s -> CLI exit 1');
    is($res->{out}, "$STEP4\n", 'AC-16: the step-4 line');
    ok(!-e "$S/fork-ok", 'AC-16: nothing recorded');
}

# ===========================================================================
# AC-17 -- a ticket carrying agent_id (a subagent) is refused at step 5.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    write_raw_ticket($base, 'A', 'T1', ['--reason', 'a subagent tried this'],
        at => time(), cwd => '/proj', agent_id => 'ag1');
    my $res = run_cli('--reason', 'a subagent tried this');
    is($res->{rc}, 1, 'AC-17: a ticket with agent_id set -> CLI exit 1');
    is($res->{out}, "$STEP5\n", 'AC-17: the step-5 line');
    ok(!-e "$S/fork-ok", 'AC-17: nothing recorded');
}

# ===========================================================================
# AC-18 -- recording twice before any fork leaves exactly one token, holding
# the second reason.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $r1 = 'the first reason given here';
    my $r2 = 'the second reason given here';
    for my $r ($r1, $r2) {
        tw(payload_bash(cmd => "butler-fork-ok --reason '$r'",
                         session_id => 'A', tool_use_id => 'T1', cwd => '/proj'));
        run_cli('--reason', $r);
    }
    my @tokens = bsd_glob("$S/fork-ok/A.json*");
    is(scalar(@tokens), 1, 'AC-18: exactly one token file exists after two record flows');
    SKIP: {
        skip 'AC-18: no token to inspect', 1 unless @tokens;
        my $tok = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes($tokens[0])) };
        is(ref($tok) eq 'HASH' ? $tok->{reason} : undef, $r2, 'AC-18: the surviving token holds the SECOND reason');
    }
    my $resA1 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T2'));
    is($resA1->{rc}, 0, 'AC-18: fork A -> rc 0');
    my $resA2 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T3'));
    is($resA2->{rc}, 2, 'AC-18: the next fork A -> rc 2');
}

# ===========================================================================
# AC-19 -- a malformed token (empty, or another session's) is consumed and
# denied, and removed afterward.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    write_raw_token($base, 'A', '');
    my $res1 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T1'));
    is($res1->{rc}, 2, 'AC-19: an empty token file -> fork A denies');
    ok(!-f "$S/fork-ok/A.json", 'AC-19: ...and the empty token file is gone');

    write_raw_token($base, 'A', JSON::PP->new->utf8->canonical->encode(
        { session_id => 'B', reason => 'needs parent context', at => '2026-01-01T00:00:00Z' }));
    my $res2 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T2'));
    is($res2->{rc}, 2, "AC-19: a token recorded under A's filename but session B's content -> fork A denies");
    ok(!-f "$S/fork-ok/A.json", 'AC-19: ...and that token file is gone too');
}

# ===========================================================================
# AC-20 -- a mere mention/unpredictable word never writes a ticket.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    for my $c (
        [q{echo butler-fork-ok --reason 'x y z w'} => 'a mention via echo'],
        [q{grep butler-fork-ok notes.txt}          => 'a mention via grep'],
        [q{butler-fork-ok --reason "$WHY"}          => 'an unpredictable word'],
    ) {
        my ($cmd, $label) = @$c;
        my $res = tw(payload_bash(cmd => $cmd, session_id => 'sess-a20', tool_use_id => 'T1', cwd => '/proj'));
        is($res->{rc}, 0, "AC-20: $label -> rc 0");
        is($res->{out} . $res->{err}, '', "AC-20: $label -> no output");
    }
    my @tf20 = find_ticket_files($base);
    is(scalar(@tf20), 0, 'AC-20: no ticket file under $S/tickets/ from any of the three');
}

# ===========================================================================
# AC-21 -- non-ASCII reason survives the whole flow byte-for-byte.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason = "Andr\x{e9} needs the parent context"; # 'André ...'
    tw(payload_bash(cmd => "butler-fork-ok --reason '$reason'",
                     session_id => 'A', tool_use_id => 'T1', cwd => '/proj'));
    my $res = run_cli('--reason', $reason);
    is($res->{rc}, 0, 'AC-21: CLI with a non-ASCII reason -> exit 0');
    my $token_path = "$S/fork-ok/A.json";
    SKIP: {
        skip 'AC-21: no token file to inspect', 1 unless -f $token_path;
        my $raw = GuardHarness::read_bytes($token_path);
        my $tok = eval { local $@; JSON::PP->new->utf8->decode($raw) };
        is(ref($tok) eq 'HASH' ? $tok->{reason} : undef, $reason, 'AC-21: token reason equals the UTF-8 string exactly');
    }
    my $resfork = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T2'));
    is($resfork->{rc}, 0, 'AC-21: fork A -> rc 0');
}

# ===========================================================================
# AC-22 -- the core ticket API for butler-continuity/butler-hold is
# unaffected, and never collides with the new name (Decision 91).
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $p = { session_id => 'A', tool_use_id => 'T1', hook_event_name => 'PreToolUse',
              tool_name => 'Bash', tool_input => { command => 'noop' } };

    is(BpHook::write_ticket($p, 'butler-continuity', ['on']), 1, 'AC-22a: write_ticket butler-continuity -> 1');
    my $t1 = BpHook::take_ticket('butler-continuity', ['on']);
    is(ref($t1) eq 'HASH' ? $t1->{session_id} : undef, 'A', 'AC-22a: take_ticket returns a hashref with session_id A');

    is(BpHook::write_ticket($p, 'butler-hold', ['a1']), 1, 'AC-22b: write_ticket butler-hold -> 1');
    my $t2 = BpHook::take_ticket('butler-hold', ['a1']);
    is(ref($t2) eq 'HASH' ? $t2->{session_id} : undef, 'A', 'AC-22b: take_ticket returns a hashref with session_id A');

    is(BpHook::write_ticket($p, 'bp-other', ['z']), 0, 'AC-22c: write_ticket of an unknown name -> 0');

    BpHook::write_ticket($p, 'butler-continuity', ['on']);
    BpHook::write_ticket($p, 'butler-fork-ok', ['on']);
    my $t3 = BpHook::take_ticket('butler-continuity', ['on']);
    is(ref($t3) eq 'HASH' ? 1 : 0, 1, 'AC-22d: butler-continuity ticket still claims cleanly alongside a butler-fork-ok write');
    my $t4 = BpHook::take_ticket('butler-fork-ok', ['on']);
    is(ref($t4) eq 'HASH' ? 1 : 0, 1, 'AC-22d: butler-fork-ok also claims a hashref, never "ambiguous"')
        or diag('got: ' . (defined $t4 ? $t4 : '<undef>') . ' -- requires BpHook.pm 2.7 (Decision 91), not yet made');

    BpHook::write_ticket($p, 'butler-fork-ok', ['on']);
    my $t5 = BpHook::take_ticket('/x/bin/butler-fork-ok.pl', ['on']);
    is(ref($t5) eq 'HASH' ? 1 : 0, 1, 'AC-22e: a ticket written as butler-fork-ok is claimed via a full .pl path')
        or diag('requires BpHook.pm 2.7 (Decision 91), not yet made');
}

# ===========================================================================
# AC-23 -- no duplicate ticket writers (package 28: ContinuityOffCheck is
# the one writer of butler-fork-ok too).
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    tw(payload_bash(cmd => "butler-fork-ok --reason 'needs parent context'",
                     session_id => 'sess-a23', tool_use_id => 'T1', cwd => '/proj'));
    my @tf23a = find_ticket_files($base);
    is(scalar(@tf23a), 1,
        'AC-23: ContinuityOffCheck is the one writer: exactly one ticket for a butler-fork-ok command');
}
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    gf(payload_bash(cmd => 'butler-hold a1', session_id => 'sess-a23b', tool_use_id => 'T1', cwd => '/proj'));
    my @tf23b = find_ticket_files($base);
    is(scalar(@tf23b), 0,
        'AC-23: ContinuityOffCheck is the one writer: exactly one ticket for a butler-fork-ok command');
}
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    gf(payload_bash(cmd => "butler-fork-ok --reason 'needs parent context'",
                     session_id => 'sess-a23', tool_use_id => 'T1', cwd => '/proj'));
    my @tf23c = find_ticket_files($base);
    is(scalar(@tf23c), 0, 'AC-23: GuardFork writes no ticket for a butler-fork-ok command');
}

# ===========================================================================
# AC-24 -- malformed input.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    for my $c (
        ['{not json' => {}],
        ['[1,2]' => {}],
        [undef => { truncated => 1 }],
        [undef => { no_sid => 1 }],
        [undef => { bad_sid => 1 }],
    ) {
        my ($raw, $opt) = @$c;
        local %ENV = %ENV;
        my $res;
        if (defined $raw) {
            $res = gf($raw);
        }
        elsif ($opt->{truncated}) {
            $res = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                    session_id => 'sess-a24', tool_use_id => 'T1'),
                      BP_PAYLOAD_TRUNCATED => 1);
        }
        elsif ($opt->{no_sid}) {
            $res = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', tool_use_id => 'T1'));
        }
        elsif ($opt->{bad_sid}) {
            $res = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                    session_id => 'a b', tool_use_id => 'T1'));
        }
        is($res->{rc}, 0, 'AC-24: malformed input -> rc 0');
        is($res->{out} . $res->{err}, '', 'AC-24: malformed input -> no output');
    }
}

# ===========================================================================
# AC-25 -- BUTLER_STATE_DIR pointing at a regular file, not a directory.
# ===========================================================================
{
    local %ENV = %ENV;
    my $tmp = tempdir(CLEANUP => 1);
    (my $fake = "$tmp/not-a-dir") =~ s{\\}{/}g;
    open(my $fh, '>', $fake) or die $!;
    close $fh;
    $ENV{BUTLER_STATE_DIR} = $fake;

    my $res_allow = gf(payload_fork(tool_name => 'Agent', subagent_type => 'general-purpose',
                                     session_id => 'sess-a25', tool_use_id => 'T1'));
    is($res_allow->{rc}, 0, 'AC-25: a non-fork dispatch with BUTLER_STATE_DIR as a file -> rc 0');
    is($res_allow->{out} . $res_allow->{err}, '', 'AC-25: no output');

    my $res_fork = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                    session_id => 'sess-a25', tool_use_id => 'T2'));
    is($res_fork->{rc}, 2, 'AC-25: a fork dispatch in the same broken-state-dir env -> rc 2');
    is($res_fork->{err}, $DENY_TEXT, 'AC-25: the deny text');
}

# ===========================================================================
# AC-26 -- wrapper: empty stdin, and a truncated fork payload.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res_empty = GuardHarness::run_wrapper('guard-fork', '');
    is($res_empty->{rc}, 0, 'AC-26: empty stdin through the wrapper -> rc 0');

    my $res_trunc = GuardHarness::run_wrapper('guard-fork',
        '{"tool_name":"Agent","tool_input":{"subagent_type":"fork"');
    is($res_trunc->{rc}, 0, 'AC-26: a truncated fork payload through the wrapper -> rc 0');
}

# ===========================================================================
# AC-27 / AC-28 -- process budget through the shim.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $shim_dir;
    my $res1 = GuardHarness::run_shim('guard-fork',
        payload_fork(tool_name => 'Agent', subagent_type => 'general-purpose',
                     session_id => 'sess-a27', tool_use_id => 'T1'));
    $shim_dir = $res1->{shim_dir};
    is($res1->{rc}, 0, 'AC-27: a non-fork Agent payload through the shim -> rc 0');
    is(GuardHarness::count_lines($res1->{shim_log}, 'perl'), 0, 'AC-27: zero perl launches');

    my $res2 = GuardHarness::run_shim('guard-fork', payload_bash(cmd => 'ls -la'), shim_dir => $shim_dir);
    is($res2->{rc}, 0, 'AC-27: an ordinary Bash payload through the shim -> rc 0');
    is(GuardHarness::count_lines($res2->{shim_log}, 'perl'), 0, 'AC-27: zero perl launches');

    my $res3 = GuardHarness::run_shim('guard-fork',
        payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T1'),
        shim_dir => $shim_dir);
    is($res3->{rc}, 2, 'AC-28: a fork payload through the shim -> rc 2');
    is(GuardHarness::count_lines($res3->{shim_log}, 'perl'), 1, 'AC-28: exactly one perl launch');
    is($res3->{err}, $DENY_TEXT, 'AC-28: stderr equals the deny text');
}

# ===========================================================================
# AC-29 -- run() never re-parses the payload.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res1 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'A', tool_use_id => 'T1'));
    is($res1->{parse_delta}, 0, 'AC-29: parse_count unchanged for a fork payload');

    my $res2 = gf(payload_bash(cmd => "butler-fork-ok --reason 'needs parent context'",
                                session_id => 'B', tool_use_id => 'T1', cwd => '/proj'));
    is($res2->{parse_delta}, 0, 'AC-29: parse_count unchanged for a ticket-writing Bash payload');
}

# ===========================================================================
# AC-30 -- hooks.json registration.
# ===========================================================================
{
    ok(-f $HOOKS_JSON, 'AC-30 precondition: hooks.json exists') or BAIL_OUT('hooks.json missing');
    my $raw = GuardHarness::read_bytes($HOOKS_JSON);
    my $data = eval { JSON::PP->new->decode($raw) };
    ok(ref($data) eq 'HASH', 'AC-30: hooks.json decodes as an object') or diag($@);
    SKIP: {
        skip 'AC-30: hooks.json did not decode', 3 unless ref($data) eq 'HASH';
        my $pre = (ref($data->{hooks}) eq 'HASH' && ref($data->{hooks}{PreToolUse}) eq 'ARRAY')
            ? $data->{hooks}{PreToolUse} : [];
        my @hits;
        for my $group (@$pre) {
            next unless ref($group) eq 'HASH' && ref($group->{hooks}) eq 'ARRAY';
            for my $h (@{ $group->{hooks} }) {
                next unless ref($h) eq 'HASH' && defined $h->{command};
                next unless index($h->{command}, '/hooks/guard-fork.sh') >= 0;
                push @hits, { group => $group, hook => $h };
            }
        }
        is(scalar(@hits), 1, 'AC-30: among PreToolUse entries, exactly ONE command mentions guard-fork.sh');
        SKIP: {
            skip 'AC-30: no matching entry to inspect', 2 unless @hits;
            is($hits[0]{group}{matcher}, 'Task|Agent', "AC-30: its group's matcher is Task|Agent");
            my $expect = q{unset BASH_ENV ; f="${CLAUDE_PLUGIN_ROOT}/hooks/guard-fork.sh" ; w="${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" ; [ -f "$f" ] && [ -f "$w" ] || exit 0 ; bash -n "$f" 2>/dev/null && bash -n "$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "$f"};
            is($hits[0]{hook}{command}, $expect, 'AC-30: the command equals the 2.5 template exactly');
            is($hits[0]{hook}{timeout}, 15, 'AC-30: timeout is 15');
        }
    }
}

# ===========================================================================
# AC-31 -- guard-fork.sh static shape.
# ===========================================================================
{
    ok(-f $GUARD_SH, 'AC-31 precondition: guard-fork.sh exists on disk')
        or diag("missing: $GUARD_SH (package 19 has not written it yet)");
  SKIP: {
        skip 'AC-31: guard-fork.sh missing', 3 unless -f $GUARD_SH;
        my $rc = system($REAL_BASH, '-n', $GUARD_SH);
        is($rc, 0, 'AC-31: bash -n on guard-fork.sh passes');
        my $src = GuardHarness::read_bytes($GUARD_SH);
        unlike($src, qr{hooks/next}, 'AC-31: the file does not contain "hooks/next"');
        like($src, qr/Guards::GuardFork/, 'AC-31: the file names Guards::GuardFork');
        like($src, qr/--pre text:fork/, 'AC-31: the file carries --pre text:fork');
    }
}

# ===========================================================================
# AC-32 -- hook-architecture.md edits.
# ===========================================================================
{
    ok(-f $ARCH_DOC, 'AC-32 precondition: hook-architecture.md exists') or BAIL_OUT('hook-architecture.md missing');
    my $src = GuardHarness::read_bytes($ARCH_DOC);
    like($src, qr/^### file: guard-fork\.sh$/m, 'AC-32: an inventory row for guard-fork.sh');
    like($src, qr/^### registration: hooks\.json PreToolUse \[Task\|Agent\] guard-fork\.sh$/m,
         'AC-32: a registration row naming its matcher group');
    like($src, qr/^\|\s*guard-fork\.sh\s*\|\s*3\s*\|/m, 'AC-32: a budget-table line starting "| guard-fork.sh | 3 |"');
}

# ===========================================================================
# AC-33 -- the extensionless CLI shim, no args.
# ===========================================================================
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res = run_cli_bin();
    is($res->{rc}, 1, 'AC-33: bash bin/butler-fork-ok, no args -> exit 1');
    is($res->{out}, "$STEP1\n", 'AC-33: stdout is exactly the step-1 line');
}

# ===========================================================================
# D93-M1 -- fix round for Decision 93 / review M1 (byte-vs-decoded-character
# mismatch in valid_reason). A reason whose UTF-8 BYTE length clears the
# 10-non-whitespace-character floor but whose DECODED character length does
# not must be refused by the CLI outright, and must never leave a token that
# a later fork would silently fail to redeem. Conversely, anything the CLI
# accepts must actually redeem: the very next fork in that session succeeds.
# ===========================================================================
{
    # 'eeee eee' spelled with U+00E9: 8 characters (7 non-space, 2 words) --
    # decoded-character-invalid (7 < 10) -- but 15 UTF-8 bytes (14 non-space)
    # -- byte-count-valid. Exactly the M1 example.
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    # Encode explicitly to real UTF-8 bytes and clear the utf8 flag: a
    # wide-flagged Perl scalar passed straight through system() downgrades
    # single-byte-range codepoints (U+00E9 -> the ONE byte 0xE9) on this
    # host instead of surfacing as two UTF-8 bytes, which would hide the
    # very byte/char mismatch this test needs on the wire.
    my $c = "\x{e9}";
    my $mismatch_chars = ($c x 4) . ' ' . ($c x 3);
    my $mismatch = Encode::encode_utf8($mismatch_chars);

    # a ticket for this exact argv, so the CLI reaches record_token (step 6)
    # rather than refusing earlier at step 4 for lack of a binding. The core
    # ticket key normalizes both forms to the same UTF-8 bytes (BpHook.pm's
    # _utf8_bytes), so a decoded-character command string here still claims
    # the byte-form argv the CLI is run with below.
    tw(payload_bash(cmd => "butler-fork-ok --reason '$mismatch_chars'",
                     session_id => 'sess-m1a', tool_use_id => 'T1', cwd => '/proj'));

    my $res = run_cli('--reason', $mismatch);
    is($res->{rc}, 1, 'D93-M1a: byte-valid/char-short reason -> CLI exit 1 (refused)');
    is($res->{out}, "$STEP2\n", 'D93-M1a: the step-2 line, not the step-8 success line');
    ok(!-e "$S/fork-ok", 'D93-M1a: no fork-ok directory was created')
        or diag('a token would silently fail a later fork -- review M1');
}
{
    # a fresh, ordinary reason that is valid at both byte and character
    # counts: the CLI must accept it, and the very next fork in that session
    # must then actually succeed -- the general invariant M1 breaks for the
    # short non-ASCII case above.
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason = 'a reason the cli truly accepts here';

    tw(payload_bash(cmd => "butler-fork-ok --reason '$reason'",
                     session_id => 'A', tool_use_id => 'T1', cwd => '/proj'));
    my $res = run_cli('--reason', $reason);
    is($res->{rc}, 0, 'D93-M1b: an ordinary valid reason -> CLI exit 0');
    is($res->{out}, "$STEP8\n", 'D93-M1b: the step-8 success line');

    my $fork = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'A', tool_use_id => 'T2'));
    is($fork->{rc}, 0, 'D93-M1b: a reason the CLI accepted actually redeems the next fork')
        or diag('CLI reported success but the fork was denied -- review M1');
}
{
    # a reason over 300 characters whose truncated (first-300-char) form is
    # STILL valid: the fix (validating the cut, per review M1's suggested
    # fix) must not reject a legitimately long reason that survives
    # truncation intact.
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $long = ('filler word content here, ' x 12) . 'and the real justification words land safely inside the first three hundred characters too';
    cmp_ok(length($long), '>', 300, 'D93-M1c precondition: the reason exceeds 300 characters');
    my $cut = substr($long, 0, 300);
    (my $cut_nospace = $cut) =~ s/\s+//g;
    my @cut_words = grep { length } split /\s+/, $cut;
    ok(length($cut_nospace) >= 10 && scalar(@cut_words) >= 2,
        'D93-M1c precondition: the first 300 characters alone are still a valid reason');

    tw(payload_bash(cmd => "butler-fork-ok --reason '$long'",
                     session_id => 'A', tool_use_id => 'T1', cwd => '/proj'));
    my $res = run_cli('--reason', $long);
    is($res->{rc}, 0, 'D93-M1c: a >300-char reason whose truncated form stays valid -> CLI exit 0');
    is($res->{out}, "$STEP8\n", 'D93-M1c: the step-8 success line');

    my $fork = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'A', tool_use_id => 'T2'));
    is($fork->{rc}, 0, 'D93-M1c: the next fork then succeeds');
}

# ===========================================================================
# D93-m2 -- fix round for Decision 93 / red-team m-2 (a reasons.log write
# failure unwinds and destroys a PREVIOUSLY recorded, still-valid token for
# the same session, even though that earlier override has nothing to do with
# the failing call). The earlier token must survive, and the CLI must say
# only that nothing NEW was recorded.
# ===========================================================================
{
    local %ENV = %ENV;
    my $base = GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason1 = 'the first reason recorded successfully here';
    my $reason2 = 'the second reason that fails to log here';

    # record reason1 for session A -- an ordinary successful flow, leaving a
    # valid, still-unredeemed token.
    tw(payload_bash(cmd => "butler-fork-ok --reason '$reason1'",
                     session_id => 'A', tool_use_id => 'T1', cwd => '/proj'));
    my $res1 = run_cli('--reason', $reason1);
    is($res1->{rc}, 0, 'D93-m2 setup: reason1 records successfully');
    ok(-f "$S/fork-ok/A.json", 'D93-m2 setup: a token now exists for session A');

    # now make reasons.log unwritable (a directory in its place), so the
    # NEXT record_token succeeds but log_reason fails, forcing the unwind.
    unlink("$S/reasons.log") if -e "$S/reasons.log";
    make_path("$S/reasons.log");
    ok(-d "$S/reasons.log", 'D93-m2 setup: reasons.log is now a directory (unwritable as a log)');

    tw(payload_bash(cmd => "butler-fork-ok --reason '$reason2'",
                     session_id => 'A', tool_use_id => 'T2', cwd => '/proj'));
    my $res2 = run_cli('--reason', $reason2);
    is($res2->{rc}, 1, 'D93-m2: the second record fails (reasons.log write failure)');
    is($res2->{out}, "$STEP6\n", 'D93-m2: the step-6 "nothing recorded" line');

    ok(-f "$S/fork-ok/A.json", 'D93-m2: the EARLIER token for session A still exists')
        or diag('the failed second record destroyed the first, still-valid override -- red-team m-2');

    my $fork = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork',
                                session_id => 'A', tool_use_id => 'T3'));
    is($fork->{rc}, 0, 'D93-m2: the surviving earlier token still redeems a fork')
        or diag('the surviving token should still allow one fork -- red-team m-2');
}

$? = 0;
done_testing();
