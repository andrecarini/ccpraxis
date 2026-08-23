#!/usr/bin/env perl
# 79-providers-panel.t -- ORACLE for package t01-providers-panel (blueprint
# butler-and-dashboard-overhaul), specs/t01-providers-panel-spec.md. Derived
# from the spec's §4 observable behaviors and §5 acceptance criteria, and
# from the package's own done criteria. WRITTEN BLIND TO
# plugins/sandbox/scripts/tui/DashboardScreen.pm's eventual edit -- every
# fixture's shape was verified only against UNCHANGED, already-shipped
# helpers (_spend_body/_spend_*_spans, _token_body, _run_summary_lines,
# row(), fmt_duration()) as they exist today, per the spec's own claim that
# those helpers are reused, not rewritten. Do NOT weaken an assertion here
# to make a future implementation's life easier.
#
# THE OPERATOR'S COMPLAINT IS AMBIGUITY OF REFERENT, NOT SCREEN ECONOMY --
# "it's now not even clear anymore what these refer to". Assertions below
# therefore check WHICH provider a fact belongs to (heading order, gutter
# absence on headings, shallower heading indentation, per-block nonce
# isolation for Behavior 7), not merely that fewer rows exist.
#
# THE ANTI-CHANGE this package's spec identifies (t/40 AC-17, t/41 AC7):
# those two blocks assert Dashboard::_fixed_panels(...) directly, which is a
# FROZEN, deliberately-retained legacy builder (D3) that still says
# 'Token'/'Spend' and is NOT part of the render path (Dashboard::compose_frame
# delegates entirely to tui::DashboardScreen::compose). This file never
# calls Dashboard::_fixed_panels/_run_lines/_token_lines/_spend_lines, and
# adds its OWN check (below) that their doc comments say so explicitly.
#
# NON-VACUITY: every negative/absence assertion below is paired with either
# a counter-fixture that trips the same detector, or a positive twin proving
# the detector is not simply blind (house rule; this blueprint has hit the
# vacuity trap four times already).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Dashboard ();
use tui::DashboardScreen ();
use tui::Layout ();

my $BP = tui::Layout::BREAKPOINT_TWO_COL();

# ===========================================================================
# Scaffolding
# ===========================================================================
sub plain {
    my ($c) = @_;
    my $t = $c->{text};
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}
sub frame_text { my ($f) = @_; return join("\n", map { plain($_) } @$f) }

