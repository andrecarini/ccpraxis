#!/usr/bin/env perl
# s04-render-foundation: the render/span oracle for Dashboard.pm.
#
# This file is the IMMUTABLE ORACLE for blueprint s04-render-foundation
# (spec 01-render-foundation-spec.md, S3 API contract / S5 invariants /
# S7 acceptance criteria). It is written BLIND to Dashboard.pm's
# implementation -- directly from the spec -- so it can serve as an oracle
# rather than an echo of whatever the implementer eventually writes.
#
# Coverage: AC-1..AC-7, AC-10 (multi-span variant), AC-11 (role-only and
# span-only variants), AC-13 (multi-span), AC-14, AC-15, AC-16, AC-18, AC-19.
#
# The functions under test (display_width, glyph_table, glyph_width, _safe,
# spanify, spans_width, spans_text, fit_spans, make_cell, sgr_for_role,
# _row_ansi, render_frame) DO NOT YET EXIST on package load -- every
# assertion below is EXPECTED to fail with "Undefined subroutine" until the
# implementer lands s04. That is correct and by design.
#
# Hard constraint (S3, D7): this file MUST NOT `use utf8`. Glyph literals are
# written as "\x{...}" escapes / chr($codepoint) (the decoded-character path)
# and mirrored via Encode::encode('UTF-8', ...) (the UTF-8-byte path) so both
# of D3's encoding paths are exercised without flagging this source file as
# UTF-8 itself.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

# _dash_glyph_table() -> { decoded_char => declared_width }, the contract
# Dashboard::glyph_table() used to provide. That function was a thin derivation
# over Theme::glyphs() and was deleted as unreachable from shipped code; the
# derivation is reproduced here rather than the assertions being dropped,
# because what they check -- that a glyph this codebase emits is declared, at
# the width Theme declares -- is still worth checking. Note Theme::glyphs() is
# keyed by NAME, not by character, which is why this is not a straight alias.
sub _dash_glyph_table {
    my $g = Theme::glyphs();
    my %t;
    for my $name (keys %$g) {
        my $rec = $g->{$name};
        next unless ref($rec) eq 'HASH' && defined $rec->{char};
        $t{ $rec->{char} } = $rec->{width};
    }
    return \%t;
}
use Test::More;
use Encode qw(encode);
use Theme;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# Fixture: the pinned glyph table (spec S3.2) -- codepoint, expected column
# width, group, human name. Shared by AC-2 and AC-15.
#
# MIGRATED 2026-08-08 (package 06-dashboard-screen, driver scope grant E-B):
# the four status-circle EMOJI (U+1F7E2/1F534/1F7E1/26AA) that used to sit
# here at width 2 are REMOVED from this fixture, not re-pinned at a new
# width. Obligation 3 (spec 06 S2.2) deletes them from Dashboard's glyph
# table entirely -- Theme.pm never declared them (they are emoji; Decision
# 11 forbids emoji in this design system) and _dash_glyph_table() now
# derives from Theme::glyphs() instead of its own legacy %GLYPH_TABLE. They
# are no longer "pinned glyphs" at all, so a row here claiming "this is a
# pinned glyph at width W" would be false of them regardless of W. Their
# AC-2/AC-15 claims are RETARGETED, not dropped -- see the "RETIRED FROM
# AC-2/AC-15" block right after AC-15 below, which proves the new, correct
# behaviour (unlisted: absent from glyph_table(), glyph_width() undef,
# _safe() -> '?') for these exact four codepoints.
# ===========================================================================
# THE SPINNER FRAMES ARE DERIVED, not pasted (re-pointed 2026-08-25). The
# sequence changed from ten frames with uneven dot counts to eight uniform ones,
# and a pasted list of codepoints turns a deliberate re-styling into a red test
# about characters this file never claimed were special. What AC-2 and AC-15 are
# about is the WIDTH CONTRACT -- every glyph the renderer emits is declared, at
# its declared width, and measures the same decoded or as UTF-8 bytes -- and
# that claim is exactly as strong over whatever frames Theme declares. The dot
# count itself is pinned where it belongs, in t/100-status-live.t's UNIFORM DOTS
# block.
my @SPINNER_GLYPHS =
    map { [ ord(Theme::glyphs()->{"spinner.$_"}{char}), 1, 'spinner', "braille spinner frame $_" ] }
    1 .. Theme::SPINNER_FRAMES();

my @GLYPHS = (
    @SPINNER_GLYPHS,
    # DERIVED (re-pointed 2026-08-26): AC-2/AC-15 are about the width
    # contract -- declared, and equal in both encodings -- which holds over
    # whatever glyphs Theme names, exactly as for the spinner frames above.
    [ord(Theme::glyphs()->{'gauge.full'}{char}),  1, 'gauge', 'meter fill'],
    [ord(Theme::glyphs()->{'gauge.empty'}{char}), 1, 'gauge', 'meter track'],
    [0x25B2,  1, 'scroll',  'up triangle'],
    [0x25BC,  1, 'scroll',  'down triangle'],
);
is(scalar(@GLYPHS), Theme::SPINNER_FRAMES() + 4,
    'sanity: glyph fixture carries every spinner frame plus the four gauge/scroll glyphs '
  . '(the 4 status-circle emoji moved out, see comment above)');

