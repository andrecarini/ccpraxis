#!/usr/bin/env perl
# 145-reporter-gate-regression.t — g03-reporter-stop-gate, DC5/DC8: the
# reporter branch must not weaken the driver's existing stop discipline, and
# the pre-existing oracle suite must be re-measured against the SAME pass
# counts after this package's edits land.
#
# Spec: specs/g03-reporter-stop-gate-spec.md §4 AC6, AC9.
#
# WHAT THIS FILE DOES NOT DO. AC6 explicitly frames itself as "a diff-and-
# rerun check, not a 'the file wasn't edited' check" — t/94-drive-loop-gate.t
# itself is READ-ONLY ground truth (per t/137's own precedent, which already
# established this house convention for a sibling package) and is NEVER
# copied or duplicated here. Section A below runs the actual, unmodified file
# as a real subprocess and asserts its own pass/fail shape — the strongest
# available proxy for "unmodified behavior", short of literally diffing the
# file (which a `docs-consistency`/`shell-syntax` check elsewhere in this
# package's `checks:` line already covers for the file's TEXT never having
# been edited at all).
#
# AC9 (full two-suite green baseline) is a PROCESS criterion, not a per-file
# oracle: recording it against the ~200 files across plugins/butler/tests and
# plugins/sandbox/tests inside a single .t file would be prohibitively slow
# and duplicates work the validation step (pipeline step 5) already owns.
# Section B narrows this to the SPECIFIC files this package's own ledger and
# dispatch prompt name as "MUST STAY GREEN" — the ones this package's diff
# can plausibly touch — re-measured here as a concrete regression tripwire,
# with the full-suite baseline recorded in this file's own test-writer
# report instead (see report §"baseline", captured BEFORE any implementation
# edit, matching this file's own git-untouched state at write time).
#
# WHY THIS FILE IS SLOW, AND WHY THAT IS NOT BEING "FIXED". Measured standalone
# 2026-08-26: 52s, of which 50s is the four child files (t/94 13s, t/112 21s,
# t/120 5s, t/137 11s). It is therefore ~100% child re-execution — and the sweep
# already runs all four directly, so A1/A3/B1/B3 (exit 0, zero "not ok")
# duplicate work the sweep does anyway.
#
# That is the same shape removed from t/166-statusline-marker-glyph.t, but it is
# NOT the same case, and the difference is the whole reason this stays: t/166's
# nested runs added no assertion the sweep did not already make. Here A2/B2 pin
# each child's PLAN COUNT, and a plan count under done_testing() cannot be known
# without running the file. Delete the runs and the floors go with them.
#
# The cheap alternative was considered and rejected: have scripts/run-tests.pl
# record plan counts and have this file read them. That buys ~50s of a ~405s
# sweep in exchange for a cache whose staleness rule is a new way to pass
# wrongly — a bad trade for a CANONICAL oracle. Revisit only if the sweep's tail
# becomes the binding constraint.
#
# Runs standalone: perl plugins/butler/tests/t/145-reporter-gate-regression.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $T = "$Bin";

