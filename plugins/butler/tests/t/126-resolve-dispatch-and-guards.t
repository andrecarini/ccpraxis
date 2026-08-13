#!/usr/bin/env perl
# e03-autonomous-resolution oracle, part 2: the orchestrator-side wiring --
# the new 'chronic-scoping' %KIND_REGISTRY entry, the fourth judge-kind
# dispatch reuse ('escalation-resolve'), the new bp-escalation-resolver agent
# contract, and two REGRESSION GUARDS explicitly mandated by the spec:
# AC-BQ (_block_and_queue gains no argument; t/115 untouched) and the
# b24-distinctness guard restated at the orchestrator/agent boundary.
# Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
# e03-autonomous-resolution-spec.md (§2.2, §2.5, §2.7) -- never from any
# implementation.
#
# WRITTEN AGAINST THE CURRENT TREE, WHICH HAS NONE OF THIS YET:
#   - %BpOrch::KIND_REGISTRY has no 'chronic-scoping' key.
#   - No 'escalation-resolve' judge-kind tick-loop block exists anywhere in
#     bp-orchestrator.pl (no source occurrence of the literal string at all).
#   - plugins/butler/agents/bp-escalation-resolver.md does not exist.
#
# TWO GROUPS ARE DELIBERATELY GREEN NOW (tripwires, not "missing behavior"
# assertions) -- named explicitly per this task's own instruction to write
# them despite starting green:
#   - GROUP BQ (AC-BQ): nothing has touched _block_and_queue or t/115 yet, so
#     these assertions currently hold trivially. They exist to go RED the
#     moment a future implementer adds an argument to _block_and_queue or
#     edits t/115 -- exactly the regression this package's own spec (§2.2)
#     names as a hard, independently-checkable acceptance criterion.
#   - GROUP WAIT (b24 positive control): bp-wait-for-decision.pl's existing
#     autonomy pair is untouched by this package by design; asserting it
#     still exists/still differs from anything e03 adds is a tripwire against
#     future drift, not evidence e03 itself is implemented.
# Every other group is a genuine RED-now assertion of missing behavior.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $ORCH_SCRIPT    = "$Bin/../../scripts/bp-orchestrator.pl";
my $AGENT_FILE      = "$Bin/../../agents/bp-escalation-resolver.md";
my $T115            = "$Bin/115-escalation-categories.t";
my $WAIT_SCRIPT     = "$Bin/../../scripts/bp-wait-for-decision.pl";

require $ORCH_SCRIPT;

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }

