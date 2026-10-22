#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 5 (blueprint
# hook-continuity-remake), CC-1..CC-11 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.8/4.3/4.11: the context-ceiling
# successor (ContextCeiling), which absorbs context-ceiling-flush and
# context-ceiling-guidance, running on the package-03 hook core.
#
# hooks/context-ceiling.sh and BpHook/Guards/ContextCeiling.pm
# DO NOT EXIST YET. Every in-process case goes through
# GuardHarness::run_module() (batch 1's harness), which mirrors
# BpHook::main()'s own require-and-call contract, so a missing module fails
# open (rc 0) exactly as the real wrapper would -- legibly, never a crash in
# this file. Every [wrapper]/[shim] case spawns the real bash file at that
# path and gets a plain "No such file or directory" until the implementer
# writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text above
# (sec 3.8 for ContextCeiling's own contract, sec 2.2/2.6 for the shared
# module/message conventions) and the BEHAVIOURAL CASES (never the source
# bash) of the two source files this batch's oracle absorbs -- never from
# reading context-ceiling.sh, context-ceiling.sh, or
# bp-orchestrator.pl/bp-dispatch-log.pl's own implementations (only their
# already-pinned PUBLIC contracts named in spec sec 3.8/2.2, exercised here
# purely as observed hook behaviour, exactly as an old-hook test observed
# them as subprocess behaviour).
#
# A DELIBERATE READING, mined verbatim from the retired context-ceiling-flush coverage's own
# expectation helper: the overrun-log line's "<pkg>" and this rule's own
# "runs/<pkg>.ctx-flush-overrun.log" phrase in the flush-turn-past-cap
# message are LITERAL text, not a substituted package name (today's hook
# writes the literal string there too; spec sec 2.6 defines a substitution
# only for <cmd> and <path>, never for a "<pkg>" appearing inside message
# prose).
#
# NOT RE-EXPRESSED (per spec sec 4.11 "Not:" list and sec 4.2's codes):
#   old file / assertion label                                        | code
#   ------------------------------------------------------------------ | ----
#   the retired context-ceiling-flush coverage AC25's no-perl and no-JSON-parser cases    | JQ (the new module never shells out
#                                                                       |   to jq or perl at all -- it is a
#                                                                       |   pure in-process require, so there
#                                                                       |   is no "no interpreter on PATH"
#                                                                       |   degrade left to re-express; CC-5
#                                                                       |   re-expresses the surviving case,
#                                                                       |   "measurement unavailable -> allow")
#   the retired context-ceiling-flush coverage AC27, the retired context-ceiling-guidance coverage AC27      | SRC (bash -n / perl -c against the
#     (source-syntax checks against the OLD bash files)                |   OLD files; this file's own
#                                                                       |   SH-1/SH-2 re-express the shape
#                                                                       |   check against the NEW successor)
#   the retired context-ceiling-guidance coverage AC14 (the outstanding-summary sentence)  | MSG (Decision carried in this
#                                                                       |   package: guidance now tells the
#                                                                       |   agent to RUN bp-dispatch-log.pl
#                                                                       |   outstanding itself, rather than
#                                                                       |   running it and quoting a summary
#                                                                       |   sentence -- there is no successor
#                                                                       |   summary text to re-express)
#   the retired context-ceiling-guidance coverage AC15 (source-text grep for the           | SRC
#     --blueprint/--package scoping of the retired outstanding call)   |
#   the retired context-ceiling-guidance coverage AC30, and the retired context-ceiling-flush coverage's      | REG (hooks.json registration,
#     hooks.json-registration subtest                                  |   package 16's concern)
#   context-growth-checkpoint.t (whole file)                           | OTHER (BpOrch::context_tokens_from_usage
#                                                                       |   / context_growth_ceiling_breached
#                                                                       |   as PURE helpers are a sibling
#                                                                       |   package's own contract, not this
#                                                                       |   hook's; this file exercises the two
#                                                                       |   subs this hook itself calls --
#                                                                       |   last_coordinator_usage,
#                                                                       |   context_ceiling_tier,
#                                                                       |   context_tokens_from_usage -- only
#                                                                       |   through the hook's own behaviour)
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use Cwd ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front (binding lesson). This
# guard, like WaitShapeGuard, never calls BpHook::arm() -- its prefilter
# atom is "coordinator" alone (BP_LEDGER non-empty and BP_ROLE empty/
# coordinator), never a per-session armed-file lookup.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