# ---------------------------------------------------------------------------
# A. AC6 CANONICAL: t/94-drive-loop-gate.t, run UNMODIFIED, is green with the
#    SAME pass count it had on the pre-package baseline (33). DC5 names this
#    file explicitly; its count must not regress AT ALL, not merely "stay
#    approximately green".
# ---------------------------------------------------------------------------
{
    my $file = "$T/94-drive-loop-gate.t";
    ok(-f $file, 'A0: t/94-drive-loop-gate.t exists (sanity — DC5 has nothing to pin '
              . 'without it)') or BAIL_OUT('t/94 missing entirely');

    my $out = `perl "$file" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'A1 CANONICAL (-> AC6/DC5): t/94-drive-loop-gate.t, run as an unmodified '
             . 'subprocess, exits 0 (Test::More\'s convention for "no failures")');

    # A FLOOR, NOT AN EQUALITY. The baseline was 33; the guard is against LOSS.
    #
    # An exact count also fails when someone STRENGTHENS t/94, which is the
    # opposite of what this file exists to protect and turns every legitimate
    # new assertion into a red test in an unrelated package. That has now cost
    # time twice — this pin and the t/112 pin below, changed for the same reason
    # on the same grounds — so it is worth naming the general rule: an oracle
    # that pins a count must pin the direction it cares about, or it treats
    # improvement as breakage.
    #
    # The cost is stated honestly: a change that deletes one assertion and adds
    # two passes here. A3's zero-"not ok" check and A1's exit code are what
    # catch a silent skip; they do not depend on this number.
    # RE-BASELINED 2026-08-26: 33 -> 39. A floor only has teeth while it sits at
    # the file's actual count; every legitimate assertion added since widens the
    # gap it will tolerate before firing. At 33 against an actual 39 this had
    # already gone slack by six. Re-baselining is the maintenance action the
    # "honest cost of the floor" note in section B describes but never scheduled,
    # so it is done here for both floors at once. Both of t/94's and t/112's SKIP
    # blocks use the COUNTED form (`skip 'reason', N`), which emits its N `ok #
    # skip` lines either way — so the plan count does not move with the
    # environment and a tight floor cannot go red on a machine that lacks
    # bp-runstate.pl.
    my ($plan) = $out =~ /^1\.\.(\d+)\s*$/m;
    cmp_ok($plan, '>=', 39,
       'A2 CANONICAL: t/94\'s own test PLAN count is at least 39 — its count as re-baselined, '
     . 'from a pre-package baseline of 33. Assertions may be ADDED; losing one is '
     . 'the regression, and a silent skip shows up here as a shortfall.');

    my @not_ok = ($out =~ /^not ok /mg);
    is(scalar(@not_ok), 0,
       'A3: zero "not ok" lines in t/94\'s own output — DC5\'s "not weakened" claim means '
     . 'every one of its existing 33 assertions individually still passes, not merely that '
     . 'the file as a whole exits 0');
}

# ---------------------------------------------------------------------------
# B. The other three MUST-STAY-GREEN files this package's own write set can
#    plausibly perturb (mark-wakeup.sh, gate-drive-loop.sh, bp-runstate.pl),
#    re-measured against their OWN recorded pre-package plan counts.
# ---------------------------------------------------------------------------
#
# RE-BASELINED 2026-08-26 to each file's actual count (112: 51 -> 67; 120 and 137
# were already tight at 21 and 12). See the note on A2 for why this is safe with
# respect to SKIP blocks, and the "honest cost" note below for why it was needed.
my %baseline = (
    '112-subagent-stall-guard.t'      => 67,
    '120-mark-wakeup-agent-dispatch.t'=> 21,
    '137-drive-loop-runstate-fold.t'  => 12,
);

for my $name (sort keys %baseline) {
    my $file = "$T/$name";
    ok(-f $file, "B0 ($name): file exists") or next;

    my $out = `perl "$file" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, "B1 ($name): exits 0, run as an unmodified subprocess");

    # AMENDED BY t07-needs-you-lifecycle (blueprint tui-operator-feedback).
    #
    # This was `is($plan, $baseline)` -- an EXACT count -- and it fired when t07
    # added eleven assertions to 112-subagent-stall-guard.t covering the
    # pending-set lifecycle it fixes (almanac 20260819-014748-0b41).
    #
    # THE INTENT IS IN THE DESCRIPTION AND IT IS ABOUT LOSS, not about the file
    # being frozen: "must not add, remove, or silently skip any of this file's
    # own PRE-EXISTING assertions". A later package legitimately growing that
    # file is not the failure this guards against; a package silently dropping
    # or skipping assertions is. A floor expresses that and an equality does
    # not.
    #
    # THE HONEST COST OF THE FLOOR, stated rather than glossed: once the file
    # grows past its baseline, a floor can no longer detect a single lost
    # assertion offset by a single added one. It still detects net loss, which
    # is the failure mode with teeth. This is exactly the correction package
    # d01 of the predecessor initiative made to t/163's own `is(scalar(@all_t),
    # 132)` for the same reason, and it is at least the fifth time in two
    # initiatives that an exact count has treated a legitimate new state as
    # breakage.
    my ($plan) = $out =~ /^1\.\.(\d+)\s*$/m;
    cmp_ok($plan, '>=', $baseline{$name},
       "B2 CANONICAL ($name): plan count is at least $baseline{$name}, its count as of the "
     . "last re-baselining — this package's --surface widening on bp-runstate.pl and "
     . "any reporter-branch insertion into gate-drive-loop.sh/mark-wakeup.sh must not "
     . "remove or silently skip any of this file's own pre-existing assertions");

    my @not_ok = ($out =~ /^not ok /mg);
    is(scalar(@not_ok), 0, "B3 ($name): zero \"not ok\" lines");
}

done_testing();
