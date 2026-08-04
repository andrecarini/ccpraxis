#!/usr/bin/env perl
# b50-write-set-implied-checks oracle.
#
# THE PROBLEM (external report, techcontas-ux-refine, 13 packages):
# every package verified its own `test_paths` and reported green, and five
# defects still reached the closing gate -- each because the check that would
# have caught it was in NO package's done-criteria. A package's gate answers
# "do my tests pass?"; it needs to answer "is everything my write set can break
# still working?". `test_paths` is a SCOPE LIMITER, not a check list.
#
# THREE OPERATOR-ACCEPTED CORRECTIONS constrain the design, and each has an
# assertion below:
#
#   1 (BLOCKING) The derivation table is PROJECT-SUPPLIED, never plugin-hardcoded.
#     Every row of the reporter's table names a JS/TS/Firebase artefact
#     (tsc --noEmit, Vitest, functions/src/**, Firestore indexes, *.rules).
#     ccpraxis is stack-agnostic and its OWN blueprints are pure Perl, where
#     every row is inapplicable. A project with no table must degrade to today's
#     behaviour, not inherit a foreign stack's checklist.
#
#   2 The harvest judge is contractually confined to its slice ("Do not wander
#     the wider repo"). It therefore cannot verify a check RAN unless the check
#     leaves a DECLARED ARTEFACT that joins that slice.
#
#   3 A declarative `checks:` field that nothing enforces is the same defect as
#     b23's prose-fixed/mechanism-unfixed divergence, wearing a new field name --
#     and worse than no field, because it reads as coverage.
#
# NO SHAPE PINS: no fixed count of check types, no pinned table contents. The
# table is read from a fixture this file builds. (t/00-oracle-hygiene.t.)

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp ();
use File::Path qw(make_path);
use File::Spec;

my $ROOT   = File::Spec->rel2abs("$Bin/../../../..");
my $CHECKS = "$ROOT/plugins/butler/scripts/bp-checks.pl";

ok(-f $CHECKS, 'bp-checks.pl exists') or BAIL_OUT("missing: $CHECKS");
require $CHECKS;

# --------------------------------------------------------------- fixtures ---

sub build_bp {
    my (%a) = @_;                       # table => text|undef, packages => { name => {write_set, checks} }
    my $dir = File::Temp->newdir(CLEANUP => 1);
    my $d   = "$dir";
    make_path("$d/packages");

    my $bp = "# blueprint: fixture\n\n";
    $bp .= $a{table} if defined $a{table};
    open my $fh, '>', "$d/blueprint.md" or die $!;
    print $fh $bp;
    close $fh;

    for my $p (sort keys %{ $a{packages} || {} }) {
        my $spec = $a{packages}{$p};
        open my $lf, '>', "$d/packages/$p.md" or die $!;
        print $lf "---\npackage: $p\nstatus: pending\n";
        print $lf "write_set: $spec->{write_set}\n";
        print $lf "checks: $spec->{checks}\n" if defined $spec->{checks};
        print $lf "---\n\n# $p\n";
        close $lf;
    }
    return ($dir, $d);                  # keep the object alive
}

# A table naming checks that mean nothing to ccpraxis, deliberately: it proves
# the mechanism carries a PROJECT's vocabulary rather than one baked in here.
my $TABLE = <<'T';
```checks-table
*.ts        => typecheck
*.ts        => lint
functions/  => prod-build
*.rules     => rules-emulator
```
T

# ------------------------------------------ C1: no table => degrade quietly ---
#
# CORRECTION 1. This is the assertion that keeps ccpraxis stack-agnostic: a
# pure-Perl blueprint that supplies no table must behave exactly as it does
# today, never inheriting a JS checklist.

