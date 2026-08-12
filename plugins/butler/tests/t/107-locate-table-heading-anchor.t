#!/usr/bin/env perl
# t/107-locate-table-heading-anchor.t — a02-api-and-guard-defects, DEFECT 7.
# bp-blueprint.pl's locate_table latches onto the FIRST `|`-row anywhere in the
# document containing the literal "depends_on" as its header -- an ordinary
# prose table above the real "## Package status" table captures every typed
# verb, which then operates silently on the prose table while the real one sits
# untouched. Spec §2.4 / AC-21..AC-24. This IS the SYN-14 failure shape,
# reachable from ordinary prose (the ledger's own criterion 7).
#
# WRITTEN BLIND TO THE IMPLEMENTATION. Every AC-21/AC-22 assertion is expected
# to FAIL against the pre-change tree: today `status`/`set-status` operate on
# the PROSE table above the real one, and a `## Package status` section with no
# depends_on row falls back to a whole-document re-scan instead of refusing.
# AC-23/AC-24 are must-not-regress positive gates and are expected to PASS
# unchanged (they are the legacy-fallback / add-harvest paths the spec says are
# untouched).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";

# ORACLE-GAP (redteam MAJOR-5, step6): needed to independently re-derive
# BpOrch::parse_dag -- the READER this package deliberately left on the old
# global latch -- so the divergence against the WRITER's heading-anchored
# locate_table can be demonstrated, not merely asserted.
require "$BUTLER/scripts/bp-orchestrator.pl";

my $ROOT = tempdir(CLEANUP => 1);
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $pn = 0;

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes; close $w or die "close $path: $!"; return $path;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/; my $c = <$r>; close $r; return defined $c ? $c : '';
}

sub run_pl {
    my ($args, %opt) = @_;
    my $n = ++$pn;
    my ($outf, $errf) = ("$ROOT/out.$n", "$ROOT/err.$n");
    write_file($outf, ''); write_file($errf, '');
    local %ENV = (%CLEAN_ENV, BSCRIPT => fwd($SCRIPT), BOUT => fwd($outf), BERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$BSCRIPT" "$@" > "$BOUT" 2> "$BERR"', 'bp-blueprint', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

my $DONE    = "\xE2\x9C\x85";
my $PENDING = "\xE2\xAC\x9C";

# A fixture whose Objective section contains an ORDINARY prose table with a
# column header also named "depends_on" (nothing to do with the package table),
# ABOVE the real "## Package status" section. This is the exact SYN-14 shape
# hit while authoring this blueprint.
sub prose_above_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Objective',
        '',
        'Some narrative prose describing dependency relationships between external',
        'systems, illustrated with a table that happens to use the same column name:',
        '',
        '| system | depends_on | note |',
        '|---|---|---|',
        '| billing | auth, ledger | external, not a package |',
        '| ledger | auth | external, not a package |',
        '',
        '## Package status',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| real01 | first real thing | \xE2\x80\x94 | $DONE done | sonnet |",
        "| real02 | second real thing | real01 | $PENDING pending | sonnet |",
        '',
        '## Decisions', '',
        '- SYN-01: an earlier decision.',
        '',
    );
}

# Same as above, but the "## Package status" section's table has NO depends_on
# column at all (some other section-local shape) -- must refuse, not re-scan.
sub prose_above_no_depends_on_in_section_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Objective',
        '',
        '| system | depends_on | note |',
        '|---|---|---|',
        '| billing | auth, ledger | external, not a package |',
        '',
        '## Package status',
        '',
        'Nothing here has been filled in yet -- no table, just prose.',
        '',
        '## Decisions', '',
        '- SYN-01: an earlier decision.',
        '',
    );
}

# Legacy shape: a depends_on table and NO "## Package status" heading anywhere.
sub legacy_no_heading_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| legacy01 | thing | \xE2\x80\x94 | $DONE done | sonnet |",
        '',
        '## Decisions', '',
        '- SYN-01: an earlier decision.',
        '',
    );
}

sub stage { my ($bytes) = @_; my $n = ++$pn; my $d = "$ROOT/w$n"; mkdir $d or die; return write_file("$d/blueprint.md", $bytes); }

# ── AC-21: `status` lists the REAL packages, not the prose ones ────────────────
{
    my $path = stage(prose_above_fixture());
    my ($rc, $out, $err) = run_pl(['status', '--file', $path]);
    is($rc, 0, 'AC-21(status): exits 0') or diag("stderr: $err");
    like($out, qr/\breal01\b/, 'AC-21(status): output names the REAL package real01');
    like($out, qr/\breal02\b/, 'AC-21(status): output names the REAL package real02');
    unlike($out, qr/\bbilling\b/, 'AC-21(status): output does NOT name the prose table\'s "billing" row');
    unlike($out, qr/\bledger\b/, 'AC-21(status): output does NOT name the prose table\'s "ledger" row');
}

