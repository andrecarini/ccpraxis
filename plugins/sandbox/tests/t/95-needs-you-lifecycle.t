#!/usr/bin/env perl
# t07-needs-you-lifecycle -- the oracle for blueprint tui-operator-feedback.
#
# Operator, verbatim: "the TUI for GSA says 'needs you: 1 decision waiting'
# despite the agent that was working on it doesn't really have anything that
# needs my attention?"
#
# COUNTING FILES IN A DIRECTORY IS NOT A LIFECYCLE. Eight scripts write into
# runs/escalations/ and exactly ONE narrow path cleared them -- and only for a
# direct package reset. A package that simply finished, or a run that simply
# ended, left its question queued forever and the panel kept asking.
#
# THE FAILURE DIRECTIONS ARE NOT SYMMETRIC (done-criterion 4), and that shapes
# every assertion here. A decision wrongly KEPT is a panel that nags. A decision
# wrongly DROPPED is a human who is never asked. So the settle rule is
# conservative by construction, and PART 2 spends more assertions on the
# must-stay-live cases than on the must-settle ones.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;
use JSON::PP;

my $OK = eval { require RunState; 1 };
ok($OK, 'RunState.pm loads') or BAIL_OUT("require failed: $@");

# No real process probing: the orchestrator pid in these fixtures is fictional,
# and RunState delegates liveness to this injected coderef by design.
{ no warnings 'once'; $RunState::PID_ALIVE = sub { 0 }; }

# ---------------------------------------------------------------------------
# Fixture builder. One blueprint, its ledgers, its queue, its run markers.
# ---------------------------------------------------------------------------
sub mkfix {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $bp   = "$root/bp";
    make_path("$bp/packages", "$bp/runs/escalations");

    for my $p (@{ $o{pkgs} || [] }) {
        open(my $f, '>', "$bp/packages/$p->{name}.md") or die $!;
        print {$f} "---\npackage: $p->{name}\nstatus: $p->{status}\n---\n\n# body\n";
        close $f;
    }
    for my $d (@{ $o{decisions} || [] }) {
        open(my $f, '>', "$bp/runs/escalations/$d->{file}") or die $!;
        print {$f} (defined $d->{raw} ? $d->{raw} : JSON::PP->new->encode($d->{rec} || {}));
        close $f;
    }
    if ($o{orchestrator}) { open(my $f, '>', "$bp/runs/.orchestrator") or die $!; print {$f} "999999\n"; close $f }
    if ($o{paused})       { open(my $f, '>', "$bp/runs/.paused") or die $!; print {$f} '{"manual":1}'; close $f }
    if ($o{shutdown})     { open(my $f, '>', "$bp/runs/.shutdown") or die $!; print {$f} "1\n"; close $f }
    open(my $r, '>', "$bp/runs/registry.json") or die $!; print {$r} '{"packages":{}}'; close $r;
    return ($root, $bp);
}

sub waiting {
    my ($root) = @_;
    my $s = RunState::summarize($root);
    return (ref($s) eq 'ARRAY' && @$s && ref($s->[0]) eq 'HASH') ? $s->[0]{decisions_waiting} : undef;
}

my $STUCK = { package => 'p1', kind => 'stuck-package', category => 'operational' };
my $FLEET = { package => '(fleet)', kind => 'reauth', category => 'operational' };

# ===========================================================================
# PART 1 -- the operator's own case.
# ===========================================================================
{
    my ($root) = mkfix(
        pkgs      => [ { name => 'p1', status => 'done' } ],
        decisions => [ { file => 'p1--aa.json', rec => $STUCK } ],
    );
    is(waiting($root), 0,
        'AC1: a decision for a package that has FINISHED no longer counts -- the operator\'s exact report');
}

# AC1n -- non-vacuity. The same fixture with the package still open must count,
# or AC1 would be satisfied by a counter that always returns zero.
{
    my ($root) = mkfix(
        pkgs      => [ { name => 'p1', status => 'converging' } ],
        decisions => [ { file => 'p1--aa.json', rec => $STUCK } ],
    );
    is(waiting($root), 1,
        'AC1 non-vacuity: the same decision for an OPEN package still counts');
}

