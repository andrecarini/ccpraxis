#!/usr/bin/env perl
# platform: any
# A glyph's extra spacing is declared once, in Theme.pm, and applied everywhere automatically.
#
# Operator, 2026-11-01: U+23F8 (the pause glyph) renders badly against the text after it and needs
# one extra space, and "only glyphs I specified it for should have the double space treatment and
# that should be automatic everywhere in a centralized code". So:
#
# AC1  Theme.pm declares `pad` per glyph; only the U+23F8 entries (thread.idle, title.paused) have it
# AC2  glyph() emits the pad, glyph_width() counts it; the record itself stays the bare glyph
#      (bytes and width describe the one character, as the width tables and drift guards need)
# AC3  generated_block() exports every padded codepoint as %THEME_GLYPH_PAD, and statusline.pl's
#      embedded block is in sync with it
# AC4  statusline.pl draws theme glyphs through _g(), which applies %THEME_GLYPH_PAD; no bare
#      U+23F8 literal remains in an emitted string
use strict;
use warnings;
use FindBin qw($Bin);
use Encode ();
use Test::More;
use lib "$Bin/../../scripts";
use Theme ();

my $PAUSE = Encode::encode('UTF-8', chr(0x23F8));

# --- AC1 ---------------------------------------------------------------------------------------------
my $src = do { open my $fh, '<:raw', "$Bin/../../scripts/Theme.pm" or die $!; local $/; <$fh> };
my @padded = $src =~ /'([a-z.]+)'\s*=>\s*\{\s*cp\s*=>\s*0x[0-9A-F]+,\s*pad\s*=>/g;
is_deeply([sort @padded], [qw(thread.idle title.paused)], 'AC1 only the two U+23F8 entries declare a pad');

# --- AC2 ---------------------------------------------------------------------------------------------
for my $name (qw(thread.idle title.paused)) {
    is(Theme::glyph($name), "$PAUSE ", "AC2 glyph('$name') is the glyph plus one space");
    is(Theme::glyph_width($name), 2, "AC2 glyph_width('$name') counts the pad (1 + 1)");
    my $rec = Theme::glyphs()->{$name};
    is($rec->{bytes}, $PAUSE, "AC2 the '$name' record stays the bare glyph (bytes)");
    is($rec->{width}, 1, "AC2 the '$name' record stays the bare glyph (width)");
}
is(Theme::glyph('status.ok'), Encode::encode('UTF-8', chr(0x25CF)), 'AC2 an unpadded glyph is unchanged');
is(Theme::glyph_width('status.ok'), 1, 'AC2 and so is its width');

# --- AC3 ---------------------------------------------------------------------------------------------
my $block = Theme::generated_block();
like($block, qr/^my %THEME_GLYPH_PAD = \(\n  0x23F8 => 1,\n\);$/m, 'AC3 the generated block exports the pad table');
my $sl = do { open my $fh, '<:raw', "$Bin/../../../../scripts/statusline.pl" or die $!; local $/; <$fh> };
my ($embedded) = $sl =~ /# >>> BEGIN GENERATED FROM Theme\.pm -- DO NOT EDIT BY HAND >>>\n(.*?)# <<< END GENERATED FROM Theme\.pm <<</s;
is($embedded, $block, 'AC3 statusline.pl embeds the current generated block');

# --- AC4 ---------------------------------------------------------------------------------------------
like($sl, qr/^sub _g \{ my \(\$cp\) = \@_; return chr\(\$cp\) \. \(q\{ \} x \(\$THEME_GLYPH_PAD\{\$cp\} \/\/ 0\)\) \}$/m,
     'AC4 statusline.pl has the one helper that applies the pad');
like($sl, qr/\$\{\\ _g\(0x23F8\)\} idle/, 'AC4 the idle marker is drawn through it');
my @bare = grep { !/^\s*#/ && /"[^"]*\\x\{23F8\}/ } split /\n/, $sl;
is(scalar @bare, 0, 'AC4 no emitted string carries a bare U+23F8 literal') or diag(join "\n", @bare);

done_testing();
