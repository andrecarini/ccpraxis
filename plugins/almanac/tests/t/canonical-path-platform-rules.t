#!/usr/bin/env perl
# platform: any
# Platform rules of the two path canonicalisers, pinned by overriding $^O
# (both read it at call time) and using a path whose parent cannot exist, so
# Cwd::abs_path answers undef and the textual fallback runs:
#
#   - the "/x/..." -> "X:/..." drive rewrite is Windows-only: on any other OS a
#     missing /q/... path stays /q/... (it used to become Q:/..., a relative path)
#   - almanac-bug.pl::canonical_root, a dedupe key, folds case on Windows and
#     macOS (both case-insensitive, abs_path keeps typed case) and nowhere else
#   - Almanac::Store::_canonical_path keeps case everywhere (it yields a path
#     that is opened and printed)
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $S = "$Bin/../../scripts";
use lib "$FindBin::Bin/../../scripts";
require "$S/almanac-bug.pl";
require Almanac::Store;

my $missing = '/q/No-Such-9f3/Deeper';
ok(!defined Cwd::abs_path($missing), 'fixture: the path does not resolve, so the fallback runs');

{
    local $^O = 'linux';
    is(AlmanacBug::canonical_root($missing), $missing, 'linux: canonical_root keeps /q/... and case');
    is(Almanac::Store::_canonical_path($missing), $missing, 'linux: _canonical_path keeps /q/... and case');
}
{
    local $^O = 'darwin';
    is(AlmanacBug::canonical_root($missing), lc($missing), 'darwin: canonical_root folds case, no drive rewrite');
    is(Almanac::Store::_canonical_path($missing), $missing, 'darwin: _canonical_path keeps case, no drive rewrite');
    is(AlmanacBug::canonical_root('/q/No-Such-9f3/Deeper/'), lc($missing), 'darwin: trailing slash dropped');
}
for my $os (qw(MSWin32 msys cygwin)) {
    local $^O = $os;
    is(AlmanacBug::canonical_root('/q/No-Such-9f3/Deeper'), 'q:/no-such-9f3/deeper', "$os: canonical_root rewrites /q/ to a drive and folds case");
    is(Almanac::Store::_canonical_path('/q/No-Such-9f3/Deeper'), 'Q:/No-Such-9f3/Deeper', "$os: _canonical_path rewrites the drive but keeps case");
}

done_testing;
