#!/usr/bin/env perl
# almanac-decision.pl -- RETIRED (blueprint where-things-go, package
# 01-inbox-rename, Decisions 2/6: hard cutover, nothing aliases). Use
# "almanac inbox" instead. This file is a self-contained stub: no require,
# no use of anything else in this repo, so it prints its one-line pointer
# even when invoked relatively or required/done from anywhere. It defines no
# Almanac::Decision symbols.
use strict;
use warnings;

my $MSG = "almanac: 'almanac-decision.pl' is retired; use 'almanac inbox' instead\n";

unless (caller) {
    print STDERR $MSG;
    exit 2;
}
die $MSG;
