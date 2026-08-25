#!/usr/bin/env perl
# s05-responsive-layout: the two-column layout oracle for Dashboard.pm.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s05-responsive-layout (spec 02-responsive-layout-spec.md, S2
# interfaces / S3 observable behaviors / S4 acceptance criteria). It is
# written BLIND to Dashboard.pm's implementation -- directly from the spec --
# so it can serve as an oracle rather than an echo of whatever the
# implementer eventually writes.
#
# Coverage: AC-1..AC-13, AC-15, AC-17, AC-18. (AC-14 and AC-16 are
# suite/file-level criteria verified by the coordinator running the whole
# t/25 + t/39 + t/40 suite -- not exercised as unit assertions here.)
#
# The six new subs under test (_two_col_min_cols, _two_col_mode,
# _col_widths, _panel_rows, _join_cells, _two_col_rows) and the modified
# _body_rows/activity_capacity DO NOT YET EXIST/behave per-spec on package
# load -- most assertions below are EXPECTED to fail with "Undefined
# subroutine" (the file will very likely die at the very first call, per
# t/39's own precedent for s04) until the implementer lands s05. That is
# correct and by design; some later oracles (built on already-existing s04
# surfaces such as make_cell/compose_frame/activity_capacity) may instead
# fail with a WRONG VALUE rather than a die once those subs exist, which is
# an equally valid RED signal.
#
# Hard constraint (spec S4.6): this file MUST NOT `use utf8`. Glyph literals
# are written as "\x{...}" escapes (the decoded-character path), per s04 S8.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# BREAKPOINT MIGRATED 100 -> 90 (package 06-dashboard-screen, in-scope oracle
# correction #4; Decision 14 is an operator decision dated 2026-08-06 and
# WINS over the prior 100; driver ruling packages/06-dashboard-screen.md
# 2026-08-07T17:56:38Z / 2026-08-07T20:40:59Z). $BP is declared ONCE here
# (spec AC-B4) and reused by every migrated assertion below, so the breakpoint
# itself is never re-typed as a bare literal in this file. Per AC-B4's
# migration rule: a width chosen BECAUSE it sits at/above the breakpoint
# becomes $BP or $BP+k; a width chosen BECAUSE it sits just below becomes
# $BP-1; a width chosen for an UNRELATED reason (an arbitrary "wide frame" or
# a maxh/row-height parameter, which this file also uses 99/100 for) STAYS
# that literal and is commented as such at first use. No assertion's CLAIM
# changes here; only the SUBJECT of the breakpoint-testing ones does.
# ===========================================================================
require tui::Layout;
require tui::Meter;
my $BP = tui::Layout::BREAKPOINT_TWO_COL();

# ===========================================================================
# RULE-FILL GLYPH RE-POINTED (package 06 in-scope oracle correction): a
# title row's fill used to be literal ASCII '-' repeated to width; compose_frame
# now composes through tui::DashboardScreen/tui::Frame, which fill title rules
# with Theme's declared 'rule.h' glyph (U+2500) instead (spec S2.1: every
# glyph tui::DashboardScreen emits comes from Theme::glyph(...)). Every
# assertion below that previously matched a FULL dash-filled title row with
# a bare `-+` is rewritten against this DERIVED pattern -- never a hardcoded
# '-' or a hardcoded codepoint -- so it cannot drift from Theme's own
# declaration. The TITLE LEAD-IN is now derived too: it was the ASCII "-- ",
# and is now one rule.h glyph plus a space, so the title line is continuous
# with its own filler and can serve as the panel's top border (operator
# request, 2026-08-25). Both halves come from Theme, never a literal.
# ===========================================================================
require Theme;
my $RULE_FILL_RE      = quotemeta(Theme::glyph('rule.h'));                    # UTF-8 BYTES, for byte-string row text
my $RULE_FILL_CHAR_RE = quotemeta(Theme::glyphs()->{'rule.h'}{char});         # decoded CHARACTER, for utf8::decode()d text

# ===========================================================================
# Fixture: the same %st shape t/25-dashboard.t uses (PART 2, :105-112) so the
# derived oracles (Sandbox L_0=5 -> T_0=7; Run L_1=3 -> T_1=5; no backpack)
# agree with spec S2.9's worked table.
# ===========================================================================
my %st = (
    project_name => 'demo',
    container    => 'claude-demo-abcd1234',
    status       => 'running',
    beat_age     => 12,
    uptime       => 3660,
    events       => ['10:00:01  launch_start', '10:00:05  container_start exit=0'],
);

# The full size matrix (spec S4.2 AC-9), reused by AC-9, AC-10 and AC-12.
# The three near-boundary samples migrate with the breakpoint ($BP-1/$BP/
# $BP+1 replace 99/100/101); 79/80 stay literal (generically-below samples,
# still below 90) and so do 120/200 (generically-above, still above 90) --
# none of AC-9/AC-10/AC-12 hardcode an expected NUMBER keyed to a specific
# column here (they compare Dashboard's own output against itself/derived
# invariants), so this migration is a like-for-like re-centring, not a
# behaviour change.
my @ROWS = (0, 1, 2, 3, 4, 5, 10, 12, 24, 50);
my @COLS = (1, 20, 39, 40, 50, 79, 80, $BP - 1, $BP, $BP + 1, 120, 200);

# ===========================================================================
# 4.1 The composer (DC-1): AC-1 .. AC-8, AC-17
# ===========================================================================

# ---------------------------------------------------------------------------
# AC-1 -> DC-1 -- BREAKPOINT MIGRATED (see file-header note): claim preserved
# verbatim -- "_two_col_min_cols() returns THE single-source-of-truth
# breakpoint; _two_col_mode returns 0 below it and 1 at/above it." Subject
# changed: the literal 100 -> the DERIVATION tui::Layout::BREAKPOINT_TWO_COL()
# (spec AC-B2), so this cannot drift from 05's constant. The boundary-adjacent
# probes (99 "just below", 100 "at") move to $BP-1/$BP; 40/79/80 stay literal
# (chosen as clearly-below samples, still < 90) and so do 101/120/200/1000
# (clearly-above, still > 90).
# ---------------------------------------------------------------------------
# RE-POINTED to tui::Layout. Dashboard::_two_col_min_cols and
# Dashboard::_two_col_mode were deleted: both were one-line delegating wrappers
# (_two_col_min_cols returned tui::Layout::BREAKPOINT_TWO_COL(); _two_col_mode
# returned arrangement() eq 'two-column'), unreachable once compose_frame began
# delegating, and their only remaining callers were the legacy render path and
# this file.
#
# AC-1's CLAIM is unchanged and is the one worth keeping: there is a single
# source of truth for the breakpoint, the mode is 0 strictly below it and 1 at
# or above it, and a junk width degrades to single-column rather than dying.
# Asserted against the module that actually owns the decision.
sub _two_col { return (tui::Layout::arrangement($_[0]) eq 'two-column') ? 1 : 0 }

