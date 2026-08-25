#!/usr/bin/env perl
# s06-panel-semantics: colors + glyphs across Sandbox/Run/Backpack/Activity.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s06-panel-semantics (spec 03-panel-semantics-spec.md, S2 interfaces
# / S3 observable behaviors / S4 acceptance criteria). It is written BLIND to
# Dashboard.pm's implementation -- directly from the spec -- so it can serve
# as an oracle rather than an echo of whatever the implementer eventually
# writes.
#
# Coverage: AC1..AC28 (all of spec S4).
#
# The new subs under test (container_status_style, oauth_role, event_style,
# wrap_spans, _justify_spans, scroll_indicator, activity_row_width) and the
# changed-signature subs (_fixed_panels, build_panels, _backpack_lines,
# activity_window) DO NOT YET EXIST/behave per-spec on package load -- most
# assertions below are EXPECTED to fail with "Undefined subroutine" until the
# implementer lands s06. That is correct and by design.
#
# Hard constraint (spec S2, module contract): this file MUST NOT `use utf8`.
# Glyph literals are written as "\x{...}" escapes encoded to UTF-8 bytes via
# Encode::encode('UTF-8', ...), matching the module's own span-text contract.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

# RETARGETED to the LIVE panel builder. Dashboard::_fixed_panels was deleted --
# unreachable since compose_frame began delegating to tui::DashboardScreen, and
# drifted to a panel set (Token/Spend) that no longer renders. The assertions
# below are about Run-panel CONTENT, which the live builder still produces, so
# they are re-pointed rather than dropped.
#
# A shim rather than an inline rewrite at each call site: panels() returns an
# ARRAYREF where _fixed_panels returned a LIST, and $cols was optional there
# (defaulting to 80). One place to state both facts beats twenty.
sub live_panels {
    my ($state, $cols) = @_;
    return @{ tui::DashboardScreen::panels($state, defined $cols ? $cols : 80) };
}

# THE PANEL TITLE LEAD-IN, DERIVED. It was the ASCII '-- '; it is now one
# Theme rule.h glyph plus a space, so a title line is continuous with its own
# filler and can serve as the panel's top border (operator request,
# 2026-08-25). Taken from Theme rather than written out, so it cannot drift
# from the declaration the renderer actually uses.
require Theme;
my $RULE_LEAD    = Theme::glyph('rule.h');      # UTF-8 BYTES, matches row text
my $RULE_LEAD_RE = quotemeta($RULE_LEAD);
use Test::More;
use Encode qw(encode);
use Time::Local qw(timegm);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# Glyph literals (spec S2.1/S2.3/S2.6) -- CORRECTED for blueprint
# unified-tui-design-system package 06-dashboard-screen (in-scope oracle
# correction #3; driver escalation E-B, packages/06-dashboard-screen.md
# 2026-08-07T20:40:59Z, measured at 4 refs here -- the spec's original "36"
# count was wrong). Package 06 removes Dashboard.pm's four hardcoded
# emoji-circle constants ($GLYPH_GREEN/$GLYPH_RED/$GLYPH_YELLOW/$GLYPH_WHITE,
# Dashboard.pm:562-565) entirely (Decision 11, "no emoji anywhere") and
# replaces them with Theme's four non-emoji status glyphs, resolved lazily
# inside sub bodies (spec §2.2). The CLAIM this file pins is UNCHANGED --
# "container_status_style / event_style return glyph G for status/event
# class X"; the SUBJECT of what G actually IS moves from a hardcoded emoji
# literal to a live derivation from Theme::glyph('status.*'), per AC-G6's
# re-derivation rule ("re-derives its subject by selecting from Theme ...
# and fails loudly if none exists, so it can never silently degrade into a
# width-1 test" -- here: a stale-emoji test). BAIL_OUT rather than a silent
# undef if Theme.pm or any of the four status glyphs is missing, since
# every assertion below this point depends on these four values meaning
# something real.
# ===========================================================================
my $THEME_OK = eval { require Theme; 1 };
BAIL_OUT("Theme.pm did not load ($@) -- this oracle's glyph expectations are derived from Theme (AC-G6's re-derivation rule); nothing below can mean anything without it")
    unless $THEME_OK;

my $GLYPH_GREEN  = Theme::glyph('status.ok');
my $GLYPH_RED    = Theme::glyph('status.crit');
my $GLYPH_YELLOW = Theme::glyph('status.warn');
my $GLYPH_WHITE  = Theme::glyph('status.idle');
for my $pair ( [ 'status.ok', $GLYPH_GREEN ], [ 'status.crit', $GLYPH_RED ],
               [ 'status.warn', $GLYPH_YELLOW ], [ 'status.idle', $GLYPH_WHITE ] ) {
    my ($name, $val) = @$pair;
    ok(defined($val) && length($val) > 0,
        "AC-G6 re-derivation: Theme::glyph('$name') is defined and non-empty -- the corrected glyph subject exists (fails loudly rather than silently degrading to an untested undef)");
}

my $TRI_UP       = encode('UTF-8', "\x{25B2}");
my $TRI_DOWN     = encode('UTF-8', "\x{25BC}");

# ===========================================================================
# tui::DashboardScreen is a READ-ONLY dependency here (blueprint
# unified-tui-design-system package 06-dashboard-screen, driver adjudication
# packages/06-dashboard-screen.md 2026-08-08T00:37:32Z, RULINGs 2/3). Its
# public surface (spec 06-dashboard-screen-spec.md S2.4) is the authoritative
# source for two things this file needs but must never hand-type:
#   - LABEL_GUTTER() == 11, the one label gutter every panel now shares
#     (S2.4.1) -- replaces the panels' previous ad-hoc per-label literals.
#   - theme_role($legacy) -> <Theme role name> (S2.1's seventeen-to-nine
#     mapping), needed wherever a span this file inspects is produced by a
#     tui::DashboardScreen function (which emits Theme role names only,
#     S2.1) rather than by a Dashboard.pm legacy-role function.
# BAIL_OUT rather than a silent undef, same rationale as the Theme guard
# above: every re-pointed assertion below depends on these meaning something
# real.
# ===========================================================================
my $DASHBOARD_SCREEN_OK = eval { require tui::DashboardScreen; 1 };
BAIL_OUT("tui::DashboardScreen.pm did not load ($@) -- LABEL_GUTTER()/theme_role() are this oracle's derivation source for the re-pointed Sandbox/Run/header assertions; nothing below can mean anything without it")
    unless $DASHBOARD_SCREEN_OK;

my $LABEL_GUTTER = tui::DashboardScreen::LABEL_GUTTER();
ok(defined($LABEL_GUTTER) && $LABEL_GUTTER =~ /^\d+$/ && $LABEL_GUTTER > 0,
    'AC-G6-style re-derivation: tui::DashboardScreen::LABEL_GUTTER() is a positive integer -- the corrected gutter subject exists');

# _live_gutter_label($label) -> the ONE shared label-gutter rendering of $label
# (spec S2.4.1: sprintf('%-*s : ', LABEL_GUTTER(), safe(label))), so every
# expected label string below is DERIVED from the spec's own constant,
# never hand-padded.
# NOT AMENDED BY t05-no-colons, DELIBERATELY -- and this is the interesting
# case in that package rather than an oversight.
#
# Every caller of this helper in this file asserts against
# Dashboard::build_panels, and Dashboard.pm's own comments (see :934-938 and
# the _run_lines header) record that build_panels/_fixed_panels are
# UNREACHABLE from compose_frame: historical, off the render path, with zero
# other callers, and explicitly "must not be updated to track" the live panel
# set. So the colons that path emits are never rendered to an operator, and
# t05's rule -- no RENDERED colon -- does not reach them.
#
# The first t05 draft pointed this helper at tui::DashboardScreen::gutter,
# which is the live path's formatter. That turned 16 assertions red for a good
# reason: they were correctly describing the legacy path, and the helper had
# started describing a different one. Two paths that are documented as separate
# must not be pinned to one expectation.
sub _gutter_label { return sprintf('%-*s : ', $LABEL_GUTTER, $_[0]); }

# _live_gutter_label -- the LIVE path's label, for the few assertions in this
# file that go through tui::DashboardScreen rather than build_panels. Derived
# from the production helper so it cannot drift.
sub _live_gutter_label { return tui::DashboardScreen::gutter($_[0]); }

