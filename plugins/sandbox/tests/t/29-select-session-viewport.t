#!/usr/bin/env perl
# Unit tests for the select-session.pl picker's viewport + display helpers —
# the pure functions behind the scrolling TUI fix. The TUI render loop itself
# needs a real TTY (covered by attended live-checks), but its load-bearing
# logic is pure and testable by `require`-ing the script (its main flow is
# guarded by `unless (caller)`):
#
#   scroll_window  — keeps the selection inside a screen-sized window so a long
#                    list never overflows / pollutes scrollback.
#   clip_visible   — clips each row to the terminal width (ANSI-aware, byte-
#                    conservative) so no row wraps and desyncs the redraw.
#   sanitize_cell  — strips terminal-control bytes from attacker-influenceable
#                    session previews before they're rendered.
#   build_options  — "Start a new session" is always option 0; previews are
#                    sanitized into the label.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $script = "$Bin/../../scripts/select-session.pl";
ok(-f $script, 'select-session.pl exists') or BAIL_OUT("script missing");

# Requiring the script must NOT run its main flow (it would call exit). The
# `unless (caller)` guard makes this safe and exposes the helpers in main::.
require $script;
pass('require did not run main() — caller guard holds');

# Strip ANSI to recover the visible payload of a clipped row.
sub visible { my $s = shift; $s =~ s/\e\[[0-9;]*[A-Za-z]//g; return $s; }

# ---------------------------------------------------------------------
# scroll_window($top, $sel, $cap, $n)
# ---------------------------------------------------------------------
is(scroll_window(0,  3, 10, 5),  0,  'list fits in window -> top stays 0');
is(scroll_window(5,  6,  3, 20), 5,  'selection already visible -> no scroll');
is(scroll_window(0,  9,  3, 20), 7,  'selection below window -> scroll down to show it');
is(scroll_window(7,  2,  3, 20), 2,  'selection above window -> scroll up to show it');
is(scroll_window(0, 19,  3, 20), 17, 'End: last item -> window pinned to the bottom');
is(scroll_window(17, 0,  3, 20), 0,  'Home: first item -> window back to the top');
is(scroll_window(100,19, 3, 20), 17, 'out-of-range top clamps to max_top');
is(scroll_window(0,  5,  1, 20), 5,  'cap=1: window tracks selection exactly');
is(scroll_window(-5,-3,  0, 20), 0,  'garbage inputs clamp safely to 0');

# Invariant sweep: for any selection, the chosen window must contain it.
{
    my $bad = 0;
    my ($cap, $n) = (5, 37);
    my $max_top = $n > $cap ? $n - $cap : 0;
    my $top = 0;
    for my $sel (0 .. $n - 1) {
        $top = scroll_window($top, $sel, $cap, $n);
        $bad++ unless $sel >= $top && $sel <= $top + $cap - 1;
        $bad++ if $top < 0 || $top > $max_top;
    }
    is($bad, 0, 'sweeping selection 0..n-1 always keeps it inside a valid window');
}

# ---------------------------------------------------------------------
# clip_visible($s, $width)
# ---------------------------------------------------------------------
is(visible(clip_visible("abcdefghij", 5)), "abcde", 'truncates to width visible cols');
is(visible(clip_visible("abc", 10)),       "abc",   'shorter than width -> unchanged');
is(visible(clip_visible("abc", 0)),        "",      'width 0 -> empty payload');
like(clip_visible("anything", 4), qr/\e\[0m\z/,     'always ends with a reset (no color bleed)');

# SGR escapes are preserved and cost zero columns.
{
    my $c = clip_visible("\e[1;36mABCDE\e[0m", 3);
    like($c, qr/\e\[1;36m/,         'SGR color sequence is preserved');
    is(visible($c), "ABC",          'SGR is zero-width: exactly 3 visible cols kept');
}

# Non-SGR control sequences are dropped entirely.
is(visible(clip_visible("a\e[2Jb", 10)), "ab", 'embedded non-SGR CSI (\\e[2J) is dropped');

# Bare C0 control bytes + DEL are stripped at the display seam (zero width), so
# an un-sanitized source (e.g. $PROJECT_LABEL) can't beep/overwrite/spoof.
is(visible(clip_visible("a\x07b\x0dc\x08d\x7fe", 10)), "abcde",
   'C0 (BEL/CR/BS) + DEL bytes are dropped by clip_visible');

# Width counted in BYTES -> multi-byte UTF-8 truncation is conservative; a row
# can never exceed the width and therefore never wraps.
{
    my $multibyte = "\xc3\xa9" x 10;     # ten "é" = 20 bytes
    my $vis = visible(clip_visible($multibyte, 5));
    ok(length($vis) <= 5, 'multi-byte payload clipped to <= width bytes (never wraps)');
}

# ---------------------------------------------------------------------
# sanitize_cell($s)
# ---------------------------------------------------------------------
is(sanitize_cell("a\x1bb"),  "ab",  'ESC (0x1b) stripped');
is(sanitize_cell("a\x07b"),  "ab",  'BEL (0x07) stripped');
is(sanitize_cell("a\x7fb"),  "ab",  'DEL (0x7f) stripped');
is(sanitize_cell("a\tb\nc"), "abc", 'TAB/newline stripped');
is(sanitize_cell("caf\xc3\xa9"), "caf\xc3\xa9", 'printable multi-byte UTF-8 preserved');
{
    my $dirty = join('', map { chr } 0 .. 0x1f) . "ok\x7f";
    my $clean = sanitize_cell($dirty);
    unlike($clean, qr/[\x00-\x1f\x7f]/, 'no control bytes survive sanitize');
    is($clean, "ok", 'only printable payload remains');
}

# ---------------------------------------------------------------------
# build_options(@sessions) — "new" first + preview sanitized into the label
# ---------------------------------------------------------------------
{
    my @opts = build_options();
    is($opts[0]{action}, 'NEW', 'option 0 is always "Start a new session" (NEW)');
}
{
    my $sess = {
        uuid    => 'abcd1234-1111-2222-3333-444455556666',
        mtime   => 1_700_000_000,
        size    => 10,
        cwd     => '/project',
        preview => "fix\x1bthe\x07bug",     # contains ESC + BEL injection bytes
    };
    my @opts = build_options($sess);
    is(scalar @opts, 2,                  'one NEW + one session => 2 options');
    is($opts[0]{action}, 'NEW',          'NEW still first when sessions exist');
    like($opts[1]{action}, qr/^RESUME abcd1234-/, 'session yields RESUME <uuid>');
    unlike($opts[1]{label}, qr/\x1b/,    'no ESC byte survives into the session label');
    unlike($opts[1]{label}, qr/[\x00-\x08\x0e-\x1f\x7f]/, 'no control bytes in the label');
    like($opts[1]{label}, qr/fixthebug/, 'preview text preserved minus the control bytes');
}
{
    # A preview that is *only* control bytes collapses to the no-preview marker.
    my $sess = {
        uuid    => '99999999-0000-0000-0000-000000000000',
        mtime   => 1_700_000_000,
        size    => 1,
        cwd     => '/p',
        preview => "\x1b\x07\x00",
    };
    my @opts = build_options($sess);
    like($opts[1]{label}, qr/\(no preview\)/, 'all-control preview => "(no preview)"');
}

# ---------------------------------------------------------------------
# plan_frame($rows, $n) — the frame must NEVER exceed the terminal height
# (otherwise it scrolls and reintroduces the bug), at any size, with cap >= 1.
# ---------------------------------------------------------------------
{
    my $overflow = 0;
    my $bad_cap  = 0;
    for my $rows (1 .. 40) {
        for my $n (0 .. 60) {
            my $L = plan_frame($rows, $n);
            my $max_height = $L->{head} + $L->{foot}
                           + ($L->{hints} ? 2 : 0) + $L->{cap};
            $overflow++ if $max_height > ($rows < 1 ? 1 : $rows);
            $bad_cap++  if $L->{cap} < 1;
        }
    }
    is($overflow, 0, 'plan_frame: frame height never exceeds the terminal at any size');
    is($bad_cap,  0, 'plan_frame: always leaves room for at least one option');
}
{
    # On a normal terminal the full chrome (title+rule+blank header, blank+keys
    # footer) is used; on a tiny one it degrades.
    my $big = plan_frame(40, 100);
    is($big->{head}, 3, 'normal terminal: full 3-row header');
    is($big->{foot}, 2, 'normal terminal: full 2-row footer');
    ok($big->{hints}, 'normal terminal with overflow: hints reserved');
    my $small = plan_frame(6, 100);
    ok($small->{head} <= 1, 'tiny terminal: header degraded');
    my $tiny = plan_frame(2, 100);
    ok($tiny->{head} + $tiny->{foot} + ($tiny->{hints} ? 2 : 0) + $tiny->{cap} <= 2,
       'rows=2: degenerate frame still fits');
}

# ---------------------------------------------------------------------
# json_unescape — decodes \uXXXX so control chars become real bytes (then
# stripped) and accented text renders, instead of literal backslash-u noise.
# ---------------------------------------------------------------------
# Build the \uXXXX sequences with chr(92) ("\") so no literal backslash-u token
# appears in this source (which would otherwise be transformed before it runs).
my $BS = chr(92);
is(json_unescape('hello world'), 'hello world', 'plain text passes through');
is(json_unescape("caf${BS}u00e9"), "caf\xc3\xa9", 'BMP escape decodes to UTF-8 "e-acute"');
is(sanitize_cell(json_unescape("a${BS}u001bb")), 'ab',
   'JSON-escaped ESC is decoded to a real byte then stripped by sanitize_cell');

done_testing();
