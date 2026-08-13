#!/usr/bin/env perl
# e04-honest-terminal-reporting, AC3 (-> DC3): a decision must never be queued
# against a package whose re-read-under-lock ledger status is already
# 'done'/'dropped'. a01 already ships the re-read-under-lock GATE mechanism
# (BpOrch::queue_needs_you, %BpOrch::DECISION_VALIDITY) -- but today the table
# lists ONLY 'stuck-package'. Spec §2.3/§3(3)/§4 AC3/§7 edge case 3 requires
# extending it (zero new code) to also cover judge-starved, turn-starved,
# harvest-failure, harvest-spawn-failure.
#
# TODAY'S WRONG REPORT (confirmed live by reading bp-orchestrator.pl:87 --
# `our %DECISION_VALIDITY = ( 'stuck-package' => ['done', 'dropped'] );` --
# and :1467-1472's default-permit fallthrough for any kind not in the table):
# a judge-starved (or turn-starved/harvest-failure/harvest-spawn-failure)
# decision queued against a package whose ledger ALREADY reads status: done
# is written anyway -- the exact terminal-race techcontas #3 describes, just
# for kinds a01's gate does not yet cover.
#
# Written BLIND to the eventual fix's shape (only the table's CURRENT single
# entry is known; no assumption about how the extension is implemented beyond
# "the table gains more keys, gate mechanism itself unchanged").
#
# VACUITY GUARDS:
#   - every refusal assertion pairs `ret` falsy with "no file appears in
#     needs-you/" AND a write_guard log-line check -- an implementation that
#     returns 0 without actually refusing the write (e.g. a bug that logs
#     nothing) is still caught by the needs-you/ emptiness check.
#   - a POSITIVE control per kind (status=pending, same kind) proves the gate
#     is not simply refusing everything -- pairs with the negative case so a
#     "refuse unconditionally" bug fails the control instead of hiding behind
#     an always-refuse implementation.
#   - `stuck-package` itself is re-asserted here (already gated by a01) as a
#     control that the table's PRE-EXISTING row is not disturbed by the
#     extension -- catches an implementer who replaces rather than extends
#     the table.
#   - `dag-stalled` is asserted to remain UNGATED (default-permit) even
#     against a done/dropped-status package -- spec §2.3 "Excluded,
#     deliberately" -- catching an over-broad extension that gates pseudo-
#     package kinds it should not.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;

sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c; close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub log_events {
    my ($path) = @_;
    return () unless -f $path;
    return map { eval { $J->decode($_) } } grep { length } split /\n/, slurp($path);
}
sub needs_you_files {
    my ($runs) = @_;
    my $dir = "$runs/needs-you";
    return () unless -d $dir;
    opendir my $dh, $dir or return ();
    my @j = sort grep { /\.json$/ } readdir $dh;
    closedir $dh;
    return @j;
}
sub mk_ledger_bp {
    my (%o) = @_;
    my $pkg    = $o{pkg}    // 'alpha';
    my $status = $o{status} // 'pending';
    my $bpdir  = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages");
    make_path("$bpdir/runs");
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: bp\nstatus: $status\nwrite_set: p/$pkg/\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n");
    return ($bpdir, $pkg);
}

