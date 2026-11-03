#!/usr/bin/env perl
# platform: any
# A checkpoint git killed on its deadline must not leave index.lock behind.
#
# Measured 2026-11-02 (acxpraxis-step-2): one `git commit` ran past the 30 s
# deadline, _git SIGKILLed it, and the lock it held stayed. Every later
# checkpoint of every package then failed "Unable to create '.git/index.lock':
# File exists" for twelve hours, until a human deleted it.
#
# A pre-commit hook that sleeps holds a REAL git mid-commit with the lock taken
# (git creates index.lock before running the hook), which works on every
# platform this suite runs on, unlike PATH-shadowing git with a script.
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

my $PERL = $Config::Config{perlpath};                  # absolute: a hook shebang needs it
my $NATIVE_TMP = do {
    my $t = $ENV{TEMP} // $ENV{TMP};
    ($^O =~ /^(MSWin32|cygwin|msys)$/ && defined $t && length $t && -d $t)
        ? do { (my $p = $t) =~ s{\\}{/}g; $p } : undef;
};
my $ROOT = tempdir(($NATIVE_TMP ? (DIR => $NATIVE_TMP) : ()), CLEANUP => 1);

sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f }
sub git_ok { my ($dir, @a) = @_; system('git', '-C', git_path($dir), @a) == 0 or die "git @a failed" }

my $n = 0;
sub hung_repo {
    my $dir = "$ROOT/repo" . (++$n);
    make_path("$dir/src");
    git_ok($dir, 'init', '-q', '.');
    spit("$dir/src/a.txt", "one\n");
    git_ok($dir, 'add', '-A');
    git_ok($dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'fixture');
    spit("$dir/src/a.txt", "two\n");
    make_path("$dir/.git/hooks");
    spit("$dir/.git/hooks/pre-commit", "#!$PERL\nsleep 20;\nexit 0;\n");
    chmod 0755, "$dir/.git/hooks/pre-commit";
    return $dir;
}

no warnings 'once';
local $BpCheckpoint::GIT_TIMEOUT = 3;

# 1. The killed git's own lock is removed.
{
    my $dir = hung_repo();
    my $r = BpCheckpoint::checkpoint({ root => $dir, pkg => 'p', write_set => 'src/',
        status => 'running', step => 1, now => 1785000000 });
    is($r->{reason}, 'git-timeout', 'the hung commit times out')
        or diag(explain($r));
    ok(!-e "$dir/.git/index.lock", 'the lock the killed git held is gone');

    # and the repository is usable again: the next checkpoint commits.
    unlink "$dir/.git/hooks/pre-commit";
    my $r2 = BpCheckpoint::checkpoint({ root => $dir, pkg => 'p', write_set => 'src/',
        status => 'running', step => 1, now => 1785000060 });
    ok($r2->{committed}, 'the next checkpoint commits')
        or diag(explain($r2));
}

# 2. A lock that predates this git is somebody else's: left alone.
{
    my $dir = hung_repo();
    my $lock = "$dir/.git/index.lock";
    spit($lock, '');
    my $old = time - 600;
    utime $old, $old, $lock;
    my $r = BpCheckpoint::checkpoint({ root => $dir, pkg => 'p', write_set => 'src/',
        status => 'running', step => 1, now => 1785000000 });
    is($r->{reason}, 'index-locked', 'a pre-existing lock is reported, not raced');
    ok(-e $lock, 'and it is not removed');
    unlink $lock;
}

# 3. What made the commit slow enough to time out in the first place: host and
#    container git share the index and record different stat data, so every
#    tracked file looked dirty to the other side (21-26 s per status over the
#    bind mount, measured 2026-11-03). The checkpoint compares size and mtime only.
{
    open my $fh, '<:raw', "$Bin/../../scripts/bp-checkpoint.pl" or die $!;
    my $src = do { local $/; <$fh> };
    my ($git) = $src =~ /(sub _git \{.*?\n\})/s;
    like($git // '', qr/'core\.checkStat=minimal'/,  'every checkpoint git runs with core.checkStat=minimal');
    like($git // '', qr/'core\.trustctime=false'/,   'and core.trustctime=false');
}

done_testing();
