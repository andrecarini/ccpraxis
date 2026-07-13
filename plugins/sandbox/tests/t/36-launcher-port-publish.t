#!/usr/bin/env perl
# Immutable oracle for blueprint 02-launcher-port-alloc.
# Source-text assertions only — do NOT require/load launcher.pl (side effects).
# Mirrors the slurp+regex convention of t/02-launcher-bind-mount-shape.t.
#
# Criterion map:
#   A => hardcoded port-range literals are gone
#   B => PortAlloc::build_port_args is used and wired into podman args
#   C => MSYS2 guard is intact
#   D => EADDRINUSE retry path exists and re-feeds PortAlloc::next_free_base
#   E => port-base persisted via _write_file and read via _read_file

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

plan tests => 11;

my $launcher = "$Bin/../../scripts/launcher.pl";
ok(-f $launcher, 'launcher.pl present') or BAIL_OUT('cannot find launcher.pl');

open my $fh, '<', $launcher or BAIL_OUT("open: $!");
my $src = do { local $/; <$fh> };
close $fh;

# ---------------------------------------------------------------------------
# A — hardcoded port-range literals must be gone (FAILS now: present at
#     lines 1899/1904 in the unfixed launcher)
# ---------------------------------------------------------------------------
unlike($src, qr/9000-9009:9000-9009/,
       'A: no hardcoded 9000-9009:9000-9009 publish literal');

unlike($src, qr/9010-9019:9010-9019/,
       'A: no hardcoded 9010-9019:9010-9019 publish literal');

# ---------------------------------------------------------------------------
# B — PortAlloc module is loaded and build_port_args feeds the podman args
#     (FAILS now: neither present in unfixed launcher)
# ---------------------------------------------------------------------------
like($src, qr/use\s+PortAlloc/,
     'B: "use PortAlloc" present (module is loaded)');

like($src, qr/PortAlloc::build_port_args/,
     'B: PortAlloc::build_port_args is called');

# build_port_args result is pushed into podman args.
# Tolerant: accepts any reasonable variable name for the returned pub args
# (e.g. $pub_args, @pub, @port_pub, @pub_args, @pargs ...).
# Requires that a push onto @podman_args (or the env array that feeds it)
# appears in proximity to build_port_args.
like($src,
     qr/PortAlloc::build_port_args.*?push\s+[@\$]*(?:podman_args|EXTRA_ENV|pub|port_args|pargs)/ms,
     'B: build_port_args result is pushed into podman/env arg list');

# ---------------------------------------------------------------------------
# C — MSYS2 colon-guard must not be regressed (passes now; regression pin)
# ---------------------------------------------------------------------------
like($src, qr/\$ENV\{MSYS2_ARG_CONV_EXCL\}\s*=\s*['"]\*['"]/,
     'C: MSYS2_ARG_CONV_EXCL guard is still present');

# ---------------------------------------------------------------------------
# D — EADDRINUSE retry branch: a retry must exist AND must re-feed a base
#     through PortAlloc::next_free_base (FAILS now: no such branch)
# ---------------------------------------------------------------------------
like($src, qr/EADDRINUSE|address.already.in.use|in.use/i,
     'D: address-in-use / EADDRINUSE condition is present');

like($src, qr/PortAlloc::next_free_base/,
     'D: PortAlloc::next_free_base called for retry');

# ---------------------------------------------------------------------------
# E — port-base persistence: _write_file for create, _read_file for attach
#     (FAILS now: neither reference exists in unfixed launcher)
# ---------------------------------------------------------------------------
like($src, qr/_write_file\s*\(.*port-base/,
     'E: _write_file persists port-base on create');

like($src, qr/_read_file\s*\(.*port-base/,
     'E: _read_file reads port-base on attach');
