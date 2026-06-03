#!/usr/bin/env perl
# Volume contents must survive container removal, so rebuilds don't blow
# away the user's sessions. Without this guarantee the entire premise of
# the workaround collapses — the host bind mount existed precisely to
# survive rebuilds; the volume needs to match that promise.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_bin podman_run_capture create_volume create_probe_container new_container_name register_cleanup_container probe_image);

plan tests => 4;

my $podman = podman_bin();
my $vol = create_volume();

# First container: write a sentinel into the volume.
my $c1 = create_probe_container(mounts => ['-v', "$vol:/vol"]);
my ($rc1, $out1) = podman_run_capture(
    'exec', $c1, 'sh', '-c', 'echo "sentinel content" > /vol/marker.txt');
is($rc1, 0, 'first container wrote sentinel');

# Remove the first container completely.
my ($rc_rm, $out_rm) = podman_run_capture('rm', '-f', $c1);
is($rc_rm, 0, 'first container removed');

# Second container with the SAME volume.
my $c2 = create_probe_container(mounts => ['-v', "$vol:/vol"]);

# Check the sentinel is still there.
my ($rc2, $out2) = podman_run_capture('exec', $c2, 'cat', '/vol/marker.txt');
is($rc2, 0, 'second container reads file from re-mounted volume');
like($out2, qr/sentinel content/, 'content preserved across container rm');
