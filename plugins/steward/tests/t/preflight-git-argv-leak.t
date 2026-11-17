#!/usr/bin/env perl
# platform: host
# A GENERIC CHILD SPAWN SHOULD NOT LEAK GIT'S OWN MSYS OPT-OUT INTO IT.
#
# Bug report 20260922-211319-19b1: /steward:backup's U4 preflight unit spawns
# `perl gen-readme-tree.pl --check` as its live install's grandchild, and that
# script's OWN `git -C $REPO_ROOT ...` call (an ordinary POSIX-style path,
# relying on MSYS's implicit argv translation to reach a native git.exe) came
# back with "fatal: cannot change to '...': No such file or directory" even
# though the directory unquestionably existed.
#
# Root cause, verified against Backup::Phase::Preflight (scripts/backup/
# Preflight.pm): its generic child-spawning helper set
# $ENV{MSYS2_ARG_CONV_EXCL} = '*' for EVERY spawn, not only the ones handing a
# hand-translated Windows-style path straight to a native binary (its own git
# wrapper, paired with _native_path per CLAUDE.md's MSYS2 landmine writeup).
# Since an env var set before a fork/exec is inherited by the whole
# descendant tree, that opt-out reached the grandchild `git -C` spawn INSIDE
# gen-readme-tree.pl too -- disabling the very translation that call depends
# on and producing exactly this failure. This is the "opposite symptom"
# CLAUDE.md already documents for the podman case, one process generation
# further down than that writeup anticipated.
#
# The fix scopes the opt-out to the one call site that pairs it with
# hand-translation (_git_capture) and removes it from the shared spawner
# (_run_capture), so a perl-script grandchild's own unqualified git call sees
# ordinary MSYS translation again.

use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;

my $PREFLIGHT = "$Bin/../../../../scripts/backup/Preflight.pm";
ok(-f $PREFLIGHT, 'scripts/backup/Preflight.pm is present') or BAIL_OUT('no Preflight.pm');

plan skip_all => 'windows-only reproduction (MSYS argv translation)' unless $^O =~ /^(MSWin32|cygwin|msys)$/;

my $ok = eval { require $PREFLIGHT; 1 };
ok($ok, 'Preflight.pm loads cleanly') or diag($@);
BAIL_OUT('Preflight.pm did not load') unless $ok;

# ---------------------------------------------------------------------------
# A real git repo in a tempdir, addressed the way FindBin/abs_path would hand
# it to gen-readme-tree.pl: a POSIX-style path (Git-for-Windows perl's own
# form), never hand-translated to "C:/..." by the test -- that lack of
# translation is exactly what the real script under test also does, and is
# the condition the bug needs to reproduce.
# ---------------------------------------------------------------------------
## A real drive-rooted temp dir, not File::Temp's default (MSYS's own
## virtual /tmp, a bind mount whose real target is NOT under the drive path
## _native_path()/git.exe expect -- using it would make the git-wrapper
## sanity check below fail for a reason unrelated to the bug this test
## targets). $ENV{TEMP}/$ENV{TMP} are inherited from Windows and are always
## real "C:\..." paths.
my $tmp_root = $ENV{TEMP} // $ENV{TMP} // '.';
my $repo = tempdir(DIR => $tmp_root, CLEANUP => 1);
(my $posix_repo = $repo) =~ s{\\}{/}g;
$posix_repo =~ s{^([A-Za-z]):/}{/\l$1/};

sub _git { system('git', @_) == 0 or die "git @_ failed: $?" }
{
    local $ENV{HOME}        = $repo;
    local $ENV{USERPROFILE} = $repo;
    local $ENV{GIT_CONFIG_GLOBAL} = "$repo/.gitconfig";
    _git('-C', $posix_repo, 'init', '-q');
    _git('-C', $posix_repo, 'config', 'user.email', 'test@example.invalid');
    _git('-C', $posix_repo, 'config', 'user.name', 'Test');
}

# A stub child script that does what gen-readme-tree.pl does: an UNQUALIFIED
# `git -C <posix path> ...` call, trusting ambient MSYS translation -- no
# MSYS2_ARG_CONV_EXCL handling of its own, no hand-translation. The repo path
# is baked into the script text (not passed as argv) so this test isolates
# the ENV-INHERITANCE leak specifically, not argv translation of the outer
# spawn's own arguments.
my $stub_dir = tempdir(CLEANUP => 1);
(my $posix_stub_dir = $stub_dir) =~ s{\\}{/}g;
my $stub = "$stub_dir/inner-git-check.pl";
open my $fh, '>', $stub or die "cannot write stub: $!";
print {$fh} <<"PERL";
use strict; use warnings;
my \$root = "$posix_repo";
my \@cmd = ('git', '-C', \$root, 'rev-parse', '--show-toplevel');
open(my \$fh, '-|', \@cmd) or exit 2;
my \$out = do { local \$/; <\$fh> };
close \$fh;
my \$exit = \$? >> 8;
print STDOUT (\$out // '');
exit \$exit;
PERL
close $fh;

# ---------------------------------------------------------------------------
# Exercise the ACTUAL shared spawner Preflight.pm uses for a perl-script
# grandchild (U4/U5/U6/... all go through this, not through _git_capture).
# Before the fix this failed because _run_capture itself disabled MSYS
# translation for the duration of the spawn, and the stub's inner git call
# inherited that; after the fix _run_capture no longer touches the env var.
# ---------------------------------------------------------------------------
my $r = Backup::Phase::Preflight::_run_capture($^X, $stub);
ok($r->{spawned}, 'the stub child spawned at all');
is($r->{exit}, 0,
   'the grandchild\'s OWN unqualified git -C call succeeds through the shared spawner')
    or diag("stdout: [$r->{out}]\nstderr: [$r->{err}]");
unlike($r->{err}, qr/fatal: cannot change to/,
       'no "fatal: cannot change to" -- the exact symptom from the bug report');
my ($repo_leaf) = ($posix_repo =~ m{([^/]+)/?$});
like($r->{out}, qr/\Q$repo_leaf\E/i,
     'the grandchild git call actually resolved the repo (not a false pass from git being entirely absent)');

# ---------------------------------------------------------------------------
# The module's OWN git wrapper must still work -- the fix must not have
# thrown out the opt-out+hand-translation pairing that _git_capture needs
# for ITS direct native-binary spawn.
# ---------------------------------------------------------------------------
my $direct = Backup::Phase::Preflight::_git_capture($posix_repo, 'rev-parse', '--show-toplevel');
is($direct->{exit}, 0, '_git_capture (the module\'s own git spawn) still succeeds after the fix')
    or diag("stdout: [$direct->{out}]\nstderr: [$direct->{err}]");

done_testing();
