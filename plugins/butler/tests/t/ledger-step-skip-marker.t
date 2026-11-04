#!/usr/bin/env perl
# platform: any
# `bp-ledger.pl tick-step --skipped|--na --reason R [--force-remark]`: a pipeline step
# that was skipped (or did not apply) is still TICKED, and says so as data on its own
# line:
#
#   - [x] <N>.<original step text> — skipped: <reason>
#   - [x] <N>.<original step text> — n/a: <reason>
#
# (separator: space, U+2014, space; first occurrence wins; reason to end of line).
# Before this, a skip was visible only in attempt-log prose. This file pins:
#   * the exact line each flag writes, and the automatic attempt-log entry;
#   * the refusals (missing/empty/over-long reason, conflicting flags, re-marking a
#     step already ticked as done or with another marker, all byte-identical);
#   * validate accepts the marker;
#   * claim-check (what harvest runs) treats a marked step as ticked and reports the
#     marker as data, while an unticked step still fires PIPELINE_STEP_UNTICKED;
#   * a plain tick and an old-style ledger are unaffected.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1; $ENV{BP_ORACLE_RECORD} = '0' }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP ();
use POSIX ();

my $LEDGER_PL = "$Bin/../../scripts/bp-ledger.pl";
my $TEMPLATE  = "$Bin/../../../blueprint/templates/package-ledger.md";
ok(-f $LEDGER_PL && -f $TEMPLATE, 'bp-ledger.pl and the ledger template exist') or BAIL_OUT('missing inputs');

my $EM  = "\xE2\x80\x94";
my $DIR = tempdir(CLEANUP => 1);

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or die "slurp $p: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub spew {
    my ($p, $c) = @_;
    open my $fh, '>:raw', $p or die "spew $p: $!";
    print {$fh} $c;
    close $fh;
}

# run_pl(@argv) -> ($exit, $stdout, $stderr). Child output captured via files (never
# an in-memory scalar: Git-for-Windows perl fails with "Bad file descriptor").
my $RUN_N = 0;
sub run_pl {
    my (@argv) = @_;
    $RUN_N++;
    my ($o, $e) = ("$DIR/out.$RUN_N", "$DIR/err.$RUN_N");
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', $o or POSIX::_exit(127);
        open STDERR, '>', $e or POSIX::_exit(127);
        exec($^X, $LEDGER_PL, @argv) or POSIX::_exit(127);
    }
    my $deadline = time + 60;
    my $got;
    while (1) {
        $got = waitpid($pid, POSIX::WNOHANG());
        last if $got == $pid;
        if (time > $deadline) { kill 'KILL', $pid; waitpid($pid, 0); return (124, '', 'timeout') }
        select(undef, undef, undef, 0.05);
    }
    return ($? >> 8, slurp($o), slurp($e));
}

# The template's own pipeline lines, so a template wording change cannot leave this
# file asserting against stale step text.
my $tpl = slurp($TEMPLATE);
my ($pipeline) = $tpl =~ /^## Pipeline\n\n(.*?)\n\n## /ms;
ok(defined $pipeline && $pipeline =~ /^- \[ \] 8\. /m, 'template pipeline extracted') or BAIL_OUT('no pipeline');
my %STEP_TEXT = map { /^- \[ \] (\d+)\.(.*)$/ ? ($1 => $2) : () } split /\n/, $pipeline;

