#!/usr/bin/env perl
# platform: any
# Pins AC-6 and AC-7 of the --state=failed spec (DC5 in the package ledger):
# a sweep killed mid-flight (SIGTERM, then SIGKILL if it does not yield) must
# leave the state file exactly as it was before the invocation started -- no
# premature write, so an in-flight file's prior "failed" status is never
# silently cleared -- and the final filename, read back, must contain only
# complete, newline-terminated lines, never a truncated partial write.
#
# A companion, un-killed control run against the SAME two-file fixture and an
# EMPTY state dir establishes the positive baseline this negative property is
# measured against: without a control run showing a completed sweep DOES
# write, "the state file is unchanged after a kill" would hold vacuously for
# any script that never implements writing at all. Both blocks are expected
# to fail against scripts/run-tests.pl as it stands today -- the control
# block because nothing is ever written yet, the kill block only in the
# sense that its positive companion is what gives it meaning (see the report
# for the full discussion of why the kill assertion alone cannot pin a
# feature's total absence).
#
# Kill choreography is the house pattern
# (TERM, brief grace, KILL, blocking waitpid). Every invocation of
# scripts/run-tests.pl targets this file's own File::Temp fixture, never the
# real plugins/*/tests/t/ tree, and every wait loop here is itself bounded.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);

use lib "$Bin/../lib";
use RunnerStateHarness qw(
    make_fixture_tree green_source sleeper_source
    state_file_path write_state_file read_state_file slurp_raw
    relpath_from_root
    spawn_runner run_runner_bounded
);

plan tests => 7;

my $fixture = make_fixture_tree(
    'quick-green.t' => green_source(),
    'slow-one.t'    => sleeper_source(5),
);
my $slow_path = File::Spec->catfile($fixture, 'tests', 't', 'slow-one.t');

# ---------------------------------------------------------------------------
# Control block: an UN-KILLED completed sweep against this fixture, empty
# state dir, DOES write -- the positive baseline the kill assertion below is
# measured against.
# ---------------------------------------------------------------------------
{
    my $state_dir = tempdir(CLEANUP => 1);
    my $res = run_runner_bounded(
        args    => ['--jobs', '1', $fixture],
        env     => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
        timeout => 20,
    );
    my @got = read_state_file($state_dir);
    is_deeply(\@got, [ relpath_from_root($slow_path) ],
        'control: a completed (non-killed) sweep over this fixture writes exactly the still-red slow-one.t to the state file');
}

# ---------------------------------------------------------------------------
# Kill-mid-flight block (AC-6 / AC-7).
# ---------------------------------------------------------------------------
{
    my $state_dir = tempdir(CLEANUP => 1);
    write_state_file($state_dir, relpath_from_root($slow_path));
    my $pristine = slurp_raw(state_file_path($state_dir));

    my $t0 = time;
    my ($pid, $out_path, $err_path) = spawn_runner(
        args => ['--jobs', '1', $fixture],
        env  => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
    );

    # ~1s: long enough for quick-green.t to finish and slow-one.t to be
    # forked and mid-sleep; short enough that slow-one.t cannot have exited.
    select(undef, undef, undef, 1.0);

    kill('TERM', $pid);
    my $waited = 0;
    while ($waited < 2) {
        my $r = waitpid($pid, WNOHANG);
        last if $r == $pid;
        select(undef, undef, undef, 0.1);
        $waited += 0.1;
    }
    if ((waitpid($pid, WNOHANG) // 0) != $pid) {
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    my $elapsed = time - $t0;

    ok($elapsed < 4,
        "sanity: the kill sequence completed in ${elapsed}s, well under slow-one.t's 5s sleep -- proves the child was actually interrupted mid-flight, not merely outrun");

    my $after = slurp_raw(state_file_path($state_dir));
    is($after, $pristine,
        'AC-6: the state file is byte-identical to its pre-seeded content after a TERM/KILL mid-sweep -- no premature write');

    ok(defined($after) && (length($after) == 0 || $after =~ /\n\z/),
        'AC-7: the exact final filename, read back, contains only complete newline-terminated lines -- no truncated trailing partial line');

    unlink $out_path, $err_path;
}

# ---------------------------------------------------------------------------
# Repeat the kill scenario starting from an EMPTY state dir (no pre-seed),
# proving the negative property holds independent of whether anything was
# recorded before -- a kill must never CREATE a state file describing a
# partially-examined run either.
# ---------------------------------------------------------------------------
{
    my $state_dir = tempdir(CLEANUP => 1);
    ok(!-f state_file_path($state_dir), 'sanity: no pre-existing state file for the empty-start kill variant');

    my $t0 = time;
    my ($pid, $out_path, $err_path) = spawn_runner(
        args => ['--jobs', '1', $fixture],
        env  => { CCPRAXIS_TEST_STATE_DIR => $state_dir },
    );
    select(undef, undef, undef, 1.0);
    kill('TERM', $pid);
    my $waited = 0;
    while ($waited < 2) {
        my $r = waitpid($pid, WNOHANG);
        last if $r == $pid;
        select(undef, undef, undef, 0.1);
        $waited += 0.1;
    }
    if ((waitpid($pid, WNOHANG) // 0) != $pid) {
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    my $elapsed = time - $t0;
    ok($elapsed < 4, "sanity: the empty-start kill sequence also completed in ${elapsed}s, well under the 5s sleep");

    ok(!-f state_file_path($state_dir),
        'AC-6 (empty-start variant): a kill mid-sweep does not CREATE a state file where none existed');

    unlink $out_path, $err_path;
}

done_testing();