# Structural access to the render path's OWN panel data, bypassing Frame's
# fixed-width layout entirely -- used wherever a claim is about STRUCTURE
# (heading order, indentation, gutter) rather than about the final $cols-wide
# render.
sub panel_by_title {
    my ($panels, $title) = @_;
    return undef unless ref($panels) eq 'ARRAY';
    for my $p (@$panels) {
        return $p if ref($p) eq 'HASH' && defined($p->{title}) && $p->{title} eq $title;
    }
    return undef;
}
sub line_text {
    my ($line) = @_;
    return '' unless ref($line) eq 'ARRAY';
    return join('', map { defined($_->{text}) ? $_->{text} : '' } @$line);
}
sub panel_line_texts {
    my ($panel) = @_;
    return [] unless $panel && ref($panel->{lines}) eq 'ARRAY';
    return [ map { line_text($_) } @{ $panel->{lines} } ];
}
sub leading_ws {
    my ($t) = @_;
    return 0 unless defined $t;
    my ($ws) = $t =~ /^(\s*)/;
    return length($ws // '');
}

my $NOW = 1785800000;

sub base_state {
    my (%o) = @_;
    return {
        project_name => 'zqxproj79',
        container    => 'zqxctr79',
        status       => 'running',
        beat_age     => 12,
        uptime       => 3660,
        %o,
    };
}

# --- token fixtures (shape verified against today's UNCHANGED _token_body) ---
my %TOKENS_EXPIRED_45S = (
    logged_in => 1, access_present => 1, access_state => 'expired',
    access_expires_at => $NOW - 5, access_seconds_left => -5,
    refresh_present => 1, refresh_fingerprint => 'zqxfp0079',
    refresh_expires => 'n/a (not stored)',
    last_refreshed_at => $NOW - 45, last_refreshed_age => 45,
    subscription_type => 'max', rate_limit_tier => 'default_max',
);
my %TOKENS_EXPIRED_NO_REFRESH_AGE = (%TOKENS_EXPIRED_45S, last_refreshed_age => undef, last_refreshed_at => undef);

# --- spend fixtures (shape verified against today's UNCHANGED
#     _spend_body/_spend_claude_spans/_spend_go_spans/_spend_zen_spans,
#     and matching the \%info contract documented in
#     t/54-spend-panel.t's own header) ---
my %SPEND_3PROVIDERS = (
    claude   => { state => 'ok', windows => [ { name => 'five_hour', fraction => 0.2, text => 'zqxclaudespend79' } ] },
    go       => { state => 'ok', windows => [ { name => 'monthly', used => 10, limit => 20, fraction => 0.5, text => 'zqxgospend79' } ] },
    zen      => { state => 'ok', balance_text => 'zqxzenspend79', budget_text => 'budget', fraction => 0.25 },
    priority => [ { provider => 'go', window => 'monthly', fraction => 0.5 } ],
);
my %SPEND_NO_PRIORITY = (%SPEND_3PROVIDERS, priority => []);

sub runs_n {
    my ($n) = @_;
    return [ map { { blueprint => "bp-$_", state => 'solo', packages_done => 0, packages_total => 3 } } (1 .. $n) ];
}

# ===========================================================================
# AC1 (done-criterion 1) -- one panel titled Providers; no Token; no Spend.
# ===========================================================================
{
    for my $cols (60, 140) {
        my $f = Dashboard::compose_frame(base_state(), 30, $cols);
        my $t = frame_text($f);
        like($t, qr/-- Providers /, "AC1: cols=$cols -- a panel titled Providers exists");
        unlike($t, qr/-- Token /, "AC1: cols=$cols -- no panel titled Token exists");
        unlike($t, qr/-- Spend /, "AC1: cols=$cols -- no panel titled Spend exists (Providers is its successor)");
    }
}

# ===========================================================================
# AC2 (done-criterion 2) -- three named provider blocks, in order, with
# Claude Code's token facts nested under it; referent clarity (Behavior 2/3).
# ===========================================================================
{
    my $state  = base_state(tokens => { %TOKENS_EXPIRED_45S }, spend => { %SPEND_3PROVIDERS });
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $providers = panel_by_title($panels, 'Providers');
    ok($providers, 'AC2 precondition: panels() returns a panel titled Providers');

  SKIP: {
        skip('no Providers panel to inspect', 11) unless $providers;
        my $texts = panel_line_texts($providers);

        my ($cc_i)  = grep { defined($texts->[$_]) && $texts->[$_] =~ /Claude Code/ } (0 .. $#$texts);
        my ($go_i)  = grep { defined($texts->[$_]) && $texts->[$_] =~ /OpenCode Go/ } (0 .. $#$texts);
        my ($zen_i) = grep { defined($texts->[$_]) && $texts->[$_] =~ /OpenCode Zen/ } (0 .. $#$texts);
        ok(defined $cc_i,  'AC2: a "Claude Code" heading line exists in Providers');
        ok(defined $go_i,  'AC2: an "OpenCode Go" heading line exists in Providers');
        ok(defined $zen_i, 'AC2: an "OpenCode Zen" heading line exists in Providers');

      SKIP: {
            skip('a heading is missing', 1) unless defined($cc_i) && defined($go_i) && defined($zen_i);
            ok($cc_i < $go_i && $go_i < $zen_i,
                'AC2/Behavior2: the three headings appear in the order Claude Code, OpenCode Go, OpenCode Zen');
        }

        # Behavior 3 -- referent-clarity mechanics: a heading carries no
        # ' : ' gutter and is more shallowly indented than the fact row(s)
        # nested under it.
        for my $pair ([$cc_i, 'Claude Code'], [$go_i, 'OpenCode Go'], [$zen_i, 'OpenCode Zen']) {
            my ($idx, $label) = @$pair;
          SKIP: {
                skip("no $label heading found", 2) unless defined $idx;
                unlike($texts->[$idx], qr/\s:\s/, "AC2/Behavior3: the '$label' heading carries no ' : ' label-gutter");
                my $fact = $texts->[$idx + 1];
              SKIP: {
                    skip('no following fact row to compare indentation against', 1) unless defined $fact;
                    cmp_ok(leading_ws($texts->[$idx]), '<', leading_ws($fact),
                        "AC2/Behavior3: the '$label' heading is indented MORE SHALLOWLY than the fact row immediately beneath it");
                }
            }
        }

        # Non-vacuity: the detectors above must be ABLE to see the defect
        # they exist to catch -- a hand-built ambiguous pair (heading WITH a
        # gutter, SAME indentation as its fact row) must trip both.
        my $bad_heading = 'Claude Code : mystery';
        my $bad_fact    = 'access      : EXPIRED';
        like($bad_heading, qr/\s:\s/, 'AC2 non-vacuity: the gutter detector fires on a hand-built heading that DOES carry a gutter');
        is(leading_ws($bad_heading), leading_ws($bad_fact),
            'AC2 non-vacuity: the indentation detector sees EQUAL indentation on a hand-built ambiguous pair -- proves it is not vacuously true');

        # The access-expiry marker lives specifically inside the Claude Code
        # block, not merely "somewhere".
      SKIP: {
            skip('missing Claude Code / OpenCode Go heading index', 1) unless defined($cc_i) && defined($go_i);
            my $cc_block = join("\n", @{$texts}[$cc_i .. $go_i - 1]);
            like($cc_block, qr/EXPIRED/, 'AC2: the access-expiry text renders WITHIN the Claude Code block');
        }
    }

    # And nowhere else in the whole composed frame (not duplicated, not
    # leaked into another panel).
    my $f = Dashboard::compose_frame($state, 30, 120);
    my $t = frame_text($f);
    my $n = () = $t =~ /EXPIRED/g;
    is($n, 1, 'AC2: the access-expiry marker "EXPIRED" appears EXACTLY once in the whole composed frame');
}

# ===========================================================================
# AC3 (done-criteria 3 & 4) -- refresh-exp gone; refreshed folded into
# access, same row, same builder change (Behavior 4/5/6).
# ===========================================================================
{
    for my $case (
        ['tokens present, refresh-age defined',   { tokens => { %TOKENS_EXPIRED_45S } }],
        ['tokens present, refresh-age undefined', { tokens => { %TOKENS_EXPIRED_NO_REFRESH_AGE } }],
        ['no tokens at all',                      {}],
    ) {
        my ($label, $extra) = @$case;
        my $t = frame_text(Dashboard::compose_frame(base_state(%$extra), 30, 120));
        unlike($t, qr/refresh-exp/, "AC3/Behavior5: no frame ($label) ever contains the literal text 'refresh-exp'");
    }
}
{
    my $panels_with    = tui::DashboardScreen::panels(base_state(tokens => { %TOKENS_EXPIRED_45S }), 120);
    my $panels_without = tui::DashboardScreen::panels(base_state(tokens => { %TOKENS_EXPIRED_NO_REFRESH_AGE }), 120);
    my $providers_with    = panel_by_title($panels_with, 'Providers');
    my $providers_without = panel_by_title($panels_without, 'Providers');
    ok($providers_with && $providers_without, 'AC3 precondition: a Providers panel exists in both arms');

  SKIP: {
        skip('Providers panel missing in one arm', 9) unless $providers_with && $providers_without;
        my $texts_with    = panel_line_texts($providers_with);
        my $texts_without = panel_line_texts($providers_without);

        my ($access_with)    = grep { /access\s*:/i } @$texts_with;
        my ($access_without) = grep { /access\s*:/i } @$texts_without;
        ok(defined $access_with,    'AC3: an access row exists when last_refreshed_age is defined');
        ok(defined $access_without, 'AC3: an access row exists when last_refreshed_age is undefined');

      SKIP: {
            skip('no access row found in one arm', 3) unless defined($access_with) && defined($access_without);
            like($access_with, qr/EXPIRED/, 'AC3: the access row still carries the expiry-state text');
            like($access_with, qr/45s/,
                'AC3/Behavior4: the SAME access row ALSO carries the last-refreshed duration (fmt_duration(45)="45s") when last_refreshed_age is defined');
            unlike($access_without, qr/45s/,
                'AC3/Behavior4: with last_refreshed_age undefined, no duration renders in the access row (matches suppression of the old standalone refreshed row)');
        }

        my @refreshed_with    = grep { /^\s*refreshed\s*:/i } @$texts_with;
        my @refreshed_without = grep { /^\s*refreshed\s*:/i } @$texts_without;
        is(scalar(@refreshed_with), 0, 'AC3/Behavior4: no standalone "refreshed" row exists anywhere when last_refreshed_age is defined');
        is(scalar(@refreshed_without), 0, 'AC3/Behavior4: no standalone "refreshed" row exists anywhere when last_refreshed_age is undefined');

        my ($refresh_with) = grep { /^\s*refresh\s*:/i } @$texts_with;
        ok(defined $refresh_with, 'AC3/Behavior6: the unchanged "refresh" row (present/absent fingerprint) still renders, distinct from "refreshed"/"refresh-exp"');
        like($refresh_with, qr/present \(zqxfp0079\)/, 'AC3/Behavior6: the "refresh" row still carries the fingerprint text unchanged') if defined $refresh_with;

        # Non-vacuity: the "no standalone refreshed row" detector must be
        # ABLE to fire -- prove it on a hand-built row that IS labeled
        # 'refreshed'.
        my @counter = grep { /^\s*refreshed\s*:/i } ('refreshed   : 45s ago', 'access      : EXPIRED', 'refresh     : present (x)');
        is(scalar(@counter), 1, 'AC3 non-vacuity: the "refreshed" row detector fires exactly once on a hand-built fixture literally labeled refreshed');
    }
}

# ===========================================================================
# AC4 (done-criterion 5) -- the 'nearest' row (D1): panel-level, first line,
# outside every provider block; absent when priority is empty.
# ===========================================================================
{
    my $panels_wp = tui::DashboardScreen::panels(base_state(spend => { %SPEND_3PROVIDERS }), 120);
    my $providers_wp = panel_by_title($panels_wp, 'Providers');
    ok($providers_wp, 'AC4 precondition: a Providers panel exists with a non-empty priority list');
  SKIP: {
        skip('no Providers panel', 2) unless $providers_wp;
        my $texts = panel_line_texts($providers_wp);
        like($texts->[0], qr/nearest/i, "AC4/Behavior9: the FIRST line of the Providers body is the nearest-exhaustion summary");
        my ($cc_i) = grep { defined($texts->[$_]) && $texts->[$_] =~ /Claude Code/ } (0 .. $#$texts);
        ok(defined($cc_i) && $cc_i > 0,
            'AC4/Behavior9/D1: the nearest line sits BEFORE the first Claude Code heading -- panel-level, not nested under any provider');
    }

    my $panels_np = tui::DashboardScreen::panels(base_state(spend => { %SPEND_NO_PRIORITY }), 120);
    my $providers_np = panel_by_title($panels_np, 'Providers');
  SKIP: {
        skip('no Providers panel', 1) unless $providers_np;
        my $texts_np = panel_line_texts($providers_np);
        my @nearest = grep { /nearest/i } @$texts_np;
        is(scalar(@nearest), 0, 'AC4 non-vacuity: with priority empty, NO nearest line renders at all -- proves the detector is not always-on');
    }
}

# ===========================================================================
# Behavior 7 -- OpenCode Go / OpenCode Zen carry exactly their own spend
# fact, never Claude's, never each other's.
# ===========================================================================
{
    my $state = base_state(spend => { %SPEND_3PROVIDERS });
    my $t = frame_text(Dashboard::compose_frame($state, 30, 120));
    for my $nonce (qw(zqxclaudespend79 zqxgospend79 zqxzenspend79)) {
        my $n = () = $t =~ /\Q$nonce\E/g;
        is($n, 1, "Behavior7: spend nonce '$nonce' appears exactly once in the whole composed frame");
    }

    my $panels = tui::DashboardScreen::panels($state, 120);
    my $providers = panel_by_title($panels, 'Providers');
  SKIP: {
        skip('no Providers panel', 3) unless $providers;
        my $texts = panel_line_texts($providers);
        my ($go_i)  = grep { defined($texts->[$_]) && $texts->[$_] =~ /OpenCode Go/ } (0 .. $#$texts);
        my ($zen_i) = grep { defined($texts->[$_]) && $texts->[$_] =~ /OpenCode Zen/ } (0 .. $#$texts);
      SKIP: {
            skip('missing a heading index', 3) unless defined($go_i) && defined($zen_i);
            my $go_block  = join("\n", @{$texts}[$go_i .. $zen_i - 1]);
            my $zen_block = join("\n", @{$texts}[$zen_i .. $#$texts]);
            like($go_block, qr/zqxgospend79/, "Behavior7: OpenCode Go's own spend fact renders inside its own block");
            unlike($go_block, qr/zqxzenspend79|zqxclaudespend79/, "Behavior7: OpenCode Go's block never carries Zen's or Claude's spend fact");
            unlike($zen_block, qr/zqxgospend79/, "Behavior7: OpenCode Zen's block never carries Go's spend fact");
        }
    }
}

# ===========================================================================
# Behavior 8 / D6 -- when $state->{spend} is entirely absent, all three
# provider blocks still render, with an honest absence, plus a once-only
# footnote distinguishing "a run is active" from "no active run".
# ===========================================================================
{
    my $state  = base_state(tokens => { %TOKENS_EXPIRED_45S }); # no spend key at all
    my $panels = tui::DashboardScreen::panels($state, 120);
    my $providers = panel_by_title($panels, 'Providers');
    ok($providers, 'Behavior8 precondition: the Providers panel renders even when $state->{spend} is entirely absent');
  SKIP: {
        skip('no Providers panel', 5) unless $providers;
        my $texts = panel_line_texts($providers);
        ok((grep { /Claude Code/ } @$texts), 'Behavior8: Claude Code heading still renders with spend absent');
        ok((grep { /OpenCode Go/ } @$texts), 'Behavior8: OpenCode Go heading still renders with spend absent');
        ok((grep { /OpenCode Zen/ } @$texts), 'Behavior8: OpenCode Zen heading still renders with spend absent');
        # AMENDED BY t02-spend-persistence (blueprint tui-operator-feedback).
        # The footnote no longer mentions a RUN, so /\brun\b/ no longer
        # matches it. That is the change, not a casualty of it: under
        # blueprint Decision 11 a run is the wrong absence to name. Every
        # figure in this panel -- go's windows, zen's balance, claude's
        # utilizations -- describes the ACCOUNT, and a snapshot is now written
        # whether or not a fleet run exists. "no active run to report spend
        # for" was accurate and useless, which is exactly what the operator
        # said about it when they reported this panel.
        #
        # BOTH PARTS OF THE INTENT ARE KEPT, and the second is the load-bearing
        # one: a footnote exists, and it renders EXACTLY ONCE -- panel-level,
        # not once per provider block. The count assertion is what stops the
        # absence statement from being duplicated three times as the provider
        # blocks were reworded, and it is unchanged.
        my @footnote = grep { /collecting - no figures yet|FAILED - spend sampler|STALLED - spend sampler/ } @$texts;
        ok(scalar(@footnote) >= 1, 'Behavior8/D6: an absent-spend footnote renders in the panel (wording replaced by t02; it no longer names a run)');
        is(scalar(@footnote), 1, 'Behavior8/D6: the footnote renders exactly ONCE -- panel-level, not once per provider block') if @footnote;
    }
}

# ===========================================================================
# AC5 (done-criteria 6 & 7) -- Blueprints is its own titled panel, sibling
# of Run; the row budget moved with it (Behavior 10/11/13/14/15/16/17).
# ===========================================================================
{
    my $runs = runs_n(12);

    # Behavior 10: Blueprints exists, is a sibling of Run (not nested in it).
    my $t = frame_text(Dashboard::compose_frame(base_state(runs => $runs), 24, 120));
    like($t, qr/-- Blueprints /, 'AC5/Behavior10: a panel titled Blueprints exists');

    # Behavior 11/16: Run's own content is unaffected by how many blueprint
    # runs exist -- structurally identical with 0 vs 12 runs, and no
    # per-blueprint summary row leaks into it.
    my $panels_no_runs   = tui::DashboardScreen::panels(base_state(), 120);
    my $panels_with_runs = tui::DashboardScreen::panels(base_state(runs => $runs), 120);
    my $run_no   = panel_by_title($panels_no_runs, 'Run');
    my $run_with = panel_by_title($panels_with_runs, 'Run');
    ok($run_no && $run_with, 'Behavior16 precondition: a Run panel exists regardless of $state->{runs}');
  SKIP: {
        skip('missing Run panel in one arm', 2) unless $run_no && $run_with;
        is_deeply(panel_line_texts($run_with), panel_line_texts($run_no),
            "AC5/Behavior16: Run's own body is IDENTICAL whether or not \$state->{runs} has entries -- the blueprint list moved out entirely");
        ok((grep { /bp-\d+\s*:/ } @{ panel_line_texts($run_with) }) == 0,
            'AC5/Behavior11: Run never carries a per-blueprint summary row (the "<blueprint> : <state> N/M pkg" shape), even with 12 runs present');
    }

    # Behavior13/14/15: overflow arithmetic and the budget travelling with
    # Blueprints, not Run. Two DIFFERENT preset budgets on the SAME 12-run
    # fixture must yield two DIFFERENT overflow counts (Behavior 15: a
    # preset $state->{blueprint_rows_max} is honored unchanged; Behavior 13:
    # the overflow-count arithmetic is unchanged).
    for my $case ([5, 7], [10, 2]) {
        my ($budget, $expected_overflow) = @$case;
        my $f = Dashboard::compose_frame(base_state(runs => $runs, blueprint_rows_max => $budget), 40, 120);
        my $t2 = frame_text($f);
        if ($t2 =~ /\+(\d+) more blueprint/) {
            is($1, $expected_overflow,
                "AC5/Behavior13/15: blueprint_rows_max=$budget -> '+N more blueprint(s)' shows N=$expected_overflow (12 runs - $budget budget)");
        } else {
            fail("AC5/Behavior13/15: blueprint_rows_max=$budget -> expected an overflow line '+$expected_overflow more blueprint(s)' but none was found");
        }
    }

    # Behavior14: compose()'s OWN derivation (int($rows/3), floor 3) --
    # without a preset budget, two different $rows values must derive two
    # different overflow counts on the same 12-run fixture (proving the
    # derivation is live, not a coincidence of one sample).
    my $t_r24 = frame_text(Dashboard::compose_frame(base_state(runs => $runs), 24, 120)); # budget=int(24/3)=8 -> overflow=4
    my $t_r30 = frame_text(Dashboard::compose_frame(base_state(runs => $runs), 30, 120)); # budget=int(30/3)=10 -> overflow=2
    my ($n24) = $t_r24 =~ /\+(\d+) more blueprint/;
    my ($n30) = $t_r30 =~ /\+(\d+) more blueprint/;
    ok(defined($n24) && defined($n30), 'AC5/Behavior14 precondition: an overflow line is found at both rows=24 and rows=30');
  SKIP: {
        skip('overflow line missing at one of the two row counts', 1) unless defined($n24) && defined($n30);
        isnt($n24, $n30,
            "AC5/Behavior14: rows=24 (N=$n24) and rows=30 (N=$n30) derive DIFFERENT overflow counts on the SAME 12-run fixture -- the budget travelled with Blueprints and tracks \$rows, not a fixed constant");
    }

    # Behavior17: in two-column mode, Run pairs with Blueprints (never
    # Providers, never Resources) -- Blueprints is unconditional, so no
    # fixture augmentation is needed.
    my $small_runs = runs_n(3);
    my $below = $BP - 1;
    my $f_below = Dashboard::compose_frame(base_state(runs => $small_runs), 24, $below);
    my $both_below = grep { $_->{text} =~ /-- Run / && $_->{text} =~ /-- Blueprints / } @$f_below;
    is($both_below, 0, "Behavior17: 24x$below -- no row carries BOTH \"-- Run \" and \"-- Blueprints \" (still stacked, below breakpoint)");

    my $f_at = Dashboard::compose_frame(base_state(runs => $small_runs), 24, $BP);
    my $both_at = grep { $_->{text} =~ /-- Run / && $_->{text} =~ /-- Blueprints / } @$f_at;
    is($both_at, 1, "Behavior17: 24x$BP -- EXACTLY one row carries BOTH \"-- Run \" and \"-- Blueprints \" (two-column mode, unconditional pairing)");
}

# ===========================================================================
# Required coverage 6 -- panels stay always-present with HONEST no-data
# states: Resources, Providers, Blueprints must not pop in mid-session.
# Tested with an EMPTY state, not merely a populated one (D4).
# ===========================================================================
{
    my $minimal = { project_name => 'p', container => 'c', status => 'running' };
    for my $cols (60, 140) {
        my $t = frame_text(Dashboard::compose_frame($minimal, 30, $cols));
        like($t, qr/-- Resources /,  "Required-6: cols=$cols -- Resources present with a minimal (no-data) state");
        like($t, qr/-- Providers /,  "Required-6: cols=$cols -- Providers present with a minimal (no-data) state");
        like($t, qr/-- Blueprints /, "Required-6: cols=$cols -- Blueprints present with a minimal (no-data) state (D4 scope extension)");
    }

    my $panels = tui::DashboardScreen::panels($minimal, 120);
    my $bp_panel = panel_by_title($panels, 'Blueprints');
  SKIP: {
        skip('no Blueprints panel', 2) unless $bp_panel;
        my $texts = panel_line_texts($bp_panel);
        ok(scalar(@$texts) > 0, 'Required-6/Behavior12: Blueprints renders an HONEST no-data line rather than being empty when $state->{runs} is absent');
        ok((grep { /bp-\d+/ } @$texts) == 0, 'Required-6: with no runs, the no-data line does not fabricate a bp- entry');
    }

    # Non-vacuity: the SAME title regex must ALSO find Blueprints when runs
    # ARE present -- proves this is a genuine "always present" guarantee,
    # not a coincidence of the empty-state fixture alone.
    my $t_full = frame_text(Dashboard::compose_frame(base_state(runs => runs_n(3)), 30, 120));
    like($t_full, qr/-- Blueprints /, 'Required-6 non-vacuity: Blueprints also appears with runs present (not an empty-state-only fluke)');

    # Same non-vacuity pairing for the empty-runs vs non-empty-array vs
    # garbage-value cases (edge case §7): all three must produce the SAME
    # "no active runs" behavior (still present, no bp- fabricated).
    for my $case (['empty array', []], ['non-array garbage', 'not-an-array']) {
        my ($label, $val) = @$case;
        my $t3 = frame_text(Dashboard::compose_frame(base_state(runs => $val), 30, 120));
        like($t3, qr/-- Blueprints /, "Required-6: runs=$label -- Blueprints panel still present");
    }
}

# ===========================================================================
# Criterion 8 (done-criterion 8, second half) -- Dashboard.pm's four frozen
# duplicate builders are documented as historical/superseded (D3). This is a
# DOC-COMMENT check, not a behavior check -- t/40 AC-17 and t/41 AC7 already
# pin that the builders themselves stay byte-identical (the anti-change);
# this file's own job is only to confirm the required doc-comment addition
# landed, mirroring Behavior27's own source-scan convention.
# ===========================================================================
{
    my $dash_path = "$Bin/../../scripts/Dashboard.pm";
    open my $fh, '<', $dash_path or die "cannot open $dash_path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;
    my @lines = split /\n/, $src;

    for my $sub (qw(_fixed_panels _run_lines _token_lines _spend_lines)) {
        my ($sub_line_i) = grep { $lines[$_] =~ /^[ \t]*sub \Q$sub\E\b/ } (0 .. $#lines);
        if (defined $sub_line_i) {
            # The 35 lines immediately preceding the sub -- wide enough to
            # span an intervening non-comment line (e.g. `our $RUN_MAX_ROWS
            # = 3;` sits between _run_lines' doc comment and its `sub` line
            # today), without reaching into a PRECEDING sub's own comment.
            my $from = $sub_line_i - 35 < 0 ? 0 : $sub_line_i - 35;
            my $comment = join("\n", @lines[$from .. $sub_line_i - 1]);
            like($comment, qr/supersed/i,
                "criterion8: the doc comment for Dashboard::$sub says it is superseded (D3)");
            like($comment, qr/pre[-\s]?t01|historical/i,
                "criterion8: the doc comment for Dashboard::$sub names the PRE-t01 vocabulary or calls itself historical (D3)");
        } else {
            fail("criterion8: could not find 'sub $sub' in Dashboard.pm at all");
            fail("criterion8: (paired) same check, second assertion for $sub");
        }
    }
}

done_testing();