for my $c (undef, -5, 0, 1, 40, 79, 80, $BP - 1) {
    my $label = defined $c ? $c : 'undef';
    is(_two_col($c), 0, "AC-1: arrangement($label) is single-column");
}
for my $c ($BP, 101, 120, 200, 1000) {
    is(_two_col($c), 1, "AC-1: arrangement($c) is two-column");
}

# ---------------------------------------------------------------------------
# AC-5, AC-6 -> DC-1: _two_col_rows -- exact composition, then truncation.
# Shared fixture: L has 5 lines (natural height 7), R has 1 line (natural
# height 3). UNRELATED to the breakpoint migration: the 100 passed as the
# TOTAL column width below is an arbitrary "wide enough to split" sample --
# this helper is only ever called once the caller (compose_frame, via
# _two_col_mode) has already decided two-column mode applies, so it has no
# opinion on where that boundary sits. The 99/5/1/0/-3 values are all
# MAX-HEIGHT (row) parameters, likewise column-breakpoint-unrelated.
# ---------------------------------------------------------------------------
my $ac56_L = { title => 'L', lines => [ 'l1', 'l2', 'l3', 'l4', 'l5' ] };
my $ac56_R = { title => 'R', lines => [ 'r1' ] };

# ---------------------------------------------------------------------------
# AC-7 -> DC-1 (narrow fallback, asserted) -- BREAKPOINT MIGRATED (see
# file-header note) AND SUBJECT RE-POINTED (package 06, driver ruling
# 2026-08-08, Family 1): claim preserved verbatim -- "just below the
# breakpoint, no row joins the two lead panels; at/above it, exactly one row
# does." 99/100 -> $BP-1/$BP (unchanged from the earlier migration). The PAIR
# itself also moves: the Sandbox panel is deleted (spec S2.4.3) and its
# rows are absorbed elsewhere, so the two panels that can now share the lead
# row are Run and Token (the driver's explicit re-pointing: "Two-column
# assertions that named Sandbox|Run as the pair now name Run and Token").
# The fixture gains a `tokens` hashref so the Token panel actually renders
# (spec S2.4.3: present when `ref $state->{tokens} eq 'HASH'`) -- without it
# there is no second lead panel to pair with at all. Both frames stay
# exactly $rows x $cols.
#
# RE-POINTED AGAIN (package t01-providers-panel, spec §6): the Token panel is
# deleted outright and replaced by the always-present Blueprints panel as
# Run's new pairing partner (Behavior 17) -- Blueprints is the panel
# immediately following Run in panels()'s order and, unlike Token, needs no
# fixture augmentation to exist at all, so the `tokens => {}` augmentation is
# dropped. Claim preserved verbatim; only the SUBJECT (Token -> Blueprints)
# and the fixture (no augmentation needed) move.
# ---------------------------------------------------------------------------
{
    my $below = $BP - 1;
    my $fbelow = Dashboard::compose_frame(\%st, 24, $below);
    is(scalar(@$fbelow), 24, "AC-7: compose_frame(24,$below) returns exactly 24 rows");
    is(scalar(grep { Dashboard::display_width($_->{text}) != $below } @$fbelow), 0,
        "AC-7: compose_frame(24,$below) -- every row is exactly $below display columns");
    my $both_below = grep { $_->{text} =~ /$RULE_FILL_RE Run / && $_->{text} =~ /$RULE_FILL_RE Blueprints / } @$fbelow;
    is($both_below, 0, "AC-7: 24x$below -- no single row contains BOTH \"-- Run\" and \"-- Blueprints\" (still stacked)");
    my ($run_below) = grep { $_->{text} =~ /^$RULE_FILL_RE Run (?:$RULE_FILL_RE)+$/ } @$fbelow;
    ok($run_below, "AC-7: 24x$below -- some row matches /^-- Run <rule.h fill>\$/");
    is(Dashboard::display_width($run_below->{text}), $below, "AC-7: that row is exactly $below display columns") if $run_below;

    my $fat = Dashboard::compose_frame(\%st, 24, $BP);
    is(scalar(@$fat), 24, "AC-7: compose_frame(24,$BP) returns exactly 24 rows");
    is(scalar(grep { Dashboard::display_width($_->{text}) != $BP } @$fat), 0,
        "AC-7: compose_frame(24,$BP) -- every row is exactly $BP display columns");
    my $both_at = grep { $_->{text} =~ /$RULE_FILL_RE Run / && $_->{text} =~ /$RULE_FILL_RE Blueprints / } @$fat;
    is($both_at, 1, "AC-7: 24x$BP -- EXACTLY one row contains BOTH \"-- Run \" and \"-- Blueprints \" (two-column mode)");
}