# ===========================================================================
# 4.1 container_status_style (spec S2.1): AC3, AC4
# ===========================================================================
{
    my @cases = (
        ['running',    $GLYPH_GREEN,  'good'],
        ['exited',     $GLYPH_RED,    'bad'],
        ['dead',       $GLYPH_RED,    'bad'],
        ['removing',   $GLYPH_RED,    'bad'],
        ['unknown',    $GLYPH_RED,    'bad'],
        ['created',    $GLYPH_YELLOW, 'warn'],
        ['restarting', $GLYPH_YELLOW, 'warn'],
        ['stopping',   $GLYPH_YELLOW, 'warn'],
        ['stopped',    $GLYPH_YELLOW, 'warn'],
        ['paused',     $GLYPH_YELLOW, 'warn'],
        ['',           $GLYPH_WHITE,  'muted'],
        [undef,        $GLYPH_WHITE,  'muted'],
        ['weird',      $GLYPH_WHITE,  'muted'],
    );
    for my $case (@cases) {
        my ($status, $eglyph, $erole) = @$case;
        my $label = defined $status ? "'$status'" : 'undef';
        my ($glyph, $role) = Dashboard::container_status_style($status, 0);
        is($glyph, $eglyph, "AC3: container_status_style($label, 0) glyph");
        is($role,  $erole,  "AC3: container_status_style($label, 0) role");
    }

    # whitespace-stripped, case-sensitive comparison (spec S2.1).
    my ($glyph_ws, $role_ws) = Dashboard::container_status_style('  running  ', 0);
    is($glyph_ws, $GLYPH_GREEN, "AC3: container_status_style strips leading/trailing whitespace ('  running  ')");
    is($role_ws,  'good',       'AC3: container_status_style strips leading/trailing whitespace role');

    my ($glyph_case, $role_case) = Dashboard::container_status_style('Running', 0);
    is($role_case, 'muted', "AC3: container_status_style('Running') is case-sensitive -> unmatched -> muted");
}
{
    # AC4: container_gone overrides everything, including 'running'.
    my ($glyph, $role) = Dashboard::container_status_style('running', 1);
    is($glyph, $GLYPH_RED, 'AC4: container_status_style("running", container_gone=1) glyph is red (override)');
    is($role,  'bad',      'AC4: container_status_style("running", container_gone=1) role is bad (override)');

    for my $status ((qw(exited dead removing unknown created restarting stopping stopped paused), '', undef)) {
        my ($g, $r) = Dashboard::container_status_style($status, 1);
        my $label = defined $status ? "'$status'" : 'undef';
        is($g, $GLYPH_RED, "AC4: container_status_style($label, container_gone=1) glyph is red for any status");
        is($r, 'bad', "AC4: container_status_style($label, container_gone=1) role is bad for any status");
    }
}

# ===========================================================================
# 4.2 oauth_role (spec S2.2): AC6
# ===========================================================================
{
    my @cases = (
        [undef, 'bad'],
        [-1,    'bad'],
        [0,     'bad'],
        [1,     'warn'],
        [900,   'warn'],
        [901,   'good'],
        [28800, 'good'],
    );
    for my $case (@cases) {
        my ($remaining, $erole) = @$case;
        my $label = defined $remaining ? $remaining : 'undef';
        is(Dashboard::oauth_role($remaining), $erole, "AC6: oauth_role($label) == $erole");
    }

    # A non-numeric $remaining degrades to the undef/absent branch (INV-8 totality).
    is(Dashboard::oauth_role('not-a-number'), 'bad', 'AC6: oauth_role(non-numeric) treated as undef -> bad');
}

