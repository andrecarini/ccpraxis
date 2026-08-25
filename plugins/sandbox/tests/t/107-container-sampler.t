#!/usr/bin/env perl
# THE CONTAINER-STATE SAMPLER, and the one mapping in it that can cost real
# money in wall-power.
#
# WHY IT EXISTS. The dashboard's gather ran FOUR podman subprocesses inline on
# the render tick -- `inspect`, two `exec`s for the busy lease, and a
# `machine list` -- as backticks, so the render loop stopped dead until each
# returned. On Windows a `podman exec` crosses into the WSL VM and then into
# the container; two back to back plus an inspect and a machine list is easily
# seconds, and any keystroke or resize landing on that round waited behind all
# four. Operator report: "scrolling the log events is sluggish, sometimes takes
# multiple seconds to respond", and intermittently so -- which fits a 20-second
# poll cadence exactly.
#
# The probing now happens in a detached child that writes a snapshot; the tick
# reads the file. Same pattern as the resources and spend samplers.
#
# WHAT THIS FILE GUARDS. Moving the probe off the tick is easy. The part that
# is not easy, and the reason this file exists, is what a MISSING reading now
# means. The probe result feeds KeepAwake::on_probe, which starts and stops a
# PowerShell process holding the machine awake:
#
#   'ok'             -> hold or release by lease age
#   'lease-absent'   -> release IMMEDIATELY  (a fact about the CONTAINER)
#   'container-gone' -> release immediately
#   'probe-failed'   -> hold through a tolerance (a fact about US)
#
# A sampler that is one round behind is the LAST of those, not the second. Read
# as 'lease-absent' it would drop the wake-lock under a fleet that is still
# running -- the machine sleeps mid-run. Read as 'ok' with a stale age it could
# hold the lock forever after a run ends.
#
# s21 exists because a transient exec hiccup used to be indistinguishable from
# "no lease" and both released the lock. This is the same defect reachable from
# the other direction, so it is pinned here rather than left to inspection.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
ok(-f $LAUNCHER, 'launcher.pl is present') or BAIL_OUT('no launcher to test');

my $SRC = do { local (@ARGV, $/) = ($LAUNCHER); <> };

