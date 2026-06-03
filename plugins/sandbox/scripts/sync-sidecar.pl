#!/usr/bin/env perl
# sync-sidecar.pl — periodic host-side sync of the sessions volume + .claude.json.
#
# The container's mount setup overlays a podman named volume on
# /root/.claude/projects (because the 9p bind from host rejects O_APPEND
# writes with EIO on Podman/HyperV — see SESSIONS_VOLUME comment in
# launcher.pl). The host bind mount is no longer the live target for those
# files. To keep the host's .claude-data/projects/ in sync with the running
# container's writes, this sidecar periodically `podman cp`s from the
# container back to the host.
#
# Why a separate process: the launcher needs to keep its main thread on the
# claude subprocess (so it returns when claude exits). A periodic sync has
# to run concurrently, hence a forked child. The child also handles the
# crash case — if the launcher dies abnormally, the sidecar notices via
# parent-PID polling and exits, so stray sidecars don't pile up.
#
# Args:
#   --container NAME          podman container to copy out of (required)
#   --host-projects PATH      target dir for sessions sync (required)
#   --host-json PATH          target path for .claude.json sync (required)
#   --parent-pid PID          launcher's PID; sidecar exits if it dies (required)
#   --interval SECONDS        sync interval, default 60
#   --quiet                   suppress per-iteration stderr noise
#
# Exit codes:
#   0   normal (SIGTERM, container stopped, parent died)
#   1   fatal misconfiguration

use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname);

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;
my $PODMAN = $WINDOWS_FAMILY ? 'podman.exe' : 'podman';

my $CONTAINER;
my $HOST_PROJECTS;
my $HOST_JSON;
my $PARENT_PID;
my $INTERVAL = 60;
my $QUIET    = 0;

{
    my @argv = @ARGV;
    while (@argv) {
        my $a = shift @argv;
        if    ($a eq '--container'     && @argv) { $CONTAINER     = shift @argv }
        elsif ($a eq '--host-projects' && @argv) { $HOST_PROJECTS = shift @argv }
        elsif ($a eq '--host-json'     && @argv) { $HOST_JSON     = shift @argv }
        elsif ($a eq '--parent-pid'    && @argv) { $PARENT_PID    = shift @argv }
        elsif ($a eq '--interval'      && @argv) { $INTERVAL      = shift @argv }
        elsif ($a eq '--quiet')                  { $QUIET         = 1           }
        else {
            print STDERR "sync-sidecar.pl: unknown arg: $a\n";
            exit 1;
        }
    }
}

# Validate that all required args were provided. Direct checks on the
# lexicals rather than symbolic-ref iteration — `${$name}` would try to
# resolve $main::CONTAINER (a package global) which is never set, so the
# validation always failed even when --container was passed.
for my $check (
    ['--container',     \$CONTAINER],
    ['--host-projects', \$HOST_PROJECTS],
    ['--host-json',     \$HOST_JSON],
    ['--parent-pid',    \$PARENT_PID],
) {
    my ($flag, $ref) = @$check;
    if (!defined $$ref || !length $$ref) {
        print STDERR "sync-sidecar.pl: $flag is required\n";
        exit 1;
    }
}

# Signal handling: clean exit on SIGTERM / SIGINT. END block + flag so we
# don't double-sync if the signal arrives during a sync.
my $STOP = 0;
$SIG{TERM} = sub { $STOP = 1 };
$SIG{INT}  = sub { $STOP = 1 };

sub log_warn {
    return if $QUIET;
    my $msg = shift;
    print STDERR "[sync-sidecar] $msg\n";
}

# Is the container in a state where podman cp would succeed? "running" is
# the obvious yes; "exited", "stopped", "removed" are no — we should bail.
# `podman inspect` exit 0 with State.Status=running ⇒ ok.
sub container_is_running {
    my $status = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null`;
    chomp $status if defined $status;
    return defined($status) && $status eq 'running';
}

# Parent-alive check. On Unix, `kill 0, $pid` is non-destructive and
# returns whether the process exists + we have permission to signal it.
# On Windows-MSYS perl it works the same way (cygwin emulation). If the
# launcher dies abnormally, this is how the sidecar notices.
sub parent_is_alive {
    return kill(0, $PARENT_PID) ? 1 : 0;
}

# Refresh the launcher heartbeat sentinel. The container's keep-alive
# loop kills itself if /tmp/.launcher-alive goes stale (>120s since
# mtime), so doing this on every sync_once means as long as the sidecar
# is alive and can `podman exec`, the container stays alive too.
sub refresh_heartbeat {
    my $rc = system($PODMAN, 'exec', $CONTAINER, 'touch', '/tmp/.launcher-alive');
    log_warn("heartbeat refresh failed (exit @{[$rc >> 8]})") if $rc != 0;
}

# One sync pass. Best-effort: a single failed copy doesn't tear down the
# sidecar — next interval will retry. We do log so the user has breadcrumbs
# if data isn't landing.
sub sync_once {
    refresh_heartbeat();
    if (-d dirname($HOST_PROJECTS)) {
        make_path($HOST_PROJECTS) unless -d $HOST_PROJECTS;
        my $rc = system($PODMAN, 'cp',
            "${CONTAINER}:/root/.claude/projects/.", "$HOST_PROJECTS/");
        log_warn("sessions sync failed (exit @{[$rc >> 8]})") if $rc != 0;
    }
    if (-d dirname($HOST_JSON)) {
        my $rc = system($PODMAN, 'cp',
            "${CONTAINER}:/root/.claude.json", $HOST_JSON);
        # exit 125 typically means "no such file in container" — claude hasn't
        # touched .claude.json yet on a fresh session. Not worth warning.
        log_warn(".claude.json sync failed (exit @{[$rc >> 8]})")
            if $rc != 0 && ($rc >> 8) != 125;
    }
}

# Main loop. Wake every second to be responsive to SIGTERM, but only
# actually sync every $INTERVAL seconds. Bail out promptly on three
# conditions: parent died, container stopped, signal received.
my $tick = 0;
while (!$STOP) {
    if (!parent_is_alive()) {
        log_warn("parent PID $PARENT_PID no longer alive; exiting");
        last;
    }
    if (!container_is_running()) {
        log_warn("container $CONTAINER no longer running; exiting");
        last;
    }
    if ($tick > 0 && $tick % $INTERVAL == 0) {
        sync_once();
    }
    sleep 1;
    $tick++;
}

# Final sync attempt on the way out — captures any writes since the last
# tick. Bounded: if the container is gone, sync_once's podman cp will
# error fast and we exit.
sync_once() if container_is_running();
exit 0;
