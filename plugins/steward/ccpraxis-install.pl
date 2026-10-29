#!/usr/bin/env perl
# ccpraxis-install.pl — steward plugin install hook.
# Wires plugins/steward/bin/ (the `ccpraxis` dispatcher) into the user's PATH.
#
# Same shape as the sandbox plugin's hook, and picked up by install.pl's
# plugins/* glob with no registration anywhere.
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
