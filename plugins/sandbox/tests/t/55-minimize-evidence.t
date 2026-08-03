#!/usr/bin/env perl
# Oracle test for s18-terminal-minimize-spike, derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/s18-terminal-minimize-spike-spec.md
#
# IMMUTABLE ORACLE: written from the spec alone. The implementer writes
# plugins/sandbox/docs/terminal-minimize-investigation.md from the scout
# report (never sees this file); this file is written from the spec (never
# sees the scout report or the implementer's doc). This file is expected to
# FAIL until that document lands, conforming to spec section 2.1-2.8. That is
# the correct, intended state.
#
# HARD BOUNDARY (spec section 3.12, AC-12, section 6): this test reads ONE
# text file and pattern-matches it. It never shells out to launcher.pl,
# podman, powershell.exe, taskkill, or any live-terminal probe, and it never
# claims to verify that a real Windows window actually minimizes -- that
# behavior is structurally unreproducible in this container.
#
# Two coordinator rulings applied here (override spec text where they conflict):
#   1. Section 2.1's "no other H1/H2 may appear between them" is VOID. Per
#      section 5, required headings are matched by presence-in-order, not
#      adjacency; extra H2/H3 sections are permitted and must not fail the
#      test.
#   2. Section 2.3's "exactly these four H3 headings" means these four are
#      REQUIRED, verbatim, in order -- NOT that the total H3 count is 4. No
#      assertion below counts total headings of any level.
#
# Criterion mapping (AC-1 .. AC-12, spec section 4):
#   AC-1  : doc exists on disk
#   AC-2  : H1 + six required H2 headings present, verbatim, in order
#   AC-3  : four required H3 candidate headings present, verbatim, in order
#   AC-4  : each candidate H3 section has >=1 Verdict line, token in the
#           closed vocabulary
#   AC-5  : Candidate 3 body contains "Finding A"; Candidate 4 body contains
#           "Finding E"
#   AC-6  : Reproduction status has a valid Status: token and non-empty Reason:
#   AC-7  : Conclusion has Cause identified: YES|NO; if NO, also Narrowed to:
#           and Evidence needed:
#   AC-8  : Recommended fix has a valid Recommendation: token and the fields
#           required for that branch
#   AC-9  : Follow-on packages has >=2 entries, one mentioning A2, one B2
#   AC-10 : Operator requests has exactly four numbered items, one containing
#           "decisive"
#   AC-11 : this file runs standalone, ends with done_testing(), no fixed plan
#   AC-12 : this file contains no invocation of launcher.pl/podman/
#           powershell.exe/taskkill or any live-terminal probe

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $doc_path = "$Bin/../../docs/terminal-minimize-investigation.md";

# ---------------------------------------------------------------------------
# AC-1 -- the doc must exist. If it does not (or cannot be read), we do NOT
# die -- we fall back to an empty $content so every downstream assertion
# still emits a clean, self-locating "not ok" instead of aborting the run
# with no TAP output (spec section 3.1, observable behavior 1).
# ---------------------------------------------------------------------------
my $doc_exists = -e $doc_path;
ok($doc_exists, "AC-1: terminal-minimize-investigation.md exists on disk ($doc_path)");

my $content = '';
if ($doc_exists) {
    if (open my $fh, '<', $doc_path) {
        local $/;
        $content = <$fh>;
        close $fh;
        $content = '' unless defined $content;
    }
    else {
        ok(0, "AC-1: terminal-minimize-investigation.md could not be opened: $!");
    }
}

