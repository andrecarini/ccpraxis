#!/usr/bin/env perl
# 77-wrap-width-regressions.t -- fix-batch step-7 regression coverage for
# t02-wrap-on-overflow (blueprint butler-and-dashboard-overhaul).
#
# Covers two defects the step-6 oracle (t/75) did NOT catch, both found by
# the step-6 red-team and confirmed by the step-7 driver's own independent
# reproduction:
#
#   1. BLOCKER -- tui::Frame::wrap_line's forced-progress bypass
#      (Frame.pm:453 pre-fix) compared the combined (indent + oversized
#      chunk) width against the FULL column budget $w, while the wrap budget
#      each line was actually built against was $w minus the continuation
#      indent. Any forced single-glyph chunk landing on a continuation line
#      therefore overflowed $w by construction -- not only in the
#      degenerate "$w itself too small" case the bypass was written for.
#
#   2. MAJOR -- Dashboard::_fixed_region_height never modelled
#      tui::Screen::flex_reserve or _place_and_render's pre-flex-band skip,
#      so it silently over-predicted the fixed region's height (and hence
#      under-allocated Activity-panel capacity) whenever wrapped fixed-
#      region content was heavy enough to approach the real renderer's
#      budget -- reproducibly at ordinary (non-degenerate) terminal sizes.
#
# This file does NOT touch t/75, t/73, or any other existing test -- see
# the fix-batch dispatch (t02-wrap-on-overflow, step 7).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Encode qw(encode);

my $SCRIPTS = "$Bin/../../scripts";
use lib "$Bin/../../scripts";

my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'tui/Layout.pm loads') or diag("  require tui::Layout failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'tui/Frame.pm loads') or diag("  require tui::Frame failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'tui/Screen.pm loads') or diag("  require tui::Screen failed: $@");
my $DASH_OK = eval { require Dashboard; 1 };
ok($DASH_OK, 'Dashboard.pm loads') or diag("  require Dashboard failed: $@");

# ===========================================================================
# 1. The exact red-team/driver reproducer: w=3, indent=2, a fullwidth glyph
#    on an ordinary (non-adversarial) three-word row.
# ===========================================================================
SKIP: {
    skip 'tui::Frame not loaded', 3 unless $FRAME_OK && $LAYOUT_OK;

    my $wide = "\x{ff5c}";                 # fullwidth vertical bar, display width 2
    my $line = "ab $wide cd";
    utf8::encode(my $bytes = $line);
    my $cells = tui::Frame::wrap_line($bytes, 'text.primary', 3, 2);

    ok(ref($cells) eq 'ARRAY' && @$cells, 'reproducer: wrap_line returns a non-empty cell list');

    my @overwide;
    for my $i (0 .. $#$cells) {
        my $dw = tui::Layout::display_width($cells->[$i]{text});
        push @overwide, "cell $i: display_width=$dw (w=3)" if $dw > 3;
    }
    ok(!@overwide, 'reproducer: no emitted cell exceeds the requested width (w=3)')
        or diag("  overwide cells: " . join('; ', @overwide));

    # DC5 companion check: the glyph must still be present SOMEWHERE across
    # the emitted cells -- the fix must not trade "never overflow" for
    # "silently drop the forced glyph".
    my $joined = join('', map { $_->{text} } @$cells);
    ok(index($joined, encode('UTF-8', $wide)) >= 0,
        'reproducer: the forced wide glyph is still present in the emitted cells (DC5, not dropped)');
}

