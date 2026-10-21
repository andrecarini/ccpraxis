#!/usr/bin/env perl
# platform: any
# ORACLE for the dashboard's "Claude Code" panel. Born as the oracle for
# package t01 (blueprint butler-and-dashboard-overhaul, specs/t01-spec.md),
# which merged the Token and Spend panels into one "Providers" panel. Do NOT
# weaken an assertion here to make a future implementation's life easier.
#
# PROVIDERS BECAME "CLAUDE CODE" WHEN OPENCODE SUPPORT WAS REMOVED. The panel
# used to nest each provider's facts under its own heading (Claude Code, then
# OpenCode with Go and Zen) and set the two blocks side by side on a wide
# terminal. With one provider left the panel title names it, so this file lost
# everything that existed only for that shape: the OpenCode/Go/Zen rows and
# their per-block nonce isolation, the heading-vs-fact indentation checks, the
# side-by-side column split, and the "values align DESPITE the indent" framing.
# What referent clarity still demands is asserted instead: no heading line in
# the body repeats the title, and no OpenCode/Go/Zen text appears at all --
# including when a legacy spend snapshot still carries go/zen rows.
#
# Also pinned here (unchanged in intent): access/refresh/account/usage rows and
# their contents, refresh-exp gone and refreshed folded into access, the oauth
# fallback feeding the access row, each fixture nonce rendering exactly once,
# the honest "not collected yet" absence, the FAILED/STALLED footnote vs the
# silent neutral case, no fabricated zeros, no colons in values, value-column
# alignment with Run, and the Blueprints panel that t01 split out of Run.
#
# NON-VACUITY: every negative/absence assertion below is paired with either
# a counter-fixture that trips the same detector, or a positive twin proving
# the detector is not simply blind.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

# THE PANEL TITLE LEAD-IN, DERIVED. One Theme rule.h glyph plus a space, so a
# title line is continuous with its own filler (operator request, 2026-08-25).
# Taken from Theme rather than written out, so it cannot drift from the
# declaration the renderer actually uses.
require Theme;
my $RULE_LEAD    = Theme::glyph('rule.h');      # UTF-8 BYTES, matches row text
my $RULE_LEAD_RE = quotemeta($RULE_LEAD);
use Dashboard ();
use SpendPanel ();
use tui::DashboardScreen ();
use tui::Layout ();

