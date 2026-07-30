use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use FindBin qw($Bin);

# --- load the unit under test (guarded: it does not exist yet) ---
my $VAL = "$Bin/../../scripts/bp-validate-dag.pl";
my $have_val = (-f $VAL) ? (eval { require $VAL; 1 } ? 1 : 0) : 0;

# Fail closed, and say WHY in one place. Most assertions below sit inside
# SKIP blocks, so without this the only symptom of a validator that exists but
# dies at require() would be a scatter of "returns a defined result" failures.
# This package exists to kill gates that never run and never say so; its own
# oracle does not get to be one.
ok($have_val, 'bp-validate-dag.pl exists and loads cleanly')
    or diag("validator did not load: $VAL" . ($@ ? " -- $@" : ''));

# --- orchestrator: already exists, real DAG parser/cycle-finder (BpOrch::) ---
require "$Bin/../../scripts/bp-orchestrator.pl";

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Write blueprint.md verbatim (caller controls every line, so line-number
# assertions in structural ACs are exact).
sub write_bp_md {
    my ($dir, @lines) = @_;
    open my $fh, '>', "$dir/blueprint.md" or die "write blueprint.md: $!";
    print $fh join("\n", @lines), "\n";
    close $fh;
}

# One package-status table (header + separator + one row per pkg).
sub table_lines {
    my (@pkgs) = @_;
    my @lines = ('| pkg | status | depends_on |', '|---|---|---|');
    for my $p (@pkgs) {
        my $dep = defined $p->{dep} ? $p->{dep} : '';
        push @lines, "| $p->{id} | pending | $dep |";
    }
    return @lines;
}

# Write packages/<id>.md with frontmatter. write_set defaults to a non-empty
# value; pass write_set => '' for an empty key, write_set => undef to omit
# the key entirely.
sub mk_ledger {
    my ($dir, $id, %fm) = @_;
    mkdir "$dir/packages" unless -d "$dir/packages";
    my $status = exists $fm{status} ? $fm{status} : 'pending';
    my $have_ws = exists $fm{write_set} ? (defined $fm{write_set} ? 1 : 0) : 1;
    my $ws = exists $fm{write_set} ? $fm{write_set} : "lib/$id.pl";
    open my $fh, '>', "$dir/packages/$id.md" or die "write ledger $id: $!";
    print $fh "---\n";
    print $fh "status: $status\n";
    print $fh "write_set: $ws\n" if $have_ws;
    print $fh "---\n\n# $id\n";
    close $fh;
}

# Full fixture: a blueprint.md status table plus matching ledgers, from a
# list of { id => ..., dep => ..., write_set => ..., no_ledger => 1 } specs.
sub setup_bp {
    my ($dir, @pkgs) = @_;
    write_bp_md($dir, '# Blueprint', '', '## Package Status', table_lines(@pkgs));
    for my $p (@pkgs) {
        next if $p->{no_ledger};
        my %fm;
        $fm{write_set} = $p->{write_set} if exists $p->{write_set};
        mk_ledger($dir, $p->{id}, %fm);
    }
}

# Call validate($bpdir) however the unit under test exposes it, without
# dying if it's missing or broken.
sub call_validate {
    my ($dir) = @_;
    return undef unless $have_val;
    my $result;
    eval {
        if (defined &main::validate) {
            $result = main::validate($dir);
        } elsif (BpValidateDag->can('validate')) {
            $result = BpValidateDag::validate($dir);
        }
    };
    return $result;
}

sub by_code {
    my ($arr, $code) = @_;
    return grep { defined $_->{code} && $_->{code} eq $code } @$arr;
}

# ---------------------------------------------------------------------------
# AC-1: validate($bpdir) returns a HASHREF with exactly the §2.9 keys, each
# of the stated type, for every input including the error paths.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-1: validate() returns a defined result');
    SKIP: {
        skip 'validate() unavailable', 12 unless defined $r;
        is(ref($r), 'HASH', 'AC-1: result is a HASHREF');
        ok($r->{ok} == 0 || $r->{ok} == 1, 'AC-1: ok is 0 or 1');
        is($r->{bpdir}, $dir, 'AC-1: bpdir echoes the input');
        is(ref($r->{packages}), 'ARRAY', 'AC-1: packages is an ARRAYREF');
        is(ref($r->{ledgers}), 'ARRAY', 'AC-1: ledgers is an ARRAYREF');
        is(ref($r->{dag}), 'HASH', 'AC-1: dag is a HASHREF');
        is(ref($r->{fixed_dag}), 'HASH', 'AC-1: fixed_dag is a HASHREF');
        is(ref($r->{normalized}), 'ARRAY', 'AC-1: normalized is an ARRAYREF');
        is(ref($r->{ambiguous}), 'ARRAY', 'AC-1: ambiguous is an ARRAYREF');
        is(ref($r->{structural}), 'ARRAY', 'AC-1: structural is an ARRAYREF');
        is(ref($r->{findings}), 'ARRAY', 'AC-1: findings is an ARRAYREF');
        ok(!ref($r->{summary}) && defined $r->{summary}, 'AC-1: summary is a STRING');
    }
}

# ---------------------------------------------------------------------------
# AC-2: clean blueprint -> ok == 1; normalized/ambiguous/structural/findings
# are all [].
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01-alpha' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-2: validate() returns a defined result on a clean blueprint')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 5 unless defined $r;
        is($r->{ok}, 1, 'AC-2: ok == 1 for a clean blueprint');
        is_deeply($r->{normalized}, [], 'AC-2: normalized is []');
        is_deeply($r->{ambiguous}, [], 'AC-2: ambiguous is []');
        is_deeply($r->{structural}, [], 'AC-2: structural is []');
        is_deeply($r->{findings}, [], 'AC-2: findings is []');
    }
}

# ---------------------------------------------------------------------------
# AC-3: short-id dep -> ok == 1; one normalized dep-short-id record;
# fixed_dag carries the full name, dag still carries the short token.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-3: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 6 unless defined $r;
        is($r->{ok}, 1, 'AC-3: ok == 1 for a short-id dep');
        my @n = by_code($r->{normalized}, 'dep-short-id');
        is(scalar @n, 1, 'AC-3: exactly one dep-short-id record');
        is($n[0]{package}, 'b02-beta', 'AC-3: normalized record names the depending package');
        is($n[0]{from}, 'b01', 'AC-3: from is the short token as written');
        is($n[0]{to}, 'b01-alpha', 'AC-3: to is the resolved full package name');
        is_deeply($r->{fixed_dag}{'b02-beta'}, ['b01-alpha'], 'AC-3: fixed_dag carries the full name');
        is_deeply($r->{dag}{'b02-beta'}, ['b01'], 'AC-3: dag still carries the raw short token');
    }
}

# ---------------------------------------------------------------------------
# AC-4: case-only dep -> ok == 1; one normalized dep-case record.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-Alpha' }, { id => 'b02-beta', dep => 'b01-alpha' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-4: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 2 unless defined $r;
        is($r->{ok}, 1, 'AC-4: ok == 1 for a case-only dep');
        my @n = by_code($r->{normalized}, 'dep-case');
        is(scalar @n, 1, 'AC-4: exactly one dep-case record');
    }
}

# ---------------------------------------------------------------------------
# AC-5: self-dep -> ok == 1; one dep-self record with to undef; fixed_dag
# for that package omits it.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha', dep => 'b01-alpha' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-5: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 4 unless defined $r;
        is($r->{ok}, 1, 'AC-5: ok == 1 for a self-dep');
        my @n = by_code($r->{normalized}, 'dep-self');
        is(scalar @n, 1, 'AC-5: exactly one dep-self record');
        is($n[0]{to}, undef, 'AC-5: dep-self record has to undef');
        is_deeply($r->{fixed_dag}{'b01-alpha'}, [], 'AC-5: fixed_dag omits the self-dep');
    }
}

# ---------------------------------------------------------------------------
# AC-6: short id + its own full name in one cell -> ok == 1; one
# dep-short-id and one dep-duplicate; fixed_dag lists the full name once.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01, b01-alpha' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-6: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 4 unless defined $r;
        is($r->{ok}, 1, 'AC-6: ok == 1 for short-id + full-name duplicate');
        is(scalar(by_code($r->{normalized}, 'dep-short-id')), 1, 'AC-6: one dep-short-id record');
        is(scalar(by_code($r->{normalized}, 'dep-duplicate')), 1, 'AC-6: one dep-duplicate record');
        is_deeply($r->{fixed_dag}{'b02-beta'}, ['b01-alpha'], 'AC-6: fixed_dag lists the full name exactly once');
    }
}

