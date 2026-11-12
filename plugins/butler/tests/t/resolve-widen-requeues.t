#!/usr/bin/env perl
# platform: any
# Bug 20261112-120628-9d26: a widen-write-set verdict widened the ledger and
# left the package `blocked`, so the orchestrator's orphan reconciler filed it
# again and one or two more paid resolver judges answered `relaunch` before the
# package moved (four times on 2026-11-12, acxpraxis-step-2 package 15).
#
#   R1  a blocked package whose widening is applied goes back to `pending`, its
#       registry attempt reset to 0, and the log says so
#       (escalation_resolve_widen_requeued) -- with or without a `decision`
#   R2  a package that is not blocked/parked keeps its status
#   R3  a package whose coordinator is still alive keeps `blocked` (the
#       widening still lands; that coordinator reads it itself)
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
my $PKG = '15-model-check-cost';

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
| 15-model-check-cost | model check cost | — | sonnet |

MD

# A ledger created through bp-ledger.pl, then parked by its coordinator the way
# package 15 was: an escalation asking for one more path, status blocked.
sub mk {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    my $d = "$root/data/blueprints/$BP";
    make_path("$d/packages", "$d/runs/escalations");
    spew("$d/blueprint.md", $BLUEPRINT);
    my $l = "$d/packages/$PKG.md";
    system($^X, $LEDGER, 'create', '--ledger', $l, '--package', $PKG, '--blueprint', $BP,
           '--template', $TPL, '--write-set', 'models/check.sh', '--test-paths', 'models/test/') == 0
        or die 'fixture: create';
    system($^X, $LEDGER, 'set-escalation', '--ledger', $l, '--text',
           'Ask: widen write_set by models/journal-recovery/sim-exempt.txt') == 0 or die 'fixture: escalation';
    system($^X, $LEDGER, 'set-status', '--ledger', $l, '--status', $o{status} // 'blocked') == 0
        or die 'fixture: status';
    spew("$d/runs/registry.json", JSON::PP->new->canonical->encode(
        { packages => { $PKG => { status => ($o{status} // 'blocked'), attempt => 3, pid => $o{pid} // 999_999 } } }));
    spew("$d/runs/$PKG.pid", ($o{pid} // 999_999) . "\n");
    my $id = "$PKG--$o{tag}";
    my $rec = { package => $PKG, blueprint => $BP, kind => 'stuck-package', category => 'scoping',
                question => 'Widen write_set by models/journal-recovery/sim-exempt.txt?', created_at => 1 };
    spew("$d/runs/escalations/$id.json", JSON::PP->new->canonical->encode($rec));
    return ($d, $l, $id, $rec);
}
sub ctx { my ($d) = @_; return { bp => $BP, bpdir => $d, runs => "$d/runs", log => "$d/runs/orchestrator.log" } }
sub widen {
    my (%o) = @_;
    return { category => 'scoping', action => 'widen-write-set', confidence => 'high',
             evidence => 'ledger Escalation section', rationale => 'one more file, within purview',
             path => 'models/journal-recovery/sim-exempt.txt',
             ($o{decision} ? (decision => 'Package 15 may write the journal-recovery sim-exempt list') : ()) };
}
sub reg_pkg { my ($d) = @_; my $r = BpOrch::_read_json("$d/runs/registry.json"); return $r->{packages}{$PKG} // {} }

# R1, through the Decision-gated path and the plain path.
for my $case ([ 'decision', 1 ], [ 'plain', 0 ]) {
    my ($label, $with_decision) = @$case;
    my ($d, $l, $id, $rec) = mk(tag => "r1$label");
    my $out = BpResolve::apply_verdict(widen(decision => $with_decision), $rec, $id, ctx($d));
    is($out->{applied}, 1, "R1 ($label): the widening applies") or diag(explain $out);
    my $lb = slurp($l);
    like(fm_value($lb, 'write_set') // '', qr/models\/journal-recovery\/sim-exempt\.txt/, "R1 ($label): write_set widened");
    is(fm_value($lb, 'status'), 'pending', "R1 ($label): the blocked package is back to pending");
    is(reg_pkg($d)->{attempt}, 0, "R1 ($label): its registry attempt is reset to 0");
    like(slurp("$d/runs/orchestrator.log") // '', qr/"type":"escalation_resolve_widen_requeued"/,
         "R1 ($label): the log records the requeue");
}

# R2: not blocked/parked -> untouched status.
{
    my ($d, $l, $id, $rec) = mk(tag => 'r2', status => 'running');
    BpResolve::apply_verdict(widen(decision => 1), $rec, $id, ctx($d));
    is(fm_value(slurp($l), 'status'), 'running', 'R2: a running package keeps its status');
    unlike(slurp("$d/runs/orchestrator.log") // '', qr/widen_requeued/, 'R2: and nothing is logged as requeued');
}

# R3: the coordinator is still alive (this test's own pid stands in for it).
{
    my ($d, $l, $id, $rec) = mk(tag => 'r3', pid => $$);
    my $out = BpResolve::apply_verdict(widen(decision => 1), $rec, $id, ctx($d));
    is($out->{applied}, 1, 'R3: the widening still applies');
    my $lb = slurp($l);
    like(fm_value($lb, 'write_set') // '', qr/sim-exempt\.txt/, 'R3: write_set widened');
    is(fm_value($lb, 'status'), 'blocked', 'R3: a live coordinator\'s package is not requeued');
}

done_testing();
