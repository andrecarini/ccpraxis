# tui::Frame -- row composition, sanitisation and the single SGR emitter for
# the shared TUI render library (blueprint unified-tui-design-system,
# package 05-render-library). See specs/05-render-library-spec.md S2.2.
#
# Depends on tui::Layout for width measurement only (Layout -> Frame in the
# module DAG). paint_row takes the terminal capability as an EXPLICIT
# argument -- nothing in this file reads the process environment, which is
# what keeps every function here pure.
package tui::Frame;
use strict;
use warnings;
use Encode ();
use Theme;
use tui::Layout;

use constant DEFAULT_ROLE => 'text.primary';
use constant PAD_ROLE     => 'text.primary';

# ---------------------------------------------------------------------------
# Byte/character decode -- same convention as tui::Layout's private copy
# (deliberately duplicated per spec S1.2: this package may not write to a
# shared internal module, and each tui/ file is self-contained). PRIVATE.
# ---------------------------------------------------------------------------
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
    $str = "$str" if ref($str);
    return $str if $str =~ /[^\x00-\xFF]/;
    my $bytes = $str;
    my $out   = '';
    while (length $bytes) {
        if ($bytes =~ /\A((?:$UTF8_CHAR_RE)+)/) {
            my $good     = $1;
            my $consumed = length $good;
            $out .= Encode::decode('UTF-8', $good, Encode::FB_QUIET());
            substr($bytes, 0, $consumed, '');
        } else {
            $out .= chr(0xFFFD);
            substr($bytes, 0, 1, '');
        }
    }
    return $out;
}