# ===========================================================================
# SAFETY NET (CC-10) -- never touch the real .ccpraxis-local-data/.dispatch-
# log. Snapshot at start, compare at the very end (mirrors the batch-4
# track-dispatch and the retired context-ceiling-*.t files' own pattern).
# ===========================================================================
(my $REAL_LOGDIR = "$BUTLER_DIR/../../.ccpraxis-local-data/.dispatch-log") =~ s{\\}{/}g;
sub real_logdir_snapshot {
    return {} unless -d $REAL_LOGDIR;
    my %seen;
    for my $f (glob("$REAL_LOGDIR/*.json")) {
        my @st = stat $f;
        $seen{$f} = ($st[9] // 0) . ':' . ($st[7] // 0);
    }
    return \%seen;
}
my $REAL_SNAPSHOT_BEFORE = real_logdir_snapshot();

# ---------------------------------------------------------------------------
# Byte I/O helpers.
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_bytes {
    my ($p, $bytes) = @_;
    (my $dir = $p) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $p) or die "cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

# ---------------------------------------------------------------------------
# fresh_cc_env(%extra) -- a coordinator-shaped env: BP_LEDGER (a real file,
# with a template Next-action body so next_action_written can read false by
# default), BP_DIR (with runs/ present), BP_PROJECT_ROOT, BP_BLUEPRINT,
# BP_PACKAGE.
# ---------------------------------------------------------------------------
my $envN = 0;
sub fresh_cc_env {
    my (%extra) = @_;
    $envN++;
    my $t = tempdir(CLEANUP => 1);
    (my $bp_dir = "$t/bpdir") =~ s{\\}{/}g;
    make_path("$bp_dir/runs");
    (my $proj = "$t/proj") =~ s{\\}{/}g;
    make_path($proj);
    my $pkg = "p14c$envN";
    my $ledger = "$bp_dir/packages/p.md";
    write_bytes($ledger, "---\npackage: $pkg\n---\n# $pkg\n\n## Next action\n\n<what to do next>\n\n## Escalation\n\n<...>\n");
    my %env = (
        BP_LEDGER       => $ledger,
        BP_DIR          => $bp_dir,
        BP_PROJECT_ROOT => $proj,
        BP_BLUEPRINT    => 'hook-continuity-remake',
        BP_PACKAGE      => $pkg,
        %extra,
    );
    return (\%env, $bp_dir, $proj, $ledger);
}

sub jline { return JSON::PP->new->canonical->encode($_[0]) . "\n" }
sub usage_of { my ($n) = @_; return { input_tokens => $n, cache_creation_input_tokens => 0, cache_read_input_tokens => 0 } }
sub assistant_rec { my (%o) = @_; return { type => 'assistant', parent_tool_use_id => undef, message => { usage => usage_of($o{tokens}) } } }
sub write_transcript {
    my ($bp_dir, $pkg, $tokens) = @_;
    write_bytes("$bp_dir/runs/$pkg.jsonl", jline(assistant_rec(tokens => $tokens)));
}

sub flush_state_path       { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-flush" }
sub overrun_log_path       { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-flush-overrun.log" }
sub overrun_once_dir_path  { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-flush-overrun.once" }
sub guidance_state_path    { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.ctx-guidance" }

sub read_turns {
    my ($bp, $pkg) = @_;
    my $c = read_bytes(flush_state_path($bp, $pkg));
    return undef unless defined $c;
    my ($t) = $c =~ /^turns:\s*(\d+)/m;
    return $t;
}
sub overrun_lines {
    my ($bp, $pkg) = @_;
    my $c = read_bytes(overrun_log_path($bp, $pkg));
    return (wantarray ? () : 0) unless defined $c;
    return grep { /\S/ } split /\n/, $c;
}

# ---------------------------------------------------------------------------
# Payload builders. Every fixture carries a session_id.
# ---------------------------------------------------------------------------
sub pre_task_payload { return { hook_event_name => 'PreToolUse', tool_name => 'Task', tool_input => {}, session_id => 'cc-sess' } }
sub pre_agent_payload { return { hook_event_name => 'PreToolUse', tool_name => 'Agent', tool_input => {}, session_id => 'cc-sess' } }
sub pre_bash_payload { my ($cmd) = @_; return { hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $cmd }, session_id => 'cc-sess' } }
sub post_payload { my ($tool) = @_; return { hook_event_name => 'PostToolUse', tool_name => $tool, tool_input => {}, session_id => 'cc-sess' } }

# ---------------------------------------------------------------------------
# cc($payload, %opts) -- GuardHarness::run_module for Guards::ContextCeiling.
# ---------------------------------------------------------------------------
sub cc {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::ContextCeiling', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ---------------------------------------------------------------------------
# spec_echo_cmd($cmd) -- see the wait-shape-guard oracle's identical helper
# (Guards::Common::echo_cmd, spec sec 2.3): \r \n \t -> ' ', cut to 80+'...'.
# ---------------------------------------------------------------------------
sub spec_echo_cmd {
    my ($cmd) = @_;
    return '' unless defined $cmd;
    (my $v = $cmd) =~ tr/\r\n\t/   /;
    return $v if length($v) <= 80;
    return substr($v, 0, 80) . '...';
}

# ---------------------------------------------------------------------------
# The mandated messages (spec sec 3.8), byte-exact.
# ---------------------------------------------------------------------------
sub deny_l1     { my ($n, $hard, $x) = @_; return "BLOCKED: context flush (~$n tokens >= hard $hard). $x" }
sub deny_l2_cap { my ($turns) = @_; return "Flush turn $turns of 5: only bp-ledger.pl set-status|set-next-action|tick-step|append-attempt|add-output|set-escalation|validate or bp-dispatch-log.pl outstanding." }
sub deny_l2_over{ my ($turns) = @_; return "Flush turn $turns is past the permitted 5 and was logged to runs/<pkg>.ctx-flush-overrun.log; set status: blocked with a filled '## Escalation', then stop." }
sub deny_full   { my ($n, $hard, $x, $turns) = @_; return deny_l1($n, $hard, $x) . "\n" . ($turns <= 5 ? deny_l2_cap($turns) : deny_l2_over($turns)) . "\n" }

sub guide_l1_soft { my ($n, $soft, $hard) = @_; return "[context-ceiling] Your last recorded own-turn context is about $n tokens, at or above the soft ceiling of $soft (hard $hard); guidance, not a block." }
sub guide_l1_hard { my ($n, $hard) = @_; return "[context-ceiling] About $n tokens, at or above the hard ceiling of $hard: a flush is in force; Task dispatch and non-flush Bash are denied." }
sub guide_l2      { return "[context-ceiling] Record outstanding dispatches (bp-dispatch-log.pl outstanding), write a concrete '## Next action', leave status non-terminal, stop." }

my $SOFT = 250_000;
my $HARD = 350_000;

# =====================================================================================
# SH-1/SH-2 -- static shape.
# =====================================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/context-ceiling.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/ContextCeiling.pm";
    ok(-f $wrapper, 'SH-1 precondition: context-ceiling.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        is(system('bash', '-n', $wrapper), 0, 'SH-1: bash -n on context-ceiling.sh passes');
        like(read_bytes($wrapper) // '', qr/Guards::ContextCeiling/, 'SH-1: the wrapper names the Guards::ContextCeiling module');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/ContextCeiling.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        is(system('perl', "-I$BUTLER_DIR/scripts", '-c', $module), 0, 'SH-2: perl -c on ContextCeiling.pm passes');
        (my $src = read_bytes($module) // '') =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# =====================================================================================
# CC-1 -- fixture transcript with a last own-turn usage; ceilings honour the
# two env vars (proving the module reads BP_CONTEXT_CEILING_SOFT_TOKENS /
# _HARD_TOKENS rather than the compiled-in defaults alone).
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env(BP_CONTEXT_CEILING_SOFT_TOKENS => 1000, BP_CONTEXT_CEILING_HARD_TOKENS => 2000);
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 1500);
    my $res = cc(pre_task_payload(), env => $env);
    is($res->{rc}, 0, 'CC-1: 1500 tokens against a 1000/2000 override sits at soft, not hard -- Task allows');
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 2500);
    my $res2 = cc(pre_task_payload(), env => $env);
    is($res2->{rc}, 2, 'CC-1: 2500 tokens against the SAME override crosses hard -- Task denies (the env vars are honoured)');
}

# =====================================================================================
# CC-2 -- below hard (including above soft): Task, Agent and any Bash allow;
# an existing .ctx-flush is deleted and .once removed.
# =====================================================================================
for my $tokens (10_000, 300_000) {
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, $tokens);
    write_bytes(flush_state_path($bp_dir, $env->{BP_PACKAGE}), "started_at: 1\nturns: 3\n");
    make_path(overrun_once_dir_path($bp_dir, $env->{BP_PACKAGE}));
    for my $p (pre_task_payload(), pre_agent_payload(), pre_bash_payload('git status')) {
        my $res = cc($p, env => $env);
        is($res->{rc}, 0, "CC-2 ($tokens tokens): $p->{tool_name} allows");
        is($res->{out} . $res->{err}, '', "CC-2 ($tokens tokens): $p->{tool_name} produces no output");
    }
    ok(!-e flush_state_path($bp_dir, $env->{BP_PACKAGE}), "CC-2 ($tokens tokens): the pre-existing .ctx-flush state is deleted");
    ok(!-e overrun_once_dir_path($bp_dir, $env->{BP_PACKAGE}), "CC-2 ($tokens tokens): the .ctx-flush-overrun.once directory is removed");
}

# =====================================================================================
# CC-3 -- at hard: Task/Agent deny with Tool:.../turns:1; every non-flush
# Bash denies with Command: <cmd>; every flush command allows and still
# increments turns.
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res_task = cc(pre_task_payload(), env => $env);
    is($res_task->{rc}, 2, 'CC-3: at hard, Task denies');
    is($res_task->{out}, '', 'CC-3: Task stdout empty (PreToolUse stdout is a protocol channel)');
    is($res_task->{err}, deny_full(400_000, $HARD, 'Tool: Task', 1), 'CC-3: Task stderr is exactly the mandated two lines, turns:1');
    is(read_turns($bp_dir, $env->{BP_PACKAGE}), 1, 'CC-3: runs/<pkg>.ctx-flush now reads turns: 1');
}
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res_agent = cc(pre_agent_payload(), env => $env);
    is($res_agent->{rc}, 2, 'CC-3: at hard, Agent denies');
    is($res_agent->{err}, deny_full(400_000, $HARD, 'Tool: Agent', 1), 'CC-3: Agent stderr is exactly the mandated two lines');
}
{
    my @nonflush = (
        'wc -l runs/p.jsonl',
        'git status',
        'perl bp-ledger.pl rotate --ledger x',
        'bp-dispatch-log.pl list',
        'echo $(bp-ledger.pl validate --ledger x)',
        'bp-ledger.pl validate --ledger x && npm test',
    );   # shape-lint: intentional -- counts a corpus THIS test builds a few lines above, asserted so the loop that follows can never pass vacuously over an empty list; not the shape of a shared artifact.
    is(scalar(@nonflush), 6, 'CC-3 setup: six non-flush Bash corpus commands');
    for my $cmd (@nonflush) {
        my ($env, $bp_dir) = fresh_cc_env();
        write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
        my $res = cc(pre_bash_payload($cmd), env => $env);
        is($res->{rc}, 2, "CC-3: non-flush Bash denies [$cmd]");
        is($res->{err}, deny_full(400_000, $HARD, 'Command: ' . spec_echo_cmd($cmd), 1), "CC-3: ...stderr exact for [$cmd]");
    }
}
{
    my @flush = (
        'perl /p/scripts/bp-ledger.pl set-next-action --ledger L --body "x"',
        'bp-ledger.pl set-status --ledger L --status blocked',
        'bp-ledger.pl tick-step --ledger L --step 2',
        'bp-ledger.pl append-attempt --ledger L --text t',
        'bp-ledger.pl add-output --ledger L --text t',
        'bp-ledger.pl set-escalation --ledger L --text t',
        'bp-ledger.pl validate --ledger L',
        'perl /p/scripts/bp-dispatch-log.pl outstanding --blueprint b --package p',
        'bp-ledger.pl set-next-action --ledger L --body "x" && bp-ledger.pl set-status --ledger L --status parked',
    );   # shape-lint: intentional -- counts a corpus THIS test builds a few lines above, asserted so the loop that follows can never pass vacuously over an empty list; not the shape of a shared artifact.
    is(scalar(@flush), 9, 'CC-3 setup: nine flush-procedure corpus commands');
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $expect_turn = 0;
    for my $cmd (@flush) {
        $expect_turn++;
        my $res = cc(pre_bash_payload($cmd), env => $env);
        is($res->{rc}, 0, "CC-3: flush command allows [$cmd]") or diag("err: $res->{err}");
        is($res->{out} . $res->{err}, '', "CC-3: flush command produces no output [$cmd]");
        is(read_turns($bp_dir, $env->{BP_PACKAGE}), $expect_turn, "CC-3: flush command still increments turns to $expect_turn [$cmd]");
    }
    my $res_empty = cc(pre_bash_payload(''), env => $env);
    is($res_empty->{rc}, 0, 'CC-3: an empty Bash command allows');
}

# =====================================================================================
# CC-4 -- six fires: fires 1-5 say "of 5", fire 6 and later say "past the
# permitted 5"; the overrun log has exactly one line, with
# next_action_written true/false/unknown per the ledger fixture.
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    for my $k (1 .. 5) {
        my $res = cc(pre_task_payload(), env => $env);
        is($res->{rc}, 2, "CC-4: fire $k denies");
        like($res->{err}, qr/\QFlush turn $k of 5:\E/, "CC-4: fire $k carries the 'of 5' wording");
        is(scalar(overrun_lines($bp_dir, $env->{BP_PACKAGE})), 0, "CC-4: fire $k -- overrun log still has zero lines");
    }
    my $res6 = cc(pre_task_payload(), env => $env);
    is($res6->{rc}, 2, 'CC-4: fire 6 denies');
    like($res6->{err}, qr/\QFlush turn 6 is past the permitted 5\E/, 'CC-4: fire 6 carries the overrun wording');
    my @lines6 = overrun_lines($bp_dir, $env->{BP_PACKAGE});
    is(scalar(@lines6), 1, 'CC-4: fire 6 -- the overrun log gains exactly one line');
    like($lines6[0] // '', qr/package=\Q$env->{BP_PACKAGE}\E turns=6 cap=5 context_tokens=400000 next_action_written=(true|false|unknown)/,
        'CC-4: the overrun log line matches the mandated shape') if @lines6;
    for my $k (7, 8) {
        my $res = cc(pre_task_payload(), env => $env);
        is($res->{rc}, 2, "CC-4: fire $k still denies");
        like($res->{err}, qr/past the permitted 5/, "CC-4: fire $k still carries the overrun wording");
        is(scalar(overrun_lines($bp_dir, $env->{BP_PACKAGE})), 1, "CC-4: fire $k -- the overrun log stays at exactly one line");
    }
}
{
    my @cases = (
        ['filled body', "\n\nDispatch the implementer for step 4.\n\n", 'true'],
        ['template placeholder', "\n\n<...>\n\n", 'false'],
        ['empty body', "\n\n\n\n", 'false'],
    );
    is(scalar(@cases), 3, 'CC-4 setup: three next_action_written ledger fixtures');
    for my $c (@cases) {
        my ($label, $body, $expect) = @$c;
        my ($env, $bp_dir, undef, $ledger) = fresh_cc_env();
        write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
        write_bytes($ledger, "---\npackage: p\n---\n# p\n\n## Next action$body## Escalation\n\n<...>\n");
        write_bytes(flush_state_path($bp_dir, $env->{BP_PACKAGE}), "started_at: 1\nturns: 5\n");
        cc(pre_task_payload(), env => $env);
        my @lines = overrun_lines($bp_dir, $env->{BP_PACKAGE});
        ok(scalar(@lines), "CC-4 ($label): an overrun line was written") or next;
        like($lines[0], qr/next_action_written=\Q$expect\E/, "CC-4 ($label): next_action_written=$expect");
    }
    {
        my ($env, $bp_dir, undef, $ledger) = fresh_cc_env();
        write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
        unlink $ledger;
        write_bytes(flush_state_path($bp_dir, $env->{BP_PACKAGE}), "started_at: 1\nturns: 5\n");
        cc(pre_task_payload(), env => $env);
        my @lines = overrun_lines($bp_dir, $env->{BP_PACKAGE});
        ok(scalar(@lines), 'CC-4 (missing ledger): an overrun line was written') or next;
        like($lines[0], qr/next_action_written=unknown/, 'CC-4 (missing ledger): next_action_written=unknown');
    }
}

# =====================================================================================
# CC-5 -- unreadable/absent transcript, no usage record -> allow, nothing
# written.
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    # No runs/<pkg>.jsonl at all.
    my $res = cc(pre_task_payload(), env => $env);
    is($res->{rc}, 0, 'CC-5: no transcript at all -> exit 0');
    is($res->{out} . $res->{err}, '', 'CC-5: no output');
    ok(!-e flush_state_path($bp_dir, $env->{BP_PACKAGE}), 'CC-5: no .ctx-flush state written');
}
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_bytes("$bp_dir/runs/$env->{BP_PACKAGE}.jsonl", "not valid jsonl at all {{{\n");
    my $res = cc(pre_task_payload(), env => $env);
    is($res->{rc}, 0, 'CC-5: an unreadable/malformed transcript -> exit 0');
    is($res->{out} . $res->{err}, '', 'CC-5: no output');
}

