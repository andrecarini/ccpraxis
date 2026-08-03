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
use Encode ();

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
# undef / negative -> "—".
sub fmt_age {
    my ($s) = @_;
    return 'n/a' if !defined $s;
    $s = int($s);
    return 'n/a' if $s < 0;
    return "${s}s"               if $s < 60;
    my $m = int($s / 60);
    return "${m}m"               if $m < 60;
    my $h = int($m / 60); $m %= 60;
    return sprintf('%dh%02dm', $h, $m) if $h < 24;
    my $d = int($h / 24); $h %= 24;
    return sprintf('%dd%02dh', $d, $h);
}

# fmt_hms($secs) -> "Xh Ym Zs" with all three components always shown
# (e.g. "0h 2m 13s", "2h 5m 9s"). undef / negative -> "n/a". Used for uptime,
# where the explicit hour/minute/second breakdown reads clearer than fmt_age's
# compact form. ASCII-only, so length() == display width (the render invariant).
sub fmt_hms {
    my ($s) = @_;
    return 'n/a' if !defined $s;
    $s = int($s);
    return 'n/a' if $s < 0;
    my $h = int($s / 3600); $s %= 3600;
    my $m = int($s / 60);   $s %= 60;
    return sprintf('%dh %dm %ds', $h, $m, $s);
}

# fmt_oauth($remaining_secs) -> ASCII-only status string for the oauth line.
# undef (no token yet — sandboxes now own an independent login) ->
# 'not logged in (run /login)'; <= 0 -> 'EXPIRED'; > 0 -> 'expires in <fmt_age>'.
sub fmt_oauth {
    my ($s) = @_;
    return 'not logged in (run /login)' if !defined $s;
    return 'EXPIRED' if $s <= 0;
    return 'expires in ' . fmt_age($s);
}

