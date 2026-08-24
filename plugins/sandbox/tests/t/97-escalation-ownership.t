#!/usr/bin/env perl
# 97-escalation-ownership.t — "needs you" means the operator, not the queue.
#
# WHAT IS BEING PROTECTED
#
# The dashboard's `needs you` row counted every live record in runs/needs-you/.
# Most of those are not the operator's: each carries a `category`, and only two
# of the seven (product, operator-action) are ones bp-resolve.pl may never
# decide. The rest go to the escalation resolver, which acts or re-tags them
# without waking anybody.
#
# So the row asserted ownership over a queue it had never looked inside. The
# operator saw "needs you: 1 decision waiting" with nothing whatsoever waiting on
# them -- reported verbatim as "the TUI for GSA says 'needs you: 1 decision
# waiting' despite the agent that was working on it doesn't really have anything
# that needs my attention?".
#
# t07 already fixed one half of this: a record whose package is done is settled
# and stops being counted. This is the other half — a record that is genuinely
# live, but is not YOURS.
#
# THE DEFAULT STAYS THE OPERATOR. RunState's own header states the asymmetry: a
# decision wrongly kept is a panel that nags, a decision wrongly dropped is a
# human who is never asked. So every unreadable, missing or unrecognised
# category counts as operator-owned — and that is not merely caution, it is
# correct: bp-orchestrator.pl's resolver dispatch filters on exactly the
# triageable set, so a record with an unrecognised category is one no agent will
# ever look at again.
#
# Runs standalone: perl plugins/sandbox/tests/t/97-escalation-ownership.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

use lib "$Bin/../../scripts";
require RunState;

my $J = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# A. decision_operator_owned — the classifier itself.
# ---------------------------------------------------------------------------
{
    # Only a human clears these.
    is(RunState::decision_operator_owned({ category => 'product' }), 1,
       'A1: product is operator-owned');
    is(RunState::decision_operator_owned({ category => 'operator-action' }), 1,
       'A2: operator-action is operator-owned');
    is(RunState::decision_operator_owned({ category => 'operational' }), 1,
       'A3: the LEGACY spelling is still operator-owned — records queued before the rename '
     . 'are still on disk and must not silently change hands');

    # An agent is expected to triage these.
    for my $c (qw(unclassified conformance oracle scoping implementation)) {
        is(RunState::decision_operator_owned({ category => $c }), 0,
           "A4[$c]: a resolver-triageable category is NOT the operator's");
    }

    # Everything ambiguous falls toward the operator.
    is(RunState::decision_operator_owned({}), 1,
       'A5: a record with NO category is operator-owned — nothing will ever triage it, because '
     . 'the resolver dispatch filters on the triageable set');
    is(RunState::decision_operator_owned({ category => 'wat' }), 1,
       'A6: an unrecognised category is operator-owned, for the same reason');
    is(RunState::decision_operator_owned({ category => '' }), 1,
       'A7: an empty category is operator-owned');
    is(RunState::decision_operator_owned({ category => {} }), 1,
       'A8: a ref where a string belongs is operator-owned, never a crash');
    is(RunState::decision_operator_owned(undef), 1,
       'A9: an unreadable record is operator-owned');
    is(RunState::decision_operator_owned('nonsense'), 1,
       'A10: a non-hashref is operator-owned');
}

# ---------------------------------------------------------------------------
# B. THE RULE, not the instance: RunState's triageable list must equal the one
#    bp-orchestrator.pl actually dispatches on. The list is duplicated because a
#    sandbox module must not require a butler script — this is what stops the
#    copy drifting.
# ---------------------------------------------------------------------------
{
    my $orch = "$Bin/../../../butler/scripts/bp-orchestrator.pl";
  SKIP: {
        skip 'bp-orchestrator.pl not present', 2 unless -f $orch;
        my $src = do { local (@ARGV, $/) = ($orch); <> };
        my ($list) = $src =~ /our\s+\@RESOLVER_TRIAGEABLE\s*=\s*qw\(([^)]*)\)/;
        ok(defined $list, 'B0: BpOrch::@RESOLVER_TRIAGEABLE is parseable')
            or skip 'cannot parse the butler list; B1 would be vacuous', 1;
        my @theirs = sort grep { length } split /\s+/, $list;
        my @ours   = sort @RunState::TRIAGEABLE_CATEGORIES;
        is_deeply(\@ours, \@theirs,
            'B1: RunState\'s triageable list equals the one the orchestrator dispatches on — '
          . 'if these drift, the panel and the resolver disagree about who owns a record')
            or diag("ours: @ours\ntheirs: @theirs");
    }
}

# ---------------------------------------------------------------------------
# C. End to end through summarize(): a queue holding both kinds is split, and
#    the old total is preserved.
# ---------------------------------------------------------------------------
sub write_json { my ($p, $d) = @_; open my $fh, '>:raw', $p or die $!; print {$fh} $J->encode($d); close $fh }