# ===========================================================================
# AC-1 -> DC-1: display_width returns length() for pure-ASCII strings
# (including ''), and 0 for undef.
# ===========================================================================
is(Dashboard::display_width(undef), 0, 'AC-1: display_width(undef) == 0');
is(Dashboard::display_width(''),    0, 'AC-1: display_width("") == 0');
for my $s ('hello', 'a', 'The quick brown fox! 123', '   ', 'MiXeD-Case_1!@#$%^&*()') {
    is(Dashboard::display_width($s), length($s),
        "AC-1: display_width(pure ASCII '$s') == length");
}

# ===========================================================================
# AC-2 -> DC-1: every pinned glyph is its declared width, whether it arrives
# decoded ("\x{...}") or as its UTF-8 byte encoding. The hard constraint:
# both forms must agree -- that equality IS this criterion.
# ===========================================================================
for my $g (@GLYPHS) {
    my ($cp, $w, $group, $name) = @$g;
    my $decoded = chr($cp);
    my $bytes   = encode('UTF-8', $decoded);
    my $tag     = sprintf('U+%04X %s/%s', $cp, $name, $group);
    is(Dashboard::display_width($decoded), $w, "AC-2: display_width(decoded $tag) == $w");
    is(Dashboard::display_width($bytes),   $w, "AC-2: display_width(UTF-8 bytes $tag) == $w");
    is(Dashboard::display_width($decoded), Dashboard::display_width($bytes),
        "AC-2: decoded and byte forms of $tag agree (the encoding contract)");
}

# ===========================================================================
# AC-3 -> DC-1: a base character followed by combining marks / variation
# selectors counts only the base character's width.
# ===========================================================================
is(Dashboard::display_width("e\x{301}"), 1,
    'AC-3: "e" + combining acute (U+0301) == 1 (base width only)');
# RETARGETED 2026-08-08 (package 06-dashboard-screen, driver scope grant
# E-B): white-circle (U+26AA) left the glyph table (Obligation 3, spec 06
# S2.2) and now measures 1, not 2 -- the base's width changed, not VS16's
# zero-width behaviour. The claim ("a variation selector adds no columns")
# still fires: were VS16 wrongly counted, this would read 2, not 1.
is(Dashboard::display_width("\x{26AA}\x{FE0F}"), 1,
    'AC-3: white-circle + VS16 (U+FE0F) == 1 (VS16 still zero-width; base is now 1, was 2, Obligation 3)');

# ===========================================================================
# AC-4 -> DC-1: SGR sequences count 0 columns; an incomplete escape leaves
# its printable residue counted; TAB (a control) counts 0.
# ===========================================================================
is(Dashboard::display_width("\e[32mok\e[0m"), 2,
    'AC-4: display_width strips whole SGR sequences, counts only "ok" (2 cols)');
is(Dashboard::display_width("\e"), 0,
    'AC-4: a lone ESC alone is 0 columns');
is(Dashboard::display_width("\e[32"), 3,
    'AC-4: incomplete escape -- only the ESC is zero-width, "[32" is 3 visible columns');
is(Dashboard::display_width("a\tb"), 2,
    'AC-4: TAB is a control char (0 columns); "a" + "b" == 2');

# ===========================================================================
# AC-5 -> DC-1, DC-4: display_width never dies and never warns, and always
# returns a defined non-negative integer -- even on invalid/truncated UTF-8,
# undef, and a lone control byte.
# ===========================================================================
{
    for my $case (
        [ "\xFF\xFE", 'invalid UTF-8 (0xFF 0xFE)' ],
        [ "\xF0\x9F", 'truncated UTF-8 (2-byte prefix of a 4-byte sequence)' ],
        [ undef,      'undef' ],
        [ "\x01",     'a lone C0 control byte' ],
    ) {
        my ($input, $label) = @$case;
        my $warns = 0;
        local $SIG{__WARN__} = sub { $warns++ };
        my $result = eval { Dashboard::display_width($input) };
        my $err = $@;
        is($err, '', "AC-5: display_width($label) does not die");
        ok((defined($result) && $result =~ /\A\d+\z/),
            "AC-5: display_width($label) returns a defined non-negative integer");
        is($warns, 0, "AC-5: display_width($label) emits no warnings");
    }
}

