#!/usr/bin/env perl
# 72-log-retention.t — LaunchLog::prune_logs.
#
# claude-home/sandbox-logs/ was never pruned. Two files per launch accumulated
# forever (48 of them on the operator's machine before anyone looked). The
# operator's call: keep the last 10 launches.
#
# The subtle requirement, and the reason retention is keyed on the LAUNCH ID
# rather than on files: one launch owns several files — `launch-<id>.log`,
# `launch-<id>.transcript.log`, `launch-<id>.bootstrap.log`. A file-by-file
# policy will happily keep a transcript whose JSON log it already deleted. That
# half-record reads as a complete one, which is worse than having neither.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use LaunchLog ();

# ---------------------------------------------------------------- grouping ---
# Pure, so the rule is pinned without touching a filesystem.
{
    my $g = LaunchLog::group_launch_files([
        'launch-20260101T000000Z-1.log',
        'launch-20260101T000000Z-1.transcript.log',
        'launch-20260101T000000Z-1.bootstrap.log',
        'launch-20260102T000000Z-2.log',
        'bootstrap-20251231T235959Z-99.log',
        'not-ours.log',
        'README.md',
        '',
    ]);
    is_deeply([sort @{ $g->{'20260101T000000Z-1'} }],
              [sort qw(launch-20260101T000000Z-1.log
                       launch-20260101T000000Z-1.transcript.log
                       launch-20260101T000000Z-1.bootstrap.log)],
              'all three files of one launch group under the same id');
    is_deeply($g->{'20260102T000000Z-2'}, ['launch-20260102T000000Z-2.log'],
              'a launch with only a JSON log is still a group');
    ok(exists $g->{"\0bootstrap:20251231T235959Z-99"},
       'a standalone bootstrap log gets its own series key');
    my @foreign = grep { /not-ours|README/ } map { @$_ } values %$g;
    is_deeply(\@foreign, [], 'unrelated files are never grouped, so never pruned');
}

# ------------------------------------------------------------------ pruning --

# Build $n launches, oldest first, with mtimes far enough apart to be orderable.
sub seed {
    my ($dir, $n, %o) = @_;
    my @ids;
    for my $i (1 .. $n) {
        my $id = sprintf('202601%02dT000000Z-%d', $i, 1000 + $i);
        push @ids, $id;
        for my $suffix ('.log', '.transcript.log') {
            my $p = "$dir/launch-$id$suffix";
            open my $fh, '>', $p or die "$p: $!";
            print $fh "x\n";
            close $fh;
            utime($i * 1000, $i * 1000, $p);
        }
    }
    return @ids;
}

{
    my $dir = tempdir(CLEANUP => 1);
    my @ids = seed($dir, 15);
    my @removed = LaunchLog::prune_logs($dir, 10, undef);

    my @left = do { opendir(my $dh, $dir); my @n = grep { /^launch-/ } readdir $dh; closedir $dh; sort @n };
    is(scalar @left, 20, '10 launches kept x 2 files each');
    is(scalar @removed, 10, '5 launches removed x 2 files each');

    # The kept ones must be the NEWEST ten, and each must be complete.
    for my $id (@ids[5 .. 14]) {
        ok(-f "$dir/launch-$id.log",            "kept: $id .log");
        ok(-f "$dir/launch-$id.transcript.log", "kept: $id .transcript.log");
    }
    for my $id (@ids[0 .. 4]) {
        ok(!-e "$dir/launch-$id.log",            "dropped: $id .log");
        ok(!-e "$dir/launch-$id.transcript.log", "dropped: $id .transcript.log — never orphaned from its JSON log");
    }
}

{
    # The launch writing right now must survive regardless of where it sorts.
    my $dir = tempdir(CLEANUP => 1);
    my @ids = seed($dir, 12);
    # Make the CURRENT launch look ancient, which is the shape that would break
    # a naive mtime-only policy.
    my $cur = $ids[0];
    utime(1, 1, "$dir/launch-$cur.log");
    utime(1, 1, "$dir/launch-$cur.transcript.log");
    LaunchLog::prune_logs($dir, 10, $cur);
    ok(-f "$dir/launch-$cur.log", 'the current launch is never pruned, even when it is the oldest by mtime');
}

{
    # Bootstrap logs are their own series: a first-time setup record must not be
    # evicted just because ten ordinary launches happened since.
    my $dir = tempdir(CLEANUP => 1);
    seed($dir, 12);
    my $bp = "$dir/bootstrap-20251231T235959Z-99.log";
    open my $fh, '>', $bp or die $!; print $fh "boot\n"; close $fh;
    utime(1, 1, $bp);                       # older than every launch
    LaunchLog::prune_logs($dir, 10, undef);
    ok(-f $bp, 'a bootstrap log survives its own retention window independently of launch logs');
}

{
    # Unrelated files in the directory are never touched.
    my $dir = tempdir(CLEANUP => 1);
    seed($dir, 12);
    for my $n (qw(README.md notes.txt launchpad.log)) {
        open my $fh, '>', "$dir/$n" or die $!; print $fh "keep\n"; close $fh;
    }
    LaunchLog::prune_logs($dir, 10, undef);
    ok(-f "$dir/$_", "untouched: $_") for qw(README.md notes.txt launchpad.log);
}

{
    # Under the limit: nothing is removed.
    my $dir = tempdir(CLEANUP => 1);
    seed($dir, 3);
    my @removed = LaunchLog::prune_logs($dir, 10, undef);
    is_deeply(\@removed, [], 'fewer launches than the limit -> nothing removed');
}

# ------------------------------------------------------------- robustness ----
# Housekeeping must never be able to fail a launch.
{
    is_deeply([LaunchLog::prune_logs(undef, 10, undef)],            [], 'undef dir -> no-op, no die');
    is_deeply([LaunchLog::prune_logs('/no/such/dir/anywhere', 10)], [], 'missing dir -> no-op, no die');
    my $dir = tempdir(CLEANUP => 1);
    seed($dir, 12);
    my @r = LaunchLog::prune_logs($dir, 0, undef);      # invalid keep
    ok(scalar @r >= 1, 'an invalid --keep falls back to the default rather than deleting everything');
    my @left = do { opendir(my $dh, $dir); my @n = grep { /^launch-/ } readdir $dh; closedir $dh; @n };
    is(scalar @left, 20, 'and the default is 10 launches, not 0');
}

done_testing();