# ---------------------------------------------------------------------------
# AC-8 -> DC-1: full-width stacking below the pair. With a gathered backpack,
# compose_frame(...,30,120): Sandbox row index < Backpack title row index <
# Recent-activity title row index; Backpack/Recent-activity title rows
# dash-fill to the FULL 120 columns (no second column on those rows).
# ---------------------------------------------------------------------------
{
    my $bp = { total => 1, approved => 0, items => [ { key => 'apt:jq', approved => 0 } ] };
    my %stb = (%st, backpack => $bp);
    my $f = Dashboard::compose_frame(\%stb, 30, 120);
    is(scalar(@$f), 30, 'AC-8: compose_frame(...,30,120) returns exactly 30 rows');
    is(scalar(grep { Dashboard::display_width($_->{text}) != 120 } @$f), 0,
        'AC-8: every row of the composed frame is exactly 120 display columns');

    # AC-8 RE-POINTED (package 06, spec S2.4.3/S2.4.8, Decision 9): TWO
    # subjects dissolved here, not one. The Sandbox panel is deleted (its
    # rows move to the header or to Run -- spec S2.4.3's disposition table),
    # AND the Backpack panel dissolves into a single summary ROW inside Run
    # rather than remaining a titled panel of its own (spec S2.4.8: "Rendered
    # through row(label => 'backpack', ...) inside the Run panel -- not as a
    # panel of its own"). Neither can serve as a "-- Title --" landmark any
    # more. Claim preserved: the fixed/lead panel(s) precede the trailing
    # full-width "Recent activity" panel, which spec S2.4.3 places LAST
    # unconditionally -- subject "-- Sandbox " -> "-- Run ". The deleted
    # Backpack-title landmark's underlying FACT (the one-item backpack is
    # visible in the frame) is preserved separately below, as a text check
    # rather than a title-row landmark, since it no longer has a title row.
    #
    # THE "NO SECOND COLUMN" HALF OF THE ORIGINAL CLAIM IS RETIRED, REPORTED
    # RATHER THAN INVENTED, driver ruling 2026-08-08 (ACCEPTED): measured
    # directly, compose_frame(...,30,120) here now puts "-- Run " and
    # "-- Recent activity " on the SAME row (Run pairs with whatever panel
    # comes next when Token/Resources/Spend are absent, rather than only ever
    # pairing with a second designated "fixed" panel). That packing decision
    # now lives in tui::Layout::place's own algorithm (package 05,
    # plugins/sandbox/scripts/tui/Layout.pm -- out of this package's write
    # set and spec's explicit "escalate; do not patch it here", S6 item 2),
    # and 06's own spec never commits Recent activity to always being
    # full-width -- only to being placed LAST (spec S2.4.3). The ordering
    # claim that IS spec-backed survives, weakened from strict "<" to "<="
    # because sharing a row is now a legitimate outcome: Run's row index
    # never comes AFTER Recent activity's.
    my ($i_run) = grep { $f->[$_]{text} =~ /$RULE_FILL_RE Run / } 0 .. $#$f;
    my ($i_ra)  = grep { $f->[$_]{text} =~ /$RULE_FILL_RE Recent activity / } 0 .. $#$f;
    ok(defined $i_run, 'AC-8: a row containing "-- Run " was found');
    ok(defined $i_ra, 'AC-8: a row containing "-- Recent activity " was found');
  SKIP: {
        skip 'AC-8 ordering requires both landmark rows to exist', 1
            unless defined $i_run && defined $i_ra;
        cmp_ok($i_run, '<=', $i_ra,
            "AC-8: the Run row index does not come after the Recent-activity title row index (Recent activity is placed LAST, spec S2.4.3; it may now share Run's row instead of dash-filling the full width alone)");
    }

    my $joined = join("\n", map { $_->{text} } @$f);
    # Pluralised: a total of 1 renders the SINGULAR "1 item".
    like($joined, qr/\b1 item\b/,
        'AC-8: the one-item backpack summary still reaches the frame (as a Run-panel row, not a titled panel -- Decision 9)');
}

# ---------------------------------------------------------------------------
# AC-8 (continued) -- THE MIN_COLS DISCIPLINE, replacing the retired "no
# second column" pin (driver ruling 2026-08-08). That old assertion was a
# crude proxy for the real discipline that now governs placement: spec
# S2.4.3 gives the Resources and Spend panels `min_cols =>
# tui::Meter::min_width()` (75) "so tui::Layout::place demotes their band
# row to full width rather than truncating their meters." The surviving,
# spec-backed property is exactly that -- a panel declaring min_cols is
# NEVER placed in a band narrower than it -- asserted directly against
# tui::Layout::place's own return value (package 05,
# plugins/sandbox/scripts/tui/Layout.pm), never a hard-coded width.
# ---------------------------------------------------------------------------
{
    # Shared violation-detector, used on BOTH the real place() output below
    # AND the hand-built counter-fixture, so the two are provably the same
    # check (standing rule: a partition/discipline assertion that cannot
    # fail is worse than the pin it replaced).
    my $min_cols_violations = sub {
        my ($band_rows) = @_;
        my @violations;
        for my $row (@$band_rows) {
            for my $band (@$row) {
                if (ref($band->{panel}) eq 'HASH'
                    && defined $band->{panel}{min_cols}
                    && !ref($band->{panel}{min_cols})
                    && $band->{w} < $band->{panel}{min_cols}) {
                    push @violations, "x=$band->{x} w=$band->{w} min_cols=$band->{panel}{min_cols}";
                }
            }
        }
        return \@violations;
    };

    my $min_cols = tui::Meter::min_width();
    for my $c ($BP, $BP + 10, 120, 150, 200) {
        my $band_rows = tui::Layout::place([ { min_cols => $min_cols }, {} ], $c);
        my $violations = $min_cols_violations->($band_rows);
        is(scalar(@$violations), 0,
            "AC-8: tui::Layout::place(...,$c) never places a min_cols=$min_cols panel in a band narrower than that (@$violations)");
    }

    # COUNTER-FIXTURE: a hand-built band assignment that DOES violate
    # min_cols must be reported as a violation by the SAME detector used
    # above -- proves the check can fail, not just always read zero.
    my $fake_bad_rows = [ [ { panel => { min_cols => $min_cols }, x => 0, w => $min_cols - 1 } ] ];
    my $bad_violations = $min_cols_violations->($fake_bad_rows);
    is(scalar(@$bad_violations), 1,
        'AC-8 counter-fixture: a hand-built band one column narrower than its panel\'s min_cols IS detected as a violation (proves the min_cols check can fail)');
}

# ===========================================================================
# 4.2 The size matrix (DC-2): AC-9, AC-10, AC-18, AC-13
# ===========================================================================

