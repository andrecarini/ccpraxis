#!/usr/bin/env perl
# 00-oracle-hygiene.t — the shared-shape lint, as a TEST.
#
# WHY THIS IS A TEST AND NOT JUST A SCRIPT
#
# `bp-shape-lint.pl` existed first, and that was not enough. A lint only helps
# if somebody runs it, and a protocol paragraph only helps if somebody reads it.
# Both are memory aids, and this failure mode already beat memory SEVEN times in
# one blueprint — the seventh firing while the operator's own decision was being
# recorded, because t/87 pinned the decisions table at exactly 26 ids.
#
# So it runs in the suite everyone already runs. Numbered 00 so it is the first
# thing anyone sees.
#
# WHAT IT CATCHES
#
# Assertions that pin the WHOLE SHAPE of a shared, extensible artifact —
# heading counts, key sets, table sizes, "exactly N ledgers", and literal values
# of tunable constants. Each one forbids every later package from extending the
# thing it counts, so a package doing exactly what it was mandated to do turns a
# done sibling red. Assert your own package's CONTRIBUTION, or a floor.
#
# THE ESCAPE HATCH IS DELIBERATE
#
# Some pins are genuinely intentional. Rather than let those erode the check,
# mark the line:
#
#     is(scalar @things, 4, '...');   # shape-lint: intentional — <reason>
#
# The marker requires a WRITTEN REASON on the same line. That is the whole
# point: a deliberate pin should cost one sentence of justification, and an
# accidental one should cost a failing test.
#
# THIS IS A FLOOR, NOT A CEILING. The lint is a heuristic over English prose and
# it has already missed a real case (t/87 said "ids", not "headings"). Passing
# here means "no KNOWN shape-pin pattern", never "this oracle is well-formed".

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $LINT = "$Bin/../../scripts/bp-shape-lint.pl";
my @SUITES = ("$Bin", "$Bin/../../../sandbox/tests/t");

ok(-f $LINT, "bp-shape-lint.pl exists at $LINT") or BAIL_OUT("lint script missing");

# Only lint suites that actually exist — the sandbox plugin may be absent in a
# partial checkout, and that is not this test's business to fail on.
my @present = grep { -d $_ } @SUITES;
ok(scalar(@present) > 0, 'at least one test suite directory was found to lint')
    or BAIL_OUT('no suite directories found');

my $out = `perl "$LINT" @{[ map { qq{"$_"} } @present ]} 2>&1`;
my $rc  = $? >> 8;

# rc: 0 = clean, 1 = candidates, 2 = usage error. A usage error is a broken
# harness, not a finding — surface it as such rather than as a hygiene failure.
isnt($rc, 2, 'bp-shape-lint.pl ran without a usage error') or diag($out);

# Drop any candidate whose source line carries an explicit, REASONED opt-out.
my @unexcused;
for my $line (split /\n/, $out) {
    next unless $line =~ m{^\s+(\S+):(\d+)\s*$};
    my ($file, $lineno) = ($1, $2);
    # Read the reported line AND its neighbours. The lint scans a two-line
    # context window, so for a single-line assertion it can report the line
    # BEFORE the one carrying the marker — an off-by-one that silently made
    # every opt-out fail. Checking a small window costs nothing and removes the
    # coupling to the lint's internal window size.
    my $src = '';
    if (open my $fh, '<', $file) {
        my $i = 0;
        while (my $l = <$fh>) {
            $i++;
            $src .= $l if $i >= $lineno && $i <= $lineno + 2;
            last if $i > $lineno + 2;
        }
        close $fh;
    }
    # Requires a REASON after the marker, not a bare token.
    #
    # Deliberately separator-agnostic. An earlier version matched an explicit
    # [-—] class, which failed on the em-dash: the file is read as bytes, so a
    # multi-byte dash never matched the class and a properly-reasoned opt-out
    # was still reported. Match the marker, then require >= 3 word characters
    # of actual justification after it, however it is punctuated.
    #
    # /m IS LOAD-BEARING, and its absence was a second instance of the same bug
    # the paragraph above describes. $src is a THREE-LINE window; without /m,
    # `$` anchors to the end of that whole string, so the marker was recognised
    # only when it happened to fall on the window's LAST line. A correctly
    # marked opt-out one line earlier was still reported as unexcused -- found
    # by s23 when exactly that happened to t/49-session-filter.t:224.
    if ($src =~ /#\s*shape-lint:\s*intentional\b(.*)$/m) {
        my $reason = $1;
        $reason =~ s/[^A-Za-z0-9]+//g;
        next if length($reason) >= 3;
    }
    push @unexcused, "$file:$lineno";
}

is_deeply(\@unexcused, [],
    'no oracle pins the whole shape of a shared artifact (unexcused candidates)')
    or diag(
        "\n$out\n"
      . "Each candidate above pins a TOTAL over something other packages must be able to\n"
      . "extend. Retarget it to this package's own contribution, or to a floor —\n"
      . "t/64's AC-36 shows the shape (cmp_ok(..., '>=', N) with a comment recording the\n"
      . "old exact-count assertion).\n\n"
      . "If a pin is genuinely intentional, mark the line and say why:\n"
      . "    # shape-lint: intentional — <reason>\n"
      . "A bare marker with no reason does NOT suppress the finding.\n");

done_testing();
