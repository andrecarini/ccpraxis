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
my @ROWS = (0, 1, 2, 3, 4, 5, 10, 12, 24, 50);
my @COLS = (1, 20, 39, 40, 50, 79, 80, 99, 100, 101, 120, 200);

# ===========================================================================
# 4.1 The composer (DC-1): AC-1 .. AC-8, AC-17
# ===========================================================================

# ---------------------------------------------------------------------------
# AC-1 -> DC-1: _two_col_min_cols() == 100; _two_col_mode returns 0 for
# undef/-5/0/1/40/79/80/99 and 1 for 100/101/120/200/1000. Table-driven.
# ---------------------------------------------------------------------------
is(Dashboard::_two_col_min_cols(), 100, 'AC-1: _two_col_min_cols() == 100');

for my $c (undef, -5, 0, 1, 40, 79, 80, 99) {
    my $label = defined $c ? $c : 'undef';
    is(Dashboard::_two_col_mode($c), 0, "AC-1: _two_col_mode($label) == 0");
}
for my $c (100, 101, 120, 200, 1000) {
    is(Dashboard::_two_col_mode($c), 1, "AC-1: _two_col_mode($c) == 1");
}

{
    # "Never dies, never warns" over the full documented (all-numeric/undef)
    # value table. NOTE: the spec's own reference implementation of
    # _two_col_mode (S2.2) is a bare `$cols >= _two_col_min_cols()` numeric
    # comparison with no special-casing for a NON-numeric string, which would
    # itself trigger perl's "isn't numeric" warning under `use warnings` --
    # this appears to conflict with S2.2's separate "a non-numeric $cols must
    # not warn" sentence. We therefore only assert "never dies/warns" over the
    # documented numeric/undef table (safe and unambiguous); see the final
    # report for this untestable-as-written tension.
    my $died  = 0;
    my $warns = 0;
    local $SIG{__WARN__} = sub { $warns++ };
    for my $c (undef, -5, 0, 1, 40, 79, 80, 99, 100, 101, 120, 200, 1000) {
        eval { Dashboard::_two_col_mode($c) };
        $died++ if $@;
    }
    is($died, 0, 'AC-1: _two_col_mode never dies across the full numeric/undef value table');
    is($warns, 0, 'AC-1: _two_col_mode never warns across the full numeric/undef value table');
}

# ---------------------------------------------------------------------------
# AC-2 -> DC-1: _col_widths: (100)->(50,50), (101)->(50,51), (200)->(100,100),
# (201)->(100,101); and for every $c in 100..201, lw+rw==$c and rw-lw is 0/1.
# ---------------------------------------------------------------------------
{
    my @cases = ([100, 50, 50], [101, 50, 51], [200, 100, 100], [201, 100, 101]);
    for my $case (@cases) {
        my ($cols, $elw, $erw) = @$case;
        my ($lw, $rw) = Dashboard::_col_widths($cols);
        is($lw, $elw, "AC-2: _col_widths($cols) left half == $elw");
        is($rw, $erw, "AC-2: _col_widths($cols) right half == $erw");
    }
    for my $c (100 .. 201) {
        my ($lw, $rw) = Dashboard::_col_widths($c);
        is($lw + $rw, $c, "AC-2: _col_widths($c): lw+rw == $c");
        ok((($rw - $lw) == 0 || ($rw - $lw) == 1),
            "AC-2: _col_widths($c): rw-lw is 0 or 1 (odd width -> right absorbs the extra column)");
        ok($lw >= 1, "AC-2: _col_widths($c): lw >= 1");
        ok($rw >= $lw, "AC-2: _col_widths($c): rw >= lw");
    }
}