# The escape byte's ordinal is looked up via chr() (never written as a
# string-escape literal) so this file names no escape-literal form itself
# outside paint_row's own use of Theme's sgr/reset accessors.
sub _strip_sgr {
    my ($s) = @_;
    return '' if !defined $s;
    my $esc = chr(27);
    $s =~ s/\Q$esc\E\[[0-9;]*m//g;
    $s =~ s/\Q$esc\E//g;
    return $s;
}

# safe_char($c) -> the sanitised DECODED form of one character: itself if
# printable ASCII or a Theme-declared glyph; '' (deleted) if zero-width;
# else exactly one '?'. PUBLIC.
# _is_narrow_latin($cp) -- true for the non-ASCII Latin letters and marks that
# occupy exactly one column in every terminal: Latin-1 Supplement, Latin
# Extended-A and Latin Extended-B (U+00A0..U+024F). Soft hyphen is excluded:
# terminals disagree about whether it renders at all, so its width is not
# something this table can honestly claim.
#
# The range stops at U+024F on purpose. Greek and Cyrillic are also narrow,
# but the first genuinely ambiguous-width block is not far beyond, and
# char_cols() falls back to 1 for anything it does not know -- so widening
# this range is a promise about column arithmetic, not a display preference.
# Latin covers the paths this project actually runs on; extend it only with
# a width table to back it. PRIVATE.
sub _is_narrow_latin {
    my ($cp) = @_;
    return 0 if $cp < 0x00A0 || $cp > 0x024F;
    return 0 if $cp == 0x00AD;
    return 1;
}

# _is_safe_punct($cp) -> 1|0 -- typographic punctuation this codebase actually
# WRITES, every one of which tui::Layout::char_cols already measures as a
# single column.
#
# Same defect as _is_narrow_latin, one Unicode block further along, and found
# the same way: from a live launch. "Rebuild - fresh container with Claude Code
# v2.1.219" reached the operator's screen as "Rebuild ? fresh container",
# because the em dash fell off the end of the ladder into '?'. It is not one
# string -- there are 32 of these characters in non-comment code in
# launcher.pl, Dashboard.pm and BackpackReview.pm alone, so every one of those
# messages has been rendering with a '?' punched through it in every frame the
# library draws.
#
# An EXPLICIT LIST, not a block range: U+2000-U+206F also holds zero-width
# joiners, bidi overrides and word joiners, none of which may reach a terminal
# from here. The width re-check in safe_char is belt-and-braces on top -- it
# makes a future addition to this list unable to become a column-arithmetic
# bug even if someone adds a wide character by mistake.
my %SAFE_PUNCT = map { $_ => 1 } (
    0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015,   # hyphen .. horizontal bar
    0x2018, 0x2019, 0x201A, 0x201B,                   # single quotes
    0x201C, 0x201D, 0x201E, 0x201F,                   # double quotes
    0x2022, 0x2023,                                   # bullets
    0x2026,                                           # ellipsis
    0x2039, 0x203A,                                   # single guillemets
    0x2032, 0x2033,                                   # prime, double prime
);
sub _is_safe_punct {
    my ($cp) = @_;
    return $SAFE_PUNCT{$cp} ? 1 : 0;
}

sub safe_char {
    my ($c) = @_;
    return '' if !defined $c || $c eq '';
    my $cp = ord($c);
    return $c if $cp >= 0x20 && $cp <= 0x7E;
    return $c if defined tui::Layout::glyph_width($c);
    return '' if tui::Layout::char_cols($c) == 0;
    # An accented Latin letter is not an unknown character. Before this arm
    # existed the ladder fell through to '?', so this machine's own home
    # directory -- the one every project path on it starts with -- rendered
    # with a '?' in place of its accented letter, in every frame the render
    # library draws: the dashboard, the backpack screen, and every launcher
    # screen built on them. That is a direct breach of the project rule that
    # nothing may assume ASCII paths, and it had already reached the point of
    # being written into a package spec as an accepted limitation before
    # anyone checked whether the width was genuinely unknown.
    #
    # It was not. char_cols() already returns 1 for these, correctly. The '?'
    # was never protecting the column arithmetic here -- it was a whitelist
    # that simply had no entry for Latin text, while the layout maths was
    # right all along. Substituting a character whose width you already know
    # loses information and buys nothing.
    return $c if _is_narrow_latin($cp);
    # The width re-check is deliberate: it makes it impossible for an addition
    # to %SAFE_PUNCT to become a column-arithmetic bug.
    return $c if _is_safe_punct($cp) && tui::Layout::char_cols($c) == 1;
    return '?';
}

# safe($str) -> a UTF-8 BYTE string: printable ASCII and Theme-declared
# glyphs pass through unchanged; zero-width characters are deleted; a
# complete escape sequence is removed whole; everything else becomes exactly
# one '?' per source character. Never dies, never warns. safe(undef) is ''.
# PUBLIC.
sub safe {
    my ($str) = @_;
    return '' if !defined $str;
    my $s   = _strip_sgr(_decode_str($str));
    my $out = '';
    $out .= safe_char($_) for split //, $s;
    return Encode::encode('UTF-8', $out);
}

# _span_hash($sp, $default_role) -- coerces whatever was actually handed in
# into a span hashref, total over any input. PRIVATE.
sub _span_hash {
    my ($sp, $default_role) = @_;
    $default_role = DEFAULT_ROLE() if !defined $default_role;
    return $sp if ref($sp) eq 'HASH';
    return { text => $sp, role => $default_role } if defined($sp) && !ref($sp);
    return { text => '', role => $default_role };
}

# spanify($line, $default_role) -> \@spans, canonicalising any accepted line
# form (plain string, {text,role}, [ span, ... ], {role,spans}, or undef)
# into a non-empty arrayref of spans with sanitised text and a defined role.
# Never dies. PUBLIC.
sub spanify {
    my ($line, $default_role) = @_;
    $default_role = DEFAULT_ROLE() if !defined $default_role;

    my $canon = sub {
        my ($sp, $role) = @_;
        if (ref $sp eq 'HASH') {
            my %out = ( text => safe($sp->{text}),
                        role => (defined $sp->{role} ? $sp->{role} : $role) );
            # Preserve the atomic marker (see fit_spans) across
            # canonicalisation -- tui::Meter relies on a bar/percent span
            # surviving spanify() with its atomicity intact.
            $out{atomic} = 1 if $sp->{atomic};
            return \%out;
        }
        return { text => safe($sp), role => $role };
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
        return [ { text => safe($line->{text}),
                   role => (defined $line->{role} ? $line->{role} : $default_role) } ];
    }
    return [ { text => safe($line), role => $default_role } ];
}

# spans_width(\@spans) -> sum of display_width across spans. PUBLIC.
sub spans_width {
    my ($spans) = @_;
    return 0 if ref($spans) ne 'ARRAY' || !@$spans;
    my $w = 0;
    $w += tui::Layout::display_width(_span_hash($_)->{text}) for @$spans;
    return $w;
}

# spans_text(\@spans) -> plain ordered concatenation of span texts. PUBLIC.
sub spans_text {
    my ($spans) = @_;
    return '' if ref($spans) ne 'ARRAY' || !@$spans;
    return join('', map { defined _span_hash($_)->{text} ? _span_hash($_)->{text} : '' } @$spans);
}

# fit_spans(\@spans, $w, $pad_role) -> a NEW span list whose total display
# width is EXACTLY $w. Truncates at a glyph boundary (a wide glyph is
# dropped whole rather than half-emitted), pads with spaces carrying
# $pad_role. $w undef/negative/non-numeric -> treated as 0.
#
# ATOMIC SPANS (round-2 fix, H1 regression): a span carrying `atomic => 1`
# (tui::Meter marks a gauge bar and a percent figure this way) is never
# half-emitted the way an ordinary span's trailing glyphs are -- it is
# rendered whole if it fits in the remaining width, or dropped whole
# (contributing nothing, truncation stops there) otherwise. A partially
# rendered gauge bar or percent digit is not a truncated value, it is a
# DIFFERENT, wrong one (2 of 10 bar cells reads as 20%, not "80%, cut
# off") -- worse than omitting it. PUBLIC.
sub fit_spans {
    my ($spans, $w, $pad_role) = @_;
    $spans = [] if ref($spans) ne 'ARRAY';
    $w = 0 if !defined $w || ref($w) || $w !~ /^-?\d+(?:\.\d+)?$/;
    $w = int($w);
    return [ { text => '', role => PAD_ROLE() } ] if $w <= 0;

    if (!defined $pad_role) {
        $pad_role = @$spans ? _span_hash($spans->[-1])->{role} : PAD_ROLE();
        $pad_role = PAD_ROLE() if !defined $pad_role;
    }

    my @out;
    my $width     = 0;
    my $truncated = 0;
    for my $raw_sp (@$spans) {
        last if $truncated;
        my $sp       = _span_hash($raw_sp);
        my $raw_text = defined $sp->{text} ? $sp->{text} : '';
        my $role     = defined $sp->{role} ? $sp->{role} : DEFAULT_ROLE();
        my $atomic   = (ref($sp) eq 'HASH' && $sp->{atomic}) ? 1 : 0;
        my $decoded  = _strip_sgr(_decode_str($raw_text));
        my @chars    = split //, $decoded;
        my $tw       = 0;
        $tw += tui::Layout::char_cols($_) for @chars;

        if ($width + $tw <= $w) {
            my $safe_text = join('', map { safe_char($_) } @chars);
            push @out, { text => Encode::encode('UTF-8', $safe_text), role => $role }
                if length $safe_text;
            $width += $tw;
            next;
        }

        if ($atomic) {
            # Never partially emit an atomic span -- either every glyph or
            # none. Stop here; any remaining width is padded below.
            $truncated = 1;
            next;
        }

        my $remaining = $w - $width;
        my $cut       = '';
        my $cut_w     = 0;
        for my $c (@chars) {
            my $cw = tui::Layout::char_cols($c);
            last if $cut_w + $cw > $remaining;
            $cut .= safe_char($c);
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

# make_cell($line, $role, $w) -> \%cell, the single constructor for a
# composed row: { text, role, spans }. PUBLIC.
sub make_cell {
    my ($line, $role, $w) = @_;
    $role = DEFAULT_ROLE() if !defined $role;
    my $spans = fit_spans(spanify($line, $role), $w, $role);
    return { text => spans_text($spans), role => $role, spans => $spans };
}

# wrap_line($line, $role, $w, $continuation_indent) -> \@cells, a NON-EMPTY
# arrayref of cells (each shaped exactly like make_cell's return), each
# exactly $w display columns wide. See specs/t02-wrap-on-overflow-spec.md
# S2.1. Never dies, never warns.
#
# Priority order, per spec: (1) an atomic span (Meter gauge bar / percent
# figure) fully excludes the row from wrapping -- delegate to today's
# truncate-or-drop-whole make_cell, unchanged (S2.3: Layout::wrap cannot
# carry the atomic marker through a rebuild, so a partially-cut gauge is a
# real risk, not a hypothetical one). (2) a row that already fits its column
# budget returns byte-identical output to today (the common case). (3)
# otherwise, word-wrap: flatten to words, pre-split any word wider than the
# continuation-aware content width at a decoded-character boundary (mirrors
# beacon's own workaround, claude-beacon.pl:551-554, reimplemented here
# because that copy is outside this file), hand the word list to the
# EXISTING, UNMODIFIED tui::Layout::wrap, then re-pad each returned line via
# make_cell/fit_spans -- which is what guarantees "exactly $w columns, never
# mid-glyph" for every wrapped line using already-tested code. PUBLIC.
sub wrap_line {
    my ($line, $role, $w, $continuation_indent) = @_;
    $role = DEFAULT_ROLE() if !defined $role;
    $continuation_indent = 0
        if !defined $continuation_indent || ref($continuation_indent)
        || $continuation_indent !~ /^-?\d+(?:\.\d+)?$/;
    $continuation_indent = int($continuation_indent);
    $continuation_indent = 0 if $continuation_indent < 0;

    my $spans = spanify($line, $role);

    # (1) Atomic carve-out -- never wrap a row carrying a gauge bar/percent
    # figure span; delegate whole to today's truncate-or-drop-whole path.
    for my $sp (@$spans) {
        return [ make_cell($line, $role, $w) ] if ref($sp) eq 'HASH' && $sp->{atomic};
    }

    # (2) Fast path -- no overflow, byte-identical to today.
    return [ make_cell($line, $role, $w) ] if spans_width($spans) <= (defined $w ? $w : 0);

    my $w_num = (!defined $w || ref($w) || $w !~ /^-?\d+(?:\.\d+)?$/) ? 0 : int($w);

    # (3a-pre) Capture the row's own LEADING indent before it is lost.
    # Step (3a) below splits every span's text on runs of spaces and drops
    # empty tokens -- a pure-whitespace span (the 2-column body indent
    # Screen.pm bakes into every row, e.g. { text => '  ', ... }) produces
    # ZERO words and silently vanishes. Both the first line AND every
    # continuation line need it restored: the first line so it keeps the
    # SAME leading gutter as an unwrapped sibling row (step-8 UI-pass
    # Finding 2 -- it was rendering flush against the panel border), and
    # continuation lines so their own added indent (WRAP_CONTINUATION_INDENT,
    # Screen.pm) reads as genuinely MORE indented than line 0, not merely
    # equal to it (existing 2 + new 2 = 4, per spec S2.4). Recover it by
    # walking the spans from the front and collecting any purely-whitespace
    # run before the first span carrying real content.
    my $leading_indent_text = '';
    my $leading_indent_role;
    for my $sp (@$spans) {
        my $t = defined $sp->{text} ? $sp->{text} : '';
        last if $t !~ /^ *$/;
        next if $t eq '';
        $leading_indent_text .= $t;
        $leading_indent_role = $sp->{role} if !defined $leading_indent_role;
    }
    $leading_indent_role = DEFAULT_ROLE() if !defined $leading_indent_role;
    my $leading_indent_w = tui::Layout::display_width($leading_indent_text);

    # Content budget: reserve room for the leading indent (paid by every
    # line, first included) PLUS the continuation indent (paid only by
    # continuation lines) so that once both indents are re-added below, no
    # line's total width (indent + words) can exceed $w_num. Uniform across
    # every line of a wrapping row, per S2.1d -- line 0 simply doesn't spend
    # the continuation-indent share of that reservation, which make_cell's
    # own right-pad silently absorbs.
    my $content_w = $w_num - $continuation_indent - $leading_indent_w;
    # Degenerate case (S2.1d/behavior 6): continuation indent (+ leading
    # indent) >= column width. Falling back to a full-width content budget
    # without ALSO dropping the indents used to build the lines below would
    # still burn the whole budget on leading spaces, leaving zero columns
    # for the words those lines exist to carry -- an implementer's own
    # regression, not one the spec asked for. $effective_indent tracks the
    # continuation-only delta actually applied on top of the leading indent;
    # $effective_leading tracks the leading indent itself.
    my $effective_indent  = $continuation_indent;
    my $effective_leading = $leading_indent_w;
    if ($content_w < 1) {
        $content_w         = $w_num;
        $effective_indent  = 0;
        $effective_leading = 0;
    }

    # (3a) Flatten spans into a word list, splitting on runs of a single
    # ASCII space -- safe on UTF-8 BYTE text because a continuation byte is
    # always >= 0x80, so 0x20 never appears mid-sequence.
    #
    # A span boundary is not necessarily a word boundary: callers routinely
    # glue two spans directly together with no space (e.g. "...approved"
    # then ", 3 pending" -- the comma belongs immediately after "approved",
    # no separator). Splitting each span's text INDEPENDENTLY and rejoining
    # every resulting token with a space (as tui::Layout::wrap always does
    # between distinct words) invents a space the source never had. Track
    # whether the previous span's text ended in a space and this span's
    # text starts with one; if NEITHER does, this span's first token is not
    # a new word -- it is the tail of the previous span's last word, and is
    # appended to it in place rather than pushed as its own entry. The
    # merged word keeps the role of its earlier (first) fragment; losing a
    # color boundary on the one glued token is the accepted tradeoff for
    # byte-exact text, which is what content fidelity requires here.
    my @words;
    my $prev_span_text;
    for my $sp (@$spans) {
        my $text     = defined $sp->{text} ? $sp->{text} : '';
        my $sp_role  = defined $sp->{role} ? $sp->{role} : $role;
        next if $text eq '';
        my $glued_to_prev = defined($prev_span_text)
            && $prev_span_text !~ / $/
            && $text !~ /^ /;
        $prev_span_text = $text;
        my $first_tok = 1;
        for my $tok (split / +/, $text) {
            if ($tok eq '') { $first_tok = 0; next; }
            if ($first_tok && $glued_to_prev && @words) {
                $words[-1]{text} .= $tok;
            } else {
                push @words, { text => $tok, role => $sp_role };
            }
            $first_tok = 0;
        }
    }

    # (3a-merge) 9897: glue a single-character hotkey-hint word (this
    # codebase's own convention -- '[d]', '[r]', '[s]', etc., confirmed by
    # grep across DashboardScreen.pm) to the SINGLE word immediately
    # following it, so tui::Layout::wrap's existing "each word is atomic"
    # guarantee (Layout.pm) can never split them across a wrap boundary.
    # Left-to-right, non-overlapping: a combined word is not re-matched (no
    # chained gluing). Multi-character bracket tokens ('[running]') do not
    # match and are left untouched -- deliberate scope discipline, not an
    # oversight. Strictly downstream of the fast-path return above, so it
    # never runs on a row that already fits.
    my @merged;
    for (my $i = 0; $i <= $#words; $i++) {
        if ($words[$i]{text} =~ /^\[[^\[\]\s]\]$/ && $i < $#words) {
            push @merged, { text => $words[$i]{text} . ' ' . $words[$i + 1]{text}, role => $words[$i]{role} };
            $i++;   # consume the following word too; do not re-match the combined word
        } else {
            push @merged, $words[$i];
        }
    }
    @words = @merged;

    # (3b) Overlong-word pre-split at decoded-character boundaries.
    my @pre_split;
    for my $word (@words) {
        my $text = $word->{text};
        if (tui::Layout::display_width($text) > $content_w) {
            my $decoded = _strip_sgr(_decode_str($text));
            my @chars   = split //, $decoded;
            my @chunks;
            my $cur   = '';
            my $cur_w = 0;
            for my $c (@chars) {
                my $cw = tui::Layout::char_cols($c);
                if ($cur_w > 0 && $cur_w + $cw > $content_w) {
                    push @chunks, $cur;
                    $cur   = $c;
                    $cur_w = $cw;
                } else {
                    $cur .= $c;
                    $cur_w += $cw;
                }
            }
            push @chunks, $cur if length $cur;
            for my $chunk (@chunks) {
                push @pre_split, { text => Encode::encode('UTF-8', $chunk), role => $word->{role} };
            }
        } else {
            push @pre_split, $word;
        }
    }

    # (3c/3e) Delegate to the existing, unmodified tui::Layout::wrap.
    my $sep_role   = $role;
    my $out_lines  = tui::Layout::wrap(\@pre_split, $content_w, $sep_role);

    # (3f) All-empty-words fallback -- never return zero cells.
    return [ make_cell($line, $role, $w) ] if !@$out_lines;

    # (3g) Re-pad each line via make_cell/fit_spans; continuation lines get
    # a fixed-width leading indent span ($effective_indent, not the raw
    # $continuation_indent -- see the degenerate-case note above).
    my @cells;
    for my $i (0 .. $#$out_lines) {
        my $line_words = $out_lines->[$i];
        my $line_spans;
        if ($i == 0) {
            # Restore the row's own leading indent captured in (3a-pre) --
            # this is what gives line 0 the SAME leading gutter as an
            # unwrapped sibling row (step-8 UI-pass Finding 2). Same
            # overflow guard as the continuation-line indent below: only
            # pay for it if it still fits within $w_num, so a pathological
            # row can never be pushed past its column budget by an indent
            # it cannot afford.
            if ($effective_leading > 0
                    && $effective_leading + spans_width($line_words) <= $w_num) {
                $line_spans = [ { text => $leading_indent_text, role => $leading_indent_role }, @$line_words ];
            } else {
                $line_spans = $line_words;
            }
        } else {
            # Per-LINE indent guard (redteam step-6 Finding 1): a
            # forced-progress chunk (below) is, by definition, already wider
            # than $content_w = $w_num - $continuation_indent. Prepending the
            # row's indent unconditionally therefore ALWAYS pushed
            # indent + chunk_width past $w_num for every such line -- not
            # only in the whole-row degenerate case ($effective_indent
            # already handles that one, above). Mirror that same fallback
            # per line: only pay the indent on a continuation line if doing
            # so still fits within $w_num; otherwise drop it for this line
            # alone so the emitted width is never inflated by an indent the
            # line cannot afford. This still satisfies AC3's "continuation
            # lines get the fixed indent" for the overwhelming common case
            # (indent + content fits) -- it only backs off when the row's
            # own forced-progress content already needs the room.
            # Continuation lines pay BOTH indents: the restored leading
            # indent (same as line 0) plus the additional continuation
            # delta -- existing 2 + new 2 = 4, per spec S2.4 -- so a
            # continuation line reads as genuinely more indented than line
            # 0, not merely equal to it.
            my $total_indent_w = $effective_leading + $effective_indent;
            if ($total_indent_w > 0
                    && $total_indent_w + spans_width($line_words) > $w_num) {
                $total_indent_w = 0;
            }
            if ($total_indent_w > 0) {
                my @indent_spans;
                push @indent_spans, { text => $leading_indent_text, role => $leading_indent_role }
                    if $effective_leading > 0;
                push @indent_spans, { text => (' ' x $effective_indent), role => DEFAULT_ROLE() }
                    if $effective_indent > 0;
                $line_spans = [ @indent_spans, @$line_words ];
            } else {
                $line_spans = $line_words;
            }
        }
        # Forced-progress exception (DC5, behavior 4's degenerate case): a
        # single decoded character wider than the WHOLE content budget was
        # still emitted alone by the (3b) pre-split loop rather than being
        # silently skipped -- but re-padding it through fit_spans/make_cell
        # here would immediately undo that: fit_spans DROPS a glyph that
        # cannot fit in the remaining width rather than half-emitting it
        # (Frame.pm's own atomic-truncation contract, by design, for the
        # normal case). For this one line shape -- content itself wider
        # than $w, and (per the per-line indent guard above) already
        # indent-free when an indent would have made it worse -- that same
        # drop-on-overflow behavior would erase the only content the line
        # carries, achieving the opposite of "the character still gets
        # emitted, never dropped" (spec behavior 4). Bypass fit_spans's
        # width clamp for this line ONLY; every other line (the
        # overwhelming common case) still goes through make_cell/fit_spans
        # unchanged, so "exactly $w columns" still holds for every line
        # that can actually fit it. $line_spans is already a well-formed
        # span array (its words came from spanify()'d, already-safe()d
        # text via the pre-split/wrap pipeline above), so building the cell
        # directly here -- rather than re-running spanify()/safe() a second
        # time -- is not a behavior change, only the removal of a
        # provably-idempotent redundant pass (reviewer step-6 NIT 1).
        if (spans_width($line_spans) > $w_num) {
            push @cells, { text => spans_text($line_spans), role => $role, spans => $line_spans };
        } else {
            push @cells, make_cell($line_spans, $role, $w);
        }
    }
    return \@cells;
}

# bound_for_wrap($text, $max_rows, $w) -> $string, a decoded-character,
# display-width-safe PREFIX of $text -- 59a4. Callers (tui::Screen::compose's
# banner loop) call this immediately before wrap_line so wrap_line never pays
# O(full message length) to wrap a message whose eventual row budget is much
# smaller: input beyond what could ever survive $max_rows rows of $w columns
# each is cut before wrap_line ever sees it. Generous, NEVER under-cuts (the
# cut result's display width is always >= $max_rows*$w when the input needed
# cutting at all) -- see spec S"Interfaces & contracts" #4. Byte-identical
# pass-through, no decode round-trip, for input already within budget (the
# common case: no live caller today sends a banner long enough to need
# cutting). PURE, PUBLIC.
#
# STRICTLY greater than $limit when cutting, not merely >=: wrap_line's own
# fast path (spans_width($spans) <= $w) is a SEPARATE code path from its
# word-wrap slow path (which reserves room for the continuation indent even
# on line 0 -- Frame.pm's own $content_w reservation), and the two produce
# DIFFERENT line-0 text for the same words when $max_rows==1 (so
# $limit==$w exactly). Cutting to EXACTLY $limit can therefore land the
# bounded text exactly at $w columns, spuriously taking wrap_line's fast
# path where the full/unbounded text -- too long to ever take that fast
# path -- would have taken the slow path and broken the line differently.
# Overshooting by one more retained character (when one exists) keeps the
# bounded text's own spans_width > $w whenever $max_rows==1, so wrap_line
# takes the SAME code path it would for the full text; found via
# t/88-banner-wrap-every-surface.t's pre-existing AC-4d ($max_banner_rows==1),
# a foreign package's regression guard this fix must not break.
sub bound_for_wrap {
    my ($text, $max_rows, $w) = @_;
    return '' if !defined $text || $text eq '';
    $max_rows = (!defined $max_rows || ref($max_rows) || $max_rows !~ /^-?\d+(?:\.\d+)?$/) ? 0 : int($max_rows);
    $w        = (!defined $w        || ref($w)        || $w        !~ /^-?\d+(?:\.\d+)?$/) ? 0 : int($w);
    return '' if $max_rows <= 0 || $w <= 0;

    my $limit = $max_rows * $w;

    # Fast path (the case this fix exists for): decode only a generous
    # RAW-BYTE prefix first -- up to 4 bytes per UTF-8 character (the widest
    # this encoding uses), doubled for margin. If that prefix alone already
    # exceeds $limit, the cut point is inside it and the REST of a huge
    # $text (a multi-million-character single token, the pathological case
    # from the filed report) is never even substr'd, let alone decoded --
    # this is what keeps behavior 11 well under 1s. Only an input whose
    # prefix does NOT strictly exceed $limit (heavy zero-width/combining
    # runs, or $text simply fits in the prefix, or the boundary lands
    # exactly on $limit -- see the overshoot note above) falls through to
    # the slow, exact path below, which is unavoidable there but rare.
    my $prefix_bytes = $limit * 4 + 64;
    if (length($text) > $prefix_bytes) {
        my $decoded_prefix = _strip_sgr(_decode_str(substr($text, 0, $prefix_bytes)));
        my $acc = 0;
        my $out = '';
        for my $c (split //, $decoded_prefix) {
            last if $acc > $limit;
            $out .= $c;
            $acc += tui::Layout::char_cols($c);
        }
        return Encode::encode('UTF-8', $out) if $acc > $limit;
        # else: prefix wasn't enough (or landed exactly on $limit) -- fall
        # through to the exact/slow path.
    }

    return $text if tui::Layout::display_width($text) <= $limit;

    my $decoded = _strip_sgr(_decode_str($text));
    my $acc     = 0;
    my $out     = '';
    for my $c (split //, $decoded) {
        last if $acc > $limit;
        $out .= $c;
        $acc += tui::Layout::char_cols($c);
    }
    return Encode::encode('UTF-8', $out);
}

# clip_pad($str, $w) -> exactly $w display columns. PUBLIC.
sub clip_pad {
    my ($s, $w) = @_;
    return spans_text(fit_spans([ { text => $s, role => PAD_ROLE() } ], $w, PAD_ROLE()));
}

# cell_sig(\%cell) -> a string that changes whenever the row's appearance
# changes: the cell text joined with the ordered role/width sequence of its
# spans. Used only by tui::Screen::diff. PUBLIC.
sub cell_sig {
    my ($cell) = @_;
    return '' if ref($cell) ne 'HASH';
    my $text  = defined $cell->{text} ? $cell->{text} : '';
    my $spans = ref($cell->{spans}) eq 'ARRAY' ? $cell->{spans} : [];
    my @parts;
    for my $sp (@$spans) {
        my $h     = _span_hash($sp);
        my $role  = defined $h->{role} ? $h->{role} : '';
        my $width = tui::Layout::display_width(defined $h->{text} ? $h->{text} : '');
        push @parts, "$role:$width";
    }
    return $text . '|' . join(',', @parts);
}

# panel_title_line($title, $w) -> \@spans, exactly $w wide: '-- ' . safe($title)
# . ' ' followed by rule.h glyphs to $w. The lead-in text carries text.primary;
# the filler carries rule. PUBLIC.
sub panel_title_line {
    my ($title, $w) = @_;
    my $lead  = '-- ' . safe($title) . ' ';
    my @spans = ( { text => $lead, role => DEFAULT_ROLE() } );
    my $lead_w = tui::Layout::display_width($lead);
    my $target_w = (!defined $w || ref($w) || $w !~ /^-?\d+(?:\.\d+)?$/) ? 0 : int($w);
    if ($target_w > $lead_w) {
        my $fill = Theme::glyph('rule.h');
        $fill = '' if !defined $fill;
        push @spans, { text => ($fill x ($target_w - $lead_w)), role => 'rule' };
    }
    return fit_spans(\@spans, $w, 'rule');
}

# rule($w) -> \@spans, $w repetitions of Theme's rule.h glyph, role rule.
# $w < 1 -> []. PUBLIC.
sub rule {
    my ($w) = @_;
    return [] if !defined $w || ref($w) || $w !~ /^-?\d+(?:\.\d+)?$/ || int($w) < 1;
    $w = int($w);
    my $glyph = Theme::glyph('rule.h');
    $glyph = '' if !defined $glyph;
    return [ { text => ($glyph x $w), role => 'rule' } ];
}

# paint_row(\%cell, $cap) -> the ONLY function in this library that emits an
# escape sequence, obtaining every one from Theme's sgr/reset accessors. $cap
# is the terminal capability, passed EXPLICITLY so this stays pure -- undef
# lets Theme's sgr accessor fall back to its own capability lookup
# internally, inside Theme, never inside this file.
#
# ROUND-2 FIX (item 7, escape-leak regression): every span's text is run
# through safe() before being wrapped in Theme's sgr/reset. make_cell's own
# path (spanify -> safe -> fit_spans) already sanitises, so this is a no-op
# for cells built the sanctioned way -- but tui::Layout::wrap returns
# UNSANITISED spans (by design; it is the bottom of the DAG and cannot call
# into this file), and paint_row is the one place in the whole library
# where a span's text is about to become terminal bytes. A caller who
# paints a wrap() result directly (a natural thing to write -- wrapping
# subprocess stderr this library does not control) must not be able to
# leak a raw escape sequence through this public-but-not-sanctioned path.
# Sanitising here, at the emitter, closes it regardless of which path the
# span arrived by. PUBLIC.
sub paint_row {
    my ($cell, $cap) = @_;
    return '' if ref($cell) ne 'HASH';
    my $spans = ref($cell->{spans}) eq 'ARRAY' ? $cell->{spans} : [];
    my $out = '';
    for my $sp (@$spans) {
        my $h    = _span_hash($sp);
        my $role = defined $h->{role} ? $h->{role} : '';
        my $text = defined $h->{text} ? $h->{text} : '';
        $out .= Theme::sgr($role, $cap) . safe($text) . Theme::reset();
    }
    return $out;
}

# ---------------------------------------------------------------------------
# is_known_role -- write-once memoized role-name set. Never call Theme's
# roles accessor per span; it defensive-copies. PRIVATE state, PUBLIC accessor.
# ---------------------------------------------------------------------------
my $ROLE_SET;

sub _role_set {
    return $ROLE_SET if $ROLE_SET;
    my $roles = Theme::roles();
    my %set = map { $_ => 1 } keys %$roles;
    $ROLE_SET = \%set;
    return $ROLE_SET;
}

sub is_known_role {
    my ($role) = @_;
    return 0 if !defined $role || ref($role);
    return _role_set()->{$role} ? 1 : 0;
}

1;
