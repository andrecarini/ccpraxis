#!/usr/bin/env perl
# 94-drive-loop-gate.t — the drive-solo driver's stop discipline.
#
# WHAT IS BEING PROTECTED
#
# /butler:drive-solo casts the driver as "a thin loop over the director": call
# bp-drive-next.pl next, dispatch the action, call next again. That is prose,
# and prose decays over a long context. Observed three times in a single 12-hour
# run on 2026-08-07: a driver turn ended immediately after a ledger write, its
# text promising the next step, with nothing scheduled to perform it. A
# dispatched agent notifies; a finished FOREGROUND Bash call does not. So the
# run died silently, mid-package, LOOKING finished — the worst property an
# unattended run can have, because the operator only discovers it by asking.
#
# gate-stop.sh already makes this argument one level down, for coordinators:
# it "converts ledger discipline from a prompt rule (which decays over long
# contexts) into a mechanical gate". But every butler hook opens with
# bp_hook_gate, which requires BP_LEDGER — exported only into coordinator
# processes. The DRIVER, the one participant nothing supervises, therefore had
# no stop discipline at all.
#
# THE RULE, in one line:
#   A driver turn may end EITHER because something will wake the session,
#   OR because the director says the run is settled. Never otherwise.
#
# The two hooks under test implement it as a pair: mark-wakeup.sh (PreToolUse)
# records that this turn scheduled a wake-up; gate-drive-loop.sh (Stop) consumes
# that marker, and blocks the stop when there is none and the director still
# has work.
#
# POSTURE UNDER TEST. A stop gate that misfires traps a human's session, which
# is strictly worse than the bug it prevents. So the safety properties below
# (bounded blocking, both escape hatches, fail-open, correct scoping) matter at
# least as much as the blocking behaviour itself, and each is asserted.
#
# Runs standalone: perl plugins/butler/tests/t/94-drive-loop-gate.t
# (`prove` does not exist on the Git-for-Windows host.) No container, no
# network, no launcher spawn; every fixture lives under File::Temp.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";

# ---------------------------------------------------------------------------
# A. The hooks exist and are registered. An unregistered hook is inert, and an
#    inert gate is indistinguishable from no gate at all.
# ---------------------------------------------------------------------------
ok(-f $MARK, 'A1: mark-wakeup.sh exists');
ok(-f $GATE, 'A2: gate-drive-loop.sh exists');

my $hooks_json = do { local (@ARGV, $/) = ("$HOOKS/hooks.json"); <> };
ok(defined $hooks_json && length $hooks_json, 'A3: hooks.json is readable');
like($hooks_json, qr/gate-drive-loop\.sh/,
     'A4: gate-drive-loop.sh is REGISTERED in hooks.json (an unregistered gate is inert)');
like($hooks_json, qr/mark-wakeup\.sh/,
     'A5: mark-wakeup.sh is REGISTERED in hooks.json');

# The Stop array must carry the gate, not merely the file mention it somewhere.
my ($stop_block) = $hooks_json =~ /"Stop"\s*:\s*(\[.*?\])\s*\}\s*\}\s*$/s;
$stop_block = '' unless defined $stop_block;
like($stop_block, qr/gate-drive-loop\.sh/,
     'A6: the gate is registered specifically under the Stop event');

# ---------------------------------------------------------------------------
# Helpers. Each case gets its own project root so no test can see another's
# state — the .drive-solo dir IS the hooks' activation signal.
# ---------------------------------------------------------------------------
# The ACTIVE-DRIVER REGISTRY for the project under test. The gate is scoped by
# SESSION now, not by directory: it asks "is this session driving", answered by
# a marker that mark-wakeup.sh writes when a session calls the director.
#
# RE-POINTED, NOT WEAKENED. These fixtures used to arm the gate merely by
# creating .drive-solo/order.json, which is exactly the defect that scoping
# change fixed — that test was true for every session in the tree, including
# ones that had never driven anything, and it never became false when a run
# finished. Every claim below is unchanged; only the way a fixture declares
# "this session is the driver" has moved.
our $ACTIVE  = '';
our $SESSION = 'sess-under-test';

