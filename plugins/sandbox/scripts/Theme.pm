package Theme;
use strict;
use warnings;
use Encode ();   # core; used only for UTF-8 encoding of declared glyphs

# =============================================================================
# Theme.pm -- the single source of colour and glyph truth for every ccpraxis
# terminal surface (statusline, Dashboard, beacon, launcher). A call site
# never sees a hex literal or a raw SGR escape: it names a semantic ROLE
# (Theme::sgr / Theme::paint) or a GLYPH NAME (Theme::glyph / glyph_width)
# and gets back an escape string or UTF-8 bytes for the terminal's detected
# capability.
#
# This package changes NO rendering by itself (blueprint unified-tui-design-
# system, package 02-design-tokens). Nothing consumes it yet; adoption is
# packages 05 (render library), 09 (beacon) and 10 (statusline rebuild),
# which is also the package that writes the GENERATED block this module's
# generated_block()/generated_markers() describe (see "THE GENERATED BLOCK"
# below).
#
# -----------------------------------------------------------------------
# THE REFERENCE BACKGROUND -- an assumption, not a measurement
# -----------------------------------------------------------------------
# A terminal exposes no portable way to query its own background colour, and
# this design system paints FOREGROUNDS ONLY -- it never repaints the
# background, because in a terminal (unlike a GUI toolkit) there is no alpha
# channel and the background belongs to the user's own theme, not to us.
#
# So every contrast guarantee in this module is measured against a STATED,
# DOCUMENTED reference background: #1E1E1E (30, 30, 30) -- see
# reference_background() below. That value is not a guess: it is chosen to
# be the LIGHTEST background this design system claims to support (VS Code
# Dark+'s "soft black"; Windows Terminal's default #0C0C0C and pure #000000
# are both darker). Because contrast against a fixed foreground is
# monotonically DEcreasing as the background gets lighter, every ratio this
# module asserts against #1E1E1E is a lower bound on the ratio the SAME
# foreground would achieve against any darker background, pure black
# included. Passing here implies passing there.
#
# What happens if the user's actual terminal background is lighter than
# #1E1E1E -- i.e. a light-theme terminal? The contrast guarantee simply does
# not hold for that user: this foreground ramp was designed for dark mode,
# and on a light background the text will look washed out. That is a
# LEGIBILITY DEGRADATION, never a crash -- Theme neither detects nor adapts
# to the real background, and no code path in this module depends on the
# assumption being correct. (Spec §2.4.5, escalation E-6.)
#
# -----------------------------------------------------------------------
# NO EMOJI, EVER, IN THIS MODULE
# -----------------------------------------------------------------------
# Every glyph declared below is checked against a block-based emoji detector
# (mirrored, deliberately, in the test oracle) and none of them fall in an
# emoji range. Richer non-ASCII glyphs (box-drawing, geometric shapes,
# braille) are used freely -- only emoji are excluded. Surfaces that still
# carry emoji today (scripts/statusline.pl, Dashboard.pm, bp-statusline.pl)
# are a recorded, tracked debt for the packages that own those files; this
# module's own glyph table is clean on arrival.
#
# -----------------------------------------------------------------------
# DEGRADATION -- what "still renders legibly" means without colour
# -----------------------------------------------------------------------
# At the 'none' capability rung (no truecolor, no 256-colour, not even
# advertised) every semantic distinction this module's palette carries in
# COLOUR is also carried by a non-colour channel:
#   * the four state.* roles are distinguishable by GLYPH alone (four
#     pairwise-distinct status.* characters);
#   * the primary/secondary text distinction is carried by the SGR ATTRIBUTE
#     (attr(text.primary) differs from attr(text.muted): normal vs dim).
# One thing is DECLARED as a degradation, not asserted as preserved: the
# three-step neutral ramp (primary / muted / faint) collapses to two visible
# steps at 'none', because SGR has no third neutral attribute between normal
# and dim. attr(text.muted) and attr(text.faint) may therefore be equal.
# This is deliberate, not a defect (spec §2.3).
#
# -----------------------------------------------------------------------
# MODULE SHAPE (spec §2.0)
# -----------------------------------------------------------------------
#   * Core modules only -- no CPAN.
#   * No "use utf8" -- every glyph below is declared with a "\x{...}" escape,
#     which yields a decoded character in a non-utf8 source file. This is
#     the same convention Dashboard.pm's own glyph table uses.
#   * No top-level side effects: loading this file performs no I/O, opens no
#     file, spawns nothing, reads no environment variable, and emits nothing
#     to the terminal. The capability lookup below is the ONLY place the
#     process environment is consulted, and only on first call, never at
#     load. All token DATA tables (roles, glyphs) live inside memoized
#     builder functions rather than as top-level literals. NOTE (reviewer
#     S3, package 02-design-tokens): this shape is NOT forced by any
#     t/64-theme-tokens.t source scan -- B-A2 scans the whole file (not
#     scoped to top-level-only) for spawn/I/O constructs and use/require
#     targets, none of which a plain top-level hash literal would trip;
#     B-A3's top-level-only scan forbids just a reference to the process
#     environment hash, a console-output call, or a call into the ambient
#     capability lookup -- none of which a literal table trips either. A
#     prior version of this comment misattributed the shape to "the
#     oracle's B-A3 source scan" -- traced line-by-line, that claim does
#     not hold. The
#     real reason is simpler: keeping every table behind a builder means
#     nothing in this module is ever populated except by an explicit call,
#     which matches the "no top-level side effects" rule in spirit even for
#     data that would itself have been inert as a literal.
#
# -----------------------------------------------------------------------
# paint() SANITISES CALLER TEXT -- do not remove this as "unnecessary"
# -----------------------------------------------------------------------
# Theme::paint($role, $text) scrubs $text through _scrub() (below, near
# paint()'s definition) before emitting it, in BOTH the known-role and the
# unknown-role-passthrough arms. This mirrors, at the token layer, the
# INV-3 guarantee Dashboard.pm's _safe/_safe_char family already
# established for fit_spans/clip_pad -- see Dashboard.pm:279-299, and
# redteam-01.md MAJOR-2, which is the finding that closed this exact class
# of bug ONE layer down. paint() is the primitive packages 05/09/10 adopt
# wholesale for untrusted-ish strings (container names, git branches,
# blueprint/session names, file paths, transcript-derived labels) -- a
# bare concatenation here would silently reopen MAJOR-2 in the new
# canonical primitive (redteam.md H1, package 02-design-tokens).
# The guarantee: paint() output never carries a control byte (C0, DEL, C1),
# a raw ESC, a CSI or OSC sequence, or a zero-width/combining character
# that $text did not... in fact it MUST NOT carry any of those from $text,
# full stop -- deleted, never transformed into something else.
# The boundary: this guarantee is paint()'s alone. sgr() legitimately
# returns escape sequences by definition (that is its job), and a caller
# who hand-composes sgr($role) . $text . reset() instead of calling
# paint() gets NONE of this protection -- _scrub() only runs inside
# paint().
#   * Theme::display_width() is the one deliberate exception to "Theme
#     reimplements nothing": it is a THIN, LAZY delegation to
#     Dashboard::display_width -- lazy ("require Dashboard;" inside the
#     function body, not a top-level "use Dashboard") because package 06
#     later rewrites Dashboard.pm to consume Theme, and a compile-time "use"
#     in both directions would be a load cycle.
# =============================================================================

