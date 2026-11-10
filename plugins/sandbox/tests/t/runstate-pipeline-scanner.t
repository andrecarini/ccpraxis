#!/usr/bin/env perl
# platform: any
# Bug 20261104-201500-ee4b: RunState had two readers of a ledger's
# "## Pipeline" checklist -- _parse_pipeline (steps 1-8 only; "N/M" and
# steps_pending) and _pipeline_step_word (1-99; the current step's word) --
# so a 9-step ledger with 1-8 ticked read "8/8" (finished) beside a step
# word naming step 9. Both now derive from one scanner, _scan_pipeline,
# which also understands range entries ("3-5. N/A"), [-] / [U+2014] N/A
# marks, and the skip / n/a markers bp-ledger.pl tick-step writes. Its
# per-item list is exposed as the package fact `pipeline`.
#
# Same harness discipline as runstate-fixbatch.t: a missing/failing sub is a
# clean per-assertion FAIL, never a spurious PASS and never a file abort.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Test::More;

use_ok('RunState');

my $EM = "\xE2\x80\x94";   # U+2014 EM DASH, as the UTF-8 bytes a ledger holds

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

sub ledger { return "---\npackage: x\nstatus: running\n---\n# body\n\n## Pipeline\n\n" . join('', map { "$_\n" } @_) . "\n## Next action\n\nsomething\n"; }

# pp($blob) -> [step, pending, word, pipeline]
sub pp {
    my ($blob) = @_;
    my ($l1) = probe_list('_parse_pipeline', $blob);
    my ($l2) = probe_list('_pipeline_step_word', $blob);
    my ($l3) = probe_list('_scan_pipeline', $blob);
    return [ $l1->[0], $l1->[1], $l2->[0], $l3->[0] ];
}

# The fraction and the word must always name the same item.
sub agrees {
    my ($r, $label) = @_;
    my $items = $r->[3];
    my ($cur) = ref($items) eq 'ARRAY' ? grep { $_->{state} eq 'todo' } @$items : ();
    if ($cur) {
        my ($n) = defined $r->[0] ? $r->[0] =~ m{\A(\d+)/} : (undef);
        is($n, $cur->{n}[0], "$label: step N is the current item's first number");
        is($r->[2], $cur->{word}, "$label: step_word is the current item's word");
    } else {
        is($r->[2], undef, "$label: nothing current -> step_word undef");
    }
}

my @eight_done = map { "- [x] $_. Step$_" } 1 .. 8;

# --- a 9-step ledger -------------------------------------------------------
{
    my $r = pp(ledger(@eight_done, '- [ ] 9. Elevated verification handoff'));
    is($r->[0], '9/9', '9-step: 1-8 ticked, 9 pending -> step 9/9 (not 8/8)');
    is_deeply($r->[1], [9], '9-step: steps_pending == [9]');
    is($r->[2], 'elevated', '9-step: step_word names step 9');
    agrees($r, '9-step');
    is(scalar(@{ $r->[3] || [] }), 9, '9-step: nine items in the per-step list');

    my $r2 = pp(ledger(@eight_done, '- [x] 9. Elevated verification handoff'));
    is($r2->[0], '9/9', '9-step all ticked: 9/9');
    is_deeply($r2->[1], [], '9-step all ticked: steps_pending == []');
    is($r2->[2], undef, '9-step all ticked: no step word');

    my $r3 = pp(ledger('- [x] 01. Scout', '- [x] 2. Spec', '- [ ] 10. Tenth', '- [ ] 0. Zero', '- [ ] 100. Hundred'));
    is($r3->[0], '10/10', '1-99: "01." folds to 1, step 10 is read, 0 and 100 are not steps');
    is($r3->[2], 'tenth', '1-99: step 10 word');
}

