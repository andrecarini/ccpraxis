#!/usr/bin/env perl
# t/76-reporter-autonomy.t — oracle for b24-reporter-autonomy, derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b24-reporter-autonomy-spec.md
# (C1..C10, sec.5) and its two corrected ledger claims (sec.0): the blueprint has 71 packages,
# never 47, and NO count is pinned anywhere in this file; the prompt-cache TTL is a
# single-sourced named input the cap is DERIVED from, never "discovered" at runtime.
#
# WRITTEN BLIND TO THE IMPLEMENTATION. reporter/SKILL.md and orchestrator-protocol/SKILL.md
# carry none of the decide/escalate boundary, record, never-block, or widened-Cast language yet
# (verified pre-authoring, disk 2026-08-03); bp-wait-for-decision.pl has no cadence/idle/table
# logic at all. Every assertion below is expected to fail on MISSING GUIDANCE / MISSING CODE,
# never on a Perl exception, a missing module, or a bad require path.
#
# PINNED INTERFACE (spec sec.2/3/4 describe *behaviour*, not a call surface; this oracle names
# the surface, the same way t/81's C5 pins BpGovern::immediate_pause_trigger). Because the write
# set's only code file is bp-wait-for-decision.pl, that is where these land, in package BpWait:
#   BpWait::cadence_cap_minutes($ttl_minutes)      -> cap, DERIVED as $ttl_minutes - margin
#   BpWait::resolve_cadence_minutes(\%opts)        -> { minutes, clamped } ; opts: requested_min,
#                                                      reason, ttl_min (default 60)
#   BpWait::blueprint_terminal(\@packages)         -> bool (I1)
#   BpWait::all_awaiting_decision(\@packages)      -> bool (I2)
#   BpWait::watcher_armed(\@packages)              -> bool (NOT I1 and NOT I2)
#   BpWait::progress_table(\@packages)             -> { done_count => N, rows => [ {id,status} ] }
#   BpWait::classify_decision(\%case)              -> 'escalate' | 'decide'
#   BpWait::autonomous_decision_record(\%case)     -> record hashref, or undef if 'escalate'
# Every call site below is wrapped in eval{} so a missing sub fails its own assertion (absence of
# implementation) rather than dying and aborting the rest of this file.
#
# C10 is a validation command, not re-implemented here:
#   perl plugins/butler/tests/t/12-wait-for-decision.t     # must stay green (58/58 from disk 2026-08-03)
#
# Package statuses used in fixtures below ('done'/'dropped' terminal; 'blocked'/'parked' = parked
# awaiting a queued human decision; 'pending'/'running' = genuinely in flight) are the existing
# vocabulary already used by bp-judge.pl/bp-orchestrator.pl (grepped from disk), not invented here.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $WAIT_SCRIPT = "$Bin/../../scripts/bp-wait-for-decision.pl";
require $WAIT_SCRIPT;

my $REPORTER_SKILL = "$Bin/../../skills/reporter/SKILL.md";
my $PROTOCOL_SKILL = "$Bin/../../skills/orchestrator-protocol/SKILL.md";

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    binmode $fh;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $reporter_src = slurp($REPORTER_SKILL);
my $protocol_src = slurp($PROTOCOL_SKILL);

ok(defined $reporter_src && length $reporter_src, "subject exists and is non-empty: $REPORTER_SKILL");
ok(defined $protocol_src && length $protocol_src, "subject exists and is non-empty: $PROTOCOL_SKILL");
$reporter_src //= '';
$protocol_src //= '';

# Flattened copies with markdown emphasis markers stripped, used for every substance regex
# below -- so e.g. "does **not** run a monitoring loop" still matches /does\s+not\s+run/ instead
# of every such pattern having to hand-tolerate `\*{0,2}` at each word boundary.
(my $reporter_flat = $reporter_src) =~ s/\*+//g;
(my $protocol_flat = $protocol_src) =~ s/\*+//g;