# ---------------------------------------------------------------------------
# AC-3 -> DC-1: _join_cells on two make_cell()s of widths 30 and 50: text is
# the concatenation; span count is the sum; role is the LEFT cell's role;
# display_width/spans_width == 80; text eq spans_text(spans); no ESC.
# Repeated with a 2-column glyph in the left half to prove the join is
# display-width correct, not byte-length correct.
# ---------------------------------------------------------------------------
{
    my $l = Dashboard::make_cell('left side content', 'label', 30);
    my $r = Dashboard::make_cell('right side content here', 'value', 50);
    my $j = Dashboard::_join_cells($l, $r);
    is($j->{text}, $l->{text} . $r->{text}, 'AC-3: joined text is the plain concatenation');
    is(scalar(@{ $j->{spans} }),
        scalar(@{ Dashboard::_cell_spans($l) }) + scalar(@{ Dashboard::_cell_spans($r) }),
        'AC-3: joined span count == sum of the two span counts');
    is($j->{role}, $l->{role}, "AC-3: joined role eq the LEFT cell's role ('label')");
    isnt($j->{role}, $r->{role}, "AC-3: joined role is NOT the right cell's role ('value')");
    is(Dashboard::display_width($j->{text}), 80, 'AC-3: display_width(joined text) == 80');
    is(Dashboard::spans_width($j->{spans}), 80, 'AC-3: spans_width(joined spans) == 80');
    is($j->{text}, Dashboard::spans_text($j->{spans}), 'AC-3: joined text eq spans_text(joined spans)');
    unlike($j->{text}, qr/\e/, 'AC-3: joined text contains no ESC');
}
{
    # 2-column allow-listed glyph (s04 glyph table) in the left half.
    my $glyph_line = [ { text => "\x{1F7E2}", role => 'accent' }, { text => 'ok', role => 'body' } ];
    my $l = Dashboard::make_cell($glyph_line, 'label', 30);
    my $r = Dashboard::make_cell('right side content here', 'value', 50);
    is(Dashboard::display_width($l->{text}), 30, 'AC-3 (glyph): left half is exactly 30 display columns');
    is(Dashboard::display_width($r->{text}), 50, 'AC-3 (glyph): right half is exactly 50 display columns');
    my $j = Dashboard::_join_cells($l, $r);
    is(Dashboard::display_width($j->{text}), 80, 'AC-3 (glyph): joined display_width == 80');
    is(Dashboard::spans_width($j->{spans}), 80, 'AC-3 (glyph): joined spans_width == 80');
    isnt(length($j->{text}), 80,
        'AC-3 (glyph): joined BYTE length() != 80 (the join is measured in display columns, not bytes)');
}

# ---------------------------------------------------------------------------
# AC-4 -> DC-1: _panel_rows({title=>'T', lines=>['a','b']}, 20, 99) returns 4
# cells with the pinned shape; maxh of 3/2/1 drops the blank first, then body
# lines; maxh of 0/-1 returns ().
# ---------------------------------------------------------------------------
{
    my $panel = { title => 'T', lines => [ 'a', 'b' ] };
    my @cells = Dashboard::_panel_rows($panel, 20, 99);
    is(scalar(@cells), 4, 'AC-4: _panel_rows returns 4 cells (title + 2 body lines + blank)');
    is($cells[0]{role}, 'panel-title', 'AC-4: cell[0] role is panel-title');
    like($cells[0]{text}, qr/^-- T -+$/, 'AC-4: cell[0] text is the dash-filled panel title');
    is($cells[1]{spans}[0]{text}, '  ', 'AC-4: cell[1] first span is the 2-space body indent');
    is($cells[1]{role}, 'body', 'AC-4: cell[1] role is body');
    is($cells[3]{role}, 'blank', 'AC-4: cell[3] role is blank');
    is(scalar(grep { Dashboard::display_width($_->{text}) != 20 } @cells), 0,
        'AC-4: every cell is exactly 20 display columns');

    my %expect_count = (3 => 3, 2 => 2, 1 => 1);
    for my $maxh (sort keys %expect_count) {
        my @c = Dashboard::_panel_rows($panel, 20, $maxh);
        is(scalar(@c), $expect_count{$maxh},
            "AC-4: _panel_rows(..., maxh=$maxh) returns $expect_count{$maxh} cells (blank dropped first, then body lines)");
    }
    for my $maxh (0, -1) {
        my @c = Dashboard::_panel_rows($panel, 20, $maxh);
        is(scalar(@c), 0, "AC-4: _panel_rows(..., maxh=$maxh) returns ()");
    }
}

