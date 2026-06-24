#!/usr/bin/env perl
# The .launcher directory contains launcher-managed metadata that the
# container must NOT write to: cache hashes (backpack-trusted-hash et al),
# snapshot files, blueprint canonicals, container metadata. A compromised
# in-container process could otherwise fake hashes to bypass backpack
# approval or corrupt the launcher's selection state.
#
# .launcher is overlaid as RO over the claude-home RW bind. This test
# proves the kernel-level enforcement: container can READ from .launcher
# but writes return EROFS / "Read-only file system".
#
# Separately: /root/.claude.json (single-file bind) and
# /root/.claude/.credentials.json (single-file bind from .launcher/) must
# remain writable from the container — claude writes settings during
# normal operation and writes OAuth tokens during `claude mcp add`.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_probe_container new_temp_dir);

plan tests => 5;

# Simulate the launcher's mount layout on a tempdir-backed claude-home:
#   claude-home → /root/.claude (RW)
#   claude-home/.launcher → /root/.claude/.launcher (RO overlay)
#   claude-home/.launcher/credentials.json → /root/.claude/.credentials.json (RW file bind)
#   claude-home/.claude.json → /root/.claude.json (RW file bind)
my $host_data = new_temp_dir();
my $launcher_dir = "$host_data/.launcher";
mkdir $launcher_dir or BAIL_OUT("mkdir $launcher_dir: $!");
# Seed launcher metadata to read inside the container.
open my $h1, '>', "$launcher_dir/backpack-trusted-hash" or BAIL_OUT($!);
print $h1 "deadbeefcafebabe1234567890abcdef\n"; close $h1;
open my $h2, '>', "$launcher_dir/credentials.json"     or BAIL_OUT($!);
print $h2 qq({"marker":"canonical-credentials"}\n);    close $h2;
open my $h3, '>', "$host_data/.claude.json"            or BAIL_OUT($!);
print $h3 qq({"marker":"canonical-claude-json"}\n);    close $h3;

my $c = create_probe_container(mounts => [
    '-v', "$host_data:/root/.claude",
    '-v', "$launcher_dir:/root/.claude/.launcher:ro",
    '-v', "$launcher_dir/credentials.json:/root/.claude/.credentials.json",
    '-v', "$host_data/.claude.json:/root/.claude.json",
]);

# 1. Container CAN read launcher metadata (e.g. statusline / skills reads).
my ($rc_r, $out_r) = podman_run_capture('exec', $c, 'cat',
    '/root/.claude/.launcher/backpack-trusted-hash');
like($out_r, qr/deadbeefcafebabe/, 'container can read .launcher metadata');

# 2. Container CANNOT write to .launcher (RO enforcement).
my ($rc_w) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo tamper > /root/.claude/.launcher/backpack-trusted-hash 2>/dev/null');
isnt($rc_w, 0, 'writes to .launcher are blocked at the kernel mount level');

# 3. Specifically, the host file is unchanged.
open my $rh, '<', "$launcher_dir/backpack-trusted-hash" or BAIL_OUT($!);
my $host_after = do { local $/; <$rh> }; close $rh;
like($host_after, qr/deadbeefcafebabe/,
     'host .launcher hash file is unchanged after attempted container write');

# 4. credentials.json file bind IS writable (mcpOAuth flow needs this).
my ($rc_cw) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo \'{"mcpOAuth":{"new":"token"}}\' > /root/.claude/.credentials.json');
is($rc_cw, 0, 'credentials.json single-file bind is RW from container');

# 5. .claude.json file bind IS writable (claude writes settings).
my ($rc_jw) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo \'{"hasCompletedOnboarding":true}\' > /root/.claude.json');
is($rc_jw, 0, '.claude.json single-file bind is RW from container');
