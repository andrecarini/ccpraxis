#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 28 (blueprint hook-continuity-remake),
# AC-1..AC-17 of specs/28-fork-guard-bash-cost-spec.md sec 4 (Decision 110):
# ticket writing for a Bash butler-fork-ok invocation moves off guard-fork.sh's
# Bash branch and onto the module that already writes butler-continuity/
# butler-hold tickets, and guard-fork.sh's hooks.json registration moves off
# the Bash matcher entirely, onto Task|Agent alone. Fork denial and the
# one-shot override behave exactly as before.
#
# WRITTEN BLIND TO THE IMPLEMENTATION of this package's own write set: derived
# only from the spec text above and from BpHook.pm/butler-fork-ok.pl, both of
# which are out of this package's write set and already implemented. The
# module edit, the .sh edits and the hooks.json move DO NOT EXIST YET at the
# time this file is written -- every AC below that exercises the NEW
# behaviour is expected to fail red for that reason, never for a harness
# crash. ACs that exercise UNCHANGED behaviour (the CLI binding contract, the
# 0-perl ordinary-Bash path, hooks.json's total command count) may already be
# green -- that is fine; this file asserts the spec, not "everything red".
#
# AC-18 (the pinned-suite stability check) is explicitly "run by the
# coordinator, not asserted in this file" per the spec's DC2 note, so it has
# no representation below.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Glob qw(bsd_glob);
use File::Spec ();
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use Time::HiRes ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

(my $BUTLER_DIR = dirname(__FILE__) . '/../..') =~ s{\\}{/}g;
my $SCRIPTS_DIR = "$BUTLER_DIR/scripts";
my $HOOKS_DIR   = "$BUTLER_DIR/hooks";
my $HOOKS_JSON  = "$HOOKS_DIR/hooks.json";
my $GUARD_SH    = "$HOOKS_DIR/guard-fork.sh";
my $COC_SH      = "$HOOKS_DIR/continuity-off-check.sh";
my $GUARD_PM    = "$SCRIPTS_DIR/BpHook/Guards/GuardFork.pm";
my $CLI_PL      = "$SCRIPTS_DIR/butler-fork-ok.pl";

