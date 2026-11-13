#!/usr/bin/env perl
# platform: any
# A checkpoint commits the INDEX's view of the write-set paths, modes included.
#
# 2026-11-13, acxpraxis-step-2 package 14: in a repo with core.filemode=false (a
# sandbox bind mount shows every file 777), the only way to set an exec bit is
# `git update-index --chmod=+x`, which changes the index alone. The checkpoint
# committed with `git commit -- <paths>`, which rebuilds those paths from the
# working tree on top of HEAD and so recorded HEAD's 100644: 43 staged exec-bit
# changes were dropped at every checkpoint.
#
#   M1  an index-only mode change inside the write set is committed (100755)
#   M2  a content change and a deletion inside the write set are committed
#   M3  something staged OUTSIDE the write set is not committed, and stays staged
#   M4  the temporary index is removed; the real index is left consistent
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps qw(git_path);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-orchestrator.pl";      # also loads bp-checkpoint.pl
require "$Bin/../../scripts/bp-checkpoint.pl";

my $NATIVE_TMP = do {
    my $t = $ENV{TEMP} // $ENV{TMP};
    ($^O =~ /^(MSWin32|cygwin|msys)$/ && defined $t && length $t && -d $t)
        ? do { (my $p = $t) =~ s{\\}{/}g; $p } : undef;
};
my $ROOT = tempdir(($NATIVE_TMP ? (DIR => $NATIVE_TMP) : ()), CLEANUP => 1);

sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f }
sub git_ok { my ($dir, @a) = @_; system('git', '-C', git_path($dir), @a) == 0 or die "git @a failed" }
sub git_out { my ($dir, @a) = @_; my $cmd = join ' ', map { my $s = $_; $s =~ s/'/'\\''/g; "'$s'" } ('git', '-C', git_path($dir), @a); my $o = `$cmd 2>&1`; return $o }

my $dir = "$ROOT/repo";
make_path("$dir/src", "$dir/other");
git_ok($dir, 'init', '-q', '.');
git_ok($dir, 'config', 'core.filemode', 'false');
spit("$dir/src/run.sh", "#!/bin/sh\necho hi\n");
spit("$dir/src/a.txt", "one\n");
spit("$dir/src/gone.txt", "bye\n");
spit("$dir/other/b.txt", "b1\n");
git_ok($dir, 'add', '-A');
git_ok($dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'fixture');

git_ok($dir, 'update-index', '--chmod=+x', 'src/run.sh');     # index-only, as a sandbox must
spit("$dir/src/a.txt", "two\n");
unlink "$dir/src/gone.txt";
spit("$dir/other/b.txt", "b2\n");
git_ok($dir, 'add', 'other/b.txt');                             # staged, but NOT in the write set

my $r = BpCheckpoint::checkpoint({ root => $dir, pkg => 'p', write_set => 'src/',
    status => 'running', step => 4, now => 1785000000 });
is($r->{status}, 'committed', 'the checkpoint commits') or diag(explain $r);

like(git_out($dir, 'ls-tree', 'HEAD', 'src/run.sh'), qr/^100755 /, 'M1: the index-only exec bit is in the commit');
is(git_out($dir, 'show', 'HEAD:src/a.txt'), "two\n", 'M2: the content change is in the commit');
unlike(git_out($dir, 'ls-tree', '-r', '--name-only', 'HEAD'), qr{^src/gone\.txt$}m, 'M2: the deletion is in the commit');
is(git_out($dir, 'show', 'HEAD:other/b.txt'), "b1\n", 'M3: the out-of-write-set change is not committed');
like(git_out($dir, 'diff', '--cached', '--name-only'), qr{^other/b\.txt$}m, 'M3: and it is still staged');
unlike(git_out($dir, 'diff', '--cached', '--name-only'), qr{^src/}m, 'M4: nothing under src/ is left staged');
my @tmp = glob("$dir/.git/index.bp-checkpoint.*");
is(scalar @tmp, 0, 'M4: the temporary index is gone');

done_testing();