# =====================================================================================
# CC-7 -- guidance below soft: no output, existing state deleted.
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 10_000);
    write_bytes(guidance_state_path($bp_dir, $env->{BP_PACKAGE}), "last_emit: 1\n");
    my $res = cc(post_payload('Bash'), env => $env);
    is($res->{rc}, 0, 'CC-7: below soft -- exit 0');
    is($res->{out}, '', 'CC-7: below soft -- no stdout');
    is($res->{err}, '', 'CC-7: below soft -- no stderr');
    ok(!-e guidance_state_path($bp_dir, $env->{BP_PACKAGE}), 'CC-7: the pre-existing guidance state is deleted');
}

# =====================================================================================
# CC-8 -- guidance at soft/hard: stdout is one JSON object whose
# additionalContext is exactly the two mandated lines; hookEventName is the
# payload's; no blank line; state last_emit written.
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 260_000);
    my $res = cc(post_payload('Bash'), env => $env);
    is($res->{rc}, 0, 'CC-8 (soft): exit 0');
    is($res->{err}, '', 'CC-8 (soft): stderr empty');
    my $doc = eval { JSON::PP->new->decode($res->{out}) };
    ok(ref $doc eq 'HASH', 'CC-8 (soft): stdout parses as a single JSON object') or diag("stdout: [$res->{out}]");
  SKIP: {
        skip 'CC-8 (soft): stdout did not parse', 3 unless ref $doc eq 'HASH';
        is($doc->{hookSpecificOutput}{hookEventName}, 'PostToolUse', 'CC-8 (soft): hookEventName is the payload\'s PostToolUse');
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        is($ctx, guide_l1_soft(260_000, $SOFT, $HARD) . "\n" . guide_l2(), 'CC-8 (soft): additionalContext is exactly the two mandated lines') or diag("ctx: [$ctx]");
        for my $line (split /\n/, $ctx) {
            unlike($line, qr/\A\s*\z/, 'CC-8 (soft): no blank line inside additionalContext');
        }
    }
    ok(-f guidance_state_path($bp_dir, $env->{BP_PACKAGE}), 'CC-8 (soft): last_emit state was written');
}
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res = cc(post_payload('Task'), env => $env);
    is($res->{rc}, 0, 'CC-8 (hard): exit 0');
    my $doc = eval { JSON::PP->new->decode($res->{out}) };
    ok(ref $doc eq 'HASH', 'CC-8 (hard): stdout parses as a single JSON object') or diag("stdout: [$res->{out}]");
  SKIP: {
        skip 'CC-8 (hard): stdout did not parse', 1 unless ref $doc eq 'HASH';
        my $ctx = $doc->{hookSpecificOutput}{additionalContext} // '';
        is($ctx, guide_l1_hard(400_000, $HARD) . "\n" . guide_l2(), 'CC-8 (hard): additionalContext is exactly the two mandated hard-tier lines') or diag("ctx: [$ctx]");
    }
}