my $REAL_BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH;
my $REAL_TIMEOUT = do { my $p = `bash -c "command -v timeout"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real timeout utility on PATH') unless length $REAL_TIMEOUT;

# ---------------------------------------------------------------------------
# payload builders (spec sec 4 house idiom: session ids/tool_use_ids never
# contain "fork" except where a fork dispatch is under test).
# ---------------------------------------------------------------------------
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

sub payload_fork {
    my (%o) = @_;
    my $ti = { description => 'a task description', prompt => 'a self-contained prompt' };
    $ti->{subagent_type} = $o{subagent_type} if exists $o{subagent_type};
    my $p = { hook_event_name => 'PreToolUse', tool_name => $o{tool_name}, tool_input => $ti };
    $p->{session_id}  = $o{session_id}  if exists $o{session_id};
    $p->{agent_id}    = $o{agent_id}    if exists $o{agent_id};
    $p->{tool_use_id} = $o{tool_use_id} if exists $o{tool_use_id};
    return $p;
}

sub tw { my ($p, %env) = @_; return GuardHarness::run_module('ContinuityOffCheck', $p, env => \%env) }
sub gf { my ($p, %env) = @_; return GuardHarness::run_module('Guards::GuardFork', $p, env => \%env) }

sub quoted_argv { return join(' ', map { /^-/ ? $_ : "'$_'" } @_) }

sub ticket_key { my ($name, @argv) = @_; return sha1_hex(join("\0", $name, @argv)) }

sub find_ticket_files { my ($S) = @_; return sort(bsd_glob("$S/tickets/*/*.json")) }

# ---------------------------------------------------------------------------
# CLI spawn helper -- copies fork-guard.t's _spawn_captured technique: a real
# subprocess, list-form system() (no shell re-quoting), bounded by the real
# "timeout" utility, output captured to File::Temp files, never an in-memory
# STDOUT/STDERR reopen (the Windows "Bad file descriptor" landmine).
# ---------------------------------------------------------------------------
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

sub run_cli { my (@args) = @_; return _spawn_captured($^X, $CLI_PL, @args) }

# ---------------------------------------------------------------------------
# hooks.json helpers.
# ---------------------------------------------------------------------------
sub hooksjson_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{unset BASH_ENV ; f="\${CLAUDE_PLUGIN_ROOT}/hooks/$file" ; w="\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

sub _find_commands {
    my ($doc, $filename) = @_;
    my @out;
    return @out unless ref($doc) eq 'HASH' && ref($doc->{hooks}) eq 'HASH';
    for my $event (sort keys %{ $doc->{hooks} }) {
        my $groups = $doc->{hooks}{$event};
        next unless ref($groups) eq 'ARRAY';
        for my $group (@$groups) {
            next unless ref($group) eq 'HASH' && ref($group->{hooks}) eq 'ARRAY';
            for my $h (@{ $group->{hooks} }) {
                next unless ref($h) eq 'HASH' && defined $h->{command};
                next unless index($h->{command}, "/hooks/$filename") >= 0;
                push @out, { event => $event, matcher => $group->{matcher}, command => $h->{command}, timeout => $h->{timeout} };
            }
        }
    }
    return @out;
}

sub _matcher_applies_to_bash {
    my ($m) = @_;
    return 1 unless defined $m && length $m;
    return 1 if $m eq '*';
    return 1 if grep { $_ eq 'Bash' } split /\|/, $m;
    return 0;
}

ok(-f $HOOKS_JSON, 'precondition: hooks.json exists') or BAIL_OUT('hooks.json missing');
my $HOOKS_RAW = GuardHarness::read_bytes($HOOKS_JSON);
my $HOOKS_DOC = eval { JSON::PP->new->decode($HOOKS_RAW) };
ok(ref($HOOKS_DOC) eq 'HASH', 'precondition: hooks.json decodes as an object') or diag($@);

# ===========================================================================
# Registration (DC1).
# ===========================================================================

# AC-1
{
    SKIP: {
        skip 'AC-1: hooks.json did not decode', 5 unless ref($HOOKS_DOC) eq 'HASH';
        my @hits = _find_commands($HOOKS_DOC, 'guard-fork.sh');
        is(scalar(@hits), 1, 'AC-1: exactly one command across ALL events contains /hooks/guard-fork.sh');
        SKIP: {
            skip 'AC-1: no matching command to inspect', 4 unless @hits;
            is($hits[0]{event}, 'PreToolUse', 'AC-1: its event is PreToolUse');
            is($hits[0]{matcher}, 'Task|Agent', "AC-1: its group's matcher equals Task|Agent");
            is($hits[0]{command}, hooksjson_template('guard-fork.sh'),
                'AC-1: its command equals the 2.2 template byte-for-byte');
            is($hits[0]{timeout}, 15, 'AC-1: its timeout is 15');
        }
    }
}

# AC-2
{
    SKIP: {
        skip 'AC-2: hooks.json did not decode', 1 unless ref($HOOKS_DOC) eq 'HASH';
        my @hits = _find_commands($HOOKS_DOC, 'guard-fork.sh');
        my @applies = grep { _matcher_applies_to_bash($_->{matcher}) } @hits;
        is(scalar(@applies), 0,
            'AC-2: no hooks.json group containing a guard-fork.sh command applies to Bash');
    }
}

# AC-3
{
    SKIP: {
        skip 'AC-3: hooks.json did not decode', 3
            unless ref($HOOKS_DOC) eq 'HASH' && ref($HOOKS_DOC->{hooks}{PreToolUse}) eq 'ARRAY';
        my @pre = @{ $HOOKS_DOC->{hooks}{PreToolUse} };
        my @ta = grep { ref($_) eq 'HASH' && defined $_->{matcher} && $_->{matcher} eq 'Task|Agent' } @pre;
        is(scalar(@ta), 1, 'AC-3: exactly one PreToolUse group has matcher Task|Agent');
        SKIP: {
            skip 'AC-3: no Task|Agent group to inspect', 1 unless @ta;
            my @files = map { my ($f) = ($_->{command} // '') =~ m{([A-Za-z0-9_.-]+\.sh)}; $f // '' }
                        @{ $ta[0]{hooks} // [] };
            is_deeply(\@files, ['bind-dispatch.sh', 'track-dispatch.sh', 'guard-fork.sh'],
                'AC-3: its commands, in order, name bind-dispatch.sh, track-dispatch.sh, guard-fork.sh');
        }
        my @tab = grep { ref($_) eq 'HASH' && defined $_->{matcher} && $_->{matcher} eq 'Task|Agent|Bash' } @pre;
        SKIP: {
            skip 'AC-3: no Task|Agent|Bash group to inspect', 1 unless @tab;
            my @files2 = map { my ($f) = ($_->{command} // '') =~ m{([A-Za-z0-9_.-]+\.sh)}; $f // '' }
                         @{ $tab[0]{hooks} // [] };
            is_deeply(\@files2, ['context-ceiling.sh'],
                'AC-3: the PreToolUse group with matcher Task|Agent|Bash holds exactly one command, naming context-ceiling.sh');
        }
    }
}

# AC-4
{
    SKIP: {
        skip 'AC-4: hooks.json did not decode', 5 unless ref($HOOKS_DOC) eq 'HASH';
        my $total = 0;
        for my $event (keys %{ $HOOKS_DOC->{hooks} // {} }) {
            for my $group (@{ $HOOKS_DOC->{hooks}{$event} // [] }) {
                next unless ref($group) eq 'HASH';
                $total += scalar(@{ $group->{hooks} // [] });
            }
        }
        is($total, 20, 'AC-4: hooks.json holds 20 commands total (never-halt 06: +record-prompt.sh, +record-denial.sh)');
        my @hits = _find_commands($HOOKS_DOC, 'continuity-off-check.sh');
        is(scalar(@hits), 1, 'AC-4: continuity-off-check.sh is registered exactly once');
        SKIP: {
            skip 'AC-4: no matching command to inspect', 3 unless @hits;
            is($hits[0]{event}, 'PreToolUse', 'AC-4: continuity-off-check.sh is on PreToolUse');
            is($hits[0]{matcher}, 'Bash', 'AC-4: its group matcher is Bash');
            is($hits[0]{command}, hooksjson_template('continuity-off-check.sh'),
                'AC-4: its command is still the 2.2 template');
        }
    }
}

# AC-5
{
    ok(-f $COC_SH, 'AC-5 precondition: continuity-off-check.sh exists') or BAIL_OUT('continuity-off-check.sh missing');
    my $rc = system($REAL_BASH, '-n', $COC_SH);
    is($rc, 0, 'AC-5: bash -n on continuity-off-check.sh passes');
    my $src = GuardHarness::read_bytes($COC_SH);
    my @lines = grep { length } split /\n/, $src;
    my $last = @lines ? $lines[-1] : '';
    is($last,
        q{exec bash "$d/run-hook.sh" ContinuityOffCheck --pre text:butler-continuity,text:butler-hold,text:butler-fork-ok,text:almanac -- "$@"},
        'AC-5: its last non-empty line equals the 2.3 exec line exactly');
}

# ===========================================================================
# The ticket still reaches the CLI (DC1).
# ===========================================================================

# AC-6
my $AC6_ARGV = ['--reason', 'needs the parent conversation verbatim'];
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $p = payload_bash(cmd => "butler-fork-ok " . quoted_argv(@$AC6_ARGV),
                          session_id => 'SA', tool_use_id => 'T1', cwd => '/proj');
    my $res = tw($p);
    is($res->{rc}, 0, 'AC-6: rc 0');
    is($res->{out}, '', 'AC-6: empty stdout');
    is($res->{err}, '', 'AC-6: empty stderr');
    is($res->{parse_delta}, 0, 'AC-6: parse_delta 0');
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 1, 'AC-6: exactly one file under $S/tickets/*/');
    SKIP: {
        skip 'AC-6: no ticket file to inspect', 7 unless @tf;
        my ($key, $name) = $tf[0] =~ m{([0-9a-f]{40})/([^/]+)\z};
        is($key, ticket_key('butler-fork-ok', @$AC6_ARGV), 'AC-6: located under the sha1_hex("butler-fork-ok\\0--reason\\0<r>") key');
        is($name, 'SA.T1.json', 'AC-6: located at .../SA.T1.json');
        my $rec = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes($tf[0])) };
        is(ref($rec) eq 'HASH' ? $rec->{session_id} : undef, 'SA', 'AC-6: record session_id is SA');
        is(ref($rec) eq 'HASH' ? $rec->{tool_use_id} : undef, 'T1', 'AC-6: record tool_use_id is T1');
        ok(ref($rec) eq 'HASH' && defined($rec->{operator}) && !$rec->{operator}, 'AC-6: record operator is false');
        ok(ref($rec) eq 'HASH' && defined($rec->{background}) && !$rec->{background}, 'AC-6: record background is false');
        is(ref($rec) eq 'HASH' ? $rec->{agent_id} : 'unreachable', undef, 'AC-6: record agent_id is null');
    }
}

# AC-7
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $p = payload_bash(cmd => "butler-fork-ok " . quoted_argv(@$AC6_ARGV),
                          session_id => 'SA', tool_use_id => 'T1', cwd => '/proj',
                          run_in_background => JSON::PP::true());
    tw($p);
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 1, 'AC-7: exactly one ticket file');
    SKIP: {
        skip 'AC-7: no ticket file to inspect', 1 unless @tf;
        my $rec = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes($tf[0])) };
        ok(ref($rec) eq 'HASH' && $rec->{background}, 'AC-7: with run_in_background true, the ticket\'s background is true');
    }
}

# AC-8
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason = $AC6_ARGV->[1];
    my $p = payload_bash(cmd => "butler-fork-ok " . quoted_argv(@$AC6_ARGV),
                          session_id => 'SA', tool_use_id => 'T1', cwd => '/proj', agent_id => 'ag1');
    tw($p);
    my @tf = find_ticket_files($S);
    SKIP: {
        skip 'AC-8: no ticket file to inspect', 1 unless @tf;
        my $rec = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes($tf[0])) };
        is(ref($rec) eq 'HASH' ? $rec->{agent_id} : undef, 'ag1', 'AC-8: with agent_id ag1, the ticket\'s agent_id is ag1');
    }
    my $res = run_cli('--reason', $reason);
    is($res->{rc}, 1, 'AC-8: the CLI with that argv exits 1');
    is($res->{out}, "butler-fork-ok: only the main session records a fork override.\n",
        'AC-8: exactly that one line');
    ok(!-e "$S/fork-ok", 'AC-8: $S/fork-ok does not exist');
}

# AC-9
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    for my $c (
        [q{echo butler-fork-ok --reason 'x y z w'} => 'a mention via echo'],
        [q{grep butler-fork-ok notes.txt}          => 'a mention via grep'],
        [q{butler-fork-ok --reason "$WHY"}          => 'an unpredictable word'],
    ) {
        my ($cmd, $label) = @$c;
        my $res = tw(payload_bash(cmd => $cmd, session_id => 'sess-a9', tool_use_id => 'T1', cwd => '/proj'));
        is($res->{rc}, 0, "AC-9: $label -> rc 0");
        is($res->{out} . $res->{err}, '', "AC-9: $label -> no output");
    }
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 0, 'AC-9: 0 files under $S/tickets/*/ afterward');
}

# AC-10
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    tw(payload_bash(cmd => q{butler-hold a1 && butler-fork-ok --reason 'needs parent context here'},
                     session_id => 'sess-a10', tool_use_id => 'T1', cwd => '/proj'));
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 2, 'AC-10: exactly 2 files under $S/tickets/*/');
    my $hold_key = ticket_key('butler-hold', 'a1');
    my $fork_key = ticket_key('butler-fork-ok', '--reason', 'needs parent context here');
    my @keys = map { my ($k) = m{([0-9a-f]{40})/}; $k // '' } @tf;
    ok((grep { $_ eq $hold_key } @keys), 'AC-10: one file is under the butler-hold key for ("a1")');
    ok((grep { $_ eq $fork_key } @keys), 'AC-10: one file is under the butler-fork-ok key');
}

# AC-11
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $res = gf(payload_bash(cmd => "butler-fork-ok " . quoted_argv(@$AC6_ARGV),
                               session_id => 'SA', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC-11: GuardFork on the AC-6 payload -> rc 0');
    is($res->{out} . $res->{err}, '', 'AC-11: no output');
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 0, 'AC-11: 0 files under $S/tickets/*/');
    ok(!-e "$S/fork-ok", 'AC-11: no $S/fork-ok');
    my $src = GuardHarness::read_bytes($GUARD_PM);
    unlike($src, qr/write_ticket/, 'AC-11: the source of GuardFork.pm does not contain write_ticket');
}

# AC-12
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $p = payload_bash(cmd => "butler-fork-ok " . quoted_argv(@$AC6_ARGV),
                          session_id => 'SA', tool_use_id => 'T1', cwd => '/proj');
    gf($p);
    tw($p);
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 1, 'AC-12: exactly 1 file under $S/tickets/*/ after GuardFork then ContinuityOffCheck');
    my $t = BpHook::take_ticket('butler-fork-ok', $AC6_ARGV);
    is(ref($t), 'HASH', 'AC-12: BpHook::take_ticket returns a HASH');
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'SA',
        'AC-12: session_id is SA (never "ambiguous")');
}

# AC-13
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason = 'needs the parent conversation verbatim';
    my $wres = GuardHarness::run_wrapper('continuity-off-check',
        payload_bash(cmd => "butler-fork-ok --reason '$reason'",
                      session_id => 'SB', tool_use_id => 'T1', cwd => '/proj'));
    is($wres->{rc}, 0, 'AC-13: run_wrapper(continuity-off-check, ...) -> rc 0');
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 1, 'AC-13: one ticket after the real wrapper');

    my $cres = run_cli('--reason', $reason);
    is($cres->{rc}, 0, 'AC-13: the CLI then exits 0');
    is($cres->{out}, "butler-fork-ok: recorded; the next fork dispatch in this session is allowed once.\n",
        'AC-13: exactly the step-8 stdout line');

    SKIP: {
        skip 'AC-13: no fork-ok token to inspect', 1 unless -f "$S/fork-ok/SB.json";
        my $tok = eval { JSON::PP->new->utf8->decode(GuardHarness::read_bytes("$S/fork-ok/SB.json")) };
        is(ref($tok) eq 'HASH' ? $tok->{session_id} : undef, 'SB', 'AC-13: $S/fork-ok/SB.json has session_id SB');
    }
    my @tf2 = find_ticket_files($S);
    is(scalar(@tf2), 0, 'AC-13: 0 files are left under $S/tickets/*/');

    my $fork1 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'SB', tool_use_id => 'T2'));
    is($fork1->{rc}, 0, 'AC-13: the next fork dispatch of SB -> rc 0');
    my $fork2 = gf(payload_fork(tool_name => 'Agent', subagent_type => 'fork', session_id => 'SB', tool_use_id => 'T3'));
    is($fork2->{rc}, 2, 'AC-13: the one after -> rc 2');
}

# AC-14
{
    my $src = GuardHarness::read_bytes($CLI_PL);
    like($src, qr/BpHook::take_ticket\(\s*'butler-fork-ok'\s*,\s*\\\@ARGV_RAW\s*\)/,
        'AC-14: the CLI source binds through BpHook::take_ticket(\'butler-fork-ok\', \\@ARGV_RAW)');
    unlike($src, qr/CLAUDE_CODE_SESSION_ID/, 'AC-14: the CLI source does not contain CLAUDE_CODE_SESSION_ID');
}

# ===========================================================================
# Process budget (DC1, Decision 33 counts only).
# ===========================================================================

# AC-15
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $res = GuardHarness::run_shim('continuity-off-check',
        payload_bash(cmd => 'ls -la', session_id => 'sess-a15', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC-15: run_shim(continuity-off-check, ordinary Bash) -> rc 0');
    is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0, 'AC-15: zero perl launches');
}

# AC-16
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $S = BpHook::state_dir();
    my $reason = 'needs the parent conversation verbatim';
    my $res = GuardHarness::run_shim('continuity-off-check',
        payload_bash(cmd => "butler-fork-ok --reason '$reason'",
                      session_id => 'SC', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC-16: run_shim(continuity-off-check, AC-6-shaped payload) -> rc 0');
    is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 1, 'AC-16: exactly one perl launch');
    my @tf = find_ticket_files($S);
    is(scalar(@tf), 1, 'AC-16: exactly one ticket file');
}

# ===========================================================================
# Measurement hook (DC3, no timing assertion) -- AC-17.
# ===========================================================================
{
    my $n_env = $ENV{FORK_GUARD_MEASURE};
    my $is_valid_n = defined $n_env && $n_env =~ /\A\d+\z/ && $n_env >= 3 && $n_env <= 200;

    SKIP: {
        skip 'AC-17: FORK_GUARD_MEASURE is unset or not an integer 3..200 -- no timing code runs', 1
            unless $is_valid_n;

        my $n = $n_env + 0;
        my @gf_hits  = _find_commands($HOOKS_DOC, 'guard-fork.sh');
        my @coc_hits = _find_commands($HOOKS_DOC, 'continuity-off-check.sh');

      SKIP: {
            skip 'AC-17: hooks.json does not carry both commands to measure', 1
                unless @gf_hits && @coc_hits;

            my @pairs = (
                ['guard-fork.sh', $gf_hits[0]{command}],
                ['continuity-off-check.sh', $coc_hits[0]{command}],
            );
            my @payloads = (
                ['ordinary', payload_bash(cmd => 'ls -la', session_id => 'sess-measure', tool_use_id => 'T1', cwd => '/proj')],
                ['fork-word', payload_bash(cmd => 'git log --grep=fork', session_id => 'sess-measure', tool_use_id => 'T1', cwd => '/proj')],
            );

            local %ENV = %ENV;
            delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CLAUDE_|CCPRAXIS_)/ } keys %ENV;
            $ENV{CLAUDE_PLUGIN_ROOT} = $BUTLER_DIR;
            $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
            my $home = tempdir(CLEANUP => 1);
            (my $home_fwd = $home) =~ s{\\}{/}g;
            $ENV{HOME} = $home_fwd;
            $ENV{USERPROFILE} = $home_fwd;

            my $all_ok = 1;
            for my $hp (@pairs) {
                my ($hfile, $hcmd) = @$hp;
                for my $pp (@payloads) {
                    my ($plabel, $payload) = @$pp;
                    local %ENV = %ENV;
                    my $t = tempdir(CLEANUP => 1);
                    (my $state_fwd = "$t/state") =~ s{\\}{/}g;
                    $ENV{BUTLER_STATE_DIR} = $state_fwd;

                    my (undef, $stdin_path) = tempfile();
                    open(my $sfh, '>:raw', $stdin_path) or die "cannot write stdin fixture: $!";
                    print {$sfh} JSON::PP->new->utf8->canonical->encode($payload);
                    close $sfh;

                    my @times;
                    for my $i (1 .. $n + 3) {
                        my (undef, $out_path) = tempfile();
                        my (undef, $err_path) = tempfile();
                        open(my $in_fh, '<', $stdin_path) or die "cannot open stdin fixture: $!";
                        open(my $saved_in,  '<&', \*STDIN)  or die "dup STDIN: $!";
                        open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
                        open(my $saved_err, '>&', \*STDERR) or die "dup STDERR: $!";
                        open(STDIN,  '<&', $in_fh)  or die "redirect STDIN: $!";
                        open(STDOUT, '>', $out_path) or die "redirect STDOUT: $!";
                        open(STDERR, '>', $err_path) or die "redirect STDERR: $!";
                        my $t0 = Time::HiRes::time();
                        system($REAL_TIMEOUT, 15, $REAL_BASH, '-c', $hcmd);
                        my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
                        my $rc = ($? == -1) ? -1 : ($? >> 8);
                        open(STDIN,  '<&', $saved_in)  or die "restore STDIN: $!";
                        open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
                        open(STDERR, '>&', $saved_err) or die "restore STDERR: $!";
                        close $saved_in; close $saved_out; close $saved_err; close $in_fh;
                        unlink $out_path, $err_path;
                        $all_ok = 0 if $rc != 0;
                        push @times, $elapsed_ms if $i > 3;
                    }
                    unlink $stdin_path;

                    my @sorted = sort { $a <=> $b } @times;
                    my $cnt = scalar(@sorted);
                    my $median_ms = $cnt
                        ? ($cnt % 2 ? $sorted[int($cnt / 2)]
                                    : ($sorted[$cnt / 2 - 1] + $sorted[$cnt / 2]) / 2)
                        : 0;
                    my $p90_ms = $cnt ? $sorted[int(0.9 * ($cnt - 1))] : 0;
                    diag(sprintf('MEASURE %s %s n=%d median_ms=%d p90_ms=%d',
                        $hfile, $plabel, $n, int($median_ms + 0.5), int($p90_ms + 0.5)));
                }
            }
            ok($all_ok, "AC-17: every run of every (hook, payload) pair exited 0 (n=$n)");
        }
    }
}

$? = 0;
done_testing();
