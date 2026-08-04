#!/usr/bin/env perl
# b49-agent-worker-turn-doctrine oracle.
#
# WHY THIS TEST EXISTS
#
# Eleven of eleven dispatched review workers died having written NOTHING, and
# each returned its last narration as its "result" -- which reads exactly like a
# finished agent reporting no findings. ~800-900k subagent tokens, zero output,
# and the failure mode is INDISTINGUISHABLE FROM SUCCESS.
#
# The cause was not a platform ceiling. It was `maxTurns:` in each agent's own
# frontmatter: bp-reviewer 20 (dispatched 7x), bp-redteam 25 (4x). The observed
# 20-34 tool-call death band IS those two numbers.
#
# THIS WAS DIAGNOSED ONCE ALREADY AND MIS-FIXED. b23 (2dced1e) raised the LEDGER
# `max_turns:` default 80 -> 150 and wrote into authoring-protocol/SKILL.md that
# "bp-scout/other haiku-model dispatches specifically default 40", citing "three
# coordinators losing EVERY bp-scout dispatch to haiku's old 15-turn cap".
# `git show 2dced1e --stat -- 'plugins/*/agents/'` is EMPTY. bp-scout.md still
# carried `maxTurns: 15` -- the exact number that prose calls known-starving --
# from its original commit, never touched.
#
# Two fields, one concept, names differing only in case and separator:
#   ledger `max_turns:`        -> headless `claude -p` coordinators, bp-launch.sh
#   agent frontmatter `maxTurns:` -> Task subagents
# The remedy went to the field that shares the concept but not the mechanism.
# That is precisely what assertion group C2 below exists to make impossible to
# repeat: it reads the floor from the protocol and enforces it on the AGENT
# FILES, so prose and mechanism can never drift apart again silently.
#
# NO SHAPE PINS. The floor is READ FROM THE PROTOCOL TEXT, never hardcoded here,
# and the agent set is discovered by glob and asserted with `>=` -- adding an
# agent or raising a cap must never turn this red. (t/00-oracle-hygiene.t.)

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

my $ROOT     = File::Spec->rel2abs("$Bin/../../../..");   # -> /project
my $PROTOCOL = "$ROOT/plugins/butler/skills/coordinator-protocol/SKILL.md";

# ---------------------------------------------------------------- fixtures ---

ok(-f $PROTOCOL, 'coordinator-protocol SKILL.md exists')
    or BAIL_OUT("protocol missing at $PROTOCOL");

my $proto = do { open my $fh, '<', $PROTOCOL or BAIL_OUT("open: $!");
                 local $/; <$fh> };

my @agents = sort glob("$ROOT/plugins/*/agents/*.md");
ok(scalar(@agents) > 0, 'at least one agent definition was discovered')
    or BAIL_OUT('no plugins/*/agents/*.md found -- glob or layout changed');

# ------------------------------------------------- C1: the floor is DECLARED ---
#
# The floor must live in the protocol as a machine-readable sentence, because C2
# reads it from there. A floor that exists only in this test is a shape pin and
# drifts from the doctrine the moment either side is edited.

my ($floor) = $proto =~ /no agent definition may declare `maxTurns:` below `(\d+)`/;

ok(defined $floor, 'C1: protocol declares a machine-readable maxTurns floor')
    or BAIL_OUT('floor sentence absent -- C2 has nothing to enforce');

# A floor-on-the-floor, so the declared floor cannot be quietly walked back down.
# 400 is not a spend decision: a cap only binds when the agent would STILL BE
# WORKING, so a healthy worker costs the same at 40 or 800 while a starved one
# costs the whole dispatch. The asymmetry always argues upward. For calibration,
# a COORDINATOR's ledger max_turns default is 150 -- a worker auditing a whole
# subsystem must not be capped below the thing that dispatches it. Raising the
# floor keeps this green; lowering it is the regression this guards.
cmp_ok($floor, '>=', 400, 'C1: the declared floor is high enough to be a runaway '
    . 'backstop rather than a budget');

# ------------------------------------- C2: every agent file honours the floor ---
#
# THE REGRESSION GUARD. This is the assertion that would have caught b23's
# mis-fix on the day it landed.

for my $path (@agents) {
    my $name = (File::Spec->splitpath($path))[2];

    open my $fh, '<', $path or do { fail("C2: $name unreadable: $!"); next };
    my $text = do { local $/; <$fh> };
    close $fh;

    my ($cap) = $text =~ /^maxTurns:\s*(\d+)\s*$/m;

    if (!defined $cap) {
        fail("C2: $name declares a maxTurns: cap");
        next;
    }

    cmp_ok($cap, '>=', $floor,
        "C2: $name maxTurns ($cap) is at or above the declared floor ($floor)");
}

# ----------------------------- C3: the two fields are distinguished by name ----
#
# The near-collision is the root cause of the mis-fix, so the protocol must name
# BOTH fields and bind each to its own mechanism.

like($proto, qr/`max_turns:`/,
    'C3: protocol names the ledger field `max_turns:`');
like($proto, qr/`maxTurns:`/,
    'C3: protocol names the agent-frontmatter field `maxTurns:`');
like($proto, qr/bp-launch\.sh/,
    'C3: protocol binds the ledger field to its mechanism (bp-launch.sh)');
like($proto, qr/claude -p/,
    'C3: protocol names the headless coordinator mechanism');

# C3d: the protocol must state that Task exposes NO per-dispatch override --
# without this, a coordinator will keep looking for a knob that is not there.
like($proto, qr/no per-dispatch|cannot be overridden per dispatch|no.{0,20}override.{0,40}dispatch/i,
    'C3: protocol states there is no per-dispatch turn override');

# ---------------------------- C4: artifact written EARLY and APPENDED ----------
#
# The load-bearing rule. Caps can be right and a worker can still die; only an
# on-disk artifact survives that.

like($proto, qr/\bappend/i,
    'C4: protocol requires the worker to APPEND to its artifact');
like($proto, qr/earl(y|ier)/i,
    'C4: protocol requires the artifact to be opened EARLY');
like($proto, qr/final message/i,
    'C4: protocol addresses the final message as an insufficient deliverable');

# ------------------- C5: an empty / narration-shaped result is a FAILURE -------
#
# Holds even when every cap is correct. Without it, raising caps only moves the
# silent-false-negative threshold.

like($proto, qr/narration/i,
    'C5: protocol names the narration-shaped result explicitly');
like($proto, qr/not a finding of|never a finding of|is a FAILURE|is a failure/,
    'C5: protocol states an empty result is a failure, not a finding of nothing');
like($proto, qr/confirm.{0,60}(on disk|exists)|(on disk|exists).{0,60}before accepting/i,
    'C5: protocol requires confirming the artifact on disk before accepting a result');

done_testing();