# =====================================================================================
# CC-9 -- rate limit: a second fire within INTERVAL is silent; past it,
# emits; a below-soft fire resets.
# =====================================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 260_000);
    my $res1 = cc(post_payload('Bash'), env => $env);
    ok(length($res1->{out}) > 0, 'CC-9: first fire emits');
    my $res2 = cc(post_payload('Bash'), env => $env);
    is($res2->{out}, '', 'CC-9: second fire immediately after, within the default 900s interval, is silent');
}
{
    my ($env, $bp_dir) = fresh_cc_env(BP_CTX_GUIDANCE_INTERVAL_SECS => 1);
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 260_000);
    write_bytes(guidance_state_path($bp_dir, $env->{BP_PACKAGE}), 'last_emit: ' . (time - 10) . "\n");
    my $res = cc(post_payload('Bash'), env => $env);
    ok(length($res->{out}) > 0, 'CC-9: past a 1s interval with a stale last_emit -- re-emits');
}
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 260_000);
    cc(post_payload('Bash'), env => $env);
    ok(-f guidance_state_path($bp_dir, $env->{BP_PACKAGE}), 'CC-9 setup: state now exists after the first emit');
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 10_000);
    my $res_below = cc(post_payload('Bash'), env => $env);
    is($res_below->{out}, '', 'CC-9: a below-soft fire is silent');
    ok(!-f guidance_state_path($bp_dir, $env->{BP_PACKAGE}), 'CC-9: a below-soft fire deletes the state file');
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 260_000);
    my $res_again = cc(post_payload('Bash'), env => $env);
    ok(length($res_again->{out}) > 0, 'CC-9: re-crossing soft immediately after a reset emits again');
}

