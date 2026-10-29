#!/usr/bin/env perl
# platform: any
# Almanac::Store::resolve_project_root honours ALMANAC_PROJECT_ROOT ahead of
# the walk-up, so a project that is a folder of git repos keeps one store
# instead of one per repo.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd ();
use Almanac::Store ();

my $top  = tempdir(CLEANUP => 1);
my $repo = "$top/Some.Repo";
make_path("$repo/.git", "$repo/src", "$top/.ccpraxis-local-data");

sub same { my ($a, $b) = @_; return Almanac::Store::_canonical_path($a) eq Almanac::Store::_canonical_path($b) }

{
    local $ENV{ALMANAC_PROJECT_ROOT};
    delete $ENV{ALMANAC_PROJECT_ROOT};
    ok(same(Almanac::Store::resolve_project_root(cwd => "$repo/src"), $repo),
       'unpinned: the walk stops at the repo\'s .git (the scattering this pin prevents)');
}
{
    local $ENV{ALMANAC_PROJECT_ROOT} = $top;
    ok(same(Almanac::Store::resolve_project_root(cwd => "$repo/src"), $top),
       'pinned: a repo subdirectory resolves to the pinned project root');
    ok(same(Almanac::Store::resolve_project_root(cwd => $top), $top), 'pinned: the root itself too');
}
{
    local $ENV{ALMANAC_PROJECT_ROOT} = "$top/does-not-exist";
    ok(same(Almanac::Store::resolve_project_root(cwd => "$repo/src"), $repo),
       'a pinned path that is not a directory is ignored');
    ok(!-e "$top/does-not-exist", '... and not created');
}
{
    local $ENV{ALMANAC_PROJECT_ROOT} = '';
    ok(same(Almanac::Store::resolve_project_root(cwd => "$repo/src"), $repo), 'an empty pin is ignored');
}

# The walk's starting point folds "/x/..." to the drive form "X:/..." only on
# a Windows-family perl. On macOS/Linux that rewrite turned an absolute cwd
# into a RELATIVE path ("X:/..."), so the walk probed under the process's
# own working directory and could adopt an unrelated directory there.
{
    my $win = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;
    is(Almanac::Store::_fold_drive_form('/q/some/where/'), $win ? 'Q:/some/where' : '/q/some/where',
       'the /x/ -> X:/ drive fold applies on Windows only');
    SKIP: {
        skip 'the drive fold is correct on Windows', 1 if $win;
        my $decoy = tempdir(CLEANUP => 1);
        make_path("$decoy/Q:/proj/.git");
        my $was = Cwd::getcwd();
        chdir $decoy or die "chdir $decoy: $!";
        local $ENV{ALMANAC_PROJECT_ROOT};
        delete $ENV{ALMANAC_PROJECT_ROOT};
        local $ENV{CLAUDE_PROJECT_DIR} = $top;
        my $got = Almanac::Store::resolve_project_root(cwd => '/q/proj');
        chdir $was or die "chdir back to $was: $!";
        ok(same($got, $top), 'a /q/... cwd is never walked as a path relative to the process cwd')
            or diag("got $got");
    }
}

done_testing();
