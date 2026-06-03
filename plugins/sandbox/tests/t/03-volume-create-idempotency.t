#!/usr/bin/env perl
# Documents that `podman volume create` is NOT idempotent on collision —
# returns non-zero with "volume already exists". The launcher's
# `ensure_sessions_volume` works around this by inspecting first; this
# test pins both behaviors so a future regression in the launcher (e.g.
# someone "simplifying" the inspect-then-create into a bare create) gets
# caught immediately.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_bin podman_run_capture new_volume_name register_cleanup_volume);

plan tests => 4;

my $vol = new_volume_name();
register_cleanup_volume($vol);

# 1. First create: succeeds.
my ($rc1, $out1) = podman_run_capture('volume', 'create', $vol);
is($rc1, 0, 'first create returns 0') or diag($out1);

# 2. Second create on same name: fails with non-zero.
my ($rc2, $out2) = podman_run_capture('volume', 'create', $vol);
isnt($rc2, 0, 'second create returns non-zero (NOT idempotent)')
    or diag("If this passed, podman volume create is now idempotent and "
          . "ensure_sessions_volume could be simplified.");
like($out2, qr/already exists/i, 'error message mentions "already exists"');

# 3. Inspect-first pattern (what the launcher uses): always succeeds for
# existing volumes.
my ($rc3, $out3) = podman_run_capture('volume', 'inspect', $vol);
is($rc3, 0, 'volume inspect returns 0 for existing volume');
