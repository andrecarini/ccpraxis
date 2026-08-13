#!/usr/bin/env perl
# t/118-table-has-no-status.t — s03-drop-table-status-column oracle.
#
# WRITTEN BLIND TO THE IMPLEMENTATION, derived from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/s03-drop-table-status-column-spec.md
# section 5 (item numbers below match that list) and section 7 (DC1-DC8 acceptance
# criteria). Every assertion here is expected to FAIL against the pre-edit tree,
# because as of this file's authoring bp-blueprint.pl still accepts set-status,
# set-field --field status and add-package --status, still ships the glyph/legend
# vocabulary, and the template still carries a status column.
#
# NEVER MUTATE A LIVE blueprint.md. Every mutating assertion runs on a File::Temp
# copy. :raw throughout.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";
my $ORCH   = "$BUTLER/scripts/bp-orchestrator.pl";
my $STATUSSH = "$BUTLER/scripts/bp-status.sh";
my $TEMPLATE  = "$PROJ/plugins/blueprint/templates/blueprint.md";

ok(-f $SCRIPT,   'sanity: bp-blueprint.pl exists') or BAIL_OUT('nothing to test');
ok(-f $TEMPLATE, 'sanity: the blueprint template exists') or BAIL_OUT('nothing to test');

require $ORCH;

my $ROOT = tempdir(CLEANUP => 1);
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $pn = 0;

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub digest_of { md5_hex(read_file($_[0]) // '') }

my $dn = 0;
sub fresh_dir { my $d = "$ROOT/w" . (++$dn); mkdir $d or die "mkdir $d: $!"; return $d }

sub stage { my ($bytes) = @_; my $d = fresh_dir(); return write_file("$d/blueprint.md", $bytes) }

sub run_pl {
    my ($args) = @_;
    my $n = ++$pn;
    my ($outf, $errf) = ("$ROOT/out.$n", "$ROOT/err.$n");
    write_file($outf, ''); write_file($errf, '');
    local %ENV = (%CLEAN_ENV, BWA_SCRIPT => fwd($SCRIPT), BWA_OUT => fwd($outf), BWA_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$BWA_SCRIPT" "$@" > "$BWA_OUT" 2> "$BWA_ERR"', 'bp-blueprint', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

# NEW-SHAPE fixture (no status column) -- the shape this package produces.
sub new_shape_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | model |',
        '|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | sonnet |",
        "| b02 | second thing | b01 | sonnet |",
        '',
        '## Decisions',
        '',
        '- SYN-01: an earlier decision, no hazard token here.',
        '',
    );
}

# OLD-SHAPE fixture (status column present) -- Decision 13 tolerance target.
sub old_shape_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | done | sonnet |",
        "| b02 | second thing | b01 | pending | sonnet |",
        '',
        '## Decisions',
        '',
        '- SYN-01: an earlier decision, no hazard token here.',
        '',
    );
}

# Resolve a real, substantial OLD-SHAPE blueprint.md by PROPERTY (largest file
# under .ccpraxis-local-data/blueprints), never by a hardcoded initiative name --
# same reasoning as t/86-blueprint-write-api.t's $LIVE_BP (a fixture that names a
# specific initiative is a fixture with an expiry date). Every criterion that uses
# it SKIPs when nothing qualifies.
my $BP_ROOT_DIRS = "$PROJ/.ccpraxis-local-data/blueprints";
my $LIVE_OLD_SHAPE = do {
    my @cands = sort { -s $b <=> -s $a }
                grep { -f && -s $_ > 50_000 }
                (glob("$BP_ROOT_DIRS/*/blueprint.md"), glob("$BP_ROOT_DIRS/_archive/*/blueprint.md"));
    $cands[0];
};
my $HAVE_OLD_SHAPE = defined $LIVE_OLD_SHAPE && -f $LIVE_OLD_SHAPE;

