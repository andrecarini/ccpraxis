#!/usr/bin/env perl
# platform: any
# Bug 20261112-214934-365f: the escalation resolver could not change test_paths,
# the commonest park in acxpraxis-step-2 (ten packages: a test_paths naming a
# whole source directory locks the implementer out of it). It answered
# `relaunch`, which changes nothing, and the package parked again.
#
#   N1  narrow-test-paths is a valid, actable action
#   N2  applied: a Decisions row (agent) naming each new path, the ledger's
#       test_paths replaced through bp-ledger.pl, the package back to pending,
#       and both steps logged
#   N3  a path outside the current test_paths is refused and goes to the
#       operator; nothing is written
#   N4  a verdict without `decision`, or with no change, writes nothing
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $ORCH    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE = "$Bin/../../scripts/bp-resolve.pl";
my $LEDGER  = "$Bin/../../scripts/bp-ledger.pl";
my $TPL     = "$Bin/../../../blueprint/templates/package-ledger.md";
require $ORCH;
require $RESOLVE;

my $BP  = 'acxpraxis-step-2';
my $PKG = '14-fold-results';

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub spew  { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "fixture $p: $!"; print {$fh} $c; close $fh }
sub fm_value {
    my ($bytes, $key) = @_;
    my ($fm) = ($bytes // '') =~ /\A---\s*\n(.*?)\n---/s;
    return undef unless defined $fm;
    return $1 if $fm =~ /^\Q$key\E:[ \t]*(.*?)[ \t]*$/m;
    return undef;
}

my $BLUEPRINT = <<'MD';
# Step 2

## Decisions

| # | Decision | Decided | Date |
|---|----------|---------|------|
| 1 | Models are written in Quint | user | 2026-10-01 |

## Package status

| pkg | deliverable | depends_on | model |
|-----|-------------|------------|-------|
| 14-fold-results | fold results | — | sonnet |

MD

sub mk {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    my $d = "$root/data/blueprints/$BP";
    make_path("$d/packages", "$d/runs/escalations");
    spew("$d/blueprint.md", $BLUEPRINT);
    my $l = "$d/packages/$PKG.md";
    system($^X, $LEDGER, 'create', '--ledger', $l, '--package', $PKG, '--blueprint', $BP,
           '--template', $TPL, '--write-set', 'models/:docs/', '--test-paths', 'models/') == 0 or die 'fixture: create';
    system($^X, $LEDGER, 'set-escalation', '--ledger', $l, '--text',
           'E1: test_paths models/ makes every model source a TEST file; narrow it') == 0 or die 'fixture: escalation';
    system($^X, $LEDGER, 'set-status', '--ledger', $l, '--status', 'blocked') == 0 or die 'fixture: status';
    spew("$d/runs/registry.json", JSON::PP->new->canonical->encode(
        { packages => { $PKG => { status => 'blocked', attempt => 2, pid => 999_999 } } }));
    spew("$d/runs/$PKG.pid", "999999\n");
    my $id = "$PKG--$o{tag}";
    my $rec = { package => $PKG, blueprint => $BP, kind => 'stuck-package', category => 'scoping',
                question => 'test_paths covers the model sources; narrow it?', created_at => 1 };
    spew("$d/runs/escalations/$id.json", JSON::PP->new->canonical->encode($rec));
    return ($d, $l, $id, $rec);
}
sub ctx { my ($d) = @_; return { bp => $BP, bpdir => $d, runs => "$d/runs", log => "$d/runs/orchestrator.log" } }
sub verdict {
    my (%o) = @_;
    return { category => 'scoping', action => 'narrow-test-paths', confidence => 'high',
             evidence => 'ledger Escalation E1; Decisions 20-30 precedent', rationale => 'same defect as Decisions 20-30',
             (exists $o{paths} ? (test_paths => $o{paths}) : (test_paths => [ 'models/budget/test/', 'models/merge/test/' ])),
             (exists $o{decision} ? (defined $o{decision} ? (decision => $o{decision}) : ())
                                  : (decision => 'Package 14 test_paths narrowed to the models\' test directories')) };
}

# N1
{
    is(BpResolve::confidence_gate(verdict()), 'act', 'N1: a high-confidence narrow-test-paths verdict is actable');
    my ($ok) = BpResolve::verdict_in_bounds(verdict());
    ok($ok, 'N1: narrow-test-paths is in bounds');
}

# N2
{
    my ($d, $l, $id, $rec) = mk(tag => 'n2');
    my $out = BpResolve::apply_verdict(verdict(), $rec, $id, ctx($d));
    is($out->{applied}, 1, 'N2: the narrowing applies') or diag(explain $out);
    my $lb = slurp($l);
    is(fm_value($lb, 'test_paths'), 'models/budget/test/:models/merge/test/', 'N2: test_paths replaced with the new set');
    is(fm_value($lb, 'write_set'), 'models/:docs/', 'N2: write_set untouched');
    is(fm_value($lb, 'status'), 'pending', 'N2: the package is back to pending');
    my $bb = slurp("$d/blueprint.md");
    like($bb, qr/^\| 2 \| Package 14 test_paths narrowed to the models' test directories \(bp-escalation-resolver, escalation \Q$id\E: narrows 14-fold-results test_paths to `models\/budget\/test\/`, `models\/merge\/test\/`\) \| agent \| \d{4}-\d\d-\d\d \|$/m,
         'N2: Decision 2 names every new path, decided by agent');
    my $log = slurp("$d/runs/orchestrator.log") // '';
    like($log, qr/"type":"escalation_resolve_narrowed_test_paths"/, 'N2: the narrowing is logged');
    like($log, qr/"type":"escalation_resolve_narrow_requeued"/, 'N2: and the requeue');
    ok(!-e "$d/runs/escalations/$id.json", 'N2: the escalation is settled');
    is(system($^X, $LEDGER, 'validate', '--ledger', $l) >> 8, 0, 'N2: the ledger validates');
}

# N3
{
    my ($d, $l, $id, $rec) = mk(tag => 'n3');
    my ($lb0, $bb0) = (slurp($l), slurp("$d/blueprint.md"));
    my $out = BpResolve::apply_verdict(verdict(paths => [ 'models/budget/test/', 'rust/tests/' ]), $rec, $id, ctx($d));
    is($out->{applied}, 0, 'N3: a path outside the current test_paths is not applied');
    is($out->{surfaced}, 'operator-action', 'N3: it goes to the operator');
    is(slurp($l), $lb0, 'N3: the ledger is byte-identical');
    is(slurp("$d/blueprint.md"), $bb0, 'N3: blueprint.md is byte-identical');
    my $q = BpOrch::_read_json("$d/runs/escalations/$id.json");
    like($q->{product_question} // '', qr/rust\/tests\//, 'N3: the question names the outside path');
}

# N4
{
    my ($d, $l, $id, $rec) = mk(tag => 'n4');
    my ($lb0, $bb0) = (slurp($l), slurp("$d/blueprint.md"));
    my $out = BpResolve::apply_verdict(verdict(decision => undef), $rec, $id, ctx($d));
    is($out->{applied}, 0, 'N4: no decision -> not applied');
    is(slurp($l), $lb0, 'N4: ledger untouched');
    is(slurp("$d/blueprint.md"), $bb0, 'N4: blueprint untouched');
    my $out2 = BpResolve::apply_verdict(verdict(paths => 'models/'), $rec, $id, ctx($d));
    is($out2->{applied}, 0, 'N4: an unchanged set -> not applied');
    is(slurp($l), $lb0, 'N4: ledger still untouched');
}

done_testing();
