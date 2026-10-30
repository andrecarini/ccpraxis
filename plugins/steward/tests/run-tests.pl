#!/usr/bin/env perl
# run-tests.pl — runner for the steward vault test suite.
#
# Discovers t/*.t relative to THIS script (not the cwd), runs each as its own
# perl process with lib/ on @INC, and reports a per-file pass/fail summary.
# Exit 0 iff every test file exits 0. Optional args are globs of test files to
# run a subset; they resolve cwd-relative first, then relative to t/.
#
# Usage:
#   perl run-tests.pl                 # all tests
#   perl run-tests.pl t/01-*.t        # a subset (works from repo root or here)
use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);

my $T_DIR   = "$Bin/t";
my $LIB_DIR = "$Bin/lib";

my @files;
if (@ARGV) {
    for my $arg (@ARGV) {
        my @hits = glob($arg);
        @hits = glob("$T_DIR/" . basename($arg)) unless @hits;
        @hits = glob("$Bin/$arg") unless @hits;
        if (@hits) { push @files, @hits } else { warn "no match for '$arg'\n" }
    }
    unless (@files) { print STDERR "No test files matched.\n"; exit 2 }
} else {
    @files = glob("$T_DIR/*.t");
}
@files = sort @files;

unless (@files) { print STDERR "No test files found in $T_DIR\n"; exit 2 }

my ($passed, $failed) = (0, 0);
my @failed_files;

for my $f (@files) {
    my $name = basename($f);
    print "=== $name ===\n";
    my $rc = system($^X, "-I$LIB_DIR", $f);
    my $exit = $rc >> 8;
    if ($rc == 0) {
        $passed++;
    } else {
        $failed++;
        push @failed_files, $name;
        print "  >>> FAILED ($name) exit=$exit\n";
    }
    print "\n";
}

print "─────────────────────────────────────────\n";
printf "Test files: %d passed, %d failed (of %d)\n", $passed, $failed, scalar @files;
print "Failed: " . join(", ", @failed_files) . "\n" if @failed_files;
exit($failed ? 1 : 0);
