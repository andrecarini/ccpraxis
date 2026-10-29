#!/usr/bin/env perl
# bp-power-journal.pl -- CLI entry for the power journal report (Decision 13,
# package 05-power-journal). All logic lives in BpPowerJournal::report_main;
# this file only locates the module and hands off argv.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/BpPowerJournal.pm";

exit(BpPowerJournal::report_main(@ARGV));
