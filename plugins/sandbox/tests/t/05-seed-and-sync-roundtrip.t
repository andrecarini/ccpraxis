#!/usr/bin/env perl
# Exercises the seed + sync path the launcher relies on: host data flows
# into a volume via `podman cp`, claude-like activity (appends) mutates
# inside the container, and `podman cp` back to the host preserves the
# result. This is the end-to-end claim that lets us trust the workaround
# without trusting the 9p bind for the write path.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_volume create_probe_container new_temp_dir);

plan tests => 5;

# A) Host source dir with an existing "session jsonl"
my $host_src = new_temp_dir();
open my $fh, '>', "$host_src/session.jsonl" or die;
print $fh "old-line-from-host\n";
close $fh;

# B) Volume + container, volume mounted at the same path the launcher uses
# (we don't actually care about path naming for this test, but mirror it
# to surface mount-path bugs).
my $vol = create_volume();
my $c = create_probe_container(mounts => ['-v', "$vol:/root/.claude/projects"]);

# C) Seed: podman cp host's contents into the volume.
my ($rc_seed, $out_seed) = podman_run_capture(
    'cp', "$host_src/.", "${c}:/root/.claude/projects/");
is($rc_seed, 0, 'seed: podman cp host -> container volume') or diag($out_seed);

# D) Inside the container: append (O_APPEND) — the operation that 9p
# rejects but the volume accepts.
my ($rc_app, $out_app) = podman_run_capture(
    'exec', $c, 'sh', '-c',
    'echo new-line-from-container >> /root/.claude/projects/session.jsonl');
is($rc_app, 0, 'append to seeded file inside container succeeds') or diag($out_app);

# E) Sync back: podman cp volume contents to a fresh host target.
my $host_dst = new_temp_dir();
my ($rc_sync, $out_sync) = podman_run_capture(
    'cp', "${c}:/root/.claude/projects/.", "$host_dst/");
is($rc_sync, 0, 'sync: podman cp container volume -> host') or diag($out_sync);

# F) Verify the synced file has both the seeded line and the appended one.
ok(-f "$host_dst/session.jsonl", 'synced file exists on host');
open my $rfh, '<', "$host_dst/session.jsonl" or die;
my $content = do { local $/; <$rfh> };
close $rfh;
like($content, qr/old-line-from-host.*new-line-from-container/s,
     'host destination has both seed line and container append');
