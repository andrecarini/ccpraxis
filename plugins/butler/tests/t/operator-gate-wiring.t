#!/usr/bin/env perl
# platform: any
# The operator gate (fifth judge kind, `operator-gate`) is registered
# everywhere judge kinds are enumerated, and its prompt pins the operator's
# rules.
#
# Structural, like escalation-resolve-wiring.t and for the same reason: bp-judge.sh
# needs a sandbox, jq and the claude binary, and running it would launch a real
# judge, so its wiring is read out of the source instead. A gate that is wired
# in the orchestrator but missing from any of these surfaces fails the same way
# escalation-resolve once did: every dispatch exits early, the bound runs out,
# and every question reaches the operator unreviewed.
#
#   W1  bp-judge.sh: allow-list, agent file, template, decision id, no ledger
#       requirement, a read-only role, sonnet, a turn cap
#   W2  the orchestrator: judge_worker_type, the decision id written before the
#       spawn, the tunables, the apply step's CLI
#   W3  turn caps: canonical role entry, the bp-judge.sh surface, no drift
#   W4  SessionIndex recognises the gate's preamble
#   W5  the agent file: frontmatter (sonnet, Read/Grep/Glob, low cap) and the
#       rules it must carry: the bar, the plain-language test, the hands rule,
#       the user-Decision rule, the verdict contract
#   W6  the escalation resolver's prompt and template settle operator_gate_rejected
#   W7  the apply step's word check, and the docs that list judge kinds
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $PLUGIN = "$Bin/../..";
my $ROOT   = "$PLUGIN/../..";
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }

my $judge = slurp("$PLUGIN/scripts/bp-judge.sh") // '';
my $orch  = slurp("$PLUGIN/scripts/bp-orchestrator.pl") // '';
ok(length $judge && length $orch, 'W0: bp-judge.sh and bp-orchestrator.pl are readable');

# ---------------------------------------------------------------- W1 ---
{
    my ($allow) = $judge =~ /case\s+"\$KIND"\s+in\s+([a-z|\-]+)\)/;
    my @kinds = split /\|/, ($allow // '');
    ok((grep { $_ eq 'operator-gate' } @kinds), 'W1: operator-gate is in bp-judge.sh\'s kind allow-list')
        or diag('allow-list: ' . join(',', @kinds));
    cmp_ok(scalar @kinds, '>=', 5, 'W1: five judge kinds are allowed');
    like($judge, qr{operator-gate\)\s+AGENT_FILE="\$PLUGIN_ROOT/agents/bp-operator-gate\.md"},
         'W1: the agent file override names agents/bp-operator-gate.md');
    ok(-f "$PLUGIN/agents/bp-operator-gate.md", 'W1: ...which exists');
    ok(-f "$PLUGIN/templates/judge-operator-gate.md", 'W1: templates/judge-operator-gate.md exists');
    like($judge, qr/\[ "\$KIND" = escalation-resolve \] \|\| \[ "\$KIND" = operator-gate \]/,
         'W1: the gate reads its record id from runs/<kind>/<pkg>.decision like the resolver');
    like($judge, qr{DECISION_ID=\$\(tr -d '\\r\\n' < "\$BPDIR/runs/\$KIND/\$PKG\.decision"},
         'W1: ...from the kind\'s own directory');
    like($judge, qr/if \[ "\$KIND" != conformance \] && \[ "\$KIND" != operator-gate \]; then\n\s*\[ -f "\$LEDGER" \]/,
         'W1: no ledger is required for the gate (it gates _fleet records too)');
    my ($blk) = $judge =~ /elif \[ "\$KIND" = operator-gate \]; then\n(.*?)\n(?:elif|else)/s;
    ok(defined $blk, 'W1: bp-judge.sh has an operator-gate model/cap block');
    $blk //= '';
    like($blk, qr/BP_OPERATOR_GATE_MODEL:-sonnet/, 'W1: model defaults to sonnet');
    like($blk, qr/BP_OPERATOR_GATE_MAX_TURNS:-\d+/, 'W1: a turn cap with an override');
    like($blk, qr/ROLE="operator-gate"; J_WRITE_SET=""; J_TEST_PATHS=""/, 'W1: a read-only role (empty write set)');
    my $tmpl = slurp("$PLUGIN/templates/judge-operator-gate.md") // '';
    like($tmpl, qr/\{\{$_\}\}/, "W1: the template carries {{$_}}") for qw(VERDICT_PATH AGENT_FILE DECISION_FILE DECISION_ID BLUEPRINT_FILE LEDGER);
    like($tmpl, qr/\A\s*You are the ccpraxis \*\*operator-gate\*\*/, 'W1: the template opens with the gate\'s preamble');
}