sub stage_live_old_shape_copy {
    return undef unless $HAVE_OLD_SHAPE;
    my $bytes = read_file($LIVE_OLD_SHAPE);
    return undef unless defined $bytes;
    my $d = fresh_dir();
    my $dst = "$d/blueprint.md";
    write_file($dst, $bytes);
    return $dst;
}

# The ledger-pointer text a retired verb's refusal must carry (spec §2.2). Checked
# as several independent substrings rather than one long regex, so a message that
# drifts wording but keeps the pointer still passes, while a GENERIC error (or a
# silent no-op that merely also happens to exit non-zero) does not: none of these
# substrings are things a generic "unsupported"/"bad option" message would contain.
my @LEDGER_POINTER_SUBSTRINGS = (
    qr/Decision 11/,
    qr/bp-ledger\.pl\s+set-status/,
    qr/ledger-guard\.sh/,
    qr/BpState/,
);

sub assert_ledger_pointer {
    my ($err, $label) = @_;
    for my $re (@LEDGER_POINTER_SUBSTRINGS) {
        like($err, $re, "$label: stderr matches ledger-pointer substring $re");
    }
}

# ===========================================================================
# Item 1 (criterion 1 / DC1): template has no status column, no legend line.
# ===========================================================================
{
    my $tpl = read_file($TEMPLATE);
    ok(defined $tpl, 'item1: template is readable');
    unlike($tpl, qr/\|\s*status\s*\|/i,
        'item1: the template table has no `status` column header cell');
    unlike($tpl, qr/^\s*Status values:/m,
        'item1: the template has no "Status values:" legend line');
    # Positive control: the four authored columns are still present, so a
    # template that lost the WHOLE table (vacuously passing the above) is
    # caught here.
    like($tpl, qr/\|\s*pkg\s*\|\s*deliverable\s*\|\s*depends_on\s*\|\s*model\s*\|/,
        'item1: the template table still has exactly the four authored columns, in order');
}

# ===========================================================================
# Item 2 (criterion 2/3, DC2/DC3, behaviors 1/2/4): retired verbs fail loudly.
# ===========================================================================
{
    my $p = stage(new_shape_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b02', '--status', 'done']);
    is($rc, 3, 'item2(set-status): exits 3');
    assert_ledger_pointer($err, 'item2(set-status)');
    is(read_file($p), $orig, 'item2(set-status): file byte-identical (never attempted, not merely undone)');
}
{
    my $p = stage(new_shape_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-field', '--file', $p, '--pkg', 'b02', '--field', 'status', '--value', 'done']);
    is($rc, 3, 'item2(set-field --field status): exits 3');
    assert_ledger_pointer($err, 'item2(set-field --field status)');
    is(read_file($p), $orig, 'item2(set-field --field status): file byte-identical');
}
{
    my $p = stage(new_shape_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $p, '--pkg', 'b09', '--deliverable', 'x', '--status', 'done']);
    is($rc, 3, 'item2(add-package --status): exits 3');
    like($err, qr/--status/, 'item2(add-package --status): message names --status');
    assert_ledger_pointer($err, 'item2(add-package --status)');
    is(read_file($p), $orig, 'item2(add-package --status): file byte-identical');
}

# Old-shape target too: retirement is unconditional regardless of table shape
# (spec behavior 1: "regardless of whether F's table has a status column").
{
    my $p = stage(old_shape_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b02', '--status', 'done']);
    is($rc, 3, 'item2(set-status, old-shape table): exits 3 too -- retirement is unconditional on table shape');
    assert_ledger_pointer($err, 'item2(set-status, old-shape table)');
    is(read_file($p), $orig, 'item2(set-status, old-shape table): file byte-identical');
}

# ===========================================================================
# Item 3 (criterion 2, behavior 3): set-field --field model is unaffected.
# ===========================================================================
{
    my $p = stage(new_shape_fixture());
    my ($rc, $out, $err) = run_pl(['set-field', '--file', $p, '--pkg', 'b02', '--field', 'model', '--value', 'opus']);
    is($rc, 0, 'item3: set-field --field model still exits 0') or diag("stderr: $err");
    like(read_file($p), qr/\|\s*b02\s*\|[^\n]*\|\s*opus\s*\|/,
        'item3: model cell actually changed to opus');
}

# Behavior 5: add-package WITHOUT --status still succeeds on a new-shape table,
# and the new row has no status cell (there is none to have).
{
    my $p = stage(new_shape_fixture());
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $p, '--pkg', 'b09', '--deliverable', 'ninth thing']);
    is($rc, 0, 'item3b(behavior5): add-package without --status exits 0') or diag("stderr: $err");
    my $new = read_file($p);
    like($new, qr/\|\s*b09\s*\|/, 'item3b(behavior5): the new row landed');
    # 4 pipe-delimited cells after the leading empty split field, matching the
    # 4-column new shape -- not 5.
    my ($row) = $new =~ /^(\|\s*b09\s*\|.*)$/m;
    ok(defined $row, 'item3b(behavior5): b09 row is capturable');
    # Split on `|` WITHOUT dropping empty cells (a trailing unset column, e.g.
    # an empty model cell, is a legitimate 4th cell, not an absent one) --
    # leading/trailing empty strings from the outer pipes are stripped instead.
    my @cells = split /\|/, $row, -1;
    shift @cells;   # the empty string before the leading pipe
    pop @cells;     # the empty string after the trailing pipe
    is(scalar(@cells), 4, 'item3b(behavior5): the new row has exactly 4 cells (no status cell)');
}