# ===========================================================================
# 4.3 Sandbox (DELETED) + Run panel spans + header (spec S3 behaviors 1-8):
# AC1, AC2, AC5, AC7, AC8
#
# CORRECTED for blueprint unified-tui-design-system package
# 06-dashboard-screen (in-scope oracle correction; driver adjudication
# packages/06-dashboard-screen.md 2026-08-08T00:37:32Z, RULINGS 2 and 3).
# Spec 06-dashboard-screen-spec.md S2.4.3: "The Sandbox panel is deleted."
# Its five rows are disposed of thus: project/container -> already in the
# header (S2.4.9: today's header content, unchanged); oauth -> the Token
# panel's `access` row when $state->{tokens} is a HASH, else the Run panel
# (S2.4.3's last conditional -- never both, never neither); heartbeat/
# uptime -> MOVE to Run, ahead of busy-lease/keep-awake/escalations (S2.4.3's
# stated Run body order). Per the standing rule ("an assertion may change
# its subject; it may never lose its claim"), every assertion below keeps
# ITS ORIGINAL CLAIM; only the panel/row/index it inspects moves. AC8
# (Run's busy-lease/keep-awake/escalations role table, immediately below AC7
# in this same block) is re-indexed for the same reason: heartbeat/uptime
# now sit ahead of it in Run, so leaving AC8's old indices [0,1,2] in place
# would silently assert the WRONG rows once the panel dissolves -- an
# adjacent defect this file must not ship even though AC8 itself was not
# separately named for re-pointing.
#
# The label gutter also unifies (S2.4.1, LABEL_GUTTER()==11): every panel's
# previous ad-hoc per-label literal ('project   : ', 'busy-lease : ', ...)
# disappears in favour of one sprintf('%-11s : ', label) gutter. Every
# label expectation below is therefore built via _live_gutter_label() (derived
# from tui::DashboardScreen::LABEL_GUTTER(), never hand-padded).
#
# TWO CLAIMS ARE INVERTED, NOT DROPPED (driver ruling, second round,
# 2026-08-08): the original absent-branch claims "project absent -> a
# visible '?' placeholder, role muted" and "container absent -> a visible
# '?' placeholder, role muted" (old lines 271-279) have no PLACEHOLDER
# analog -- the header's own absence handling (S2.4.9: "today's
# _title_line unchanged in content") OMITS the clause entirely (" -
# <project>" / "<container> " simply do not appear) rather than showing a
# "?". But what those two assertions actually bought was never the glyph
# "?" itself -- it was that THE ABSENT-PROJECT AND ABSENT-CONTAINER
# BRANCHES ARE EXERCISED, and the frame degrades in a defined,
# non-corrupting way. That purpose survives the design change intact, so
# the OLD SUBJECT (the deleted Sandbox panel's project/container rows,
# each rendering a "?" placeholder) becomes the NEW SUBJECT (the header,
# which renders a clean omission): the expected outcome inverts from
# "a '?' appears" to "the clause omits cleanly -- no dangling separator, no
# stray artifact, no literal undef, the frame still composes". Dropping
# these entirely would mean nobody exercises the absent-project path at
# all, which is exactly how a bare dangling " - ", a stray double space, or
# an interpolated "undef" ships unnoticed. Each inverted assertion below
# carries its own counter-fixture (the PRESENT case) so "the clause is
# absent" cannot pass vacuously against a header that never renders the
# clause under any input. The heartbeat/uptime absent-branch claims (still
# row-level facts inside Run) also survive and are re-pointed below.
# ===========================================================================
{
    my %full = (
        project_name    => 'demo',
        container       => 'claude-demo-abcd1234',
        status          => 'running',
        beat_age        => 12,
        uptime          => 3660,
        oauth_remaining => 3 * 3600 + 12 * 60,   # 11520s -> 'good' tier
        busy_age        => 30,
        stay_awake      => 1,
        needs_you       => 2,
    );
    my @panels = live_panels(\%full, 80);
    my ($sandbox) = grep { $_->{title} eq 'Sandbox' } @panels;
    my ($run)     = grep { $_->{title} eq 'Run' } @panels;

    # AC1: the Sandbox panel is gone; Run absorbs heartbeat/uptime.
    ok(!$sandbox, 'AC1: the Sandbox panel no longer exists (spec S2.4.3: "the Sandbox panel is deleted")');
    ok($run,      'AC1: a Run panel is present');

    # AC1: Run's rows, in spec S2.4.3 order, for a fixture with no backpack
    # key and no tokens key (so `row()`'s absence rules drop backpack and
    # the run-summary rows, and oauth lands in RUN, not Token -- exercised
    # separately by AC7 below). Deliberately NOT a row-count assertion
    # (Decision 15): each row is checked by name/content at its position,
    # never by counting scalar(@{ $run->{lines} }).
    my @rlabels = ('heartbeat', 'uptime', 'busy-lease', 'keep-awake', 'needs you');
    for my $i (0 .. $#rlabels) {
        my $line = $run->{lines}[$i];
        is(ref($line), 'ARRAY', "AC1: Run line $i ('$rlabels[$i]') is an ARRAY ref of spans");
        is($line->[0]{text}, _live_gutter_label($rlabels[$i]),
            "AC1: Run line $i first span text is '$rlabels[$i]' padded to the one shared LABEL_GUTTER");
        is($line->[0]{role}, tui::DashboardScreen::theme_role('label'), "AC1: Run line $i first span role is 'label'");
    }

    # AC2: value span roles/text for the two MIGRATED rows (heartbeat,
    # uptime), now at Run's positions 0/1. Uptime's text is fmt_age, never
    # fmt_hms (AC-F5/S2.4.7: fmt_hms is off every render path; this is the
    # exact assertion AC-F5 and this AC used to disagree about -- AC-F5
    # wins, and re-deriving via Dashboard::fmt_age is how AC2 keeps its
    # claim without re-pinning a literal).
    is($run->{lines}[0][1]{role}, tui::DashboardScreen::theme_role('value'), 'AC2: heartbeat value role is value when beat_age defined (now in Run)');
    is($run->{lines}[0][1]{text}, Dashboard::fmt_age(12) . ' ago',
        'AC2: heartbeat text is fmt_age(...) . " ago" (now in Run)');
    is($run->{lines}[1][1]{role}, tui::DashboardScreen::theme_role('value'), 'AC2: uptime value role is value when uptime defined (now in Run)');
    is($run->{lines}[1][1]{text}, Dashboard::fmt_age(3660),
        'AC2: uptime text is fmt_age(...), NOT fmt_hms (AC-F5, now in Run)');

    # AC5 (+ AC2's project claim, folded in here for the same reason): the
    # project fact and the container fact -- the latter WITH its status
    # style -- reach the frame via the header (S2.4.9), not a panel body.
    # tui::DashboardScreen::header_spans emits Theme role names only
    # (S2.1), confirmed empirically (no legacy 'title'/'good'): the status
    # span's expected role is therefore container_status_style's legacy
    # role MAPPED through theme_role(), not the legacy role bare. The
    # header's spec'd content ("<container> [<status>]") carries no glyph
    # character -- verified against the already-landed header_spans, which
    # emits only a role-styled status word, matching S2.4.9's "unchanged
    # content" note. AC5's claim is therefore preserved as "the container
    # fact, WITH ITS STYLE (theme_role(container_status_style(...))),
    # reaches the frame" rather than as an invented glyph literal.
    my ($cglyph, $crole) = Dashboard::container_status_style('running', undef);
    my $expected_status_role = tui::DashboardScreen::theme_role($crole);
    my $header = tui::DashboardScreen::header_spans(\%full, 80);
    my $header_text = Dashboard::spans_text($header);

    my $n_project = () = $header_text =~ /\Qdemo\E/g;
    ok($n_project > 0, 'AC2: the project name reaches the header (present)');

    my $n_container = () = $header_text =~ /\Qclaude-demo-abcd1234\E/g;
    ok($n_container > 0, 'AC5: the container fact reaches the header (present)');
    is($n_container, 1,  'AC5: the container fact reaches the header exactly once');

    my ($status_span) = grep { $_->{text} eq 'running' } @$header;
    ok($status_span, 'AC5: a header span carries the status text "running"');
    is($status_span->{role}, $expected_status_role,
        'AC5: that span carries container_status_style\'s role, mapped through Theme (theme_role)')
        if $status_span;

    # AC2/AC5, INVERTED absent branches (driver ruling, second round): the
    # branch is exercised and asserted to degrade cleanly, rather than
    # asserting the now-nonexistent "?" placeholder. Each has a
    # counter-fixture proving the omission isn't vacuously true.
    {
        my %no_project = %full;
        delete $no_project{project_name};
        my $h_no_project = tui::DashboardScreen::header_spans(\%no_project, 80);
        my $t_no_project = Dashboard::spans_text($h_no_project);

        ok(scalar(@$h_no_project) > 0,
            'AC2 (project absent, inverted): header_spans still returns a non-empty span list');
        is(Dashboard::display_width($t_no_project), 80,
            'AC2 (project absent, inverted): the header still composes to exactly $cols -- well-formed, not corrupted');
        unlike($t_no_project, qr/ - /,
            'AC2 (project absent, inverted): no dangling " - " separator when project_name is absent');
        unlike($t_no_project, qr/undef/i,
            'AC2 (project absent, inverted): no literal "undef" leaks into the header when project_name is absent');

        # counter-fixture: with project_name PRESENT (the %full fixture
        # already in scope), the " - <project>" clause DOES appear -- so
        # the "no dangling separator" check above is not testing a
        # separator that never renders under any input.
        like($header_text, qr/ - demo\b/,
            'AC2 (project present, counter-fixture): the " - <project>" clause DOES appear when project_name is present');
    }
    {
        my %no_container = %full;
        delete $no_container{container};
        my $h_no_container = tui::DashboardScreen::header_spans(\%no_container, 80);
        my $t_no_container = Dashboard::spans_text($h_no_container);

        ok(scalar(@$h_no_container) > 0,
            'AC5 (container absent, inverted): header_spans still returns a non-empty span list');
        is(Dashboard::display_width($t_no_container), 80,
            'AC5 (container absent, inverted): the header still composes to exactly $cols -- well-formed, not corrupted');
        unlike($t_no_container, qr/undef/i,
            'AC5 (container absent, inverted): no literal "undef" leaks into the header when container is absent');
        unlike($t_no_container, qr/\[\[|\]\]/,
            'AC5 (container absent, inverted): no doubled bracket where the container-name prefix would have gone');
        # The status block LEADS the header (operator request, 2026-08-25); it
        # used to trail it, with the container name immediately before it. What
        # AC5 is really asserting is unchanged -- an absent container must not
        # leave a hole, a stray bracket or a literal "undef" -- so the anchor
        # moves from end-of-row to start-of-row and the container's own
        # counter-fixture moves to the right-hand slot it now occupies.
        like($t_no_container, qr/\A\[running\] /,
            'AC5 (container absent, inverted): the status clause still renders cleanly at the head of the row');

        # counter-fixture: with container PRESENT (the %full fixture
        # already in scope), the container name DOES appear -- so the checks
        # above are not testing an element that never renders under any input.
        like($header_text, qr/\Qclaude-demo-abcd1234\E\s*\z/,
            'AC5 (container present, counter-fixture): the container name DOES appear, right-justified, when present');
    }
    # AC7 REMOVED 2026-08-25 (operator: "I don't want to keep obsolete stuff
    # around"). It asserted that the oauth fact lands in a TOKEN PANEL when
    # $state->{tokens} is a hashref, and in Run otherwise -- "never both, never
    # neither". There is no Token panel any more: it was replaced by Providers,
    # where the same fact renders as Claude Code's `access` row, and t/79 is the
    # oracle for that. The assertions were not re-pointed because the behaviour
    # they pin is the behaviour that was deliberately replaced, not a live
    # behaviour reached through a dead accessor (that is AC1/AC2/AC8 above,
    # which WERE re-pointed).


    # AC8: Run panel role table across the busy-lease/keep-awake/escalations
    # tiers. RE-INDEXED from [0,1,2] to [2,3,4] and re-labeled via
    # _live_gutter_label(): heartbeat/uptime (always present for this %full-
    # derived fixture) now occupy Run's first two positions (see AC1
    # above), so busy-lease/keep-awake/escalations shift down by two. Same
    # claim (the role table itself), same fixture cases, only the
    # subject's location changes.
    my @run_cases = (
        # [ busy_age, stay_awake, needs_you, busy_text, busy_role, keep_text, keep_role, needs_text, needs_role ]
        [undef, 0, 0, 'none (no active run)', 'muted',
            'released (PC may sleep)', 'muted', 'none', 'muted'],
        [30, 1, 2, 'active (' . Dashboard::fmt_age(30) . ' ago)', 'good',
            'holding (PC stays awake)', 'good', '2 decisions waiting', 'warn'],
        [9999, 0, 0, 'idle (' . Dashboard::fmt_age(9999) . ' ago)', 'warn',
            'released (PC may sleep)', 'muted', 'none', 'muted'],
    );
    for my $c (@run_cases) {
        my ($busy_age, $stay_awake, $needs_you, $bt, $br, $kt, $kr, $nt, $nr) = @$c;
        my %s3 = (%full, busy_age => $busy_age, stay_awake => $stay_awake, needs_you => $needs_you);
        my @p3 = live_panels(\%s3, 80);
        my ($rn) = grep { $_->{title} eq 'Run' } @p3;
        my $tag = 'busy_age=' . (defined $busy_age ? $busy_age : 'undef') . " stay_awake=$stay_awake needs_you=$needs_you";
        # FOUND BY LABEL, NOT BY INDEX. These used to pin Run indices 2/3/4.
        # The live builder applies row-absence rules the legacy one did not --
        # with needs_you == 0 the escalations row is omitted entirely and
        # `oauth` moves into index 4 -- so an index-pinned assertion fails
        # while reporting a text mismatch, which describes the symptom and
        # hides the cause. What AC8 is actually about is the role TABLE: given
        # this state, this row carries this text and this role. Locating the
        # row by its label says exactly that and survives every reflow.
        my $row_by = sub {
            my ($label) = @_;
            my $want = _live_gutter_label($label);
            for my $ln (@{ $rn->{lines} || [] }) {
                next unless ref($ln) eq 'ARRAY' && ref($ln->[0]) eq 'HASH';
                return $ln if defined($ln->[0]{text}) && $ln->[0]{text} eq $want;
            }
            return undef;
        };
        for my $case ([ 'busy-lease', $bt, $br ], [ 'keep-awake', $kt, $kr ]) {
            my ($label, $text, $role) = @$case;
            is_deeply($row_by->($label),
                [ { text => _live_gutter_label($label), role => tui::DashboardScreen::theme_role('label') },
                  { text => $text, role => tui::DashboardScreen::theme_role($role) } ],
                "AC8: $label row ($tag)");
        }
        # The escalations row is CONDITIONAL: present only when there is
        # something waiting. Asserted as such rather than unconditionally,
        # because "absent when there is nothing to say" is itself the
        # behaviour -- and an assertion that demanded it always be there would
        # be asserting the legacy builder's rule, not the live one's.
        my $needs_row = $row_by->('needs you');
        if ($needs_you) {
            is_deeply($needs_row,
                [ { text => _live_gutter_label('needs you'), role => tui::DashboardScreen::theme_role('label') },
                  { text => $nt, role => tui::DashboardScreen::theme_role($nr) } ],
                "AC8: escalations row present and correct when needs_you=$needs_you ($tag)");
        } else {
            ok(!defined $needs_row,
                "AC8: escalations row is ABSENT when there is nothing waiting ($tag)");
        }
    }

    # AC2 (absent branches): heartbeat/uptime fall back to 'n/a' with role
    # muted when their state fields are absent -- re-pointed to Run's
    # positions 0/1 (project/container's absent-branch claims are the two
    # INVERTED claims tested above, alongside AC5).
    my %sparse = (status => 'running');
    my @ps = live_panels(\%sparse, 80);
    my ($run_sparse) = grep { $_->{title} eq 'Run' } @ps;
    ok($run_sparse, 'AC2 (absent branches): a Run panel is present for the sparse fixture');
    # AC2's ABSENT-BRANCH assertions removed 2026-08-25.
    #
    # They pinned "heartbeat/uptime with no state fall back to the text 'n/a'
    # with a muted role". The live builder does not do that and is not meant
    # to: it OMITS a row whose value is absent, so a sparse fixture's Run panel
    # is busy-lease / keep-awake / oauth and no heartbeat row exists at all
    # (verified against tui::DashboardScreen::panels, not assumed).
    #
    # That is a deliberate design change -- row-absence rules replaced
    # placeholder text -- so these are in the "asserts behaviour that no longer
    # exists" category and were deleted rather than re-pointed, unlike AC1/AC2
    # (present branches) and AC8 above, which assert live behaviour through
    # what was merely a dead accessor.

    # The live builder takes $cols as its second argument; live_panels defaults
    # it to 80 exactly as _fixed_panels used to, so old-shaped call sites keep
    # working (spec S2.8 / S5.6, re-pointed).
    my @pd = eval { live_panels(\%full) };
    is($@, '', 'S2.8/S5.6: the panel builder with no $cols does not die (defaults to 80)');
    ok(scalar(@pd), 'S2.8/S5.6: the panel builder with no $cols still returns panels');
}

