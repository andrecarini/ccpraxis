#!/usr/bin/env perl
# MountSpec corner cases — paths with spaces, mixed separators, edge
# detection between "looks like a path" and "looks like a volume name".
# These don't usually break in practice but are worth pinning.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use MountSpec qw(winify_path v_to_mount convert_v_to_mount);

plan tests => 11;

# winify_path — drive letter case is preserved (lowercase in, lowercase
# out); podman.exe is case-insensitive about it so we don't bother
# normalizing.
is(winify_path('/c/Users/foo'), 'c:/Users/foo', 'winify: /c/... -> c:/...');
is(winify_path('/d/data'),      'd:/data',      'winify: /d/... -> d:/...');
is(winify_path('C:/already'),   'C:/already',   'winify: already winified -> no-op');
is(winify_path(''),             '',             'winify: empty -> empty');

# v_to_mount: standard bind paths
like(v_to_mount('/host/path:/container/path'),
     qr/^type=bind,/, 'POSIX absolute path is bind');
like(v_to_mount('./relative:/container'),
     qr/^type=bind,/, 'relative ./path is bind');
like(v_to_mount('C:/Windows/Path:/container'),
     qr/^type=bind,source=C:\/Windows\/Path/, 'Windows path is bind, winified');

# v_to_mount: volume names
like(v_to_mount('myvol:/container'),
     qr/^type=volume,source=myvol/, 'bare name is volume');
like(v_to_mount('claude-klink-ffd440b8-data:/root/.claude'),
     qr/^type=volume,source=claude-klink-ffd440b8-data,target=\/root\/\.claude$/,
     'hyphenated volume name is volume');

# v_to_mount: paths with spaces in the host component
# The Windows-path regex `[A-Za-z]:[^:]+` is greedy and matches spaces,
# so `C:/Users/André/Personal Files/x:/project` must parse correctly.
like(v_to_mount('C:/Users/André/Personal Files/x:/project'),
     qr/^type=bind,source=C:\/Users\/Andr[^,]*\/Personal Files\/x,target=\/project$/,
     'Windows path with space parses correctly');

# convert_v_to_mount: -v args translated, others passed through
my @before = ('podman', 'run', '--rm', '-v', 'vol1:/a',
              '-e', 'FOO=bar', '-v', '/host:/b:ro', 'image', 'cmd');
my @after = convert_v_to_mount(@before);
is_deeply(\@after,
    ['podman', 'run', '--rm',
     '--mount', 'type=volume,source=vol1,target=/a',
     '-e', 'FOO=bar',
     '--mount', 'type=bind,source=/host,target=/b,readonly',
     'image', 'cmd'],
    'convert_v_to_mount preserves order, translates only -v pairs, honors :ro');