my $BP    = tui::Layout::BREAKPOINT_TWO_COL();
my $TITLE = 'Claude Code';

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
# fixed-width layout entirely.
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
sub cc_texts {
    my ($state, $cols) = @_;
    my $p = panel_by_title(tui::DashboardScreen::panels($state, $cols // 120), $TITLE);
    return $p ? panel_line_texts($p) : undef;
}
sub row_for {
    my ($texts, $label) = @_;
    my ($r) = grep { /^\s*\Q$label\E\s+\S/ } @{ $texts || [] };
    return $r;
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

# --- token fixtures ---
my %TOKENS_EXPIRED_45S = (
    logged_in => 1, access_present => 1, access_state => 'expired',
    access_expires_at => $NOW - 5, access_seconds_left => -5,
    refresh_present => 1, refresh_fingerprint => 'zqxfp0079',
    refresh_expires => 'n/a (not stored)',
    last_refreshed_at => $NOW - 45, last_refreshed_age => 45,
    subscription_type => 'zqxsubmax79', rate_limit_tier => 'zqxtier79',
);
my %TOKENS_EXPIRED_NO_REFRESH_AGE = (%TOKENS_EXPIRED_45S, last_refreshed_age => undef, last_refreshed_at => undef);
my %TOKENS_NO_ACCOUNT = (%TOKENS_EXPIRED_45S, subscription_type => undef, rate_limit_tier => undef);

# --- spend fixture (the \%info contract SpendPanel::status documents) ---
my %SPEND_CLAUDE = (
    claude   => { state => 'ok', windows => [ { name => 'five_hour', fraction => 0.2, text => 'zqxclaudespend79' } ] },
    priority => [ { provider => 'claude', window => 'five_hour', fraction => 0.2 } ],
);
my %SPEND_NO_PRIORITY = (%SPEND_CLAUDE, priority => []);

sub runs_n {
    my ($n) = @_;
    return [ map { { blueprint => "bp-$_", state => 'solo', packages_done => 0, packages_total => 3 } } (1 .. $n) ];
}

# ===========================================================================
# AC1 -- one panel titled Claude Code; no Token, no Spend, no Providers.
# ===========================================================================
{
    for my $cols (60, 140) {
        my $t = frame_text(Dashboard::compose_frame(base_state(), 30, $cols));
        like($t,   qr/$RULE_LEAD_RE Claude Code /, "AC1: cols=$cols -- a panel titled Claude Code exists");
        unlike($t, qr/$RULE_LEAD_RE Token /,       "AC1: cols=$cols -- no panel titled Token exists");
        unlike($t, qr/$RULE_LEAD_RE Spend /,       "AC1: cols=$cols -- no panel titled Spend exists");
        unlike($t, qr/$RULE_LEAD_RE Providers /,   "AC1: cols=$cols -- no panel titled Providers exists (Claude Code is its successor)");
    }
    # Non-vacuity: the title detector is the same shape as the absences above,
    # and a hand-built Providers title line trips it.
    like("$RULE_LEAD Providers $RULE_LEAD", qr/$RULE_LEAD_RE Providers /,
        'AC1 non-vacuity: the title detector fires on a hand-built Providers title');
}

# ===========================================================================
# AC2 -- referent clarity with one provider: the body is facts only, no
# heading repeating the title, no OpenCode/Go/Zen anywhere; the expiry is a
# Claude Code fact and renders exactly once in the frame.
# ===========================================================================
my $NO_OPENCODE_RE = qr/OpenCode|\bGo\b|\bZen\b/;
{
    my $state = base_state(tokens => { %TOKENS_EXPIRED_45S }, spend => { %SPEND_CLAUDE });
    for my $cols (60, 120, 200) {
        my $texts = cc_texts($state, $cols);
        ok($texts, "AC2 precondition: cols=$cols -- panels() returns a panel titled Claude Code");
      SKIP: {
            skip('no Claude Code panel', 4) unless $texts;
            is(scalar(grep { /Claude Code/ } @$texts), 0,
                "AC2: cols=$cols -- no body line repeats 'Claude Code' (the title already names the provider)");
            is(scalar(grep { $_ =~ $NO_OPENCODE_RE } @$texts), 0,
                "AC2: cols=$cols -- no OpenCode / Go / Zen text anywhere in the panel");
            is(scalar(grep { /^\s/ } @$texts), 0,
                "AC2: cols=$cols -- no body row is indented (no nesting under a heading)");
            like($texts->[0], qr/^access\s+\S/,
                "AC2: cols=$cols -- the body leads with the access fact, not a heading or summary");
        }
    }
    # Non-vacuity: the OpenCode/Go/Zen detector sees each of the old row shapes.
    is(scalar(grep { $_ =~ $NO_OPENCODE_RE } ('OpenCode', 'Go           x', 'Zen          y', 'access  ok')), 3,
        'AC2 non-vacuity: the OpenCode/Go/Zen detector fires on each hand-built legacy row, not on a Claude row');

    my $texts = cc_texts($state, 120) || [];
    like(join("\n", @$texts), qr/EXPIRED/, 'AC2: the access-expiry text renders inside the Claude Code panel');

    my $t = frame_text(Dashboard::compose_frame($state, 30, 120));
    my $n = () = $t =~ /EXPIRED/g;
    is($n, 1, 'AC2: the access-expiry marker "EXPIRED" appears EXACTLY once in the whole composed frame');
}

# ===========================================================================
# AC3 -- refresh-exp gone; refreshed folded into access; refresh row keeps
# the fingerprint; account row present only with account facts.
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
    my $texts_with    = cc_texts(base_state(tokens => { %TOKENS_EXPIRED_45S }));
    my $texts_without = cc_texts(base_state(tokens => { %TOKENS_EXPIRED_NO_REFRESH_AGE }));
    ok($texts_with && $texts_without, 'AC3 precondition: a Claude Code panel exists in both arms');

  SKIP: {
        skip('Claude Code panel missing in one arm', 11) unless $texts_with && $texts_without;

        # Anchored and requiring whitespace after the label, so `refresh`
        # cannot match `refreshed`.
        my $access_with    = row_for($texts_with,    'access');
        my $access_without = row_for($texts_without, 'access');
        ok(defined $access_with,    'AC3: an access row exists when last_refreshed_age is defined');
        ok(defined $access_without, 'AC3: an access row exists when last_refreshed_age is undefined');

      SKIP: {
            skip('no access row found in one arm', 3) unless defined($access_with) && defined($access_without);
            like($access_with, qr/EXPIRED/, 'AC3: the access row carries the expiry-state text');
            # DERIVED from fmt_duration: sub-minute durations render as '<1m'.
            my $dur = quotemeta(tui::DashboardScreen::fmt_duration(45));
            like($access_with, qr/refreshed $dur ago/,
                'AC3/Behavior4: the SAME access row ALSO carries the last-refreshed duration (fmt_duration(45))');
            unlike($access_without, qr/refreshed/,
                'AC3/Behavior4: with last_refreshed_age undefined, no duration renders in the access row');
        }

        my $REFRESHED_ROW = qr/^\s*refreshed\s+\S/i;
        is(scalar(grep { $_ =~ $REFRESHED_ROW } @$texts_with),    0, 'AC3/Behavior4: no standalone "refreshed" row when last_refreshed_age is defined');
        is(scalar(grep { $_ =~ $REFRESHED_ROW } @$texts_without), 0, 'AC3/Behavior4: no standalone "refreshed" row when last_refreshed_age is undefined');
        # Non-vacuity: the SAME compiled pattern fires on a hand-built row.
        is(scalar(grep { $_ =~ $REFRESHED_ROW } ('refreshed     45s ago', 'access        EXPIRED', 'refresh       present (x)')), 1,
            'AC3 non-vacuity: the "refreshed" row detector fires exactly once on a hand-built fixture literally labeled refreshed');

        my $refresh_with = row_for($texts_with, 'refresh');
        ok(defined $refresh_with, 'AC3/Behavior6: the "refresh" row (present/absent fingerprint) renders, distinct from "refreshed"/"refresh-exp"');
        like($refresh_with // '', qr/present \(zqxfp0079\)/, 'AC3/Behavior6: the "refresh" row carries the fingerprint text');

        my $account = row_for($texts_with, 'account');
        like($account // '', qr/zqxsubmax79 \/ zqxtier79/,
            'AC3: the account row renders subscription_type / rate_limit_tier when both are present');
    }

    my $texts_noacct = cc_texts(base_state(tokens => { %TOKENS_NO_ACCOUNT })) || [];
    ok(!defined row_for($texts_noacct, 'account'),
        'AC3: with neither subscription_type nor rate_limit_tier, NO account row renders (no blank row, no fabricated plan)');
    my $refresh_absent = row_for(cc_texts(base_state(tokens => { %TOKENS_EXPIRED_45S, refresh_present => 0 })) || [], 'refresh');
    like($refresh_absent // '', qr/absent/, 'AC3/Behavior6: with no refresh token, the refresh row says absent');
}

# ===========================================================================
# OAUTH FALLBACK -- with no token facts, $state->{oauth_remaining} feeds the
# access row (Run's old oauth row is gone, not duplicated).
# ===========================================================================
{
    my $texts = cc_texts(base_state(oauth_remaining => 7200)) || [];
    my $access = row_for($texts, 'access');
    my $dur = quotemeta(tui::DashboardScreen::fmt_duration(7200));
    like($access // '', qr/expires in $dur/,
        'OAUTH: with no token facts, the access row renders the oauth_remaining fallback (expires in fmt_duration(7200))');

    my $t = frame_text(Dashboard::compose_frame(base_state(oauth_remaining => 7200), 30, 120));
    my $n = () = $t =~ /expires in $dur/g;
    is($n, 1, 'OAUTH: the fallback expiry appears exactly once in the frame (Run carries no second oauth row)');

    # Positive twin: without the fallback the row says "not logged in", so the
    # assertion above is not satisfied by some default text.
    unlike(row_for(cc_texts(base_state()) || [], 'access') // '', qr/expires in/,
        'OAUTH non-vacuity: with neither tokens nor oauth_remaining, the access row carries no expiry');

    # Token facts win over the fallback when present.
    my $texts_tok = cc_texts(base_state(oauth_remaining => 7200, tokens => { %TOKENS_EXPIRED_45S })) || [];
    like(row_for($texts_tok, 'access') // '', qr/EXPIRED/,
        'OAUTH: when token facts are present they drive the access row, not oauth_remaining');
}

# ===========================================================================
# AC4 -- no 'nearest' summary row (removed 2026-08-25: it restated the row
# below it); the body leads with a fact.
# ===========================================================================
{
    for my $case (['non-empty priority', { %SPEND_CLAUDE }], ['empty priority', { %SPEND_NO_PRIORITY }]) {
        my ($label, $spend) = @$case;
        my $texts = cc_texts(base_state(spend => $spend)) || [];
        is(scalar(grep { /nearest/i } @$texts), 0, "AC4: $label -- no 'nearest' summary row renders");
    }
    is(scalar(grep { /nearest/i } ('nearest  claude/five_hour 20%')), 1,
        'AC4 non-vacuity: the nearest detector fires on a hand-built nearest row');
}

# ===========================================================================
# USAGE -- the spend nonce renders exactly once, in the usage row.
# ===========================================================================
{
    my $state = base_state(spend => { %SPEND_CLAUDE });
    my $t = frame_text(Dashboard::compose_frame($state, 30, 120));
    my $n = () = $t =~ /zqxclaudespend79/g;
    is($n, 1, "USAGE: spend nonce 'zqxclaudespend79' appears exactly once in the whole composed frame");

    my $usage = row_for(cc_texts($state) || [], 'usage');
    like($usage // '', qr/5h zqxclaudespend79/, 'USAGE: the claude window text renders in the usage row, tagged 5h');

    my $bad = row_for(cc_texts(base_state(spend => { claude => { state => 'unknown' }, priority => [] })) || [], 'usage');
    like($bad // '', qr/unreadable/, 'USAGE: an unreadable claude reading says unreadable, never a figure');
    unlike($bad // '', qr/\d%/, 'USAGE: an unreadable claude reading renders no percentage');
}

# ===========================================================================
# LEGACY SNAPSHOT -- a snapshot written before OpenCode was removed still
# carries go/zen rows. Through the real adapter + status(), only the claude
# figures reach the panel.
# ===========================================================================
{
    my $spend = SpendPanel::status(SpendPanel::from_snapshot({ results => [
        { provider => 'claude', status => 'ok', five_hour => { utilization => 42 }, seven_day => { utilization => 9 } },
        { provider => 'go',     status => 'ok' },
        { provider => 'zen',    status => 'ok' },
    ] }), 1787000000);
    my $texts = cc_texts(base_state(tokens => { %TOKENS_EXPIRED_45S }, spend => $spend)) || [];
    my $usage = row_for($texts, 'usage');
    like($usage // '', qr/5h 42%/, 'LEGACY: the claude five_hour figure (42%) renders in the usage row');
    like($usage // '', qr/7d 9%/,  'LEGACY: the claude seven_day figure (9%) renders in the usage row');
    is(scalar(grep { $_ =~ $NO_OPENCODE_RE } @$texts), 0,
        'LEGACY: nothing about OpenCode / Go / Zen renders from a snapshot that still carries go/zen rows');
    is(scalar(@$texts), 4,
        'LEGACY: the panel is exactly access, refresh, account, usage -- the go/zen rows added no row');

    my $t = frame_text(Dashboard::compose_frame(base_state(spend => $spend), 30, 140));
    unlike($t, $NO_OPENCODE_RE, 'LEGACY: no OpenCode / Go / Zen text anywhere in the composed frame');
}

# ===========================================================================
# Behavior 8 / D6 -- $state->{spend} entirely absent: the panel still renders,
# says "not collected yet" in the usage row, fabricates no zero; the footnote
# appears only when the sampler has a fault to name, and exactly once.
# ===========================================================================
{
    my $state = base_state(tokens => { %TOKENS_EXPIRED_45S }); # no spend key at all
    my $texts = cc_texts($state);
    ok($texts, 'Behavior8 precondition: the Claude Code panel renders even when $state->{spend} is entirely absent');
  SKIP: {
        skip('no Claude Code panel', 6) unless $texts;
        ok(defined row_for($texts, 'access'), 'Behavior8: the access row still renders with spend absent');
        my $usage = row_for($texts, 'usage');
        ok(defined $usage, 'Behavior8: the usage row is KEPT with spend absent (panel height does not change when figures arrive)');
        like($usage // '', qr/not collected yet/, 'Behavior8: the usage row says "not collected yet"');

        # NO FABRICATED ZEROS: absent figures are said, never rendered as 0%/$0.
        my $body = join("\n", @$texts);
        unlike($body, qr/\b0%|\$0|\d%/, 'Behavior8: no percentage or $0 is fabricated when spend is absent');
        like(join("\n", @{ cc_texts(base_state(spend => { claude => { state => 'ok', windows => [ { name => 'five_hour', fraction => 0, text => '0%' } ] } })) || [] }),
            qr/\b0%/, 'Behavior8 non-vacuity: a REAL 0% reading does render, so the detector above can see one');

        my $footnote_re = qr/collecting - no figures yet|FAILED - spend sampler|STALLED - spend sampler/;
        is(scalar(grep { /$footnote_re/ } @$texts), 0,
            'Behavior8/D6: a spend sampler with nothing to report renders NO footnote -- the usage row already says "not collected yet"');
    }
    is(scalar(@{ $texts || [] }), 4,
        'Behavior8/D6: the neutral case adds no row (access, refresh, account, usage -- no blank footnote row)');

    for my $case (
        ['FAILED',  { status => 'failed' },             qr/FAILED - spend sampler/],
        ['STALLED', { elapsed => 120, grace => 30 },    qr/STALLED - spend sampler/],
    ) {
        my ($label, $sampler, $want) = @$case;
        my $ft = cc_texts(base_state(tokens => { %TOKENS_EXPIRED_45S }, spend_sampler => $sampler));
        ok($ft, "Behavior8/D6 precondition: the Claude Code panel renders with a $label spend sampler");
        my @note = grep { $_ =~ $want } @{ $ft || [] };
        is(scalar(@note), 1, "Behavior8/D6: a $label spend sampler renders its footnote exactly ONCE -- the fault is named nowhere else");
        is($ft ? $ft->[-1] : undef, $note[0], "Behavior8/D6: the $label footnote is the panel's LAST line");

        # With figures present the footnote has nothing to explain.
        my $with = cc_texts(base_state(tokens => { %TOKENS_EXPIRED_45S }, spend => { %SPEND_CLAUDE }, spend_sampler => $sampler)) || [];
        is(scalar(grep { $_ =~ $want } @$with), 0, "Behavior8/D6: with spend present, a $label sampler adds no footnote");
    }
}

# ===========================================================================
# NO COLONS IN VALUES (Decision 2 / t05-no-colons): the gutter separator is
# whitespace, and no value carries a colon either.
# ===========================================================================
{
    for my $case (
        ['tokens + spend',         base_state(tokens => { %TOKENS_EXPIRED_45S }, spend => { %SPEND_CLAUDE })],
        ['no tokens, no spend',    base_state()],
        ['oauth fallback',         base_state(oauth_remaining => 7200)],
        ['failed spend sampler',   base_state(spend_sampler => { status => 'failed' })],
        ['unreadable claude',      base_state(spend => { claude => { state => 'unknown' }, priority => [] })],
    ) {
        my ($label, $state) = @$case;
        my $texts = cc_texts($state) || [];
        ok(scalar(@$texts) > 0 && !grep({ /:/ } @$texts), "NO-COLON: $label -- no Claude Code row renders a colon")
            or diag('  lines: ' . join(' | ', @$texts));
    }
    is(scalar(grep { /:/ } ('access : EXPIRED', 'usage   not collected yet')), 1,
        'NO-COLON non-vacuity: the detector fires on a hand-built row with a colon gutter');
}

# ===========================================================================
# AC5 -- Blueprints is its own titled panel, sibling of Run; the row budget
# moved with it (Behavior 10/11/13/14/15/16/17).
# ===========================================================================
{
    my $runs = runs_n(12);

    my $t = frame_text(Dashboard::compose_frame(base_state(runs => $runs), 24, 120));
    like($t, qr/$RULE_LEAD_RE Blueprints /, 'AC5/Behavior10: a panel titled Blueprints exists');

    my $run_no   = panel_by_title(tui::DashboardScreen::panels(base_state(), 120), 'Run');
    my $run_with = panel_by_title(tui::DashboardScreen::panels(base_state(runs => $runs), 120), 'Run');
    ok($run_no && $run_with, 'Behavior16 precondition: a Run panel exists regardless of $state->{runs}');
  SKIP: {
        skip('missing Run panel in one arm', 2) unless $run_no && $run_with;
        is_deeply(panel_line_texts($run_with), panel_line_texts($run_no),
            "AC5/Behavior16: Run's own body is IDENTICAL whether or not \$state->{runs} has entries -- the blueprint list moved out entirely");
        ok((grep { /bp-\d+\s*:/ } @{ panel_line_texts($run_with) }) == 0,
            'AC5/Behavior11: Run never carries a per-blueprint summary row, even with 12 runs present');
    }

    for my $case ([5, 7], [10, 2]) {
        my ($budget, $expected_overflow) = @$case;
        my $t2 = frame_text(Dashboard::compose_frame(base_state(runs => $runs, blueprint_rows_max => $budget), 40, 120));
        if ($t2 =~ /\+(\d+) more blueprint/) {
            is($1, $expected_overflow,
                "AC5/Behavior13/15: blueprint_rows_max=$budget -> '+N more blueprint(s)' shows N=$expected_overflow");
        } else {
            fail("AC5/Behavior13/15: blueprint_rows_max=$budget -> expected an overflow line '+$expected_overflow more blueprint(s)' but none was found");
        }
    }

    # Behavior14: compose()'s own derivation -- two heights, two overflow
    # counts on the same 12-run fixture (32 and 34 both render the line).
    my ($n32) = frame_text(Dashboard::compose_frame(base_state(runs => $runs), 32, 120)) =~ /\+(\d+) more blueprint/;
    my ($n34) = frame_text(Dashboard::compose_frame(base_state(runs => $runs), 34, 120)) =~ /\+(\d+) more blueprint/;
    ok(defined($n32) && defined($n34), 'AC5/Behavior14 precondition: an overflow line is found at both rows=32 and rows=34');
  SKIP: {
        skip('overflow line missing at one of the two row counts', 1) unless defined($n32) && defined($n34);
        isnt($n32, $n34,
            "AC5/Behavior14: rows=32 (N=$n32) and rows=34 (N=$n34) derive DIFFERENT overflow counts -- the budget tracks \$rows");
    }

    # Behavior17: below the breakpoint Run and Blueprints stack; on a wide
    # terminal Run pairs with Resources.
    my $small_runs = runs_n(3);
    my $below = $BP - 1;
    my $f_below = Dashboard::compose_frame(base_state(runs => $small_runs), 24, $below);
    my $both_below = grep { $_->{text} =~ /$RULE_LEAD_RE Run / && $_->{text} =~ /$RULE_LEAD_RE Blueprints / } @$f_below;
    is($both_below, 0, "Behavior17: 24x$below -- no row carries BOTH the Run and Blueprints titles (stacked below breakpoint)");

    my $wide = 200;
    my $f_at = Dashboard::compose_frame(base_state(runs => $small_runs), 24, $wide);
    my $both_at = grep { $_->{text} =~ /$RULE_LEAD_RE Run / && $_->{text} =~ /$RULE_LEAD_RE Resources / } @$f_at;
    is($both_at, 1, "Behavior17: 24x$wide -- EXACTLY one row carries BOTH the Run and Resources titles");
}

# ===========================================================================
# Required coverage 6 -- panels stay always-present with HONEST no-data
# states: Resources, Claude Code, Blueprints must not pop in mid-session.
# ===========================================================================
{
    my $minimal = { project_name => 'p', container => 'c', status => 'running' };
    for my $cols (60, 140) {
        my $t = frame_text(Dashboard::compose_frame($minimal, 30, $cols));
        like($t, qr/$RULE_LEAD_RE Resources /,   "Required-6: cols=$cols -- Resources present with a minimal (no-data) state");
        like($t, qr/$RULE_LEAD_RE Claude Code /, "Required-6: cols=$cols -- Claude Code present with a minimal (no-data) state");
        like($t, qr/$RULE_LEAD_RE Blueprints /,  "Required-6: cols=$cols -- Blueprints present with a minimal (no-data) state");
    }

    my $bp_panel = panel_by_title(tui::DashboardScreen::panels($minimal, 120), 'Blueprints');
  SKIP: {
        skip('no Blueprints panel', 2) unless $bp_panel;
        my $texts = panel_line_texts($bp_panel);
        ok(scalar(@$texts) > 0, 'Required-6/Behavior12: Blueprints renders an HONEST no-data line rather than being empty');
        ok((grep { /bp-\d+/ } @$texts) == 0, 'Required-6: with no runs, the no-data line does not fabricate a bp- entry');
    }

    my $t_full = frame_text(Dashboard::compose_frame(base_state(runs => runs_n(3)), 30, 120));
    like($t_full, qr/$RULE_LEAD_RE Blueprints /, 'Required-6 non-vacuity: Blueprints also appears with runs present');

    for my $case (['empty array', []], ['non-array garbage', 'not-an-array']) {
        my ($label, $val) = @$case;
        my $t3 = frame_text(Dashboard::compose_frame(base_state(runs => $val), 30, 120));
        like($t3, qr/$RULE_LEAD_RE Blueprints /, "Required-6: runs=$label -- Blueprints panel still present");
    }
}

# ===========================================================================
# VALUE-COLUMN ALIGNMENT (operator, 2026-08-25: "Providers values are one
# column right of every other panel"). With no nesting there is no indent to
# spend out of the label column: EVERY Claude Code fact row starts its value
# in exactly the column an ordinary Run row does. Asserted as a relationship
# between two panels, not a column number.
# ===========================================================================
{
    my $panels = tui::DashboardScreen::panels(base_state(tokens => { %TOKENS_EXPIRED_45S }, spend => { %SPEND_CLAUDE }), 132);
    my $cc  = panel_by_title($panels, $TITLE);
    my $run = panel_by_title($panels, 'Run');
    ok($cc && $run, 'ALIGN precondition: both a Claude Code and a Run panel exist');

  SKIP: {
        skip('Claude Code or Run panel missing', 6) unless $cc && $run;

        # value_col($text) -> the column the VALUE starts at: past the label
        # and the run of spaces that follows it.
        my $value_col = sub {
            my ($t) = @_;
            return undef unless defined $t && $t =~ /^(\s*\S+\s{2,})\S/;
            return length($1);
        };

        my ($run_row) = grep { $value_col->($_) } @{ panel_line_texts($run) };
        ok(defined $run_row, 'ALIGN: the Run panel has at least one label/value row to compare against')
            or diag('  Run lines: ' . join(' | ', @{ panel_line_texts($run) }));

        my $texts = panel_line_texts($cc);
      SKIP: {
            skip('no Run row to compare against', 4) unless defined $run_row;
            for my $label (qw(access refresh account usage)) {
                my $r = row_for($texts, $label);
                is(defined($r) ? $value_col->($r) : undef, $value_col->($run_row),
                   "ALIGN CANONICAL: the Claude Code '$label' value starts in the same column as an ordinary Run row")
                    or diag("  Run:         [$run_row]\n  Claude Code: [" . ($r // '<missing>') . "]");
            }
        }
        # Non-vacuity: a row indented by two (the old _FACT_INDENT shape, full
        # gutter on top) lands two columns right, and value_col sees it.
        my $plain_r  = tui::DashboardScreen::gutter('access') . 'x';
        isnt($value_col->('  ' . $plain_r), $value_col->($plain_r),
            'ALIGN non-vacuity: value_col distinguishes an indented row from a flush one');
    }
}

done_testing();
