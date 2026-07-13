package PortAlloc;
# PortAlloc — pure port-block allocation logic (no podman, no filesystem).
# Part of blueprint fix-multiple-running-sandboxes / package 01-port-alloc-module.
#
# Each sandbox occupies one "block" of 20 consecutive ports:
#   ports base..base+9  (SANDBOX_BRIDGED_PORTS, published into the container)
#   ports base+10..base+19 (SANDBOX_OPEN_PORTS, published into the container)
# Blocks start at 9000 by default and step by 20 each time.
# All functions are I/O-free and depend only on core Perl.
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

# ranges_for_base($base, %opts) -> ($bridged_lo, $bridged_hi, $open_lo, $open_hi)
#   Returns the 4-element list describing the two sub-ranges within the block:
#     bridged: base .. base+9
#     open:    base+10 .. base+19
sub ranges_for_base {
    my ($base, %opts) = @_;
    return ($base, $base + 9, $base + 10, $base + 19);
}

# build_port_args($base) -> (\@publish_args, \@env_args)
#   Returns two arrayrefs suitable for splicing into a podman-run command:
#     @publish_args: -p flags for both sub-ranges
#     @env_args:     -e flags for SANDBOX_PORT_BASE, SANDBOX_BRIDGED_PORTS,
#                    SANDBOX_OPEN_PORTS
sub build_port_args {
    my ($base) = @_;

    my $bridged_lo = $base;
    my $bridged_hi = $base + 9;
    my $open_lo    = $base + 10;
    my $open_hi    = $base + 19;

    my @publish_args = (
        '-p', "${bridged_lo}-${bridged_hi}:${bridged_lo}-${bridged_hi}",
        '-p', "${open_lo}-${open_hi}:${open_lo}-${open_hi}",
    );

    my @env_args = (
        '-e', "SANDBOX_PORT_BASE=${base}",
        '-e', "SANDBOX_BRIDGED_PORTS=${bridged_lo}-${bridged_hi}",
        '-e', "SANDBOX_OPEN_PORTS=${open_lo}-${open_hi}",
    );

    return (\@publish_args, \@env_args);
}

1;