# ---------------------------------------------------------------------------
# AC-9 -> DC-2: over the full ROWS x COLS matrix, compose_frame(\%st,$r,$c)
# neither dies nor warns; row count is exactly $r ($r>=1) / 0 ($r==0); every
# cell satisfies display_width==spans_width==$c, text eq spans_text(spans),
# no ESC, and spans is a non-empty arrayref. Run twice: plain state, and a
# state with backpack + install_warning + status=exited (alert-reduced
# body_h).
# ---------------------------------------------------------------------------
sub _assert_ac9_cell {
    my ($state, $r, $c, $label) = @_;
    my $warns = 0;
    local $SIG{__WARN__} = sub { $warns++ };
    my $f   = eval { Dashboard::compose_frame($state, $r, $c) };
    my $err = $@;
    is($err, '', "AC-9$label: compose_frame($r,$c) does not die");
    is($warns, 0, "AC-9$label: compose_frame($r,$c) does not warn");
  SKIP: {
        skip "compose_frame($r,$c) died; cannot inspect the frame", 6 if $err ne '';
        my $expect_rows = $r >= 1 ? $r : 0;
        is(scalar(@$f), $expect_rows, "AC-9$label: compose_frame($r,$c) returns $expect_rows rows");
        my @bad_w     = grep { Dashboard::display_width($_->{text}) != $c } @$f;
        my @bad_sw    = grep { Dashboard::spans_width($_->{spans}) != $c } @$f;
        my @bad_tx    = grep { $_->{text} ne Dashboard::spans_text($_->{spans}) } @$f;
        my @bad_esc   = grep { $_->{text} =~ /\e/ } @$f;
        my @bad_spans = grep { !$_->{spans} || ref($_->{spans}) ne 'ARRAY' || !@{ $_->{spans} } } @$f;
        is(scalar(@bad_w),     0, "AC-9$label: compose_frame($r,$c) -- every cell display_width == $c");
        is(scalar(@bad_sw),    0, "AC-9$label: compose_frame($r,$c) -- every cell spans_width == $c");
        is(scalar(@bad_tx),    0, "AC-9$label: compose_frame($r,$c) -- every cell text eq spans_text(spans)");
        is(scalar(@bad_esc),   0, "AC-9$label: compose_frame($r,$c) -- no cell text contains an ESC byte");
        is(scalar(@bad_spans), 0, "AC-9$label: compose_frame($r,$c) -- every cell has a non-empty spans arrayref");
    }
}

for my $r (@ROWS) {
    for my $c (@COLS) {
        _assert_ac9_cell(\%st, $r, $c, ' (plain state)');
    }
}

my %st_alert = (
    %st,
    status          => 'exited',
    install_warning => 'backpack install FAILED - run /backpack:install',
    backpack        => { total => 1, approved => 0, items => [ { key => 'apt:jq', approved => 0 } ] },
);
for my $r (@ROWS) {
    for my $c (@COLS) {
        _assert_ac9_cell(\%st_alert, $r, $c, ' (alert-reduced body_h state)');
    }
}

# ---------------------------------------------------------------------------
# AC-10 -> DC-2: over the same matrix, activity_capacity returns a defined
# integer >= 0, never dies, never warns; 0 for every $r <= 2 (incl. $r==0);
# plus the two named edge cases (-1 rows, undef cols).
# ---------------------------------------------------------------------------
for my $r (@ROWS) {
    for my $c (@COLS) {
        my $warns = 0;
        local $SIG{__WARN__} = sub { $warns++ };
        my $cap = eval { Dashboard::activity_capacity(\%st, $r, $c) };
        my $err = $@;
        is($err, '', "AC-10: activity_capacity($r,$c) does not die");
        is($warns, 0, "AC-10: activity_capacity($r,$c) does not warn");
        ok((defined($cap) && $cap =~ /\A\d+\z/),
            "AC-10: activity_capacity($r,$c) returns a defined non-negative integer");
        if ($r <= 2) {
            is($cap, 0, "AC-10: activity_capacity($r,$c) == 0 (rows <= 2)") if $err eq '';
        }
    }
}
# UNRELATED to the breakpoint migration: -1 rows always yields 0 regardless
# of the mode/column count (the row-count clamp fires before any column
# arithmetic), so 100 here is an arbitrary "any" column value. Stays literal.
is(Dashboard::activity_capacity(\%st, -1, 100), 0, 'AC-10: activity_capacity(-1,100) == 0');
# RE-DERIVED (package 06, Family 3): the old literal 9 assumed the
# (now-deleted) Sandbox panel's fixed-region height. Claim preserved
# verbatim -- "undef cols degrades to stacked mode" -- by comparing against
# a KNOWN sub-breakpoint column count (80 < $BP) rather than re-pinning
# whatever number the dissolution happens to produce.
is(Dashboard::activity_capacity(\%st, 24, undef), Dashboard::activity_capacity(\%st, 24, 80),
    'AC-10: activity_capacity(24,undef) == activity_capacity(24,80) (undef cols degrades to stacked mode, same as any other sub-breakpoint width)');

