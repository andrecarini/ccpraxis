package PortAlloc;
# PortAlloc — pure port-block allocation logic (no podman, no filesystem).
# Part of blueprint fix-multiple-running-sandboxes / package 01-port-alloc-module.
#
# Each sandbox occupies one "block" of 20 consecutive ports:
#   ports base..base+19 (SANDBOX_OPEN_PORTS, published into the container)
# Blocks start at 9000 by default and step by 20 each time.
# All functions are I/O-free and depend only on core Perl.
#
# ONE RANGE, NOT TWO (2026-08-29, bug report 20260825-235021-5e5c).
#
# The block used to be split in half: base..base+9 was "bridged", published AND
# held open inside the container by a socat forwarder on 0.0.0.0:N, so that an
# OAuth callback listener on 127.0.0.1:N would be reachable from the host.
#
# That could never work, and was measured not to. A wildcard bind on 0.0.0.0:N
# EXCLUDES any later bind on 127.0.0.1:N, and SO_REUSEADDR does not change it --
# tested with and without. So the forwarder made the port unbindable by the very
# listener it existed to serve: with socat running Claude Code could not bind,
# and with socat killed the listener bound but the host browser could not reach
# it. Both states failed. The feature cost ten otherwise-usable ports per
# sandbox and made any wildcard-binding dev server in that half fail with
# EADDRINUSE.
#
# It was also unnecessary. Claude Code's MCP auth wizard prints the authorization
# URL and accepts the pasted callback URL, so OAuth completes with no published
# port, no socat and no --callback-port at all.
#
# THE BLOCK SIZE AND BASE MATH ARE DELIBERATELY UNCHANGED. next_free_base and
# bases_from_published still step by 20 from 9000, so every already-allocated
# sandbox keeps the base it has. Only the split within a block is gone.
use strict;
use warnings;

# next_free_base(\@in_use_bases, %opts) -> $base | undef
#   Return the lowest block base >= start (default 9000) that is NOT in
#   @in_use_bases.  Blocks step by `block` (default 20).  Only valid bases
#   where base+19 <= 65535 are considered.  Returns undef if the entire
#   range is occupied (exhaustion).
sub next_free_base {
    my ($in_use_ref, %opts) = @_;
    my $start = defined $opts{start} ? $opts{start} : 9000;
    my $block = defined $opts{block} ? $opts{block} : 20;

    my %occupied = map { $_ => 1 } @{$in_use_ref};

    my $base = $start;
    while ($base + 19 <= 65535) {
        return $base unless $occupied{$base};
        $base += $block;
    }
    return undef;
}

# bases_from_published(\@host_ports, %opts) -> @distinct_bases
#   Floor each host port to its block base using:
#     base = start + block * int(($port - start) / $block)
#   Returns a deduplicated list of occupied bases.
sub bases_from_published {
    my ($ports_ref, %opts) = @_;
    my $start = defined $opts{start} ? $opts{start} : 9000;
    my $block = defined $opts{block} ? $opts{block} : 20;

    my %seen;
    for my $port (@{$ports_ref}) {
        my $base = $start + $block * int(($port - $start) / $block);
        $seen{$base} = 1;
    }
    return sort { $a <=> $b } keys %seen;
}

# ranges_for_base($base, %opts) -> ($open_lo, $open_hi)
#   The block's single published range: base .. base+19.
#
#   Returned a 4-element (bridged_lo, bridged_hi, open_lo, open_hi) list until
#   2026-08-29. The arity change is deliberate rather than padded with two undefs
#   or two zeros: a caller written against the old shape must FAIL to compile or
#   fail its test, not silently receive a placeholder it then publishes.
sub ranges_for_base {
    my ($base, %opts) = @_;
    return ($base, $base + 19);
}

# build_port_args($base) -> (\@publish_args, \@env_args)
#   Returns two arrayrefs suitable for splicing into a podman-run command:
#     @publish_args: one -p flag for the whole block
#     @env_args:     -e flags for SANDBOX_PORT_BASE and SANDBOX_OPEN_PORTS
#
#   SANDBOX_BRIDGED_PORTS IS NO LONGER SET, and deliberately not kept as an
#   alias of the open range. Every use of it documented in container/CLAUDE.md
#   told the reader to put a listener on a bridged port precisely BECAUSE
#   something was forwarding it; aliasing the name to a range that forwards
#   nothing would keep that advice syntactically working while making it mean
#   the opposite. An unset variable makes a stale script fail loudly instead.
sub build_port_args {
    my ($base) = @_;

    my ($open_lo, $open_hi) = ranges_for_base($base);

    my @publish_args = (
        '-p', "${open_lo}-${open_hi}:${open_lo}-${open_hi}",
    );

    my @env_args = (
        '-e', "SANDBOX_PORT_BASE=${base}",
        '-e', "SANDBOX_OPEN_PORTS=${open_lo}-${open_hi}",
    );

    return (\@publish_args, \@env_args);
}

1;
