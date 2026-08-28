package Theme;
use strict;
use warnings;
use Encode ();   # core; used only for UTF-8 encoding of declared glyphs

# =============================================================================
# Theme.pm -- the single source of colour and glyph truth for every ccpraxis
# terminal surface (statusline, the sandbox dashboard, launcher). A call site
# never sees a hex literal or a raw SGR escape: it names a semantic ROLE
# (Theme::sgr / Theme::paint) or a GLYPH NAME (Theme::glyph / glyph_width)
# and gets back an escape string or UTF-8 bytes for the terminal's detected
# capability.
#
# This package changes NO rendering by itself (blueprint unified-tui-design-
# system, package 02-design-tokens). Nothing consumes it yet; adoption is
# packages 05 (render library) and 10 (statusline rebuild),
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
# NO EMOJI -- WITH ONE NARROW, DELIBERATE EXCEPTION (title.*)
# -----------------------------------------------------------------------
# Every glyph declared below is checked against a block-based emoji detector
# (mirrored, deliberately, in the test oracle) and none of them fall in an
# emoji range -- EXCEPT the title.* set, waived by operator decision on
# 2026-08-28.
#
# THE EXCEPTION IS SCOPED BY THE RULE'S OWN REASONING. This rule exists because
# emoji render inconsistently IN A TERMINAL: often double-width, often in
# colour, and at the mercy of the font stack. The title.* glyphs are the only
# ones that never reach a terminal -- they are the lead character of the OS
# WINDOW TITLE, drawn in the desktop's UI font, where these symbols are the
# recognisable ones and where the failure mode above does not arise.
#
# It is not a free pass -- a title.* glyph must still measure exactly one cell.
#
# TEXT PRESENTATION IS APPLIED BY THE TITLE BUILDER, NOT HERE, and the reason is
# worth recording because the obvious placement is wrong. These codepoints have
# emoji forms, so a U+FE0E variation selector is wanted to force the text form.
# Declaring it in this table looked right and broke the HEADER: glyphs from here
# pass through the render path's sanitiser, which strips zero-width and
# combining characters by design -- an invariant that exists to stop control
# sequences riding in on untrusted text -- so every affected glyph rendered as
# "?". The window title has no such sanitiser and is the only surface where the
# emoji form could appear, so the selector is appended there.
#
# Any glyph outside title.* is still held to the original rule. Richer non-ASCII glyphs (box-drawing, geometric shapes,
# braille) are used freely -- only emoji are excluded. Surfaces that still
# carry emoji today (scripts/statusline.pl, the sandbox dashboard module,
# bp-statusline.pl) are a recorded, tracked debt for the packages that own
# those files; this
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
#     the same convention the sandbox dashboard module's own glyph table uses.
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
# INV-3 guarantee the sandbox dashboard module's _safe/_safe_char family
# already established for fit_spans/clip_pad, and
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
#   * Theme::display_width() PREVIOUSLY existed here as a thin, lazy
#     delegation into the legacy sandbox dashboard's own width core. Package
#     06 (unified-tui-design-system) deleted it outright rather than
#     repointing it at tui::Layout: tui::Layout itself loads Theme at compile
#     time, so a repoint would only have traded one 2-cycle for another
#     (driver ruling E-F). display_width now lives at exactly one place,
#     tui::Layout::display_width -- callers here use that directly.
# =============================================================================

# ---------------------------------------------------------------------------
# THE REFERENCE BACKGROUND -- named, valued, documented (see header above).
# Value: #1E1E1E (30, 30, 30). Relative luminance ~= 0.01298.
# ---------------------------------------------------------------------------
use constant REFERENCE_BG => [30, 30, 30];