# ---------------------------------------------------------------------------
# AC-5, AC-6 -> DC-1: _two_col_rows -- exact composition, then truncation.
# Shared fixture: L has 5 lines (natural height 7), R has 1 line (natural
# height 3).
# ---------------------------------------------------------------------------
my $ac56_L = { title => 'L', lines => [ 'l1', 'l2', 'l3', 'l4', 'l5' ] };
my $ac56_R = { title => 'R', lines => [ 'r1' ] };

{
    # AC-5: generous $maxh -> exactly max(7,3)==7 cells, each exactly 100
    # columns; for ASCII content, each half matches the standalone
    # _panel_rows output (or 50 spaces once R has run out).
    my @rows = Dashboard::_two_col_rows($ac56_L, $ac56_R, 100, 99);
    is(scalar(@rows), 7, 'AC-5: max(1+5+1, 1+1+1) == 7 cells returned');
    is(scalar(grep { Dashboard::display_width($_->{text}) != 100 } @rows), 0,
        'AC-5: every cell is exactly 100 display columns');
    is(scalar(grep { Dashboard::spans_width($_->{spans}) != 100 } @rows), 0,
        'AC-5: every cell has spans_width == 100');

    my @Lrows = Dashboard::_panel_rows($ac56_L, 50, 99);
    my @Rrows = Dashboard::_panel_rows($ac56_R, 50, 99);
    for my $i (0 .. 6) {
        is(substr($rows[$i]{text}, 0, 50), $Lrows[$i]{text},
            "AC-5: row $i, columns [0,50) match the standalone _panel_rows(L,50,99) cell text");
        my $expect_right = $i < scalar(@Rrows) ? $Rrows[$i]{text} : (' ' x 50);
        is(substr($rows[$i]{text}, 50), $expect_right,
            "AC-5: row $i, columns [50,100) match the standalone R cell text (or 50 blank spaces)");
    }
}

{
    # AC-6: truncation -- maxh=5 -> exactly 5 cells, both halves cut at the
    # SAME row (row i == _join_cells(L_rows[i], R_rows[i])); maxh=1 -> 1 cell
    # with BOTH panel titles; maxh=0/-3 -> 0 cells.
    my @rows5 = Dashboard::_two_col_rows($ac56_L, $ac56_R, 100, 5);
    is(scalar(@rows5), 5, 'AC-6: maxh=5 -> exactly 5 cells');
    my @Lrows5 = Dashboard::_panel_rows($ac56_L, 50, 5);
    my @Rrows5 = Dashboard::_panel_rows($ac56_R, 50, 5);
    for my $i (0 .. 4) {
        my $lc = $Lrows5[$i] // Dashboard::make_cell('', 'blank', 50);
        my $rc = $Rrows5[$i] // Dashboard::make_cell('', 'blank', 50);
        my $expect = Dashboard::_join_cells($lc, $rc);
        is_deeply($rows5[$i], $expect,
            "AC-6: maxh=5, row $i equals _join_cells(L_rows[$i], R_rows[$i]) (both halves cut at the same row)");
    }

    my @rows1 = Dashboard::_two_col_rows($ac56_L, $ac56_R, 100, 1);
    is(scalar(@rows1), 1, 'AC-6: maxh=1 -> exactly 1 cell');
    like($rows1[0]{text}, qr/-- L /, 'AC-6: maxh=1 -- the single row contains "-- L "');
    like($rows1[0]{text}, qr/-- R /, 'AC-6: maxh=1 -- the single row ALSO contains "-- R "');

    for my $maxh (0, -3) {
        my @r = Dashboard::_two_col_rows($ac56_L, $ac56_R, 100, $maxh);
        is(scalar(@r), 0, "AC-6: maxh=$maxh -> 0 cells");
    }
}

