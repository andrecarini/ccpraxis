# Dashboard.pm — the raw-ANSI TUI dashboard framework for `claude-sandbox` (B2).
#
# Decision #19: `claude-sandbox` (the only user-typed form) always lands HERE —
# a live dashboard, not a scrolling log. The dashboard is the manager window: it
# holds the container alive via the heartbeat (over the injected podman-exec
# seam) and exposes two hotkeys (Decision #18):
#   [c] launch-claude   — spawn a NEW terminal window running `claude-sandbox
#                         --session <project>` (the existing connector + session
#                         picker), with a wt.exe -> `start` -> in-window fallback
#                         ladder (Decision #19).
#   [s] shutdown-all    — write the fleet-wide graceful-shutdown signal
#                         (`runs/.shutdown` in every blueprint, consumed by the
#                         A4 gate).
#
# This module is split into a PURE core (layout / frame composition / render
# diff / key dispatch / spawn-argv / signal-path derivation — all unit-tested in
# tests/t/25-dashboard.t with no terminal) and a thin seam-injected loop
# (`run`). Every side effect the loop performs — heartbeat touch, container
# inspect, state gather, key read, terminal size, spawn, signal write, raw-mode
# enter/leave, output — is an injected coderef, so the loop itself is driven by
# the test harness with a fake clock and a scripted key queue.
#
# RENDER MODEL (the B0 carry-forward / flicker fix, extended by s04): never
# `\e[2J` per frame. Clear once on a full redraw (first frame or a resize), then
# update only the rows whose text changed via `\e[<row>;1H` + text + `\e[K`, with
# the whole burst wrapped in synchronized-output `\e[?2026h` … `\e[?2026l`.
#
# Composed rows are a STYLED-SPAN model (s04): a row is an ordered list of
# `{ text, role }` spans; a composed cell carries both the spans and their plain
# concatenation (`$cell->{text}`), fit to EXACTLY `display_width($cell->{text})
# == $cols` terminal display COLUMNS (measured by `display_width`, NOT byte
# `length` — a status dot / spinner / gauge glyph is 1-2 display columns but
# several UTF-8 bytes). Encoding rule: a string is treated as already-decoded
# characters iff it contains a codepoint > 0xFF; otherwise it is decoded
# leniently as UTF-8 (malformed bytes -> U+FFFD, never dies/warns). Every string
# the module returns is UTF-8 bytes (no `use utf8`, no `binmode`). Color is
# applied at render time per span by role (`sgr_for_role`). Rich panels /
# box-drawing are B3/B4's job.
#
# CALLER CONTRACT (D3): callers MUST pass UTF-8 BYTES, not already-decoded
# (wide-char) Perl strings. "Already decoded iff some codepoint > 0xFF" is a
# KNOWN, ACCEPTED source of imprecision for a genuinely-decoded string whose
# codepoints are all <= 0xFF: the 2-CHARACTER decoded string "\x{00C2}\x{00A9}"
# is re-read as the 2 BYTES 0xC2 0xA9, which happen to be valid UTF-8 for
# U+00A9 -- so display_width reports 1 instead of 2. This is cosmetic only
# (the row is still padded to exactly $cols; INV-1 holds, per an exhaustive
# sweep) and is deliberately NOT "fixed" by a smarter heuristic -- pass bytes
# in and the ambiguity never arises (s04 fix-batch, F8: see reviewer-01.md).
#
# Non-TTY / no-Term::ReadKey fallback is decided by `decide_mode`; launcher.pl
# keeps its proven plain heartbeat loop for that case (graceful degradation,
# Decision #19 / B0).
package Dashboard;
use strict;
use warnings;
use JSON::PP ();
use File::Spec ();
use Time::Local ();
use Time::HiRes ();
use Encode ();

# tui:: consumption (blueprint unified-tui-design-system, package
# 06-dashboard-screen, Obligations 1-3): the width core and the composed-
# frame content vocabulary now live in the shared render library / this
# module's own tui::DashboardScreen. The arrow points ONE way -- tui/*.pm
# never names this package (05's/06's AC-P4).
require tui::Layout;
require tui::DashboardScreen;
require tui::Frame;
require tui::Screen;
require Theme;

# ===========================================================================
# PURE CORE
# ===========================================================================

# decide_mode($is_tty, $readkey_ok, $force_plain) -> 'tui' | 'plain'
# The dashboard runs as a real TUI only on an interactive terminal with
# Term::ReadKey available and not explicitly forced off. Anything else (piped
# output, a dumb terminal, CCPRAXIS_NO_TUI) degrades to the plain loop.
sub decide_mode {
    my ($is_tty, $readkey_ok, $force_plain) = @_;
    return 'plain' if $force_plain;
    return 'plain' unless $is_tty;
    return 'plain' unless $readkey_ok;
    return 'tui';
}

# fmt_age($secs) -> compact human duration ("12s", "3m", "1h04m", "2d03h").
# undef / negative -> "n/a". DELEGATING ALIAS (blueprint unified-tui-design-
# system, package 06-dashboard-screen, criterion 4 -- "one duration format"):
# the grammar now lives at exactly one place, tui::DashboardScreen::
# fmt_duration; kept here so out-of-write-set callers (and every existing pin
# of this name) keep working unchanged.
sub fmt_age {
    my ($s) = @_;
    return tui::DashboardScreen::fmt_duration($s);
}

# ---------------------------------------------------------------------------
# s04-render-foundation: the styled-span line model + display-width core.
# See specs/01-render-foundation-spec.md S3 for the binding API contract.
# ---------------------------------------------------------------------------

# _decode_str($str) -> a CHARACTER string, per the D3 byte/character rule: a
# string is treated as already-decoded characters iff it contains at least one
# codepoint > 0xFF; otherwise it is decoded as UTF-8 leniently (malformed bytes
# become U+FFFD, one replacement per bad byte) -- never dies, never warns.
# PRIVATE, internal to the width/sanitize core.
#
# Perf note (F4, s04 fix-batch): this is a hand-rolled strict-UTF-8 chunker,
# NOT a loop of whole-string Encode::decode(..., FB_QUIET) retries. The prior
# implementation called Encode::decode on the (shrinking-by-one-byte) REMAINDER
# once per malformed byte; measured cost grows worse than linear in the number
# of bad bytes (an attacker-influenceable corrupted log line) because each
# retry's internal cost scales with the remaining buffer length, not just the
# one byte skipped. This version advances by matching the longest run of valid
# UTF-8 in ONE regex pass (one Encode::decode call per GOOD run, not per bad
# byte) and only steps a single byte at a time across genuinely malformed
# bytes -- linear in the input regardless of how bad bytes are distributed.
my $UTF8_CHAR_RE = qr/(?:
      [\x00-\x7F]
    | [\xC2-\xDF][\x80-\xBF]
    | \xE0[\xA0-\xBF][\x80-\xBF]
    | [\xE1-\xEC][\x80-\xBF]{2}
    | \xED[\x80-\x9F][\x80-\xBF]
    | [\xEE-\xEF][\x80-\xBF]{2}
    | \xF0[\x90-\xBF][\x80-\xBF]{2}
    | [\xF1-\xF3][\x80-\xBF]{3}
    | \xF4[\x80-\x8F][\x80-\xBF]{2}
)/x;
sub _decode_str {
    my ($str) = @_;
    return '' if !defined $str;
    return $str if $str =~ /[^\x00-\xFF]/;   # already decoded (D3)
    # MODULE-LOAD GUARD. This file's `require tui::Layout / tui::DashboardScreen
    # / Theme` are RUNTIME statements near the top, while $UTF8_CHAR_RE below is
    # assigned later -- and subs are installed at COMPILE time. So a failed
    # require (Theme.pm absent, say) aborts the load with every sub already in
    # the symbol table and this pattern still undef. A caller that wraps the
    # require in eval and then probes `defined &Dashboard::fit_spans` sees a
    # healthy-looking module and calls straight into here.
    #
    # That is not hypothetical: on 2026-08-08 it hung bp-statusline.pl -- exit
    # 124, 250 MB of stderr -- because an undef pattern makes the match below
    # `(?:)+`, which succeeds on the empty string, so $consumed was 0 and the
    # loop never advanced. Returning the bytes unchanged is the honest answer
    # when the decoder is unavailable: no spin, and no fabricated U+FFFD run
    # standing in for text nobody could actually decode.
    return $str if !defined $UTF8_CHAR_RE;
    my $bytes = $str;
    my $out = '';
    while (length $bytes) {
        # `length($1)` is load-bearing, not belt-and-braces: a zero-length match
        # consumes nothing, and a loop over a buffer that can consume nothing is
        # an infinite loop by construction. Any future edit that lets this
        # pattern match empty re-creates the hang above, so the guard is here
        # rather than in the caller.
        if ($bytes =~ /\A((?:$UTF8_CHAR_RE)+)/ && length($1)) {
            my $good = $1;
            # Measure BEFORE decoding: FB_QUIET consumes what it decodes from
            # its source argument in place, so $good is '' afterwards and a
            # length() taken after the call would advance $bytes by 0 forever.
            my $consumed = length $good;
            $out .= Encode::decode('UTF-8', $good, Encode::FB_QUIET());
            substr($bytes, 0, $consumed, '');
        } else {
            $out .= "\x{FFFD}";               # one malformed byte -> one U+FFFD
            substr($bytes, 0, 1, '');
        }
    }
    return $out;
}

