#!/usr/bin/env perl
# Structural: the launcher MUST touch /tmp/.launcher-alive immediately
# after `podman start`, before any other `podman exec` calls. Without
# this initial touch the container only has its 5s boot grace, after
# which the sidecar's first sync (at ~60s) is too late and the container
# would already be exiting.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

plan tests => 3;

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'launcher.pl present') or BAIL_OUT;

open my $fh, '<', $launcher or BAIL_OUT("open: $!");
my @lines = <$fh>;
close $fh;

# Find the `podman start` invocation line.
my $start_line;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /^[^#]*system\s*\(\s*\$PODMAN\s*,\s*['"]start['"]/) {
        $start_line = $i + 1;
        last;
    }
}
ok($start_line, "found podman start at line $start_line") or BAIL_OUT;

# Find the first `podman exec` call after that. It must be a `touch
# /tmp/.launcher-alive` — landing the heartbeat sentinel — not something
# else (e.g. an apt-get) that would leave the sentinel un-touched and let
# the container drift toward death.
my $touched = 0;
for my $i ($start_line .. $#lines) {
    next unless $lines[$i] =~ /^[^#]*system\s*\(\s*\$PODMAN\s*,\s*['"]exec['"]/;
    # First post-start exec found. Check that it touches the sentinel.
    if ($lines[$i] =~ /touch.*?\.launcher-alive/
        || ($i + 1 <= $#lines && $lines[$i + 1] =~ /touch.*?\.launcher-alive/)
        || ($i + 2 <= $#lines && $lines[$i + 2] =~ /touch.*?\.launcher-alive/)) {
        $touched = 1;
    }
    last;
}
ok($touched,
   'first `podman exec` after `podman start` touches /tmp/.launcher-alive');