# ---------------------------------------------------------------------------
# AC-7 -> DC-1 (narrow fallback, asserted): compose_frame(\%st,24,99) never
# joins Sandbox+Run on one row; compose_frame(\%st,24,100) joins them on
# EXACTLY one row. Both frames stay exactly $rows x $cols.
# ---------------------------------------------------------------------------
{
    my $f99 = Dashboard::compose_frame(\%st, 24, 99);
    is(scalar(@$f99), 24, 'AC-7: compose_frame(24,99) returns exactly 24 rows');
    is(scalar(grep { Dashboard::display_width($_->{text}) != 99 } @$f99), 0,
        'AC-7: compose_frame(24,99) -- every row is exactly 99 display columns');
    my $both99 = grep { $_->{text} =~ /-- Sandbox / && $_->{text} =~ /-- Run / } @$f99;
    is($both99, 0, 'AC-7: 24x99 -- no single row contains BOTH "-- Sandbox" and "-- Run" (still stacked)');
    my ($sb99) = grep { $_->{text} =~ /^-- Sandbox -+$/ } @$f99;
    ok($sb99, 'AC-7: 24x99 -- some row matches /^-- Sandbox -+$/');
    is(Dashboard::display_width($sb99->{text}), 99, 'AC-7: that row is exactly 99 display columns') if $sb99;

    my $f100 = Dashboard::compose_frame(\%st, 24, 100);
    is(scalar(@$f100), 24, 'AC-7: compose_frame(24,100) returns exactly 24 rows');
    is(scalar(grep { Dashboard::display_width($_->{text}) != 100 } @$f100), 0,
        'AC-7: compose_frame(24,100) -- every row is exactly 100 display columns');
    my $both100 = grep { $_->{text} =~ /-- Sandbox / && $_->{text} =~ /-- Run / } @$f100;
    is($both100, 1, 'AC-7: 24x100 -- EXACTLY one row contains BOTH "-- Sandbox " and "-- Run " (two-column mode)');
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

    my ($i_sb) = grep { $f->[$_]{text} =~ /-- Sandbox / } 0 .. $#$f;
    my ($i_bp) = grep { $f->[$_]{text} =~ /^-- Backpack -+$/ } 0 .. $#$f;
    my ($i_ra) = grep { $f->[$_]{text} =~ /^-- Recent activity -+$/ } 0 .. $#$f;
    ok(defined $i_sb, 'AC-8: a row containing "-- Sandbox " was found');
    ok(defined $i_bp, 'AC-8: a full-width "-- Backpack" title row was found (no second column)');
    ok(defined $i_ra, 'AC-8: a full-width "-- Recent activity" title row was found (no second column)');
  SKIP: {
        skip 'AC-8 ordering requires all three landmark rows to exist', 2
            unless defined $i_sb && defined $i_bp && defined $i_ra;
        cmp_ok($i_sb, '<', $i_bp, 'AC-8: the Sandbox row index precedes the Backpack title row index');
        cmp_ok($i_bp, '<', $i_ra, 'AC-8: the Backpack title row index precedes the Recent-activity title row index');
    }
}

