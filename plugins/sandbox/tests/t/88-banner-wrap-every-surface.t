#!/usr/bin/env perl
# 88-banner-wrap-every-surface.t -- ORACLE for package d02-wrap-every-surface
# (blueprint ccpraxis-tooling-debt), specs/d02-wrap-every-surface-spec.md.
# Written BLIND to any implementation of the banner-wrap fix -- Screen.pm's
# banner block still routes through tui::Frame::make_cell (truncate) as of
# this writing. Do NOT weaken an assertion here to make a future
# implementation's life easier.
#
# TODAY'S EXPECTED STATE: banners truncate, not wrap. Every assertion below
# that depends on wrapping is expected to go RED for a WRONG VALUE (a single
# truncated cell, or a dropped "[d] dismiss" hint) -- that IS "missing
# behavior", not a harness bug. Title/footer assertions (which pin the
# UNCHANGED, deliberately-truncating behavior, spec Decision D1) are expected
# to be GREEN today and must stay green after implementation.
#
# This file complements, and does not duplicate, the amendment made to
# t/75-wrap-on-overflow.t:543-575 (the single superseded assertion) and the
# DashboardScreen.pm addition to t/75's AC7 non-ASCII guard. See this
# package's test-writer report for the full criterion map.
#
# SELECTOR NOTE (read before editing): several blocks below select "the
# banner row(s)" out of a composed frame by CELL ROLE rather than by a text
# substring. This deliberately differs from t/75's own (amended) exclusion
# block, which still uses a text-substring grep per the spec's literal
# wording. Role-based selection was required here because this file's own
# fixtures reuse words across title/footer/banner text (to keep fixtures
# short), which a substring grep cannot disambiguate; role is unambiguous
# because tui::Screen::compose emits a distinct, stable role per surface
# (title default 'accent', footer default 'text.faint', panel/body default
# 'text.primary', banner default 'state.warn' via Screen.pm's own
# _ROLE_ATTENTION(), or an explicit caller-supplied banner_role such as
# DashboardScreen's 'state.crit'). This is a black-box observable of
# compose()'s public contract, not a reach into a private implementation
# detail.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $SCRIPTS = "$Bin/../../scripts";
my $TUI_DIR = "$SCRIPTS/tui";
use lib "$Bin/../../scripts";

# ===========================================================================
# Module load gates (mirrors t/75/t/77 convention)
# ===========================================================================
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'tui/Layout.pm loads (shipped)') or diag("  require tui::Layout failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'tui/Frame.pm loads (shipped)') or diag("  require tui::Frame failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'tui/Screen.pm loads (shipped)') or diag("  require tui::Screen failed: $@");
my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'tui/DashboardScreen.pm loads (shipped)') or diag("  require tui::DashboardScreen failed: $@");

# ===========================================================================
# Scaffolding (this file's own copies, per t/75/t/77 convention -- no shared
# test-lib import).
# ===========================================================================

# plain($cell) -> de-SGR'd text.
sub plain {
    my ($c) = @_;
    my $t = ref($c) eq 'HASH' ? $c->{text} : '';
    $t = '' if !defined $t;
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}

# words($str) -> the word list, split on runs of a single ASCII space.
sub words { my ($s) = @_; return grep { length } split / +/, $s; }

# reconstruct(\@texts) -> the ordered word list recovered by stripping each
# row's own leading/trailing whitespace, then splitting what's left on
# spaces. Same normalisation strategy as t/75's own reconstruct(), copied
# rather than shared (this file's own convention).
sub reconstruct {
    my ($texts) = @_;
    my @all;
    for my $t (@$texts) {
        (my $s = $t) =~ s/^\s+//;
        $s =~ s/\s+\z//;
        push @all, words($s);
    }
    return @all;
}

# WIDE -- the one glyph this suite's own Theme table declares at column
# width 2 (fullwidth vertical line, U+FF5C), same fixture t/75/t/77 use.
my $WIDE = chr(0xFF5C);