# ---------------------------------------------------------------------------
# THE REFERENCE BACKGROUND -- named, valued, documented (see header above).
# Value: #1E1E1E (30, 30, 30). Relative luminance ~= 0.01298.
# ---------------------------------------------------------------------------
use constant REFERENCE_BG => [30, 30, 30];

sub reference_background {
    return [ @{ +REFERENCE_BG } ];
}

# =============================================================================
# SEMANTIC ROLES (spec §2.1) -- the nine required roles, each with rgb /
# x256 / attr / class / meaning. Built lazily and memoized by _roles_data()
# below (see the MODULE SHAPE note above for why this lives inside a
# function rather than as a top-level literal).
# =============================================================================

my $ROLES_DATA;   # memoized canonical table; never populated at load time

# _roles_data() -- the canonical (NOT defensive-copy) role table. Every rgb
# value was chosen so that contrast_ratio(rgb, REFERENCE_BG) clears its
# class floor WITH margin (never exactly at the floor -- spec §2.4.6), and
# so the four accent-family roles named by accent_roles() share a common
# CIE L* well inside accent_lightness_band()'s tolerance (Decision 11:
# "accent hues at a common perceptual lightness so they read as one
# family"). The "ok" role's meaning is deliberately narrow: a healthy
# state, NEVER "a value is present" -- that distinction is the fix for the
# collision the scout measured between Dashboard's ad-hoc "good" role and
# statusline's green (which meant both "usage is low" and "a git-ahead
# count is nonzero"). "A value is present" belongs to text.primary. This
# module can only STATE that rule (there are no call sites yet); enforcing
# it is packages 05/09/10 (spec E-4).
sub _roles_data {
    return $ROLES_DATA if $ROLES_DATA;
    $ROLES_DATA = {
        'text.primary' => {
            rgb     => [230, 230, 230],
            x256    => 254,
            attr    => '',
            class   => 'body',
            meaning => 'The value the user is here to read. Default foreground.',
        },
        'text.muted' => {
            rgb     => [148, 163, 184],
            x256    => 248,
            attr    => '2',
            class   => 'body',
            meaning => 'Labels and secondary metadata that frame a primary value.',
        },
        'text.faint' => {
            rgb     => [100, 116, 139],
            x256    => 243,
            attr    => '2',
            class   => 'large',
            meaning => 'Tertiary/inactive text: hints, ages, "not configured".',
        },
        'rule' => {
            rgb     => [60, 70, 85],
            x256    => 238,
            attr    => '2',
            class   => 'decor',
            meaning => 'Separators, frame lines, gauge track. Carries no fact.',
        },
        'accent' => {
            rgb     => [66, 148, 250],
            x256    => 69,
            attr    => '1',
            class   => 'body',
            meaning => 'The one identifying/focused element: project, selection.',
        },
        'state.ok' => {
            rgb     => [26, 168, 74],
            x256    => 35,
            attr    => '1',
            class   => 'body',
            meaning => 'A healthy state. Never "a value is present".',
        },
        'state.warn' => {
            rgb     => [214, 128, 16],
            x256    => 172,
            attr    => '1',
            class   => 'body',
            meaning => 'A state that needs attention but still functions.',
        },
        'state.crit' => {
            rgb     => [255, 90, 90],
            x256    => 203,
            attr    => '1',
            class   => 'body',
            meaning => 'A failed or critical state.',
        },
        'state.idle' => {
            rgb     => [110, 126, 148],
            x256    => 244,
            attr    => '2',
            class   => 'large',
            meaning => 'Absent/not-configured/never-run -- distinguishable from broken.',
        },
    };
    return $ROLES_DATA;
}