# _strip_sgr($decoded) -> $decoded, with every complete CSI-SGR sequence
# (\e[...m) removed WHOLE and any remaining bare/dangling ESC removed. This is
# the SHARED escape grammar: display_width and _safe both go through this one
# helper so they can never disagree on what "zero width" means (INV-3). PRIVATE.
sub _strip_sgr {
    my ($s) = @_;
    return '' if !defined $s;
    $s =~ s/\e\[[0-9;]*m//g;
    $s =~ s/\e//g;
    return $s;
}

# _char_cols($c) -> the display width of one DECODED character. DELEGATING
# ALIAS (package 06, Obligation 2): the width core now lives at exactly one
# place, tui::Layout::char_cols, which itself sources its width table from
# Theme::glyphs() (see _glyph_table_ref() below, the SAME source). PRIVATE.
sub _char_cols {
    my ($c) = @_;
    return tui::Layout::char_cols($c);
}

# glyph_table() -> \%table, mapping each decoded single-character glyph to
# its declared display width. WRITE-ONCE DERIVED FROM Theme::glyphs()
# (package 06, Obligation 3): the four emoji status circles (U+1F7E2 green /
# U+1F534 red / U+1F7E1 yellow / U+26AA white, width 2) are GONE -- Theme's
# glyph table carries no emoji at all (Decision 11) -- and U+FF5C (sep.bar)
# enters at width 2, which is exactly Obligation 5b's requirement, obtained
# by derivation rather than a hand-added literal. Every other glyph this
# module allow-lists (braille spinners, gauge blocks, scroll arrows, the
# four non-emoji status glyphs) enters at Theme's declared width, which for
# every one of them is unchanged from before. Memoized once, like
# Theme::glyphs()'s own defensive-copy discipline this mirrors -- load-
# bearing for the same performance reason the old per-char hash-copy note
# below used to warn about. PUBLIC.
my $GLYPH_TABLE_MEMO;

# _glyph_table_ref() -> the canonical (write-once memoized) table with NO
# copy. Internal hot-path accessor: every per-character caller (_char_cols
# used to use this directly; now _safe_char alone does, since _char_cols
# itself delegates to tui::Layout) MUST use this, never glyph_table(), or
# the per-char hash-copy performance regression comes right back. Callers
# here never mutate it. PRIVATE.
sub _glyph_table_ref {
    return $GLYPH_TABLE_MEMO if $GLYPH_TABLE_MEMO;
    my %table;
    my $glyphs = Theme::glyphs();
    for my $name (keys %$glyphs) {
        my $rec = $glyphs->{$name};
        next unless ref($rec) eq 'HASH' && defined $rec->{char};
        $table{ $rec->{char} } = $rec->{width};
    }
    $GLYPH_TABLE_MEMO = \%table;
    return $GLYPH_TABLE_MEMO;
}

# display_width($str) -> the number of terminal display columns $str
# occupies. undef/'' -> 0. Never dies, never warns. DELEGATING ALIAS
# (package 06, Obligation 2): tui::Layout::display_width is now the single
# width implementation; this module's own copy of the decode/strip/sum
# pipeline (_decode_str/_strip_sgr/_char_cols) is retained ONLY because
# _safe/_safe_char (below) still need it for sanitisation, per spec S2.2 --
# they keep their own bodies but consult the SAME derived glyph table.
# PUBLIC.
sub display_width {
    my ($str) = @_;
    return tui::Layout::display_width($str);
}

# _safe_char($c) -> the sanitized DECODED form of one character: itself if
# printable ASCII or an allow-listed glyph, '' (deleted) if zero-width
# (_char_cols($c) == 0: controls, DEL, combining marks, U+200B/200D/FE0F),
# else exactly one '?'. Factored out of _safe (F2, s04 fix-batch) so
# `fit_spans` can apply the IDENTICAL per-character sanitization while it
# already has the string split into characters for the cut-boundary
# computation, instead of re-deciding "is this safe to emit raw" differently
# (or not at all) from `_safe`. This is what makes INV-3 hold for
# fit_spans/clip_pad output too, not just for `_safe`'s own output -- closing
# the live-C1/control-byte leak through the public fit_spans/clip_pad
# primitives (redteam-01.md MAJOR-2). PRIVATE.
sub _safe_char {
    my ($c) = @_;
    return '' if !defined $c || $c eq '';
    my $cp = ord($c);
    return $c if $cp >= 0x20 && $cp <= 0x7E;
    my $gt = _glyph_table_ref();
    return $c if exists $gt->{$c};
    return '' if _char_cols($c) == 0;
    return '?';
}

# _safe($str) -> a UTF-8 BYTE string: printable ASCII and allow-listed glyphs
# pass through unchanged; zero-width characters (controls, DEL, combining
# marks, U+200B/200D/FE0F) are deleted; a complete SGR sequence is removed
# whole (sharing _strip_sgr with display_width, so INV-3 holds); everything
# else becomes exactly ONE '?' per source CHARACTER (never one '?' per byte).
# Never dies, never warns. _safe(undef) is ''. PRIVATE (name preserved).
sub _safe {
    my ($str) = @_;
    return '' if !defined $str;
    my $s = _strip_sgr(_decode_str($str));
    my $out = '';
    $out .= _safe_char($_) for split //, $s;
    return Encode::encode('UTF-8', $out);
}

# spanify($line, $default_role) -> \@spans, canonicalizing any of the accepted
# line forms (plain string, {text,role}, [ {text,role}, ... ], {role,spans}, or
# undef) into a non-empty arrayref of { text, role } spans with sanitized,
# UTF-8-byte text and a defined role. Never dies. PUBLIC.
sub spanify {
    my ($line, $default_role) = @_;
    $default_role = 'body' if !defined $default_role;

    # NOTE (F7, s04 fix-batch): precedence when a HASH provides BOTH `text` and
    # `spans` is that `spans` silently wins below (the `ref $line->{spans} eq
    # 'ARRAY'` branch is checked FIRST and returns without ever looking at
    # `$line->{text}`) -- a stray leftover `text` key from a refactor is
    # silently discarded, not diagnosed. Documented per spec S3.4; not treated
    # as a bug to fix (would require a die/warn, which INV-8 forbids).
    my $canon = sub {
        my ($sp, $role) = @_;
        # NOTE (F7): does NOT recurse into a nested { role, spans => [...] }
        # element -- such an element has no `text` key, so it collapses to an
        # EMPTY span (_safe(undef) eq '') with no error. Nested arrayrefs/spans
        # are "not supported and not exercised" per spec S3.4; this is the
        # silent-data-loss shape that produces, called out here so a future
        # s05-13 author hitting it isn't debugging blind.
        if (ref $sp eq 'HASH') {
            return { text => _safe($sp->{text}),
                     role => (defined $sp->{role} ? $sp->{role} : $role) };
        }
        return { text => _safe($sp), role => $role };
    };

    return [ { text => '', role => $default_role } ] if !defined $line;

    if (ref $line eq 'ARRAY') {
        my @out = map { $canon->($_, $default_role) } @$line;
        return @out ? \@out : [ { text => '', role => $default_role } ];
    }
    if (ref $line eq 'HASH') {
        if (ref $line->{spans} eq 'ARRAY') {
            my $role = defined $line->{role} ? $line->{role} : $default_role;
            my @out = map { $canon->($_, $role) } @{ $line->{spans} };
            return @out ? \@out : [ { text => '', role => $role } ];
        }
        return [ { text => _safe($line->{text}),
                   role => (defined $line->{role} ? $line->{role} : $default_role) } ];
    }
    return [ { text => _safe($line), role => $default_role } ];
}

# _span_hash($sp, $default_role) -> a HASH-ref span, coercing whatever was
# actually handed in: a HASH ref passes through unchanged; a defined non-ref
# scalar (bare string) becomes { text => $sp, role => $default_role }
# (mirroring spanify's own tolerance for bare strings inside an array); undef
# or any other ref shape (arrayref, coderef, scalarref, blessed ref) becomes
# an EMPTY span -- contributes nothing, never dies. Shared by fit_spans,
# spans_width, spans_text and _cell_sig so EVERY span-consuming function is
# TOTAL (INV-8, F1, s04 fix-batch): a malformed span list degrades instead of
# taking the whole dashboard down via `run`'s `die $err`. PRIVATE.
sub _span_hash {
    my ($sp, $default_role) = @_;
    $default_role = 'body' if !defined $default_role;
    return $sp if ref($sp) eq 'HASH';
    return { text => $sp, role => $default_role } if defined($sp) && !ref($sp);
    return { text => '', role => $default_role };
}

# spans_width(\@spans) -> sum of display_width across spans (0 for []/undef).
# spans_text(\@spans) -> plain ordered concatenation of span texts, no SGR
# ('' for []/undef). Both PUBLIC. Both total over a malformed span list (F1):
# a non-hashref element is coerced via _span_hash rather than dereferenced raw.
sub spans_width {
    my ($spans) = @_;
    return 0 if !defined $spans || ref($spans) ne 'ARRAY' || !@$spans;
    my $w = 0;
    $w += display_width(_span_hash($_)->{text}) for @$spans;
    return $w;
}
sub spans_text {
    my ($spans) = @_;
    return '' if !defined $spans || ref($spans) ne 'ARRAY' || !@$spans;
    return join('', map { defined _span_hash($_)->{text} ? _span_hash($_)->{text} : '' } @$spans);
}

# fit_spans(\@spans, $w, $pad_role) -> a NEW span list whose total display
# width is EXACTLY $w. Does not mutate the input. Never dies.
#   $w <= 0 (or undef)  -> [ { text => '', role => 'body' } ].
#   $pad_role defaults to the role of the LAST input span, or 'body'.
#   Truncation copies spans left to right; the span that crosses $w is cut at
#   the largest character boundary that still fits -- if the cut would land
#   inside a wide glyph, the WHOLE glyph is dropped (D4), never a half-glyph.
#   Padding tops up to exactly $w, merging into the last emitted span when its
#   role matches $pad_role, else appending a new pad span.
# A non-hashref span element is coerced via _span_hash rather than
# dereferenced raw (F1: INV-8 -- this must never die, on any input).
# Text is sanitized per-character via _safe_char (F2, s04 fix-batch): earlier
# this function kept whatever survived _strip_sgr verbatim (including live C1
# control bytes / unlisted wide characters), so a public "returns exactly $w
# display columns" primitive could emit a raw CSI/C0 byte. _safe_char applies
# the SAME per-character mapping `_safe` uses, so fit_spans/clip_pad now agree
# with `_safe` on what is safe to emit (extends INV-3's guarantee to these
# public primitives too), independent of whether the caller already sanitized.
# NOTE (F8): argument order is ($spans, $w, $pad_role) -- $w SECOND -- unlike
# spanify($line, $role) / make_cell($line, $role, $cols), which put role
# second. This is pinned by spec S3 and is NOT being changed; s05-13 authors
# hand-composing `fit_spans(spanify($line, $role), $cols, $role)` (what
# make_cell does internally) must remember the role argument moves position.
# PUBLIC.
sub fit_spans {
    my ($spans, $w, $pad_role) = @_;
    $spans = [] if !defined $spans || ref($spans) ne 'ARRAY';
    return [ { text => '', role => 'body' } ] if !defined $w || $w <= 0;

    if (!defined $pad_role) {
        $pad_role = @$spans ? _span_hash($spans->[-1])->{role} : 'body';
        $pad_role = 'body' if !defined $pad_role;
    }

    my @out;
    my $width = 0;
    my $truncated = 0;
    for my $raw_sp (@$spans) {
        last if $truncated;
        my $sp       = _span_hash($raw_sp);
        my $raw_text = defined $sp->{text} ? $sp->{text} : '';
        my $role     = defined $sp->{role} ? $sp->{role} : 'body';
        my $decoded  = _strip_sgr(_decode_str($raw_text));
        my @chars    = split //, $decoded;
        my $tw = 0;
        $tw += _char_cols($_) for @chars;

        if ($width + $tw <= $w) {
            my $safe_text = join('', map { _safe_char($_) } @chars);
            push @out, { text => Encode::encode('UTF-8', $safe_text), role => $role }
                if length $safe_text;
            $width += $tw;
            next;
        }

        my $remaining = $w - $width;
        my $cut = '';
        my $cut_w = 0;
        for my $c (@chars) {
            my $cw = _char_cols($c);
            last if $cut_w + $cw > $remaining;   # would straddle -- drop it (D4)
            $cut .= _safe_char($c);
            $cut_w += $cw;
        }
        push @out, { text => Encode::encode('UTF-8', $cut), role => $role } if length $cut;
        $width += $cut_w;
        $truncated = 1;
    }

    if ($width < $w) {
        my $pad = ' ' x ($w - $width);
        if (@out && $out[-1]{role} eq $pad_role) {
            $out[-1]{text} .= $pad;
        } else {
            push @out, { text => $pad, role => $pad_role };
        }
    }

    @out = grep { length($_->{text}) } @out;
    return @out ? \@out : [ { text => '', role => $pad_role } ];
}

# _justify_spans(\@spans, $right, $w, $right_role) -> \@spans (s06-panel-
# semantics, spec S2.5). The spans-aware sibling of _justify: returns a NEW
# span list (input not mutated) whose spans_width is EXACTLY $w. Unlike
# _justify (which drops the RIGHT side and clips the left when both don't
# fit), this clips the LEFT and keeps the right -- the scroll indicator is
# unique information Decision #19 exists to surface, while the left side is
# repeated/scrollable event text. The indicator is only dropped when it
# cannot fit even alone. PRIVATE, pure, total (never dies/warns).
sub _justify_spans {
    my ($spans, $right, $w, $right_role) = @_;
    $w = 0 if !defined $w || $w !~ /^-?\d+(?:\.\d+)?$/ || $w < 0;
    $right_role = 'muted' if !defined $right_role;
    my @sp = (ref($spans) eq 'ARRAY') ? @$spans : ();
    return fit_spans(\@sp, $w, 'body') if !defined $right || $right eq '';

    my $rw = display_width($right);
    my $lw = spans_width(\@sp);
    if ($lw + $rw + 1 <= $w) {                      # both fit: pad the gap
        return [ @sp, { text => (' ' x ($w - $lw - $rw)), role => 'body' },
                 { text => $right, role => $right_role } ];
    }
    if ($rw + 1 <= $w) {                            # only by clipping the left
        return [ @{ fit_spans(\@sp, $w - $rw - 1, 'body') },
                 { text => ' ', role => 'body' },
                 { text => $right, role => $right_role } ];
    }
    return fit_spans(\@sp, $w, 'body');             # indicator cannot fit at all: drop it
}

# ---------------------------------------------------------------------------
# s06-panel-semantics: Decision #1 (curated glyphs) + Decision #2 (semantic
# color hierarchy) pure classifiers, and small span-composition helpers used
# by _fixed_panels / _backpack_lines / recent_events / activity_window. See
# specs/03-panel-semantics-spec.md S2 for the binding API contract. Every
# function here is PURE and TOTAL (INV-8): never die/warn on any input,
# including undef, empty string, non-numeric, arrayref, or blessed-ref input.
# ---------------------------------------------------------------------------
# The four emoji circle constants are GONE (package 06, Obligation 5a --
# Decision 11, "no emoji anywhere"). Replaced by _status_glyph(), a lazy
# accessor onto Theme's four non-emoji status glyphs, resolved INSIDE the
# sub bodies that use it (container_status_style, event_style, the spend
# styler) -- never at file scope, so this module's %INC/load path never
# needs Theme::glyph before it is actually rendering a frame. spec S2.2.
sub _status_glyph {              # 'ok' | 'warn' | 'crit' | 'idle'
    my ($k) = @_;
    my $g = Theme::glyph("status.$k");
    return defined($g) ? $g : '?';
}

my $TRI_UP       = Encode::encode('UTF-8', "\x{25B2}");
my $TRI_DOWN     = Encode::encode('UTF-8', "\x{25BC}");

# %BUTLER_KIND_STYLE -- s16-fleet-event-source spec S3: butler-fleet and
# keep-awake event kinds NOT already covered by event_style's pre-existing
# suffix regexes (those regexes already classify e.g. *_failed/*_error as
# 'bad' and *_start/*_launch(ed) as 'accent' -- orchestrator_start,
# fleet_launched, launch, launch_failed, pkg_failed, checkpoint_failed and
# creds_error all fall through to those unaided; listing checkpoint_failed
# and creds_error here too is harmless/redundant, not load-bearing). This
# table is consulted AFTER those regexes and BEFORE the generic fallback, so
# an unknown kind still reaches the fallback untouched (criterion c).
#
# The second element of each pair is now a STATUS KEY ('ok'/'warn'/'crit'/
# 'idle'), not a glyph literal (package 06, Obligation 5a): this table is a
# plain data literal with no Theme:: call, so _status_glyph resolves the
# actual glyph lazily, inside event_style's own sub body, at the moment a
# frame is actually rendered.
my %BUTLER_KIND_STYLE = (
    watchdog_relaunch => [ 'warn',   'warn' ],
    pkg_finished      => [ 'good',   'ok' ],
    pause             => [ 'warn',   'warn' ],
    checkpoint        => [ 'accent', 'idle' ],
    checkpoint_failed => [ 'bad',    'crit' ],
    creds_error       => [ 'bad',    'crit' ],
    'broken-env'      => [ 'bad',    'crit' ],
    'turn-starved'    => [ 'warn',   'warn' ],
    remediation       => [ 'warn',   'warn' ],
    notice            => [ 'accent', 'idle' ],
    review            => [ 'warn',   'warn' ],
    acquire           => [ 'good',   'ok' ],
    release           => [ 'muted',  'idle' ],
);

# @SPINNER DELETED (2026-08-25). It listed the ten spinner glyphs in order so
# this file could index them directly; nothing has read it since the render
# path moved to Theme::glyph('spinner.N'), and it was a second, silently
# divergent copy of the sequence -- which the change to eight uniform frames
# would have left stale and wrong with no test able to notice.

my $OAUTH_WARN_SECS   = 900;   # 15 minutes (spec S2.2)
my $BACKPACK_MAX_ROWS = 2;     # spec S3.12

# container_status_style($status, $container_gone) -> ($glyph, $role) -- spec
# S2.1. $status compared case-sensitively after stripping leading/trailing
# whitespace; undef treated as ''. $container_gone truthy overrides
# everything -> red/bad. PUBLIC, pure.
sub container_status_style {
    my ($status, $container_gone) = @_;
    my $st = defined $status ? $status : '';
    $st =~ s/^\s+//;
    $st =~ s/\s+$//;
    return (_status_glyph('crit'), 'bad')   if $container_gone;
    return (_status_glyph('ok'), 'good')    if $st eq 'running';
    return (_status_glyph('crit'), 'bad')   if $st =~ /^(?:exited|dead|removing|unknown)$/;
    return (_status_glyph('warn'), 'warn')  if $st =~ /^(?:created|restarting|stopping|stopped|paused)$/;
    return (_status_glyph('idle'), 'muted');
}

# window_title(\%state) -> an ASCII-safe OS window-title string, "<char>
# <project>" (spec S2.2). Reads ONLY project_name/status/container_gone/
# needs_you; any other key is ignored. $state undef/non-hashref -> {}.
# Reuses container_status_style as the sole status vocabulary (S2.3): no
# status word is re-listed here. Precedence: gone > exited > stopped >
# escalations > running > fallback. PUBLIC, pure, total. Guaranteed to match
# /\A[\x20-\x7E]{1,80}\z/ for any input.
sub window_title {
    my ($state) = @_;
    $state = {} if !defined $state || ref($state) ne 'HASH';

    my (undef, $role) = container_status_style($state->{status}, $state->{container_gone});
    my $needs_you = $state->{needs_you};
    $needs_you = 0 if !defined $needs_you || ref $needs_you || $needs_you !~ /^-?\d+(?:\.\d+)?$/;

    # THE LEAD CHARACTER ANIMATES ONLY WHERE ANIMATION MEANS SOMETHING.
    #
    # The operator asked for "proper animation on the first character, just
    # like the running spinner". Taken literally that would animate in every
    # state -- and the lead character is not decoration: it is the ONLY status
    # signal that survives into a taskbar button or an alt-tab list, where the
    # rest of the title is truncated away. Spinning it unconditionally would
    # trade the one place you can see "this exited an hour ago" for motion.
    #
    # So: running animates (motion is exactly what "running" means), and every
    # NOT-RUNNING state keeps its literal, glanceable character. The states that
    # need you to look are the states that stop moving, which is a stronger
    # signal than either half alone.
    #
    # `!` IS THE EXCEPTION, AND IT IS A REAL ONE (operator, 2026-08-26: "the
    # title of the terminal replaces the spinner with a `!` in some occasions,
    # when is that? when there's something that needs me? I wish the `!` would
    # appear after the spinner instead of replacing it").
    #
    # They are right, and the distinction is that `!` is not a state of the
    # CONTAINER. `x`, `-` and `?` all mean the container is not running -- there
    # is nothing to animate, so the literal character replacing the spinner
    # loses nothing. But needs-you fires while the container is running
    # perfectly well; suppressing the spinner there threw away the "still alive"
    # signal to say "and also, look at me". Both are true, so both are shown:
    # the spinner keeps spinning and the `!` follows it.
    #
    # It follows rather than leads deliberately -- the lead character is the one
    # guaranteed to survive taskbar truncation, and "is this thing alive" is the
    # question that has to be answerable from a single glyph.
    my $char;
    if ($state->{container_gone})             { $char = '?'; }
    elsif ($role eq 'bad')                    { $char = 'x'; }
    elsif ($role eq 'warn')                   { $char = '-'; }
    elsif ($role eq 'good') {
        $char = _title_spinner_char($state->{title_spinner_idx});
        $char .= '!' if $needs_you > 0;
    }
    else                                      { $char = '?'; }

    # MINOR-3 (red-team step 6): a ref project_name reaches _decode_str's
    # substr() as an lvalue and warns ("Attempt to use reference as lvalue in
    # substr"). window_title is spec'd total AND warn-free (S2.2/AC-9), so
    # coerce non-scalar values to '' before they reach _safe.
    my $pn = ref($state->{project_name}) ? '' : $state->{project_name};
    my $name = _safe($pn);
    $name =~ s/[^\x20-\x7E]/?/g;   # hard ASCII pass -- _safe alone lets allow-listed glyphs through
    $name =~ s/^\s+//;
    $name =~ s/\s+$//;

    # "<char> <project> - ccpraxis sandbox" (operator request, 2026-08-25).
    #
    # The suffix goes LAST, not first, because window titles are truncated from
    # the right in every taskbar this runs in. Leading with the product name
    # would give every sandbox window the identical visible prefix and hide the
    # project -- the only part that distinguishes one window from another.
    # THE PROJECT NAME YIELDS, NOT THE SUFFIX.
    #
    # A naive "build it all, then substr to 80" drops the tail first, so a long
    # project name silently ate the whole " - ccpraxis sandbox" suffix -- the
    # part that was just asked for, gone in exactly the case where the title is
    # under pressure. Budget the fixed parts first and clip only the name, so
    # every title keeps its lead character and its suffix and loses only the
    # middle, which is the one part with redundancy in it (the project name is
    # also the first thing in the panel header).
    my $suffix = ' - ' . PRODUCT_NAME();
    my $budget = 80 - length($char) - 1 - length($suffix);   # -1 for the space after $char
    $name = substr($name, 0, $budget) if $budget > 0 && length($name) > $budget;
    $name = '' if $budget <= 0;

    my $title = length($name) ? "$char $name" : $char;
    $title .= $suffix;
    return substr($title, 0, 80);
}

# The ten braille frames, resolved through Theme like every other glyph so this
# file keeps no glyph table of its own.
#
# THE ASCII CONTRACT IS DELIBERATELY RELAXED HERE, and only here. window_title
# used to guarantee /\A[\x20-\x7E]{1,80}\z/ and still hard-clamps the PROJECT
# NAME to that range just below -- an operator-supplied string is exactly where
# an encoding surprise would come from. The lead character is ours, is one of
# ten known code points, and is the same glyph set the TUI body already writes
# to this terminal on every frame; a terminal that renders the in-screen
# spinner renders this. Falls back to the old literal '*' if Theme cannot
# resolve the frame, so the degenerate case is the previous behaviour rather
# than an empty title.
# _period_opt($given, $default) -> a strictly positive number. These values are
# DIVISORS, so a 0 or a stray string is a division-by-zero or a warn-then-wrong
# index rather than a cosmetic slip.
sub _period_opt {
    my ($given, $default) = @_;
    return $default if !defined $given || ref($given) || $given !~ /^-?\d+(?:\.\d+)?$/;
    return $default if $given <= 0;
    return $given;
}

sub _title_spinner_char {
    my ($idx) = @_;
    return '*' if !defined($idx) || ref($idx) || $idx !~ /^-?\d+(?:\.\d+)?$/;
    # DERIVED FROM Theme, never restated -- see tui::DashboardScreen's own
    # _spinner_frame for the same note. The frame count changed once already.
    my $n = Theme::SPINNER_FRAMES();
    return '*' if !defined($n) || $n < 1;
    my $i = int($idx) % $n;
    $i += $n if $i < 0;
    my $g = Theme::glyph('spinner.' . ($i + 1));
    return (defined($g) && length($g)) ? $g : '*';
}

# ---------------------------------------------------------------------------
# s09-resources-panel: the pressure classifier, the gauge and the byte
# formatter. They live HERE, not in Resources.pm, because they emit render
# vocabulary (role names, glyphs) -- the same family as oauth_role /
# container_status_style / fmt_age / fmt_oauth above. Keeping them here is
# what lets Resources.pm stay free of every render concept and Dashboard.pm
# stay free of any knowledge of Resources.pm (spec S2.5, I4).
# All three are PUBLIC, pure, total: never die, never warn, on any input.
# ---------------------------------------------------------------------------
my $PRESSURE_WARN = 0.75;   # ratio at/above which a resource reads 'warn'
my $PRESSURE_BAD  = 0.90;   # ratio at/above which a resource reads 'bad'
my $GAUGE_FULL    = Encode::encode('UTF-8', "\x{2588}");   # already allow-listed
my $GAUGE_LIGHT   = Encode::encode('UTF-8', "\x{2591}");   # (glyph_table :240-241)
my $GAUGE_CELLS   = 10;

# event_style($type, $exit, $state) -> ($role, $glyph) -- spec S2.3, the
# activity classifier. $type/$exit/$state are already-scalarized values
# (_ev_scalar); evaluated top to bottom, first match wins. The default is
# 'value' (normal), NOT 'muted' -- an unrecognized event type must not be
# dimmed into invisibility. PUBLIC, pure.
sub event_style {
    my ($type, $exit, $state) = @_;
    $type = '' if !defined $type;
    return ('bad', _status_glyph('crit'))   if $type =~ /(?:^|_)(?:failed|failure|error|gone|dead)$/;
    return ('muted', _status_glyph('idle')) if $type =~ /^(?:heartbeat|tick)$/;
    if (defined $exit) {
        return ('bad', _status_glyph('crit'))  if $exit !~ /^0+$/;
        return ('good', _status_glyph('ok'));
    }
    return ('good', _status_glyph('ok'))    if defined $state && $state eq 'ok';
    return ('accent', _status_glyph('idle'))
        if $type =~ /(?:^|_)(?:start|create|launch)(?:ed)?$/ || $type eq 'launch_session';
    if (exists $BUTLER_KIND_STYLE{$type}) {
        my ($role, $key) = @{ $BUTLER_KIND_STYLE{$type} };
        return ($role, _status_glyph($key));
    }
    return ('value', _status_glyph('idle'));
}

# scroll_indicator($above, $below) -> $text|undef -- spec S2.6, replaces
# _scroll_hint (deleted). Undef/negative/non-numeric counts treated as 0.
# PUBLIC, pure.
sub scroll_indicator {
    my ($above, $below) = @_;
    $above = (defined $above && $above =~ /^-?\d+(?:\.\d+)?$/ && $above > 0) ? $above : 0;
    $below = (defined $below && $below =~ /^-?\d+(?:\.\d+)?$/ && $below > 0) ? $below : 0;
    return "$TRI_UP $above more"                        if $above > 0 && $below == 0;
    return "$TRI_DOWN $below more"                      if $above == 0 && $below > 0;
    return "$TRI_UP $above more  $TRI_DOWN $below more"  if $above > 0 && $below > 0;
    return undef;
}

# session_boundary_row() -> \@spans -- spec S2.3 (s13-activity-history).
# The muted divider inserted between a prior session's tail and the current
# session's events. No parameters. Returns a freshly-constructed arrayref on
# every call so no caller can alias shared state. PUBLIC, pure.
sub session_boundary_row {
    my ($epoch, $localtime_fn) = @_;
    # The label carries the DATE of the session it introduces. Activity rows
    # show a wall-clock time (17:43) rather than an age, and a bare time is
    # ambiguous the moment the list spans more than one day -- which this
    # divider is the definition of. Without a date here, "7d16h" became "23:41"
    # with nothing saying which 23:41.
    my $date = _local_date_label($epoch, $localtime_fn);
    return [ { text => (defined $date ? "-- previous session ($date) --"
                                      : '-- previous session --'), role => 'muted' } ];
}

# _local_parts($epoch, $localtime_fn) -> (hh, mm, ymd, "Www DD Mon") | ()
# The one place an epoch becomes local wall-clock text. $localtime_fn is
# injectable so every caller stays testable without touching the machine clock.
sub _local_parts {
    my ($epoch, $localtime_fn) = @_;
    return () unless defined $epoch && !ref($epoch) && $epoch =~ /^-?\d+(?:\.\d+)?$/;
    my $lt = (ref($localtime_fn) eq 'CODE') ? $localtime_fn : sub { localtime($_[0]) };
    my @t = eval { $lt->(int($epoch)) };
    return () unless @t >= 6;
    my @MON = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my @DOW = qw(Sun Mon Tue Wed Thu Fri Sat);
    my $ymd = sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]);
    my $pretty = sprintf('%s %d %s', $DOW[ $t[6] % 7 ], $t[3], $MON[ $t[4] % 12 ]);
    return ($t[2], $t[1], $ymd, $pretty);
}

# _local_hhmm / _local_date_label / _local_ymd -- thin readers over _local_parts.
sub _local_hhmm {
    my @p = _local_parts(@_);
    return undef unless @p;
    return sprintf('%02d:%02d', $p[0], $p[1]);
}
sub _local_ymd {
    my @p = _local_parts(@_);
    return @p ? $p[2] : undef;
}
sub _local_date_label {
    my @p = _local_parts(@_);
    return @p ? $p[3] : undef;
}

# day_boundary_row($epoch, $localtime_fn) -> \@spans
# Inserted wherever consecutive activity rows fall on different local dates.
# Once the time column shows a clock rather than an age, crossing midnight is
# invisible without this -- 00:14 sorts below 23:58 and reads as fourteen
# minutes later when it is fourteen minutes into the NEXT DAY.
sub day_boundary_row {
    my ($epoch, $localtime_fn) = @_;
    my $label = _local_date_label($epoch, $localtime_fn);
    return [ { text => (defined $label ? "-- $label --" : '-- new day --'), role => 'muted' } ];
}

# activity_row_width($cols) -> $w -- spec S2.7. $w = $cols - 2 (the
# _panel_rows body-indent span), clamped >= 0; undef/non-numeric $cols -> 0.
# The single place that constant is mirrored, so `run` never open-codes it.
# PUBLIC, pure.
sub activity_row_width {
    my ($cols) = @_;
    return 0 if !defined $cols || $cols !~ /^-?\d+(?:\.\d+)?$/;
    # DERIVED from the renderer's own constant, not a repeated literal. This
    # was `$cols - 2` for the two-space body indent; that indent is now
    # BODY_INDENT and is 0, and a hard-coded 2 here would have gone on
    # reserving columns nothing occupies.
    my $w = $cols - tui::Screen::BODY_INDENT();
    return $w < 0 ? 0 : $w;
}

