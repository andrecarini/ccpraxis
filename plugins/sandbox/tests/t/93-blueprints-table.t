#!/usr/bin/env perl
# t04-blueprints-table -- the oracle for blueprint tui-operator-feedback.
#
# Closes the operator's fifth report, verbatim: "the blueprints section should
# be styled as a table because right now its hard to see with things randomly
# aligned."
#
# It was literally that. _one_run_summary_spans concatenated variable-width
# fields with two-space separators, so the state of run 2 sat under the middle
# of run 1's name and nothing below the first field lined up with anything. A
# per-row renderer structurally CANNOT align columns -- only something that can
# see every row at once can.
#
# CRITERION 2 IS WHY THE HELPER LIVES IN tui::Frame: written once, reusable, not
# inlined into this one panel. The predecessor initiative spent two fix-batches
# on exactly this class of duplication, so PART 1 tests the helper on synthetic
# data with no dashboard in sight, and PART 3 tests the panel through it.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Theme;

my $OK = eval { require tui::Frame; require tui::Layout; require tui::DashboardScreen;
                require Dashboard; 1 };
ok($OK, 'the TUI modules load') or BAIL_OUT("require failed: $@");

sub plain { my ($s) = @_; $s = '' if !defined $s; $s =~ s/\e\[[0-9;]*m//g; return $s }
sub text_of { return plain(tui::Frame::spans_text($_[0])) }
sub width_of { return tui::Layout::display_width(text_of($_[0])) }

# ===========================================================================
# PART 1 -- tui::Frame::table on synthetic data (criterion 1, 2, 3).
# ===========================================================================
{
    can_ok('tui::Frame', 'table');

    my @rows = (
        [ 'alpha',        'running', '1/2 pkg'   ],
        [ 'bravo-longer', 'paused',  '10/20 pkg' ],
        [ 'c',            'done',    '3/3 pkg'   ],
    );

    # AC1 -- THE WHOLE ASK. Every rendered row is the same width, and each
    # column starts at the same offset in every row. That second half is the
    # one that matters: equal total width is satisfiable by padding alone,
    # while equal column offsets is what lets a reader scan down.
    my $t = tui::Frame::table(\@rows, { width => 60 });
    is(scalar(@$t), 3, 'AC1: one output row per input row');

    my %w; $w{ width_of($_) } = 1 for @$t;
    is(scalar(keys %w), 1, 'AC1: every rendered row has the same display width');

    for my $col (1, 2) {
        my %offset;
        for my $i (0 .. $#rows) {
            my $needle = $rows[$i][$col];
            $offset{ index(text_of($t->[$i]), $needle) } = 1;
        }
        is(scalar(keys %offset), 1,
            "AC1: column $col starts at the same offset in every row -- a reader can scan down it");
    }

    # AC1 -- and non-vacuously: the OLD concatenating shape would fail this.
    my @concat = map { join('  ', @$_) } @rows;
    my %old_offset; $old_offset{ index($_, 'pkg') } = 1 for @concat;
    cmp_ok(scalar(keys %old_offset), '>', 1,
        'AC1 non-vacuity: the concatenated shape this replaces genuinely misaligned the same data');

    # Alignment, and it must actually differ from the default.
    my $right = tui::Frame::table(\@rows, { width => 60, align => [ 'left', 'left', 'right' ] });
    my @lefts  = map { text_of($_) } @$t;
    my @rights = map { text_of($_) } @$right;
    isnt(join('|', @lefts), join('|', @rights),
        'AC1: a right-aligned column renders differently from a left-aligned one');
    my %rend; $rend{ length((text_of($_) =~ /(.*pkg)/)[0] // '') } = 1 for @$right;
    is(scalar(keys %rend), 1, 'AC1: right-aligned cells end at a common column');

    # AC3 -- narrow behaviour is DECIDED. Drop order is honoured, highest first.
    my @wide_rows = (
        [ 'alpha', 'running', '1/2 pkg', '2 coord', '1 waiting' ],
        [ 'bravo', 'paused',  '3/9 pkg', '',        ''          ],
    );
    my %opts = ( align => [ ('left') x 5 ], min => [ 5, 4, 5, 3, 3 ],
                 drop => [ undef, undef, undef, 2, 1 ] );

    my $roomy = tui::Frame::table(\@wide_rows, { %opts, width => 80 });
    like(text_of($roomy->[0]), qr/2 coord/,   'AC3: with room, no column is dropped');
    like(text_of($roomy->[0]), qr/1 waiting/, 'AC3: including the last one');

    my $tight = tui::Frame::table(\@wide_rows, { %opts, width => 34 });
    unlike(text_of($tight->[0]), qr/2 coord/,
        'AC3: the highest drop-order column goes first');
    like(text_of($tight->[0]), qr/1 waiting/,
        'AC3: and the lower one survives -- the ORDER is honoured, not just the dropping');

    my $tighter = tui::Frame::table(\@wide_rows, { %opts, width => 24 });
    unlike(text_of($tighter->[0]), qr/waiting/,
        'AC3: squeezed further, the next column goes too');
    like(text_of($tighter->[0]), qr/alpha/,
        'AC3: but a column with NO drop entry is never dropped -- without it the row identifies nothing');

    # AC3 -- shrink, then truncate visibly. A shortened value must be visibly
    # shortened, never quietly wrong.
    my $ell = tui::Frame::ELLIPSIS();
    my $squeezed = tui::Frame::table([ [ 'a-very-long-blueprint-name', 'running' ] ],
                                     { width => 16, min => [ 6, 4 ], gap => 1 });
    like(text_of($squeezed->[0]), qr/\Q$ell\E/,
        'AC3: a cell shrunk past its content is truncated WITH the ellipsis, not silently cut');

    # AC4 -- widths. The contract is "never claim to fit when you do not", so
    # a table given room must be within it.
    for my $width (24, 34, 40, 60, 100) {
        my $rowset = tui::Frame::table(\@wide_rows, { %opts, width => $width });
        my @over = grep { width_of($_) > $width } @$rowset;
        is(scalar(@over), 0, "AC4: at width $width no row exceeds the budget");
    }

    # Totality -- this is on the render path.
    for my $bad (undef, 'scalar', {}, []) {
        my $got = eval { tui::Frame::table($bad, { width => 40 }) };
        is(ref($got), 'ARRAY', 'AC: malformed rows yield an arrayref rather than dying')
            or diag("  died: $@");
    }
    is_deeply(tui::Frame::table([], { width => 40 }), [], 'AC: no rows yields no rows');

    # A SHORT row must not crash or shift the columns of its neighbours.
    my $ragged = tui::Frame::table([ [ 'a', 'b', 'c' ], [ 'aa' ] ], { width => 40 });
    is(scalar(@$ragged), 2, 'AC: a row with missing trailing cells still renders');
    is(width_of($ragged->[0]), width_of($ragged->[1]),
        'AC: and comes out the same width as its full-length neighbour');
}

# ===========================================================================
# PART 2 -- the helper is REUSABLE, not blueprint-shaped (criterion 2).
# ===========================================================================
{
    # Nothing in the signature or behaviour mentions blueprints. Demonstrated
    # rather than asserted about the source: a completely unrelated dataset
    # tables correctly with the same call.
    my $t = tui::Frame::table(
        [ [ 'cpu',    '42%',  'ok'   ],
          [ 'memory', '7.5G', 'warn' ],
          [ 'disk',   '91%',  'crit' ] ],
        { width => 40, align => [ 'left', 'right', 'left' ] });
    is(scalar(@$t), 3, 'AC2: the helper tables an unrelated dataset with no changes');
    my %w; $w{ width_of($_) } = 1 for @$t;
    is(scalar(keys %w), 1, 'AC2: and aligns it');

    # THE REUSABILITY EVIDENCE IS THE DEMONSTRATION ABOVE, NOT A SOURCE SCAN.
    #
    # The first draft of this check grepped tui/Frame.pm for /blueprint/i and
    # failed -- on the module's own header, which cites the ccpraxis BLUEPRINT
    # that commissioned the render library. That is the "oracle pinning prose"
    # shape this initiative has already corrected three times in other files,
    # and writing a fourth instance into a brand-new oracle would have been the
    # worst of the four.
    #
    # What criterion 2 actually asks is that the helper carry no
    # blueprint-specific BEHAVIOUR. That is checked where it can be checked:
    # the sub's own body, with comments and the surrounding module excluded.
    my $src = do { local $/; open(my $fh, '<', "$Bin/../../scripts/tui/Frame.pm") or die $!; <$fh> };
    my ($body) = $src =~ /\nsub table \{(.*?)\n\}/s;
    ok(defined $body && length $body, 'AC2: tui::Frame::table\'s body is locatable for inspection');
  SKIP: {
        skip('table body not found', 1) unless defined $body && length $body;
        $body =~ s/^\s*#.*$//mg;                      # comments are not behaviour
        unlike($body, qr/blueprint|package|run\b|coord|waiting/i,
            'AC2: and its body names no concept from the panel that commissioned it -- it is a table, not a blueprint renderer');
    }
}

# ===========================================================================
# PART 3 -- the Blueprints panel, through the real dashboard.
# ===========================================================================
my @RUNS = (
    { blueprint => 'ccpraxis-tooling-debt', state => 'running', packages_done => 5,  packages_total => 5,
      current_package => 'd05-almanac-frontmatter-injection', running_coordinators => 2, decisions_waiting => 0 },
    { blueprint => 'tui-operator-feedback', state => 'paused',  packages_done => 7,  packages_total => 10,
      current_package => 't04-blueprints-table', running_coordinators => 0, decisions_waiting => 1 },
    { blueprint => 'gsa',                   state => 'done',    packages_done => 12, packages_total => 12,
      running_coordinators => 0, decisions_waiting => 0 },
);

sub panel_rows {
    my ($cols) = @_;
    my $panels = tui::DashboardScreen::panels({ runs => \@RUNS, events => [], tokens => {} }, $cols);
    my ($p) = grep { ref($_) eq 'HASH' && ($_->{title} // '') eq 'Blueprints' } @$panels;
    return $p ? $p->{lines} : [];
}

for my $cols (60, 80, 100, 130, 150, 200) {
    my $lines = panel_rows($cols);
    my @table = grep { text_of($_) !~ /^\s*cur / && text_of($_) =~ /pkg/ } @$lines;

    cmp_ok(scalar(@table), '>=', 3, "AC5: cols=$cols -- all three runs render as table rows");

    my %w; $w{ width_of($_) } = 1 for @table;
    is(scalar(keys %w), 1, "AC5: cols=$cols -- every blueprint row is the same width");

    my %at;
    $at{ index(text_of($_), 'pkg') } = 1 for @table;
    is(scalar(keys %at), 1,
        "AC5: cols=$cols -- the package-count column ends at a common offset in every row, which is the operator's actual ask");

    # AC6 -- the table sizes to the BAND, not the terminal. A table wider than
    # the band it lands in would be wrapped by _render_panel, destroying the
    # alignment this package exists to create.
    my @over = grep { width_of($_) > $cols } @table;
    is(scalar(@over), 0, "AC6: cols=$cols -- no row exceeds even the full terminal width");
}

# AC7 -- the current package is NOT a table column, and this is the assertion
# that encodes why. Package d02 of the predecessor initiative closed bug report
# 20260814-093052-312a with a standing rule -- an overflowing row must WRAP and
# no word may be silently dropped -- and a droppable column violates it. The
# first draft of this package made `cur` a column; t/75-wrap-on-overflow.t AC1
# caught it, at cols=30, where the column was dropped and the package name
# vanished entirely.
for my $cols (60, 100, 150) {
    my $lines = panel_rows($cols);
    my $joined = join("\n", map { text_of($_) } @$lines);
    like($joined, qr/d05-almanac-frontmatter-injection/,
        "AC7: cols=$cols -- the current package survives at every width, because it is its own wrappable line rather than a droppable column");
    my @curs = grep { text_of($_) =~ /^\s*cur / } @$lines;
    is(scalar(@curs), 2,
        "AC7: cols=$cols -- exactly one such line per run that HAS a current package, and none for the run that does not");
}

# AC8 -- no colon in a blueprint table row (Decision 2). The old shape wrote
# "$bp : " between the name and the state; in a table the column IS the
# separator, so the colon was decoration.
for my $cols (60, 100, 150) {
    my @table = grep { text_of($_) =~ /pkg/ } @{ panel_rows($cols) };
    my $with = grep { text_of($_) =~ /:/ } @table;
    is($with, 0, "AC8 (Decision 2): cols=$cols -- no colon in any blueprint table row");
}

# AC9 -- the empty case still says something rather than rendering nothing.
{
    my $panels = tui::DashboardScreen::panels({ runs => [], events => [], tokens => {} }, 100);
    my ($p) = grep { ($_->{title} // '') eq 'Blueprints' } @$panels;
    ok($p, 'AC9: the Blueprints panel exists with no runs at all');
    like(join("\n", map { text_of($_) } @{ $p->{lines} }), qr/no active runs/,
        'AC9: and states the absence rather than rendering an empty table');
}

# AC10 -- row-count and exact-width invariants, through compose_frame, across a
# grid. Criterion 4, and the invariant t03 and the previous initiative's d02
# both turned on.
{
    my ($rowbad, $widebad, $checked) = (0, 0, 0);
    for my $cols (60, 80, 100, 130, 150, 200) {
        for my $rows (6, 12, 24, 45) {
            my $f = Dashboard::compose_frame({ runs => \@RUNS, events => [], tokens => {} }, $rows, $cols);
            $rowbad++ if scalar(@$f) != $rows;
            $widebad += scalar grep { tui::Layout::display_width(plain($_->{text})) != $cols } @$f;
            $checked++;
        }
    }
    is($rowbad,  0, "AC10: total rows equals the terminal height across all $checked combinations");
    is($widebad, 0, 'AC10: and every row is exactly the terminal width');
}

done_testing();
