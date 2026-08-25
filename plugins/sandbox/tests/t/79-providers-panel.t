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

# THE PANEL TITLE LEAD-IN, DERIVED. It was the ASCII '-- '; it is now one
# Theme rule.h glyph plus a space, so a title line is continuous with its own
# filler and can serve as the panel's top border (operator request,
# 2026-08-25). Taken from Theme rather than written out, so it cannot drift
# from the declaration the renderer actually uses.
require Theme;
my $RULE_LEAD    = Theme::glyph('rule.h');      # UTF-8 BYTES, matches row text
my $RULE_LEAD_RE = quotemeta($RULE_LEAD);
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
        like($t, qr/$RULE_LEAD_RE Providers /, "AC1: cols=$cols -- a panel titled Providers exists");
        unlike($t, qr/$RULE_LEAD_RE Token /, "AC1: cols=$cols -- no panel titled Token exists");
        unlike($t, qr/$RULE_LEAD_RE Spend /, "AC1: cols=$cols -- no panel titled Spend exists (Providers is its successor)");
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

        # RESTRUCTURED 2026-08-25 (operator request): Go and Zen are two
        # products of ONE provider, so they are facts nested under a single
        # "OpenCode" heading rather than two top-level headings that each
        # repeat the word. Four lines became three, and -- because they are now
        # ordinary fact rows -- their values align with every other value in
        # the panel instead of sitting in a private, narrower column.
        #
        # Behavior 2 and 3 are unchanged as PROPERTIES: every provider has a
        # heading, headings appear in a stable order, and a heading carries no
        # label gutter and is indented more shallowly than the facts beneath
        # it. Only the set of headings changed.
        my ($cc_i) = grep { defined($texts->[$_]) && $texts->[$_] =~ /Claude Code/ } (0 .. $#$texts);
        my ($oc_i) = grep { defined($texts->[$_]) && $texts->[$_] =~ /^\s*OpenCode\s*$/ } (0 .. $#$texts);
        ok(defined $cc_i, 'AC2: a "Claude Code" heading line exists in Providers');
        ok(defined $oc_i, 'AC2: a single "OpenCode" heading line exists in Providers');

        # ...and Go and Zen survive as FACTS under it, not as vanished content.
        my ($go_i)  = grep { defined($texts->[$_]) && $texts->[$_] =~ /^\s+Go\b/ }  (0 .. $#$texts);
        my ($zen_i) = grep { defined($texts->[$_]) && $texts->[$_] =~ /^\s+Zen\b/ } (0 .. $#$texts);
        ok(defined $go_i,  'AC2: a "Go" fact row exists (nested, not deleted)');
        ok(defined $zen_i, 'AC2: a "Zen" fact row exists (nested, not deleted)');

      SKIP: {
            skip('a heading is missing', 1) unless defined($cc_i) && defined($oc_i)
                                              && defined($go_i)  && defined($zen_i);
            ok($cc_i < $oc_i && $oc_i < $go_i && $go_i < $zen_i,
                'AC2/Behavior2: Claude Code, then OpenCode, then its Go and Zen facts, in that order');
        }

        # Behavior 3 -- referent-clarity mechanics: a heading carries no
        # ' : ' gutter and is more shallowly indented than the fact row(s)
        # nested under it.
        for my $pair ([$cc_i, 'Claude Code'], [$oc_i, 'OpenCode']) {
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

        # AMENDED BY t05-no-colons: the label gutter's separator is three
        # spaces now, not " : ". Every intent in this block is preserved --
        # which row exists, which text it carries, and which row must NOT
        # exist. The row matchers are anchored and require the label to be
        # followed by whitespace, so `refresh` still cannot match `refreshed`.
        #
        # THE "refreshed" ABSENCE CHECKS BELOW MATTERED MOST HERE. They were
        # is(0) assertions written against /^\s*refreshed\s*:/ and they would
        # have kept passing after the colon vanished -- vacuously, matching
        # nothing whatever the panel rendered. A green assertion that can no
        # longer fail is worse than a red one.
        my ($access_with)    = grep { /^\s*access\s+\S/i } @$texts_with;
        my ($access_without) = grep { /^\s*access\s+\S/i } @$texts_without;
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

        my $REFRESHED_ROW = qr/^\s*refreshed\s+\S/i;
        my @refreshed_with    = grep { $_ =~ $REFRESHED_ROW } @$texts_with;
        my @refreshed_without = grep { $_ =~ $REFRESHED_ROW } @$texts_without;
        is(scalar(@refreshed_with), 0, 'AC3/Behavior4: no standalone "refreshed" row exists anywhere when last_refreshed_age is defined');
        is(scalar(@refreshed_without), 0, 'AC3/Behavior4: no standalone "refreshed" row exists anywhere when last_refreshed_age is undefined');

        my ($refresh_with) = grep { /^\s*refresh\s+\S/i } @$texts_with;
        ok(defined $refresh_with, 'AC3/Behavior6: the unchanged "refresh" row (present/absent fingerprint) still renders, distinct from "refreshed"/"refresh-exp"');
        like($refresh_with, qr/present \(zqxfp0079\)/, 'AC3/Behavior6: the "refresh" row still carries the fingerprint text unchanged') if defined $refresh_with;

        # Non-vacuity: the "no standalone refreshed row" detector must be
        # ABLE to fire -- prove it on a hand-built row that IS labeled
        # 'refreshed'. The fixture rows below now use the CURRENT gutter
        # (t05-no-colons), and the detector is the SAME compiled pattern the
        # two absence checks above use, so this cannot drift from them the way
        # a second hand-written copy could.
        my @counter = grep { $_ =~ $REFRESHED_ROW }
            ('refreshed     45s ago', 'access        EXPIRED', 'refresh       present (x)');
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
        # THE 'nearest' SUMMARY ROW IS GONE (operator request, 2026-08-25:
        # "no point to have `nearest claude/five_hour 2500%`").
        #
        # It named the provider/window closest to exhaustion and its
        # percentage, every part of which the per-provider rows immediately
        # below already say, in the same panel, two lines down. It was also the
        # most visible casualty of the utilization scale bug: claude's fraction
        # was stored 0..100 where every other provider's is 0..1, so the
        # ranking put claude first unconditionally and this row was reporting
        # something that could not have said anything else.
        #
        # $spend->{priority} is still computed and t/54 is its oracle; what is
        # asserted here now is that the panel leads with a PROVIDER, which is
        # the property the removal was for.
        my $texts = panel_line_texts($providers_wp);
        like($texts->[0], qr/Claude Code/,
            'AC4/Behavior9: the Providers body leads with a provider heading, not a summary of the rows below it');
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
        # See the AC2 note above: one "OpenCode" heading with Go and Zen as
        # facts under it. Behavior8's property is that NOTHING disappears when
        # $state->{spend} is absent entirely, so all three are still asserted --
        # the heading and both products.
        ok((grep { /^\s*OpenCode\s*$/ } @$texts), 'Behavior8: the OpenCode heading still renders with spend absent');
        ok((grep { /^\s+Go\b/  } @$texts), 'Behavior8: the Go fact row still renders with spend absent');
        ok((grep { /^\s+Zen\b/ } @$texts), 'Behavior8: the Zen fact row still renders with spend absent');
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
    like($t, qr/$RULE_LEAD_RE Blueprints /, 'AC5/Behavior10: a panel titled Blueprints exists');

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
    my $both_below = grep { $_->{text} =~ /$RULE_LEAD_RE Run / && $_->{text} =~ /$RULE_LEAD_RE Blueprints / } @$f_below;
    is($both_below, 0, "Behavior17: 24x$below -- no row carries BOTH \"-- Run \" and \"-- Blueprints \" (still stacked, below breakpoint)");

    my $f_at = Dashboard::compose_frame(base_state(runs => $small_runs), 24, $BP);
    my $both_at = grep { $_->{text} =~ /$RULE_LEAD_RE Run / && $_->{text} =~ /$RULE_LEAD_RE Blueprints / } @$f_at;
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
        like($t, qr/$RULE_LEAD_RE Resources /,  "Required-6: cols=$cols -- Resources present with a minimal (no-data) state");
        like($t, qr/$RULE_LEAD_RE Providers /,  "Required-6: cols=$cols -- Providers present with a minimal (no-data) state");
        like($t, qr/$RULE_LEAD_RE Blueprints /, "Required-6: cols=$cols -- Blueprints present with a minimal (no-data) state (D4 scope extension)");
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
    like($t_full, qr/$RULE_LEAD_RE Blueprints /, 'Required-6 non-vacuity: Blueprints also appears with runs present (not an empty-state-only fluke)');

    # Same non-vacuity pairing for the empty-runs vs non-empty-array vs
    # garbage-value cases (edge case §7): all three must produce the SAME
    # "no active runs" behavior (still present, no bp- fabricated).
    for my $case (['empty array', []], ['non-array garbage', 'not-an-array']) {
        my ($label, $val) = @$case;
        my $t3 = frame_text(Dashboard::compose_frame(base_state(runs => $val), 30, 120));
        like($t3, qr/$RULE_LEAD_RE Blueprints /, "Required-6: runs=$label -- Blueprints panel still present");
    }
}

# Criterion 8's doc-comment check REMOVED 2026-08-25.
#
# It required Dashboard.pm's four frozen duplicate builders (_fixed_panels,
# _run_lines, _token_lines, _spend_lines) to carry doc comments saying they
# were superseded and historical. All four have since been DELETED as
# unreachable, which is the stronger form of the same intent: the best way to
# document that a duplicate is superseded is not to have it.
#
# An assertion that dead code still exists, and is still commented a certain
# way, is the one kind that cannot survive removing it.

# ===========================================================================
# VALUE-COLUMN ALIGNMENT (operator, 2026-08-25): "Providers values are one
# column right of every other panel".
#
#     backpack      5 items, 5 pending  [b]      <- Run
#     snapshot      fresh, 15s old, ...          <- Resources
#       access        expires in 7h21m, ...      <- Providers, out by _FACT_INDENT
#
# The tension this pins is real and is why the assertion is written as a
# RELATIONSHIP between two panels rather than as a column number: Providers must
# keep the nesting that Behavior 3 above requires (a heading indented LESS than
# its facts) AND land its values where every other panel lands them. Those are
# only compatible if the indent is spent OUT OF the label column rather than on
# top of it -- so if someone "fixes" the alignment by flattening the nesting,
# Behavior 3 goes red; if someone restores the old full-width gutter under the
# indent, this goes red. Neither can be satisfied by weakening the other.
# ===========================================================================
{
    my $panels = tui::DashboardScreen::panels(base_state(), 132);
    my $providers = panel_by_title($panels, 'Providers');
    my $run       = panel_by_title($panels, 'Run');
    ok($providers && $run, 'ALIGN precondition: both a Providers and a Run panel exist');

  SKIP: {
        skip('Providers or Run panel missing', 3) unless $providers && $run;

        # value_col($text) -> the column the VALUE starts at, i.e. past the
        # leading indent, the label and the gutter separator. Derived from the
        # rendered text the same way a reader's eye derives it: the first
        # non-space after the run of spaces that follows the label word.
        my $value_col = sub {
            my ($t) = @_;
            return undef unless defined $t && $t =~ /^(\s*\S+\s{2,})\S/;
            return length($1);
        };

        my ($run_row) = grep { $value_col->($_) } @{ panel_line_texts($run) };
        my ($fact_row) = grep { /^\s+\S/ && $value_col->($_) } @{ panel_line_texts($providers) };
        ok(defined $run_row,  'ALIGN: the Run panel has at least one label/value row to compare against')
            or diag('  Run lines: ' . join(' | ', @{ panel_line_texts($run) }));
        ok(defined $fact_row, 'ALIGN: the Providers panel has at least one INDENTED fact row')
            or diag('  Providers lines: ' . join(' | ', @{ panel_line_texts($providers) }));

      SKIP: {
            skip('no comparable pair of rows', 1) unless defined($run_row) && defined($fact_row);
            is($value_col->($fact_row), $value_col->($run_row),
               'ALIGN CANONICAL: an indented Providers fact starts its VALUE in the same column '
             . 'as an ordinary Run row -- the nesting indent is spent out of the label column, '
             . 'not added on top of it')
                or diag("  Run:       [$run_row]\n  Providers: [$fact_row]");
        }
    }
}

done_testing();
