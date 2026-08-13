#!/usr/bin/env perl
# e03-autonomous-resolution oracle, part 1: BpResolve's PURE gates
# (verdict_shape_ok / verdict_in_bounds / confidence_gate / chronic_scoping_bump)
# and its deterministic apply-step (apply_verdict), plus the --digest CLI.
# Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
# e03-autonomous-resolution-spec.md (§2.1, §2.6) and e01's worked Decision-5
# fixtures (e01 spec §4/§4.1) -- never from any implementation.
#
# WRITTEN AGAINST THE CURRENT TREE, WHICH HAS NONE OF THIS YET:
#   - plugins/butler/scripts/bp-resolve.pl does not exist at all (confirmed,
#     scout report + this test-writer's own re-check immediately before
#     writing this file).
#   - No BpResolve package, no verdict_shape_ok/verdict_in_bounds/
#     confidence_gate/apply_verdict/chronic_scoping_bump subs anywhere.
#   - No runs/resolved-escalations/ directory concept exists anywhere in
#     bp-orchestrator.pl or bp-answer-decision.pl.
# Every group below is wrapped in run_group() so a missing bp-resolve.pl
# produces ONE clearly-labelled failing assertion per group (the require
# error, verbatim) rather than a single opaque script-wide die -- this keeps
# the criterion->assertion mapping legible even while the whole file is red
# for the single, correct reason: the deliverable does not exist yet.
#
# VACUITY GUARDS, stated up front so a reviewer can check each is honoured:
#   - Every REFUSE assertion is paired with a matching POSITIVE control using
#     the same category/action but the one changed field that should flip the
#     outcome (e.g. conformance+relaunch passes, conformance+accept refused --
#     never just "accept is refused" in isolation, which a
#     category-independent global ban on the STRING 'accept' could fake).
#   - AC2(a) is tested as an ORDER/FAILURE-COUPLING test, not a presence-only
#     test: the archive directory is pre-occupied by a plain FILE (forcing the
#     archive write to fail deterministically, cross-platform, without relying
#     on chmod semantics Windows does not honour), then we assert the QUEUE
#     FILE SURVIVES BYTE-IDENTICAL -- an implementation that unlinks first and
#     archives second would delete the queue file even though the archive
#     write failed, and this test would catch exactly that inversion.
#   - AC2(b)/provenance is tested with a POSITIVE marker equality check
#     (resolved_by eq the specific agent name), not merely "the key exists" --
#     a naive stamp of resolved_by => 1 or '' would fail this.
#   - Decision-5 fixtures (A3/A4) assert the record STAYS QUEUED (no archive,
#     file present) -- pairing the negative (no archive) with the positive
#     (queue file unchanged in its non-additive fields) so a resolver that
#     silently drops the record instead of tagging it cannot pass by accident.
#   - Fixture names are neutral ('alpha', 'blk9', 'e5') per the spec's own
#     named landmine -- never containing the substrings 'product' or
#     'resolved' where a test also matches on that substring in output.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();

my $ORCH_SCRIPT    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE_SCRIPT = "$Bin/../../scripts/bp-resolve.pl";
my $WAIT_SCRIPT     = "$Bin/../../scripts/bp-wait-for-decision.pl";

require $ORCH_SCRIPT;   # BpOrch -- already exists, load unconditionally

my $J = JSON::PP->new->canonical;

my $RESOLVE_LOADED = eval { require $RESOLVE_SCRIPT; 1 };
my $RESOLVE_ERR = $@;

sub run_group {
    my ($label, $code) = @_;
    my $ok = eval { $code->(); 1 };
    fail("$label -- group errored (setup/infra problem, not a per-assertion failure): $@") unless $ok;
}

# ═══════════════════════════════════════════════════════════════════════════
# Scaffolding
# ═══════════════════════════════════════════════════════════════════════════
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub read_json { my ($p) = @_; my $t = slurp($p); return undef unless defined $t; return eval { $J->decode($t) }; }