# _event_time($iso_ts, $localtime_fn) -> 'HH:MM:SS' in local time.
# Parses YYYY-MM-DDThh:mm:ssZ to epoch via Time::Local::timegm (UTC), then
# applies $localtime_fn (default real localtime) to get local breakdown.
sub _event_time {
    my ($ts, $localtime_fn) = @_;
    $localtime_fn ||= sub { localtime($_[0]) };
    return '00:00:00' unless defined $ts && $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/;
    my ($yr, $mo, $dy, $h, $m, $sec) = ($1, $2, $3, $4, $5, $6);
    my $epoch = eval { Time::Local::timegm($sec, $m, $h, $dy, $mo - 1, $yr - 1900) };
    return '00:00:00' unless defined $epoch;
    my @lt = $localtime_fn->($epoch);
    return sprintf('%02d:%02d:%02d', $lt[2], $lt[1], $lt[0]);
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
    my $bytes = $str;
    my $out = '';
    while (length $bytes) {
        if ($bytes =~ /\A((?:$UTF8_CHAR_RE)+)/) {
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

# _char_cols($c) -> the display width of one DECODED character: 0 for C0
# control / DEL, combining marks (\p{Mn}/\p{Me}), U+200B, U+200D, U+FE0F; the
# allow-listed glyph width if $c is in glyph_table(); else 1 (printable ASCII or
# an unlisted non-ASCII character, which _safe will render as a single '?').
# PRIVATE.
#
# Perf note (F3, s04 fix-batch): reads the package-level %GLYPH_TABLE directly
# via _glyph_table_ref() (no copy) -- this runs ONCE PER CHARACTER measured, so
# the previous `glyph_table()` call here made a fresh 18-key hash copy per
# character (~80x per-frame regression on hostile/large input). glyph_table()
# itself is untouched and still returns a defensive copy for external callers.
sub _char_cols {
    my ($c) = @_;
    return 0 if !defined $c || $c eq '';
    my $cp = ord($c);
    return 0 if $cp < 0x20 || $cp == 0x7F;
    return 0 if $cp == 0x200B || $cp == 0x200D || $cp == 0xFE0F;
    return 0 if $c =~ /\p{Mn}|\p{Me}/;
    my $gt = _glyph_table_ref();
    return $gt->{$c} if exists $gt->{$c};
    return 1;
}

# glyph_table() -> \%table, the pinned 18-entry allow-list mapping each
# decoded single-character glyph to its declared display width (status dots,
# braille spinners, gauge blocks, scroll arrows). Read-only; callers must not
# mutate the returned hashref. PUBLIC.
my %GLYPH_TABLE = (
    "\x{1F7E2}" => 2,   # status: green circle
    "\x{1F534}" => 2,   # status: red circle
    "\x{1F7E1}" => 2,   # status: yellow circle
    "\x{26AA}"  => 2,   # status: white circle
    "\x{280B}"  => 1,   # spinner: braille dots-1
    "\x{2819}"  => 1,   # spinner: braille dots-2
    "\x{2839}"  => 1,   # spinner: braille dots-3
    "\x{2838}"  => 1,   # spinner: braille dots-4
    "\x{283C}"  => 1,   # spinner: braille dots-5
    "\x{2834}"  => 1,   # spinner: braille dots-6
    "\x{2826}"  => 1,   # spinner: braille dots-7
    "\x{2827}"  => 1,   # spinner: braille dots-8
    "\x{2807}"  => 1,   # spinner: braille dots-9
    "\x{280F}"  => 1,   # spinner: braille dots-10
    "\x{2588}"  => 1,   # gauge: full block
    "\x{2591}"  => 1,   # gauge: light shade
    "\x{25B2}"  => 1,   # scroll: up triangle
    "\x{25BC}"  => 1,   # scroll: down triangle
);
# _glyph_table_ref() -> \%GLYPH_TABLE, the canonical table with NO copy.
# Internal hot-path accessor (F3): every per-character caller (_char_cols,
# _safe_char) MUST use this, never glyph_table(), or the per-char hash-copy
# regression comes right back. Callers here never mutate it. PRIVATE.
sub _glyph_table_ref {
    return \%GLYPH_TABLE;
}
sub glyph_table {
    return { %GLYPH_TABLE };
}

# glyph_width($char) -> the declared width if $char (a decoded character OR its
# UTF-8 byte encoding, per D3) is allow-listed, else undef. PUBLIC.
sub glyph_width {
    my ($c) = @_;
    return undef if !defined $c || $c eq '';
    my $decoded = _decode_str($c);
    return undef if length($decoded) != 1;
    my $gt = _glyph_table_ref();
    return exists $gt->{$decoded} ? $gt->{$decoded} : undef;
}

# display_width($str) -> the number of terminal display columns $str occupies.
# undef/'' -> 0. Never dies, never warns. Decodes per D3, strips SGR/ESC (S3.0,
# shared with _safe), then sums _char_cols over what remains. PUBLIC.
sub display_width {
    my ($str) = @_;
    return 0 if !defined $str || $str eq '';
    my $s = _strip_sgr(_decode_str($str));
    my $w = 0;
    $w += _char_cols($_) for split //, $s;
    return $w;
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

# make_cell($line, $role, $cols) -> \%cell, the single constructor for a
# composed row: { text, role, spans }, with display_width($cell->{text}) ==
# spans_width($cell->{spans}) == $cols, $cell->{text} eq
# spans_text($cell->{spans}), no ESC in $cell->{text}. PUBLIC.
sub make_cell {
    my ($line, $role, $cols) = @_;
    $role = 'body' if !defined $role;
    $cols = 0 if !defined $cols || $cols < 0;
    my $spans = fit_spans(spanify($line, $role), $cols, $role);
    return { text => spans_text($spans), role => $role, spans => $spans };
}

# clip_pad($str, $w) -> exactly $w DISPLAY COLUMNS: truncated if longer
# (mid-glyph cuts drop the glyph, D4), space-padded if shorter. $w <= 0 -> ''.
# undef -> $w spaces. PUBLIC, semantics changed from byte length to display
# columns; signature unchanged.
#
# F2 correction (s04 fix-batch): the previous comment here claimed clip_pad
# "does NOT sanitize... but the result is sanitized in practice" because
# fit_spans/spanify supposedly always did. That was FALSE for a caller of
# clip_pad directly (fit_spans itself did not sanitize -- see redteam-01.md
# MAJOR-2: a live C1 CSI / raw C0 control could survive it). fit_spans now
# sanitizes every character it emits via _safe_char (same mapping `_safe`
# uses), so clip_pad's output genuinely IS sanitized, unconditionally, by
# construction -- not merely "in practice" via an unenforced upstream call.
sub clip_pad {
    my ($s, $w) = @_;
    $w = 0 if !defined $w || $w < 0;
    return spans_text(fit_spans([ { text => $s, role => 'body' } ], $w, 'body'));
}

# _justify($left, $right, $w) -> $left ... $right filling exactly $w DISPLAY
# COLUMNS. If they don't both fit (plus a gap), the right side is dropped and
# the left clipped. String-level (D8); measured with display_width, not
# length. PRIVATE.
sub _justify {
    my ($left, $right, $w) = @_;
    $left  = '' if !defined $left;
    $right = '' if !defined $right;
    if (display_width($left) + display_width($right) + 1 <= $w) {
        my $gap = $w - display_width($left) - display_width($right);
        return $left . (' ' x $gap) . $right;
    }
    return clip_pad($left, $w);
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
my $GLYPH_GREEN  = Encode::encode('UTF-8', "\x{1F7E2}");
my $GLYPH_RED    = Encode::encode('UTF-8', "\x{1F534}");
my $GLYPH_YELLOW = Encode::encode('UTF-8', "\x{1F7E1}");
my $GLYPH_WHITE  = Encode::encode('UTF-8', "\x{26AA}");
my $TRI_UP       = Encode::encode('UTF-8', "\x{25B2}");
my $TRI_DOWN     = Encode::encode('UTF-8', "\x{25BC}");

# @SPINNER -- the ten braille spinner glyphs already allow-listed at
# Dashboard.pm:230-239 (dots-1..dots-10 order, per their own comments),
# ordered here (the hash %GLYPH_TABLE carries no order). s07-live-status
# spec S2.1. No glyph is added to %GLYPH_TABLE; no width declaration changes.
my @SPINNER = map { Encode::encode('UTF-8', $_) }
    ("\x{280B}","\x{2819}","\x{2839}","\x{2838}","\x{283C}",
     "\x{2834}","\x{2826}","\x{2827}","\x{2807}","\x{280F}");   # dots-1 .. dots-10

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
    return ($GLYPH_RED, 'bad')      if $container_gone;
    return ($GLYPH_GREEN, 'good')   if $st eq 'running';
    return ($GLYPH_RED, 'bad')      if $st =~ /^(?:exited|dead|removing|unknown)$/;
    return ($GLYPH_YELLOW, 'warn')  if $st =~ /^(?:created|restarting|stopping|stopped|paused)$/;
    return ($GLYPH_WHITE, 'muted');
}

# spinner_frame($idx) -> UTF-8 bytes of one of the 10 braille spinner glyphs
# in @SPINNER (spec S2.1). PUBLIC, pure, total: never reads the clock -- the
# caller (Dashboard::run, Decision #21) supplies a wall-clock-derived $idx.
# undef / non-numeric / any ref -> frame 0. A negative or fractional index is
# handled by Perl's `%` (period 10 either way): never dies, never warns.
sub spinner_frame {
    my ($idx) = @_;
    $idx = 0 if !defined $idx || ref $idx || $idx !~ /^-?\d+(?:\.\d+)?$/;
    return $SPINNER[$idx % 10];
}

# window_title(\%state) -> an ASCII-safe OS window-title string, "<char>
# <project>" (spec S2.2). Reads ONLY project_name/status/container_gone/
# needs_you; any other key is ignored. $state undef/non-hashref -> {}.
# Reuses container_status_style as the sole status vocabulary (S2.3): no
# status word is re-listed here. Precedence: gone > exited > stopped >
# needs-you > running > fallback. PUBLIC, pure, total. Guaranteed to match
# /\A[\x20-\x7E]{1,80}\z/ for any input.
sub window_title {
    my ($state) = @_;
    $state = {} if !defined $state || ref($state) ne 'HASH';

    my (undef, $role) = container_status_style($state->{status}, $state->{container_gone});
    my $needs_you = $state->{needs_you};
    $needs_you = 0 if !defined $needs_you || ref $needs_you || $needs_you !~ /^-?\d+(?:\.\d+)?$/;

    my $char;
    if ($state->{container_gone})            { $char = '?'; }
    elsif ($role eq 'bad')                   { $char = 'x'; }
    elsif ($role eq 'warn')                  { $char = '-'; }
    elsif ($role eq 'good' && $needs_you > 0) { $char = '!'; }
    elsif ($role eq 'good')                  { $char = '*'; }
    else                                     { $char = '?'; }

    # MINOR-3 (red-team step 6): a ref project_name reaches _decode_str's
    # substr() as an lvalue and warns ("Attempt to use reference as lvalue in
    # substr"). window_title is spec'd total AND warn-free (S2.2/AC-9), so
    # coerce non-scalar values to '' before they reach _safe.
    my $pn = ref($state->{project_name}) ? '' : $state->{project_name};
    my $name = _safe($pn);
    $name =~ s/[^\x20-\x7E]/?/g;   # hard ASCII pass -- _safe alone lets allow-listed glyphs through
    $name =~ s/^\s+//;
    $name =~ s/\s+$//;

    my $title = length($name) ? "$char $name" : $char;
    return substr($title, 0, 80);
}

# oauth_role($remaining_secs) -> $role -- spec S2.2. Mirrors fmt_oauth's
# three-way semantics plus an explicit "expiring soon" yellow tier at
# OAUTH_WARN_SECS. A non-numeric $remaining degrades to the undef/absent
# branch. PUBLIC, pure.
sub oauth_role {
    my ($remaining) = @_;
    return 'bad' if !defined $remaining || $remaining !~ /^-?\d+(?:\.\d+)?$/;
    return 'bad'  if $remaining <= 0;
    return 'warn' if $remaining <= $OAUTH_WARN_SECS;
    return 'good';
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

# pressure_role($used, $total) -> 'good' | 'warn' | 'bad' | 'muted'. An
# undeterminable ratio (no total, a total <= 0, a negative/non-numeric used)
# is 'muted', never a fabricated 0%. Boundaries are inclusive on the upper
# tier: exactly 0.75 is 'warn', exactly 0.90 is 'bad'. Every returned name is
# already styled by sgr_for_role -- this package introduces no new role.
sub pressure_role {
    my ($used, $total) = @_;
    return 'muted' if !defined $total || ref $total || $total !~ /^-?\d+(?:\.\d+)?$/ || $total <= 0;
    return 'muted' if !defined $used  || ref $used  || $used  !~ /^-?\d+(?:\.\d+)?$/ || $used < 0;
    my $r = $used / $total;
    return 'good' if $r < $PRESSURE_WARN;
    return 'warn' if $r < $PRESSURE_BAD;
    return 'bad';
}

# gauge($used, $total, $cells) -> a UTF-8 BYTE string of $cells glyphs (full
# block for the filled part, light shade for the rest). $cells defaults to 10
# and is truncated with int(); an undeterminable ratio renders an all-empty
# gauge, so the display width is ALWAYS exactly $cells whatever the input.
# Both glyphs are already in %GLYPH_TABLE at width 1: this package adds none.
sub gauge {
    my ($used, $total, $cells) = @_;
    my $c = (defined $cells && !ref $cells && $cells =~ /^-?\d+(?:\.\d+)?$/ && $cells >= 1)
          ? int($cells) : $GAUGE_CELLS;
    return $GAUGE_LIGHT x $c if pressure_role($used, $total) eq 'muted';
    my $r = $used / $total;
    $r = 0 if $r < 0;
    $r = 1 if $r > 1;
    my $filled = int($r * $c + 0.5);
    $filled = 0  if $filled < 0;
    $filled = $c if $filled > $c;
    return ($GAUGE_FULL x $filled) . ($GAUGE_LIGHT x ($c - $filled));
}

# fmt_bytes($n) -> 'n/a' | '<N> B' | '<N.N> kB|MB|GB|TB'. DECIMAL units
# (1000), end to end: podman is the source of half the numbers and emits
# decimal (go-units), so parse -> format round-trips and every number can be
# diffed verbatim against `podman stats` / `podman system df`. Plain bytes
# carry no decimals. ASCII-only, so length() == display width.
sub fmt_bytes {
    my ($n) = @_;
    return 'n/a' if !defined $n || ref $n || $n !~ /^-?\d+(?:\.\d+)?$/ || $n < 0;
    return sprintf('%d B', $n) if $n < 1000;
    for my $u ([ 1e12, 'TB' ], [ 1e9, 'GB' ], [ 1e6, 'MB' ], [ 1e3, 'kB' ]) {
        return sprintf('%.1f %s', $n / $u->[0], $u->[1]) if $n >= $u->[0];
    }
    return sprintf('%d B', $n);
}

# event_style($type, $exit, $state) -> ($role, $glyph) -- spec S2.3, the
# activity classifier. $type/$exit/$state are already-scalarized values
# (_ev_scalar); evaluated top to bottom, first match wins. The default is
# 'value' (normal), NOT 'muted' -- an unrecognized event type must not be
# dimmed into invisibility. PUBLIC, pure.
sub event_style {
    my ($type, $exit, $state) = @_;
    $type = '' if !defined $type;
    return ('bad', $GLYPH_RED)      if $type =~ /(?:^|_)(?:failed|failure|error|gone|dead)$/;
    return ('muted', $GLYPH_WHITE)  if $type =~ /^(?:heartbeat|tick)$/;
    if (defined $exit) {
        return ('bad', $GLYPH_RED)  if $exit !~ /^0+$/;
        return ('good', $GLYPH_GREEN);
    }
    return ('good', $GLYPH_GREEN)   if defined $state && $state eq 'ok';
    return ('accent', $GLYPH_WHITE)
        if $type =~ /(?:^|_)(?:start|create|launch)(?:ed)?$/ || $type eq 'launch_session';
    return ('value', $GLYPH_WHITE);
}

# wrap_spans(\@words, $w, $sep_role) -> \@lines -- spec S2.4. Greedy word-wrap
# by DISPLAY width (never length). Each word is atomic (never split); a word
# wider than $w occupies its own line intact (fit_spans truncates at
# render-time). Lines are NOT padded to $w. A malformed element (undef /
# arrayref / blessed ref) contributes an empty word rather than dying
# (_span_hash). PUBLIC, pure, total.
sub wrap_spans {
    my ($words, $w, $sep_role) = @_;
    $sep_role = 'body' if !defined $sep_role;
    return [] if !defined $w || $w !~ /^-?\d+(?:\.\d+)?$/ || $w < 1;
    return [] if ref($words) ne 'ARRAY' || !@$words;

    my @lines;
    my @cur;
    my $cur_w = 0;
    for my $raw (@$words) {
        my $sp   = _span_hash($raw, 'body');
        my $text = defined $sp->{text} ? $sp->{text} : '';
        my $role = defined $sp->{role} ? $sp->{role} : 'body';
        my $ww   = display_width($text);
        if (!@cur) {
            @cur   = ({ text => $text, role => $role });
            $cur_w = $ww;
        } elsif ($cur_w + 1 + $ww <= $w) {
            push @cur, { text => ' ', role => $sep_role }, { text => $text, role => $role };
            $cur_w += 1 + $ww;
        } else {
            push @lines, [ @cur ];
            @cur   = ({ text => $text, role => $role });
            $cur_w = $ww;
        }
    }
    push @lines, [ @cur ] if @cur;
    return \@lines;
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
    return [ { text => '-- previous session --', role => 'muted' } ];
}

# activity_row_width($cols) -> $w -- spec S2.7. $w = $cols - 2 (the
# _panel_rows body-indent span), clamped >= 0; undef/non-numeric $cols -> 0.
# The single place that constant is mirrored, so `run` never open-codes it.
# PUBLIC, pure.
sub activity_row_width {
    my ($cols) = @_;
    return 0 if !defined $cols || $cols !~ /^-?\d+(?:\.\d+)?$/;
    my $w = $cols - 2;
    return $w < 0 ? 0 : $w;
}

# _fixed_panels(\%state, $cols) -> the panels ABOVE the scrollable Activity
# panel (Sandbox, Run, Backpack). Split out so activity_capacity can measure
# their total height to compute how many event rows the Activity panel has
# left. s06-panel-semantics: body lines are now spans-arrayrefs (dim labels,
# colored values; spec S3 behaviors 1-8) and $cols (undef/<1 -> 80, matching
# run's term_size fallback) is threaded through to _backpack_lines so its
# wrapped-paragraph height agrees with the width actually composed.
sub _fixed_panels {
    my ($s, $cols) = @_;
    $s ||= {};
    $cols = 80 if !defined $cols || $cols !~ /^-?\d+(?:\.\d+)?$/ || $cols < 1;
    my @p;

    my @sb;
    push @sb, defined($s->{project_name}) && length($s->{project_name})
        ? [ { text => 'project   : ', role => 'label' }, { text => $s->{project_name}, role => 'strong' } ]
        : [ { text => 'project   : ', role => 'label' }, { text => '?', role => 'muted' } ];

    my ($cglyph, $crole) = container_status_style($s->{status}, $s->{container_gone});
    my $cname_ok  = defined($s->{container}) && length($s->{container});
    my $cstatus   = (defined($s->{status}) && length($s->{status})) ? $s->{status} : '?';
    push @sb, [ { text => 'container : ', role => 'label' },
                { text => ($cname_ok ? $s->{container} : '?'), role => ($cname_ok ? 'value' : 'muted') },
                { text => '  ', role => 'body' },
                { text => "$cglyph [$cstatus]", role => $crole } ];

    push @sb, defined($s->{beat_age})
        ? [ { text => 'heartbeat : ', role => 'label' }, { text => fmt_age($s->{beat_age}) . ' ago', role => 'value' } ]
        : [ { text => 'heartbeat : ', role => 'label' }, { text => 'n/a', role => 'muted' } ];

    push @sb, defined($s->{uptime})
        ? [ { text => 'uptime    : ', role => 'label' }, { text => fmt_hms($s->{uptime}), role => 'value' } ]
        : [ { text => 'uptime    : ', role => 'label' }, { text => 'n/a', role => 'muted' } ];

    # Always shown: a fresh sandbox has no token until an in-container /login
    # (each sandbox owns an independent grant), and "not logged in" is exactly
    # the actionable cue the user needs — so never silently drop the line.
    push @sb, [ { text => 'oauth     : ', role => 'label' },
                { text => fmt_oauth($s->{oauth_remaining}), role => oauth_role($s->{oauth_remaining}) } ];
    push @p, { title => 'Sandbox', lines => \@sb };

    # B3: run + wakefulness state. busy-lease freshness (the orchestrator only
    # refreshes /tmp/.butler-busy while there's active work / pending auto-resume)
    # drives keep-awake; `stay_awake` is the launcher's single computed decision
    # (KeepAwake::should_stay_awake) so this view never re-derives the threshold.
    my @run;
    my ($busy_text, $busy_role);
    if (!defined $s->{busy_age})  { ($busy_text, $busy_role) = ('none (no active run)', 'muted'); }
    elsif ($s->{stay_awake})     { ($busy_text, $busy_role) = ('active (' . fmt_age($s->{busy_age}) . ' ago)', 'good'); }
    else                          { ($busy_text, $busy_role) = ('idle ('   . fmt_age($s->{busy_age}) . ' ago)', 'warn'); }
    push @run, [ { text => 'busy-lease : ', role => 'label' }, { text => $busy_text, role => $busy_role } ];

    my ($keep_text, $keep_role) = $s->{stay_awake}
        ? ('holding (PC stays awake)', 'good') : ('released (PC may sleep)', 'muted');
    push @run, [ { text => 'keep-awake : ', role => 'label' }, { text => $keep_text, role => $keep_role } ];

    my $ny = (defined $s->{needs_you} && $s->{needs_you} =~ /^\d+$/) ? $s->{needs_you} : 0;
    my ($needs_text, $needs_role) = $ny > 0 ? ("$ny decision(s) waiting", 'warn') : ('none', 'muted');
    push @run, [ { text => 'needs you  : ', role => 'label' }, { text => $needs_text, role => $needs_role } ];
    push @run, _run_lines($s->{runs});   # s10
    push @p, { title => 'Run', lines => \@run };

    # B4: backpack view — per-item approval state (#21). Present only when the
    # launcher gathered a backpack structure for this project. s06: a wrapped
    # paragraph, so its width (hence height) must agree with $cols.
    if (ref $s->{backpack} eq 'HASH') {
        push @p, { title => 'Backpack', lines => [ _backpack_lines($s->{backpack}, $cols - 2) ] };
    }

    # s08: access/refresh token status view. Present only when the launcher
    # gathered a TokenInfo struct for this project (I1: that struct itself is
    # never undef, so the guard here only protects callers that never supply
    # the key at all -- e.g. the pre-s08 t/25-dashboard.t gather stubs).
    if (ref $s->{tokens} eq 'HASH') {
        push @p, { title => 'Token', lines => [ _token_lines($s->{tokens}) ] };
    }

    # s09: podman machine + container + host resources. Present only when the
    # launcher gathered a Resources struct (I3: that struct is never undef, so
    # the guard here only protects callers that never supply the key at all).
    # Appended LAST on purpose: _body_rows pulls only positions 0/1 (always
    # Sandbox and Run) into the two-column region, so this stacks full-width.
    if (ref $s->{resources} eq 'HASH') {
        push @p, { title => 'Resources', lines => [ _resources_lines($s->{resources}) ] };
    }
    return @p;
}

# build_panels(\%state, $cols) -> ordered list of { title => str,
# lines => [line,...] }, where a line is a spans-arrayref (or, for the
# Activity panel, a plain string / spans-arrayref per event -- see
# recent_events). The Activity panel is always LAST (the scrollable,
# height-flexible one); the loop fills state.events with the already-windowed
# lines (see activity_window). $cols forwards to _fixed_panels (s06).
sub build_panels {
    my ($s, $cols) = @_;
    $s ||= {};
    my @p = _fixed_panels($s, $cols);
    my $ev = (ref $s->{events} eq 'ARRAY') ? $s->{events} : [];
    push @p, { title => 'Recent activity',
               lines => (@$ev ? [@$ev] : ['(no events yet)']) };
    return @p;
}

# _backpack_lines(\%backpack, $w) -> body lines for the B4 panel. {total,
# approved, items=>[{key, approved}]}. s06-panel-semantics (spec S3 items
# 9-13): a header line (counts, no more (+)/(-) legend) followed by up to
# BACKPACK_MAX_ROWS wrapped paragraph rows of space-separated item keys
# (color carries approval state), capped with a "+N more" word when the full
# list doesn't fit -- K is the largest prefix of items whose wrap (plus the
# "+N more" word) still fits in BACKPACK_MAX_ROWS rows. $w (paragraph wrap
# width) undef/<1 -> 78.
sub _backpack_lines {
    my ($bp, $w) = @_;
    $bp ||= {};
    $w = 78 if !defined $w || $w !~ /^-?\d+(?:\.\d+)?$/ || $w < 1;
    my $total = (defined $bp->{total} && $bp->{total} =~ /^\d+$/) ? $bp->{total} : 0;
    return ( [ { text => '(no backpack for this project)', role => 'muted' } ] ) if $total == 0;
    my $appr = (defined $bp->{approved} && $bp->{approved} =~ /^\d+$/) ? $bp->{approved} : 0;
    my $pend = $total - $appr; $pend = 0 if $pend < 0;

    my @header = ( { text => "$total item(s) - ", role => 'label' },
                   { text => "$appr approved",    role => 'good'  } );
    push @header, ( { text => ', ', role => 'label' }, { text => "$pend pending", role => 'warn' } )
        if $pend > 0;
    my @out = ( \@header );

    my $items = (ref $bp->{items} eq 'ARRAY') ? $bp->{items} : [];
    my @words = map {
        my $it  = (ref $_ eq 'HASH') ? $_ : {};
        my $key = (defined($it->{key}) && length($it->{key})) ? $it->{key} : '?';
        { text => $key, role => ($it->{approved} ? 'good' : 'warn') };
    } @$items;

    my $wrapped_all = wrap_spans(\@words, $w);
    if (@$wrapped_all <= $BACKPACK_MAX_ROWS) {
        push @out, @$wrapped_all;
        return @out;
    }

    # Doesn't fit: search for the largest K (item keys shown, in order) such
    # that those K words plus a trailing "+N more" (N = total shown - K) word
    # still wrap to <= BACKPACK_MAX_ROWS rows. K=0 (just "+N more" alone)
    # always succeeds -- a lone word always occupies exactly one line.
    my $n_words = scalar(@words);
    for (my $k = $n_words - 1; $k >= 0; $k--) {
        my $n = $n_words - $k;
        my @try = (@words[0 .. $k - 1], { text => "+$n more", role => 'muted' });
        my $wrapped = wrap_spans(\@try, $w);
        if (@$wrapped <= $BACKPACK_MAX_ROWS) {
            push @out, @$wrapped;
            return @out;
        }
    }
    push @out, @{ wrap_spans([ { text => "+$n_words more", role => 'muted' } ], $w) };
    return @out;
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
our $RUN_MAX_ROWS = 3;

# _run_int($v) -> a non-negative Int, or 0 for undef/ref/non-digit input
# (private helper for _run_lines' numeric fields).
sub _run_int {
    my ($v) = @_;
    return (defined($v) && !ref($v) && $v =~ /^\d+$/) ? ($v + 0) : 0;
}

# _run_state_role($state) -> the S2.10a role for a run-summary state span.
my %RUN_STATE_ROLE = ( running => 'good', paused => 'warn', parked => 'warn', idle => 'muted' );
sub _run_state_role {
    my ($state) = @_;
    return $RUN_STATE_ROLE{$state} // 'muted';
}

# _one_run_line(\%summary) -> \@spans (private) -- the S2.10 exact span
# composition for one RunState summary.
sub _one_run_line {
    my ($s) = @_;
    my $bp = (defined($s->{blueprint}) && !ref($s->{blueprint}) && length($s->{blueprint}))
           ? $s->{blueprint} : '?';
    my @spans;
    push @spans, { text => "$bp : ", role => 'accent' };

    my $state = (defined($s->{state}) && !ref($s->{state}) && length($s->{state}))
              ? $s->{state} : '?';
    push @spans, { text => $state, role => _run_state_role($state) };

    my $done  = _run_int($s->{packages_done});
    my $total = _run_int($s->{packages_total});
    push @spans, { text => sprintf('  %d/%d pkg', $done, $total), role => 'value' };

    if (defined($s->{current_package}) && !ref($s->{current_package}) && length($s->{current_package})) {
        # MAJOR-3 (fix-batch): defensive truncation at the renderer, in
        # addition to RunState.pm's producer-side bound -- never hand _safe
        # more than a line's worth, regardless of what produced the struct.
        my $cp = substr($s->{current_package}, 0, 200);
        push @spans, { text => "  cur $cp", role => 'strong' };
    }

    my $coord = _run_int($s->{running_coordinators});
    push @spans, { text => sprintf('  %d coord', $coord), role => 'accent' } if $coord > 0;

    my $waiting = _run_int($s->{decisions_waiting});
    if ($waiting > 0) {
        push @spans, { text => sprintf('  %d waiting', $waiting), role => ($state eq 'paused' ? 'bad' : 'warn') };
    }

    return \@spans;
}

sub _run_lines {
    my ($runs) = @_;
    return () unless ref($runs) eq 'ARRAY';
    my @summaries = grep { ref($_) eq 'HASH' } @$runs;
    return () unless @summaries;

    my @out;
    my $shown = (@summaries < $RUN_MAX_ROWS) ? scalar(@summaries) : $RUN_MAX_ROWS;
    push @out, _one_run_line($summaries[$_]) for (0 .. $shown - 1);

    if (@summaries > $RUN_MAX_ROWS) {
        my $extra = @summaries - $RUN_MAX_ROWS;
        push @out, [ { text => sprintf('  +%d more blueprint(s)', $extra), role => 'muted' } ];
    }
    return @out;
}

# _token_lines(\%tokens) -> LIST of body lines for the s08 Token panel.
# {logged_in, access_present, access_state, access_expires_at,
# access_seconds_left, refresh_present, refresh_fingerprint, refresh_expires,
# last_refreshed_at, last_refreshed_age, subscription_type?, rate_limit_tier?}
# -- the TokenInfo::status struct (spec S2.1), passed through the gather hash
# with no arithmetic. PRIVATE, pure, mirrors _backpack_lines's style. A
# non-hashref $tokens -> the empty list (never dies).
sub _token_lines {
    my ($t) = @_;
    return () unless ref $t eq 'HASH';

    my @lines;

    # 1. access — reuses fmt_oauth/oauth_role verbatim (S2.3 a1): no divergent
    # token classifier. access_state 'absent' covers both "no token" and "a
    # token whose expiry can't be read" (TokenInfo B4), both of which must
    # render as the same "not logged in" cue, not a stale countdown.
    my $access_state = defined $t->{access_state} ? $t->{access_state} : 'absent';
    my $sec = ($access_state eq 'absent') ? undef : $t->{access_seconds_left};
    push @lines, [ { text => sprintf('%-11s : ', 'access'), role => 'label' },
                   { text => fmt_oauth($sec), role => oauth_role($sec) } ];

    # 2. refresh
    if ($t->{refresh_present}) {
        my $fp = defined $t->{refresh_fingerprint} ? $t->{refresh_fingerprint} : '';
        push @lines, [ { text => sprintf('%-11s : ', 'refresh'), role => 'label' },
                       { text => "present ($fp)", role => 'good' } ];
    } else {
        push @lines, [ { text => sprintf('%-11s : ', 'refresh'), role => 'label' },
                       { text => 'absent', role => 'bad' } ];
    }

    # 3. refreshed
    if (defined $t->{last_refreshed_age}) {
        push @lines, [ { text => sprintf('%-11s : ', 'refreshed'), role => 'label' },
                       { text => fmt_age($t->{last_refreshed_age}) . ' ago', role => 'value' } ];
    } else {
        push @lines, [ { text => sprintf('%-11s : ', 'refreshed'), role => 'label' },
                       { text => 'n/a', role => 'muted' } ];
    }

    # 4. refresh-exp — always the struct value verbatim (Decision #18: never
    # computed here); a missing/undef key falls back to the plain 'n/a'
    # literal (S5: a future caller passing tokens => {}).
    my $rexp = defined $t->{refresh_expires} ? $t->{refresh_expires} : 'n/a';
    push @lines, [ { text => sprintf('%-11s : ', 'refresh-exp'), role => 'label' },
                   { text => $rexp, role => 'muted' } ];

    # 5. account — optional, present iff at least one of the two pass-through
    # fields exists with a defined, non-empty value (subscription_type first).
    my @present;
    for my $k (qw(subscription_type rate_limit_tier)) {
        push @present, $t->{$k} if defined $t->{$k} && length $t->{$k};
    }
    if (@present) {
        push @lines, [ { text => sprintf('%-11s : ', 'account'), role => 'label' },
                       { text => join(' / ', @present), role => 'value' } ];
    }

    return @lines;
}

# _resources_lines(\%res) -> LIST of body lines for the s09 Resources panel.
# The 15-key resource struct the launcher built (machine_*, ctr_*, vm_*,
# pod_*, host_* -- source-labelled, closed key set),
# passed through the gather hash with no arithmetic -- every derivation
# already happened in the launcher. PRIVATE, pure, mirrors _token_lines'
# style. A non-hashref $res -> the empty list (never dies).
#
# ALWAYS exactly 7 lines, whatever the input: an unknown fact renders 'n/a',
# never a fabricated number and never a vanished row. host_* and vm_*/ctr_*
# facts are labelled by source and never conflated.
sub _resources_lines {
    my ($r) = @_;
    return () unless ref $r eq 'HASH';

    my @lines;
    my $label = sub { return { text => sprintf('%-11s : ', $_[0]), role => 'label' }; };
    my $na    = sub { return { text => 'n/a', role => 'muted' }; };

    # A used/total row: the three numbers (used | free | total) plus a gauge,
    # both carrying the pressure role. Emitted only when both values are
    # present; otherwise the single n/a span and NO gauge (never a 0% bar for
    # a fact we don't have).
    my $gauge_row = sub {
        my ($used, $total) = @_;
        return ($na->()) unless defined $used && defined $total;
        my $role  = pressure_role($used, $total);
        my $avail = (!ref $used && !ref $total
                     && $used  =~ /^-?\d+(?:\.\d+)?$/
                     && $total =~ /^-?\d+(?:\.\d+)?$/) ? $total - $used : undef;
        $avail = 0 if defined $avail && $avail < 0;
        return ( { text => sprintf('%s used | %s free | %s total',
                                   fmt_bytes($used), fmt_bytes($avail), fmt_bytes($total)),
                   role => $role },
                 { text => '  ', role => 'body' },
                 { text => gauge($used, $total), role => $role } );
    };

    # 1. machine — the podman VM's lifecycle state, plus its name when known.
    my %mstate = (running => 'good', starting => 'warn', stopped => 'bad');
    my $ms = $r->{machine_state};
    my @m = (defined $ms && !ref $ms && $mstate{$ms})
          ? ( { text => $ms, role => $mstate{$ms} } ) : ( $na->() );
    push @m, { text => " ($r->{machine_name})", role => 'muted' }
        if defined $r->{machine_name} && !ref $r->{machine_name} && length $r->{machine_name};
    push @lines, [ $label->('machine'), @m ];

    # 2. ctr mem — THIS container against the VM's cgroup limit (the real
    # limit, not the cosmetic configured one).
    #
    # KNOWN WART: the numerator is per-container, the denominator VM-wide, so
    # $gauge_row's middle "free" term is VM-free-of-THIS-container — it ignores
    # every other container and every VM-side process, and therefore overstates
    # the headroom this container can actually take. used/limit is still the
    # meaningful pressure ratio, and podman gives us no container-free figure to
    # print instead (fabricating one would violate "report what is real"). The
    # honest fix is a label/wording change ('ctr/vm mem', or dropping the free
    # term for this row) — both are pinned verbatim by t/44-resources.t's B23
    # table, so it belongs in the package that may amend the oracle.
    push @lines, [ $label->('ctr mem'), $gauge_row->($r->{ctr_mem_used}, $r->{vm_mem_total}) ];

    # 3. ctr cpu — no gauge: a container's CPU% is not bounded by 100 on a
    # multi-core host, so a 0-100 bar would misrepresent it.
    my $cpct = $r->{ctr_cpu_pct};
    push @lines, [ $label->('ctr cpu'),
                   (defined $cpct && !ref $cpct && $cpct =~ /^-?\d+(?:\.\d+)?$/)
                     ? { text => sprintf('%.1f%%', $cpct), role => 'value' } : $na->() ];

    # 4. podman — the image/container/volume store on disk. Each component
    # degrades independently; only an all-unknown row collapses to n/a.
    my ($pi, $pc, $pv) = ($r->{pod_images}, $r->{pod_containers}, $r->{pod_volumes});
    push @lines, [ $label->('podman'),
                   (defined $pi || defined $pc || defined $pv)
                     ? { text => sprintf('images %s | containers %s | volumes %s',
                                         fmt_bytes($pi), fmt_bytes($pc), fmt_bytes($pv)),
                         role => 'value' }
                     : $na->() ];

    # 5. host ram — the Windows host, never summed with the VM's numbers.
    push @lines, [ $label->('host ram'), $gauge_row->($r->{host_ram_used}, $r->{host_ram_total}) ];

    # 6. host disk — the drive suffix is printed in BOTH branches: the panel
    # always names the device it measured (or would have measured).
    my @d = $gauge_row->($r->{host_disk_used}, $r->{host_disk_total});
    push @d, { text => " ($r->{host_disk_dev})", role => 'muted' }
        if defined $r->{host_disk_dev} && !ref $r->{host_disk_dev} && length $r->{host_disk_dev};
    push @lines, [ $label->('host disk'), @d ];

    # 7. host cpu — bounded by 100 by definition, so this one does get a gauge.
    my $hpct = $r->{host_cpu_pct};
    my @c;
    if (defined $hpct && !ref $hpct && $hpct =~ /^-?\d+(?:\.\d+)?$/) {
        my $role = pressure_role($hpct, 100);
        @c = ( { text => sprintf('%.1f%%', $hpct), role => $role },
               { text => '  ', role => 'body' },
               { text => gauge($hpct, 100), role => $role } );
    } else {
        @c = ( $na->() );
    }
    push @c, { text => sprintf(' (%d cores)', $r->{host_cores}), role => 'muted' }
        if defined $r->{host_cores} && !ref $r->{host_cores} && $r->{host_cores} =~ /^\d+$/;
    push @lines, [ $label->('host cpu'), @c ];

    return @lines;
}

# _title_line / _footer_line / _panel_title_line — single rows, exactly $cols.
# _title_line returns an ARRAYREF of {text,role} spans (s07-live-status spec
# S2.4), which make_cell -> spanify already accepts. With $s->{spinner_idx}
# absent (every pre-existing direct compose_frame call), the emitted text is
# byte-identical to the pre-s07 plain-string output -- this backward
# compatibility is load-bearing.
sub _title_line {
    my ($s, $cols) = @_;
    my $left = 'ccpraxis sandbox';
    $left .= ' - ' . _safe($s->{project_name}) if defined $s->{project_name} && length $s->{project_name};
    my $ctr = _safe(defined $s->{container} ? $s->{container} : '');
    my $st  = _safe(defined $s->{status}    ? $s->{status}    : '?');
    my (undef, $role) = container_status_style($s->{status}, $s->{container_gone});

    my $spin;
    my $idx = $s->{spinner_idx};
    $spin = spinner_frame($idx)
        if defined $idx && !ref($idx) && $idx =~ /^-?\d+(?:\.\d+)?$/;

    my @right_spans = (
        { text => (length $ctr ? "$ctr [" : '['), role => 'title' },
        (defined $spin ? ({ text => "$spin ", role => $role }) : ()),
        { text => $st, role => $role },
        { text => ']', role => 'title' },
    );

    my $lw = display_width($left);
    my $rw = spans_width(\@right_spans);
    if ($lw + $rw + 1 <= $cols) {
        return [
            { text => $left, role => 'title' },
            { text => (' ' x ($cols - $lw - $rw)), role => 'title' },
            @right_spans,
        ];
    }
    return [ { text => clip_pad($left, $cols), role => 'title' } ];
}

# footer_legend($cols) -> the unpadded command legend, tiered so the pinned
# "[c] launch Claude Code" wording (Decision #9) survives down to 80 cols
# before degrading (s11-lifecycle-stop spec 08 S2.2). PURE; the caller
# (_footer_line) is the only one that pads.
sub footer_legend {
    my ($cols) = @_;
    $cols = 200 if !defined $cols;
    my @tiers = (
        ' [c] launch Claude Code  [s] stop runs  [x] full shutdown  [up/down] scroll  [r] refresh  [q] quit',
        ' [c] launch Claude Code  [s] stop runs  [x] shutdown  [r] refresh  [q] quit',
        ' [c] launch  [s] stop  [x] shutdown  [r] refresh  [q] quit',
    );
    for my $t (@tiers) {
        return $t if display_width($t) <= $cols;
    }
    return $tiers[-1];
}

# confirm_prompt($pending, $cols) -> the unpadded two-step confirm text for
# one of the two pinned pending tokens, or undef for anything else (including
# the retired 'shutdown' token). Two tiers per token, "first that fits, else
# the short one" (s11-lifecycle-stop spec 08 S2.2). PURE.
sub confirm_prompt {
    my ($pending, $cols) = @_;
    $cols = 200 if !defined $cols;
    return undef unless defined $pending;
    if ($pending eq 'stop-runs') {
        my $L = 'Stop ALL butler runs in this project? The container and podman machine stay UP. [y] confirm   [any other] cancel';
        my $S = 'Stop ALL butler runs? Container+machine stay up. [y] confirm  [other] cancel';
        return display_width($L) <= $cols ? $L : $S;
    }
    if ($pending eq 'full-shutdown') {
        my $L = 'Full shutdown: stop ALL butler runs, then STOP THIS CONTAINER, then stop the podman machine if no other container is running. [y] confirm   [any other] cancel';
        my $S = 'Stop runs + STOP CONTAINER (+ machine if last). [y] confirm  [other] cancel';
        return display_width($L) <= $cols ? $L : $S;
    }
    # s12-lifecycle-relaunch: [l] is the ONLY constructive lifecycle control, so
    # both tiers promise "nothing is deleted" -- the confirm has to read visibly
    # unlike the two destructive ones above or a user trained to fear the
    # red footer banner will cancel the one control that fixes their sandbox.
    # THREE tiers, not two: the spec's short tier is 88 display columns, so at
    # the 80-col reference width _footer_line's clip_pad would truncate it
    # mid-word and the footer would no longer carry a whole prompt. The two
    # spec-pinned wordings are kept verbatim as T1/T2; T3 is a genuinely-short
    # tier that survives 80 (and below) intact.
    if ($pending eq 'relaunch') {
        my @tiers = (
            'Relaunch: start the podman machine if it is down, start this container, and re-attach. Nothing is deleted. [y] confirm   [any other] cancel',
            'Start machine + container and re-attach. Nothing is deleted. [y] confirm  [other] cancel',
            'Relaunch machine + container. Nothing is deleted. [y] confirm  [other] cancel',
        );
        for my $t (@tiers) {
            return $t if display_width($t) <= $cols;
        }
        return $tiers[-1];
    }
    return undef;
}

sub _footer_line {
    my ($s, $cols) = @_;
    my $pending = defined $s->{pending} ? $s->{pending} : '';
    my $legend;
    my $prompt = confirm_prompt($pending, $cols);
    if (defined $prompt) {
        $legend = $prompt;
    } elsif (defined $s->{footer_flash} && length $s->{footer_flash}) {
        $legend = ' ' . $s->{footer_flash};   # transient [c]-on-dead-container notice
    } else {
        $legend = footer_legend($cols);
    }
    return clip_pad($legend, $cols);
}

# _alert_line($msg, $cols) -> a full-width banner row (rendered red via the
# 'alert' role). Used for the backpack-install-failure warning so it can't be
# lost behind the alt-screen the way the pre-dashboard stdout warning was.
sub _alert_line {
    my ($msg, $cols) = @_;
    return clip_pad('  !! ' . _safe(defined $msg ? $msg : ''), $cols);
}

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

sub _panel_title_line {
    my ($title, $cols) = @_;
    my $s = '-- ' . _safe($title) . ' ';
    $s .= '-' x ($cols - display_width($s)) if display_width($s) < $cols;
    return clip_pad($s, $cols);
}

# _two_col_min_cols() -> 100 (PRIVATE, pure). The pinned two-column threshold
# (s05 D1); the single source of truth -- nothing else may hardcode it.
sub _two_col_min_cols {
    return 100;
}

# _two_col_mode($cols) -> 0|1 (PRIVATE, pure). Mode depends on $cols ONLY (D2):
# never rows, alerts, panel count or state. Never dies, never warns -- undef,
# 0, and negative all fall through to stacked (0). A non-numeric $cols (never
# seen from a real caller -- activity_capacity/compose_frame only ever pass
# integers/undef) is guarded via a string-context regex check rather than
# handed raw to the numeric `>=`, so it degrades to stacked (0) instead of
# tripping perl's "isn't numeric" warning under `use warnings` (F1).
sub _two_col_mode {
    my ($cols) = @_;
    return 0 if !defined $cols;
    return 0 if $cols !~ /^-?\d+(?:\.\d+)?$/;
    return ($cols >= _two_col_min_cols()) ? 1 : 0;
}

# _col_widths($cols) -> ($lw, $rw) (PRIVATE, pure). Right column absorbs the
# extra column on an odd width (D4); $lw + $rw == $cols always.
sub _col_widths {
    my ($cols) = @_;
    my $lw = int($cols / 2);
    my $rw = $cols - $lw;
    return ($lw, $rw);
}

# _panel_rows(\%panel, $w, $maxh) -> up to $maxh { text, role, spans } cells:
# today's per-panel body of _body_rows factored out verbatim (s05 s2.4) so the
# stacked path and each two-column half render identically. See _body_rows'
# doc comment above for the accepted body-line shapes. A $panel->{lines} that
# isn't an ARRAY ref (never produced by _fixed_panels today, but a forward
# risk once s06-s16 add more panels) is coerced to [] rather than
# dereferenced raw (INV-8, matches _fixed_region_height's existing
# `@{ $_->{lines} || [] }` coercion). PRIVATE.
sub _panel_rows {
    my ($panel, $w, $maxh) = @_;
    my @out;
    return @out if !defined $maxh || $maxh < 1;
    push @out, make_cell(_panel_title_line($panel->{title}, $w), 'panel-title', $w);
    my $lines = (ref($panel->{lines}) eq 'ARRAY') ? $panel->{lines} : [];
    for my $ln (@$lines) {
        last if @out >= $maxh;
        my $role = (ref($ln) eq 'HASH' && defined $ln->{role}) ? $ln->{role} : 'body';
        # F4 (s04 fix-batch): don't pre-canonicalize $ln via spanify() here
        # -- make_cell(\@full, ...) below calls spanify() on \@full anyway,
        # so calling it twice ran _safe (decode+strip+map) over the SAME
        # text twice, every body row, every frame. Instead just flatten
        # $ln's raw element(s) alongside the indent span and let
        # make_cell's single internal spanify() canonicalize once. The
        # three accepted shapes need different flattening (mirrors
        # spanify's own dispatch, S3.4): an arrayref of spans flattens
        # element-wise; a { role, spans => [...] } hash flattens its spans
        # array; anything else (plain string / {text,role}) is one element.
        my @elems;
        if (ref($ln) eq 'ARRAY') {
            @elems = @$ln;
        } elsif (ref($ln) eq 'HASH' && ref($ln->{spans}) eq 'ARRAY') {
            @elems = @{ $ln->{spans} };
        } else {
            @elems = ($ln);
        }
        push @out, make_cell([ { text => '  ', role => 'body' }, @elems ], $role, $w);
    }
    push @out, make_cell('', 'blank', $w) if @out < $maxh;
    return @out;
}

# _join_cells(\%left, \%right) -> \%cell (PRIVATE, pure, s05 D3). Builds each
# half as an independent make_cell at its own half-width, then concatenates
# text and spans -- no new render primitive, no gutter (D5). role is the LEFT
# cell's role (per-span roles carry the styling; the row role is only a
# diff/fallback key, s04 S4). Uses _cell_spans so a hand-built span-free cell
# still joins. A $l/$r that isn't even a hashref (never produced by
# _panel_rows/make_cell today, but a forward risk once s06-s16 add more
# panels) is guarded the same way _cell_spans already guards `spans` --
# `text` defaults to '' and `role` to 'body' rather than dereferenced raw
# (INV-8).
sub _join_cells {
    my ($l, $r) = @_;
    my $lt = (ref($l) eq 'HASH' && defined $l->{text}) ? $l->{text} : '';
    my $rt = (ref($r) eq 'HASH' && defined $r->{text}) ? $r->{text} : '';
    my $lrole = (ref($l) eq 'HASH' && defined $l->{role}) ? $l->{role} : 'body';
    return {
        text  => $lt . $rt,
        role  => $lrole,
        spans => [ @{ _cell_spans($l) }, @{ _cell_spans($r) } ],
    };
}

# _two_col_rows(\%left_panel, \%right_panel, $cols, $maxh) -> @cells (PRIVATE,
# pure, s05 D3/D6). Splits $cols via _col_widths, renders each side
# independently via _panel_rows at its own half-width with the SAME $maxh (so
# both halves truncate at the same absolute row), pads the shorter side with
# blank cells, joins row-for-row via _join_cells. Depends only on its
# arguments -- no %state, no globals.
sub _two_col_rows {
    my ($left, $right, $cols, $maxh) = @_;
    my @out;
    return @out if !defined $maxh || $maxh < 1;
    my ($lw, $rw) = _col_widths($cols);
    my @L = _panel_rows($left,  $lw, $maxh);
    my @R = _panel_rows($right, $rw, $maxh);
    my $h = (@L > @R) ? scalar(@L) : scalar(@R);
    for my $i (0 .. $h - 1) {
        my $lc = defined $L[$i] ? $L[$i] : make_cell('', 'blank', $lw);
        my $rc = defined $R[$i] ? $R[$i] : make_cell('', 'blank', $rw);
        push @out, _join_cells($lc, $rc);
    }
    return @out;
}

# _body_rows(\%state, $cols, $maxh) -> up to $maxh { text, role, spans } cells:
# each panel rendered as a title line, its (indented) body lines, then a blank
# separator, clipped to $maxh. A body line may be a plain string, { text, role }
# (the Activity panel's scroll hint), an arrayref of spans, or
# { role, spans => [...] } (s05+'s seam; forwarded to spanify) -- the two-space
# body indent is a leading { text => '  ', role => 'body' } span in every case.
#
# s05: at or above _two_col_min_cols(), the first two _fixed_panels entries
# (Sandbox, Run -- unconditionally positions 0/1, D7) are pulled off and
# rendered as a joined two-column region via _two_col_rows; every remaining
# panel (Backpack when present, Recent activity always last) stacks
# full-width below it via _panel_rows, exactly as today. Below the threshold
# this is byte-identical to the pre-s05 stacked loop. PRIVATE.
sub _body_rows {
    my ($state, $cols, $maxh) = @_;
    my @out;
    return @out if !defined $maxh || $maxh < 1;
    my @panels = build_panels($state, $cols);
    if (_two_col_mode($cols) && @panels >= 2) {
        my $left  = shift @panels;
        my $right = shift @panels;
        push @out, _two_col_rows($left, $right, $cols, $maxh);
    }
    for my $p (@panels) {
        last if @out >= $maxh;
        push @out, _panel_rows($p, $cols, $maxh - scalar(@out));
    }
    @out = @out[0 .. $maxh - 1] if @out > $maxh;
    return @out;
}

# compose_frame(\%state, $rows, $cols) -> arrayref of EXACTLY $rows
# { text, role, spans } cells (every cell built via make_cell, so
# display_width($cell->{text}) == $cols for every row). Layout: title row, a
# body region of stacked panels, and a footer legend reserved on the last row.
# Degrades cleanly to tiny terminals (1xN -> title only; 2xN -> title+footer).
# PUBLIC, cells extended (F9: s04 fix-batch doc-tag pass).
sub compose_frame {
    my ($state, $rows, $cols) = @_;
    $state ||= {};
    $rows = 0 if !defined $rows || $rows < 0;
    $cols = 1 if !defined $cols || $cols < 1;
    my @frame;
    return \@frame if $rows < 1;

    push @frame, make_cell(_title_line($state, $cols), 'title', $cols);
    return \@frame if $rows == 1;

    my $footer_role = 'footer';
    if (defined $state->{pending}
        && ($state->{pending} eq 'stop-runs' || $state->{pending} eq 'full-shutdown'
            || $state->{pending} eq 'relaunch')) {
        $footer_role = 'footer-alert';
    } elsif (defined $state->{footer_flash} && length $state->{footer_flash}) {
        $footer_role = 'footer-flash';   # transient launch-blocked notice
    }
    my $footer = make_cell(_footer_line($state, $cols), $footer_role, $cols);

    if ($rows == 2) {
        push @frame, $footer;
        return \@frame;
    }

    # Optional alert banner(s) directly under the title: a container that is no
    # longer running / reachable (so the dashboard staying open after a container
    # death is obvious and actionable) and/or a backpack-install failure. Each
    # needs room for title + alert + >=1 body + footer; on a tiny terminal we
    # drop the lowest-priority alerts (install_warning first) rather than crowd
    # out the body. The launcher surfaces these where a pre-dashboard stdout
    # warning would otherwise be wiped by the alt-screen.
    my @msgs = _alert_msgs($state, $rows);
    my @alert = map { make_cell(_alert_line($_, $cols), 'alert', $cols) } @msgs;

    my $body_h = $rows - 2 - scalar(@alert);
    my @body = _body_rows($state, $cols, $body_h);
    while (@body < $body_h) {
        push @body, make_cell('', 'blank', $cols);
    }
    push @frame, @alert, @body;
    push @frame, $footer;
    return \@frame;
}

# sgr_for_role($role) -> the SGR escape for a role (row role or span role;
# color mode only). '' for unknown roles, 'body', 'blank' and undef.
# PUBLIC, extended (F9: s04 fix-batch doc-tag pass).
sub sgr_for_role {
    my ($role) = @_;
    $role = '' if !defined $role;
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
    return "\e[36m"       if $role eq 'accent';       # cyan
    return '';
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
# Full redraw (clear + every row) when there is no previous frame, the row count
# changed (a resize), or opts.full is set; otherwise a per-row diff that touches
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
    my $full  = $opts->{full} || !$prev || !@$prev || @$prev != @$new;

    my $out = "\e[?2026h";   # begin synchronized output
    $out .= "\e[2J\e[H" if $full;
    for my $i (0 .. $#$new) {
        unless ($full) {
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

# decide_spawn_mode($wt, $comspec, $os) -> 'wt' | 'start' | 'inline'.
# Prefer a real new Windows Terminal window; else a new console via cmd `start`;
# else reuse the dashboard window (Decision #19's fallback ladder).
sub decide_spawn_mode {
    my ($wt, $comspec, $os) = @_;
    return 'wt'    if $wt;
    my $is_win = (defined $os ? $os : $^O) =~ /^(MSWin32|cygwin|msys)$/;
    return 'start' if $is_win && $comspec;
    return 'inline';
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
# Optional 3rd arg $localtime_fn is the time seam passed to _event_time; omit
# for real localtime (2-arg callers unchanged). s06-panel-semantics (spec
# S3.14): each accepted record is now a spans-arrayref -- dim timestamp +
# severity glyph + semantically-colored body (classified by event_style),
# not an opaque string. The timestamp span is ALWAYS role 'muted', regardless
# of classification.
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

sub recent_events {
    my ($lines, $n, $localtime_fn) = @_;
    $lines ||= [];
    $n = 10 if !defined $n || $n < 1;
    my $jp = JSON::PP->new;
    my @ev;
    for my $ln (@$lines) {
        next unless defined $ln && $ln =~ /\S/;
        my $rec = eval { $jp->decode($ln) };
        next unless $rec && ref $rec eq 'HASH';
        my $ts   = defined $rec->{ts} ? $rec->{ts} : '';
        my $hms  = _event_time($ts, $localtime_fn);
        my $type = _ev_scalar($rec->{type});
        $type = 'event' if !defined $type;
        my $extra = '';
        my $exit  = _ev_scalar($rec->{exit});
        my $state = _ev_scalar($rec->{state});
        $extra .= " exit=$exit"   if defined $exit;
        $extra .= " state=$state" if defined $state;
        my ($role, $glyph) = event_style($type, $exit, $state);
        my @spans;
        push @spans, { text => "$hms  ", role => 'muted' } if length $hms;
        push @spans, { text => "$glyph ", role => $role };
        push @spans, { text => "$type$extra", role => $role };
        push @ev, \@spans;
    }
    my @last = @ev > $n ? @ev[-$n .. -1] : @ev;
    return \@last;
}

# activity_view(\@events_chrono, $offset) -> the events to DISPLAY in the Activity
# panel, NEWEST-FIRST (descending), starting $offset items down from the newest.
# $offset is the up/down scroll position (0 = newest at top); it's clamped to
# [0, last index] so scrolling can't run off either end. Pure / unit-tested; the
# loop keeps the offset and feeds the result to the panel each frame. (Retained;
# activity_window is the capacity-aware successor used by the loop.)
sub activity_view {
    my ($events, $offset) = @_;
    $events ||= [];
    my @desc = reverse @$events;
    return [] unless @desc;
    $offset = 0       if !defined $offset || $offset < 0;
    $offset = $#desc  if $offset > $#desc;
    return [ @desc[$offset .. $#desc] ];
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
    my $max_alert = (defined $rows ? $rows : 0) - 3;   # title + >=1 body + footer
    $max_alert = 0 if $max_alert < 0;
    if (@msgs > $max_alert) {
        @msgs = $max_alert > 0 ? @msgs[0 .. $max_alert - 1] : ();
    }
    return @msgs;
}

# _fixed_region_height(\%state, $cols) -> $h (PRIVATE, pure, s05 s2.8). The
# single arithmetic mirror of the fixed (non-Activity) region's height, shared
# by activity_capacity so it agrees with _body_rows' mode split exactly.
# Stacked: plain sum of (1 + lines + 1) over every fixed panel -- identical to
# the pre-s05 inline loop. Two-column: the first two panels (Sandbox, Run)
# contribute max(total_0, total_1) instead of their sum; every later fixed
# panel (e.g. Backpack) still contributes its own (1 + lines + 1).
sub _fixed_region_height {
    my ($state, $cols) = @_;
    my @h = map { 1 + scalar(@{ $_->{lines} || [] }) + 1 } _fixed_panels($state, $cols);
    if (_two_col_mode($cols) && @h >= 2) {
        my ($a, $b) = splice(@h, 0, 2);
        unshift @h, (($a > $b) ? $a : $b);
    }
    my $t = 0; $t += $_ for @h;
    return $t;
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
    $rows = 0 if !defined $rows || $rows < 0;
    my $alerts = scalar(_alert_msgs($state, $rows));
    my $body_h = $rows - 2 - $alerts;             # 2 = title + footer
    my $fixed  = _fixed_region_height($state, $cols);
    my $cap = $body_h - $fixed - 1;               # -1 = Activity panel title
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
sub run {
    my (%o) = @_;
    my $now        = $o{now}        || sub { time };
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
    my $prev;
    my %state;
    my $pending = '';
    my $hb_state = 'ok';        # last heartbeat result; 'gone' no longer exits the loop
    my @all_events;             # full chronological event list from the last gather
    my $activity_offset = 0;    # up/down scroll position in the Activity panel
    my $activity_max    = 0;    # scroll ceiling (set each frame by activity_window)
    my $flash_until = 0;        # footer-flash expiry (set when [c] hit a dead container)
    my $last_recover_at;        # now() when the last [l] recovery FINISHED (undef: none yet)
    my $rc = 0;
    my $ticks = 0;
    my $last_title;                                            # undef => nothing emitted yet
    my $spin_div = ($tick_int && $tick_int > 0) ? $tick_int : 0.2;   # never divide by zero

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

                # state refresh (slower cadence than input polling)
                if (!defined $last_state || $t - $last_state >= $state_int) {
                    ($cols, $rows) = $term_size->();
                    my $base = $gather->() || {};
                    %state = %$base;
                    @all_events = @{ $base->{events} || [] };   # chronological
                    $activity_offset = 0 if $activity_offset < 0;
                    $last_state = $t;
                    # B5: re-evaluate the wake-lock on the freshly gathered state
                    # (carries busy_age). The launcher's seam owns the decision.
                    $keepawake->(\%state);
                }
                $state{beat_age}       = $t - $last_beat;
                $state{uptime}         = $t - $start;
                $state{pending}        = $pending;
                $state{container_gone} = ($hb_state eq 'gone') ? 1 : 0;
                $state{spinner_idx}    = int($t / $spin_div);   # Decision #21: WALL CLOCK, not iteration count
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

                my $frame = compose_frame(\%state, $rows, $cols);
                $out->(render_frame($prev, $frame, { color => $color }));
                $prev = $frame;

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
                        $last_state      = undef;   # force a gather next tick
                        $prev            = undef;   # (D) force a FULL repaint: blank
                                                    # (\e[2J) then redraw every row fresh
                        $activity_offset = 0;       # back to the newest events
                        delete $state{lifecycle};   # clear the lifecycle banner (spec 08 S2.7)
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
                    if ($wk eq "\e") {
                        # Decision #22: the wait may have consumed only the ESC
                        # byte of an arrow/CSI sequence to detect readiness. The
                        # remaining bytes ('[' or 'O', then the final letter)
                        # are still sitting in the input source and must be
                        # pulled via the ordinary $read_key seam (NOT another
                        # $wait_input call -- they are already available, not
                        # awaited) and stitched into the same 'UP'/'DOWN' tokens
                        # dispatch_key expects, mirroring launcher.pl's own
                        # ESC-sequence assembly exactly. Applied ONLY here (the
                        # pushback-originated byte), never to keys $read_key
                        # returns directly -- launcher.pl's read_key already
                        # fully assembles those before Dashboard.pm ever sees
                        # them, so re-assembling here too would risk mis-eating
                        # an unrelated, later keystroke as if it were part of a
                        # CSI sequence.
                        my $k2 = $read_key->();
                        if (defined $k2 && ($k2 eq '[' || $k2 eq 'O')) {
                            my $k3 = $read_key->();
                            if (defined $k3) {
                                if    ($k3 eq 'A') { $wk = 'UP'; }
                                elsif ($k3 eq 'B') { $wk = 'DOWN'; }
                                else               { $wk = undef; }   # unrecognized CSI: drop, like launcher.pl
                            } else {
                                $wk = undef;   # incomplete sequence
                            }
                        } elsif (defined $k2) {
                            # ESC + a non-CSI byte (Alt+key): surface that byte
                            # rather than dropping it, mirroring launcher.pl.
                            $wk = $k2;
                        }
                        # else: lone ESC (no k2) -- $wk stays "\e", inert in dispatch_key.
                    }
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