# Extract the text from the first literal "E1" marker up to (not incl.) the next `## `/`### `
# heading, or EOF. Scopes the boundary assertions to the boundary section as the spec demands
# ("a bare keyword match over the whole file can hit unrelated prose") without depending on
# guessing the implementer's exact heading wording.
sub section_from_E1 {
    my ($text) = @_;
    return undef unless $text =~ /\bE1\b/;
    my $rest = substr($text, $-[0]);
    if ($rest =~ /\n#{2,3}\s/) {
        return substr($rest, 0, $-[0]);
    }
    return $rest;
}

my $boundary = section_from_E1($reporter_flat);

# =====================================================================================
# C1 — the decide/escalate boundary, with all three escalation classes stated concretely
# enough to classify a case. Scoped to the extracted boundary section, not the whole file.
# =====================================================================================
{
    ok(defined $boundary, "C1 [$REPORTER_SKILL]: a boundary section anchored at a literal 'E1' marker exists")
        or diag("no 'E1' marker found in $REPORTER_SKILL -- expected pre-implementation");
    my $b = $boundary // '';

    ok(length($b) > 200,
        'C1 VACUITY GATE: the extracted boundary section is substantial prose, not a bare heading/one-liner');

    like($b, qr/\bE2\b/, "C1 [$REPORTER_SKILL]: boundary section names E2");
    like($b, qr/\bE3\b/, "C1 [$REPORTER_SKILL]: boundary section names E3");

    # E1 — irreversible/destructive, naming accept/drop concretely.
    like($b, qr/irreversible/i, "C1 [$REPORTER_SKILL]: E1 states 'irreversible'");
    like($b, qr/destructive/i, "C1 [$REPORTER_SKILL]: E1 states 'destructive'");
    like($b, qr/\baccept\b/, "C1 [$REPORTER_SKILL]: E1 names the concrete action `accept`");
    like($b, qr/\bdrop\b/,   "C1 [$REPORTER_SKILL]: E1 names the concrete action `drop`");

    # E2 — contradicts a recorded operator ruling.
    like($b, qr/contradict/i, "C1 [$REPORTER_SKILL]: E2 states 'contradicts'");
    like($b, qr/(recorded|SYN|ledger|Out-of-scope)/i,
        "C1 [$REPORTER_SKILL]: E2 names a recorded-ruling source (SYN / ledger / Out-of-scope)");

    # E3 — not groundable in disk evidence.
    like($b, qr/disk evidence/i, "C1 [$REPORTER_SKILL]: E3 states 'disk evidence'");
    like($b, qr/(not\s+groundable|cannot\s+ground|no\s+evidence)/i,
        "C1 [$REPORTER_SKILL]: E3 states the ungroundable condition concretely");

    # The disjunction-evaluated-first ordering is the safety property (spec 1.2/§5 C1).
    like($b, qr/(disjunction|evaluated first|any one|regardless)/i,
        "C1 [$REPORTER_SKILL]: states the three classes are evaluated as a disjunction FIRST");
}

