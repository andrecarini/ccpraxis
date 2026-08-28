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

    # RE-POINTED 2026-08-28: ALERTS ARE AN OVERLAY, NOT A SIDE-COLUMN BANNER.
    #
    # The 2026-08-25 design put alerts INTO the side column so they would stop
    # pushing the grid down. It worked, but it spent the column: the operator's
    # report was that warnings were "popping off on top of the Recent activity
    # column", and a capture showed a `!!` row sitting over the activity feed.
    #
    # They are now painted over the BOTTOM of an already-composed frame, after
    # placement, so they consume no layout budget at all -- which is a STRONGER
    # version of the original claim (asserted in A above and again in B): the
    # grid does not move at ANY width, not just where a side column exists.
    #
    # What this block now pins is that the alert is at the bottom and does not
    # land in the activity column.
    my $side_w    = tui::Screen::side_column_width($WIDE);
    my $side_part = substr($with->[$alert_row]{text},
                           length($with->[$alert_row]{text}) - $side_w);
    unlike($side_part, $ALERT_RE,
        'A: the alert does NOT render inside the activity column -- that placement is what was reported');

    cmp_ok($alert_row, '>', $run_with,
        'A: the alert sits BELOW the panel grid, at the bottom of the frame');
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

    # RE-POINTED 2026-08-28, AND THE CLAIM INVERTED ON PURPOSE.
    #
    # This asserted that a narrow terminal keeps the OLD behaviour: no side
    # column to hold the alert, so it goes full-width above the panels and costs
    # the grid a row. That was the documented fallback of the side-column
    # design.
    #
    # The overlay has no fallback, and that is the improvement: it paints over
    # the composed frame, so it costs nothing at ANY width. The narrow case is
    # now the SAME as the wide case, which is why this pairing is kept -- an
    # implementation that pushed the grid at either width fails here.
    is($run_with, $run_without,
        'B: at a width with NO side column an alert still does not move the grid -- '
      . 'the overlay has no push-down fallback, unlike the banner it replaced');

    my $alert_row = row_of($with, $ALERT_RE);
    ok(defined $alert_row, 'B: the alert text is on screen');
    cmp_ok($alert_row, '>', $run_with, 'B: and it sits BELOW the Run panel, at the bottom');
    unlike($with->[$alert_row]{text}, $RUN_TITLE,
        'B: the alert owns its row rather than sharing one with a panel title');
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
    # LONG ENOUGH TO ACTUALLY OVERFLOW $WIDE, which the previous fixture was
    # not: at 150 columns the old message fitted on ONE row and only its
    # "[d] dismiss" suffix wrapped, so the assertion passed for the wrong
    # reason and would have kept passing had wrapping broken entirely.
    my $long = join ' ', ('this is a deliberately long alert message that cannot possibly fit on one row') x 3;
    my $f = frame($WIDE, install_warning => $long);

    # RE-POINTED 2026-08-28: the overlay spans the FULL WIDTH, so a long alert
    # wraps across whole rows rather than inside a column. The old assertions
    # measured the side column's tail and its hanging indent against the
    # vertical border -- neither exists here.
    my @alert_rows = grep { /deliberately|possibly|one row/ } map { $_->{text} } @$f;
    cmp_ok(scalar(@alert_rows), '>=', 2, 'D: a long alert occupies more than one row (it really did wrap)');

    # NO WORD IS SILENTLY DROPPED. This is the standing rule t/75 AC1 pins for
    # every wrapping surface, asserted here too because the overlay is a NEW
    # surface that wraps -- and the failure it guards against (content quietly
    # truncated instead of wrapped) is invisible unless something checks.
    my $joined  = join ' ', @alert_rows;
    my @missing = grep { $joined !~ /\Q$_\E/ } split /\s+/, $long;
    is(scalar(@missing), 0, 'D: every word of the alert survives the wrap -- nothing silently truncated')
        or diag('missing: ' . join(',', @missing));

    # THE FOOTER IS NEVER COVERED, and this is the assertion that would have
    # caught the first implementation. The overlay was anchored to the bottom of
    # the frame, which put it over the hotkey row -- hiding the very key that
    # dismisses it. The operator reported exactly that. It now anchors above the
    # footer rule, so both chrome rows survive.
    my $footer = $f->[-1]{text};
    like($footer, qr/\[q\] quit/, 'D: the footer hotkeys are still visible beneath the overlay');
    unlike($footer, qr/deliberately|possibly/, 'D: the overlay did not paint over the footer row');

    # And the frame is still exactly as tall as it was asked to be: an overlay
    # that added rows would be a banner wearing a different name.
    is(scalar(@$f), 16, 'D: overlaying a long alert did not change the frame height');
}

done_testing();
