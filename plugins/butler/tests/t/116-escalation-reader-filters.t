#!/usr/bin/env perl
# e02-escalation-classification-layer oracle, part 2: the reader side --
# bp-wait-for-decision.pl's `category` field + `--category` filter,
# bp-answer-decision.pl's new read-only `--list [--category ...]` surface, and
# the `known_kinds()`/`dag-stalled` visibility fix. Derived ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/
# e02-escalation-classification-layer-spec.md (§2.5-§2.8) -- never from any
# implementation.
#
# WRITTEN AGAINST THE CURRENT SCRIPTS, WHICH HAVE NONE OF THIS YET:
#   - BpWait::scan() does not read a `category` field at all.
#   - BpWait::fresh_decisions/wait_loop have no category_filter concept.
#   - bp-wait-for-decision.pl's CLI has no --category flag.
#   - bp-answer-decision.pl has no --list mode at all (always acts on one
#     --decision/--package).
#   - BpAnswer::known_kinds() source-scans a 2-6 line window and CANNOT see
#     'dag-stalled' (built via _dag_decision, a builder function -- e02 §2.5).
# Every failing assertion below is expected absence-of-implementation.
#
# VACUITY GUARDS:
#   - Backward-tolerance tests (G group) probe a legacy (no-category) record
#     against EVERY one of the 7 real category values, INCLUDING
#     'unclassified' specifically -- an implementation that defaults a missing
#     category to 'unclassified' and then matches it against a
#     category_filter containing 'unclassified' would pass a naive test but
#     fails this one, because 'unclassified' is deliberately included in the
#     probe set.
#   - The unfiltered/filtered pair (G1 vs G2, G3 vs G4) is asserted on the
#     SAME fixture in the SAME block, so "just checks truthy category" (which
#     would pass unfiltered and incorrectly also pass filtered) cannot satisfy
#     both halves independently -- exactly the spec's own named landmine
#     (§5 edge cases).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $WAIT_SCRIPT   = "$Bin/../../scripts/bp-wait-for-decision.pl";
my $ANSWER_SCRIPT = "$Bin/../../scripts/bp-answer-decision.pl";

require $WAIT_SCRIPT;     # loads BpWait
require $ANSWER_SCRIPT;   # loads BpAnswer + BpOrch (the CLI requires bp-orchestrator.pl)

my $J = JSON::PP->new->canonical;

sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }
sub run_wait_cli {
    my (@args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $WAIT_SCRIPT, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}
sub run_answer_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $ANSWER_SCRIPT, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP F -- BpWait::scan carries `category`; fresh_decisions/wait_loop filter
# by it. AC4 (DC4, part: bp-wait-for-decision.pl --category LIST).
# ═══════════════════════════════════════════════════════════════════════════

# F1: scan() surfaces category (present) and leaves it undef for a legacy
# record (no key at all) -- never defaulted (spec §2.6).
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = "$root/escalations";
    make_path($dir);
    write_file("$dir/cat--aa11.json",
        $J->encode({ package=>'cat', blueprint=>'bp', kind=>'stuck-package',
                     question=>'?', context=>'', created_at=>1, category=>'operational' }));
    write_file("$dir/legacy--bb22.json",
        $J->encode({ package=>'legacy', blueprint=>'bp', kind=>'stuck-package',
                     question=>'?', context=>'', created_at=>2 }));   # no category key at all
    my $got = BpWait::scan($dir);
    my %by = map { $_->{id} => $_ } @$got;
    is($by{'cat--aa11'}{category}, 'operational', 'F1: scan() surfaces a present category field');
    ok(!exists $by{'legacy--bb22'}{category} || !defined $by{'legacy--bb22'}{category},
        'F1: scan() leaves category undef/absent for a legacy record -- never defaulted');
}

