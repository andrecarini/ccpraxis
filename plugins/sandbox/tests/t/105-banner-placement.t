#!/usr/bin/env perl
# WHERE BANNERS RENDER, and what that costs the layout.
#
# Operator report, 2026-08-25: "Any errors, warnings and etc could go into that
# same column instead of pushing everything down."
#
# A banner is full-width and stacks ABOVE the panel grid, so every alert cost
# the whole layout a row and shoved every panel down -- on a 200-column
# terminal, to say one short sentence. When a side column exists it is the
# natural home: it already spans the full body height, it is where transient,
# time-ordered content already lives, and putting alerts there costs the main
# region nothing.
#
# Below the responsive breakpoint there is no side column, so banners stay
# full-width above the panels (operator's own choice of fallback -- a narrow
# side column is too cramped to read a wrapped alert in).
#
# WHY THIS FILE EXISTS AT ALL. When the change landed, every layout-sensitive
# oracle in the suite stayed green -- t/92, t/73, t/77, t/40, t/25, t/66, t/102.
# Nothing anywhere asserted WHERE a banner goes, so the relocation was
# invisible to the suite in both directions: it could equally have been broken
# by accident and stayed green. That is the gap this closes.
#
# NON-VACUITY: each placement claim is paired with its opposite at the other
# side of the breakpoint, so an implementation that put banners in one place
# unconditionally fails one half or the other.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');
require tui::Screen;
require Theme;

my $RULE_LEAD = Theme::glyph('rule.h');

# A width that certainly HAS a side column, and one that certainly does not.
my $WIDE   = 150;
my $NARROW = 80;
ok(tui::Screen::side_column_width($WIDE) > 0,  "fixture: cols=$WIDE has a side column");
is(tui::Screen::side_column_width($NARROW), 0, "fixture: cols=$NARROW has no side column");

my $ALERT = 'podman machine is low on disk - 2.1 GB free';

sub frame {
    my ($cols, %extra) = @_;
    return Dashboard::compose_frame({
        project_name => 'demo', container => 'c1', status => 'running',
        events => [ map { { ts => "03:1$_", text => "event $_" } } (0 .. 3) ],
        %extra,
    }, 16, $cols);
}
sub texts { my ($f) = @_; return [ map { $_->{text} } @$f ] }

