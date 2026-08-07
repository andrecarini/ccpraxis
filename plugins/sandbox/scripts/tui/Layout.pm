# tui::Layout -- measurement, wrapping, and arrangement for the shared TUI
# render library (blueprint unified-tui-design-system, package
# 05-render-library). See specs/05-render-library-spec.md S2.3.
#
# THE BOTTOM OF THE tui/ DAG. This file consumes only core Perl and Theme --
# never another tui::* module, never Dashboard. That is what lets package 06
# later repoint Theme's lazy width delegation at this file with a one-line
# change and close the dependency cycle for good (spec S1.3).
#
# WIDTH OWNERSHIP: this file DEFINES display_width/glyph_width/char_cols and
# the glyph-width table they consult, rather than re-exporting Theme's own
# width call (Theme has none -- Theme's own width entry point is itself a
# lazy delegation into the pre-existing dashboard width implementation). The
# table below is sourced from Theme's glyphs accessor -- glyph IDENTITY and
# declared WIDTH remain Theme's; MEASUREMENT is this module's.
package tui::Layout;
use strict;
use warnings;
use Encode ();
use Theme;

# BREAKPOINT_TWO_COL -- the single declaration of the responsive breakpoint
# for the whole library. Nothing else in tui/ may name this number.
use constant BREAKPOINT_TWO_COL => 90;

# ---------------------------------------------------------------------------
# Byte/character decode -- the same convention the pre-existing dashboard
# core uses: a string is treated as already-decoded characters iff it
# contains at least one codepoint above the byte range; otherwise it is
# decoded as UTF-8, leniently (malformed bytes become the standard
# replacement character; this never fails or emits a diagnostic). PRIVATE.
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