# _run_lines(\@runs) -> LIST of extra Run-panel body lines (possibly empty).
# @runs is the RunState::summarize struct list (spec 07 S2.2, closed 11-key
# set), passed through the gather hash with no arithmetic. Dashboard.pm must
# NOT load the RunState module (no "use"/"require" of it anywhere) -- it
# only renders the already-computed struct,
# exactly as it does for tokens/resources. PRIVATE, pure, no file I/O, mirrors
# _token_lines'/_resources_lines' style. Never dies for any input.
#
# $runs not an ARRAYREF, or an empty ARRAYREF (after skipping non-hashref
# elements) -> the empty list. At most the first $RUN_MAX_ROWS surviving
# summaries get a line; when more survive, one extra overflow line is
# appended.
# t11-tui-hot-reload: how long a [r] reload report stays on screen. Long enough
# to read after the forced repaint, short enough that a stale claim about a
# moment that has passed does not linger.
use constant HOT_RELOAD_REPORT_SECS => 20;

# Animation cadence, seconds per frame. The in-screen spinner reads as motion;
# the OS window title is glanced at rather than watched, and a title that
# rewrites five times a second is both distracting in a taskbar and a stream of
# needless OSC writes -- so it advances through the SAME ten frames four times
# more slowly.
# RESIZE_SETTLE_SECS -- how long after a geometry change every tick keeps
# painting in full. Sized to cover a terminal that reflows AFTER reporting its
# new size (a maximize does this; a drag-resize hides it by reporting many
# times). Long enough to outlast that reflow, short enough that the extra full
# repaints are invisible: at the production tick five ticks is about a second.
use constant RESIZE_SETTLE_TICKS       => 5;
use constant SPINNER_PERIOD_SECS       => 0.5;
# Was 2.0, on the reasoning that a title is glanced at rather than watched and
# each change costs an OSC write. The operator watched it and wanted it faster,
# which settles it: the write is a dozen-odd bytes emitted only when the STRING
# changes, so two per second is not a cost worth a slower spinner.
use constant TITLE_SPINNER_PERIOD_SECS => 0.5;

# The product name, in ONE place. It was a bare literal in two builders
# (window_title's suffix and the in-screen header's left half) that must agree
# -- the sort of duplication that stays correct right up until someone renames
# one of them.
use constant PRODUCT_NAME => 'ccpraxis sandbox';

our $RUN_MAX_ROWS = 3;

# _run_state_role($state) -> the S2.10a role for a run-summary state span.
my %RUN_STATE_ROLE = ( running => 'good', paused => 'warn', parked => 'warn', idle => 'muted' );

# ===========================================================================
# b37-spend-surfaces: renders SpendPanel's already-computed status() \%info
# struct. Dashboard.pm does NOT load the SpendPanel module (no use/require,
# no module-qualified call anywhere in this file) -- exactly the TokenInfo/
# _token_lines split.
# PRIVATE, pure, mirrors _token_lines' style. Never dies for any input.
# ===========================================================================

# _status_alert(\%state) -> a one-line banner string when the container is no
# longer running or no longer reachable, else undef. This drives the "dashboard
# stays open after the container dies" behavior: the loop no longer exits on
# container death, so this makes the dead/unreachable state loud and tells the
# user what to do. 'unknown' = inspect couldn't read the container (podman down
# or the host slept); empty/running/created/restarting are healthy-or-transient
# and stay quiet.
#
# The dead-state banner deliberately does NOT offer [c]: [c] only spawns a
# connector (`podman exec` into a LIVE container), so on a dead container it
# opens a Windows Terminal that instantly closes (the exec has nothing to attach
# to). Since s12 the banner leads with [l] relaunch (start the machine if it is
# down, start the container, re-attach — in-TUI, nothing deleted) and keeps
# "[q] quit, then re-run claude-sandbox" as the fallback for the one case [l]
# cannot fix (a container that was genuinely removed and needs a rebuild).
# [r] retry stays for the 'unknown'/unreachable case, where the same container
# may simply reappear once podman/the host is back.
#
# $s->{machine_state} (s12, gather's new key; the _machine_state vocabulary
# running|stopped|absent|unknown|n/a) is checked FIRST: a stopped podman machine
# and a removed container both read as "unreachable" from the container probe
# alone, and only the machine reading tells them apart. Every pre-s12 caller
# omits the key, so the container rows below are unchanged for them.
sub _status_alert {
    my ($s) = @_;
    $s ||= {};
    my $st = defined $s->{status}        ? lc $s->{status}        : '';
    my $ms = defined $s->{machine_state} ? lc $s->{machine_state} : '';
    return 'podman machine is stopped - [l] relaunch to start the machine and container, or [q] quit'
        if $ms eq 'stopped';
    if ($s->{container_gone}) {
        return ($st && $st ne 'unknown')
            ? "container is not running ($st) - [l] relaunch, or [q] quit and re-run claude-sandbox"
            : 'container unreachable - [l] relaunch, [r] retry, or [q] quit';
    }
    return undef if $st eq '' || $st eq '?' || $st eq 'running'
                 || $st eq 'created' || $st eq 'restarting';
    return 'container unreachable (podman down or host asleep) - [l] relaunch, [r] retry, [q] quit'
        if $st eq 'unknown';
    return "container is $st (not running) - [l] relaunch, or [q] quit and re-run claude-sandbox";
}

# can_launch(\%state) -> 1 iff the container is in a state where the [c] hotkey
# can actually attach a connector. [c] spawns `claude-sandbox --session`, which
# `podman exec`s into the container — and exec needs a RUNNING container. On any
# other state (exited / stopped / created / restarting / gone / not-yet-known)
# the exec instantly fails and the spawned Windows Terminal vanishes, so the
# loop SUPPRESSES the spawn and flashes launch_blocked_msg() instead. This is
# _status_alert's "is it alive?" judgement seen from the launch side.
sub can_launch {
    my ($s) = @_;
    $s ||= {};
    return 0 if $s->{container_gone};
    my $st = defined $s->{status} ? lc $s->{status} : '';
    return $st eq 'running' ? 1 : 0;
}

# launch_blocked_msg() -> the transient footer notice shown when [c] is pressed
# on a non-running container (see can_launch). Names the real relaunch path so
# the key never feels dead. The "container is down" lead is deliberately
# distinct from the persistent _status_alert banner wording, so the two never
# read as one duplicated line and each is independently greppable.
sub launch_blocked_msg {
    return 'container is down - [l] relaunch, or [q] quit and re-run claude-sandbox';
}

# compose_frame(\%state, $rows, $cols) -> arrayref of EXACTLY $rows
# { text, role, spans } cells (every cell built via make_cell, so
# display_width($cell->{text}) == $cols for every row). DELEGATES to
# tui::DashboardScreen::compose (package 06, spec S2.4): the content
# vocabulary -- panel set, density suppression, the two-column reflow --
# now lives there, composed through package 05's tui::Screen/Layout/Frame/
# Meter. This module's own argument normalisation ($rows < 0 -> 0, $cols < 1
# -> 1) is preserved here, ahead of the delegation, exactly as before.
# PUBLIC.
sub compose_frame {
    my ($state, $rows, $cols) = @_;
    $state ||= {};
    # Fix batch (package 06, red-team finding, latent/low): guard ref/non-
    # numeric $rows/$cols the same way _fixed_region_height's own cols
    # normalisation does (below), rather than a bare `< 0`/`< 1` comparison
    # that would warn under `use warnings` (and mis-compare) on a ref or a
    # non-numeric string.
    $rows = 0 if !defined $rows || ref($rows) || $rows !~ /^-?\d+(?:\.\d+)?$/ || $rows < 0;
    $cols = 1 if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/ || $cols < 1;
    return tui::DashboardScreen::compose($state, $rows, $cols);
}

# sgr_for_role($role) -> the SGR escape for a role (row role or span role;
# color mode only). '' for unknown roles, 'body', 'blank' and undef.
# PUBLIC, extended (F9: s04 fix-batch doc-tag pass).
#
# THEME ROLES RESOLVE FIRST (package 06, spec S2.1; driver ruling
# 2026-08-08, resolving the spec's own self-contradiction over 'accent').
# sgr_for_role has exactly one caller in the whole repository -- _row_ansi,
# below, this file's own render path -- and that caller now feeds it ONLY
# the role names tui::DashboardScreen emits, which are Theme's nine role
# names exclusively (spec S2.1: "tui::DashboardScreen emits Theme role
# names only"). 'accent' is the single name that collides between the
# legacy seventeen and Theme's nine; resolving Theme FIRST is what lets the
# live caller's 'accent' spans (the title row) paint in Theme's actual
# accent colour instead of being permanently shadowed by the legacy cyan
# branch below, which a legacy-first order would make unreachable for the
# one caller that exists. The other fourteen legacy names are not Theme
# role names, so they are untouched by this reordering and stay byte-
# identical (spec S6 item 8 retains every legacy branch -- only the
# resolution ORDER changes, nothing is deleted).
my $THEME_ROLE_NAMES_MEMO;
sub _theme_role_names {
    return $THEME_ROLE_NAMES_MEMO if $THEME_ROLE_NAMES_MEMO;
    $THEME_ROLE_NAMES_MEMO = Theme::roles();
    return $THEME_ROLE_NAMES_MEMO;
}

sub sgr_for_role {
    my ($role) = @_;
    $role = '' if !defined $role;
    return Theme::sgr($role, undef) if exists _theme_role_names()->{$role};
    return "\e[1;36m"     if $role eq 'title';        # bold cyan
    return "\e[1m"        if $role eq 'panel-title';  # bold
    return "\e[2m"        if $role eq 'footer';       # dim
    return "\e[2m"        if $role eq 'scrollhint';   # dim — like the footer command row
    return "\e[1;33;41m"  if $role eq 'footer-alert'; # bold yellow on red
    return "\e[1;33m"     if $role eq 'footer-flash'; # bold yellow — transient notice
    return "\e[1;37;41m"  if $role eq 'alert';        # bold white on red (banner)
    return "\e[2m"        if $role eq 'label';        # dim (s05+: label/value pairs)
    return "\e[2m"        if $role eq 'muted';        # dim
    return ''             if $role eq 'value';        # reset/normal, contrasts dim labels
    return "\e[1m"        if $role eq 'strong';       # bold
    return "\e[32m"       if $role eq 'good';         # green
    return "\e[33m"       if $role eq 'warn';         # yellow
    return "\e[31m"       if $role eq 'bad';          # red
    return "\e[36m"       if $role eq 'accent';       # cyan -- UNREACHABLE: 'accent' is
                                                       # also a Theme role name and is now
                                                       # resolved by the Theme-first check
                                                       # above; kept, not deleted (S6 item 8).
    return Theme::sgr($role, undef);
}

# _cell_spans(\%cell) -> \@spans: $cell->{spans} when present, else the
# implicit single span synthesized from { text, role } (so a hand-built,
# span-free cell -- including a `prev` frame built before s04 -- still works).
# A $cell that isn't even a hashref (F1: INV-8, never die on any input)
# degrades to an empty span list rather than dereferencing it raw. PRIVATE.
sub _cell_spans {
    my ($cell) = @_;
    return [] if ref($cell) ne 'HASH';
    return $cell->{spans} if defined $cell->{spans} && ref($cell->{spans}) eq 'ARRAY';
    return [ { text => $cell->{text}, role => $cell->{role} } ];
}

# _cell_sig(\%cell) -> a canonical signature string encoding the row role and
# every span's role+text. This -- NOT text-eq-and-role-eq -- is the ONLY thing
# render_frame may compare (D2): once a cell carries a `spans` arrayref, `eq`
# on the arrayref compares references, not values.
#
# F5 correction (s04 fix-batch): the original encoding joined fields with a
# bare "\x00" separator on the (unenforced) assumption that "\x00 cannot occur
# in a role or in sanitized text". That assumption is false for roles (never
# sanitized anywhere -- spanify copies $sp->{role} verbatim) and was ALSO false
# for fit_spans-produced text before the F2 fix. Two cells built from
# {role=>'good',text=>''}+{role=>'',text=>'y'} vs a single
# {role=>'good',text=>"\x00\x00y"} span collided on the exact same "\x00"-joined
# signature despite rendering differently -- a changed row silently never
# repainted. Length-prefixing each field ("<len>:<field>" concatenated, a
# netstring-style encoding) makes the encoding unambiguous regardless of what
# bytes appear inside role/text, closing the gap unconditionally rather than
# relying on an upstream sanitization guarantee holding forever.
# Guards a non-hashref $cell / span element (F1) via _cell_spans / _span_hash.
# PRIVATE.
sub _cell_sig {
    my ($cell) = @_;
    my $role = (ref($cell) eq 'HASH' && defined $cell->{role}) ? $cell->{role} : '';
    my @fields = ($role);
    for my $raw_sp (@{ _cell_spans($cell) }) {
        my $sp = _span_hash($raw_sp);
        push @fields, (defined $sp->{role} ? $sp->{role} : ''),
                      (defined $sp->{text} ? $sp->{text} : '');
    }
    return join('', map { length($_) . ':' . $_ } @fields);
}

# _row_ansi($row, \%cell, $color) -> the ANSI to (re)draw one 1-based row.
# The line is cleared (\e[K) BEFORE the text, never after: every composed row is
# exactly $cols display columns wide, so writing it parks the cursor in the last
# cell (deferred auto-wrap). A trailing \e[K would then erase that last cell —
# invisibly on a dash separator, but visibly chopping the title's closing "]"
# (the "[running" bug). Clearing first wipes any stale tail (a width-shrink
# diff) and leaves the final character intact. With color, each span is
# SELF-CLOSING (SGR . text . \e[0m; a ''-role span emits bare text) -- no
# row-level trailing reset, so style never bleeds within a row or across rows.
# PRIVATE, extended (F9: s04 fix-batch doc-tag pass).
sub _row_ansi {
    my ($row, $cell, $color) = @_;
    my $s = "\e[${row};1H\e[K";
    for my $raw_sp (@{ _cell_spans($cell) }) {
        my $sp   = _span_hash($raw_sp);   # F1: never die on a malformed span element
        my $text = defined $sp->{text} ? $sp->{text} : '';
        if (!$color) {
            $s .= $text;
            next;
        }
        my $sgr = sgr_for_role($sp->{role});
        $s .= $sgr eq '' ? $text : ($sgr . $text . "\e[0m");
    }
    return $s;
}

# render_frame($prev_frame, $new_frame, \%opts) -> the ANSI string to apply.
# Full redraw (clear + every row) when there is no previous frame or the row
# count changed (a resize -- callers force this by passing $prev=undef, the
# idiom run() uses for a width-only resize too, since render_frame never
# receives terminal width); otherwise a per-row diff that touches
# ONLY changed rows, keyed on _cell_sig (D2) -- a VALUE comparison, so two
# structurally-identical cells built by separate compose_frame calls (distinct
# spans arrayrefs) still diff to nothing. The whole burst is wrapped in
# synchronized-output markers (\e[?2026h/l) so the terminal presents it
# atomically — the B0 flicker fix.
# PUBLIC, diff key changed (F9: s04 fix-batch doc-tag pass).
sub render_frame {
    my ($prev, $new, $opts) = @_;
    $opts ||= {};
    my $color = $opts->{color};
    my $full  = !$prev || !@$prev || @$prev != @$new;

    # `repaint` -- RE-EMIT EVERY ROW WITHOUT CLEARING. Distinct from $full,
    # which also erases the screen first.
    #
    # It exists for the resize settle window (see Dashboard::run's geometry
    # poll): after a terminal reflows on its own, our per-row diff has nothing
    # to emit because our model and the screen disagree and only the screen
    # knows it. Re-emitting every row repairs that -- each row carries its own
    # \e[K -- and NOT clearing is the point: a repeated \e[2J is the one thing
    # that could read as flicker, and the rows alone are sufficient to repair.
    my $repaint = $full || $opts->{repaint};

    my $out = "\e[?2026h";   # begin synchronized output
    $out .= "\e[2J\e[H" if $full;
    for my $i (0 .. $#$new) {
        unless ($repaint) {
            next if _cell_sig($prev->[$i]) eq _cell_sig($new->[$i]);
        }
        $out .= _row_ansi($i + 1, $new->[$i], $color);
    }
    $out .= "\e[?2026l";     # end synchronized output
    return $out;
}

# dispatch_key($key, $pending) -> ($action, $new_pending).
# Single-letter hotkeys; [s] stop-runs, [x] full-shutdown and [l] relaunch are
# each independent two-step confirms (pending 'stop-runs' / 'full-shutdown' /
# 'relaunch'; y/Y fires, any other key cancels WITHOUT re-arming any other
# control -- s11-lifecycle-stop spec 08 S2.1, s12 spec 09 S2.1). The legacy
# 'shutdown' pending token is retired: any $pending value that isn't one of the
# three pinned tokens is normalized to '' (no confirm armed). Unknown keys are
# inert.
sub dispatch_key {
    my ($key, $pending) = @_;
    $key = '' if !defined $key;
    $pending = '' if !defined $pending;
    # s12-lifecycle-relaunch: 'relaunch' joins the whitelist. A pending token
    # that is NOT listed here is silently coerced to '' -- so a control whose
    # token is added to the branch chain below but forgotten HERE arms a
    # confirm that can never be confirmed (the [l] landmine this comment marks).
    $pending = '' unless $pending eq 'stop-runs' || $pending eq 'full-shutdown'
                      || $pending eq 'relaunch';

    if ($pending eq 'stop-runs') {
        return ('stop-runs', '')          if $key =~ /^[yY]$/;
        return ('cancel-stop-runs', '');  # any other key cancels; never re-arms full-shutdown
    }
    if ($pending eq 'full-shutdown') {
        return ('full-shutdown', '')          if $key =~ /^[yY]$/;
        return ('cancel-full-shutdown', '');  # any other key cancels; never re-arms stop-runs
    }
    if ($pending eq 'relaunch') {
        return ('relaunch', '')          if $key =~ /^[yY]$/;
        return ('cancel-relaunch', '');  # any other key cancels; never re-arms stop-runs/full-shutdown
    }
    return ('launch', '')             if $key =~ /^[cC]$/ || $key eq "\r" || $key eq "\n";
    return ('confirm-stop-runs',     'stop-runs')     if $key =~ /^[sS]$/;
    return ('confirm-full-shutdown', 'full-shutdown') if $key =~ /^[xX]$/;
    return ('confirm-relaunch',      'relaunch')      if $key =~ /^[lL]$/;
    return ('refresh', '')            if $key =~ /^[rR]$/;
    return ('quit', '')               if $key =~ /^[qQ]$/;
    # 07-backpack-screen S2.2: 'b' opens the backpack screen. Lowercase-only,
    # deliberately -- an uppercase alias would risk an unassembled CSI byte
    # ('B' is the DOWN arrow's final letter) firing this action by accident.
    # The second element is the LITERAL '', not $pending: no new pending
    # token is introduced, so the :2024 whitelist above needs no entry and
    # has nothing to forget.
    return ('backpack', '')           if $key eq 'b';
    # t03-banner-dismiss S2.3: dismiss the backpack-install-warning banner.
    # Lowercase-only, deliberately -- same rationale as 'b' above: 'D' is the
    # LEFT arrow's CSI final byte (\e[D), so an uppercase alias risks firing
    # on an unassembled escape sequence.
    return ('dismiss-install-warning', '') if $key eq 'd';
    # Up/down scroll the Activity panel. The read-key seam assembles the arrow
    # escape sequences into the 'UP'/'DOWN' tokens (also accept k/j as aliases).
    return ('scroll-up', $pending)    if $key eq 'UP'   || $key eq 'k';
    return ('scroll-down', $pending)  if $key eq 'DOWN' || $key eq 'j';
    return ('', $pending);
}

# find_exe($name, $path, $sep) -> first existing $path-dir/$name, or undef.
# Used to detect wt.exe. $sep defaults to the platform PATH separator.
sub find_exe {
    my ($name, $path, $sep) = @_;
    return undef if !defined $name || !length $name;
    return undef if !defined $path;
    # ONLY native Windows perl (Strawberry/ActiveState, $^O eq 'MSWin32') presents
    # $ENV{PATH} semicolon-separated. The Git-for-Windows perl that actually runs
    # the launcher reports $^O 'cygwin' (or 'msys') and presents a POSIX
    # colon-separated PATH (/c/foo:/c/bar) — so it must split on ':', NOT ';'.
    # (Regression: the old `cygwin|msys -> ;` guess split a colon-PATH into one
    # element, so find_exe never found wt.exe and launch-claude silently fell back
    # to a bare PowerShell console instead of a Windows Terminal window.)
    $sep = ($^O eq 'MSWin32') ? ';' : ':' if !defined $sep;
    for my $dir (split /\Q$sep\E/, $path) {
        next unless length $dir;
        my $cand = File::Spec->catfile($dir, $name);
        return $cand if -f $cand || -x $cand;
    }
    return undef;
}

