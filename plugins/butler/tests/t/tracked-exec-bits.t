#!/usr/bin/env perl
# platform: host
# Exec bits are decided in the git index, and nothing but a test keeps them
# right: Git for Windows ignores modes and commits a new file as 100644, which a
# Mac clone then cannot run by path (exit 126), and an install-time chmod inside
# the live install makes the next promote refuse a dirty tree.
#
#   E1  every tracked non-.t file that starts with `#!` is 100755 in the index
#   E2  every plugins/*/bin/X.sh has a tracked, 100755, extensionless X that is
#       a shim for it (so the bare name works on a Linux/macOS PATH without the
#       install helper writing a symlink into the install)
#
# Fix a red E1 with: git update-index --chmod=+x <path>
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd ();

my $ROOT = Cwd::abs_path("$Bin/../../../..");
plan skip_all => 'not a git work tree' unless -e "$ROOT/.git";
my $ls = do { local $ENV{GIT_OPTIONAL_LOCKS} = 0; `git -C "$ROOT" ls-files -s -z 2>/dev/null` };
plan skip_all => 'git ls-files unavailable' unless defined $ls && length $ls;

my %mode;
for my $rec (split /\0/, $ls) {
    my ($m, undef, $stage, $path) = $rec =~ /\A(\d+) (\S+) (\d)\t(.*)\z/s or next;
    $mode{$path} = $m;
}
ok(scalar(keys %mode) > 100, 'sanity: the index lists the repo');

my @bad;
for my $p (sort keys %mode) {
    next if $p =~ /\.t\z/ || $mode{$p} eq '120000';
    my $f = "$ROOT/$p";
    next unless -f $f;
    open my $fh, '<:raw', $f or next;
    read($fh, my $head, 2);
    close $fh;
    push @bad, "$mode{$p} $p" if defined $head && $head eq '#!' && $mode{$p} ne '100755';
}
is_deeply(\@bad, [], 'E1: every tracked shebang script is 100755 (git update-index --chmod=+x)');

my @gaps;
for my $p (sort keys %mode) {
    next unless $p =~ m{\A(plugins/[^/]+/bin/)([^/]+)\.sh\z};
    my ($dir, $name) = ($1, $2);
    my $alias = "$dir$name";
    if (!exists $mode{$alias})        { push @gaps, "$alias: not tracked"; next }
    if ($mode{$alias} ne '100755')    { push @gaps, "$alias: mode $mode{$alias}"; next }
    open my $fh, '<:raw', "$ROOT/$alias" or do { push @gaps, "$alias: unreadable"; next };
    my $body = do { local $/; <$fh> };
    close $fh;
    push @gaps, "$alias: does not exec $name.sh" unless $body =~ /\Q$name\E\.sh/;
}
is_deeply(\@gaps, [], 'E2: every bin/X.sh has a tracked 100755 extensionless shim');

done_testing;