# ===========================================================================
# 4.4 wrap_spans (spec S2.4): AC9, AC10
# ===========================================================================
{
    # AC9: greedy fill at a known width produces the expected line grouping.
    # widths: aa=2 bb=2 cc=2 dddd=4; w=6.
    #   aa(2) -> line="aa"(2)
    #   bb(2): 2+1+2=5<=6 -> join -> line="aa bb"(5)
    #   cc(2): 5+1+2=8>6  -> flush; new line="cc"(2)
    #   dddd(4): 2+1+4=7>6 -> flush; new line="dddd"(4)
    my @words = (
        { text => 'aa',   role => tui::DashboardScreen::theme_role('good') },
        { text => 'bb',   role => tui::DashboardScreen::theme_role('warn') },
        { text => 'cc',   role => tui::DashboardScreen::theme_role('good') },
        { text => 'dddd', role => tui::DashboardScreen::theme_role('warn') },
    );
    my $lines = Dashboard::wrap_spans(\@words, 6);
    is(ref($lines), 'ARRAY', 'AC9: wrap_spans returns an arrayref');
    is(scalar(@$lines), 3, 'AC9: wrap_spans(w=6) groups the 4 words into exactly 3 lines');
    is_deeply($lines->[0],
        [ { text => 'aa', role => tui::DashboardScreen::theme_role('good') }, { text => ' ', role => 'body' }, { text => 'bb', role => tui::DashboardScreen::theme_role('warn') } ],
        'AC9: line 1 is "aa bb" with a body-role separator, original word roles preserved');
    is_deeply($lines->[1], [ { text => 'cc', role => tui::DashboardScreen::theme_role('good') } ], 'AC9: line 2 is "cc" alone (didn\'t fit after bb)');
    is_deeply($lines->[2], [ { text => 'dddd', role => tui::DashboardScreen::theme_role('warn') } ], 'AC9: line 3 is "dddd" alone (didn\'t fit after cc)');

    for my $i (0 .. 2) {
        ok(Dashboard::spans_width($lines->[$i]) <= 6, "AC9: line $i spans_width <= \$w (6)");
    }
    is(Dashboard::spans_width($lines->[0]), 5, 'AC9: lines are NOT padded to $w (line 1 width is 5, not 6)');
    is(Dashboard::spans_width($lines->[1]), 2, 'AC9: lines are NOT padded to $w (line 2 width is 2, not 6)');

    # No leading/trailing separator on any line: first/last elements are words.
    for my $i (0 .. 2) {
        isnt($lines->[$i][0]{text}, ' ', "AC9: line $i has no leading separator");
        isnt($lines->[$i][-1]{text}, ' ', "AC9: line $i has no trailing separator");
    }

    # Custom $sep_role.
    my $lines_lbl = Dashboard::wrap_spans(\@words, 6, 'label');
    is($lines_lbl->[0][1]{role}, 'label', 'AC9: $sep_role parameter controls the separator span role');
    is($lines_lbl->[0][1]{text}, ' ',     'AC9: separator text is always a single space');

    # Boundary: current_width + 1 + word_width <= $w decides the join, exactly.
    my @boundary_words = ({ text => 'ab', role => 'body' }, { text => 'cd', role => 'body' });
    my $exact_fit = Dashboard::wrap_spans(\@boundary_words, 5);   # 2+1+2 == 5 -> joins
    is(scalar(@$exact_fit), 1, 'AC9: boundary -- current_width+1+word_width == $w -> joins onto one line');
    my @boundary_words2 = ({ text => 'ab', role => 'body' }, { text => 'cde', role => 'body' });
    my $one_over = Dashboard::wrap_spans(\@boundary_words2, 5);  # 2+1+3 == 6 > 5 -> splits
    is(scalar(@$one_over), 2, 'AC9: boundary -- current_width+1+word_width > $w by one -> splits');
}
{
    # AC10: degenerate/total inputs never die and degrade to [].
    my @words = ({ text => 'a', role => 'body' });
    is_deeply(Dashboard::wrap_spans(\@words, undef), [], 'AC10: $w undef -> []');
    is_deeply(Dashboard::wrap_spans(\@words, 0),     [], 'AC10: $w == 0 -> []');
    is_deeply(Dashboard::wrap_spans(\@words, -5),    [], 'AC10: $w < 0 -> []');
    is_deeply(Dashboard::wrap_spans([], 10),         [], 'AC10: empty word list -> []');
    is_deeply(Dashboard::wrap_spans(undef, 10),      [], 'AC10: undef word list -> []');
    is_deeply(Dashboard::wrap_spans('not-an-arrayref', 10), [], 'AC10: non-arrayref word list -> []');

    # A single word wider than $w occupies its own line, left intact (never
    # dropped, never half-cut -- fit_spans handles the render-time clip).
    my $long = Dashboard::wrap_spans([ { text => 'averylongword', role => tui::DashboardScreen::theme_role('good') } ], 4);
    is(scalar(@$long), 1, 'AC10: a single over-wide word still produces exactly one line');
    is_deeply($long->[0], [ { text => 'averylongword', role => tui::DashboardScreen::theme_role('good') } ],
        'AC10: the over-wide word is left intact, not truncated by wrap_spans itself');

    # Totality: a malformed element (undef / arrayref / blessed ref) contributes
    # an empty word rather than dying or warning (spec S2.4, S5.3).
    my @malformed = (undef, [1, 2, 3], bless({}, 'Dashboard::Test::Bogus'), 'ok');
    my ($died, $warns, $result) = (0, 0, undef);
    local $SIG{__WARN__} = sub { $warns++ };
    eval { $result = Dashboard::wrap_spans(\@malformed, 20) };
    $died = 1 if $@;
    is($died,  0, 'AC10: wrap_spans never dies on malformed elements (undef/arrayref/blessed ref)');
    is($warns, 0, 'AC10: wrap_spans never warns on malformed elements');
    is(ref($result), 'ARRAY', 'AC10: wrap_spans still returns an arrayref on malformed input');
}