# find_wt($path, $localappdata) -> the resolved wt.exe path, or undef if Windows
# Terminal is not installed. wt.exe is normally a per-user app-execution alias on
# PATH under %LOCALAPPDATA%\Microsoft\WindowsApps; we look there directly too, so a
# stripped PATH entry can't hide an installed WT. launch-claude REQUIRES Windows
# Terminal (no silent console fallback), so this is the gate the launcher asserts.
sub find_wt {
    my ($path, $localappdata) = @_;
    my $p = find_exe('wt.exe', $path);
    return $p if defined $p;
    if (defined $localappdata && length $localappdata) {
        my $cand = File::Spec->catfile($localappdata, 'Microsoft', 'WindowsApps', 'wt.exe');
        return $cand if -e $cand || -x $cand;
    }
    return undef;
}

# spawn_argv($mode, \%ctx) -> argv arrayref to run, or undef for 'inline'.
# ctx.cmd is the caller-supplied command list to run in the new window (the
# launcher's internal connector entry, `claude-sandbox --session <project>`);
# this function only wraps it with the window-spawning prefix. Keeping the
# command opaque means the wrapping logic stays pure/testable while the launcher
# owns the platform-correct invocation (a native wt.exe/`start` can't exec the
# .ps1 by bare name, so the launcher passes a `powershell.exe -File …` cmd).
# ctx: { cmd => [...], comspec }.
sub spawn_argv {
    my ($mode, $ctx) = @_;
    $ctx ||= {};
    my @cmd = @{ $ctx->{cmd} || [] };
    return ['wt.exe', '-w', 'new', @cmd]                            if $mode eq 'wt';
    return [($ctx->{comspec} || 'cmd.exe'), '/c', 'start', '', @cmd] if $mode eq 'start';
    return undef;   # inline: caller runs the connector in-process
}

# recent_events(\@json_lines, $n, $localtime_fn) -> arrayref of the last $n
# events parsed from B1 launch-log JSON lines. Unparseable lines are skipped.
# s06-panel-semantics (spec S3.14): each accepted record is now a
# spans-arrayref -- dim timestamp + severity glyph + semantically-colored
# body (classified by event_style), not an opaque string. The timestamp span
# is ALWAYS role 'muted', regardless of classification.
#
# RESTRUCTURED (package 06, spec S2.4.6): parse -> collapse -> tail-slice ->
# render, in that order, so $n bounds RENDERED rows (after collapsing, not
# before -- criterion 5). Optional 4th arg $now enables the per-event time
# column (fmt_duration($now - $epoch)); $localtime_fn (3rd arg) is retained
# for signature compatibility with existing callers but is UNUSED by the new
# time field -- _event_time (the old HH:MM:SS clock-time renderer) is no
# longer on this render path (AC-F5, criterion 4's one duration format).
# _ev_scalar($json_value) -> a safe display string, or undef to omit the field.
# F6 (s04 fix-batch, redteam-01.md MINOR): a launch-log line is untrusted input,
# and a JSON object/array value interpolated straight into an event string
# stringifies its REFERENCE — painting a raw `HASH(0x5eef04400aa0)` heap address
# onto the dashboard (an information leak and visual garbage). Render a bounded
# type marker instead. JSON::PP booleans are left to interpolate: they overload
# stringification to 1/'' , which is the meaningful rendering. PRIVATE.
sub _ev_scalar {
    my ($v) = @_;
    return undef if !defined $v;
    my $r = ref $v;
    return $v if !$r || $r eq 'JSON::PP::Boolean';
    return '{...}' if $r eq 'HASH';
    return '[...]' if $r eq 'ARRAY';
    return '<ref>';
}

# $EVENT_FIELD_MAX_LEN -- s16-fleet-event-source spec S3/C6: a bound on the
# per-row event text BEFORE _safe sanitization, so an oversized untrusted
# JSON field (an attacker-influenceable reason/type string) can't paint an
# unbounded blob into a fixed-height panel.
my $EVENT_FIELD_MAX_LEN = 500;

# _event_epoch($iso_ts) -> the epoch (seconds), or undef when $ts is missing
# or unparseable. Pure UTC arithmetic (Time::Local::timegm) -- never touches
# the clock, never calls localtime, unlike the retired _event_time. PRIVATE.
sub _event_epoch {
    my ($ts) = @_;
    return undef unless defined $ts && $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/;
    my ($yr, $mo, $dy, $h, $m, $sec) = ($1, $2, $3, $4, $5, $6);
    return eval { Time::Local::timegm($sec, $m, $h, $dy, $mo - 1, $yr - 1900) };
}

# _event_epoch_of_line($json_line) -> epoch | undef. The line-level companion to
# _event_epoch, so a caller that only has raw log lines (the launcher's history
# reader) can date a group without re-implementing the JSON decode or the
# timestamp grammar. PUBLIC-ish, pure, total: any malformed input -> undef.
sub _event_epoch_of_line {
    my ($ln) = @_;
    return undef unless defined $ln && $ln =~ /\S/;
    my $rec = eval { JSON::PP->new->decode($ln) };
    return undef unless $rec && ref $rec eq 'HASH' && defined $rec->{ts};
    return _event_epoch($rec->{ts});
}

sub recent_events {
    my ($lines, $n, $localtime_fn, $now) = @_;
    $lines ||= [];
    $n = 10 if !defined $n || $n < 1;
    my $jp = JSON::PP->new;
    my @records;
    for my $ln (@$lines) {
        next unless defined $ln && $ln =~ /\S/;
        my $rec = eval { $jp->decode($ln) };
        next unless $rec && ref $rec eq 'HASH';
        my $ts    = defined $rec->{ts} ? $rec->{ts} : '';
        my $epoch = _event_epoch($ts);
        my $type = _ev_scalar($rec->{type});
        $type = 'event' if !defined $type;
        my $extra  = '';
        my $exit   = _ev_scalar($rec->{exit});
        my $state  = _ev_scalar($rec->{state});
        # s16-fleet-event-source spec S3: `pause`'s reason (and any other
        # kind's, generically -- the field isn't pause-specific) must reach
        # the rendered row, same as exit/state already do.
        my $reason = _ev_scalar($rec->{reason});
        $extra .= " exit=$exit"     if defined $exit;
        $extra .= " state=$state"   if defined $state;
        $extra .= " reason=$reason" if defined $reason;
        my ($role, $glyph) = event_style($type, $exit, $state);
        my $body = "$type$extra";
        # C6: bound an oversized untrusted field BEFORE sanitizing, so a
        # pathological JSON value can't blow up the row regardless of how
        # much of it survives control-character stripping.
        $body = substr($body, 0, $EVENT_FIELD_MAX_LEN) if length($body) > $EVENT_FIELD_MAX_LEN;
        push @records, { epoch => $epoch, body => $body, role => $role, glyph => $glyph };
    }

    # Collapse BEFORE the tail-slice, so $n bounds RENDERED rows (criterion
    # 5, spec S2.4.6 step 3).
    my $collapsed = tui::DashboardScreen::collapse_records(\@records);
    my @last = @$collapsed > $n ? @{$collapsed}[ -$n .. -1 ] : @$collapsed;

    my $now_numeric = defined($now) && !ref($now) && $now =~ /^-?\d+(?:\.\d+)?$/;
    my @ev;
    my $prev_ymd;
    my $prev_epoch;
    for my $rec (@last) {
        # WALL-CLOCK, NOT AN AGE (operator request). The column used to read
        # "5m", "11m", "7d16h" -- a relative age answers "how long ago" but
        # never "when", so two events could not be lined up against anything
        # outside this panel (a log line, a commit, a memory of what you were
        # doing). "17:43" answers both: the age is still obvious for anything
        # recent, and the absolute time is there for everything else.
        #
        # A clock makes midnight invisible, though: 00:14 renders below 23:58
        # and reads as sixteen minutes later when it is sixteen minutes into the
        # NEXT DAY. So a date divider is emitted wherever consecutive rows fall
        # on different local dates, and the session divider carries its date too.
        #
        # THE DIVIDER CARRIES THE OLDER DATE, NOT THE NEWER ONE (operator,
        # 2026-08-26: the feed showed "-- Wed 26 Aug --" sitting directly above
        # a block of 22:15 rows that were Tue 25 Aug).
        #
        # These rows are built CHRONOLOGICALLY and the panel renders them
        # NEWEST-FIRST (Dashboard::run windows `reverse @all_events`). A
        # separator is the one kind of row whose meaning depends on which side
        # of it you are on, so reversing the list moves it to the other side of
        # the boundary it marks: emitted before the first row of the new date,
        # it lands after them, heading the OLDER block instead.
        #
        # Reading a newest-first list downward, a divider introduces what
        # follows it -- so it must name the older date. Labelling it from
        # $prev_epoch rather than $rec->{epoch} is the whole fix. The list stays
        # chronological (every oracle and every consumer depends on that); only
        # the label changes, to the side it will actually head.
        #
        # The session divider is already correct for the same reason without
        # needing a change: launcher.pl builds it from $hist_last_epoch, the
        # PREVIOUS session's tail, which is exactly the block it heads once
        # reversed.
        my $ymd = defined($rec->{epoch}) ? _local_ymd($rec->{epoch}, $localtime_fn) : undef;
        if (defined($ymd) && defined($prev_ymd) && $ymd ne $prev_ymd) {
            push @ev, day_boundary_row($prev_epoch, $localtime_fn);
        }
        $prev_ymd   = $ymd            if defined $ymd;
        $prev_epoch = $rec->{epoch}   if defined $rec->{epoch};

        my @spans;
        if (defined $rec->{epoch}) {
            my $hhmm = _local_hhmm($rec->{epoch}, $localtime_fn);
            # AC19 (t/41): the time span's role is the THEME token
            # (theme_role('muted') == 'text.muted').
            $hhmm = ($now_numeric ? fmt_age($now - $rec->{epoch}) : '') unless defined $hhmm;
            push @spans, { text => tui::DashboardScreen::activity_time_text($hhmm),
                           role => tui::DashboardScreen::theme_role('muted') };
        }
        # Fix batch (package 06, review finding "Fix 1"): event_style still
        # returns a LEGACY role name (good/bad/muted/accent/value) -- that
        # classifier's own return value is pinned by t/41 AC17/AC18 and by
        # the driver's ruling that theme_role is the single translation
        # point, so it stays legacy. But this is a SPAN on the render path,
        # and sgr_for_role only honours NO_COLOR/capability for Theme role
        # names (Theme::sgr) -- a legacy name falls through to a hard-coded
        # escape that ignores both. Route through theme_role() here, at the
        # point the span is built, exactly like the time span above, so
        # NO_COLOR=1 actually degrades every span in an activity row, not
        # just the timestamp.
        my $ev_role = tui::DashboardScreen::theme_role($rec->{role});
        push @spans, { text => "$rec->{glyph} ", role => $ev_role };
        push @spans, { text => _safe($rec->{body}), role => $ev_role };
        push @spans, { text => " x$rec->{count}", role => tui::DashboardScreen::theme_role('muted') }
            if defined($rec->{count}) && $rec->{count} >= 2;
        push @ev, \@spans;
    }
    return \@ev;
}

# _alert_msgs(\%state, $rows) -> the (priority-capped) alert banner messages a
# frame will show: the container-status alert and/or the backpack-install
# warning, trimmed so they never crowd out title + >=1 body + footer. Factored
# out of compose_frame so activity_capacity can subtract the same alert rows.
sub _alert_msgs {
    my ($state, $rows) = @_;
    $state ||= {};
    my @msgs = grep { defined && length }
        ( lifecycle_alert_msg($state), _status_alert($state), $state->{install_warning} );
    # chrome (title + the footer rule + footer) plus at least one body row.
    # DERIVED from tui::Screen, never restated: the footer rule added a chrome
    # row in 2026-08, and a literal 3 here would have gone on promising a body
    # row that no longer existed.
    my $max_alert = (defined $rows ? $rows : 0) - tui::Screen::chrome_rows() - 1;
    $max_alert = 0 if $max_alert < 0;
    if (@msgs > $max_alert) {
        @msgs = $max_alert > 0 ? @msgs[0 .. $max_alert - 1] : ();
    }
    return @msgs;
}

# _fixed_region_height(\%state, $cols) -> $h (PRIVATE, pure). The single
# arithmetic mirror of the fixed (non-Activity) region's height, shared by
# activity_capacity so it agrees with what compose_frame actually renders.
#
# REBUILT (package 06, spec S2.4.9): derives panel heights from
# tui::DashboardScreen::panels() and simulates the SAME tui::Layout::place
# band-row assignment compose() makes, summing the height of every band-row
# STRICTLY BEFORE the one containing 'Recent activity' -- rather than a
# fixed "first two panels join" assumption, because tui::Layout::place's
# band width (package 05) GROWS with $cols above the breakpoint (more than
# two panels can share a row on a wide terminal), so Activity itself can
# join the same band-row as an earlier panel rather than always starting a
# fresh one. Simulating the actual placement is what keeps this in exact
# agreement with compose_frame regardless of how many panels are present.
#
# REBUILT AGAIN (package t02-wrap-on-overflow): a panel body row is no
# longer always exactly one rendered row -- tui::Screen::_render_panel now
# runs every logical line through tui::Frame::wrap_line, which emits MORE
# THAN ONE cell for a row that overflows its band's own width $w (S2.4 of
# specs/t02-wrap-on-overflow-spec.md). "1 + scalar(@$lines) + 1" (title +
# one-row-per-line + trailing blank) silently assumed a row can never grow
# taller than its own logical-line count, which stopped being true the
# moment wrapping shipped. This simulates the EXACT SAME wrap_line call
# _render_panel makes (same synthesized 2-space-indent line shape, same
# role selection, same WRAP_CONTINUATION_INDENT) using each band-row cell's
# OWN placed width ($cell->{w}, from tui::Layout::place) rather than $cols,
# because a panel sharing a band-row with another is narrower than the full
# terminal width -- the same width difference that made the 'backpack :
# ... manage' Run-panel row wrap only at cols=40, not at cols=120.
#
# REBUILT A THIRD TIME (fix-batch step 7, red-team Finding 2): the two
# rebuilds above still summed every pre-Activity band's NATURAL (unclamped)
# height, never modelling two things the real renderer (_place_and_render,
# tui/Screen.pm) does: (a) `tui::Screen::flex_reserve($body_height)` is held
# back from every PRE-flex band, and (b) a pre-flex band that would not fit
# in what is left is SKIPPED outright, not counted at its natural height.
# Both require knowing $body_height, which this function did not previously
# take. $rows is now an OPTIONAL third parameter -- callers that supply it
# (activity_capacity, below) get the capped/reserve-aware total that agrees
# with compose_frame at realistic terminal sizes (verified:
# t/77-wrap-width-regressions.t, rows=30 cols=90/120). Callers that omit it
# (t/25, t/40, t/41's direct 2-arg AC16 calls -- pre-existing, untouched
# tests) fall back to the OLD natural/uncapped total, exactly as before this
# fix-batch: not because the cap doesn't apply to them, but because without
# $rows there is no $body_height to cap against, and guessing one would risk
# a WORSE (silently wrong) prediction for those call sites rather than a
# knowingly-approximate one. This is the one part of Finding 2 this
# fix-batch leaves unmodelled: a 2-arg caller still gets the pre-existing
# (uncapped, over-estimating) approximation, not the exact renderer match.
sub _fixed_region_height {
    my ($state, $cols, $rows) = @_;
    # AC-10 (t/40): $cols undef/non-numeric/<1 must degrade to the SAME
    # stacked-layout value any other sub-breakpoint width produces (matching
    # _two_col_mode's total degradation ladder), not to 0 -- tui::Layout::
    # place() itself returns [] for an out-of-range $cols (it has no
    # "default to stacked" notion, only "cannot place at all"), so the
    # normalisation has to happen HERE, one level up, exactly as
    # _fixed_panels already normalises $cols before use.
    $cols = 80 if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/ || $cols < 1;
    my $panels = tui::DashboardScreen::panels($state, $cols);
    return 0 unless ref($panels) eq 'ARRAY' && @$panels;

    # t03-activity-column: mirror compose()'s side-column split, which happens
    # BEFORE placement -- the side panel is removed from the panel list and the
    # rest are placed into a narrower main region. Simulating placement over
    # the full list at the full width would model a screen that is not what
    # compose_frame renders, and this function exists precisely to agree with
    # it.
    my $side_w = tui::Screen::side_column_width($cols);
    my $side   = 0;
    if ($side_w > 0) {
        my @rest;
        for my $p (@$panels) {
            if (!$side && ref($p) eq 'HASH' && $p->{side}) { $side = 1; next }
            push @rest, $p;
        }
        if ($side) { $panels = \@rest; $cols = $cols - $side_w }
    }
    return 0 unless @$panels;

    my $band_rows = tui::Layout::place($panels, $cols);

    # $body_height (only when $rows was supplied) -- the SAME formula
    # activity_capacity/compose_frame use: rows - chrome (title + footer rule +
    # footer) - alert banner rows. Mirrors tui::Screen::compose's own
    # `$body_height = $rows - chrome_rows(); ... -= scalar(@banner_cells);`,
    # and reads the constant from there rather than restating it.
    my $body_height;
    if (defined $rows && !ref($rows) && $rows =~ /^-?\d+(?:\.\d+)?$/) {
        my $alerts = scalar(_alert_msgs($state, $rows));
        $body_height = int($rows) - tui::Screen::chrome_rows() - $alerts;
    }

    # Which band-row carries the 'Recent activity' (flex) panel -- mirrors
    # _place_and_render's own $flex_band scan, one level removed (there we
    # scan for `panel->{flex}`; here, as in every prior rebuild of this
    # function, for the Activity panel's title, since Activity is the one
    # flex panel this dashboard ever places).
    my $flex_band;
    for my $i (0 .. $#$band_rows) {
        my $has_activity = grep {
            ref($_) eq 'HASH' && ref($_->{panel}) eq 'HASH'
                && defined($_->{panel}{title}) && $_->{panel}{title} eq 'Recent activity'
        } @{ $band_rows->[$i] };
        if ($has_activity) { $flex_band = $i; last; }
    }
    # t03: with a side column there is no flex band in the main flow, because
    # Activity has left it. Leaving $flex_band set would stop the loop below at
    # the band Activity WOULD have occupied and under-count the fixed region by
    # everything after it -- and this function's whole contract is agreeing with
    # what compose_frame renders.
    $flex_band = undef if $side;
    my $reserve = (defined($body_height) && defined($flex_band))
        ? tui::Screen::flex_reserve($body_height) : 0;

    my $total = 0;
    my $used  = 0;
    for my $i (0 .. $#$band_rows) {
        last if defined($flex_band) && $i >= $flex_band;
        my $row = $band_rows->[$i];

        # Cap/skip (only modelled when $body_height is known): mirrors
        # _place_and_render's `$remaining = $body_height - $used - $reserve`
        # (every band here is pre-flex by construction, since the loop
        # stops at $flex_band above) and its "a pre-flex band that does not
        # fit is SKIPPED" rule.
        my $remaining;
        if (defined $body_height) {
            $remaining = $body_height - $used - $reserve;
            next if $remaining < 1;
        }

        my $row_h = 0;
        for my $cell (@$row) {
            my $panel = (ref($cell) eq 'HASH') ? $cell->{panel} : undef;
            my $w     = (ref($cell) eq 'HASH' && defined $cell->{w}
                          && !ref($cell->{w}) && $cell->{w} =~ /^-?\d+(?:\.\d+)?$/)
                      ? int($cell->{w}) : $cols;
            my $lines = (ref($panel) eq 'HASH' && ref($panel->{lines}) eq 'ARRAY') ? $panel->{lines} : [];
            my $h = 1;    # panel title row
            for my $ln (@$lines) {
                my $role = (ref($ln) eq 'HASH' && defined $ln->{role}) ? $ln->{role} : 'text.primary';
                my @elems;
                if (ref($ln) eq 'ARRAY') {
                    @elems = @$ln;
                } elsif (ref($ln) eq 'HASH' && ref($ln->{spans}) eq 'ARRAY') {
                    @elems = @{ $ln->{spans} };
                } else {
                    @elems = ($ln);
                }
                # MIRRORS tui::Screen::_render_panel's synthesized line, indent
                # included. When BODY_INDENT went to 0 and this kept prepending
                # two spaces, the predictor modelled rows two columns narrower
                # than the renderer draws them, so the fixed region "wrapped"
                # more than it does and Activity was under-allocated -- t/40's
                # AC-12 agreement check caught it immediately, which is the
                # whole reason that check exists.
                my $indent = tui::Screen::BODY_INDENT();
                my $cells = tui::Frame::wrap_line(
                    ($indent > 0
                        ? [ { text => (' ' x $indent), role => 'text.primary' }, @elems ]
                        : [ @elems ]),
                    $role, $w, tui::Screen::WRAP_CONTINUATION_INDENT()
                );
                $h += (ref($cells) eq 'ARRAY') ? scalar(@$cells) : 1;
            }
            $h += 1;      # trailing blank row (_render_panel's own padding)
            $row_h = $h if $h > $row_h;
        }
        # _render_panel bounds EVERY cell's rendered length at $remaining
        # (its own $maxh argument), so the row's actual rendered height --
        # the max across its cells -- is exactly min(natural, $remaining),
        # never the uncapped natural value. Only enforced when $remaining is
        # known (i.e. $rows was supplied).
        $row_h = $remaining if defined($remaining) && $row_h > $remaining;
        $total += $row_h;
        $used  += $row_h;
    }
    return $total;
}

