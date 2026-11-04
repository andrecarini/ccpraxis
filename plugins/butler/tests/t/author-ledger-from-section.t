#!/usr/bin/env perl
# platform: any
# Bug 20261104-163147-07ae: bp-resolve.pl's author-ledger action built a
# package ledger from blueprint.md's package-STATUS ROW alone -- empty
# write_set, depends_on in the frontmatter, the one-line deliverable as Scope,
# "TBD" done criteria, no effort/max_turns/test_paths/checks. bp-launch refused
# it (empty write_set) and every bp-ledger verb refused to repair it
# (depends_on), so the package was stuck until the file was deleted by hand.
#
# Pinned here:
#   S  -- a blueprint whose `### NN-slug` section is complete yields a ledger
#         carrying that section's write_set/test_paths/checks/max_turns/effort/
#         model, real Scope/Done criteria/Inputs/Out of scope text, and no
#         depends_on; bp-ledger.pl validate accepts it.
#   R  -- no section, or a section without write_set: author-ledger refuses
#         and writes nothing.
#   AV -- through apply_verdict, a refusal leaves the record queued, re-tagged
#         operator-action with a product_question, so the resolver does not
#         pick the same action again and a human is told; nothing is marked
#         applied.
#   X  -- an existing ledger is never overwritten.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $ORCH    = "$Bin/../../scripts/bp-orchestrator.pl";
my $RESOLVE = "$Bin/../../scripts/bp-resolve.pl";
my $LEDGER  = "$Bin/../../scripts/bp-ledger.pl";
require $ORCH;
require $RESOLVE;

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }
sub spew  { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "fixture $p: $!"; print {$fh} $c; close $fh }

sub fm_value {
    my ($bytes, $key) = @_;
    my ($fm) = $bytes =~ /\A---\s*\n(.*?)\n---/s;
    return undef unless defined $fm;
    return $1 if $fm =~ /^\Q$key\E:[ \t]*(.*?)[ \t]*$/m;
    return undef;
}

sub section_body {
    my ($bytes, $name) = @_;
    return $1 if $bytes =~ /^## \Q$name\E[ \t]*\n(.*?)(?=^## |\z)/ms;
    return undef;
}

# Mirrors the real acxpraxis-step-2 blueprint: a status-table row whose
# deliverable is a one-liner, and a full `### 12-model-merge` section in the
# shape the template documents (backticked paths, an HTML comment on a bullet).
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

my $NEXT = <<'MD';
### 13-model-push-check: the push-check model

- **scope:** Something else entirely.
- **done_criteria:** Not this package's.
- **write_set:** `models/push-check/`

## Constraints & known hazards

None.
MD

sub mk_bp {
    my ($blueprint) = @_;
    my $d = tempdir(CLEANUP => 1);
    $d =~ s{\\}{/}g;
    make_path("$d/packages", "$d/runs/escalations");
    spew("$d/blueprint.md", $blueprint);
    return $d;
}

my $FULL = "# Step 2\n\n$STATUS## Packages\n\n$SECTION$NEXT";