sub new_project {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    $ACTIVE = "$root/.active-drivers";
    make_path($ACTIVE);
    # order.json is what marks a run as "in progress"; omit it to model a
    # project where drive-solo has never run.
    if ($opt{order}) {
        open my $fh, '>', "$ds/order.json" or die;
        print {$fh} '{"order":["x"],"recorded_at":1}';
        close $fh;
        # ... and arm THIS session as the driver, unless the case is
        # specifically about an unarmed one.
        unless ($opt{unarmed}) {
            open my $m, '>', "$ACTIVE/$SESSION" or die;
            print {$m} "$root/.ccpraxis-local-data\n";
            close $m;
        }
    }
    return ($root, $ds);
}

sub run_hook {
    my ($script, $payload, %opt) = @_;
    my $env = '';
    $env = "CCPRAXIS_DRIVE_STOP_OK=1 " if $opt{stop_ok_env};
    # Pin the usage verdict for any case that depends on the director's answer.
    # Without it the director shells out to bp-usage-gate.pl and reads the
    # HOST's real OAuth state, so these assertions would track a token clock:
    # once the token ages under the relogin floor the director answers
    # pause/token, the gate correctly allows the stop, and a green test turns
    # red with no code change. Observed exactly that on 2026-08-08.
    $env .= "CCPRAXIS_USAGE_VERDICT_JSON='{\"action\":\"ok\"}' " if $opt{verdict_ok};
    # Point the hooks at THIS case's driver registry, so no case can see
    # another's arming and nothing touches the real one under $HOME.
    $env .= "CCPRAXIS_DRIVE_ACTIVE_DIR='$ACTIVE' " if length $ACTIVE;
    # Single-quote the payload for sh; payloads here contain no single quotes.
    my $out = `$env bash "$script" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub payload_task { my $cwd = shift; qq({"session_id":"$SESSION","cwd":"$cwd","tool_name":"Task","tool_input":{}}) }
sub payload_bash {
    my ($cwd, $bg) = @_;
    return $bg
        ? qq({"session_id":"$SESSION","cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"ls","run_in_background":true}})
        : qq({"session_id":"$SESSION","cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"ls"}});
}
sub payload_stop { my $cwd = shift; qq({"session_id":"$SESSION","cwd":"$cwd"}) }

# ---------------------------------------------------------------------------
# B. mark-wakeup.sh records exactly the things that schedule a wake-up.
# ---------------------------------------------------------------------------
{
    my ($root, $ds) = new_project(order => 1);

    my ($rc) = run_hook($MARK, payload_task($root));
    is($rc, 0, 'B1: mark-wakeup never blocks (Task)');
    ok(-f "$ds/.wakeup-pending", 'B2: a Task dispatch records a pending wake-up');

    unlink "$ds/.wakeup-pending";
    run_hook($MARK, payload_bash($root, 1));
    ok(-f "$ds/.wakeup-pending",
       'B3: a BACKGROUNDED Bash call records a pending wake-up (its exit notifies)');

    unlink "$ds/.wakeup-pending";
    run_hook($MARK, payload_bash($root, 0));
    ok(!-f "$ds/.wakeup-pending",
       'B4: a FOREGROUND Bash call records NOTHING — it returns into the same turn '
     . 'and schedules no wake-up. (Regression guard: bp_json_get returns EMPTY for '
     . 'JSON booleans, so reading run_in_background through it silently classified '
     . 'every backgrounded call as foreground.)');

    unlink "$ds/.wakeup-pending";
    run_hook($MARK, qq({"cwd":"$root","tool_name":"Read","tool_input":{}}));
    ok(!-f "$ds/.wakeup-pending", 'B5: an unrelated tool records nothing');
}

# ---------------------------------------------------------------------------
# C. Scoping. The gate must be invisible to everyone it does not govern.
# ---------------------------------------------------------------------------
{
    my ($root) = new_project(order => 1);

    my ($rc) = run_hook($GATE, payload_stop($root), stop_ok_env => 1);
    is($rc, 0, 'C1: CCPRAXIS_DRIVE_STOP_OK=1 always allows the stop (session-wide hatch)');

    # A coordinator carries BP_LEDGER; gate-stop.sh owns that session.
    my $out = `BP_LEDGER=/tmp/nonexistent bash "$GATE" <<'EOF' 2>&1
{"cwd":"$root"}
EOF`;
    is($? >> 8, 0, 'C2: a COORDINATOR session (BP_LEDGER set) is untouched — gate-stop.sh owns it');

    my ($rc3) = run_hook($GATE, payload_stop("/tmp"));
    is($rc3, 0, 'C3: a project with no .ccpraxis-local-data is untouched');

    my ($noorder) = new_project(order => 0);
    my ($rc4) = run_hook($GATE, payload_stop($noorder));
    is($rc4, 0, 'C4: a project with .drive-solo but NO order.json is untouched '
              . '(no run has been started, so there is no loop to protect)');
}

# ---------------------------------------------------------------------------
# D. The marker is CONSUMED, not merely read. This is what makes the rule
#    per-turn: one scheduled wake-up buys exactly one turn end.
# ---------------------------------------------------------------------------
{
    my ($root, $ds) = new_project(order => 1);
    run_hook($MARK, payload_task($root));
    ok(-f "$ds/.wakeup-pending", 'D1: marker present before the stop');

    my ($rc) = run_hook($GATE, payload_stop($root));
    is($rc, 0, 'D2: a stop with a pending wake-up is ALLOWED');
    ok(!-f "$ds/.wakeup-pending",
       'D3: the marker is CONSUMED — a second turn cannot reuse the first turn\'s '
     . 'dispatch to justify ending with nothing scheduled');
}

# ---------------------------------------------------------------------------
# E. Fail-open. Every path that cannot reach a verdict must ALLOW the stop.
#    A gate that cannot consult its oracle must never trap the session.
# ---------------------------------------------------------------------------
{
    # order.json present, but the project has no blueprints dir at all, so the
    # director cannot produce an actionable verdict from this root.
    my ($root) = new_project(order => 1);
    my ($rc) = run_hook($GATE, payload_stop($root));
    is($rc, 0, 'E1: when the director cannot return an actionable verdict, the stop '
             . 'is ALLOWED (fail-open: a broken gate must not trap a session)');
}

# ---------------------------------------------------------------------------
# F. The escape hatch is one-shot, so it cannot silently disable the gate.
# ---------------------------------------------------------------------------
{
    my ($root, $ds) = new_project(order => 1);
    open my $fh, '>', "$ds/.stop-ok" or die; close $fh;
    my ($rc) = run_hook($GATE, payload_stop($root));
    is($rc, 0, 'F1: .stop-ok allows the stop');
    ok(!-f "$ds/.stop-ok",
       'F2: .stop-ok is CONSUMED — an operator override applies to one stop, never '
     . 'permanently, so the gate cannot be switched off by accident');
}

# ---------------------------------------------------------------------------
# G. Source-level invariants. These are the properties that keep the gate SAFE,
#    and each is easy to remove by accident while "simplifying".
# ---------------------------------------------------------------------------
{
    my $src = do { local (@ARGV, $/) = ($GATE); <> };
    ok(defined $src && length $src, 'G0: gate source readable');

    like($src, qr/MAX_BLOCKS=\d+/,
         'G1: the gate caps consecutive blocks — it must always yield eventually');
    like($src, qr/CCPRAXIS_DRIVE_STOP_OK/,  'G2: the session-wide escape hatch survives');
    like($src, qr/\.stop-ok/,               'G3: the one-shot escape hatch survives');
    like($src, qr/BP_LEDGER/,               'G4: coordinator sessions are still excluded');
    like($src, qr/timeout/,
         'G5: the director call is bounded by a timeout — a hanging oracle must not '
       . 'hang the stop');

    # The block message has to tell a reader what to DO. A gate that blocks
    # without a next action is just an obstacle.
    like($src, qr/bp-drive-next\.pl next/,
         'G6: the block message names the concrete command that advances the loop');

    my $msrc = do { local (@ARGV, $/) = ($MARK); <> };
    like($msrc, qr/run_in_background/,
         'G7: mark-wakeup still distinguishes backgrounded from foreground Bash');

    # G8 reads CODE, not prose. The first draft of this assertion scanned the
    # whole file and failed on mark-wakeup's own comment explaining why
    # bp_json_get must not be used here — the comment warning against the bug
    # matched the pattern looking for it. Blank full-line comments first, the
    # same way t/62's adapter guard does, or a file that documents its reasoning
    # is punished for it.
    my $mcode = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $msrc, -1;
    unlike($mcode, qr/bp_json_get[^\n]*run_in_background/,
         'G8: run_in_background is NOT read through bp_json_get — it returns empty '
       . 'for JSON booleans, which silently breaks the distinction G7 asserts');
}

# ---------------------------------------------------------------------------
# H. A package already owned by a worker is IN FLIGHT, not finished.
#
#    The gate consults the director and allows the stop when the answer is
#    'done'. For a long time the director ALSO answered 'done' whenever nothing
#    happened to be dispatchable — including the very ordinary case of a driver
#    holding packages open across concurrent workers. Every package non-terminal,
#    the run very much alive, and the one mechanism guarding an unattended run
#    waved the stop through. The run then died mid-package while looking
#    finished, which is precisely the failure this hook exists to prevent, and
#    the hook was the thing being lied to rather than the thing at fault.
#
#    Observed 2026-08-08 on this repo; the director now answers 'in-flight'.
#    These assertions are here so the distinction cannot quietly collapse back
#    into 'done' — the gate needs no change to honour it, which is exactly why
#    nothing else would notice if it regressed.
# ---------------------------------------------------------------------------
sub project_with_package {
    my (%opt) = @_;
    my ($root, $ds) = new_project(order => 1);
    my $bpdir = "$root/.ccpraxis-local-data/blueprints/x";
    make_path("$bpdir/packages");
    # The package set comes from the DAG table in blueprint.md, NOT from the
    # packages/ directory — a fixture without this table parses as a blueprint
    # with zero packages, which then reads as settled and tests nothing.
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print {$b} "# x\n\n| pkg | depends_on |\n|---|---|\n| p1 |  |\n";
    close $b;
    open my $p, '>', "$bpdir/packages/p1.md" or die;
    print {$p} "---\npackage: p1\nstatus: $opt{status}\n---\n\nbody\n";
    close $p;
    if ($opt{announced}) {
        open my $a, '>', "$ds/announced.json" or die;
        print {$a} '{"announced":["x"]}';
        close $a;
    }
    return ($root, $ds);
}

{
    my ($root) = project_with_package(status => 'running');
    my ($rc, $out) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 2, 'H1: a stop is BLOCKED while a package is still marked running — '
             . '"nothing to hand out right now" is not "the work is finished", and '
             . 'only the second one makes it safe to end the turn');
    like($out, qr/in-flight/,
         'H2: and the block names the action, so the driver is told what is still '
       . 'open rather than merely being refused');
}

{
    # THE COUNTER-FIXTURE. H1 is only evidence of a working gate if the same
    # gate lets a genuinely finished run stop. Announced, so the director has
    # no blueprint-done left to report and answers 'done' outright.
    my ($root) = project_with_package(status => 'done', announced => 1);
    my ($rc) = run_hook($GATE, payload_stop($root), verdict_ok => 1);
    is($rc, 0, 'H3: counter-fixture — the same gate ALLOWS the stop once the package '
             . 'is genuinely done; H1 detects work in flight rather than simply '
             . 'refusing every stop');
}

done_testing();