# ---------------------------------------------------------------------------
# AC-7: dangling dep -> ok == 0; one ambiguous dep-dangling finding whose
# detail is the token and whose message contains "names no package";
# fixed_dag preserves the token verbatim.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha', dep => 'zzz-nonexistent' });
    my $r = call_validate($dir);
    ok(defined $r, 'AC-7: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 6 unless defined $r;
        is($r->{ok}, 0, 'AC-7: ok == 0 for a dangling dep');
        my @a = by_code($r->{ambiguous}, 'dep-dangling');
        is(scalar @a, 1, 'AC-7: one ambiguous dep-dangling finding');
        is($a[0]{severity}, 'ambiguous', 'AC-7: severity is literally ambiguous');
        is($a[0]{detail}, 'zzz-nonexistent', 'AC-7: detail is the dangling token');
        like($a[0]{message}, qr/names no package/, 'AC-7: message contains "names no package"');
        is_deeply($r->{fixed_dag}{'b01-alpha'}, ['zzz-nonexistent'], 'AC-7: fixed_dag preserves the token verbatim');
    }
}

# ---------------------------------------------------------------------------
# AC-8: a short id matching two packages -> ok == 0; one dep-ambiguous
# finding naming both candidates; fixed_dag preserves the token verbatim.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir,
        { id => 'b01-alpha' },
        { id => 'b01-beta' },
        { id => 'b02-gamma', dep => 'b01' },
    );
    my $r = call_validate($dir);
    ok(defined $r, 'AC-8: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 5 unless defined $r;
        is($r->{ok}, 0, 'AC-8: ok == 0 for an ambiguous short id');
        my @a = by_code($r->{ambiguous}, 'dep-ambiguous');
        is(scalar @a, 1, 'AC-8: one dep-ambiguous finding');
        like($a[0]{message}, qr/b01-alpha/, 'AC-8: message names candidate b01-alpha');
        like($a[0]{message}, qr/b01-beta/, 'AC-8: message names candidate b01-beta');
        is_deeply($r->{fixed_dag}{'b02-gamma'}, ['b01'], 'AC-8: fixed_dag preserves the token verbatim (no silent pick)');
    }
}

# ---------------------------------------------------------------------------
# AC-9: a 3-package cycle -> ok == 0; exactly one dep-cycle finding; members
# rotated to start at the lexicographically smallest; message joins by " -> ".
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir,
        { id => 'b01-alpha', dep => 'b02-beta' },
        { id => 'b02-beta', dep => 'b03-gamma' },
        { id => 'b03-gamma', dep => 'b01-alpha' },
    );
    my $r = call_validate($dir);
    ok(defined $r, 'AC-9: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 4 unless defined $r;
        is($r->{ok}, 0, 'AC-9: ok == 0 for a 3-package cycle');
        my @c = by_code($r->{ambiguous}, 'dep-cycle');
        is(scalar @c, 1, 'AC-9: exactly one dep-cycle finding');
        is($c[0]{members}[0], 'b01-alpha', 'AC-9: members rotated to start at lexicographically smallest');
        like($c[0]{message}, qr/b01-alpha\s*->\s*b02-beta\s*->\s*b03-gamma/, 'AC-9: message joins every member by " -> "');
    }
}

# ---------------------------------------------------------------------------
# AC-10: BpOrch::find_cycles returns an empty list on an acyclic DAG, and
# one arrayref per distinct cycle when two disjoint cycles exist.
# ---------------------------------------------------------------------------
{
    my $acyclic = { a => ['b'], b => ['c'], c => [] };
    my @cycles;
    my $ok1 = eval { @cycles = BpOrch::find_cycles($acyclic); 1 };
    ok($ok1, 'AC-10: BpOrch::find_cycles is callable') or diag("died: $@");
    is(scalar @cycles, 0, 'AC-10: find_cycles returns empty list on an acyclic DAG') if $ok1;

    my $two_cycles = { a => ['b'], b => ['a'], c => ['d'], d => ['c'] };
    my @c2;
    my $ok2 = eval { @c2 = BpOrch::find_cycles($two_cycles); 1 };
    ok($ok2, 'AC-10: BpOrch::find_cycles is callable on a two-cycle DAG') or diag("died: $@");
    is(scalar @c2, 2, 'AC-10: find_cycles returns one arrayref per distinct cycle for two disjoint cycles') if $ok2;
}

# ---------------------------------------------------------------------------
# AC-11: validate($bpdir)->{dag} is is_deeply-equal to
# BpOrch::parse_dag(<blueprint.md text>) -- proving the validator uses the
# real parser and did not grow a second one.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01-alpha' });
    my $text = do {
        local $/;
        open my $fh, '<', "$dir/blueprint.md" or die $!;
        <$fh>;
    };
    my $expected;
    my $parse_ok = eval { $expected = BpOrch::parse_dag($text); 1 };
    ok($parse_ok, 'AC-11: BpOrch::parse_dag is callable') or diag("died: $@");
    my $r = call_validate($dir);
    ok(defined $r, 'AC-11: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 1 unless defined $r && $parse_ok;
        is_deeply($r->{dag}, $expected, 'AC-11: validate()->{dag} matches BpOrch::parse_dag output verbatim');
    }
}

# ---------------------------------------------------------------------------
# AC-12: a depends_on-bearing table BEFORE the status table -> ok == 0;
# findings include header-hijack (message naming two 1-based line numbers)
# and a pkg-not-in-table per ledger that vanished.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    write_bp_md($dir,
        '# Blueprint',                        # 1
        '',                                    # 2
        'Some notes',                          # 3
        '| foo | depends_on |',                # 4  <- bogus header, hijacks the latch
        '|---|---|',                            # 5
        '| x | y |',                            # 6
        '',                                     # 7
        '## Package Status',                    # 8
        '| pkg | status | depends_on |',    # 9  <- real header
        '|---|---|---|',                        # 10
        '| b01-alpha | pending |  |',           # 11
    );
    mk_ledger($dir, 'b01-alpha');
    my $r = call_validate($dir);
    ok(defined $r, 'AC-12: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 5 unless defined $r;
        is($r->{ok}, 0, 'AC-12: ok == 0 when a bogus depends_on table precedes the real one');
        my @hh = by_code($r->{structural}, 'header-hijack');
        is(scalar @hh, 1, 'AC-12: one header-hijack finding');
        like($hh[0]{message}, qr/4/, 'AC-12: message names the first hijacking line (4)');
        like($hh[0]{message}, qr/9/, 'AC-12: message names the real header line (9)');
        my @pnit = by_code($r->{structural}, 'pkg-not-in-table');
        ok(scalar(@pnit) >= 1, 'AC-12: at least one pkg-not-in-table for a ledger that vanished');
    }
}

# ---------------------------------------------------------------------------
# AC-13: a status table split by a ### heading with real package rows after
# it -> ok == 0; table-split finding names the interrupting line and every
# dropped package id.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    write_bp_md($dir,
        '# Blueprint',                        # 1
        '',                                    # 2
        '## Package Status',                   # 3
        '| pkg | status | depends_on |',   # 4  <- header
        '|---|---|---|',                        # 5
        '| b01-alpha | pending |  |',           # 6
        '### Interruption',                    # 7  <- terminates the table
        '| b02-beta | pending |  |',            # 8  <- dropped row
    );
    mk_ledger($dir, 'b01-alpha');
    mk_ledger($dir, 'b02-beta');
    my $r = call_validate($dir);
    ok(defined $r, 'AC-13: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 4 unless defined $r;
        is($r->{ok}, 0, 'AC-13: ok == 0 when the status table is split');
        my @ts = by_code($r->{structural}, 'table-split');
        is(scalar @ts, 1, 'AC-13: one table-split finding');
        like($ts[0]{message}, qr/7/, 'AC-13: message names the interrupting line (7)');
        like($ts[0]{message}, qr/b02-beta/, 'AC-13: message names every dropped package id');
    }
}

