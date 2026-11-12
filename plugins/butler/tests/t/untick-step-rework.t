#!/usr/bin/env perl
# platform: any
# bp-ledger.pl untick-step --from N --reason R: rework after a finished pipeline.
#
# A package reopened after its last step (failed harvest, reset with new scope)
# kept every box ticked, so the operator's panel showed no current step beside a
# live coordinator (acxpraxis-step-2 package 15, 2026-11-12).
#
#   U1  unticks every done step numbered >= N, and only those
#   U2  skipped / n/a-marked steps stay ticked with their marker
#   U3  one attempt-log entry names the unticked steps and the reason
#   U4  nothing left to untick is a no-op: exit 0, file byte-identical
#   U5  usage errors exit 3 and touch nothing (bad --from, missing --reason)
#   U6  the result still validates, and tick-step re-ticks a step normally
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

my $LEDGER_PL = abs_path("$Bin/../../scripts/bp-ledger.pl");
ok(-f $LEDGER_PL, "subject exists: $LEDGER_PL") or BAIL_OUT('no bp-ledger.pl');
my $EM = "\xE2\x80\x94";

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub spit  { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print $fh $c; close $fh }
sub shq   { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'" }
sub ledger_cli {
    my (@args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $LEDGER_PL, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# A ledger shaped like the real template, every step done, scout skipped, ui n/a.
sub mk_ledger {
    my $d = tempdir(CLEANUP => 1);
    my $p = "$d/15-x.md";
    spit($p, join("\n",
        '---', 'package: 15-x', 'blueprint: bp', 'status: running', 'model: sonnet', 'effort: medium',
        'max_turns: 800', 'write_set: models/', 'test_paths: models/t/', 'checks: none',
        'last_updated: 2026-11-12T00:00:00Z', '---', '', '# 15-x', '',
        '## Scope', '', 'x', '', '## Done criteria', '', 'x', '', '## Inputs', '', 'x', '',
        '## Out of scope', '', 'x', '', '## Next action', '', 'go', '', '## Outputs', '', '- none', '',
        '## Escalation (when status: blocked)', '', '_(none)_', '',
        '## Pipeline', '',
        "- [x] 1. Scout (skip if scope already maps cleanly) $EM skipped: inputs map it",
        '- [x] 2. Spec written to specs/<NN-slug>-spec.md and checked against done criteria',
        '- [x] 3. Tests written from spec (bp-test-writer) and sanity-checked against spec',
        '- [x] 4. Implementation converged (bp-implementer; tests immutable; loop <= 4 attempts)',
        '- [x] 5. Validation suite green from disk (commands + exit codes recorded below)',
        '- [x] 6. Review and red-team complete (report paths below)',
        '- [x] 7. Fix-batch applied (single dispatch) and re-validated',
        "- [x] 8. UI pass (only if package touches UI) $EM n/a: no UI",
        '', '## Decisions & attempt log', '', '- 2026-11-12T00:00:00Z ' . $EM . ' started', ''));
    return $p;
}
sub box { my ($txt, $n) = @_; return $txt =~ /^\s*-\s*\[([ xX])\]\s*$n\./m ? $1 : undef }

my $L = mk_ledger();
my ($rc0, $out0) = ledger_cli('validate', '--ledger', $L);
is($rc0, 0, 'precondition: the fixture validates') or diag($out0);

# U1 + U2 + U3
{
    my ($rc, $out) = ledger_cli('untick-step', '--ledger', $L, '--from', '3', '--reason', 'Decision 40 rework');
    is($rc, 0, 'U1: untick-step --from 3 exits 0') or diag($out);
    is($out, '', 'U1: stdout and stderr empty on success');
    my $t = slurp($L);
    is(box($t, 2), 'x', 'U1: step 2 (below --from) stays ticked');
    is(box($t, $_), ' ', "U1: step $_ unticked") for 3 .. 7;
    is(box($t, 1), 'x', 'U2: the skipped scout stays ticked');
    like($t, qr/^- \[x\] 8\. UI pass.* \Q$EM\E n\/a: no UI$/m, 'U2: the n/a ui step keeps its tick and marker');
    my @e = $t =~ /^(- \S+ \Q$EM\E Rework: .*)$/mg;
    is(scalar @e, 1, 'U3: exactly one rework entry');
    like($e[0] // '', qr/Rework: steps 3, 4, 5, 6, 7 unticked: Decision 40 rework$/, 'U3: it names the steps and the reason');
}

# U4: nothing left to untick
{
    my $before = slurp($L);
    my ($rc, $out) = ledger_cli('untick-step', '--ledger', $L, '--from', '3', '--reason', 'again');
    is($rc, 0, 'U4: a second call exits 0');
    is(slurp($L), $before, 'U4: and leaves the file byte-identical (no second entry)');
}

# U5: usage errors
{
    my $before = slurp($L);
    my ($rc1) = ledger_cli('untick-step', '--ledger', $L, '--from', '03', '--reason', 'x');
    is($rc1, 3, 'U5: a leading-zero --from is a usage error');
    my ($rc2) = ledger_cli('untick-step', '--ledger', $L, '--from', '2');
    is($rc2, 3, 'U5: a missing --reason is a usage error');
    my ($rc3) = ledger_cli('untick-step', '--ledger', $L, '--reason', 'x');
    is($rc3, 3, 'U5: a missing --from is a usage error');
    is(slurp($L), $before, 'U5: none of them touched the ledger');
}

# U6
{
    my ($rc, $out) = ledger_cli('validate', '--ledger', $L);
    is($rc, 0, 'U6: the reworked ledger validates') or diag($out);
    my ($rc2, $out2) = ledger_cli('tick-step', '--ledger', $L, '--step', '3');
    is($rc2, 0, 'U6: tick-step re-ticks a reworked step') or diag($out2);
    is(box(slurp($L), 3), 'x', 'U6: step 3 is ticked again');
}

done_testing();
