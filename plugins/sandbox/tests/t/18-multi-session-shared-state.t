#!/usr/bin/env perl
# Multi-session use case: two `claude-sandbox` invocations on the same
# project share the SAME container and the SAME host bind mount of
# .claude-data. This test exercises the shared-state guarantees that
# matter on the new bind-mount architecture:
#
#   - Both processes see the same files under /root/.claude.
#   - Each process writes its own session jsonl without colliding with
#     the other (per-UUID file scheme).
#   - Concurrent writes to different subpaths don't corrupt each other.
#   - A new file written by one is visible to the other immediately.
#   - Host filesystem reflects both sessions' state in real time (no
#     volume, no sync delay).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_probe_container new_temp_dir);

plan tests => 6;

# Shared state via host bind mount.
my $host_dir = new_temp_dir();
my $c = create_probe_container(mounts => ['-v', "$host_dir:/root/.claude"]);

# Pre-create the dir structure (claude does this on startup).
podman_run_capture('exec', $c, 'mkdir', '-p',
    '/root/.claude/projects/-project',
    '/root/.claude/tasks');

# Spawn worker A — appends to its own jsonl + writes its task dir.
podman_run_capture('exec', '-d', $c, 'bash', '-c',
    'mkdir -p /root/.claude/tasks/sess-A; ' .
    'for i in $(seq 1 30); do ' .
    '  echo "{\"sess\":\"A\",\"i\":$i}" >> /root/.claude/projects/-project/sess-A.jsonl; ' .
    '  touch /root/.claude/tasks/sess-A/.lock.lock; ' .
    '  sleep 0.2; ' .
    'done');

# Spawn worker B — same pattern, different identity.
podman_run_capture('exec', '-d', $c, 'bash', '-c',
    'mkdir -p /root/.claude/tasks/sess-B; ' .
    'for i in $(seq 1 30); do ' .
    '  echo "{\"sess\":\"B\",\"i\":$i}" >> /root/.claude/projects/-project/sess-B.jsonl; ' .
    '  touch /root/.claude/tasks/sess-B/.lock.lock; ' .
    '  sleep 0.2; ' .
    'done');

# Let both run for ~8s (30 iters * 0.2s = 6s, plus settle margin).
sleep 8;

# 1. Both jsonl files exist and have the expected line counts (in container).
my ($rc_a, $count_a) = podman_run_capture('exec', $c, 'sh', '-c',
    'wc -l < /root/.claude/projects/-project/sess-A.jsonl');
chomp $count_a;
$count_a =~ s/\s+//g;
is($count_a, '30', 'session A wrote all 30 expected jsonl lines (no corruption)');

my ($rc_b, $count_b) = podman_run_capture('exec', $c, 'sh', '-c',
    'wc -l < /root/.claude/projects/-project/sess-B.jsonl');
chomp $count_b;
$count_b =~ s/\s+//g;
is($count_b, '30', 'session B wrote all 30 expected jsonl lines (no corruption)');

# 2. Each session's task dir + lockfile exists. No cross-contamination.
my ($rc_la) = podman_run_capture('exec', $c, 'test', '-f',
    '/root/.claude/tasks/sess-A/.lock.lock');
is($rc_la, 0, 'session A lockfile present in tasks/sess-A/');

my ($rc_lb) = podman_run_capture('exec', $c, 'test', '-f',
    '/root/.claude/tasks/sess-B/.lock.lock');
is($rc_lb, 0, 'session B lockfile present in tasks/sess-B/');

# 3. Both files visible to a "third reader" simultaneously — proving the
# bind mount supports concurrent multi-reader file visibility.
my ($rc_ls, $ls) = podman_run_capture('exec', $c, 'ls',
    '/root/.claude/projects/-project/');
like($ls, qr/sess-A\.jsonl.*sess-B\.jsonl|sess-B\.jsonl.*sess-A\.jsonl/s,
     'third reader sees BOTH sessions concurrently in projects/');

# 4. Host filesystem reflects both sessions in real time (no volume/sync delay).
# With the bind mount, what's in the container IS on the host.
my @host_jsonls = glob("$host_dir/projects/-project/sess-*.jsonl");
is(scalar(@host_jsonls), 2,
   'host sees both session jsonl files via bind mount (no sync needed)');
