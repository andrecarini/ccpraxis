#!/usr/bin/env perl
# Dir-bind + CLAUDE_CONFIG_DIR shape (s02-config-safety-implement spec
# B38-B41 / AC23): the probe container mounts the host claude-home
# directory at /root/.claude (RW dir bind, as before) and sets
# `-e CLAUDE_CONFIG_DIR=/root/.claude` on `podman create`. There is NO
# separate `/root/.claude.json` single-file bind anymore. The CLI's
# config resolver follows CLAUDE_CONFIG_DIR and reads/writes an ORDINARY
# file at /root/.claude/.claude.json, inside the dir bind, where atomic
# temp+rename() works. (s01 probe-01 Case A/B: a single-file bind rejects
# rename-over-mount with EBUSY and forces a non-atomic in-place
# truncate+write — the bug this package eliminates.) Tests:
#   - /root/.claude is a directory; /root/.claude/.claude.json is a
#     regular file living INSIDE that dir bind (same device as its
#     parent — not its own mountpoint); no top-level /root/.claude.json
#     path exists at all (the old single-file bind is gone).
#   - host write before container start is visible inside the container.
#   - a container write is visible on the host (RW bind, as before).
#   - an atomic `printf > tmp && mv tmp .claude.json` inside the
#     container SUCCEEDS (exit 0, no EBUSY) and the renamed content
#     lands on the canonical host file — the direct regression test for
#     s01 probe-01 Case A/B at the post-fix path shape.
#   - CLAUDE_CONFIG_DIR is exactly /root/.claude inside the container.
#
# This test is TestSandbox/podman-based and therefore host-only: it dies
# at `use TestSandbox` (exit 127) whenever no docker/podman is on PATH,
# which is always true in this sandbox container (TestSandbox.pm:45 dies,
# not skips, by design — that module is outside this package's write
# set). That exit-127 is expected and pre-existing here; this test's
# green must come from a host-side run.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_probe_container new_temp_dir);

plan tests => 10;

my $host_dir = new_temp_dir();
my $host_json = "$host_dir/.claude.json";

# Pre-create the host file with a recognizable marker (this is what
# ensure_claude_json_onboarded does, plus initial content).
open my $fh, '>', $host_json or BAIL_OUT("write $host_json: $!");
print $fh qq({"marker":"from-host"}\n);
close $fh;

# Probe container: dir bind + CLAUDE_CONFIG_DIR only. NO
# `-v .../.claude.json:/root/.claude.json` single-file bind (B38).
my $c = create_probe_container(mounts => [
    '-v', "$host_dir:/root/.claude",
    '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
]);

# 1. /root/.claude is a directory inside the container.
my ($rc_dir, $out_dir) = podman_run_capture('exec', $c, 'test', '-d', '/root/.claude');
is($rc_dir, 0, '/root/.claude is a directory inside container') or diag($out_dir);

# 2. /root/.claude/.claude.json is a regular file inside the container.
my ($rc_f, $out_f) = podman_run_capture('exec', $c, 'test', '-f', '/root/.claude/.claude.json');
is($rc_f, 0, '/root/.claude/.claude.json is a regular file inside container') or diag($out_f);

# 3. It is NOT its own mountpoint — same device id as its parent dir
# bind, i.e. an ordinary file living inside the /root/.claude bind, not
# a separate single-file bind layered on top of it.
my ($rc_dev, $out_dev) = podman_run_capture('exec', $c, 'sh', '-c',
    '[ "$(stat -c %d /root/.claude)" = "$(stat -c %d /root/.claude/.claude.json)" ]');
is($rc_dev, 0, '/root/.claude/.claude.json is not a mountpoint (same device as /root/.claude)')
    or diag($out_dev);

# 4. There is no separate top-level /root/.claude.json single-file bind.
my ($rc_old, $out_old) = podman_run_capture('exec', $c, 'sh', '-c', 'test ! -e /root/.claude.json');
is($rc_old, 0, 'no top-level /root/.claude.json path exists (single-file bind is gone, B38)')
    or diag($out_old);

# 5. Host-written marker is visible from inside container.
my ($rc2, $out2) = podman_run_capture('exec', $c, 'cat', '/root/.claude/.claude.json');
chomp $out2;
like($out2, qr/from-host/, 'host-written marker visible inside container at /root/.claude/.claude.json');

# 6. Container write is visible on host.
my ($rc3) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo {"marker":"from-container"} > /root/.claude/.claude.json');
is($rc3, 0, 'container can write to /root/.claude/.claude.json (RW dir bind)');

open my $rfh, '<', $host_json or BAIL_OUT("re-read $host_json: $!");
my $host_content = do { local $/; <$rfh> };
close $rfh;
like($host_content, qr/from-container/, 'container-written content visible on host');

# 7. Atomic temp+rename() over /root/.claude/.claude.json succeeds with
# no EBUSY — the direct regression test for s01 probe-01 Case A/B.
my ($rc_mv, $out_mv) = podman_run_capture('exec', $c, 'sh', '-c',
    'printf \'{"marker":"from-rename"}\' > /root/.claude/.claude.json.tmp '
  . '&& mv /root/.claude/.claude.json.tmp /root/.claude/.claude.json');
is($rc_mv, 0, 'atomic temp+rename onto /root/.claude/.claude.json succeeds (no EBUSY)') or diag($out_mv);

# 8. The renamed content landed on the canonical host file.
open my $rfh2, '<', $host_json or BAIL_OUT("re-read $host_json: $!");
my $host_after_rename = do { local $/; <$rfh2> };
close $rfh2;
like($host_after_rename, qr/from-rename/, 'renamed content lands on the canonical host .claude.json file');

# 9. CLAUDE_CONFIG_DIR is exactly /root/.claude inside the container (B40).
my ($rc_env, $out_env) = podman_run_capture('exec', $c, 'sh', '-c', 'env | grep ^CLAUDE_CONFIG_DIR=');
chomp $out_env;
is($out_env, 'CLAUDE_CONFIG_DIR=/root/.claude',
   'CLAUDE_CONFIG_DIR is exactly /root/.claude inside container');
