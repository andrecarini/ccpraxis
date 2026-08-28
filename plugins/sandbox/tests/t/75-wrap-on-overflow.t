#!/usr/bin/env perl
# 75-wrap-on-overflow.t -- ORACLE for package t02-wrap-on-overflow (blueprint
# butler-and-dashboard-overhaul), specs/t02-wrap-on-overflow-spec.md. Written
# BLIND to any implementation of tui::Frame::wrap_line -- it does not exist
# yet. Do NOT weaken an assertion here to make a future implementation's
# life easier.
#
# TODAY'S EXPECTED STATE: tui::Frame::wrap_line does not exist. Direct calls
# to it are wrapped in eval and are expected to die ("Undefined subroutine")
# -- that die is checked for and reported as a distinct, honest RED signal,
# not silently swallowed. Screen-level ("surface") tests call the EXISTING,
# unmodified tui::Screen::compose / tui::DashboardScreen::compose / etc.,
# which today still hard-truncate via make_cell -- those assertions go RED
# for a WRONG VALUE (single truncated cell) rather than a die, which is
# exactly what "missing behavior" looks like at that layer.
#
# NON-VACUITY STRATEGY, applied uniformly:
#   1. Content-preservation is checked by RECONSTRUCTION (join all emitted
#      cells' plain text, strip padding/indent, recover the original word
#      list) -- never by a bare "more than one cell" count, which a buggy
#      wrap that duplicates or drops words would still pass.
#   2. Width correctness is checked via tui::Layout::display_width on every
#      emitted cell, never length()/byte count -- a wide-glyph or SGR-span
#      row is included specifically so a column-vs-byte-vs-char miscount
#      cannot hide.
#   3. Every negative ("does NOT wrap") assertion -- atomic rows, panel
#      titles/banners/footer -- is paired with a positive control proving the
#      SAME code path wraps an ordinary overflowing row under otherwise
#      identical conditions, so the negative cannot pass because nothing
#      ever wraps.
#   4. Marker-word fixtures use nonce nonwords (ZQXW-prefixed) rather than
#      generic labels, so a false match against unrelated fixture content
#      cannot make an assertion pass vacuously.
#   5. Hangs (the single-wide-glyph-on-1-column-budget edge case) are bounded
#      with alarm() -- a hang must show up as a timeout/fail, never mimic a
#      pass by being killed by the outer harness.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use Encode qw(decode encode);

my $SCRIPTS = "$Bin/../../scripts";
my $TUI_DIR = "$SCRIPTS/tui";
use lib "$Bin/../../scripts";

# ===========================================================================
# Module load gates (mirrors t/66/t/67/t/68 convention)
# ===========================================================================
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'tui/Layout.pm loads (shipped)') or diag("  require tui::Layout failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'tui/Frame.pm loads (shipped)') or diag("  require tui::Frame failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'tui/Screen.pm loads (shipped)') or diag("  require tui::Screen failed: $@");
my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'tui/DashboardScreen.pm loads (shipped)') or diag("  require tui::DashboardScreen failed: $@");
my $BS_OK = eval { require tui::BackpackScreen; 1 };
ok($BS_OK, 'tui/BackpackScreen.pm loads (shipped)') or diag("  require tui::BackpackScreen failed: $@");
my $LS_OK = eval { require tui::LaunchScreens; 1 };
ok($LS_OK, 'tui/LaunchScreens.pm loads (shipped)') or diag("  require tui::LaunchScreens failed: $@");
my $DASH_OK = eval { require Dashboard; 1 };
ok($DASH_OK, 'Dashboard.pm loads (shipped, AC2 scope-boundary needs it)') or diag("  require Dashboard failed: $@");

# ===========================================================================
# Scaffolding
# ===========================================================================

# plain($cell) -> de-SGR'd text, same shape as t/73's own helper.
sub plain {
    my ($c) = @_;
    my $t = ref($c) eq 'HASH' ? $c->{text} : '';
    $t = '' if !defined $t;
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}

# has_wrap_line() -- true once tui::Frame::wrap_line exists as a callable sub.
sub has_wrap_line { return $FRAME_OK && defined &tui::Frame::wrap_line; }

# call_wrap_line(@args) -> (\@cells, $err). Never lets a die escape -- the
# RIGHT failure for "the sub does not exist yet" is a captured, reported
# error, not a killed test file.
sub call_wrap_line {
    my (@args) = @_;
    my $cells = eval { tui::Frame::wrap_line(@args) };
    return ($cells, $@);
}