# --- range entries ---------------------------------------------------------
{
    # The real z01-operator-signoff shape, with 1-2 ticked.
    my $r = pp(ledger('- [x] 1. Scout', "- [x] 2. Spec $EM N/A", '- [ ] 3-5. N/A', '- [ ] 6. N/A', '- [ ] 7. N/A', '- [ ] 8. UI pass'));
    is($r->[0], '3/8', 'range: a todo 3-5 entry is current -> 3/8 (the old reader skipped it and said 6/8)');
    is_deeply($r->[1], [3, 4, 5, 6, 7, 8], 'range: the todo range contributes 3, 4 and 5 to steps_pending');
    is($r->[2], 'na', 'range: the word of the range entry ("N/A" -> "na")');
    agrees($r, 'range');
    my ($rng) = grep { $_->{label} eq '3-5' } @{ $r->[3] || [] };
    ok($rng, 'range: one item labelled "3-5"');
    is_deeply($rng && $rng->{n}, [3, 4, 5], 'range: the item covers steps 3, 4 and 5');
    is(scalar(@{ $r->[3] || [] }), 6, 'range: six checkboxes -> six items');

    my $r2 = pp(ledger('- [x] 1. a', '- [x] 2. b', '- [x] 3-5. N/A', '- [ ] 6. f', '- [ ] 7. g', '- [ ] 8. h'));
    is($r2->[0], '6/8', 'range ticked: current moves past it to 6/8');
    is_deeply($r2->[1], [6, 7, 8], 'range ticked: 3-5 not pending');

    my $r3 = pp(ledger('- [ ] 1-3. Tail'));
    is($r3->[0], '1/3', 'range: the highest number in a range is the denominator');

    my $r4 = pp(ledger('- [x] 1. a', '- [ ] 5-3. backwards', '- [ ] 2. b'));
    is($r4->[0], '2/2', 'range: a descending A-B is not a step line');

    my $r5 = pp(ledger('- [x] 4. first', '- [ ] 3-5. overlap'));
    my ($ov) = grep { $_->{n}[0] == 3 } @{ $r5->[3] || [] };
    is_deeply($ov && $ov->{n}, [3, 5], 'range: a number already claimed by an earlier line is dropped from the range');
}

# --- [-] and [U+2014] marks -----------------------------------------------
{
    # The real 11-operator-visual-signoff shape: every step marked N/A.
    my $r = pp(ledger(map { "- [$EM] $_. Step $EM N/A, nothing to do" } 1 .. 8));
    is($r->[0], '8/8', 'em-dash marks: an all-N/A checklist is parseable (8/8), not undef');
    is_deeply($r->[1], [], 'em-dash marks: nothing pending');
    is($r->[2], undef, 'em-dash marks: nothing current');
    is_deeply([ map { $_->{state} } @{ $r->[3] || [] } ], [ ('na') x 8 ], 'em-dash marks: every item is na');

    my $r2 = pp(ledger('- [x] 1. a', '- [ ] 2. b', "- [$EM] 3. c"));
    is($r2->[0], '2/3', 'em-dash mark: a trailing N/A step still counts toward M');
    is_deeply($r2->[1], [2], 'em-dash mark: na is not pending');

    my $r3 = pp(ledger('- [-] 1. a', '- [ ] 2. Second'));
    is($r3->[0], '2/2', '[-] mark: na, so step 2 is current');
    is($r3->[2], 'second', '[-] mark: word of step 2');
    is($r3->[3] && $r3->[3][0]{state}, 'na', '[-] mark: state na');
    agrees($r3, '[-]');
}

# --- tick-step skip / n/a markers -----------------------------------------
{
    my $r = pp(ledger(
        "- [x] 1. Scout $EM skipped: scope is the initiative",
        "- [x] 2. Spec $EM n/a: doc package",
        "- [x] 3. Tests (if skipped $EM record the skip)",        # template em-dash
        "- [x] 4. Impl $EM skipped:",                             # no reason
        "- [x] 5. Valid $EM Skipped: wrong case",
        "- [x] 6. Review $EM record the skip $EM skipped: real reason",
        "- [x] 7. Fix ${EM}skipped: no space before keyword",
        "- [ ] 8. UI $EM skipped: unticked keeps todo",
    ));
    is_deeply([ map { $_->{state} } @{ $r->[3] || [] } ],
              [ qw(skipped na done done done skipped done todo) ],
              'markers: skipped / na read only from the exact " <em> skipped|n/a: <reason>" grammar on a ticked line');
    is($r->[0], '8/8', 'markers: skipped and na are settled, step 8 is current');
    is_deeply($r->[1], [8], 'markers: only the unticked step is pending');
    is($r->[2], 'ui', 'markers: step word unaffected by the marker');
    is($r->[3] && $r->[3][0]{word}, 'scout', 'markers: a skipped item keeps its first word');
}