# Strips a complete CSI-SGR sequence whole, plus any dangling escape byte.
# The escape byte's ordinal is looked up via chr() (never written as a
# string-escape literal) so this file names no escape-literal form itself --
# tui::Frame::paint_row remains the library's only source of an actual
# emitted escape sequence. PRIVATE.
sub _strip_sgr {
    my ($s) = @_;
    return '' if !defined $s;
    my $esc = chr(27);
    $s =~ s/\Q$esc\E\[[0-9;]*m//g;
    $s =~ s/\Q$esc\E//g;
    return $s;
}

# ---------------------------------------------------------------------------
# The glyph-width table -- built lazily, ONCE, memoized. Sourced from
# Theme's glyphs accessor (each record already carries a declared width);
# never rebuilt. Load-bearing for performance: char_cols runs once per character
# measured, and re-deriving this table per character would be the exact
# regression the pre-existing dashboard core's own perf note records and
# fixed one layer down. This is the only mutable package state in this file.
# ---------------------------------------------------------------------------
my $WIDTH_TABLE;

sub _width_table {
    return $WIDTH_TABLE if $WIDTH_TABLE;
    my %table;
    my $glyphs = Theme::glyphs();
    for my $name (keys %$glyphs) {
        my $rec = $glyphs->{$name};
        next unless ref($rec) eq 'HASH' && defined $rec->{char};
        $table{ $rec->{char} } = $rec->{width};
    }
    $WIDTH_TABLE = \%table;
    return $WIDTH_TABLE;
}

# char_cols($c) -- the display width of one DECODED character: 0 for a C0
# control / DEL, a handful of zero-width formatting codepoints, and any
# combining mark; the Theme-declared width if the character is in the
# glyph-width table; else 1. PUBLIC.
sub char_cols {
    my ($c) = @_;
    return 0 if !defined $c || $c eq '';
    my $cp = ord($c);
    return 0 if $cp < 0x20 || $cp == 0x7F;
    return 0 if $cp == 0x200B || $cp == 0x200D || $cp == 0xFE0F;
    return 0 if $c =~ /\p{Mn}|\p{Me}/;
    my $t = _width_table();
    return $t->{$c} if exists $t->{$c};
    return 1;
}

# glyph_width($c) -- accepts a decoded character OR its UTF-8 byte encoding.
# Returns the declared width if the character is in the glyph-width table,
# else undef. Distinct from Theme::glyph_width, which takes a glyph NAME.
#
# ROUND-2 FIX (item 5, H4 regression): this used to run $c through
# _decode_str() unconditionally. _decode_str's "already decoded" heuristic
# is ORDINAL-based (does the string contain a codepoint above 0xFF?), which
# is the wrong test for a single already-decoded character whose codepoint
# happens to be <= 0xFF (e.g. U+00B7 sep.dot, U+00D7 status.crit): such a
# character is indistinguishable, by ordinal alone, from a single raw byte
# that is the (invalid, context-free) first half of nothing. The heuristic
# picked the wrong branch, tried to UTF-8-decode a lone byte, and produced
# U+FFFD -- so every glyph in that range fell through safe_char's ladder to
# '?'. LENGTH is the right discriminator here, not ordinal: a Perl string
# that is already exactly one character has length 1 regardless of its
# codepoint or internal representation, while this function's OTHER
# accepted form -- the character's raw UTF-8 byte encoding -- is more than
# one byte for every codepoint this table actually holds (all of them are
# above U+007F). So a length-1 argument is used as-is; only a longer one is
# run through the byte decoder. PUBLIC.
sub glyph_width {
    my ($c) = @_;
    return undef if !defined $c || $c eq '';
    my $decoded = (length($c) == 1) ? $c : _decode_str($c);
    return undef if length($decoded) != 1;
    my $t = _width_table();
    return exists $t->{$decoded} ? $t->{$decoded} : undef;
}

# display_width($str) -- 0 for undef/empty; decode, strip a complete escape
# sequence, sum char_cols over what remains. Never dies, never warns. PUBLIC.
sub display_width {
    my ($str) = @_;
    return 0 if !defined $str || $str eq '';
    my $s = _strip_sgr(_decode_str($str));
    my $w = 0;
    $w += char_cols($_) for split //, $s;
    return $w;
}

# _word_hash($w) -- coerces a wrap() input element into a { text, role }
# hashref: a hashref passes through, a defined non-ref scalar becomes plain
# text at the default role, anything else (undef, an arrayref, a coderef, a
# blessed ref) becomes an empty word rather than dying. PRIVATE.
sub _word_hash {
    my ($w) = @_;
    return $w if ref($w) eq 'HASH';
    return { text => $w, role => 'text.primary' } if defined($w) && !ref($w);
    return { text => '', role => 'text.primary' };
}

# wrap(\@words, $w, $sep_role) -> \@lines_of_spans -- greedy word wrap by
# DISPLAY width. Each word is atomic (never split); a word wider than $w
# occupies its own line intact. Lines are NOT padded. $w < 1, a non-arrayref,
# or an empty list -> []. A malformed element contributes an empty word
# rather than dying. PUBLIC.
sub wrap {
    my ($words, $w, $sep_role) = @_;
    $sep_role = 'text.primary' if !defined $sep_role;
    return [] if !defined $w || ref($w) || $w !~ /^-?\d+(?:\.\d+)?$/ || int($w) < 1;
    $w = int($w);
    return [] if ref($words) ne 'ARRAY' || !@$words;

    my @lines;
    my @cur;
    my $cur_w = 0;
    for my $raw (@$words) {
        my $sp   = _word_hash($raw);
        my $text = defined $sp->{text} ? $sp->{text} : '';
        my $role = defined $sp->{role} ? $sp->{role} : 'text.primary';
        my $ww   = display_width($text);
        if (!@cur) {
            @cur   = ( { text => $text, role => $role } );
            $cur_w = $ww;
        } elsif ($cur_w + 1 + $ww <= $w) {
            push @cur, { text => ' ', role => $sep_role }, { text => $text, role => $role };
            $cur_w += 1 + $ww;
        } else {
            push @lines, [ @cur ];
            @cur   = ( { text => $text, role => $role } );
            $cur_w = $ww;
        }
    }
    push @lines, [ @cur ] if @cur;
    return \@lines;
}

# arrangement($cols) -> 'two-column' | 'single-column'. Decision 14: the
# decision depends on $cols ONLY. undef/non-numeric/zero/negative all yield
# 'single-column'. PUBLIC.
sub arrangement {
    my ($cols) = @_;
    return 'single-column'
        if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/;
    return (int($cols) >= BREAKPOINT_TWO_COL()) ? 'two-column' : 'single-column';
}

# divide($cols, $n) -> \@bands -- $n bands covering [0, $cols) with no
# gutter: each band width is int($cols / $n), the LAST band absorbs the
# remainder, offsets are cumulative. $n < 1 or $cols < 1 -> []. PUBLIC.
sub divide {
    my ($cols, $n) = @_;
    return []
        if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/
        || !defined $n    || ref($n)    || $n    !~ /^-?\d+(?:\.\d+)?$/;
    $cols = int($cols);
    $n    = int($n);
    return [] if $n < 1 || $cols < 1;

    my @bands;
    my $base = int($cols / $n);
    my $x    = 0;
    for my $i (0 .. $n - 1) {
        my $w = ($i == $n - 1) ? ($cols - $x) : $base;
        push @bands, { x => $x, w => $w };
        $x += $w;
    }
    return \@bands;
}

# columns($cols) -> divide($cols,1) below the responsive breakpoint (single-
# column, unchanged -- AC-S5(06)'s narrow case pins exactly one band there,
# so panels never share a row below BREAKPOINT_TWO_COL). At or above the
# breakpoint, the ORIGINAL spec text fixed this at divide($cols,2) always;
# that is what left AC-L6 (criterion 3's "the right third is not left
# empty") unreachable at wide widths -- a 200-column terminal still only
# ever got two bands, so the right band started at column 100 and ordinary
# panel content could not reliably reach column 134 from there, regardless
# of how much horizontal room existed past two panels' worth. Decision 14's
# whole point is a terminal that STRETCHES to use its width, so at or above
# the breakpoint the number of bands now grows with the available width
# instead of staying pinned at two: one band per full multiple of HALF the
# breakpoint's own width, floored at two. Derived from BREAKPOINT_TWO_COL()
# itself (never a fresh literal), so the two-column case right at the
# breakpoint is unchanged (the breakpoint divided by half of itself is
# always exactly two, matching the original behavior at the boundary) and
# wider terminals gain additional bands as they earn them. PUBLIC.
sub columns {
    my ($cols) = @_;
    return divide($cols, 1) if arrangement($cols) ne 'two-column';
    my $band_unit = int(BREAKPOINT_TWO_COL() / 2);
    my $n = ($band_unit >= 1) ? int(int($cols) / $band_unit) : 2;
    $n = 2 if $n < 2;
    return divide($cols, $n);
}

# place(\@panels, $cols) -> \@band_rows -- assigns panels to bands. See spec
# S2.3 for the exact algorithm; carried here verbatim. PUBLIC.
sub place {
    my ($panels, $cols) = @_;
    return [] if ref($panels) ne 'ARRAY' || !@$panels;
    return []
        if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/ || int($cols) < 1;
    $cols = int($cols);

    my $K = scalar @{ columns($cols) };
    my @P = @$panels;
    my @out;
    my $i = 0;
    while ($i < @P) {
        my $n = ($K < (@P - $i)) ? $K : (@P - $i);
        my $bands;
        while (1) {
            $bands = divide($cols, $n);
            if ($n > 1) {
                my $overflow = 0;
                for my $j (0 .. $n - 1) {
                    my $panel = $P[ $i + $j ];
                    my $min_cols = (ref($panel) eq 'HASH' && defined $panel->{min_cols}
                                     && !ref($panel->{min_cols})
                                     && $panel->{min_cols} =~ /^-?\d+(?:\.\d+)?$/)
                                 ? $panel->{min_cols} : 0;
                    if ($min_cols > $bands->[$j]{w}) { $overflow = 1; last; }
                }
                if ($overflow) { $n--; next; }
            }
            last;
        }
        my @row;
        for my $j (0 .. $n - 1) {
            push @row, { panel => $P[ $i + $j ], x => $bands->[$j]{x}, w => $bands->[$j]{w} };
        }
        push @out, \@row;
        $i += $n;
    }
    return \@out;
}

# dead_columns(\@panels, $cols) -> int -- $cols minus the rightmost band-row
# extent, maximized over band rows; 0 when place() is empty. PUBLIC.
sub dead_columns {
    my ($panels, $cols) = @_;
    my $rows = place($panels, $cols);
    return 0 if !@$rows;
    return 0 if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/;
    my $max_end = 0;
    for my $row (@$rows) {
        next unless ref($row) eq 'ARRAY' && @$row;
        my $last = $row->[-1];
        my $end  = $last->{x} + $last->{w};
        $max_end = $end if $end > $max_end;
    }
    return int($cols) - $max_end;
}

# right_third_start($cols) -> $cols - int($cols/3). PUBLIC.
sub right_third_start {
    my ($cols) = @_;
    return 0 if !defined $cols || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/;
    $cols = int($cols);
    return $cols - int($cols / 3);
}

# content_reach(\@cells) -> the rightmost display column real (non-
# decorative) ink reaches, over a composed frame. See spec S2.3 for the
# exact walk. PUBLIC.
sub content_reach {
    my ($cells) = @_;
    return 0 if ref($cells) ne 'ARRAY';
    my $rule_h = Theme::glyph('rule.h');
    my $max = 0;
    for my $cell (@$cells) {
        next unless ref($cell) eq 'HASH';
        my $spans = ref($cell->{spans}) eq 'ARRAY' ? $cell->{spans} : [];
        my $col = 0;
        for my $sp (@$spans) {
            my $text = (ref($sp) eq 'HASH' && defined $sp->{text}) ? $sp->{text} : '';
            my $w = display_width($text);

            (my $no_space = $text) =~ s/ //g;
            my $decorative = 0;
            if ($no_space eq '') {
                $decorative = 1;
            } elsif (defined $rule_h && length($rule_h) && $no_space =~ /\A(?:\Q$rule_h\E)+\z/) {
                $decorative = 1;
            } elsif ($no_space =~ /\A-+\z/) {
                $decorative = 1;
            }

            if (!$decorative && $text =~ /\S/) {
                my $decoded = _strip_sgr(_decode_str($text));
                my $c = 0;
                my $rightmost_end;
                for my $ch (split //, $decoded) {
                    my $cw = char_cols($ch);
                    $c += $cw;
                    $rightmost_end = $c if $ch ne ' ' && $cw > 0;
                }
                if (defined $rightmost_end) {
                    my $candidate = $col + $rightmost_end;
                    $max = $candidate if $candidate > $max;
                }
            }
            $col += $w;
        }
    }
    return $max;
}

1;