# =====================================================================
# AC-2 -- H1 title + six required H2 headings, verbatim, present in order.
# Ruling #1: presence-in-order, NOT adjacency. Extra headings interleaved
# between required ones must not fail this check.
# =====================================================================
my @required_headings = (
    ['H1 title (Terminal minimize investigation)', qr/^# Terminal minimize investigation\s*$/m],
    ['H2 Reproduction status',                     qr/^## Reproduction status\s*$/m],
    ['H2 Candidate verdicts',                      qr/^## Candidate verdicts\s*$/m],
    ['H2 Conclusion',                              qr/^## Conclusion\s*$/m],
    ['H2 Recommended fix',                         qr/^## Recommended fix\s*$/m],
    ['H2 Follow-on packages',                      qr/^## Follow-on packages\s*$/m],
    ['H2 Operator requests',                       qr/^## Operator requests\s*$/m],
);

my @heading_positions;
for my $h (@required_headings) {
    my ($name, $re) = @$h;
    if ($content =~ $re) {
        push @heading_positions, $-[0];
        ok(1, "AC-2: heading '$name' present verbatim");
    }
    else {
        push @heading_positions, undef;
        ok(0, "AC-2: heading '$name' present verbatim");
    }
}

{
    # Do not let a missing heading make this vacuously true: the order claim
    # is only meaningful once every required heading is confirmed present.
    my $all_present = !grep { !defined $_ } @heading_positions;
    my $in_order = $all_present;
    if ($all_present) {
        for my $i (1 .. $#heading_positions) {
            $in_order = 0 if $heading_positions[$i] <= $heading_positions[$i - 1];
        }
    }
    ok($in_order, "AC-2: required H1/H2 headings appear in the correct relative order (adjacency not required)");
}

# =====================================================================
# AC-3 -- the four required H3 candidate headings, verbatim, in order,
# under '## Candidate verdicts'. Ruling #2: this checks these four are
# present in order; it never counts total H3 headings, so an added
# '### Finding C' or similar must not fail this check.
# =====================================================================
my ($cand_section) = $content =~ /^## Candidate verdicts\s*$(.*?)(?=^##[ \t]|\z)/ms;
$cand_section = '' unless defined $cand_section;

my @cand_headings = (
    ['Candidate 1', qr/^### Candidate 1 — keep-awake spawn and lifecycle\s*$/m],
    ['Candidate 2', qr/^### Candidate 2 — native process spawn \/ console flash\s*$/m],
    ['Candidate 3', qr/^### Candidate 3 — window-manipulation escape sequences\s*$/m],
    ['Candidate 4', qr/^### Candidate 4 — external Windows mechanism\s*$/m],
);

my @cand_positions;
for my $h (@cand_headings) {
    my ($name, $re) = @$h;
    if ($cand_section =~ $re) {
        push @cand_positions, $-[0];
        ok(1, "AC-3: $name heading present verbatim under '## Candidate verdicts'");
    }
    else {
        push @cand_positions, undef;
        ok(0, "AC-3: $name heading present verbatim under '## Candidate verdicts'");
    }
}

{
    # Same vacuous-pass hazard as AC-2 above: require every candidate
    # heading to be present before an order claim means anything.
    my $all_present = !grep { !defined $_ } @cand_positions;
    my $in_order = $all_present;
    if ($all_present) {
        for my $i (1 .. $#cand_positions) {
            $in_order = 0 if $cand_positions[$i] <= $cand_positions[$i - 1];
        }
    }
    ok($in_order, "AC-3: the four candidate H3 headings appear in the correct relative order");
}

# =====================================================================
# AC-4 / AC-5 -- per-candidate body: at least one Verdict line whose token
# is in the closed vocabulary (section 2.2); Candidate 3 must contain the
# literal substring 'Finding A', Candidate 4 must contain 'Finding E'.
# =====================================================================
my @closed_verdict_tokens = qw(
    CONFIRMED EXCLUDED-BY-EVIDENCE EXCLUDED-BY-ASSUMPTION
    NOT-EXCLUDED UNTESTED UNVERIFIED-HYPOTHESIS
);
my %is_closed_verdict_token = map { $_ => 1 } @closed_verdict_tokens;

my ($c1_body) = $cand_section =~ /^### Candidate 1 — keep-awake spawn and lifecycle\s*$(.*?)(?=^###[ \t]|\z)/ms;
my ($c2_body) = $cand_section =~ /^### Candidate 2 — native process spawn \/ console flash\s*$(.*?)(?=^###[ \t]|\z)/ms;
my ($c3_body) = $cand_section =~ /^### Candidate 3 — window-manipulation escape sequences\s*$(.*?)(?=^###[ \t]|\z)/ms;
my ($c4_body) = $cand_section =~ /^### Candidate 4 — external Windows mechanism\s*$(.*?)(?=^###[ \t]|\z)/ms;
$_ = '' for grep { !defined $_ } ($c1_body, $c2_body, $c3_body, $c4_body);
$c1_body //= ''; $c2_body //= ''; $c3_body //= ''; $c4_body //= '';

for my $cand (
    ['Candidate 1', $c1_body],
    ['Candidate 2', $c2_body],
    ['Candidate 3', $c3_body],
    ['Candidate 4', $c4_body],
) {
    my ($name, $body) = @$cand;
    my @tokens;
    while ($body =~ /^Verdict(?:\s*\([^)]+\))?:\s*(\S+)\s*$/mg) {
        push @tokens, $1;
    }
    ok(scalar(@tokens) >= 1, "AC-4: $name carries at least one Verdict:/Verdict (label): line");
    if (@tokens) {
        for my $tok (@tokens) {
            ok($is_closed_verdict_token{$tok}, "AC-4: $name verdict token '$tok' is drawn from the closed vocabulary");
        }
    }
    else {
        ok(0, "AC-4: $name verdict token is drawn from the closed vocabulary (no Verdict line found)");
    }
}

like($c3_body, qr/Finding A/, "AC-5: Candidate 3 body contains the literal substring 'Finding A'");
like($c4_body, qr/Finding E/, "AC-5: Candidate 4 body contains the literal substring 'Finding E'");

# =====================================================================
# AC-6 -- Reproduction status: valid Status: token, non-empty Reason:.
# =====================================================================
my ($repro_body) = $content =~ /^## Reproduction status\s*$(.*?)(?=^##[ \t]|\z)/ms;
$repro_body //= '';

ok($repro_body =~ /^Status:\s*(?:REPRODUCED|NOT-REPRODUCED|PARTIALLY-REPRODUCED)\s*$/m,
    "AC-6: '## Reproduction status' contains a Status: line with a token from the closed set");

{
    my ($reason) = $repro_body =~ /^Reason:[ \t]*(.+?)\s*$/m;
    ok(defined $reason && length $reason, "AC-6: '## Reproduction status' contains a non-empty Reason: line");
}

# =====================================================================
# AC-7 -- Conclusion: Cause identified: YES|NO; if NO, also non-empty
# Narrowed to: and Evidence needed:.
# =====================================================================
my ($concl_body) = $content =~ /^## Conclusion\s*$(.*?)(?=^##[ \t]|\z)/ms;
$concl_body //= '';

my $cause_ok = ($concl_body =~ /^Cause identified:\s*(YES|NO)\s*$/m);
my $cause    = $cause_ok ? $1 : undef;
ok($cause_ok, "AC-7: '## Conclusion' contains 'Cause identified: YES|NO'");

SKIP: {
    skip "Cause identified: YES -- 'Narrowed to:'/'Evidence needed:' not required by section 2.5", 2
        if $cause_ok && $cause eq 'YES';
    skip "Cause identified: line missing or invalid -- cannot evaluate the NO-branch fields", 2
        unless $cause_ok;

    my ($narrowed) = $concl_body =~ /^Narrowed to:[ \t]*(.+?)\s*$/m;
    ok(defined $narrowed && length $narrowed, "AC-7: Cause identified: NO -> non-empty 'Narrowed to:' line present");

    my ($evidence) = $concl_body =~ /^Evidence needed:[ \t]*(.+?)\s*$/m;
    ok(defined $evidence && length $evidence, "AC-7: Cause identified: NO -> non-empty 'Evidence needed:' line present");
}

# =====================================================================
# AC-8 -- Recommended fix: valid Recommendation: token, and the fields
# required for that branch (Files:/Mechanism:/Risk: for FIX; Rationale:
# for CLOSE-AS-OUT-OF-SCOPE).
# =====================================================================
my ($fix_body) = $content =~ /^## Recommended fix\s*$(.*?)(?=^##[ \t]|\z)/ms;
$fix_body //= '';

my $rec_ok  = ($fix_body =~ /^Recommendation:\s*(FIX|CLOSE-AS-OUT-OF-SCOPE)\s*$/m);
my $rec_tok = $rec_ok ? $1 : undef;
ok($rec_ok, "AC-8: '## Recommended fix' contains 'Recommendation: FIX|CLOSE-AS-OUT-OF-SCOPE'");

SKIP: {
    skip "Recommendation: CLOSE-AS-OUT-OF-SCOPE -- Files:/Mechanism:/Risk: not required", 3
        if $rec_ok && $rec_tok eq 'CLOSE-AS-OUT-OF-SCOPE';
    skip "Recommendation: line missing or invalid -- cannot evaluate the FIX-branch fields", 3
        unless $rec_ok;

    my ($files) = $fix_body =~ /^Files:[ \t]*(.+?)\s*$/m;
    ok(defined $files && length $files, "AC-8: Recommendation: FIX -> non-empty 'Files:' line present");

    my ($mechanism) = $fix_body =~ /^Mechanism:[ \t]*(.+?)\s*$/m;
    ok(defined $mechanism && length $mechanism, "AC-8: Recommendation: FIX -> non-empty 'Mechanism:' line present");

    my ($risk) = $fix_body =~ /^Risk:[ \t]*(.+?)\s*$/m;
    ok(defined $risk && length $risk, "AC-8: Recommendation: FIX -> non-empty 'Risk:' line present");
}

SKIP: {
    skip "Recommendation: FIX -- Rationale: not required", 1
        if $rec_ok && $rec_tok eq 'FIX';
    skip "Recommendation: line missing or invalid -- cannot evaluate the CLOSE-branch field", 1
        unless $rec_ok;

    my ($rationale) = $fix_body =~ /^Rationale:[ \t]*(.+?)\s*$/m;
    ok(defined $rationale && length $rationale,
        "AC-8: Recommendation: CLOSE-AS-OUT-OF-SCOPE -> non-empty 'Rationale:' line present");
}

# =====================================================================
# AC-9 -- Follow-on packages: >=2 '### Follow-on:' entries, and (spec
# section 2.7) EACH entry individually must carry non-empty 'Defect:',
# 'Fix sketch:' and 'Files:' lines -- not just the section as a whole,
# which would let one entry carry both the 'A2'/'B2' markers while a
# second entry is an empty stub. 'A2'/'B2' are likewise matched per
# entry, not section-wide, so a stub entry cannot ride along on a
# marker that actually lives in a different, well-formed entry.
# =====================================================================
my ($followon_body) = $content =~ /^## Follow-on packages\s*$(.*?)(?=^##[ \t]|\z)/ms;
$followon_body //= '';

my @followon_entries = $followon_body =~ /^(### Follow-on:[ \t]*\S.*?)(?=^### Follow-on:[ \t]*\S|\z)/msg;

ok(scalar(@followon_entries) >= 2,
    "AC-9: '## Follow-on packages' has at least two '### Follow-on:' entries (found " . scalar(@followon_entries) . ")");

my ($any_a2, $any_b2) = (0, 0);
for my $i (0 .. $#followon_entries) {
    my $entry = $followon_entries[$i];
    my $label = "entry " . ($i + 1);

    my ($defect) = $entry =~ /^Defect:[ \t]*(.+?)\s*$/m;
    ok(defined $defect && length $defect, "AC-9: Follow-on $label has a non-empty 'Defect:' line");

    my ($sketch) = $entry =~ /^Fix sketch:[ \t]*(.+?)\s*$/m;
    ok(defined $sketch && length $sketch, "AC-9: Follow-on $label has a non-empty 'Fix sketch:' line");

    my ($files) = $entry =~ /^Files:[ \t]*(.+?)\s*$/m;
    ok(defined $files && length $files, "AC-9: Follow-on $label has a non-empty 'Files:' line");

    $any_a2 = 1 if $entry =~ /A2/;
    $any_b2 = 1 if $entry =~ /B2/;
}

ok($any_a2, "AC-9: at least one well-formed follow-on entry mentions the literal substring 'A2'");
ok($any_b2, "AC-9: at least one well-formed follow-on entry mentions the literal substring 'B2'");

# =====================================================================
# AC-10 -- Operator requests: exactly four numbered items (1. .. 4.), at
# least one containing 'decisive'.
# =====================================================================
my ($operator_body) = $content =~ /^## Operator requests\s*$(.*?)(?=^##[ \t]|\z)/ms;
$operator_body //= '';

my @item_nums;
while ($operator_body =~ /^(\d+)\.[ \t]+\S/mg) {
    push @item_nums, $1;
}
ok(scalar(@item_nums) == 4, "AC-10: '## Operator requests' has exactly four numbered items (found " . scalar(@item_nums) . ")");
is_deeply([ sort { $a <=> $b } @item_nums ], [ 1, 2, 3, 4 ],
    "AC-10: the four numbered items are exactly 1., 2., 3., 4.");
like($operator_body, qr/decisive/, "AC-10: at least one operator-request item contains the word 'decisive'");

# =====================================================================
# AC-11 / AC-12 -- this test file's own shape (satisfied by construction;
# reasserted here against our own source, without contorting the checks).
# =====================================================================
{
    open my $fh, '<', $0 or die "cannot reopen own test file $0: $!";
    my @lines = <$fh>;
    close $fh;
    my @nonblank = grep { $_ !~ /^\s*$/ } @lines;
    like($nonblank[-1], qr/^\s*done_testing\(\);\s*$/,
        "AC-11: t/55-minimize-evidence.t ends with done_testing() (no fixed plan)");

    my $own_source = join('', @lines);
    ok($own_source !~ /^\s*plan\s*\(/m && $own_source !~ /^\s*plan\s+tests\b/m,
        "AC-11: t/55-minimize-evidence.t declares no fixed Test::More plan");

    # Phrased/escaped to avoid this very check matching its own description
    # text or its own pattern source (a backtick character used as a regex
    # delimiter would otherwise trip the backtick check on itself).
    ok($own_source !~ /\bsystem\s*\(/,          "AC-12: t/55 contains no shell-out via the system builtin");
    ok($own_source !~ /\x60[^\x60]*\x60/,       "AC-12: t/55 contains no backtick command substitution");
    ok($own_source !~ /\bqx\s*[\/({]/,          "AC-12: t/55 contains no qx-style command substitution");
    ok($own_source !~ /\bexec\s*\(/,            "AC-12: t/55 contains no exec builtin call");
}

# =====================================================================
# s20 EXTENSION -- C1..C6, per
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/
#   s20-minimize-evidence-completion-spec.md section 3.
#
# s18 documented operator evidence pieces 1 and 2 but omitted piece 3 (the
# operator has seen the minimize BOTH while actively using the machine AND
# while away from it), which excludes a candidate (wt.exe -w new) and
# reshapes the candidate list. This block is ADDITIVE ONLY: it does not
# touch any assertion above. $content (the whole document, or '' if the
# doc is missing/unreadable) and $operator_body (the '## Operator requests'
# section body) are reused from the AC-1..AC-12 block above, in scope here.
#
# Vacuity gate (spec section 3, "Vacuity gate"): C1 checks both halves of
# piece 3, not the bare word "computer"; C3 asserts a negative (Dashboard.pm
# NOT credited) alongside the positive corrected attribution; C5 asserts
# the QUESTION FORM is absent, not merely that some "answered" marker
# string appears. Each assertion names the file it read.
# =====================================================================

# ---------------------------------------------------------------------
# C1 -- piece 3 appears in substance: BOTH the active-use half and the
# away half, not as a passing mention of the word "computer".
# ---------------------------------------------------------------------
{
    my $active_half = ($content =~ /\bwhile\b.{0,60}\busing\s+the\s+computer\b/is);
    ok($active_half,
        "C1: piece 3's ACTIVE-use half present in substance (\"...using the computer...\") "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    my $away_half = ($content =~ /\b(?:leave|left)\b.{0,40}\bcomputer\b.{0,60}\bcome\s+back\b.{0,120}\bminimiz\w*/is);
    ok($away_half,
        "C1: piece 3's AWAY half present in substance (\"...leave the computer and come back...minimized...\") "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
}

# ---------------------------------------------------------------------
# C2 -- wt.exe -w new recorded as EXCLUDED, with its basis being BOTH
# halves of the piece-3 testimony (not just "no window appears on top"),
# and the earlier reporter note ("this candidate may outrank the others")
# recorded as RETRACTED. Scoped to $c2_body (already extracted above for
# AC-4/AC-5) so a match elsewhere in the document -- e.g. the unrelated
# "both halves" occurring in Finding C's discussion of a byte channel --
# cannot vacuously satisfy this.
# ---------------------------------------------------------------------
{
    like($c2_body, qr/wt\.exe/i,
        "C2: the wt.exe sub-finding is present under Candidate 2 "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    like($c2_body, qr/excluded/i,
        "C2: wt.exe is recorded as excluded "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    like($c2_body, qr/both\s+halves/i,
        "C2: the exclusion basis is framed as BOTH halves of the operator's testimony "
        . "(not merely 'no window on top'), scoped to Candidate 2's own body so the "
        . "unrelated 'both halves' in Finding C's byte-channel discussion cannot satisfy this "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    like($c2_body, qr/earlier\s+reporter\s+note/i,
        "C2: an 'earlier reporter note' about wt.exe is named "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    like($c2_body, qr/outrank/i,
        "C2: the earlier note's claim ('may outrank the others') is named "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    like($c2_body, qr/retract/i,
        "C2: the earlier reporter note is recorded as RETRACTED "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
}

# ---------------------------------------------------------------------
# C3 -- the timer-driven explanation is anchored to launcher.pl BY
# PATTERN (the $last_inspect guard shape), not merely by a line number
# that DECOMPOSED.md warns "moves". Positive: the pattern-anchor appears
# in the doc, and the guard shape genuinely exists in launcher.pl today.
# Negative (the corrected-attribution point, per the vacuity gate): the
# doc does NOT credit Dashboard.pm with this guard, and Dashboard.pm's
# own source does not define $last_inspect at all -- confirming the
# correction record's re-verification.
# ---------------------------------------------------------------------
{
    my $launcher_path = "$Bin/../../scripts/launcher.pl";
    my $launcher_src  = '';
    if (open my $fh, '<', $launcher_path) {
        local $/;
        $launcher_src = <$fh>;
        close $fh;
    }
    ok(defined $launcher_src && length $launcher_src,
        "C3 sanity: launcher.pl is readable [plugins/sandbox/scripts/launcher.pl]");
    # RETARGETED 2026-08-03 (SYN-21: a documented, owned consequence of a
    # mandated feature). This pinned the literal cadence value 10. s17's done criteria
    # MANDATE replacing that cadence with a named constant precisely so the
    # value is tunable and greppable, and it now reads
    # a named constant instead. Pinning the VALUE was the wrong assertion in
    # the first place -- it is the same global-snapshot mistake that has broken
    # other oracles in this blueprint, because it forbids the very change
    # another package was required to make.
    #
    # What C3 actually needs is that the guard SHAPE exists, since the document
    # anchors its claim on the per-tick guard identifier in launcher.pl. So:
    # accept a literal or a named constant, and keep everything else exact.
    #
    # NOTE: this file's own AC-12 greps itself for backtick command
    # substitution, so comments here must not contain a backtick -- an earlier
    # version of this note did, and tripped it.
    like($launcher_src, qr/if\s*\(\s*\$now\s*-\s*\$last_inspect\s*>=\s*(?:\d+|\$[A-Za-z_]\w*)\s*\)/,
        "C3 sanity: the \$last_inspect guard shape genuinely exists in launcher.pl today "
        . "[plugins/sandbox/scripts/launcher.pl]");

    my $dashboard_path = "$Bin/../../scripts/Dashboard.pm";
    my $dashboard_src  = '';
    if (open my $fh, '<', $dashboard_path) {
        local $/;
        $dashboard_src = <$fh>;
        close $fh;
    }
    ok(defined $dashboard_src && length $dashboard_src,
        "C3 sanity: Dashboard.pm is readable [plugins/sandbox/scripts/Dashboard.pm]");
    unlike($dashboard_src, qr/last_inspect/,
        "C3 sanity: Dashboard.pm does NOT define \$last_inspect at all -- the guard genuinely "
        . "lives only in launcher.pl [plugins/sandbox/scripts/Dashboard.pm]");

    # Positive: the document anchors the candidate by PATTERN (the
    # $last_inspect identifier / guard shape), tied to launcher.pl, not
    # solely by a bare line-number citation.
    like($content, qr/last_inspect/,
        "C3 positive: the document anchors the timer candidate by PATTERN "
        . "(references \$last_inspect), not merely by a line number that moves "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    like($content, qr/launcher\.pl.{0,200}last_inspect|last_inspect.{0,200}launcher\.pl/is,
        "C3 positive: the \$last_inspect pattern anchor is tied to launcher.pl in the document "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    # Negative: the document must NOT attribute the guard/timer candidate
    # to Dashboard.pm -- that misattribution is exactly the error this
    # package corrects (DECOMPOSED.md TUI-03's "re-verify by pattern" note).
    unlike($content, qr/Dashboard\.pm.{0,120}(?:last_inspect|per-tick\s+native-binary\s+spawn|10s?\s*inspect\s+guard)/is,
        "C3 negative: the document does NOT credit Dashboard.pm with the timer/inspect guard "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    unlike($content, qr/Dashboard\.pm:3374/,
        "C3 negative: the document does not cite 'Dashboard.pm:3374' for the timer candidate "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
}

# ---------------------------------------------------------------------
# C4 -- the "cannot be the normal path -> must be failure/retry -> s17's
# Can't fork" chain is present, together with the testable prediction
# (correlate with fork-failure events, not with ticks).
# ---------------------------------------------------------------------
{
    like($content, qr/cannot\s+be\s+the\s+normal\s+path|would\s+minimiz\w*.{0,20}every.{0,10}10\s*s/is,
        "C4: the document states the timer candidate cannot be the NORMAL path "
        . "(or the window would minimize every ~10s) "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    like($content, qr/failure(?:\s*\/\s*|\s+or\s+)retry\s+path|failure\s+or\s+retry/is,
        "C4: the document names it a FAILURE/RETRY path instead "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    like($content, qr/(?:failure\s+or\s+retry|retry\s+path).{0,300}(?:s17|Can't fork)|(?:s17|Can't fork).{0,300}(?:failure\s+or\s+retry|retry\s+path)/is,
        "C4: the failure/retry attribution is tied to s17's Can't fork diagnosis "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    like($content, qr/correlat\w*.{0,200}fork.failure/is,
        "C4: a testable prediction is stated -- minimizes correlate with fork-failure events "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    like($content, qr/correlat\w*.{0,250}\bnot\b.{0,40}\bticks?\b/is,
        "C4: the testable prediction contrasts fork-failure correlation with TICKS, not just ticks in general "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
}

# ---------------------------------------------------------------------
# C5 -- the answered questions are gone or marked answered. Per the
# vacuity gate, this asserts the QUESTION FORM IS ABSENT document-wide
# (not scoped only to '## Operator requests', since the same question
# text also currently appears in '## Conclusion'), rather than merely
# checking for the word "answered" somewhere.
# ---------------------------------------------------------------------
{
    unlike($content, qr/does\s+the\s+minimize\s+coincide\s+with\s+something\s+(?:you\s+did|the\s+operator\s+did)/is,
        "C5: the document no longer ASKS whether the minimize coincides with something the operator did "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    unlike($content, qr/(?:or\s+)?does\s+it\s+happen\s+while\s+the\s+dashboard\s+sits\s+idle/is,
        "C5: the document no longer ASKS whether it happens while the dashboard sits idle "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    unlike($content, qr/whether\s+(?:you\s+were|the\s+operator\s+was)\s+away\s+from\s+the\s+machine/is,
        "C5: the document no longer ASKS whether the operator was away from the machine "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    unlike($content, qr/away\s+from\s+the\s+machine\s+for\s+(?:more\s+than\s+)?~?\s*10\s*min/is,
        "C5: the document no longer ASKS about the ~10-minute away threshold as an open question "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
}

# ---------------------------------------------------------------------
# C6 -- the headline next step is INSTRUMENTATION, not another operator
# question.
# ---------------------------------------------------------------------
{
    my ($headline) = $content =~ /\[Headline next step\](.*?)(?=\n\s*\d+\.[ \t]|\n##|\z)/ms;
    ok(defined $headline && length $headline,
        "C6: a '[Headline next step]' item exists in the document "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");

    my $headline_text = defined $headline ? $headline : '';
    like($headline_text, qr/instrumentation/i,
        "C6: the headline next step names INSTRUMENTATION "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
    unlike($headline_text, qr/does\s+the\s+minimize\s+coincide|does\s+it\s+happen\s+while\s+the\s+dashboard\s+sits\s+idle/is,
        "C6: the headline next step is no longer phrased as the old coincide/idle question "
        . "[plugins/sandbox/docs/terminal-minimize-investigation.md]");
}

done_testing();
