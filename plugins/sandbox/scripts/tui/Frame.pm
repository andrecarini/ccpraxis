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
sub safe_char {
    my ($c) = @_;
    return '' if !defined $c || $c eq '';
    my $cp = ord($c);
    return $c if $cp >= 0x20 && $cp <= 0x7E;
    return $c if defined tui::Layout::glyph_width($c);
    return '' if tui::Layout::char_cols($c) == 0;
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
