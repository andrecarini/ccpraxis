#!/usr/bin/env perl
# platform: any
# usage-audit.pl's $HOME walk must not open the folders macOS guards with TCC.
#
# WHY. Root discovery walks $HOME three levels deep looking for sandbox homes.
# On a Mac, listing ~/Documents, ~/Desktop, ~/Downloads, the media libraries,
# ~/.Trash or parts of ~/Library from a terminal-spawned perl raises a GUI
# "would like to access" prompt (or fails outright when nobody is there to
# answer). Those are skipped at the top of $HOME on darwin; everything else,
# and every other platform, is walked as before.
#
# HERMETIC: HOME is a tempdir with fake project trees; --list-roots only.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd ();

my $SCRIPT = "$Bin/../../scripts/usage-audit.pl";
ok(-f $SCRIPT, 'usage-audit.pl exists') or BAIL_OUT('script missing');

my $home = Cwd::abs_path(tempdir(CLEANUP => 1));
my $tail = '.ccpraxis-local-data/claude-home/projects';
make_path("$home/Projects/alpha/$tail", "$home/Documents/beta/$tail", "$home/Work/Library/gamma/$tail");

local $ENV{HOME} = $home;
local $ENV{USERPROFILE} = $home;
my @roots = map { chomp; $_ } `"$^X" "$SCRIPT" --list-roots 2>&1`;
my %have = map { $_ => 1 } @roots;

ok($have{"$home/Projects/alpha/$tail"}, 'an ordinary project under $HOME is found') or diag(join "\n", @roots);
ok($have{"$home/Work/Library/gamma/$tail"}, 'a folder named Library BELOW the top of $HOME is still walked');
if ($^O eq 'darwin') {
    ok(!$have{"$home/Documents/beta/$tail"}, 'darwin: ~/Documents is never listed (TCC)');
} else {
    ok($have{"$home/Documents/beta/$tail"}, 'non-darwin: Documents is walked like any folder (unchanged)');
}

done_testing();