# WIDE -- the one glyph this suite's own Theme table declares at column
# width 2 (fullwidth vertical line, U+FF5C), expressed as \x{...} per this
# package's own non-ASCII-source rule (AC7/DC6) -- this file may carry no
# byte >= 0x80 itself.
my $WIDE = chr(0xFF5C);

# EACUTE -- a single decoded Latin-1 letter (U+00E9, "e with acute"), the
# accented letter this machine's own home directory path contains
# (Andr + EACUTE). Column width 1 (tui::Frame::_is_narrow_latin), byte width
# 2 in UTF-8 -- deliberately NOT equal to its char count either, so a
# byte-counting or char-counting (rather than column-counting) bug is
# distinguishable from a correct implementation.
my $EACUTE = chr(0x00E9);
my $ANDRE  = "Andr${EACUTE}";

# words($str) -> the original word list, split the same way the spec's own
# word-splitting step does (runs of a single ASCII space).
sub words { my ($s) = @_; return grep { length } split / +/, $s; }

# reconstruct(\@cells, $indent) -> the ordered word list recovered by
# stripping each cell's own leading whitespace (up to $indent, for
# continuation lines -- the FIRST cell has none) and trailing pad, then
# splitting what's left on spaces. Cells are assumed pre-decoded plain text
# (already run through plain()).
sub reconstruct {
    my ($texts, $indent) = @_;
    $indent = 0 if !defined $indent;
    my @all;
    for my $t (@$texts) {
        (my $s = $t) =~ s/\A */ /; # normalise for the split below
        $s =~ s/^\s+//;
        $s =~ s/\s+\z//;
        push @all, words($s);
    }
    return @all;
}

# atomic_overflow_spans($w) -> spans containing one atomic span wider than
# $w -- the Meter-gauge shape (tui::Meter builds atomic => 1 spans the same
# way; reconstructed by hand here rather than depending on tui::Meter, which
# this package's spec does not name).
sub atomic_overflow_spans {
    my ($w) = @_;
    return [
        { text => 'gauge ', role => 'text.primary' },
        { text => ('#' x ($w + 20)), role => 'accent', atomic => 1 },
    ];
}

# ===========================================================================
# AC7 / DC6 -- non-ASCII source guard, the manual command pinned by the spec
# (S8: no automated check could be located). Run against the three write-set
# files AND this test file itself.
# ===========================================================================
{
    my @targets = (
        "$TUI_DIR/Frame.pm",
        "$TUI_DIR/Layout.pm",
        "$TUI_DIR/Screen.pm",
        "$TUI_DIR/DashboardScreen.pm",
        "$Bin/75-wrap-on-overflow.t",
    );
    for my $f (@targets) {
        open my $fh, '<:raw', $f or do { fail("AC7: can open $f"); next };
        my @bad;
        my $ln = 0;
        while (my $line = <$fh>) {
            $ln++;
            push @bad, $ln if $line =~ /[^\x00-\x7f]/;
        }
        close $fh;
        is(scalar(@bad), 0, "AC7/DC6: no byte >= 0x80 in " . _basename($f))
            or diag("  offending lines: " . join(',', @bad));
    }
}
sub _basename { my ($p) = @_; $p =~ s{.*[\\/]}{}; return $p; }

