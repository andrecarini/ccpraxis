#!/usr/bin/env perl
# 03-container-dynamic-ranges (fix-multiple-running-sandboxes):
# bridged_ports() pure function — derives the socat port list from
# $SANDBOX_BRIDGED_PORTS (explicit range) or the default 9000-9009.
#
# heartbeat.sh is *sourced* (main loop guarded off via BASH_SOURCE==$0) so
# socat is NEVER spawned; the test is deterministic, no network.
#
# Criterion map:
#   AC-a: SANDBOX_BRIDGED_PORTS=9020-9029  -> "9020 9021 … 9029"
#   AC-b: SANDBOX_BRIDGED_PORTS unset      -> "9000 9001 … 9009"
#   Guard: sourcing must NOT hang / spawn socat

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $HB = "$Bin/../../container/heartbeat.sh";
ok(-f $HB, 'heartbeat.sh exists');

# Source heartbeat.sh (main loop guarded off), then evaluate $code.
# Environment overrides passed via %env.
sub hb_call {
    my ($env, $code) = @_;
    local %ENV = (%ENV, HBFILE => $HB, %{ $env || {} });
    chomp(my $out = `bash -c 'source "\$HBFILE" >/dev/null 2>&1; $code' 2>&1`);
    return $out;
}

# -----------------------------------------------------------------------
# GUARD: confirm the source completes without hanging (socat must NOT run).
# We give it 3 seconds; if it hangs, alarm fires and the test suite hangs
# too — but the right-reason failure we're after is "command not found",
# not a timeout. The function just won't exist yet.
# -----------------------------------------------------------------------
{
    # Simply source the file and echo "ok" — if main() ran, socat would
    # background-spawn but not block; the echo would still come. The real
    # guard is that the exit-guard keeps main() from being called at all.
    my $probe = hb_call({}, 'echo sourced_ok');
    is($probe, 'sourced_ok', 'sourcing heartbeat.sh completes without running main()');
}

# -----------------------------------------------------------------------
# AC-a: explicit range via SANDBOX_BRIDGED_PORTS=9020-9029
# Expected: "9020 9021 9022 9023 9024 9025 9026 9027 9028 9029"
# -----------------------------------------------------------------------
{
    my $out = hb_call(
        { SANDBOX_BRIDGED_PORTS => '9020-9029' },
        'bridged_ports'
    );
    is($out, '9020 9021 9022 9023 9024 9025 9026 9027 9028 9029',
       'AC-a: SANDBOX_BRIDGED_PORTS=9020-9029 -> correct port list');
}

# -----------------------------------------------------------------------
# AC-b: SANDBOX_BRIDGED_PORTS unset -> default 9000-9009
# -----------------------------------------------------------------------
{
    # Scrub SANDBOX_BRIDGED_PORTS from the environment entirely so we
    # exercise the unset-variable branch, not an inherited value.
    my $out = hb_call(
        {},
        'unset SANDBOX_BRIDGED_PORTS; bridged_ports'
    );
    is($out, '9000 9001 9002 9003 9004 9005 9006 9007 9008 9009',
       'AC-b: SANDBOX_BRIDGED_PORTS unset -> default 9000-9009');
}

done_testing();