sub roles {
    my $src = _roles_data();
    my %copy;
    for my $name (keys %$src) {
        my $rec = $src->{$name};
        $copy{$name} = {
            rgb     => [ @{ $rec->{rgb} } ],
            x256    => $rec->{x256},
            attr    => $rec->{attr},
            class   => $rec->{class},
            meaning => $rec->{meaning},
        };
    }
    return \%copy;
}

# accent_roles() -- the roles Decision 11's "common perceptual lightness"
# applies to. A literal list, not a filter over the role table: the accent
# FAMILY is a deliberate design choice (which roles read as "one family"),
# not a structural property every body-class role happens to share
# (text.primary and text.muted are body-class too, and are NOT part of it).
sub accent_roles {
    return ('accent', 'state.ok', 'state.warn', 'state.crit');
}

# accent_lightness_band() -- target and tolerance chosen so every role
# named by accent_roles() lies within it. Measured CIE L* against
# REFERENCE_BG: the accent role sits at roughly sixty-one, the healthy-state
# role a little under that, the attention-state role a little over, and the
# critical-state role in between -- a spread of well under one
# just-noticeable-difference, with generous headroom below the tolerance
# ceiling this function's contract allows (5.0).
sub accent_lightness_band {
    return { target => 61.0, tolerance => 1.0 };
}

# =============================================================================
# THE GLYPH TABLE (spec §2.5) -- every non-ASCII character this design
# system may use, each with a DECLARED (not computed) display width. Theme
# contains NO width logic of its own: it never inspects codepoint ranges,
# never consults combining-mark properties, never implements a wcwidth.
# display_width() below is a thin, lazy delegation to the one width
# implementation that already exists (Dashboard::display_width).
#
# Built lazily and memoized by _glyphs_data() below (see the MODULE SHAPE
# note near the top of this file). The first nineteen entries are the
# spec's required minimum set. The ten "spinner.N" entries exist ONLY so
# this table is a superset of Dashboard::glyph_table()'s non-emoji entries
# at the same declared widths (spec §2.5's completeness rule) -- Dashboard's
# own glyph table carries ten braille spinner frames this table must also
# name.
#
# NO EMOJI: every codepoint below was checked against the emoji-range test
# in t/64-theme-tokens.t's own detector (mirroring spec §2.6.1) and none
# match. The Miscellaneous Symbols and Dingbats blocks in particular are
# off-limits to this design system.
# =============================================================================

my $GLYPHS_DATA;   # memoized canonical table; never populated at load time

