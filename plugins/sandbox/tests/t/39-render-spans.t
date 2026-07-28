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
use Test::More;
use Encode qw(encode);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# Fixture: the pinned glyph table (spec S3.2) -- codepoint, expected column
# width, group, human name. Shared by AC-2 and AC-15.
# ===========================================================================
my @GLYPHS = (
    [0x1F7E2, 2, 'status',  'green circle'],
    [0x1F534, 2, 'status',  'red circle'],
    [0x1F7E1, 2, 'status',  'yellow circle'],
    [0x26AA,  2, 'status',  'white circle'],
    [0x280B,  1, 'spinner', 'braille dots-1'],
    [0x2819,  1, 'spinner', 'braille dots-2'],
    [0x2839,  1, 'spinner', 'braille dots-3'],
    [0x2838,  1, 'spinner', 'braille dots-4'],
    [0x283C,  1, 'spinner', 'braille dots-5'],
    [0x2834,  1, 'spinner', 'braille dots-6'],
    [0x2826,  1, 'spinner', 'braille dots-7'],
    [0x2827,  1, 'spinner', 'braille dots-8'],
    [0x2807,  1, 'spinner', 'braille dots-9'],
    [0x280F,  1, 'spinner', 'braille dots-10'],
    [0x2588,  1, 'gauge',   'full block'],
    [0x2591,  1, 'gauge',   'light shade'],
    [0x25B2,  1, 'scroll',  'up triangle'],
    [0x25BC,  1, 'scroll',  'down triangle'],
);
is(scalar(@GLYPHS), 18, 'sanity: glyph fixture carries all 18 pinned entries');

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
is(Dashboard::display_width("\x{26AA}\x{FE0F}"), 2,
    'AC-3: white-circle + VS16 (U+FE0F) == 2 (VS16 is zero-width)');

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
        { text => "\x{1F7E2}", role => 'accent'  },   # 2-column glyph
        { text => 'cd',        role => 'body'   },
    ];
    for my $cols (1, 2, 3, 10, 40, 80, 120) {
        my $cell = Dashboard::make_cell($mixed_line, 'body', $cols);
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
# ===========================================================================
{
    my $glyph_bytes = encode('UTF-8', "\x{1F7E2}");
    my $line = 'a' . "\x{1F7E2}";                # decoded width 1 + 2 = 3
    my $cell = Dashboard::make_cell($line, 'body', 2);   # the cut lands mid-glyph
    is(Dashboard::display_width($cell->{text}), 2,
        'AC-7: mid-glyph truncation still yields exactly $w == 2 columns');
    is($cell->{text}, 'a ',
        'AC-7: the straddling glyph is dropped and replaced by one pad space ("a ")');
    unlike($cell->{text}, qr/\Q$glyph_bytes\E/,
        "AC-7: the dropped glyph's own UTF-8 bytes are wholly absent from the result");
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
        push @rows, Dashboard::make_cell(
            [ { text => 'foo', role => 'label' }, { text => "\x{1F7E2}", role => 'accent' } ],
            'body', 20);
        push @rows, Dashboard::make_cell(
            [ { text => 'bar', role => 'value' }, { text => 'baz', role => 'muted' } ],
            'body', 20);
        push @rows, Dashboard::make_cell('plain footer row', 'footer', 20);
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
    my $cellA = Dashboard::make_cell($fixed_span, 'body',  3);   # exact fit, no pad
    my $cellB = Dashboard::make_cell($fixed_span, 'alert', 3);
    is_deeply($cellA->{spans}, $cellB->{spans},
        'AC-11 role-only setup: spans array is identical between the two cells');
    is($cellA->{text}, $cellB->{text},
        'AC-11 role-only setup: cell text is identical between the two cells');
    isnt($cellA->{role}, $cellB->{role},
        'AC-11 role-only setup: only the row-level (cell) role differs');

    my $footer3 = Dashboard::make_cell('same', 'footer', 3);
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
    my $cellC = Dashboard::make_cell(
        [ { text => 'ab', role => 'label' }, { text => 'cd', role => 'body' } ], 'body', 4);
    my $cellD = Dashboard::make_cell(
        [ { text => 'ab', role => 'muted' }, { text => 'cd', role => 'body' } ], 'body', 4);
    is($cellC->{text}, $cellD->{text},
        'AC-11 span-only setup: concatenated cell text is identical');
    is($cellC->{role}, $cellD->{role},
        'AC-11 span-only setup: row-level (cell) role is identical');
    isnt($cellC->{spans}[0]{role}, $cellD->{spans}[0]{role},
        "AC-11 span-only setup: only one span's role differs");

    my $footer4 = Dashboard::make_cell('same', 'footer', 4);
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
        Dashboard::make_cell(
            [ { text => 'AAA', role => 'label' }, { text => 'BBB', role => 'accent' } ],
            'body', 6),
        # exact-fit -- last span 'value' has an EMPTY SGR
        Dashboard::make_cell(
            [ { text => 'CCC', role => 'strong' }, { text => 'DDD', role => 'value' } ],
            'body', 6),
        # exact-fit, three spans -- last span 'body' has an EMPTY SGR
        Dashboard::make_cell(
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
        'accent'       => "\e[36m",
    );
    is(scalar(keys %pinned), 15, 'sanity: AC-14 fixture has all 15 pinned roles');
    for my $role (sort keys %pinned) {
        is(Dashboard::sgr_for_role($role), $pinned{$role},
            "AC-14: sgr_for_role('$role') == pinned SGR");
    }
    is(Dashboard::sgr_for_role('body'),  '', "AC-14: sgr_for_role('body') == '' (fall-through)");
    is(Dashboard::sgr_for_role('blank'), '', "AC-14: sgr_for_role('blank') == '' (fall-through)");
    is(Dashboard::sgr_for_role('nosuchrole'), '', 'AC-14: sgr_for_role(unknown role) == \'\'');
    is(Dashboard::sgr_for_role(undef), '', 'AC-14: sgr_for_role(undef) == \'\'');
}

# ===========================================================================
# AC-15 -> DC-4: glyph_table has exactly the 18 pinned entries at the
# pinned widths; _safe passes each glyph through byte-for-byte; an unlisted
# non-ASCII CHARACTER collapses to exactly one '?' (never one '?' per byte).
# ===========================================================================
{
    my $table = Dashboard::glyph_table();
    is(ref($table), 'HASH', 'AC-15: glyph_table() returns a hashref');
    is(scalar(keys %$table), 18, 'AC-15: glyph_table() has exactly 18 entries');
    for my $g (@GLYPHS) {
        my ($cp, $w, $group, $name) = @$g;
        my $decoded = chr($cp);
        my $bytes   = encode('UTF-8', $decoded);
        my $tag     = sprintf('U+%04X %s', $cp, $name);
        is($table->{$decoded}, $w, "AC-15: glyph_table()->{$tag} == $w");
        is(Dashboard::glyph_width($decoded), $w, "AC-15: glyph_width(decoded $tag) == $w");
        is(Dashboard::glyph_width($bytes),   $w, "AC-15: glyph_width(bytes $tag) == $w");
        is(Dashboard::_safe($decoded), $bytes,
            "AC-15: _safe(decoded $tag) passes the glyph through byte-for-byte");
        is(Dashboard::_safe($bytes), $bytes,
            "AC-15: _safe(bytes $tag) passes the glyph through byte-for-byte");
    }
    is(Dashboard::glyph_width('z'), undef, 'AC-15: glyph_width of a non-glyph char -> undef');

    # unlisted non-ASCII CHARACTER -> exactly one '?' (not one per byte)
    my $unlisted       = "\x{4E16}";   # CJK "world", 3 UTF-8 bytes, not allow-listed
    my $unlisted_bytes = encode('UTF-8', $unlisted);
    is(Dashboard::_safe($unlisted), '?',
        'AC-15: _safe(unlisted decoded char U+4E16) == exactly one "?"');
    is(Dashboard::_safe($unlisted_bytes), '?',
        'AC-15: _safe(unlisted UTF-8 bytes U+4E16) == exactly one "?" (not one per byte)');

    my $safe_glyph = Dashboard::_safe("\x{1F7E2}");
    isnt($safe_glyph, '????', 'AC-15: _safe(green-circle) is NOT "????" (one glyph, not 4 bytes-as-?)');
    is($safe_glyph, encode('UTF-8', "\x{1F7E2}"),
        'AC-15: _safe(green-circle) is the 4 raw UTF-8 bytes of U+1F7E2');
}

# ===========================================================================
# AC-16 -> DC-2, DC-5: a plain-string panel line composes to the 2-span
# shape [{'  ','body'}, {<sanitized text + pad>, <row role>}]; its cell role
# is 'body'; its text is unchanged from the pre-s04 ASCII content. Plus a
# byte-identical regression guard for the pinned S3.11/S3.12 algorithm.
# ===========================================================================
{
    # -- structural shape, via compose_frame + a known ASCII panel value --
    my %mini_state = (
        project_name => 'demo',
        container    => 'claude-demo-abcd1234',
        status       => 'running',
        beat_age     => 12,
        uptime       => 3660,
        events       => [],
    );
    my $frame = Dashboard::compose_frame(\%mini_state, 24, 80);
    my ($body_row) = grep { $_->{text} =~ /container : claude-demo/ } @$frame;
    ok($body_row, 'AC-16 setup: found the plain-string container body row in the composed frame');
  SKIP: {
        skip 'AC-16 structural checks require the container body row to exist', 6
            unless $body_row;
        is($body_row->{role}, 'body', "AC-16: plain-string panel line's row role is 'body'");
        is(scalar(@{ $body_row->{spans} }), 2,
            'AC-16: plain-string panel line composes to exactly 2 spans (indent + text)');
        is($body_row->{spans}[0]{text}, '  ', 'AC-16: first span is the 2-space body indent');
        is($body_row->{spans}[0]{role}, 'body', "AC-16: indent span role is 'body'");
        is(Dashboard::spans_text($body_row->{spans}), $body_row->{text},
            "AC-16: spans_text(cell->{spans}) eq cell->{text}");
        unlike($body_row->{text}, qr/\e/, 'AC-16: cell text contains no ESC (INV-4)');
    }
    like($body_row->{text}, qr/container : claude-demo-abcd1234/, "AC-16: text unchanged from pre-s04 ASCII content")
        if $body_row;

    # -- byte-identical regression guard, independent of any panel-layout
    # specifics: derived purely from the pinned S3.11/S3.12 algorithm --
    my @rows = (
        Dashboard::make_cell('Row One', 'body',   10),
        Dashboard::make_cell('Row Two', 'footer', 10),
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
