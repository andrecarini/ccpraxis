#!/usr/bin/env perl
# platform: any
# 2026-10-22 (judged-continuity-disarm/01): the orchestrator filed a second
# orphan escalation for a self-parked package while the first was with the
# resolver. The second verdict's relaunch then failed every tick (exit 6,
# the ledger lock held by the coordinator the first relaunch had started)
# and the resolver re-fired each minute. A relaunch whose desired state
# already holds must settle instead:
#   - _relaunch_already_holds reports 'pending' for a pending ledger and
#     'coordinator-live' for a live runs/<pkg>.pid, undef otherwise;
#   - _dispatch_action returns 0 (applied) without shelling out in either
#     case.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $ORCH    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE = "$Bin/../../scripts/bp-resolve.pl";
require $ORCH;
require $RESOLVE;

sub mk_bp {
    my (%o) = @_;
    my $d = tempdir(CLEANUP => 1);
    $d =~ s{\\}{/}g;
    make_path("$d/packages", "$d/runs");
    open(my $fh, '>', "$d/packages/p1.md") or die "fixture: $!";
    print {$fh} "---\npackage: p1\nblueprint: b\nstatus: $o{status}\n---\n# p1\n";
    close $fh;
    if (defined $o{pid}) {
        open(my $pf, '>', "$d/runs/p1.pid") or die "fixture: $!";
        print {$pf} "$o{pid}\n";
        close $pf;
    }
    return $d;
}

# A pid that is certainly not alive: spawn a child and reap it.
my $dead = fork();
die "fork: $!" unless defined $dead;
if ($dead == 0) { exit 0 }
waitpid($dead, 0);

is(BpResolve::_relaunch_already_holds(mk_bp(status => 'pending'), 'p1'), 'pending',
    'a pending ledger already holds what a relaunch writes');
is(BpResolve::_relaunch_already_holds(mk_bp(status => 'parked', pid => $$), 'p1'), 'coordinator-live',
    'a live coordinator pid means a relaunch would kill working code');
is(BpResolve::_relaunch_already_holds(mk_bp(status => 'parked', pid => $dead), 'p1'), undef,
    'parked with a dead pid: relaunch is still needed');
is(BpResolve::_relaunch_already_holds(mk_bp(status => 'running'), 'p1'), undef,
    'running with no pid file (dead coordinator): relaunch is still needed');
is(BpResolve::_relaunch_already_holds(mk_bp(status => 'parked', pid => 'garbage'), 'p1'), undef,
    'a non-numeric pid file is ignored');

{
    my $bpdir = mk_bp(status => 'pending');
    # If _dispatch_action shelled out, bp-answer-escalation would fail on this
    # fake blueprint and return non-zero; 0 proves the short-circuit.
    my $rc = BpResolve::_dispatch_action({ action => 'relaunch', rationale => 'x' },
        { package => 'p1' }, 'p1--dup', { bp => 'b', bpdir => $bpdir });
    is($rc, 0, 'a moot relaunch is reported applied without running bp-answer-escalation');
}

done_testing();