sub _glyphs_data {
    return $GLYPHS_DATA if $GLYPHS_DATA;

    my %source = (
        'rule.h'      => { cp => 0x2500, desc => 'light horizontal rule / frame top' },
        'rule.v'      => { cp => 0x2502, desc => 'light vertical rule / frame edge' },
        'corner.tl'   => { cp => 0x250C, desc => 'frame corner, top-left' },
        'corner.tr'   => { cp => 0x2510, desc => 'frame corner, top-right' },
        'corner.bl'   => { cp => 0x2514, desc => 'frame corner, bottom-left' },
        'corner.br'   => { cp => 0x2518, desc => 'frame corner, bottom-right' },
        'sep.bar'     => { cp => 0xFF5C, desc => 'fullwidth vertical line, statusline segment separator', width => 2 },
        'sep.dot'     => { cp => 0x00B7, desc => 'middle dot, inline separator' },
        'gauge.full'  => { cp => 0x2588, desc => 'full block, meter fill' },
        'gauge.empty' => { cp => 0x2591, desc => 'light shade, meter track' },
        'scroll.up'   => { cp => 0x25B2, desc => 'black up-pointing triangle, scroll indicator' },
        'scroll.down' => { cp => 0x25BC, desc => 'black down-pointing triangle, scroll indicator' },
        'arrow.up'    => { cp => 0x2191, desc => 'upwards arrow, git-ahead count' },
        'arrow.down'  => { cp => 0x2193, desc => 'downwards arrow, git-behind count' },
        'cursor'      => { cp => 0x25B6, desc => 'black right-pointing triangle, selection cursor' },
        'status.ok'   => { cp => 0x25CF, desc => 'black circle -- healthy state, replaces an emoji circle' },
        'status.warn' => { cp => 0x25B3, desc => 'hollow up-pointing triangle -- attention state, replaces an emoji circle' },
        'status.crit' => { cp => 0x00D7, desc => 'multiplication sign -- critical state, replaces an emoji circle' },
        'status.idle' => { cp => 0x25CB, desc => 'white circle -- idle/absent state, replaces an emoji circle' },
        # Braille spinner frames -- present so this table is a superset of
        # Dashboard::glyph_table()'s non-emoji entries (spec §2.5
        # completeness rule). All width 1, matching Dashboard's own
        # declaration.
        'spinner.1'  => { cp => 0x280B, desc => 'braille spinner, frame 1 of 10' },
        'spinner.2'  => { cp => 0x2819, desc => 'braille spinner, frame 2 of 10' },
        'spinner.3'  => { cp => 0x2839, desc => 'braille spinner, frame 3 of 10' },
        'spinner.4'  => { cp => 0x2838, desc => 'braille spinner, frame 4 of 10' },
        'spinner.5'  => { cp => 0x283C, desc => 'braille spinner, frame 5 of 10' },
        'spinner.6'  => { cp => 0x2834, desc => 'braille spinner, frame 6 of 10' },
        'spinner.7'  => { cp => 0x2826, desc => 'braille spinner, frame 7 of 10' },
        'spinner.8'  => { cp => 0x2827, desc => 'braille spinner, frame 8 of 10' },
        'spinner.9'  => { cp => 0x2807, desc => 'braille spinner, frame 9 of 10' },
        'spinner.10' => { cp => 0x280F, desc => 'braille spinner, frame 10 of 10' },
    );

    my %built;
    for my $name (keys %source) {
        my $item  = $source{$name};
        my $char  = chr($item->{cp});
        my $width = defined($item->{width}) ? $item->{width} : 1;
        $built{$name} = {
            cp    => $item->{cp},
            char  => $char,
            bytes => Encode::encode('UTF-8', $char),
            width => $width,
            desc  => $item->{desc},
        };
    }
    $GLYPHS_DATA = \%built;
    return $GLYPHS_DATA;
}

sub glyphs {
    my $src = _glyphs_data();
    my %copy;
    for my $name (keys %$src) {
        my $rec = $src->{$name};
        $copy{$name} = {
            cp    => $rec->{cp},
            char  => $rec->{char},
            bytes => $rec->{bytes},
            width => $rec->{width},
            desc  => $rec->{desc},
        };
    }
    return \%copy;
}

# glyph($name) / glyph_width($name) -- both return undef for an unknown
# name and NEVER die (redteam.md L7). A call site that feeds glyph_width's
# result into arithmetic (e.g. `$col += Theme::glyph_width($name)`) must
# default it (`// 1`) or a typo'd name silently mis-measures a layout
# instead of failing loudly.
sub glyph {
    my ($name) = @_;
    return undef unless defined $name;
    my $rec = _glyphs_data()->{$name};
    return undef unless $rec;
    return $rec->{bytes};
}

sub glyph_width {
    my ($name) = @_;
    return undef unless defined $name;
    my $rec = _glyphs_data()->{$name};
    return undef unless $rec;
    return $rec->{width};
}

# display_width($str) -- thin, LAZY delegation. The lazy require (rather
# than a top-level "use Dashboard") is load-bearing: package 06 rewrites
# Dashboard.pm to consume Theme, and a compile-time "use" in both
# directions would be a load cycle (spec §2.0 rule 4).
sub display_width {
    my ($str) = @_;
    require Dashboard;
    return Dashboard::display_width($str);
}

