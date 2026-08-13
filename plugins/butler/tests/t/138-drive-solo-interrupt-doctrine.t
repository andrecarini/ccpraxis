#!/usr/bin/env perl
# 138-drive-solo-interrupt-doctrine.t — IMMUTABLE ORACLE for w02's SKILL.md
# doctrine changes to plugins/butler/skills/drive-solo/SKILL.md: the
# per-dispatch budget stamp (§2.4 step 1), the interrupt-and-report move
# positioned between waiting and killing (§2.4 step 4, Decision 8,
# criterion 4/5), and the "Known residual" paragraph's replacement (§2.4
# step 5), which t/135-bp-watch-doctrine.t does NOT pin (confirmed by the
# architect's own re-read, spec §2.1 "SKILL.md consequence").
#
# Spec: .../specs/w02-dispatch-budget-and-interrupt-spec.md §2.4, §3
# behaviors 13-14, §4 AC4 (documented move + canonical prompt — the
# BEHAVIORAL half, "the worker actually returns promptly", is explicitly
# NOT mechanically testable and is not attempted here), AC5 (imperative
# "do not defer again" framing — whether a future driver actually OBEYS it
# is likewise not testable and not attempted here).
#
# This file reads plugins/butler/skills/drive-solo/SKILL.md as TEXT only —
# no require, no execution — the same posture t/135 already uses for this
# file. It is written against the file's CURRENT (pre-w02) content, so most
# assertions below are RED today by construction: the interrupt doctrine,
# the bp-dispatch-log.pl stamp, and the residual-paragraph replacement do
# not exist yet. Recorded per-assertion, not assumed.
#
# Runs standalone: perl plugins/butler/tests/t/138-drive-solo-interrupt-doctrine.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $SKILL = "$Bin/../../skills/drive-solo/SKILL.md";
ok(-f $SKILL, 'A0: drive-solo/SKILL.md exists');

my $content = do {
    local $/;
    open my $fh, '<', $SKILL or die "read SKILL.md: $!";
    <$fh>;
};
ok(defined $content && length $content, 'A1: drive-solo/SKILL.md is readable');

