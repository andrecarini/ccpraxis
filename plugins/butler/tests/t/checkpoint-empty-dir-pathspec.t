#!/usr/bin/env perl
# platform: windows
# A write-set entry naming a directory that exists but holds nothing git can
# track must not cost the other entries their checkpoint.
#
# Measured 2026-11-02 (acxpraxis-step-2, 05-checks-erlang): `git add -A --
# tools/checks/otp` exits 0 for an existing empty directory, so the entry
# counted as staged, and `git commit -- <all staged>` then refused the whole
# commit: "pathspec 'tools/checks/otp' did not match any file(s) known to git".
# Four checkpoints were lost that way before the directory got a file.
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

# Native-resolvable fixture root (see t/checkpoint-hardening.t: requiring the
# orchestrator disables MSYS argv translation, so /tmp/... must not reach git).
my $NATIVE_TMP = do {
    my $t = $ENV{TEMP} // $ENV{TMP};
    ($^O =~ /^(MSWin32|cygwin|msys)$/ && defined $t && length $t && -d $t)
        ? do { (my $p = $t) =~ s{\\}{/}g; $p } : undef;
};
my $ROOT = tempdir(($NATIVE_TMP ? (DIR => $NATIVE_TMP) : ()), CLEANUP => 1);

sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f }
sub git_ok { my ($dir, @a) = @_; system('git', '-C', git_path($dir), @a) == 0 or die "git @a failed" }
sub git_out {
    my ($dir, @a) = @_;
    my $pid = open(my $fh, '-|') // die "fork: $!";
    unless ($pid) { open(STDERR, '>&', \*STDOUT); exec('git', '-C', git_path($dir), @a); exit 127 }
    local $/; my $o = <$fh>; close $fh; return $o // '';
}

my $dir = "$ROOT/repo";
make_path("$dir/src");
git_ok($dir, 'init', '-q', '.');
spit("$dir/src/a.txt", "one\n");
git_ok($dir, 'add', '-A');
git_ok($dir, '-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'fixture');
my $before = git_out($dir, 'rev-parse', 'HEAD');

spit("$dir/src/a.txt", "two\n");
make_path("$dir/tools/checks/otp");                   # exists, empty

my $r = eval { BpCheckpoint::checkpoint({ root => $dir, pkg => '05-checks-erlang',
    write_set => 'src/:tools/checks/otp', status => 'running', step => 2, now => 1785000000 }) };
is($@, '', 'checkpoint does not die');
ok($r && $r->{committed}, 'the checkpoint commits')
    or diag(explain($r));
isnt(git_out($dir, 'rev-parse', 'HEAD'), $before, 'HEAD moved');
like(git_out($dir, 'show', '--name-only', '--format=', 'HEAD'), qr{^src/a\.txt$}m, 'src/a.txt is in the commit');
is_deeply($r->{staged}, ['src'], 'the empty directory is not reported as staged');
ok((grep { $_ eq 'tools/checks/otp' } @{ $r->{unmatched} || [] }), 'it is reported unmatched');

# Nothing else in the set: a clean no-op, not a failure.
spit("$dir/src/a.txt", "two\n");
my $r2 = eval { BpCheckpoint::checkpoint({ root => $dir, pkg => '05-checks-erlang',
    write_set => 'tools/checks/otp', status => 'running', step => 2, now => 1785000060 }) };
# (a no-op reports exit 1 by design: _noop, "nothing needed committing")
ok($r2 && $r2->{ok} && !$r2->{committed} && $r2->{status} eq 'clean', 'an empty directory alone is a no-op')
    or diag(explain($r2));

done_testing();