# =============================================================================
# COLOUR MATHS (spec §2.4) -- WCAG 2.1 relative luminance / contrast ratio,
# plus CIE L* for the accent-family lightness band. Written from scratch;
# nothing in the repo provided this before (scout Q14).
# =============================================================================

# _is_integer($v) -- true iff $v is defined and looks like a base-10
# integer (optionally negative). Used only for input validation below.
sub _is_integer {
    my ($v) = @_;
    return defined($v) && $v =~ /\A-?\d+\z/;
}

# _validate_rgb($rgb, $who) -- dies with a "Theme: " message unless $rgb is
# an arrayref of exactly three integers in 0..255. $who names the calling
# function, for a useful message.
sub _validate_rgb {
    my ($rgb, $who) = @_;
    die "Theme: ${who}: rgb must be an arrayref of exactly three integers 0..255\n"
        unless ref($rgb) eq 'ARRAY'
            && @$rgb == 3
            && !grep { !_is_integer($_) || $_ < 0 || $_ > 255 } @$rgb;
    return;
}

# _linearize($v) -- sRGB 8-bit channel (0..255) -> linear channel, per
# spec §2.4.1 / WCAG 2.1's relative-luminance definition.
sub _linearize {
    my ($v) = @_;
    my $c = $v / 255;
    return $c <= 0.04045 ? $c / 12.92 : (($c + 0.055) / 1.055)**2.4;
}

sub relative_luminance {
    my ($rgb) = @_;
    _validate_rgb($rgb, 'relative_luminance');
    my ($r, $g, $b) = @$rgb;
    return 0.2126 * _linearize($r) + 0.7152 * _linearize($g) + 0.0722 * _linearize($b);
}

sub contrast_ratio {
    my ($a, $b) = @_;
    _validate_rgb($a, 'contrast_ratio');
    _validate_rgb($b, 'contrast_ratio');
    my $ya = relative_luminance($a);
    my $yb = relative_luminance($b);
    my ($l1, $l2) = $ya >= $yb ? ($ya, $yb) : ($yb, $ya);
    return ($l1 + 0.05) / ($l2 + 0.05);
}

sub lstar {
    my ($rgb) = @_;
    _validate_rgb($rgb, 'lstar');
    my $Y = relative_luminance($rgb);
    my $f = $Y > (216 / 24389) ? $Y**(1 / 3) : ((841 / 108) * $Y + 4 / 29);
    return 116 * $f - 16;
}

# x256_rgb($index) -- the standard xterm-256 palette, closed formula, for
# indices 16..255 (the 16 system colours 0..15 are terminal-theme-dependent
# and have no fixed RGB, so they are excluded by contract -- spec §2.3).
sub x256_rgb {
    my ($index) = @_;
    die "Theme: x256_rgb: index must be an integer 16..255\n"
        unless _is_integer($index) && $index >= 16 && $index <= 255;
    if ($index <= 231) {
        my $n  = $index - 16;
        my $ri = int($n / 36);
        my $gi = int(($n % 36) / 6);
        my $bi = $n % 6;
        my $level = sub { my ($v) = @_; return $v == 0 ? 0 : 55 + 40 * $v; };
        return [ $level->($ri), $level->($gi), $level->($bi) ];
    }
    my $g = 8 + 10 * ($index - 232);
    return [ $g, $g, $g ];
}

# =============================================================================
# THE CALL-SITE API (spec §2.2) -- sgr / reset / paint. A call site names
# only a role or a glyph name; it never sees a hex literal.
# =============================================================================

sub sgr {
    my ($role, $cap) = @_;
    return '' unless defined($role) && length($role);
    my $rec = _roles_data()->{$role};
    return '' unless $rec;
    $cap = capability() unless defined $cap;
    if ($cap eq 'truecolor') {
        my ($r, $g, $b) = @{ $rec->{rgb} };
        return "\e[38;2;$r;$g;${b}m";
    }
    if ($cap eq '256') {
        return "\e[38;5;$rec->{x256}m";
    }
    # 'none', or any unrecognised capability string -- treated as 'none'.
    return $rec->{attr} eq '' ? '' : "\e[$rec->{attr}m";
}

# named `reset` deliberately -- shadows the core `reset` builtin inside this
# package. Harmless today (Theme has no exporter), but never export it bare:
# an importer's own unqualified `reset()` call would silently become this
# SGR string instead of the builtin. paint() below calls it fully-qualified
# (Theme::reset()) for exactly this reason (redteam.md L4).
sub reset {
    return "\e[0m";
}