my $N_LEDGER = 0;
sub mk_ledger {
    my (%o) = @_;
    $N_LEDGER++;
    my $p = "$DIR/ledger$N_LEDGER.md";
    my $pipe = defined $o{pipeline} ? $o{pipeline} : $pipeline;
    spew($p, join("\n",
        '---',
        'package: 01-skip-fixture',
        'blueprint: skip-fixture',
        'status: ' . ($o{status} // 'running'),
        'write_set: plugins/x/',
        'test_paths: plugins/x/tests/t/none.t',
        'last_updated: 2026-01-01T00:00:00Z',
        '---',
        '',
        '# Package 01-skip-fixture',
        '',
        '## Pipeline',
        '',
        $pipe,
        '',
        '## Decisions & attempt log',
        '',
        '- 2026-01-01T00:00:00Z ' . $EM . ' created',
        '',
        '## Next action',
        '',
        'Do the thing.',
        '',
        '## Outputs',
        '',
        '_(none yet)_',
        '',
        '## Escalation (when status: blocked)',
        '',
        '_(none)_',
        '',
    ));
    return $p;
}

sub step_line {
    my ($B, $n) = @_;
    my ($l) = $B =~ /^(- \[[ xX]\] \Q$n\E\..*)$/m;
    return $l;
}

sub attempts { my ($B) = @_; my ($s) = $B =~ /^## Decisions & attempt log\n(.*?)^## /ms; return grep { /^- / } split /\n/, ($s // '') }

my $ISO = qr/\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ/;

# ---------------------------------------------------------------------------
# 1. --skipped writes exactly the documented line + one attempt entry
# ---------------------------------------------------------------------------
{
    my $L = mk_ledger();
    my ($rc, $out, $err) = run_pl('tick-step', '--ledger', $L, '--step', '1', '--skipped',
                                  '--reason', 'inputs already map the terrain');
    is($rc, 0, 'skipped: exit 0') or diag($err);
    is($out, '', 'skipped: stdout empty');
    my $B = slurp($L);
    is(step_line($B, 1), "- [x] 1.$STEP_TEXT{1} $EM skipped: inputs already map the terrain",
       'skipped: step 1 line is exactly box [x] + original text + " — skipped: <reason>"');
    my @a = grep { /Step 1/ } attempts($B);
    is(scalar(@a), 1, 'skipped: exactly one attempt entry appended');
    like($a[0] // '', qr/\A- $ISO \Q$EM\E Step 1 skipped: inputs already map the terrain\z/,
         'skipped: attempt entry reads "- <ISO> — Step 1 skipped: <reason>"');
    is(step_line($B, 2), "- [ ] 2.$STEP_TEXT{2}", 'skipped: other steps untouched');

    # Idempotent: the identical call again is byte-identical (no second attempt).
    my $before = $B;
    ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '1', '--skipped', '--reason', 'inputs already map the terrain');
    is($rc, 0, 'skipped: identical re-run exits 0');
    is(slurp($L), $before, 'skipped: identical re-run is byte-identical');

    # A plain tick on a skipped step leaves it as it is.
    ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '1');
    is($rc, 0, 'plain tick on a skipped step exits 0');
    is(slurp($L), $before, 'plain tick on a skipped step is byte-identical (marker kept)');

    ($rc, $out, $err) = run_pl('validate', '--ledger', $L);
    is($rc, 0, 'validate accepts a ledger carrying a skipped marker') or diag($err);
}

# ---------------------------------------------------------------------------
# 2. --na, and reason normalisation
# ---------------------------------------------------------------------------
{
    my $L = mk_ledger();
    my ($rc, $out, $err) = run_pl('tick-step', '--ledger', $L, '--step', '8', '--na',
                                  '--reason', "  no   UI\nin this\tpackage ");
    is($rc, 0, 'na: exit 0') or diag($err);
    my $B = slurp($L);
    is(step_line($B, 8), "- [x] 8.$STEP_TEXT{8} $EM n/a: no UI in this package",
       'na: step 8 line carries " — n/a: <reason>", whitespace collapsed to one line');
    my @a = grep { /Step 8/ } attempts($B);
    is(scalar(@a), 1, 'na: exactly one attempt entry');
    like($a[0] // '', qr/\A- $ISO \Q$EM\E Step 8 not applicable: no UI in this package\z/,
         'na: attempt entry reads "Step 8 not applicable: <reason>"');
    ($rc) = run_pl('validate', '--ledger', $L);
    is($rc, 0, 'validate accepts a ledger carrying an n/a marker');

    my $r200 = 'r' x 200;
    ($rc, $out, $err) = run_pl('tick-step', '--ledger', $L, '--step', '7', '--skipped', '--reason', $r200);
    is($rc, 0, 'a 200-byte reason (the cap) is accepted') or diag($err);
}