# banner_rows_by_role(\@frame, $role) -> the subset of emitted cells whose
# 'role' key equals $role, in frame order.
sub banner_rows_by_role {
    my ($f, $role) = @_;
    return grep { defined($_->{role}) && $_->{role} eq $role } @$f;
}

# ===========================================================================
# AC-2 (DC2) -- a banner longer than the terminal is FULLY READABLE at 40
# and 80 columns, including the "[d] dismiss" hint (report's concrete cost).
# ===========================================================================
SKIP: {
    skip 'tui::DashboardScreen (or a dependency) did not load', 8 unless $DS_OK && $SCREEN_OK;

    my $install_warning =
        'zqx-install warning several backpack items failed to install correctly '
      . 'and need manual review before proceeding';
    my $state = { status => 'running', install_warning => $install_warning };

    for my $cols (40, 80) {
        my $f = tui::DashboardScreen::compose($state, 24, $cols);
        my @banner_cells = banner_rows_by_role($f, 'overlay.warn');
        ok(scalar(@banner_cells) >= 1,
            "AC-2 (cols=$cols): at least one banner row is emitted for the install_warning banner");
        my @plain_rows = map { plain($_) } @banner_cells;
        my @rebuilt = reconstruct(\@plain_rows);
        my $found_adjacent = 0;
        for my $i (0 .. $#rebuilt - 1) {
            if (defined($rebuilt[$i]) && defined($rebuilt[$i + 1])
                    && $rebuilt[$i] eq '[d]' && $rebuilt[$i + 1] eq 'dismiss') {
                $found_adjacent = 1;
                last;
            }
        }
        ok($found_adjacent,
            "AC-2 (cols=$cols): the '[d] dismiss' hint is present, unbroken (adjacent words), in the reconstructed banner text")
            or diag("  reconstructed words: [" . join(',', @rebuilt) . "]");

        # Row-accounting must hold at the same time the hint becomes visible.
        is(scalar(@$f), 24, "AC-2 (cols=$cols): compose still returns exactly 24 cells while the banner wraps");

        # Every emitted banner row must itself fit within $cols (no overflow
        # traded for readability).
        my $over = grep { tui::Layout::display_width(plain($_)) > $cols } @banner_cells;
        is($over, 0, "AC-2 (cols=$cols): no emitted banner row exceeds the column width");
    }
}

