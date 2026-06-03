#!/usr/bin/env perl
# Holds MountSpec::v_to_mount accountable for the bind/volume distinction.
#
# REGRESSION: the launcher used to hardcode `type=bind` for every mount,
# which turned `myvol:/path` into `--mount type=bind,source=myvol,...`.
# Podman then tried to statfs `myvol` as a host path inside the machine
# VM and failed with "no such file or directory". Caught by the user
# running claude-sandbox; not caught by the suite at the time because
# the launcher's converter wasn't testable. Module extraction fixed that.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use MountSpec qw(v_to_mount convert_v_to_mount);

plan tests => 9;

# Bind: source looks like a POSIX absolute path.
like(v_to_mount('/host/path:/container/path'),
     qr/^type=bind,source=/,
     'POSIX absolute path -> bind');

# Bind: source is a Windows drive-letter path.
like(v_to_mount('C:/Users/foo:/container/path'),
     qr/^type=bind,source=C:\/Users\/foo,target=/,
     'Windows drive-letter path -> bind');

# Bind: source is relative-style (./foo).
like(v_to_mount('./relative:/container/path'),
     qr/^type=bind,source=/,
     'relative-style path -> bind');

# THE CRITICAL ONE: bare identifier (no slash, no drive) is a NAMED VOLUME.
# This was the regression — used to incorrectly emit type=bind here.
like(v_to_mount('my-named-volume:/container/path'),
     qr/^type=volume,source=my-named-volume,target=\/container\/path$/,
     'bare identifier -> volume (was the regressing case)');

# Volume name with the same shape as the user's failure case.
like(v_to_mount('claude-klink-ffd440b8-sessions:/root/.claude/projects'),
     qr/^type=volume,source=claude-klink-ffd440b8-sessions,target=/,
     'concrete project volume name -> volume');

# `ro` opts get translated to readonly on the mount.
like(v_to_mount('/host:/container:ro'),
     qr/,readonly$/,
     ':ro suffix -> readonly mount flag');

# convert_v_to_mount walks an argv list, rewriting only `-v` pairs.
my @before = ('podman', 'run', '-v', 'volname:/tgt', '--rm', 'image');
my @after  = convert_v_to_mount(@before);
is(scalar(@after), 6, 'argv length preserved (-v pair becomes --mount pair)');
is($after[2], '--mount', 'third arg becomes --mount');
like($after[3], qr/^type=volume,source=volname,target=\/tgt$/,
     'fourth arg is the rewritten spec for the volume');
