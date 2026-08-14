#!/usr/bin/env perl
# 144-runstate-surface-separation.t — g03-reporter-stop-gate, PILLAR 3: the
# --surface separation on bp-runstate.pl, and the concrete collision it
# exists to prevent.
#
# Spec: specs/g03-reporter-stop-gate-spec.md §1.3 (Decision 3 -> DC4), §2.3
# (the --surface widening), §4 AC5, AC-RS.
#
# THE COLLISION, TRACED CONCRETELY (spec §1.3, restated here so the fixture
# below is legible without cross-referencing the spec): a driver dispatches
# work -> project state -> active. A reporter in the SAME project arms
# bp-watch.pl and calls `pause --watcher-pid <its own watcher's pid> --until
# T1` -> WITHOUT --surface, this OVERWRITES the driver's active record with a
# paused one carrying the reporter's pid -> the driver's own Stop gate then
# reads state=paused, verifies the (genuinely alive) reporter pid, and
# ALLOWS the driver to stop -- a false ALLOW on a dispatch that has not
# resolved. Section D below constructs exactly this shape and asserts the
# two surfaces' state never contends.
#
# AC-RS (constraint): every existing caller that never passes --surface must
# take a byte-identical path (default 'driver', same run-state.json
# filename). Section B pins this directly against the EXISTING oracle files'
# own assumed path (t/112's runstate_path, t/137's runstate_path) so a
# widening that silently renames the default path is caught by this file
# even though it duplicates no fixture from either.
#
# Runs standalone: perl plugins/butler/tests/t/144-runstate-surface-separation.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $RS = "$Bin/../../scripts/bp-runstate.pl";
ok(-f $RS, 'A1: bp-runstate.pl exists') or BAIL_OUT('state machine missing');

my $J = JSON::PP->new->canonical;

sub rs {
    my ($root, @args) = @_;
    my $cmd = qq{perl "$RS" } . join(' ', @args) . qq{ --root "$root" 2>&1};
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub state_of {
    my ($root, @surface) = @_;
    my (undef, $out) = rs($root, 'status', @surface);
    my $j = eval { JSON::PP->new->decode($out) } || {};
    return $j->{state} // 'inert';
}
sub driver_path   { my ($root) = @_; return "$root/.ccpraxis-local-data/.subagent-guard/run-state.json"; }
sub reporter_path { my ($root) = @_; return "$root/.ccpraxis-local-data/.subagent-guard/run-state.reporter.json"; }

# ===========================================================================
# B. AC-RS: the DEFAULT path (no --surface at all) is byte-identical to
#    today's — the exact path t/112 and t/137's own fixtures already assume.
#    A widening that silently renames the default path (e.g. always writing
#    run-state.driver.json) breaks this WITHOUT necessarily breaking t/112 or
#    t/137 in isolation if those files' own path constants were "helpfully"
#    kept in sync — this file re-derives the path independently instead of
#    importing either fixture file's helper, so a coordinated rename cannot
#    slip past both at once.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc) = rs($root, 'activate', '--reason', '"x"');
    is($rc, 0, 'B1: activate with no --surface succeeds (today\'s existing, unmodified path)');
    ok(-f driver_path($root),
       'B2 CANONICAL (-> AC-RS): the state file lands at the EXACT pre-existing path '
     . '(.subagent-guard/run-state.json) when --surface is omitted -- not a new default '
     . 'filename');
    is(state_of($root), 'active', 'B3: status with no --surface reads it back correctly');
}

# ===========================================================================
# C. A non-default surface produces a SIBLING file, never touching the
#    default path.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out) = rs($root, 'activate', '--reason', '"x"', '--surface', 'reporter');
    is($rc, 0, 'C1: activate --surface reporter succeeds')
        or diag("output: $out");
    ok(-f reporter_path($root),
       'C2 CANONICAL: --surface reporter writes to a SIBLING file '
     . '(run-state.reporter.json), not the default run-state.json');
    ok(!-f driver_path($root),
       'C3 CANONICAL: ...and the DEFAULT file is NOT created as a side effect of a '
     . 'non-default --surface call');
}