# ===========================================================================
# A. THE RENDER TICK NO LONGER SPAWNS PODMAN.
#
# Asserted against the SOURCE of the gather closure, because that is the claim:
# not "podman is called less often" but "podman is not called here at all".
# Comment-stripped first -- this file has been bitten before by oracles that
# matched prose about code instead of the code (t/26, t/44, t/61, t/65, t/66,
# t/100, t/115 this session alone).
# ===========================================================================
{
    my ($gather) = $SRC =~ /\n        gather    => sub \{(.*?)\n        \},\n/s;
    ok(defined $gather && length $gather, 'A: the gather closure is extractable');

  SKIP: {
        skip 'gather not extractable', 4 unless defined $gather;
        (my $code = $gather) =~ s/^\s*#.*$//mg;
        $code =~ s/#.*$//mg;

        unlike($code, qr/\$PODMAN\s+inspect/,
            'A: the gather does not run `podman inspect` on the render tick');
        unlike($code, qr/_busy_lease_probe\s*\(/,
            'A: ...nor the busy-lease probe, which was two `podman exec` calls');
        unlike($code, qr/_machine_state\s*\(/,
            'A: ...nor `podman machine list`');
        # Non-vacuity: it MUST still read the snapshot, or this block would
        # pass just as well against a gather that had been deleted.
        like($code, qr/_container_snapshot_read\s*\(/,
            'A: it reads the sampler snapshot instead (not vacuous -- the work moved, it did not vanish)');
    }
}

# ===========================================================================
# B. THE SAMPLER STILL DOES THE PROBING. The work moved; it did not disappear.
# ===========================================================================
{
    my ($round) = $SRC =~ /sub _container_sampler_round \{(.*?)\n\}/s;
    ok(defined $round, 'B: _container_sampler_round is extractable');
  SKIP: {
        skip 'round not extractable', 3 unless defined $round;
        (my $code = $round) =~ s/^\s*#.*$//mg;
        like($code, qr/\$PODMAN\s+inspect/,     'B: the sampler runs the inspect');
        like($code, qr/_busy_lease_probe\s*\(/, 'B: the sampler runs the busy-lease probe');
        like($code, qr/_machine_state\s*\(/,    'B: the sampler runs the machine-state read');
    }
}

# ===========================================================================
# C. THE MAPPING. Extracted and executed, not merely grepped.
# ===========================================================================
{
    my ($fn)  = $SRC =~ /(sub _container_probe_from_snapshot \{.*?\n\})/s;
    my ($max) = $SRC =~ /my \$CONTAINER_SNAPSHOT_MAX_AGE = (\d+);/;
    ok(defined $fn,  'C: _container_probe_from_snapshot is extractable');
    ok(defined $max, 'C: the staleness bound is declared as a named constant');

  SKIP: {
        skip 'mapping not extractable', 12 unless defined $fn && defined $max;
        my $ok = eval "package T107; our \$CONTAINER_SNAPSHOT_MAX_AGE = $max; $fn 1";
        ok($ok, 'C: the extracted mapping evaluates') or diag($@);
        skip 'mapping did not evaluate', 11 unless $ok;

        my $NOW  = 1_800_000_000;
        my $good = { v => 1, measured_at => $NOW, probe => { state => 'ok', age => 12 } };

        # A FRESH reading passes through untouched -- including 'ok', which is
        # the only state that can HOLD the lock on its own merits.
        my $r = T107::_container_probe_from_snapshot($good, $NOW);
        is($r->{state}, 'ok', 'C: a fresh snapshot passes its probe result through');
        is($r->{age}, 12,     'C: ...with the lease age intact, which is what decides hold-vs-release');

        # Exactly at the bound is still fresh; one second past is not.
        is(T107::_container_probe_from_snapshot({ %$good, measured_at => $NOW - $max }, $NOW)->{state},
            'ok', "C: a snapshot exactly ${max}s old is still believed");
        is(T107::_container_probe_from_snapshot({ %$good, measured_at => $NOW - $max - 1 }, $NOW)->{state},
            'probe-failed', "C: one second past ${max}s it is not");

        # THE ASSERTION THIS FILE IS FOR. Stale must be probe-failed -- which
        # KeepAwake HOLDS through -- and never lease-absent, which it RELEASES
        # on. Both halves stated, because "is probe-failed" and "is not
        # lease-absent" fail differently if someone maps it to 'ok'.
        my $stale = T107::_container_probe_from_snapshot({ %$good, measured_at => $NOW - 9999 }, $NOW);
        is($stale->{state}, 'probe-failed',
            'C: a STALE snapshot is probe-failed -- a fact about us, which KeepAwake holds through');
        isnt($stale->{state}, 'lease-absent',
            'C: ...and NEVER lease-absent, which would release the wake-lock under a running fleet');
        like($stale->{detail}, qr/\d+s old/,
            'C: ...and says how old, so the reason is diagnosable rather than just a state name');

        # Every degenerate input degrades the same way rather than dying.
        for my $case ([undef, 'undef'], ['not a hash', 'plain string'], [[], 'arrayref'],
                      [{}, 'empty hash'], [{ measured_at => 'soon' }, 'non-numeric measured_at'],
                      [{ measured_at => $NOW }, 'no probe key'],
                      [{ measured_at => $NOW, probe => 'nope' }, 'non-hash probe']) {
            my ($in, $label) = @$case;
            my $got = eval { T107::_container_probe_from_snapshot($in, $NOW) };
            is(($got && $got->{state}), 'probe-failed', "C: $label -> probe-failed, not a die and not lease-absent");
        }
    }
}

# ===========================================================================
# D. THE SAMPLER IS WIRED LIKE THE OTHER TWO -- started with them, and stopped
#    on every teardown path. A sampler that outlives its dashboard is an
#    orphan burning CPU on the host, which is a defect this project has
#    already met (twelve days of one, at ~27% of a core).
# ===========================================================================
{
    (my $code = $SRC) =~ s/^\s*#.*$//mg;
    like($code, qr/_container_sampler_start\s*\(/,  'D: the sampler is started');
    like($code, qr/_container_sampler_stop\s*\(/,   'D: ...and stopped');
    my $releases = () = $code =~ /_container_sampler_release_global\(\)/g;
    cmp_ok($releases, '>=', 3,
        'D: the release hook is on the INT, TERM and END paths (>=3 call sites), like the other samplers');
    like($code, qr/--container-sampler/, 'D: the child mode has a dispatch');
    like($code, qr/last unless kill\(0, \$owner_pid\)/,
        'D: the sampler loop self-exits when its owner goes away -- no orphan');
}

done_testing();