# _scrub($text) -- paint()'s sanitiser. See the "paint() SANITISES CALLER
# TEXT" header note above for the guarantee and its boundary; this is the
# implementation. Deliberately conservative: every dangerous byte sequence
# is DELETED, never transformed into something else, and clean text passes
# through byte-for-byte unchanged (paint(role,'x') still equals
# sgr(role).'x'.reset() -- the oracle's B-B8 identity holds because 'x' has
# nothing for this function to remove).
#
# Order matters: complete CSI and OSC sequences are stripped as WHOLE units
# first (steps 1-2), so a caller cannot end up with the escape gone but its
# parameter/URL payload left behind as literal visible text (which would
# both leak the payload and desynchronise Theme::display_width()'s column
# count from what paint() actually emits -- the H1 width invariant).
# Step 3 catches a bare/dangling ESC that did not form a full CSI/OSC.
# Step 4 removes the remaining C0 controls (NUL, bare CR, BEL, ...) and DEL.
# Steps 1-4 are ASCII-only (every byte they match is <0x80), so they behave
# identically whether $t is a raw byte string or an upgraded Perl character
# string -- UTF-8 represents an ASCII byte as itself in either
# representation, so there is nothing encoding-specific to get wrong here.
#
# C1 CONTROLS (U+0080-U+009F) ARE FULLY IN SCOPE -- NOT "harmless high
# characters". On any terminal honouring 8-bit controls, every codepoint in
# this range is a live single-BYTE control in its own right, not merely
# something that becomes dangerous once UTF-8 encoded: U+009B is the
# single-byte CSI introducer, byte-for-byte equivalent to the two-byte
# "ESC '['" step 1 already strips (so "before" . chr(0x9B) . "2Jafter" is
# still a screen-clear on such a terminal); U+009D/U+009C/U+0090/U+0085 are
# likewise OSC/ST/DCS/NEL. This is the C1 half of the exact leak
# Dashboard.pm's _safe/_safe_char family already closed one layer down
# (Dashboard.pm:279-299's own comment names it "the live-C1/control-byte
# leak", redteam-01.md MAJOR-2, INV-3) -- paint() reopening it here would be
# the same bug one layer up (redteam.md H1).
#
# THE THIRD DEFECT IN THIS AREA, and why the rest of this comment exists:
# round 1 stripped C1 only as its UTF-8-ENCODED two-byte form (0xC2 0x80-
# 0x9F); round 2 added a bare ordinal strip s/[\x80-\x9f]//g to also catch a
# RAW SINGLE C1 BYTE (chr(0x9B) with no "use utf8" in effect -- this module
# has none, see the MODULE SHAPE note near the top -- is stored as exactly
# one byte equal to its own ordinal). That ordinal strip is CORRECT for a
# genuine Perl CHARACTER string, where every character is one array slot and
# an ordinal in 0x80-0x9F can only ever be a real C1 codepoint. It is
# DESTRUCTIVE for a Perl BYTE string carrying UTF-8-ENCODED text, because a
# multi-byte character's CONTINUATION bytes legitimately occupy that same
# 0x80-0x9F ordinal range: e.g. U+2026 encodes as E2 80 A6, and E2 80
# (which is 0x80, matched and deleted by the blind ordinal strip) leaves
# only A6 behind -- a corrupted, undecodable remnant. A byte whose ordinal
# is 0x80-0x9F is therefore AMBIGUOUS on its own: it means "C1 control" in
# a character string and "possibly just a continuation byte" in a byte
# string, and the two are indistinguishable by ordinal value alone -- only
# by knowing which representation the whole string is in. Blindly reusing
# one policy for both, as round 2 did, is the bug.
#
# So: normalise to CHARACTER representation before applying the C1/zero-
# width ordinal policy (steps 5-6 below), then return the result in the
# SAME representation the caller handed us, via three cases:
#   - Already a Perl character string (utf8::is_utf8 true): apply the
#     character-level policy directly (_scrub_chars) -- no conversion
#     needed. This is the case the round-2 character-mode C1 sweep proves
#     and remains untouched.
#   - A raw byte string that IS valid UTF-8: this is Dashboard.pm's
#     calling convention (Encode::encode('UTF-8', $out) at Dashboard.pm:313,
#     encoded spans pushed at :446/:461 -- package 06 wiring Dashboard to
#     Theme is exactly where this fires). Decode it, apply the SAME
#     character-level policy, then re-encode -- this is the fix.
#   - A raw byte string that is NOT valid UTF-8 (not decodable text at all
#     -- e.g. a lone C1 byte with no multi-byte context, which is what the
#     byte-mode C1 sweep corpus exercises): fall back to the byte-ordinal
#     strip (_scrub_bytes, round 1/2's approach). This remains correct
#     precisely because a byte that cannot be part of valid UTF-8 is, by
#     definition, not a legitimate multi-byte character's continuation
#     byte, so deleting it by raw ordinal cannot corrupt one.
#
# paint() must never die on untrusted input (it renders arbitrary caller
# labels), so the UTF-8 validity probe below is a non-throwing eval, and
# invalid input simply takes the conservative byte-level branch rather than
# propagating an error.
sub _scrub {
    my ($t) = @_;
    return '' unless defined $t;

    # 1. Complete CSI sequences: ESC '[' parameter-bytes intermediate-bytes
    #    final-byte. Covers SGR (final 'm') and every other CSI final byte
    #    this module must never let through: cursor motion, screen/line
    #    erase, DECSET/DECRST, etc.
    $t =~ s/\x1b\[[0-9:;<=>?]*[\x20-\x2f]*[\x40-\x7e]//g;

    # 2. Complete OSC sequences: ESC ']' ... terminated by BEL or ST
    #    (ESC '\'). Covers OSC 8 hyperlinks, OSC 0/2 title-set, OSC 52
    #    clipboard writes.
    $t =~ s/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)//g;

    # 3. Any ESC that did not form a recognised CSI/OSC sequence above (a
    #    bare ESC, or a truncated/malformed escape) -- delete outright.
    $t =~ s/\x1b//g;

    # 4. Remaining C0 controls (incl. NUL, bare CR, BEL, tab, LF) and DEL.
    $t =~ s/[\x00-\x1f\x7f]//g;

    # 5-6 (C1 controls + zero-width/invisible-formatting/combining chars):
    # representation-dispatched -- see the policy comment above.
    if (utf8::is_utf8($t)) {
        $t = _scrub_chars($t);
    } else {
        my $decoded = eval { Encode::decode('UTF-8', $t, Encode::FB_CROAK) };
        if (defined $decoded) {
            $t = Encode::encode('UTF-8', _scrub_chars($decoded));
        } else {
            $t = _scrub_bytes($t);
        }
    }

    return $t;
}