# A full, bp-ledger.pl-VALID package ledger -- required sections present (V5)
# so relaunch/widen-write-set dispatch through the real bp-answer-decision.pl
# CLI (which shells to bp-ledger.pl set-next-action / run_op) does not refuse
# on an incomplete fixture. This is a THROWAWAY File::Temp fixture, never a
# real blueprint.
sub mk_full_ledger_bp {
    my (%o) = @_;
    my $pkg    = $o{pkg}    // 'alpha';
    my $status = $o{status} // 'blocked';
    my $bpdir  = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages");
    make_path("$bpdir/runs");
    write_file("$bpdir/packages/$pkg.md",
          "---\npackage: $pkg\nblueprint: bp\nstatus: $status\nwrite_set: p/$pkg/\n"
        . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n"
        . "## Next action\n\nTBD.\n\n"
        . "## Decisions & attempt log\n\n"
        . "## Pipeline\n\n"
        . "## Outputs\n\n"
        . "## Escalation\n\n");
    return ($bpdir, $pkg);
}

sub ledger_status {
    my ($bpdir, $pkg) = @_;
    my $txt = slurp("$bpdir/packages/$pkg.md") // '';
    return ($txt =~ /^status:\s*(\S+)/m) ? $1 : undef;
}
sub ledger_write_set {
    my ($bpdir, $pkg) = @_;
    my $txt = slurp("$bpdir/packages/$pkg.md") // '';
    return ($txt =~ /^write_set:\s*(.*?)\s*$/m) ? $1 : undef;
}

# File a fixture queued decision via the REAL, already-tested BpOrch::queue_needs_you
# (not a hand-typed JSON file) so the record shape is exactly what production code
# produces. Returns ($decision_id, $path, \%rec_as_filed).
sub file_decision {
    my ($runs, %o) = @_;
    my $rec = {
        package    => $o{pkg}      // 'alpha',
        blueprint  => 'bp',
        kind       => $o{kind}     // 'stuck-package',
        question   => $o{question} // 'what should happen?',
        context    => $o{context}  // 'some context',
        created_at => $o{created_at} // time,
        category   => $o{category} // 'unclassified',
    };
    my $path = BpOrch::queue_needs_you($runs, $rec);
    die "file_decision: queue_needs_you failed" unless $path;
    (my $id = $path) =~ s{.*[\\/]}{}; $id =~ s/\.json$//i;
    my $filed = read_json($path);
    return ($id, $path, $filed);
}

sub decision_path { my ($runs, $id) = @_; return "$runs/needs-you/$id.json"; }
sub archive_path  { my ($runs, $id) = @_; return "$runs/resolved-escalations/$id.json"; }

