#!/usr/bin/env perl
# platform: any
# Bug 20261113-155619-da9f: the checkpoint commit runs the project's own
# pre-commit hook, and a 30 s cap shared with every other git call killed it.
# acxpraxis's hook (lefthook -> make check-fast) takes 44-50 s, so for 8+ hours
# on 2026-11-13 no checkpoint of package 14-fold-results could commit, and its
# finished work could not land.
#
#   T1  commit_timeout(): default 180; BP_CHECKPOINT_COMMIT_TIMEOUT overrides;
#       clamped to 1..1800; junk falls back to the default
#   T2  a commit whose hook outlasts $GIT_TIMEOUT but not the commit cap lands
#   T3  a hook that outlasts the commit cap still times out (it is a cap)
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps qw(git_path);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Config ();

require "$Bin/../../scripts/bp-orchestrator.pl";      # also loads bp-checkpoint.pl
require "$Bin/../../scripts/bp-checkpoint.pl";

my $PERL = $Config::Config{perlpath};
my $NATIVE_TMP = do {
    my $t = $ENV{TEMP} // $ENV{TMP};
    ($^O =~ /^(MSWin32|cygwin|msys)$/ && defined $t && length $t && -d $t)
        ? do { (my $p = $t) =~ s{\\}{/}g; $p } : undef;
};
my $ROOT = tempdir(($NATIVE_TMP ? (DIR => $NATIVE_TMP) : ()), CLEANUP => 1);

sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f }
sub git_ok { my ($dir, @a) = @_; system('git', '-C', git_path($dir), @a) == 0 or die "git @a failed" }

my $n = 0;
sub repo_with_hook {
    my ($sleep) = @_;
    my $dir = "$ROOT/repo" . (++$n);
    make_path("$dir/src");
    git_ok($dir, 'init', '-q', '.');
    spit("$dir/src/a.txt", "one\n");
    git_ok($dir, 'add', '-A');
    git_ok($dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'fixture');
    spit("$dir/src/a.txt", "two\n");
    make_path("$dir/.git/hooks");
    spit("$dir/.git/hooks/pre-commit", "#!$PERL\nsleep $sleep;\nexit 0;\n");
    chmod 0755, "$dir/.git/hooks/pre-commit";
    return $dir;
}
sub ck { my ($dir) = @_; return BpCheckpoint::checkpoint({ root => $dir, pkg => 'p', write_set => 'src/',
    status => 'running', step => 1, now => 1785000000 }) }

no warnings 'once';

# T1
{
    local $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT};
    delete $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT};
    is(BpCheckpoint::commit_timeout(), 180, 'T1: default commit cap is 180 s');
    $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT} = 90;   is(BpCheckpoint::commit_timeout(), 90,   'T1: the env var overrides it');
    $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT} = 0;    is(BpCheckpoint::commit_timeout(), 1,    'T1: clamped at 1');
    $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT} = 9999; is(BpCheckpoint::commit_timeout(), 1800, 'T1: clamped at 1800');
    $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT} = '5m'; is(BpCheckpoint::commit_timeout(), 180,  'T1: junk -> default');
}

# T2: hook 4 s, plain-git cap 2 s, commit cap 30 s -> commits.
{
    local $BpCheckpoint::GIT_TIMEOUT = 2;
    local $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT} = 30;
    my $dir = repo_with_hook(4);
    my $r = ck($dir);
    is($r->{status}, "committed", 'T2: a hook slower than the plain-git cap no longer kills the commit')
        or diag(explain $r);
    ok(!-e "$dir/.git/index.lock", 'T2: no lock left behind');
}

# T3: hook 6 s, commit cap 2 s -> still times out.
{
    local $BpCheckpoint::GIT_TIMEOUT = 2;
    local $ENV{BP_CHECKPOINT_COMMIT_TIMEOUT} = 2;
    my $dir = repo_with_hook(6);
    my $r = ck($dir);
    is($r->{reason}, 'git-timeout', 'T3: a hook past the commit cap still times out');
}

done_testing();
