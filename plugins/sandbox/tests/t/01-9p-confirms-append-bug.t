#!/usr/bin/env perl
# Sanity: on a 9p host-bind mount (Podman/HyperV), O_APPEND writes fail
# with EIO. If this test ever PASSES (i.e. appends succeed), the upstream
# bug got fixed and the named-volume workaround is no longer necessary —
# investigate before treating that as "everything's still fine."

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_bin podman_run_capture create_probe_container new_temp_dir);

plan tests => 4;

my $podman = podman_bin();
my $host_dir = new_temp_dir();

# Mount the temp dir into the container — this goes over 9p on Windows/HyperV.
my $container = create_probe_container(
    mounts => ['-v', "$host_dir:/test-bind"],
);

# 1. Truncating write to a new file: must succeed.
my ($rc1, $out1) = podman_run_capture(
    'exec', $container, 'sh', '-c', 'echo line1 > /test-bind/probe.txt');
is($rc1, 0, '9p bind: truncating write to new file succeeds')
    or diag("output: $out1");

# 2. Verify the file is there and has content.
my ($rc2, $out2) = podman_run_capture(
    'exec', $container, 'cat', '/test-bind/probe.txt');
is($rc2, 0, '9p bind: file readable after truncating write');
like($out2, qr/^line1/, '9p bind: file content matches');

# 3. THE KEY ONE: appending to the same file. On a healthy filesystem
# this succeeds; on Podman/HyperV's 9p, it fails with EIO.
my ($rc3, $out3) = podman_run_capture(
    'exec', $container, 'sh', '-c', 'echo line2 >> /test-bind/probe.txt');
isnt($rc3, 0, '9p bind: append to existing file FAILS (this is the bug)')
    or diag("If this test passed, the 9p O_APPEND bug may be fixed upstream. "
          . "Verify against vanilla bind mounts before removing the workaround.");
