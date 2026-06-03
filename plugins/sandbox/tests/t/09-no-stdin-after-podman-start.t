#!/usr/bin/env perl
# Regression: any interactive prompt (STDIN read) in launcher.pl must
# happen BEFORE the container is started, OR be inside a sub that's only
# called during pre-start setup. The container's keep-alive bash CMD
# exits ~15s after the last `claude` process is gone — a user prompt
# AFTER `podman start` would let user-think-time burn through that
# window, leaving the subsequent `podman exec` to fail with
# "container state improper". Caught in production by the backpack
# approval prompt; this test prevents the same shape of mistake on any
# future prompt.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

plan tests => 3;

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'launcher.pl present') or BAIL_OUT('launcher missing');

open my $fh, '<', $launcher or BAIL_OUT("open: $!");
my @lines = <$fh>;
close $fh;

# Locate the `podman start` invocation that begins the container's
# keep-alive window. There should be exactly one such line in the main
# flow; comments mentioning it don't count.
my $start_line;
for my $i (0 .. $#lines) {
    if ($lines[$i] =~ /^[^#]*system\s*\(\s*\$PODMAN\s*,\s*['"]start['"]/) {
        $start_line = $i + 1;  # human-readable 1-based
        last;
    }
}
ok($start_line, "found `podman start` call (line $start_line)")
    or BAIL_OUT('could not locate podman start in launcher.pl');

# Now scan for `<STDIN>` reads and ensure none appear AFTER the start
# line. Reads inside sub definitions invoked only pre-start are OK and
# already exist (prompt_stale_action's fallback). Anything below the
# start line is a regression risk.
my @bad;
for my $i ($start_line .. $#lines) {
    next unless $lines[$i] =~ /<STDIN>/;
    # 1-indexed for the report.
    push @bad, { line => $i + 1, text => $lines[$i] };
}
is(scalar(@bad), 0,
   "no <STDIN> reads after `podman start` (line $start_line)")
    or do {
        for my $b (@bad) {
            diag("  line $b->{line}: $b->{text}");
        }
        diag("Any user prompt after `podman start` lets user-think-time burn through the container's 15s keep-alive window.");
    };