# ===========================================================================
# Item 4 (criterion 6/DC4, behavior 6): status --file on a new-shape table.
# ===========================================================================
{
    my $p = stage(new_shape_fixture());
    my ($rc, $out, $err) = run_pl(['status', '--file', $p]);
    is($rc, 5, "item4: status against a new-shape table exits 5");
    like($err, qr/no\s+'status'\s+column/i, "item4: message says the table has no 'status' column");
}

# ===========================================================================
# Item 5 (criterion 6/DC4/DC7, behavior 7): status --file on the real
# archived old-shape fixture (copy, never the live path).
# ===========================================================================
SKIP: {
    skip('item5: no substantial old-shape blueprint.md available as a fixture', 2)
        unless $HAVE_OLD_SHAPE;
    my $p = stage_live_old_shape_copy();
    skip('item5: could not stage a copy of the old-shape fixture', 2) unless defined $p;
    my ($rc, $out, $err) = run_pl(['status', '--file', $p]);
    is($rc, 0, 'item5: status against the real archived old-shape fixture exits 0') or diag("stderr: $err");
    ok(length($out) > 0, 'item5: ...and prints real per-package values');
}

# ===========================================================================
# Item 6 (criterion 4/DC4, behavior 8): `ready` is deleted.
# ===========================================================================
{
    my $p = stage(new_shape_fixture());
    my ($rc, $out, $err) = run_pl(['ready', '--file', $p]);
    isnt($rc, 0, 'item6: ready exits non-zero');
    like($err, qr/unknown subcommand\s+'ready'/i, "item6: stderr reports ready as an unknown subcommand");
}

# ===========================================================================
# Item 7 (criterion 4, behaviors 10/11): parse_dag on both table shapes.
# ===========================================================================
{
    my $c = new_shape_fixture();
    my $dag = BpOrch::parse_dag($c);
    ok(exists $dag->{b01} && exists $dag->{b02},
        'item7(new-shape): parse_dag sees both packages');
    is_deeply($dag->{b02}, ['b01'], 'item7(new-shape): b02 depends on b01');
    is_deeply($dag->{b01}, [], 'item7(new-shape): b01 depends on nothing (em-dash rejected)');
}
{
    my $c = old_shape_fixture();
    my $dag = BpOrch::parse_dag($c);
    ok(exists $dag->{b01} && exists $dag->{b02},
        'item7(old-shape): parse_dag sees both packages despite the extra status column');
    is_deeply($dag->{b02}, ['b01'], 'item7(old-shape): b02 depends on b01');
}
SKIP: {
    skip('item7(live old-shape): no substantial old-shape blueprint.md available', 1)
        unless $HAVE_OLD_SHAPE;
    my $c = read_file($LIVE_OLD_SHAPE);
    my $dag = BpOrch::parse_dag($c);
    ok(scalar(keys %$dag) > 0,
        'item7(live old-shape): parse_dag returns a non-empty graph on the real archived fixture');
}

