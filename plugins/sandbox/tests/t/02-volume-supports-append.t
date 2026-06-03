#!/usr/bin/env perl
# Critical: a podman named volume (backed by the in-machine xfs filesystem)
# supports O_APPEND writes — this is the entire premise of the workaround.
# If this test fails, the hybrid sync approach in launcher.pl is dead in
# the water.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_volume create_probe_container);

plan tests => 4;

my $vol = create_volume();
my $container = create_probe_container(
    mounts => ['-v', "$vol:/test-vol"],
);

my ($rc1, $out1) = podman_run_capture(
    'exec', $container, 'sh', '-c', 'echo line1 > /test-vol/probe.txt');
is($rc1, 0, 'volume: truncating write succeeds') or diag($out1);

# THE KEY ONE: append to existing file via O_APPEND. This is what
# breaks on 9p and works on xfs.
my ($rc2, $out2) = podman_run_capture(
    'exec', $container, 'sh', '-c', 'echo line2 >> /test-vol/probe.txt');
is($rc2, 0, 'volume: O_APPEND write to existing file succeeds') or diag($out2);

my ($rc3, $out3) = podman_run_capture('exec', $container, 'cat', '/test-vol/probe.txt');
is($rc3, 0, 'volume: file readable after appends');
like($out3, qr/line1.*line2/s, 'volume: file content has both lines in order');