# ── AC-21: `set-status` mutates the REAL row; the prose table's bytes are unchanged ──
{
    my $path = stage(prose_above_fixture());
    my $before = read_file($path);
    my ($prose_before) = $before =~ /(\| system \| depends_on \| note \|.*?)\n\n## Package status/s;

    my ($rc, $out, $err) = run_pl(['set-status', '--file', $path, '--pkg', 'real02', '--status', 'done']);
    is($rc, 0, 'AC-21(set-status): exits 0 mutating the real table') or diag("stderr: $err");

    my $after = read_file($path);
    my ($prose_after) = $after =~ /(\| system \| depends_on \| note \|.*?)\n\n## Package status/s;
    is($prose_after, $prose_before, 'AC-21(set-status): the prose table\'s bytes are byte-identical after the mutation');

    like($after, qr/\| real02 \| second real thing \| real01 \| $DONE done \| sonnet \|/,
        'AC-21(set-status): the REAL row for real02 now reads done');
}

# ── AC-21: set-field / add-package also hit the real table (not batched with the
#           above -- separate calls so a defect-7 failure in one verb cannot mask
#           a pass in another) ─────────────────────────────────────────────────
{
    my $path = stage(prose_above_fixture());
    my ($rc, $out, $err) = run_pl(['set-field', '--file', $path, '--pkg', 'real01', '--field', 'model', '--value', 'opus']);
    is($rc, 0, 'AC-21(set-field): exits 0') or diag("stderr: $err");
    like(read_file($path), qr/\| real01 \| first real thing \| \xE2\x80\x94 \| $DONE done \| opus \|/,
        'AC-21(set-field): the REAL row for real01 now carries model=opus');
}
{
    my $path = stage(prose_above_fixture());
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $path, '--pkg', 'real03', '--deliverable', 'a third real thing']);
    is($rc, 0, 'AC-21(add-package): exits 0') or diag("stderr: $err");
    my $after = read_file($path);
    like($after, qr/\| real03 \|/, 'AC-21(add-package): the new row landed');
    # It must land in the REAL table (after real02, before ## Decisions), not the prose one.
    like($after, qr/real02.*?\n\| real03 \|.*?## Decisions/s,
        'AC-21(add-package): the new row landed inside the REAL Package status table, not the prose one');
}

# ── AC-22: a "## Package status" section with NO depends_on row -> write verbs
#           refuse (exit 2), file byte-identical -- no re-scan captures a table
#           elsewhere (in this fixture the ONLY depends_on table left is the
#           prose one, which must NOT be silently captured as a fallback) ─────
# Spec AC-22 speaks specifically of "the write verbs" (§4 / observable behavior
# 34); `status` is a READ op that already exits 5 ("no such column") rather than
# 2 on ANY table lacking a status column, pre- and post-fix alike, so it is not
# the right seam for this criterion and is deliberately not asserted here.
{
    my $path = stage(prose_above_no_depends_on_in_section_fixture());
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $path, '--pkg', 'billing', '--status', 'done']);
    is($rc, 2, 'AC-22(set-status): exits 2 -- refuses, never mutates the prose table under a different name');
    is(read_file($path), $before, 'AC-22(set-status): file byte-identical');
    like($err, qr/no package-status table found/i, 'AC-22(set-status): the existing "no package-status table found" message is used');
}
{
    my $path = stage(prose_above_no_depends_on_in_section_fixture());
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $path, '--pkg', 'newpkg', '--deliverable', 'x']);
    is($rc, 2, 'AC-22(add-package): exits 2 -- refuses, never captures the prose table');
    is(read_file($path), $before, 'AC-22(add-package): file byte-identical');
}

# ── AC-23: legacy fallback -- a depends_on table with NO "## Package status"
#           heading anywhere parses exactly as today ───────────────────────────
{
    my $path = stage(legacy_no_heading_fixture());
    my ($rc, $out, $err) = run_pl(['status', '--file', $path]);
    is($rc, 0, 'AC-23: legacy fixture (no heading) still parses -- exits 0') or diag("stderr: $err");
    like($out, qr/\blegacy01\b/, 'AC-23: legacy fixture\'s package is found via the whole-document scan');
}

