#!/usr/bin/env perl
# platform: any
# The chronic-scoping escalation ("more than 2 autonomous scoping
# resolutions") is filed ONCE per package, and resolving it never counts as
# another scoping resolution. Before this, the counter fed itself: each
# resolution of the escalation bumped the count past 2 and filed the next one,
# so a package looped through the resolver indefinitely (acxpraxis
# 15-model-check-cost, 2026-11-05: 25 judges in two hours, every verdict a
# moot relaunch).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-orchestrator.pl";
require "$Bin/../../scripts/bp-resolve.pl";

my $J = JSON::PP->new->canonical;

sub fresh_runs {
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/runs");
    open my $fh, '>', "$bpdir/runs/registry.json" or die $!;
    print $fh $J->encode({ packages => { alpha => {} } });
    close $fh;
    return $bpdir;
}

sub reg_pkg {
    my ($bpdir) = @_;
    open my $fh, '<', "$bpdir/runs/registry.json" or die $!;
    local $/;
    return $J->decode(<$fh>)->{packages}{alpha};
}

# Record every queue_needs_you call instead of writing a queue file.
my @queued;
{
    no warnings 'redefine';
    *BpOrch::queue_needs_you = sub { my ($runs, $rec) = @_; push @queued, $rec; return 1 };
}

sub bump {
    my ($bpdir, $kind) = @_;
    BpResolve::_bump_chronic_scoping_counter(
        { package => 'alpha', kind => $kind },
        "alpha--$kind-" . scalar(@queued),
        { category => 'scoping', rationale => 'r' },
        { runs => "$bpdir/runs", bp => 'bp', bpdir => $bpdir },
    );
}

{
    my $bp = fresh_runs();
    @queued = ();
    bump($bp, 'stuck-package') for 1 .. 2;
    is(scalar(@queued), 0, 'S1: two scoping resolutions file nothing');
    bump($bp, 'stuck-package');
    is(scalar(@queued), 1, 'S2: the third scoping resolution files one chronic-scoping escalation');
    is($queued[0]{kind}, 'chronic-scoping', 'S2: ...of kind chronic-scoping');
    ok(reg_pkg($bp)->{chronic_scoping_filed}, 'S2: the registry records that it was filed');

    bump($bp, 'stuck-package') for 1 .. 5;
    is(scalar(@queued), 1, 'S3: later scoping resolutions never file a second one');
    is(reg_pkg($bp)->{chronic_scoping_count}, 8, 'S3: ...though the count keeps counting');
}

{
    my $bp = fresh_runs();
    @queued = ();
    bump($bp, 'stuck-package') for 1 .. 2;
    bump($bp, 'chronic-scoping') for 1 .. 4;
    is(scalar(@queued), 0, 'S4: resolving a chronic-scoping escalation is not a scoping resolution of the package');
    is(reg_pkg($bp)->{chronic_scoping_count}, 2, 'S4: ...and leaves the count untouched');
}

done_testing();