# ---------------------------------------------------------------------------
# AC-14: a raw | inside a cell -> ok == 0, cell-pipe with expected-vs-actual
# column counts. A \| inside a cell -> ok == 0, cell-pipe (even when the
# column count happens to match).
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    write_bp_md($dir,
        '# Blueprint',
        '',
        '## Package Status',
        '| pkg | status | depends_on |',
        '|---|---|---|',
        '| b01-alpha | pen|ding |  |',          # raw pipe -> column count mismatch
        '| b02-beta | pending | esc\\|aped |',  # escaped pipe -> lying escape
    );
    mk_ledger($dir, 'b01-alpha');
    mk_ledger($dir, 'b02-beta');
    my $r = call_validate($dir);
    ok(defined $r, 'AC-14: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 3 unless defined $r;
        is($r->{ok}, 0, 'AC-14: ok == 0 when a cell contains a raw or escaped pipe');
        my @cp = by_code($r->{structural}, 'cell-pipe');
        ok(scalar(@cp) >= 2, 'AC-14: cell-pipe fires for both the raw-pipe row and the escaped-pipe row');
        ok((grep { $_->{message} =~ /expected \d+ columns?, got \d+/i } @cp), 'AC-14: message states expected-vs-actual column counts');
    }
}

# ---------------------------------------------------------------------------
# AC-15: a ledger whose write_set: is empty (and one with the key absent) ->
# ok == 0, one write-set-empty per package, message containing
# "write-set serialization".
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir,
        { id => 'b01-alpha', write_set => '' },
        { id => 'b02-beta', write_set => undef },
    );
    my $r = call_validate($dir);
    ok(defined $r, 'AC-15: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 3 unless defined $r;
        is($r->{ok}, 0, 'AC-15: ok == 0 when a write_set is empty or absent');
        my @ws = by_code($r->{structural}, 'write-set-empty');
        is(scalar @ws, 2, 'AC-15: one write-set-empty per offending package (empty and absent)');
        ok((grep { $_->{message} =~ /write-set serialization/ } @ws) == 2, 'AC-15: every message contains "write-set serialization"');
    }
}

# ---------------------------------------------------------------------------
# AC-16: a ledger with no table row -> pkg-not-in-table (message contains
# "invisible to the orchestrator"). A table row with no ledger ->
# pkg-not-on-disk. Both directions in one fixture.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir,
        { id => 'b01-alpha' },
        { id => 'b02-beta', no_ledger => 1 },   # table row, no ledger -> pkg-not-on-disk
    );
    mk_ledger($dir, 'b03-gamma');                # ledger, no table row -> pkg-not-in-table
    my $r = call_validate($dir);
    ok(defined $r, 'AC-16: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 4 unless defined $r;
        my @pnit = by_code($r->{structural}, 'pkg-not-in-table');
        is(scalar @pnit, 1, 'AC-16: one pkg-not-in-table for the ledger with no table row');
        like($pnit[0]{message}, qr/invisible to the orchestrator/, 'AC-16: message contains "invisible to the orchestrator"');
        my @pnod = by_code($r->{structural}, 'pkg-not-on-disk');
        is(scalar @pnod, 1, 'AC-16: one pkg-not-on-disk for the table row with no ledger');
        is($pnod[0]{package} || $pnod[0]{detail}, 'b02-beta', 'AC-16: pkg-not-on-disk names the package id');
    }
}

# ---------------------------------------------------------------------------
# AC-17: missing/unreadable blueprint.md -> ok == 0, exactly one
# blueprint-missing finding, no exception thrown, all other keys present
# and well-typed.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    # deliberately no blueprint.md
    my $r;
    my $died = !eval { $r = call_validate($dir); 1 };
    ok(!$died, 'AC-17: validate() does not throw when blueprint.md is missing');
    ok(defined $r, 'AC-17: validate() returns a defined result')
        or diag('validate() unavailable or died');
    SKIP: {
        skip 'validate() unavailable', 4 unless defined $r;
        is($r->{ok}, 0, 'AC-17: ok == 0 when blueprint.md is missing');
        my @bm = by_code($r->{structural}, 'blueprint-missing');
        is(scalar @bm, 1, 'AC-17: exactly one blueprint-missing finding');
        like($bm[0]{message}, qr/blueprint\.md/, 'AC-17: message names the path');
        is(ref($r->{packages}), 'ARRAY', 'AC-17: packages key still present and well-typed');
    }
}

# ---------------------------------------------------------------------------
# AC-18: validate() is read-only: after a call on a normalizable blueprint,
# blueprint.md's bytes and mtime and every packages/*.md's bytes are
# unchanged.
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    setup_bp($dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01' });

    my $slurp = sub {
        my ($f) = @_;
        local $/;
        open my $fh, '<', $f or die $!;
        return <$fh>;
    };

    my $bp_before = $slurp->("$dir/blueprint.md");
    my @mtime_before = stat("$dir/blueprint.md");
    my $l1_before = $slurp->("$dir/packages/b01-alpha.md");
    my $l2_before = $slurp->("$dir/packages/b02-beta.md");

    call_validate($dir);

    my $bp_after = $slurp->("$dir/blueprint.md");
    my @mtime_after = stat("$dir/blueprint.md");
    my $l1_after = $slurp->("$dir/packages/b01-alpha.md");
    my $l2_after = $slurp->("$dir/packages/b02-beta.md");

    is($bp_after, $bp_before, 'AC-18: blueprint.md bytes unchanged after validate()');
    is($mtime_after[9], $mtime_before[9], 'AC-18: blueprint.md mtime unchanged after validate()');
    is($l1_after, $l1_before, 'AC-18: packages/b01-alpha.md bytes unchanged after validate()');
    is($l2_after, $l2_before, 'AC-18: packages/b02-beta.md bytes unchanged after validate()');
}

