#!/usr/bin/env perl
# bp-answer-decision.pl is retired (hard cutover). Use bp-answer-escalation.pl.
my $MSG = "butler: 'bp-answer-decision.pl' is retired; use 'bp-answer-escalation.pl' instead (same arguments)\n";
unless (caller) { print STDERR $MSG; exit 2; }
die $MSG;
