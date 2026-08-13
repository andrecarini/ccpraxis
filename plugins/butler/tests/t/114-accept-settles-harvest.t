#!/usr/bin/env perl
# t/114-accept-settles-harvest.t — accepting a harvest failure must be DURABLE.
#
# THE BUG. `bp-answer-decision.pl --action accept` set the ledger to `done` and
# stopped there. But the orchestrator fires a harvest audit on
# (status done, harvest EMPTY, none in flight) — BpJudge::want_harvest_audit —
# so a package whose harvest never produced a verdict was re-armed on the very
# next tick. Accepting settled nothing.
#
# Reported from a live GSA fleet run: EIGHT consecutive re-fires of the same
# harvest-failure decision, each re-accepted by hand. It compounded the
# one-shot judge deadlock fixed in 0841130 — that judge could never write a
# verdict, so nothing would ever fill the field and the loop had no exit.
#
# 'pass' specifically is required, not a more honest-looking 'accepted': gate
# mode admits dependents only on `harvest eq 'pass'` (bp-judge.pl:52), so any
# other value strands them. Provenance is kept in a separate field instead.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/bp-judge.pl";

my $SRC = do { open my $f, '<', "$S/bp-answer-decision.pl" or die; local $/; <$f> };

# ---- the predicate this bug lives in ---------------------------------------
# Pinned first, because the fix is only correct while this is how firing works.
is(BpJudge::want_harvest_audit({ mode=>'audit', status=>'done', harvest=>'', inflight=>0 }), 1,
   'an empty harvest on a done package FIRES the audit — this is what accept left behind');
is(BpJudge::want_harvest_audit({ mode=>'audit', status=>'done', harvest=>'pass', inflight=>0 }), 0,
   "...and a settled harvest does not");
is(BpJudge::want_harvest_gate({ mode=>'gate', status=>'done', harvest=>'pass', inflight=>0 }), 0,
   'gate mode likewise treats pass as settled');

# ---- gate-mode admission is why the value must be exactly 'pass' -----------
{
    # BpJudge::gate_admits — in gate mode a done package is admitted only on an
    # exact 'pass'.
    is(BpJudge::gate_admits('gate', 'done', 'pass'), 1,
       "gate mode admits a done package on harvest 'pass'");
    is(BpJudge::gate_admits('gate', 'done', 'accepted'), 0,
       "...and NOT on 'accepted' — which is why accept must write 'pass', not something prettier");
    is(BpJudge::gate_admits('audit', 'done', 'accepted'), 1,
       'audit mode admits regardless, so the trap is gate-mode-only and easy to miss');
}

# ---- the fix, in the source ------------------------------------------------
# bp-answer-decision.pl exits early on many paths and writes the registry
# through BpOrch; driving it end-to-end needs a whole blueprint fixture. What
# must not silently regress is that `accept` settles the field and resets the
# same companions a real pass does, so that is asserted against the applied
# plan directly.
like($SRC, qr/\$plan->\{action\}.{0,20}eq 'accept'/s,
     'accept is special-cased when the registry patch is built');

my ($blk) = $SRC =~ /eq 'accept'\)\s*\{(.*?)\n\s*\}/s;
ok(defined $blk, 'the accept branch is present') or BAIL_OUT('cannot locate the accept branch');

like($blk, qr/\$reg\{harvest\}\s*=\s*'pass'/,
     "accept settles harvest to 'pass' — the value gate mode requires");
for my $f (qw(harvest_reaudit harvest_defer harvest_defer_blockers harvest_starve_continuations)) {
    like($blk, qr/\$reg\{$f\}/,
         "accept also resets $f, mirroring a real pass (a stale counter would resurrect the audit)");
}
like($blk, qr/harvest_settled_by/,
     'provenance is recorded separately, so the record does not claim a judge passed it');

# ---- the companion resets must match what a real pass writes ---------------
# If the orchestrator's real-pass write ever gains a field, this catches the
# drift rather than letting accept quietly settle less than a pass does.
{
    my $orch = do { open my $f, '<', "$S/bp-orchestrator.pl" or die; local $/; <$f> };
    my ($pass_blk) = $orch =~ /harvest\s*=>\s*'pass',\s*harvest_reaudit\s*=>\s*0,(.{0,220})/s;
    ok(defined $pass_blk, 'located the real-pass registry write in bp-orchestrator.pl');
    for my $f (qw(harvest_defer harvest_defer_blockers harvest_starve_continuations)) {
        next unless defined $pass_blk && $pass_blk =~ /\b$f\b/;
        like($blk, qr/\b$f\b/,
             "a real pass resets $f, so accept must too");
    }
}

done_testing();
