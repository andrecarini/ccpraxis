#!/usr/bin/env perl
# platform: any
# Bug 20261111-093546-547b: the hooks self-test's `claude -p` could never end its turn.
#
# bp-hooks-selftest.sh runs a headless session dressed as a coordinator (BP_LEDGER, BP_DIR,
# BP_PACKAGE=hooks-selftest exported, no BP_ROLE) so guard-writes has a write set to enforce.
# BpHook classifies that session as a coordinator, so the Stop gate holds it to a
# coordinator's ledger discipline, which an empty stub ledger can never meet: every stop
# was refused ("status 'unset' is not terminal").
#
# The first fix (ef9b6d5) pre-created the gate's one-shot force-stop marker. That let the
# stop through, but GateShutdown reads the same marker as "this package is being
# force-stopped" and denied the Agent dispatch the self-test exists to make, so the
# self-test failed closed as INCONCLUSIVE and the acxpraxis-step-3 fleet refused to start
# (2026-11-23). The stub ledger now says `status: done` instead, and no marker is created.
#
#   S1  the script writes a stub ledger with `status: done` inside the subshell, after the
#       BP_* exports and before `claude -p`, and creates no force-stop marker
#   S2  the real Stop gate, in exactly that environment, refuses the stop with an empty
#       ledger (the original bug) and allows it with the stub the script writes
#   S3  the real GateShutdown guard, in that environment, does not deny the Agent dispatch
#       (the regression the first fix caused), and does deny it when a force-stop marker
#       exists (so S3 is not vacuous)
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
require File::Spec;
require POSIX;

my $SCRIPT = "$Bin/../../scripts/bp-hooks-selftest.sh";

# ---- S1: the script --------------------------------------------------------
my $stub_cmd;
{
    open my $fh, '<:raw', $SCRIPT or die "$SCRIPT: $!";
    my @l = <$fh>;
    close $fh;
    my ($i_pkg)    = grep { $l[$_] =~ /export BP_PACKAGE="hooks-selftest"/ } 0 .. $#l;
    my ($i_ledger) = grep { $l[$_] =~ /'status: done'/ && $l[$_] =~ /^\s*printf / } 0 .. $#l;
    my ($i_claude) = grep { $l[$_] =~ /^\s*claude -p "\$PROMPT"/ } 0 .. $#l;
    ok(defined $i_pkg && defined $i_claude, 'S1 precondition: the exports and the claude -p call are found');
    ok(defined $i_ledger, 'S1: the script writes a stub ledger with status: done');
    ok(defined $i_ledger && defined $i_pkg && $i_ledger > $i_pkg, 'S1: ...after BP_PACKAGE is exported');
    ok(defined $i_ledger && defined $i_claude && $i_ledger < $i_claude, 'S1: ...and before claude -p runs');
    ok(!grep({ $_ !~ /^\s*#/ && /force-stop/ } @l), 'S1: the script creates no force-stop marker');
    if (defined $i_ledger) {
        # The printf statement may span continuation lines; take it whole.
        my $j = $i_ledger;
        $stub_cmd = $l[$j];
        while ($stub_cmd =~ /\\\s*\z/ && $j < $#l) { $stub_cmd .= $l[++$j] }
    }
}

# ---- S2/S3: the guards, in the self-test's environment ----------------------
require "$Bin/../../scripts/BpHook.pm";
require "$Bin/../../scripts/BpHook/StopGate.pm";
require "$Bin/../../scripts/BpHook/Guards/GateShutdown.pm";

my $ws = tempdir(CLEANUP => 1);
make_path("$ws/bp/runs", "$ws/proj", "$ws/data");

local $ENV{BP_LEDGER}         = "$ws/bp/ledger.md";
local $ENV{BP_DIR}            = "$ws/bp";
local $ENV{BP_PROJECT_ROOT}   = "$ws/proj";
local $ENV{BP_PACKAGE}        = 'hooks-selftest';
local $ENV{BP_WRITE_SET}      = 'allowed/';
local $ENV{BP_TEST_PATHS}     = 'tests/';
local $ENV{CCPRAXIS_DATA_DIR} = "$ws/data";
delete local $ENV{BP_ROLE};

is(BpHook::role({ session_id => 'selftest-sid', cwd => "$ws/proj" }), 'coordinator',
   'S2 precondition: the self-test environment is classified as a coordinator');

my $stop = { hook_event_name => 'Stop', session_id => 'selftest-sid', cwd => "$ws/proj" };

# Run a guard in a child so a deny that exits cannot end the test; 1 = allowed.
sub allowed {
    my ($code) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        my $rc = eval { $code->() };
        POSIX::_exit(defined $rc && $rc == 0 ? 0 : 1);
    }
    waitpid($pid, 0);
    return ($? >> 8) == 0 ? 1 : 0;
}

# S2: an empty ledger is refused; the script's own stub is allowed.
open my $lf, '>', $ENV{BP_LEDGER} or die $!; close $lf;
ok(!allowed(sub { BpHook::StopGate::run($stop) }), 'S2: with an empty ledger the stop is refused (the original bug)');

SKIP: {
    skip 'S2: the stub-writing statement was not found', 2 unless defined $stub_cmd;
    unlink $ENV{BP_LEDGER};
    my $rc = system('bash', '-c', $stub_cmd);
    ok($rc == 0 && -s $ENV{BP_LEDGER}, 'S2: the script\'s own stub statement writes the ledger');
    ok(allowed(sub { BpHook::StopGate::run($stop) }), 'S2: with the stub ledger the stop is allowed');
}

# S3: GateShutdown, for the Agent dispatch the self-test makes.
my $task = { hook_event_name => 'PreToolUse', tool_name => 'Agent', session_id => 'selftest-sid',
             cwd => "$ws/proj", tool_input => { prompt => 'write two files', subagent_type => 'general-purpose' } };
my $gate = BpHook::Guards::GateShutdown->can('check') || BpHook::Guards::GateShutdown->can('run');
SKIP: {
    skip 'S3: GateShutdown has no check/run entry point', 2 unless $gate;
    ok(allowed(sub { my $r = $gate->($task); (ref $r ? 1 : ($r // 0)) }),
       'S3: with no force-stop marker GateShutdown lets the Agent dispatch through');
    my $force = "$ws/bp/runs/hooks-selftest.force-stop";
    open my $mf, '>', $force or die $!; close $mf;
    ok(!allowed(sub { my $r = $gate->($task); (ref $r ? 1 : ($r // 0)) }),
       'S3: with a force-stop marker it denies it (the regression the first fix caused)');
    unlink $force;
}

done_testing();