# ---------------------------------------------------------------------------
# AC-19: CLI exit codes: 0 for clean and for normalizable-only, 1 for any
# ambiguous/structural finding, 2 for a missing <blueprint-dir> argument.
# --quiet prints nothing on exit 0.
# ---------------------------------------------------------------------------
{
    my $clean_dir = tempdir(CLEANUP => 1);
    setup_bp($clean_dir, { id => 'b01-alpha' });

    my $norm_dir = tempdir(CLEANUP => 1);
    setup_bp($norm_dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01' });

    my $bad_dir = tempdir(CLEANUP => 1);
    setup_bp($bad_dir, { id => 'b01-alpha', dep => 'zzz-nonexistent' });

    system(sprintf('perl %s %s >/dev/null 2>&1', quotemeta($VAL), quotemeta($clean_dir)));
    is($? >> 8, 0, 'AC-19: exit 0 for a clean blueprint');

    system(sprintf('perl %s %s >/dev/null 2>&1', quotemeta($VAL), quotemeta($norm_dir)));
    is($? >> 8, 0, 'AC-19: exit 0 for a normalizable-only blueprint');

    system(sprintf('perl %s %s >/dev/null 2>&1', quotemeta($VAL), quotemeta($bad_dir)));
    is($? >> 8, 1, 'AC-19: exit 1 for a blueprint with an ambiguous finding');

    system(sprintf('perl %s >/dev/null 2>&1', quotemeta($VAL)));
    is($? >> 8, 2, 'AC-19: exit 2 for a missing <blueprint-dir> argument');

    my (undef, $quiet_out) = tempfile();
    system(sprintf('perl %s --quiet %s >%s 2>&1', quotemeta($VAL), quotemeta($clean_dir), quotemeta($quiet_out)));
    my $quiet_exit = $? >> 8;
    open my $qfh, '<', $quiet_out or die $!;
    local $/;
    my $quiet_content = <$qfh>;
    close $qfh;
    is($quiet_exit, 0, 'AC-19: --quiet still exits 0 on a clean blueprint');
    is($quiet_content, '', 'AC-19: --quiet prints nothing on exit 0');
}

# =============================================================================
# CHUNK 2 — AC-20..AC-32
#   AC-20..AC-25: the bp-preflight.pl DAG gate (subprocess, criterion b)
#   AC-26:        bp-auditor.md doc assertion (criterion c)
#   AC-27..AC-32: runtime normalization in BpOrch:: (criterion d)
# =============================================================================

# ---------------------------------------------------------------------------
# Shared subprocess helper for bp-preflight.pl. Captures merged
# STDOUT+STDERR via an fd-backed File::Temp file (never an in-memory-scalar
# filehandle -- see house Windows landmines). Never uses a shell string, so
# there is nothing to quote.
# ---------------------------------------------------------------------------
my $PREFLIGHT = "$Bin/../../scripts/bp-preflight.pl";
my $have_preflight = (-f $PREFLIGHT) ? 1 : 0;
ok($have_preflight, 'bp-preflight.pl exists') or diag("missing: $PREFLIGHT");

sub run_preflight {
    my (%opt) = @_;
    my @args;
    push @args, "--bp-dir=$opt{bp_dir}" if defined $opt{bp_dir};
    push @args, '--quiet' if $opt{quiet};

    # Force a clean, explicit environment for every resolution-ladder rung
    # (restored automatically when this sub returns -- dynamic scope of `local`).
    delete local $ENV{BP_BLUEPRINT_DIR};
    delete local $ENV{BP_BLUEPRINT};
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    $ENV{BP_BLUEPRINT_DIR}  = $opt{BP_BLUEPRINT_DIR}  if defined $opt{BP_BLUEPRINT_DIR};
    $ENV{BP_BLUEPRINT}      = $opt{BP_BLUEPRINT}      if defined $opt{BP_BLUEPRINT};
    $ENV{CCPRAXIS_DATA_DIR} = $opt{CCPRAXIS_DATA_DIR} if defined $opt{CCPRAXIS_DATA_DIR};
    $ENV{BP_PROJECT_ROOT}   = $opt{BP_PROJECT_ROOT}   if defined $opt{BP_PROJECT_ROOT};

    my ($tfh, $outfile) = tempfile(UNLINK => 1);
    close $tfh;
    open(my $save_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $save_err, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $outfile)        or die "redirect STDOUT: $!";
    open(STDERR, '>&', \*STDOUT)       or die "redirect STDERR: $!";
    my $rc = system($^X, $PREFLIGHT, @args);
    open(STDOUT, '>&', $save_out) or die "restore STDOUT: $!";
    open(STDERR, '>&', $save_err) or die "restore STDERR: $!";
    close $save_out; close $save_err;

    my $exit = ($rc == -1) ? -1 : ($rc >> 8);
    open(my $rf, '<', $outfile) or die "read preflight capture: $!";
    local $/;
    my $text = <$rf>;
    close $rf;
    return ($exit, defined $text ? $text : '');
}

my ($amb_dir, $ok_dir, $out_ok_dir);
SKIP: {
    skip 'bp-preflight.pl unavailable', 13 unless $have_preflight;

    # ---- AC-20: ambiguous DAG -> exit 2, FAIL row, literal + bracketed code ----
    $amb_dir = tempdir(CLEANUP => 1);
    setup_bp($amb_dir,
        { id => 'b01-alpha' },
        { id => 'b01-beta' },
        { id => 'b02-gamma', dep => 'b01' },   # short id resolves to TWO packages
    );
    my ($exit20, $out20) = run_preflight(bp_dir => $amb_dir);
    is($exit20, 2, 'AC-20: bp-preflight.pl exits 2 for an ambiguous DAG');
    like($out20, qr/\[\s*FAIL\s*\]\s*dag\.integrity/,
        'AC-20: dag.integrity row carries the FAIL glyph');
    like($out20, qr/blueprint DAG is broken at .*\[[\w.-]+\]/s,
        'AC-20: detail has the literal "blueprint DAG is broken at " plus a bracketed code');

    # ---- AC-21: normalizable DAG -> ok row, not attributable to a FAILED block ----
    $ok_dir = tempdir(CLEANUP => 1);
    setup_bp($ok_dir, { id => 'b01-alpha' }, { id => 'b02-beta', dep => 'b01' });
    my ($exit21, $out21) = run_preflight(bp_dir => $ok_dir);
    $out_ok_dir = $out21;
    like($out21, qr/\[\s*ok\s*\]\s*dag\.integrity/,
        'AC-21: dag.integrity row is ok for an auto-normalizable DAG');
    unlike($out21, qr/-\s*\[dag\.integrity\]/,
        'AC-21: dag.integrity is not attributable to any *** PREFLIGHT FAILED *** item');

    # ---- AC-22: no --bp-dir / BP_BLUEPRINT_DIR / BP_BLUEPRINT, empty project root -> skip ----
    my $empty_root = tempdir(CLEANUP => 1);
    my ($exit22, $out22) = run_preflight(BP_PROJECT_ROOT => $empty_root);
    like($out22, qr/\[\s*skip\s*\]\s*dag\.integrity\s+\S/,
        'AC-22: dag.integrity row is skip with a non-empty reason when nothing resolves');
    unlike($out22, qr/-\s*\[dag\.integrity\]/,
        'AC-22: the skip contributes no failure');

    # ---- AC-23: --bp-dir names a path with no blueprint.md -> skip names the path ----
    my $bad_path = tempdir(CLEANUP => 1);
    my ($exit23, $out23) = run_preflight(bp_dir => $bad_path);
    like($out23, qr/\[\s*skip\s*\]\s*dag\.integrity/,
        'AC-23: an explicit --bp-dir with no blueprint.md is a skip, not silent fallthrough');
    like($out23, qr/\Q$bad_path\E/,
        'AC-23: the skip reason names the explicit --bp-dir path');

    # ---- AC-24: --quiet still surfaces failure; --quiet is silent on a clean pass ----
    my ($exitQF, $outQF) = run_preflight(bp_dir => $amb_dir, quiet => 1);
    is($exitQF, 2, 'AC-24: --quiet with a failing DAG still exits 2');
    like($outQF, qr/\*\*\* PREFLIGHT FAILED/,
        'AC-24: --quiet with a failing DAG still prints the *** PREFLIGHT FAILED *** block');
    my ($exitQP, $outQP) = run_preflight(bp_dir => $ok_dir, quiet => 1);
    is($outQP, '', 'AC-24: --quiet with a passing DAG prints nothing');

    # ---- AC-25 (row-production half): the gate produced a row without any manifest id ----
    like($out_ok_dir, qr/dag\.integrity/,
        'AC-25: the gate produced a dag.integrity row though it is not a manifest id (below)');
}

# ---- AC-25 (manifest half): dag.integrity is NOT an id in assumptions.json ----
{
    my $manifest = "$Bin/../../docs/assumptions.json";
    ok(-f $manifest, 'AC-25: plugins/butler/docs/assumptions.json exists');
    my $has_id = 0;
    if (-f $manifest) {
        open my $fh, '<', $manifest or die "read assumptions.json: $!";
        local $/;
        my $txt = <$fh>;
        close $fh;
        $has_id = ($txt =~ /"id"\s*:\s*"dag\.integrity"/) ? 1 : 0;
    }
    ok(!$has_id, 'AC-25: dag.integrity does not appear as an id in assumptions.json');
}

# ---------------------------------------------------------------------------
# AC-26: bp-auditor.md gets the new DAG-integrity hunt-list bullet; the
# frontmatter and the pre-existing eight bullets are untouched.
# ---------------------------------------------------------------------------
{
    my $md = "$Bin/../../../blueprint/agents/bp-auditor.md";
    ok(-f $md, 'AC-26: agent contract plugins/blueprint/agents/bp-auditor.md exists');
    my $text = '';
    if (-f $md) {
        open my $fh, '<', $md or die "read bp-auditor.md: $!";
        local $/;
        $text = <$fh>;
        close $fh;
    }
    like($text, qr/^- \*\*DAG integrity\*\* .*REQUIRED pass:/m,
        'AC-26: bp-auditor.md REQUIRES a DAG-integrity pass (exact §4.3 grep)');
    like($text, qr/^name:\s*bp-auditor\s*$/m, 'AC-26: frontmatter still declares name: bp-auditor');
    like($text, qr/^model:/m,    'AC-26: frontmatter still declares model:');
    like($text, qr/^maxTurns:/m, 'AC-26: frontmatter still declares maxTurns:');
    like($text, qr/^tools:/m,    'AC-26: frontmatter still declares tools:');
    like($text, qr/^-\s*\*\*Write-set hazards\*\*/m,
        'AC-26: pre-existing "Write-set hazards" hunt-list bullet still present');
    like($text, qr/^-\s*\*\*Hidden dependencies\*\*/m,
        'AC-26: pre-existing "Hidden dependencies" hunt-list bullet still present');
}

# ---------------------------------------------------------------------------
# AC-27: deps_met unchanged for full-name deps.
# ---------------------------------------------------------------------------
{
    is(BpOrch::deps_met(['X'], { X => 'done' }), 1,
        'AC-27: deps_met true when a full-name dep is done');
    is(BpOrch::deps_met(['X'], { X => 'pending' }), 0,
        'AC-27: deps_met false when a full-name dep is pending');
    is(BpOrch::deps_met([], {}), 1, 'AC-27: deps_met true for an empty dep list');
    is(BpOrch::deps_met(undef, {}), 1, 'AC-27: deps_met true for an undef dep list');
}

# ---------------------------------------------------------------------------
# AC-28: deps_met resolves a short-id token against $status's keys.
# ---------------------------------------------------------------------------
{
    is(BpOrch::deps_met(['b01'], { 'b01-orchestrator-broken-env-turns' => 'done' }), 1,
        'AC-28: deps_met(short-id) true when the uniquely-resolved package is done');
    is(BpOrch::deps_met(['b01'], { 'b01-orchestrator-broken-env-turns' => 'pending' }), 0,
        'AC-28: deps_met(short-id) false when the uniquely-resolved package is pending');
}

# ---------------------------------------------------------------------------
# AC-29: deps_met fails closed on a dangling or ambiguous short-id token.
# ---------------------------------------------------------------------------
{
    is(BpOrch::deps_met(['b99'], { 'b01-alpha' => 'done' }), 0,
        'AC-29: deps_met fails closed on a dangling short-id token');
    is(BpOrch::deps_met(['b01'], { 'b01-alpha' => 'done', 'b01-beta' => 'done' }), 0,
        'AC-29: deps_met fails closed when a short-id token matches two packages');
}

# ---------------------------------------------------------------------------
# AC-30: normalize_dag canonicalizes short ids, drops self-deps, dedupes,
# preserves unresolvable tokens verbatim, and preserves the key set.
# ---------------------------------------------------------------------------
{
    my $have_norm = BpOrch->can('normalize_dag') ? 1 : 0;
    ok($have_norm, 'AC-30: BpOrch::normalize_dag exists')
        or diag('BpOrch::normalize_dag not implemented yet');
    SKIP: {
        skip 'BpOrch::normalize_dag unavailable', 5 unless $have_norm;
        my $dag = {
            'b01-alpha' => [],
            'b02-beta'  => ['b01', 'b01-alpha', 'b01'],   # short id + its own full name + dup
            'b03-gamma' => ['b03-gamma'],                  # self-dep
            'b04-delta' => ['bXX-missing'],                # unresolvable, preserved verbatim
        };
        my $fixed = eval { BpOrch::normalize_dag($dag) };
        ok(defined $fixed, 'AC-30: normalize_dag returns a defined result')
            or diag("normalize_dag died: $@");
        SKIP: {
            skip 'normalize_dag unavailable or died', 4 unless defined $fixed;
            is_deeply([sort keys %$fixed], [sort keys %$dag],
                'AC-30: keys of the returned hash equal keys of the input');
            is_deeply($fixed->{'b02-beta'}, ['b01-alpha'],
                'AC-30: short id canonicalized to the full id, and duplicates deduped');
            is_deeply($fixed->{'b03-gamma'}, [],
                'AC-30: self-dep dropped');
            is_deeply($fixed->{'b04-delta'}, ['bXX-missing'],
                'AC-30: an unresolvable token is preserved verbatim (fail closed, not dropped)');
        }
    }
}

# ---------------------------------------------------------------------------
# AC-31: end-to-end. BpOrch::run over a fixture blueprint whose table uses a
# SHORT id in depends_on launches every package (all reach done) with no
# decision filed (runs/needs-you/ stays empty).
# ---------------------------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    my $bpdir = "$dir/bp";
    mkdir $bpdir; mkdir "$bpdir/packages"; mkdir "$bpdir/runs";
    write_bp_md($bpdir,
        '# T31', '',
        '## Package status', '',
        '| pkg | deliverable | depends_on | model | status |',
        '|-----|-------------|------------|-------|--------|',
        '| b01-alpha | thing A | — | sonnet | ⬜ pending |',
        '| b02-beta  | thing B | b01 | sonnet | ⬜ pending |',
    );
    for my $p (['b01-alpha', 'p/a/'], ['b02-beta', 'p/b/']) {
        open my $l, '>', "$bpdir/packages/$p->[0].md" or die "write ledger: $!";
        print $l "---\npackage: $p->[0]\nblueprint: T31\nstatus: pending\nmodel: sonnet\n"
               . "max_turns: 80\nwrite_set: $p->[1]\ntest_paths: $p->[1]\n"
               . "last_updated: 2026-06-24T00:00:00Z\n---\n\n# $p->[0]\n";
        close $l;
    }
    my $NOW = 1_900_000_000;
    my $creds = "$dir/creds.json";
    open my $cf, '>', $creds or die "write creds: $!";
    print $cf '{"claudeAiOauth":{"accessToken":"sk-ant-TESTTESTTESTTESTTESTTEST",'
            . '"refreshToken":"sk-ant-REFREFREFREFREFREFREFREF","expiresAt":'
            . (($NOW + 5 * 3600) * 1000)
            . ',"scopes":["user:inference"],"subscriptionType":"max","rateLimitTier":"x"}}';
    close $cf;
    my $t = {
        ceil5 => 85, ceil7 => 90, drain => 600, max_par => 2, cap => 5, flat => 600,
        watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
        jit_lo => 300, jit_hi => 900, tele_retry => 3, usage_fail => 60,
        busy_path => "$dir/busy",
        harvest => 'audit', resolve_cap => 1, corr_cap => 1, judge_to => 1800,
    };
    my $usage_body = '{"five_hour":{"utilization":10,"resets_at":"2026-06-22T05:59:59+00:00"},'
                    . '"seven_day":{"utilization":5,"resets_at":"2026-06-22T17:59:59+00:00"}}';
    my @launched;
    for (1 .. 6) {
        eval {
            BpOrch::run({
                blueprint => 'T31', bp_dir => $bpdir, creds_path => $creds, tunables => $t,
                once => 1, now => sub { $NOW }, sleep => sub { },
                http_get  => sub { { status => 200, content => $usage_body } },
                http_post => sub { { status => 200, content => '{}' } },
                spawn_judge => sub { 0 },
                launch    => sub {
                    my ($job) = @_;
                    push @launched, $job->{pkg};
                    my $lf = "$bpdir/packages/$job->{pkg}.md";
                    if (open my $rf, '<', $lf) {
                        local $/;
                        my $c = <$rf>;
                        close $rf;
                        $c =~ s/^status:\s*\S+/status: done/m;
                        open my $wf, '>', $lf or die "rewrite ledger: $!";
                        print $wf $c;
                        close $wf;
                    }
                    0;
                },
            });
            1;
        } or last;
    }
    my %final;
    for my $id ('b01-alpha', 'b02-beta') {
        open my $rf, '<', "$bpdir/packages/$id.md" or die "read ledger $id: $!";
        local $/;
        my $c = <$rf>;
        close $rf;
        $final{$id} = ($c =~ /^status:\s*(\S+)/m) ? $1 : '?';
    }
    is($final{'b01-alpha'}, 'done', 'AC-31: b01-alpha (no dep) reaches done');
    is($final{'b02-beta'}, 'done',
        'AC-31: b02-beta (short-id dep on b01) reaches done -- launched with no decision');
    my @needs_you = -d "$bpdir/runs/needs-you" ? glob("$bpdir/runs/needs-you/*") : ();
    is(scalar @needs_you, 0, 'AC-31: runs/needs-you/ stays empty -- no decision was filed');
}

