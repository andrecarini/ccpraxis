#!/usr/bin/env perl
# b42-decision-context-split oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b42-decision-context-split-spec.md
# section 5 (C1..C7) plus the frozen ground truth in
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/reports/b42-decision-context-split/
# step1-inventory.md (per-row sha256 digests, byte counts, and the citation map). This file loads
# its expectations from that report rather than re-deriving them, per the spec's own instruction.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. The split has not happened: `reports/decisions/SYN-*.md` do
# not exist, and every `| SYN-N | ... |` row is still the full, unsplit original text with no
# `-> reports/decisions/SYN-N.md` pointer. Every C assertion below is expected to fail on MISSING
# BEHAVIOUR (absent files / absent pointer / absent binding statement), never on a bug in this file.
#
# :raw ONLY, throughout. No `use utf8` anywhere in this file — the three non-ASCII bytes this file
# needs to match (em dash, en dash, right arrow) are written as explicit \xNN hex escapes below so
# the source stays plain ASCII and unambiguous regardless of how it round-trips through an editor.
#
# SYN-23: no assertion, fixture or comment in this file cites a line number in blueprint.md,
# bp-orchestrator.pl or bp-blueprint.pl. Everything is located by grep pattern / regex.
#
# MANDATORY VACUITY GATE (spec §5, "deferred-review queue" standing rule): C3, C4 and C7 each have a
# natural negative-only phrasing that passes trivially against a do-nothing implementation. Each
# therefore carries a POSITIVE assertion FIRST, before the negative one:
#   - C3 asserts >=1 citation was actually enumerated across packages/*.md.
#   - C4 asserts parse_dag returned a non-empty result of >=71 packages.
#   - C7 asserts, PER DECISION, that a non-empty binding statement was actually located (i.e. the
#     `-> reports/decisions/SYN-N.md` pointer is present in that row) BEFORE checking what the
#     statement contains. Locating "a binding statement" is defined as finding the pointer — not as
#     "whatever text happens to be in the cell" — because the cell today is the WHOLE original row,
#     which would trivially "contain" its own ruling and make the criterion vacuous pre-split.
#
# No SKIP block appears anywhere in this file. A missing file, a missing pointer, or an unlocatable
# row is always asserted as a FAILURE via a defined empty-string/undef fallback, never skipped.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $ORCH   = "$BUTLER/scripts/bp-orchestrator.pl";

my $BP_ROOT   = "$PROJ/.ccpraxis-local-data";
# Resolved through live AND _archive/. This blueprint was archived -- the
# expected end of a finished initiative -- and the hardcoded path made that a
# CRASH here: the file died outright and took 139 assertions with it, reporting
# nothing at all rather than one honest skip. almanac 20260823-210122-433f.
use lib "$Bin/../lib";
use HostCaps qw(corpus_blueprint_dir);
my $BP_DIR    = corpus_blueprint_dir($PROJ, 'sandbox-butler-overhaul')
              // "$BP_ROOT/blueprints/sandbox-butler-overhaul";
my $LIVE_BP   = "$BP_DIR/blueprint.md";
my $DECISIONS_DIR = "$BP_DIR/reports/decisions";

diag("subject under test: $LIVE_BP (decisions section) "
     . (-e $LIVE_BP ? "(present)" : "(ABSENT)"));
diag("relocated-decisions dir: $DECISIONS_DIR "
     . (-d $DECISIONS_DIR ? "(present)" : "(ABSENT -- every C1/C7 assertion below is expected to fail)"));

require $ORCH;   # the REAL parse_dag, never a reimplementation (C4).

# =====================================================================================
# Scaffolding
# =====================================================================================

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub sha16 { substr(sha256_hex($_[0]), 0, 16) }

# Non-ASCII bytes used in the frozen ground-truth phrases below, as raw UTF-8 byte sequences
# (never as literal source characters, and never via \x{...}, since this file has no `use utf8`).
my $EMDASH = "\xE2\x80\x94";   # U+2014 em dash
my $ENDASH = "\xE2\x80\x93";   # U+2013 en dash
my $ARROW  = "\xE2\x86\x92";   # U+2192 rightwards arrow