# ===========================================================================
# AC-6 -> DC-2: make_cell on a hand-built multi-span line (ASCII + a
# 2-column glyph + a role whose SGR is non-empty) always yields spans
# totalling exactly $cols, whatever $cols is.
# ===========================================================================
{
    my $mixed_line = [
        { text => 'ab',        role => 'label'  },   # label SGR = \e[2m (non-empty)
        { text => "\x{1F7E2}", role => 'accent'  },   # arbitrary glyph text (width now 1, was 2 -- Obligation 3; irrelevant to this block's adaptive-padding claim)
        { text => 'cd',        role => 'body'   },
    ];
    for my $cols (1, 2, 3, 10, 40, 80, 120) {
        my $cell = tui::Frame::make_cell($mixed_line, 'body', $cols);
        is(Dashboard::spans_width($cell->{spans}), $cols,
            "AC-6: spans_width(make_cell(mixed spans, cols=$cols)) == $cols");
        is(Dashboard::display_width($cell->{text}), $cols,
            "AC-6: display_width(make_cell(mixed spans, cols=$cols)->{text}) == $cols");
        is($cell->{text}, Dashboard::spans_text($cell->{spans}),
            "AC-6: cell->{text} eq spans_text(cell->{spans}) at cols=$cols");
    }
}

# ===========================================================================
# AC-7 -> DC-2: truncation that would land INSIDE a wide glyph drops the
# whole glyph and pads with a space instead -- never a half-glyph.
#
# RETARGETED 2026-08-08 (package 06-dashboard-screen, driver scope grant
# E-B, spec 06 AC-G6's rule): the original fixture used U+1F7E2 (green
# circle) as "a 2-column glyph". Obligation 3 deletes it from the glyph
# table and it now measures 1 column -- keeping it here would make the
# 2-column cut land EXACTLY on a boundary between 'a' and the glyph instead
# of mid-glyph, so the assertion would pass trivially without ever
# exercising the "drop the whole glyph" branch at all. That is the exact
# vacuity trap AC-G6 names (spec 06 S4): "if you re-point those fixtures to
# a glyph that is now 1 column wide ... the assertion becomes trivially
# true and its claim is GONE even though it is green". Per AC-G6's rule the
# subject is re-derived by SELECTING FROM THEME rather than re-guessing a
# literal, and fails loudly if no 2-column glyph exists any more (which
# would mean the claim is genuinely untestable, not silently true).
# ===========================================================================
{
    my ($wide_name) = grep { Theme::glyphs()->{$_}{width} == 2 } sort keys %{ Theme::glyphs() };
    ok(defined $wide_name,
        'AC-7 setup: at least one width-2 glyph still exists in Theme::glyphs() to straddle (AC-G6 loud-failure rule)');
  SKIP: {
        skip 'AC-7: no 2-column glyph exists in Theme::glyphs() any more -- the straddling-glyph claim is untestable, not silently true', 3
            unless defined $wide_name;
        my $wide_char   = Theme::glyphs()->{$wide_name}{char};
        my $glyph_bytes = encode('UTF-8', $wide_char);
        my $line = 'a' . $wide_char;                 # decoded width 1 + 2 = 3
        my $cell = tui::Frame::make_cell($line, 'body', 2);   # the cut lands mid-glyph
        is(Dashboard::display_width($cell->{text}), 2,
            'AC-7: mid-glyph truncation still yields exactly $w == 2 columns');
        is($cell->{text}, 'a ',
            "AC-7: the straddling glyph ($wide_name) is dropped and replaced by one pad space (\"a \")");
        unlike($cell->{text}, qr/\Q$glyph_bytes\E/,
            "AC-7: the dropped glyph's ($wide_name) own UTF-8 bytes are wholly absent from the result");
    }
}

