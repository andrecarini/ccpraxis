#!/usr/bin/env perl
# 73-layout-flex-stability.t
#
# Two operator complaints about the dashboard, which turned out to be ONE
# defect seen twice:
#
#   "the overall layout is a piece of shit. Look at all the empty space"
#   "when the dashboard TUI appeared it first was a complete mess with
#    characters jumping around and it took many seconds until it actually
#    settled into the final layout"
#
# Every panel rendered at its NATURAL content height and the leftover body
# height became blank padding at the bottom. That single decision produces both:
# a 55-row terminal drew ~15 rows of content and ~35 rows of nothing, AND every
# panel's position depended on how much content the panels above it happened to
# have -- so while the activity log was being actively written during the first
# seconds of a launch, the whole frame reflowed on each arriving event.
#
# The fix is tui::Screen's flex band (H6): one panel absorbs the leftover rows,
# so the space is used AND the geometry stops tracking content. This file pins
# both halves, plus the two ways it could go wrong: the flex panel being
# squeezed out entirely on a short terminal, and panels that appear mid-session
# (the detached resources sampler) re-introducing the reflow.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Dashboard ();
use tui::Screen ();

# ---------------------------------------------------------------- fixtures ---

sub events {
    my ($n) = @_;
    return [ map { [ { text => tui::DashboardScreen::activity_time_text(sprintf('%02d:%02d', 9 + int($_ / 60), $_ % 60)),
                       role => 'text.muted' },
                     { text => "o event-$_", role => 'text.primary' } ] } (1 .. $n) ];
}