# ═══════════════════════════════════════════════════════════════════════════
# GROUP V -- pure gates (AC3, §2.6)
# ═══════════════════════════════════════════════════════════════════════════
run_group('GROUP V (pure gates)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;

    # V1: shape_ok -- a well-formed product verdict (no action key at all).
    {
        my $v = { category => 'product', confidence => 'high', evidence => 'cites project rule' };
        my ($ok, $why) = BpResolve::verdict_shape_ok($v);
        ok($ok, 'V1: a product verdict with category+confidence+evidence and no action is shape_ok') or diag("why: " . ($why // '?'));
    }
    # V2: shape_ok -- a resolver-owned verdict with all five required keys.
    {
        my $v = { category => 'conformance', action => 'relaunch', confidence => 'high',
                   evidence => 'cites DC3', rationale => 'clear, bounded fix' };
        my ($ok, $why) = BpResolve::verdict_shape_ok($v);
        ok($ok, 'V2: a resolver-owned verdict with all 5 required keys is shape_ok') or diag("why: " . ($why // '?'));
    }
    # V3: shape_ok -- resolver-owned verdict MISSING rationale -> malformed.
    {
        my $v = { category => 'oracle', action => 'relaunch', confidence => 'high', evidence => 'cites DC1' };
        my ($ok, $why) = BpResolve::verdict_shape_ok($v);
        ok(!$ok, 'V3: a resolver-owned verdict missing rationale is NOT shape_ok');
        ok(defined $why && length $why, 'V3: verdict_shape_ok explains why (non-empty $why)');
    }
    # V4: confidence_gate -- product verdict CARRYING an action key is a shape
    # violation that downgrades the whole thing to 'refuse' (spec §2.6's own
    # explicit rule: product/operational must never also carry a mutation).
    {
        my $v = { category => 'product', action => 'relaunch', confidence => 'high', evidence => 'x' };
        is(BpResolve::confidence_gate($v), 'refuse',
            'V4: a product verdict that ALSO carries an action is refused, not silently tag-only\'d');
    }
    # V5: verdict_in_bounds -- resolver-owned category with an action OUTSIDE
    # the four-verb vocabulary is out of bounds.
    {
        my $v = { category => 'scoping', action => 'do-whatever-seems-right', confidence => 'high', evidence => 'x', rationale => 'y' };
        my ($ok, $why) = BpResolve::verdict_in_bounds($v);
        ok(!$ok, 'V5: an action outside {relaunch,widen-write-set,edit-depends-on,author-ledger} is out of bounds');
    }
    # V6: the accept/drop bright line -- refused for EVERY category, paired
    # with a positive control (same category, action=relaunch, passes) so the
    # refusal is proven action-specific, not a category-wide ban.
    for my $cat (qw(conformance oracle scoping implementation)) {
        my $bad  = { category => $cat, action => 'accept', confidence => 'high', evidence => 'x', rationale => 'y' };
        my $bad2 = { category => $cat, action => 'drop',   confidence => 'high', evidence => 'x', rationale => 'y' };
        my $good = { category => $cat, action => 'relaunch', confidence => 'high', evidence => 'x', rationale => 'y' };
        my ($ok_bad)  = BpResolve::verdict_in_bounds($bad);
        my ($ok_bad2) = BpResolve::verdict_in_bounds($bad2);
        my ($ok_good) = BpResolve::verdict_in_bounds($good);
        ok(!$ok_bad,  "V6: category=$cat + action=accept is unconditionally refused");
        ok(!$ok_bad2, "V6: category=$cat + action=drop is unconditionally refused");
        ok($ok_good,  "V6 positive control: category=$cat + action=relaunch is in bounds (accept/drop refusal is action-specific, not a $cat-wide ban)");
    }
    # V7: confidence_gate -- resolver-owned + confidence low -> refuse (a
    # CONTRACT VIOLATION per e01 §2.4, not a downgrade to tag-only/act).
    {
        my $v = { category => 'implementation', action => 'relaunch', confidence => 'low', evidence => 'x', rationale => 'y' };
        is(BpResolve::confidence_gate($v), 'refuse', 'V7: resolver-owned category + confidence=low is refused outright');
    }
    # V8: confidence_gate -- resolver-owned + high confidence but EMPTY evidence -> refuse.
    {
        my $v = { category => 'oracle', action => 'relaunch', confidence => 'high', evidence => '', rationale => 'y' };
        is(BpResolve::confidence_gate($v), 'refuse', 'V8: resolver-owned + confidence=high + empty evidence is refused (no citation, no act)');
    }
    # V9 positive control: resolver-owned + high + non-empty evidence + in-bounds action -> act.
    {
        my $v = { category => 'oracle', action => 'relaunch', confidence => 'high', evidence => 'cites DC3 precisely', rationale => 'y' };
        is(BpResolve::confidence_gate($v), 'act', 'V9 positive control: a fully-qualifying resolver-owned verdict resolves to act');
    }
    # V10: confidence_gate -- product, EVEN AT confidence=low, is tag-only (never act, never refuse
    # merely for being low-confidence -- product/operational categories are never actable regardless).
    {
        my $v = { category => 'product', confidence => 'low', evidence => '' };
        is(BpResolve::confidence_gate($v), 'tag-only', 'V10: a product verdict is tag-only regardless of confidence (never act; never spuriously refused)');
    }
    # V11: confidence_gate -- category='unclassified' as a FINAL verdict value
    # (never a legitimate terminal answer, e01 §2.1) falls to refuse by
    # elimination: not resolver-owned (not in the 4-category resolver set as
    # far as 'act' requires action+rationale which unclassified verdicts don't
    # carry) and not in {product,operational} for tag-only.
    {
        my $v = { category => 'unclassified', confidence => 'high', evidence => 'x' };
        is(BpResolve::confidence_gate($v), 'refuse',
            'V11: a verdict that (mis)uses unclassified as its OWN final category is refused, never acted on');
    }
});

# ═══════════════════════════════════════════════════════════════════════════
# GROUP C -- chronic_scoping_bump (pure counter step, §2.6, DC1's 'more than 2' rule)
# ═══════════════════════════════════════════════════════════════════════════
run_group('GROUP C (chronic_scoping_bump)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($after0, $fire0) = BpResolve::chronic_scoping_bump(0);
    is($after0, 1, 'C1: bump(0) -> count_after=1');
    ok(!$fire0, 'C1: bump(0) does not fire (1 is not > 2)');

    my ($after1, $fire1) = BpResolve::chronic_scoping_bump(1);
    is($after1, 2, 'C2: bump(1) -> count_after=2');
    ok(!$fire1, 'C2: bump(1) does not fire (2 is not > 2)');

    my ($after2, $fire2) = BpResolve::chronic_scoping_bump(2);
    is($after2, 3, 'C3: bump(2) -> count_after=3');
    ok($fire2, 'C3: bump(2) FIRES (3 > 2) -- this is the crossing this package must file chronic-scoping on');

    my ($after3, $fire3) = BpResolve::chronic_scoping_bump(3);
    is($after3, 4, 'C4: bump(3) -> count_after=4');
    ok($fire3, 'C4: bump(3) still reports fires=true (the DEDUPE against refiling is a higher-layer, queue_needs_you-level concern, not this pure counter\'s job per spec §2.6)');
});

# ═══════════════════════════════════════════════════════════════════════════
# GROUP A -- apply_verdict: act / tag-only outcomes, archive-before-delete
# ordering, and the failed-archive-aborts-deletion guarantee.
# AC1, AC2, AC5, and the two HIGHEST-VALUE tests (fallback direction;
# provenance/archive-before-delete).
# ═══════════════════════════════════════════════════════════════════════════

# A1 (AC1): a resolver-owned category ('oracle') with a fully-qualifying
# high-confidence verdict -> 'act'. Archive written, queue file unlinked,
# ledger flips off 'blocked', .paused never written, ledger not left blocked
# with an empty queue.
run_group('A1 (AC1: resolver-owned category -> act, end to end)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'blk9', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id, $path, $filed) = file_decision($runs, pkg => $pkg, kind => 'stuck-package',
        category => 'oracle', question => 'is this screenshot a real defect?');
    my $verdict = { category => 'oracle', action => 'relaunch', confidence => 'high',
                     evidence => 'cites DC3 exactly: the golden screenshot rule', rationale => 'matches DC3 precisely' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id, { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'act', 'A1: outcome is act');
    ok($outcome->{applied}, 'A1: applied=1 (the underlying dispatch succeeded on a throwaway fixture with no live coordinator)');
    ok(!-f decision_path($runs, $id), 'A1: the queue file was unlinked');
    my $arc = read_json(archive_path($runs, $id));
    ok(ref $arc eq 'HASH', 'A1: an archive record exists') or diag("no archive at " . archive_path($runs, $id));
    if (ref $arc eq 'HASH') {
        is($arc->{resolved_by}, 'bp-escalation-resolver', 'A1: archive resolved_by is the literal agent name (positive marker)');
        is($arc->{action}, 'relaunch', 'A1: archive records the action taken');
        ok($arc->{applied} ? 1 : 0, 'A1: archive applied field is truthy (dispatch rc==0)');
        ok(defined $arc->{resolved_at} && $arc->{resolved_at} =~ /^\d+(\.\d+)?$/, 'A1: archive resolved_at is a numeric epoch');
        is_deeply($arc->{original}, $filed, 'A1: archive carries the FULL original queued record, unmodified');
    }
    isnt(ledger_status($bpdir, $pkg), 'blocked', 'A1: ledger is no longer blocked');
    is(BpOrch::read_paused($runs), undef, 'A1: no .paused was written (DC1: run continues, no fleet pause)');
});

# A2 (AC1): unclassified record resolved by the verdict into one of the four
# resolver-owned categories -> also lands as act (the fallback path must not
# be the ONLY path exercised -- spec's own vacuity guard).
run_group('A2 (AC1: unclassified resolved to scoping+widen-write-set -> act)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'blk10', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id, $path, $filed) = file_decision($runs, pkg => $pkg, kind => 'stuck-package',
        category => 'unclassified', question => 'ambiguous free-text park');
    my $verdict = { category => 'scoping', action => 'widen-write-set', confidence => 'high',
                     evidence => 'cites the exact missing file path from the ledger', rationale => 'a narrow, additive widen closes it' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id,
        { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'act', 'A2: unclassified, once resolved by the verdict, reaches act');
    ok(!-f decision_path($runs, $id), 'A2: queue file unlinked');
    ok(-f archive_path($runs, $id), 'A2: archive exists');
});

