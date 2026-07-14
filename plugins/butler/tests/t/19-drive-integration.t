#!/usr/bin/env perl
# t/19-drive-integration.t — skill↔director contract test (04-wireup-cleanup, Decision #12).
#
# Asserts that drive-solo/SKILL.md and bp-drive-next.pl carry the same five
# action-name vocabulary. This is the CONJUNCTION guard: assertion group A
# (skill) alone passes if the director drops an action; group B (director) alone
# passes if the skill drops it. Only the conjunction — same @actions list,
# two independent file reads — holds when AND ONLY WHEN both sides carry every
# name. Dropping blueprint-done from either file turns exactly one `like` red.
#
# Not fail-first: both source files (pkg-01, pkg-03) are already written and
# carry all five names. This test is a regression/drift guard, not a red-first
# TDD test. That is expected and correct for an integration/agreement test
# written after both sides exist.
#
# No fixtures, tempdirs, network, clock, powershell, or `require` of the
# director as a module — pure source-text read of two committed files.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $SKILL    = "$Bin/../../skills/drive-solo/SKILL.md";
my $DIRECTOR = "$Bin/../../scripts/bp-drive-next.pl";

sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $r = <$fh>;
    close $fh;
    $r // '';
}

my $skill    = read_file($SKILL);
my $director = read_file($DIRECTOR);

# ── Step 1: both files load / are non-empty ─────────────────────────────────
ok(length $skill,    "drive-solo/SKILL.md is non-empty (path: $SKILL)");
ok(length $director, "bp-drive-next.pl is non-empty (path: $DIRECTOR)");

# ── Step 2 + 3: Decision #12 five-action contract — both files must carry all ─
# Bare \Q...\E regexes match the token wherever it appears (prose, JSON-shape
# example, table cell, or perl source) — the test asserts AGREEMENT OF
# VOCABULARY, not byte-position, so it survives reformatting of either file
# but breaks the moment a name is dropped or renamed on one side only.
# pause and done are short common words; anchoring them as the action tokens
# by matching the literal name is acceptable because both files use them as
# the action identifier and the purpose is drift-detection, not exhaustive
# parsing (see spec §4 rationale).

my @actions = qw(need-order run-package pause blueprint-done done);

for my $action (@actions) {
    like($skill,    qr/\Q$action\E/, "drive-solo SKILL.md documents '$action'");
    like($director, qr/\Q$action\E/, "bp-drive-next.pl emits '$action'");
}

# ── Step 4: skill references the real director subcommands / verdict source ──
# These four asserts guard against vocabulary drift on the SKILL side only:
# the subcommand names and verdict source are produced by bp-drive-next.pl
# (director) and bp-usage-gate.pl (governor); the skill must name them so a
# user reading the skill knows exactly which scripts carry the mechanics.

like($skill, qr/bp-drive-next\.pl/,         "drive-solo SKILL.md names the director script");
like($skill, qr/record-order/,              "drive-solo SKILL.md references record-order subcommand (need-order response)");
like($skill, qr/\bpark\b/,                  "drive-solo SKILL.md references park subcommand (blueprint-done response)");
like($skill, qr/bp-usage-gate\.pl verdict/, "drive-solo SKILL.md references bp-usage-gate.pl verdict (Decision #13)");

done_testing();