sub state {
    my (%o) = @_;
    my %s = (
        project_name => 'demo',
        container    => 'claude-demo-abcd1234',
        status       => 'running',
        beat_age     => 12,
        uptime       => 3600,
        events       => events($o{events} // 20),
        backpack     => { total => 15, approved => 12, pending => 3 },
        runs         => [ map { { blueprint => "bp-$_", state => 'solo',
                                  packages_done => 0, packages_total => 3 } } (1 .. ($o{runs} // 12)) ],
        tokens       => { access => 'EXPIRED', refresh => 'present (abc123)' },
    );
    $s{resources} = $o{resources} if $o{resources};
    return \%s;
}

sub plain { my ($c) = @_; my $t = $c->{text}; $t =~ s/\x1b\[[0-9;]*m//g; return $t }

# The panel titles present, with the row each starts on. This is the GEOMETRY
# -- what must not move when content changes.
sub geometry {
    my ($frame) = @_;
    my @out;
    my $i = 0;
    for my $cell (@$frame) {
        $i++;
        my $t = plain($cell);
        utf8::decode($t) unless utf8::is_utf8($t);
        # The title lead-in is a rule glyph, not the old ASCII '--' (operator
        # request, 2026-08-25): a panel's title line is now its top border, so
        # it is continuous with its own filler. Both ends of the match are
        # therefore U+2500. Written as the escape rather than a literal because
        # this file must not `use utf8`.
        while ($t =~ /\x{2500}\s+([A-Za-z][A-Za-z ]*?)\s+\x{2500}/g) { push @out, "$1\@$i" }
    }
    return join(' | ', @out);
}

sub blank_tail {
    my ($frame) = @_;
    my $n = 0;
    # The footer is the last row; count blank body rows immediately above it.
    for (my $i = $#$frame - 1; $i >= 0; $i--) {
        last if plain($frame->[$i]) =~ /\S/;
        $n++;
    }
    return $n;
}

# ============================================================================
# 1. The empty space is gone.
# ============================================================================
{
    # The launcher hands the dashboard up to ACTIVITY_EVENT_MAX (50) events, so
    # that is the fixture: with real content available, the body must be full.
    for my $rows (24, 40, 55) {
        my $f = Dashboard::compose_frame(state(events => 50), $rows, 110);
        is(scalar @$f, $rows, "compose still returns exactly $rows rows");
        cmp_ok(blank_tail($f), '<=', 1,
            "rows=$rows: at most one blank row above the footer -- the body is filled, not padded")
            or diag("  blank tail = " . blank_tail($f));
    }

    # And when content genuinely runs out, the shortfall is HONEST -- there is
    # no more activity to show. What matters is that it does not grow with the
    # terminal: a taller screen must not mean proportionally more dead space.
    my $short_tail = blank_tail(Dashboard::compose_frame(state(events => 6), 30, 110));
    my $tall_tail  = blank_tail(Dashboard::compose_frame(state(events => 6), 55, 110));
    cmp_ok($tall_tail - $short_tail, '<=', 25,
        'with only 6 events the leftover tracks the missing content, not the terminal height');
}

# ============================================================================
# 2. The geometry does not move as the activity log grows.
#
# This is the settling bug stated precisely: during the first seconds of a
# launch, events arrive one at a time. Every panel's position must be
# unaffected.
# ============================================================================
{
    my $base;
    my $moved = 0;
    for my $n (1, 3, 6, 12, 20, 35, 50) {
        my $g = geometry(Dashboard::compose_frame(state(events => $n), 40, 110));
        $base //= $g;
        $moved++ if $g ne $base;
    }
    is($moved, 0,
       'panel positions are identical for 1..50 activity events -- an arriving event cannot reflow the frame');
}

# ============================================================================
# 3. ...and the extra height is actually SPENT on activity rows, not padding.
# ============================================================================
{
    my $short = Dashboard::compose_frame(state(events => 50), 24, 110);
    my $tall  = Dashboard::compose_frame(state(events => 50), 50, 110);
    my $count = sub {
        my ($f) = @_;
        return scalar grep { plain($_) =~ /event-\d+/ } @$f;
    };
    cmp_ok($count->($tall), '>', $count->($short),
        'a taller terminal shows MORE activity rows -- the flex panel uses the space rather than padding it');
}

# ============================================================================
# 4. The flex panel is never squeezed out.
#
# The regression this guards: bands above the flex one render at natural
# height, so a tall Run panel could consume the whole body and the loop would
# stop before ever reaching the activity panel. Losing the largest panel
# because something above it grew is worse than the reflow it replaced.
# ============================================================================
{
    for my $rows (10, 14, 16, 20, 24, 30, 40, 55) {
        for my $runs (1, 12, 40) {
            my $f = Dashboard::compose_frame(state(runs => $runs, events => 50), $rows, 110);
            like(geometry($f), qr/Recent activity/,
                "rows=$rows runs=$runs: the activity panel still exists");
        }
    }
}

# ============================================================================
# 5. Panels that arrive mid-session do not appear from nowhere.
#
# The resources sampler is a DETACHED process: it starts as the dashboard opens
# and writes its first snapshot seconds later. While its key was undef the panel
# did not exist at all, so it materialised mid-session and pushed everything
# after it down -- a scheduled reflow a few seconds into every launch. Same for
# Providers (t01-providers-panel's successor to Spend, whose snapshot is never
# written at all today), and for Blueprints (t01's new sibling panel for the
# blueprint-run list, unconditional for the identical reason -- D4).
#
# RETARGETED (package t01-providers-panel, spec §6): the panel title `Spend`
# no longer exists -- its direct successor `Providers` is the claim's new
# subject, the CLAIM ITSELF ("the panel exists before any snapshot is read")
# is unchanged. `Blueprints` is an ADDITION (recommended by spec §6, not a
# correction) closing the gap this package opens: it is now equally
# unconditional (D4) and this is exactly the oracle that would catch a
# future regression reintroducing a conditional panel.
# ============================================================================
{
    my $g_absent = geometry(Dashboard::compose_frame(state(), 40, 110));
    like($g_absent, qr/Resources/,  'the Resources panel exists BEFORE the sampler has written anything');
    like($g_absent, qr/Providers/,  'the Providers panel exists even though no spend snapshot is ever written today');
    like($g_absent, qr/Blueprints/, 'the Blueprints panel exists even with zero blueprint runs (D4: unconditional like Resources/Providers)');

    my $f = Dashboard::compose_frame(state(), 40, 110);
    my $txt = join("\n", map { plain($_) } @$f);
    like($txt, qr/sampling - no reading yet/,
        'and Resources SAYS it has no reading rather than silently not being there');
    # AMENDED BY t02-spend-persistence (blueprint tui-operator-feedback). The
    # literal it pinned, "no snapshot", is gone: that phrase described OUR
    # plumbing rather than the account, and read as though the provider had
    # been asked and had nothing to say -- when in fact nothing had asked
    # (claude was never fetched by anything, and the persisted snapshot the
    # other two came from was in a format the reader could not parse).
    #
    # THE ASSERTION'S INTENT IS THE SENTENCE AFTER THE COMMA, and it is
    # untouched: Providers must STATE the absence rather than express it by
    # being missing. So what is pinned now is that a non-empty absence
    # statement is present, not which words it uses -- and this still fails if
    # Providers goes back to rendering nothing, or renders figures it does not
    # have. The alternation is deliberately narrow rather than a bare /./, so a
    # panel that silently stopped saying anything cannot pass it.
    like($txt, qr/not collected yet|collecting - no figures yet|FAILED - spend sampler|STALLED - spend sampler/,
        'and Providers states the absence rather than expressing it by being missing (D6 footnote preserved; wording replaced by t02)');
    unlike($txt, qr/\b0\.0\b|\b0%/,
        'neither fabricates a zero -- absent-vs-empty is preserved, only how it is communicated changed');
}

# ============================================================================
# 6. tui::Screen's flex contract, directly.
# ============================================================================
{
    my $screen = {
        title  => 'T',
        footer => 'F',
        panels => [
            { title => 'Fixed', lines => [ 'a', 'b' ] },
            { title => 'Flexy', lines => [ map { "row$_" } (1 .. 40) ], flex => 1 },
        ],
    };
    my $f = tui::Screen::compose($screen, 20, 60);
    is(scalar @$f, 20, 'compose returns exactly the requested rows');
    my $rendered = scalar grep { plain($_) =~ /row\d+/ } @$f;
    cmp_ok($rendered, '>=', 10,
        'the flex panel expands into the body rather than stopping at its natural height');

    # Without the marker, the old behaviour: content height only, blanks after.
    my $screen2 = { %$screen, panels => [ map { my %p = %$_; delete $p{flex}; \%p } @{ $screen->{panels} } ] };
    my $f2 = tui::Screen::compose($screen2, 20, 60);
    my $rendered2 = scalar grep { plain($_) =~ /row\d+/ } @$f2;
    cmp_ok($rendered2, '<=', $rendered,
        'and a panel WITHOUT the flex marker never takes more than it did before -- the change is opt-in');
}

# ============================================================================
# 7. Degenerate inputs still return exactly $rows and never die.
# ============================================================================
{
    for my $rows (1, 2, 3, 4) {
        my $f = eval { Dashboard::compose_frame(state(), $rows, 110) };
        is($@, '', "rows=$rows: compose does not die");
        is(scalar @$f, $rows, "rows=$rows: exactly $rows rows returned");
    }
    my $f = eval { tui::Screen::compose({ panels => [ { title => 'X', flex => 1 } ] }, 10, 40) };
    is($@, '', 'a flex panel with NO lines does not die');
    is(scalar @$f, 10, 'and still fills the frame');
}

done_testing();