# =====================================================================================
# CC-6 -- BP_ROLE=judge and BP_LEDGER unset exit before perl (SH-3).
# =====================================================================================
{
    my $res = GuardHarness::run_shim('context-ceiling.sh',
        pre_task_payload(),
        env => { BP_ROLE => 'judge' });
    is($res->{rc}, 0, 'CC-6: BP_ROLE=judge with BP_LEDGER unset -> exit 0');
    is($res->{out}, '', 'CC-6: empty stdout');
    is($res->{err}, '', 'CC-6: empty stderr');
    is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0, 'CC-6: 0 perl launches (the coordinator prefilter fails in bash)');
}

# =====================================================================================
# The remaining shared ACs.
# =====================================================================================

# SH-5 -- parse_count unchanged, on a deny and an allow path.
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res_deny = cc(pre_task_payload(), env => $env);
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');
}
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 10_000);
    my $res_allow = cc(pre_task_payload(), env => $env);
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- the deny budget (2 lines), length, forbidden vocabulary.
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res = cc(pre_task_payload(), env => $env);
    is($res->{rc}, 2, 'SH-6 setup: the fixture is really a deny');
  SKIP: {
        skip 'SH-6: fixture is not a deny', 5 unless $res->{rc} == 2;
        my @lines = split /\n/, $res->{err};
        pop @lines while @lines && $lines[-1] eq '';
        cmp_ok(scalar(@lines), '<=', 2, 'SH-6: the deny has at most the context-ceiling budget of 2 lines');
        for my $l (@lines) {
            cmp_ok(length($l), '<=', 160, 'SH-6: line length <= 160');
            unlike($l, qr/\.run-finished|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
                   'SH-6: the line names no retired mechanism');
            unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i, 'SH-6: the line names no disable-a-guard hatch');
        }
        is($res->{out}, '', 'SH-6: stdout is empty on the PreToolUse deny path');
    }
}