# ---------------------------------------------------------------------------
# AC-32: has_progressable_work resolves a short-id dep post-normalization.
# ---------------------------------------------------------------------------
{
    my $meta = { 'b02-beta' => { deps => ['b01'] } };
    is(BpOrch::has_progressable_work($meta, { 'b02-beta' => 'pending', 'b01-alpha' => 'done' }), 1,
        'AC-32: has_progressable_work true for a pending pkg whose short-id dep is done');
    is(BpOrch::has_progressable_work($meta, { 'b02-beta' => 'pending', 'b01-alpha' => 'blocked' }), 0,
        'AC-32: has_progressable_work false when that short-id dep is blocked');
}

# =============================================================================
# CHUNK 3 — AC-33..AC-46
#   Stall detection (dag_stall, pure) and routing (dag_stall_step, glue):
#   criterion (e) routes a blocked-dependency stall to the b07 remediation
#   engine; criterion (f) surfaces exactly one dag-stalled decision only when
#   the stall is structurally unresolvable. See spec-b08 §2.6/§2.7, §5.3-§5.5.
# =============================================================================

my $have_dag_stall      = BpOrch->can('dag_stall')      ? 1 : 0;
my $have_dag_stall_step = BpOrch->can('dag_stall_step') ? 1 : 0;

