#!/usr/bin/env perl
# 120-mark-wakeup-agent-dispatch.t — oracle for done criterion 4, the
# HIGHEST-VALUE test in this package (h01-headless-background-gate spec
# §2.3/§2.4, AC4).
#
# THE LIVE DEFECT THIS PINS, OBSERVED THIS SESSION, NOT HYPOTHESISED.
# gate-drive-loop.sh blocked a driver turn THREE separate times with SEVEN
# background workers running — including once when the director itself
# returned `action: in-flight`, i.e. it agreed nothing was dispatchable. Every
# one of those seven workers was dispatched via the Agent tool. Cause:
# mark-wakeup.sh's case statement has NO Agent arm (falls to the `*) exit 0`
# default) AND hooks.json registers NO PreToolUse matcher for Agent at all —
# so an Agent dispatch never registers as a wake-up, and the gate — which
# genuinely had nothing to see — trained the driver to route around it. Only
# a backgrounded Bash call in the SAME turn silenced the gate.
#
# THE FIX HAS TWO HALVES, AND NEITHER ALONE SATISFIES CRITERION 4:
#   A. mark-wakeup.sh's case statement gains an Agent arm (§2.3).
#   B. hooks.json's registration widens to reach Agent dispatches (§2.4).
# Section G below asserts BOTH; sections B/C exercise the case-statement
# change end to end; section H is the live-bug reproduction against
# gate-drive-loop.sh itself.
#
# THE Agent/subagent_type QUESTION (dispatch-prompt note, w03's inherited
# assumption). subagent_type on the Agent tool's tool_input is UNVERIFIED
# anywhere in this repo (verified only for Task: t/09-gate.t:228, t/78:707,
# t/79:361/435/440, track-dispatch.sh:24). The spec's mark-wakeup.sh Agent arm
# (`Task|Agent) : ;;`) reads NO field off tool_input at all — it is a wake-up
# purely by virtue of TOOL NAME. So every fixture below constructs an Agent
# payload WITHOUT subagent_type, proving the oracle is correct when the field
# is ABSENT rather than laundering an assumption that it is present. See the
# test-writer report for the explicit route decision.
#
# Runs standalone: perl plugins/butler/tests/t/120-mark-wakeup-agent-dispatch.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";