# =====================================================================================
# Frozen ground truth, loaded from step1-inventory.md (never re-derived from the live file for
# the purpose of grading it -- these are the numbers/hashes/phrases the inventory already measured).
# =====================================================================================

# C1: per-decision sha256 (first 16 hex chars) of the pre-split row text -- the "Per-decision digest
# and citation load" table in step1-inventory.md.
my %SHA16 = (
    'SYN-1'  => '19493fae2a757430', 'SYN-2'  => '4eef162ad63af17e', 'SYN-3'  => 'c0b0c6e269f5a568',
    'SYN-4'  => 'c62250cabb3f682d', 'SYN-5'  => '06c3f10beb8b1bdb', 'SYN-6'  => 'c0f3cc453c323d72',
    'SYN-7'  => 'f987a5d550654103', 'SYN-8'  => '0dc27ef52275e2af', 'SYN-9'  => '436dd07f592a7f26',
    'SYN-10' => '632898bfe443193a', 'SYN-11' => '8ffd3bec506273a5', 'SYN-12' => '47e5774d689a5e76',
    'SYN-13' => '77ccc906312aa19c', 'SYN-14' => 'bcdc67406c70eb58', 'SYN-15' => '39abd61bbecf2df7',
    'SYN-16' => '97acaf26aac8038c', 'SYN-17' => '0ca372f349c12603', 'SYN-18' => 'a1ac8fb5a7170866',
    'SYN-19' => 'c9896e2037ba99b0', 'SYN-20' => 'cbd56afc32bc7370', 'SYN-21' => 'ca0beb9e40457258',
    'SYN-22' => '1865fafcb353f2b7', 'SYN-23' => 'cb2a13c041eb4d48', 'SYN-24' => '4d84931ce87a11a7',
    'SYN-25' => '087ae8afabaa0572', 'SYN-26' => '748933de289bca12',
);
my @IDS = map { "SYN-$_" } (1 .. 26);
is(scalar(keys %SHA16), 26, "HARNESS: 26 frozen per-decision sha256 digests loaded from the inventory");

# C7: the operative ruling each binding statement must still carry, per decision. Spec's own test
# for "ruling" vs "rationale": *if a decision mandates a specific file, id, threshold or forbidden
# action, that specific stays; if someone obeyed only the summary, could they violate the original?*
# A binding statement is legitimately a REWORDING of its source row (that is the whole point of
# compression), so this file must not require the ORIGINAL SENTENCE verbatim -- only the SPECIFIC,
# falsifiable facts a lossy summary would be first to drop: package/file ids, dates, counts, quoted
# terms and emphasis words. Each id below carries a short list of such tokens, extracted from the
# frozen ground truth in step1-inventory.md's verbatim blocks (case-sensitive for ids/ACRONYMS,
# case-insensitive -- marked [i] -- for the handful of decisions whose ruling has no such token and
# is instead named by a couple of ordinary words). Every token in a decision's list must be present.
#
# SYN-8 landmine: its bold lead-in in the ORIGINAL row ("Execution model = sandbox, via the
# isolation prerequisite...") is the STRUCK-THROUGH (~~...~~), SUPERSEDED half of that row -- using
# it as "the ruling" would require a binding statement to carry forward a claim the row itself voids.
# The actual ruling is the surviving half: superseded by SYN-13, unattended completion except a
# TUI-visual attended final check. Tokens below reflect that, not the crossed-out headline.
my %REQUIRED_TOKENS = (
    'SYN-1'  => [['two tracks', 1], ['parallel', 1]],
    'SYN-2'  => [['lossless', 1]],
    'SYN-3'  => [['FULL']],
    'SYN-4'  => [['seam', 1]],
    'SYN-5'  => [['TUI']],
    'SYN-6'  => [['auto-fix', 1], ['escalate', 1]],
    'SYN-7'  => [['re-audit', 1]],
    'SYN-8'  => [['SUPERSEDED'], ['SYN-13']],
    'SYN-9'  => [['b08'], ['DAG']],
    'SYN-10' => [['archived', 1]],
    'SYN-11' => [['Green']],
    'SYN-12' => [['sandbox-refuse-protected-paths'], ['q01']],
    'SYN-13' => [['SYN-8'], ['clone', 1]],
    'SYN-14' => [['q03'], ['s02-config-safety-implement']],
    'SYN-15' => [['43'], ['51']],
    'SYN-16' => [['s02'], ['RULED'], ['2026-07-28']],
    'SYN-17' => [['b09'], ['b10'], ['b11'], ['2026-07-29']],
    'SYN-18' => [['b09']],
    'SYN-19' => [['b12'], ['b13'], ['2026-07-29']],
    'SYN-20' => [['15'], ['2026-07-29']],
    'SYN-21' => [['AMENDED'], ['OWNED']],
    'SYN-22' => [['b27'], ['b28'], ['b19']],
    'SYN-23' => [['HINTS'], ['2026-07-29']],
    'SYN-24' => [['b32'], ['b38'], ['CHOICE']],
    'SYN-25' => [['b39'], ['2026-08-02']],
    'SYN-26' => [['COST'], ['2026-08-03']],
);
is(scalar(keys %REQUIRED_TOKENS), 26, "HARNESS: 26 frozen per-decision required-token lists loaded");

