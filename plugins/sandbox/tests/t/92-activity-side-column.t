#!/usr/bin/env perl
# t03-activity-column -- the oracle for blueprint tui-operator-feedback.
#
# Closes the operator's third request, verbatim: "the Recent activity could
# very well be a narrow column instead of expanding to fill everything ... It
# could be always the last column and take the entire height of the terminal.
# Everything else could be arranged on the remaining space in rows and columns
# ... which could wrap to up to three lines and then ellipsis."
#
# This is NEW LAYOUT CAPABILITY, not a bug fix. Composition was strictly
# row-banded (tui::Layout::place assigns panels to bands; bands stack), there
# was no full-height side-column concept, and no wrap-to-N-then-ellipsis helper
# existed at all.
#
# EVERY SIZE-SENSITIVE ASSERTION SWEEPS A GRID OF WIDTHS *AND* HEIGHTS
# (criterion 6, and it is not a formality). t08 of this same blueprint fixed a
# CRITICAL that a 95-assertion file missed because it never varied HOME; the
# same file's wrap check hardcoded cols=40 while its cols=1 check asserted only
# timing. A single size proves nothing about a layout.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Theme;

my $OK = eval { require Dashboard; require tui::Screen; require tui::Frame;
                require tui::Layout; require tui::DashboardScreen; 1 };
ok($OK, 'the TUI modules load') or BAIL_OUT("require failed: $@");

