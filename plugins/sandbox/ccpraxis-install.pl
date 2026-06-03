#!/usr/bin/env perl
# ccpraxis-install.pl — sandbox plugin install hook.
# Wires plugins/sandbox/bin/ (claude-sandbox) into the user's PATH.
#
# Two modes — passed through to the shared helper:
#   perl ccpraxis-install.pl plan       describe what would change
#   perl ccpraxis-install.pl apply      make the changes

use strict;
use warnings;
use FindBin qw($Bin);

my $mode = $ARGV[0] // 'plan';
exec $^X,
    "$Bin/../../scripts/_install-bin-helper.pl",
    $mode,
    "$Bin/bin"
    or die "exec helper failed: $!\n";