# =====================================================================================
# Read the live blueprint.md ONCE (read-only throughout this file -- nothing here ever writes to
# it), locate the decisions section and the decisions table rows within it.
# =====================================================================================

my $LIVE_CONTENT = read_file($LIVE_BP);
ok(defined($LIVE_CONTENT) && length($LIVE_CONTENT) > 50_000,
   "FIXTURE-SANITY: blueprint.md exists and is a substantial real file (>50 KB)");

# The decisions section: from the "## Synthesis decisions" heading up to (not including) the next
# top-level "## " heading. Same extraction shape step1-inventory.md used (measured 32,844 bytes).
my ($DECISIONS_SECTION) = defined($LIVE_CONTENT)
    ? ($LIVE_CONTENT =~ /(^## Synthesis decisions\r?\n.*?)(?=^## )/ms)
    : (undef);
ok(defined($DECISIONS_SECTION) && length($DECISIONS_SECTION) > 0,
   "FIXTURE-SANITY: the '## Synthesis decisions' section is locatable in blueprint.md");

# Every `| SYN-N | <cell> |` row within that section, IN ORDER, id -> cell text (cell text is
# whatever currently sits between the pipes -- pre-split this is the whole original row; post-split
# it will be `<binding statement> -> \`reports/decisions/SYN-N.md\``).
my @IDS_IN_ORDER;
my %ROW_CELL;
if (defined $DECISIONS_SECTION) {
    while ($DECISIONS_SECTION =~ /^\|\s*(SYN-\d+)\s*\|\s*(.*?)\s*\|\s*$/mg) {
        push @IDS_IN_ORDER, $1;
        $ROW_CELL{$1} = $2;
    }
}
diag("HARNESS: decisions table rows located: " . scalar(@IDS_IN_ORDER) . " (" . join(',', @IDS_IN_ORDER) . ")");

# =====================================================================================
# C1 -- no information loss. All 26 relocated files exist and each contains the pre-split row
# text verbatim (sha256 match against the inventory). A MISSING file FAILS, never SKIPs.
# =====================================================================================

# Tries several reasonable "the row text lives inside this file, under SOME heading" shapes without
# assuming one exact heading format: every suffix-of-lines join (handles an arbitrary-length leading
# heading block), then any single line, then the whole file trimmed. Returns the matching substring,
# or undef if nothing in the file hashes to the expected prefix.
sub locate_verbatim_body {
    my ($content, $expected16) = @_;
    return undef unless defined $content && length $content;
    my @lines = split /\n/, $content, -1;
    for my $skip (0 .. $#lines) {
        my $body = join("\n", @lines[$skip .. $#lines]);
        $body =~ s/\A\n+//;
        $body =~ s/\n+\z//;
        next unless length $body;
        return $body if sha16($body) eq $expected16;
    }
    for my $l (@lines) {
        next unless length $l;
        return $l if sha16($l) eq $expected16;
    }
    (my $whole = $content) =~ s/\A\s+//;
    $whole =~ s/\s+\z//;
    return $whole if length($whole) && sha16($whole) eq $expected16;
    return undef;
}

my $c1_files_present  = 0;
my $c1_bodies_matched  = 0;
for my $id (@IDS) {
    my $path    = "$DECISIONS_DIR/$id.md";
    my $content = read_file($path);
    my $present = defined($content) && length($content) > 0;
    ok($present, "C1: $DECISIONS_DIR/$id.md exists and is non-empty");
    $c1_files_present++ if $present;

    my $body = locate_verbatim_body($content, $SHA16{$id});
    my $matched = defined($body) ? 1 : 0;
    ok($matched, "C1: $id.md contains the pre-split row text verbatim (sha256 prefix $SHA16{$id})")
        or diag("$id.md: no substring hashed to $SHA16{$id}"
                . (defined $content ? " (file sha256[0..16]=" . sha16($content) . ")" : " (file absent)"));
    $c1_bodies_matched++ if $matched;
}
is($c1_files_present, 26, "C1: exactly 26 of 26 relocated decision files exist (never a partial count)");
is($c1_bodies_matched, 26, "C1: exactly 26 of 26 relocated files verify byte-for-byte against the inventory");

# =====================================================================================
# C2 -- resolvable from blueprint.md alone. Each id still appears as the first cell of a row in
# the decisions table, in its original relative order.
# =====================================================================================

# RETARGETED 2026-08-04, and this one fired while the operator was RECORDING A
# DECISION — the seventh instance of an oracle pinning a total over a shared,
# deliberately-extensible artifact. A decisions table exists to be added to; an
# assertion that it holds exactly 26 rows makes recording decision 27 a test
# failure. That is the antipattern in its purest form.
#
# What C2 protects is that the split did not LOSE or REORDER an id, and both
# survive extension: a floor catches loss, an ordered-subsequence match catches
# reordering and renaming. Growth is the normal, intended case.
cmp_ok(scalar(@IDS_IN_ORDER), '>=', scalar(@IDS),
    "C2: every pre-split id is still defined in the blueprint.md decisions table (a FLOOR — later decisions may be added)")
    or diag("have " . scalar(@IDS_IN_ORDER) . ", pre-split baseline " . scalar(@IDS));

{
    my @missing;
    my $cursor = 0;
    for my $want (@IDS) {
        my $found = -1;
        for my $i ($cursor .. $#IDS_IN_ORDER) {
            if ($IDS_IN_ORDER[$i] eq $want) { $found = $i; last }
        }
        if ($found < 0) { push @missing, "$want (absent, or out of order after index $cursor)" }
        else            { $cursor = $found + 1 }
    }
    is_deeply(\@missing, [],
        "C2: the pre-split ids appear in the table in their original relative order (SYN-1 .. SYN-26), later additions permitted");
}

# =====================================================================================
# C3 -- every citation resolves. Enumerate every SYN-\d+ occurrence across all packages/*.md
# (57 citing ledgers per the inventory baseline) and assert each id is defined. Dangling must be 0.
# =====================================================================================

my %DEFINED = map { $_ => 1 } @IDS_IN_ORDER;
my @package_files = sort glob("$BP_DIR/packages/*.md");
ok(scalar(@package_files) > 0, "FIXTURE-SANITY: packages/*.md corpus is non-empty");

my @all_citation_instances;
my $citing_file_count = 0;
my %cited_ids_seen;
for my $f (@package_files) {
    my $content = read_file($f);
    next unless defined $content;
    my $hit_this_file = 0;
    while ($content =~ /\b(SYN-\d+)\b/g) {
        push @all_citation_instances, $1;
        $cited_ids_seen{$1} = 1;
        $hit_this_file = 1;
    }
    $citing_file_count++ if $hit_this_file;
}

# Positive gate (vacuity): at least one citation was actually enumerated.
ok(scalar(@all_citation_instances) > 0,
   "C3: at least one SYN-\\d+ citation was actually enumerated across packages/*.md");

# RETARGETED 2026-08-03 (SYN-21). This pinned the count at EXACTLY 57, which is
# a corpus snapshot and therefore a moving target by construction: every package
# that later cites a SYN- decision in its own ledger breaks it. It broke the
# moment coordinator entries citing SYN-21 were appended during normal work
# (57 -> 58), and that number had ALREADY been corrected once (32 -> 57).
#
# It is the same global-snapshot antipattern as t/25's frozen heading count and
# the four oracles that pinned launcher.pl's literal poll cadence -- an
# assertion about the whole tree's shape, forbidding every later package from
# adding to it.
#
# What C3 actually protects is stated by the two assertions around it: that
# citations were genuinely enumerated (the vacuity gate above) and that NONE
# dangles (below). The count only ever served as a proxy for "the split did not
# LOSE citations", so assert that directly as a floor -- a drop below the
# pre-split baseline is a real regression; growth is normal, expected work.
cmp_ok($citing_file_count, '>=', 57,
   "C3: at least 57 ledgers cite a SYN- decision -- the pre-split baseline is a FLOOR, "
 . "not a frozen count (growth is normal; a drop would mean the split lost citations)")
    or diag("citing ledgers: $citing_file_count (pre-split baseline was 57)");

my @dangling = sort grep { !exists $DEFINED{$_} } keys %cited_ids_seen;
is(scalar(@dangling), 0, "C3: 0 dangling citations (every cited id resolves to a defined table row)")
    or diag("dangling ids: " . join(',', @dangling));

# =====================================================================================
# C4 -- parse_dag byte-identical / structurally unperturbed. Positive: parse_dag returns a
# non-empty result of >=71 packages. Mechanism: no |-row ABOVE the real DAG header row contains the
# literal token `depends_on` (the hazard the split must not introduce -- SYN-14).
# =====================================================================================

my $dag_before = BpOrch::parse_dag($LIVE_CONTENT);
cmp_ok(scalar(keys %$dag_before), ">=", 71,
   "C4: parse_dag returns a non-empty result of >=71 packages (positive gate, before the negative check)");

my @all_lines = split /\n/, $LIVE_CONTENT, -1;
# Locate the REAL DAG header by its distinctive column shape (pkg + deliverable + depends_on
# together), not merely "the first |-row mentioning depends_on" -- that would make the "nothing
# above it" check tautological by construction.
my ($real_hdr_idx) = grep {
    $all_lines[$_] =~ /^\s*\|/
        && $all_lines[$_] =~ /\bpkg\b/
        && $all_lines[$_] =~ /\bdeliverable\b/
        && $all_lines[$_] =~ /\bdepends_on\b/
} 0 .. $#all_lines;
ok(defined $real_hdr_idx, "C4: the real package-status DAG header row (pkg/deliverable/depends_on) is located");

my $bad_row_above = 0;
if (defined $real_hdr_idx) {
    for my $i (0 .. $real_hdr_idx - 1) {
        if ($all_lines[$i] =~ /^\s*\|/ && $all_lines[$i] =~ /\bdepends_on\b/) { $bad_row_above = 1; last }
    }
}
is($bad_row_above, 0,
   "C4: no |-row ABOVE the real DAG header contains the literal 'depends_on' (SYN-14 hazard not introduced)");

# Same-run before/after: this file never writes to blueprint.md, so a fresh disk re-read at the end
# of this run must parse to the structurally identical DAG as the one captured at the start. This is
# the strongest before/after comparison available to a test that must not perform the split itself;
# DAG preservation ACROSS the split is additionally guaranteed by the mechanism check above (which
# looks at the state on disk right now, whatever that state is) plus C1/C2's own preservation proof.
my $LIVE_CONTENT_END = read_file($LIVE_BP);
my $dag_after = BpOrch::parse_dag($LIVE_CONTENT_END);
is_deeply($dag_after, $dag_before,
   "C4: parse_dag's structural output re-read from disk at the end of this run is unchanged from the start");

# =====================================================================================
# C5 -- measurable shrink, bounded. Section <= 12,000 bytes (from 32,844). Per statement: a
# 400-byte BUDGET with an 800-byte HARD CEILING, excluding the pointer -- spec §5 "Why the ceiling
# is not the budget": a flat 400-byte cap and C7 (no ruling lost) are jointly unsatisfiable for at
# least one decision (SYN-24 needs 748 to stay lossless). So the hard ceiling (800, never exceeded)
# is asserted PER DECISION, while the 400-byte budget is asserted in AGGREGATE as "breaches must be
# rare": at most 3 of the 26 statements may exceed it.
# =====================================================================================

cmp_ok(length($DECISIONS_SECTION), "<=", 12_000,
   "C5: the '## Synthesis decisions' section is <=12,000 bytes (from 32,844 pre-split)");

my $c5_over_budget = 0;
for my $id (@IDS) {
    my $cell = $ROW_CELL{$id};
    $cell = '' unless defined $cell;
    # Strip a trailing "-> `reports/decisions/SYN-N.md`" pointer (either the real arrow glyph or an
    # ASCII "->" fallback) if present; what remains is the binding statement to be bounded.
    my $stmt = $cell;
    if ($cell =~ /\A(.*?)\s*(?:\Q$ARROW\E|->)\s*\`reports\/decisions\/\Q$id\E\.md\`\s*\z/s) {
        $stmt = $1;
    }
    cmp_ok(length($stmt), "<=", 800,
       "C5: $id binding statement is <=800 bytes -- the HARD CEILING, excluding the pointer (currently "
       . length($stmt) . " bytes)");
    $c5_over_budget++ if length($stmt) > 400;
}
cmp_ok($c5_over_budget, "<=", 3,
   "C5: at most 3 of the 26 binding statements exceed the 400-byte BUDGET (currently $c5_over_budget "
   . "-- the ceiling exception must stay rare, not become the rule)");

# =====================================================================================
# C6 -- the standing rule is documented. authoring-protocol/SKILL.md states the binding-
# statement/pointer split WITH the length budget; coordinator-protocol/SKILL.md's read-instruction
# is updated to the new shape. Asserted on substance, not on heading presence.
# =====================================================================================

my $AUTHORING_SKILL   = "$PROJ/plugins/blueprint/skills/authoring-protocol/SKILL.md";
my $COORDINATOR_SKILL = "$PROJ/plugins/butler/skills/coordinator-protocol/SKILL.md";

my $authoring_text   = read_file($AUTHORING_SKILL);
my $coordinator_text = read_file($COORDINATOR_SKILL);
ok(defined($authoring_text) && length($authoring_text) > 0,   "FIXTURE-SANITY: authoring-protocol/SKILL.md is readable");
ok(defined($coordinator_text) && length($coordinator_text) > 0, "FIXTURE-SANITY: coordinator-protocol/SKILL.md is readable");

{
    my $a = $authoring_text // '';
    like($a, qr/binding statement/i,
       "C6: authoring-protocol/SKILL.md names the 'binding statement' half of the split");
    like($a, qr/reports\/decisions/,
       "C6: authoring-protocol/SKILL.md names the reports/decisions/<ID>.md pointer convention");
    like($a, qr/\b400\s*bytes\b/,
       "C6: authoring-protocol/SKILL.md states the 400-byte binding-statement budget");
}
{
    my $c = $coordinator_text // '';
    like($c, qr/binding statement/i,
       "C6: coordinator-protocol/SKILL.md's read-instruction names the binding statement");
    like($c, qr/reports\/decisions/,
       "C6: coordinator-protocol/SKILL.md's read-instruction names the reports/decisions/<ID>.md pointer");
}

# =====================================================================================
# C7 -- no ruling lost, PER DECISION (never in aggregate). Positive: a non-empty binding statement
# was actually LOCATED (the pointer is present in that row) before checking its content. Then:
# the binding statement carries that decision's operative ruling.
# =====================================================================================

for my $id (@IDS) {
    my $cell = $ROW_CELL{$id};
    $cell = '' unless defined $cell;
    my ($stmt) = $cell =~ /\A(.*?)\s*(?:\Q$ARROW\E|->)\s*\`reports\/decisions\/\Q$id\E\.md\`\s*\z/s;
    my $located = defined($stmt) && length($stmt) > 0;

    ok($located,
       "C7: $id -- a non-empty binding statement was actually located (pointer format present in the row)");

    my $hay = $located ? $stmt : '';
    for my $pair (@{ $REQUIRED_TOKENS{$id} }) {
        my ($tok, $ci) = @$pair;
        my $re = $ci ? qr/\Q$tok\E/i : qr/\Q$tok\E/;
        like($hay, $re,
           "C7: $id -- the binding statement retains the operative-ruling token '$tok'"
           . ($ci ? ' (case-insensitive)' : ''));
    }
}

done_testing();