# ===========================================================================
# AC8 (partial) -- perl -c on the three write-set files exits 0.
# ===========================================================================
{
    my $tmpdir = tempdir(CLEANUP => 1);
    for my $f (qw(Frame.pm Layout.pm Screen.pm)) {
        my $path = "$TUI_DIR/$f";
        my (undef, $out) = tempfile(DIR => $tmpdir, SUFFIX => '.out');
        my $rc = system("\"$^X\" -I\"$SCRIPTS\" -c \"$path\" > \"$out\" 2>&1");
        is($rc, 0, "AC8: perl -c $f exits 0")
            or diag("  " . do { local $/; open my $fh, '<', $out; my $s = <$fh> // ''; close $fh; $s });
    }
}

# ===========================================================================
# DC1/AC1 (unit level) -- tui::Frame::wrap_line: fast path is byte-identical.
# ===========================================================================
{
    my $line = 'short row that fits';
    my $w    = 40;
    my $expect = tui::Frame::make_cell($line, 'text.primary', $w);
    my ($cells, $err) = call_wrap_line($line, 'text.primary', $w, 2);
    ok(!$err, 'DC1-fast: wrap_line callable without dying on a fitting row')
        or diag("  died: $err");
    if (!$err) {
        is(scalar(@$cells), 1, 'DC1-fast: exactly one cell for a row that already fits');
        is_deeply($cells->[0], $expect, 'DC1-fast: byte-identical to make_cell($line,...) -- no behavior change on the common case');
    } else {
        fail('DC1-fast: exactly one cell for a row that already fits (unreachable: wrap_line died)');
        fail('DC1-fast: byte-identical to make_cell (unreachable: wrap_line died)');
    }
}

# ===========================================================================
# DC1 (unit level) -- overflow wraps, no content lost (reconstruction, not
# just "more than one cell").
# ===========================================================================
{
    my @w = qw(alpha bravo charlie delta echo foxtrot golf hotel);
    my $line = join(' ', @w);
    my $w = 20;
    my $indent = 2;
    my ($cells, $err) = call_wrap_line($line, 'text.primary', $w, $indent);
    ok(!$err, 'DC1-wrap: wrap_line callable without dying on an overflowing row')
        or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 4 if $err;
        cmp_ok(scalar(@$cells), '>', 1, 'DC1-wrap: overflowing row produces more than one cell');
        my @plain_texts = map { plain($_) } @$cells;
        for my $i (0 .. $#plain_texts) {
            is(tui::Layout::display_width($plain_texts[$i]), $w,
               "DC1-wrap: cell $i is exactly \$w=$w display columns wide");
        }
        my @got = reconstruct(\@plain_texts, $indent);
        is_deeply(\@got, \@w,
            'DC1-wrap: reconstructing all cells recovers every original word, in order, none dropped or duplicated')
            or diag("  got: [" . join(',', @got) . "]");
    }
}

# ===========================================================================
# DC1 -- atomic carve-out: an overflowing row with an atomic span still
# truncates exactly as today, is NOT wrapped. Paired with the positive
# control above (an otherwise-identical non-atomic row DOES wrap).
# ===========================================================================
{
    my $w = 10;
    my $spans = atomic_overflow_spans($w);
    my $expect = tui::Frame::make_cell($spans, 'text.primary', $w);
    my ($cells, $err) = call_wrap_line($spans, 'text.primary', $w, 2);
    ok(!$err, 'DC1-atomic: wrap_line callable without dying on an atomic-bearing overflowing row')
        or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 2 if $err;
        is(scalar(@$cells), 1, 'DC1-atomic: an atomic-bearing overflowing row still produces exactly ONE cell (not wrapped)');
        is_deeply($cells->[0], $expect, 'DC1-atomic: byte-identical to today\'s truncate-or-drop-whole make_cell result');
    }
}

# ===========================================================================
# AC3/DC2 -- continuation lines are indented by a FIXED amount, independent
# of label length (two rows of different label length, same fixed delta).
# ===========================================================================
{
    my $w = 24;
    my $indent = 2;
    my $row_short = 'ab: one two three four five six seven';
    my $row_long  = 'abcdefghijklmnop: one two three four five six seven';
    for my $row ([ 'short-label', $row_short ], [ 'long-label', $row_long ]) {
        my ($label, $line) = @$row;
        my ($cells, $err) = call_wrap_line($line, 'text.primary', $w, $indent);
        ok(!$err, "AC3: wrap_line callable without dying ($label)") or diag("  died: $err");
        SKIP: {
            skip 'wrap_line not implemented yet', 3 if $err;
            cmp_ok(scalar(@$cells), '>', 1, "AC3: $label overflowing row wraps into multiple cells");
            my $first_plain = plain($cells->[0]);
            my ($first_lead) = $first_plain =~ /^( *)/;
            my $cont_plain = plain($cells->[1]);
            my ($cont_lead) = $cont_plain =~ /^( *)/;
            cmp_ok(length($cont_lead) - length($first_lead), '==', $indent,
                "AC3: $label continuation cell has exactly $indent MORE leading columns than the row's own first cell");
            ok(substr($cont_plain, $indent, 1) ne ' ' || $indent == 0,
               "AC3: $label continuation content begins immediately after the indent (not further padded)");
        }
    }
}

# ===========================================================================
# AC3/behavior 6 -- degenerate indent >= column width falls back to indent 0
# for that row: must not die, must not loop, must make progress (continuation
# content is non-empty, not swallowed by a negative/zero budget).
# ===========================================================================
{
    my $w = 10;
    my $line = 'one two three four five six seven eight';
    for my $indent (10, 15) {
        my ($cells, $err) = eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm(5);
            my @r = call_wrap_line($line, 'text.primary', $w, $indent);
            alarm(0);
            return @r;
        };
        my $timed_out = ($@ // '') eq "TIMEOUT\n";
        ok(!$timed_out, "AC3-degenerate: indent=$indent >= w=$w does not hang");
        ok(!$err, "AC3-degenerate: indent=$indent >= w=$w does not die") or diag("  died: $err");
        SKIP: {
            skip 'wrap_line not implemented yet', 2 if $err || $timed_out;
            cmp_ok(scalar(@$cells), '>=', 1, "AC3-degenerate: indent=$indent still returns at least one cell");
            my $cont_plain = @$cells > 1 ? plain($cells->[1]) : plain($cells->[0]);
            like($cont_plain, qr/\S/, "AC3-degenerate: indent=$indent continuation content is not entirely blank -- progress was made");
        }
    }
}