# F2: fresh_decisions with an optional category_filter -- omitted/empty means
# NO filtering, today's behavior, byte-identical (spec §2.6).
{
    my @d = (
        { id=>'a--1', created_at=>10, category=>'product' },
        { id=>'b--2', created_at=>20, category=>'operational' },
        { id=>'c--3', created_at=>30 },   # legacy, no category
    );
    my $unfiltered = BpWait::fresh_decisions(\@d, {});
    is_deeply([sort map { $_->{id} } @$unfiltered], ['a--1','b--2','c--3'],
        'F2: no category_filter -> every decision returned, INCLUDING the legacy one (today\'s behavior unchanged)');
}

# F3: fresh_decisions WITH a category_filter -- matches only decisions whose
# category is in the requested set; a legacy (no-category) record matches
# NO filter regardless of the values requested (spec §2.6, the exact
# matching rule).
{
    my @d = (
        { id=>'a--1', created_at=>10, category=>'product' },
        { id=>'b--2', created_at=>20, category=>'operational' },
        { id=>'c--3', created_at=>30 },   # legacy
    );
    my $f = BpWait::fresh_decisions(\@d, {}, { operational => 1 });
    is_deeply([map { $_->{id} } @$f], ['b--2'],
        'F3: category_filter={operational} -> only the operational decision, legacy excluded');

    # The specific vacuity-trap probe: even a filter that INCLUDES every real
    # category (a caller asking for "everything classified") must still
    # exclude the legacy record, because it was never classified at all.
    my $f_all = BpWait::fresh_decisions(\@d, {}, {
        product => 1, operational => 1, conformance => 1, oracle => 1,
        scoping => 1, implementation => 1, unclassified => 1,
    });
    ok(!(grep { $_->{id} eq 'c--3' } @$f_all),
        'F3b: a filter naming ALL 7 real categories (incl. unclassified) still excludes a legacy record '
      . '-- catches an implementation that defaults a missing category to a real value');
}

