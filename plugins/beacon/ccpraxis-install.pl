#!/usr/bin/env perl
# ccpraxis-install.pl — beacon plugin install hook.
# Wires plugins/beacon/bin/ (claude-beacon) into the user's PATH.

use strict;
use warnings;
use FindBin qw($Bin);

my $mode = $ARGV[0] // 'plan';
exec $^X,
    "$Bin/../../scripts/_install-bin-helper.pl",
    $mode,
    "$Bin/bin"
    or die "exec helper failed: $!\n";