# ---------------------------------------------------------------------------
# AC-18 -> DC-2: odd widths. For $c in (101,121,201) at rows=24, every row is
# exactly $c display columns. UNRELATED to the breakpoint migration: these
# three values exercise ODD-width splitting, not the mode boundary -- all
# three remain comfortably above 90 (as they were above the old 100), so
# their role as "two-column, odd width" samples is unchanged. Stay literal.
#
# SUBJECT RE-POINTED (package 06, Family 1/AC-B4): "-- Sandbox " -> "-- Run "
# (the Sandbox panel is deleted, spec S2.4.3). The fixture gains a `tokens`
# hashref so a second lead panel (Token) exists to pair with Run and
# actually trigger the two-column split this AC probes (spec S2.4.3: the
# Token panel renders only when `ref $state->{tokens} eq 'HASH'`).
#
# RE-POINTED AGAIN (package t01-providers-panel, spec §6): Token is deleted;
# Blueprints is Run's new, unconditional pairing partner (Behavior 17), so
# the `tokens => {}` fixture augmentation is no longer needed to force a
# second lead panel into existence -- it exists regardless of input.
#
# THE "split point is int($c/2)" SUB-CLAIM IS RETIRED, REPORTED RATHER THAN
# INVENTED, driver ruling 2026-08-08 (ACCEPTED): measured directly against
# the real render path, it is FALSE under the new architecture. At c=201
# the Run title cell measured 67 display columns wide, not int(201/2)==100.
# The old claim assumed compose_frame's real two-column split used the same
# 50/50-ish rule as the legacy Dashboard::_col_widths helper (still
# independently, correctly tested by AC-2 above, unchanged) -- true under
# the OLD architecture because the old compose_frame literally called
# _col_widths internally. The NEW compose_frame delegates entirely to
# tui::DashboardScreen -> tui::Layout::place's own algorithm (package 05,
# plugins/sandbox/scripts/tui/Layout.pm -- out of this package's write set
# and spec S6 item 2 says "if one of them is wrong, escalate; do not patch
# it here"), which is free to allocate column widths by a different rule --
# 06's own spec never commits to a specific split ratio, only to
# arrangement (one column below the breakpoint, two at/above it -- spec
# S2.4.9).
#
# THE SURVIVING PROPERTY (driver ruling: what the 50/50 pin was a crude
# proxy for, and criterion 7's direct concern): whatever partition
# tui::Layout::place chooses, it must account for the FULL width exactly --
# nothing overflows past $c, no dead space is left unaccounted. Derived
# from place()'s OWN return value (never a hard-coded width like 67), then
# cross-checked against the REAL rendered row so this is an integration
# check, not a restatement of place()'s own arithmetic. Run/Token declare
# no min_cols (spec S2.4.3 gives that only to Resources/Spend), so two bare
# panel hashrefs are a faithful, minimal stand-in for what decides their
# partition.
# ---------------------------------------------------------------------------
{
    for my $c (101, 121, 201) {
        my $f = Dashboard::compose_frame(\%st, 24, $c);
        is(scalar(grep { Dashboard::display_width($_->{text}) != $c } @$f), 0,
            "AC-18: compose_frame(24,$c) -- every row is exactly $c display columns");
        my ($run_row) = grep { $_->{text} =~ /^$RULE_FILL_RE Run / && $_->{text} =~ /$RULE_FILL_RE Blueprints / } @$f;
        ok($run_row, "AC-18: compose_frame(24,$c) -- a row carries BOTH \"-- Run \" and \"-- Blueprints \" (odd width still triggers two-column mode)");
      SKIP: {
            skip "no paired row found for cols=$c", 1 unless $run_row;
            is(Dashboard::display_width($run_row->{text}), $c,
                "AC-18: compose_frame(24,$c) -- the paired row is exactly $c display columns wide (no overflow/underflow at an odd width)");

            my $band_rows = tui::Layout::place([ {}, {} ], $c);
          SKIP: {
                skip "place([{},{}],$c) did not return the expected 1-row/2-band shape", 2
                    unless @$band_rows == 1 && @{ $band_rows->[0] } == 2;
                my ($b1, $b2) = @{ $band_rows->[0] };
                is($b1->{w} + $b2->{w}, $c,
                    "AC-18: compose_frame(24,$c) -- place()'s own bands account for the full width exactly ($b1->{w} + $b2->{w} == $c)");

                # CHARACTER-decode before slicing (same reasoning as the old
                # split-point check): every glyph on this row is display-width
                # 1, so a character offset is a display-column offset once
                # decoded.
                my $chars = $run_row->{text};
                utf8::decode($chars) unless utf8::is_utf8($chars);
                my $left  = substr($chars, $b1->{x}, $b1->{w});
                my $right = substr($chars, $b2->{x}, $b2->{w});
                is(Dashboard::display_width($left) + Dashboard::display_width($right), $c,
                    "AC-18: compose_frame(24,$c) -- the REAL rendered row's content at place()'s own band offsets/widths accounts for the full width exactly (nothing overflows, no dead space)");
            }
        }
    }

    # COUNTER-FIXTURE (standing rule: a partition assertion that cannot fail
    # is worse than the pin it replaced): a hand-built row whose left
    # segment is deliberately 5 columns wider than place() says must NOT
    # satisfy the same width-sum check.
    my $c = 101;
    my $band_rows = tui::Layout::place([ {}, {} ], $c);
    my ($b1, $b2) = @{ $band_rows->[0] };
    my $bad_left  = ('L' x ($b1->{w} + 5));
    my $bad_right = ('R' x $b2->{w});
    my $bad_total = Dashboard::display_width($bad_left) + Dashboard::display_width($bad_right);
    isnt($bad_total, $c,
        'AC-18 counter-fixture: a deliberately mis-partitioned row (left band 5 columns too wide) is correctly detected as NOT accounting for the full width -- proves the partition check can fail');
}

# ---------------------------------------------------------------------------
# AC-13 -> DC-2, DC-3: degradation ladder preserved at BOTH modes. For $c in
# (20,40,80,100,200): 0 rows -> []; 1 row -> title; 2 rows -> title+footer;
# 3 rows -> 3 cells, last is the footer. compose_frame(...,3,1) -> width 1.
# UNRELATED to the breakpoint migration: this list's job is "some clearly-
# stacked widths (20/40/80, all < 90) and some clearly-two-column widths
# (100/200, both still > 90)" -- 100 is no longer THE breakpoint value
# (Decision 14 moved that to $BP==90) but it is still unambiguously above it,
# so the ladder claim this AC makes is unaffected. Stays literal.
#
# ROLE VOCABULARY RE-POINTED (package 06, Family 2, spec S2.1): the claim
# ("row 0 carries the title role; the last row of a short frame carries the
# footer role") survives verbatim -- only the role NAME's vocabulary moved,
# because compose_frame now composes through tui::DashboardScreen, which
# emits Theme role names exclusively (spec S2.1: "tui::DashboardScreen emits
# Theme role names only on every span it produces"). Derived via
# tui::DashboardScreen::theme_role(), never hand-typed, so this cannot drift
# from the authoritative legacy->Theme mapping table.
# ---------------------------------------------------------------------------
require tui::DashboardScreen;
my $TITLE_ROLE  = tui::DashboardScreen::theme_role('title');
my $FOOTER_ROLE = tui::DashboardScreen::theme_role('footer');

for my $c (20, 40, 80, 100, 200) {
    my $f0 = Dashboard::compose_frame(\%st, 0, $c);
    is(scalar(@$f0), 0, "AC-13: compose_frame(0,$c) -> 0 cells");

    my $f1 = Dashboard::compose_frame(\%st, 1, $c);
    is(scalar(@$f1), 1, "AC-13: compose_frame(1,$c) -> 1 cell");
    is($f1->[0]{role}, $TITLE_ROLE, "AC-13: compose_frame(1,$c) -- cell[0] role eq the Theme title role ($TITLE_ROLE)");

    my $f2 = Dashboard::compose_frame(\%st, 2, $c);
    is(scalar(@$f2), 2, "AC-13: compose_frame(2,$c) -> 2 cells");
    is($f2->[1]{role}, $FOOTER_ROLE, "AC-13: compose_frame(2,$c) -- cell[1] role eq the Theme footer role ($FOOTER_ROLE)");

    my $f3 = Dashboard::compose_frame(\%st, 3, $c);
    is(scalar(@$f3), 3, "AC-13: compose_frame(3,$c) -> 3 cells");
    is($f3->[-1]{role}, $FOOTER_ROLE, "AC-13: compose_frame(3,$c) -- last cell is the footer role ($FOOTER_ROLE)");
}
{
    my $ftiny = Dashboard::compose_frame(\%st, 3, 1);
    is(Dashboard::display_width($ftiny->[0]{text}), 1, 'AC-13: compose_frame(3,1) -- row 0 is exactly 1 display column');
}

# ===========================================================================
# 4.3 Capacity <-> composition agreement (DC-2, DC-3): AC-11, AC-12
# ===========================================================================

