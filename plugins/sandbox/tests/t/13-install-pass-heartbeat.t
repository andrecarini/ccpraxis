#!/usr/bin/env perl
# Regression test for the install-pass heartbeat pattern in launcher.pl.
#
# Bug history: the launcher used to land its first /tmp/.launcher-alive
# touch AFTER the backpack install pass completed. For large installs
# (e.g. chromium = 289 deps / 221MB), the install ran longer than the
# container's combined GRACE + HB window, so the entrypoint loop reaped
# the container mid-`apt-get install` and the next podman exec failed
# with "container state improper".
#
# Fix: launcher.pl runs apt-get update + backpack install + a parallel
# heartbeat refresher under a single `podman exec bash`, with the
# refresher running as a background subshell tied to the bash's lifetime
# via `trap EXIT`. This test mirrors that exact pattern with shrunken
# timings (HB=5, GRACE=2) so it runs in ~25s.
#
# Two scenarios:
#   1. Long "install" WITH heartbeat refresher: container stays alive.
#   2. Long "install" WITHOUT heartbeat refresher: container reaps itself.
# Both confirm the pattern is load-bearing.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_bin podman_run_capture new_container_name register_cleanup_container probe_image);

plan tests => 6;

my $podman = podman_bin();

# Container entrypoint: mirrors the Containerfile's heartbeat-only loop
# with HB and GRACE shrunk for test speed.
my $entry = q{
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

# The install-pass pattern from launcher.pl, exact same shape — heartbeat
# subshell in background + foreground work, EXIT trap cleans up. Sleeps
# 12s to simulate an install that takes well over HB=5.
my $install_with_hb = q{
    HB_PID=""
    cleanup() { [ -n "$HB_PID" ] && kill "$HB_PID" 2>/dev/null; }
    trap cleanup EXIT INT TERM HUP
    ( while true; do touch /tmp/.launcher-alive; sleep 1; done ) &
    HB_PID=$!
    sleep 12
    echo "install-done"
};

# Same workload WITHOUT the heartbeat subshell — proves the heartbeat
# is what's keeping the container alive (not some other side effect).
my $install_no_hb = q{
    sleep 12
    echo "install-done"
};

# Scenario 1: WITH heartbeat refresher → container survives.
{
    my $name = new_container_name();
    register_cleanup_container($name);
    my ($rc, $out) = podman_run_capture('run', '-d', '--name', $name,
        probe_image(), 'bash', '-c', $entry);
    is($rc, 0, 'scenario-1 container started') or diag($out);

    # Launcher's first sentinel touch (lands immediately after podman start
    # to satisfy the GRACE window).
    podman_run_capture('exec', $name, 'touch', '/tmp/.launcher-alive');

    # Now run the install-pass bash pattern. The internal refresher should
    # keep the sentinel fresh while the foreground sleep blocks for 12s.
    my ($rc2, $install_out) = podman_run_capture('exec', $name,
        'bash', '-c', $install_with_hb);
    is($rc2, 0,
       'install-pass bash exited 0 (container survived the HB window)')
        or diag($install_out);
    like($install_out, qr/install-done/,
         'foreground "install" body actually completed');

    # Confirm container is still up after the install pass returns —
    # the EXIT trap should have killed the heartbeat subshell, but the
    # container itself stays alive (main entrypoint loop still running).
    my ($rc3, $state) = podman_run_capture('inspect', '--format',
        '{{.State.Status}}', $name);
    chomp $state;
    is($state, 'running',
       'container is still running after install-pass returns');
}

# Scenario 2: WITHOUT heartbeat → container dies mid-install, proving the
# refresher is what's load-bearing in the install-pass pattern.
{
    my $name = new_container_name();
    register_cleanup_container($name);
    my ($rc, $out) = podman_run_capture('run', '-d', '--name', $name,
        probe_image(), 'bash', '-c', $entry);
    is($rc, 0, 'scenario-2 container started') or diag($out);

    # First sentinel touch (as in scenario 1), to make this a fair
    # comparison — the ONLY difference between the two scenarios is the
    # presence of the heartbeat refresher inside the install pass.
    podman_run_capture('exec', $name, 'touch', '/tmp/.launcher-alive');

    # Run the install pass WITHOUT a heartbeat refresher. The 12s sleep
    # exceeds GRACE+HB=7s, so the container should self-exit mid-flight
    # and this exec should report failure (or come back with the entry
    # loop already broken when we inspect afterwards).
    podman_run_capture('exec', $name, 'bash', '-c', $install_no_hb);

    # Give podman a moment to reflect the state change after the
    # container's entrypoint loop breaks.
    sleep 2;

    my ($rc3, $state) = podman_run_capture('inspect', '--format',
        '{{.State.Status}}', $name);
    chomp $state;
    is($state, 'exited',
       'control case: container reaps itself mid-install when no heartbeat refresher runs');
}
