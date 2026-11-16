#!/usr/bin/env perl
# platform: any
# Bug 20261116-132008-3692, path 3 of 3: bp-resolve.pl trusted the
# resolver's product/operator-action category and checked only that
# product_question was non-blank. A mode-only exec-bit change on a file a
# user Decision kept "untouched" became a product question, and the operator,
# who could not even tell what it meant, was the only way out for 62 hours.
# Two earlier fixes for the same class reworded the prompt only.
#
# Pinned here (the deterministic backstop):
#   P1 -- product_question_technical_terms is PURE and finds every family
#         the spec names: a path-like word, a file name, a backtick, and the
#         internal terms (write set, test path, exec bit, chmod, mode-only,
#         ledger, escalation, blueprint, Decision <n>, ADR, AC-<id>,
#         coordinator, resolver, orchestrator, harvest, checkpoint, hook,
#         lefthook, Makefile, protected path), case-insensitive and
#         word-bounded; a plain product question passes, and so does
#         "and/or".
#   P2 -- a product verdict with a technical product_question is NOT tagged
#         operator-owned: the queued record is re-tagged `implementation`
#         in place with product_question_rejected {terms, text}, stays queued
#         (no archive), its original fields survive, and the log names
#         escalation_resolve_not_product. `implementation` is one of the
#         categories the orchestrator fires the resolver on.
#   P3 -- the bound: the same record coming back product/operator-action
#         with a technical question again reaches the operator, with a
#         one-line note that it twice failed the check.
#   P4 -- a plain product question is tagged for the operator unchanged.
#   P5 -- the resolver prompt states the plain-language test, the
#         product_question_rejected rule, the refined user-Decision rule and
#         the project-process-rule rule.
# Runs standalone: perl this file
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $ORCH    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE = "$Bin/../../scripts/bp-resolve.pl";
my $AGENT   = "$Bin/../../agents/bp-escalation-resolver.md";
require $ORCH;
require $RESOLVE;

my $J = JSON::PP->new->canonical;
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub read_json { my ($p) = @_; my $t = slurp($p); return undef unless defined $t; return eval { $J->decode($t) }; }

# Guarded so the file reports every assertion, not one die, against a tree
# that lacks the check.
sub terms {
    return [] unless defined &BpResolve::product_question_technical_terms;
    return [ BpResolve::product_question_technical_terms($_[0]) ];
}

# ---- P1: the pure check ---------------------------------------------------
{
    ok(defined &BpResolve::product_question_technical_terms, 'P1: product_question_technical_terms exists');
    my @fail = (
        [ 'Approve the change to container/run.sh?',                 'container/run.sh' ],
        [ 'May the entrypoint.sh keep its mode?',                     'entrypoint.sh' ],
        [ 'Should `setup` run first?',                                '`' ],
        [ 'Should package 14 widen its write set?',                   'write set' ],
        [ 'May the write_set include it?',                            'write_set' ],
        [ 'Should the test_paths shrink?',                            'test_paths' ],
        [ 'Is the exec bit change allowed?',                          'exec bit' ],
        [ 'Is a mode-only change fine?',                              'mode-only' ],
        [ 'May we CHMOD it?',                                         'CHMOD' ],
        [ 'Should the ledger record it?',                             'ledger' ],
        [ 'Should this escalation wait?',                             'escalation' ],
        [ 'Does the blueprint allow it?',                             'blueprint' ],
        [ 'Is an exception to Decision 2 fine?',                      'Decision 2' ],
        [ 'Does ADR 7 cover it?',                                     'ADR' ],
        [ 'Is AC-12b met?',                                           'AC-12b' ],
        [ 'Should the coordinator retry?',                            'coordinator' ],
        [ 'Was the resolver right?',                                  'resolver' ],
        [ 'Should the orchestrator pause?',                           'orchestrator' ],
        [ 'Should harvest be skipped?',                               'harvest' ],
        [ 'Should the checkpoint include it?',                        'checkpoint' ],
        [ 'Should the pre-commit hook run?',                          'hook' ],
        [ 'Should lefthook skip it?',                                 'lefthook' ],
        [ 'Should the Makefile change?',                              'Makefile' ],
        [ 'Is this a protected path?',                                'protected path' ],
    );
    for my $f (@fail) {
        my ($q, $want) = @$f;
        my $t = terms($q);
        ok((grep { lc $_ eq lc $want } @$t), "P1: '$q' fails on '$want'") or diag(explain $t);
    }
    for my $q ('Should checkout keep guest accounts?',
               'Should guests be able to pay and/or save a card?',
               'Should the app delete inactive accounts after a year?',
               'Should the DI seam be added for cidadao_meus_dados but not auth_recuperacao_sms_otp?',
               'Should the hookah lounge listing stay public?',
               'Which product behaviour do you want here?') {
        is_deeply(terms($q), [], "P1: plain question passes: '$q'");
    }
    is_deeply(terms(undef), [], 'P1: undef has no terms');
}

# ---- fixtures for P2-P4 ----------------------------------------------------
sub mk_runs {
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages", "$bpdir/runs");
    return ($bpdir, "$bpdir/runs");
}
sub file_decision {
    my ($runs, %o) = @_;
    my $rec = { package => 'p14', blueprint => 'bp', kind => 'stuck-package',
                question => 'may the coordinator chmod container/run.sh?', context => 'ctx',
                created_at => time, category => 'unclassified', %o };
    my $path = BpOrch::queue_needs_you($runs, $rec);
    die 'queue_needs_you failed' unless $path;
    (my $id = $path) =~ s{.*[\\/]}{}; $id =~ s/\.json$//i;
    return ($id, $path, read_json($path));
}
sub apply {
    my ($v, $rec, $id, $bpdir, $runs) = @_;
    return BpResolve::apply_verdict($v, $rec, $id, { bpdir => $bpdir, runs => $runs, bp => 'bp', log => "$runs/orchestrator.log" });
}
my $TECH_Q = 'Approve the mode-only exec bit change on container/run.sh, an exception to Decision 2?';

