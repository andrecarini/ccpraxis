#!/usr/bin/env perl
# Test runner for plugins/beacon/tests/t/.
#
# Runs every `*.t` file in alphabetical order, captures pass/fail, prints
# a one-line summary plus the per-file output for any failure. Exit code
# is the number of failed test files (0 = all green).
#
# Usage:
#   perl tests/run-tests.pl              # all tests
#   perl tests/run-tests.pl t/02-*.t     # subset by glob

use strict;
use warnings;
use FindBin qw($Bin);
use File::Basename qw(basename);

my @files;
if (@ARGV) {
    for my $arg (@ARGV) {
        # Resolve the glob cwd-relative first (so `perl run-tests.pl t/02-*.t`
        # works when invoked from the plugin root where `t/` is a child).
        # Fall back to $Bin-relative, then $Bin/t/-relative, so the same
        # invocation also works from the repo root (where `t/` is several
        # levels deeper but `plugins/beacon/tests/t/` resolves via $Bin).
        my @matched = glob($arg);
        unless (@matched) {
            @matched = glob("$Bin/$arg");
        }
        unless (@matched) {
            @matched = glob("$Bin/t/$arg");
        }
        push @files, sort @matched;
    }
} else {
    @files = sort glob("$Bin/t/*.t");
}

unless (@files) {
    print STDERR "no test files matched\n";
    exit 2;
}

my $passed = 0;
my $failed = 0;
my @failures;

print "\n=== beacon plugin test suite ===\n";
print "running ", scalar(@files), " files\n\n";

for my $file (@files) {
    my $short = basename($file);
    printf("  %-50s ", $short);
    my $start = time;
    my $output = `"$^X" "$file" 2>&1`;
    my $rc = $? >> 8;
    my $elapsed = time - $start;
    if ($rc == 0) {
        printf("ok   (%ds)\n", $elapsed);
        $passed++;
    } else {
        printf("FAIL (%ds, exit %d)\n", $elapsed, $rc);
        $failed++;
        push @failures, { file => $short, rc => $rc, output => $output };
    }
}

print "\n--- summary ---\n";
printf("passed: %d\n", $passed);
printf("failed: %d\n", $failed);

if (@failures) {
    print "\n=== failure details ===\n";
    for my $f (@failures) {
        print "\n### $f->{file} (exit $f->{rc}) ###\n";
        print $f->{output};
    }
}

exit $failed;
