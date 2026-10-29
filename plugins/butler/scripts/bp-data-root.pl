#!/usr/bin/env perl
# bp-data-root.pl — the small perl helper named in Decision 6(7), so a shell
# caller (bp-lib.sh, in both plugins) gets the bounded walk-up (package 03,
# Decision 3) without reimplementing BpDataRoot.pm's Windows-path-form rules
# (8.3 short names, "/x/..." vs "X:/...", Cygwin translation) a third time, in
# the language least able to express them.
#
# Usage:
#   perl bp-data-root.pl [--cwd DIR]
#
# --cwd absent: DIR defaults to Cwd::getcwd(). A relative DIR is made
# absolute against the process cwd.
#
# It calls BpProjectRoot::bounded_walkup(DIR) — the SAME adapter every widened
# Perl caller in this package uses — and nothing else. It reads no
# CLAUDE_PROJECT_DIR, BP_PROJECT_ROOT or CCPRAXIS_DATA_DIR, runs no git,
# writes nothing, and spawns nothing (spec §2.5).
#
# Exit 0: the found dir on STDOUT, spelled with '\' turned into '/', newline
#         terminated. STDERR empty.
# Exit 1: nothing found. STDOUT and STDERR both empty.
# Exit 2: usage error (unknown argument, or --cwd with no value). One line on
#         STDERR, STDOUT empty.

use strict;
use warnings;
use Cwd ();
use File::Spec ();
use File::Basename qw(dirname);

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
# Decision 24 item 6 (review S4): a missing/broken BpProjectRoot.pm must not
# exit 2 -- that code is reserved for a real usage error, and an unguarded
# top-level `require` dying here exits 2 by virtue of $! (ENOENT), making the
# two indistinguishable to a caller. Exit 3 instead, with the failure named on
# stderr, and nothing on stdout (spec §2.5's "yields nothing" behaviour).
unless (eval { require "$DIR/BpProjectRoot.pm"; 1 }) {
    print STDERR "bp-data-root: cannot load BpProjectRoot.pm: $@";
    exit 3;
}

sub _usage_error {
    my ($msg) = @_;
    print STDERR "bp-data-root: $msg\n";
    exit 2;
}

my $cwd_arg;
my @args = @ARGV;
while (@args) {
    my $a = shift @args;
    if ($a eq '--cwd') {
        _usage_error('--cwd requires a value') unless @args;
        $cwd_arg = shift @args;
    }
    else {
        _usage_error("unknown argument: $a");
    }
}

my $start;
if (defined $cwd_arg && length $cwd_arg) {
    $start = File::Spec->file_name_is_absolute($cwd_arg)
        ? $cwd_arg
        : File::Spec->rel2abs($cwd_arg);
}
else {
    $start = Cwd::getcwd() // '.';
}

my $found = eval { BpProjectRoot::bounded_walkup($start) };
if (defined $found) {
    (my $out = $found) =~ s{\\}{/}g;
    print "$out\n";
    exit 0;
}
exit 1;
