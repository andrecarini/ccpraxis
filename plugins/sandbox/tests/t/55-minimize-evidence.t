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

done_testing();