# ===========================================================================
# 4.5 Backpack paragraph (spec S3 behaviors 9-13, S2.8): AC11..AC16
# ===========================================================================
{
    # AC11/AC12: items that fit -> header + exactly 1 paragraph row; no
    # markers/bullets/per-item rows; word roles follow approval state.
    my $bp = { total => 3, approved => 2, items => [
        { key => 'apt:jq',              approved => 1 },
        { key => 'apt:chromium',        approved => 0 },
        { key => 'npm-global:prettier', approved => 1 },
    ] };
    my @lines = Dashboard::_backpack_lines($bp, 78);   # cols=80 -> w=78
    is(scalar(@lines), 2, 'AC11: total>0 + items that fit -> exactly 2 lines (header + 1 paragraph row)');
    is(Dashboard::spans_text($lines[0]), '3 item(s) - 2 approved, 1 pending',
        'AC10/S3.10: header line text is "<total> item(s) - <appr> approved, <pend> pending"');
    is(Dashboard::spans_text($lines[1]), 'apt:jq apt:chromium npm-global:prettier',
        'AC11: paragraph row spans_text is the item keys space-separated, in order');
    unlike(Dashboard::spans_text($lines[1]), qr/[\[\]]/, 'AC11: no [+]/[-] bracket markers in the paragraph row');

    my @word_spans = grep { $_->{text} !~ /^\s*$/ } @{ $lines[1] };
    my %role_by_key = map { $_->{text} => $_->{role} } @word_spans;
    is($role_by_key{'apt:jq'},              'good', 'AC12: approved item word role is good');
    is($role_by_key{'apt:chromium'},        'warn', 'AC12: pending item word role is warn');
    is($role_by_key{'npm-global:prettier'}, 'good', 'AC12: second approved item word role is good');

    # Header with pend==0: no ", N pending" suffix.
    my $bp_allgood = { total => 2, approved => 2, items => [
        { key => 'apt:a', approved => 1 }, { key => 'apt:b', approved => 1 },
    ] };
    my @lines_ag = Dashboard::_backpack_lines($bp_allgood, 78);
    is(Dashboard::spans_text($lines_ag[0]), '2 item(s) - 2 approved',
        'S3.10: header with pend==0 omits the ", N pending" clause');
}
{
    # AC13: many items -> body never exceeds header + 2 paragraph rows; the
    # last word is "+<N> more" (muted), N == total - keys actually shown.
    my @many_items = map { { key => sprintf('apt:pkg%02d', $_), approved => ($_ % 2 == 0) ? 1 : 0 } } (1 .. 30);
    my $bp_many = { total => 30, approved => 15, items => \@many_items };
    my @lines = Dashboard::_backpack_lines($bp_many, 78);
    ok(scalar(@lines) >= 2 && scalar(@lines) <= 3,
        'AC13: backpack body is header + at most 2 paragraph rows, even with many items');
    my @paragraph_rows = @lines[1 .. $#lines];
    ok(scalar(@paragraph_rows) <= 2, 'AC13: at most BACKPACK_MAX_ROWS=2 paragraph rows');
    for my $i (0 .. $#paragraph_rows) {
        ok(Dashboard::spans_width($paragraph_rows[$i]) <= 78, "AC13: paragraph row $i fits within \$w (78)");
    }

    my $all_text = join(' ', map { Dashboard::spans_text($_) } @paragraph_rows);
    like($all_text, qr/\+\d+ more$/, 'AC13: with more items than fit, the last word is "+<N> more"');
    my ($n_more) = $all_text =~ /\+(\d+) more$/;
    my $last_row = $paragraph_rows[-1];
    my ($more_span) = grep { $_->{text} =~ /^\+\d+ more$/ } @$last_row;
    ok($more_span, 'AC13: the "+N more" text is its own span/word');
    is($more_span->{role}, 'muted', 'AC13: "+N more" word role is muted');

    my %shown_keys;
    for my $row (@paragraph_rows) {
        for my $sp (@$row) {
            $shown_keys{$sp->{text}} = 1 if $sp->{text} =~ /^apt:pkg\d+$/;
        }
    }
    my $k_shown = scalar(keys %shown_keys);
    is($n_more, 30 - $k_shown, 'AC13: N == <total items> - <keys actually shown>');
}
{
    # AC14: the paragraph wraps to the PASSED width -- same item list, two
    # widths, different row groupings; every row's width <= the passed width.
    # 5 keys of exactly 10 chars each: total width incl. 4 separators = 54.
    my @items5 = map { { key => $_ x 10, approved => 1 } } ('a', 'b', 'c', 'd', 'e');
    my $bp5 = { total => 5, approved => 5, items => \@items5 };

    my @lines_wide   = Dashboard::_backpack_lines($bp5, 118);   # cols=120 -> w=118: fits in 1 row (54<=118)
    my @lines_narrow = Dashboard::_backpack_lines($bp5, 38);    # cols=40  -> w=38: must wrap to 2 rows

    is(scalar(@lines_wide) - 1,   1, 'AC14: at $w=118 the 5x10-char item list wraps to exactly 1 paragraph row');
    is(scalar(@lines_narrow) - 1, 2, 'AC14: the SAME item list at $w=38 wraps to exactly 2 paragraph rows');

    for my $row (@lines_wide[1 .. $#lines_wide]) {
        ok(Dashboard::spans_width($row) <= 118, 'AC14: wide paragraph row width <= $w (118)');
    }
    for my $row (@lines_narrow[1 .. $#lines_narrow]) {
        ok(Dashboard::spans_width($row) <= 38, 'AC14: narrow paragraph row width <= $w (38)');
    }

    # End-to-end via build_panels($state,$cols). RE-POINTED (package
    # 06-dashboard-screen, spec S2.4.3/S2.4.8, Decision 9, driver report
    # item 1): the Backpack panel is deleted; the backpack fact now reaches
    # the frame as a single summary ROW inside Run
    # (tui::DashboardScreen::backpack_summary_spans), which does not wrap
    # with $cols at all -- so the "row count varies with $cols" half of
    # this AC has no surviving analog (a one-line summary never wraps).
    # That half is NOT re-pointed to a new count -- doing so would just
    # reintroduce the same whole-shape pin Decision 15 / t/00-oracle-
    # hygiene.t already forbids elsewhere in this package. What survives:
    # the backpack fact reaches the frame at EVERY width tested, and it is
    # a SUMMARY, not an item listing -- it never contains the fixture's
    # item keys, at any width.
    my %state5 = (status => 'running', backpack => $bp5);
    # THE LIVE label, not the legacy one, and the difference is real: the
    # backpack row is the one row _fixed_panels builds through
    # tui::DashboardScreen::row rather than through its own local formatter
    # (Dashboard.pm:1020), so it carries the live gutter while its siblings in
    # the same panel carry the legacy one. t05-no-colons made that visible by
    # changing only the live gutter.
    my $bp_label14 = _live_gutter_label('backpack');
    my $expected_value14 = tui::DashboardScreen::backpack_summary_spans($bp5);

    for my $cols (120, 40) {
        my @panels14 = live_panels(\%state5, $cols);
        my ($run14) = grep { $_->{title} eq 'Run' } @panels14;
        ok($run14, "AC14 (end-to-end): a Run panel is present at cols=$cols (subject moved off the deleted Backpack panel)");
        my ($bprow14) = $run14 ? (grep { $_->[0]{text} eq $bp_label14 } @{ $run14->{lines} }) : ();
        ok($bprow14, "AC14 (end-to-end): a backpack summary row exists in Run at cols=$cols");
        is_deeply([ @{ $bprow14 }[1 .. $#$bprow14] ], $expected_value14,
            "AC14 (end-to-end): the row's value spans equal backpack_summary_spans(\$bp5) exactly, unaffected by \$cols=$cols")
            if $bprow14;

        for my $item (@items5) {
            unlike(Dashboard::spans_text($bprow14), qr/\Q$item->{key}\E/,
                "AC14 (end-to-end): the backpack row at cols=$cols is a summary, not an item listing (item key '$item->{key}' absent)")
                if $bprow14;
        }
    }
}
{
    # AC15: total==0 (incl. items absent) -> exactly one line, verbatim text.
    my @lines0 = Dashboard::_backpack_lines({ total => 0 }, 78);
    is(scalar(@lines0), 1, 'AC15: total==0 -> exactly one line');
    is(Dashboard::spans_text($lines0[0]), '(no backpack for this project)',
        'AC15: total==0 line spans_text is "(no backpack for this project)"');

    my @lines_noitems = Dashboard::_backpack_lines({ total => 0, items => undef }, 78);
    is(scalar(@lines_noitems), 1, 'AC15: total==0 with items absent -> still exactly one line');
    is(Dashboard::spans_text($lines_noitems[0]), '(no backpack for this project)',
        'AC15: total==0 with items absent -> same message');
}
{
    # AC16: _fixed_region_height($state,$cols) must equal the number of body
    # rows compose_frame actually emits for the fixed region at that $cols,
    # for a backpack that wraps to 1 row wide (cols=120) and 2 rows narrow
    # (cols=40) -- same 5x10-char fixture as AC14.
    my @items5 = map { { key => $_ x 10, approved => 1 } } ('a', 'b', 'c', 'd', 'e');
    my $bp5 = { total => 5, approved => 5, items => \@items5 };
    my %state16 = (status => 'running', backpack => $bp5);

    # $rows is passed to BOTH sides deliberately. _fixed_region_height's third
    # argument is what lets it model the flex reserve and the cap/skip that
    # compose_frame actually applies; without it the predictor is being asked to
    # match a 30-row render using information it was never given, and the
    # comparison is not a predictor-vs-renderer check at all. Measured at
    # cols=40: 2-arg returns 25, 3-arg returns 24, the real render is 24 -- the
    # 3-arg form is exact, including the access row's 2-cell wrap. The 2-arg
    # path is test-only (production's sole caller always supplies $rows), so
    # asserting on it pinned the accuracy of a shape nothing ships.
    for my $cols (120, 40) {
        my $expected_h = Dashboard::_fixed_region_height(\%state16, $cols, 30);
        my $f = Dashboard::compose_frame(\%state16, 30, $cols);
        my $activity_title_idx;
        for my $i (1 .. $#$f) {
            if ($f->[$i]{text} =~ /$RULE_LEAD_RE Recent activity /) { $activity_title_idx = $i; last; }
        }
        ok(defined $activity_title_idx, "AC16: compose_frame(cols=$cols) has a Recent-activity title row");
        my $actual_fixed_rows = defined($activity_title_idx) ? $activity_title_idx - 1 : -1;
        is($expected_h, $actual_fixed_rows,
            "AC16: _fixed_region_height(state,$cols) agrees with compose_frame's actual fixed-region row count (cols=$cols)");
    }
}

# ===========================================================================
# 4.6 event_style (spec S2.3): AC17, AC18
# ===========================================================================
{
    my @cases = (
        # [ type, exit, state, expected_role, expected_glyph ]
        ['heartbeat',      undef, undef, 'muted',  $GLYPH_WHITE],
        ['tick',           undef, undef, 'muted',  $GLYPH_WHITE],
        ['install_failed', undef, undef, 'bad',    $GLYPH_RED],
        ['container_gone', undef, undef, 'bad',    $GLYPH_RED],
        ['launch_failure', undef, undef, 'bad',    $GLYPH_RED],
        ['error',          undef, undef, 'bad',    $GLYPH_RED],
        ['some_event',     1,     undef, 'bad',    $GLYPH_RED],
        ['some_event',     'sig', undef, 'bad',    $GLYPH_RED],
        ['some_event',     0,     undef, 'good',   $GLYPH_GREEN],
        ['some_event',     '00',  undef, 'good',   $GLYPH_GREEN],
        ['some_event',     undef, 'ok',  'good',   $GLYPH_GREEN],
        ['container_start',undef, undef, 'accent', $GLYPH_WHITE],
        ['launch_session', undef, undef, 'accent', $GLYPH_WHITE],
        ['create',         undef, undef, 'accent', $GLYPH_WHITE],
        ['launched',       undef, undef, 'accent', $GLYPH_WHITE],
        ['something_else', undef, undef, 'value',  $GLYPH_WHITE],
    );
    for my $c (@cases) {
        my ($type, $exit, $state, $erole, $eglyph) = @$c;
        my ($role, $glyph) = Dashboard::event_style($type, $exit, $state);
        my $label = "event_style('$type', " . (defined $exit ? "'$exit'" : 'undef') . ', '
            . (defined $state ? "'$state'" : 'undef') . ')';
        is($role,  $erole,  "AC17: $label role");
        is($glyph, $eglyph, "AC17: $label glyph");
    }
}
{
    # AC18: precedence -- rule 2 (heartbeat/tick) sits ABOVE the exit/state
    # rules; rule 1 (failed/failure/error/gone/dead) sits above everything.
    my ($role1) = Dashboard::event_style('heartbeat', undef, 'ok');
    is($role1, 'muted', "AC18: ('heartbeat', undef, 'ok') -> muted, not good (rule 2 above rule 5)");

    my ($role2) = Dashboard::event_style('install_failed', 0, undef);
    is($role2, 'bad', "AC18: ('install_failed', 0, undef) -> bad, not good (rule 1 above rule 4)");

    my ($role3) = Dashboard::event_style('container_start', 1, undef);
    is($role3, 'bad', "AC18: ('container_start', 1, undef) -> bad (rule 3 above rule 6)");
}

# ===========================================================================
# 4.7 recent_events spans (spec S3.14 / 06-dashboard-screen-spec.md S2.4.6): AC19
#
# CORRECTED for blueprint unified-tui-design-system package
# 06-dashboard-screen (in-scope oracle correction; driver adjudication
# packages/06-dashboard-screen.md 2026-08-08T00:37:32Z, RULING 3).
# recent_events gained an OPTIONAL 4th arg: Dashboard::recent_events
# ($lines, $n, $localtime_fn, $now). Per spec S2.4.6 step 4 the render
# stage now produces, in order: an optional TIME span -- emitted ONLY when
# $now is defined and numeric, text sprintf('%-6s  ', fmt_duration($now -
# $epoch)), role 'text.muted' (a THEME role name -- a deliberately new
# span, distinct from the glyph/body spans below) -- then the GLYPH span,
# then the BODY span (both STILL deriving their role from
# Dashboard::event_style(...) exactly as before: that half of the claim is
# UNCHANGED, per the driver's explicit instruction to keep deriving
# glyph/role from event_style "as it already does"), then a COUNT span
# when count>=2. $localtime_fn (3rd arg, \&CORE::gmtime here) is retained
# for call-site compatibility and is UNUSED by the new time field (AC-F5:
# fmt_hms/_event_time are off the render path; the one duration grammar is
# fmt_duration, reachable here via the retained Dashboard::fmt_age alias,
# S2.4.7).
#
# The original assertions here pinned an ABSOLUTE "HH:MM:SS" first span
# with legacy role 'muted', produced by calling recent_events with NO
# $now (3 args only). That subject no longer exists: with $now undef, NO
# time span renders at all (S2.4.6 "Degradation when $now is absent" /
# S5), so a bare 3-arg call's first span is now the GLYPH span, not a
# timestamp. The CLAIM ("the timestamp is muted even though the event
# itself is good/bad", "the row carries glyph + type + extra, with the
# classified glyph") is preserved; its SUBJECT moves from an absolute
# clock time to a $now-relative duration, observed by injecting $now as a
# 4th argument (determinism: the clock is ALWAYS an argument, never
# time() -- same principle t/25's A1-A3 assert for compose_frame).
#
# A NEW arm is added (not in the original 8 reds, but spec'd and untested
# here until now): the "honest absence" degradation -- with $now absent,
# NO time span is produced at all. This is the counter-fixture that proves
# the time-span detector above can also NOT fire; a detector that always
# fires is not a detector (binding rule: every detector needs a
# counter-fixture proving it can fire).
# ===========================================================================
{
    my @lines = (
        '{"ts":"2026-06-24T10:00:01Z","type":"launch_start","pid":1}',
        'not json at all',
        '{"ts":"2026-06-24T10:00:05Z","type":"container_start","exit":0}',
        '{"ts":"2026-06-24T10:00:09Z","type":"container_gone","state":"exited"}',
        '',
    );

    # Independently derive each event's epoch via plain UTC arithmetic
    # (Time::Local::timegm on the fixture's own "ts" strings) -- this is a
    # standard, unambiguous ISO-8601-Z -> epoch conversion, not a coupling
    # to Dashboard.pm's internals. $now is chosen 500s after the newest
    # event so every delta is positive and none is zero.
    my $epoch0 = timegm(1, 0, 10, 24, 5, 126);   # event 0: launch_start    2026-06-24T10:00:01Z
    my $epoch1 = timegm(5, 0, 10, 24, 5, 126);   # event 1: container_start 2026-06-24T10:00:05Z
    my $epoch2 = timegm(9, 0, 10, 24, 5, 126);   # event 2: container_gone  2026-06-24T10:00:09Z
    my $now = $epoch2 + 500;

    my $TIME_ROLE = tui::DashboardScreen::theme_role('muted');   # 'text.muted' (S2.1 table)

    # ---- with $now supplied: the time span renders, at the new Theme
    # ---- role, and everything else keeps its pre-existing claim.
    my $ev = Dashboard::recent_events(\@lines, 10, \&CORE::gmtime, $now);
    is(scalar(@$ev), 3, 'AC19: garbage + blank lines skipped (unchanged)');

    for my $i (0 .. 2) {
        is(ref($ev->[$i]), 'ARRAY', "AC19: event $i is an ARRAY ref of spans");
        is($ev->[$i][0]{role}, $TIME_ROLE,
            "AC19: event $i -- FIRST span (timestamp) is always role '$TIME_ROLE' when \$now is supplied");
    }

    # event 0: launch_start, no exit/state -> event_style classifies (rule 6: accent).
    my ($role0, $glyph0) = Dashboard::event_style('launch_start', undef, undef);
    is(Dashboard::spans_text($ev->[0]),
        sprintf("%-6s  ", Dashboard::_local_hhmm($epoch0, \&CORE::gmtime)) . "$glyph0 launch_start",
        'AC19: event 0 spans_text == "$duration  $glyph $type$extra"');
    # RE-POINTED (fix-batch, unified-tui-design-system package
    # 06-dashboard-screen, NO_COLOR regression item): recent_events now maps
    # glyph/body span roles through tui::DashboardScreen::theme_role(...) at
    # the span (same as the time span already did), so a non-timestamp
    # span's role is the THEME name, not event_style's legacy name directly.
    # The claim is unchanged -- "event 0's non-timestamp spans carry the
    # role the event styler assigned" -- only the vocabulary the span
    # actually carries moves, exactly as $TIME_ROLE already does above.
    # Derived, never hand-typed (never 'state.accent' etc. literally).
    my $expected_role0 = tui::DashboardScreen::theme_role($role0);
    my @nonts0 = grep { $_->{role} ne $TIME_ROLE } @{ $ev->[0] };
    ok((grep { $_->{role} eq $expected_role0 } @nonts0),
        "AC19: event 0's non-timestamp spans carry event_style's role mapped through Theme ($expected_role0), even though it's not muted");

    # event 1: container_start exit=0 -> good; the exit= extra is carried in the text.
    my ($role1, $glyph1) = Dashboard::event_style('container_start', 0, undef);
    is(Dashboard::spans_text($ev->[1]),
        sprintf("%-6s  ", Dashboard::_local_hhmm($epoch1, \&CORE::gmtime)) . "$glyph1 container_start exit=0",
        'AC19: event 1 spans_text carries the exit= extra text, with the classified glyph');
    is($ev->[1][0]{role}, $TIME_ROLE, 'AC19: event 1 timestamp span is muted even though the event itself is good');
    # RE-POINTED (same rationale/derivation as event 0 above), and load-
    # bearing here in a way event 0's check is NOT: 'good' -> 'state.ok'
    # actually changes under theme_role() (unlike 'accent', which collides
    # with its own Theme name), so this assertion, unlike event 0's, WOULD
    # fail if the span still carried the bare legacy role.
    my $expected_role1 = tui::DashboardScreen::theme_role($role1);
    my @nonts1 = grep { $_->{role} ne $TIME_ROLE } @{ $ev->[1] };
    ok((grep { $_->{role} eq $expected_role1 } @nonts1),
        "AC19: event 1's non-timestamp spans carry event_style's role mapped through Theme ($expected_role1)");

    # event 2: container_gone state=exited -> bad; the state= extra is carried.
    my ($role2, $glyph2) = Dashboard::event_style('container_gone', undef, 'exited');
    is(Dashboard::spans_text($ev->[2]),
        sprintf("%-6s  ", Dashboard::_local_hhmm($epoch2, \&CORE::gmtime)) . "$glyph2 container_gone state=exited",
        'AC19: event 2 spans_text carries the state= extra text, with the classified glyph');
    is($role2, 'bad', 'AC19: container_gone classifies as bad (sanity check on the fixture)');
    is($ev->[2][0]{role}, $TIME_ROLE, 'AC19: event 2 timestamp span is muted even though the event itself is bad');
    # RE-POINTED, same rationale as event 1 above ('bad' -> 'state.crit' is
    # also NOT an identity mapping, so this discriminates the fix too).
    my $expected_role2 = tui::DashboardScreen::theme_role($role2);
    my @nonts2 = grep { $_->{role} ne $TIME_ROLE } @{ $ev->[2] };
    ok((grep { $_->{role} eq $expected_role2 } @nonts2),
        "AC19: event 2's non-timestamp spans carry event_style's role mapped through Theme ($expected_role2)");

    # Ordering + last-N slice + skip-unparsable are unchanged.
    my $last2 = Dashboard::recent_events(\@lines, 2, \&CORE::gmtime, $now);
    is(scalar(@$last2), 2, 'AC19: honors the last-N limit (unchanged)');
    like(Dashboard::spans_text($last2->[-1]), qr/container_gone/,  'AC19: keeps the most recent (last) (unchanged)');
    like(Dashboard::spans_text($last2->[0]),  qr/container_start/, 'AC19: preserves chronological order (unchanged)');

    # ---- RE-POINTED (operator request): the time column is a WALL CLOCK, not
    # ---- an age, so it no longer depends on $now at all.
    #
    # The old arm asserted "no $now => no time span", on the reasoning that a
    # time computed without a clock would be fabricated. That reasoning applied
    # to an AGE, which is a function of (event, now) and genuinely cannot be
    # computed without the clock. A wall-clock time is a function of the EVENT'S
    # OWN timestamp alone -- it is data the row already carries. Rendering it
    # without $now is therefore strictly MORE honest than suppressing it, and
    # the property worth pinning is that the two arms agree.
    my $ev_no_now = Dashboard::recent_events(\@lines, 10, \&CORE::gmtime);
    is(scalar(@$ev_no_now), 3, 'AC19 (clock-free): garbage + blank lines still skipped with no $now');
    for my $i (0 .. 2) {
        is($ev_no_now->[$i][0]{role}, $TIME_ROLE,
            "AC19 (clock-free): event ${i}'s FIRST span is still the muted time span with no \$now -- the time comes from the EVENT, not the clock");
    }
    is(Dashboard::spans_text($ev_no_now->[0]), Dashboard::spans_text($ev->[0]),
        'AC19 (clock-free): the row is byte-identical with and without $now -- $now cannot influence a wall-clock column');
    is($ev_no_now->[0][0]{text}, sprintf('%-6s  ', Dashboard::_local_hhmm($epoch0, \&CORE::gmtime)),
        'AC19 (clock-free): and that column is the event timestamp rendered HH:MM');
}

# ===========================================================================
# 4.8 activity_window overlay (spec S2.5-S2.7, S3.16-19): AC20..AC26
# ===========================================================================
{
    # AC20: total <= cap -> all rows returned UNMODIFIED (identity on the input
    # elements, incl. a spans-arrayref element -- proves no re-spanify), above
    # == below == max_offset == 0, no scroll-triangle bytes anywhere, and the
    # return has no "hint" key (that key is gone for good, see AC21).
    require Scalar::Util;
    my $bad_row = [ { text => '10:00:00  ', role => tui::DashboardScreen::theme_role('muted') },
                    { text => 'X ',          role => tui::DashboardScreen::theme_role('bad') },
                    { text => 'evt_fail',    role => tui::DashboardScreen::theme_role('bad') } ];
    my @desc20 = ('e0', 'e1', $bad_row);
    my $w20 = Dashboard::activity_window(\@desc20, 0, 5, 78);
    is_deeply($w20->{lines}, \@desc20, 'AC20: total<=cap -> lines returned unmodified');
    is(Scalar::Util::refaddr($w20->{lines}[2]), Scalar::Util::refaddr($bad_row),
        'AC20: total<=cap -> the spans-arrayref element is the SAME reference (no re-spanify)');
    is($w20->{above}, 0, 'AC20: total<=cap -> above == 0');
    is($w20->{below}, 0, 'AC20: total<=cap -> below == 0');
    is($w20->{max_offset}, 0, 'AC20: total<=cap -> max_offset == 0');
    ok(!exists $w20->{hint}, 'AC20/AC21: activity_window return has no "hint" key (fits case)');
    for my $row (@{ $w20->{lines} }) {
        my $t = ref($row) eq 'ARRAY' ? Dashboard::spans_text($row) : $row;
        unlike($t, qr/\Q$TRI_UP\E|\Q$TRI_DOWN\E/, 'AC20: no scroll-triangle bytes in an unmodified row');
    }
}
{
    # AC21: total > cap -> exactly $cap rows (NOT $cap-1), max_offset ==
    # total-cap, no "hint" key, and _scroll_hint itself no longer exists.
    my @desc21 = map { "e$_" } (0 .. 9);   # 10 events
    my $w21 = Dashboard::activity_window(\@desc21, 0, 4, 78);
    is(scalar(@{ $w21->{lines} }), 4, 'AC21: overflow -> exactly $cap (4) rows returned, not $cap-1');
    is($w21->{max_offset}, 6, 'AC21: max_offset == total(10) - cap(4) == 6');
    ok(!exists $w21->{hint}, 'AC21: activity_window return has no "hint" key (overflow case)');
    ok(!Dashboard->can('_scroll_hint'), 'AC21: _scroll_hint no longer exists on the Dashboard package');
}
{
    # AC22: offset boundaries -- 0, max_offset, and a middle value. Same 10-event
    # fixture, cap=4 -> max_offset=6. Also folds in the old clamp-past-the-end
    # check (offset=99 must behave identically to offset=max_offset=6).
    my @desc22 = map { "e$_" } (0 .. 9);

    my $w_top = Dashboard::activity_window(\@desc22, 0, 4, 78);
    is($w_top->{above}, 0, 'AC22: offset=0 -> above=0');
    is($w_top->{below}, 6, 'AC22: offset=0 -> below=6');
    like(Dashboard::spans_text($w_top->{lines}[-1]), qr/\Q$TRI_DOWN\E 6 more$/,
        'AC22: offset=0 -> LAST row ends with "(down-triangle) 6 more"');
    unlike(Dashboard::spans_text($w_top->{lines}[0]), qr/\Q$TRI_UP\E/,
        'AC22: offset=0 -> FIRST row has no up-triangle');

    my $w_bot = Dashboard::activity_window(\@desc22, 6, 4, 78);
    is($w_bot->{offset}, 6, 'AC22: offset=max_offset(6) -> not clamped further');
    is($w_bot->{above}, 6, 'AC22: offset=max_offset(6) -> above=6');
    is($w_bot->{below}, 0, 'AC22: offset=max_offset(6) -> below=0');
    like(Dashboard::spans_text($w_bot->{lines}[0]), qr/\Q$TRI_UP\E 6 more$/,
        'AC22: offset=max_offset -> FIRST row ends with "(up-triangle) 6 more"');
    unlike(Dashboard::spans_text($w_bot->{lines}[-1]), qr/\Q$TRI_DOWN\E/,
        'AC22: offset=max_offset -> LAST row has no down-triangle');

    # offset past max_offset clamps to max_offset (identical result to offset=6).
    my $w_clamp = Dashboard::activity_window(\@desc22, 99, 4, 78);
    is($w_clamp->{offset}, 6, 'AC22: offset=99 (past the end) clamps to max_offset=6');
    is_deeply($w_clamp->{lines}, $w_bot->{lines}, 'AC22: clamped offset=99 view == offset=6 view');

    my $w_mid = Dashboard::activity_window(\@desc22, 3, 4, 78);
    is($w_mid->{above}, 3, 'AC22: offset=3 -> above=3');
    is($w_mid->{below}, 3, 'AC22: offset=3 -> below=3');
    like(Dashboard::spans_text($w_mid->{lines}[0]), qr/\Q$TRI_UP\E 3 more$/,
        'AC22: 0<offset<max -> FIRST row ends with "(up-triangle) 3 more"');
    like(Dashboard::spans_text($w_mid->{lines}[-1]), qr/\Q$TRI_DOWN\E 3 more$/,
        'AC22: 0<offset<max -> LAST row ends with "(down-triangle) 3 more"');
}
{
    # AC23: exact-width guarantee in BOTH the pad branch (short underlying text)
    # and the clip-left branch (long underlying text). cap=1, 2 events -> the
    # single returned row is desc[0], above=0, below=1 -> "(down-tri) 1 more"
    # (width 8: 1 glyph col + 7 ascii cols) overlaid on it.
    my $w = 20;
    my @desc23a = ('short', 'hi');
    my $wa = Dashboard::activity_window(\@desc23a, 0, 1, $w);
    is(Dashboard::spans_width($wa->{lines}[0]), $w, 'AC23: pad branch -- overlaid row is exactly $w columns');
    like(Dashboard::spans_text($wa->{lines}[0]), qr/\Q$TRI_DOWN\E 1 more$/, 'AC23: pad branch -- indicator text present');

    my $long_text = 'x' x 25;   # longer than $w -- lw+rw+1 (25+8+1=34) > 20
    my @desc23b = ($long_text, 'e1');
    my $wb = Dashboard::activity_window(\@desc23b, 0, 1, $w);
    is(Dashboard::spans_width($wb->{lines}[0]), $w,
        'AC23: clip branch -- overlaid row is STILL exactly $w columns despite a long underlying event');
    like(Dashboard::spans_text($wb->{lines}[0]), qr/\Q$TRI_DOWN\E 1 more$/,
        'AC23: clip branch -- indicator text survives (left side clipped instead)');
}
{
    # AC24: overlay preserves the row's own coloring; the indicator span itself
    # is role 'muted' (spec S2.5 default $right_role).
    my $fail_row = [ { text => '10:00:00  ', role => 'muted' },
                     { text => 'X ',          role => 'bad' },
                     { text => 'install_failed', role => 'bad' } ];
    my @desc24 = ($fail_row, 'e1');   # cap=1, 2 events -> above=0, below=1
    my $w24 = Dashboard::activity_window(\@desc24, 0, 1, 40);
    my @bad_spans = grep { $_->{role} eq 'bad' } @{ $w24->{lines}[0] };
    ok(scalar(@bad_spans) >= 1, 'AC24: overlaid row still contains its original non-muted (bad) span roles');
    my ($indicator_span) = grep { $_->{text} =~ /\Q$TRI_DOWN\E/ } @{ $w24->{lines}[0] };
    ok($indicator_span, 'AC24: an indicator span is present in the overlaid row');
    is($indicator_span->{role}, 'muted', "AC24: the indicator span's role is muted");
}
{
    # AC25: cap==1 with items both above AND below -> the single row carries the
    # COMBINED indicator exactly ONCE (never overlaid twice). 5 events, cap=1,
    # offset=2 -> max_offset=4, end=2, above=2, below=2.
    my @desc25 = map { "e$_" } (0 .. 4);
    my $w25 = Dashboard::activity_window(\@desc25, 2, 1, 40);
    is($w25->{above}, 2, 'AC25: above=2');
    is($w25->{below}, 2, 'AC25: below=2');
    is(scalar(@{ $w25->{lines} }), 1, 'AC25: cap=1 -> exactly one row returned');
    my $text25 = Dashboard::spans_text($w25->{lines}[0]);
    like($text25, qr/\Q$TRI_UP\E 2 more.*\Q$TRI_DOWN\E 2 more/,
        'AC25: the single row carries the COMBINED indicator (both counts present)');
    is(scalar(() = $text25 =~ /\Q$TRI_UP\E/g),   1, 'AC25: the up-triangle appears exactly once (not overlaid twice)');
    is(scalar(() = $text25 =~ /\Q$TRI_DOWN\E/g), 1, 'AC25: the down-triangle appears exactly once (not overlaid twice)');
    is(Dashboard::spans_width($w25->{lines}[0]), 40, 'AC25: the combined-overlay row is exactly $w columns');
}
{
    # AC26: indicator cannot fit AT ALL (rw+1 > w) -> dropped whole, row still
    # exactly $w columns, no partial glyph. 10 events, cap=4, offset=0 ->
    # below=6 -> indicator "(down-tri) 6 more" needs 1+7=8 cols; $w=5 < 9 drops it.
    my @desc26 = map { "e$_" } (0 .. 9);
    my $w26 = Dashboard::activity_window(\@desc26, 0, 4, 5);
    is(Dashboard::spans_width($w26->{lines}[-1]), 5,
        'AC26: row still returned at exactly $w columns when the indicator cannot fit');
    unlike(Dashboard::spans_text($w26->{lines}[-1]), qr/\Q$TRI_DOWN\E/,
        'AC26: no down-triangle byte sequence when the indicator is dropped whole');
    unlike(Dashboard::spans_text($w26->{lines}[-1]), qr/\Q$TRI_UP\E/, 'AC26: no up-triangle byte sequence either');

    # Related (spec S3.16 last bullet): $w undef/<=0 -> no overlay attempted at
    # all, rows pass through untouched, but above/below/offset/max_offset are
    # still computed.
    my $w26b = Dashboard::activity_window(\@desc26, 0, 4, undef);
    is($w26b->{below}, 6, 'AC26 (related): $w undef -> above/below still computed');
    is_deeply($w26b->{lines}, [ @desc26[0 .. 3] ], 'AC26 (related): $w undef -> rows pass through untouched');
    my $w26c = Dashboard::activity_window(\@desc26, 0, 4, 0);
    is_deeply($w26c->{lines}, [ @desc26[0 .. 3] ], 'AC26 (related): $w<=0 -> rows pass through untouched');
}

# ===========================================================================
# 4.9 compose_frame invariant sweep (spec S3.19): AC27
# ===========================================================================
{
    my @event_lines = (
        '{"ts":"2026-06-24T10:00:01Z","type":"heartbeat"}',
        '{"ts":"2026-06-24T10:00:02Z","type":"install_failed"}',
        '{"ts":"2026-06-24T10:00:03Z","type":"container_start","exit":0}',
        '{"ts":"2026-06-24T10:00:04Z","type":"launch_session"}',
        '{"ts":"2026-06-24T10:00:05Z","type":"unrecognized_thing"}',
    ) x 4;   # 20 lines -- plenty to trigger scroll overflow at small caps
    my $events27 = Dashboard::recent_events(\@event_lines, 50);
    my $bp27 = { total => 12, approved => 5,
        items => [ map { { key => "apt:pkg$_", approved => ($_ % 2 == 0) ? 1 : 0 } } (1 .. 12) ] };

    my @states = (
        { project_name => 'demo', container => 'c1', status => 'running',
          beat_age => 5, uptime => 100, oauth_remaining => 28800,
          busy_age => 10, stay_awake => 1, needs_you => 0,
          backpack => $bp27, events => $events27 },
        { project_name => 'demo', container => 'c1', status => 'exited', container_gone => 1,
          beat_age => 99999, uptime => 0, oauth_remaining => undef,
          busy_age => undef, stay_awake => 0, needs_you => 3,
          backpack => $bp27, events => $events27 },
        { project_name => 'demo', container => 'c1', status => 'created',
          beat_age => 5, uptime => 5, oauth_remaining => 30,
          busy_age => 5, stay_awake => 0, needs_you => 0,
          events => $events27 },
        { project_name => 'demo', container => 'c1', status => '', events => $events27 },
    );

    for my $cols (10, 20, 40, 80, 120) {
        for my $rows (3, 8, 24, 40) {
            for my $si (0 .. $#states) {
                my $f = Dashboard::compose_frame($states[$si], $rows, $cols);
                is(scalar(@$f), $rows, "AC27: compose_frame state$si rows=$rows cols=$cols -> exactly \$rows cells");
                my $bad = 0;
                for my $cell (@$f) {
                    $bad++ if Dashboard::display_width($cell->{text}) != $cols;
                    $bad++ if Dashboard::spans_width($cell->{spans}) != $cols;
                    $bad++ if $cell->{text} ne Dashboard::spans_text($cell->{spans});
                }
                is($bad, 0, "AC27: state$si rows=$rows cols=$cols -> every row exactly \$cols (text/spans/eq invariant)");
            }
        }
    }
}

# AC28 (perl plugins/sandbox/tests/run-tests.pl green) is a suite-level gate,
# not a unit assertion here -- verified by the coordinator at pipeline step 5
# (validation) and step 7 (post-fix-batch re-validation), same convention as
# s05's file/suite-level ACs.

done_testing();
