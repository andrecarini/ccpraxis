#!/usr/bin/env perl
# PortAlloc.pm — pure port-block allocation logic (no podman, no filesystem).
# Pins all acceptance criteria from blueprint fix-multiple-running-sandboxes /
# package 01-port-alloc-module.  Criterion mapping is noted per test.
#
# AC-1  next_free_base: default start=9000, step=20, returns lowest free base
# AC-2  next_free_base: skips occupied bases, finds gaps (not just max+20)
# AC-3  next_free_base: returns undef when entire space is exhausted
# AC-4  bases_from_published: floors host ports to block boundaries
# AC-5  ranges_for_base: returns the block's single published range (open_lo, open_hi)
# AC-6  build_port_args: correct -p publish args (default base 9000 + base 9020)
# AC-7  build_port_args: correct -e env args, and NO SANDBOX_BRIDGED_PORTS
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use List::Util qw(max);

use_ok('PortAlloc') or BAIL_OUT('PortAlloc.pm did not load — module not yet implemented');

# ---- AC-1: next_free_base defaults ----------------------------------------
is(PortAlloc::next_free_base([]),       9000, 'AC-1: empty in-use list -> start=9000');
is(PortAlloc::next_free_base([9000]),   9020, 'AC-1: 9000 occupied -> next=9020');
is(PortAlloc::next_free_base([9000, 9020]), 9040, 'AC-1: 9000+9020 occupied -> next=9040');

# AC-2: gap detection — key oracle: lowest free, NOT max+20
is(PortAlloc::next_free_base([9020]),   9000, 'AC-2: gap at 9000 even though 9020 is occupied');

# AC-3: cap / exhaustion
{
    # Build a fully occupied range from 9000 up to and including the last valid
    # base (base+19 <= 65535  =>  base <= 65516; 65516 is last multiple-of-20
    # offset from 9000: (65516-9000)/20 = 2825.8 -> floor = 2825 -> 9000+56500=65500).
    # Compute last valid base: largest k s.t. 9000 + 20*k + 19 <= 65535
    #   20*k <= 65516  =>  k <= 3275.8  =>  k=3275  =>  base = 9000+65500 = 74500
    # Wait — start is 9000, steps are +20 each time.
    # Valid bases: 9000, 9020, ..., 9000+20*k where 9000+20*k+19 <= 65535
    #   20*k <= 65535-9019 = 56516  =>  k <= 2825.8  =>  k_max=2825
    #   last valid base = 9000 + 20*2825 = 9000 + 56500 = 65500.
    # So we need 2826 entries (k=0..2825).
    my @all_bases = map { 9000 + 20 * $_ } 0 .. 2825;
    is(scalar @all_bases, 2826, 'AC-3 setup: 2826 valid bases from 9000 to 65500');
    is(PortAlloc::next_free_base(\@all_bases), undef,
        'AC-3: all bases occupied -> undef (exhausted)');
}

# ---- AC-4: bases_from_published -------------------------------------------
{
    my @result = PortAlloc::bases_from_published([9005, 9010, 9033]);
    my %got = map { $_ => 1 } @result;
    # 9005 -> floor to block boundary rel to 9000,20 -> 9000
    # 9010 -> 9000 (same block)
    # 9033 -> 9020 (9033-9000=33, floor(33/20)*20=20, +9000=9020)
    ok($got{9000}, 'AC-4: 9005 and 9010 map to base 9000');
    ok($got{9020}, 'AC-4: 9033 maps to base 9020');
    is(scalar keys %got, 2, 'AC-4: exactly 2 distinct bases returned');
}

{
    my @result = PortAlloc::bases_from_published([]);
    is(scalar @result, 0, 'AC-4: empty port list -> empty bases list');
}

# ---- AC-5: ranges_for_base ------------------------------------------------
#
# RE-POINTED 2026-08-29 (bug report 20260825-235021-5e5c). This asserted a
# 4-element (bridged_lo, bridged_hi, open_lo, open_hi) split. The bridged half
# is gone -- socat's wildcard bind on 0.0.0.0:N excluded the loopback bind it
# existed to serve -- so a block is now one published range.
#
# The ARITY is asserted, not just the values: a caller still written against the
# old 4-element shape must be caught here rather than silently receiving undef
# for two of them and publishing garbage.
{
    my @r = PortAlloc::ranges_for_base(9020);
    is(scalar @r, 2, 'AC-5: ranges_for_base returns exactly 2 values -- one range, not a split');
    is($r[0], 9020, 'AC-5: open_lo = base');
    is($r[1], 9039, 'AC-5: open_hi = base+19');
}

# ---- AC-6 + AC-7: build_port_args (base 9020) -----------------------------
{
    my ($pub_ref, $env_ref) = PortAlloc::build_port_args(9020);

    # publish args
    is_deeply(
        $pub_ref,
        ['-p', '9020-9039:9020-9039'],
        'AC-6: build_port_args(9020) publish args exact -- one range covering the whole block'
    );

    # env args — build expected list and compare; also spot-check individual vars
    is_deeply(
        $env_ref,
        ['-e', 'SANDBOX_PORT_BASE=9020',
         '-e', 'SANDBOX_OPEN_PORTS=9020-9039'],
        'AC-7: build_port_args(9020) env args exact'
    );

    # SANDBOX_BRIDGED_PORTS IS NOT SET, AT ANY VALUE -- asserted, not merely
    # absent from the list above. Aliasing it to the open range would keep every
    # "pin your listener to a bridged port" instruction syntactically working
    # while making it mean the opposite; an unset variable fails loudly instead.
    ok(!(grep { /SANDBOX_BRIDGED_PORTS/ } @$env_ref),
        'AC-7: build_port_args sets no SANDBOX_BRIDGED_PORTS -- the bridge is gone, not renamed');
}

# ---- AC-6 + AC-7: build_port_args at the default base (9000) --------------
#
# This anchor's POINT is unchanged and worth restating, because its old name
# ("back-compat") no longer describes it. It exists so the DEFAULT base -- the
# one a first sandbox on a clean machine gets -- is pinned independently of the
# 9020 case above, which could otherwise be satisfied by arithmetic that happens
# to work only away from the start of the range.
#
# What changed is the shape, not the base: one published range instead of two.
{
    my ($pub_ref, $env_ref) = PortAlloc::build_port_args(9000);

    is_deeply(
        $pub_ref,
        ['-p', '9000-9019:9000-9019'],
        'AC-6: build_port_args(9000) publish args at the default base'
    );

    is_deeply(
        $env_ref,
        ['-e', 'SANDBOX_PORT_BASE=9000',
         '-e', 'SANDBOX_OPEN_PORTS=9000-9019'],
        'AC-7: build_port_args(9000) env args at the default base'
    );
}

done_testing();