# ===========================================================================
# B (behavior 13a). The "Arm the watcher" section stamps the dispatch with
# bp-dispatch-log.pl start, foreground, BEFORE the bp-watch.pl arm — Decision
# 7's "elapsed time measured driver-side, from launch".
# ===========================================================================
my ($arm_section) = $content =~ /(^## Arm the watcher.*?)(?=^## |\z)/ms;
$arm_section //= '';
ok(length($arm_section), 'B0: the "## Arm the watcher" section exists (sanity anchor for '
                        . 'every positional assertion below)');
like($arm_section, qr/bp-dispatch-log\.pl\s+start\b/,
     'B1 (behavior 13a / criterion 1,2): "## Arm the watcher" contains the literal '
   . '"bp-dispatch-log.pl start" invocation — the per-dispatch stamp, taken from the '
   . 'driver\'s own clock');
like($arm_section, qr/--budget-seconds/,
     'B2 (criterion 1): the stamp names --budget-seconds explicitly (not left to the '
   . 'CLI default alone) — §2.4 step 1\'s documented practice');

# ===========================================================================
# C (behavior 13b / AC4). The canonical interrupt-and-report prompt is
# present, POSITIONED between the exit-code (wait/re-arm) table and the
# existing "re-dispatch the wedged worker" kill guidance — Decision 8,
# criterion 4/5: interrupt sits explicitly BETWEEN waiting and killing, not
# merely present somewhere in the file.
#
# Landmark choice: the table's LAST row (STATUS-CHANGE) is unambiguous and
# already present today; "re-dispatch the wedged worker" appears TWICE in
# the CURRENT file — once INSIDE the table itself (the WORKERS-GONE row's
# own "what to do" cell) and once in the prose paragraph that follows the
# table. The doctrine must land strictly AFTER the table closes and
# strictly BEFORE that PROSE occurrence (the one outside the table) — so
# this assertion anchors on the table's closing landmark, then looks for
# the FIRST "re-dispatch the wedged worker" AFTER that point, which is
# necessarily the prose occurrence, not the in-table one.
# ===========================================================================
my $table_end_idx = index($arm_section, 'STATUS-CHANGE');
ok($table_end_idx >= 0,
   'C0: the exit-code table\'s STATUS-CHANGE row is present (landmark for positioning)');

if ($table_end_idx >= 0) {
    my $after_table = substr($arm_section, $table_end_idx);
    my $prompt_idx     = index($after_table, 'STOP ITERATING AND REPORT NOW');
    my $redispatch_idx = index($after_table, 're-dispatch the wedged worker');

    ok($prompt_idx >= 0,
       'C1 CANONICAL (behavior 13b / AC4): the canonical interrupt prompt\'s opening line '
     . '("STOP ITERATING AND REPORT NOW") is present after the exit-code table');
    ok($redispatch_idx >= 0,
       'C2: the "re-dispatch the wedged worker" kill guidance is still present after the '
     . 'table (sanity — it must survive w02\'s edit, just relocated relative to the prompt)');
    if ($prompt_idx >= 0 && $redispatch_idx >= 0) {
        ok($prompt_idx < $redispatch_idx,
           'C3 CANONICAL (behavior 13b / criterion 4): the interrupt prompt is positioned '
         . 'BEFORE "re-dispatch the wedged worker" — interrupt-and-report sits explicitly '
         . 'BETWEEN waiting (the table) and killing (re-dispatch), never after killing');
    } else {
        fail('C3: cannot check ordering — one or both landmarks missing');
    }
}

# ===========================================================================
# D (AC4). The prompt's four structural elements must survive verbatim (or
# the spec's own "tested improvement" — but nothing in this package
# proposes one, so this pins the spec's literal text): stop iterating / let
# in-flight work finish / report state verbatim / do not keep trying to fix.
# ===========================================================================
like($content, qr/STOP ITERATING AND REPORT NOW/,
     'D1 (AC4 element 1/4): "STOP ITERATING AND REPORT NOW" — stop iterating');
like($content, qr/[Ll]et anything currently in flight finish/,
     'D2 (AC4 element 2/4): "let anything currently in flight finish" — do not kill mid-op');
like($content, qr/report immediately/i,
     'D3 (AC4 element 3/4): "report immediately" — a prompt, not a silent kill');
like($content, qr/report the failure verbatim/i,
     'D4 (AC4 element 4/4): "report the failure verbatim" — an accurate accounting, nothing '
   . 'thrown away, per criterion 4\'s "nothing was lost and no context was thrown away"');
like($content, qr/do NOT keep trying to fix it/,
     'D5 (AC4): "do NOT keep trying to fix it" — the worker must not start a fresh cycle on '
   . 'receiving the prompt');

# ===========================================================================
# E (AC5, criterion 5). Imperative doctrine, not descriptive prose: "do not
# defer again" — the report is explicit that FOUR consecutive deferrals is
# a design that fails the same way again; the fix is stated as an
# instruction, not left as an observation.
# ===========================================================================
like($content, qr/do not defer again/i,
     'E1 CANONICAL (AC5 / criterion 5): "do not defer again" — stated as the instruction, '
   . 'not merely described as a past failure mode');

# ===========================================================================
# F (behavior 14). The "Known residual" paragraph naming the gap as OPEN is
# REPLACED, not merely amended — it must no longer read as an open gap once
# the fold (this same package) closes it.
# ===========================================================================
unlike($content, qr/Known residual \(not closed by/,
       'F1 CANONICAL (behavior 14): the "Known residual (not closed by bp-watch.pl alone)" '
     . 'paragraph naming the gap as still-open is GONE — replaced per §2.4 step 5, because '
     . 'the fold (this same package) closes it');
like($content, qr/closed by the fold/i,
     'F2 (behavior 14): the replacement text names the fold as what closes the residual — '
   . 'not simply deleted, but replaced with an accurate closing note');

# ===========================================================================
# G (behavior 15 / AC6, negative check specific to THIS file — the positive
# half lives in coordinator-protocol's own oracle, t/139). drive-solo
# points AT coordinator-protocol for the shared per-package pipeline
# already ("## Read first"); it must not gain a SECOND, competing home for
# the interrupt doctrine's canonical wording.
# ===========================================================================
my @stop_now_hits = $content =~ /STOP ITERATING AND REPORT NOW/g;
is(scalar(@stop_now_hits), 1,
   'G1: the canonical prompt\'s opening line appears exactly ONCE in drive-solo/SKILL.md — '
 . 'not duplicated within the same file (a second, drifted copy is worse than none)');

done_testing();