# ═══════════════════════════════════════════════════════════════════════════
# NEGATIVE cases — one per newly-required kind, ledger status already 'done'.
# ═══════════════════════════════════════════════════════════════════════════
# `judge-starved` is DELIBERATELY ABSENT from this list, and from %DECISION_VALIDITY
# -- but NOT because it cannot race. Both of its emission sites sit inside guards
# that check the ledger status against a once-per-tick SNAPSHOT (`$jstate eq
# 'starved' && $st eq 'done'`, bp-orchestrator.pl ~:2933/:2998), and a concurrent
# `bp-answer-decision.pl` can flip the LIVE ledger after that snapshot but before
# either branch runs (fixbatch step7 / red-team MAJOR: the "cannot structurally
# fire under any other status" claim was true only of the stale snapshot, not the
# live ledger -- the race was real). Adding a ['done','dropped'] row here would
# still be the wrong fix regardless: it would refuse the kind UNCONDITIONALLY
# (every judge-starved call site is already snapshot-gated to 'done'), converting
# this table's rule ("never queue against an already-terminal package") into
# "never queue this kind at all" -- and it regresses must-stay-green
# plugins/butler/tests/t/99-write-guard-sites.t's own S4/AC14 control, which pins
# that an unmoved 'done' state (the ORDINARY case: status genuinely still 'done'
# while the harvest audit is unresolved, not a race) still queues judge-starved.
# The actual fix closes the race at its source instead: `_judge_outcome_still_
# applies` (bp-orchestrator.pl) now re-reads the ledger's live status, under the
# ledger's own lock, immediately before either branch commits to queuing --
# a01's re-read-under-the-lock convention, applied to the resource this gate was
# missing. The omission from this table is asserted positively below rather than
# left implicit.
my @NEW_KINDS = qw(turn-starved harvest-failure harvest-spawn-failure);
my $n = 0;
for my $kind (@NEW_KINDS) {
    my ($bpdir, $pkg) = mk_ledger_bp(pkg => "done_$kind" =~ s/[^a-z0-9]/_/gr, status => 'done');
    my $runs = "$bpdir/runs";
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => $kind, question => 'q', context => 'c',
          created_at => 10 + $n, category => 'operational' },
        $bpdir);
    ok(!$ret, "AC3/neg: $kind refused when the re-read status is already 'done' (fails today: default-permit)");
    is_deeply([needs_you_files($runs)], [], "AC3/neg: $kind -- no decision file appears in needs-you/");
    my @wg = grep { ($_->{type} // '') eq 'write_guard' } log_events("$runs/orchestrator.log");
    ok((grep { ($_->{outcome} // '') eq 'refused' } @wg) >= 1,
        "AC3/neg: $kind -- a write_guard 'refused' log line is emitted");
    $n++;
}

# ═══════════════════════════════════════════════════════════════════════════
# NEGATIVE cases — same four kinds, ledger status already 'dropped'.
# ═══════════════════════════════════════════════════════════════════════════
for my $kind (@NEW_KINDS) {
    my ($bpdir, $pkg) = mk_ledger_bp(pkg => "dropped_$kind" =~ s/[^a-z0-9]/_/gr, status => 'dropped');
    my $runs = "$bpdir/runs";
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => $kind, question => 'q', context => 'c',
          created_at => 100 + $n, category => 'operational' },
        $bpdir);
    ok(!$ret, "AC3/neg-dropped: $kind refused when the re-read status is already 'dropped'");
    $n++;
}

# ═══════════════════════════════════════════════════════════════════════════
# POSITIVE controls — same four kinds, ledger status still 'pending'/'blocked'
# (not in the refusal set) -- must still queue normally.
# ═══════════════════════════════════════════════════════════════════════════
for my $kind (@NEW_KINDS) {
    my ($bpdir, $pkg) = mk_ledger_bp(pkg => "live_$kind" =~ s/[^a-z0-9]/_/gr, status => 'blocked');
    my $runs = "$bpdir/runs";
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => $kind, question => 'q', context => 'c',
          created_at => 200 + $n, category => 'operational' },
        $bpdir);
    ok($ret, "AC3/pos-control: $kind still queues normally when status is 'blocked' (not in refusal set)");
    is(scalar(needs_you_files($runs)), 1, "AC3/pos-control: $kind -- exactly one decision file written");
    $n++;
}

# ═══════════════════════════════════════════════════════════════════════════
# CONTROL — the pre-existing stuck-package row must still work (not replaced).
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($bpdir, $pkg) = mk_ledger_bp(pkg => 'stuckdone', status => 'done');
    my $runs = "$bpdir/runs";
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c',
          created_at => 300, category => 'unclassified' },
        $bpdir);
    ok(!$ret, 'AC3/control: stuck-package is STILL refused against a done package (a01 row not disturbed)');
}