# ===========================================================================
# AC5/DC4 -- SGR-styled, mixed-role spans: role survives per word, and width
# is measured in DISPLAY COLUMNS, not bytes or characters (wide glyph whose
# byte length != column width != char count).
# ===========================================================================
{
    my $w = 10;
    my $indent = 2;
    my $spans = [
        { text => 'aa bb',                      role => 'text.primary' },
        { text => "${WIDE}${WIDE}${WIDE} cc dd", role => 'accent' },
    ];
    my ($cells, $err) = call_wrap_line($spans, 'text.primary', $w, $indent);
    ok(!$err, 'AC5: wrap_line callable without dying on a mixed-role wide-glyph row') or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 3 if $err;
        cmp_ok(scalar(@$cells), '>', 1, 'AC5: mixed-role wide-glyph row wraps');
        for my $i (0 .. $#$cells) {
            is(tui::Layout::display_width(plain($cells->[$i])), $w,
               "AC5: cell $i is exactly \$w=$w DISPLAY columns wide (not bytes, not chars) -- catches a column miscount");
        }
        # role-per-word: every span emitted anywhere carries a role that is
        # one of the two the row supplied -- 'accent' must appear somewhere
        # (the WIDE-glyph word), proving role survived the word-split/rewrap.
        my $saw_accent = 0;
        for my $c (@$cells) {
            for my $sp (@{ $c->{spans} || [] }) {
                $saw_accent = 1 if defined($sp->{role}) && $sp->{role} eq 'accent';
            }
        }
        ok($saw_accent, "AC5: the 'accent'-role word's role survives into the wrapped output");
    }
}

