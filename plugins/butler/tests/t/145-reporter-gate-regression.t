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

    my ($plan) = $out =~ /^1\.\.(\d+)\s*$/m;
    is($plan, 33,
       'A2 CANONICAL: t/94\'s own test PLAN count is exactly 33 — the pre-package baseline '
     . 'recorded before this package\'s first edit. A regression that adds, removes, or '
     . '(more subtly) SILENTLY SKIPS one of t/94\'s existing assertions changes this number '
     . 'even if the file\'s own exit code stays 0.');

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
my %baseline = (
    '112-subagent-stall-guard.t'      => 51,
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
       "B2 CANONICAL ($name): plan count is at least $baseline{$name}, the recorded "
     . "pre-package baseline — this package's --surface widening on bp-runstate.pl and "
     . "any reporter-branch insertion into gate-drive-loop.sh/mark-wakeup.sh must not "
     . "remove or silently skip any of this file's own pre-existing assertions");

    my @not_ok = ($out =~ /^not ok /mg);
    is(scalar(@not_ok), 0, "B3 ($name): zero \"not ok\" lines");
}

done_testing();
