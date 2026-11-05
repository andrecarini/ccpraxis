#!/usr/bin/env perl
# platform: any
# Bug 20261105-055544-2c28: an escalation asking to widen a write_set by one
# file and to grant a lint exemption got an `author-ledger` verdict (rationale:
# "author a new blueprint.md Decision granting both"), and the apply step of
# that day replaced the package's live 9.9 KB ledger with a stub.
#
# Pinned here:
#   C  -- an author-ledger verdict against a package whose ledger exists is a
#         contradiction: the ledger stays byte-identical, nothing is archived
#         or dispatched, the queued record is re-tagged operator-action with a
#         question carrying the escalation's own text, and the log names the
#         case (escalation_resolve_contradiction).
#   CS -- the same verdict against a record that changed meanwhile is stale:
#         nothing is written at all.
#   G  -- the last line of defence: a ledger that appears after the existence
#         check, under the write lock, is still never overwritten.
#   W  -- a widen-write-set verdict carrying `decision` records a Decisions row
#         naming the path (decided by agent) and widens the ledger through the
#         Decision-gated typed verb; with no Decisions table it writes nothing
#         and goes to the operator.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $ORCH    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE = "$Bin/../../scripts/bp-resolve.pl";
my $LEDGER  = "$Bin/../../scripts/bp-ledger.pl";
my $TPL     = "$Bin/../../../blueprint/templates/package-ledger.md";
require $ORCH;
require $RESOLVE;

my $BP  = 'acxpraxis-step-2';
my $PKG = '12-model-merge';

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub spew  { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "fixture $p: $!"; print {$fh} $c; close $fh }

sub fm_value {
    my ($bytes, $key) = @_;
    my ($fm) = $bytes =~ /\A---\s*\n(.*?)\n---/s;
    return undef unless defined $fm;
    return $1 if $fm =~ /^\Q$key\E:[ \t]*(.*?)[ \t]*$/m;
    return undef;
}

# Same blueprint shape as author-ledger-from-section.t: a status row plus a
# complete `### 12-model-merge` section, so author-ledger WOULD succeed if the
# ledger were absent -- the refusal below is about the existing file, nothing else.
my $STATUS = <<'MD';
## Package status

| pkg | deliverable | depends_on | model |
|-----|-------------|------------|-------|
| 10-model-journal-recovery | journal model | — | sonnet |
| 12-model-merge | merge model | 10-model-journal-recovery | sonnet |

MD

my $SECTION = <<'MD';
### 12-model-merge: the merge model

- **scope:** Write `models/merge/`: write-ahead merges, compare-and-swap ref updates,
  and recovery after a crash between any two steps.
- **done_criteria:** As package 10's, for `models/merge/`.
- **write_set:** `models/merge/`        <!-- colon-separated; trailing / = prefix -->
- **test_paths:** `models/merge/test/`
- **checks:** quint-verify
- **model:** sonnet
- **effort:** high
- **max_turns:** 650
- **inputs:** docs/architecture.md §4.2 and §8; models/README.md from package 10.
- **out_of_scope:** design fixes (14); other models.

MD

my $DECISIONS = <<'MD';
## Decisions

| # | Decision | Decided | Date |
|---|----------|---------|------|
| 1 | Models are written in Quint | user | 2026-10-01 |
| 2 | Each model owns its own directory | agent | 2026-10-02 |

MD

# A data dir with the blueprint two levels down, like the real layout, so
# bp-ledger.pl's in-flight overlap check looks at this temp tree only.
sub mk_bp {
    my ($blueprint) = @_;
    my $root = tempdir(CLEANUP => 1);
    $root =~ s{\\}{/}g;
    my $d = "$root/data/blueprints/$BP";
    make_path("$d/packages", "$d/runs/escalations");
    spew("$d/blueprint.md", $blueprint);
    return $d;
}

