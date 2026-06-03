#!/usr/bin/env perl
# Empty sessions dir should produce NEW without showing the picker. This
# is the "fresh sandbox" path — first launch, no prior work to resume.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);

plan tests => 3;

my $script = "$Bin/../../scripts/select-session.pl";
ok(-f $script, "select-session.pl exists at $script") or BAIL_OUT("script missing");

my $empty_dir = tempdir(CLEANUP => 1);
my $out_file  = "$empty_dir/.session-pick";

my $rc = system($^X, $script,
    '--sessions-dir', $empty_dir,
    '--project-label', 'test-empty',
    '--output', $out_file);

is($rc >> 8, 0, 'select-session.pl exits 0 on empty dir');

open my $fh, '<', $out_file or die "open $out_file: $!";
my $content = do { local $/; <$fh> };
close $fh;
chomp $content;
is($content, 'NEW', 'output is NEW when no sessions exist');
