#!/usr/bin/env perl
# platform: any
# The tree interlock (GB-d rule b) used to refuse every coordinator test run
# while ANY write-capable worker of ANY blueprint was mid-edit in the tree.
# With two fleets in one working tree, nearly every run of one fleet collided
# with whatever the other had in flight (where-things-go/10 vs
# judged-continuity-disarm/02, 2026-10-22). It now applies the same
# write-set scoping as the same-blueprint path (Decision 85, B-4): a
# coordinator running exactly one test file inside its own
# write_set/test_paths is let through past a live writer whose ledger
# write_set does not overlap its own scope.
#
# The safety half is the larger half of this file: an overlapping writer,
# a sweep, a multi-file run, a test file outside the caller's scope, an
# unreadable foreign ledger and an unreadable own ledger all still deny.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

sub gb {
    my ($cmd, %env) = @_;
    return GuardHarness::run_module('Guards::GuardBash',
        { tool_name => 'Bash', tool_input => { command => $cmd } }, env => \%env);
}

sub spit {
    my ($path, $body) = @_;
    make_path(dirname($path));
    open(my $fh, '>:raw', $path) or die "fixture: $path: $!";
    print {$fh} $body;
    close $fh;
}

sub ledger {
    my ($bp_dir, $pkg, $ws, $tp) = @_;
    spit("$bp_dir/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: running\nwrite_set: $ws\n"
      . (defined $tp ? "test_paths: $tp\n" : '')
      . "---\n# $pkg\n");
}

sub writer {
    my ($bp_dir, $pkg) = @_;
    spit("$bp_dir/runs/$pkg.active-worker", 'bp-implementer');
}

# One fresh tree per case, so markers never leak between cases.
sub tree {
    my $data = tempdir(CLEANUP => 1);
    $data =~ s{\\}{/}g;
    my $root = "$data/blueprints";
    my $self = "$root/self-bp";
    my $other = "$root/other-bp";
    make_path("$self/runs", "$other/runs");
    ledger($self, 'p1', 'plugins/fx/:plugins/fx/tests/t/alpha.t', 'plugins/fx/tests/t/alpha.t');
    my %env = (BP_LEDGER => "$self/packages/p1.md", BP_DIR => $self, BP_PACKAGE => 'p1');
    return ($self, $other, \%env);
}

my $MINE = 'perl plugins/fx/tests/t/alpha.t';

{
    my ($self, $other, $env) = tree();
    ledger($other, 'op1', 'plugins/other/');
    writer($other, 'op1');
    my $res = gb($MINE, %$env);
    is($res->{rc}, 0, 'a foreign writer with a disjoint write set no longer blocks an in-scope single test')
        or diag($res->{err});
}

{
    my ($self, $other, $env) = tree();
    ledger($self, 'p2', 'plugins/sib/');
    writer($self, 'p2');
    is(gb($MINE, %$env)->{rc}, 0, 'a same-blueprint sibling with a disjoint write set does not block either');
}

{
    my ($self, $other, $env) = tree();
    ledger($other, 'op1', 'plugins/fx/lib/');
    writer($other, 'op1');
    my $res = gb($MINE, %$env);
    is($res->{rc}, 2, 'a foreign writer whose write set overlaps still blocks');
    like($res->{err}, qr/BLOCKED \(tree interlock\).*other-bp.*op1/s, 'and names it');
}

{
    my ($self, $other, $env) = tree();
    ledger($other, 'op1', 'plugins/fx/tests/t/alpha.t');
    writer($other, 'op1');
    is(gb($MINE, %$env)->{rc}, 2, 'a foreign writer editing the very test file being run still blocks');
}

{
    my ($self, $other, $env) = tree();
    ledger($other, 'op1', 'plugins/other/');
    writer($other, 'op1');
    is(gb('perl scripts/run-tests.pl --fast', %$env)->{rc}, 2, 'a full sweep still blocks on a disjoint writer');
    is(gb('perl scripts/run-tests.pl plugins/fx', %$env)->{rc}, 2, 'a directory run still blocks on a disjoint writer');
}

{
    my ($self, $other, $env) = tree();
    ledger($other, 'op1', 'plugins/other/');
    writer($other, 'op1');
    is(gb('perl plugins/other/tests/t/beta.t', %$env)->{rc}, 2,
        'a test file outside the caller\'s own scope still blocks');
    is(gb("$MINE && perl plugins/other/tests/t/beta.t", %$env)->{rc}, 2,
        'a second test run chained after an in-scope one still blocks');
}

{
    my ($self, $other, $env) = tree();
    writer($other, 'op1');   # no ledger for op1
    is(gb($MINE, %$env)->{rc}, 2, 'a foreign writer whose ledger cannot be read still blocks');
}

{
    my ($self, $other, $env) = tree();
    unlink "$self/packages/p1.md";
    ledger($other, 'op1', 'plugins/other/');
    writer($other, 'op1');
    is(gb($MINE, %$env)->{rc}, 2, 'a caller whose own ledger cannot be read still blocks');
}

{
    my ($self, $other, $env) = tree();
    ledger($self, 'p1', 'plugins/fx/:plugins/fx/tests/t/alpha.t', 'plugins/fx/tests/t/alpha.t');
    writer($self, 'p1');
    is(gb($MINE, %$env)->{rc}, 2, 'the caller\'s own in-flight writer still blocks (rule a)');
}

done_testing();
