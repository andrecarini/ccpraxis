#!/usr/bin/env perl
# THE PANEL GRID'S BORDERS -- glyph choice, collapsing, and viewport edges.
#
# The grid landed (operator request, 2026-08-25: borders on all sides except
# the viewport edges, adjacent borders collapsed into one) with NO oracle at
# all. The operator then found two defects by eye that the entire suite ran
# green through:
#
#   1. The first body row's seam between the main region and the side column
#      drew a CROSS. A cross claims a line in all four directions, but that row
#      is the top of the body -- nothing arrives from above. It should be a
#      tee-down. The chooser looked only at "rule on the left, rule on the
#      right" and assumed the vertical always continued both ways.
#
#   2. The single rule glyph leading each panel title carried text.primary
#      while the identical glyphs filling the rest of the same line carried
#      'rule', so every title line visibly changed colour one column in.
#      Correct when the lead was the ASCII '-- ' caption; wrong the moment it
#      became a rule glyph.
#
# Both are pinned below, along with the structural properties they sit inside,
# because a glyph table is exactly the kind of thing that looks right in review
# and wrong on screen.
#
# Hard constraint (mirrors t/40, t/65): this file MUST NOT `use utf8`. Glyphs
# come from Theme, never from a literal.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');
require Theme;
require tui::Screen;
require tui::Layout;

my $H     = Theme::glyph('rule.h');
my $V     = Theme::glyph('rule.v');
my $TDOWN = Theme::glyph('tee.down');
my $TUP   = Theme::glyph('tee.up');
my $TLEFT = Theme::glyph('tee.left');
my $CROSS = Theme::glyph('cross');
ok(defined $H && defined $V && defined $TDOWN && defined $TUP && defined $TLEFT && defined $CROSS,
    'fixture: every junction glyph this file needs is declared in Theme');