# =====================================================================================
# C2 — classification behaves correctly on fixtures (pinned BpWait::classify_decision).
# VACUITY GATE: the decide case must actually decide -- an implementation that escalates
# everything must fail the last assertion in this block.
# =====================================================================================
{
    my $e1_case = { action_kind => 'accept', contradicts_recorded_ruling => 0,
                     groundable_in_disk_evidence => 1, clearly_better_option => 1 };
    my $v1 = eval { BpWait::classify_decision($e1_case) };
    diag("BpWait::classify_decision error: $@") if $@;
    is($v1, 'escalate', 'C2: an accept/drop-shaped decision escalates (E1)')
        or diag('expected pre-implementation: sub is missing or misclassifies');

    my $e1b_case = { action_kind => 'drop', contradicts_recorded_ruling => 0,
                      groundable_in_disk_evidence => 1, clearly_better_option => 1 };
    my $v1b = eval { BpWait::classify_decision($e1b_case) };
    is($v1b, 'escalate', 'C2: a drop-shaped decision escalates (E1)');

    my $e2_case = { action_kind => 'other', contradicts_recorded_ruling => 1,
                     groundable_in_disk_evidence => 1, clearly_better_option => 1 };
    my $v2 = eval { BpWait::classify_decision($e2_case) };
    is($v2, 'escalate', 'C2: a decision contradicting a recorded ruling escalates (E2)');

    my $e3_case = { action_kind => 'other', contradicts_recorded_ruling => 0,
                     groundable_in_disk_evidence => 0, clearly_better_option => 1 };
    my $v3 = eval { BpWait::classify_decision($e3_case) };
    is($v3, 'escalate', 'C2: a decision with no disk evidence escalates (E3)');

    my $decide_case = { action_kind => 'other', contradicts_recorded_ruling => 0,
                         groundable_in_disk_evidence => 1, clearly_better_option => 1 };
    my $vd = eval { BpWait::classify_decision($decide_case) };
    is($vd, 'decide',
        'C2 VACUITY GATE: a clear-better-option decision with none of E1-E3 is DECIDED, not escalated')
        or diag('an implementation that escalates everything must fail this assertion');
}

# =====================================================================================
# C3 — E1 wins over obviousness: both clearly-better AND irreversible must escalate.
# =====================================================================================
{
    my $case = { action_kind => 'accept', contradicts_recorded_ruling => 0,
                 groundable_in_disk_evidence => 1, clearly_better_option => 1 };
    my $v = eval { BpWait::classify_decision($case) };
    is($v, 'escalate',
        'C3: a decision that is BOTH clearly-better AND irreversible (accept) still escalates -- E1 wins');
}

# =====================================================================================
# C4 — every self-made decision produces a durable, discoverable record. VACUITY GATE: no
# record exists when no autonomous decision was made.
# =====================================================================================
{
    my $decide_case = {
        action_kind => 'other', contradicts_recorded_ruling => 0,
        groundable_in_disk_evidence => 1, clearly_better_option => 1,
        reasoning       => 'the alternative required a protocol-forbidden hand-edit',
        disk_evidence   => "q04's ledger and SYN-20",
        cost_of_waiting => 'would have stalled all q04-dependent packages until the human returned',
    };
    is(eval { BpWait::classify_decision($decide_case) }, 'decide',
        'C4 FIXTURE-SANITY: the record fixture is itself a decide case');

    my $rec = eval { BpWait::autonomous_decision_record($decide_case) };
    diag("BpWait::autonomous_decision_record error: $@") if $@;
    ok(defined $rec, 'C4: a self-made decision produces a durable record')
        or diag('expected pre-implementation: sub is missing');
    SKIP: {
        # NO skip here, deliberately. Skipping when the record is missing would count
        # these four as PASSES precisely when the feature is absent -- the green-and-inert
        # trap that has already bitten three packages in this blueprint. If there is no
        # record, that IS the failure, so substitute an empty hash and let each field
        # assertion fail on its own terms.
        $rec = {} unless ref($rec) eq 'HASH';
        ok(defined $rec->{reasoning} && length $rec->{reasoning}, 'C4: record carries the reasoning');
        ok(defined $rec->{disk_evidence} && length $rec->{disk_evidence}, 'C4: record carries the disk evidence');
        ok(defined $rec->{cost_of_waiting} && length $rec->{cost_of_waiting}, 'C4: record carries what waiting would have cost');
        ok($rec->{awaiting_confirmation}, 'C4: record carries an awaiting-operator-confirmation marker');
    }

    my $escalate_case = { action_kind => 'accept', contradicts_recorded_ruling => 0,
                           groundable_in_disk_evidence => 1, clearly_better_option => 1,
                           reasoning => 'x', disk_evidence => 'y', cost_of_waiting => 'z' };
    is(eval { BpWait::classify_decision($escalate_case) }, 'escalate',
        'C4 FIXTURE-SANITY: the no-record fixture is itself an escalate case');
    my $rec2 = eval { BpWait::autonomous_decision_record($escalate_case) };
    ok(!defined $rec2,
        'C4 VACUITY GATE: no record exists when no autonomous decision was made (escalated case)')
        or diag('an implementation that always writes a record must fail this assertion');

    # Discoverability: the skill documents the record as durable/discoverable, not merely made.
    like($reporter_flat, qr/(durable|permanent)\W{0,40}\brecord\b/is,
        "C4 [$REPORTER_SKILL]: states the record is durable, not ephemeral");
    like($reporter_flat, qr/discoverable|operator can (review|check|find)|for the (user|operator) to (check|confirm)/i,
        "C4 [$REPORTER_SKILL]: states the record is discoverable by the operator on return");
    like($reporter_flat, qr/cost of waiting|what waiting would have cost/i,
        "C4 [$REPORTER_SKILL]: names 'cost of waiting' as part of the record");
    like($reporter_flat, qr/awaiting.{0,25}confirmation/i,
        "C4 [$REPORTER_SKILL]: names an awaiting-confirmation marker as part of the record");
}