# ---- S: a full section yields a launchable, validate()-clean ledger --------
{
    my $bpdir = mk_bp($FULL);
    my ($ok, $why) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok($ok, 'S1: author-ledger succeeds from a complete ### section') or diag("refused: " . ($why // 'undef'));
    my $l = slurp("$bpdir/packages/12-model-merge.md") // '';
    ok(length $l, 'S2: the ledger exists');
    is(fm_value($l, 'write_set'),  'models/merge/',      'S3: write_set comes from the section, backticks and comment stripped');
    is(fm_value($l, 'test_paths'), 'models/merge/test/', 'S4: test_paths comes from the section');
    is(fm_value($l, 'checks'),     'quint-verify',       'S5: checks comes from the section');
    is(fm_value($l, 'max_turns'),  '650',                'S6: max_turns comes from the section');
    is(fm_value($l, 'effort'),     'high',               'S7: effort comes from the section');
    is(fm_value($l, 'model'),      'sonnet',             'S8: model comes from the section');
    is(fm_value($l, 'status'),     'pending',            'S9: status is pending');
    is(fm_value($l, 'package'),    '12-model-merge',     'S10: package');
    is(fm_value($l, 'blueprint'),  'acxpraxis-step-2',   'S11: blueprint');
    my ($fm) = $l =~ /\A---\s*\n(.*?)\n---/s;
    unlike($fm // '', qr/^depends_on:/m, 'S12: no depends_on in the frontmatter (ordering lives in the status table)');
    like(section_body($l, 'Scope') // '', qr/compare-and-swap ref updates,\s*\nand recovery after a crash/,
        'S13: Scope carries the section scope, continuation line included');
    unlike(section_body($l, 'Scope') // '', qr/\A\s*merge model\s*\z/, 'S14: Scope is not the status-row deliverable');
    like(section_body($l, 'Done criteria') // '', qr/As package 10's, for `models\/merge\/`\./, 'S15: Done criteria is real text');
    unlike($l, qr/\bTBD\b/, 'S16: no TBD placeholder anywhere');
    like(section_body($l, 'Inputs') // '', qr/docs\/architecture\.md \x{00a7}4\.2|docs\/architecture\.md \xC2\xA74\.2/,
        'S17: Inputs carries the section inputs, non-ASCII byte-exact');
    like(section_body($l, 'Out of scope') // '', qr/design fixes \(14\); other models\./, 'S18: Out of scope carries the section text');
    unlike($l, qr/Something else entirely/, 'S19: the next package section does not bleed in');
    like($l, qr/^# Package 12-model-merge \xE2\x80\x94 the merge model$/m, 'S20: title line uses the section title');
    unlike($l, qr/<Copied from the blueprint|<Testable, copied|<Files \(with line refs/,
        'S21: no template placeholder survives in the body sections');
    my $rc = system($^X, $LEDGER, 'validate', '--ledger', "$bpdir/packages/12-model-merge.md");
    is($rc >> 8, 0, 'S22: bp-ledger.pl validate accepts the authored ledger');
}

# ---- S-model fallback: the section has no model -> the status-table column --
{
    (my $sec = $SECTION) =~ s/^- \*\*model:\*\* sonnet\n//m;
    (my $st = $STATUS) =~ s/\| merge model \| 10-model-journal-recovery \| sonnet \|/| merge model | 10-model-journal-recovery | opus |/;
    my $bpdir = mk_bp("# Step 2\n\n$st## Packages\n\n$sec$NEXT");
    my ($ok, $why) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok($ok, 'S23: succeeds without a model bullet') or diag($why // '');
    is(fm_value(slurp("$bpdir/packages/12-model-merge.md") // '', 'model'), 'opus',
        'S24: model falls back to the status table');
}

# ---- R: refusals write nothing ---------------------------------------------
{
    my $bpdir = mk_bp("# Step 2\n\n$STATUS## Packages\n\n$NEXT");
    my ($ok, $why) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok(!$ok, 'R1: no ### section -> refused');
    like($why // '', qr/no '### 12-model-merge' section/, 'R2: the reason names the missing section');
    ok(!-e "$bpdir/packages/12-model-merge.md", 'R3: no stub ledger is written');
}
{
    (my $sec = $SECTION) =~ s/^- \*\*write_set:\*\*.*\n//m;
    my $bpdir = mk_bp("# Step 2\n\n$STATUS## Packages\n\n$sec$NEXT");
    my ($ok, $why) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok(!$ok, 'R4: a section without write_set -> refused');
    like($why // '', qr/no write_set/, 'R5: the reason names the missing write_set');
    ok(!-e "$bpdir/packages/12-model-merge.md", 'R6: no ledger is written');
}
{
    (my $sec = $SECTION) =~ s/^- \*\*done_criteria:\*\*.*\n//m;
    my $bpdir = mk_bp("# Step 2\n\n$STATUS## Packages\n\n$sec$NEXT");
    my ($ok, $why) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok(!$ok, 'R7: a section without done_criteria -> refused (never TBD)');
    ok(!-e "$bpdir/packages/12-model-merge.md", 'R8: no ledger is written');
}
{
    # A heading inside a fenced example is not the package's section.
    my $bpdir = mk_bp("# Step 2\n\n$STATUS## Packages\n\n```\n$SECTION```\n\n$NEXT");
    my ($ok) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok(!$ok, 'R9: a ### heading inside a code fence does not count');
}

# ---- X: never overwrite an existing ledger ---------------------------------
{
    my $bpdir = mk_bp($FULL);
    spew("$bpdir/packages/12-model-merge.md", "existing\n");
    my ($ok, $why) = BpResolve::_author_ledger('12-model-merge', { bp => 'acxpraxis-step-2', bpdir => $bpdir });
    ok(!$ok, 'X1: refused when a ledger already exists');
    is(slurp("$bpdir/packages/12-model-merge.md"), "existing\n", 'X2: the existing ledger is byte-identical');
}

# ---- AV: apply_verdict surfaces a refusal to a human -----------------------
my %VERDICT = (category => 'scoping', action => 'author-ledger', confidence => 'high',
               evidence => 'packages/12-model-merge.md missing', rationale => 'author the missing ledger');

sub queue {
    my ($bpdir, $id) = @_;
    my $rec = { package => '12-model-merge', blueprint => 'acxpraxis-step-2', kind => 'orphan',
                category => 'unclassified', question => 'ledger missing', created_at => 1 };
    spew("$bpdir/runs/escalations/$id.json", JSON::PP->new->canonical->encode($rec));
    return $rec;
}

{
    my $bpdir = mk_bp("# Step 2\n\n$STATUS## Packages\n\n$NEXT");
    my $id  = '12-model-merge--a1';
    my $rec = queue($bpdir, $id);
    my $out = BpResolve::apply_verdict({ %VERDICT }, $rec, $id,
        { bp => 'acxpraxis-step-2', bpdir => $bpdir, runs => "$bpdir/runs", log => "$bpdir/runs/orchestrator.log" });
    is($out->{applied}, 0, 'AV1: a refused author-ledger is not applied');
    is($out->{surfaced}, 'operator-action', 'AV2: the outcome says it was handed to a human');
    my $q = BpOrch::_read_json("$bpdir/runs/escalations/$id.json");
    ok(ref $q eq 'HASH', 'AV3: the queued record is still there (not marked resolved)');
    is($q->{category}, 'operator-action', 'AV4: re-tagged operator-action, so the resolver does not re-fire on it');
    ok(!$BpOrch::RESOLVER_TRIAGEABLE{ $q->{category} // '' }, 'AV5: no longer resolver-triageable');
    like($q->{product_question} // '', qr/12-model-merge.*no '### 12-model-merge' section/,
        'AV6: product_question carries the refusal reason');
    ok(!-e "$bpdir/packages/12-model-merge.md", 'AV7: no stub ledger');
    my $arc = BpOrch::_read_json("$bpdir/runs/resolved-escalations/$id.json");
    ok(ref $arc eq 'HASH' && !$arc->{applied}, 'AV8: the archive records applied=false');
}
{
    my $bpdir = mk_bp($FULL);
    my $id  = '12-model-merge--a2';
    my $rec = queue($bpdir, $id);
    my $out = BpResolve::apply_verdict({ %VERDICT }, $rec, $id,
        { bp => 'acxpraxis-step-2', bpdir => $bpdir, runs => "$bpdir/runs", log => "$bpdir/runs/orchestrator.log" });
    is($out->{applied}, 1, 'AV9: with a full section, apply_verdict applies author-ledger');
    ok(!-e "$bpdir/runs/escalations/$id.json", 'AV10: and the queued record is settled');
    is(fm_value(slurp("$bpdir/packages/12-model-merge.md") // '', 'write_set'), 'models/merge/',
        'AV11: the authored ledger carries the section write_set');
}

done_testing();