# ===========================================================================
# D. THE COLLISION, CONSTRUCTED DIRECTLY (spec §1.3 traced step by step) --
#    the acceptance case for this entire pillar. Same --root, two surfaces,
#    DIFFERENT states, read back independently and proven to disagree.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);

    # Step 1: "a driver dispatches a Task in terminal A -> project state ->
    # active" (default surface, no --surface flag -- exactly what
    # guard-subagent-stall.sh's own activation path does today).
    my ($rc1) = rs($root, 'activate', '--reason', '"driver dispatched a Task"');
    is($rc1, 0, 'D1 setup: driver surface activates (default, no --surface)');

    # Step 2: "a reporter in terminal B arms bp-watch.pl and calls pause
    # --watcher-pid <its own watcher's pid> --until T1" -- on the reporter
    # surface specifically, per spec §2.4's SKILL.md addition.
    my $until = time() + 300;
    my ($rc2, $out2) = rs($root, 'pause', '--watcher-pid', $$, '--until', $until,
                           '--reason', '"bp-watch.pl armed"', '--surface', 'reporter');
    is($rc2, 0, 'D2 setup: reporter surface pause succeeds against this test process\'s own '
              . 'live pid') or diag("output: $out2");

    my $driver_state   = state_of($root);
    my $reporter_state = state_of($root, '--surface', 'reporter');

    is($driver_state, 'active',
       'D3 CANONICAL (-> AC5, the collision proof, part 1): the DRIVER surface still reads '
     . '"active" -- the reporter\'s pause call did NOT overwrite it. Under the collision '
     . 'this pillar exists to prevent, this would read "paused" instead (the exact false '
     . 'ALLOW traced in the spec), which is precisely what a shared, unscoped run-state.json '
     . 'would produce.');
    is($reporter_state, 'paused',
       'D4 CANONICAL (-> AC5, part 2): the REPORTER surface independently reads "paused" -- '
     . 'proving --surface reporter genuinely wrote SOMEWHERE, not that --surface is a silent '
     . 'no-op that happens to leave the driver file alone by writing nothing at all');
    isnt($driver_state, $reporter_state,
       'D5 CANONICAL (-> AC5, the direct pairing the spec calls for): the two surfaces\' '
     . 'states DIFFER in the SAME fixture -- direct evidence against the collision, not '
     . 'merely "the file exists"');

    # And the literal false-ALLOW this prevents, made concrete: a driver-side
    # consumer (mirroring gate-drive-loop.sh's own w02 fold) reading the
    # DEFAULT surface must never see the reporter's pause.
    ok($driver_state ne 'paused',
       'D6 CANONICAL: explicitly, the driver surface is NOT "paused" -- this is the exact '
     . 'condition that would cause a driver\'s own Stop gate to wrongly ALLOW a stop while '
     . 'its own dispatch has not resolved');
}

# ===========================================================================
# E. Surface name validation: a typo must fail LOUDLY at parse time (exit 3
#    per bp-runstate.pl's existing usage-error convention), never silently
#    write to a garbled filename.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc, $out) = rs($root, 'activate', '--surface', 'Not-Valid!');
    isnt($rc, 0, 'E1 CANONICAL: an invalid --surface value (uppercase + punctuation) is '
               . 'REFUSED, not silently accepted');
    opendir(my $dh, "$root/.ccpraxis-local-data/.subagent-guard")
        or ok(1, 'E2: no .subagent-guard dir was created at all for a refused surface name');
    if (opendir(my $dh2, "$root/.ccpraxis-local-data/.subagent-guard")) {
        my @files = grep { !/^\.\.?$/ } readdir $dh2;
        closedir $dh2;
        is(scalar(@files), 0,
           'E2: ...and no garbled-filename state file was written under any name');
    }
}
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc) = rs($root, 'activate', '--surface', '');
    isnt($rc, 0, 'E3: an EMPTY --surface value is also refused, not silently treated as the '
               . 'default');
}

# ===========================================================================
# F. Two independent surfaces resolve/pause/finish through the FULL contract,
#    not just activate/status -- the same three-verb machine (t/112's own
#    "exactly two resolutions and no third") reused per surface, not
#    duplicated as a second machine (DC4's own "not a second state machine").
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    rs($root, 'activate', '--surface', 'reporter');
    is(state_of($root, '--surface', 'reporter'), 'active', 'F1: reporter surface activates');

    my $until = time() + 300;
    my ($rcp) = rs($root, 'pause', '--watcher-pid', $$, '--until', $until, '--surface', 'reporter');
    is($rcp, 0, 'F2: reporter surface pause accepted with a live pid + future deadline');
    is(state_of($root, '--surface', 'reporter'), 'paused', 'F3: ...and reads back paused');

    rs($root, 'finish', '--reason', '"nothing pending"', '--surface', 'reporter');
    is(state_of($root, '--surface', 'reporter'), 'finished', 'F4: reporter surface finish -> finished');

    # The driver surface (default) never moved at all across this whole
    # sequence -- it was never mentioned by a single one of the calls above.
    is(state_of($root), 'inert',
       'F5 CANONICAL: the DRIVER (default) surface is untouched by an ENTIRE reporter-surface '
     . 'activate/pause/finish sequence -- not merely "different at one point in time" (D3-D5) '
     . 'but never perturbed at any point across the whole lifecycle');
}

done_testing();