# ===========================================================================
# PART 2 -- the conservative direction. These are the assertions that matter.
#
# Each of these is a case where a naive rule would have dropped a decision a
# human still needs to answer.
# ===========================================================================
my @MUST_STAY_LIVE = (
    [ 'blocked package',
      { pkgs => [ { name => 'p1', status => 'blocked' } ],
        decisions => [ { file => 'p1--aa.json', rec => $STUCK } ] },
      'blocked is precisely the state that needs a human -- it must never read as settled' ],

    [ 'parked package',
      { pkgs => [ { name => 'p1', status => 'parked' } ],
        decisions => [ { file => 'p1--aa.json', rec => $STUCK } ] },
      'so is parked' ],

    [ 'pending package',
      { pkgs => [ { name => 'p1', status => 'pending' } ],
        decisions => [ { file => 'p1--aa.json', rec => $STUCK } ] },
      'a package that has not started has certainly not settled anything' ],

    [ 'ledger with an EMPTY status',
      { pkgs => [ { name => 'p1', status => '' } ],
        decisions => [ { file => 'p1--aa.json', rec => $STUCK } ] },
      'an unreadable status is not evidence of settlement' ],

    [ 'unparseable record',
      { decisions => [ { file => 'bad--dd.json', raw => '{not json' } ] },
      'a record we cannot read might be anything, including urgent' ],

    [ 'record that is not an object',
      { decisions => [ { file => 'arr--ee.json', raw => '[1,2,3]' } ] },
      'a schema we do not recognise is not a schema we may discard' ],

    [ 'fleet decision while the run is RUNNING',
      { orchestrator => 1, decisions => [ { file => 'fl--bb.json', rec => $FLEET } ] },
      'a live run is exactly when a fleet question is still blocking' ],

    [ 'fleet decision while the run is PAUSED',
      { paused => 1, decisions => [ { file => 'fl--bb.json', rec => $FLEET } ] },
      'a paused run is waiting for the very answer this record is asking for' ],

    [ 'package decision naming a package with no ledger, run RUNNING',
      { orchestrator => 1, decisions => [ { file => 'ghost--cc.json', rec => $STUCK } ] },
      'a missing ledger during a live run is a gap in our knowledge, not proof of settlement' ],

    [ 'record with no package field at all, run RUNNING',
      { orchestrator => 1, decisions => [ { file => 'x--ff.json', rec => { kind => 'broken-env' } } ] },
      'nothing to resolve it against and the run is live' ],

    [ 'STALE run (dead orchestrator, .paused still present)',
      { paused => 1, decisions => [ { file => 'fl--bb.json', rec => $FLEET } ] },
      'abandoning a run is not the same as answering the question it was blocked on' ],
);

for my $c (@MUST_STAY_LIVE) {
    my ($label, $spec, $why) = @$c;
    my ($root) = mkfix(%$spec);
    is(waiting($root), 1, "AC2 [$label] stays LIVE -- $why");
}

# ===========================================================================
# PART 3 -- the settle direction, each for a stated reason.
# ===========================================================================
my @MUST_SETTLE = (
    [ 'package done',    { pkgs => [ { name => 'p1', status => 'done' } ],
                           decisions => [ { file => 'p1--aa.json', rec => $STUCK } ] } ],
    [ 'package dropped', { pkgs => [ { name => 'p1', status => 'dropped' } ],
                           decisions => [ { file => 'p1--aa.json', rec => $STUCK } ] } ],
    [ 'fleet decision, run over (no orchestrator, no pause)',
                         { decisions => [ { file => 'fl--bb.json', rec => $FLEET } ] } ],
    [ 'package with no ledger, run over',
                         { decisions => [ { file => 'ghost--cc.json', rec => $STUCK } ] } ],
);

for my $c (@MUST_SETTLE) {
    my ($label, $spec) = @$c;
    my ($root) = mkfix(%$spec);
    is(waiting($root), 0, "AC3 [$label] settles");
}

# ===========================================================================
# PART 4 -- mixed queues. A settled record must not suppress a live sibling,
# and vice versa. This is the shape the operator would actually hit: several
# packages, some finished.
# ===========================================================================
{
    my ($root) = mkfix(
        pkgs => [ { name => 'p1', status => 'done' },
                  { name => 'p2', status => 'blocked' },
                  { name => 'p3', status => 'dropped' },
                  { name => 'p4', status => 'parked' } ],
        decisions => [
            { file => 'p1--aa.json', rec => { %$STUCK, package => 'p1' } },
            { file => 'p2--bb.json', rec => { %$STUCK, package => 'p2' } },
            { file => 'p3--cc.json', rec => { %$STUCK, package => 'p3' } },
            { file => 'p4--dd.json', rec => { %$STUCK, package => 'p4' } },
        ],
    );
    is(waiting($root), 2,
        'AC4: in a mixed queue exactly the two unfinished packages count -- settled siblings neither suppress nor inflate them');
}

