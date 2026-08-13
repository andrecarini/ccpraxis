#!/usr/bin/env perl
# Regression suite for the b01-backpack-install-accounting step-7 fix-batch.
# Each block below reproduces a defect from the step-6 reviewer/red-team
# reports that the immutable oracle files (03-06) did NOT catch -- that is
# exactly why they survived to step 6. This file is NEW (03-06 are immutable
# and were never touched).
#
# BP_UNDER_TEST may be set to point at an alternate backpack.pl (e.g. a
# pre-fix snapshot) to prove a given block fails before the fix and passes
# after it -- see the fixbatch-step7.md report for the recorded before/after
# runs. Defaults to the real script in this checkout.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $BP = $ENV{BP_UNDER_TEST} // "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl under test exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

sub item {
    my ($name, %extra) = @_;
    return { category => 'other', name => $name, install => 'true', verify => 'true', %extra };
}

sub write_backpack {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh encode_json({ version => 2, items => \@items });
    close $fh;
}

sub run_bp {
    my (@args) = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null');
        open(STDERR, '>&', \*STDOUT);
        exec($^X, $BP, @args);
        CORE::exit(127);
    }
    my @lines;
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        @lines = <$fh>;
        alarm 0;
    };
    if ($@) { $timed_out = 1; kill 'KILL', $pid; }
    alarm 0;
    close $fh;
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc);
}

# ---------------------------------------------------------------------------
# BLOCKER-1: a count-preserving substitution (one declared item dropped,
# one undeclared item filling its slot -- same COUNT, different MEMBERSHIP)
# must make RECONCILE fire as MISMATCH, never OK. Reproducer from the
# red-team report (BLOCKER-1).
# ---------------------------------------------------------------------------
{
    my $declared_path = "$dir/b1-declared.json";
    my $set_path       = "$dir/b1-set.json";
    write_backpack($declared_path, item('x'), item('y'), item('z'));
    write_backpack($set_path,      item('x'), item('y'), item('w'));  # z dropped, w substituted (not declared)

    my ($out, $rc) = run_bp('install', $set_path, '--declared', $declared_path);

    unlike($out, qr/^RECONCILE: OK$/m,
        'BLOCKER-1: a count-preserving substitution must NOT report RECONCILE: OK')
        or diag("  got:\n$out");
    like($out, qr/^RECONCILE: MISMATCH$/m,
        'BLOCKER-1: a count-preserving substitution reports RECONCILE: MISMATCH')
        or diag("  got:\n$out");
    like($out, qr/^ABSENT: other:z /m,
        'BLOCKER-1: the dropped declared item (z) still gets its ABSENT line');
}

# ---------------------------------------------------------------------------
# BLOCKER-2: a dropped declared item with NO dependents (so nothing else
# fails) must still make the process exit non-zero -- the original incident's
# exact shape (all-SKIP run, one declared item silently absent). Reproducer
# from the red-team report (BLOCKER-2).
# ---------------------------------------------------------------------------
{
    my $declared_path = "$dir/b2-declared.json";
    my $set_path       = "$dir/b2-set.json";
    write_backpack($declared_path, item('x'), item('y'), item('z'));
    write_backpack($set_path,      item('x'), item('y'));   # z silently dropped, no dependents

    my ($out, $rc) = run_bp('install', $set_path, '--declared', $declared_path);

    like($out, qr/^RECONCILE: MISMATCH$/m, 'BLOCKER-2: reconciliation still fires') or diag("  got:\n$out");
    isnt($rc, 0,
        'BLOCKER-2: a dropped declared item with no dependents still makes install exit non-zero')
        or diag("  got:\n$out  rc=$rc");
    isnt($rc, 1,
        'BLOCKER-2: the reconcile-only failure is a DISTINCT exit code from an item install/verify failure (not 1)')
        or diag("  got:\n$out  rc=$rc");
}

# ---------------------------------------------------------------------------
# MAJOR-1: a dependency cycle must not be reported as ordinary
# "load_bearing: no" in the `deps` audit table -- that gives zero indication
# that `install` would refuse to run on this file at all. Covers both a
# mutual cycle and a self-loop, per the red-team's reproducers.
# ---------------------------------------------------------------------------
{
    my $mutual_path = "$dir/m1-cycle.json";
    write_backpack($mutual_path,
        item('a', depends_on => ['other:b']),
        item('b', depends_on => ['other:a']),
    );
    my ($out, $rc) = run_bp('deps', $mutual_path, '--note', 'regression fixture');
    unlike($out, qr/other:b - depends_on: other:a - load_bearing: no/,
        'MAJOR-1: a mutual-cycle member is not silently reported load_bearing: no')
        or diag("  got:\n$out");
    like($out, qr/other:b - depends_on: other:a - load_bearing: CYCLE/,
        'MAJOR-1: a mutual-cycle member is reported as a cycle member')
        or diag("  got:\n$out");

    my $self_path = "$dir/m1-selfloop.json";
    write_backpack($self_path, item('s', depends_on => ['other:s']));
    my ($out2, $rc2) = run_bp('deps', $self_path, '--note', 'regression fixture');
    unlike($out2, qr/other:s - depends_on: other:s - load_bearing: no/,
        'MAJOR-1: a self-loop is not silently reported load_bearing: no')
        or diag("  got:\n$out2");
}

# ---------------------------------------------------------------------------
# MAJOR-2: depends_on entries get the same control/escape-character
# validation every other field already receives. Reproducer from the
# red-team report (MAJOR-2): an ANSI cursor/erase sequence in depends_on.
# ---------------------------------------------------------------------------
{
    my $ansi = "\x1b[2K\x1b[1A\x1b[31mFAKE-OK\x1b[0m";
    my $path = "$dir/m2-ansi.json";
    write_backpack($path, item('a', depends_on => [$ansi]));

    my ($out, $rc) = run_bp('validate', $path);
    isnt($rc, 0,
        'MAJOR-2: a depends_on entry with control/escape characters fails validate (same as other fields)')
        or diag("  got:\n$out  rc=$rc");
    like($out, qr/depends_on/, 'MAJOR-2: the validate error names depends_on') or diag("  got:\n$out");
}

# ---------------------------------------------------------------------------
# MINOR-1: a missing/unparseable --declared file must degrade (loud warning,
# reconciliation skipped) rather than abort the ENTIRE install pass -- that
# would make the accounting layer itself a new all-or-nothing gate. Reproducer
# from the red-team report (MINOR-1).
# ---------------------------------------------------------------------------
{
    my $set_path = "$dir/m3-set.json";
    write_backpack($set_path, item('p'));   # trivially-idempotent, SKIP path

    my ($out, $rc) = run_bp('install', $set_path, '--declared', "$dir/does-not-exist.json");

    is($rc, 0,
        'MINOR-1: a missing --declared file does not abort the install pass (handed items still processed)')
        or diag("  got:\n$out  rc=$rc");
    like($out, qr/^SKIP: other:p /m,
        'MINOR-1: the handed install-set item still gets its normal disposition line')
        or diag("  got:\n$out");
    unlike($out, qr/^RECONCILE: /m,
        'MINOR-1: reconciliation is skipped (not fabricated) when --declared is unusable');
}

done_testing();
