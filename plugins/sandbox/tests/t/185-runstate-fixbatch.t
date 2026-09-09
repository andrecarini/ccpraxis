#!/usr/bin/env perl
# agent-telemetry 04-runstate-run-and-package-facts consolidated fix-batch:
# covers the two behavioural fixes that have no home in the existing
# immutable oracle (t/184-runstate-package-facts.t, which permits exactly one
# authorised edit -- AC35's expected 'step' value -- and no others):
#
#   * HIGH-2  -- _parse_next_action takes the LAST '## Next action' heading
#                in an append-only ledger, not the first (stale-instruction
#                defect: a real archived ledger with five headings rendered
#                a finished package as "dispatch step 3").
#   * MEDIUM-2 -- both _parse_pipeline and _parse_next_action tolerate a
#                '#'-at-column-0 line (e.g. a pasted shell comment) inside a
#                fenced code block without misreading it as the next
#                markdown heading and truncating the scan early.
#
# Same harness discipline as t/184: a missing/failing sub degrades to a
# clean per-assertion FAIL via probe_call/probe_list, never a spurious PASS
# and never a file-aborting die.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('RunState');

sub probe_call {
    my ($fn, @args) = @_;
    my ($res, $err);
    {
        local $SIG{__WARN__} = sub { };
        $res = eval { no strict 'refs'; &{"RunState::$fn"}(@args) };
        $err = $@;
    }
    return ($res, defined($err) ? $err : '');
}

sub probe_list {
    my ($fn, @args) = @_;
    my (@res, $err);
    {
        local $SIG{__WARN__} = sub { };
        @res = eval { no strict 'refs'; &{"RunState::$fn"}(@args) };
        $err = $@;
    }
    return (\@res, defined($err) ? $err : '');
}

# ===========================================================================
# HIGH-2 -- _parse_next_action takes the LAST heading, not the first.
# ===========================================================================
{
    my $blob = "---\npackage: x\n---\n# body\n\n"
        . "## Next action\n\nDispatch bp-test-writer (step 3) against the accepted spec.\n\n"
        . "## Decisions & attempt log\n\nsome journal entry\n\n"
        . "## Next action\n\nNone -- package COMPLETE. All 8 pipeline steps closed.\n";
    my ($list, $err) = probe_list('_parse_next_action', $blob);
    is($err, '', 'HIGH-2: _parse_next_action does not die on a multi-heading ledger');
    is($list->[0], 'None -- package COMPLETE. All 8 pipeline steps closed.',
        'HIGH-2: _parse_next_action returns the LAST "## Next action" section, not the first stale one');
}

{
    # Three headings, to rule out an off-by-one "second, not last" bug.
    my $blob = "---\npackage: x\n---\n# body\n\n"
        . "## Next action\n\nfirst (oldest)\n\n"
        . "## Next action\n\nsecond (middle)\n\n"
        . "## Next action\n\nthird (current)\n";
    my ($list, $err) = probe_list('_parse_next_action', $blob);
    is($err, '', 'HIGH-2 [3 headings]: _parse_next_action does not die');
    is($list->[0], 'third (current)', 'HIGH-2 [3 headings]: the LAST of three headings wins');
}

# ===========================================================================
# MEDIUM-2 -- fenced-code-block awareness in _parse_pipeline.
# ===========================================================================
{
    # Exact repro from 04-redteam.md's MEDIUM-2: a shell comment pasted at
    # column 0 inside a fence, between two real checkbox lines, must not
    # truncate the scan.
    my $blob = "---\npackage: x\n---\n# body\n\n## Pipeline\n\n"
        . "- [x] 1. a\n"
        . "```\n# a shell comment\n```\n"
        . "- [x] 2. b\n"
        . "- [ ] 3. c\n";
    my ($list, $err) = probe_list('_parse_pipeline', $blob);
    is($err, '', 'MEDIUM-2 [pipeline]: _parse_pipeline does not die on a fenced code block');
    is($list->[0], '3/3', 'MEDIUM-2 [pipeline]: fenced "# a shell comment" does not truncate the scan -- step eq "3/3", not "1/1"');
    is_deeply($list->[1], [3], 'MEDIUM-2 [pipeline]: steps_pending == [3] -- steps 1 and 2 (after the fence) both parsed');
}

{
    # Unbalanced fence (never closed) must not hang or die -- the scan just
    # ends at EOF still "inside" the fence, same as any other malformed input.
    my $blob = "---\npackage: x\n---\n# body\n\n## Pipeline\n\n"
        . "- [x] 1. a\n"
        . "```\n# never closed\n"
        . "- [ ] 2. b\n";
    my ($list, $err) = probe_list('_parse_pipeline', $blob);
    is($err, '', 'MEDIUM-2 [unclosed fence]: _parse_pipeline does not die');
    ok(defined($list->[0]), 'MEDIUM-2 [unclosed fence]: still returns a step (does not silently degrade to undef,undef)');
}

# ===========================================================================
# MEDIUM-2 -- the same guard applied to _parse_next_action (redteam: "the
# same guard should be applied to _parse_next_action, whose collection loop
# has the identical stop condition").
# ===========================================================================
{
    my $blob = "---\npackage: x\n---\n# body\n\n## Next action\n\n"
        . "Run the validation command below,\n"
        . "```\n# perl scripts/run-tests.pl --fast\n```\n"
        . "then report the result.\n";
    my ($list, $err) = probe_list('_parse_next_action', $blob);
    is($err, '', 'MEDIUM-2 [next_action]: _parse_next_action does not die on a fenced code block');
    like($list->[0], qr/then report the result\./, 'MEDIUM-2 [next_action]: text after the fenced "#" line is still collected, not truncated');
}

# ===========================================================================
# AT-6 (driver ruling) -- the denominator is the highest step number
# observed, not a count of parseable lines, exercised directly (not only via
# t/184's AC35 over-length fixture).
# ===========================================================================
{
    # Step 5 appears twice; the spec's "first occurrence wins" rule means the
    # duplicate is dropped from the checked SET, so a naive count-of-keys
    # denominator (7 distinct numbers seen: 1,2,3,4,5,8 -- six, not seven,
    # since 5 collapses to one key) would disagree with the max, which is 8.
    my $blob = "---\npackage: x\n---\n# body\n\n## Pipeline\n\n"
        . "- [x] 1. a\n- [x] 2. b\n- [x] 3. c\n- [x] 4. d\n"
        . "- [ ] 5. e (first)\n- [x] 5. e (duplicate, ignored)\n"
        . "- [ ] 8. h\n";
    my ($list, $err) = probe_list('_parse_pipeline', $blob);
    is($err, '', 'AT-6: _parse_pipeline does not die');
    is($list->[0], '5/8', 'AT-6: denominator is the highest step number observed (8), not the count of distinct recognised numbers (6)');
    is_deeply($list->[1], [5, 8], 'AT-6: steps_pending == [5,8] -- the duplicate 5 line (first occurrence wins) does not double-count');
}

done_testing();