sub st {
    return {
        project_name => 'demo', container => 'c1', status => 'running',
        spinner_idx => 1, beat_age => 50, uptime => 50,
        events => [ map { { ts => "13:2$_", text => "evt $_" } } (0 .. 5) ],
        @_,
    };
}
sub frame { my ($cols, $rows) = @_; return Dashboard::compose_frame(st(), $rows // 14, $cols) }

# Decoded characters, so column indices mean columns rather than bytes.
sub chars {
    my ($text) = @_;
    my $t = $text;
    utf8::decode($t) unless utf8::is_utf8($t);
    return [ split //, $t ];
}
sub dec { my ($g) = @_; my $c = $g; utf8::decode($c) unless utf8::is_utf8($c); return $c }

my ($dH, $dV, $dTDOWN, $dTUP, $dTLEFT, $dCROSS) = map { dec($_) } ($H, $V, $TDOWN, $TUP, $TLEFT, $CROSS);

# ===========================================================================
# A. THE FIRST BODY ROW HAS NOTHING ABOVE IT.
#
# Every junction on the first body row is therefore a tee-DOWN or a plain
# horizontal -- never a cross, never a tee-up, both of which assert a line
# running up into the header row.
# ===========================================================================
{
    my $f = frame(170);
    my $row1 = chars($f->[1]{text});          # row 0 is the header
    my %seen;
    $seen{$_}++ for @$row1;

    is(($seen{$dCROSS} || 0), 0,
        'A: the first body row contains NO cross -- nothing comes from above it')
        or diag($f->[1]{text});
    is(($seen{$dTUP} || 0), 0,
        'A: the first body row contains no tee-up either, for the same reason');
    cmp_ok(($seen{$dTDOWN} || 0), '>=', 1,
        'A: it does contain at least one tee-down (the grid really is dividing here -- not vacuous)');
}

# ===========================================================================
# B. THE LAST BODY ROW HAS NOTHING BELOW IT, symmetrically.
# ===========================================================================
{
    my $f = frame(170);
    my $last = chars($f->[$#$f - 1]{text});   # last row before the footer
    my %seen;
    $seen{$_}++ for @$last;
    is(($seen{$dCROSS} || 0), 0, 'B: the last body row contains no cross');
    is(($seen{$dTDOWN} || 0), 0, 'B: ...and no tee-down -- nothing continues below it');
}

# ===========================================================================
# C. NOTHING IS DRAWN AT THE VIEWPORT EDGES.
# ===========================================================================
{
    for my $cols (100, 150, 200) {
        my $f = frame($cols);
        my (@first_col, @last_col);
        for my $i (1 .. $#$f - 1) {           # body rows only
            my $c = chars($f->[$i]{text});
            push @first_col, $c->[0];
            push @last_col,  $c->[$#$c];
        }
        my $edge_glyphs = grep { defined $_ && ($_ eq $dV || $_ eq $dTDOWN || $_ eq $dTUP || $_ eq $dCROSS) }
                          (@first_col, @last_col);
        is($edge_glyphs, 0,
            "C: cols=$cols -- no vertical or junction glyph sits in the first or last column (viewport edges are bare)");
    }
}

# ===========================================================================
# D. ADJACENT PANELS SHARE ONE COLUMN.
#
# The collapse property, expressed structurally: no two vertical glyphs are
# ever side by side on the same row. Two adjacent verticals would mean each
# panel drew its own border against its neighbour's.
# ===========================================================================
{
    for my $cols (100, 150, 200) {
        my $f = frame($cols);
        my $doubled = 0;
        for my $i (1 .. $#$f - 1) {
            my $c = chars($f->[$i]{text});
            for my $j (0 .. $#$c - 1) {
                $doubled++ if $c->[$j] eq $dV && $c->[$j + 1] eq $dV;
            }
        }
        is($doubled, 0,
            "D: cols=$cols -- no two vertical borders are adjacent (collapsed into one, never drawn twice)");
    }
}

# ===========================================================================
# E. A SINGLE-COLUMN LAYOUT DRAWS NO VERTICALS AT ALL.
#
# There is no adjacency below the breakpoint, so there is nothing to separate.
# Paired with C/D above: an implementation that drew borders unconditionally
# would pass those and fail this.
# ===========================================================================
{
    my $narrow = tui::Layout::BREAKPOINT_TWO_COL() - 1;
    my $f = frame($narrow);
    my $verticals = 0;
    for my $i (1 .. $#$f - 1) {
        my $c = chars($f->[$i]{text});
        $verticals += grep { $_ eq $dV || $_ eq $dTDOWN || $_ eq $dTUP || $_ eq $dCROSS || $_ eq $dTLEFT } @$c;
    }
    is($verticals, 0,
        "E: cols=$narrow (single column) -- no vertical or junction glyph anywhere; nothing is adjacent to anything");
}

# ===========================================================================
# F. THE TITLE LINE IS ONE COLOUR OF RULE.
#
# Every rule glyph on a panel title line carries the 'rule' role; only the
# title TEXT carries the text role. The lead glyph used to be bundled into the
# text span, so it rendered brighter than the line it was part of and each
# title visibly changed colour one column in.
# ===========================================================================
{
    my $f = frame(170);
    my @offenders;
    for my $i (1 .. $#$f - 1) {
        my $spans = $f->[$i]{spans} or next;
        next unless grep { defined($_->{text}) && $_->{text} =~ /\Q$H\E/ } @$spans;
        for my $s (@$spans) {
            next unless defined $s->{text} && length $s->{text};
            # A span made ENTIRELY of rule/junction glyphs must be role 'rule'.
            my $only_rule = $s->{text} =~ /\A(?:\Q$H\E|\Q$V\E|\Q$TDOWN\E|\Q$TUP\E|\Q$TLEFT\E|\Q$CROSS\E)+\z/;
            next unless $only_rule;
            push @offenders, "row $i: [$s->{text}] role=" . ($s->{role} // 'undef')
                unless ($s->{role} // '') eq 'rule';
        }
    }
    is(scalar(@offenders), 0,
        'F: every span made only of rule glyphs carries the rule role -- no bright glyph in a dim line')
        or diag(join "\n", @offenders);

    # THE DEFECT ITSELF, pinned directly. The check above scans spans made
    # ENTIRELY of rule glyphs -- which the original bug was NOT: the lead glyph
    # was bundled with the title into ONE span reading "<rule> Run ", so it
    # slipped straight through that filter. Asserting that a title line BEGINS
    # with a pure-rule span in the rule role is what actually catches it, and
    # is the assertion this section exists for.
    # The scan stops before ALL the chrome below the body, not just the footer.
    # Since 2026-08 a full-width horizontal rule sits above the footer, and its
    # first span is a long run of rule glyphs -- which looks exactly like a
    # title line to the test below, and is not one: it has no title.
    for my $i (1 .. $#$f - (tui::Screen::chrome_rows() - 1)) {
        my $spans = $f->[$i]{spans} or next;
        next unless @$spans;
        my $first = $spans->[0];
        next unless defined $first->{text} && $first->{text} =~ /\A\Q$H\E/;   # a title line
        is($first->{text}, $H,
            "F: row $i -- the title line's first span is the lead glyph ALONE, not glyph+title bundled together");
        is(($first->{role} // ''), 'rule',
            "F: row $i -- and that lead glyph carries the rule role, matching the line it leads");
    }

    # Positive control: the title TEXT is still not styled as rule, so F is not
    # passing merely because everything got painted 'rule'.
    my ($title_span) = grep { defined($_->{text}) && $_->{text} =~ /\bRun\b/ }
                       @{ $f->[1]{spans} || [] };
    ok($title_span, 'F CONTROL: a span carrying the panel title text exists');
    isnt(($title_span->{role} // ''), 'rule',
        'F CONTROL: ...and it is NOT the rule role -- the title is content, not decoration');
}

# ===========================================================================
# G. Geometry, across widths and with and without a side column.
# ===========================================================================
{
    for my $cols (60, 90, 100, 130, 150, 200) {
        for my $rows (10, 14, 24) {
            my $f = Dashboard::compose_frame(st(), $rows, $cols);
            is(scalar(@$f), $rows, "G: ${cols}x$rows -- exactly $rows rows");
            my $bad = grep { Dashboard::display_width($_->{text}) != $cols } @$f;
            is($bad, 0, "G: ${cols}x$rows -- every row is exactly $cols display columns");
        }
    }
}

# ===========================================================================
# H. THE FOOTER'S BORDER (operator request, 2026-08-25).
#
# This is the first horizontal rule in the layout that is NOT a panel title
# line. Every other one is a panel's title doing double duty as its top border,
# which is why the grid costs no extra rows and why there are no bottom borders
# anywhere. The footer has no panel above it to borrow a title rule from, so
# this rule is constructed -- and it is the only rule that costs a row.
#
# Three claims, and the third is the one worth having: it is drawn, it spans the
# full width, and its JUNCTIONS agree with the row above it. A rule that ignores
# what meets it draws a straight line through a vertical border and looks broken
# at exactly the seams the rest of this file exists to protect.
# ===========================================================================
{
    my %ok_rule = map { dec($_) => 1 } grep { defined && length }
                  ($H, $TUP, $TLEFT, Theme::glyph('tee.right'),
                   Theme::glyph('corner.bl'), Theme::glyph('corner.br'));
    my %down    = map { dec($_) => 1 } grep { defined && length }
                  ($V, $TDOWN, $TLEFT, Theme::glyph('tee.right'), $CROSS,
                   Theme::glyph('corner.tl'), Theme::glyph('corner.tr'));

    # 4 rows: the last body row must carry the panel-grid seams that this
    # section is about. At 14 rows the last body row is inside the Activity
    # panel, which spans its whole band and has no vertical to terminate --
    # true, and not what needs pinning. A frame just tall enough for the first
    # band puts the seam directly above the footer rule.
    for my $case ([100, 4], [150, 4], [100, 14], [150, 14]) {
        my ($cols, $rows) = @$case;
        my $f = Dashboard::compose_frame(st(), $rows, $cols);
        my $rule_i = $#$f - 1;                 # immediately above the footer

        my $rt = chars($f->[$rule_i]{text});
        my $bad = grep { !$ok_rule{$_} } @$rt;
        is($bad, 0, "H: ${cols}x$rows -- the row above the footer is made only of horizontal-rule and terminating-junction glyphs")
            or diag('  [' . $f->[$rule_i]{text} . ']');
        is(scalar(@$rt), $cols, "H: ${cols}x$rows -- the footer rule spans the full width");

        # JUNCTION AGREEMENT: every column where the row ABOVE carries a glyph
        # with a downward stroke must carry a terminating junction here, and no
        # other column may. Derived from the rendered rows, exactly as
        # tui::Screen derives it -- not from a model of where panels landed.
        my $above = chars($f->[$rule_i - 1]{text});
        my @want = grep { $down{ $above->[$_] } } 0 .. $#$above;
        my @got  = grep { $rt->[$_] ne dec($H) } 0 .. $#$rt;
        is_deeply(\@got, \@want,
            "H: ${cols}x$rows -- the footer rule carries a junction at exactly the columns where a "
          . 'vertical border terminates on it, and nowhere else')
            or diag("  above: [$f->[$rule_i - 1]{text}]\n  rule:  [$f->[$rule_i]{text}]");
    }

    # Non-vacuity, stated once: at 4 rows the row above the rule IS the first
    # band's title line, which carries real vertical seams -- so the agreement
    # check above is comparing something rather than two empty lists.
    # WIDTHS RAISED 100/150 -> 200/240, 2026-08-28.
    #
    # The claim is unchanged: at 4 rows the row above the footer rule is the
    # first band's title line, and it must carry a real vertical seam -- so the
    # agreement check above is comparing something rather than two empty lists.
    #
    # What moved is where a seam EXISTS. The grid was reorganised so Run pairs
    # with Resources, which declares min_cols 75 against Run's 44 -- a band holds
    # both only once the main region has ~119 columns. At 100 and 150 (main
    # regions of 100 and 100, the latter after a 50-column side column) the
    # panels stack, so the title row is a single full-width rule with no seam,
    # and this non-vacuity check was correctly reporting that it had nothing to
    # measure.
    #
    # Verified: seams=0 at 150, seams=1 at 200 and 240.
    for my $cols (200, 240) {
        my $f = Dashboard::compose_frame(st(), 4, $cols);
        my $above = chars($f->[$#$f - 2]{text});
        my $n = grep { $down{$_} } @$above;
        cmp_ok($n, '>', 0,
            "H: ${cols}x4 non-vacuity -- the row above the footer rule really does carry at least "
          . 'one terminating vertical')
            or diag('  [' . $f->[$#$f - 2]{text} . ']');
    }
}

done_testing();
