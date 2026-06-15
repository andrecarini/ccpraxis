#!/usr/bin/env perl
# Validates the container's keep-alive pattern that the Containerfile
# bakes in: a heartbeat-only loop that watches /tmp/.launcher-alive
# mtime and reaps the container if the sentinel goes stale.
#
# Uses the same shell logic with a shorter HB (staleness window) and
# GRACE (startup grace) so the test runs in ~25s instead of ~5 min.
#
# Two scenarios:
#   1. No heartbeat refresh: container should self-exit within
#      GRACE + HB + loop margin.
#   2. Periodic heartbeat refresh: container stays alive past the HB
#      window because each tick advances the sentinel mtime.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_bin podman_run_capture new_container_name register_cleanup_container probe_image);

plan tests => 4;

my $podman = podman_bin();

# Heartbeat-only keep-alive script. Mirrors the Containerfile ENTRYPOINT
# logic exactly, except HB and GRACE are shrunk for test speed.
my $cmd = q{
    START=$SECONDS
    ALIVE=/tmp/.launcher-alive
    HB=5
    GRACE=2
    while true; do
        EL=$((SECONDS-START))
        if [ $EL -lt $GRACE ]; then sleep 1; continue; fi
        if [ -f $ALIVE ]; then
            LAST=$(stat -c %Y $ALIVE 2>/dev/null || echo 0)
            NOW=$(date +%s)
            if [ $((NOW-LAST)) -lt $HB ]; then sleep 1; continue; fi
        fi
        break
    done
};

# Scenario 1: no heartbeat, container should self-exit.
{
    my $name = new_container_name();
    register_cleanup_container($name);
    my ($rc, $out) = podman_run_capture('run', '-d', '--name', $name,
        probe_image(), 'bash', '-c', $cmd);
    is($rc, 0, 'no-heartbeat container started') or diag($out);

    # Wait GRACE(2) + HB(5) + loop margin(2) = ~9s. Then check state.
    sleep 10;
    my ($rc2, $state) = podman_run_capture('inspect', '--format',
        '{{.State.Status}}', $name);
    chomp $state;
    is($state, 'exited',
       'no-heartbeat container self-exited within GRACE+HB+margin');
}

# Scenario 2: periodic heartbeat keeps the container alive.
{
    my $name = new_container_name();
    register_cleanup_container($name);
    my ($rc, $out) = podman_run_capture('run', '-d', '--name', $name,
        probe_image(), 'bash', '-c', $cmd);
    is($rc, 0, 'heartbeat-refresh container started') or diag($out);

    # Touch the sentinel IMMEDIATELY (mirrors what the launcher does
    # right after `podman start` returns). If we waited until after
    # GRACE+HB expires the container would race to `break` before our
    # first touch lands.
    podman_run_capture('exec', $name, 'touch', '/tmp/.launcher-alive');
    # Then refresh every 2s for ~12s (well past HB=5) to prove the
    # heartbeat keeps it alive indefinitely while refreshes continue.
    for (1 .. 6) {
        sleep 2;
        podman_run_capture('exec', $name, 'touch', '/tmp/.launcher-alive');
    }
    my ($rc2, $state) = podman_run_capture('inspect', '--format',
        '{{.State.Status}}', $name);
    chomp $state;
    is($state, 'running',
       'periodic heartbeat keeps container alive past the HB window');
}