# A3 (AC5, Decision-5 Case A -- DI-seam / SMS-auth-retirement): a hand-authored
# verdict matching e01 §4.1's own worked result (category=product, high
# confidence, citing the project rule) MUST land as tag-only, never act.
run_group('A3 (AC5: Decision-5 Case A -- DI-seam/SMS-retirement verdict lands tag-only/product)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'e5', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id, $path, $filed) = file_decision($runs, pkg => $pkg, kind => 'stuck-package',
        category => 'unclassified',
        question => 'add DI seam for cidadao_meus_dados; do not add one for auth_recuperacao_sms_otp (SMS auth retired)');
    my $verdict = { category => 'product', confidence => 'high', evidence => 'cites project rule -- SMS auth retired' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id,
        { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'tag-only', 'A3: Case A resolves to tag-only, not act');
    ok(-f decision_path($runs, $id), 'A3: the queue file is STILL PRESENT (never unlinked -- stays for the operator)');
    ok(!-f archive_path($runs, $id), 'A3: NO archive entry was written (nothing was "acted on")');
    my $tagged = read_json(decision_path($runs, $id));
    is($tagged->{category}, 'product', 'A3: the record is re-tagged category=product');
    is($tagged->{resolved_by}, 'bp-escalation-resolver', 'A3: resolved_by is the positive marker (agent name), not just a boolean');
    is($tagged->{confidence}, 'high', 'A3: confidence carried through');
    is($tagged->{question}, $filed->{question}, 'A3: the original question text is untouched');
    is($tagged->{created_at}, $filed->{created_at}, 'A3: created_at is untouched');
});