# ---------------------------------------------------------------------------
# AC-17 -> DC-1: pairing guard. (_fixed_panels)[0]/[1] are unconditionally
# Sandbox/Run (D7); _two_col_rows/_body_rows must not die on a degenerate
# (empty-lines) panel pair.
# ---------------------------------------------------------------------------
{
    my @fp = Dashboard::_fixed_panels(\%st);
    is($fp[0]{title}, 'Sandbox', "AC-17: (_fixed_panels)[0]{title} eq 'Sandbox'");
    is($fp[1]{title}, 'Run', "AC-17: (_fixed_panels)[1]{title} eq 'Run'");

    my $empty_panel = { title => 'Empty', lines => [] };
    my @rows = eval { Dashboard::_two_col_rows($empty_panel, $empty_panel, 100, 10) };
    is($@, '', 'AC-17: _two_col_rows with two empty-lines panels does not die');
    is(scalar(grep { Dashboard::display_width($_->{text}) != 100 } @rows), 0,
        'AC-17: _two_col_rows(empty-lines panels) -- every returned row is exactly 100 display columns');
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
is(Dashboard::activity_capacity(\%st, -1, 100), 0, 'AC-10: activity_capacity(-1,100) == 0');
is(Dashboard::activity_capacity(\%st, 24, undef), 9, 'AC-10: activity_capacity(24,undef) == 9 (undef cols -> stacked)');

# ---------------------------------------------------------------------------
# AC-18 -> DC-2: odd widths. For $c in (101,121,201) at rows=24, every row is
# exactly $c display columns, and the joined region's split point is
# int($c/2) (for ASCII content, the left half matches the standalone left
# half-cell text).
# ---------------------------------------------------------------------------
for my $c (101, 121, 201) {
    my $f = Dashboard::compose_frame(\%st, 24, $c);
    is(scalar(grep { Dashboard::display_width($_->{text}) != $c } @$f), 0,
        "AC-18: compose_frame(24,$c) -- every row is exactly $c display columns");
    my ($sb_row) = grep { $_->{text} =~ /^-- Sandbox / } @$f;
    ok($sb_row, "AC-18: compose_frame(24,$c) -- a Sandbox title row was found");
  SKIP: {
        skip "no Sandbox row found for cols=$c", 1 unless $sb_row;
        my $lw = int($c / 2);
        my ($sandbox_panel) = Dashboard::_fixed_panels(\%st);
        my @left_alone = Dashboard::_panel_rows($sandbox_panel, $lw, 99);
        is(substr($sb_row->{text}, 0, $lw), $left_alone[0]{text},
            "AC-18: compose_frame(24,$c) -- split point is int($c/2)==$lw (left half matches the standalone cell text)");
    }
}

# ---------------------------------------------------------------------------
# AC-13 -> DC-2, DC-3: degradation ladder preserved at BOTH modes. For $c in
# (20,40,80,100,200): 0 rows -> []; 1 row -> title; 2 rows -> title+footer;
# 3 rows -> 3 cells, last is the footer. compose_frame(...,3,1) -> width 1.
# ---------------------------------------------------------------------------
for my $c (20, 40, 80, 100, 200) {
    my $f0 = Dashboard::compose_frame(\%st, 0, $c);
    is(scalar(@$f0), 0, "AC-13: compose_frame(0,$c) -> 0 cells");

    my $f1 = Dashboard::compose_frame(\%st, 1, $c);
    is(scalar(@$f1), 1, "AC-13: compose_frame(1,$c) -> 1 cell");
    is($f1->[0]{role}, 'title', "AC-13: compose_frame(1,$c) -- cell[0] role eq title");

    my $f2 = Dashboard::compose_frame(\%st, 2, $c);
    is(scalar(@$f2), 2, "AC-13: compose_frame(2,$c) -> 2 cells");
    is($f2->[1]{role}, 'footer', "AC-13: compose_frame(2,$c) -- cell[1] role eq footer");

    my $f3 = Dashboard::compose_frame(\%st, 3, $c);
    is(scalar(@$f3), 3, "AC-13: compose_frame(3,$c) -> 3 cells");
    is($f3->[-1]{role}, 'footer', "AC-13: compose_frame(3,$c) -- last cell is the footer");
}
{
    my $ftiny = Dashboard::compose_frame(\%st, 3, 1);
    is(Dashboard::display_width($ftiny->[0]{text}), 1, 'AC-13: compose_frame(3,1) -- row 0 is exactly 1 display column');
}

# ===========================================================================
# 4.3 Capacity <-> composition agreement (DC-2, DC-3): AC-11, AC-12
# ===========================================================================

# ---------------------------------------------------------------------------
# AC-11 -> DC-3: every row of spec S2.9's oracle table, asserted literally.
# The three unchanged stacked values, the boundary pair, every two-column
# value, and both backpack cases (T_2=6 for a gathered 3-item backpack).
# (The canonical home for these oracles is t/25-dashboard.t PART 9; this is a
# cross-check per spec S4.6.)
# ---------------------------------------------------------------------------
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
        [ \%st,     24, 80,  9,  'stacked: 24x80 (unchanged)' ],
        [ \%exited, 24, 80,  8,  'stacked: 24x80, status=exited (unchanged)' ],
        [ \%st,     12, 80,  0,  'stacked: 12x80 (unchanged)' ],
        [ \%st,     24, 99,  9,  'boundary: 24x99 (stacked)' ],
        [ \%st,     24, 100, 14, 'boundary: 24x100 (two-column)' ],
        [ \%st,     24, 120, 14, 'two-column: 24x120' ],
        [ \%exited, 24, 120, 13, 'two-column: 24x120, status=exited' ],
        [ \%st,     12, 120, 2,  'two-column: 12x120' ],
        [ \%st,     10, 120, 0,  'two-column: 10x120' ],
        [ \%st,     8,  120, 0,  'two-column: 8x120 (clamped from a negative body_h)' ],
        [ \%stb,    24, 120, 8,  'two-column with a gathered 3-item backpack (T_2=6): 24x120' ],
        [ \%stb,    24, 80,  3,  'stacked with a gathered 3-item backpack (T_2=6): 24x80' ],
    );
    for my $row (@table) {
        my ($state, $r, $c, $expect, $label) = @$row;
        is(Dashboard::activity_capacity($state, $r, $c), $expect,
            "AC-11: activity_capacity($label) == $expect");
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
    my $f = Dashboard::compose_frame(\%st, 12, 120);

    # 1. wrapper + single clear
    my $full = Dashboard::render_frame(undef, $f, { color => 0 });
    like($full, qr/^\e\[\?2026h/, 'AC-15.1: two-column frame full render opens with synchronized-output begin');
    like($full, qr/\e\[\?2026l$/, 'AC-15.1: two-column frame full render closes with synchronized-output end');
    my $n_clears = () = ($full =~ /\e\[2J\e\[H/g);
    is($n_clears, 1, 'AC-15.1: two-column frame full render clears the screen EXACTLY once');

    # 2. two structurally identical frames -> no clear, zero row repaints
    my $fB       = Dashboard::compose_frame(\%st, 12, 120);
    my $diffnone = Dashboard::render_frame($f, $fB, { color => 0 });
    unlike($diffnone, qr/\e\[2J/, 'AC-15.2: two structurally identical two-column frames -> no full clear');
    my @moves_none = ($diffnone =~ /\e\[(\d+);1H/g);
    is(scalar(@moves_none), 0,
        'AC-15.2: two structurally identical two-column frames -> zero row repaints (value-keyed diff on joined multi-span cells)');

    # 3a. RIGHT-column-only diff (needs_you, part of the Run panel) -> exactly one row
    my $f_base_right = Dashboard::compose_frame({ %st, busy_age => 5, stay_awake => 1, needs_you => 1 }, 12, 120);
    my $f_diff_right = Dashboard::compose_frame({ %st, busy_age => 5, stay_awake => 1, needs_you => 7 }, 12, 120);
    my $diffR = Dashboard::render_frame($f_base_right, $f_diff_right, { color => 0 });
    unlike($diffR, qr/\e\[2J/, 'AC-15.3: RIGHT-column-only (needs_you) diff -> not a full clear');
    my @movesR = ($diffR =~ /\e\[(\d+);1H/g);
    is(scalar(@movesR), 1,
        'AC-15.3: a state differing ONLY in a RIGHT-column field (needs_you) repaints EXACTLY one row');

    # 3b. LEFT-column-only diff (beat_age, part of the Sandbox panel) -> exactly one row
    my $f_diff_left = Dashboard::compose_frame({ %st, beat_age => 999 }, 12, 120);
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
    like($f->[0]{text}, qr/\[running\]$/, 'AC-15.4: the title row still ends with the full "[running]"');
}

done_testing();