# ===========================================================================
# 2. Sweep: small widths x small indents x wide glyphs. The single case
#    above is a symptom; this is the actual contract (every emitted cell's
#    display_width <= $w, for every row that reaches the forced-progress
#    path AND for ordinary rows alongside it).
# ===========================================================================
SKIP: {
    skip 'tui::Frame not loaded', 2 unless $FRAME_OK && $LAYOUT_OK;

    # sep.bar (U+FF5C) is the ONLY glyph declared width=>2 anywhere in
    # Theme's glyph table (grep-confirmed against Theme.pm) -- the
    # reviewer's own "no width => 3 or higher exists" finding, and the
    # ceiling that makes $w<2 the sole genuinely-unrepresentable case
    # (DC5's forced-progress exception, S2.1b). U+FF21/U+4E2D are NOT in
    # the table and so measure width 1 under this codebase's OWN width
    # function, same as any other single-column character -- included here
    # to prove the invariant holds for ordinary (non-wide, per this table)
    # multi-byte characters too, not only the one declared-wide glyph.
    my @wide_glyphs = ("\x{ff5c}", "\x{ff21}", "\x{4e2d}");
    my @rows_text = (
        "ab $wide_glyphs[0] cd $wide_glyphs[1] ef",
        "$wide_glyphs[2]$wide_glyphs[2]$wide_glyphs[2] plain words here too",
        "x $wide_glyphs[0]$wide_glyphs[1] y",
    );

    my (@violations, @unbounded_overflows);
    for my $w (2 .. 8) {
        for my $indent (0 .. 4) {
            for my $text (@rows_text) {
                utf8::encode(my $bytes = $text);
                my $cells = eval { tui::Frame::wrap_line($bytes, 'text.primary', $w, $indent) };
                if ($@) {
                    push @violations, "w=$w indent=$indent text=[$text]: wrap_line died: $@";
                    next;
                }
                next unless ref($cells) eq 'ARRAY';
                for my $i (0 .. $#$cells) {
                    my $dw = eval { tui::Layout::display_width($cells->[$i]{text}) };
                    if (!defined $dw || $dw > $w) {
                        push @violations,
                            "w=$w indent=$indent text=[$text] cell $i: display_width="
                            . (defined $dw ? $dw : 'undef') . " > w=$w";
                    }
                }
            }
        }
    }
    ok(!@violations, 'sweep (w>=2, representable by the widest declared glyph): every emitted cell respects display_width <= $w')
        or diag("  " . scalar(@violations) . " violation(s), first few:\n  " . join("\n  ", @violations[0 .. ($#violations > 9 ? 9 : $#violations)]));

    # w=1: the one genuinely-unrepresentable budget (narrower than the
    # widest declared glyph). DC5 forbids dropping the glyph, so an
    # overflow here is unavoidable -- but per the fix, it must be bounded
    # EXACTLY to the forced glyph's own width (2), never inflated further
    # by an indent the line could not afford (the actual pre-fix defect:
    # indent + chunk_width, not chunk_width alone).
    for my $indent (0 .. 4) {
        for my $text (@rows_text) {
            utf8::encode(my $bytes = $text);
            my $cells = eval { tui::Frame::wrap_line($bytes, 'text.primary', 1, $indent) };
            next if $@ || ref($cells) ne 'ARRAY';
            for my $i (0 .. $#$cells) {
                my $dw = eval { tui::Layout::display_width($cells->[$i]{text}) };
                next unless defined $dw;
                push @unbounded_overflows, "indent=$indent text=[$text] cell $i: display_width=$dw > 2 (w=1)"
                    if $dw > 2;
            }
        }
    }
    ok(!@unbounded_overflows, 'sweep (w=1, unavoidable): any overflow is bounded to the forced glyph\'s own width (2), never indent-inflated')
        or diag("  " . scalar(@unbounded_overflows) . " unbounded overflow(s), first few:\n  " . join("\n  ", @unbounded_overflows[0 .. ($#unbounded_overflows > 9 ? 9 : $#unbounded_overflows)]));
}

# ===========================================================================
# 3. Predictor-vs-renderer agreement: Dashboard::_fixed_region_height(state,
#    cols, rows) against what Dashboard::compose_frame actually renders, at
#    the exact realistic sizes the step-6 red-team measured a mismatch at
#    (rows=30, cols=90 and cols=120; six long blueprint/package Run rows,
#    matching the spec's own long-name example).
# ===========================================================================
SKIP: {
    skip 'Dashboard/tui::Screen not loaded', 2 unless $DASH_OK && $SCREEN_OK;

    my @runs;
    for my $i (1 .. 6) {
        push @runs, {
            blueprint       => "iniciativa-cardapio-consolidation-package-$i",
            state           => 'running',
            packages_done   => 1,
            packages_total  => 3,
            current_package => "some-long-current-package-name-being-worked-on-right-now-$i",
        };
    }
    my %state = (status => 'running', runs => \@runs);
    my $rows = 30;

    for my $cols (90, 120) {
        my $frame = Dashboard::compose_frame(\%state, $rows, $cols);
        my $activity_title_idx;
        for my $i (1 .. $#$frame) {
            if ($frame->[$i]{text} =~ /-- Recent activity /) { $activity_title_idx = $i; last; }
        }
        ok(defined $activity_title_idx, "predictor-vs-renderer: compose_frame(cols=$cols) has a Recent-activity title row")
            or next;
        my $actual_fixed_rows = $activity_title_idx - 1;
        my $predicted = Dashboard::_fixed_region_height(\%state, $cols, $rows);
        is($predicted, $actual_fixed_rows,
            "predictor-vs-renderer: _fixed_region_height(state,$cols,$rows) agrees with compose_frame's actual fixed-region row count (cols=$cols)");
    }
}

# ---------------------------------------------------------------------------
# The `atomic` marker must survive the PRODUCTION path, not just wrap_line.
#
# Found by the step-8 UI pass, after BOTH the reviewer and the red-team had
# declared the atomic exclusion "structural". They were right about
# wrap_line/fit_spans, which honour the marker perfectly -- and both probed those
# directly. What neither exercised was tui::DashboardScreen::row(), which rebuilt
# every span hash with only text+role and silently dropped `atomic` before
# wrap_line could ever see it. Meter gauges shattered mid-bar at width 40.
#
# Harmless for as long as nothing wrapped; t02 made it a live spec violation.
#
# Asserted through row() ON PURPOSE. A unit test against wrap_line passes with the
# flag dropped -- that is precisely how this survived two review passes. The
# contract that matters is end-to-end: a span declared atomic by a caller must
# still be atomic by the time it reaches the wrapper.
# ---------------------------------------------------------------------------
{
    my $bar = eval { tui::Meter::bar(0.62, tui::Meter::BAR_CELLS()) };
    SKIP: {
        skip 'tui::Meter unavailable', 3 unless defined $bar && length $bar;

        my $spans = [
            { text => $bar,  role => 'text.primary', atomic => 1 },
            { text => ' 62%', role => 'text.primary', atomic => 1 },
        ];
        my $row = eval { tui::DashboardScreen::row(label => 'ctr mem', value => $spans, force => 1) };
        ok(ref($row) eq 'ARRAY', 'atomic-through-row: row() returns a span list');

        my $kept = grep { ref($_) eq 'HASH' && $_->{atomic} } @{ $row || [] };
        cmp_ok($kept, '>=', 2,
            'atomic-through-row: row() PRESERVES the atomic marker (it used to copy only text+role)');

        # And the end-to-end consequence: a gauge row must not be split by the
        # wrapper at a width where its content overflows.
        # local de-SGR helper (t/75 has its own; this file did not)
        my $plain = sub {
            my ($c) = @_;
            my $t = (ref($c) eq 'HASH') ? ($c->{text} // '') : ($c // '');
            $t =~ s/\e\[[0-9;]*m//g;
            return $t;
        };

        my $narrow = 40;
        my $cells  = eval { tui::Frame::wrap_line(tui::Frame::spans_text($row), 'text.primary', $narrow, 2) };
        my $gauge_intact = 1;
        if (ref($cells) eq 'ARRAY') {
            # the bar's leading glyphs must still sit contiguously on ONE cell
            (my $bar_plain = $bar) =~ s/\e\[[0-9;]*m//g;
            my $probe = substr($bar_plain, 0, 4);
            $gauge_intact = 0
                unless length($probe)
                    && grep { index($plain->($_), $probe) >= 0 } @$cells;
        }
        ok($gauge_intact,
            'atomic-through-row: the gauge bar survives on a single cell at width 40, never shattered');
    }
}

# ---------------------------------------------------------------------------
# step-8 UI-pass Finding 2 -- a wrapped row's FIRST line lost the row's own
# leading indent (the 2-column body gutter Screen.pm bakes into every row),
# while its continuation lines built their own indent fine. The first line
# rendered flush against the panel border, structurally different from every
# non-wrapping sibling row. Fixed in tui::Frame::wrap_line by recovering the
# leading whitespace-only span before it is lost to word-flattening and
# re-applying it to line 0 (and folding it into the continuation lines' own
# indent, so a continuation line still reads as MORE indented than line 0,
# not merely equal to it).
# ---------------------------------------------------------------------------
SKIP: {
    skip 'tui::Frame not loaded', 3 unless $FRAME_OK && $LAYOUT_OK;

    my $short_row = [
        { text => '  ',                       role => 'text.primary' },
        { text => 'busy-lease  : ',            role => 'text.muted' },
        { text => 'none (no active run)',      role => 'text.muted' },
    ];
    my $long_row = [
        { text => '  ',                        role => 'text.primary' },
        { text => 'backpack    : ',             role => 'text.muted' },
        { text => '15 items, 12 approved',      role => 'text.primary' },
        { text => ', 3 pending',                role => 'state.warn' },
        { text => '   [b] manage',              role => 'text.muted' },
    ];

    my $w = 40;
    my $short_cells = tui::Frame::wrap_line($short_row, 'text.primary', $w, 2);
    my $long_cells  = tui::Frame::wrap_line($long_row, 'text.primary', $w, 2);

    ok(scalar(@$long_cells) > 1, 'Finding 2 fixture: the long backpack row actually wraps at width 40')
        or diag("  only " . scalar(@$long_cells) . " cell(s) -- fixture no longer overflows, re-check the row text");

    my $leading_ws = sub {
        my ($text) = @_;
        return length($1) if $text =~ /^( *)/;
        return 0;
    };

    my $short_indent = $leading_ws->($short_cells->[0]{text});
    my $long_first_indent = $leading_ws->($long_cells->[0]{text});
    is($long_first_indent, $short_indent,
        "Finding 2: a wrapped row's FIRST line carries the SAME leading gutter ($short_indent cols) as an unwrapped sibling row")
        or diag("  short row first line: [" . $short_cells->[0]{text} . "]\n  long row first line:  [" . $long_cells->[0]{text} . "]");

    if (@$long_cells > 1) {
        my $long_cont_indent = $leading_ws->($long_cells->[1]{text});
        cmp_ok($long_cont_indent, '>', $long_first_indent,
            'Finding 2: a continuation line is strictly MORE indented than line 0 (the continuation-indent delta still applies on top)')
            or diag("  line 0: [" . $long_cells->[0]{text} . "]\n  line 1: [" . $long_cells->[1]{text} . "]");
    } else {
        fail('Finding 2: continuation-line indent check skipped -- row did not wrap');
    }
}

# ---------------------------------------------------------------------------
# step-8 UI-pass Finding 3 -- word-splitting each span's text INDEPENDENTLY
# (Frame.pm step 3a) rejoins tokens from adjacent spans with a space that was
# never in the source, whenever a span boundary falls mid-token with no
# space either side of it (e.g. "...12 approved" + ", 3 pending" -> rendered
# as "...approved , 3 pending", an inserted space before the comma). Fixed
# by tracking whether the previous span's text ended in a space and the
# current span's starts with one; when NEITHER does, the spans are glued in
# the source and must not gain a separator during wrap.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'tui::Frame not loaded', 2 unless $FRAME_OK && $LAYOUT_OK;

    my $glued_row = [
        { text => '  ',                        role => 'text.primary' },
        { text => 'backpack    : ',             role => 'text.muted' },
        { text => '15 items, 12 approved',      role => 'text.primary' },
        { text => ', 3 pending',                role => 'state.warn' },
        { text => '   [b] manage',              role => 'text.muted' },
    ];

    my $plain77 = sub {
        my ($c) = @_;
        my $t = (ref($c) eq 'HASH') ? ($c->{text} // '') : ($c // '');
        $t =~ s/\e\[[0-9;]*m//g;
        return $t;
    };

    # Byte-exact on a row that does NOT wrap (fast path, S2.1 priority 2).
    my $unwrapped = tui::Frame::wrap_line($glued_row, 'text.primary', 200, 2);
    my $unwrapped_text = $plain77->($unwrapped->[0]);
    $unwrapped_text =~ s/ +$//;   # strip only the trailing pad make_cell adds
    is($unwrapped_text, '  backpack    : 15 items, 12 approved, 3 pending   [b] manage',
        'Finding 3: an unwrapped row reconstructs byte-exact, no inserted space at the span boundary');

    # The wrapping case: join every emitted line's plain text and confirm no
    # "approved , 3" (space-then-comma) sequence exists anywhere -- the
    # spurious-space signature the UI pass reproduced live.
    for my $w (40, 60, 100) {
        my $cells = tui::Frame::wrap_line($glued_row, 'text.primary', $w, 2);
        my $joined = join(' ', map { $plain77->($_) } @$cells);
        unlike($joined, qr/approved\s+,/,
            "Finding 3 (width $w): 'approved' is not followed by a space then a comma -- the comma stayed glued to the word before it");
    }
}

done_testing();