# ═══════════════════════════════════════════════════════════════════════════
# CONTROL — dag-stalled (pseudo-package kind) must remain default-permit, even
# against a real package whose status happens to be done/dropped (spec §2.3:
# "Excluded, deliberately" -- dag-stalled/remediation-escalation are never
# gated, regardless of what package name they happen to carry).
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($bpdir, $pkg) = mk_ledger_bp(pkg => 'dagdone', status => 'done');
    my $runs = "$bpdir/runs";
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'dag-stalled', question => 'q', context => 'c',
          created_at => 400, category => 'scoping' },
        $bpdir);
    ok($ret, 'AC3/control: dag-stalled remains default-permit (never added to %DECISION_VALIDITY per spec §2.3)');
}

# ═══════════════════════════════════════════════════════════════════════════
# Direct table-content assertion: %BpOrch::DECISION_VALIDITY itself carries
# all five expected rows, each exactly ['done','dropped'] (spec §2.3's literal
# table) -- WITHOUT localizing it (this is the real global the fix must edit).
# ═══════════════════════════════════════════════════════════════════════════
{
    # judge-starved is deliberately NOT here -- see the block comment above
    # @NEW_KINDS. Its absence is asserted POSITIVELY straight after this loop, so
    # the omission is a pinned guarantee rather than a silently missing row that a
    # later edit could "restore" without anything going red.
    my @want = qw(stuck-package turn-starved harvest-failure harvest-spawn-failure);
    for my $k (@want) {
        ok(exists $BpOrch::DECISION_VALIDITY{$k} && ref $BpOrch::DECISION_VALIDITY{$k} eq 'ARRAY',
            "AC3/table: \%DECISION_VALIDITY has a row for '$k'");
        is_deeply($BpOrch::DECISION_VALIDITY{$k}, ['done', 'dropped'],
            "AC3/table: '$k' row is exactly ['done','dropped'] (not the broader terminal set, spec §7 edge case 3)")
            if exists $BpOrch::DECISION_VALIDITY{$k};
    }
    ok(!exists $BpOrch::DECISION_VALIDITY{'dag-stalled'},
        'AC3/table: dag-stalled is NOT in the table (stays default-permit per spec §2.3)');
    ok(!exists $BpOrch::DECISION_VALIDITY{'remediation-escalation'},
        'AC3/table: remediation-escalation is NOT in the table (stays default-permit per spec §2.3)');
    ok(!exists $BpOrch::DECISION_VALIDITY{'awaiting-ledger'},
        'AC3/table: awaiting-ledger is NOT in the table (spec §2.3: "not a terminal-race case")');

    # THE OMISSION IS A GUARANTEE, NOT AN OVERSIGHT -- asserted positively so a
    # future edit that "completes" the spec's §2.3 table turns this red and has to
    # read the reasoning first. judge-starved's only emission sites are guarded by
    # a snapshot check (`$st eq 'done'`, bp-orchestrator.pl ~:2933/:2998), so a
    # ['done','dropped'] row would refuse it unconditionally rather than narrowing
    # a race -- and doing so regressed must-stay-green t/99-write-guard-sites.t's
    # S4/AC14 control, which pins that an unmoved 'done' state still queues
    # judge-starved as it does today. The race the table would have closed is
    # real (a concurrent bp-answer-decision.pl can flip the live ledger after the
    # snapshot, fixbatch step7 / red-team MAJOR) -- it is closed instead at
    # `_judge_outcome_still_applies`, which now re-reads the ledger's live status
    # under its own lock immediately before either branch queues.
    ok(!exists $BpOrch::DECISION_VALIDITY{'judge-starved'},
        'AC3/table: judge-starved is NOT in the table -- its emission sites are '
      . 'snapshot-gated to status=done and the live-status race that gate cannot see is '
      . 'closed by _judge_outcome_still_applies\'s own re-read-under-lock instead (fixbatch '
      . 'step7; see t/99 S4/AC14)');
}

done_testing();
