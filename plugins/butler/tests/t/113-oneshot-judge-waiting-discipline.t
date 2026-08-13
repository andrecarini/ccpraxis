#!/usr/bin/env perl
# t/113-oneshot-judge-waiting-discipline.t — a one-shot judge must never be told
# to background its work.
#
# THE BUG THIS PINS. `judge-harvest.md` and `judge-resolve.md` both carried a
# paragraph copied from the interactive coordinator's protocol:
#
#   "if you launch any long-running check, use run_in_background, end your turn,
#    and resume on the completion notification"
#
# For a coordinator that is right — it has a next turn. A judge does not.
# `bp-judge.sh:8` calls it "a fresh headless `claude -p`" and `:14` says
# outright "a judge is one-shot". When such a process ends its turn awaiting a
# background task, the PROCESS EXITS: the notification has nowhere to arrive and
# no verdict is ever written.
#
# The orchestrator then logs `judge_crashed` and parks the package with a
# decision reading "its outputs don't meet the done-criteria" — which is false;
# no judge ever assessed the work. Reported from a live GSA fleet run
# (2026-08-13) with orchestrator.log evidence, after the same package ate the
# same coin-flip twice across two sessions. It had also been filed once before
# and lost, because that report lived in a session scratchpad.
#
# The instruction is only reachable through prose, so prose is where it must be
# pinned — there is no hook that can inspect what a template tells a model.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

(my $ROOT = "$Bin/../../..") =~ s{\\}{/}g;
my $TPL   = "$ROOT/butler/templates";
my $JUDGE = "$ROOT/butler/scripts/bp-judge.sh";

# The judges: one-shot, and the paragraph is fatal for them.
my @ONESHOT = ('judge-harvest.md', 'judge-resolve.md');

sub slurp { my ($p) = @_; open my $f, '<', $p or return undef; local $/; <$f> }

# The premise this whole test rests on: these really are one-shot processes.
# If that ever stops being true, this file is asserting the wrong thing and
# should fail loudly rather than quietly guard a rule that no longer applies.
{
    my $src = slurp($JUDGE);
    ok(defined $src, 'bp-judge.sh is readable') or BAIL_OUT('cannot read bp-judge.sh');
    like($src, qr/claude -p/,   'bp-judge.sh still launches the judge with `claude -p`');
    like($src, qr/one-shot/i,   'bp-judge.sh still describes the judge as one-shot');
}

for my $name (@ONESHOT) {
    my $p = "$TPL/$name";
    my $t = slurp($p);
    ok(defined $t, "$name exists") or next;

    # The exact instruction that kills a one-shot process.
    #
    # Naively forbidding the STRING is wrong — the corrected text has to name
    # `run_in_background` in order to forbid it, and a first draft of this test
    # duly failed on its own fix. The real property is that every mention is
    # NEGATED: no occurrence may read as an instruction to use it.
    my @unnegated;
    while ($t =~ /run_in_background/gi) {
        my $at   = pos($t);
        my $pre  = substr($t, ($at - 60 > 0 ? $at - 60 : 0), ($at - 60 > 0 ? 60 : $at));
        push @unnegated, $pre unless $pre =~ /\b(?:not|never|don't|do\s+not|avoid|without)\b[^.]{0,40}$/i;
    }
    is(scalar @unnegated, 0,
        "$name mentions run_in_background only to FORBID it")
        or diag("un-negated mention(s) preceded by: " . join(' || ', @unnegated));
    unlike($t, qr/resume on the completion notification/i,
        "$name does not promise a resume that cannot happen");
    unlike($t, qr/end your turn,\s*\n?\s*and resume/i,
        "$name does not tell it to end its turn and resume");

    # ...and it must positively say the opposite, so a reader is not merely left
    # without guidance. Absence of the bad instruction is not the same as
    # presence of the right one.
    like($t, qr/foreground/i,
        "$name positively instructs FOREGROUND execution");
    like($t, qr/one-shot|process (?:exits|EXITS)/i,
        "$name explains WHY — the process exits when the turn ends");

    # The escape valve. Without it, "never background" plus a 1800s timeout is a
    # trap of its own: a judge facing a slow check has no legal move and stalls
    # anyway. It must know it may return a verdict with a stated gap.
    like($t, qr/without it and say so|stated gap|write your verdict without/i,
        "$name tells a judge what to do when a check is too slow to run synchronously");
}

# The coordinator's copy is CORRECT and must not be "fixed" by pattern-matching:
# a coordinator is multi-turn, so backgrounding and resuming is exactly right
# there. This asserts the distinction is understood rather than blanket-applied.
{
    my $t = slurp("$TPL/dispatch-prompt.md");
    ok(defined $t, 'dispatch-prompt.md exists');
    like($t, qr/run_in_background/i,
        'the COORDINATOR template still teaches backgrounding — it has a next turn, unlike a judge');
}

done_testing();
