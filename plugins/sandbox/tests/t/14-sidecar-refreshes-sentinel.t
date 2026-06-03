#!/usr/bin/env perl
# Structural: sync-sidecar.pl must refresh /tmp/.launcher-alive every
# sync tick. If it stops touching, the container heartbeat goes stale and
# the container exits within 120s — even though the user clearly wanted
# it to stay alive (sidecar is alive, which is what running launcher
# means).

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

plan tests => 3;

my $sidecar = "$Bin/../../scripts/sync-sidecar.pl";
ok(-f $sidecar, 'sync-sidecar.pl present') or BAIL_OUT;

open my $fh, '<', $sidecar or BAIL_OUT("open: $!");
my $src = do { local $/; <$fh> };
close $fh;

# Must define a heartbeat-touch sub. The exact name doesn't matter for
# the test contract — just that SOME code path runs `podman exec ... touch
# /tmp/.launcher-alive`.
like($src, qr/touch.*?\.launcher-alive/,
     'sync-sidecar.pl contains a touch /tmp/.launcher-alive call');

# And that call must be reached during the normal sync cycle (sync_once
# is the per-tick entry point). Check by lexical proximity: a call to
# touch-sentinel logic should appear inside or immediately above sync_once.
my ($sync_once_block) = $src =~ /(sub\s+sync_once\b.*?^\})/ms;
ok(defined($sync_once_block) && length($sync_once_block) > 0 &&
     ($sync_once_block =~ /refresh_heartbeat|\.launcher-alive/),
   'sync_once invokes the heartbeat refresh (directly or via a helper sub)')
   or diag("sync_once body did not reference the sentinel or a refresh helper");