# ---------------------------------------------------------------------------
# 3. Argument refusals: exit 3, byte-identical
# ---------------------------------------------------------------------------
{
    my $L = mk_ledger();
    my $orig = slurp($L);
    my @cases = (
        ['--skipped without --reason',      ['--step', '1', '--skipped']],
        ['--na without --reason',           ['--step', '8', '--na']],
        ['--skipped with a blank reason',   ['--step', '1', '--skipped', '--reason', "  \n "]],
        ['--skipped and --na together',     ['--step', '1', '--skipped', '--na', '--reason', 'x']],
        ['--reason without a skip flag',    ['--step', '1', '--reason', 'x']],
        ['--force-remark without a flag',   ['--step', '1', '--force-remark']],
        ['a 201-byte reason',               ['--step', '1', '--skipped', '--reason', 'r' x 201]],
    );
    for my $c (@cases) {
        my ($name, $args) = @$c;
        my ($rc, $out, $err) = run_pl('tick-step', '--ledger', $L, @$args);
        is($rc, 3, "refusal: $name -> exit 3");
        my @lines = grep { length } split /\n/, $err;
        is(scalar(@lines), 1, "refusal: $name -> exactly one stderr line");
        is(slurp($L), $orig, "refusal: $name -> ledger byte-identical");
    }
    my ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '9', '--skipped', '--reason', 'x');
    is($rc, 5, 'refusal: a step the pipeline does not have -> exit 5');
    is(slurp($L), $orig, 'refusal: missing step -> ledger byte-identical');
}

# ---------------------------------------------------------------------------
# 4. Re-marking refusals and --force-remark
# ---------------------------------------------------------------------------
{
    my $L = mk_ledger();
    my ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '2');
    is($rc, 0, 'remark: plain tick of step 2 exits 0');
    my $done = slurp($L);
    is(step_line($done, 2), "- [x] 2.$STEP_TEXT{2}", 'remark: a plain tick writes no marker');

    my ($rc2, $out2, $err2) = run_pl('tick-step', '--ledger', $L, '--step', '2', '--skipped', '--reason', 'late');
    is($rc2, 2, 'remark: --skipped on a step already ticked as done -> exit 2');
    like($err2, qr/already ticked as done/, 'remark: the refusal says the step is already done');
    like($err2, qr/--force-remark/, 'remark: the refusal names --force-remark');
    is(slurp($L), $done, 'remark: refused re-mark is byte-identical');

    ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '1', '--skipped', '--reason', 'first');
    is($rc, 0, 'remark: skip step 1 exits 0');
    my $skipped = slurp($L);
    my ($rc3, undef, $err3) = run_pl('tick-step', '--ledger', $L, '--step', '1', '--na', '--reason', 'second');
    is($rc3, 2, 'remark: a different marker on an already-marked step -> exit 2');
    like($err3, qr/already marked 'skipped: first'/, 'remark: the refusal names the existing marker');
    is(slurp($L), $skipped, 'remark: refused marker change is byte-identical');

    ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '1', '--na', '--reason', 'second', '--force-remark');
    is($rc, 0, 'remark: --force-remark replaces a marker');
    my $B = slurp($L);
    is(step_line($B, 1), "- [x] 1.$STEP_TEXT{1} $EM n/a: second",
       'remark: the old marker is replaced, never stacked');
    is(scalar(grep { /Step 1 / } attempts($B)), 2, 'remark: the forced re-mark appends its own attempt entry');

    ($rc) = run_pl('tick-step', '--ledger', $L, '--step', '2', '--skipped', '--reason', 'late', '--force-remark');
    is($rc, 0, 'remark: --force-remark marks a step already ticked as done');
    is(step_line(slurp($L), 2), "- [x] 2.$STEP_TEXT{2} $EM skipped: late", 'remark: done step now carries the marker');
}