# SH-7 -- bad JSON, a BP_PAYLOAD_TRUNCATED=1 payload, and {} -> exit 0, no output.
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    for my $c (
        ['{}'                          => 'empty object'],
        ['not json at all'             => 'malformed JSON'],
        ['{"tool_name":"Task","tool_i' => 'truncated JSON'],
    ) {
        my ($raw, $label) = @$c;
        my %e = %$env;
        $e{BP_PAYLOAD_TRUNCATED} = 1 if $label eq 'truncated JSON';
        my $res = cc($raw, env => \%e);
        is($res->{rc}, 0, "SH-7: $label -> exit 0");
        is($res->{out}, '', "SH-7: $label -> empty stdout");
        is($res->{err}, '', "SH-7: $label -> empty stderr");
    }
}

# SH-9 -- opt-in timing block, gated, never asserted (Decision 33).
{
  SKIP: {
        skip 'SH-9: opt-in timing run (set GUARDS_REMAKE_TIME=1 and run this file alone)', 1
            unless $ENV{GUARDS_REMAKE_TIME};
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with GUARDS_REMAKE_TIME=1 '
           . 'to record medians against the package-01 item (g) floor + 100ms; this hook loads the '
           . '~6000-line bp-orchestrator.pl in-process, so its own applies-path timing is worth watching '
           . 'closely at registration time (spec sec 5), but never asserted here');
    }
}

