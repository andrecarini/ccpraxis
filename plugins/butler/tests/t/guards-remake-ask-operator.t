#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 14-guards-remake batch 3 (blueprint
# hook-continuity-remake), AO-1..AO-9 and the applicable SH-1..SH-9 of
# specs/14-guards-remake-spec.md sec 3.4/4.3/4.7: the guard-ask-operator
# successor (GuardAskOperator, against the legacy queue, Decision 22),
# running on the package-03 hook core.
#
# hooks/guard-ask-operator.sh and BpHook/Guards/GuardAskOperator.pm
# DO NOT EXIST YET. Every in-process call goes through
# GuardHarness::run_module() (batch 1's harness,
# plugins/butler/tests/lib/GuardHarness.pm), which mirrors BpHook::main()'s
# own require-and-call contract, so a missing module fails open (rc 0)
# exactly as the real wrapper would -- legibly, never a crash in this file.
# Every [wrapper]/[shim] case spawns the real bash file at that path and
# gets a plain "No such file or directory" until the implementer writes it.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text
# above, never from reading the old guard-ask-operator.sh (used only as a
# non-code cross-check of the questions.md line format that
# plugins/butler/scripts/butler-continuity.pl's "ask" verb writes, per
# AO-7 -- that format is never spawned here, only replicated by regex).
#
# NOT RE-EXPRESSED (per spec sec 4.7 "Not:" list and sec 4.2's codes;
# Decision 26 exemption highlighted separately):
#   old file / assertion label                                   | code
#   ------------------------------------------------------------- | ----
#   no-halt-for-questions.t AC8 "like .run-finished"              | OVR (Decision 6 retired override:
#     (the .drive-solo/.run-finished remedy sentence)               |   .drive-solo/.run-finished --
#                                                                    |   listed for Decision 26)
#   no-halt-for-questions.t AC8 "like only the operator"          | OVR (Decision 6 retired override:
#     (the "only the operator" remedy sentence)                    |   same override family as above --
#                                                                    |   listed for Decision 26)
#   no-halt-for-questions.t AC6                                   | OTHER (butler-continuity; package 04
#                                                                    owns the "ask" verb itself)
#   no-halt-for-questions.t ROOT-A                                | OTHER (a root-resolution population
#                                                                    this successor does not have)
#   no-halt-for-questions.t ROOT-BPPR                             | OTHER (same file's own naming; folded
#                                                                    into this file's AO-6, which now
#                                                                    asserts BP_PROJECT_ROOT is IGNORED --
#                                                                    Decision 108, spec 09 sec 2.5)
#   no-halt-for-questions.t ROOT-C                                | OTHER (a root-resolution population
#                                                                    this successor does not have)
#   no-halt-for-questions.t ROOT-B/ROOT-D, writer halves          | OTHER (the WRITER side of those
#                                                                    scenarios belongs to whatever wrote
#                                                                    the legacy state, not this guard)
#   old "guard-ask-operator.sh exists" file-existence check       | SRC
#
# Queue assertions re-pointed at the almanac decision store by package 09
# (Decision 108); reason codes above are unaffected -- this file's own
# queue assertions are re-pointed, not weakened.
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

# spec 01-inbox-rename: GuardAskOperator now files into Almanac::Inbox
# (almanac-inbox.pl), not Almanac::Decision -- guarded, house not-yet-built
# pattern.
{
    local $@;
    eval { require(Cwd::abs_path(dirname(__FILE__) . '/../../../almanac/scripts/almanac-inbox.pl')); 1 }
        or diag("almanac-inbox.pl did not load (expected until package 01-inbox-rename renames it): $@");
}

# filed($root) -- the almanac inbox store's own records for $root.
sub filed {
    my ($root) = @_;
    return [] unless -d "$root/.ccpraxis-local-data/almanac/inbox";
    return [] unless defined &Almanac::Inbox::list_items;
    my $list = eval { Almanac::Inbox::list_items(root => $root) };
    return (ref $list eq 'ARRAY') ? $list : [];
}

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front. R9-RM4 (review M4):
# GuardHarness.pm itself now isolates the environment unconditionally at
# "use GuardHarness;" above (deletes BP_*/CCPRAXIS_*/CLAUDE_*, deletes any
# inherited BUTLER_STATE_DIR, pins a decoy HOME/USERPROFILE), so this block
# is redundant, not load-bearing. The PRIOR claim here that "every
# individual block wraps its own env changes in local %ENV = %ENV" was
# false (no such wrap exists anywhere in this file) and is removed.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $BUTLER_DIR = dirname(__FILE__) . '/../..';

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
    open(my $fh, '>:raw', $p) or die "cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}