# ---------------------------------------------------------------------------
# AC-11 -> DC-3: every row of spec S2.9's oracle table. RE-DERIVED (package
# 06, spec S5 ":756-774", Family 3): claim preserved verbatim -- "capacity is
# total rows minus the fixed region" -- but every literal expected NUMBER in
# the old table assumed the (now-deleted) Sandbox panel's fixed-region
# height AND the old 100-column breakpoint, BOTH of which moved the fixed
# region's size, so no literal survives unchanged. Per spec S5's own
# migration formula:
#   capacity == max(0, rows - 2(title+footer) - _fixed_region_height(state,cols) - 1)
# A live status alert is NOT folded into that formula (the spec's own worked
# example omits it); it is instead asserted as a DIFFERENTIAL against the
# non-alert derivation, preserving the ORIGINAL table's own comment ("a
# status alert costs one more row") as a relative claim rather than a
# guessed absolute term -- this also means the alert term cannot silently
# hide a bug inside _fixed_region_height itself. The backpack rows (T_2=4/6
# in the old comments) need NO special-casing any more: the backpack summary
# is now just one more row INSIDE the Run panel (spec S2.4.8), so
# _fixed_region_height(\%stb, $cols) already reflects it by construction.
# This derivation is anchored to real content by AC-12 below, which counts
# actually-rendered event rows against activity_capacity's return value --
# AC-11 alone would be a tautology-shaped restatement of the same formula
# activity_capacity itself presumably uses, but AC-12 is untouched by this
# migration and still cross-checks it against genuine rendered text.
# ---------------------------------------------------------------------------
sub _ac11_expect {
    my ($state, $r, $c) = @_;
    # chrome_rows(), not the literal 2 it was: the footer gained a rule above
    # it in 2026-08, so the chrome is title + rule + footer. Read from
    # tui::Screen for the same reason the flex floor below is -- an oracle that
    # restates the renderer's constants stops mirroring it the moment one moves.
    my $body = $r - tui::Screen::chrome_rows();
    my $raw  = $body - Dashboard::_fixed_region_height($state, $c) - 1;
    # The Activity panel is tui::Screen's FLEX band and is guaranteed a
    # reservation the fixed region cannot eat, so the old
    # "clamped at 0" floor is now the flex floor. Still DERIVED -- read from
    # tui::Screen rather than restated -- for the same reason the fixed-region
    # term is: a literal here would agree with the renderer only until one of
    # them changed.
    my $floor = tui::Screen::flex_reserve($body) - 1;   # -1 = the panel title
    $raw = $floor if $raw < $floor;
    return $raw > 0 ? $raw : 0;
}

{
    my %exited = (%st, status => 'exited');
    my $bp3    = {
        total    => 3,
        approved => 0,
        items    => [
            { key => 'apt:a', approved => 0 },
            { key => 'apt:b', approved => 0 },
            { key => 'apt:c', approved => 0 },
        ],
    };
    my %stb = (%st, backpack => $bp3);

    my @table = (
        [ \%st,  24, 80,      'stacked: 24x80' ],
        [ \%st,  12, 80,      'stacked: 12x80' ],
        [ \%st,  24, $BP - 1, "boundary: 24x@{[ $BP - 1 ]} (stacked)" ],
        [ \%st,  24, $BP,     "boundary: 24x$BP (two-column)" ],
        [ \%st,  24, 120,     'two-column: 24x120' ],
        [ \%st,  12, 120,     'two-column: 12x120' ],
        [ \%st,  10, 120,     'two-column: 10x120' ],
        [ \%st,  8,  120,     'two-column: 8x120 (clamped from a non-positive body_h)' ],
        [ \%stb, 24, 120,     'two-column with a gathered 3-item backpack (now a Run-panel row, not a panel): 24x120' ],
        [ \%stb, 24, 80,      'stacked with a gathered 3-item backpack (now a Run-panel row, not a panel): 24x80' ],
    );
    for my $row (@table) {
        my ($state, $r, $c, $label) = @$row;
        my $expect = _ac11_expect($state, $r, $c);
        is(Dashboard::activity_capacity($state, $r, $c), $expect,
            "AC-11: activity_capacity($label) == $expect (derived: rows - chrome_rows() - _fixed_region_height - 1, clamped at the flex floor)");
    }

    # RE-POINTED (package t01-providers-panel, operator ruling 2026-08-13):
    # the Providers+Blueprints panels this package adds make the fixed region
    # taller, so at 24 rows the Activity panel is now PINNED AT THE FLEX
    # FLOOR at BOTH 80 and 120 columns -- it was not before this package.
    # Below the floor, a status alert costs NOTHING (both plain and exited
    # clamp to the same floor value), so asserting the differential at 24
    # rows was asserting an invariant at a row count where it structurally
    # cannot be observed. The claim itself ("an alert costs exactly one more
    # row") is TRUE and preserved verbatim; only the row count moves, to one
    # with slack above the floor (measured exhaustively -- see the THRESHOLD
    # block below). 24-row coverage is NOT dropped: see the SATURATION block
    # below, which pins the new floor-pinned behaviour explicitly instead of
    # leaving it an untested accident.
    for my $pair ([31, 80, 'stacked: 31x80'], [28, 120, 'two-column: 28x120']) {
        my ($r, $c, $label) = @$pair;
        my $cap_plain  = Dashboard::activity_capacity(\%st, $r, $c);
        my $cap_exited = Dashboard::activity_capacity(\%exited, $r, $c);
        is($cap_exited, $cap_plain - 1,
            "AC-11: activity_capacity($label, status=exited) == activity_capacity($label) - 1 (a status alert costs exactly one more row -- claim preserved from the original table's own comment; row count chosen to sit above the flex floor)");
    }
}