# =====================================================================================
# CC-11 (part 2) -- [wrapper]/[shim] cases. SH-3 (not-applies: BP_LEDGER
# unset), SH-4 (applies: a Bash PreToolUse at hard -- the path that used to
# spawn bp-orchestrator.pl -- exactly 1 perl launch), SH-8 (one deny case
# end to end through the real wrapper, same stderr as in-process).
# =====================================================================================
{
    my $res_not_applies = GuardHarness::run_shim('context-ceiling.sh',
        pre_task_payload(),
        env => {});
    is($res_not_applies->{rc}, 0, 'SH-3: BP_LEDGER unset -> exit 0');
    is($res_not_applies->{out}, '', 'SH-3: empty stdout');
    is($res_not_applies->{err}, '', 'SH-3: empty stderr');
    is(GuardHarness::count_lines($res_not_applies->{shim_log}, 'perl'), 0,
       'SH-3: 0 perl launches (the coordinator prefilter fails in bash)');

    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res_applies = GuardHarness::run_shim('context-ceiling.sh',
        pre_bash_payload('git status'),
        env => $env);
    is($res_applies->{rc}, 2, 'SH-4: a Bash PreToolUse at hard denies (the path that used to spawn bp-orchestrator.pl)');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'perl'), 1, 'SH-4: exactly 1 perl launch');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'jq'), 0, 'SH-4: 0 jq launches');
}
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    my $res_wrapper = GuardHarness::run_wrapper('context-ceiling.sh',
        pre_task_payload(),
        env => $env);
    is($res_wrapper->{rc}, 2, 'SH-8: one deny case end to end through the real wrapper');
    is($res_wrapper->{err}, deny_full(400_000, $HARD, 'Tool: Task', 1), 'SH-8: the wrapper stderr is identical to the in-process CC-3 text');
}

