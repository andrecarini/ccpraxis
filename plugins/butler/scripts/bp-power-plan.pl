#!/usr/bin/env perl
# bp-power-plan.pl -- CLI entry for the power plan reconciler (Decision 14,
# package 06-plan-follows-arming). All logic lives in BpPowerPlan::cli_main;
# this file only locates the module and hands off argv.
use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f });
require "$DIR/BpPowerPlan.pm";

exit(BpPowerPlan::cli_main(@ARGV));
