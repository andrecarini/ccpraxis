#!/usr/bin/env perl
# Exercises sync-sidecar.pl: a forked sidecar should copy volume state to
# the host on its --interval cadence, and self-exit when the container
# stops. This is the safety net for crash-loss between explicit syncs.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_volume create_probe_container new_temp_dir);
use POSIX qw(WNOHANG);

my $sidecar = "$Bin/../../scripts/sync-sidecar.pl";
plan skip_all => "sidecar script missing at $sidecar" unless -f $sidecar;

plan tests => 4;

my $vol = create_volume();
my $c = create_probe_container(mounts => ['-v', "$vol:/root/.claude/projects"]);

my $host_projects = new_temp_dir();
my $host_json     = new_temp_dir() . '/.claude.json';

# Fork the sidecar with a short interval so the test is fast (~5s vs 60s).
my $sidecar_pid = fork();
die "fork failed: $!" unless defined $sidecar_pid;
if ($sidecar_pid == 0) {
    exec($^X, $sidecar,
        '--container',     $c,
        '--host-projects', $host_projects,
        '--host-json',     $host_json,
        '--parent-pid',    $$,
        '--interval',      '3',
        '--quiet');
    exit 1;
}

# Write a file inside the volume from the container.
my ($rc1) = podman_run_capture(
    'exec', $c, 'sh', '-c',
    'echo "in-flight-data" > /root/.claude/projects/live.jsonl');
is($rc1, 0, 'wrote file inside volume from container');

# Wait long enough for at least one sidecar sync tick + an additional
# margin for podman cp latency.
sleep 8;

ok(-f "$host_projects/live.jsonl", 'sidecar copied file to host within interval');

open my $rfh, '<', "$host_projects/live.jsonl" or die "open: $!";
my $content = do { local $/; <$rfh> };
close $rfh;
like($content, qr/in-flight-data/, 'synced content matches what container wrote');

# Stop the container. Sidecar's container_is_running check should detect
# this and self-exit within ~1s of the next poll tick.
podman_run_capture('stop', '-t', '1', $c);

# Give the sidecar up to 15s to detect + shut down.
my $exited = 0;
for (1 .. 15) {
    my $r = waitpid($sidecar_pid, WNOHANG);
    if ($r > 0) { $exited = 1; last }
    sleep 1;
}

# If it didn't self-exit, kill it so we don't leak the process.
if (!$exited) {
    kill 'TERM', $sidecar_pid;
    waitpid($sidecar_pid, 0);
}
ok($exited, 'sidecar self-exited after container stopped');