# ---------------------------------------------------------------------------
# AC-11 SATURATION (rows=24, cols=80/120) -- operator ruling 2026-08-13
# (t01-providers-panel): ACCEPT the taller fixed region, do NOT shrink
# mandated panel content, and assert the new floor-pinned behaviour at 24
# rows explicitly rather than leave it an untested side effect of moving the
# differential assertions above to a taller terminal.
#
# The floor value (3) is HAND-DERIVED from tui::Screen::flex_reserve's own
# documented formula (plugins/sandbox/scripts/tui/Screen.pm:164-172:
# reserve = min(4, floor(body_h/2)), floored at 0) applied to THIS fixture's
# own dimensions -- rows=24 -> body_h = 24-3 = 21 (title, footer rule, footer)
# -> half = floor(21/2) = 10
# -> reserve = min(4,10) = 4 -> activity floor = reserve-1 = 3 (the -1 is the
# panel's own title row, per the existing _ac11_expect/_cap_expect
# convention in this file and t/25-dashboard.t) -- NEVER by calling
# flex_reserve() or activity_capacity() itself, so a future change that
# quietly lowers the reservation (e.g. 4 -> 3, which would drop this floor
# to 2) is caught by this literal going red, not silently re-derived away.
# ---------------------------------------------------------------------------
{
    my $floor24 = 3;
    my %exited24 = (%st, status => 'exited');
    is(Dashboard::activity_capacity(\%st, 24, 80), $floor24,
        "AC-11 saturation: 24x80 (stacked) -- capacity == the hand-derived flex floor ($floor24)");
    is(Dashboard::activity_capacity(\%exited24, 24, 80), $floor24,
        "AC-11 saturation: 24x80 with a status alert -- capacity is STILL $floor24 (the floor absorbs the alert row; no differential at this row count)");
    is(Dashboard::activity_capacity(\%st, 24, 120), $floor24,
        "AC-11 saturation: 24x120 (two-column) -- capacity == the hand-derived flex floor ($floor24)");
    is(Dashboard::activity_capacity(\%exited24, 24, 120), $floor24,
        "AC-11 saturation: 24x120 with a status alert -- capacity is STILL $floor24 (the floor absorbs the alert row; no differential at this row count)");
}

# ---------------------------------------------------------------------------
# AC-11 THRESHOLD -- the exact row count where the differential resumes,
# pinned as a permanent guarantee (not just a one-time implementer
# measurement). Measured exhaustively (row 11-80 scan, both 80 and 120
# columns): diff=0 throughout the dead band with no exceptions, diff=1 from
# the threshold onward with no exceptions. This is the assertion most likely
# to catch a future regression in tui::Screen::flex_reserve's arithmetic,
# because it pins the BOUNDARY itself, not a value comfortably past it.
# ---------------------------------------------------------------------------
{
    my $floor24 = 3; # same hand-derived value as the SATURATION block above;
                      # body_h keeps rising with $r, but the reserve stays
                      # clamped at its max (4) well past row 30, so the floor
                      # is still 3 at every row count probed here.
    my %exited = (%st, status => 'exited');

    # THE THRESHOLD IS LOCATED, NOT PASTED. (Mirrors t/25-dashboard.t's copy of
    # this block; see the longer note there.)
    #
    # The header above says the threshold was measured by an exhaustive row
    # 11-80 scan -- but only the ANSWER was written down (30/31 at 80 cols,
    # 27/28 at 120). That answer is a function of how tall the panels above
    # Activity happen to be, so it moved by one row the moment the Providers
    # panel lost a line (Go and Zen nested under a single OpenCode heading,
    # 2026-08-25), and this block went red over a change that never touched the
    # dead band. Do the scan the header describes, then assert the shape around
    # whatever it finds -- including that the dead band is CONTIGUOUS, which a
    # pasted pair of row numbers could never say.
    # WHERE THE SCAN STARTS, DERIVED RATHER THAN REMEMBERED (mirrors t/25's
    # copy). Below this bound an alert does not merely take a body row, it
    # shrinks the flex RESERVATION itself -- a different mechanism from the dead
    # band, and one inside which the differential genuinely does appear. The old
    # literal 11 was that bound for a two-row chrome; the footer rule made the
    # chrome three rows in 2026-08 and moved it. So compute it: the first row
    # count at which the reservation is already at its ceiling even after an
    # alert has taken a body row.
    my $reserve_cap = tui::Screen::flex_reserve(1_000);
    my $SCAN_LO = 4;
    $SCAN_LO++ until $SCAN_LO > 80
        || tui::Screen::flex_reserve($SCAN_LO - tui::Screen::chrome_rows() - 1) == $reserve_cap;

    my $find_threshold = sub {
        my ($cols) = @_;
        for my $rows ($SCAN_LO .. 80) {
            my $base  = Dashboard::activity_capacity(\%st, $rows, $cols);
            my $alert = Dashboard::activity_capacity(\%exited, $rows, $cols);
            return $rows if $base > $floor24 && $alert == $base - 1;
        }
        return undef;
    };

    for my $cols (80, 120) {
        my $thr = $find_threshold->($cols);
        ok(defined $thr, "AC-11 threshold: a differential threshold exists at ${cols} cols (scan $SCAN_LO..80)");
        next unless defined $thr;

        my $below = Dashboard::activity_capacity(\%st, $thr - 1, $cols);
        is($below, $floor24,
            "AC-11 threshold precondition: @{[$thr-1]}x$cols -- one row below the threshold, capacity is still "
          . "exactly at the floor (proves the dead band, not a coincidence)");
        is(Dashboard::activity_capacity(\%exited, $thr - 1, $cols), $below,
            "AC-11 threshold: @{[$thr-1]}x$cols -- one row BELOW the threshold, a status alert costs NOTHING");

        my $at = Dashboard::activity_capacity(\%st, $thr, $cols);
        cmp_ok($at, '>', $floor24,
            "AC-11 threshold precondition: ${thr}x$cols -- capacity has genuinely left the floor (not still clamped)");
        is(Dashboard::activity_capacity(\%exited, $thr, $cols), $at - 1,
            "AC-11 threshold: ${thr}x$cols -- the FIRST row count where a status alert costs exactly one more row again");

        my @leaks = grep {
            Dashboard::activity_capacity(\%exited, $_, $cols)
              != Dashboard::activity_capacity(\%st, $_, $cols)
        } ($SCAN_LO .. $thr - 1);
        is_deeply(\@leaks, [],
            "AC-11 threshold: the dead band below ${thr}x$cols is contiguous -- no row count inside it "
          . "charges for the alert");
    }
}