# activity_capacity(\%state, $rows, $cols) -> how many EVENT rows the Activity
# panel has room for, mirroring compose_frame's budget: total rows minus the
# title + footer + alert banners + the fixed region (_fixed_region_height,
# mode-aware since s05) + the Activity panel's own title. Used by the loop to
# clamp the scroll offset and to window the events (so scrolling can't run off
# the end). Unchanged by s06-panel-semantics: it never subtracted a hint row
# (activity_window's own $visible arithmetic did, and no longer does -- see
# activity_window). Returns >= 0. PUBLIC.
sub activity_capacity {
    my ($state, $rows, $cols) = @_;
    $state ||= {};

    # t03-activity-column: when Activity is the SIDE COLUMN it is no longer
    # in the band flow at all, so none of the arithmetic below applies to it.
    # Its height is the whole body -- $rows minus the title and footer rows --
    # and alerts do not shorten it, because banners live in the main region
    # (see tui::Screen::compose's own note on why the side column's height
    # must not track what is happening elsewhere on the screen).
    #
    # THIS FUNCTION AND compose_frame MUST AGREE OR SCROLLING BREAKS: capacity
    # is what the launcher uses to decide how many events to hand the panel.
    # Under-report and the column renders short with blank rows below the last
    # event; over-report and the scroll arithmetic runs off a number the screen
    # never had. The pre-existing comment above already stakes this function on
    # that agreement, so the side-column case has to be handled here rather
    # than left to the fixed-region model that no longer describes it.
    $rows = 0 if !defined $rows || ref($rows) || $rows !~ /^-?\d+(?:\.\d+)?$/ || $rows < 0;
    if (tui::Screen::side_column_width($cols) > 0) {
        # THE COLUMN NOW STARTS AT ROW 0. It used to begin under the screen
        # title, so its height was rows - title - footer - its own panel title.
        # tui::Screen runs it from the very top of the viewport (the header
        # occupies the main region only), so the title row is no longer
        # subtracted -- one more row of events, which is the entire point of
        # that change and would otherwise be an off-by-one between this
        # predictor and the renderer. t/40's AC-12 agreement check caught it on
        # the first run, as it is designed to.
        # chrome_rows() - 1: the side column starts at row 0, so it pays the
        # chrome MINUS the title row (which occupies the main region only). The
        # footer rule is NOT one of the rows it escapes -- it spans the whole
        # terminal, below both regions -- so it has to be in this subtraction or
        # capacity over-reports by one and the scroll runs off the screen.
        my $cap = int($rows) - (tui::Screen::chrome_rows() - 1) - 1;   # chrome below row 0, and the panel's own title
        return $cap > 0 ? $cap : 0;
    }

    # Fix batch (package 06, red-team finding, latent/low): same guard as
    # _fixed_region_height's cols normalisation and compose_frame's own
    # rows/cols normalisation above -- a ref or non-numeric $rows would
    # otherwise warn under `use warnings` on the bare `< 0` comparison.
    $rows = 0 if !defined $rows || ref($rows) || $rows !~ /^-?\d+(?:\.\d+)?$/ || $rows < 0;
    my $alerts = scalar(_alert_msgs($state, $rows));
    my $body_h = $rows - tui::Screen::chrome_rows() - $alerts;   # title + footer rule + footer
    my $fixed  = _fixed_region_height($state, $cols, $rows);
    my $cap = $body_h - $fixed - 1;               # -1 = Activity panel title

    # The Activity panel is tui::Screen's FLEX band, so it is guaranteed a
    # reservation the fixed region cannot eat. Without this floor, capacity
    # under-reports on a short terminal (or one with a tall Run panel) while
    # compose_frame goes on rendering the reserved rows — and the launcher's
    # scroll arithmetic runs off a number that disagrees with the screen.
    #
    # The reservation is READ from tui::Screen, never restated here. The
    # comment above this function has always claimed it "agrees with what
    # compose_frame actually renders"; a second copy of the constant is how
    # that claim quietly stops being true.
    my $floor = tui::Screen::flex_reserve($body_h) - 1;   # -1 = the panel title
    $cap = $floor if $cap < $floor;
    return $cap > 0 ? $cap : 0;
}

# activity_window(\@events_desc, $offset, $capacity, $w) -> the Activity
# panel's view:
#   { lines => [...], offset => clamped scroll position,
#     max_offset => clamp ceiling, above => $n, below => $n }
# s06-panel-semantics (Decision #19): no row is reserved for a hint anymore
# ($visible == $cap); when the events overflow, an inline scroll indicator
# (scroll_indicator) is overlaid onto the FIRST (above>0) and/or LAST
# (below>0) visible row via _justify_spans, which preserves each row's own
# colors and guarantees the overlaid row is exactly $w display columns. When
# $cap == 1 and both above>0 and below>0, the single row gets ONE combined
# overlay, never two. $w undef/<=0 -> no overlay is attempted (rows pass
# through untouched) but above/below/offset/max_offset are still computed.
# Pure / unit-tested.
sub activity_window {
    my ($desc, $offset, $cap, $w) = @_;
    $desc ||= [];
    my $total = scalar @$desc;
    $cap    = 0 if !defined $cap    || $cap !~ /^-?\d+(?:\.\d+)?$/    || $cap < 0;
    $offset = 0 if !defined $offset || $offset !~ /^-?\d+(?:\.\d+)?$/ || $offset < 0;

    return { lines => [], offset => 0, max_offset => 0, above => 0, below => 0 }
        if $total == 0 || $cap == 0;

    if ($total <= $cap) {                      # everything fits: no scroll/overlay
        return { lines => [ @$desc ], offset => 0, max_offset => 0, above => 0, below => 0 };
    }

    my $visible = $cap;                        # Decision #19: no reserved hint row
    my $max_offset = $total - $visible;
    $max_offset = 0 if $max_offset < 0;
    $offset = $max_offset if $offset > $max_offset;
    my $end = $offset + $visible - 1;
    $end = $total - 1 if $end > $total - 1;

    my @lines = @{$desc}[$offset .. $end];
    my $above = $offset;
    my $below = $total - 1 - $end;

    if (defined $w && $w =~ /^-?\d+(?:\.\d+)?$/ && $w > 0) {
        if ($cap == 1 && $above > 0 && $below > 0) {
            # A single row is simultaneously first and last: ONE combined
            # overlay, never overlaid twice.
            $lines[0] = _justify_spans(spanify($lines[0], 'body'),
                                        scroll_indicator($above, $below), $w, 'muted');
        } else {
            if ($above > 0) {
                $lines[0] = _justify_spans(spanify($lines[0], 'body'),
                                            scroll_indicator($above, 0), $w, 'muted');
            }
            if ($below > 0) {
                $lines[-1] = _justify_spans(spanify($lines[-1], 'body'),
                                             scroll_indicator(0, $below), $w, 'muted');
            }
        }
    }

    return {
        lines => \@lines,
        offset => $offset, max_offset => $max_offset,
        above => $above, below => $below,
    };
}

# blueprint_runs_dirs($data_root) -> the runs/ dir of every blueprint under
# $data_root/blueprints/. opendir (not glob) — safe for spaces / André paths.
sub blueprint_runs_dirs {
    my ($data_root) = @_;
    return () if !defined $data_root;
    my $bp = "$data_root/blueprints";
    return () unless -d $bp;
    opendir(my $dh, $bp) or return ();
    my @dirs;
    for my $e (sort readdir $dh) {
        next if $e eq '.' || $e eq '..';
        my $runs = "$bp/$e/runs";
        push @dirs, $runs if -d $runs;
    }
    closedir $dh;
    return @dirs;
}

# shutdown_targets($project_path) -> the `runs/.shutdown` path for every
# blueprint under the project. Mirrors heartbeat.sh's signal_graceful_shutdown
# (host side): the A4 gate reads each blueprint's runs/.shutdown.
sub shutdown_targets {
    my ($project) = @_;
    return () if !defined $project;
    return map { "$_/.shutdown" } blueprint_runs_dirs("$project/.ccpraxis-local-data");
}

# write_shutdown_signals(@targets) -> count written. Idempotent touch.
sub write_shutdown_signals {
    my (@targets) = @_;
    my $n = 0;
    for my $t (@targets) {
        if (open my $fh, '>', $t) { close $fh; $n++; }
    }
    return $n;
}

# ===========================================================================
# s11-lifecycle-stop: stop-runs / full-shutdown staged driver (spec 08 S2.3-6)
# ===========================================================================

# _lifecycle_stage_catalog() -> @stages (PRIVATE, pure). The single source of
# the 4 pinned lifecycle stages (id/label), shared by stop_runs_plan and
# full_shutdown_plan so the two can never drift apart (spec 08 S2.3). Fresh
# hashrefs every call -- callers can never mutate a shared structure.
sub _lifecycle_stage_catalog {
    return (
        { id => 'signal-runs',    label => 'signal butler runs' },
        { id => 'await-quiet',    label => 'wait for runs to wind down' },
        { id => 'stop-container', label => 'stop container' },
        { id => 'stop-machine',   label => 'stop podman machine' },
    );
}

# stop_runs_plan(\%state) -> \@stages (PUBLIC, pure). Always exactly the first
# two pinned stages (signal-runs, await-quiet), for ANY input including
# undef/{} -- spec 08 S2.3. Never dies; no system/qx/backtick/exec (AC-8
# source scan).
sub stop_runs_plan {
    my @all = _lifecycle_stage_catalog();
    return [ @all[0, 1] ];
}

# full_shutdown_plan(\%state) -> \@stages (PUBLIC, pure). The first three
# pinned stages, plus stop-machine iff $state->{machine_capable} is truthy.
# undef / non-hashref input is treated as {} (never dies) -- spec 08 S2.3.
sub full_shutdown_plan {
    my ($state) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my @all  = _lifecycle_stage_catalog();
    my @plan = @all[0, 1, 2];
    push @plan, $all[3] if $state->{machine_capable};
    return \@plan;
}

# _chomp_err($msg) -> a single-line, trailing-whitespace-trimmed error string
# (PRIVATE, pure). Shared by await_quiet and run_stages so a dying seam's
# $@ never leaks an embedded newline into a `detail` field.
sub _chomp_err {
    my ($e) = @_;
    return '' unless defined $e;
    $e =~ s/\n/ /g;
    $e =~ s/\s+$//;
    return $e;
}

# _cap_name_list(\@names, $cap) -> "$name1, $name2, $name3, +N more" (PRIVATE,
# pure). Caps an offending-container-name list at $cap (default 3) entries.
sub _cap_name_list {
    my ($names, $cap) = @_;
    $cap = 3 unless defined $cap;
    my @n = @{ $names || [] };
    return join(', ', @n) if @n <= $cap;
    my @head = @n[0 .. $cap - 1];
    my $more = @n - $cap;
    return join(', ', @head) . ", +$more more";
}

# await_quiet(%opts) -> \%result (PUBLIC; seam-driven, never dies). Bounded
# poll loop used by run_stages' await-quiet stage (spec 08 S2.4). No real
# sleeping happens here -- sleep_for is an injected seam the caller controls.
# %opts: probe, now, sleep_for, timeout (default 60), interval (default 1).
sub await_quiet {
    my (%o) = @_;
    my $probe     = $o{probe};
    my $now       = ref($o{now})       eq 'CODE' ? $o{now}       : sub { time };
    my $sleep_for = ref($o{sleep_for}) eq 'CODE' ? $o{sleep_for} : sub { };
    my $timeout   = defined $o{timeout}  ? $o{timeout}  : 60;
    my $interval  = defined $o{interval} ? $o{interval} : 1;

    if (ref($probe) ne 'CODE') {
        return { ok => 1, outcome => 'no-probe', polls => 0, waited => 0, detail => '' };
    }

    my $start      = $now->();
    my $polls      = 0;
    my $err_detail = '';
    while (1) {
        $polls++;
        my $r = eval { $probe->() };
        my ($quiet, $detail) = (0, '');
        if ($@) {
            $err_detail = _chomp_err($@);
        }
        elsif (ref($r) eq 'HASH') {
            $quiet  = $r->{quiet};
            $detail = defined $r->{detail} ? $r->{detail} : '';
        }
        else {
            $quiet = $r;
        }

        my $full_detail = $detail;
        $full_detail .= ($full_detail ne '' ? ' ' : '') . $err_detail if length $err_detail;

        if ($quiet) {
            return { ok => 1, outcome => ($polls == 1 ? 'already-quiet' : 'quiet'),
                     polls => $polls, waited => $now->() - $start, detail => $full_detail };
        }
        my $waited = $now->() - $start;
        if ($waited >= $timeout) {
            return { ok => 0, outcome => 'timeout', polls => $polls, waited => $waited, detail => $full_detail };
        }
        $sleep_for->($interval);
    }
}

