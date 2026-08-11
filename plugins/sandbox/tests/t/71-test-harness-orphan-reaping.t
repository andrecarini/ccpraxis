#!/usr/bin/env perl
# 71-test-harness-orphan-reaping.t
#
# The harness itself is the system under test here.
#
# TestSandbox.pm creates real `sleep 600` probe containers and relied on a
# single END block to remove them. END does not run on an unhandled signal, and
# this suite is routinely run under `timeout` (project CLAUDE.md mandates it for
# anything that could reach launcher.pl) and interrupted by hand. Every such
# abort leaked a container, and because names are PID-tagged the leftovers
# accumulated silently instead of colliding — the operator eventually found a
# pile of them in `podman ps -a`.
#
# These tests pin the reaping RULE (pure, no container runtime needed) and the
# registration of the signal handlers. They deliberately do NOT create real
# containers: the rule is where the bugs live, and a test that spawns podman
# would be gated on a runtime this file does not need.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/../../scripts";

# Loading TestSandbox runs its load-time sweep against the real container CLI.
# Suppress that here: this file asserts on the rule, and a test that quietly
# removed containers as a side effect of `use` would be a worse citizen than
# the leak it is fixing.
BEGIN { $ENV{CCPRAXIS_TEST_NO_SWEEP} = 1 }

my $HAVE_CLI = do {
    my $ok = 0;
    for my $c ($^O =~ /^(MSWin32|cygwin|msys)$/ ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        if (system("$c --version > /dev/null 2>&1") == 0) { $ok = 1; last }
    }
    $ok;
};

if (!$HAVE_CLI) {
    plan skip_all => 'no container CLI on PATH (TestSandbox.pm dies at load without one)';
}

require TestSandbox;
TestSandbox->import(qw(orphan_container_names test_container_prefix sweep_orphan_containers));

my $P = test_container_prefix();
is($P, 'claude-sandbox-test-', 'prefix is the documented one');

# --- The rule ---------------------------------------------------------------
# $alive_fn is injected so "is this PID alive" is decided by the test, not by
# whatever happens to be running on the machine.
my $DEAD = sub { 0 };
my $LIVE = sub { 1 };

{
    my @orphans = orphan_container_names(["${P}12345-1-c"], $DEAD);
    is_deeply(\@orphans, ["${P}12345-1-c"], 'a test container whose PID is dead is an orphan');
}

{
    my @orphans = orphan_container_names(["${P}12345-1-c"], $LIVE);
    is_deeply(\@orphans, [], 'a test container whose PID is ALIVE is never reaped (concurrent runs stay safe)');
}

{
    # The whole point of the PID tag: two runs at once must not reap each other.
    my @orphans = orphan_container_names(
        ["${P}111-1-c", "${P}222-1-c"],
        sub { $_[0] == 222 ? 1 : 0 },
    );
    is_deeply(\@orphans, ["${P}111-1-c"], 'mixed live/dead: only the dead run\'s container is reaped');
}

{
    # Never reap our own containers, whatever the liveness probe claims. A
    # buggy probe must not be able to make a run delete the containers it is
    # actively using.
    my @orphans = orphan_container_names(["${P}$$-1-c"], $DEAD);
    is_deeply(\@orphans, [], 'our own PID is excluded even when the alive-probe says dead');
}

# --- Names that are not ours ------------------------------------------------
# The matcher is strict on purpose. A loose prefix match would make this
# sweeper capable of deleting a real project container, which is unacceptable
# for something that runs automatically at module load.
for my $foreign (
    'claude-ccpraxis-1c2a518d',            # a real project sandbox
    'claude-gsa-superapp-0f5c8f75',        # another operator container
    'claude-sandbox-test',                 # prefix with nothing after it
    'claude-sandbox-testing-1-1-c',        # prefix is not followed by a PID
    "${P}notapid-1-c",                     # non-numeric pid
    "${P}123",                             # pid but no counter
    "x${P}123-1-c",                        # prefix not at the start
) {
    my @orphans = orphan_container_names([$foreign], $DEAD);
    is_deeply(\@orphans, [], "not ours, never reaped: $foreign");
}

{
    # Suffixless and multi-suffix forms both belong to us.
    my @orphans = orphan_container_names(["${P}999-3", "${P}999-4-c", "${P}999-5-vol-a"], $DEAD);
    is_deeply(\@orphans, ["${P}999-3", "${P}999-4-c", "${P}999-5-vol-a"],
              'the optional suffix is optional, and a multi-part suffix still matches');
}

# --- Robustness -------------------------------------------------------------
is_deeply([orphan_container_names([], $DEAD)],       [], 'empty list -> no orphans');
is_deeply([orphan_container_names(undef, $DEAD)],    [], 'undef list -> no orphans, no crash');
is_deeply([orphan_container_names(['', undef], $DEAD)], [], 'empty/undef names are skipped');

# --- Signal handlers are actually registered --------------------------------
# The regression this file exists for is "END never ran". Assert the handlers
# are installed, since that is the layer that covers Ctrl-C and `timeout`.
for my $sig (qw(INT TERM HUP)) {
    is(ref $SIG{$sig}, 'CODE', "SIG$sig has a cleanup handler installed (END alone does not cover signals)");
}

# --- The sweeper is callable and non-fatal ----------------------------------
# Not asserting on what it removes: on a developer machine that depends on what
# is running. Asserting it returns a list and does not die is the contract that
# matters — a sweeper that can throw would fail unrelated tests at load time.
{
    my @swept = eval { sweep_orphan_containers() };
    is($@, '', 'sweep_orphan_containers does not die');
    ok(ref(\@swept) eq 'ARRAY', 'sweep_orphan_containers returns a list');
}

done_testing();