{
    my $root = tempdir(CLEANUP => 1);
    my $bp   = "$root/demo";
    make_path("$bp/runs/needs-you");
    make_path("$bp/packages");

    # A live package, so nothing below is skipped as settled by t07's rules.
    open my $pk, '>:raw', "$bp/packages/p1.md" or die $!;
    print {$pk} "---\npackage: p1\nstatus: running\n---\n\n# p1\n";
    close $pk;
    write_json("$bp/runs/registry.json", { packages => { p1 => { status => 'running' } } });

    write_json("$bp/runs/needs-you/p1--a1.json", { package => 'p1', kind => 'reauth',    category => 'operator-action' });
    write_json("$bp/runs/needs-you/p1--a2.json", { package => 'p1', kind => 'stuck',     category => 'product' });
    write_json("$bp/runs/needs-you/p1--b1.json", { package => 'p1', kind => 'starved',   category => 'unclassified' });
    write_json("$bp/runs/needs-you/p1--b2.json", { package => 'p1', kind => 'conform',   category => 'conformance' });
    write_json("$bp/runs/needs-you/p1--b3.json", { package => 'p1', kind => 'scope',     category => 'scoping' });

    my $runs = RunState::summarize($root);
    ok(ref($runs) eq 'ARRAY' && @$runs, 'C0: summarize returned a run') or BAIL_OUT('no summary');
    my ($s) = grep { ($_->{blueprint} // '') eq 'demo' } @$runs;
    ok($s, 'C1: the demo blueprint is in the summary') or BAIL_OUT('missing');

    is($s->{decisions_operator}, 2,
       'C2: exactly the two operator-owned records are counted as needing the operator');
    is($s->{decisions_triage}, 3,
       'C3: the three triageable records are counted separately — VISIBLE, not hidden, because '
     . 'the resolver can be capped or unwired and then nothing moves');
    is($s->{decisions_waiting}, 5,
       'C4: decisions_waiting still reports the TOTAL, so every existing consumer keeps the '
     . 'number it has always had');
    is($s->{decisions_operator} + $s->{decisions_triage}, $s->{decisions_waiting},
       'C5: the split is exhaustive — no record falls out of both halves');
}

# ---------------------------------------------------------------------------
# D. Counter-fixture: a queue of ONLY triageable records reports zero for the
#    operator. This is the exact case the operator saw as "1 decision waiting".
# ---------------------------------------------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $bp   = "$root/quiet";
    make_path("$bp/runs/needs-you");
    make_path("$bp/packages");
    open my $pk, '>:raw', "$bp/packages/p1.md" or die $!;
    print {$pk} "---\npackage: p1\nstatus: running\n---\n\n# p1\n";
    close $pk;
    write_json("$bp/runs/registry.json", { packages => { p1 => { status => 'running' } } });
    write_json("$bp/runs/needs-you/p1--only.json", { package => 'p1', kind => 'starved', category => 'unclassified' });

    my $runs = RunState::summarize($root);
    my ($s) = grep { ($_->{blueprint} // '') eq 'quiet' } @{ $runs || [] };
    ok($s, 'D0: the quiet blueprint is in the summary') or BAIL_OUT('missing');
    is($s->{decisions_operator}, 0,
       'D1: a queue holding only triageable records needs the operator ZERO times — the exact '
     . 'state that used to render "needs you: 1 decision waiting"');
    is($s->{decisions_triage}, 1, 'D2: ...and the record is still counted, under triage');
}

# ---------------------------------------------------------------------------
# E. The renderer reads the right field for the right row.
# ---------------------------------------------------------------------------
{
    require tui::DashboardScreen;
    my $lines = tui::DashboardScreen::panels({
        needs_you => 2, triage_queued => 3, cols => 100,
    }, 100);
    # panels() returns a list of PANELS, each { title, lines }, and each line is
    # a list of spans. Flatten all three levels -- an earlier version of this
    # test walked only two and produced an empty string, which made E3's
    # `unlike` pass for the wrong reason. Assert non-emptiness so that cannot
    # recur silently.
    my $flat = '';
    if (ref($lines) eq 'ARRAY') {
        for my $panel (@$lines) {
            next unless ref($panel) eq 'HASH' && ref($panel->{lines}) eq 'ARRAY';
            for my $l (@{ $panel->{lines} }) {
                next unless ref($l) eq 'ARRAY';
                $flat .= join('', map { ref($_) eq 'HASH' ? ($_->{text} // '') : '' } @$l) . "\n";
            }
        }
    }
    ok(length($flat) > 0,
       'E0: the panels rendered SOMETHING -- without this, E3\'s unlike() passes on an empty '
     . 'string and asserts nothing at all');
    like($flat, qr/needs you\s+2 decisions waiting/,
         'E1: the needs-you row renders the OPERATOR count');
    like($flat, qr/in triage\s+3 escalations with the resolver/,
         'E2: the triage count renders as its own row, so nothing vanishes from the panel');
    unlike($flat, qr/needs you\s+5 decisions/,
           'E3: the row does NOT render the total — that conflation is the defect');
}

done_testing();
