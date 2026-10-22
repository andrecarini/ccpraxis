#!/usr/bin/env perl
# platform: any
# bp-launch.sh enforces BP_MAX_PARALLEL across every blueprint, but the
# orchestrator's slot checks counted only its own @live. With two fleets
# running, a slot that looked free made bp-launch exit 3 every tick, and each
# refused attempt was logged as a fresh coordinator_death plus two
# launch_failed lines (where-things-go/10, 2026-10-22). foreign_live_count
# gives the orchestrator the other blueprints' share, using the same rule as
# bp-lib.sh count_running_global: a registry row whose pid is alive.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-orchestrator.pl";

# A pid that is certainly not alive: spawn a child and reap it.
my $dead = fork();
die "fork: $!" unless defined $dead;
if ($dead == 0) { exit 0 }
waitpid($dead, 0);

my $root = tempdir(CLEANUP => 1) . "/blueprints";
$root =~ s{\\}{/}g;
make_path("$root/bp-a/runs", "$root/bp-b/runs", "$root/bp-c/runs", "$root/.hidden/runs");

sub put {
    my ($path, $body) = @_;
    open(my $fh, '>', $path) or die "fixture: $!";
    print {$fh} $body;
    close $fh;
}

# bp-a (the caller) has a live coordinator of its own: it is @live's job, not
# foreign_live_count's.
put("$root/bp-a/runs/registry.json", qq({"packages":{"a1":{"pid":$$}}}));
# bp-b: one live, one dead, one with no pid at all.
put("$root/bp-b/runs/registry.json",
    qq({"packages":{"b1":{"pid":$$},"b2":{"pid":$dead},"b3":{"status":"pending"}}}));
# bp-c: an unreadable registry is skipped, not fatal.
put("$root/bp-c/runs/registry.json", '{not json');
# a dot-directory is never a blueprint.
put("$root/.hidden/runs/registry.json", qq({"packages":{"h1":{"pid":$$}}}));

is(BpOrch::foreign_live_count("$root/bp-a/runs"), 1,
    'counts the live rows of other blueprints only (own, dead, pid-less, unreadable and dot-dirs excluded)');
is(BpOrch::foreign_live_count("$root/bp-b/runs"), 1,
    'from bp-b, bp-a\'s live coordinator is the foreign one');
is(BpOrch::foreign_live_count("$root/bp-c/runs"), 2,
    'from bp-c, both other live coordinators count');
is(BpOrch::foreign_live_count("$root/nowhere/runs"), 2,
    'a caller whose own directory is missing still counts its siblings');
is(BpOrch::foreign_live_count(undef), 0, 'undef runs dir counts nothing');

# The same siblings under a root that is not named blueprints/ (every
# orchestrator test fixture) are never counted.
{
    my $other = tempdir(CLEANUP => 1) . "/fixtures";
    $other =~ s{\\}{/}g;
    make_path("$other/x/runs", "$other/y/runs");
    put("$other/y/runs/registry.json", qq({"packages":{"y1":{"pid":$$}}}));
    is(BpOrch::foreign_live_count("$other/x/runs"), 0,
        'a non-blueprints root counts no siblings');
}

# With max_par 2 and one foreign coordinator, a blueprint with one live
# coordinator of its own has no free slot.
is(BpOrch::cap_slots(1 + BpOrch::foreign_live_count("$root/bp-a/runs"), 2), 0,
    'one own plus one foreign coordinator fill a cap of 2');

done_testing();