# ── AC-24: add-harvest still lands in "## Harvest log" even with a prose
#           depends_on table above it ───────────────────────────────────────────
{
    my $fixture = join("\n",
        '# Blueprint: fixture-bp', '',
        '## Objective', '',
        '| system | depends_on | note |',
        '|---|---|---|',
        '| billing | auth | external |',
        '',
        '## Package status', '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| real01 | first real thing | \xE2\x80\x94 | $DONE done | sonnet |",
        '',
        '## Harvest log', '',
        '| pkg | outputs verified | by | date |',
        '|---|---|---|---|',
        '| | | | |',
        '',
    );
    my $path = stage($fixture);
    my ($rc, $out, $err) = run_pl(['add-harvest', '--file', $path, '--pkg', 'real01',
                                    '--outputs', 'checked the deliverable end to end']);
    is($rc, 0, 'AC-24: add-harvest exits 0 with a prose depends_on table above') or diag("stderr: $err");
    my $after = read_file($path);
    like($after, qr/## Harvest log.*?\| real01 \|.*checked the deliverable end to end/s,
        'AC-24: the harvest row landed inside "## Harvest log"');
}

# ── ORACLE-GAP (redteam MAJOR-5, step6): the WRITER (locate_table, heading-
#    anchored, fixed here) and the READER (BpOrch::parse_dag, deliberately
#    left on the old global first-match latch) now DIVERGE on
#    prose_above_fixture: the writer correctly finds the real table, but the
#    reader's whole-document scan latches onto the prose table's OWN header
#    row (itself containing the literal "depends_on"), mis-parses it as the
#    package-status header, and returns an EMPTY dag -- silently. add-package
#    reports success while the orchestrator's view of the DAG is zero
#    packages. The driver's stated condition for accepting this writer/reader
#    split was that the divergence be DETECTABLE/LOUD, not silent. Confirm
#    the divergence exists (this passes -- it documents the bug), then assert
#    SOME loud signal exists on the add-package call that created it (this is
#    the gap: nothing today makes it loud). ─────────────────────────────────
{
    my $path = stage(prose_above_fixture());
    my $before_dag = BpOrch::parse_dag(read_file($path));
    is_deeply([ sort keys %$before_dag ], [],
        'ORACLE-GAP(MAJOR-5) precondition: BpOrch::parse_dag sees an EMPTY dag on the prose-above fixture (documents the divergence)');

    my ($rc, $out, $err) = run_pl(['add-package', '--file', $path, '--pkg', 'real99', '--deliverable', 'a fourth real thing']);
    is($rc, 0, 'ORACLE-GAP(MAJOR-5): add-package still reports success on this fixture (the writer side is correct)')
        or diag("stderr: $err");

    my $after_dag = BpOrch::parse_dag(read_file($path));
    is_deeply([ sort keys %$after_dag ], [],
        'ORACLE-GAP(MAJOR-5) postcondition: the reader STILL sees an empty dag after the write -- every package, old and new, invisible to it');

    like($err, qr/depends_on|header-hijack|prose table|divergence|hijack/i,
        'ORACLE-GAP(MAJOR-5): add-package must say SOMETHING (stderr) when it wrote into a table the reader cannot see -- currently silent')
        or diag("stderr was: '$err'");
}

# ── ORACLE-GAP (redteam MAJOR-6, step6): a fenced code block CONTAINING the
#    literal text "## Package status" (e.g. a blueprint documenting its own
#    format, which authoring guidance encourages) precedes the REAL heading.
#    $PKG_STATUS_HEAD_RE has no fenced-region awareness, so it anchors on the
#    fenced line, the section it computes ends at the real heading (which
#    also matches `^##\s`), and no depends_on row exists in that empty span
#    -> refuse. Measured: HEAD worked fine; working tree bricks EVERY typed
#    write for the whole blueprint (rc=2, "no package-status table found").
#    Because blueprint.md may only be mutated through these typed verbs, this
#    takes out set-status/set-deps/add-package/set-field entirely. Must NOT
#    brick -- the real table below the fence must still be found. ──────────
{
    my $fixture = join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Objective',
        '',
        'This blueprint documents the format it uses, for reference:',
        '',
        '```',
        '## Package status',
        '```',
        '',
        '## Package status',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| real01 | first real thing | \xE2\x80\x94 | $PENDING pending | sonnet |",
        '',
        '## Decisions', '',
        '- SYN-01: an earlier decision.',
        '',
    );
    my $path = stage($fixture);
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $path, '--pkg', 'real01', '--status', 'done']);
    is($rc, 0, 'ORACLE-GAP(MAJOR-6): set-status does NOT brick when a fenced code block containing "## Package status" precedes the real heading')
        or diag("stderr: $err");
    like(read_file($path), qr/\| real01 \| first real thing \| \xE2\x80\x94 \| $DONE done \| sonnet \|/,
        'ORACLE-GAP(MAJOR-6): the real row was actually updated, not the fenced text');
}

done_testing();