# ---------------------------------------------------------------------------
# payload(%o) -- an AskUserQuestion (or other tool) tool_input payload.
# %o: tool (default 'AskUserQuestion'), questions (arrayref of question
# strings; undef entries become absent/gap markers), session_id, cwd.
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $tool = $o{tool} // 'AskUserQuestion';
    my $ti = {};
    if (exists $o{questions}) {
        $ti->{questions} = [ map { defined $_ ? { question => $_ } : {} } @{ $o{questions} } ];
    }
    my $p = { tool_name => $tool, tool_input => $ti };
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    $p->{agent_id}   = $o{agent_id}   if exists $o{agent_id};
    $p->{cwd}        = $o{cwd}        if exists $o{cwd};
    return $p;
}

# ---------------------------------------------------------------------------
# ao($payload, %opts) -- GuardHarness::run_module for Guards::GuardAskOperator.
# ---------------------------------------------------------------------------
sub ao {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('Guards::GuardAskOperator', $p,
        env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ---------------------------------------------------------------------------
# mk_root() -- a fresh tempdir laid out as a project root, marked with
# .ccpraxis-local-data so BpProjectRoot's cwd-walk fallback can find it.
# ---------------------------------------------------------------------------
sub mk_root {
    my $t = tempdir(CLEANUP => 1);
    (my $root = $t) =~ s{\\}{/}g;
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub questions_path { my ($root) = @_; return "$root/.ccpraxis-local-data/.subagent-guard/questions.md" }
sub no_legacy { return !-e "$_[0]/.ccpraxis-local-data/.subagent-guard/questions.md" }

my $ISO_RE = qr/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/;

# ===========================================================================
# SH-1/SH-2 -- static shape.
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/guard-ask-operator.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/GuardAskOperator.pm";
    ok(-f $wrapper, 'SH-1 precondition: guard-ask-operator.sh exists on disk')
        or diag("missing: $wrapper (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-1: wrapper missing', 2 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'SH-1: bash -n on guard-ask-operator.sh passes');
        my $src = read_bytes($wrapper) // '';
        like($src, qr/Guards::GuardAskOperator/,
             'SH-1: the wrapper names the Guards::GuardAskOperator module');
    }
    ok(-f $module, 'SH-2 precondition: BpHook/Guards/GuardAskOperator.pm exists on disk')
        or diag("missing: $module (package 14 has not written it yet)");
  SKIP: {
        skip 'SH-2: module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'SH-2: perl -c on GuardAskOperator.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
               'SH-2: the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# AO-1 -- an armed session (manual, driver, reporter) denies with the ARMED
# WHY, exactly 4 lines, and files NOTHING.
#
# AMENDED by bug 20261116-132008-3692: this used to pin that the deny filed
# the raw question as an inbox item (AC17/AC29 of spec 01-inbox-rename).
# That auto-filing was one of three unguarded paths by which technical
# questions reached the operator, who could not answer them; nothing
# classified the text. The deny now files nothing and tells the session to
# decide itself, filing deliberately and in product terms only a product
# decision. The positive filing assertions are inverted, not dropped, so a
# regression back to auto-filing fails here.
# ===========================================================================
for my $role (qw(manual driver reporter)) {
    my $root = mk_root();
    GuardHarness::fresh_state();
    my $sid = "ao1-$role";
    ok(GuardHarness::arm($sid, $role), "AO-1 setup: session armed (role $role)");

    my $res = ao(payload(session_id => $sid, cwd => $root, questions => ['Should I rename it?']),
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res->{rc}, 2, "AO-1 (role $role): deny");
    my @lines = split /\n/, $res->{err};
    pop @lines while @lines && $lines[-1] eq '';
    is(scalar(@lines), 4, "AO-1 (role $role): exactly 4 lines");
    like($lines[0], qr/\bARMED\b/, "AO-1 (role $role): line 1 contains ARMED");
    like($lines[0], qr/^BLOCKED: continuity is ARMED for this session, so asking the operator would stop unattended work for an answer nobody is there to give\.$/,
         "AO-1 (role $role): exact line 1 text");
    like($lines[1], qr/^Nothing was filed\. Decide it yourself/,
         "AO-1 (role $role): line 2 says nothing was filed and to decide it yourself");
    like($lines[2], qr/no technical explanation .*in product terms, with almanac inbox file\.$/,
         "AO-1 (role $role): line 3 names the deliberate, product-terms route");

    is(scalar(@{ filed($root) }), 0, "AO-1 (role $role): no inbox item filed");
    ok(!-d "$root/.ccpraxis-local-data/almanac", "AO-1 (role $role): no almanac/ dir was created");
    ok(no_legacy($root), "AO-1 (role $role): no legacy questions.md was written");
}

# ===========================================================================
# AO-2 -- unarmed, BP_LEDGER unset: exit 0, nothing written.
# ===========================================================================
{
    my $root = mk_root();
    GuardHarness::fresh_state();
    my $res = ao(payload(session_id => 'ao2-unarmed', cwd => $root, questions => ['Anybody home?']),
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res->{rc}, 0, 'AO-2: unarmed, BP_LEDGER unset -> exit 0');
    ok(!-e questions_path($root), 'AO-2: nothing written to questions.md');
    ok(!-d "$root/.ccpraxis-local-data/.subagent-guard", 'AO-2: the queue directory itself was never created');
    ok(!-d "$root/.ccpraxis-local-data/almanac", 'AO-2: no almanac/ dir was created');
}

# ===========================================================================
# AO-3 -- bug 20260922-210421-0468 regression: session isolation. Session B
# armed, session A unarmed -> A allows, even with stale legacy state present.
# ===========================================================================
{
    my $root = mk_root();
    my $state = GuardHarness::fresh_state();
    my $sidA = 'ao3-a-unarmed';
    my $sidB = 'ao3-b-armed';
    ok(GuardHarness::arm($sidB, 'manual'), 'AO-3 setup: session B armed');

    # Plant stale/legacy project-wide state that a defective implementation
    # might consult instead of the per-session arm file.
    make_path("$root/.ccpraxis-local-data/.subagent-guard");
    write_bytes("$root/.ccpraxis-local-data/.subagent-guard/run-state.json", qq({"state":"active"}\n));
    make_path("$root/.ccpraxis-local-data/.continuity-active");
    write_bytes("$root/.ccpraxis-local-data/.continuity-active/$sidA", "1\n");

    my $res = ao(payload(session_id => $sidA, cwd => $root, questions => ['Is anyone driving?']),
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res->{rc}, 0,
       'AO-3 (bug 0468 regression): session A (never armed) allows despite session B being armed, '
     . 'a project-wide run-state.json "active", and a legacy .continuity-active registry file for A');
}

# ===========================================================================
# AO-4 -- BP_LEDGER set (coordinator): deny with the coordinator WHY;
# BP_ROLE=harvest-judge -> allow.
# ===========================================================================
{
    my $root = mk_root();
    my $res_coord = ao(payload(session_id => 'ao4-coord', cwd => $root, questions => ['Proceed?']),
        env => { CLAUDE_PROJECT_DIR => $root, BP_LEDGER => '/x/ledger.md' });
    is($res_coord->{rc}, 2, 'AO-4: BP_LEDGER set (coordinator) -> deny');
    my @lines = split /\n/, $res_coord->{err};
    like($lines[0], qr/^BLOCKED: this is a headless coordinator session, so asking the operator would stop unattended work for an answer nobody is there to give\.$/,
         'AO-4: exact coordinator WHY line');
    # Bug 20261116-132008-3692: a coordinator's channel is the ledger
    # escalation, which the resolver judges; nothing is filed for it.
    like($res_coord->{err}, qr/bp-ledger\.pl set-escalation, then set status: blocked/,
         'AO-4: the coordinator is sent to the ledger escalation');
    ok(!-d "$root/.ccpraxis-local-data/almanac", 'AO-4: nothing filed for the coordinator');

    my $res_judge = ao(payload(session_id => 'ao4-judge', cwd => $root, questions => ['Proceed?']),
        env => { CLAUDE_PROJECT_DIR => $root, BP_LEDGER => '/x/ledger.md', BP_ROLE => 'harvest-judge' });
    is($res_judge->{rc}, 0, 'AO-4: BP_LEDGER set but BP_ROLE=harvest-judge -> allow (judge never armed)');
}

# ===========================================================================
# AO-5/AO-6/AO-7 -- AMENDED by bug 20261116-132008-3692.
#
# These used to pin how the auto-filed inbox item was built: the question
# text joined across calls and shapes (AO-5), which project root it was
# filed under (AO-6, Decision 108), and the filed record's fields (AO-7).
# The guard no longer files anything -- the raw question text, filed
# unclassified, is how technical questions reached an operator who could not
# answer them -- so there is no text to assemble, no root to resolve and no
# record to shape. What survives of each is the part that is still a
# contract: every payload shape is still denied while armed (AO-5), no root
# is ever written under, whichever of cwd / CLAUDE_PROJECT_DIR /
# BP_PROJECT_ROOT is set, and a missing root no longer changes the deny
# (AO-6), and repeated calls never accumulate records (AO-7).
# ===========================================================================
{
    my $root = mk_root();
    GuardHarness::fresh_state();
    my $sid = 'ao5-sid';
    ok(GuardHarness::arm($sid, 'manual'), 'AO-5 setup: session armed');
    my %env = (CLAUDE_PROJECT_DIR => $root);
    my @shapes = (
        [ 'one question',          payload(session_id => $sid, cwd => $root, questions => ['First question?']) ],
        [ 'two questions',         payload(session_id => $sid, cwd => $root, questions => ['Third-a?', 'Third-b?']) ],
        [ 'seventeen questions',   payload(session_id => $sid, cwd => $root, questions => [ map { "Q$_?" } (1 .. 17) ]) ],
        [ 'an embedded CR/LF',     payload(session_id => $sid, cwd => $root, questions => ["line one\r\nline two"]) ],
        [ 'no question text',      payload(session_id => $sid, cwd => $root, tool => 'AskUserQuestion') ],
    );
    for my $s (@shapes) {
        my ($label, $p) = @$s;
        my $res = ao($p, env => \%env);
        is($res->{rc}, 2, "AO-5: $label -> still denied while armed");
        like($res->{err}, qr/^Nothing was filed\./m, "AO-5: $label -> the deny says nothing was filed");
    }
    is(scalar(@{ filed($root) }), 0, 'AO-5/AO-7: five denied calls filed zero inbox items');
    ok(!-d "$root/.ccpraxis-local-data/almanac", 'AO-5/AO-7: no almanac/ dir was ever created');
    ok(no_legacy($root), 'AO-5/AO-7: no legacy questions.md was written');
}

{
    my $root_cpd  = mk_root();
    my $root_bppr = mk_root();
    my $root_cwd  = mk_root();
    my $sub = "$root_cwd/sub/dir";
    make_path($sub);
    my @cases = (
        [ 'cwd nonexistent, CLAUDE_PROJECT_DIR and BP_PROJECT_ROOT set', 'ao6-a', '/nonexistent/wherever',
          { CLAUDE_PROJECT_DIR => $root_cpd, BP_PROJECT_ROOT => $root_bppr } ],
        [ 'cwd nonexistent, only BP_PROJECT_ROOT set', 'ao6-b', '/nonexistent/wherever', { BP_PROJECT_ROOT => $root_bppr } ],
        [ 'cwd a project, no env', 'ao6-c', $root_cwd, {} ],
        [ 'no cwd, no env', 'ao6-d', undef, {} ],
        [ 'cwd under a project, CLAUDE_PROJECT_DIR elsewhere', 'ao6-e', $sub, { CLAUDE_PROJECT_DIR => $root_cpd } ],
    );
    for my $c (@cases) {
        my ($label, $sid, $cwd, $env) = @$c;
        ok(GuardHarness::arm($sid, 'manual'), "AO-6 setup: $label");
        my $res = ao(payload(session_id => $sid, (defined $cwd ? (cwd => $cwd) : ()), questions => ['Which root?']),
            env => $env);
        is($res->{rc}, 2, "AO-6: $label -> denied");
        unlike($res->{err}, qr/could not be filed/, "AO-6: $label -> no could-not-be-filed variant any more");
    }
    for my $r ($root_cpd, $root_bppr, $root_cwd) {
        ok(!-d "$r/.ccpraxis-local-data/almanac", "AO-6: nothing written under $r");
    }
}

# ===========================================================================
# AO-8 -- any tool other than AskUserQuestion allows, nothing written, even
# when armed.
# ===========================================================================
{
    my $root = mk_root();
    my $sid = 'ao8-other-tool';
    ok(GuardHarness::arm($sid, 'manual'), 'AO-8 setup: session armed');
    for my $tool (qw(Bash Write Read Task)) {
        my $res = ao({ tool_name => $tool, tool_input => {}, session_id => $sid, cwd => $root },
            env => { CLAUDE_PROJECT_DIR => $root });
        is($res->{rc}, 0, "AO-8: tool $tool allows even though the session is armed");
    }
    ok(!-e questions_path($root), 'AO-8: nothing was written for any non-AskUserQuestion tool');
    ok(!-d "$root/.ccpraxis-local-data/almanac", 'AO-8: no almanac/ dir was created');
}

# ===========================================================================
# AO-9 -- the remaining shared ACs.
# ===========================================================================

# SH-5 -- run() leaves BpHook::parse_count() unchanged, deny and allow.
{
    my $root = mk_root();
    my $sid = 'ao9-sh5-armed';
    ok(GuardHarness::arm($sid, 'manual'), 'SH-5 setup: session armed');
    my $res_deny = ao(payload(session_id => $sid, cwd => $root, questions => ['x?']),
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res_deny->{parse_delta}, 0, 'SH-5: parse_count unchanged on a deny path');

    my $res_allow = ao(payload(session_id => 'ao9-sh5-unarmed', cwd => $root, questions => ['x?']),
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res_allow->{parse_delta}, 0, 'SH-5: parse_count unchanged on an allow path');
}

# SH-6 -- budget (4 lines for this successor) and forbidden vocabulary.
{
    my $root = mk_root();
    my $sid = 'ao9-sh6';
    ok(GuardHarness::arm($sid, 'manual'), 'SH-6 setup: session armed');
    my $res = ao(payload(session_id => $sid, cwd => $root, questions => ['x?']),
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res->{rc}, 2, 'SH-6 setup: the fixture is really a deny');
    my @lines = split /\n/, $res->{err};
    pop @lines while @lines && $lines[-1] eq '';
    cmp_ok(scalar(@lines), '<=', 4, 'SH-6: at most the guard-ask-operator budget of 4 lines');
    for my $l (@lines) {
        cmp_ok(length($l), '<=', 160, 'SH-6: line length <= 160');
        unlike($l, qr/\.run-finished|stop-ok|\.subagent-guard\/force-stop|CCPRAXIS_[A-Z_]*_STOP_OK|MAX_BLOCKS|bp-watch|bp-continuity\.pl|bp-runstate/,
               'SH-6: line names no retired mechanism');
        unlike($l, qr/BP_[A-Z_]*_ACTION|_OFF\b|threshold/i,
               'SH-6: line names no disable-a-guard hatch');
    }
    is($res->{out}, '', 'SH-6: stdout is empty');
}

# SH-7 -- bad JSON, truncated payload, {} -> exit 0, no output (unarmed and
# BP_LEDGER unset, so no signal complicates the baseline for this successor).
{
    for my $c (
        ['not json at all'                          => 'malformed JSON'],
        ['{"tool_input":{"questions":[{"question"'   => 'truncated JSON'],
        ['{}'                                        => 'empty object'],
    ) {
        my ($raw, $label) = @$c;
        my %e = ($label eq 'truncated JSON') ? (BP_PAYLOAD_TRUNCATED => 1) : ();
        my $res = ao($raw, env => \%e);
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
        pass('SH-9: opt-in timing harness placeholder -- run this file alone with '
           . 'GUARDS_REMAKE_TIME=1 to record medians against the package-01 item (g) '
           . 'floor + 100ms; wall time itself is never asserted here');
    }
}

# ===========================================================================
# [wrapper]/[shim] cases: SH-3 (not-applies: unarmed, BP_LEDGER unset) and
# SH-4 (applies: armed).
# ===========================================================================
{
    my $root = mk_root();

    my $res_not_applies = GuardHarness::run_shim('guard-ask-operator.sh',
        { tool_name => 'AskUserQuestion', tool_input => { questions => [{ question => 'x?' }] },
          session_id => 'ao-shim-unarmed', cwd => $root },
        env => { CLAUDE_PROJECT_DIR => $root });
    is($res_not_applies->{rc}, 0, 'SH-3: unarmed, BP_LEDGER unset -> exit 0');
    is($res_not_applies->{out}, '', 'SH-3: empty stdout');
    is($res_not_applies->{err}, '', 'SH-3: empty stderr');
    is(GuardHarness::count_lines($res_not_applies->{shim_log}, 'perl'), 0,
       'SH-3: 0 perl launches (the wrapper exits in bash before ever reaching perl)');

    my $base = GuardHarness::fresh_state();
    my $sid = 'ao-shim-armed';
    ok(GuardHarness::arm($sid, 'manual'), 'SH-4 setup: session armed');
    my $res_applies = GuardHarness::run_shim('guard-ask-operator.sh',
        { tool_name => 'AskUserQuestion', tool_input => { questions => [{ question => 'x?' }] },
          session_id => $sid, cwd => $root },
        env => { CLAUDE_PROJECT_DIR => $root, BUTLER_STATE_DIR => $base });
    is($res_applies->{rc}, 2, 'SH-4: an armed session reaches perl and denies');
    is(GuardHarness::count_lines($res_applies->{shim_log}, 'perl'), 1,
       'SH-4: exactly 1 perl launch');
}

# ===========================================================================
# Harness self-check -- confirms GuardHarness itself works, against a real
# EXISTING successor (stop-gate.sh, package 06), not GuardAskOperator. Proves
# a red result above is guard-ask-operator's absence, not a harness defect.
# Repeats batch 1's own self-check independently, since this file must stand
# on its own when the runner parallelises files.
# ===========================================================================
{
    my $stopgate = "$BUTLER_DIR/hooks/stop-gate.sh";
    ok(-f $stopgate, 'self-check precondition: stop-gate.sh (package 06) exists on disk');

    my $res_wrapper = GuardHarness::run_wrapper($stopgate,
        { session_id => 'aoselfcheck-1', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_wrapper->{rc}, 0, 'self-check: run_wrapper against the real stop-gate.sh (unarmed) allows');

    my $res_shim = GuardHarness::run_shim($stopgate,
        { session_id => 'aoselfcheck-2', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim->{rc}, 0, 'self-check: run_shim against the real stop-gate.sh (unarmed) allows');
    is(GuardHarness::count_lines($res_shim->{shim_log}, 'perl'), 0,
       'self-check: run_shim reports 0 perl launches on stop-gate.sh\'s not-applies path (unarmed)');

    ok(GuardHarness::arm('aoselfcheck-3', 'manual'), 'self-check: GuardHarness::arm() armed a session');
    my $res_shim_armed = GuardHarness::run_shim($stopgate,
        { session_id => 'aoselfcheck-3', hook_event_name => 'Stop', stop_hook_active => JSON::PP::false() });
    is($res_shim_armed->{rc}, 2, 'self-check: run_shim against stop-gate.sh, now armed -> denies (applies path)');
    is(GuardHarness::count_lines($res_shim_armed->{shim_log}, 'perl'), 1,
       'self-check: ...with exactly 1 perl launch');

    ok(GuardHarness::arm('aoselfcheck-run-module-armed', 'manual'),
       'self-check/run_module setup: a distinct session armed');
    my $res_module_armed = GuardHarness::run_module('StopGate',
        { session_id => 'aoselfcheck-run-module-armed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_armed->{rc}, 2,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, armed -> denies '
     . '(proves run_module really requires BpHook/StopGate.pm by relative path and calls its '
     . 'run(), rather than failing open silently)');

    my $res_module_unarmed = GuardHarness::run_module('StopGate',
        { session_id => 'aoselfcheck-run-module-unarmed', hook_event_name => 'Stop',
          stop_hook_active => JSON::PP::false() });
    is($res_module_unarmed->{rc}, 0,
       'self-check: run_module("StopGate", ...) against the real StopGate.pm, a DIFFERENT and '
     . 'never-armed session -> allows');
}

$? = 0;
done_testing();