# =====================================================================================
# C5 — never blocks on interactive input; human-only items accumulate and present as a batch.
# =====================================================================================
{
    like($reporter_flat, qr/\b(never\s+block|does\s+not\s+block)\b/i,
        "C5 [$REPORTER_SKILL]: states it never blocks");
    like($reporter_flat, qr/interactive input/i,
        "C5 [$REPORTER_SKILL]: names 'interactive input' as what it never blocks on");
    like($reporter_flat, qr/always\s+running\s+unattended/i,
        "C5 [$REPORTER_SKILL]: states the always-running-unattended assumption (spec 1.4)");
    like($reporter_flat, qr/\bbatch(?:ed|es)?\b/i,
        "C5 [$REPORTER_SKILL]: states human-only items are batched");
}

# =====================================================================================
# C6 — cadence: default 50; cap DERIVED from an injected TTL (change TTL -> cap changes);
# literal 55 is not the cap; a request above the cap is clamped; a shorter interval requires
# a recorded reason.
# =====================================================================================
{
    # Decisive derivation test: cap must equal ttl-5 for MULTIPLE distinct injected TTLs.
    # A hardcoded 55 passes at ttl=60 but fails at ttl=90/120 below.
    for my $ttl (60, 90, 120, 37) {
        my $cap = eval { BpWait::cadence_cap_minutes($ttl) };
        diag("BpWait::cadence_cap_minutes($ttl) error: $@") if $@;
        is($cap, $ttl - 5,
            "C6: cadence_cap_minutes($ttl) == $ttl-5 (derived, not hardcoded)")
            or diag('a hardcoded 55 fails this at every TTL except 60');
    }
    {
        my $cap60 = eval { BpWait::cadence_cap_minutes(60) };
        my $cap90 = eval { BpWait::cadence_cap_minutes(90) };
        isnt($cap60, $cap90,
            'C6: injecting a different TTL observably changes the cap (60->' . ($cap60//'undef')
            . ', 90->' . ($cap90//'undef') . ')');
    }

    # The literal 55 must not appear as the cap for the default TTL=60 fixture, checked
    # structurally: the sub body itself must not hardcode 55.
    my $src = do { open my $fh, '<', $WAIT_SCRIPT or die $!; local $/; <$fh> };
    my ($cap_body) = ($src =~ /sub\s+cadence_cap_minutes\s*\{(.*?)\n\}/s);
    if (defined $cap_body) {
        unlike($cap_body, qr/\b55\b/,
            'C6: cadence_cap_minutes body does not hardcode the literal 55');
    } else {
        fail('C6: cadence_cap_minutes sub body not found to inspect for a hardcoded 55 -- expected pre-implementation');
    }

    # Default is 50.
    my $default_res = eval { BpWait::resolve_cadence_minutes({}) };
    diag("BpWait::resolve_cadence_minutes error: $@") if $@;
    is(ref($default_res) eq 'HASH' ? $default_res->{minutes} : undef, 50,
        'C6: the default cadence is 50 minutes');

    # A request above the cap is clamped, not honoured.
    my $over = eval { BpWait::resolve_cadence_minutes({ requested_min => 999, ttl_min => 60 }) };
    is(ref($over) eq 'HASH' ? $over->{minutes} : undef, 55,
        'C6: a requested interval above the cap is clamped to the derived cap (55 for TTL=60)');
    ok((ref($over) eq 'HASH' ? $over->{clamped} : 0),
        'C6: the clamp is recorded (clamped=true), not silently honoured');

    # Shorter intervals permitted only with a recorded reason.
    my $short_with_reason = eval { BpWait::resolve_cadence_minutes(
        { requested_min => 20, reason => 'expects the next package to finish within minutes' }) };
    is(ref($short_with_reason) eq 'HASH' ? $short_with_reason->{minutes} : undef, 20,
        'C6: a shorter interval WITH a recorded reason is honoured as requested');

    my $short_no_reason = eval { BpWait::resolve_cadence_minutes({ requested_min => 20 }) };
    isnt(ref($short_no_reason) eq 'HASH' ? $short_no_reason->{minutes} : undef, 20,
        'C6: a shorter interval with NO recorded reason is not honoured as requested (not an unaccountable escape hatch)');
}

# =====================================================================================
# C7 — idle: no watcher armed under I1 (terminal) or I2 (all non-terminal awaiting decision),
# asserted SEPARATELY. Paired positive: a watcher IS armed when work is genuinely in flight.
# =====================================================================================
{
    # I1: blueprint terminal (every package done/dropped) -- no non-terminal packages at all.
    my $i1_pkgs = [
        { id => 'p1', status => 'done' },
        { id => 'p2', status => 'done' },
        { id => 'p3', status => 'dropped' },
    ];
    is(eval { BpWait::blueprint_terminal($i1_pkgs) } ? 1 : 0, 1,
        'C7 I1: blueprint_terminal is true when every package is done/dropped');
    is(eval { BpWait::watcher_armed($i1_pkgs) } ? 1 : 0, 0,
        'C7 I1: no watcher armed when the blueprint is terminal');

    # I2: every NON-terminal package is waiting on a queued decision (blocked/parked), mixed
    # with some done packages -- blueprint_terminal must be FALSE here (asserted separately
    # from I1: an implementation could satisfy I1's fixture while missing this one).
    my $i2_pkgs = [
        { id => 'p1', status => 'done' },
        { id => 'p2', status => 'blocked' },
        { id => 'p3', status => 'parked' },
    ];
    is(eval { BpWait::blueprint_terminal($i2_pkgs) } ? 1 : 0, 0,
        'C7 I2 FIXTURE-SANITY: this fixture is NOT blueprint-terminal (proves I2 is asserted separately from I1)');
    is(eval { BpWait::all_awaiting_decision($i2_pkgs) } ? 1 : 0, 1,
        'C7 I2: all_awaiting_decision is true when every non-terminal package is blocked/parked');
    is(eval { BpWait::watcher_armed($i2_pkgs) } ? 1 : 0, 0,
        'C7 I2: no watcher armed when every non-terminal package is waiting on a queued decision');

    # Paired positive gate: work genuinely in flight (a pending/running package present) ->
    # watcher IS armed. Rules out an implementation that never arms anything.
    my $live_pkgs = [
        { id => 'p1', status => 'done' },
        { id => 'p2', status => 'blocked' },
        { id => 'p3', status => 'running' },
    ];
    is(eval { BpWait::blueprint_terminal($live_pkgs) } ? 1 : 0, 0,
        'C7 PAIRED-POSITIVE FIXTURE-SANITY: live fixture is not terminal');
    is(eval { BpWait::all_awaiting_decision($live_pkgs) } ? 1 : 0, 0,
        'C7 PAIRED-POSITIVE FIXTURE-SANITY: live fixture is not all-awaiting-decision (one package is running)');
    is(eval { BpWait::watcher_armed($live_pkgs) } ? 1 : 0, 1,
        'C7 PAIRED POSITIVE: a watcher IS armed when work is genuinely in flight (the guard must not silence a live run)')
        or diag('an implementation that never arms anything would otherwise satisfy I1 and I2 trivially');
}

# =====================================================================================
# C8 — progress table: non-terminal packages listed individually with state; done packages
# collapsed to a summary. NO package-count assertion against the real corpus anywhere in this
# file -- only against this synthetic fixture, which is the property, not a snapshot.
# =====================================================================================
{
    my @synthetic = (
        (map { { id => "done-$_", status => 'done' } } (1 .. 6)),
        { id => 'wk-running', status => 'running' },
        { id => 'wk-blocked', status => 'blocked' },
        { id => 'wk-pending', status => 'pending' },
        { id => 'wk-parked',  status => 'parked' },
    );
    my $table = eval { BpWait::progress_table(\@synthetic) };
    diag("BpWait::progress_table error: $@") if $@;
    ok(ref($table) eq 'HASH', 'C8: progress_table returns a structured result')
        or diag('expected pre-implementation: sub is missing');

    SKIP: {
        # Same reasoning as C4: skipping on a missing table turns absence into passes.
        $table = {} unless ref($table) eq 'HASH';
        my $rows = $table->{rows} || [];
        my %row_by_id = map { $_->{id} => $_ } @$rows;

        my @done_rows = grep { defined $_->{status} && $_->{status} eq 'done' } @$rows;
        is(scalar(@done_rows), 0,
            'C8: done packages are NOT listed individually in rows (collapsed to a summary)');

        my @expected_individual = qw(wk-running wk-blocked wk-pending wk-parked);
        my @missing = grep { !exists $row_by_id{$_} } @expected_individual;
        is_deeply(\@missing, [],
            'C8: every non-terminal synthetic package is listed individually with its state');

        is($row_by_id{'wk-running'}{status}, 'running', 'C8: wk-running row carries its actual state');
        is($row_by_id{'wk-blocked'}{status}, 'blocked', 'C8: wk-blocked row carries its actual state');

        is($table->{done_count}, 6,
            'C8: done packages collapse to a count against THIS synthetic fixture (never the real corpus)');
    }
}

# =====================================================================================
# C9 — Cast in orchestrator-protocol/SKILL.md no longer describes the reporter as merely
# relaying, and STILL states it does not run a monitoring loop and does not drive the run.
# Both halves asserted.
# =====================================================================================
{
    my ($cast_row) = ($protocol_flat =~ /^(\|\s*reporter\s*\|.*)$/m);
    ok(defined $cast_row, "C9 [$PROTOCOL_SKILL]: the Cast table's reporter row is present")
        or diag('reporter row not found in the Cast table');
    my $row = $cast_row // '';

    # Invariant half (must NOT be damaged by the doctrine widening).
    like($row, qr/does\s+not\s+run\s+a\s+monitoring\s+loop/i,
        "C9 [$PROTOCOL_SKILL]: reporter row STILL states it does not run a monitoring loop");
    like($row, qr/does\s+not\s+drive\s+the\s+run/i,
        "C9 [$PROTOCOL_SKILL]: reporter row STILL states it does not drive the run");

    # Widened half: no longer merely "relays queued decisions" -- must carry autonomy vocabulary.
    like($row, qr/\b(resolv(?:e|es|ing)|decides?|autonom\w*)\b/i,
        "C9 [$PROTOCOL_SKILL]: reporter row carries autonomy/decision-resolving vocabulary, not just relaying");
    unlike($row, qr/relays\s+queued\s+decisions\s*\./i,
        "C9 [$PROTOCOL_SKILL]: reporter row is no longer summarised as bare 'relays queued decisions.'");
}

done_testing();