# ===========================================================================
# PART 5 -- the launcher's indicator and the Blueprints rows agree.
#
# They used to be two independent walks of the same tree, which is how the
# indicator drifted into being a file count in the first place.
# ===========================================================================
{
    my $LSRC = do { local $/; open(my $fh, '<', "$Bin/../../scripts/launcher.pl") or die $!; <$fh> };
    like($LSRC, qr/sub _count_needs_you.*?RunState::summarize/s,
        'AC5 (source-text): the header indicator is derived from the same summaries the Blueprints panel renders, not from a second walk of the tree');
    unlike($LSRC, qr/sub _count_needs_you.*?\Q\$n++ if -f\E/s,
        'AC5 (source-text): and no longer counts files');
}

# ===========================================================================
# PART 6 -- PARITY with the butler-side implementation.
#
# The settle rule exists twice: RunState::decision_live (read path, sandbox)
# and BpAnswer's decision_live (sweep path, butler). The duplication is
# deliberate -- a butler script requiring a sandbox module is a dependency this
# tree has in neither direction -- and it is the same technique statusline.pl
# uses for bp_continuity_active_dir, where AC-13 pins the parity rather than
# assuming it.
#
# WITHOUT THIS CHECK the duplication would be a latent bug rather than a
# design: one copy could start settling something the other keeps, and the
# panel and the sweep would disagree about what the operator still owes.
# ===========================================================================
SKIP: {
    my $ans = "$Bin/../../../butler/scripts/bp-answer-decision.pl";
    skip('bp-answer-decision.pl not found', 1) unless -f $ans;

    my @cases = (
        [ { package => 'p1', kind => 'stuck-package' }, 'done',       0, 0 ],
        [ { package => 'p1', kind => 'stuck-package' }, 'dropped',    0, 0 ],
        [ { package => 'p1', kind => 'stuck-package' }, 'blocked',    0, 1 ],
        [ { package => 'p1', kind => 'stuck-package' }, 'parked',     0, 1 ],
        [ { package => 'p1', kind => 'stuck-package' }, 'converging', 0, 1 ],
        [ { package => 'p1', kind => 'stuck-package' }, '',           0, 1 ],
        [ { package => '(fleet)', kind => 'reauth' },   undef,        1, 0 ],
        [ { package => '(fleet)', kind => 'reauth' },   undef,        0, 1 ],
        [ { kind => 'broken-env' },                     undef,        1, 0 ],
        [ 'not-a-hash',                                 undef,        1, 1 ],
    );

    my $disagreements = 0;
    my @detail;
    for my $c (@cases) {
        my ($rec, $status, $run_over, $expect) = @$c;
        my ($root, $bp) = mkfix(
            pkgs => (defined $status ? [ { name => 'p1', status => $status } ] : []));

        my $sandbox = RunState::decision_live(
            (ref($rec) eq 'HASH' ? $rec : $rec), $bp, "$bp/runs/escalations", $run_over) ? 1 : 0;

        # The butler copy is exercised out of process -- requiring that script
        # here would pull in its whole CLI. A tiny driver keeps this test from
        # depending on butler's load-time behaviour.
        my $drv = "$root/drv.pl";
        open(my $d, '>', $drv) or die $!;
        print {$d} "require '" . $ans . "';\n"
                 . "my \$rec = " . (ref($rec) eq 'HASH'
                        ? 'JSON::PP->new->decode(q{' . JSON::PP->new->canonical->encode($rec) . '})'
                        : "'not-a-hash'") . ";\n"
                 . "print main::decision_live(\$rec, q{$bp}, $run_over) ? 1 : 0;\n";
        close $d;
        my $butler = `perl "$drv" 2>&1`;
        $butler = ($butler =~ /(\d)\s*$/) ? $1 : 'ERR';

        if ("$sandbox" ne "$butler" || $sandbox != $expect) {
            $disagreements++;
            push @detail, sprintf('rec=%s status=%s run_over=%s expect=%s sandbox=%s butler=%s',
                (ref($rec) eq 'HASH' ? ($rec->{package} // '(none)') : $rec),
                (defined $status ? "'$status'" : '(no ledger)'), $run_over, $expect, $sandbox, $butler);
        }
    }
    is($disagreements, 0,
        'AC6 (parity): the sandbox reader and the butler sweeper agree on every case, and both match the stated rule')
        or diag("  disagreements:\n    " . join("\n    ", @detail));
}

done_testing();
