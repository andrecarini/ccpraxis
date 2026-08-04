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

# done_testing() rather than a hand-counted plan: the SKIP below changes the
# assertion count by platform, and a hand-counted plan turns that into a plan
# mismatch — which fails with ZERO `not ok` lines and is therefore invisible to
# the `grep -c '^not ok'` half of this repo's pass criterion.

# winify_path — drive letter case is preserved (lowercase in, lowercase
# out); podman.exe is case-insensitive about it so we don't bother
# normalizing.
#
# THESE TWO ARE WINDOWS-ONLY, and ran unconditionally until s22. MountSpec's
# winify_path opens with `return $p unless $WINDOWS_FAMILY`, so off the Windows
# family it is a documented no-op and these assertions asserted something the
# code never claimed. The resulting 2 not-ok were normalised into the sandbox
# suite's "known baseline red" for an entire 79-package blueprint — which is the
# real cost: it trained everyone to ignore the one file guarding the MSYS2 `;C`
# path-mangling landmine.
SKIP: {
    skip('winify_path is a documented no-op off the Windows family '
         . "(\$MountSpec::WINDOWS_FAMILY is false on $^O)", 2)
        unless $MountSpec::WINDOWS_FAMILY;

    is(winify_path('/c/Users/foo'), 'c:/Users/foo', 'winify: /c/... -> c:/...');
    is(winify_path('/d/data'),      'd:/data',      'winify: /d/... -> d:/...');
}

# The POSIX counterpart. A bare SKIP would leave this platform asserting nothing
# about winify_path's main path, so the no-op is asserted rather than assumed --
# skipping is not the same as "no behaviour to check", and a skip that hides a
# regression is how the original red survived so long.
unless ($MountSpec::WINDOWS_FAMILY) {
    is(winify_path('/c/Users/foo'), '/c/Users/foo',
       'winify (POSIX): a /c/... path is returned UNCHANGED — no accidental drive-letter rewrite');
    is(winify_path('/d/data'), '/d/data',
       'winify (POSIX): a /d/... path is returned UNCHANGED');
}
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

done_testing();