# run_stages(%opts) -> \%result (PUBLIC; seam-driven, never dies). The staged
# driver behind stop-runs / full-shutdown (spec 08 S2.5). Every real side
# effect goes through an injected seam -- no podman call ever appears in this
# function. The machine guard (Decision #15) is safety-critical and
# fail-closed: see the stop-machine branch below.
sub run_stages {
    my (%o) = @_;
    my $plan = (ref($o{plan}) eq 'ARRAY') ? $o{plan} : [];
    my $mode = defined $o{mode} ? $o{mode} : '';
    my $self_container = defined $o{self_container} ? $o{self_container} : '';
    my $await_timeout  = defined $o{await_timeout}  ? $o{await_timeout}  : 60;
    my $await_interval = defined $o{await_interval} ? $o{await_interval} : 1;
    my $status_cb = (ref($o{status_cb}) eq 'CODE') ? $o{status_cb} : sub { };
    my $log_cb    = (ref($o{log_cb})    eq 'CODE') ? $o{log_cb}    : sub { };

    my $n = scalar @$plan;
    my @stages;
    my $machine_stopped = 0;
    my @others;
    my $others_known = 0;

    eval { $log_cb->('lifecycle_start', { mode => $mode, stages => $n }); };

    my $idx = 0;
    for my $stage_in (@$plan) {
        $idx++;
        my $stage = (ref($stage_in) eq 'HASH') ? $stage_in : {};
        my $id    = defined $stage->{id}    ? $stage->{id}    : 'unknown';
        my $label = defined $stage->{label} ? $stage->{label} : '';

        eval {
            $status_cb->({ active => 1, mode => $mode, stage => $id, label => $label,
                           index => $idx, total => $n, state => 'running', detail => '' });
        };

        my ($state, $detail) = ('skipped', '');

        eval {
            if ($id eq 'signal-runs') {
                if (ref($o{signal_runs}) eq 'CODE') {
                    my $r = eval { $o{signal_runs}->() };
                    if ($@) { $state = 'fail'; $detail = _chomp_err($@); }
                    else {
                        my $cnt = (defined $r && !ref($r)) ? ($r + 0) : 0;
                        $state = 'ok'; $detail = "$cnt run(s) signalled";
                    }
                }
                else { $detail = 'signal_runs seam not provided'; }
            }
            elsif ($id eq 'await-quiet') {
                my $r;
                if (ref($o{await_quiet}) eq 'CODE') {
                    $r = eval { $o{await_quiet}->() };
                }
                else {
                    $r = eval {
                        await_quiet(probe => $o{quiet_probe}, now => $o{now}, sleep_for => $o{sleep_for},
                                    timeout => $await_timeout, interval => $await_interval);
                    };
                }
                if ($@) { $state = 'fail'; $detail = _chomp_err($@); }
                else {
                    my $outcome = (ref($r) eq 'HASH') ? ($r->{outcome} // '') : '';
                    my $rdetail = (ref($r) eq 'HASH') ? ($r->{detail}  // '') : '';
                    if    ($outcome eq 'timeout')  { $state = 'timeout'; $detail = length($rdetail) ? $rdetail : 'timed out waiting for runs to quiet'; }
                    elsif ($outcome eq 'no-probe') { $state = 'skipped'; $detail = length($rdetail) ? $rdetail : 'no quiet probe provided'; }
                    else                           { $state = 'ok';      $detail = $rdetail; }
                }
            }
            elsif ($id eq 'stop-container') {
                if (ref($o{stop_container}) eq 'CODE') {
                    my $r = eval { $o{stop_container}->() };
                    if ($@) { $state = 'fail'; $detail = _chomp_err($@); }
                    else {
                        my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                        if ($rr->{ok}) { $state = 'ok'; $detail = defined $rr->{detail} ? $rr->{detail} : ''; }
                        else { $state = 'fail'; $detail = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : 'container stop failed'; }
                    }
                }
                else { $detail = 'stop_container seam not provided'; }
            }
            elsif ($id eq 'stop-machine') {
                my ($cstage) = grep { $_->{id} eq 'stop-container' } @stages;
                # ne 'ok' (not eq 'fail'): defence in depth. If stop_container
                # ever ended anything other than a confirmed 'ok' -- e.g.
                # 'skipped' because the seam was absent -- this must still
                # block the machine stop while our own container may still be
                # running, not just when it explicitly failed.
                if ($cstage && $cstage->{state} ne 'ok') {
                    $state = 'skipped';
                    $detail = 'container stop failed; podman machine left running';
                }
                else {
                    my $list;
                    my $enum_ok = 0;
                    if (ref($o{list_containers}) eq 'CODE') {
                        my $r = eval { $o{list_containers}->() };
                        if (!$@ && ref($r) eq 'ARRAY') { $list = $r; $enum_ok = 1; }
                    }
                    if (!$enum_ok) {
                        $state = 'skipped';
                        $detail = 'could not enumerate running containers; podman machine left running';
                        $others_known = 0;
                    }
                    else {
                        $others_known = 1;
                        @others = grep { defined($_) && length($_) && $_ ne $self_container }
                                  map { my $x = $_; $x =~ s/^\s+|\s+$//g if defined $x; $x } @$list;
                        if (@others == 0) {
                            if (ref($o{stop_machine}) eq 'CODE') {
                                my $r = eval { $o{stop_machine}->() };
                                if ($@) { $state = 'fail'; $detail = _chomp_err($@); }
                                else {
                                    my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                                    if ($rr->{ok}) { $state = 'ok'; $detail = defined $rr->{detail} ? $rr->{detail} : ''; $machine_stopped = 1; }
                                    else { $state = 'fail'; $detail = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : 'podman machine stop failed'; }
                                }
                            }
                            else { $detail = 'stop_machine seam not provided'; }
                        }
                        else {
                            $state = 'skipped';
                            $detail = 'other container(s) running: ' . _cap_name_list(\@others, 3);
                        }
                    }
                }
            }
            else {
                $state = 'skipped';
                $detail = 'unknown stage';
            }
        };
        if ($@) { $state = 'fail'; $detail = _chomp_err($@); }

        push @stages, { id => $id, label => $label, state => $state, detail => $detail };

        eval {
            $status_cb->({ active => 1, mode => $mode, stage => $id, label => $label,
                           index => $idx, total => $n, state => $state, detail => $detail });
        };
        eval {
            $log_cb->('lifecycle_stage', { mode => $mode, stage => $id, index => $idx, total => $n,
                                            state => $state, detail => $detail });
        };
    }

    my $ok        = (grep { $_->{state} eq 'fail' } @stages) ? 0 : 1;
    my $timed_out = (grep { $_->{state} eq 'timeout' } @stages) ? 1 : 0;

    my ($failed) = grep { $_->{state} eq 'fail' } @stages;
    my @clauses;
    if ($failed) {
        push @clauses, "$failed->{id} failed" . (length($failed->{detail}) ? " ($failed->{detail})" : '');
    }
    if ($mode eq 'stop-runs') {
        push @clauses, 'runs stopped' unless $failed;
        push @clauses, 'container stays up';
    }
    else {
        push @clauses, 'container stopped' if !$failed;
        if ($machine_stopped) {
            push @clauses, 'machine stopped';
        }
        elsif (@others) {
            push @clauses, 'machine left running (' . scalar(@others) . ' other container(s) running)';
        }
        elsif ($failed) {
            push @clauses, 'machine left running (container stop failed)';
        }
        elsif (!$others_known) {
            push @clauses, 'machine left running (could not verify other containers)';
        }
    }
    push @clauses, 'timed out' if $timed_out;
    my $summary = join('; ', @clauses);
    $summary = 'lifecycle sequence completed' unless length $summary;

    eval {
        $status_cb->({ active => 0, mode => $mode, stage => undef, label => undef,
                        index => $n, total => $n, state => 'done', detail => '', summary => $summary });
    };

    my %done_fields = (mode => $mode, ok => $ok, timed_out => $timed_out, summary => $summary);
    if ($mode eq 'full-shutdown') {
        $done_fields{machine_stopped} = $machine_stopped;
        $done_fields{others}          = scalar(@others);
        $done_fields{others_known}    = $others_known;
    }
    eval { $log_cb->('lifecycle_done', \%done_fields); };

    return {
        mode            => $mode,
        ok              => $ok,
        timed_out       => $timed_out,
        stages          => \@stages,
        machine_stopped => $machine_stopped,
        others          => [ @others ],
        others_known    => $others_known,
        summary         => $summary,
    };
}

# lifecycle_alert_msg(\%state) -> $string | undef (PUBLIC, pure; never dies).
# Renders $state->{lifecycle} (the run_stages \%progress the loop stashes
# verbatim) as a single alert-banner line -- the FIRST message _alert_msgs
# returns (spec 08 S2.6). Missing keys degrade to '?'. Does not re-cap any
# name list embedded in summary/detail -- that is run_stages' job (S2.5);
# this sub only relays what it is given.
sub lifecycle_alert_msg {
    my ($state) = @_;
    return undef unless ref($state) eq 'HASH';
    my $lc = $state->{lifecycle};
    return undef unless ref($lc) eq 'HASH';

    # Registering 'recover' is REQUIRED, not decorative: the fallback below is a
    # defence against an unknown mode, and an unregistered mode would render the
    # banner off the raw token rather than a deliberate label.
    my %mode_label = ('stop-runs' => 'stop runs', 'full-shutdown' => 'full shutdown',
                      'recover'   => 'recover');
    my $mode  = defined $lc->{mode} ? $lc->{mode} : '';
    my $label = $mode_label{$mode};
    $label = (length($mode) ? $mode : '?') unless defined $label;

    if ($lc->{active}) {
        my $index = defined $lc->{index} ? $lc->{index} : '?';
        my $total = defined $lc->{total} ? $lc->{total} : '?';
        my $slabel = defined $lc->{label} ? $lc->{label} : '?';
        my $sstate = defined $lc->{state} ? $lc->{state} : '?';
        return "$label $index/$total: $slabel - $sstate";
    }
    my $summary = defined $lc->{summary} ? $lc->{summary} : '?';
    return "$label done: $summary";
}

# ===========================================================================
# s12-lifecycle-relaunch-recovery: the [l] relaunch/recover staged driver
# (spec 09 S2.4-S2.6). Everything below is PURE or seam-driven: NO podman call,
# no system/exec/qx/backtick, no filesystem, no clock. The impure half lives in
# launcher.pl's recover_container (the same split s11 uses for run_stages).
# ===========================================================================

# _recover_stage_catalog() -> @stages (PRIVATE, pure). The single source of the
# 4 pinned recovery stages (id/label) -- nothing else may hardcode them. Fresh
# hashrefs every call, so a caller mutating one plan can never poison the next
# (the _lifecycle_stage_catalog mould).
sub _recover_stage_catalog {
    return (
        { id => 'machine-status',     label => 'check podman machine' },
        { id => 'machine-start',      label => 'start podman machine' },
        { id => 'container-start',    label => 'start container' },
        { id => 'heartbeat-reattach', label => 're-attach heartbeat' },
    );
}

# recover_plan(\%state) -> \@stages (PUBLIC, pure; never dies -- undef/non-
# hashref is treated as {}). All four stages when $state->{machine_capable} is
# truthy, else stages 3+4 only (docker / Linux-native podman have no machine).
#
# The ORDER is load-bearing, not cosmetic. machine-status must precede
# container-start because an empty container probe is ambiguous (removed vs
# unreadable) until the machine's liveness is known -- that is exactly what
# classify_container_state keys off. heartbeat-reattach must follow
# container-start IMMEDIATELY so the heartbeat is re-established promptly: the
# container entrypoint reaps itself once /tmp/.launcher-alive goes stale, and a
# stage inserted between the two would let a recovery start the container and
# then dawdle before re-arming the sentinel it depends on.
#
# MINOR-2 (red-team step 6) -- this used to justify the adjacency with a "~10s
# startup grace". That number was fiction, off by 60x: container/heartbeat.sh:26-27
# sets HB=600 and STARTUP_GRACE=600, i.e. TEN MINUTES. The ordering is still
# right (touching early is unconditionally correct and costs nothing); only the
# cliff it invoked never existed. Do not reason about stage insertion from a
# 10-second budget.
sub recover_plan {
    my ($state) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my @all = _recover_stage_catalog();
    return $state->{machine_capable} ? [ @all ] : [ @all[2, 3] ];
}

# classify_container_state($raw_status, $machine_state) -> running|stopped|
# absent|unknown (PUBLIC, pure; never dies).
#
# The single normalizer for the TWO "no such container" sentinels the launcher
# carries for one and the same fact: container_status() returns '' where
# gather() returns the synthetic 'unknown'. Both -- and undef -- mean "no
# reading" here, and the machine state is what disambiguates them: with the
# machine up (or on a platform that has none) an empty probe really does mean
# the container is gone; with the machine down it means we simply cannot tell,
# and a recovery must try the start rather than declare a rebuild.
sub classify_container_state {
    my ($raw_status, $machine_state) = @_;
    my $raw = defined $raw_status ? lc $raw_status : '';
    $raw =~ s/^\s+//;
    $raw =~ s/\s+$//;
    my $m = defined $machine_state ? lc $machine_state : '';
    $m =~ s/^\s+//;
    $m =~ s/\s+$//;
    return 'running' if $raw eq 'running';
    return 'stopped' if length($raw) && $raw ne 'unknown';   # exited/created/paused/dead/...
    return 'absent'  if $m eq 'running' || $m eq 'n/a';      # probe worked; nothing there
    return 'unknown';                                        # machine down/absent -> can't tell
}

# _machine_boolish($v) -> 1 | 0 | undef (PRIVATE, pure). The ONE place a
# podman-machine liveness flag is turned into a decision. undef means "this
# field was absent or says nothing I recognise" -- deliberately distinct from 0,
# because the caller must be able to fall through to the next spelling and
# ultimately to 'unknown' instead of inventing a confident 'stopped'.
#
# Perl truthiness alone is NOT good enough here (red-team step 6, MAJOR-2): a
# podman build emitting the JSON STRING "false" reads as true under `if ($v)`,
# so a stopped machine would report running. A JSON::PP::Boolean is a blessed
# ref with an overloaded numification, so it is asked directly.
sub _machine_boolish {
    my ($v) = @_;
    return undef unless defined $v;
    return ($v ? 1 : 0) if ref $v;                  # JSON::PP::Boolean (overloaded)
    return 1 if $v =~ /^\s*(?:1|true|yes|on)\s*$/i;
    return 0 if $v =~ /^\s*(?:0|false|no|off)?\s*$/i;
    return undef;
}

# classify_machine_state($raw, $capable) -> running|starting|stopped|absent|
# unknown|n/a (PUBLIC, pure; never dies, never warns).
#
#   $raw      the raw bytes of `podman machine list --format json`. undef and ''
#             are LEGAL inputs -- the probe failed, timed out, or was never run.
#   $capable  does this platform HAVE a podman machine at all? (false on docker
#             and on Linux-native podman, where 'n/a' is the honest answer and
#             wins over everything the bytes might say).
#
# This is the pure half of launcher.pl's _machine_state, split out so it can be
# tested behaviourally -- launcher.pl is not loadable by a test, which is exactly
# how four MAJOR defects survived a green suite (red-team step 6).
#
# SELECTION (MAJOR-1). `podman machine start` takes no name and acts on the
# DEFAULT machine, so the reading must describe the default machine, never "any
# machine that happens to be running". The rule is `parse_machine_list`'s in
# Resources.pm (:97-114) verbatim: the element with a truthy `Default` wins
# regardless of position, else the first HASH element. A host with a second,
# hand-made machine running while ours is down must read 'stopped' -- reading
# 'running' there routes the user into a rebuild that `rm -f`s a healthy
# container.
#
# FIELD READ (MAJOR-2/MAJOR-3). `Starting` is read FIRST and is its own answer:
# a machine mid-auto-start after a host resume is neither running nor stopped,
# and calling it 'stopped' makes [l] fire a `podman machine start` that exits 125.
# `Running` is next, boolean-ish only. The `State` / `Status` spellings other
# podman versions emit are the fallback. If NONE of the four is present the
# answer is 'unknown' -- never a confident 'stopped', which would paint a
# permanent red "podman machine is stopped" banner over a healthy sandbox.
sub classify_machine_state {
    my ($raw, $capable) = @_;
    return 'n/a' unless $capable;
    return 'unknown' unless defined $raw && !ref($raw) && length $raw;

    my $data = eval { JSON::PP::decode_json($raw) };
    return 'unknown' if $@ || ref($data) ne 'ARRAY';
    return 'absent' unless @$data;

    my ($pick, $first);
    for my $el (@$data) {
        next unless ref($el) eq 'HASH';
        $first = $el unless defined $first;
        if ($el->{Default}) { $pick = $el; last; }
    }
    $pick = $first unless defined $pick;
    return 'unknown' unless ref($pick) eq 'HASH';   # nothing selectable in the list

    my $starting = _machine_boolish($pick->{Starting});
    return 'starting' if defined $starting && $starting;
    my $running = _machine_boolish($pick->{Running});
    return 'running' if defined $running && $running;
    return 'stopped' if defined $running;

    for my $k (qw(State Status)) {
        my $v = $pick->{$k};
        next unless defined $v && !ref($v);
        $v = lc $v;
        $v =~ s/^\s+//;
        $v =~ s/\s+$//;
        next unless length $v;
        return 'running'  if $v eq 'running';
        return 'starting' if $v eq 'starting';
        return 'stopped';
    }
    return 'unknown';   # unrecognised schema -> say so, do not guess 'stopped'
}

# _recover_status_alias($state) -> the ledger's {status} vocabulary (PRIVATE,
# pure). s11's {state} stays canonical (lifecycle_alert_msg and s11's immutable
# oracle read it); this alias is what the recovery-seam contract promises s03.
# 'timeout' has no ledger equivalent and collapses to 'failed'.
sub _recover_status_alias {
    my ($st) = @_;
    $st = '' unless defined $st;
    return 'ok'      if $st eq 'ok';
    return 'skipped' if $st eq 'skipped';
    return 'failed';
}

# _recover_machine_vocab($s) -> one of running|starting|stopped|absent|unknown|
# n/a (PRIVATE, pure). The vocabulary is classify_machine_state's, unchanged.
# Anything a machine_status seam reports outside it degrades to 'unknown', which
# is deliberately NOT fatal -- the machine-start stage then simply attempts the
# start, and a FAILED attempt on that uncertain reading does not abort the
# recovery either (see the machine-start branch of run_recover_stages).
sub _recover_machine_vocab {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s = lc $s;
    return $s if $s eq 'running'  || $s eq 'starting' || $s eq 'stopped'
              || $s eq 'absent'   || $s eq 'n/a';
    return 'unknown';
}

# _recover_pre_detail($id) -> the detail carried by a stage's PRE-'running'
# interface update (PRIVATE, pure). Only machine-start has one, and it is
# load-bearing rather than decorative: recovery runs synchronously inside the
# input drain, so on the platform that actually needs a machine start
# (Windows/WSL2, where _run_timed's SIGALRM bound degrades to a no-op) this
# frame is the LAST thing painted until podman returns. The freeze is therefore
# announced by the frame that freezes, instead of looking like a hang.
sub _recover_pre_detail {
    my ($id) = @_;
    $id = '' unless defined $id;
    return 'this may take a minute; the dashboard is frozen and will not repaint until podman returns'
        if $id eq 'machine-start';
    return '';
}

# run_recover_stages(%opts) -> \%result (PUBLIC; seam-driven, never dies). The
# recovery engine behind recover_container (spec 09 S2.6). Every side effect
# goes through an injected seam and every seam/callback call is eval-wrapped, so
# neither a dying seam nor a dying status_cb/log_cb can abort a run or escape
# into the TUI's input drain.
#
# It STOPS on the first failing stage -- unlike s11's run_stages, which walks
# the whole plan. A shutdown sequence wants every remaining stage attempted; a
# recovery is a dependency chain (no machine -> no container -> no heartbeat),
# so continuing past a failure would only produce a cascade of derived failures
# that bury the one the user has to act on. Stages that never ran are OMITTED
# from `stages` (so "did stage N run?" is directly observable); `total` in the
# emits stays the PLANNED count.
#
# %opts: plan, mode ('recover'), reason, state (the gathered dashboard state),
#        machine_status / machine_start / container_start / container_create /
#        heartbeat_reattach (seams), status_cb, log_cb.
sub run_recover_stages {
    my (%o) = @_;
    my $plan   = (ref($o{plan}) eq 'ARRAY') ? $o{plan} : [];
    my $mode   = defined $o{mode}   ? $o{mode}   : 'recover';
    my $reason = defined $o{reason} ? $o{reason} : '';
    my $state  = (ref($o{state}) eq 'HASH') ? $o{state} : {};
    my $status_cb = (ref($o{status_cb}) eq 'CODE') ? $o{status_cb} : sub { };
    my $log_cb    = (ref($o{log_cb})    eq 'CODE') ? $o{log_cb}    : sub { };

    my $n = scalar @$plan;
    my @stages;
    my $mstate = 'n/a';     # machine state observed in THIS run; 'n/a' until probed
    my $created = 0;        # the container-start stage went through container_create
    my $failed_stage;
    my $error;

    eval { $log_cb->('lifecycle_start', { mode => $mode, stages => $n, reason => $reason }); };

    my $idx = 0;
    for my $stage_in (@$plan) {
        $idx++;
        my $stage = (ref($stage_in) eq 'HASH') ? $stage_in : {};
        my $id    = defined $stage->{id}    ? $stage->{id}    : 'unknown';
        my $label = defined $stage->{label} ? $stage->{label} : '';

        eval {
            $status_cb->({ active => 1, mode => $mode, reason => $reason, stage => $id, label => $label,
                           index => $idx, total => $n, state => 'running',
                           detail => _recover_pre_detail($id) });
        };

        my ($st, $detail) = ('skipped', '');

        eval {
            if ($id eq 'machine-status') {
                if (ref($o{machine_status}) eq 'CODE') {
                    my $r = eval { $o{machine_status}->() };
                    if ($@) { $st = 'fail'; $detail = _chomp_err($@); $mstate = 'unknown'; }
                    else {
                        my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                        $mstate = _recover_machine_vocab($rr->{state});
                        my $d = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : '';
                        # An 'unknown' reading with ok => 1 is NOT fatal: the
                        # container probe may still resolve on its own.
                        if ($rr->{ok}) { $st = 'ok';   $detail = "machine $mstate"; }
                        else           { $st = 'fail'; $detail = length($d) ? $d : 'machine status probe failed'; }
                    }
                }
                else {
                    $st = 'skipped'; $mstate = 'n/a';
                    $detail = 'machine_status seam not provided';
                }
            }
            elsif ($id eq 'machine-start') {
                # 'starting' skips for the SAME reason 'running' does (MAJOR-3):
                # `podman machine start` against a VM that is already running OR
                # ALREADY STARTING exits 125, and that failure would abort the
                # whole recovery at stage 2 -- in the host-resume case the control
                # exists for.
                if    ($mstate eq 'running')  { $st = 'skipped'; $detail = 'machine already running'; }
                elsif ($mstate eq 'starting') { $st = 'skipped'; $detail = 'machine already starting'; }
                elsif ($mstate eq 'n/a')      { $st = 'skipped'; $detail = 'no podman machine on this platform'; }
                elsif (ref($o{machine_start}) eq 'CODE') {
                    my $r = eval { $o{machine_start}->() };
                    if ($@) { $st = 'fail'; $detail = _chomp_err($@); }
                    else {
                        my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                        my $d = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : '';
                        if    ($rr->{ok})      { $st = 'ok';      $detail = length($d) ? $d : 'machine started'; }
                        elsif ($rr->{timeout}) { $st = 'timeout'; $detail = length($d) ? $d : 'podman machine start timed out'; }
                        # A failed start on an UNCERTAIN reading is NOT fatal
                        # (MAJOR-3). We do not actually know the machine is down;
                        # container-start is the authoritative test of that, and
                        # an advisory probe must never gate the repair. The failure
                        # is still REPORTED -- its text is carried into the detail,
                        # not swallowed -- it just does not stop the sequence. A
                        # CONFIDENT 'stopped'/'absent' reading keeps failing hard:
                        # there we know the machine is down and could not start it.
                        elsif ($mstate eq 'unknown') {
                            $st = 'skipped';
                            $detail = 'machine start not conclusive: '
                                    . (length($d) ? $d : 'podman machine start failed');
                        }
                        else                   { $st = 'fail';    $detail = length($d) ? $d : 'podman machine start failed'; }
                    }
                }
                else { $st = 'fail'; $detail = 'machine_start seam not provided'; }
            }
            elsif ($id eq 'container-start') {
                my $c = classify_container_state($state->{status}, $mstate);
                # MINOR-3: $state->{status} is the launcher's THROTTLED inspect
                # cache; a container that died inside that window still reads
                # 'running'. status_stale is the caller's explicit "do not trust
                # this reading to skip work" signal -- with it set we always call
                # the seam, which re-probes authoritatively. Without it the plain
                # 'running' shortcut stands (AC-12 pins that path).
                my $stale = $state->{status_stale} ? 1 : 0;
                if ($c eq 'running' && !$stale) { $st = 'skipped'; $detail = 'container already running'; }
                elsif ($c eq 'absent') {
                    # R1: production does NOT wire container_create, so this is
                    # the branch a genuinely removed container takes in the TUI.
                    # It is a FAIL, not a skip: the contract only allows ok => 1
                    # when the container ends up running, and it does not.
                    if (ref($o{container_create}) eq 'CODE') {
                        my $r = eval { $o{container_create}->() };
                        if ($@) { $st = 'fail'; $detail = _chomp_err($@); }
                        else {
                            my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                            my $d = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : '';
                            if ($rr->{ok}) { $st = 'ok'; $detail = length($d) ? $d : 'container created'; $created = 1; }
                            else           { $st = 'fail'; $detail = length($d) ? $d : 'container create failed'; }
                        }
                    }
                    else {
                        $st = 'fail';
                        $detail = 'container no longer exists; in-TUI recreate is not available'
                                . ' - [q] quit, then re-run claude-sandbox to rebuild';
                    }
                }
                elsif (ref($o{container_start}) eq 'CODE') {
                    my $r = eval { $o{container_start}->() };
                    if ($@) { $st = 'fail'; $detail = _chomp_err($@); }
                    else {
                        my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                        my $d = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : '';
                        if ($rr->{ok}) { $st = 'ok';   $detail = length($d) ? $d : 'container started'; }
                        else           { $st = 'fail'; $detail = length($d) ? $d : 'container start failed'; }
                    }
                }
                else { $st = 'fail'; $detail = 'container_start seam not provided'; }
            }
            elsif ($id eq 'heartbeat-reattach') {
                if (ref($o{heartbeat_reattach}) eq 'CODE') {
                    my $r = eval { $o{heartbeat_reattach}->() };
                    if ($@) { $st = 'fail'; $detail = _chomp_err($@); }
                    else {
                        my $rr = (ref($r) eq 'HASH') ? $r : { ok => ($r ? 1 : 0), detail => '' };
                        my $d = (defined $rr->{detail} && length $rr->{detail}) ? $rr->{detail} : '';
                        if ($rr->{ok}) { $st = 'ok';   $detail = length($d) ? $d : 'heartbeat ok'; }
                        else           { $st = 'fail'; $detail = length($d) ? $d : 'heartbeat re-attach failed'; }
                    }
                }
                else { $st = 'fail'; $detail = 'heartbeat_reattach seam not provided'; }
            }
            else {
                $st = 'skipped';
                $detail = 'unknown stage';
            }
        };
        if ($@) { $st = 'fail'; $detail = _chomp_err($@); }

        # Dual shape (spec 09 E1): s11's {id,label,state,detail} is canonical
        # (the renderer and s11's oracle read it); {name,status} are aliases on
        # the SAME hashref, so the ledger's recovery-seam contract is satisfied
        # without a second structure that could drift.
        push @stages, { id => $id, label => $label, state => $st, detail => $detail,
                        name => $id, status => _recover_status_alias($st) };

        eval {
            $status_cb->({ active => 1, mode => $mode, reason => $reason, stage => $id, label => $label,
                           index => $idx, total => $n, state => $st, detail => $detail });
        };
        eval {
            $log_cb->('lifecycle_stage', { mode => $mode, stage => $id, index => $idx, total => $n,
                                            state => $st, detail => $detail });
        };

        if ($st eq 'fail' || $st eq 'timeout') {
            $failed_stage = $id;
            $error        = $detail;
            last;                      # stop the sequence (the contract's error path)
        }
    }

    my $timed_out = (grep { $_->{state} eq 'timeout' } @stages) ? 1 : 0;
    my $ok        = (grep { $_->{state} eq 'fail' || $_->{state} eq 'timeout' } @stages) ? 0 : 1;

    my $summary;
    if (defined $failed_stage) {
        my ($f) = grep { $_->{id} eq $failed_stage } @stages;
        my $fd  = ($f && defined $f->{detail}) ? $f->{detail} : '';
        $summary = ($f && $f->{state} eq 'timeout')
            ? "$failed_stage failed (timed out" . (length($fd) ? ": $fd" : '') . ')'
            : "$failed_stage failed" . (length($fd) ? " ($fd)" : '');
    }
    else {
        my @clauses;
        for my $s (@stages) {
            if ($s->{id} eq 'machine-start') {
                push @clauses, 'machine started'         if $s->{state} eq 'ok';
                push @clauses, 'machine already running' if $s->{state} eq 'skipped' && $mstate eq 'running';
            }
            elsif ($s->{id} eq 'container-start') {
                push @clauses, ($created ? 'container created' : 'container started')
                    if $s->{state} eq 'ok';
                push @clauses, 'container already running' if $s->{state} eq 'skipped';
            }
            elsif ($s->{id} eq 'heartbeat-reattach') {
                push @clauses, 're-attached' if $s->{state} eq 'ok';
            }
        }
        $summary = join('; ', @clauses);
        $summary = 'recovery sequence completed' unless length $summary;
    }

    my $k = scalar @stages;
    eval {
        $status_cb->({ active => 0, mode => $mode, reason => $reason, stage => undef, label => undef,
                       index => $k, total => $n, state => 'done', detail => '', summary => $summary });
    };
    # Every payload value is a plain scalar (log_ev's contract): failed_stage
    # and error become '' rather than undef so the log line never carries a hole.
    eval {
        $log_cb->('lifecycle_done', { mode => $mode, ok => $ok, timed_out => $timed_out,
                                       summary => $summary, reason => $reason,
                                       failed_stage => (defined $failed_stage ? $failed_stage : ''),
                                       error        => (defined $error        ? $error        : '') });
    };

    return {
        ok           => $ok,
        stages       => \@stages,
        failed_stage => $failed_stage,
        error        => $error,
        mode         => $mode,
        reason       => $reason,
        timed_out    => $timed_out,
        summary      => $summary,
    };
}

# ===========================================================================
# THE LOOP (seam-injected; every side effect is a coderef)
# ===========================================================================
#
# Required seams (launcher.pl supplies the real ones; the test harness supplies
# fakes): now, sleep_for, read_key, term_size, gather, heartbeat, spawn,
# enter_raw, leave_raw, out. Optional: color, beat_interval, state_interval,
# tick_interval, max_ticks (bounded run for tests), stop_runs/full_shutdown
# (s11-lifecycle-stop spec 08 S2.7 -- sub($state,$progress) -> \%result|undef;
# neither exits the loop, only [q] does), recover (s12 spec 09 S2.7 -- same
# shape, driving the [l] relaunch/recover sequence), and keepawake->(\%state) — B5's
# hook, called once per state refresh with the freshly gathered state so the
# launcher can drive the wake-lock off busy_age (the loop itself stays
# ignorant of the keep-awake decision; that lives in KeepAwake.pm).
# write_signals (retired) is tolerated if still passed -- unknown %o keys are
# simply ignored, as before.
#
# gather->() returns the base state hashref (project_name, container, status,
# events); the loop augments it with beat_age, uptime and pending. heartbeat->()
# returns 'ok' | 'fail' | 'gone' — 'gone' does NOT end the loop (see (E) in the
# body: the dashboard stays open on a dead container so [l] can recover it; the
# old "'gone' ends the loop" wording here described behaviour that no longer
# exists and that t/25 pins the opposite of). spawn->() may return
# 'redraw' to force a full repaint (the inline fallback suspends/repaints).

# _assemble_esc($key, $read_key) -> $key' -- a behaviour-preserving extraction
# (07-backpack-screen S2.3) of run()'s ESC-sequence assembly, so the backpack
# modal seam can receive already-assembled arrow tokens via the same logic
# without depending on Dashboard's internals. $key ne "\e" passes through
# unchanged; "\e" peeks $read_key for '['/'O' then a final letter: 'A' ->
# 'UP', 'B' -> 'DOWN', any other final letter -> undef, an incomplete
# sequence -> undef, ESC + a non-CSI byte (Alt+key) -> that byte, a lone ESC
# (nothing more to read) -> "\e". No branch's outcome changed by the
# extraction; the call site below is now a one-line call.
sub _assemble_esc {
    my ($key, $read_key) = @_;
    return $key unless defined $key && $key eq "\e";
    my $k2 = $read_key->();
    if (defined $k2 && ($k2 eq '[' || $k2 eq 'O')) {
        my $k3 = $read_key->();
        if (defined $k3) {
            if    ($k3 eq 'A') { return 'UP'; }
            elsif ($k3 eq 'B') { return 'DOWN'; }
            else               { return undef; }   # unrecognized CSI: drop, like launcher.pl
        }
        return undef;   # incomplete sequence
    } elsif (defined $k2) {
        # ESC + a non-CSI byte (Alt+key): surface that byte rather than
        # dropping it, mirroring launcher.pl.
        return $k2;
    }
    return "\e";   # lone ESC (no k2): stays inert in dispatch_key.
}

sub run {
    my (%o) = @_;
    my $now        = $o{now}        || sub { time };
    # A SEPARATE, SUB-SECOND CLOCK, and only the animations use it.
    #
    # $now is deliberately integer-seconds (`sub { time }`) and is injected by
    # tests that assert exact ages and durations; it must stay that way. But
    # spinner_idx was derived from it as int($now / $tick_int) with $tick_int
    # = 0.2, and int(<integer> / 0.2) is always a MULTIPLE OF 5 -- so `% 10`
    # over the ten braille frames could only ever produce index 0 or 5. The
    # dashboard shipped a ten-frame spinner that alternated between exactly two
    # glyphs, once per second. Nine-tenths of the frames were unreachable by
    # arithmetic, not by configuration, which is why it looked like a glyph-table
    # problem and was not.
    #
    # AN INJECTED CLOCK GOVERNS EVERYTHING. If the caller supplied `now` it has
    # taken control of time, and a second clock ticking independently underneath
    # it would make the animation -- and therefore the rendered frame, and
    # therefore every repaint-count assertion -- nondeterministic in exactly the
    # tests that exist to be deterministic. So hires_now defaults to `now` when
    # `now` was injected, and only reaches for the real sub-second clock in
    # production, where nobody is holding time still. A caller that genuinely
    # wants two different clocks can still pass hires_now explicitly.
    my $hires_now  = $o{hires_now} || $o{now} || sub { Time::HiRes::time() };
    my $sleep_for  = $o{sleep_for}  || sub { select undef, undef, undef, $_[0] };
    my $read_key   = $o{read_key}   || sub { undef };
    # s15-input-latency: an interruptible wait on input, injected alongside the
    # other seams (b32 opt-in shape). Default preserves today's behaviour
    # BYTE-FOR-BYTE -- sleep the full interval via $sleep_for, report no key --
    # so every existing caller/test that injects only sleep_for is unaffected.
    # The real seam (launcher.pl) builds this on blocking
    # Term::ReadKey::ReadKey($timeout), which may consume a single byte to
    # detect readiness; see the pushback handling at the tail of the loop
    # below for how that byte is handed back to the drain (Decision #22).
    my $wait_input = $o{wait_input} || sub { $sleep_for->($_[0]); undef };
    my $term_size  = $o{term_size}  || sub { (80, 24) };
    my $gather     = $o{gather}     || sub { {} };
    my $heartbeat  = $o{heartbeat}  || sub { 'ok' };
    my $spawn      = $o{spawn}      || sub { undef };
    # write_signals is retired (s11-lifecycle-stop); an unknown %o key is
    # simply ignored, so a caller still passing it is tolerated for free.
    my $stop_runs     = (ref($o{stop_runs})     eq 'CODE') ? $o{stop_runs}     : undef;
    my $full_shutdown = (ref($o{full_shutdown}) eq 'CODE') ? $o{full_shutdown} : undef;
    my $recover       = (ref($o{recover})       eq 'CODE') ? $o{recover}       : undef;
    # 07-backpack-screen S2.3: the [b] modal seam, plus its three optional
    # persistence seams. Every default preserves today's behaviour
    # byte-for-byte for a caller that passes none -- backpack_screen's
    # default lazily requires tui::BackpackScreen only when actually
    # invoked, so a caller that never presses [b] never loads it.
    my $backpack_screen = (ref($o{backpack_screen}) eq 'CODE') ? $o{backpack_screen}
        : sub { require tui::BackpackScreen; tui::BackpackScreen::run(%{$_[0]}) };
    # t11-tui-hot-reload: two optional seams, defaulting to no-ops so every
    # existing caller and test is unaffected byte-for-byte.
    #
    #   hot_reload         -> \%summary   (HotReload::summarise's shape)
    #   hot_reload_pending -> count of modules changed on disk
    #
    # Injected rather than called directly for the reason every I/O boundary in
    # this file is: hot_reload runs a subprocess, and this module contains no
    # system/exec/fork anywhere. The arrow stays one-way.
    #
    # NOTE FOR ANYONE EDITING THE LOOP ITSELF: run() is on the call stack for
    # the whole session, so THIS sub is the one thing hot-reload cannot update.
    # These two call sites are frozen at launch; everything behind the seams is
    # live. Keep the call sites trivial and the logic on the far side.
    my $hot_reload         = (ref($o{hot_reload})         eq 'CODE') ? $o{hot_reload}         : undef;
    my $hot_reload_pending = (ref($o{hot_reload_pending}) eq 'CODE') ? $o{hot_reload_pending} : undef;
    my $launcher_changed   = (ref($o{launcher_changed}) eq q{CODE}) ? $o{launcher_changed} : undef;
    my $bp_load       = (ref($o{bp_load})   eq 'CODE') ? $o{bp_load}   : undef;
    my $bp_save       = (ref($o{bp_save})   eq 'CODE') ? $o{bp_save}   : undef;
    my $bp_remove     = (ref($o{bp_remove}) eq 'CODE') ? $o{bp_remove} : undef;
    my $bp_max_ticks  = $o{bp_max_ticks};
    my $enter_raw  = $o{enter_raw}  || sub { };
    my $leave_raw  = $o{leave_raw}  || sub { };
    my $keepawake  = $o{keepawake}  || sub { };   # B5: drive the wake-lock off fresh state
    my $out        = $o{out}        || sub { print STDOUT $_[0] };
    my $color      = exists $o{color} ? $o{color} : 1;
    my $beat_int   = defined $o{beat_interval}  ? $o{beat_interval}  : 120;
    my $state_int  = defined $o{state_interval} ? $o{state_interval} : 2;
    my $tick_int   = defined $o{tick_interval}  ? $o{tick_interval}  : 0.2;
    # MINOR-1 (red-team step 6): a wall-clock cooldown on the recover ACTION.
    # "ly" is one of the commonest digraphs in English (only/really/finally), so
    # pasting an ordinary paragraph into the dashboard otherwise fires one full
    # recovery per occurrence, back to back -- each up to ~190s of a frozen,
    # unrepainting TUI, each orphaning a `podman machine start` the next one
    # races. The window is on the ACTION, never on the confirm, so the two-step
    # [l][y] timing the oracle pins is untouched. Read through the SAME now()
    # seam the loop uses, so a test never sleeps. Default is non-zero: a caller
    # that configures nothing still gets amplification protection.
    my $recover_cooldown = defined $o{recover_cooldown} ? $o{recover_cooldown} : 30;

    $enter_raw->();

    my $start     = $now->();
    my $last_beat = $start - $beat_int;   # heartbeat fires on the first tick
    my $last_state = undef;               # forces a gather on the first tick
    my ($cols, $rows) = $term_size->();
    my ($last_cols, $last_rows) = ($cols, $rows);
    # Open while a resize is still settling -- see the note at the geometry poll.
    my $settle_ticks = 0;
    my $prev;
    my %state;
    my $pending = '';
    my $hb_state = 'ok';        # last heartbeat result; 'gone' no longer exits the loop
    my @all_events;             # full chronological event list from the last gather
    my $activity_offset = 0;    # up/down scroll position in the Activity panel
    # t03-banner-dismiss S2.4: lives OUTSIDE %state's replace-on-gather
    # lifecycle (same reasoning as $pending/$activity_offset above) and is
    # re-applied onto %state every tick, so a forced regather ([r]/relaunch,
    # or simply the next periodic $state_int tick) cannot resurrect a
    # dismissed install-warning banner.
    #
    # SAFETY INVARIANT this flag depends on (step-6 red-team MEDIUM-1): this
    # is a BLANKET, content-blind, per-process mute -- once set, it suppresses
    # WHATEVER install_warning the next gather returns, not just the string
    # that was on screen at dismiss time. That is only safe because every
    # $INSTALL_WARNING assignment in launcher.pl executes before this loop is
    # ever entered (_launch_stage_begin('dashboard')) -- so no NEW/different
    # warning can ever arise while this flag is live to swallow it. That
    # invariant is enforced by plugins/sandbox/tests/t/87-banner-dismiss.t
    # PART 7 (a source-structure scan of launcher.pl); if a future change adds
    # or moves an $INSTALL_WARNING assignment to after the dashboard stage
    # begins, that test goes red -- read it before "fixing" this flag to be
    # content-aware or removing it.
    my $install_warning_dismissed = 0;
    # t11: the last [r] reload report, and when it was produced. Loop-scoped
    # rather than in %state because %state is wholesale-replaced on every
    # gather; see the re-apply below.
    my ($hot_reload_report, $hot_reload_report_at) = (undef, 0);
    my $activity_max    = 0;    # scroll ceiling (set each frame by activity_window)
    my $flash_until = 0;        # footer-flash expiry (set when [c] hit a dead container)
    my $last_recover_at;        # now() when the last [l] recovery FINISHED (undef: none yet)
    my $rc = 0;
    my $ticks = 0;
    my $last_title;                                            # undef => nothing emitted yet
    # Frame-cache state. $gather_seq changes whenever %state is replaced from a
    # gather, so the signature below does not have to enumerate the state hash
    # to notice one. See the note at the compose call.
    my $last_frame_sig;
    my $gather_seq = 0;
    # Animation cadences, in seconds per frame. Deliberately NOT tied to
    # $tick_int: the render tick is an input-latency decision (how fast a
    # keystroke is noticed) and has no business setting how fast a spinner
    # reads. Coupling them is what produced the two-frame spinner above.
    # Injectable so a test can drive many frames inside a short fake-clock
    # window without having to fake half a second per frame. Guarded against
    # zero/negative/non-numeric because these are divisors.
    my $spin_div  = _period_opt($o{spinner_period},       SPINNER_PERIOD_SECS());
    my $title_div = _period_opt($o{title_spinner_period}, TITLE_SPINNER_PERIOD_SECS());

    # s15-input-latency pushback (Decision #22): a single-slot holding cell for
    # a byte that $wait_input already consumed off the input source in order to
    # detect readiness. $next_key hands that byte back FIRST, before falling
    # through to the ordinary non-blocking $read_key poll, so no keystroke is
    # ever lost to the wait. Declared once, outside the tick loop -- it is only
    # ever armed and drained within the same tick, never left set across ticks.
    my $pushback_key;
    my $next_key = sub {
        if (defined $pushback_key) {
            my $k = $pushback_key;
            $pushback_key = undef;
            return $k;
        }
        return $read_key->();
    };

    # $progress->(\%p) -- handed to the stop_runs/full_shutdown seams as
    # run_stages(status_cb => $progress). Stashes the progress hashref
    # verbatim into $state{lifecycle} and repaints immediately, mirroring the
    # dirty-scroll same-tick re-render exactly (compose -> render_frame ->
    # update $prev), so the synchronized-output wrapper and per-row diff are
    # preserved by construction (spec 08 S2.7).
    my $progress = sub {
        my ($p) = @_;
        $state{lifecycle} = $p;
        my $frame = compose_frame(\%state, $rows, $cols);
        $out->(render_frame($prev, $frame, { color => $color }));
        $prev = $frame;
        $last_frame_sig = undef;
    };

    # MEDIUM-1 (07-backpack-screen fix-batch): the [b] modal blocks this
    # loop synchronously for its whole lifetime, so nothing below touches
    # the container's keep-alive sentinel while it's open -- an operator
    # who opens the screen and walks away for HB (container/heartbeat.sh,
    # 600s idle) loses the container. This is the exact failure class the
    # heartbeat exists to prevent. Hand the modal a heartbeat tick it can
    # call on every iteration of ITS OWN loop; the throttle ($last_beat /
    # $beat_int -- the SAME bookkeeping the tick loop below uses, so the
    # two never double-count or drift) lives in THIS closure, never inside
    # tui::BackpackScreen -- that module may not call time() (spec S2.0),
    # so it stays pure/testable and a caller that never wires `heartbeat`
    # gets tui::BackpackScreen's no-op default.
    my $modal_heartbeat = sub {
        my $t = $now->();
        if ($t - $last_beat >= $beat_int) {
            my $hb = $heartbeat->();
            $last_beat = $t;
            $hb_state = $hb if defined $hb;
        }
    };

    # _lifecycle($seam,$mode) -- inline handler for the stop-runs/full-shutdown
    # actions (spec 08 S2.7). Never sets $quit, never last's, never touches
    # $rc -- only [q] quits. A dying seam paints one synthetic failure frame
    # instead of propagating.
    my $do_lifecycle = sub {
        my ($seam, $mode) = @_;
        return unless ref($seam) eq 'CODE';
        eval { $seam->(\%state, $progress) };
        if ($@) {
            my $err_txt = $@;
            $err_txt =~ s/\n/ /g;
            $err_txt =~ s/\s+$//;
            $state{lifecycle} = { active => 0, mode => $mode, state => 'fail', index => 0, total => 0,
                                   detail => $err_txt, summary => "$mode failed: $err_txt" };
            my $frame = compose_frame(\%state, $rows, $cols);
            $out->(render_frame($prev, $frame, { color => $color }));
            $prev = $frame;
            $last_frame_sig = undef;
        }
        $last_state = undef;   # force a fresh gather next tick (container status may have changed)
    };

    my $err;
    {
        local $SIG{INT}  = sub { $leave_raw->(); exit 130 };
        local $SIG{TERM} = sub { $leave_raw->(); exit 143 };
        eval {
            while (1) {
                my $t = $now->();

                # heartbeat (token-free keep-alive of the container)
                if ($t - $last_beat >= $beat_int) {
                    my $hb = $heartbeat->();
                    $last_beat = $t;
                    # (E) Do NOT exit when the container is gone/unreachable. Keep
                    # the dashboard open so the user can see the dead state and
                    # recover ([q] quit, then re-run claude-sandbox) — surfaced as
                    # a status alert. Keep heartbeating: if the container comes
                    # back (podman/host woke), the dashboard recovers on its own.
                    $hb_state = $hb if defined $hb;
                }

                # GEOMETRY IS POLLED EVERY TICK, NOT ON THE GATHER ROUND.
                #
                # This used to live inside the state-refresh block below, which
                # runs once per $state_int (2s in production) -- so a resize was
                # invisible for up to two seconds, and for however much longer
                # the gather round itself took. Operator: "it takes a long time
                # for the repaint to trigger or it may not even trigger at all.
                # But the moment I e.g. scroll my mouse, everything repaints
                # nicely" -- scrolling moves $activity_offset, which IS in the
                # frame signature, so it forced the recompose the resize should
                # have forced. Reading the terminal size is an ioctl, not a
                # subprocess; there is no reason for it to ride a throttle meant
                # for probes. At $tick_int it is now noticed within ~200ms.
                #
                # $rows/$cols are in the frame-cache signature, so updating them
                # here is by itself enough to force a recompose on the same tick.
                ($cols, $rows) = $term_size->();
                if ($cols != $last_cols || $rows != $last_rows) {
                    # c8b0: a width-only resize never changes the ROW COUNT
                    # that render_frame's own $full formula compares, so the
                    # per-row diff would otherwise skip unchanged rows and
                    # leave whatever the real terminal did to them during the
                    # resize on screen. Reuse the SAME idiom already used
                    # three times elsewhere in this file to force a full
                    # repaint ([r] refresh, backpack-modal exit, first frame)
                    # instead of adding a second mechanism.
                    $prev = undef;
                    ($last_cols, $last_rows) = ($cols, $rows);
                    # ...AND KEEP REPAINTING FOR A MOMENT AFTERWARDS.
                    #
                    # Operator, after the poll was moved to every tick: "still
                    # getting some issue with the repaint on maximizing the
                    # terminal window. Curiously the problem doesn't happen when
                    # resizing it, but it happens when I maximize it. It only
                    # repaints after I scroll the mouse."
                    #
                    # That difference is the diagnosis. A drag-resize reports
                    # its new geometry many times as it moves, so SOME poll
                    # always lands after the terminal has finished reflowing.
                    # A maximize is ONE jump: the new size is reported once,
                    # we repaint against it immediately, and then the terminal
                    # does its own reflow of the scrollback AFTER our repaint --
                    # overwriting rows we now believe are correct. From then on
                    # the per-row diff has nothing to emit, because our model
                    # and the screen disagree and only the screen knows it.
                    # Scrolling "fixed" it for the same reason it did before:
                    # it dirties rows, forcing emissions we were skipping.
                    #
                    # So a geometry change arms a short settle window instead of
                    # a single repaint. While it is open the frame cache is
                    # bypassed and every tick paints in full, which lands after
                    # the terminal has finished whatever it was doing. The cost
                    # is bounded and tiny -- a handful of full repaints, only
                    # ever right after a resize -- and it needs no way to detect
                    # an event the terminal never tells us about.
                    #
                    # COUNTED IN TICKS, NOT SECONDS. The loop's clock is an
                    # injected seam and a test may legitimately freeze it; a
                    # wall-clock deadline would then never expire and the
                    # window would stay open forever. Ticks are the unit the
                    # repainting actually happens in, so they are the honest
                    # unit to bound it in.
                    $settle_ticks = RESIZE_SETTLE_TICKS();
                }
                # The settle window itself. It re-emits every row but does NOT
                # clear -- the one clear that IS wanted already happened above,
                # on the tick the change was detected. Repeating it is what
                # would look like flicker.
                my $settling = 0;
                if ($settle_ticks > 0) { $settle_ticks--; $settling = 1; $last_frame_sig = undef }

                # state refresh (slower cadence than input polling)
                if (!defined $last_state || $t - $last_state >= $state_int) {
                    my $base = $gather->() || {};
                    %state = %$base;
                    # t11-tui-hot-reload: the nudge. Thirteen stats, no fork --
                    # deliberately cheap enough to ride the gather it is folded
                    # into, because the gap it closes is a PROMOTE THE OPERATOR
                    # FORGOT TO PICK UP, and a hint they have to ask for would
                    # not close it. Kept out of the render tick proper (which
                    # runs far more often) by living here, on the throttled
                    # gather round.
                    $state{hot_reload_pending} = $hot_reload_pending
                        ? (eval { $hot_reload_pending->() } || 0) : 0;
                    # launcher.pl is watched separately: it is never in the
                    # reload allowlist (it is this process), so the count above
                    # can only ever be 0 for it. [r] now restarts into it.
                    $state{launcher_changed} = $launcher_changed
                        ? (eval { $launcher_changed->() } ? 1 : 0) : 0;
                    # ...and re-apply the last reload REPORT across the same
                    # wholesale replace, exactly as the dismissed-banner line
                    # below does. Without this the report would live for a
                    # single tick: [r] sets $last_state = undef, which forces a
                    # gather on the very next pass, which would blank the one
                    # thing the operator pressed [r] to read. It expires on its
                    # own rather than sticking, because a stale "reloaded 3
                    # modules" is a claim about a moment that has passed.
                    if ($hot_reload_report && $now->() - $hot_reload_report_at <= HOT_RELOAD_REPORT_SECS()) {
                        $state{hot_reload} = $hot_reload_report;
                    } else {
                        $hot_reload_report = undef;
                    }
                    # t03-banner-dismiss S2.4: %state was just wholesale-replaced
                    # from $base, which unconditionally re-supplies whatever
                    # install_warning the gather seam has -- re-apply the
                    # dismissal here so a forced/periodic regather can't
                    # resurrect a banner the operator already dismissed.
                    $state{install_warning} = undef if $install_warning_dismissed;
                    @all_events = @{ $base->{events} || [] };   # chronological
                    $activity_offset = 0 if $activity_offset < 0;
                    $last_state = $t;
                    # %state has just been replaced wholesale. Bumping this is
                    # what tells the frame cache below that EVERY field may have
                    # moved, without the signature needing to enumerate them.
                    $gather_seq++;
                    # B5: re-evaluate the wake-lock on the freshly gathered state
                    # (carries busy_age). The launcher's seam owns the decision.
                    $keepawake->(\%state);
                }
                $state{beat_age}       = $t - $last_beat;
                $state{uptime}         = $t - $start;
                $state{pending}        = $pending;
                $state{container_gone} = ($hb_state eq 'gone') ? 1 : 0;
                # Decision #21: WALL CLOCK, not iteration count -- but the
                # SUB-SECOND wall clock. $t is integer seconds, and dividing an
                # integer by 0.5 (or the old 0.2) lands on a coarse lattice that
                # made most of the ten frames unreachable. See $hires_now.
                my $ht = $hires_now->();
                $ht = $t if !defined $ht || ref($ht) || $ht !~ /^-?\d+(?:\.\d+)?$/;
                $state{spinner_idx}       = int($ht / $spin_div);
                $state{title_spinner_idx} = int($ht / $title_div);
                $state{oauth_remaining} = defined $state{oauth_expires_at}
                    ? $state{oauth_expires_at} - $t : undef;
                # Transient footer notice when [c] was pressed on a non-running
                # container (set in the launch branch below). Auto-expires so the
                # normal command legend returns on its own.
                $state{footer_flash} = ($t < $flash_until) ? launch_blocked_msg() : undef;
                # Activity: capacity-aware window (newest-first) + an inline
                # scroll overlay (Decision #19). activity_window clamps the
                # offset to the last page (so you can't scroll past the end)
                # and overlays the scroll indicator directly onto the
                # first/last visible row -- no separate hint row/element.
                my $cap  = activity_capacity(\%state, $rows, $cols);
                my @desc = reverse @all_events;
                my $win  = activity_window(\@desc, $activity_offset, $cap, activity_row_width($cols));
                $activity_offset = $win->{offset};
                $activity_max    = $win->{max_offset};
                my @ev_lines = @{ $win->{lines} };
                $state{events} = (@ev_lines ? \@ev_lines : ['(no events yet)']);

                # OSC window-title emit (s07-live-status S2.5): its OWN out
                # call, outside the diffed frame, only on change. Only the
                # PRIMARY render path emits -- $progress/$do_lifecycle/the
                # recover-cooldown frame/the post-drain scroll re-render do
                # not gather, so no title-relevant field can have changed.
                my $title = window_title(\%state);
                if (!defined $last_title || $title ne $last_title) {
                    $out->("\e]0;" . $title . "\a");
                    $last_title = $title;
                }

                # SKIP THE COMPOSE WHEN NOTHING THAT FEEDS IT HAS MOVED.
                #
                # This loop recomposed the WHOLE frame five times a second and
                # then diffed it to discover that mostly nothing had changed.
                # Measured on the operator's host: two idle launcher processes
                # burning 16.6% and 12.2% of a core each, doing nothing but
                # this. render_frame already suppresses the OUTPUT of an
                # unchanged frame; what it cannot avoid is the cost of building
                # the frame in order to compare it.
                #
                # The signature is every input to compose that can move between
                # ticks. Everything else in %state arrives from a gather, and
                # $gather_seq changes when one happens -- so a gather
                # invalidates the whole cache without the signature having to
                # enumerate the state hash.
                #
                # THE SAFETY PROPERTY, and why this cannot silently freeze the
                # screen: beat_age and uptime are in the signature and both
                # advance every whole second, so a full recompose happens at
                # least once a second no matter what else is or is not
                # enumerated here. A field this list forgets costs at most one
                # second of staleness, never a stuck frame.
                my $sig = join "\x1f", $rows, $cols, $gather_seq, $activity_offset,
                    map { defined $state{$_} ? $state{$_} : '' }
                    qw(beat_age uptime pending container_gone spinner_idx
                       title_spinner_idx oauth_remaining footer_flash status);

                if (!defined $last_frame_sig || $sig ne $last_frame_sig) {
                    my $frame = compose_frame(\%state, $rows, $cols);
                    $out->(render_frame($prev, $frame, { color => $color, repaint => $settling }));
                    $prev = $frame;
                    $last_frame_sig = undef;
                    $last_frame_sig = $sig;
                }

                # input — DRAIN all pending keys available THIS tick, not one.
                # $next_key polls non-blocking (falling through to $read_key once
                # any pushback is consumed), so a fast burst of scroll events
                # (mouse wheel) otherwise queued one-per-tick and took seconds to
                # settle. Coalescing them into a single frame keeps scrolling
                # responsive. The cap is a runaway-input backstop.
                #
                # s15-input-latency: this drain is now a reusable closure so the
                # SAME dispatch logic can run twice in one iteration: once here
                # (the primary, top-of-tick drain) and once more at the tail if
                # $wait_input hands back a key (a keypress must be drained and
                # rendered on the SAME tick it arrives in, not the next one) --
                # without re-running the heartbeat/gather section above, which
                # would make wall-clock-gated tests observe an extra heartbeat
                # or gather that never happened in the real timeline.
                my $do_drain = sub {
                my $quit = 0;
                my $drained = 0;
                my $scroll_dirty = 0;   # set when a scroll mutates the view
                while ($drained < 256) {
                    my $key = $next_key->();
                    last unless defined $key && length $key;
                    $drained++;
                    my $pending_was_armed = ($pending ne '');
                    my ($action, $np) = dispatch_key($key, $pending);
                    $pending = $np;
                    if ($action eq 'quit') { $rc = 0; $quit = 1; last; }
                    elsif ($action eq 'launch') {
                        if (can_launch(\%state)) {
                            my $r = $spawn->();
                            $prev = undef if defined $r && $r eq 'redraw';
                        } else {
                            # Container isn't running: a connector's `podman exec`
                            # would instantly fail and the spawned Windows Terminal
                            # would vanish. Suppress the spawn and flash the real
                            # recovery path in the footer for a couple of seconds.
                            $flash_until = $t + 2;
                        }
                    }
                    elsif ($action eq 'stop-runs') {
                        $do_lifecycle->($stop_runs, 'stop-runs');
                    }
                    elsif ($action eq 'full-shutdown') {
                        $do_lifecycle->($full_shutdown, 'full-shutdown');
                    }
                    elsif ($action eq 'relaunch') {
                        # MINOR-1: suppress a confirmed recover that lands inside
                        # the cooldown window. Nothing is queued or retried -- the
                        # press is simply dropped, with a banner so the key never
                        # feels dead. The stamp is taken AFTER the sequence
                        # returns, so the window measures idle time since the last
                        # recovery FINISHED, not since it started (a 180s machine
                        # start would otherwise clear a 30s window by itself).
                        if (defined $last_recover_at
                            && ($now->() - $last_recover_at) < $recover_cooldown) {
                            $state{lifecycle} = {
                                active => 0, mode => 'recover', state => 'skipped',
                                index => 0, total => 0, detail => '',
                                summary => 'not run - a recovery just finished'
                                         . " (cooldown ${recover_cooldown}s); press [l] again in a moment",
                            };
                            my $sframe = compose_frame(\%state, $rows, $cols);
                            $out->(render_frame($prev, $sframe, { color => $color }));
                            $prev = $sframe;
                            $last_frame_sig = undef;
                            next;
                        }
                        $do_lifecycle->($recover, 'recover');
                        $last_recover_at = $now->();
                        # Force a heartbeat on the very NEXT tick. $hb_state is
                        # sticky and beat_interval defaults to 120s, so without
                        # this a SUCCESSFUL recover leaves container_gone (and
                        # the dead-container banner it drives) painted for up to
                        # two minutes -- the user fixes the sandbox and the TUI
                        # keeps telling them it is broken. $do_lifecycle already
                        # reset $last_state; this is the other half, and it is
                        # applied ONLY here: a stop-* action legitimately expects
                        # the container to go away. Cost: $state{beat_age} reads
                        # $beat_int for exactly one tick before the forced
                        # heartbeat corrects it.
                        $last_beat = $now->() - $beat_int;
                    }
                    elsif ($action eq 'refresh') {
                        # t11-tui-hot-reload: [r] now RELOADS THE RENDER MODULES
                        # and then does everything refresh already did.
                        #
                        # Nothing is taken away. The operator's read was that
                        # refresh "doesn't actually do anything meaningful",
                        # which is nearly right -- the data it forces would have
                        # arrived within a tick anyway and the repaint is
                        # invisible when nothing changed. But its three side
                        # effects turn out to be EXACTLY what a code swap needs:
                        # a forced gather, a forced full repaint, and a cleared
                        # banner. So reload is folded in ahead of them rather
                        # than replacing them.
                        #
                        # The smoke closure is built here, in the frozen loop,
                        # but calls compose_frame BY NAME -- so it renders with
                        # whatever was just installed, which is the point.
                        if ($hot_reload) {
                            my ($w, $h) = $term_size->();
                            my %snap = %state;
                            $hot_reload_report = eval {
                                $hot_reload->(sub { compose_frame(\%snap, $h, $w) });
                            };
                            $hot_reload_report_at = $now->();
                            $state{hot_reload}    = $hot_reload_report;
                        }
                        $last_state      = undef;   # force a gather next tick
                        $prev            = undef;   # (D) force a FULL repaint: blank
                                                    # (\e[2J) then redraw every row fresh
                        $activity_offset = 0;       # back to the newest events
                        delete $state{lifecycle};   # clear the lifecycle banner (spec 08 S2.7)
                    }
                    elsif ($action eq 'backpack') {
                        # 07-backpack-screen S2.2: the [b] modal owns the screen
                        # for the duration of the call -- every I/O boundary it
                        # needs is injected here, so the arrow stays one-way
                        # (Dashboard -> tui::BackpackScreen, never back).
                        # $quit is never set, $rc is never touched, leave_raw
                        # is never called here -- only [q] quits.
                        my $items = (ref($state{backpack}) eq 'HASH'
                                     && ref($state{backpack}{items}) eq 'ARRAY')
                            ? $state{backpack}{items} : [];
                        my $ctx = {
                            items     => $items,
                            load      => $bp_load,  save => $bp_save,  remove => $bp_remove,
                            read_key  => $next_key,
                            wait_key  => sub { _assemble_esc($wait_input->($_[0]), $read_key) },
                            term_size => $term_size,  out => $out,
                            render    => sub { render_frame($_[0], $_[1], { color => $color }) },
                            tick      => $tick_int,   max_ticks => $bp_max_ticks,
                            # MEDIUM-1: keeps the container alive while the modal
                            # blocks this loop -- see $modal_heartbeat above.
                            heartbeat => $modal_heartbeat,
                        };
                        eval { $backpack_screen->($ctx) };
                        if ($@) {
                            my $e = $@; $e =~ s/\s+/ /g;
                            $state{lifecycle} = { active => 0, mode => 'backpack', index => 0, total => 0,
                                                   detail => $e, summary => "screen failed - $e" };
                        }
                        $prev       = undef;   # the modal owned the screen: the next paint must be FULL
                        $last_state = undef;   # approvals/backpack may have changed: re-gather next tick
                        my $bframe = compose_frame(\%state, $rows, $cols);
                        $out->(render_frame($prev, $bframe, { color => $color }));
                        $prev = $bframe;
                        $last_frame_sig = undef;
                        last;   # stop draining; keys pressed after the modal wait for the next tick
                    }
                    elsif ($action eq 'dismiss-install-warning') {
                        # t03-banner-dismiss S2.4: two writes, not one -- the
                        # immediate undef makes THIS tick's render correct
                        # without waiting for $do_rerender; the lexical flag
                        # (re-applied at :3713-ish, right after the wholesale
                        # %state = %$base replace) makes every FUTURE gather
                        # correct too.
                        $install_warning_dismissed = 1;
                        $state{install_warning} = undef;
                        $scroll_dirty = 1;   # same-tick re-render, mirrors scroll's own flag
                    }
                    elsif ($action eq 'scroll-up') {
                        # Only a view-changing scroll marks the frame dirty; a no-op
                        # scroll at the top boundary needs no same-tick re-render.
                        if ($activity_offset > 0) { $activity_offset--; $scroll_dirty = 1; }
                    }
                    elsif ($action eq 'scroll-down') {
                        if ($activity_offset < $activity_max) { $activity_offset++; $scroll_dirty = 1; }
                    }
                    # confirm-stop-runs / cancel-stop-runs / confirm-full-shutdown /
                    # cancel-full-shutdown / confirm-relaunch / cancel-relaunch
                    # only toggle $pending

                    # s11-lifecycle-stop fix-batch FIX 2: this key just ARMED a
                    # confirm (pending went '' -> non-empty). Stop draining NOW
                    # so the normal end-of-tick render below paints the confirm
                    # banner before any further key can be dispatched against
                    # it -- otherwise a same-tick 'x','y' (or 's','y') pair
                    # fires the destructive action with the banner never
                    # rendered. This only DEFERS the remaining drained input to
                    # the next tick's drain -- nothing here is flushed,
                    # discarded, or swallowed, so a scripted/pasted "xy" still
                    # satisfies the confirm one tick later; the seams these
                    # tests exercise still fire. It does not fully close the
                    # pasted-bytes vector (the bytes are still sitting wherever
                    # $read_key's source buffers them and get read on the very
                    # next tick) -- a complete fix needs bracketed-paste mode
                    # or a wall-clock debounce, which would change the input
                    # contract the oracle pins, so that is deferred.
                    if (!$pending_was_armed && $pending ne '') { last; }
                }
                return ($quit, $scroll_dirty);
                };   # end $do_drain

                # Post-drain re-render: if a scroll changed the view, re-compose and
                # re-render immediately (same tick) using @all_events already in scope —
                # NO new gather. Update $prev so the next tick diffs against the last
                # frame actually emitted, not a stale pre-drain baseline.
                my $do_rerender = sub {
                    # Refresh the fields the drain may have mutated, so this same-tick
                    # re-render matches what the NEXT primary render will show rather
                    # than their stale pre-drain values: $pending (mutated at :801) and
                    # the footer flash (set at :812 when [c] was pressed on a non-running
                    # container during THIS drain). Mirrors the primary path (:766/:771).
                    $state{pending}      = $pending;
                    $state{footer_flash} = ($t < $flash_until) ? launch_blocked_msg() : undef;
                    my $cap2  = activity_capacity(\%state, $rows, $cols);
                    my @desc2 = reverse @all_events;
                    my $win2  = activity_window(\@desc2, $activity_offset, $cap2, activity_row_width($cols));
                    $activity_offset = $win2->{offset};
                    $activity_max    = $win2->{max_offset};
                    my @ev2 = @{ $win2->{lines} };
                    $state{events} = (@ev2 ? \@ev2 : ['(no events yet)']);
                    my $frame2 = compose_frame(\%state, $rows, $cols);
                    $out->(render_frame($prev, $frame2, { color => $color }));
                    $prev = $frame2;
                    $last_frame_sig = undef;
                };

                my ($quit, $scroll_dirty) = $do_drain->();
                last if $quit;
                $do_rerender->() if $scroll_dirty;

                $ticks++;
                last if defined $o{max_ticks} && $ticks >= $o{max_ticks};

                # s15-input-latency: an interruptible wait replaces the old
                # unconditional tail sleep. Default $wait_input sleeps the full
                # interval and reports no key (byte-for-byte today's
                # behaviour, C6). The real seam wakes immediately on a
                # keypress; when it does, drain + render it on THIS SAME tick
                # (C1) rather than falling through to the next iteration's
                # heartbeat/gather check -- an idle wait still consumes ~the
                # full interval with one call per tick, so there is no
                # busy-spin (C2).
                my $wk = $wait_input->($tick_int);
                if (defined $wk && length $wk) {
                    # Decision #22: the wait may have consumed only the ESC byte
                    # of an arrow/CSI sequence to detect readiness. The remaining
                    # bytes ('[' or 'O', then the final letter) are still sitting
                    # in the input source and must be pulled via the ordinary
                    # $read_key seam (NOT another $wait_input call -- they are
                    # already available, not awaited) and stitched into the same
                    # 'UP'/'DOWN' tokens dispatch_key expects, mirroring
                    # launcher.pl's own ESC-sequence assembly exactly. Applied
                    # ONLY here (the pushback-originated byte), never to keys
                    # $read_key returns directly -- launcher.pl's read_key
                    # already fully assembles those before Dashboard.pm ever
                    # sees them, so re-assembling here too would risk mis-eating
                    # an unrelated, later keystroke as if it were part of a CSI
                    # sequence. 07-backpack-screen S2.3: this is now the
                    # extracted _assemble_esc, unchanged in outcome, so the
                    # backpack modal's wait_key seam can reuse the same logic.
                    $wk = _assemble_esc($wk, $read_key);
                    if (defined $wk && length $wk) {
                        $pushback_key = $wk;
                        my ($quit2, $scroll_dirty2) = $do_drain->();
                        last if $quit2;
                        $do_rerender->() if $scroll_dirty2;
                    }
                }
            }
        };
        $err = $@;
    }

    $leave_raw->();
    die $err if $err;
    return $rc;
}

1;