# A real, running ledger: created through bp-ledger.pl, then given progress
# and an escalation through its typed verbs -- the kind of file the bug lost.
sub mk_ledger {
    my ($bpdir) = @_;
    my $l = "$bpdir/packages/$PKG.md";
    my $rc = system($^X, $LEDGER, 'create', '--ledger', $l, '--package', $PKG, '--blueprint', $BP,
                    '--template', $TPL, '--write-set', 'models/merge/', '--test-paths', 'models/merge/test/');
    die "fixture: bp-ledger create failed ($rc)" if $rc;
    $rc = system($^X, $LEDGER, 'append-attempt', '--ledger', $l, '--text',
                 'coordinator: step 4 done; needs core/apps/x_SUITE.erl and an ex_doc locale exemption');
    die "fixture: append-attempt failed ($rc)" if $rc;
    return $l;
}

sub queue {
    my ($bpdir, $id) = @_;
    my $rec = { package => $PKG, blueprint => $BP, kind => 'self-park', category => 'scoping',
                question => 'Widen write_set by core/apps/x_SUITE.erl, and exempt the ex_doc locale warning?',
                created_at => 1 };
    spew("$bpdir/runs/escalations/$id.json", JSON::PP->new->canonical->encode($rec));
    return $rec;
}

sub ctx { my ($bpdir) = @_; return { bp => $BP, bpdir => $bpdir, runs => "$bpdir/runs", log => "$bpdir/runs/orchestrator.log" } }

my $FULL = "# Step 2\n\n$DECISIONS$STATUS## Packages\n\n$SECTION";

my %AUTHOR = (category => 'scoping', action => 'author-ledger', confidence => 'high',
              evidence => 'ledger Escalation section', rationale => 'author a new blueprint.md Decision granting both');