ok($have_dag_stall, 'AC-33: BpOrch::dag_stall is implemented')
    or diag('dag_stall not yet implemented -- AC-33..AC-36 assertions are skipped');
ok($have_dag_stall_step, 'AC-37: BpOrch::dag_stall_step is implemented')
    or diag('dag_stall_step not yet implemented -- AC-37,40,41,42,43,44,45 assertions are skipped');

# ---------------------------------------------------------------------------
# Chunk-3-local fixture helpers (self-contained; do not depend on chunk 1/2
# internals we did not read).
# ---------------------------------------------------------------------------
sub decode_json_file {
    my ($path) = @_;
    return undef unless -f $path;
    open(my $fh, '<', $path) or return undef;
    local $/;
    my $text = <$fh>;
    close $fh;
    require JSON::PP;
    return eval { JSON::PP::decode_json($text) };
}

sub needs_you_files {
    my ($runs) = @_;
    my $dir = "$runs/needs-you";
    # NOTE: every exit must `return @out`, never a bare `return ()`. A bare
    # `return ()` evaluates to undef in SCALAR context, so `scalar(needs_you_files(...))`
    # would yield undef instead of 0 precisely when the directory correctly
    # does not exist -- making "expect 0 files" unpassable. `return @out` gives
    # the count in scalar context and the list in list context.
    my @out;
    return @out unless -d $dir;
    opendir(my $dh, $dir) or return @out;
    my @files = sort grep { -f "$dir/$_" } readdir($dh);
    closedir $dh;
    @out = map { "$dir/$_" } @files;
    return @out;
}

