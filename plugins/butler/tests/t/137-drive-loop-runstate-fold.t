#!/usr/bin/env perl
# 137-drive-loop-runstate-fold.t — the w02 FOLD: gate-drive-loop.sh consults
# bp-runstate.pl's effective 'paused' state as an ADDITIONAL escape from
# BLOCK, on top of everything t/94-drive-loop-gate.t already pins.
#
# Spec: .../specs/w02-dispatch-budget-and-interrupt-spec.md §2.1 (design),
# §3 behaviors 9-12, §4 AC9, §5 (edge cases: unreadable/malformed runstate,
# stale pause via dead pid, stale pause via elapsed deadline).
#
# THIS FILE DOES NOT TOUCH t/94-drive-loop-gate.t. Section H there
# (:274-322) pins the hard constraint this fold must survive: 'in-flight'
# + nothing scheduled must still BLOCK. That file is read-only ground
# truth here, not duplicated — this file adds a NEW, clearly-labeled
# section ("I") on an otherwise-identical fixture, per spec §2.1's own
# instruction not to add the runstate fixture into H's existing block (so
# "H is untouched" stays independently verifiable by diff).
#
# Fixture helpers below are a DELIBERATE, LIGHT adaptation of t/94's own
# new_project/project_with_package/run_hook — not an import (t/94 has no
# exported library), reproduced here so this file is self-contained and a
# change to t/94's internals cannot silently break this file's fixtures
# without the diff being visible in THIS file's own history.
#
# NON-VACUITY, spelled out per behavior (see also inline comments):
#   - Behavior 9 (H1-shape, no run-state.json at all) currently ALSO passes
#     with NO fold present — it is the "fold is inert against H's fixture"
#     proof, not a red-before-green assertion. It is still load-bearing:
#     the plausible WRONG implementation ("in-flight -> allow, unconditionally")
#     would flip this to rc==0 and fail it.
#   - Behavior 10 (verified live pause) is the ONE assertion that is RED
#     today (current gate-drive-loop.sh never reads bp-runstate.pl at all,
#     so this fixture BLOCKS exactly like H1) and must turn GREEN once the
#     fold lands. This is the "MUST NOW PASS" acceptance case named in the
#     dispatch prompt.
#   - Behaviors 11/12 (stale pause: dead deadline, dead pid) also currently
#     pass VACUOUSLY pre-fold (today's gate blocks everything in-flight,
#     coincidentally including these). They stop being vacuous the moment a
#     fold exists: a fold implemented as a blanket "in-flight -> allow"
#     (the plausible WRONG shape) would flip BOTH to rc==0 and fail them.
#     They are the guard-rail against exactly that wrong implementation,
#     not a currently-red assertion — recorded honestly, not disguised.
#
# Runs standalone: perl plugins/butler/tests/t/137-drive-loop-runstate-fold.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);

my $HOOKS = "$Bin/../../hooks";
my $GATE  = "$HOOKS/gate-drive-loop.sh";

ok(-f $GATE, 'A0: gate-drive-loop.sh exists (sanity — this file assumes it, per spec §2.1: '
           . 'the fold is additive to an EXISTING file, never a new one)');

our $ACTIVE  = '';
our $SESSION = 'sess-fold-under-test';

sub new_project {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    $ACTIVE = "$root/.active-drivers";
    make_path($ACTIVE);
    if ($opt{order}) {
        open my $fh, '>', "$ds/order.json" or die;
        print {$fh} '{"order":["x"],"recorded_at":1}';
        close $fh;
        open my $m, '>', "$ACTIVE/$SESSION" or die;
        print {$m} "$root/.ccpraxis-local-data\n";
        close $m;
    }
    return ($root, $ds);
}