# F4: wait_loop threads category_filter through to fresh_decisions (blocks
# until a matching-category decision appears; a non-matching one already
# queued does not satisfy it).
{
    my @sleeps;
    my $clock = 1000;
    my $i = 0;
    my @snaps = (
        [ { id=>'x--1', created_at=>5, category=>'product' } ],                                   # doesn't match
        [ { id=>'x--1', created_at=>5, category=>'product' }, { id=>'y--2', created_at=>6, category=>'oracle' } ],  # matches now
    );
    my $r = BpWait::wait_loop({
        dir => '/does-not-matter',
        category_filter => { oracle => 1 },
        poll => 5,
        now  => sub { $clock },
        sleep=> sub { push @sleeps, $_[0]; $clock += $_[0]; },
        scan => sub { my $s = $snaps[$i < $#snaps ? $i : $#snaps]; $i++; return $s; },
    });
    is($r->{status}, 'decision', 'F4: wait_loop eventually returns once a matching-category decision appears');
    is_deeply([map { $_->{id} } @{$r->{decisions}}], ['y--2'],
        'F4: only the category-matching decision is returned, not the earlier non-matching one');
}

# F5: CLI --category flag, comma-separated (spec §2.6/observable behavior 4).
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = "$root/escalations";
    make_path($dir);
    write_file("$dir/op--1.json",
        $J->encode({ package=>'op', blueprint=>'bp', kind=>'reauth', question=>'?', context=>'', created_at=>1, category=>'operational' }));
    write_file("$dir/pr--2.json",
        $J->encode({ package=>'pr', blueprint=>'bp', kind=>'stuck-package', question=>'?', context=>'', created_at=>2, category=>'product' }));
    write_file("$dir/legacy--3.json",
        $J->encode({ package=>'lg', blueprint=>'bp', kind=>'stuck-package', question=>'?', context=>'', created_at=>3 }));

    # matching filter -> immediate exit 0, only the matching decision.
    my ($rc, $out) = run_wait_cli('--runs', $root, '--category', 'operational', '--timeout', 5);
    is($rc, 0, 'F5: CLI --category operational -> exit 0 (a matching decision is already queued)') or diag($out);
    my $res = eval { JSON::PP->new->decode($out) };
    is(scalar(@{ $res->{decisions} || [] }), 1, 'F5: exactly one decision returned');
    is($res->{decisions}[0]{package}, 'op', 'F5: the operational-category decision, not product or legacy');

    # non-matching filter (nothing in the queue is 'conformance') -> times out,
    # even though the queue is non-empty (product + legacy are both present).
    my ($rc2, $out2) = run_wait_cli('--runs', $root, '--category', 'conformance', '--timeout', 1, '--poll', 1);
    is($rc2, 3, 'F5: CLI --category conformance -> times out (no queued decision matches, incl. the legacy one)') or diag($out2);

    # omitted --category -> byte-identical unfiltered behavior (all 3, incl. legacy).
    my ($rc3, $out3) = run_wait_cli('--runs', $root, '--timeout', 5);
    is($rc3, 0, 'F5: CLI with no --category -> exit 0 (unfiltered, unchanged behavior)') or diag($out3);
    my $res3 = eval { JSON::PP->new->decode($out3) };
    is(scalar(@{ $res3->{decisions} || [] }), 3, 'F5: no --category returns all 3 decisions, including the legacy one');
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP G -- bp-answer-decision.pl --list [--category LIST] (AC4, DC4 part 3;
# spec §2.7). Mutates nothing; sorted oldest-created_at first, ties by id.
# ═══════════════════════════════════════════════════════════════════════════

sub mk_answer_bp {
    my (%recs) = @_;   # id => { package, kind, category(optional), question, created_at }
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/runs/escalations");
    for my $id (keys %recs) {
        my $r = $recs{$id};
        write_file("$bpdir/runs/escalations/$id.json", $J->encode({
            package => $r->{package}, blueprint => 'bp', kind => $r->{kind},
            question => $r->{question} // '?', context => $r->{context} // '',
            created_at => $r->{created_at},
            (exists $r->{category} ? (category => $r->{category}) : ()),
        }));
    }
    return $bpdir;
}

# G1/G2 -- unfiltered vs filtered, asserted on the SAME fixture (the specific
# vacuity-trap pairing the spec names, §5 edge cases).
{
    my $bpdir = mk_answer_bp(
        'alpha--1' => { package=>'alpha', kind=>'stuck-package',   category=>'conformance', created_at=>20 },
        'beta--2'  => { package=>'beta',  kind=>'harvest-failure', category=>'oracle',       created_at=>10 },
        'gamma--3' => { package=>'gamma', kind=>'stuck-package',   created_at=>30 },   # legacy, no category
    );
    my $before = { map { $_ => slurp("$bpdir/runs/escalations/$_") }
                   map { s/\.json$//r } glob_needs_you($bpdir) };

    # G1: --list with no --category -> every record, including legacy, sorted
    # oldest-created_at first (beta=10, alpha=20, gamma=30).
    my ($rc, $out) = run_answer_cli($bpdir, '--list');
    is($rc, 0, 'G1: --list with no --category exits 0') or diag($out);
    my @lines = grep { length } split /\n/, $out;
    my @recs = map { eval { JSON::PP->new->decode($_) } } @lines;
    is(scalar(@recs), 3, 'G1: --list with no filter lists all 3, INCLUDING the legacy record');
    is_deeply([map { $_->{id} // $_->{package} } @recs], ['beta--2','alpha--1','gamma--3'],
        'G1: sorted oldest created_at first (10,20,30)')
        or diag('order was: ' . join(',', map { ($_->{id}//'') . '@' . ($_->{created_at}//'?') } @recs));

    # G2: --list --category conformance,oracle -> excludes the legacy record
    # even though it is present and would appear in the unfiltered listing above.
    my ($rc2, $out2) = run_answer_cli($bpdir, '--list', '--category', 'conformance,oracle');
    is($rc2, 0, 'G2: --list --category conformance,oracle exits 0') or diag($out2);
    my @lines2 = grep { length } split /\n/, $out2;
    my @recs2 = map { eval { JSON::PP->new->decode($_) } } @lines2;
    is(scalar(@recs2), 2, 'G2: exactly the 2 matching-category records, legacy excluded');
    ok(!(grep { ($_->{package} // '') eq 'gamma' } @recs2),
        'G2: the legacy record (gamma, no category) does NOT appear under any --category filter');

    # G3: --list mutates nothing on disk (spec §2.7 "Mutates nothing").
    my $after = { map { $_ => slurp("$bpdir/runs/escalations/$_") }
                  map { s/\.json$//r } glob_needs_you($bpdir) };
    is_deeply($after, $before, 'G3: --list left every queued decision file byte-identical (mutates nothing)');
}

sub glob_needs_you {
    my ($bpdir) = @_;
    my $dir = "$bpdir/runs/escalations";
    opendir my $dh, $dir or return ();
    my @f = grep { /\.json$/ } readdir $dh;
    closedir $dh;
    return @f;
}

# G4: --list is mutually exclusive with --decision/--package (spec §2.7,
# "same 'use X or Y, not both' pattern the script already uses").
{
    my $bpdir = mk_answer_bp('solo--1' => { package=>'solo', kind=>'stuck-package', category=>'product', created_at=>1 });
    my ($rc, $out) = run_answer_cli($bpdir, '--list', '--decision', 'solo--1');
    isnt($rc, 0, 'G4: --list together with --decision is refused (non-zero exit)') or diag($out);
    my ($rc2, $out2) = run_answer_cli($bpdir, '--list', '--package', 'solo');
    isnt($rc2, 0, 'G4: --list together with --package is refused (non-zero exit)') or diag($out2);
}

# ═══════════════════════════════════════════════════════════════════════════
# GROUP H -- known_kinds()/dag-stalled visibility fix (AC4, DC4 part; spec
# §2.5, e01 §9 hard MUST; the still-live techcontas-batch1 #2 defect).
# ═══════════════════════════════════════════════════════════════════════════

# H1: known_kinds() must see 'dag-stalled' (built via _dag_decision, a
# builder function -- invisible to the old source-scanning derivation).
{
    my @kinds = BpAnswer::known_kinds();
    ok((grep { $_ eq 'dag-stalled' } @kinds), 'H1: known_kinds() includes dag-stalled')
        or diag('known_kinds() returned: ' . join(',', @kinds));
}

# H2: kind_family('dag-stalled') must be defined (currently undef -- the
# false "unknown decision kind" claim techcontas-batch1 #2 documents).
{
    my $fam = BpAnswer::kind_family('dag-stalled');
    ok(defined $fam, 'H2: kind_family(\'dag-stalled\') is defined (no longer "unknown to every producer")')
        or diag('kind_family returned undef');
}

# H3: end-to-end CLI -- a dag-stalled decision no longer fails with the FALSE
# "unknown decision kind" message; it fails instead with a specific,
# ledger-targeted refusal (spec observable behavior 6: visibility fixed,
# pseudo-package answerability NOT fixed here, e04's job).
{
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/runs/escalations");
    write_file("$bpdir/runs/escalations/_dag--x1.json", $J->encode({
        package => '_dag', blueprint => 'bp', kind => 'dag-stalled',
        question => 'The dependency graph cannot progress.', context => {}, created_at => 1,
        category => 'scoping',
    }));
    my ($rc, $out) = run_answer_cli($bpdir, '--decision', '_dag--x1', '--action', 'accept');
    isnt($rc, 0, 'H3: acting on a dag-stalled decision still fails (pseudo-package answerability is NOT this package\'s job)');
    unlike($out, qr/unknown decision kind/i,
        'H3: the failure is NOT the false "unknown decision kind \'dag-stalled\'" claim -- visibility is fixed')
        or diag("actual message: $out");
    like($out, qr/_dag/,
        'H3: the failure message names the pseudo-package target (a specific, ledger-targeted refusal)')
        or diag("actual message: $out");
}

done_testing();