# ===========================================================================
# AC-10 -> DC-3 (multi-span variant): two independently-built, structurally
# identical frames (distinct refs, cells carrying multi-span arrayrefs) diff
# to NOTHING -- proving the diff key is a value comparison (_cell_sig), not
# a reference comparison.
# ===========================================================================
{
    my $build = sub {
        my @rows;
        push @rows, tui::Frame::make_cell(
            [ { text => 'foo', role => 'label' }, { text => "\x{1F7E2}", role => 'accent' } ],
            'body', 20);
        push @rows, tui::Frame::make_cell(
            [ { text => 'bar', role => 'value' }, { text => 'baz', role => 'muted' } ],
            'body', 20);
        push @rows, tui::Frame::make_cell('plain footer row', 'footer', 20);
        return \@rows;
    };
    my $mfA = $build->();
    my $mfB = $build->();
    isnt($mfA, $mfB, 'AC-10 setup: the two multi-span frames are distinct references');
    my $mdiff = Dashboard::render_frame($mfA, $mfB, { color => 0 });
    unlike($mdiff, qr/\e\[2J/,
        'AC-10: structurally-identical multi-span frames -> no full clear');
    my @mmoves = ($mdiff =~ /\e\[(\d+);1H/g);
    is(scalar(@mmoves), 0,
        'AC-10: structurally-identical multi-span frames -> zero row repaints');
}

# ===========================================================================
# AC-11 -> DC-3: role-only and span-only variants. (t/25 already keeps the
# text-change variant at :366-369.) Both prove _cell_sig -- not a naive
# text-eq-and-role-eq compare -- drives the diff, per D2.
# ===========================================================================
{
    # (a) role-only: the ROW-level (cell) role changes; every span (text +
    # role) is byte-for-byte identical between the two frames.
    my $fixed_span = [ { text => 'txt', role => 'accent' } ];
    my $cellA = tui::Frame::make_cell($fixed_span, 'body',  3);   # exact fit, no pad
    my $cellB = tui::Frame::make_cell($fixed_span, 'alert', 3);
    is_deeply($cellA->{spans}, $cellB->{spans},
        'AC-11 role-only setup: spans array is identical between the two cells');
    is($cellA->{text}, $cellB->{text},
        'AC-11 role-only setup: cell text is identical between the two cells');
    isnt($cellA->{role}, $cellB->{role},
        'AC-11 role-only setup: only the row-level (cell) role differs');

    my $footer3 = tui::Frame::make_cell('same', 'footer', 3);
    my $frameA = [ $footer3, $cellA ];
    my $frameB = [ $footer3, $cellB ];
    my $rdiff = Dashboard::render_frame($frameA, $frameB, { color => 0 });
    unlike($rdiff, qr/\e\[2J/, 'AC-11 role-only: same row count -> diff path, not a clear');
    my @moves = ($rdiff =~ /\e\[(\d+);1H/g);
    is(scalar(@moves), 1,
        'AC-11 role-only: a row-level-role-only change repaints exactly one row');

    # (b) span-only: the OUTER cell role and the concatenated cell text are
    # both identical; only ONE span's role differs (the same visible text is
    # split across spans differently).
    my $cellC = tui::Frame::make_cell(
        [ { text => 'ab', role => 'label' }, { text => 'cd', role => 'body' } ], 'body', 4);
    my $cellD = tui::Frame::make_cell(
        [ { text => 'ab', role => 'muted' }, { text => 'cd', role => 'body' } ], 'body', 4);
    is($cellC->{text}, $cellD->{text},
        'AC-11 span-only setup: concatenated cell text is identical');
    is($cellC->{role}, $cellD->{role},
        'AC-11 span-only setup: row-level (cell) role is identical');
    isnt($cellC->{spans}[0]{role}, $cellD->{spans}[0]{role},
        "AC-11 span-only setup: only one span's role differs");

    my $footer4 = tui::Frame::make_cell('same', 'footer', 4);
    my $frameC = [ $footer4, $cellC ];
    my $frameD = [ $footer4, $cellD ];
    my $sdiff = Dashboard::render_frame($frameC, $frameD, { color => 0 });
    unlike($sdiff, qr/\e\[2J/, 'AC-11 span-only: same row count -> diff path, not a clear');
    my @smoves = ($sdiff =~ /\e\[(\d+);1H/g);
    is(scalar(@smoves), 1,
        "AC-11 span-only: a single span-level role change (outer role+text unchanged) still repaints exactly one row");
}

# ===========================================================================
# AC-13 -> DC-3 (multi-span): every colored row starts with the cursor-move
# + clear-to-EOL escape, has no further \e[K after that, and ends with
# either its own last span's text (empty SGR) or the SGR reset \e[0m
# (non-empty SGR) -- per S3.11's exact algorithm.
# ===========================================================================
{
    my @rows = (
        # exact-fit (no padding span) -- last span 'accent' has a non-empty SGR
        tui::Frame::make_cell(
            [ { text => 'AAA', role => 'label' }, { text => 'BBB', role => 'accent' } ],
            'body', 6),
        # exact-fit -- last span 'value' has an EMPTY SGR
        tui::Frame::make_cell(
            [ { text => 'CCC', role => 'strong' }, { text => 'DDD', role => 'value' } ],
            'body', 6),
        # exact-fit, three spans -- last span 'body' has an EMPTY SGR
        tui::Frame::make_cell(
            [ { text => 'E', role => 'good' }, { text => 'F', role => 'warn' }, { text => 'G', role => 'body' } ],
            'body', 3),
    );
    for my $i (0 .. $#rows) {
        my $row  = $i + 1;
        my $cell = $rows[$i];
        my $s    = Dashboard::_row_ansi($row, $cell, 1);
        my $prefix = "\e[${row};1H\e[K";
        is(substr($s, 0, length($prefix)), $prefix,
            "AC-13: row $row starts with the cursor-move + clear-to-EOL escape");
        my $after = substr($s, length($prefix));
        unlike($after, qr/\e\[K/,
            "AC-13: row $row has no further \\e[K after the initial clear");
        my $last_span = $cell->{spans}[-1];
        my $last_sgr  = Dashboard::sgr_for_role($last_span->{role});
        if ($last_sgr eq '') {
            my $want = $last_span->{text};
            is(substr($s, -length($want)), $want,
                "AC-13: row $row (last span role '$last_span->{role}', empty SGR) ends with its own text");
        } else {
            is(substr($s, -4), "\e[0m",
                "AC-13: row $row (last span role '$last_span->{role}', non-empty SGR) ends with the SGR reset");
        }
    }
}

# ===========================================================================
# AC-14 -> DC-4: sgr_for_role returns the exact pinned code for all 15 named
# roles, '' for body/blank, and '' for an unknown role and for undef.
# ===========================================================================
{
    # RETARGETED 2026-08-08 (package 06-dashboard-screen, driver ruling
    # 2026-08-08 -- "Theme wins", t/25:139 vs this file's mutual exclusion):
    # 'accent' is the ONE name that collides between the seventeen legacy
    # Dashboard roles (pinned here byte-identically) and Theme's nine
    # canonical roles (accent, rule, state.crit, state.idle, state.ok,
    # state.warn, text.faint, text.muted, text.primary -- spec S2.1).
    # sgr_for_role has exactly one caller in the whole repository,
    # Dashboard.pm:1914 on the render path, which per spec S2.1 now emits
    # Theme role names on every span -- so keeping legacy cyan for 'accent'
    # would render the title in the wrong colour once the render path is
    # Theme-driven. The implementer reorders sgr_for_role to resolve Theme
    # names first, falling through to the legacy branches for the other
    # fourteen names, which are NOT Theme names and are therefore unaffected
    # and stay pinned byte-identically -- their claim ("legacy names resolve
    # byte-identically") is untouched. Only 'accent' moves out of the pinned
    # literal table into a derived expectation (Theme::sgr, never a pinned
    # truecolor literal, so this cannot silently drift from Theme's own
    # escape sequence).
    my %pinned = (
        'title'        => "\e[1;36m",
        'panel-title'  => "\e[1m",
        'footer'       => "\e[2m",
        'scrollhint'   => "\e[2m",
        'footer-alert' => "\e[1;33;41m",
        'footer-flash' => "\e[1;33m",
        'alert'        => "\e[1;37;41m",
        'label'        => "\e[2m",
        'muted'        => "\e[2m",
        'value'        => '',
        'strong'       => "\e[1m",
        'good'         => "\e[32m",
        'warn'         => "\e[33m",
        'bad'          => "\e[31m",
    );
    is(scalar(keys %pinned), 14, 'sanity: AC-14 fixture has all 14 byte-identical pinned legacy roles (accent moved to Theme::sgr)');
    for my $role (sort keys %pinned) {
        is(Dashboard::sgr_for_role($role), $pinned{$role},
            "AC-14: sgr_for_role('$role') == pinned SGR");
    }
    is(Dashboard::sgr_for_role('accent'), Theme::sgr('accent', undef),
        "AC-14: sgr_for_role('accent') == Theme::sgr('accent', undef) -- the collision resolves via Theme (driver ruling: Theme wins)");
    is(Dashboard::sgr_for_role('body'),  '', "AC-14: sgr_for_role('body') == '' (fall-through)");
    is(Dashboard::sgr_for_role('blank'), '', "AC-14: sgr_for_role('blank') == '' (fall-through)");
    is(Dashboard::sgr_for_role('nosuchrole'), '', 'AC-14: sgr_for_role(unknown role) == \'\'');
    is(Dashboard::sgr_for_role(undef), '', 'AC-14: sgr_for_role(undef) == \'\'');
}

# ===========================================================================
# AC-15 -> DC-4: glyph_table has (at least) the pinned entries at the
# pinned widths (was "exactly the 18 pinned entries" -- now 14, see the
# @GLYPHS migration comment above); _safe passes each glyph through
# byte-for-byte; an unlisted non-ASCII CHARACTER collapses to exactly one
# '?' (never one '?' per byte).
# ===========================================================================
{
    my $table = _dash_glyph_table();
    is(ref($table), 'HASH', 'AC-15: glyph_table() returns a hashref');

    # SUPERSEDED (s23): `is(scalar(keys %$table), 18, ...)`.
    #
    # That pinned the WHOLE SHAPE of a shared artifact: any later package adding
    # a glyph -- doing exactly what it was mandated to do -- turned this done
    # sibling red. A floor plus the per-glyph loop below carries the same
    # information without forbidding extension, since the loop already asserts
    # every glyph this package owns is present at its declared width. The
    # equality assertion was therefore redundant as well as harmful.
    cmp_ok(scalar(keys %$table), '>=', scalar(@GLYPHS),
        'AC-15: glyph_table() carries at least this package\'s own glyphs (floor, not a pin)');
    for my $g (@GLYPHS) {
        my ($cp, $w, $group, $name) = @$g;
        my $decoded = chr($cp);
        my $bytes   = encode('UTF-8', $decoded);
        my $tag     = sprintf('U+%04X %s', $cp, $name);
        is($table->{$decoded}, $w, "AC-15: glyph_table()->{$tag} == $w");
        is(tui::Layout::glyph_width($decoded), $w, "AC-15: glyph_width(decoded $tag) == $w");
        is(tui::Layout::glyph_width($bytes),   $w, "AC-15: glyph_width(bytes $tag) == $w");
        is(Dashboard::_safe($decoded), $bytes,
            "AC-15: _safe(decoded $tag) passes the glyph through byte-for-byte");
        is(Dashboard::_safe($bytes), $bytes,
            "AC-15: _safe(bytes $tag) passes the glyph through byte-for-byte");
    }
    is(tui::Layout::glyph_width('z'), undef, 'AC-15: glyph_width of a non-glyph char -> undef');

    # unlisted non-ASCII CHARACTER -> exactly one '?' (not one per byte)
    my $unlisted       = "\x{4E16}";   # CJK "world", 3 UTF-8 bytes, not allow-listed
    my $unlisted_bytes = encode('UTF-8', $unlisted);
    is(Dashboard::_safe($unlisted), '?',
        'AC-15: _safe(unlisted decoded char U+4E16) == exactly one "?"');
    is(Dashboard::_safe($unlisted_bytes), '?',
        'AC-15: _safe(unlisted UTF-8 bytes U+4E16) == exactly one "?" (not one per byte)');

    my $safe_glyph = Dashboard::_safe("\x{1F7E2}");
    isnt($safe_glyph, '????', 'AC-15: _safe(green-circle) is NOT "????" (one glyph, not 4 bytes-as-?, regardless of allow-list status)');
    # RETARGETED 2026-08-08 (package 06-dashboard-screen, driver scope grant
    # E-B): green-circle is no longer allow-listed (Obligation 3), so _safe
    # now collapses it to a single '?' instead of passing it through.
    is($safe_glyph, '?',
        'AC-15: _safe(green-circle) is now exactly "?" (was a byte-for-byte pass-through -- no longer allow-listed, Decision 11: no emoji)');
}

# ===========================================================================
# RETIRED FROM AC-2/AC-15's PINNED-GLYPH FIXTURE (package 06-dashboard-screen,
# 2026-08-08, driver scope grant E-B): the four status-circle emoji that used
# to sit in @GLYPHS at width 2. Obligation 3 (spec 06 S2.2) deletes them from
# the glyph table outright -- they are not "resized", they are GONE: Theme.pm
# never declared them (Decision 11 forbids emoji) and _dash_glyph_table()
# now derives from Theme::glyphs() instead of its own legacy %GLYPH_TABLE.
#
# The claim AC-2/AC-15's per-glyph loop made about these four rows ("this is
# a pinned glyph, its declared width holds, and it round-trips through _safe
# unchanged") is no longer TRUE of them -- they are not pinned any more, so
# there is nothing left to differential a width against. The claim that DOES
# still hold, and is asserted here instead, is exactly the "unlisted
# character" contract AC-15 already proves for U+4E16 above: an unlisted
# character measures via the generic single-width fallback, is reported
# absent from glyph_table()/glyph_width(), and is replaced by _safe with
# exactly one '?'. Subject moved (pinned glyph -> unlisted glyph), claim
# held (their AC-2/AC-15 coverage is not silently lost).
# ===========================================================================
{
    my @RETIRED = (
        [0x1F7E2, 'green circle'],
        [0x1F534, 'red circle'],
        [0x1F7E1, 'yellow circle'],
        [0x26AA,  'white circle'],
    );
    for my $g (@RETIRED) {
        my ($cp, $name) = @$g;
        my $decoded = chr($cp);
        my $bytes   = encode('UTF-8', $decoded);
        my $tag     = sprintf('U+%04X %s', $cp, $name);

        # display_width: spec 06 S2.2 states plainly they "now measure 1"
        # (the generic single-width fallback for an unlisted character) --
        # a stated consequence of Obligation 3, not a guess.
        is(Dashboard::display_width($decoded), 1,
            "AC-2 RETARGETED: display_width(decoded $tag) == 1 (no longer in the glyph table, Obligation 3)");
        is(Dashboard::display_width($bytes), 1,
            "AC-2 RETARGETED: display_width(UTF-8 bytes $tag) == 1 (no longer in the glyph table, Obligation 3)");
        is(Dashboard::display_width($decoded), Dashboard::display_width($bytes),
            "AC-2 RETARGETED: decoded and byte forms of $tag still agree (the encoding contract survives the migration)");

        # glyph_table()/glyph_width(): the glyph is gone, not resized
        # (Behavior 3).
        my $table = _dash_glyph_table();
        ok(!exists $table->{$decoded},
            "AC-15 RETARGETED: glyph_table() no longer contains $tag (Behavior 3)");
        is(tui::Layout::glyph_width($decoded), undef,
            "AC-15 RETARGETED: glyph_width(decoded $tag) == undef (no longer declared)");
        is(tui::Layout::glyph_width($bytes), undef,
            "AC-15 RETARGETED: glyph_width(bytes $tag) == undef (no longer declared)");

        # _safe: an unlisted character collapses to exactly one '?', the
        # same contract already proven for U+4E16 above -- never a
        # byte-for-byte pass-through any more (Decision 11: no emoji).
        is(Dashboard::_safe($decoded), '?',
            "AC-15 RETARGETED: _safe(decoded $tag) == '?' (no longer allow-listed)");
        is(Dashboard::_safe($bytes), '?',
            "AC-15 RETARGETED: _safe(bytes $tag) == '?' (no longer allow-listed)");
    }
}

# ===========================================================================
# AC-16 -> DC-2, DC-5: a container panel line's cell role is 'body'; its
# text is unchanged from the pre-s04 ASCII content. Plus a byte-identical
# regression guard for the pinned S3.11/S3.12 algorithm.
# RETARGETED by s06-panel-semantics (2026-07-28): the exact-span-count
# assertion below now expects the 6-span per-field shape (indent, label,
# value, gap, glyph+status, trailing pad) that s06's own done-criterion #1
# mandates for this same container line — see t/41-panel-semantics.t AC1/AC5
# for the superseding, per-field oracle. Every other assertion in this block
# (row role, indent span, spans_text invariant, no-ESC invariant) still holds
# unchanged and is untouched.
#
# RE-RETARGETED 2026-08-08 (package 06-dashboard-screen, driver scope grant
# E-B/E-D; precedent: the driver's own Ruling 2 for the structurally
# identical case in t/41's AC5, "composed container line -> the header
# row"). Package 06 deletes the Sandbox panel outright (spec 06 S2.4.3):
# "container" is no longer a panel body row at all -- it is header material
# ("<container> [<status>]", right-justified). There is therefore no
# "container : claude-demo..." body row left to find. The SAME move the
# driver ruled for t/41's AC5 is applied here:
#   (a) "the container fact reaches the frame" -> now asserted against the
#       HEADER row (frame->[0]{text}), not a panel body row. Claim held.
#   (b) the structural regression checks this block also made (row role,
#       2-space indent span, spans_text invariant, no-ESC invariant) are
#       properties of ANY row()-composed panel body row, not specifically
#       of "container" -- re-pointed onto the Run panel's "heartbeat" row
#       (spec 06 S2.4.3's Run-panel row list: "heartbeat, uptime,
#       busy-lease, ..."), a row this design still produces. Role literal
#       'body' moves to 'text.primary' per spec 06 S2.1's mapping table
#       ("panel-title, value, strong, body, blank -> text.primary"),
#       confirmed against tui::Screen.pm's _render_panel (a read-only,
#       spec-named module, tui/Screen.pm:77-91): an ordinary panel line
#       defaults to cell role 'text.primary', with a leading 2-space indent
#       span also of role 'text.primary'.
#   (c) the EXACT 6-span shape ("indent, label, value, gap, glyph+status,
#       pad") was itself specific to the OLD bespoke Sandbox container-row
#       builder, deleted along with the panel -- it cannot be re-derived
#       without inventing an implementation detail this spec does not
#       state, and this file's own prior comment already treats the exact
#       shape as t/41-panel-semantics.t's claim to keep ("the superseding,
#       per-field oracle"), not this file's. RETIRED here, not silently
#       dropped: replaced with a floor (>= 2 spans: the indent plus at
#       least one content span), which is the one shape fact spec 06
#       S2.4.9's row() genuinely guarantees. Decision 15 (no whole-shape
#       pins) independently disfavours re-pinning an exact count anyway.
# ===========================================================================
{
    # -- (a) the container fact now reaches the frame via the HEADER row --
    my %mini_state = (
        project_name => 'demo',
        container    => 'claude-demo-abcd1234',
        status       => 'running',
        beat_age     => 12,
        uptime       => 3660,
        events       => [],
    );
    my $frame = Dashboard::compose_frame(\%mini_state, 24, 80);
    my $header_row = $frame->[0];
    ok($header_row, 'AC-16 setup: compose_frame produced a header row');
    like($header_row->{text}, qr/\Qclaude-demo-abcd1234\E/,
        "AC-16 RETARGETED: the container fact reaches the frame via the header row (Sandbox panel deleted, spec 06 S2.4.3)")
        if $header_row;

    # -- (b)/(c) structural regression guard, re-pointed onto the Run
    # panel's still-current "heartbeat" row instead of the deleted
    # container row --
    my ($body_row) = grep { $_->{text} =~ /heartbeat/ } @$frame;
    ok($body_row, "AC-16 setup RETARGETED: found the Run panel's heartbeat body row in the composed frame");
  SKIP: {
        skip 'AC-16 structural checks require the heartbeat body row to exist', 6
            unless $body_row;
        is($body_row->{role}, 'text.primary',
            "AC-16 RETARGETED: a row()-composed panel line's row role is 'text.primary' (was 'body' -- spec 06 S2.1)");
        cmp_ok(scalar(@{ $body_row->{spans} }), '>=', 1,
            'AC-16 RETARGETED: the row has at least one content span (exact 6-span shape retired -- see comment above; Decision 15)');
        # THE TWO-SPACE BODY INDENT IS GONE (tui::Screen::BODY_INDENT, 0 since
        # 2026-08-25). It predated the panel grid: with no left edge of its own,
        # a panel needed the indent to tie its rows to the title above them.
        # Every panel has a real edge now -- a border, or the viewport -- so the
        # indent was two columns of nothing on every row of every panel.
        #
        # Derived from the constant rather than deleted, so this assertion goes
        # on meaning something if the indent ever comes back.
        require tui::Screen;
        my $indent = tui::Screen::BODY_INDENT();
        if ($indent > 0) {
            is($body_row->{spans}[0]{text}, ' ' x $indent, "AC-16: first span is the ${indent}-space body indent");
            is($body_row->{spans}[0]{role}, 'text.primary', "AC-16: indent span role is 'text.primary'");
        } else {
            isnt($body_row->{spans}[0]{text}, '  ',
                'AC-16: no leading indent span -- content starts at the panel edge (BODY_INDENT is 0)');
            like($body_row->{spans}[0]{text}, qr/\S/,
                'AC-16: the first span carries content, not padding');
        }
        is(Dashboard::spans_text($body_row->{spans}), $body_row->{text},
            "AC-16: spans_text(cell->{spans}) eq cell->{text}");
        unlike($body_row->{text}, qr/\e/, 'AC-16: cell text contains no ESC (INV-4)');
    }

    # -- byte-identical regression guard, independent of any panel-layout
    # specifics: derived purely from the pinned S3.11/S3.12 algorithm --
    my @rows = (
        tui::Frame::make_cell('Row One', 'body',   10),
        tui::Frame::make_cell('Row Two', 'footer', 10),
    );
    my $out = Dashboard::render_frame(undef, \@rows, { color => 0 });
    my $expected = "\e[?2026h" . "\e[2J\e[H"
        . "\e[1;1H\e[K" . $rows[0]{text}
        . "\e[2;1H\e[K" . $rows[1]{text}
        . "\e[?2026l";
    is($out, $expected,
        'AC-16 regression: color=>0 full-redraw output is byte-identical to the pinned S3.11/S3.12 algorithm');
}

# ===========================================================================
# AC-18 -> DC-2, DC-5: the module's doc header no longer claims the old
# "plain ASCII ... length == display width" model; it must mention
# display_width instead. The SOURCE FILE is grepped here, at test RUN time
# (never read by the test-writer), so this stays a spec-only check.
# ===========================================================================
{
    my $module_path = "$Bin/../../scripts/Dashboard.pm";
    my $opened = open(my $fh, '<', $module_path);
    ok($opened, 'AC-18 setup: Dashboard.pm is readable for the doc-header check')
        or diag("could not open $module_path: $!");
    if ($opened) {
        my @header;
        for (1 .. 40) {
            my $line = <$fh>;
            last unless defined $line;
            push @header, $line;
        }
        close $fh;
        my $header_text = join('', @header);
        unlike($header_text, qr/length.{0,15}==.{0,15}display[\s_-]*width/is,
            'AC-18: doc header no longer claims "length == display width"');
        like($header_text, qr/display_width/,
            'AC-18: doc header mentions display_width as the measure');
    }
}

# ===========================================================================
# AC-19 -> DC-1, DC-4: INV-3 as a property test over a fixed corpus of >= 12
# strings -- pins display_width and _safe to the single shared _strip_sgr
# grammar (S3.0).
# ===========================================================================
{
    my @corpus = (
        [ 'ABC 123 pure ascii',          'pure ASCII' ],
        [ encode('UTF-8', "\x{1F7E2}"),  'allow-listed glyph (bytes)' ],
        [ "\x{1F7E2}",                   'allow-listed glyph (decoded)' ],
        [ "e\x{301}",                    'combining sequence (e + acute)' ],
        [ "\e[32mok\e[0m",               'full SGR sequence' ],
        [ "\e[32",                       'incomplete escape' ],
        [ "\e[2J",                       'CSI, not SGR' ],
        [ "\e",                          'lone ESC' ],
        [ "a\tb",                        'embedded TAB' ],
        [ "\xFF\xFE",                    'invalid UTF-8' ],
        [ "caf\xC3\xA9",                 'UTF-8 cafe bytes' ],
        [ "\x{4E16}",                    'unlisted wide char' ],
        [ '',                            'empty string' ],
        [ undef,                         'undef' ],
    );
    is(scalar(@corpus), 14, 'sanity: AC-19 corpus has >= 12 elements (14)');
    for my $c (@corpus) {
        my ($s, $label) = @$c;
        my $dw_s      = Dashboard::display_width($s);
        my $safe_s    = Dashboard::_safe($s);
        my $dw_safe_s = Dashboard::display_width($safe_s);
        is($dw_safe_s, $dw_s,
            "AC-19: display_width(_safe($label)) == display_width($label)");
        my $safe_safe_s = Dashboard::_safe($safe_s);
        is($safe_safe_s, $safe_s,
            "AC-19: _safe(_safe($label)) eq _safe($label) (idempotent)");
        unlike($safe_s, qr/[\x00-\x1F\x7F]/,
            "AC-19: _safe($label) contains no control byte (< 0x20 or DEL)");
    }
}

done_testing();
