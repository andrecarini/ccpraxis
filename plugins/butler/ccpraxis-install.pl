#!/usr/bin/env perl
# ccpraxis-install.pl — butler plugin install hook.
# Wires plugins/butler/bin/ (the bp-* command shims) into the user's PATH.
#
# WHY THERE IS A SHIM AT ALL. stop-gate.sh blocks a turn and tells the
# agent what to run instead. Those instructions used to carry the fully
# resolved path to the old continuity CLI -- around eighty characters of it, complete
# with a `/../` -- printed twice in one message. A remedy that unwieldy invites
# being retyped wrongly, and it made an already long block message longer.
#
# Two modes -- passed through to the shared helper:
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