# --- code fences, size limit, heading stop ---------------------------------
{
    my $r = pp(ledger('- [x] 1. a', '```', '# a shell comment', '- [ ] 2. fake', '```', '- [ ] 2. Real', '- [ ] 3. c'));
    is($r->[0], '2/3', 'fence: a "#" line inside a fence does not truncate the scan');
    is($r->[2], 'real', 'fence: a fenced checkbox lookalike is not a step (the real step 2 is current)');
    agrees($r, 'fence');

    my $long = '- [ ] 2. ' . ('a' x 1100);
    my $r2 = pp(ledger('- [x] 1. a', $long, '- [ ] 3. Third'));
    is($r2->[0], '3/3', 'size: a line over 1024 bytes is skipped');
    is($r2->[2], 'third', 'size: and its word is never read');

    my $r3 = pp("## Pipeline\n- [x] 1. a\n## Other\n- [ ] 2. b\n");
    is($r3->[0], '1/1', 'heading: the scan stops at the next heading');
    my $r4 = pp("\xEF\xBB\xBF## Pipeline\r\n- [x] 1. a\r\n- [ ] 2. Bee\r\n");
    is($r4->[2], 'bee', 'BOM + CRLF tolerated');
}

# --- no checklist ----------------------------------------------------------
{
    for my $c ([ 'undef', undef ], [ 'empty', '' ], [ 'no heading', "# x\n- [ ] 1. a\n" ],
               [ 'heading, no boxes', ledger('just prose') ], [ 'garbage marks', ledger('- [?] 1. a', '- [ ]1 no dot') ]) {
        my ($label, $blob) = @$c;
        my $r = pp($blob);
        is($r->[0], undef, "no checklist [$label]: step undef");
        is($r->[1], undef, "no checklist [$label]: steps_pending undef");
        is($r->[2], undef, "no checklist [$label]: step_word undef");
        is($r->[3], undef, "no checklist [$label]: pipeline undef");
    }
}

# --- the per-step list in the package facts --------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/packages");
    my $blob = ledger('- [x] 1. Scout', "- [x] 2. Spec $EM n/a: doc", '- [ ] 3-5. N/A', "- [$EM] 6. Review", '- [ ] 9. Elevated handoff');
    open my $fh, '>:raw', "$root/packages/p1.md" or die "write: $!";
    print $fh $blob;
    close $fh;
    my ($l) = probe_list('_ledger_facts', $root, 'p1');
    my $f = $l->[0];
    ok(ref($f) eq 'HASH', 'facts: _ledger_facts returns a hash');
    is_deeply($f->{pipeline}, [
        { n => [1],       label => '1',   word => 'scout',    state => 'done' },
        { n => [2],       label => '2',   word => 'spec',     state => 'na'   },
        { n => [3, 4, 5], label => '3-5', word => 'na',       state => 'todo' },
        { n => [6],       label => '6',   word => 'review',   state => 'na'   },
        { n => [9],       label => '9',   word => 'elevated', state => 'todo' },
    ], 'facts: pipeline is the data-only per-item list, ascending');
    is($f->{step}, '3/9', 'facts: step 3/9');
    is_deeply($f->{steps_pending}, [3, 4, 5, 9], 'facts: steps_pending');
    is($f->{step_word}, 'na', 'facts: step_word is the same item');

    my ($l2) = probe_list('_ledger_facts', $root, 'nosuch');
    ok(exists($l2->[0]{pipeline}) && !defined($l2->[0]{pipeline}), 'facts: a missing ledger has pipeline undef');
}

done_testing();