# ---------------------------------------------------------------- W2 ---
{
    require "$PLUGIN/scripts/bp-orchestrator.pl";
    is(BpOrch::judge_worker_type('operator-gate'), 'bp-operator-gate', 'W2: judge_worker_type maps the kind to its agent');
    is(BpOrch::judge_worker_type('escalation-resolve'), 'bp-escalation-resolver', 'W2: the resolver mapping is unchanged');
    my $name  = index($orch, '"/$key.decision"');
    my $spawn = index($orch, "\$spawn->({ kind => 'operator-gate'");
    cmp_ok($name,  '>', -1, 'W2: the gate\'s decision-id write is present');
    cmp_ok($spawn, '>', -1, 'W2: the gate\'s spawn is present');
    cmp_ok($name, '<', $spawn, 'W2: the record is named BEFORE the gate is spawned');
    my $t = BpOrch::_tunables_base();
    ok(defined $t->{operator_gate_to} && $t->{operator_gate_to} > 0, 'W2: operator_gate_to is a tunable');
    ok(defined $t->{operator_gate_attempts} && $t->{operator_gate_attempts} > 0, 'W2: operator_gate_attempts is a tunable');
    like($orch, qr/'--apply-gate-verdict'/, 'W2: the orchestrator hands verdicts to bp-resolve.pl --apply-gate-verdict');
    my $res = slurp("$PLUGIN/scripts/bp-resolve.pl") // '';
    like($res, qr/\$arg eq '--apply-gate-verdict'/, 'W2: ...which bp-resolve.pl accepts');
    like($res, qr/sub apply_gate_verdict/, 'W2: ...and applies in apply_gate_verdict');
    like($orch, qr/spawn_judge => \$spawn_judge, read_verdict => \$read_verdict, pid_alive => \$pid_alive/,
         'W2: run() hands the bridge tick its judge seams');
}