sub _dag_stall_queue_entries {
    my ($runs) = @_;
    # Same scalar-context rule as needs_you_files above: `return @out`, never a
    # bare `return ()`, or "expect 0 queue entries" can never pass.
    my @out;
    my $data = decode_json_file("$runs/remediation-queue.json");
    return @out unless defined $data;
    # BpRemediate::write_queue emits an ENVELOPE: { entries => [...], escalated =>
    # [...], schema => 'remediation-queue/1', ... }. The entries live under
    # ->{entries}; `values %$data` would hand back the envelope's own values
    # (arrayrefs, counters, the schema string) and match nothing. Sibling
    # t/26-auto-remediation-engine.t reads ->{entries} for the same reason.
    my @all = ref($data) eq 'ARRAY'                 ? @$data
            : ref($data->{entries}) eq 'ARRAY'      ? @{ $data->{entries} }
            : ref($data) eq 'HASH'                  ? values %$data
            : ();
    @out = grep {
        ref($_) eq 'HASH' && ref($_->{finding}) eq 'HASH'
            && (($_->{finding}{kind} // '') eq 'dag-stall')
    } @all;
    return @out;
}

sub mk_dag_stall_a {
    my (%over) = @_;
    my $dir  = tempdir(CLEANUP => 1);
    my $runs = "$dir/runs";
    mkdir $runs or die "mkdir $runs: $!";
    my $log  = "$dir/orchestrator.log";
    my %a = (
        bpdir          => $dir,
        runs           => $runs,
        log            => $log,
        blueprint      => 'sandbox-butler-overhaul',
        meta           => {},
        status         => {},
        now            => time(),
        tunables       => { dag_stall => 1 },
        queue          => "$runs/remediation-queue.json",
        live           => [],
        shutdown       => 0,
        paused         => 0,
        resume_pending => 0,
    );
    @a{ keys %over } = values %over;
    return (\%a, $dir, $runs, $log);
}

# ---- AC-33: the four non-stall reasons, and purity (no I/O) ----------------
SKIP: {
    skip 'BpOrch::dag_stall not implemented', 9 unless $have_dag_stall;

    my $purity_dir = tempdir(CLEANUP => 1);
    opendir(my $dh0, $purity_dir) or die "opendir $purity_dir: $!";
    my @before = sort readdir($dh0);
    closedir $dh0;

    my $r_running = BpOrch::dag_stall(
        { 'b01-a' => { deps => [], write_set => 'x', remediation => 0 } },
        { 'b01-a' => 'pending' },
        [ 'b01-a' ],
    );
    is($r_running->{stalled}, 0, 'AC-33: a live package -> stalled is 0');
    is($r_running->{reason}, 'running', "AC-33: reason is exactly 'running'");

    my $r_np = BpOrch::dag_stall(
        { 'b01-a' => { deps => [], write_set => 'x', remediation => 0 } },
        { 'b01-a' => 'done' },
        [],
    );
    is($r_np->{stalled}, 0, 'AC-33: nothing pending -> stalled is 0');
    is($r_np->{reason}, 'no-pending', "AC-33: reason is exactly 'no-pending'");

    my $r_l = BpOrch::dag_stall(
        { 'b01-a' => { deps => [], write_set => 'x', remediation => 0 } },
        { 'b01-a' => 'pending' },
        [],
    );
    is($r_l->{stalled}, 0, 'AC-33: a pending package with met deps -> stalled is 0');
    is($r_l->{reason}, 'launchable', "AC-33: reason is exactly 'launchable'");

    my $r_i = BpOrch::dag_stall(
        { 'b01-a' => { deps => [], write_set => 'x', remediation => 0 } },
        { 'b01-a' => 'harvesting' },
        [],
    );
    is($r_i->{stalled}, 0, 'AC-33: a non-terminal, non-pending package -> stalled is 0');
    is($r_i->{reason}, 'inflight', "AC-33: reason is exactly 'inflight'");

    opendir(my $dh1, $purity_dir) or die "opendir $purity_dir: $!";
    my @after = sort readdir($dh1);
    closedir $dh1;
    is_deeply(\@after, \@before, 'AC-33: dag_stall creates/modifies no files (pure, no I/O)');
}

# ---- AC-34: blocked dep -> one blockers entry, unresolvable is [] ----------
SKIP: {
    skip 'BpOrch::dag_stall not implemented', 6 unless $have_dag_stall;
    my $meta = {
        'b02-dependent' => { deps => ['b01-blocker'], write_set => 'x', remediation => 0 },
        'b01-blocker'   => { deps => [], write_set => 'y', remediation => 0 },
    };
    my $status = { 'b02-dependent' => 'pending', 'b01-blocker' => 'blocked' };
    my $r = BpOrch::dag_stall($meta, $status, []);
    is($r->{stalled}, 1, 'AC-34: a blocked dependency stalls the run');
    is(scalar(@{ $r->{blockers} }), 1, 'AC-34: exactly one blockers entry');
    is($r->{blockers}[0]{blocker}, 'b01-blocker', 'AC-34: blocker is the blocked package');
    ok(($r->{blockers}[0]{blocker_status} eq 'blocked' || $r->{blockers}[0]{blocker_status} eq 'parked'),
        "AC-34: blocker_status is 'blocked' or 'parked'");
    is_deeply($r->{blockers}[0]{dependents}, ['b02-dependent'], 'AC-34: dependents is sorted and non-empty');
    is_deeply($r->{unresolvable}, [], 'AC-34: unresolvable is [] for a pure blocked-dep stall');
}

# ---- AC-35: dangling / cycle / dropped -> unresolvable, blockers is [] -----
SKIP: {
    skip 'BpOrch::dag_stall not implemented', 12 unless $have_dag_stall;

    my $r_d = BpOrch::dag_stall(
        { 'b02-x' => { deps => ['nope-does-not-exist'], write_set => 'x', remediation => 0 } },
        { 'b02-x' => 'pending' },
        [],
    );
    is($r_d->{stalled}, 1, 'AC-35: a dangling dep stalls the run');
    is(scalar(@{ $r_d->{unresolvable} }), 1, 'AC-35: exactly one unresolvable entry for a dangling dep');
    is($r_d->{unresolvable}[0]{code}, 'dep-dangling', "AC-35: code is 'dep-dangling'");
    is_deeply($r_d->{blockers}, [], 'AC-35: blockers is [] for a dangling dep');

    my $r_c = BpOrch::dag_stall(
        { 'b02-x' => { deps => ['b03-y'], write_set => 'x', remediation => 0 },
          'b03-y' => { deps => ['b02-x'], write_set => 'y', remediation => 0 } },
        { 'b02-x' => 'pending', 'b03-y' => 'pending' },
        [],
    );
    is($r_c->{stalled}, 1, 'AC-35: a dependency cycle stalls the run');
    my @cyc = grep { $_->{code} eq 'dep-cycle' } @{ $r_c->{unresolvable} };
    is(scalar(@cyc), 1, "AC-35: exactly one 'dep-cycle' entry (per cycle, not per member)");
    ok(scalar(@{ $cyc[0]{members} }) >= 2, 'AC-35: dep-cycle members lists the rotated cycle');
    is_deeply($r_c->{blockers}, [], 'AC-35: blockers is [] for a cycle');

    my $r_dr = BpOrch::dag_stall(
        { 'b02-x'    => { deps => ['b01-gone'], write_set => 'x', remediation => 0 },
          'b01-gone' => { deps => [], write_set => 'y', remediation => 0 } },
        { 'b02-x' => 'pending', 'b01-gone' => 'dropped' },
        [],
    );
    is($r_dr->{stalled}, 1, 'AC-35: a dropped dep stalls the run');
    is(scalar(@{ $r_dr->{unresolvable} }), 1, 'AC-35: exactly one unresolvable entry for a dropped dep');
    is($r_dr->{unresolvable}[0]{code}, 'dep-dropped', "AC-35: code is 'dep-dropped'");
    is_deeply($r_dr->{blockers}, [], 'AC-35: blockers is [] for a dropped dep');
}

# ---- AC-36: recursion exclusion (remediation flag and remediation- prefix) -
SKIP: {
    skip 'BpOrch::dag_stall not implemented', 9 unless $have_dag_stall;

    my $meta1 = {
        'remediation-slug-r1' => { deps => [], write_set => 'x', remediation => 0 },
        'b02-normal'          => { deps => [], write_set => 'y', remediation => 1 },
    };
    my $status1 = { 'remediation-slug-r1' => 'pending', 'b02-normal' => 'pending' };
    my $r1 = BpOrch::dag_stall($meta1, $status1, []);
    ok(!(grep { $_ eq 'remediation-slug-r1' } @{ $r1->{pending} }),
        'AC-36: id-prefixed remediation package excluded from pending');
    ok(!(grep { $_ eq 'b02-normal' } @{ $r1->{pending} }),
        'AC-36: flagged (remediation=>1) package excluded from pending');
    ok(!(grep { $_ eq 'remediation-slug-r1' } @{ $r1->{ready} }),
        'AC-36: id-prefixed remediation package excluded from ready');
    ok(!(grep { $_ eq 'b02-normal' } @{ $r1->{ready} }),
        'AC-36: flagged remediation package excluded from ready');
    is_deeply($r1->{blockers}, [], 'AC-36: excluded packages produce no blockers');
    is_deeply($r1->{unresolvable}, [], 'AC-36: excluded packages produce no unresolvable findings');

    my $meta2 = {
        'b02-normal'          => { deps => ['remediation-slug-r1'], write_set => 'y', remediation => 0 },
        'remediation-slug-r1' => { deps => [], write_set => 'x', remediation => 0 },
    };
    my $status2 = { 'b02-normal' => 'pending', 'remediation-slug-r1' => 'blocked' };
    my $r2 = BpOrch::dag_stall($meta2, $status2, []);
    ok(!(grep { $_->{blocker} eq 'remediation-slug-r1' } @{ $r2->{blockers} }),
        'AC-36: excluded package never appears as a blocker even when blocked and depended upon');
    ok(!(grep { ($_->{package} // '') eq 'remediation-slug-r1' || ($_->{detail} // '') eq 'remediation-slug-r1' }
        @{ $r2->{unresolvable} }),
        'AC-36: excluded package never appears in unresolvable');
    ok(!(grep { $_ eq 'remediation-slug-r1' } (@{ $r2->{pending} }, @{ $r2->{ready} })),
        'AC-36: excluded package absent from pending and ready');
}

# ---- AC-37 (criterion e): blocked-dep stall routes to the b07 engine -------
SKIP: {
    skip 'BpOrch::dag_stall_step not implemented', 5 unless $have_dag_stall_step;
    my $meta = {
        'b02-dependent' => { deps => ['b01-blocker'], write_set => 'packages/b02-dependent/**', remediation => 0 },
        'b01-blocker'   => { deps => [], write_set => 'packages/b01-blocker/**', remediation => 0 },
    };
    my $status = { 'b02-dependent' => 'pending', 'b01-blocker' => 'blocked' };
    my ($a, $dir, $runs, $log) = mk_dag_stall_a(meta => $meta, status => $status);
    BpOrch::dag_stall_step($a);
    my @entries = _dag_stall_queue_entries($runs);
    is(scalar(@entries), 1, 'AC-37: remediation-queue.json gains one dag-stall entry');
    is($entries[0]->{finding}{subject}, 'b01-blocker',
        'AC-37: finding.subject is the blocker, not the stalled dependent');
    is($entries[0]->{finding}{remedy}{action}, 'remediate-conformance',
        "AC-37: finding.remedy.action is 'remediate-conformance'");
    is(scalar(needs_you_files($runs)), 0, 'AC-37: runs/needs-you gains no file for a mechanical blocker route');
    my $logtext = '';
    if (open(my $lfh, '<', $log)) { local $/; $logtext = <$lfh> // ''; close $lfh; }
    like($logtext, qr/dag_stall_remediation/, 'AC-37: orchestrator.log gains a dag_stall_remediation event');
}

# ---- AC-38/AC-39: the finding is compatible with the real b07 engine -------
my $have_remediate = do {
    my $ok = 1;
    local $SIG{__WARN__} = sub { warn $_[0] unless $_[0] =~ /Subroutine .* redefined/ };
    eval { require "$Bin/../../scripts/bp-remediate.pl"; 1 } or $ok = 0;
    $ok;
};
ok($have_remediate, 'AC-38: bp-remediate.pl (classify_finding, write_set_for) is loadable');

SKIP: {
    skip 'bp-remediate.pl unavailable', 2 unless $have_remediate;
    my $find = {
        kind     => 'dag-stall',
        subject  => 'b01-blocker',
        detail   => "package 'b01-blocker' is 'blocked' and blocks 1 dependent package(s): "
                   . "b02-dependent — the run cannot progress until it reaches 'done'",
        evidence => { blocked_on => 'b01-blocker', blocker_status => 'blocked',
                      dependents => ['b02-dependent'], files => [] },
        remedy   => { action => 'remediate-conformance', package => 'b01-blocker' },
    };
    my $c = BpRemediate::classify_finding($find,
        { pkg_write_sets => { 'b01-blocker' => 'packages/b01-blocker/**' } });
    ok(defined($c) && ref($c) eq 'HASH', 'AC-38: classify_finding returns a disposition hash for the b08 finding shape');
    is($c->{disposition}, 'auto',
        "AC-38: remedy.action 'remediate-conformance' is auto-remediable, not fail-closed to 'unfixable'");
}

SKIP: {
    skip 'bp-remediate.pl unavailable', 1 unless $have_remediate;
    my $f2 = {
        kind     => 'dag-stall',
        subject  => 'blocker',
        detail   => "package 'blocker' is 'blocked' and blocks 1 dependent package(s): stalled "
                   . "— the run cannot progress until it reaches 'done'",
        evidence => { blocked_on => 'blocker', blocker_status => 'blocked',
                      dependents => ['stalled'], files => [] },
        remedy   => { action => 'remediate-conformance', package => 'blocker' },
    };
    is(BpRemediate::write_set_for($f2, { pkg_write_sets => { blocker => 'A', stalled => 'B' } }), 'A',
        "AC-39: the resolved write set is the blocker's declared write set, not the stalled package's");
}

# ---- AC-40/AC-41: idempotence and registry persistence across ticks --------
SKIP: {
    skip 'BpOrch::dag_stall_step not implemented', 4 unless $have_dag_stall_step;
    my $meta = {
        'b02-dependent' => { deps => ['b01-blocker'], write_set => 'packages/b02-dependent/**', remediation => 0 },
        'b01-blocker'   => { deps => [], write_set => 'packages/b01-blocker/**', remediation => 0 },
    };
    my $status = { 'b02-dependent' => 'pending', 'b01-blocker' => 'blocked' };
    my ($a, $dir, $runs, $log) = mk_dag_stall_a(meta => $meta, status => $status);
    BpOrch::dag_stall_step($a);
    my $first_count = scalar(_dag_stall_queue_entries($runs));

    my $a2 = { %$a, now => $a->{now} + 60 };
    BpOrch::dag_stall_step($a2);
    is(scalar(_dag_stall_queue_entries($runs)), $first_count,
        'AC-40: an identical second tick performs no second submission (queue non-quiet guard)');

    my $meta3 = { %$meta, 'b03-also-dependent' => { deps => ['b01-blocker'], write_set => 'z', remediation => 0 } };
    my $status3 = { %$status, 'b03-also-dependent' => 'pending' };
    my $a3 = { %$a, meta => $meta3, status => $status3, now => $a->{now} + 120 };
    BpOrch::dag_stall_step($a3);
    is(scalar(_dag_stall_queue_entries($runs)), $first_count,
        'AC-40: a widened dependent list on the same blocker still produces no new submission (finding_key guard)');

    ok(-f "$runs/registry.json", 'AC-41: the _dag_stall fact is persisted to runs/registry.json');
    # registry.json nests every package under ->{packages}: update_registry_pkg
    # writes $data->{packages}{$pkg}, and read_registry() returns $r->{packages},
    # which is why the spec's `read_registry($runs)->{_dag_stall}` resolves to
    # packages._dag_stall. Reading the raw decode at top level would miss it.
    my $reg  = decode_json_file("$runs/registry.json");
    my $pkgs = (ref($reg) eq 'HASH' && ref($reg->{packages}) eq 'HASH') ? $reg->{packages} : {};
    ok(ref($pkgs->{_dag_stall}) eq 'HASH' && exists $pkgs->{_dag_stall}{'b01-blocker'},
        'AC-41: a fresh read of registry.json (simulating restart) still shows the blocker recorded');
}

# ---- AC-42 (criterion f): unresolvable -> exactly one _dag decision --------
SKIP: {
    skip 'BpOrch::dag_stall_step not implemented', 5 unless $have_dag_stall_step;
    my $meta = { 'b02-x' => { deps => ['nope-missing'], write_set => 'x', remediation => 0 } };
    my $status = { 'b02-x' => 'pending' };
    my ($a, $dir, $runs, $log) = mk_dag_stall_a(meta => $meta, status => $status);
    BpOrch::dag_stall_step($a);
    my @ny = needs_you_files($runs);
    is(scalar(@ny), 1, 'AC-42: exactly one needs-you file after an unresolvable stall');
    for (1 .. 10) { BpOrch::dag_stall_step($a); }
    my @ny2 = needs_you_files($runs);
    is(scalar(@ny2), 1, 'AC-42: ten further ticks add no additional needs-you file');
    my ($decision) = map { decode_json_file($_) } @ny2;
    is($decision->{package}, '_dag', "AC-42: decision package is '_dag'");
    is($decision->{kind}, 'dag-stalled', "AC-42: decision kind is 'dag-stalled'");
    ok(!-f "$runs/remediation-queue.json",
        'AC-42: remediation_step is never called (queue file never created) for an unresolvable stall');
}

# ---- AC-43: mixed blockers+unresolvable -> decision route only ------------
SKIP: {
    skip 'BpOrch::dag_stall_step not implemented', 3 unless $have_dag_stall_step;
    my $meta = {
        'b02-blocked-dep' => { deps => ['b01-blocker'], write_set => 'x', remediation => 0 },
        'b01-blocker'     => { deps => [], write_set => 'y', remediation => 0 },
        'b03-dangling'    => { deps => ['nope-missing'], write_set => 'z', remediation => 0 },
    };
    my $status = { 'b02-blocked-dep' => 'pending', 'b01-blocker' => 'blocked', 'b03-dangling' => 'pending' };
    my ($a, $dir, $runs, $log) = mk_dag_stall_a(meta => $meta, status => $status);
    BpOrch::dag_stall_step($a);
    my @ny = needs_you_files($runs);
    is(scalar(@ny), 1, 'AC-43: a tick with both blockers and unresolvable takes only the decision route');
    ok(!-f "$runs/remediation-queue.json", 'AC-43: no remediation submission alongside the decision');
    is(scalar(_dag_stall_queue_entries($runs)), 0, 'AC-43: zero dag-stall remediation-queue entries');
}

# ---- AC-44: unscopable/exhausted route still ends visibly ------------------
SKIP: {
    skip 'BpOrch::dag_stall_step not implemented', 2 unless $have_dag_stall_step;
    my $meta = {
        'b02-dependent' => { deps => ['b01-blocker'], write_set => 'packages/b02-dependent/**', remediation => 0 },
        'b01-blocker'   => { deps => [], write_set => '', remediation => 0 },   # empty write_set -> unscopable
    };
    my $status = { 'b02-dependent' => 'pending', 'b01-blocker' => 'blocked' };
    my ($a, $dir, $runs, $log) = mk_dag_stall_a(meta => $meta, status => $status);
    BpOrch::dag_stall_step($a);                              # tick 1: submitted, engine escalates (no write set)
    my $a2 = { %$a, now => $a->{now} + 3600 };
    BpOrch::dag_stall_step($a2);                              # tick 2: quiesced queue, mechanical route exhausted
    my @ny = needs_you_files($runs);
    is(scalar(@ny), 1, 'AC-44: exactly one _dag decision once the remediation route is exhausted');
    my ($decision) = map { decode_json_file($_) } @ny;
    is($decision->{context}{class}, 'remediation-exhausted',
        "AC-44: decision context.class is 'remediation-exhausted'");
}

# ---- AC-45: tunables.dag_stall == 0 short-circuits, writes nothing --------
SKIP: {
    skip 'BpOrch::dag_stall_step not implemented', 4 unless $have_dag_stall_step;
    my @cases = (
        { label => 'blocker',
          meta   => { 'b02-dependent' => { deps => ['b01-blocker'], write_set => 'x', remediation => 0 },
                      'b01-blocker'   => { deps => [], write_set => 'y', remediation => 0 } },
          status => { 'b02-dependent' => 'pending', 'b01-blocker' => 'blocked' } },
        { label => 'unresolvable',
          meta   => { 'b02-x' => { deps => ['nope-missing'], write_set => 'x', remediation => 0 } },
          status => { 'b02-x' => 'pending' } },
    );
    for my $case (@cases) {
        my ($a, $dir, $runs, $log) = mk_dag_stall_a(
            meta => $case->{meta}, status => $case->{status}, tunables => { dag_stall => 0 });
        my $out = BpOrch::dag_stall_step($a);
        is_deeply($out, { fired => 0, decided => 0, remediation_outstanding => 0 },
            "AC-45: dag_stall==0 short-circuits dag_stall_step for a $case->{label} stall");
        ok(!-f "$runs/remediation-queue.json" && !-d "$runs/needs-you",
            "AC-45: dag_stall==0 writes nothing for a $case->{label} stall");
    }
}

# ---- AC-46: static contract -- every new sub is defined, forbidden require -
{
    my $orch_src_path = "$Bin/../../scripts/bp-orchestrator.pl";
    open(my $sfh, '<', $orch_src_path) or die "cannot read $orch_src_path: $!";
    local $/;
    my $src = <$sfh>;
    close $sfh;
    for my $sub (qw(resolve_dep_token normalize_dag find_cycles dag_stall dag_stall_step _dag_decision)) {
        like($src, qr/\bsub\s+\Q$sub\E\b/, "AC-46: bp-orchestrator.pl defines sub $sub");
    }
    unlike($src, qr/require\s+.*bp-validate-dag\.pl/,
        'AC-46: bp-orchestrator.pl contains no require of bp-validate-dag.pl');
}

done_testing();
