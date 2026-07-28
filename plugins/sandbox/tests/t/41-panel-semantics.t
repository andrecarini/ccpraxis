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
use Test::More;
use Encode qw(encode);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# Glyph literals (spec S2.1/S2.3/S2.6), encoded to UTF-8 bytes -- the
# module's span `text` contract (spec S2 preamble).
# ===========================================================================
my $GLYPH_GREEN  = encode('UTF-8', "\x{1F7E2}");
my $GLYPH_RED    = encode('UTF-8', "\x{1F534}");
my $GLYPH_YELLOW = encode('UTF-8', "\x{1F7E1}");
my $GLYPH_WHITE  = encode('UTF-8', "\x{26AA}");
my $TRI_UP       = encode('UTF-8', "\x{25B2}");
my $TRI_DOWN     = encode('UTF-8', "\x{25BC}");

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
# 4.3 Sandbox + Run panel spans (spec S3 behaviors 1-8): AC1, AC2, AC5, AC7, AC8
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
    my @panels = Dashboard::_fixed_panels(\%full, 80);
    my ($sandbox) = grep { $_->{title} eq 'Sandbox' } @panels;
    my ($run)     = grep { $_->{title} eq 'Run' } @panels;
    ok($sandbox, 'AC1: a Sandbox panel is present');
    ok($run,     'AC1: a Run panel is present');

    is(scalar(@{ $sandbox->{lines} }), 5, 'AC1: Sandbox panel has exactly 5 lines');
    is(scalar(@{ $run->{lines} }),     3, 'AC1: Run panel has exactly 3 lines');

    my @slabels = ('project   : ', 'container : ', 'heartbeat : ', 'uptime    : ', 'oauth     : ');
    for my $i (0 .. 4) {
        my $line = $sandbox->{lines}[$i];
        is(ref($line), 'ARRAY', "AC1: Sandbox line $i is an ARRAY ref of spans");
        is($line->[0]{text}, $slabels[$i], "AC1: Sandbox line $i first span text is the exact label (incl. padding)");
        is($line->[0]{role}, 'label',      "AC1: Sandbox line $i first span role is 'label'");
    }

    my @rlabels = ('busy-lease : ', 'keep-awake : ', 'needs you  : ');
    for my $i (0 .. 2) {
        my $line = $run->{lines}[$i];
        is(ref($line), 'ARRAY', "AC1/AC8: Run line $i is an ARRAY ref of spans");
        is($line->[0]{text}, $rlabels[$i], "AC1/AC8: Run line $i first span text is the exact label (incl. padding)");
        is($line->[0]{role}, 'label',      "AC1/AC8: Run line $i first span role is 'label'");
    }

    # AC2: value span roles when every field is defined+non-empty.
    is($sandbox->{lines}[0][1]{role}, 'strong', 'AC2: project value role is strong when defined+non-empty');
    is($sandbox->{lines}[0][1]{text}, 'demo',   'AC2: project value text is the project name');
    is($sandbox->{lines}[1][1]{role}, 'value',  'AC2: container name role is value when defined+non-empty');
    is($sandbox->{lines}[1][1]{text}, 'claude-demo-abcd1234', 'AC2: container name text');
    is($sandbox->{lines}[2][1]{role}, 'value', 'AC2: heartbeat value role is value when beat_age defined');
    is($sandbox->{lines}[2][1]{text}, Dashboard::fmt_age(12) . ' ago',
        'AC2: heartbeat text is fmt_age(...) . " ago"');
    is($sandbox->{lines}[3][1]{role}, 'value', 'AC2: uptime value role is value when uptime defined');
    is($sandbox->{lines}[3][1]{text}, Dashboard::fmt_hms(3660), 'AC2: uptime text is fmt_hms(...)');

    # AC5: composed container line -- the "<glyph> [<status>]" span and the
    # whole line's spans_text.
    my ($glyph, $crole) = Dashboard::container_status_style('running', undef);
    is(Dashboard::spans_text($sandbox->{lines}[1]),
        "container : claude-demo-abcd1234  $glyph [running]",
        'AC5: composed container line spans_text matches the exact spec text');
    my ($status_span) = grep { $_->{text} eq "$glyph [running]" } @{ $sandbox->{lines}[1] };
    ok($status_span, 'AC5: a span exists whose text is exactly "<glyph> [<status>]"');
    is($status_span->{role}, $crole, 'AC5: that span carries the container_status_style role');

    # AC7: oauth line for each of the four tiers, always present, never dropped.
    for my $r (undef, -1, 450, 11520) {
        my %s2 = (%full, oauth_remaining => $r);
        my @p2 = Dashboard::_fixed_panels(\%s2, 80);
        my ($sb2) = grep { $_->{title} eq 'Sandbox' } @p2;
        ok($sb2, "AC7: Sandbox panel present for oauth_remaining=" . (defined $r ? $r : 'undef'));
        my $oline = $sb2->{lines}[4];
        my $label = defined $r ? $r : 'undef';
        is_deeply($oline,
            [ { text => 'oauth     : ', role => 'label' },
              { text => Dashboard::fmt_oauth($r), role => Dashboard::oauth_role($r) } ],
            "AC7: oauth line for oauth_remaining=$label matches exactly");
    }

    # AC8: Run panel role table across the busy-lease/keep-awake/needs-you tiers.
    my @run_cases = (
        # [ busy_age, stay_awake, needs_you, busy_text, busy_role, keep_text, keep_role, needs_text, needs_role ]
        [undef, 0, 0, 'none (no active run)', 'muted',
            'released (PC may sleep)', 'muted', 'none', 'muted'],
        [30, 1, 2, 'active (' . Dashboard::fmt_age(30) . ' ago)', 'good',
            'holding (PC stays awake)', 'good', '2 decision(s) waiting', 'warn'],
        [9999, 0, 0, 'idle (' . Dashboard::fmt_age(9999) . ' ago)', 'warn',
            'released (PC may sleep)', 'muted', 'none', 'muted'],
    );
    for my $c (@run_cases) {
        my ($busy_age, $stay_awake, $needs_you, $bt, $br, $kt, $kr, $nt, $nr) = @$c;
        my %s3 = (%full, busy_age => $busy_age, stay_awake => $stay_awake, needs_you => $needs_you);
        my @p3 = Dashboard::_fixed_panels(\%s3, 80);
        my ($rn) = grep { $_->{title} eq 'Run' } @p3;
        my $tag = 'busy_age=' . (defined $busy_age ? $busy_age : 'undef') . " stay_awake=$stay_awake needs_you=$needs_you";
        is_deeply($rn->{lines}[0], [ { text => 'busy-lease : ', role => 'label' }, { text => $bt, role => $br } ],
            "AC8: busy-lease line ($tag)");
        is_deeply($rn->{lines}[1], [ { text => 'keep-awake : ', role => 'label' }, { text => $kt, role => $kr } ],
            "AC8: keep-awake line ($tag)");
        is_deeply($rn->{lines}[2], [ { text => 'needs you  : ', role => 'label' }, { text => $nt, role => $nr } ],
            "AC8: needs-you line ($tag)");
    }

    # AC2 (absent branches): project/container/heartbeat/uptime fall back to
    # '?'/'n/a' with role muted when their state fields are absent.
    my %sparse = (status => 'running');
    my @ps = Dashboard::_fixed_panels(\%sparse, 80);
    my ($sb_sparse) = grep { $_->{title} eq 'Sandbox' } @ps;
    is_deeply($sb_sparse->{lines}[0], [ { text => 'project   : ', role => 'label' }, { text => '?', role => 'muted' } ],
        'AC2: project absent -> "?" + muted');
    is($sb_sparse->{lines}[1][1]{text}, '?',    'AC2: container name absent -> "?"');
    is($sb_sparse->{lines}[1][1]{role}, 'muted', 'AC2: container name absent -> muted role');
    is($sb_sparse->{lines}[2][1]{text}, 'n/a',  'AC2: heartbeat absent (beat_age undef) -> "n/a"');
    is($sb_sparse->{lines}[2][1]{role}, 'muted', 'AC2: heartbeat absent -> muted role');
    is($sb_sparse->{lines}[3][1]{text}, 'n/a',  'AC2: uptime absent (uptime undef) -> "n/a"');
    is($sb_sparse->{lines}[3][1]{role}, 'muted', 'AC2: uptime absent -> muted role');

    # spec S2.8 / S5.6: _fixed_panels($state) with NO $cols must default to 80
    # and must not die (old call sites keep working).
    my @pd = eval { Dashboard::_fixed_panels(\%full) };
    is($@, '', 'S2.8/S5.6: _fixed_panels($state) with no $cols does not die (defaults to 80)');
    ok(scalar(@pd), 'S2.8/S5.6: _fixed_panels($state) with no $cols still returns panels');
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
        { text => 'aa',   role => 'good' },
        { text => 'bb',   role => 'warn' },
        { text => 'cc',   role => 'good' },
        { text => 'dddd', role => 'warn' },
    );
    my $lines = Dashboard::wrap_spans(\@words, 6);
    is(ref($lines), 'ARRAY', 'AC9: wrap_spans returns an arrayref');
    is(scalar(@$lines), 3, 'AC9: wrap_spans(w=6) groups the 4 words into exactly 3 lines');
    is_deeply($lines->[0],
        [ { text => 'aa', role => 'good' }, { text => ' ', role => 'body' }, { text => 'bb', role => 'warn' } ],
        'AC9: line 1 is "aa bb" with a body-role separator, original word roles preserved');
    is_deeply($lines->[1], [ { text => 'cc', role => 'good' } ], 'AC9: line 2 is "cc" alone (didn\'t fit after bb)');
    is_deeply($lines->[2], [ { text => 'dddd', role => 'warn' } ], 'AC9: line 3 is "dddd" alone (didn\'t fit after cc)');

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
    my $long = Dashboard::wrap_spans([ { text => 'averylongword', role => 'good' } ], 4);
    is(scalar(@$long), 1, 'AC10: a single over-wide word still produces exactly one line');
    is_deeply($long->[0], [ { text => 'averylongword', role => 'good' } ],
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

    # End-to-end via build_panels($state,$cols): the $cols -> $w=$cols-2 wiring.
    my %state5 = (status => 'running', backpack => $bp5);
    my ($bpanel_wide)   = grep { $_->{title} eq 'Backpack' } Dashboard::build_panels(\%state5, 120);
    my ($bpanel_narrow) = grep { $_->{title} eq 'Backpack' } Dashboard::build_panels(\%state5, 40);
    ok($bpanel_wide,   'AC14 (end-to-end): Backpack panel present at cols=120');
    ok($bpanel_narrow, 'AC14 (end-to-end): Backpack panel present at cols=40');
    my @wp = @{ $bpanel_wide->{lines} }[1 .. $#{ $bpanel_wide->{lines} }];
    my @np = @{ $bpanel_narrow->{lines} }[1 .. $#{ $bpanel_narrow->{lines} }];
    isnt(scalar(@wp), scalar(@np),
        'AC14 (end-to-end): build_panels($state,$cols) backpack row count differs between cols=120 and cols=40');
    for my $row (@wp) { ok(Dashboard::spans_width($row) <= 118, 'AC14 (end-to-end): wide row width <= $cols-2'); }
    for my $row (@np) { ok(Dashboard::spans_width($row) <= 38,  'AC14 (end-to-end): narrow row width <= $cols-2'); }
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

    for my $cols (120, 40) {
        my $expected_h = Dashboard::_fixed_region_height(\%state16, $cols);
        my $f = Dashboard::compose_frame(\%state16, 30, $cols);
        my $activity_title_idx;
        for my $i (1 .. $#$f) {
            if ($f->[$i]{text} =~ /-- Recent activity /) { $activity_title_idx = $i; last; }
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
# 4.7 recent_events spans (spec S3.14): AC19
# ===========================================================================
{
    my @lines = (
        '{"ts":"2026-06-24T10:00:01Z","type":"launch_start","pid":1}',
        'not json at all',
        '{"ts":"2026-06-24T10:00:05Z","type":"container_start","exit":0}',
        '{"ts":"2026-06-24T10:00:09Z","type":"container_gone","state":"exited"}',
        '',
    );
    my $ev = Dashboard::recent_events(\@lines, 10, \&CORE::gmtime);
    is(scalar(@$ev), 3, 'AC19: garbage + blank lines skipped (unchanged)');

    for my $i (0 .. 2) {
        is(ref($ev->[$i]), 'ARRAY', "AC19: event $i is an ARRAY ref of spans");
        is($ev->[$i][0]{role}, 'muted', "AC19: event $i -- FIRST span (timestamp) is always role muted");
    }

    # event 0: launch_start, no exit/state -> event_style classifies (rule 6: accent).
    my ($role0, $glyph0) = Dashboard::event_style('launch_start', undef, undef);
    is(Dashboard::spans_text($ev->[0]), "10:00:01  $glyph0 launch_start",
        'AC19: event 0 spans_text == "$hms  $glyph $type$extra"');
    my @nonts0 = grep { $_->{role} ne 'muted' } @{ $ev->[0] };
    ok((grep { $_->{role} eq $role0 } @nonts0),
        "AC19: event 0's non-timestamp spans carry event_style's role ($role0), even though it's not muted");

    # event 1: container_start exit=0 -> good; the exit= extra is carried in the text.
    my ($role1, $glyph1) = Dashboard::event_style('container_start', 0, undef);
    is(Dashboard::spans_text($ev->[1]), "10:00:05  $glyph1 container_start exit=0",
        'AC19: event 1 spans_text carries the exit= extra text, with the classified glyph');
    is($ev->[1][0]{role}, 'muted', 'AC19: event 1 timestamp span is muted even though the event itself is good');

    # event 2: container_gone state=exited -> bad; the state= extra is carried.
    my ($role2, $glyph2) = Dashboard::event_style('container_gone', undef, 'exited');
    is(Dashboard::spans_text($ev->[2]), "10:00:09  $glyph2 container_gone state=exited",
        'AC19: event 2 spans_text carries the state= extra text, with the classified glyph');
    is($role2, 'bad', 'AC19: container_gone classifies as bad (sanity check on the fixture)');
    is($ev->[2][0]{role}, 'muted', 'AC19: event 2 timestamp span is muted even though the event itself is bad');

    # Ordering + last-N slice + skip-unparsable are unchanged.
    my $last2 = Dashboard::recent_events(\@lines, 2, \&CORE::gmtime);
    is(scalar(@$last2), 2, 'AC19: honors the last-N limit (unchanged)');
    like(Dashboard::spans_text($last2->[-1]), qr/container_gone/,  'AC19: keeps the most recent (last) (unchanged)');
    like(Dashboard::spans_text($last2->[0]),  qr/container_start/, 'AC19: preserves chronological order (unchanged)');
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
    my $bad_row = [ { text => '10:00:00  ', role => 'muted' },
                    { text => 'X ',          role => 'bad' },
                    { text => 'evt_fail',    role => 'bad' } ];
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