# ===========================================================================
# AC6/DC5 -- a single word longer than the whole width: pre-split at
# character boundaries, reconstructible, no drop, no duplicate, bounded.
# ===========================================================================
{
    my $w = 10;
    my $indent = 2;
    my $word = 'x' x 50;
    my ($cells, $err, $timed_out);
    eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm(10);
        ($cells, $err) = call_wrap_line($word, 'text.primary', $w, $indent);
        alarm(0);
        1;
    } or do { $timed_out = (($@ // '') eq "TIMEOUT\n") ? 1 : 0; $err ||= $@; };
    ok(!$timed_out, 'AC6: a single overlong word does not hang');
    ok(!$err, 'AC6: a single overlong word does not die') or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 3 if $err || $timed_out;
        cmp_ok(scalar(@$cells), '>', 1, 'AC6: a single overlong word splits across multiple continuation lines');
        my @texts = map { plain($_) } @$cells;
        my @chunks = reconstruct(\@texts, $indent);
        is(join('', @chunks), $word,
            'AC6: concatenating the chunks in order recovers the exact original 50-char word -- nothing dropped or duplicated');
        my $over = grep { tui::Layout::display_width($_) > $w } @texts;
        is($over, 0, 'AC6: no emitted cell exceeds the target width');
    }
}

# ===========================================================================
# AC6/DC5 -- degenerate: single WIDE glyph on a 1-column budget. Must
# terminate (bounded by alarm), must emit the glyph whole (never dropped),
# may exceed the nominal 1-column budget by construction (unavoidable).
# ===========================================================================
{
    my $w = 1;
    my $indent = 0;
    my ($cells, $err, $timed_out);
    eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm(5);
        ($cells, $err) = call_wrap_line($WIDE, 'text.primary', $w, $indent);
        alarm(0);
        1;
    } or do { $timed_out = (($@ // '') eq "TIMEOUT\n") ? 1 : 0; $err ||= $@; };
    ok(!$timed_out, 'AC6-degenerate: a single wide glyph on a 1-column budget does not hang (bounded by alarm)');
    ok(!$err, 'AC6-degenerate: a single wide glyph on a 1-column budget does not die') or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 2 if $err || $timed_out;
        cmp_ok(scalar(@$cells), '>=', 1, 'AC6-degenerate: at least one cell is returned');
        cmp_ok(scalar(@$cells), '<=', 5, 'AC6-degenerate: terminates with a small, sane number of cells (not runaway growth)');
        # THE ORACLE WAS DESTROYING ITS OWN FIXTURE (driver, 2026-08-14).
        #
        # Encode::encode/decode CONSUME their source string in place when given a
        # truthy CHECK -- documented Encode behaviour, and the reason the
        # round-trip probe below used to empty $joined before the `like` after it
        # could read it. Verified in isolation:
        #
        #   my $s = "hello";
        #   Encode::encode("UTF-8", $s, Encode::FB_CROAK());   # $s is now ""
        #
        # This cost two wrong diagnoses. One implementer called it a missing
        # decode; the driver then called it a real DC5 content-drop and was also
        # wrong -- wrap_line returns the glyph correctly (efbd9c = U+FF5C), and
        # the emptiness was manufactured one line above the assertion.
        #
        # The probe now runs on a COPY, so it still proves the glyph round-trips
        # as a whole character while leaving $joined intact for the match.
        #
        # (plain() returns raw UTF-8 BYTES -- Frame.pm's contract, stated
        # correctly in the AC6-non-ascii block and misstated in reconstruct()'s
        # header -- so the decode below is still required to compare against the
        # decoded $WIDE.)
        my $joined_bytes = join('', map { plain($_) } @$cells);
        my $joined = eval { decode('UTF-8', $joined_bytes, Encode::FB_CROAK()) } // $joined_bytes;
        my $probe = $joined;   # COPY: encode() with a CHECK consumes its source
        my $decoded_ok = eval { decode('UTF-8', encode('UTF-8', $probe, Encode::FB_CROAK()), Encode::FB_CROAK()); 1 };
        ok($decoded_ok, 'AC6-degenerate: the glyph is emitted as a whole, valid character (round-trips through UTF-8)');
        like($joined, qr/\Q$WIDE\E/, 'AC6-degenerate: the wide glyph itself is present, never dropped');
    }
}

# ===========================================================================
# AC6/DC5 -- non-ASCII (Andre-style) survives: no \x{FFFD}, no partial
# multi-byte sequence, and the substring is preserved across every wrapped
# occurrence.
# ===========================================================================
{
    my $w = 15;
    my $indent = 2;
    my @w_list = ($ANDRE) x 20;
    # DOMAIN FIX (driver, 2026-08-14). wrap_line/fit_spans are a BYTE-domain API
    # -- Frame.pm walks raw UTF-8 via its own UTF8_CHAR_RE -- and this block's
    # own comment below says so. Feeding it a DECODED string made every cell
    # decode to something that could not contain $ANDRE, so the count came back
    # 0 of 20 regardless of the implementation. Encode on the way in, matching
    # what the block already does on the way out.
    my $line = encode('UTF-8', join(' ', @w_list));
    my ($cells, $err) = call_wrap_line($line, 'text.primary', $w, $indent);
    ok(!$err, 'AC6-non-ascii: wrap_line callable without dying on repeated Andre-style text') or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 3 if $err;
        cmp_ok(scalar(@$cells), '>', 1, 'AC6-non-ascii: the row wraps');
        my $total_count = 0;
        for my $c (@$cells) {
            # cell->{text} is raw UTF-8 BYTES (Frame.pm's own contract) --
            # decode strictly; a partial multi-byte sequence dies here.
            my $decoded = eval { decode('UTF-8', $c->{text}, Encode::FB_CROAK()) };
            ok(defined($decoded), 'AC6-non-ascii: cell text is valid, complete UTF-8 (no partial multi-byte sequence)')
                or diag("  decode failed for cell text");
            next unless defined $decoded;
            unlike($decoded, qr/\x{FFFD}/, 'AC6-non-ascii: no replacement character in any emitted cell');
            $total_count += () = ($decoded =~ /\Q$ANDRE\E/g);
        }
        is($total_count, 20, 'AC6-non-ascii: every occurrence of the Andre-style word survives across all wrapped cells');
    }
}

# ===========================================================================
# DC1 -- all-space line degrades to a single cell (S2.1f fallback), does not
# return zero cells.
# ===========================================================================
{
    my $w = 10;
    my $line = ' ' x 30;
    my ($cells, $err) = call_wrap_line($line, 'text.primary', $w, 2);
    ok(!$err, 'DC1-allspace: wrap_line callable without dying on an all-space overflowing line') or diag("  died: $err");
    SKIP: {
        skip 'wrap_line not implemented yet', 1 if $err;
        is(scalar(@$cells), 1, 'DC1-allspace: an all-space line (no words) falls back to exactly one cell, never zero');
    }
}

# ===========================================================================
# DC3 -- a pre-flex panel that WRAPS (grows taller from content width, not
# just content count) must not move any band before it, and the flex band's
# geometry must be unaffected. This is the scout-flagged coverage GAP in
# t/73 (which only varies row COUNT, never row WIDTH) -- t/73 itself is not
# touched; this is new, additional coverage using synthetic panels only
# (no live Dashboard/Backpack/LaunchScreens row inventory pinned).
# ===========================================================================
{
    my $screen_short = {
        title  => 'T',
        footer => 'F',
        panels => [
            { title => 'Fixed', lines => [ 'a short line' ] },
            { title => 'Flexy', lines => [ map { "row$_" } (1 .. 30) ], flex => 1 },
        ],
    };
    my $long_row = join(' ', map { "ZQXW$_" } (1 .. 12));
    my $screen_long = {
        title  => 'T',
        footer => 'F',
        panels => [
            { title => 'Fixed', lines => [ $long_row ] },
            { title => 'Flexy', lines => [ map { "row$_" } (1 .. 30) ], flex => 1 },
        ],
    };
    my $rows = 20;
    my $cols = 30;
    my $f_short = tui::Screen::compose($screen_short, $rows, $cols);
    my $f_long  = tui::Screen::compose($screen_long,  $rows, $cols);
    is(scalar(@$f_short), $rows, 'DC3-gap: compose returns exactly $rows for the short-content fixture');
    is(scalar(@$f_long),  $rows, 'DC3-gap: compose returns exactly $rows for the wide-content fixture');

    my $find_flexy_start = sub {
        my ($f) = @_;
        for my $i (0 .. $#$f) {
            return $i if plain($f->[$i]) =~ /Flexy/;
        }
        return undef;
    };
    my $start_short = $find_flexy_start->($f_short);
    my $start_long  = $find_flexy_start->($f_long);
    ok(defined($start_short), 'DC3-gap: the flex panel exists in the short-content fixture');
    ok(defined($start_long),  'DC3-gap: the flex panel exists in the wide-content fixture');
    # CORRECTED BY THE DRIVER, 2026-08-14 -- this assertion contradicted the spec
    # it was written from.
    #
    # It required a pre-flex panel's wrap-driven growth to leave the flex band's
    # start row untouched. The settled spec (AC4) says the opposite in terms:
    # wrap-driven growth in a pre-flex panel is "mechanically identical to ...
    # more {lines} entries -- already tolerated by t/73 block 4". Pre-flex panels
    # have ALWAYS been allowed to change height with content; that is why only
    # the flex band carries the no-shift guarantee.
    #
    # Decision 18 is NOT at risk: t/73-layout-flex-stability.t is green and
    # untouched, and it -- not this file -- is the guarantee. Satisfying the old
    # form would have meant redesigning _place_and_render's pass-1 sizing to pin
    # pre-flex height to the PRE-wrap line count and clip the overflow, i.e.
    # silently truncating again, which is the exact behaviour this package exists
    # to remove.
    #
    # What genuinely must hold is asserted instead, and is strictly stronger than
    # nothing: the frame still fills exactly $rows, the flex band still exists,
    # and it never starts EARLIER (growth may push it down, never pull it up or
    # off the frame).
    if (defined($start_short) && defined($start_long)) {
        cmp_ok($start_long, '>=', $start_short,
            'DC3-gap: wider pre-flex content may push the flex band down, never pull it up (spec AC4)');
        cmp_ok($start_long, '<', $rows,
            'DC3-gap: and the flex band still starts inside the frame, never pushed off it');
    }
}

# ===========================================================================
# S2.5/behavior 7 -- AMENDED by package d02-wrap-every-surface, Decision D1
# (specs/d02-wrap-every-surface-spec.md, Section 0). Panel titles and the
# footer still never wrap: always exactly one row each, by design -- they are
# structurally one-row surfaces via compose()'s own $rows==1/$rows==2
# short-circuits, and are already pre-narrowed upstream (header_spans,
# _footer_legend) before reaching make_cell. BANNERS NOW WRAP, deliberately
# (D1): a banner longer than the terminal used to be silently cut (losing,
# concretely, the "[d] dismiss" hint appended to install_warning); it now
# spreads across multiple rows via tui::Frame::wrap_line, row-budgeted by
# Screen.pm's compose() (Decision D2). The single assertion this superseded
# ("the overflowing banner occupies exactly one row") is replaced below by a
# multi-row assertion plus full-content reconstruction, proving the banner
# text wrapped rather than being cut into pieces. Paired positive control,
# unchanged: an ordinary body row under otherwise-identical conditions DOES
# produce more than one cell once wrap_line exists (checked above); this
# block still shows title/footer stay singular even when their own text
# overflows.
# ===========================================================================
{
    my $cols = 12;
    my $long_title  = 'a title so long it will not fit in twelve columns at all';
    my $long_banner = 'a banner so long it will not fit in twelve columns at all either';
    my $long_footer = 'a footer so long it will not fit in twelve columns at all either';
    my $screen = {
        title   => $long_title,
        footer  => $long_footer,
        banners => [ $long_banner ],
        panels  => [ { title => 'P', lines => [ 'x' ] } ],
    };
    my $rows = 12;
    my $f = tui::Screen::compose($screen, $rows, $cols);
    is(scalar(@$f), $rows, 'exclusion: compose still returns exactly $rows cells with overflowing chrome text');
    cmp_ok(tui::Layout::display_width(plain($f->[0])), '<=', $cols,
        'exclusion: the (single) title cell never exceeds the column width even though the title text overflows -- it was cut, not wrapped into a second row');
    # SUPERSEDED (d02-wrap-every-surface, Decision D1/Section 0 AC-0): the
    # banner now wraps. Selected here by CELL ROLE, not the text-substring
    # grep the original assertion used -- verified directly against
    # tui::Frame::wrap_line's real output for this exact fixture
    # ($long_banner, cols=12, indent=2) that the literal substring "a banner"
    # survives on only the FIRST wrapped row (the word "banner" is not
    # split), so a substring grep cannot detect "more than one row" here even
    # once wrapping is implemented correctly -- it would always find exactly
    # one match, for the wrong reason (a selector miss, not a behavior miss).
    # Screen.pm's compose() gives every banner row a stable, distinct role
    # (here the default 'state.warn', Screen.pm's _ROLE_ATTENTION()), which
    # is what actually identifies "a row that belongs to this banner" without
    # depending on where wrap_line happened to break the words.
    my @banner_rows = grep { defined($_->{role}) && $_->{role} eq 'state.warn' } @$f;
    cmp_ok(scalar(@banner_rows), '>', 1,
        'exclusion (superseded by d02 Decision D1): the overflowing banner now occupies MORE than one row -- it wraps rather than being cut');
    my @banner_plain = map { plain($_) } @banner_rows;
    my @banner_words = reconstruct(\@banner_plain, tui::Screen::WRAP_CONTINUATION_INDENT());
    my @expect_words  = words($long_banner);
    is_deeply(\@banner_words, \@expect_words,
        'exclusion (superseded by d02 Decision D1): reconstructing the wrapped banner rows recovers the FULL original banner text, in order, none dropped or duplicated -- proving it wrapped rather than being cut into pieces')
        or diag("  got: [" . join(',', @banner_words) . "]\n  want: [" . join(',', @expect_words) . "]");
    my @footer_rows = grep { plain($_) =~ /a footer/ } @$f;
    is(scalar(@footer_rows), 1, 'exclusion: the overflowing footer occupies exactly one row, not wrapped into more');
}

# ===========================================================================
# S2.3/DC1 -- exclusion, at the Screen level: an overflowing row carrying an
# atomic span (the Meter gauge/percent shape) renders as exactly one row per
# logical line, not wrapped -- paired against a positive control (a plain
# overflowing row in the SAME panel DOES, once wrap_line exists, produce
# multiple cells; that is asserted above at the unit level and, via AC1
# below, at the surface level).
# ===========================================================================
{
    my $cols = 10;
    my $atomic_line = [ { text => 'gauge ', role => 'text.primary' },
                         { text => ('#' x 40), role => 'accent', atomic => 1 } ];
    my $screen = {
        title  => 'T',
        footer => 'F',
        panels => [ { title => 'P', lines => [ $atomic_line ] } ],
    };
    my $f = tui::Screen::compose($screen, 10, $cols);
    my @gauge_rows = grep { plain($_) =~ /gauge/ } @$f;
    is(scalar(@gauge_rows), 1, 'exclusion: an atomic-bearing overflowing row occupies exactly one rendered row, never wrapped');
}

# ===========================================================================
# AC2 -- explicit scope-boundary record: Dashboard.pm's own separate
# fit_spans/make_cell (used directly by bp-statusline.pl) is OUT OF SCOPE
# and remains truncating. This does not assert wrap must NOT ever be added
# there later -- it records today's (and this package's intended) behavior
# so a future change cannot silently start claiming otherwise here.
# ===========================================================================
SKIP: {
    skip 'Dashboard.pm did not load', 2 if !$DASH_OK;
    my $long = 'x' x 60;
    my $cell = Dashboard::fit_spans([ { text => $long, role => 'body' } ], 10, 'body');
    my $text = join('', map { $_->{text} // '' } @$cell);
    is(tui::Layout::display_width($text), 10,
        'AC2 scope-boundary: Dashboard::fit_spans (legacy, used by bp-statusline.pl) still pads/truncates to exactly $w -- unaffected by this package, by design');
    unlike($text, qr/\A$long\z/, 'AC2 scope-boundary: Dashboard::fit_spans truncated the overlong text rather than preserving all of it -- confirms it still truncates, not wraps (OUT OF SCOPE, S6)');
}

# ===========================================================================
# AC1 -- surface-level: every production caller of the render library wraps
# an overflowing, non-atomic row. Synthetic fixtures only; the exact row
# inventory of the live Dashboard/Backpack/LaunchScreens panel sets is NOT
# pinned (t01's territory) -- only the presence/shape of OUR injected marker
# row is asserted.
# ===========================================================================
{
    my @marker_words = map { "ZQXW$_" } (1 .. 12);
    my $marker_text  = join(' ', @marker_words);
    my $cols = 30;
    # HEIGHT RAISED 30 -> 40, 2026-08-28. The WIDTH is what this test is about
    # (30 columns is what forces the marker row to wrap) and it is unchanged.
    #
    # The height had to move because the grid was reorganised: Providers now
    # renders its two provider blocks stacked at this width and wraps to ~13
    # rows, which pushed the Blueprints panel -- where the marker lives -- past
    # the bottom of a 30-row frame entirely. The marker was not truncated; the
    # panel carrying it was never composed, so the assertion was measuring an
    # absent row rather than a wrapped one.
    #
    # 40 rows reaches the panel with room to spare. Verified: the marker occupies
    # 3 rows at 40, 50 and 60, so this is not balanced on a boundary.
    my $rows = 40;

    # -- DashboardScreen::compose --------------------------------------
    SKIP: {
        skip 'tui::DashboardScreen did not load', 4 if !$DS_OK;
        my $state = {
            project_name => 'p', container => 'c', status => 'running',
            runs => [ { blueprint => 'bp', state => 'running',
                        packages_done => 1, packages_total => 3,
                        current_package => $marker_text } ],
        };
        my $f = tui::DashboardScreen::compose($state, $rows, $cols);
        _assert_surface_wraps('DashboardScreen', $f, \@marker_words, $marker_text, $cols);
    }

    # -- BackpackScreen::compose -----------------------------------------
    SKIP: {
        skip 'tui::BackpackScreen did not load', 4 if !$BS_OK;
        my $ss = { rows => [ { key => $marker_text, approved => 0 } ] };
        my $f = tui::BackpackScreen::compose($ss, $rows, $cols);
        _assert_surface_wraps('BackpackScreen', $f, \@marker_words, $marker_text, $cols);
    }

    # -- LaunchScreens::compose_progress (progress_screen) ---------------
    SKIP: {
        skip 'tui::LaunchScreens did not load', 4 if !$LS_OK;
        my $host = { stages => [ { label => $marker_text, state => 'running' } ] };
        my $f = tui::LaunchScreens::compose_progress($host, $rows, $cols);
        _assert_surface_wraps('LaunchScreens::progress', $f, \@marker_words, $marker_text, $cols);
    }

    # -- LaunchScreens::compose_list (list_screen) ------------------------
    SKIP: {
        skip 'tui::LaunchScreens did not load', 4 if !$LS_OK;
        my $ls = { items => [ { kind => 'row', display => $marker_text } ] };
        my $f = tui::LaunchScreens::compose_list($ls, $rows, $cols);
        _assert_surface_wraps('LaunchScreens::list', $f, \@marker_words, $marker_text, $cols);
    }
}

# _assert_surface_wraps($surface, \@frame_cells, \@marker_words, $marker_text, $cols)
# AC1's three sub-assertions: (a) more than one cell's worth of content for
# the marker row, (b) no matched cell's plain text exceeds $cols, (c) full
# word reconstruction across matched cells recovers every marker word.
sub _assert_surface_wraps {
    my ($surface, $f, $marker_words, $marker_text, $cols) = @_;
    my @matched = grep { plain($_) =~ /ZQXW/ } @$f;
    cmp_ok(scalar(@matched), '>', 1,
        "AC1 $surface: the injected overflowing marker row produces more than one cell -- not cut to one truncated line");
    my $over = grep { tui::Layout::display_width(plain($_)) > $cols } @matched;
    is($over, 0, "AC1 $surface: no matched cell's plain text exceeds the column width ($cols)");
    my $joined = join(' ', map { plain($_) } @matched);
    my $missing = grep { $joined !~ /\Q$_\E/ } @$marker_words;
    is($missing, 0, "AC1 $surface: every marker word from the original row is present somewhere across the produced cells -- nothing silently dropped");
}

done_testing();