# SPINNER_FRAMES -- how many 'spinner.N' glyphs the table below declares, and
# therefore the period of the animation. PUBLIC: both renderers index the
# sequence modulo this, and neither may restate the number. See the block
# comment beside the spinner entries for why it is 8.
use constant SPINNER_FRAMES => 8;

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
# collision the scout measured between the sandbox dashboard's ad-hoc "good" role and
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
            meaning => 'Separators and frame lines. Carries no fact.',
        },
        # SPLIT OUT OF 'rule', which used to paint the gauge track too.
        #
        # A border and a gauge track look like the same job but are held to
        # different standards: a border only has to be visible against the
        # BACKGROUND, whereas a track also has to be distinguishable from the
        # FILL drawn in the same row. Sharing one token meant tuning either one
        # moved the other, and repainting 'rule' to fix a gauge would have
        # repainted every frame line on the screen.
        #
        # Measured, not eyeballed (WCAG relative luminance), against the
        # #1E1E1E background t/64 holds decor roles to:
        #
        #   x256  rgb        vs fill    vs bg     verdict
        #   ----  ---------  ---------  --------  -----------------------------
        #    236  (48)       4.30:1     1.263     below t/64's 1.5:1 decor floor
        #    237  (58)       3.71:1     1.466     below it -- first draft, red
        #    238  (68)       3.18:1     1.712     this
        #    239  (78)       2.71:1     2.003
        #
        # AND THE HONEST CONCLUSION: colour buys almost nothing here. The two
        # columns pull against each other, and t/64's floor -- correctly -- caps
        # how dark a track may go before it stops reading as a channel on a dark
        # terminal. 3.18:1 against the old shared 'rule' figure of 3.11:1 is
        # noise. "Very dark grey" is delivered as far as the floor allows and no
        # further; anyone tempted to push to 236 for more separation should read
        # the vs-bg column first.
        #
        # What actually separates fill from track is GLYPH WEIGHT -- heavy rule
        # against light rule -- which is why that pairing, not this colour, is
        # the fix for a gauge that read as one undifferentiated smear.
        #
        # This role therefore earns its place by DECOUPLING, not by its value: a
        # border and a track have different jobs, and sharing 'rule' meant a
        # gauge tweak repainted every frame line on the screen.
        #
        # attr is deliberately EMPTY rather than '2'. Dim is a terminal-defined
        # transform, so stacking it on an already-dark grey makes the rendered
        # result unpredictable and the numbers above meaningless.
        'gauge.track' => {
            rgb     => [68, 68, 68],
            x256    => 238,
            attr    => '',
            class   => 'decor',
            meaning => 'The unfilled portion of a meter. Carries no fact.',
        },

        # ------------------------------------------------------------------
        # THE GAUGE FILL RAMP -- Radix Colors, step 9, four steps.
        #
        # A PALETTE, NOT FOUR PICKED COLOURS. Radix step 9 is the one its
        # authors specify as the solid, high-chroma step intended for dark
        # backgrounds, so legibility here is a property of the system rather
        # than something tuned per colour and re-tuned whenever one changes.
        #
        # WHY NOT THE OBVIOUS SCIENTIFIC RAMPS. Viridis and Cividis are
        # perceptually uniform across their whole range -- INCLUDING the
        # near-black end a dark terminal cannot show. Measured against t/64's
        # own #1E1E1E reference: viridis #440154 is 1.09:1 and #414487 is
        # 1.91:1, so a gauge below about 40% would have been invisible.
        # ColorBrewer YlOrRd is the right idea inverted, brightest at LOW values
        # and darkest at critical (#BD0026, 2.53:1) -- backwards for a meter on
        # a dark ground. IBM's colourblind-safe set clears the contrast but is
        # CATEGORICAL, and using a categorical palette sequentially implies an
        # ordering it does not encode.
        #
        # Every step below clears 4.2:1 against that background in truecolour
        # and 4.5:1 through its 256-colour rung, which is why the x256 values
        # are recorded rather than left to a nearest-neighbour guess at runtime.
        #
        # SEPARATE FROM state.* ON PURPOSE. These are the same three ideas as
        # state.ok/warn/crit but they are not the same colours, and merging them
        # would mean a gauge tweak repainting every status glyph on the screen --
        # the same reasoning that split gauge.track out of rule.
        # THE WARNING OVERLAY -- the one role that owns its background.
        #
        # Operator, 2026-08-27: warnings should "actually appear on the footer of
        # the terminal, without moving anything, just overlay it on top of
        # whatever was in it before. Like it's a pop up... Dark red background
        # (very dark), light white foreground."
        #
        # Because it covers arbitrary content, its contrast is measured against
        # ITS OWN background and not reference_background(): #F5F5F5 on #3B0A0A
        # is 15.6:1, comfortably AAA. Darker reds score higher still but stop
        # reading as red; this is the point where it is unmistakably a red
        # surface and still far past the threshold.
        #
        # bg256 52 (#5F0000) is the nearest dark red the 256-colour cube has.
        # It is lighter than the truecolour value, so the fallback is checked on
        # its own terms: #F5F5F5 on #5F0000 is 12.96:1, still AAA.
        'overlay.warn' => {
            rgb     => [245, 245, 245],
            bg      => [59, 10, 10],
            x256    => 255,
            bg256   => 52,
            attr    => '1',
            class   => 'body',
            meaning => 'A dismissable warning overlaid on the footer. Owns its background.',
        },

        'gauge.low' => {
            rgb     => [0, 144, 255],
            x256    => 33,
            attr    => '',
            class   => 'body',
            meaning => 'Meter fill below half. Ample headroom.',
        },
        'gauge.mid' => {
            rgb     => [18, 165, 148],
            x256    => 36,
            attr    => '',
            class   => 'body',
            meaning => 'Meter fill from half to the warn threshold. Filling, still fine.',
        },
        'gauge.warn' => {
            rgb     => [247, 107, 21],
            x256    => 202,
            attr    => '',
            class   => 'body',
            meaning => 'Meter fill past the warn threshold. Needs attention, still functions.',
        },
        # Radix red STEP 10, not step 9. Step 9 (#E5484D) measures 4.26:1
        # against t/64's #1E1E1E reference and the floor for a `body` role is
        # 4.5:1, so the suite rejected it -- correctly, since this is the one
        # colour in the ramp that must never be the hard one to read. Step 10 is
        # the same hue one step lighter and clears it at 5.00:1. The other three
        # steps stay at 9; only the colour that failed moved.
        'gauge.crit' => {
            rgb     => [236, 93, 94],
            x256    => 203,
            attr    => '',
            class   => 'body',
            meaning => 'Meter fill past the critical threshold.',
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
        # bg/bg256 are copied ONLY when the role declares them, so a role
        # without a background has no such keys at all and callers can test
        # presence rather than having to compare against undef.
        #
        # They have to be exposed: sgr() emits a second SGR for these roles, and
        # a describe-the-table function that omitted the reason would leave the
        # oracle unable to tell a role that legitimately paints a background
        # from one that had sprouted a stray escape.
        if (ref($rec->{bg}) eq 'ARRAY') {
            $copy{$name}{bg}    = [ @{ $rec->{bg} } ];
            $copy{$name}{bg256} = $rec->{bg256};
        }
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
# Width MEASUREMENT lives at tui::Layout::display_width, which sources this
# very table (via glyphs() below) for its own width lookups (package 06,
# unified-tui-design-system) -- Theme declares identity and width; it never
# measures.
#
# Built lazily and memoized by _glyphs_data() below (see the MODULE SHAPE
# note near the top of this file). The first nineteen entries are the
# spec's required minimum set. The "spinner.N" entries exist ONLY so
# this table is a superset of the sandbox dashboard's own glyph table's
# non-emoji entries at the same declared widths (spec §2.5's completeness
# rule) -- the dashboard's own glyph table carries the braille spinner
# frames this table must also name. There are SPINNER_FRAMES of them; see
# the block comment beside them for why that number is what it is.
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
        # Junctions, for the panel grid (operator request, 2026-08-25): each
        # panel's title rule IS its top border, and horizontally-adjacent
        # panels share ONE column of vertical border rather than drawing two
        # against each other. Where a shared column begins below a title rule
        # that is a tee-down; where it also arrives from the band row above,
        # the same position is a cross. Nothing is drawn at the viewport edges.
        'tee.down'    => { cp => 0x252C, desc => 'light tee pointing down, panel-grid junction' },
        'tee.up'      => { cp => 0x2534, desc => 'light tee pointing up, panel-grid junction' },
        'cross'       => { cp => 0x253C, desc => 'light cross, panel-grid junction' },
        'tee.left'    => { cp => 0x2524, desc => 'light tee pointing left, panel-grid junction' },
        'tee.right'   => { cp => 0x251C, desc => 'light tee pointing right, panel-grid junction' },
        'sep.bar'     => { cp => 0xFF5C, desc => 'fullwidth vertical line, statusline segment separator', width => 2 },
        'sep.dot'     => { cp => 0x00B7, desc => 'middle dot, inline separator' },
        # The statusline's blueprint-count icon (2026-08-26). Declared HERE
        # because Theme is the single source of glyph truth and t/69's AC-S5
        # drift guard checks statusline.pl's inline width table against it --
        # a glyph that surface emits without an entry here is exactly what that
        # guard exists to catch. East-Asian-ambiguous, declared as one column.
        'icon.blueprints' => { cp => 0x29C9, desc => 'two joined squares, blueprint count' },
        'icon.todos'      => { cp => 0x22EE, desc => 'vertical ellipsis, todo count' },
        # THE GAUGE IS NOT A FULL-HEIGHT BLOCK (operator, 2026-08-26: "I want a
        # different usage bar foreground styling. Different colors and also
        # different character. Maybe doesn't need to be a solid block, could be
        # a slightly dithered one. Or maybe even something completely different
        # than the full height block. Can we have blocks that are not full
        # height?").
        #
        # Yes -- U+2581..U+2588 are the eighth-height ladder, and the answer to
        # the question is this pair. U+2584 (lower half block) fills the bottom
        # half of the cell, so the gauge sits ON the text baseline instead of
        # standing a full row tall next to it: the same information at roughly
        # half the visual weight, which is what "too distracting" was about.
        # U+2581 (lower one eighth) leaves a thin rule where the channel
        # continues, so the track reads as a channel rather than as more blocks.
        #
        # The dithered alternative the operator also floated is one line from
        # here -- U+2593 over U+2591 -- and was NOT chosen because a shade
        # pattern still occupies the full cell height, so it changes the texture
        # without changing the mass. Height is what carries the weight.
        # VERTICALLY CENTRED AND CONTIGUOUS, which is what the block elements
        # could not be. 0x2584/0x2581 sat on the cell's baseline, so the bar
        # read as a row of blocks resting on a floor rather than as a bar. Every
        # block-element fill is anchored to an edge (upper or lower) by
        # definition, so no choice within that family fixes it.
        #
        # These two are box-drawing rules: they occupy the cell's vertical
        # centre and span its full width, so consecutive cells fuse into one
        # continuous line instead of showing gaps. 0x2501 is the heaviest
        # centred horizontal rule in the BMP -- nothing in box-drawing is
        # thicker. Heavier exists only in Symbols for Legacy Computing
        # (0x1FB97), which was rejected: Theme::glyph() returns bytes
        # unconditionally with no font-capability fallback, a terminal cannot
        # detect whether a font has a glyph, and this ships into a container
        # image whose font is not ours to choose. Tofu would have no backstop.
        #
        # Contrast is carried by WEIGHT as well as colour: heavy fill against
        # light track, painted 'accent' against 'rule'.
        'gauge.full'  => { cp => 0x2501, desc => 'heavy horizontal rule, meter fill' },
        'gauge.empty' => { cp => 0x2500, desc => 'light horizontal rule, meter track' },
        # ------------------------------------------------------------------
        # WINDOW-TITLE LEAD CHARACTERS (operator selection, 2026-08-28).
        #
        # The title is the ONE string that renders in the desktop's UI font
        # rather than the terminal's, and it is truncated from the right in
        # every taskbar -- so the lead character is often all that survives.
        # These are the states it has to distinguish at one glyph.
        #
        # They live in Theme rather than inline in the window-title builder so
        # the glyph table stays the single source, and so that module needs no
        # non-ASCII bytes of its own.
        #
        # (The identifier of that module is deliberately not named here: t/64's
        # B-E7 cycle-closure guard scans this file's SOURCE for it, comments
        # included, because a back-edge that starts life in a comment is how the
        # last one came back.)
        #
        # 'title.gone' is NOT the same as 'title.exited', and the distinction is
        # the reason it earns a separate glyph: exited is a status podman
        # REPORTS, while gone is the launcher's own liveness probe having FAILED
        # to reach the container. One is being told, the other is trying and
        # not getting through.
        'title.needs'   => { cp => 0x203C, desc => 'double exclamation -- a decision is waiting on the operator' },
        'title.exited'  => { cp => 0x2716, desc => 'heavy multiplication x -- container exited or dead' },
        'title.paused'  => { cp => 0x23F8, desc => 'double vertical bar -- stopped, paused, created, restarting' },
        'title.gone'    => { cp => 0x26A0, desc => 'warning sign -- the container could not be reached' },

        'scroll.up'   => { cp => 0x25B2, desc => 'black up-pointing triangle, scroll indicator' },
        'scroll.down' => { cp => 0x25BC, desc => 'black down-pointing triangle, scroll indicator' },
        'arrow.up'    => { cp => 0x2191, desc => 'upwards arrow, git-ahead count' },
        'arrow.down'  => { cp => 0x2193, desc => 'downwards arrow, git-behind count' },
        'cursor'      => { cp => 0x25B6, desc => 'black right-pointing triangle, selection cursor' },
        'status.ok'   => { cp => 0x25CF, desc => 'black circle -- healthy state, replaces an emoji circle' },
        'status.warn' => { cp => 0x25B3, desc => 'hollow up-pointing triangle -- attention state, replaces an emoji circle' },
        'status.crit' => { cp => 0x00D7, desc => 'multiplication sign -- critical state, replaces an emoji circle' },
        'status.idle' => { cp => 0x25CB, desc => 'white circle -- idle/absent state, replaces an emoji circle' },
        # t03-activity-column: the truncation marker for a row that wrapped
        # past its cap. Declared HERE rather than written into tui/Frame.pm
        # because that module is held to an ASCII-only source rule
        # (t/65-tui-render-library.t AC-T2: no byte >= 0x80 and no \x{...}
        # escape >= 0x80), and this table's chr($cp) construction is the
        # mechanism that rule exists to funnel every glyph through.
        'ellipsis'    => { cp => 0x2026, desc => 'horizontal ellipsis -- a row was truncated past its wrap cap' },
        # Braille spinner frames -- present so this table is a superset of
        # the sandbox dashboard's glyph_table()'s non-emoji entries (spec
        # §2.5 completeness rule). All width 1, matching the dashboard's own
        # declaration.
        #
        # EVERY FRAME HAS THE SAME NUMBER OF DOTS (operator, 2026-08-25: "the
        # spinner has a different number of dots depending on the spinner step.
        # I wish all steps had the same number of dots").
        #
        # The old ten frames were the widely-copied "dots" sequence, whose dot
        # counts run 3,3,4,3,4,3,3,4,3,4 -- so the glyph does not merely rotate,
        # it PULSES, brighter on every second or third frame. That is a second
        # animation nobody asked for, riding on the one that is meant to be
        # there.
        #
        # These eight are a three-dot arc walked around the 8-dot braille ring.
        # The ring, in visual order, is dots 1,4,5,6,8,7,3,2 (down the right
        # column, back up the left); frame k lights ring positions k, k+1, k+2.
        # So each frame is exactly three dots, consecutive, and the sequence is
        # a smooth clockwise rotation that returns to its start -- the count is
        # constant BY CONSTRUCTION rather than by having been counted once.
        #
        # EIGHT, not ten, and that is forced rather than chosen: the ring has
        # eight positions, so a ten-frame cycle over it would have to repeat two
        # of them and the spinner would stutter twice per revolution. The frame
        # count is SPINNER_FRAMES, read by both callers; it is not a literal
        # anywhere outside this file.
        'spinner.1'  => { cp => 0x2819, desc => 'braille spinner, 3-dot arc, frame 1 of 8' },
        'spinner.2'  => { cp => 0x2838, desc => 'braille spinner, 3-dot arc, frame 2 of 8' },
        'spinner.3'  => { cp => 0x28B0, desc => 'braille spinner, 3-dot arc, frame 3 of 8' },
        'spinner.4'  => { cp => 0x28E0, desc => 'braille spinner, 3-dot arc, frame 4 of 8' },
        'spinner.5'  => { cp => 0x28C4, desc => 'braille spinner, 3-dot arc, frame 5 of 8' },
        'spinner.6'  => { cp => 0x2846, desc => 'braille spinner, 3-dot arc, frame 6 of 8' },
        'spinner.7'  => { cp => 0x2807, desc => 'braille spinner, 3-dot arc, frame 7 of 8' },
        'spinner.8'  => { cp => 0x280B, desc => 'braille spinner, 3-dot arc, frame 8 of 8' },
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

# display_width($str) DELETED (package 06, unified-tui-design-system, driver
# ruling E-F). It previously existed as a thin, lazy delegation into the
# legacy sandbox dashboard's own width core -- but tui::Layout (the module
# that took over that width core) itself loads Theme at compile time, so
# merely repointing this function at tui::Layout would only have traded one
# 2-cycle (Theme<->the sandbox dashboard) for another (Theme<->tui::Layout),
# not produced a DAG. Deleting it outright removes the last back-edge out of
# Theme; width measurement now lives at exactly one place,
# tui::Layout::display_width, and every caller (including the legacy
# dashboard module) calls that directly.

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

    # A ROLE MAY OWN ITS BACKGROUND, AND ALMOST NONE DO.
    #
    # The header of this module states that the design system paints
    # FOREGROUNDS ONLY, because a terminal has no alpha channel and the
    # background belongs to the user's theme. That rule stands, and the reason
    # it stands is what carves out the exception: it is about text drawn ON the
    # user's background.
    #
    # An OVERLAY is not that. It deliberately occludes whatever it covers, so it
    # has to supply its own background or it renders as light text sitting on
    # top of a resources gauge -- illegible, and indistinguishable from a
    # rendering fault. Its contrast is therefore measured against its OWN
    # background rather than reference_background(), which is the only honest
    # way to measure a surface the reference does not describe.
    #
    # A role without `bg` behaves exactly as before, byte for byte.
    my $bg = $rec->{bg};
    if ($cap eq 'truecolor') {
        my ($r, $g, $b) = @{ $rec->{rgb} };
        my $s = "\e[38;2;$r;$g;${b}m";
        $s .= "\e[48;2;$bg->[0];$bg->[1];$bg->[2]m" if ref($bg) eq 'ARRAY';
        return $s;
    }
    if ($cap eq '256') {
        my $s = "\e[38;5;$rec->{x256}m";
        $s .= "\e[48;5;$rec->{bg256}m" if ref($bg) eq 'ARRAY' && defined $rec->{bg256};
        return $s;
    }
    # 'none', or any unrecognised capability string -- treated as 'none'.
    # Reverse video is the only way to say "this is a surface, not text" with
    # no colour at all, and an overlay that vanished on a mono terminal would
    # be a warning nobody sees.
    return "\e[7m" if ref($bg) eq 'ARRAY';
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
# the sandbox dashboard module's _safe/_safe_char family already closed one
# layer down (that module's own comment names it "the live-C1/control-byte
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
#   - A raw byte string that IS valid UTF-8: this is the sandbox dashboard
#     module's calling convention (Encode::encode('UTF-8', $out) on its own
#     span text) -- package 06 wiring that module to Theme is exactly where
#     this fires). Decode it, apply the SAME character-level policy, then
#     re-encode -- this is the fix.
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