# ---------------------------------------------------------------------------
# 5. claim-check (harvest's mechanical gate) treats a marked step as ticked
# ---------------------------------------------------------------------------
sub claim {
    my ($L) = @_;
    my ($rc, $out, $err) = run_pl('claim-check', '--ledger', $L);
    my $r = eval { JSON::PP->new->decode($out) };
    return ($rc, $r, $err);
}
{
    my $L = mk_ledger();
    run_pl('tick-step', '--ledger', $L, '--step', '1', '--skipped', '--reason', 'inputs map it');
    run_pl('tick-step', '--ledger', $L, '--step', $_) for 2 .. 6;
    run_pl('tick-step', '--ledger', $L, '--step', '8', '--na', '--reason', 'no UI');
    my ($rc) = run_pl('set-status', '--ledger', $L, '--status', 'done');
    is($rc, 0, 'claim: set-status done exits 0');

    my ($rc1, $r1) = claim($L);
    is($rc1, 0, 'claim: claim-check exits 0');
    ok($r1, 'claim: claim-check printed JSON') or BAIL_OUT('no report');
    my @unt = grep { $_->{code} eq 'PIPELINE_STEP_UNTICKED' } @{ $r1->{findings} || [] };
    is_deeply([ map { $_->{step} } @unt ], [7],
              'claim: only the genuinely unticked step 7 fires PIPELINE_STEP_UNTICKED (not skipped 1, not n/a 8)');
    my %it = map { ($_->{step} => $_) } @{ $r1->{pipeline}{items} || [] };
    ok($it{1} && $it{1}{ticked} && $it{1}{satisfied}, 'claim: skipped step 1 is ticked and satisfied');
    is($it{1}{skip}, 'skipped', 'claim: step 1 reports skip "skipped"');
    is($it{1}{skip_reason}, 'inputs map it', 'claim: step 1 reports its skip reason');
    is($it{8}{skip}, 'n/a', 'claim: step 8 reports skip "n/a"');
    ok($it{8}{ticked} && $it{8}{satisfied}, 'claim: n/a step 8 is ticked and satisfied');
    ok(!defined $it{2}{skip}, 'claim: a plainly ticked step reports no skip');

    run_pl('tick-step', '--ledger', $L, '--step', '7', '--skipped', '--reason', 'no findings to batch');
    my (undef, $r2) = claim($L);
    is(scalar(grep { $_->{code} eq 'PIPELINE_STEP_UNTICKED' } @{ $r2->{findings} || [] }), 0,
       'claim: once step 7 is skipped too, no PIPELINE_STEP_UNTICKED remains');
}

# ---------------------------------------------------------------------------
# 6. Old-style ledgers are unaffected
# ---------------------------------------------------------------------------
{
    (my $old = $pipeline) =~ s/^- \[ \]/- [x]/mg;
    my $L = mk_ledger(pipeline => $old, status => 'done');
    my ($rc) = run_pl('validate', '--ledger', $L);
    is($rc, 0, 'old-style: an all-ticked ledger with no markers validates');
    my (undef, $r) = claim($L);
    is(scalar(grep { $_->{code} eq 'PIPELINE_STEP_UNTICKED' } @{ $r->{findings} || [] }), 0,
       'old-style: no PIPELINE_STEP_UNTICKED');
    is(scalar(grep { defined $_->{skip} } @{ $r->{pipeline}{items} || [] }), 0,
       'old-style: every step reads as done (no skip)');

    my $L2 = mk_ledger();
    my $before = slurp($L2);
    ($rc) = run_pl('tick-step', '--ledger', $L2, '--step', '4');
    is($rc, 0, 'old-style: plain tick exits 0');
    my $after = slurp($L2);
    (my $want = $before) =~ s/^- \[ \] 4\./- [x] 4./m;
    is($after, $want, 'old-style: a plain tick flips exactly the one box and nothing else');
}

done_testing();