{
    my ($keep, $d) = build_bp(
        packages => { 'p01' => { write_set => 'src/a.ts' } },   # no checks: at all
    );
    my $out = `perl "$CHECKS" audit --blueprint "$d/blueprint.md" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'C1: with NO project table, audit passes -- a stack-agnostic tool imposes no checklist')
        or diag($out);
}

# ------------------------------- C2: table + omitted implied check => FAIL ---
#
# CORRECTION 3's teeth. Without this the `checks:` field is a declaration that
# nothing enforces.

{
    my ($keep, $d) = build_bp(
        table    => $TABLE,
        packages => { 'p01' => { write_set => 'src/a.ts', checks => 'lint' } },  # typecheck missing
    );
    my $out = `perl "$CHECKS" audit --blueprint "$d/blueprint.md" 2>&1`;
    my $rc  = $? >> 8;

    isnt($rc, 0, 'C2: a package omitting a check its write set implies FAILS the audit')
        or diag($out);
    like($out, qr/typecheck/, 'C2: the failure NAMES the missing check, not just a count');
    like($out, qr/p01/,       'C2: the failure names the offending package');
}

# --------------------------------- C3: table + all implied checks => PASS ----
#
# The counterpart. Without it, C2 could pass because the audit fails on
# everything.

{
    my ($keep, $d) = build_bp(
        table    => $TABLE,
        packages => { 'p01' => { write_set => 'src/a.ts', checks => 'typecheck:lint' } },
    );
    my $out = `perl "$CHECKS" audit --blueprint "$d/blueprint.md" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'C3 (counterpart): a package declaring every implied check PASSES')
        or diag($out);
}

# ------------------------------------- C4: matching is by PATH, not by luck ---
#
# A write set that touches nothing the table names implies nothing. Otherwise
# the audit would demand a prod-build of a package that never goes near
# functions/.

{
    my ($keep, $d) = build_bp(
        table    => $TABLE,
        packages => { 'p01' => { write_set => 'docs/readme.md' } },
    );
    my $out = `perl "$CHECKS" audit --blueprint "$d/blueprint.md" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'C4: a write set matching no table row implies no checks')
        or diag($out);
}

# --------------------------------------------- C5: the prefix row matches ----

{
    my ($keep, $d) = build_bp(
        table    => $TABLE,
        packages => { 'p01' => { write_set => 'functions/src/x.js', checks => '' } },
    );
    my $out = `perl "$CHECKS" audit --blueprint "$d/blueprint.md" 2>&1`;
    my $rc  = $? >> 8;
    isnt($rc, 0, 'C5: a directory-prefix row (functions/) implies its check');
    like($out, qr/prod-build/, 'C5: and names it');
}

# ----------------------------------------------- C6..C8: the DOCUMENTATION ---
#
# Each of these is a rule the operator accepted; prose is the deliverable for
# them, so prose is what is asserted. Content, never heading counts.

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/; <$fh>;
}

my $coord   = slurp("$ROOT/plugins/butler/skills/coordinator-protocol/SKILL.md");
my $auditor = slurp("$ROOT/plugins/blueprint/agents/bp-auditor.md");
my $harvest = slurp("$ROOT/plugins/butler/agents/bp-harvest-judge.md");
my $ledger  = slurp("$ROOT/plugins/blueprint/templates/package-ledger.md");

like($ledger, qr/^checks:/m,
    'C6: the ledger template carries a `checks:` field');

like($coord, qr/even (?:when|if) the criteria omit/i,
    'C6: coordinator-protocol requires running implied checks even when the criteria omit one');

like($auditor, qr/bp-checks\.pl/,
    'C7: bp-auditor is told to run the derivation, not to eyeball it');

like($harvest, qr/artefact|artifact/i,
    'C8: bp-harvest-judge verifies a check ran via a declared artefact');
like($harvest, qr/slice/i,
    'C8: and its read-only-the-slice contract is restated rather than quietly widened');

# --------------------------- C9: the visual class is NOT claimed as closed ---
#
# The reporter was explicit that the 185px-offscreen spinner is not closed by
# any of this, and that it argues for KEEPING a human-read pass. Asserted so the
# visual sign-off is not quietly dropped on the belief that checks now cover it.

like($coord, qr/bp-ui-prober|visual/i,
    'C9: the shipped doctrine says this does not close the visual class');

done_testing();