ok(-f $MARK, 'mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $GATE, 'gate-drive-loop.sh exists') or BAIL_OUT('hook missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub new_drive_solo_root {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.drive-solo");
    return $root;
}

sub run_mark {
    my ($payload, %env) = @_;
    my $envstr = 'BP_LEDGER= ';
    $envstr = "BP_LEDGER='$env{BP_LEDGER}' " if defined $env{BP_LEDGER};
    my $out = `${envstr}bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# Agent payload with NO subagent_type field — see header note above.
sub agent_payload {
    my ($cwd, $sid) = @_;
    $sid //= 'sess-agent';
    return qq({"session_id":"$sid","cwd":"$cwd","tool_name":"Agent",)
         . qq("tool_input":{"description":"a worker","prompt":"do x"}});
}
sub task_payload {
    my ($cwd, $sid) = @_;
    $sid //= 'sess-task';
    return qq({"session_id":"$sid","cwd":"$cwd","tool_name":"Task",)
         . qq("tool_input":{"subagent_type":"butler:bp-implementer"}});
}

# ===========================================================================
# A. mark-wakeup.sh gains an Agent arm — behavior 6.
# ===========================================================================
{
    my $root = new_drive_solo_root();
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";

    my ($rc, $out) = run_mark(agent_payload($root));
    is($rc, 0, 'A1: mark-wakeup.sh never blocks on an Agent dispatch');
    ok(-f "$ds/.wakeup-pending",
       'A2: an Agent dispatch (BP_LEDGER unset, no subagent_type on the payload) '
     . 'records a pending wake-up — THE defect this package exists to fix')
        or diag('mark-wakeup.sh has no Agent arm in its case statement, or the arm requires '
              . 'a field (e.g. subagent_type) that is not part of this payload');
}

# ===========================================================================
# B. mark-wakeup.sh + BP_LEDGER set (coordinator) — behavior 7: unchanged,
#    the top-of-file check still short-circuits before the case statement.
# ===========================================================================
{
    my $root = new_drive_solo_root();
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";

    my ($rc) = run_mark(agent_payload($root), BP_LEDGER => '/fake/ledger.md');
    is($rc, 0, 'B1: mark-wakeup.sh exits 0 for an Agent dispatch when BP_LEDGER is set');
    ok(!-f "$ds/.wakeup-pending",
       'B2: ...and writes NOTHING — coordinator sessions are gate-stop.sh'."'".'s business, '
     . 'not mark-wakeup.sh'."'".'s, unchanged by the Agent arm');
}

# ===========================================================================
# C. TASK AND AGENT ARE TREATED EQUIVALENTLY. A fix that special-cases one
#    tool and not the other reproduces the defect in a narrower form — this
#    is explicitly called out as a live-observed risk, not a hypothetical.
# ===========================================================================
{
    my $root_t = new_drive_solo_root();
    my $root_a = new_drive_solo_root();

    my ($rc_t) = run_mark(task_payload($root_t));
    my ($rc_a) = run_mark(agent_payload($root_a));
    is($rc_t, $rc_a, 'C1: Task and Agent dispatches exit identically (both 0)');

    ok(-f "$root_t/.ccpraxis-local-data/.drive-solo/.wakeup-pending",
       'C2: Task dispatch recorded a wake-up (pre-existing behavior, unchanged)');
    ok(-f "$root_a/.ccpraxis-local-data/.drive-solo/.wakeup-pending",
       'C3: Agent dispatch recorded a wake-up TOO — equivalence holds, not just Task alone');
}

# ===========================================================================
# D. An unrelated tool still records nothing (regression guard — the new arm
#    must be scoped to Task|Agent, not widened to '*').
# ===========================================================================
{
    my $root = new_drive_solo_root();
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    run_mark(qq({"cwd":"$root","tool_name":"Read","tool_input":{}}));
    ok(!-f "$ds/.wakeup-pending", 'D1: an unrelated tool (Read) still records nothing');
}

# ===========================================================================
# E. hooks.json registers mark-wakeup.sh under a matcher that reaches Agent
#    — done criterion 4 part B (§2.4). The case-statement fix alone is
#    insufficient if nothing invokes the hook for an Agent dispatch at all.
# ===========================================================================
{
    my $hooks_json_path = "$HOOKS/hooks.json";
    open my $fh, '<', $hooks_json_path or BAIL_OUT("cannot read $hooks_json_path");
    my $raw = do { local $/; <$fh> };
    close $fh;

    my $doc = eval { require JSON::PP; JSON::PP->new->decode($raw) };
    ok(ref $doc eq 'HASH', 'E1: hooks.json parses as JSON') or diag("decode failed: $@");

    my $agent_matcher_reaches_mark = 0;
    if (ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH') {
        for my $entry (@{ $doc->{hooks}{PreToolUse} // [] }) {
            next unless ref $entry eq 'HASH';
            my $matcher = $entry->{matcher} // '';
            next unless length $matcher;
            # matcher must include "Agent" as its OWN alternative, e.g.
            # "Bash|Task|Agent" — not merely a substring like "AgentXyz".
            my @alts = split /\|/, $matcher;
            next unless grep { $_ eq 'Agent' } @alts;
            for my $h (@{ $entry->{hooks} // [] }) {
                next unless ref $h eq 'HASH';
                $agent_matcher_reaches_mark = 1
                    if ($h->{command} // '') =~ /mark-wakeup\.sh/;
            }
        }
    }
    ok($agent_matcher_reaches_mark,
       'E2: hooks.json registers mark-wakeup.sh under a PreToolUse matcher that includes '
     . 'Agent as its own alternative — an Agent arm in the script with no matching '
     . 'registration is never invoked at all')
        or diag('the fix must widen mark-wakeup.sh'."'".'s registration (its own dedicated '
              . 'block per spec section 2.4), not just its case statement');
}

# ===========================================================================
# F. The shared Bash/Task blocks are UNCHANGED in shape (spec §2.4: give
#    mark-wakeup.sh its OWN block rather than widening guard-bash.sh /
#    gate-shutdown.sh / track-dispatch.sh to Agent — out of scope per §6).
# ===========================================================================
{
    my $hooks_json_path = "$HOOKS/hooks.json";
    open my $fh, '<', $hooks_json_path or BAIL_OUT("cannot read $hooks_json_path");
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $doc = eval { JSON::PP->new->decode($raw) };
    ok(ref $doc eq 'HASH', 'F0: hooks.json parses');

    my $guard_bash_matcher = '';
    my $track_dispatch_matcher = '';
    for my $entry (@{ $doc->{hooks}{PreToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            my $cmd = $h->{command} // '';
            $guard_bash_matcher = $entry->{matcher} // '' if $cmd =~ /guard-bash\.sh/;
            $track_dispatch_matcher = $entry->{matcher} // '' if $cmd =~ /track-dispatch\.sh/;
        }
    }
    unlike($guard_bash_matcher, qr/\bAgent\b/,
       'F1: guard-bash.sh'."'".'s matcher is NOT widened to Agent — out of scope per spec §6');
    unlike($track_dispatch_matcher, qr/\bAgent\b/,
       'F2: track-dispatch.sh'."'".'s matcher is NOT widened to Agent either — it reads '
     . 'subagent_type, which is unverified for Agent payloads (spec §6)');
}

# ===========================================================================
# G. BOTH HALVES TOGETHER — the scout's own framing of criterion 4: neither
#    the case-statement fix nor the registration fix alone satisfies it.
# ===========================================================================
{
    my $msrc = do { local (@ARGV, $/) = ($MARK); <> };
    like($msrc, qr/Agent/, 'G1: mark-wakeup.sh source mentions Agent at all (case-statement half)');

    my $hjson = do { local (@ARGV, $/) = ("$HOOKS/hooks.json"); <> };
    like($hjson, qr/"Agent"|Agent\|/,
       'G2: hooks.json source mentions an Agent matcher at all (registration half)');
}

# ===========================================================================
# H. LIVE REPRODUCTION: gate-drive-loop.sh must NOT block a driver turn that
#    correctly dispatched a live worker via the Agent tool. This is the exact
#    scenario observed THIS SESSION: seven Agent-dispatched workers running,
#    a package still 'running', and the gate blocking anyway because nothing
#    registered as a wake-up.
#
#    H1 is only meaningful alongside its counter-fixture H2 (same package
#    state, NO wake-up recorded): if the gate always allowed regardless, H1
#    would pass vacuously. H2 proves the gate is still capable of blocking,
#    so H1's pass is attributable to the Agent-dispatch fix and nothing else.
# ===========================================================================
sub project_with_running_package {
    my $root = tempdir(CLEANUP => 1);
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    open my $o, '>', "$ds/order.json" or die;
    print {$o} '{"order":["x"],"recorded_at":1}';
    close $o;
    my $active = "$root/.active-drivers";
    make_path($active);
    open my $m, '>', "$active/sess-h" or die;
    print {$m} "$root/.ccpraxis-local-data\n";
    close $m;

    my $bpdir = "$root/.ccpraxis-local-data/blueprints/x";
    make_path("$bpdir/packages");
    open my $b, '>', "$bpdir/blueprint.md" or die;
    print {$b} "# x\n\n| pkg | depends_on |\n|---|---|\n| p1 |  |\n";
    close $b;
    open my $p, '>', "$bpdir/packages/p1.md" or die;
    print {$p} "---\npackage: p1\nstatus: running\n---\n\nbody\n";
    close $p;
    return ($root, $ds, $active);
}

sub run_gate_stop {
    my ($root, $active) = @_;
    my $payload = qq({"session_id":"sess-h","cwd":"$root"});
    my $out = `CCPRAXIS_DRIVE_ACTIVE_DIR='$active' CCPRAXIS_USAGE_VERDICT_JSON='{"action":"ok"}' bash "$GATE" <<'EOF' 2>&1
$payload
EOF`;
    return ($? >> 8, $out);
}

{
    my ($root, $ds, $active) = project_with_running_package();
    # Simulate the exact live scenario: a worker was dispatched via Agent
    # this turn.
    run_mark(agent_payload($root, 'sess-h'));
    ok(-f "$ds/.wakeup-pending", 'H0: the Agent dispatch recorded a wake-up (precondition)');

    my ($rc, $out) = run_gate_stop($root, $active);
    is($rc, 0, 'H1: gate-drive-loop.sh ALLOWS the stop — an Agent-dispatched worker is a '
             . 'legitimate wake-up, exactly like the seven this session actually saw blocked')
        or diag("gate output: $out");
}

{
    # COUNTER-FIXTURE: same package state, but NO wake-up was recorded (no
    # dispatch happened this turn) — the gate must still block, proving H1
    # is not simply "the gate never blocks".
    my ($root, $ds, $active) = project_with_running_package();
    ok(!-f "$ds/.wakeup-pending", 'H2 precondition: no wake-up recorded');
    my ($rc, $out) = run_gate_stop($root, $active);
    is($rc, 2, 'H2: counter-fixture — with NO recorded wake-up and a package still running, '
             . 'the gate still BLOCKS; H1'."'".'s allow is attributable to the Agent fix, '
             . 'not to a gate that never blocks')
        or diag("gate output: $out");
}

done_testing();
