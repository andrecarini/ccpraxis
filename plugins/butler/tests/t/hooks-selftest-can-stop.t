#!/usr/bin/env perl
# platform: any
# Bug 20261111-093546-547b: the hooks self-test's `claude -p` could never end its turn.
#
# bp-hooks-selftest.sh runs a headless session dressed as a coordinator (BP_LEDGER, BP_DIR,
# BP_PACKAGE=hooks-selftest exported, no BP_ROLE) so guard-writes has a write set to enforce,
# with an empty stub ledger. BpHook classifies that session as a coordinator, so the Stop
# gate held it to a coordinator's ledger discipline, which the stub can never meet: every
# stop was refused ("status 'unset' is not terminal"), and the session kept going -- once
# long enough to file the bug. The fix pre-creates the gate's own one-shot force-stop marker.
#
#   S1  the script creates $BP_DIR/runs/$BP_PACKAGE.force-stop inside the subshell, after the
#       BP_* exports and before `claude -p` runs
#   S2  the real Stop gate, in exactly that environment with the stub ledger, refuses the
#       stop without the marker (the bug), allows it with the marker, and consumes it, so a
#       second stop is refused again (the marker is not a standing exemption)
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPT = "$Bin/../../scripts/bp-hooks-selftest.sh";

# ---- S1: the script --------------------------------------------------------
{
    open my $fh, '<:raw', $SCRIPT or die "$SCRIPT: $!";
    my @l = <$fh>;
    close $fh;
    my ($i_pkg)   = grep { $l[$_] =~ /export BP_PACKAGE="hooks-selftest"/ } 0 .. $#l;
    my ($i_force) = grep { $l[$_] =~ /^\s*:\s*>\s*"\$BP_DIR\/runs\/\$BP_PACKAGE\.force-stop"\s*$/ } 0 .. $#l;
    my ($i_claude) = grep { $l[$_] =~ /^\s*claude -p "\$PROMPT"/ } 0 .. $#l;
    ok(defined $i_pkg && defined $i_claude, 'S1 precondition: the exports and the claude -p call are found');
    ok(defined $i_force, 'S1: the script creates $BP_DIR/runs/$BP_PACKAGE.force-stop');
    ok(defined $i_force && defined $i_pkg && $i_force > $i_pkg, 'S1: ...after BP_PACKAGE is exported');
    ok(defined $i_force && defined $i_claude && $i_force < $i_claude, 'S1: ...and before claude -p runs');
    my ($i_mk) = grep { $l[$_] =~ /mkdir -p .*"\$WS\/bp\/runs"/ } 0 .. $#l;
    ok(defined $i_mk && defined $i_force && $i_mk < $i_force, 'S1: the runs dir it writes into is created first');
}

# ---- S2: the gate, in the self-test's environment ---------------------------
require "$Bin/../../scripts/BpHook.pm";
require "$Bin/../../scripts/BpHook/StopGate.pm";

my $ws = tempdir(CLEANUP => 1);
make_path("$ws/bp/runs", "$ws/proj");
open my $lf, '>', "$ws/bp/ledger.md" or die $!; close $lf;      # the stub: `: > "$BP_LEDGER"`

local $ENV{BP_LEDGER}       = "$ws/bp/ledger.md";
local $ENV{BP_DIR}          = "$ws/bp";
local $ENV{BP_PROJECT_ROOT} = "$ws/proj";
local $ENV{BP_PACKAGE}      = 'hooks-selftest';
local $ENV{BP_WRITE_SET}    = 'allowed/';
local $ENV{BP_TEST_PATHS}   = 'tests/';
delete local $ENV{BP_ROLE};
local $ENV{CCPRAXIS_DATA_DIR} = "$ws/data";
make_path("$ws/data");

is(BpHook::role({ session_id => 'selftest-sid', cwd => "$ws/proj" }), 'coordinator',
   'S2 precondition: the self-test environment is classified as a coordinator');

my $p = { hook_event_name => 'Stop', session_id => 'selftest-sid', cwd => "$ws/proj" };
my $force = "$ws/bp/runs/hooks-selftest.force-stop";

# Capture the gate's verdict: deny() prints a decision and returns non-zero (or exits);
# run it in a child so an exit cannot end the test.
sub gate_allows {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        my $rc = eval { BpHook::StopGate::run($p) };
        POSIX::_exit(defined $rc && $rc == 0 ? 0 : 1);
    }
    waitpid($pid, 0);
    return ($? >> 8) == 0 ? 1 : 0;
}
require File::Spec;
require POSIX;

ok(!gate_allows(), 'S2: without the marker the stop is refused (the bug: the stub ledger can never be terminal)');
open my $mf, '>', $force or die $!; close $mf;
ok(gate_allows(), 'S2: with the marker the stop is let through');
ok(!-e $force, 'S2: ...and the marker is consumed');
ok(!gate_allows(), 'S2: a second stop is refused again: the marker is one-shot, not an exemption');

done_testing();