sub run_hook {
    my ($script, $payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_USAGE_VERDICT_JSON='{\"action\":\"ok\"}' " if $opt{verdict_ok};
    $env .= "CCPRAXIS_DRIVE_ACTIVE_DIR='$ACTIVE' " if length $ACTIVE;
    my $out = `$env bash "$script" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub payload_stop { my $cwd = shift; qq({"session_id":"$SESSION","cwd":"$cwd"}) }

# project_with_package — DELIBERATELY BYTE-FOR-BYTE the same shape as t/94's
# own fixture (director answers 'in-flight' for a 'running' package, no
# .subagent-guard/run-state.json at all unless a caller adds one).
sub project_with_package {
    my (%opt) = @_;
    my ($root, $ds) = new_project(order => 1);
    my $bpdir = "$root/.ccpraxis-local-data/blueprints/x";
    make_path("$bpdir/packages");
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print {$b} "# x\n\n| pkg | depends_on |\n|---|---|\n| p1 |  |\n";
    close $b;
    open my $p, '>', "$bpdir/packages/p1.md" or die;
    print {$p} "---\npackage: p1\nstatus: $opt{status}\n---\n\nbody\n";
    close $p;
    return ($root, $ds);
}

sub runstate_path {
    my ($root) = @_;
    return "$root/.ccpraxis-local-data/.subagent-guard/run-state.json";
}

sub write_runstate {
    my ($root, $json_text) = @_;
    my $p = runstate_path($root);
    make_path(dirname($p));
    open my $fh, '>', $p or die "write run-state.json: $!";
    print {$fh} $json_text;
    close $fh;
}

# ===========================================================================
# I1 (behavior 9). EXACT COPY of t/94's H1 fixture — no run-state.json at
# all. Proves the fold is inert against H's own fixture BY CONSTRUCTION:
# bp-runstate.pl status against a project with no .subagent-guard/run-
# state.json returns 'inert', not 'paused', so the fold's new case-arm
# matches nothing and execution falls through to the unchanged BLOCK.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'I1 (behavior 9): H1-shape fixture (in-flight, NO run-state.json at all) still '
             . 'BLOCKS — the fold adds nothing here. A "blanket in-flight -> allow" wrong '
             . 'implementation would flip this to 0 and fail it.');
    like($out, qr/in-flight/, 'I1: block still names the in-flight action');
}

# ===========================================================================
# I2 (behavior 10) — THE ACCEPTANCE CASE. Same director answer as I1
# ('in-flight'), but bp-runstate.pl now reports a VERIFIED live pause: a
# real pid (this test process's own $$, guaranteed alive for the duration
# of this call) and a deadline in the future. THIS is the exact shape that
# has blocked the driver all session: a WAITING turn, .wakeup-pending
# already consumed, director says in-flight, bp-runstate says paused with a
# live watcher and a future deadline. Today (pre-fold) this BLOCKS (rc==2,
# identical to I1) — that is the RED this file exists to turn GREEN.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my $until = time() + 300;
    write_runstate($root, qq({"state":"paused","watcher_pid":$$,"until":$until}));
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 0, 'I2 CANONICAL (behavior 10 / AC9 acceptance case): in-flight + a VERIFIED live '
             . 'pause (live pid, future deadline) ALLOWS the stop — same director answer as '
             . 'I1, only the runstate differs. This is the exact turn shape that has blocked '
             . 'this driver session repeatedly; it must stop blocking once the fold lands.');
}

# ===========================================================================
# I3 (behavior 11) — a pause whose DEADLINE has passed is STALE.
# bp-runstate.pl::effective reverts a stale pause to 'active' before the
# fold ever sees it (the fold performs no bound-checking of its own — it
# only reads the already-verified answer). Must still BLOCK.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my $past = time() - 100;
    write_runstate($root, qq({"state":"paused","watcher_pid":$$,"until":$past}));
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'I3 (behavior 11): in-flight + a pause whose "until" has ALREADY PASSED still '
             . 'BLOCKS — a stale deadline is not a confirmed watcher, and the fold must not '
             . 'do its own bound-checking to rescue it.');
}

# ===========================================================================
# I4 (behavior 12) — a pause whose watcher_pid is NOT RUNNING is stale by
# the other axis. Same reasoning as I3, different failure mode.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    my $future = time() + 300;
    # A pid astronomically unlikely to be alive on any real system, per the
    # spec's own suggested fixture shape (§3 behavior 12).
    write_runstate($root, qq({"state":"paused","watcher_pid":99999999,"until":$future}));
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'I4 (behavior 12): in-flight + a pause whose watcher_pid is NOT running still '
             . 'BLOCKS — "a watcher process exists" is not the claim; "THIS specific pid, '
             . 'recorded at pause time, is alive right now" is, and it is not.');
}

# ===========================================================================
# I5 (edge case, spec §5) — a run-state.json that is malformed JSON. The
# fold's own status call fails; RST stays empty/unparseable; the case
# matches nothing; execution falls through to the UNCHANGED BLOCK path.
# The safe direction: an error in the NEW check must never silently grant
# the escape it did not earn.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    write_runstate($root, '{not valid json at all');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'I5 (edge case): malformed run-state.json still BLOCKS — an unreadable '
             . 'answer from the new check must fail closed, not fail open into an allow');
}

# ===========================================================================
# I6 (edge case, spec §5) — a run-state.json claiming state:paused but
# MISSING watcher_pid/until entirely. bp-runstate.pl::effective already
# treats an incomplete pause record's liveness check as failing closed
# (pid_alive(undef) is 0) — the fold inherits this for free by only ever
# reading the already-validated effective state, never the raw record.
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    write_runstate($root, '{"state":"paused"}');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'I6 (edge case): a "paused" record with NO watcher_pid/until still BLOCKS — '
             . 'an incomplete pause record fails closed, inherited from bp-runstate.pl '
             . 'effective(), not reimplemented by the fold');
}

# ===========================================================================
# I7 — the counter-fixture check: a genuinely 'active' (not 'paused') run-
# state must not accidentally satisfy the case arm either (belt-and-braces
# against a regex that matches too loosely, e.g. matching "paused" as a
# substring of something else).
# ===========================================================================
{
    my ($root) = project_with_package(status => 'running');
    write_runstate($root, '{"state":"active","reason":"run in progress"}');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'I7: an explicitly ACTIVE (not paused) run-state still BLOCKS');
}

done_testing();
