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
# Separately (Fix 1): /root/.claude/.credentials.json is NO LONGER a
# single-file bind — it lives at claude-home/.credentials.json and rides
# the claude-home RW dir bind as a REAL file. That is what makes an
# in-container OAuth refresh persist: the token-keeper / Claude Code write
# the refreshed token with an atomic temp+rename, and you cannot rename()
# over a single-file bind mountpoint (EBUSY). A real file in the dir bind
# accepts both in-place AND rename writes, and they land on the canonical
# host path. /root/.claude.json is still its own single-file RW bind.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_probe_container new_temp_dir);

plan tests => 7;

# Simulate the launcher's mount layout on a tempdir-backed claude-home:
#   claude-home → /root/.claude (RW)
#   claude-home/.launcher → /root/.claude/.launcher (RO overlay)
#   claude-home/.credentials.json → /root/.claude/.credentials.json
#       (REAL file in the dir bind — RW + rename-safe, NOT a single-file mount)
#   claude-home/.claude.json → /root/.claude.json (RW single-file bind)
my $host_data = new_temp_dir();
my $launcher_dir = "$host_data/.launcher";
mkdir $launcher_dir or BAIL_OUT("mkdir $launcher_dir: $!");
# Seed launcher metadata to read inside the container.
open my $h1, '>', "$launcher_dir/backpack-trusted-hash" or BAIL_OUT($!);
print $h1 "deadbeefcafebabe1234567890abcdef\n"; close $h1;
# Seed .credentials.json as a real file INSIDE claude-home (no single-file bind).
open my $h2, '>', "$host_data/.credentials.json"       or BAIL_OUT($!);
print $h2 qq({"marker":"canonical-credentials"}\n);    close $h2;
open my $h3, '>', "$host_data/.claude.json"            or BAIL_OUT($!);
print $h3 qq({"marker":"canonical-claude-json"}\n);    close $h3;

my $c = create_probe_container(mounts => [
    '-v', "$host_data:/root/.claude",
    '-v', "$launcher_dir:/root/.claude/.launcher:ro",
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

# 4. .credentials.json is writable IN PLACE (truncate+write) from the container.
my ($rc_cw) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo \'{"mcpOAuth":{"new":"token"}}\' > /root/.claude/.credentials.json');
is($rc_cw, 0, '.credentials.json (dir-bind real file) is RW from container');

# 5. THE Fix-1 regression: an atomic temp+rename write onto .credentials.json
#    SUCCEEDS. A single-file bind would reject rename-over-mount with EBUSY;
#    the dir-bind real file accepts it. This is exactly how Claude Code and
#    butler's token-keeper persist a refreshed OAuth token.
my ($rc_mv) = podman_run_capture('exec', $c, 'sh', '-c',
    'printf \'{"claudeAiOauth":{"accessToken":"refreshed-via-rename"}}\' '
  . '> /root/.claude/.credentials.json.tmp '
  . '&& mv /root/.claude/.credentials.json.tmp /root/.claude/.credentials.json');
is($rc_mv, 0, 'atomic temp+rename onto .credentials.json succeeds (rename-safe dir bind)');

# 6. The renamed content landed on the CANONICAL host file (claude-home),
#    so an in-container refresh persists across rebuild.
open my $rc2, '<', "$host_data/.credentials.json" or BAIL_OUT($!);
my $creds_after = do { local $/; <$rc2> }; close $rc2;
like($creds_after, qr/refreshed-via-rename/,
     'renamed .credentials.json content persists to the canonical host file');

# 7. .claude.json single-file bind IS writable (claude writes settings).
my ($rc_jw) = podman_run_capture('exec', $c, 'sh', '-c',
    'echo \'{"hasCompletedOnboarding":true}\' > /root/.claude.json');
is($rc_jw, 0, '.claude.json single-file bind is RW from container');