# A4 (AC5, Decision-5 Case B -- invisible AlertDialog): confidence=low,
# no citation resolving the SPECIFIC dispute -> tag-only/product, low
# confidence recorded (the confidence-citation rule is the actual backstop
# per e01 §4, not the category test alone).
run_group('A4 (AC5: Decision-5 Case B -- invisible-AlertDialog verdict lands tag-only/product/low)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'e6', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id, $path, $filed) = file_decision($runs, pkg => $pkg, kind => 'stuck-package',
        category => 'unclassified',
        question => 'invisible AlertDialog -- capture artifact or real defect? coordinator could not determine and cannot run the discriminating experiment');
    my $verdict = { category => 'product', confidence => 'low',
                     evidence => 'ledger already investigated and left this open; no citation resolves the specific dispute' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id,
        { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'tag-only', 'A4: Case B resolves to tag-only, not act');
    ok(-f decision_path($runs, $id), 'A4: the queue file is STILL PRESENT');
    ok(!-f archive_path($runs, $id), 'A4: NO archive was written');
    my $tagged = read_json(decision_path($runs, $id));
    is($tagged->{category}, 'product', 'A4: re-tagged category=product');
    is($tagged->{confidence}, 'low', 'A4: confidence=low is carried through honestly (not upgraded)');
});

