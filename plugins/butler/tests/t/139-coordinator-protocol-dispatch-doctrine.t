#!/usr/bin/env perl
# 139-coordinator-protocol-dispatch-doctrine.t — IMMUTABLE ORACLE for w02's
# §2.5 edit to plugins/butler/skills/coordinator-protocol/SKILL.md:
# criterion 6 ("coordination, not a dependency" with e03) is satisfied by
# documenting the dispatch-log bracket and the interrupt doctrine somewhere
# a headless coordinator's own Task dispatch can adopt it from, WITHOUT
# adding a DAG edge and WITHOUT documenting gate-drive-loop.sh here (that
# gate is drive-solo-scoped by construction — coordinator-protocol's own
# stop discipline is gate-stop.sh, untouched by this package).
#
# Spec: .../specs/w02-dispatch-budget-and-interrupt-spec.md §2.5, §3
# behavior 15, §4 AC6. AC6 is explicit that "the doctrine text exists and
# is reusable in principle" is all that is testable — whether e03 actually
# adopts it is that package's business, not assertable here.
#
# Text-only, no execution — same posture as t/135 for drive-solo/SKILL.md.
# Written against the file's CURRENT (pre-w02) content: B1 is RED today by
# construction (the file does not mention bp-dispatch-log.pl at all yet).
# B2/B3 are regression guards that also hold true TODAY (the file mentions
# neither gate-drive-loop.sh nor duplicates the canonical prompt) — they
# are not red-before-green assertions, they are invariants meant to hold
# across the edit, same class as t/137's I1.
#
# Runs standalone:
#   perl plugins/butler/tests/t/139-coordinator-protocol-dispatch-doctrine.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $SKILL = "$Bin/../../skills/coordinator-protocol/SKILL.md";
ok(-f $SKILL, 'A0: coordinator-protocol/SKILL.md exists');

my $content = do {
    local $/;
    open my $fh, '<', $SKILL or die "read SKILL.md: $!";
    <$fh>;
};
ok(defined $content && length $content, 'A1: coordinator-protocol/SKILL.md is readable');

# ===========================================================================
# B1 (behavior 15 / AC6). The per-package worker-dispatch step gains a
# reference to bp-dispatch-log.pl — available uniformly to a headless
# coordinator's Task dispatch, not just the interactive driver's Agent
# dispatch, since both share the same blind spot (§2.5).
# ===========================================================================
like($content, qr/bp-dispatch-log\.pl/,
     'B1 CANONICAL (behavior 15 / AC6): coordinator-protocol/SKILL.md references '
   . 'bp-dispatch-log.pl — the shared budget/elapsed-time mechanism a coordinator\'s own '
   . 'Task dispatch can adopt, per criterion 6\'s "coordination, not a dependency"');

# Positioned near the existing worker-dispatch machinery, not bolted on
# anywhere unrelated in the file. Anchor loosely: from "## Pipeline" (the
# per-package worker-dispatch steps) through to "## Resumption" (the next
# unrelated top-level section) — spans "## Pipeline", "## Worker dispatch
# contract" and its "### Turn caps" subsection, without pinning the exact
# heading the spec did not itself mandate (spec §2.5 says "at the existing
# per-package worker-dispatch step", not a literal heading string).
my ($dispatch_section) = $content =~ /(^## Pipeline\b.*?)(?=^## Resumption\b|\z)/ms;
$dispatch_section //= '';
ok(length($dispatch_section), 'B2: the "## Pipeline" .. "## Resumption" span exists '
                             . '(sanity anchor covering the per-package dispatch machinery)');
if (length $dispatch_section) {
    like($dispatch_section, qr/bp-dispatch-log\.pl/,
         'B3: the reference lands within the per-package worker-dispatch machinery '
       . '("## Pipeline" through "## Worker dispatch contract"), not merely somewhere '
       . 'unrelated elsewhere in the file');
}

# ===========================================================================
# C (behavior 15 / AC6, docs-consistency). gate-drive-loop.sh is
# drive-solo-scoped by construction (exits immediately whenever BP_LEDGER
# is set — i.e. inside every coordinator, per gate-drive-loop.sh:48). A
# coordinator's own stop discipline is gate-stop.sh, untouched by w02.
# Documenting the fold HERE would be actively misleading: it would tell a
# coordinator to expect a gate that never runs in its own session.
# ===========================================================================
unlike($content, qr/gate-drive-loop\.sh/,
       'C1 CANONICAL (behavior 15 / docs-consistency): coordinator-protocol/SKILL.md does '
     . 'NOT mention gate-drive-loop.sh anywhere — that gate is drive-solo-scoped, and '
     . 'documenting it here would mislead a coordinator into expecting a gate that never '
     . 'runs inside a BP_LEDGER-bearing session');

# ===========================================================================
# D (§2.5). The interrupt-and-report doctrine is dispatch-shape-agnostic
# and documented HERE too, but "by reference ... rather than duplicating
# the text — one canonical wording, one place it can drift out of sync".
# So: coordinator-protocol must POINT at drive-solo/SKILL.md for the
# canonical prompt, and must NOT duplicate the prompt's literal opening
# line verbatim (duplication is exactly the drift risk the spec names).
# ===========================================================================
like($content, qr{drive-solo/SKILL\.md},
     'D1 (§2.5): coordinator-protocol/SKILL.md references drive-solo/SKILL.md by path — '
   . 'the canonical prompt lives in ONE place, referenced by pointer, per the spec\'s own '
   . '"one canonical wording, one place it can drift" reasoning');
unlike($content, qr/STOP ITERATING AND REPORT NOW/,
       'D2 CANONICAL (§2.5): coordinator-protocol/SKILL.md does NOT duplicate the canonical '
     . 'prompt\'s literal opening line — a second, independently-editable copy is precisely '
     . 'the drift risk the spec calls out by name');

# ===========================================================================
# E (§2.5, negative). No DAG edge language — criterion 6 is explicit that
# there is deliberately NO DAG edge between w02 and e03; this file must not
# gain prose asserting or implying one (e.g. "depends on e03", "e03 must
# land first").
# ===========================================================================
unlike($content, qr/e03\b.*\bdepends|\bdepends\b.*\be03\b/i,
       'E1 (criterion 6): coordinator-protocol/SKILL.md carries no dependency language '
     . 'tying it to e03 — criterion 6 rules this "coordination, not a dependency", and no '
     . 'DAG edge is to be inferred as a fix');

done_testing();
