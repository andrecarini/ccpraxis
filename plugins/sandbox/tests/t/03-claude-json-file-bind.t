#!/usr/bin/env perl
# Single-file bind mount of host's claude-home/.claude.json onto
# /root/.claude.json (file, not directory). Tests:
#   - host write before bind is visible inside container.
#   - container write is visible on host (RW bind).
#   - the mount target inside the container is a file, not a dir.
# These cover the "file-bind requires host file to exist" gotcha that
# would have podman silently auto-create a directory on the host if the
# file weren't pre-touched.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_probe_container new_temp_dir);

plan tests => 4;

my $host_dir = new_temp_dir();
my $host_json = "$host_dir/.claude.json";

# Pre-create the host file with a recognizable marker (this is what
# ensure_claude_json_host_file does, plus initial content).
open my $fh, '>', $host_json or BAIL_OUT("write $host_json: $!");
print $fh qq({"marker":"from-host"}\n);
close $fh;

# Probe container: single-file bind.
my $c = create_probe_container(mounts => ['-v', "$host_json:/root/.claude.json"]);

# 1. Mount target inside container is a file, not a directory.
my ($rc1, $out1) = podman_run_capture('exec', $c, 'test', '-f', '/root/.claude.json');
is($rc1, 0, '/root/.claude.json is a regular file inside container') or diag($out1);

# 2. Host-written marker is visible from inside container.
my ($rc2, $out2) = podman_run_capture('exec', $c, 'cat', '/root/.claude.json');
chomp $out2;
like($out2, qr/from-host/, 'host-written marker visible inside container');

# 3. Container write is visible on host.
my ($rc3) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo {"marker":"from-container"} > /root/.claude.json');
is($rc3, 0, 'container can write to /root/.claude.json (RW bind)');

open my $rfh, '<', $host_json or BAIL_OUT("re-read $host_json: $!");
my $host_content = do { local $/; <$rfh> };
close $rfh;
like($host_content, qr/from-container/, 'container-written content visible on host');
