#!/usr/bin/env perl
# bp_clear_stale_shutdown (bp-lib.sh / #28): an explicit dispatch clears a stale
# terminal .shutdown so a freshly-launched orchestrator actually runs instead of
# winding down on tick 1. (The orchestrator HONORING a live .shutdown is unchanged
# — that path is covered by t/08 S7.) It must NOT touch a sibling .paused, which
# the orchestrator's auto-resume owns.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $LIB = File::Spec->rel2abs(File::Spec->catfile($Bin, qw(.. .. scripts bp-lib.sh)));
ok(-f $LIB, "bp-lib.sh exists at $LIB") or BAIL_OUT("missing $LIB");

# Source bp-lib.sh in a bash subshell and run the helper (stdout silenced so its
# note never leaks into TAP). Paths are passed as bash positional args, not spliced
# into the script string, so a temp path with spaces can't break quoting.
sub clear {
    my $runs = shift;
    return system('bash', '-c',
        'source "$1"; bp_clear_stale_shutdown "$2" >/dev/null', 'x', $LIB, $runs) >> 8;
}

my $tmp  = tempdir(CLEANUP => 1);
my $runs = File::Spec->catdir($tmp, 'runs');
mkdir $runs or die "mkdir $runs: $!";

# 1. a present marker is removed
{ open my $f, '>', "$runs/.shutdown" or die; close $f; }
ok(-e "$runs/.shutdown", 'precondition: .shutdown present');
is(clear($runs), 0, 'clear exits 0 when a marker was present');
ok(!-e "$runs/.shutdown", '.shutdown removed on fresh dispatch');

# 2. absent -> safe no-op
is(clear($runs), 0, 'clear is a safe no-op when no marker is present');
ok(!-e "$runs/.shutdown", 'still absent after no-op');

# 3. a sibling .paused is left intact (auto-resume owns its reset window)
{ open my $f, '>', "$runs/.paused"   or die; close $f; }
{ open my $f, '>', "$runs/.shutdown" or die; close $f; }
is(clear($runs), 0, 'clear exits 0 with both markers present');
ok(!-e "$runs/.shutdown", '.shutdown cleared');
ok(-e "$runs/.paused", '.paused left intact');

done_testing();
