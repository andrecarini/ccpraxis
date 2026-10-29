#!/usr/bin/env perl
# platform: any
# orchestrator_live must not call a live orchestrator on the OTHER side of the container boundary dead.
#
# Bug report 20261029-114219-b403: the host-side sitrep reported fleet acxpraxis-step-2 as
# "orphaned -- orchestrator is dead, resume it" while its orchestrator ran in the sandbox and wrote
# runs/orchestrator.log every 10 s. orchestrator_live judged only the marker's flock, and a flock
# taken inside the container is invisible to a Windows host process. A free lock now means dead
# only when the marker was written on the reader's own side; otherwise the log's freshness decides.
#
# Each case builds its own runs/ dir: the marker (unlocked unless said), the side sidecar, the log.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Test::More;
use lib "$Bin/../../scripts";
use Almanac::SessionLive ();

my $HERE  = (-e '/run/.containerenv' || -e '/.dockerenv') ? 'container' : 'host';
my $OTHER = $HERE eq 'host' ? 'container' : 'host';

sub spew { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print $fh $c; close $fh }

# fixture(%o) -> ($root, $marker_path)
#   side => host|container|undef, side_pid => n (default: the marker's), log_age => s|undef
sub fixture {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1); $root =~ s{\\}{/}g;
    my $runs = "$root/.ccpraxis-local-data/blueprints/bp/runs";
    make_path($runs);
    spew("$runs/.orchestrator", "4242\n");
    spew("$runs/.orchestrator-side.json",
         qq({"v":1,"pid":) . ($o{side_pid} // 4242) . qq(,"side":"$o{side}","host":"x"}\n)) if defined $o{side};
    if (defined $o{log_age}) {
        spew("$runs/orchestrator.log", qq({"type":"busy_lease_tick"}\n));
        my $t = time() - $o{log_age};
        utime($t, $t, "$runs/orchestrator.log");
    }
    return ($root, "$runs/.orchestrator");
}

sub live { my ($root) = @_; return Almanac::SessionLive::orchestrator_live(root => $root, blueprint => 'bp') }

# --- across the boundary: the log decides -----------------------------------------------------------
is(live((fixture(side => $OTHER, log_age => 5))[0]), 1,
   "THE BUG: written on the $OTHER side, lock looks free here, log 5 s old -> live");
is(live((fixture(side => $OTHER, log_age => 80))[0]), 1, 'log within the 90 s window -> live');
is(live((fixture(side => $OTHER, log_age => 200))[0]), 0, 'log older than the window -> dead');
is(live((fixture(side => $OTHER))[0]), 0, 'no log at all -> dead');
is(live((fixture(side => $OTHER, log_age => -60))[0]), 1, 'log a minute in the future (clock skew) -> live');
is(live((fixture(side => $OTHER, log_age => -3600))[0]), 0, 'log an hour in the future -> not trusted, dead');

# --- the same side: the lock is authoritative, as before ------------------------------------------
is(live((fixture(side => $HERE, log_age => 5))[0]), 0,
   "written on this ($HERE) side, lock free -> dead even with a fresh log (crashed just now)");
{
    my ($root, $marker) = fixture(side => $HERE, log_age => 500);
    open(my $fh, '<', $marker) or die $!;
    flock($fh, LOCK_EX) or die "flock: $!";
    is(live($root), 1, 'a held lock -> live, whatever the log says');
    close $fh;
}

# --- no usable side record: the lock decides, as before ---------------------------------------------
# A marker left by a crash has a log written seconds ago; it must still read dead at once, or its
# fleet thread could not be taken over (butler fleet-thread.t AC6 variant).
is(live((fixture(log_age => 5))[0]), 0, 'no sidecar, lock free, fresh log -> dead (a crash leftover)');
is(live((fixture())[0]), 0, 'no sidecar, no log -> dead (unchanged)');
is(live((fixture(side => $OTHER, side_pid => 999, log_age => 5))[0]), 0,
   'a sidecar about another pid is stale, so it cannot vouch for this marker -> dead');

# --- no marker: dead regardless -----------------------------------------------------------------
{
    my ($root, $marker) = fixture(side => $OTHER, log_age => 5);
    unlink $marker;
    is(live($root), 0, 'no marker (clean exit) -> dead even with a fresh log');
}

done_testing();