# A5 (AC3(c) restated at the apply_verdict level): a verdict proposing
# action=accept for an otherwise-clean resolver-owned category is refused --
# queue file untouched, nothing archived, outcome='refuse'.
run_group('A5 (AC3c at apply_verdict level: accept/drop bright line, end to end)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'e7', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id, $path, $filed) = file_decision($runs, pkg => $pkg, kind => 'stuck-package', category => 'conformance');
    my $before = slurp(decision_path($runs, $id));
    my $verdict = { category => 'conformance', action => 'accept', confidence => 'high', evidence => 'x', rationale => 'y' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id,
        { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    is($outcome->{outcome}, 'refuse', 'A5: action=accept is refused end to end, never applied');
    is(slurp(decision_path($runs, $id)), $before, 'A5: the queue file is BYTE-IDENTICAL to before (no partial mutation)');
    ok(!-f archive_path($runs, $id), 'A5: nothing archived for a refused verdict (a refusal is not itself a decision, §2.6)');
});

# A6 -- HIGHEST-VALUE TEST #2: archive-before-delete ordering, proven by
# FORCING the archive write to fail and checking the queue file SURVIVES.
# If a future implementation reversed the order (unlink, then try to
# archive), the queue file would be gone here even though the archive write
# failed -- this test would go red on exactly that inversion.
run_group('A6 (HIGHEST-VALUE #2: a FAILED archive write ABORTS the deletion)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'e8', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id, $path, $filed) = file_decision($runs, pkg => $pkg, kind => 'stuck-package', category => 'oracle');
    my $before = slurp(decision_path($runs, $id));
    # Pre-occupy the archive directory's OWN path with a plain FILE, so any
    # attempt to write "$runs/resolved-escalations/<id>.json" fails
    # deterministically (the parent path component is not a directory) --
    # portable across Windows and POSIX, unlike relying on chmod semantics.
    write_file("$runs/resolved-escalations", "blocker -- not a directory, forces the archive write to fail");
    my $verdict = { category => 'oracle', action => 'relaunch', confidence => 'high', evidence => 'cites DC1 precisely', rationale => 'y' };
    my $outcome = BpResolve::apply_verdict($verdict, $filed, $id,
        { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    ok(-f decision_path($runs, $id), 'A6: the queue file SURVIVES a failed archive write (deletion did not proceed)');
    is(slurp(decision_path($runs, $id)), $before, 'A6: the surviving queue file is byte-identical (no partial tag/mutation applied either)');
    ok(!$outcome->{applied}, 'A6: outcome.applied is falsy -- a failed archive must never be reported as a successful autonomous resolution');
    ok(!-d "$runs/resolved-escalations", 'A6: resolved-escalations is still the blocker FILE, not a directory (the write genuinely never landed)');
});

# A7 -- HIGHEST-VALUE TEST #2 continued: the POSITIVE provenance marker,
# tested against its own absence for a plain (operator-style) deletion.
run_group('A7 (HIGHEST-VALUE #2: positive marker distinguishes resolver from operator-answered)', sub {
    die $RESOLVE_ERR unless $RESOLVE_LOADED;
    my ($bpdir, $pkg) = mk_full_ledger_bp(pkg => 'e9', status => 'blocked');
    my $runs = "$bpdir/runs";
    my ($id_r, $path_r, $filed_r) = file_decision($runs, pkg => $pkg, kind => 'stuck-package', category => 'oracle', question => 'q-resolver');
    my $verdict = { category => 'oracle', action => 'relaunch', confidence => 'high', evidence => 'cites DC1 precisely', rationale => 'y' };
    BpResolve::apply_verdict($verdict, $filed_r, $id_r, { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
    my $arc = read_json(archive_path($runs, $id_r));
    ok(ref $arc eq 'HASH' && ($arc->{resolved_by} // '') eq 'bp-escalation-resolver',
        'A7: a resolver-acted decision carries the POSITIVE resolved_by marker in its archive');

    # Simulate an OPERATOR answer on a second, unrelated decision: today's plain
    # unlink, no archive at all -- exactly what bp-answer-decision.pl already does.
    my ($id_h, $path_h, $filed_h) = file_decision($runs, pkg => $pkg, kind => 'stuck-package', category => 'oracle', question => 'q-human');
    unlink $path_h;
    ok(!-f decision_path($runs, $id_h), 'A7 setup: the human-answered decision is gone from needs-you/');
    ok(!-f archive_path($runs, $id_h), 'A7: a human-answered decision has NO archive entry -- absence is the signal for a human answer, presence (with the positive marker) is the signal for the resolver');
});

# ═══════════════════════════════════════════════════════════════════════════
# GROUP D -- bp-resolve.pl --digest CLI (AC6)
# ═══════════════════════════════════════════════════════════════════════════
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }
sub run_resolve_cli {
    my (@args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $RESOLVE_SCRIPT, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

run_group('D (AC6: bp-resolve.pl --digest)', sub {
    die "bp-resolve.pl does not exist -- cannot exec its CLI" unless -f $RESOLVE_SCRIPT;
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/runs/resolved-escalations");
    make_path("$bpdir/runs/needs-you");
    my %rec1 = ( original => { package => 'alpha', kind => 'stuck-package', question => 'q1', category => 'oracle' },
                 resolved_by => 'bp-escalation-resolver', action => 'relaunch', rationale => 'r1',
                 confidence => 'high', evidence => 'e1', resolved_at => 1000, applied => JSON::PP::true );
    my %rec2 = ( original => { package => 'beta', kind => 'stuck-package', question => 'q2', category => 'scoping' },
                 resolved_by => 'bp-escalation-resolver', action => 'widen-write-set', rationale => 'r2',
                 confidence => 'high', evidence => 'e2', resolved_at => 500, applied => JSON::PP::true );
    write_file("$bpdir/runs/resolved-escalations/alpha--r1.json", $J->encode(\%rec1));
    write_file("$bpdir/runs/resolved-escalations/beta--r2.json",  $J->encode(\%rec2));
    # A still-queued decision that must NOT appear in the digest.
    write_file("$bpdir/runs/needs-you/gamma--q1.json",
        $J->encode({ package => 'gamma', kind => 'stuck-package', question => 'still queued', category => 'implementation', created_at => 999 }));

    my $before_alpha = slurp("$bpdir/runs/resolved-escalations/alpha--r1.json");
    my $before_beta  = slurp("$bpdir/runs/resolved-escalations/beta--r2.json");
    my $before_gamma = slurp("$bpdir/runs/needs-you/gamma--q1.json");

    my ($rc, $out) = run_resolve_cli('bp', '--digest', '--bp-dir', $bpdir);
    is($rc, 0, 'D1: --digest exits 0');
    my @lines = grep { length } split /\n/, $out;
    is(scalar @lines, 2, 'D1: exactly 2 JSON lines printed (the 2 resolved records, not the still-queued one)');
    my @decoded = map { eval { $J->decode($_) } } @lines;
    ok((grep { defined && ref eq 'HASH' } @decoded) == 2, 'D1: both lines parse as JSON objects');
    is($decoded[0]{resolved_at}, 500,  'D2: sorted oldest resolved_at FIRST (beta, 500)');
    is($decoded[1]{resolved_at}, 1000, 'D2: then alpha, 1000');
    ok(!(grep { ($_->{original}{package} // '') eq 'gamma' } @decoded),
        'D3: the still-queued gamma record does NOT appear in the digest');

    is(slurp("$bpdir/runs/resolved-escalations/alpha--r1.json"), $before_alpha, 'D4: --digest left the alpha archive byte-identical (read-only)');
    is(slurp("$bpdir/runs/resolved-escalations/beta--r2.json"),  $before_beta,  'D4: --digest left the beta archive byte-identical');
    is(slurp("$bpdir/runs/needs-you/gamma--q1.json"), $before_gamma, 'D4: --digest left the still-queued record byte-identical too');

    my ($rc2, $out2) = run_resolve_cli('bp', '--digest', '--bp-dir', $bpdir);
    is($rc2, 0, 'D5: a REPEAT invocation also exits 0');
    is($out2, $out, 'D5: a repeat invocation prints byte-identical output (idempotent, mutates nothing)');
});

# ═══════════════════════════════════════════════════════════════════════════
# GROUP N -- HIGHEST-VALUE TEST #3: this must be DISTINCT from b24's
# classify_decision/autonomous_decision_record pair in bp-wait-for-decision.pl.
# ═══════════════════════════════════════════════════════════════════════════
run_group('N (HIGHEST-VALUE #3: b24 autonomy and e03 resolver stay distinct mechanisms)', sub {
    # N1: bp-wait-for-decision.pl still owns classify_decision/autonomous_decision_record
    # (positive control -- proves this test isn't just "the names don't exist anywhere").
    require $WAIT_SCRIPT;
    ok(defined &BpWait::classify_decision, 'N1: BpWait::classify_decision still exists (b24 autonomy, untouched)');
    ok(defined &BpWait::autonomous_decision_record, 'N1: BpWait::autonomous_decision_record still exists (b24 autonomy, untouched)');

    # N2: bp-resolve.pl must NOT define (or re-export) either of those two names --
    # e03's resolver is deliberately PARALLEL, never reused/wrapped (spec §2.6).
    die "bp-resolve.pl does not exist -- cannot check for name collisions" unless -f $RESOLVE_SCRIPT;
    my $src = slurp($RESOLVE_SCRIPT) // '';
    unlike($src, qr/\bsub\s+classify_decision\b/, 'N2: bp-resolve.pl does not define its own classify_decision');
    unlike($src, qr/\bsub\s+autonomous_decision_record\b/, 'N2: bp-resolve.pl does not define its own autonomous_decision_record');
});

done_testing();