# row index of the first row whose text matches, or undef
sub row_of {
    my ($f, $re) = @_;
    my $t = texts($f);
    for my $i (0 .. $#$t) { return $i if $t->[$i] =~ $re }
    return undef;
}

my $RUN_TITLE = qr/\Q$RULE_LEAD\E Run /;
my $ALERT_RE  = qr/\Qlow on disk\E/;

# ===========================================================================
# A. WIDE -- the alert goes into the side column, and the panel grid does not
#    move. The second half is the operator's actual complaint.
# ===========================================================================
{
    my $without = frame($WIDE);
    my $with    = frame($WIDE, install_warning => $ALERT);

    my $run_without = row_of($without, $RUN_TITLE);
    my $run_with    = row_of($with,    $RUN_TITLE);
    ok(defined $run_without && defined $run_with, 'A: the Run panel title is locatable with and without an alert');

    is($run_with, $run_without,
        'A: an alert does NOT push the panel grid down at a width that has a side column '
      . '(this is the whole point of the move)');

    my $alert_row = row_of($with, $ALERT_RE);
    ok(defined $alert_row, 'A: the alert text is on screen');

    # It is on the SAME row as a panel title, which can only be true if it is
    # beside the grid rather than above it.
    like($with->[$alert_row]{text}, $RUN_TITLE,
        'A: the alert shares its row with the Run panel title -- i.e. it is BESIDE the grid, not above it');

    # And specifically in the right-hand region.
    my $side_w = tui::Screen::side_column_width($WIDE);
    my $left_of_alert = substr($with->[$alert_row]{text}, 0, length($with->[$alert_row]{text}) - $side_w);
    unlike($left_of_alert, $ALERT_RE, 'A: the alert is not in the main region, it is in the side column');
}

# ===========================================================================
# B. NARROW -- the fallback. No side column exists, so the alert renders
#    full-width above the panels exactly as it always did, and DOES cost the
#    grid a row. Paired with A: an implementation that always used the side
#    column would fail here, one that never did would fail A.
# ===========================================================================
{
    my $without = frame($NARROW);
    my $with    = frame($NARROW, install_warning => $ALERT);

    my $run_without = row_of($without, $RUN_TITLE);
    my $run_with    = row_of($with,    $RUN_TITLE);
    ok(defined $run_without && defined $run_with, 'B: the Run panel title is locatable with and without an alert');

    cmp_ok($run_with, '>', $run_without,
        'B: with no side column to hold it, an alert still pushes the grid down (the unchanged fallback)');

    my $alert_row = row_of($with, $ALERT_RE);
    ok(defined $alert_row, 'B: the alert text is on screen');
    cmp_ok($alert_row, '<', $run_with, 'B: and it sits ABOVE the Run panel');
    unlike($with->[$alert_row]{text}, $RUN_TITLE,
        'B: the alert has its own full-width row, not shared with a panel title');
}

# ===========================================================================
# C. Geometry is preserved either way -- the invariant every frame must hold,
#    asserted here because this change moves content between two regions whose
#    widths are computed separately and could easily fail to sum.
# ===========================================================================
{
    for my $cols ($NARROW, 100, 120, $WIDE, 200) {
        for my $alert (0, 1) {
            my $f = $alert ? frame($cols, install_warning => $ALERT) : frame($cols);
            my $bad = grep { Dashboard::display_width($_->{text}) != $cols } @$f;
            is($bad, 0, "C: cols=$cols alert=$alert -- every row is exactly $cols display columns");
            is(scalar(@$f), 16, "C: cols=$cols alert=$alert -- the frame is exactly the requested height");
        }
    }
}

# ===========================================================================
# D. A LONG alert wraps inside the side column rather than overflowing it, and
#    every one of its rows starts in the same column.
#
# The ragged-first-row bug this pins: a banner in the side column butts
# straight against the vertical border, so its first row rendered as
# "|!! podman ..." with no gap while its own continuation rows were indented.
# ===========================================================================
{
    my $long = 'this is a deliberately long alert message that cannot possibly fit on one row of the side column and must therefore wrap across several of them';
    my $f = frame($WIDE, install_warning => $long);
    my $side_w = tui::Screen::side_column_width($WIDE);

    my @alert_rows;
    for my $cell (@$f) {
        my $tail = substr($cell->{text}, length($cell->{text}) - $side_w);
        push @alert_rows, $tail if $tail =~ /deliberately|possibly|wrap/;
    }
    cmp_ok(scalar(@alert_rows), '>=', 2, 'D: a long alert occupies more than one row (it really did wrap)');

    # THE PROPERTY IS "never flush against the border", NOT "all rows equal".
    #
    # Continuation rows carry wrap_line's hanging indent, so they are
    # deliberately indented FURTHER than the first row -- that is a feature and
    # asserting uniformity would forbid it. What the fix actually corrected is
    # that the FIRST row had a gap of ZERO, jammed against the vertical border,
    # while its own continuations were indented: ragged against the one edge
    # that makes raggedness obvious.
    my @gaps = map { my ($ws) = $_ =~ /^\S(\s*)/; length($ws // '') } @alert_rows;
    my $flush = grep { $_ == 0 } @gaps;
    is($flush, 0,
        'D: no row of a side-column alert is flush against the vertical border')
        or diag('leading gaps seen: ' . join(',', @gaps));

    # And the continuations agree with each other, so the hanging indent is a
    # consistent shape rather than per-row drift.
    my %cont = map { $_ => 1 } @gaps[ 1 .. $#gaps ];
    is(scalar(keys %cont), 1,
        'D: continuation rows share one hanging indent')
        or diag('continuation gaps: ' . join(',', sort keys %cont));
}

done_testing();