# ---- C: author-ledger against an existing ledger ---------------------------
{
    my $bpdir = mk_bp($FULL);
    my $l     = mk_ledger($bpdir);
    my $before = slurp($l);
    my $id  = "$PKG--c1";
    my $rec = queue($bpdir, $id);
    my $out = BpResolve::apply_verdict({ %AUTHOR }, $rec, $id, ctx($bpdir));

    is(slurp($l), $before, 'C1: the existing ledger is byte-identical');
    is($out->{outcome}, 'contradiction', 'C2: the outcome is a contradiction, not an apply failure');
    is($out->{applied}, 0, 'C3: nothing is applied');
    is($out->{surfaced}, 'operator-action', 'C4: the record is handed to the operator');
    my $q = BpOrch::_read_json("$bpdir/runs/escalations/$id.json");
    ok(ref $q eq 'HASH', 'C5: the queued record is still there');
    is($q->{category}, 'operator-action', 'C6: re-tagged operator-action');
    ok(!$BpOrch::RESOLVER_TRIAGEABLE{ $q->{category} // '' }, 'C7: no longer resolver-triageable, so the resolver does not re-fire on it');
    like($q->{product_question} // '', qr/author-ledger.*packages\/12-model-merge\.md already exists/,
        'C8: the question says why the verdict was not applied');
    like($q->{product_question} // '', qr/The escalation asked: Widen write_set by core\/apps\/x_SUITE\.erl/,
        'C9: the question carries what the escalation actually asked');
    unlike($q->{product_question} // '', qr/\n/, 'C10: the question is one line');
    like($q->{product_question} // '', qr/\APackage 12-model-merge's escalation needs your decision/,
        'C10b: the question names the package');
    ok(!-e "$bpdir/runs/resolved-escalations/$id.json", 'C11: nothing is archived (nothing was decided)');
    like(slurp("$bpdir/runs/orchestrator.log") // '', qr/escalation_resolve_contradiction\b(?!_failed)/,
        'C12: logged under its own event');
    opendir(my $dh, "$bpdir/packages") or die;
    my @extra = grep { !/^\.\.?\z/ && $_ ne "$PKG.md" && $_ ne "$PKG.md.lock" } readdir $dh;
    closedir $dh;
    is_deeply(\@extra, [], 'C13: no other file appears beside the ledger');
}

# ---- CS: a record that changed meanwhile is stale; nothing is written ------
{
    my $bpdir = mk_bp($FULL);
    my $l     = mk_ledger($bpdir);
    my $before = slurp($l);
    my $id  = "$PKG--c2";
    my $rec = queue($bpdir, $id);
    my $qbefore = slurp("$bpdir/runs/escalations/$id.json");
    my $out = BpResolve::apply_verdict({ %AUTHOR }, { %$rec, question => 'an older snapshot' }, $id, ctx($bpdir));
    is($out->{outcome}, 'stale', 'CS1: a changed record is stale');
    is(slurp($l), $before, 'CS2: the ledger is byte-identical');
    is(slurp("$bpdir/runs/escalations/$id.json"), $qbefore, 'CS3: the queued record is byte-identical');
}

# ---- G: a ledger appearing under the lock is never overwritten -------------
{
    my $bpdir = mk_bp($FULL);
    my $l = "$bpdir/packages/$PKG.md";
    my ($ok, $why);
    {
        local $BpWrite::AFTER_LOCK_HOOK = sub { spew($l, "raced in\n") unless -e $l };
        ($ok, $why) = BpResolve::_author_ledger($PKG, ctx($bpdir));
    }
    ok(!$ok, 'G1: author-ledger refuses when a ledger appears under the write lock');
    is(slurp($l), "raced in\n", 'G2: the ledger that appeared is byte-identical');
}

# ---- W: widen-write-set with a decision ------------------------------------
my %WIDEN = (category => 'scoping', action => 'widen-write-set', confidence => 'high',
             evidence => 'ledger Escalation section; Decisions row 2', rationale => 'one more file, within purview',
             path => 'models/shared/x_SUITE.erl',
             decision => "Package 12 may edit the shared suite file;\nthe ex_doc locale warning is exempt");
{
    my $bpdir = mk_bp($FULL);
    my $l     = mk_ledger($bpdir);
    my $id  = "$PKG--w1";
    my $rec = queue($bpdir, $id);
    my $out = BpResolve::apply_verdict({ %WIDEN }, $rec, $id, ctx($bpdir));
    is($out->{applied}, 1, 'W1: a widen-write-set verdict with a decision applies') or diag(explain $out);
    my $lb = slurp($l) // '';
    is(fm_value($lb, 'write_set'), 'models/merge/:models/shared/x_SUITE.erl', 'W2: the path is added to write_set');
    like($lb, qr/write_set widened per Decision 3: models\/shared\/x_SUITE\.erl/, 'W3: the ledger logs the widening against Decision 3');
    like($lb, qr/needs core\/apps\/x_SUITE\.erl and an ex_doc locale exemption/, 'W4: the prior attempt log survives');
    my $bb = slurp("$bpdir/blueprint.md") // '';
    like($bb, qr/^\| 3 \| Package 12 may edit the shared suite file; the ex_doc locale warning is exempt \(bp-escalation-resolver, escalation 12-model-merge--w1: widens 12-model-merge write_set by `models\/shared\/x_SUITE\.erl`\) \| agent \| \d{4}-\d\d-\d\d \|$/m,
        'W5: Decision 3 is recorded on one line, naming the path, decided by agent');
    like($bb, qr/^\| 2 \| Each model owns its own directory \| agent \| 2026-10-02 \|$/m, 'W6: existing Decisions are untouched');
    ok(!-e "$bpdir/runs/escalations/$id.json", 'W7: the escalation is settled');
    my $rc = system($^X, $LEDGER, 'validate', '--ledger', $l);
    is($rc >> 8, 0, 'W8: the widened ledger validates');
}
{
    # No Decisions table: nothing is written, and the operator is asked.
    my $bpdir = mk_bp("# Step 2\n\n$STATUS## Packages\n\n$SECTION");
    my $l     = mk_ledger($bpdir);
    my ($lbefore, $bbefore) = (slurp($l), slurp("$bpdir/blueprint.md"));
    my $id  = "$PKG--w2";
    my $rec = queue($bpdir, $id);
    my $out = BpResolve::apply_verdict({ %WIDEN }, $rec, $id, ctx($bpdir));
    is($out->{applied}, 0, 'W9: with no Decisions table it is not applied');
    is($out->{surfaced}, 'operator-action', 'W10: and it is handed to the operator');
    is(slurp($l), $lbefore, 'W11: the ledger is byte-identical');
    is(slurp("$bpdir/blueprint.md"), $bbefore, 'W12: blueprint.md is byte-identical');
    my $q = BpOrch::_read_json("$bpdir/runs/escalations/$id.json");
    like($q->{product_question} // '', qr/\APackage 12-model-merge's escalation could not be resolved.*chose widen-write-set.*no Decisions table/,
        'W13: the question names the action and the missing table, not a ledger');
}

done_testing();