# ---------------------------------------------------------------- W3 ---
{
    require "$PLUGIN/scripts/bp-turn-caps.pl";
    my $caps = slurp("$PLUGIN/turn-caps.json") // '';
    like($caps, qr/"bp-operator-gate":\s*\d+/, 'W3: turn-caps.json has a canonical bp-operator-gate cap');
    my $tc = slurp("$PLUGIN/scripts/bp-turn-caps.pl") // '';
    like($tc, qr/BP_OPERATOR_GATE_MAX_TURNS/, 'W3: bp-turn-caps.pl checks the bp-judge.sh default against it');
    my $cfg = eval { BpTurnCaps::load("$PLUGIN/turn-caps.json") };
  SKIP: {
        skip 'BpTurnCaps::load unavailable', 1 unless ref $cfg;
        my $d = BpTurnCaps::drift($cfg, $ROOT);
        my @mine = grep { ($_->{file} // '') =~ /bp-operator-gate|bp-judge\.sh/ } @$d;
        is(scalar @mine, 0, 'W3: no turn-cap drift for the gate\'s surfaces')
            or diag(join "\n", map { "$_->{file}: $_->{reason}" } @mine);
    }
}

# ---------------------------------------------------------------- W4 ---
{
    require "$ROOT/plugins/sandbox/scripts/SessionIndex.pm";
    no warnings 'once';
    like("You are the ccpraxis **operator-gate** for blueprint **x**", $SessionIndex::PREAMBLE_RE,
         'W4: SessionIndex recognises the gate\'s preamble as a judge session');
}

# ---------------------------------------------------------------- W5 ---
{
    my $a = slurp("$PLUGIN/agents/bp-operator-gate.md") // '';
    my ($fm) = $a =~ /\A---\n(.*?)\n---\n/s;
    ok(defined $fm, 'W5: the agent file has frontmatter');
    $fm //= '';
    like($fm, qr/^name: bp-operator-gate$/m, 'W5: name');
    like($fm, qr/^model: sonnet$/m, 'W5: model sonnet');
    like($fm, qr/^tools: Read, Grep, Glob$/m, 'W5: tools Read, Grep, Glob only');
    my ($mt) = $fm =~ /^maxTurns:\s*(\d+)$/m;
    ok(defined $mt && $mt <= 400, 'W5: a low turn cap (the 400 floor band)') or diag("maxTurns: " . ($mt // 'none'));
    (my $flat = $a) =~ s/\s+/ /g;
    like($flat, qr/product decisions or very unexpected findings that would change the product, never technical details within the agent's purview/,
         'W5: the operator\'s bar, verbatim');
    like($flat, qr/could the operator answer this without any explanation of internals\?/i, 'W5: the plain-language test');
    like($flat, qr/files, paths, tools, tests, permissions, modes, write sets/, 'W5: ...naming what counts as internals');
    like($flat, qr/Decisions numbers/, 'W5: ...including Decisions numbers');
    like($flat, qr/Applying a user Decision is not changing it/i, 'W5: the user-Decision rule');
    like($flat, qr/`Decided` column/, 'W5: ...read from the Decided column');
    like($flat, qr/The operator's hands/, 'W5: the hands rule');
    like($flat, qr/re-authenticate/, 'W5: ...re-authenticating');
    like($flat, qr/repair the host/, 'W5: ...repairing the host');
    like($flat, qr/spending money beyond the agreed budget/, 'W5: ...spending beyond the budget');
    like($flat, qr/\{"verdict":"operator","question":"[^"]+","reasoning":"[^"]+"\}/, 'W5: the operator verdict contract');
    like($flat, qr/\{"verdict":"agents","reasoning":"[^"]+","covering_decision":"[^"]+","guidance":"[^"]+"\}/, 'W5: the agents verdict contract');
    like($flat, qr/Read ONLY these/i, 'W5: the input scope is closed');
    like($flat, qr/`## Escalation` section/, 'W5: ...the ledger Escalation section, if present');
    like($flat, qr/operator_gate_rejected/, 'W5: it knows what a record that came back looks like');
    like($flat, qr/ONE-SHOT/, 'W5: one-shot discipline');
}

# ---------------------------------------------------------------- W6 ---
{
    my $r = slurp("$PLUGIN/agents/bp-escalation-resolver.md") // '';
    (my $flat = $r) =~ s/\s+/ /g;
    like($flat, qr/A record carrying `operator_gate_rejected` is yours to settle, with one of the actions, never routed to `product` or `operator-action` again/,
         'W6: the resolver must settle a gate-rejected record with an action');
    like($flat, qr/its `guidance`/, 'W6: ...using the gate\'s guidance');
    like($flat, qr/`covering_decision`/, 'W6: ...and its covering decision');
    like($flat, qr/`product_question_rejected` or `operator_gate_rejected` is the exception: write `relaunch`/,
         'W6: the one-shot fallback covers it too');
    my $t = slurp("$PLUGIN/templates/judge-escalation-resolve.md") // '';
    like($t, qr/operator_gate_rejected/, 'W6: the resolver template names it');
}

# ---------------------------------------------------------------- W7 ---
{
    require "$PLUGIN/scripts/bp-resolve.pl";
    my $mk = sub { my ($dir) = @_; require File::Temp; my $d = File::Temp::tempdir(CLEANUP => 1); mkdir "$d/escalations"; $d };
    my $runs = $mk->();
    my $rec = { package => 'p', kind => 'stuck-package', question => 'q', category => 'product' };
    require JSON::PP;
    open my $fh, '>', "$runs/escalations/p--x.json" or die; print $fh JSON::PP->new->canonical->encode($rec); close $fh;
    my $o = BpResolve::apply_gate_verdict({ verdict => 'operator', reasoning => 'r', question => 'Change the write set of package 3?' },
        $rec, 'p--x', { runs => $runs, log => "$runs/orchestrator.log" });
    is($o->{outcome}, 'retry', 'W7: an operator question naming internals is refused for another attempt');
    $o = BpResolve::apply_gate_verdict({ verdict => 'operator', reasoning => 'r', question => 'Should guests check out without an account?' },
        $rec, 'p--x', { runs => $runs, log => "$runs/orchestrator.log" });
    is($o->{outcome}, 'operator', 'W7: a plain one is applied');
    my ($ok) = BpOrch::operator_gate_verdict_ok({ verdict => 'agents', reasoning => 'r' });
    ok(!$ok, 'W7: an agents verdict without guidance is malformed');
    ok((BpOrch::operator_gate_verdict_ok({ verdict => 'agents', reasoning => 'r', guidance => 'g', covering_decision => undef }))[0],
       'W7: covering_decision may be null');

    my $proto = slurp("$PLUGIN/skills/orchestrator-protocol/SKILL.md") // '';
    like($proto, qr/`operator-gate` → `bp-operator-gate`/, 'W7: the orchestrator protocol lists the fifth judge kind');
    like($proto, qr/\*\*The operator gate/, 'W7: ...and describes the gate');
    my $auth = slurp("$ROOT/plugins/blueprint/skills/authoring-protocol/SKILL.md") // '';
    like($auth, qr/`bp-operator-gate`/, 'W7: the authoring protocol\'s worker-model list names it');
}

done_testing();