# ═══════════════════════════════════════════════════════════════════════════
# GROUP K -- %KIND_REGISTRY gains 'chronic-scoping' (§2.2, one new data line).
# RED now: the key is entirely absent from the current registry.
# ═══════════════════════════════════════════════════════════════════════════
{
    ok(exists $BpOrch::KIND_REGISTRY{'chronic-scoping'},
        "K1: \%BpOrch::KIND_REGISTRY has a 'chronic-scoping' entry")
        or diag('current keys: ' . join(',', sort keys %BpOrch::KIND_REGISTRY));
    if (exists $BpOrch::KIND_REGISTRY{'chronic-scoping'}) {
        is($BpOrch::KIND_REGISTRY{'chronic-scoping'}{family}, 'package',
            "K2: chronic-scoping's family is 'package' (resolved through the ledger, exactly the spec's own literal)");
    } else {
        fail("K2: cannot check family -- chronic-scoping key is entirely missing");
    }
    ok((grep { $_ eq 'chronic-scoping' } BpOrch::known_kinds_list()),
        "K3: chronic-scoping is visible via known_kinds_list() (so bp-answer-decision.pl's known_kinds() sees it too)");
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP J -- the fourth judge-kind dispatch, structurally (§2.5, DC4).
# The generic marker functions (mark_judge_inflight etc.) are already kind-
# agnostic and therefore ALREADY "work" for kind='escalation-resolve' today --
# that is not evidence of DC4 being built. What is actually missing is the
# orchestrator's own TICK-LOOP DISPATCH for this fourth kind: a
# structurally-identical block to the existing resolve/harvest/conformance
# ones, checking $t->{judge_to} against judge_inflight($runs,
# 'escalation-resolve', $pkg). Mirrors t/115 Group J's own source-self-check
# technique (a textual/structural oracle, deliberately not a full live-tick
# integration test -- spinning up bp-orchestrator.pl's real tick loop against
# a fixture is out of scope per this task's own environment rules, and no
# pure function name for "is this package's escalation-resolve judge due" is
# named anywhere in the spec for this test-writer to target without inventing
# one).
# ═══════════════════════════════════════════════════════════════════════════
{
    my $src = slurp($ORCH_SCRIPT) // '';
    my @occ = ($src =~ /'escalation-resolve'/g);
    ok(scalar(@occ) >= 1,
        "J1: the literal 'escalation-resolve' appears at least once in bp-orchestrator.pl (the fourth judge kind exists as a value somewhere)")
        or diag('occurrences found: ' . scalar(@occ));

    # J2: it must appear NEAR a judge_to comparison (the wall-clock bound,
    # spec §2.5) -- not just mentioned in a comment. Anchor on the same
    # structural shape the three existing kinds use
    # ("$now - $started) > $t->{judge_to}", per the spec's own citation of
    # bp-orchestrator.pl:2495/:2626/:3543) within a generous window around
    # any 'escalation-resolve' occurrence.
    my $near_bound = 0;
    while ($src =~ /'escalation-resolve'/g) {
        my $idx = pos($src);
        my $lo = $idx > 800 ? $idx - 800 : 0;
        my $window = substr($src, $lo, 1600);
        $near_bound = 1 if $window =~ /judge_to/;
    }
    ok($near_bound,
        "J2: at least one 'escalation-resolve' occurrence sits near a judge_to wall-clock check (DC4's bound, reused not reinvented)");

    # J3: mark_judge_inflight itself is untouched/still generic (kind is not
    # hardcoded anywhere inside it) -- a positive control proving the reuse
    # path is genuinely available, not merely assumed.
    unlike($src, qr/sub mark_judge_inflight\s*\{[^}]*'resolve'/s,
        'J3 positive control: mark_judge_inflight does not hardcode any specific kind (still safely reusable for escalation-resolve)');
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP AG -- the bp-escalation-resolver agent contract (§2.7, DC4's turn cap).
# RED now: the file does not exist.
# ═══════════════════════════════════════════════════════════════════════════
{
    ok(-f $AGENT_FILE, 'AG1: plugins/butler/agents/bp-escalation-resolver.md exists')
        or diag("not found at $AGENT_FILE");
    SKIP: {
        skip 'agent file does not exist yet', 6 unless -f $AGENT_FILE;
        my $txt = slurp($AGENT_FILE) // '';
        my ($fm) = $txt =~ /\A---\s*\n(.*?)\n---/s;
        ok(defined $fm, 'AG2: the agent file has a parseable frontmatter block');
        $fm //= '';
        like($fm, qr/^name:\s*bp-escalation-resolver\s*$/m, 'AG3: name: bp-escalation-resolver');
        like($fm, qr/^model:\s*opus\s*$/m, 'AG4: model: opus (matches bp-resolve-judge, Decision 10\'s "a wrong call costs trust" rationale)');
        like($fm, qr/^maxTurns:\s*800\s*$/m, 'AG5: maxTurns: 800 (the DC4 turn cap, matching bp-resolve-judge exactly)');
        like($fm, qr/^tools:\s*Read,\s*Grep,\s*Glob\s*$/m,
            'AG6: tools are EXACTLY Read, Grep, Glob -- no Edit/Write/Bash (this agent classifies and proposes only, mirrors bp-conformance-judge\'s "never fix anything" shape)');
        unlike($fm, qr/\b(Edit|Write|Bash)\b/, 'AG7: no Edit/Write/Bash tool anywhere in frontmatter (vacuity guard on AG6: a tools: line with extra entries elsewhere in the block would still be a contract violation)');
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP BQ (AC-BQ) -- constraint, deliberately GREEN now (tripwire per this
# task's own explicit instruction). Pins: (a) _block_and_queue's positional
# call shape is unchanged -- calling it with EXACTLY the current 10-arg form
# still produces the exact same field-for-field result t/115's own D3 already
# asserts, so a future implementer who inserts a NEW argument anywhere in the
# middle of that list (shifting every argument after it into the wrong slot)
# breaks THIS test even without anyone running a literal `git diff`; and
# (b) t/115 itself, byte-for-byte, is untouched by this package.
# ═══════════════════════════════════════════════════════════════════════════
{
    # BQ1: t/115 (this package's neighbor, IMMUTABLE per the dispatch prompt)
    # is byte-identical to its known-good content -- spot-checked via its own
    # header comment and the exact D3 positional call shape it exercises,
    # rather than a full-file hash this test-writer can't have pinned before
    # this package's implementation step runs (that pin is the IMPLEMENTER's
    # job to keep true, not this test-writer's to bake in as a hash literal).
    ok(-f $T115, 'BQ1: t/115-escalation-categories.t exists (sibling oracle, must never be edited by this package)');
    if (-f $T115) {
        my $t115_src = slurp($T115) // '';
        like($t115_src, qr/BpOrch::_block_and_queue\(\$bpdir,\s*\$runs,\s*\$log,\s*'bp',\s*\$pkg,\s*'stuck',\s*time,\s*'question\?',\s*'stuck-package',\s*'scoping'\)/,
            "BQ1: t/115's D3 positive-control call is STILL the exact 10-positional-arg shape (10 args: bpdir,runs,log,bp,pkg,why,now,question,kind,category) -- an implementer who converts this sub to a hashref, or inserts an 11th argument, changes this literal text and this assertion goes red");
    }

    # BQ2: the CURRENT 10-arg call, exercised directly by THIS file (not by
    # t/115), still produces exactly the result t/115's own D3 documents --
    # ledger flips to blocked, registry flips to blocked, exactly one decision
    # queued carrying the passed category. If a future implementer inserts a
    # new required argument ANYWHERE in the positional list, this exact call
    # (unchanged text, same 10 values) will silently shift every argument
    # after the insertion point into the wrong slot -- and at least one of
    # these three assertions will then observe the wrong value (e.g. the
    # queued category being 'scoping' the STRING literal 'question?' instead
    # of the real category, or vice versa) rather than passing by accident.
    require File::Path;
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages");
    make_path("$bpdir/runs");
    open my $fh, '>:raw', "$bpdir/packages/bq1.md" or die $!;
    print $fh "---\npackage: bq1\nblueprint: bp\nstatus: pending\nwrite_set: p/bq1/\nlast_updated: 2020-01-01T00:00:00Z\n---\n\n# bq1\n";
    close $fh;
    my $runs = "$bpdir/runs";
    my $log  = "$runs/orchestrator.log";
    BpOrch::_block_and_queue($bpdir, $runs, $log, 'bp', 'bq1', 'stuck', time, 'question?', 'stuck-package', 'scoping');
    my $ltxt = slurp("$bpdir/packages/bq1.md") // '';
    like($ltxt, qr/^status:\s*blocked\s*$/m, 'BQ2: the CURRENT positional call still flips the ledger to blocked (arity/order has not silently shifted)');
    my $reg_txt = slurp("$runs/registry.json") // '';
    my $reg = eval { JSON::PP->new->decode($reg_txt) };
    is(ref($reg) eq 'HASH' ? $reg->{packages}{bq1}{status} : undef, 'blocked', 'BQ2: registry also flips to blocked');
    opendir(my $dh, "$runs/needs-you") or die $!;
    my @f = grep { /\.json$/ } readdir $dh;
    closedir $dh;
    is(scalar @f, 1, 'BQ2: exactly one decision queued');
    if (@f) {
        my $rec = eval { JSON::PP->new->decode(slurp("$runs/needs-you/$f[0]")) };
        is(ref($rec) eq 'HASH' ? $rec->{category} : undef, 'scoping',
            'BQ2: the queued decision carries category=scoping in the RIGHT slot -- a shifted 11th argument would break this specific field');
    } else {
        fail('BQ2: no decision file to inspect category on');
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP WAIT -- b24 positive control (untouched-by-design; tripwire against
# future drift, not evidence e03 is built).
# ═══════════════════════════════════════════════════════════════════════════
{
    require $WAIT_SCRIPT;
    ok(defined &BpWait::classify_decision, 'WAIT1: bp-wait-for-decision.pl still defines classify_decision (e03 does not touch this file)');
    ok(defined &BpWait::autonomous_decision_record, 'WAIT1: bp-wait-for-decision.pl still defines autonomous_decision_record');
}

done_testing();