sub plain { my ($s) = @_; $s =~ s/\e\[[0-9;]*m//g; return $s }
sub w     { return tui::Layout::display_width(plain($_[0])) }

# A deterministic activity feed. Every fourth row is deliberately long enough
# to need more than three wrapped lines -- at the WIDEST the column can get.
#
# DERIVED, NOT HARDCODED, and that distinction has already cost a red: this was
# a fixed string sized for "a 40-column column", and when the column gained the
# ability to grow to ACTIVITY_COLUMN_MAX_COLS the string stopped overflowing the
# three-line cap at cols=200. AC14's ellipsis assertion then failed -- not
# because the cap broke, but because the fixture no longer exercised it. A
# fixture that encodes a constant it does not read goes stale silently, so this
# one reads it.
my $LONG = 'resources_sampler_forked with an unusually long trailing explanation ';
$LONG .= 'that keeps going well past any reasonable column width and then some more '
    while length($LONG) < 4 * tui::Screen::ACTIVITY_COLUMN_MAX_COLS();
sub events {
    my ($n) = @_;
    return [ map {
        [ { text => tui::DashboardScreen::activity_time_text(sprintf('16:%02d', $_ % 60)), role => 'text.muted' },
          { text => 'o ',  role => 'text.primary' },
          { text => ($_ % 4 == 0 ? $LONG : 'spend_sampler_forked'), role => 'text.primary' } ]
    } 1 .. $n ];
}
sub state { return { events => events($_[0] // 40), runs => [], tokens => {} } }

# ===========================================================================
# PART 1 -- tui::Frame::wrap_capped (spec S1).
# ===========================================================================
{
    can_ok('tui::Frame', 'wrap_capped');

    my $text = join(' ', ('alpha') x 60);

    for my $width (12, 20, 40, 61) {
        for my $cap (1, 2, 3, 5) {
            my $rows = tui::Frame::wrap_capped($text, 'text.primary', $width, 2, $cap);
            cmp_ok(scalar(@$rows), '<=', $cap,
                "AC1: cap $cap at width $width yields at most $cap rows");
            my @bad = grep { w($_->{text}) != $width } @$rows;
            is(scalar(@bad), 0,
                "AC3: every row is exactly $width display columns at cap $cap -- the ellipsis does not overflow");
        }
    }

    # THE MARKER IS THE REAL GLYPH, NOT THE ASCII FALLBACK -- and this
    # assertion exists because the fallback actually fired. tui::Frame::ELLIPSIS
    # reads Theme::glyph('ellipsis'), which returns the glyph's UTF-8 BYTES; the
    # first implementation treated the return value as a record and read a
    # `char` key off it, so the check failed, the fallback engaged, and the
    # dashboard rendered a full stop where the ellipsis belonged. Everything
    # compiled and every test passed. Only reading the rendered screen caught
    # it, so the oracle now pins what reading the screen established.
    is(tui::Frame::ELLIPSIS(), Theme::glyph('ellipsis'),
        'AC2: the truncation marker is Theme\'s declared glyph, not the ASCII degrade path');
    isnt(tui::Frame::ELLIPSIS(), '.',
        'AC2: and specifically not a full stop, which is what a misread glyph API produced');

    # AC2 -- the ellipsis appears exactly when rows were dropped, and not
    # otherwise. Asserted in BOTH directions: a marker that is always present
    # says nothing, and one that is never present hides the truncation.
    my $ell     = tui::Frame::ELLIPSIS();
    my $natural = tui::Frame::wrap_line($text, 'text.primary', 20, 2);
    my $cut     = tui::Frame::wrap_capped($text, 'text.primary', 20, 2, 3);
    my $whole   = tui::Frame::wrap_capped($text, 'text.primary', 20, 2, scalar(@$natural));
    cmp_ok(scalar(@$natural), '>', 3, 'AC2 precondition: this input genuinely needs more than three rows');
    like(plain($cut->[-1]{text}), qr/\Q$ell\E\s*$/,
        'AC2: when rows were dropped the last kept row ends with the ellipsis');
    unlike(join('', map { plain($_->{text}) } @$whole), qr/\Q$ell\E/,
        'AC2: when nothing was dropped no ellipsis is added');

    # AC4 -- a cap at or above the natural row count is wrap_line exactly.
    is_deeply([ map { $_->{text} } @$whole ], [ map { $_->{text} } @$natural ],
        'AC4: a cap at the natural row count is byte-identical to wrap_line');
    is_deeply([ map { $_->{text} } @{ tui::Frame::wrap_capped($text, 'text.primary', 20, 2, 999) } ],
              [ map { $_->{text} } @$natural ],
        'AC4: and so is a cap far above it');

    # AC5 -- the two degenerate cap values, which must differ from each other.
    is_deeply(tui::Frame::wrap_capped($text, 'text.primary', 20, 2, 0), [],
        'AC5: an explicit cap below 1 yields no rows');
    my $uncapped = tui::Frame::wrap_capped($text, 'text.primary', 20, 2, undef);
    is(scalar(@$uncapped), scalar(@$natural),
        'AC5: a MISSING cap means uncapped, not zero -- rendering nothing because a parameter was malformed is the worse failure, and this is on the render path');
    is(scalar(@{ tui::Frame::wrap_capped($text, 'text.primary', 20, 2, 'nonsense') }), scalar(@$natural),
        'AC5: and so does a non-numeric one');

    # Totality: this sits on the render path, so a die blanks the screen.
    for my $bad (undef, [], {}, \"ref") {
        my $got = eval { tui::Frame::wrap_capped($bad, 'text.primary', 20, 2, 3) };
        is(ref($got), 'ARRAY', 'AC5: malformed input yields an arrayref rather than dying')
            or diag("  died: $@");
    }
}

# ===========================================================================
# PART 2 -- the reservation rule (spec S2.1/S2.2, criterion 5).
# ===========================================================================
{
    my $col   = tui::Screen::ACTIVITY_COLUMN_COLS();
    my $floor = tui::Screen::SIDE_COLUMN_MIN_MAIN();
    my $edge  = $col + $floor;

    is(tui::Screen::side_column_width($edge - 1), 0,
        "AC6: one column below the threshold ($edge) there is no side column");
    is(tui::Screen::side_column_width($edge), $col,
        'AC6: at the threshold the full column is reserved');
    # RE-POINTED 2026-08-26, AND THIS ONE IS A REVERSAL, not a tuning change.
    #
    # This asserted `side_column_width($edge + 500) == $col` -- the column never
    # grows, "narrow is the whole point". The operator asked for the opposite:
    # on a full-width terminal the activity column can be twice as wide, because
    # the surplus was going to a main region that did not need it.
    #
    # What the original assertion was really protecting is preserved below and
    # in AC6b: the main region never drops below the layout breakpoint, and the
    # threshold behaviour is byte-identical. Growth spends surplus only.
    my $max = tui::Screen::ACTIVITY_COLUMN_MAX_COLS();
    is(tui::Screen::side_column_width($edge + 500), $max,
        'AC6: on a very wide terminal the column grows to its 2x cap -- it is no '
      . 'longer pinned narrow, but it is still bounded');
    cmp_ok($max, '==', 2 * $col,
        'AC6: the cap IS twice the base width, which is what was asked for, rather '
      . 'than a third number near it');

    # Monotonic and bounded across the whole range: never below the base once a
    # split happens, never above the cap, and never shrinking as the terminal
    # grows. A cap plus a floor does not by itself rule out a non-monotonic
    # middle, so it is checked rather than assumed.
    my $prev = 0;
    my $bad  = '';
    for my $c ($edge .. $edge + 200) {
        my $w = tui::Screen::side_column_width($c);
        if ($w < $col || $w > $max || $w < $prev) {
            $bad = "cols=$c gave $w (previous $prev, band [$col, $max])";
            last;
        }
        $prev = $w;
    }
    is($bad, '',
        'AC6b: width rises monotonically from the base to the 2x cap and never '
      . 'leaves that band -- a cap and a floor alone do not rule out a '
      . 'non-monotonic middle, so it is checked rather than assumed');

    # THE RULE IS DERIVED, NOT PICKED. This is what makes criterion 5's
    # "behaviour at narrow widths is DEFINED, not incidental" true rather than
    # asserted: the floor is tui::Layout's own two-column breakpoint, so the
    # side column is taken only when the main region still clears the width at
    # which that module is willing to give it two columns.
    is($floor, tui::Layout::BREAKPOINT_TWO_COL(),
        'AC6: the main-region floor IS the layout breakpoint, not a second number that happens to be near it');

    for my $c ($edge, $edge + 1, 200, 400) {
        cmp_ok($c - tui::Screen::side_column_width($c), '>=', $floor,
            "AC6: at cols=$c the main region is never left below the floor");
    }

    for my $bad (undef, 'x', -5, 0, [ ]) {
        is(tui::Screen::side_column_width($bad), 0,
            'AC6: a malformed width reserves nothing rather than guessing');
    }

    # AC6c -- THE SCROLL INDICATOR'S WIDTH IS THE COLUMN'S, NOT THE SCREEN'S.
    #
    # Dashboard::activity_row_width is what activity_window justifies the
    # "N more above / N more below" overlay to. It used to return $cols -- the
    # whole terminal -- while the rows it overlays are only as wide as the side
    # column, so the marker was justified past the panel's right edge and
    # clipped. The operator's report was that the markers "are not showing", and
    # they never had, at any side-column width.
    #
    # Pinned as a RELATIONSHIP rather than a number: it must equal the column's
    # body width (the column minus its border) less the body indent, at every
    # width where a column exists, and fall back to the full terminal where one
    # does not.
    # (@WIDE is declared further down this file, so the widths are derived from
    # $edge here rather than reaching forward for it.)
    for my $c ($edge, $edge + 20, $edge + 70, $edge + 500) {
        my $body = tui::Screen::side_column_body_width($c);
        cmp_ok($body, '>', 0, "AC6c: cols=$c has a side-column body width");
        is(Dashboard::activity_row_width($c), $body - tui::Screen::BODY_INDENT(),
            "AC6c: cols=$c -- the scroll overlay is justified to the COLUMN, not the terminal");
    }
    is(Dashboard::activity_row_width($edge - 1), ($edge - 1) - tui::Screen::BODY_INDENT(),
        'AC6c: below the threshold there is no column, so it falls back to the full width');
}

# ===========================================================================
# PART 3 -- the composed frame. The invariants that a side column can break.
# ===========================================================================
my $EDGE = tui::Screen::ACTIVITY_COLUMN_COLS() + tui::Screen::SIDE_COLUMN_MIN_MAIN();
my @WIDE   = ($EDGE, $EDGE + 1, 150, 200);
my @NARROW = (60, 80, $EDGE - 1);
my @HEIGHTS = (5, 8, 12, 24, 45, 60);

{
    my ($rowbad, $widebad) = (0, 0);
    my $checked = 0;
    for my $cols (@NARROW, @WIDE) {
        for my $rows (@HEIGHTS) {
            my $f = Dashboard::compose_frame(state(), $rows, $cols);
            $rowbad++ if scalar(@$f) != $rows;
            $widebad += scalar grep { w($_->{text}) != $cols } @$f;
            $checked++;
        }
    }
    is($rowbad, 0,
        "AC10: total emitted rows equals the terminal height, across all $checked width/height combinations -- the invariant t08 and the previous initiative's d02 both turned on");
    is($widebad, 0,
        'AC11: every emitted row is exactly the terminal width, across the same grid');
}

# AC7/AC8 -- the column is LAST and spans the WHOLE body.
for my $cols (@WIDE) {
    for my $rows (12, 24, 45) {
        my $f  = Dashboard::compose_frame(state(), $rows, $cols);
        my $sw = tui::Screen::side_column_width($cols);

        # The title rule for 'Recent activity' must begin within the reserved
        # right-hand slice, which is what "last column" means positionally.
        my ($idx) = grep { plain($f->[$_]{text}) =~ /Recent activity/ } 0 .. $#$f;
        ok(defined $idx, "AC7: cols=$cols rows=$rows -- the activity panel is present");
      SKIP: {
            skip('no activity panel', 2) unless defined $idx;
            my $at = index(plain($f->[$idx]{text}), 'Recent activity');
            cmp_ok($at, '>=', $cols - $sw,
                "AC7: cols=$cols rows=$rows -- it starts inside the reserved rightmost $sw columns");
            # AC8 RE-POINTED TWICE, and it is back where it started.
            #
            # Originally index 1 -- the first row BELOW the screen title, which
            # spanned the whole terminal. On 2026-08-25 it became index 0: the
            # header was narrowed to the main region and the column ran beside
            # it from row 0, so Activity gained a row (operator: "I thought
            # Recent Activity would go to the top of the viewport instead of
            # stretching that banner throughout the entire terminal").
            #
            # On 2026-08-27, having seen it, the operator reversed that: "drop
            # whatever I said about having Recent activity take the top row. It
            # looks better when it was instead on the second row aligned with
            # Run." So the header spans the terminal again and the column starts
            # under it -- index 1 -- which is the row the first main-region panel
            # also starts on. That alignment is the whole point of the reversal,
            # so it is asserted directly below rather than left implied.
            is($idx, 1,
                "AC8: cols=$cols rows=$rows -- the column starts BELOW the full-width header, not beside it");

            # ...and row 0 is ALL header. This is the structural half of the
            # claim: index 1 alone would still hold if the column merely started
            # late while something else occupied row 0's right-hand end. An
            # activity row is recognisable by its leading clock, so its absence
            # from row 0's tail is what says the header owns the full width.
            my $row0_tail = substr(plain($f->[0]{text}), -$sw);
            unlike($row0_tail, qr/\d\d:\d\d/,
                "AC8: cols=$cols rows=$rows -- row 0 carries no activity content, so the header spans the terminal");
        }

        # AC8 -- the bottom body row also carries column content. With 40
        # events supplied there is always more than enough to fill it.
        my $last_body = plain($f->[-2]{text});
        my $tail = substr($last_body, -$sw);
        like($tail, qr/\S/,
            "AC8: cols=$cols rows=$rows -- the bottom body row carries side-column content, so the column spans the entire height");
    }
}

# AC9 -- below the threshold there is no side column at all, and the activity
# panel is back in the band flow.
for my $cols (@NARROW) {
    my $f = Dashboard::compose_frame(state(), 24, $cols);
    my ($idx) = grep { plain($f->[$_]{text}) =~ /Recent activity/ } 0 .. $#$f;
    ok(defined $idx, "AC9: cols=$cols -- the activity panel still exists");
    isnt($idx, 1, "AC9: cols=$cols -- but it is NOT pinned to the first body row; it is in the band flow, where its flex flag still protects it");
}

# AC12 -- RE-POINTED 2026-08-28. A banner used to shorten the MAIN region while
# leaving the side column's height alone; that was the property compose()
# ordered its code to preserve.
#
# Alerts are now an OVERLAY: painted over the bottom rows of a finished frame,
# full width, above the footer rule. So they change neither region's height --
# a strictly stronger version of the old claim -- but they DO cover the bottom
# of the side column, because a full-width popup covers whatever is beneath it.
# That is the operator's own specification ("overlay it on top of whatever was
# in it before. Like it's a pop up"), not an accident.
#
# The claim therefore splits in two, and both halves are asserted below:
#   * the side column's HEIGHT is unchanged (nothing reflows), and
#   * the rows the overlay covers are exactly the rows it painted -- it does not
#     eat more of the column than the alert needed.
for my $cols (@WIDE) {
    my $rows = 30;
    my $sw   = tui::Screen::side_column_width($cols);
    my $plain_f  = Dashboard::compose_frame(state(), $rows, $cols);
    my $banner_f = Dashboard::compose_frame({ %{ state() }, install_warning => 'a warning that occupies a row' }, $rows, $cols);

    my $count = sub {
        my ($f) = @_;
        return scalar grep { substr(plain($_->{text}), -$sw) =~ /\S/ } @{$f}[ 1 .. $#$f - 1 ];
    };
    # The frame is the same height either way -- nothing reflowed.
    is(scalar(@$banner_f), scalar(@$plain_f),
        "AC12: cols=$cols -- an alert does not change the frame height (it overlays, it does not displace)");

    # And it covers only what it painted: the count of side-column rows drops by
    # at most the number of overlay rows, never more. A larger drop would mean
    # the alert had disturbed the column's layout rather than merely covering
    # its last rows.
    my $overlay_rows = scalar grep { ($_->{role} // '') eq 'overlay.warn' } @$banner_f;
    cmp_ok($overlay_rows, '>=', 1, "AC12: cols=$cols -- the alert really is rendered as an overlay");
    my $lost = $count->($plain_f) - $count->($banner_f);
    cmp_ok($lost, '<=', $overlay_rows,
        "AC12: cols=$cols -- the alert covers at most the rows it painted; the column beneath is not reflowed");
}

# AC13 -- the other panels are still all there, in the narrower main region.
for my $cols (@WIDE) {
    my $f = Dashboard::compose_frame(state(), 45, $cols);
    my $all = join("\n", map { plain($_->{text}) } @$f);
    like($all, qr/Run/,        "AC13: cols=$cols -- Run survives the split");
    like($all, qr/Blueprints/, "AC13: cols=$cols -- Blueprints survives the split");
    like($all, qr/Resources/,  "AC13: cols=$cols -- Resources survives the split");
    like($all, qr/Providers/,  "AC13: cols=$cols -- Providers survives the split");
}

# AC14 -- the three-line cap, THROUGH THE REAL DASHBOARD rather than only
# through wrap_capped in isolation. A helper that caps correctly and a panel
# that never uses it would pass PART 1 and fail the operator.
{
    my $ell = tui::Frame::ELLIPSIS();
    for my $cols (@WIDE) {
        my $sw = tui::Screen::side_column_width($cols);
        my $f  = Dashboard::compose_frame(state(60), 45, $cols);
        my @col = map { substr(plain($_->{text}), -$sw) } @{$f}[ 1 .. $#$f - 1 ];

        # A wrapped continuation row is one that does not open with a clock.
        # Count the longest run of them following a clock row: that run plus
        # its own leading row is the wrapped height of one event.
        my ($longest, $run) = (0, 0);
        for my $line (@col) {
            if ($line =~ /^\s*\d\d:\d\d/) { $run = 1 }
            elsif ($line =~ /\S/ && $run)  { $run++; $longest = $run if $run > $longest }
            else                            { $run = 0 }
        }
        cmp_ok($longest, '<=', 3,
            "AC14: cols=$cols -- no activity row occupies more than three lines in the rendered dashboard");
        like(join("\n", @col), qr/\Q$ell\E/,
            "AC14: cols=$cols -- and a row that needed more than three says so with an ellipsis");
    }
}

# AC15 -- with no side panel marked, compose is byte-identical to what it did
# before this package. This is what makes every other consumer of tui::Screen
# (the backpack screen, the launcher screens) provably unaffected.
{
    my %screen = (
        title  => 'a title', footer => 'a footer',
        panels => [ { title => 'One', lines => [ 'alpha', 'beta' ] },
                    { title => 'Two', lines => [ 'gamma' ] } ],
    );
    for my $cols (60, 100, 200) {
        for my $rows (5, 12, 24) {
            my $f = tui::Screen::compose(\%screen, $rows, $cols);
            is(scalar(@$f), $rows, "AC15: no side panel, cols=$cols rows=$rows -- row count is the terminal height");
            my @bad = grep { w($_->{text}) != $cols } @$f;
            is(scalar(@bad), 0, "AC15: no side panel, cols=$cols rows=$rows -- every row is the terminal width");
        }
    }
}

# ===========================================================================
# PART 4 -- capacity agrees with the render.
#
# Dashboard::activity_capacity is what the launcher uses to decide how many
# events to hand the panel. Its own header stakes it on agreeing with what
# compose_frame renders. Moving Activity out of the band flow invalidated the
# model it computed from, so the agreement has to be re-established, not
# assumed.
# ===========================================================================
for my $cols (@WIDE, @NARROW) {
    for my $rows (12, 24, 45) {
        my $sw  = tui::Screen::side_column_width($cols);
        my $cap = Dashboard::activity_capacity(state(200), $rows, $cols);
        next unless $sw > 0;

        my $f = Dashboard::compose_frame(state(200), $rows, $cols);
        # FROM ROW 0, not row 1. The slice used to skip the first row because
        # the screen title spanned the full terminal and the side column began
        # beneath it. The header now occupies the main region only and the
        # column runs from the top, so row 0 carries the column's own title --
        # excluding it counted one row fewer than the renderer draws and made
        # the predictor look wrong when it was right.
        # ...and stop BEFORE the chrome that sits below the body. That used to
        # be the footer row alone ($#$f - 1); since 2026-08 a horizontal rule
        # sits above the footer, and it is full-width -- so it looks like a
        # rendered side-column row to the -$sw test and counted one too many.
        # Derived from tui::Screen::chrome_rows() minus the title row, which is
        # ABOVE the body and is part of the main region, not below it.
        my $below = tui::Screen::chrome_rows() - 1;
        my $rendered = scalar grep { substr(plain($_->{text}), -$sw) =~ /\S/ } @{$f}[ 0 .. $#$f - $below ];
        # -1 for the panel's own title row, which capacity excludes.
        is($cap, $rendered - 1,
            "AC-capacity: cols=$cols rows=$rows -- reported capacity ($cap) matches the rows the column actually renders");
    }
}

# ===========================================================================
# PART 6 -- character-level wrapping with a hanging indent.
#
# Operator feedback, with a screenshot, on the shipped column:
#   "It doesn't need to respect word boundaries, I would rather have it just
#    always break in a dumb way at the character"
#   "the wrapped text needs to be aligned to the text above ... aligned to the
#    hour minute `:` separator, should be aligned to the text itself after the
#    icon"
#
# Both halves matter and they are independent, so both are asserted.
#
# Note this part exists because PART 1-5 all stayed green through the change --
# they cover the CAP and the column geometry, not how a row breaks. A behaviour
# change that no assertion notices is a gap in the oracle, not a free pass.
# ===========================================================================
{
    can_ok('tui::Frame', 'wrap_chars');

    # A real activity row: the ACTIVITY_HANG-column fixed prefix (time + glyph), body.
    my $row = [ { text => tui::DashboardScreen::activity_time_text('21:19'), role => 'text.muted' },
                { text => 'x ',                      role => 'state.crit' },
                { text => 'backpack_install_failed exit=1', role => 'state.crit' } ];

    # DERIVED, not restated: the hang is whatever the renderer's own constant
    # says, so a change to the row prefix (2026-08-25: one space after the clock
    # instead of three) re-points this oracle instead of breaking it.
    my $HANG = tui::DashboardScreen::ACTIVITY_HANG();
    my $BODY = 'backpack_install_failed exit=1';

    my $cells = tui::Frame::wrap_chars($row, 'text.primary', 32, $HANG, 3);
    my @txt = map { my $c = $_; join('', map { $_->{text} } @{ $c->{spans} || [] }) } @$cells;
    cmp_ok(scalar(@txt), '>=', 2, 'PART6: a row longer than the column wraps');

    # (a) CHARACTER breaking: the first row is filled to the column width, which
    #     a word-boundary wrap could not do -- it would have to stop at the
    #     space before `exit=1` and leave the tail of the row empty.
    is(tui::Layout::display_width($txt[0]), 32,
       'PART6a: the first line fills the column exactly -- broken at a character, not at a '
     . 'word boundary (a word wrap would stop early and leave the row short)');
    is($txt[0], tui::DashboardScreen::activity_time_text('21:19') . 'x ' . substr($BODY, 0, 32 - $HANG),
       'PART6a: ...and the break lands wherever the column runs out inside the token, which is the '
     . '"dumb break" that was asked for');

    # (b) HANGING INDENT: continuation starts under the BODY (ACTIVITY_HANG),
    #     not under the timestamp and not at the old 2-column continuation indent.
    my ($lead) = $txt[1] =~ /^( *)/;
    is(length($lead), $HANG,
       "PART6b: the continuation is indented to the BODY column ($HANG = time field + one space "
     . '+ glyph + one space), so it lines up under the event text rather than under the clock');

    # Non-vacuity: the SAME row with no hang is NOT indented, so PART6b is
    # pinning the parameter rather than some incidental property of the text.
    my $flat = tui::Frame::wrap_chars($row, 'text.primary', 32, 0, 3);
    my $f1 = join('', map { $_->{text} } @{ $flat->[1]{spans} || [] });
    unlike($f1, qr/^ {$HANG}/,
           'PART6b non-vacuity: with hang=0 the continuation is not indented, so the assertion '
         . 'above measures the hanging indent and not the body text');

    # (c) The cap still applies, and a truncated row still carries the ellipsis.
    my $long = [ { text => tui::DashboardScreen::activity_time_text('21:19'), role => 'text.muted' },
                 { text => 'x ', role => 'state.crit' },
                 { text => ('z' x 400), role => 'state.crit' } ];
    my $capped = tui::Frame::wrap_chars($long, 'text.primary', 32, $HANG, 3);
    is(scalar(@$capped), 3, 'PART6c: the 3-row cap is honoured');
    my $last = join('', map { $_->{text} } @{ $capped->[-1]{spans} || [] });
    like($last, qr/\Q@{[ tui::Frame::ELLIPSIS() ]}\E/,
         'PART6c: the capped row carries the ellipsis, so a truncated row stays distinguishable '
       . 'from a complete one');

    # (d) Totality: the degenerate widths must not die or loop.
    for my $w (0, 1, 5) {
        my $got = eval { tui::Frame::wrap_chars($row, 'text.primary', $w, $HANG, 3) };
        ok(!$@ && ref($got) eq 'ARRAY', "PART6d: wrap_chars survives width $w without dying");
    }

    # (e) The panel actually asks for this. A helper nothing calls is not a fix.
    my $panels = tui::DashboardScreen::panels({ events => [ $row ] }, 132);
    my ($act) = grep { ref($_) eq 'HASH' && ($_->{title} // '') eq 'Recent activity' } @{ $panels || [] };
    ok($act, 'PART6e: the Recent activity panel exists');
    is(($act || {})->{wrap_break}, 'char',
       'PART6e: ...and declares character breaking');
    is(($act || {})->{wrap_indent}, $HANG,
       'PART6e: ...and a hanging indent matching the row prefix Dashboard::recent_events emits');
}

done_testing();