# _scrub_chars($t) -- CHARACTER-level half of _scrub()'s steps 5-6: $t must
# already be a Perl character string (utf8::is_utf8 true, or plain ASCII
# where byte/character is moot). Strips C1 controls and zero-width /
# invisible-formatting / combining characters by CODEPOINT ORDINAL. Perl's
# \x{...} regex escape always matches by character ordinal regardless of
# the subject string's internal UTF8 flag, so this is unambiguous as long
# as the caller has already ensured $t is a character string (never a raw
# UTF-8-encoded byte string, where these same ordinals can be continuation
# bytes of a different, legitimate character -- see the policy comment on
# _scrub() above for why that distinction matters).
sub _scrub_chars {
    my ($t) = @_;

    # C1 controls, U+0080-U+009F.
    $t =~ s/[\x{80}-\x{9f}]//g;

    # Zero-width / invisible-formatting / combining characters: ZWSP/ZWNJ/
    # ZWJ/LRM/RLM (U+200B-200F), directional embedding/override marks
    # (U+202A-202E), word joiner and invisible operators (U+2060-2064),
    # BOM/ZWNBSP (U+FEFF), variation selectors (U+FE00-FE0F), and the
    # combining-marks block (U+0300-036F).
    $t =~ s/[\x{200b}-\x{200f}]//g;
    $t =~ s/[\x{202a}-\x{202e}]//g;
    $t =~ s/[\x{2060}-\x{2064}]//g;
    $t =~ s/\x{feff}//g;
    $t =~ s/[\x{fe00}-\x{fe0f}]//g;
    $t =~ s/[\x{0300}-\x{036f}]//g;

    return $t;
}

# _scrub_bytes($t) -- BYTE-level half of _scrub()'s steps 5-6, used only
# when $t is a raw byte string that does NOT decode as valid UTF-8 (so it
# cannot safely be reinterpreted as characters -- see the policy comment on
# _scrub() above). This is round 1/2's original approach, preserved
# unchanged for that one narrower case: strip the UTF-8 TWO-BYTE encoding
# of a C1 control (e.g. 0xC2 0x9B for U+009B) and of each zero-width class
# as a whole byte-sequence unit first, then delete any remaining lone byte
# whose ordinal falls in C1's range. Safe here specifically because $t is
# NOT valid UTF-8 overall, so a byte in 0x80-0x9F cannot be a continuation
# byte of a legitimate multi-byte character in THIS string.
sub _scrub_bytes {
    my ($t) = @_;

    $t =~ s/\xc2[\x80-\x9f]//g;
    $t =~ s/\xe2\x80[\x8b-\x8f]//g;
    $t =~ s/\xe2\x80[\xaa-\xae]//g;
    $t =~ s/\xe2\x81[\xa0-\xa4]//g;
    $t =~ s/\xef\xbb\xbf//g;
    $t =~ s/\xef\xb8[\x80-\x8f]//g;
    $t =~ s/\xcc[\x80-\xbf]//g;
    $t =~ s/\xcd[\x80-\xaf]//g;
    $t =~ s/[\x80-\x9f]//g;

    return $t;
}