# ===========================================================================
# Item 8 (criterion 7, behavior 12): add-package against the old-shape
# fixture (copy) does not choke.
# ===========================================================================
{
    my $p = stage(old_shape_fixture());
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $p, '--pkg', 'b03', '--deliverable', 'third thing', '--deps', 'b02']);
    is($rc, 0, 'item8: add-package against an old-shape (5-col) table exits 0') or diag("stderr: $err");
    my $new = read_file($p);
    like($new, qr/\|\s*b03\s*\|/, 'item8: the new row landed');
    my $dag = BpOrch::parse_dag($new);
    ok(exists $dag->{b03}, 'item8: parse_dag sees the new package on the old-shape table');
}

# ===========================================================================
# Item 9 (criterion 4, behavior 13): bp-status.sh reads ledgers only.
# ===========================================================================
{
    my $src = read_file($STATUSSH);
    ok(defined $src, 'item9: bp-status.sh is readable');
    unlike($src, qr/bp-blueprint\.pl\s+status\b/,
        'item9: bp-status.sh never shells out to `bp-blueprint.pl status`');
    unlike($src, qr/col_index/,
        'item9: bp-status.sh never references col_index (a table-status read primitive)');
}

# ===========================================================================
# Item 10 (criterion 5, behavior 14): locate_table's source is untouched by
# this package's diff -- a coarse content check, not a byte-diff (this file
# has no baseline snapshot to diff against; the identifying comment text is
# pinned instead, per spec §5 item 10's "coarse content check" allowance).
# ===========================================================================
{
    my $src = read_file($SCRIPT);
    ok(defined $src, 'item10: bp-blueprint.pl is readable');
    like($src, qr/step-6 red-team MAJOR-6/,
        'item10: locate_table still carries its step-6/MAJOR-6 fence-skipping comment verbatim');
    like($src, qr/collect EVERY unfenced/,
        'item10: locate_table still describes collecting every unfenced heading candidate');
    like($src, qr/REFUSE; no legacy re-scan once ANY heading was found/,
        'item10: locate_table still refuses rather than re-scanning once a heading was found');
}

# ===========================================================================
# Item 11 (criterion 1/2, §2.4): deleted symbols are actually gone.
# ===========================================================================
{
    my $src = read_file($SCRIPT);
    ok(defined $src, 'item11: bp-blueprint.pl is readable');
    unlike($src, qr/\$G_DROPPED\b/, 'item11: $G_DROPPED is gone');
    unlike($src, qr/\@STATUS_VALUES\b/, 'item11: @STATUS_VALUES is gone');
    unlike($src, qr/%WORD2GLYPH\b|\bWORD2GLYPH\b/, 'item11: %WORD2GLYPH is gone');
    unlike($src, qr/\bstatus_help\b/, 'item11: status_help is gone');
    unlike($src, qr/\bnormalize_status\b/, 'item11: normalize_status is gone');
    unlike($src, qr/\bop_refresh_legend\b/, 'item11: op_refresh_legend is gone');
    unlike($src, qr/'refresh-legend'/, 'item11: the refresh-legend dispatch entry is gone');
}

# ===========================================================================
# Extra (criterion 1, §2.4): op_ready itself is deleted, not merely retired.
# ===========================================================================
{
    my $src = read_file($SCRIPT);
    unlike($src, qr/\bop_ready\b/, 'extra: op_ready is deleted outright (not retired-with-message)');
}

done_testing();
