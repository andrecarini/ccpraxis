#!/usr/bin/env perl
# bp-wait-for-decision.pl is retired (hard cutover). Use bp-wait-for-escalation.pl.
my $MSG = "butler: 'bp-wait-for-decision.pl' is retired; use 'bp-wait-for-escalation.pl' instead (same arguments)\n";
unless (caller) { print STDERR $MSG; exit 2; }
die $MSG;