sub paint {
    my ($role, $text) = @_;
    return '' unless defined($text) && length($text);
    my $safe = _scrub($text);
    return '' unless length($safe);
    if (defined($role) && exists _roles_data()->{$role}) {
        return sgr($role) . $safe . Theme::reset();
    }
    return $safe;
}

# =============================================================================
# CAPABILITY DETECTION AND DEGRADATION (spec §2.3)
# =============================================================================

# detect_capability(\%env) -- PURE function of the passed hashref. Ladder
# evaluated in this exact order, first match wins. Never touches the real
# process environment itself (that is the capability lookup's job, below).
sub detect_capability {
    my ($env) = @_;
    die "Theme: detect_capability: env must be a hashref\n" unless ref($env) eq 'HASH';

    return 'none' if exists $env->{NO_COLOR};

    if (defined($env->{CCPRAXIS_COLOR})
        && $env->{CCPRAXIS_COLOR} =~ /\A(truecolor|256|none)\z/) {
        # Return the MATCHED literal ($1), never the raw env value (redteam.md
        # L3): safe today only because the regex is \A..\z-anchored so the two
        # are byte-identical, but returning the match keeps that true even if
        # the anchoring is ever loosened later.
        return $1;
    }

    if (!defined($env->{TERM}) || $env->{TERM} eq '' || $env->{TERM} eq 'dumb') {
        return 'none';
    }

    if (defined($env->{COLORTERM}) && $env->{COLORTERM} =~ /\A(?:truecolor|24bit)\z/i) {
        return 'truecolor';
    }

    if (defined($env->{WT_SESSION}) && length($env->{WT_SESSION})) {
        return 'truecolor';
    }

    if ($env->{TERM} =~ /(?:\A|-)direct(?:\z|-)/) {
        return 'truecolor';
    }

    if ($env->{TERM} =~ /256/) {
        return '256';
    }

    return 'none';
}

my $CAPABILITY_MEMO;   # set only inside the lookup function below, never at load time

# The ambient capability lookup, memoized after the first call. This is the
# ONLY function in this module that reads the real process environment, and
# it happens on call, never at load (spec §2.3).
sub capability {
    $CAPABILITY_MEMO = detect_capability(\%ENV) unless defined $CAPABILITY_MEMO;
    return $CAPABILITY_MEMO;
}

# _reset_capability_memo -- clears the memo so the NEXT ambient lookup
# re-derives from the live process environment (redteam.md L2).
# Underscore-private: for tests, and for a future re-init path (e.g. a
# long-lived TUI reacting to a terminal/session change), not for ordinary
# call sites.
sub _reset_capability_memo {
    undef $CAPABILITY_MEMO;
    return;
}

# =============================================================================
# THE GENERATED BLOCK (spec §2.7) -- the statusline drift guard's canonical
# output. Package 10 embeds generated_block()'s exact text, between the two
# marker lines generated_markers() returns, into scripts/statusline.pl; the
# guard in t/64-theme-tokens.t regenerates this payload in memory and
# compares it byte-for-byte against what is on disk.
# =============================================================================

sub generated_markers {
    return {
        begin => '# >>> BEGIN GENERATED FROM Theme.pm -- DO NOT EDIT BY HAND >>>',
        end   => '# <<< END GENERATED FROM Theme.pm <<<',
    };
}

# generated_block() -- deterministic, LF-only, byte-exact payload per spec
# §2.7.2's grammar. Every role in roles() appears in all three hashes, in
# sort (ASCII-betical) order of role name.
sub generated_block {
    my $roles_data = _roles_data();
    my @sorted     = sort keys %$roles_data;

    my $s = "# THEME TOKENS -- generated from plugins/sandbox/scripts/Theme.pm.\n";
    $s .= "# Regenerate: perl -Iplugins/sandbox/scripts -MTheme -e " . '"print Theme::generated_block()"' . "\n";

    $s .= "my \%THEME_RGB = (\n";
    for my $role (@sorted) {
        my ($r, $g, $b) = @{ $roles_data->{$role}{rgb} };
        $s .= "  '$role' => [$r,$g,$b],\n";
    }
    $s .= ");\n";

    $s .= "my \%THEME_X256 = (\n";
    for my $role (@sorted) {
        $s .= "  '$role' => $roles_data->{$role}{x256},\n";
    }
    $s .= ");\n";

    $s .= "my \%THEME_ATTR = (\n";
    for my $role (@sorted) {
        $s .= "  '$role' => '$roles_data->{$role}{attr}',\n";
    }
    $s .= ");\n";

    return $s;
}

1;