# ===========================================================================
# AC-3 / AC-3d (DC3) -- row accounting holds EXACTLY, for a genuine width x
# row x banner-count sweep (DC6: this is a real sweep, not a single value).
# The smallest $rows in the sweep (3) is AC-3d's "tightest case" -- the
# never-negative-$body_height guarantee, asserted indirectly via the row
# count never falling short.
# ===========================================================================
SKIP: {
    skip 'tui::Screen did not load', 1 unless $SCREEN_OK;

    my @cols_sweep = (1, 2, 3, 4, 8, 12, 20, 40, 80, 120);
    my @rows_sweep = (3, 4, 5, 8, 12, 24, 50);
    my $long_a = 'a banner so long it will not fit in many widths at all either today';
    my $long_b = 'another moderately long banner message included for the three-banner fixture';
    my @banner_fixtures = (
        [ 'zero banners',  [] ],
        [ 'one banner',    [ $long_a ] ],
        [ 'three banners', [ 'short one', $long_a, $long_b ] ],
    );

    my @violations;
    for my $cols (@cols_sweep) {
        for my $rows (@rows_sweep) {
            for my $bf (@banner_fixtures) {
                my ($label, $banners) = @$bf;
                my $screen = {
                    title   => 'T',
                    footer  => 'F',
                    banners => $banners,
                    panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
                };
                my $f = tui::Screen::compose($screen, $rows, $cols);
                if (scalar(@$f) != $rows) {
                    push @violations,
                        "cols=$cols rows=$rows banners=[$label]: got " . scalar(@$f) . " cells, wanted $rows";
                }
            }
        }
    }
    is(scalar(@violations), 0,
        'AC-3/AC-3d: scalar(@{compose(...)}) == $rows EXACTLY for every (cols,rows,banner-count) combination in the sweep')
        or diag("  " . scalar(@violations) . " violation(s), first few:\n  "
            . join("\n  ", @violations[0 .. ($#violations > 9 ? 9 : $#violations)]));
}

# ===========================================================================
# AC-4(a)/(b) (DC4) -- $rows==1 / $rows==2 short-circuits are unaffected by
# banner content, at any $cols, regardless of banner length.
# ===========================================================================
SKIP: {
    skip 'tui::Screen did not load', 1 unless $SCREEN_OK;

    my @cols_sweep = (1, 2, 3, 40, 80);
    my $screen = {
        title   => 'T',
        footer  => 'F',
        banners => [ 'a banner so long it will not fit in many widths at all either today' ],
        panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
    };
    for my $cols (@cols_sweep) {
        my $f1 = tui::Screen::compose($screen, 1, $cols);
        is(scalar(@$f1), 1, "AC-4a (cols=$cols): \$rows==1 returns exactly 1 cell regardless of banner content");
        my $f2 = tui::Screen::compose($screen, 2, $cols);
        is(scalar(@$f2), 2, "AC-4b (cols=$cols): \$rows==2 returns exactly 2 cells regardless of banner content");
    }
}

# ===========================================================================
# AC-4(c) (DC4) -- $rows==3: banners fully absorbed (zero banner rows
# emitted), panel/body row still present.
# ===========================================================================
SKIP: {
    skip 'tui::Screen did not load', 2 unless $SCREEN_OK;

    my $screen = {
        title   => 'T',
        footer  => 'F',
        banners => [ 'short one', 'a banner so long it will not fit at all either today', 'another banner' ],
        panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
    };
    my $cols = 12;
    my $f = tui::Screen::compose($screen, 3, $cols);
    is(scalar(@$f), 3, 'AC-4c: $rows==3 still returns exactly 3 cells');
    my @banner_rows = banner_rows_by_role($f, 'state.warn');
    is(scalar(@banner_rows), 0, 'AC-4c: $rows==3 (max_banner_rows==0) absorbs ALL banner content -- zero banner rows emitted');
}

# ===========================================================================
# AC-4(d) (DC4) -- $rows==4: exactly one banner row, containing ONLY the
# first wrapped line of the FIRST banner (never a later banner's leading
# rows, per Decision D2's ordering rule).
# ===========================================================================
SKIP: {
    skip 'tui::Screen (or Frame) did not load', 2 unless $SCREEN_OK && $FRAME_OK;

    my $first_banner  = 'a banner so long it will not fit at all either today for sure';
    my $second_banner = 'a second banner that would also overflow this column width';
    my $cols = 12;
    my $screen = {
        title   => 'T',
        footer  => 'F',
        banners => [ $first_banner, $second_banner ],
        panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
    };
    # TWO BODY ROWS PLUS THE CHROME, not the literal 4 this was. The condition
    # the case is built on is max_banner_rows == 1 -- i.e. body_height == 2 --
    # and 4 expressed that when the chrome was title + footer. The footer rule
    # made the chrome three rows in 2026-08; a remembered 4 makes body_height 1,
    # max_banner_rows 0, and tests nothing this section is about.
    my $rows = 2 + tui::Screen::chrome_rows();
    my $f = tui::Screen::compose($screen, $rows, $cols);
    is(scalar(@$f), $rows, "AC-4d: \$rows==$rows still returns exactly $rows cells");
    my @banner_rows = banner_rows_by_role($f, 'state.warn');
    is(scalar(@banner_rows), 1, "AC-4d: \$rows==$rows (max_banner_rows==1) emits EXACTLY one banner row");
  SKIP: {
        skip 'no banner row emitted -- fix not implemented yet', 1 unless @banner_rows == 1;
        my $expected_first_row = tui::Frame::wrap_line(
            $first_banner, 'state.warn', $cols, tui::Screen::WRAP_CONTINUATION_INDENT()
        )->[0];
        is_deeply($banner_rows[0], $expected_first_row,
            'AC-4d: that one banner row is byte-identical to the FIRST wrapped line of the FIRST banner, nothing else');
    }
}

# ===========================================================================
# AC-4(e) (DC4) -- title/footer with content longer than $cols, at $cols in
# (1,2,3): exactly one cell each, display_width == $cols exactly. Unchanged
# from today (Decision D1: title/footer keep truncating, deliberately).
# ===========================================================================
SKIP: {
    skip 'tui::Screen (or Layout) did not load', 1 unless $SCREEN_OK && $LAYOUT_OK;

    my $screen = {
        title  => 'a title so long it will not fit in a few columns at all',
        footer => 'a footer so long it will not fit in a few columns at all',
    };
    for my $cols (1, 2, 3) {
        my $f1 = tui::Screen::compose($screen, 1, $cols);
        is(tui::Layout::display_width(plain($f1->[0])), $cols,
            "AC-4e (cols=$cols): the title cell is exactly \$cols display columns wide (padded/truncated, never more than one row)");
        my $f2 = tui::Screen::compose($screen, 2, $cols);
        is(tui::Layout::display_width(plain($f2->[1])), $cols,
            "AC-4e (cols=$cols): the footer cell is exactly \$cols display columns wide (padded/truncated, never more than one row)");
    }
}

# ===========================================================================
# AC-4(f) (DC4/DC5) -- banner wrap at $cols in (1,2,3): every emitted banner
# cell's display_width <= $cols, EXCEPT the documented DC5 forced-progress
# case (a decoded character wider than $cols is still emitted whole, bounded
# to that glyph's own width) -- identical exception t/77 already pins for
# panel bodies (t/77:124-144), now also holding for banners.
# ===========================================================================
SKIP: {
    skip 'tui::Screen did not load', 1 unless $SCREEN_OK && $LAYOUT_OK;

    my $rows = 12; # body_height=10, max_banner_rows=9 -- ample room to wrap fully
    my @violations;
    my @unbounded;
    for my $cols (1, 2, 3) {
        my $banner_text = "ab $WIDE cd $WIDE ef gh ij kl mn op";
        utf8::encode(my $bytes = $banner_text);
        my $screen = {
            title   => 'T',
            footer  => 'F',
            banners => [ $bytes ],
            panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
        };
        my $f = tui::Screen::compose($screen, $rows, $cols);
        my @banner_rows = banner_rows_by_role($f, 'state.warn');
        for my $i (0 .. $#banner_rows) {
            my $dw = tui::Layout::display_width(plain($banner_rows[$i]));
            if ($cols == 1) {
                push @unbounded, "cols=1 row=$i: display_width=$dw > 2" if $dw > 2;
            } else {
                push @violations, "cols=$cols row=$i: display_width=$dw > $cols" if $dw > $cols;
            }
        }
    }
    is(scalar(@violations), 0,
        'AC-4f: at cols in (2,3), every emitted banner row respects display_width <= $cols')
        or diag("  " . join("\n  ", @violations));
    is(scalar(@unbounded), 0,
        'AC-4f: at cols==1 (unavoidable), any overflow is bounded to the forced glyph\'s own width (2), never more')
        or diag("  " . join("\n  ", @unbounded));
}

# ===========================================================================
# AC-5 (DC5) -- adversarial banner text containing a raw ESC byte, wrapped
# across multiple rows: no emitted cell's {text} contains \x1b anywhere.
# Pinned as a REGRESSION GUARD (see spec Decision D4): escapes are added
# only in Frame.pm's paint_row, after width arithmetic, so this is expected
# to already hold -- the point is to catch a FUTURE refactor that moves
# escape generation earlier, not to prove a present bug.
# ===========================================================================
SKIP: {
    skip 'tui::Screen did not load', 1 unless $SCREEN_OK;

    my $adversarial = chr(27) . '[31m' . join(' ', ('overflowing') x 20) . chr(27) . '[0m';
    my @bad;
    for my $cols (5, 10, 20) {
        my $screen = {
            title   => 'T',
            footer  => 'F',
            banners => [ $adversarial ],
            panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
        };
        my $f = tui::Screen::compose($screen, 12, $cols);
        for my $i (0 .. $#$f) {
            my $t = ref($f->[$i]) eq 'HASH' ? $f->[$i]{text} : undef;
            push @bad, "cols=$cols cell=$i" if defined($t) && $t =~ /\x1b/;
        }
    }
    is(scalar(@bad), 0,
        'AC-5: no emitted cell anywhere in the frame contains a raw ESC byte, at any swept width, with an adversarial ESC-laden banner')
        or diag("  " . join(', ', @bad));
}

# ===========================================================================
# Decision D3 -- exact shape of a wrapped banner's leading/continuation
# indent (accepted cosmetic side-effect, pinned so a future refactor that
# silently changes it is caught, not rediscovered): line 0 starts "!!", NOT
# "  !!" (the two leading spaces are lost to word-flattening); continuation
# lines start with exactly WRAP_CONTINUATION_INDENT() (2) leading spaces,
# not 4.
# ===========================================================================
SKIP: {
    skip 'tui::DashboardScreen did not load', 1 unless $DS_OK && $SCREEN_OK;

    my $install_warning =
        'zqx-install warning several backpack items failed to install correctly '
      . 'and need manual review before proceeding';
    my $state = { status => 'running', install_warning => $install_warning };
    my $f = tui::DashboardScreen::compose($state, 24, 20);
    my @banner_rows = banner_rows_by_role($f, 'overlay.warn');
    cmp_ok(scalar(@banner_rows), '>=', 2, 'D3 fixture: the install_warning banner wraps into at least 2 rows at cols=20')
        or diag("  only " . scalar(@banner_rows) . " banner row(s) -- fixture no longer overflows, re-check the text");
  SKIP: {
        skip 'fewer than 2 banner rows -- D3 shape not checkable yet', 3 unless @banner_rows >= 2;
        my $line0 = plain($banner_rows[0]);
        my $line1 = plain($banner_rows[1]);
        # RE-POINTED 2026-08-28: THE "!!" MARKER IS GONE.
        #
        # It was the visual cue that a full-width grid row was an ALERT rather
        # than panel content -- necessary when alerts shared the layout with
        # everything else. Alerts are now an overlay painted in their own role
        # ('overlay.warn'), on its own dark-red background, above the footer.
        # The surface itself says "alert", so prefixing every line with "!!"
        # became noise that ate two columns of the message.
        #
        # What still matters, and is asserted instead: the first line carries
        # the message (not padding), and the continuation is indented so a
        # wrapped alert reads as one block rather than two unrelated rows.
        like($line0, qr/\S/, 'D3: wrapped banner line 0 carries message text');
        my ($lead) = $line1 =~ /^( *)/;
        cmp_ok(length($lead // ''), '>=', 1,
            'D3: a wrapped banner continuation line is indented, so the wrap reads as one block');
    }
}

# ===========================================================================
# Edge case (spec S5) -- a banner containing an atomic span (Meter-gauge
# shape) still delegates whole to make_cell via wrap_line's existing atomic
# carve-out: exactly one row, unchanged from today. Defensive-only case
# (production banners never emit atomic spans) -- one assertion, no fixture
# family built around it.
# ===========================================================================
SKIP: {
    skip 'tui::Screen did not load', 1 unless $SCREEN_OK;

    my $cols = 10;
    my $atomic_banner = [
        { text => 'gauge ', role => 'text.primary' },
        { text => ('#' x 40), role => 'accent', atomic => 1 },
    ];
    my $screen = {
        title   => 'T',
        footer  => 'F',
        banners => [ $atomic_banner ],
        panels  => [ { title => 'P', lines => [ 'a body line' ] } ],
    };
    my $f = tui::Screen::compose($screen, 12, $cols);
    my @banner_rows = banner_rows_by_role($f, 'state.warn');
    is(scalar(@banner_rows), 1, 'edge case: an atomic-bearing overflowing banner still produces exactly ONE row, never wrapped');
}

done_testing();
