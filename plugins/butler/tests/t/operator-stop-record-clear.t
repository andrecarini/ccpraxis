#!/usr/bin/env perl
# platform: any
# fleet-control (operator, 2026-11-11): the sandbox dashboard's [f] screen
# stops a fleet with butler's own graceful stop (runs/.shutdown) and records
# that the operator asked for it in runs/.stopped-by-operator, so a stopped
# fleet never reads as a crashed one. An explicit dispatch (bp-orchestrate.sh
# -> bp_clear_stale_shutdown) is the operator starting it again, so it must
# clear that record along with the stale .shutdown -- or the NEXT crash would
# read as "stopped by you". .paused is still left alone.
#
# Non-vacuity: against the pre-change bp-lib.sh, bp_clear_stale_shutdown
# leaves .stopped-by-operator in place, so the two "is cleared" assertions
# (tests 3 and 6) fail; measured 2026-11-11 against HEAD 8418620.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $LIB = File::Spec->rel2abs(File::Spec->catfile($Bin, qw(.. .. scripts bp-lib.sh)));
ok(-f $LIB, "bp-lib.sh exists at $LIB") or BAIL_OUT("missing $LIB");

sub clear {
    my $runs = shift;
    return system('bash', '-c',
        'source "$1"; bp_clear_stale_shutdown "$2" >/dev/null', 'x', $LIB, $runs) >> 8;
}
sub touch { my ($p) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} qq({"v":1,"at":1767225600,"by":"dashboard"}\n); close $f; }

my $tmp  = tempdir(CLEANUP => 1);
my $runs = File::Spec->catdir($tmp, 'runs');
mkdir $runs or die "mkdir $runs: $!";

# 1. an operator stop: both markers present -> both cleared on dispatch
touch("$runs/.stopped-by-operator");
touch("$runs/.shutdown");
is(clear($runs), 0, 'clear exits 0 with an operator-stop record and .shutdown present');
ok(!-e "$runs/.stopped-by-operator", 'the operator-stop record is cleared by an explicit dispatch');
ok(!-e "$runs/.shutdown", '.shutdown is cleared too (unchanged behaviour)');

# 2. the record alone (the orchestrator already consumed nothing else) -> cleared
touch("$runs/.stopped-by-operator");
is(clear($runs), 0, 'clear exits 0 with only the record present');
ok(!-e "$runs/.stopped-by-operator", 'a lone operator-stop record is cleared');

# 3. .paused is still never touched
touch("$runs/.paused");
touch("$runs/.stopped-by-operator");
is(clear($runs), 0, 'clear exits 0 with .paused and the record present');
ok(-e "$runs/.paused", '.paused left intact (auto-resume owns it)');

# 4. absent -> a safe no-op
unlink "$runs/.paused";
is(clear($runs), 0, 'clear is a no-op when nothing is present');

# 5. bp-orchestrate.sh still clears through this one helper, after it has
#    confirmed no live orchestrator holds the marker (source order).
my $orch = File::Spec->catfile($Bin, qw(.. .. scripts bp-orchestrate.sh));
open my $fh, '<', $orch or die "$orch: $!";
my $src = do { local $/; <$fh> };
close $fh;
my $live = index($src, 'orchestrator already running');
my $clr  = index($src, 'bp_clear_stale_shutdown "$RUNS"');
ok($live > 0 && $clr > $live, 'bp-orchestrate.sh clears the markers only after its already-running check');

done_testing();