# =====================================================================================
# Harness self-check -- against a real EXISTING successor (stop-gate.sh),
# proving a red result above is context-ceiling's absence, not a harness
# defect. Repeats batch 1's own self-check, since this file must stand alone.
# =====================================================================================
{
    GuardHarness::fresh_state();
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'ccselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('ccselfcheck-2', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'ccselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1, 'self-check: ...with exactly 1 perl launch');

    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'ccselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires and calls it, rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'ccselfcheck-never-armed', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against a DIFFERENT and never-armed session -> allows');
}

# =====================================================================================
# CC-10 -- FINAL SAFETY CHECK. Must be the last thing this file does before
# done_testing().
# =====================================================================================
{
    my $after = real_logdir_snapshot();
    is_deeply($after, $REAL_SNAPSHOT_BEFORE,
        'CC-10: the real .ccpraxis-local-data/.dispatch-log is byte-for-byte untouched by this whole file');
}

# ===========================================================================
# R9-RM1 (review M1): the flush classifier's segment splitter pushes empty
# segments (a trailing ";" or "\n", or a blank line between two verbs), and
# _is_flush_work requires EVERY segment to match a verb regex -- an empty
# segment never does, so all three deny today. The fix should skip
# whitespace-only segments and require at least one non-empty verb segment.
# ===========================================================================
{
    my ($env, $bp_dir) = fresh_cc_env();
    write_transcript($bp_dir, $env->{BP_PACKAGE}, 400_000);
    for my $cmd (
        'bp-ledger.pl validate --ledger L;',
        "bp-ledger.pl validate --ledger L\n",
        "bp-ledger.pl set-status --ledger L --status blocked\n\nbp-ledger.pl validate --ledger L",
    ) {
        my $res = cc(pre_bash_payload($cmd), env => $env);
        is($res->{rc}, 0, "R9-RM1: flush command with a trailing ';'/newline/blank line still allows [$cmd]")
            or diag("err: $res->{err}");
    }
    # a control: ";" alone has NO verb segment at all -- still denies.
    my $res_bare_semi = cc(pre_bash_payload(';'), env => $env);
    is($res_bare_semi->{rc}, 2, 'R9-RM1 control: a bare ";" with no verb segment still denies');
}

$? = 0;
done_testing();