# ---------------------------------------------------------------------------
# AC-12 -> DC-2, DC-3: agreement property. With 30 distinct event strings,
# for every matrix member with $c >= 20 (i.e. excluding $c==1, where the
# event text itself is truncated away -- that exclusion is PART OF the
# criterion, not a loophole), the number of frame rows matching /evt-\d\d/
# equals min(30, activity_capacity(...)). Asserted for both a no-backpack and
# a with-backpack state.
# ---------------------------------------------------------------------------
{
    my @events = map { sprintf('evt-%02d', $_) } (1 .. 30);
    my %sev  = (%st, events => \@events);
    my %sevb = (%st, events => \@events,
        backpack => { total => 1, approved => 0, items => [ { key => 'apt:jq', approved => 0 } ] });

    for my $pair ([ \%sev, 'no-backpack' ], [ \%sevb, 'with-backpack' ]) {
        my ($state, $tag) = @$pair;
        for my $r (@ROWS) {
            for my $c (@COLS) {
                next if $c == 1;   # excluded per spec S4.3 AC-12: event text is truncated away at cols=1
                my $f      = Dashboard::compose_frame($state, $r, $c);
                my $joined = join("\n", map { $_->{text} } @$f);
                my $n_shown = () = ($joined =~ /evt-\d\d/g);
                my $cap    = Dashboard::activity_capacity($state, $r, $c);
                my $expect = (30 < $cap) ? 30 : $cap;
                is($n_shown, $expect,
                    "AC-12 ($tag): compose_frame($r,$c) shows min(30,cap)=$expect 'evt-NN' rows");
            }
        }
    }
}

# ===========================================================================
# AC-15 -> DC-3, DC-4 (Decision #12 render-invariant gate): a two-column
# frame's render output still honors the synchronized-output wrapper, the
# clear-before-text convention, and -- the sharpest test in this suite --
# per-side value-keyed diffing survives the join: a state differing ONLY in
# a RIGHT-column field, or ONLY in a LEFT-column field, each repaints EXACTLY
# one row.
# ===========================================================================
{
    # TEN BODY ROWS PLUS THE CHROME, not the literal 12 this was. Twelve meant
    # "ten body rows" when the chrome was title + footer; the footer rule made
    # it three rows in 2026-08, and a remembered 12 pushed the needs_you row
    # off the body -- which turned AC-15.3 red over a layout change that has
    # nothing to say about per-side diffing.
    my $AC15_ROWS = 10 + tui::Screen::chrome_rows();
    my $f = Dashboard::compose_frame(\%st, $AC15_ROWS, 120);

    # 1. wrapper + single clear
    my $full = Dashboard::render_frame(undef, $f, { color => 0 });
    like($full, qr/^\e\[\?2026h/, 'AC-15.1: two-column frame full render opens with synchronized-output begin');
    like($full, qr/\e\[\?2026l$/, 'AC-15.1: two-column frame full render closes with synchronized-output end');
    my $n_clears = () = ($full =~ /\e\[2J\e\[H/g);
    is($n_clears, 1, 'AC-15.1: two-column frame full render clears the screen EXACTLY once');

    # 2. two structurally identical frames -> no clear, zero row repaints
    my $fB       = Dashboard::compose_frame(\%st, $AC15_ROWS, 120);
    my $diffnone = Dashboard::render_frame($f, $fB, { color => 0 });
    unlike($diffnone, qr/\e\[2J/, 'AC-15.2: two structurally identical two-column frames -> no full clear');
    my @moves_none = ($diffnone =~ /\e\[(\d+);1H/g);
    is(scalar(@moves_none), 0,
        'AC-15.2: two structurally identical two-column frames -> zero row repaints (value-keyed diff on joined multi-span cells)');

    # 3a. RIGHT-column-only diff (needs_you, part of the Run panel) -> exactly one row
    my $f_base_right = Dashboard::compose_frame({ %st, busy_age => 5, stay_awake => 1, needs_you => 1 }, $AC15_ROWS, 120);
    my $f_diff_right = Dashboard::compose_frame({ %st, busy_age => 5, stay_awake => 1, needs_you => 7 }, $AC15_ROWS, 120);
    my $diffR = Dashboard::render_frame($f_base_right, $f_diff_right, { color => 0 });
    unlike($diffR, qr/\e\[2J/, 'AC-15.3: RIGHT-column-only (needs_you) diff -> not a full clear');
    my @movesR = ($diffR =~ /\e\[(\d+);1H/g);
    is(scalar(@movesR), 1,
        'AC-15.3: a state differing ONLY in a RIGHT-column field (needs_you) repaints EXACTLY one row');

    # 3b. LEFT-column-only diff (beat_age, part of the Sandbox panel) -> exactly one row
    my $f_diff_left = Dashboard::compose_frame({ %st, beat_age => 999 }, $AC15_ROWS, 120);
    my $diffL = Dashboard::render_frame($f, $f_diff_left, { color => 0 });
    unlike($diffL, qr/\e\[2J/, 'AC-15.3: LEFT-column-only (beat_age) diff -> not a full clear');
    my @movesL = ($diffL =~ /\e\[(\d+);1H/g);
    is(scalar(@movesL), 1,
        'AC-15.3: a state differing ONLY in a LEFT-column field (beat_age) repaints EXACTLY one row');

    # 4. every emitted row repaint matches /\e[\d+;1H\e[K/ and no \e[K follows any text;
    #    the title row still ends with the full "[running]".
    for my $pair ([ $diffR, 'right-diff' ], [ $diffL, 'left-diff' ]) {
        my ($diff_out, $tag) = @$pair;
        my @all_moves = ($diff_out =~ /\e\[\d+;1H/g);
        my @moves_with_clear = ($diff_out =~ /\e\[\d+;1H\e\[K/g);
        is(scalar(@all_moves), scalar(@moves_with_clear),
            "AC-15.4 ($tag): every row-repaint escape matches /\\e[\\d+;1H\\e[K/");
        unlike($diff_out, qr/\]\e\[K/, "AC-15.4 ($tag): no \\e[K follows any already-emitted text");
    }
    # Same re-anchoring as t/25's copy: the property is "the last cell of a
    # full-width row survives the \e[K", not "[running] is at the end". The
    # status block moved to the head of the row (operator request, 2026-08-25),
    # so the element occupying that last cell is now the container name.
    #
    # RE-POINTED AGAIN, same day and for the same reason as t/25's copy: the
    # container id stopped being right-justified, so at 120 columns the last
    # cell is padding -- and an erased SPACE is invisible, which would leave
    # this passing while guarding nothing. Compose at the header's own natural
    # width (derived, never a literal) so the id occupies the final cell again.
    my $nat = Dashboard::spans_text(tui::DashboardScreen::header_spans(\%st, 400));
    $nat =~ s/\s+\z//;
    my $f_nat = Dashboard::compose_frame(\%st, 12, Dashboard::display_width($nat));
    like($f_nat->[0]{text}, qr/\Qclaude-demo-abcd1234\E$/,
        'AC-15.4: the title row still ends with the full container name (last cell not erased)');
}

done_testing();