# ---- P2: first failure -> re-tagged implementation, still queued ------------
my ($P2_BPDIR, $P2_RUNS, $P2_ID, $P2_PATH);
{
    my ($bpdir, $runs) = mk_runs();
    my ($id, $path, $filed) = file_decision($runs);
    my $out = apply({ category => 'product', confidence => 'low', evidence => 'e', product_question => $TECH_Q },
                    $filed, $id, $bpdir, $runs);
    is($out->{outcome}, 'not-product', 'P2: a technical product_question is not tagged for the operator');
    ok(-f $path, 'P2: the record is still queued');
    ok(!-e "$runs/resolved-escalations/$id.json", 'P2: nothing was archived');
    my $rec = read_json($path);
    is($rec->{category}, 'implementation', 'P2: re-tagged category implementation');
    ok(!defined $rec->{product_question}, 'P2: no operator product_question was written');
    ok(!defined $rec->{resolved_by}, 'P2: not marked resolved');
    is(ref $rec->{product_question_rejected}, 'HASH', 'P2: product_question_rejected recorded');
    is($rec->{product_question_rejected}{text}, $TECH_Q, 'P2: it holds the rejected text');
    my $t = $rec->{product_question_rejected}{terms} || [];
    for my $want ('container/run.sh', 'mode-only', 'exec bit', 'Decision 2') {
        ok((grep { $_ eq $want } @$t), "P2: failing terms include '$want'");
    }
    is($rec->{question}, $filed->{question}, 'P2: the original question survives');
    is($rec->{package}, 'p14', 'P2: the package survives');
    ok($BpOrch::RESOLVER_TRIAGEABLE{ $rec->{category} }, 'P2: implementation is resolver-triageable, so the resolver fires again');
    like(slurp("$runs/orchestrator.log") // '', qr/escalation_resolve_not_product/, 'P2: escalation_resolve_not_product logged');
    ($P2_BPDIR, $P2_RUNS, $P2_ID, $P2_PATH) = ($bpdir, $runs, $id, $path);
}

# ---- P3: second failure on the same record -> operator, with a note --------
{
    my $rec = read_json($P2_PATH);
    my $out = apply({ category => 'operator-action', confidence => 'low', evidence => 'e', product_question => $TECH_Q },
                    $rec, $P2_ID, $P2_BPDIR, $P2_RUNS);
    is($out->{outcome}, 'tag-only', 'P3: the bound lets a twice-failed question reach the operator');
    my $tagged = read_json($P2_PATH);
    is($tagged->{category}, 'operator-action', 'P3: tagged operator-owned');
    like($tagged->{product_question}, qr/\A\Q$TECH_Q\E \(Note: this question twice failed the plain-language check; it names [^\n]+\.\)\z/,
         'P3: product_question carries a one-line note that it twice failed the check');
    unlike($tagged->{product_question}, qr/\n/, 'P3: still one line');
    like(slurp("$P2_RUNS/orchestrator.log") // '', qr/escalation_resolve_not_product_bounded/, 'P3: the bounded case is logged');
}

# ---- P4: a plain question is tagged unchanged -------------------------------
{
    my ($bpdir, $runs) = mk_runs();
    my ($id, $path, $filed) = file_decision($runs, question => 'q');
    my $out = apply({ category => 'product', confidence => 'low', evidence => 'e',
                      product_question => '  Should checkout keep guest accounts?  ' }, $filed, $id, $bpdir, $runs);
    is($out->{outcome}, 'tag-only', 'P4: a plain product question is tagged for the operator');
    my $rec = read_json($path);
    is($rec->{product_question}, 'Should checkout keep guest accounts?', 'P4: unchanged (trimmed)');
    ok(!exists $rec->{product_question_rejected}, 'P4: no rejection recorded');
    unlike(slurp("$runs/orchestrator.log") // '', qr/escalation_resolve_not_product/, 'P4: no not_product event');
}

# ---- P5: the resolver prompt -------------------------------------------------
{
    my $txt = slurp($AGENT) // '';
    (my $flat = $txt) =~ s/\s+/ /g;
    like($flat, qr/\*\*The plain-language test is part of that bar\.\*\*/, 'P5: the plain-language test is part of the bar');
    like($flat, qr/without any explanation\*\* of files, paths, tools, tests, permissions, modes, write sets, test paths, Decisions numbers or any other internal mechanics/,
         'P5: it names what needing an explanation means');
    like($flat, qr/A record carrying `product_question_rejected` is yours to settle, with one of the actions, never routed to `product` or `operator-action` again\./,
         'P5: a rejected record is settled by the agents');
    like($flat, qr/A row decided by `user` is the operator's: a change to what it means \*\*for the product\*\* is theirs to make, and only that\./,
         'P5: only a change to what a user Decision means for the product is the operator\'s');
    like($flat, qr/a file mode, an exec bit, a path detail, a test fixture\) without changing what it means for the product, is not a change to its meaning/,
         'P5: technical application of a user Decision is the agents\'');
    like($flat, qr/\*\*A project's own process rules are not product questions by themselves\.\*\*/, 'P5: process rules are not product questions');
    like($flat, qr/A Decisions row decided by `user` that covers the step satisfies such a rule/, 'P5: a covering user Decision satisfies a process rule');
    like($flat, qr/record in `rationale` which rule applied/, 'P5: the resolver records its reasoning');
}

done_testing();
