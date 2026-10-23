#!/usr/bin/env perl
# platform: windows
#
# Oracle for 01-compact-oracle-records (bug 20260926-155710-2c57), derived ONLY from
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/01-compact-oracle-records-spec.md
# (sections 2-5), the ledger's Done criteria, and Decisions 1, 6, 7, 11 of blueprint
# tooling-fixes/blueprint.md. Decision 11's amendment supersedes spec section 2.6 step 5's
# "No stderr" line: the sidecar-write-failure fallback in tick-step prints exactly ONE
# stderr warning naming the ledger and the reason. This file follows that amendment, not
# the un-amended spec prose (AC-14 below).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION of this package. bp-ledger.pl's oracle records are, at
# authoring time, always LONG FORM: no ORACLE_RECORD_MAX_BYTES cap, no "v":2, no sidecar, no
# migrate-oracle verb. Every assertion below is expected to FAIL for the right reason (records
# too large, no "v" key, no sidecar file, unknown "migrate-oracle" verb), never on a harness
# bug of this file's own making.
#
# HARNESS RULES (completion-claim-integrity.t / ledger-budget-irreducible.t precedent):
#   * Hermetic: tempdir(CLEANUP => 1) at $ROOT, nothing written outside it.
#   * bp-ledger.pl runs as a CHILD PROCESS via run_pl(), ambient BP_* stripped.
#   * Fixture `.t` files tick-step actually RUNS are generated fresh into $ROOT -- never a
#     real repo test file (tests-never-run-tests.t).
#   * Absolute paths throughout; never `cd`.
#   * done_testing() at EOF, never a hand-counted plan.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl qw(:flock);
use JSON::PP;
use Digest::SHA qw(sha256_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-ledger.pl";

my $J = JSON::PP->new->canonical;

# compact_projection: the test's own spec-blind reimplementation of spec section 2.3's
# compact_oracle_record($full), used ONLY to compute what a sidecar candidate WOULD project
# to for the matching-rule comparison in AC-15 (spec 2.4: "sidecar entry S backs compact
# record C iff encode(compact_oracle_record(S)) eq encode(C)"). A raw full-form sidecar
# entry (which carries "descriptions") can never be byte-identical to a compact ledger line,
# so the comparison must go through this projection, not compare $e itself.
sub compact_projection {
    my ($full) = @_;
    my %c;
    $c{v} = 2;
    $c{step} = $full->{step} + 0;
    $c{recorded_at} = $full->{recorded_at};
    $c{status} = $full->{status};
    # N1 (a): prefer "path" over "path_sha256" whenever the input carries one -- but the real
    # compact_oracle_record switches on the ENCODED LINE LENGTH (spec 2.3's 400-byte cap), not
    # on which field happens to be present on the input. Compute both candidates and pick the
    # length-based winner below, after the rest of the record is assembled.
    if (defined $full->{path}) {
        $c{path} = $full->{path};
    } elsif (defined $full->{path_sha256}) {
        $c{path_sha256} = $full->{path_sha256};
    }
    if (($full->{status} // '') eq 'ok') {
        $c{sha256} = $full->{sha256};
        $c{assertions} = $full->{assertions} + 0 if defined $full->{assertions};
        $c{descriptions_sha256} = $full->{descriptions_sha256};
    } else {
        # N1 (c): an undefined reason projects to the empty string, matching the real
        # function -- never to a JSON null.
        my $reason = $full->{reason};
        if (defined $reason) {
            $reason =~ s/[^\x20-\x7E]/?/g;
            $reason = substr($reason, 0, 64);
        }
        else {
            $reason = '';
        }
        $c{reason} = $reason;
    }
    $c{reaccepted} = JSON::PP::true if exists $full->{reaccept};

    # N1 (a), continued: if the "path" candidate pushes the encoded compact line over the
    # 400-byte cap, and a path is available to hash, swap to path_sha256 -- this is the same
    # length-based rule AC-12 pins for the real function, ported here rather than merely
    # mirrored from whichever field the caller happened to supply.
    if (defined $c{path} && length($J->encode(\%c)) > 400) {
        delete $c{path};
        $c{path_sha256} = sha256_hex($full->{path});
    }

    return \%c;
}

diag("subject under test: $SCRIPT "
     . (-e $SCRIPT ? "(present)" : "(ABSENT)")
     . " -- compact oracle records / sidecar / migrate-oracle are expected ABSENT at authoring time");

my $ROOT = tempdir(CLEANUP => 1);
my $pn  = 0;
my $tfn = 0;

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# =====================================================================================
# Low-level file/process helpers
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
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

sub run_pl {
    my ($args, %opt) = @_;
    my $n     = ++$pn;
    my $inf   = "$ROOT/in.$n";
    my $outf  = "$ROOT/out.$n";
    my $errf  = "$ROOT/err.$n";
    my $script = $opt{script} || $SCRIPT;
    write_file($inf, defined $opt{stdin} ? $opt{stdin} : '');
    write_file($outf, '');
    write_file($errf, '');
    my %extra = %{ $opt{env} || {} };
    local %ENV = (%CLEAN_ENV, %extra,
                  LGT_SCRIPT => fwd($script), LGT_IN => fwd($inf),
                  LGT_OUT    => fwd($outf),   LGT_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 60 perl "$LGT_SCRIPT" "$@" < "$LGT_IN" > "$LGT_OUT" 2> "$LGT_ERR"',
        'bp-ledger', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

# run_pl_cwd($cwd, \@args, %opt) -- S1 (Decision 13): identical to run_pl, except the child
# process's CWD is explicitly set to $cwd (via bash's own "cd", precedent:
# ledger-budget-irreducible.t's run_pl(cwd => ...)), so a ledger argument like a bare
# "packages/x.md" or "./packages/x.md" is resolved relative to a real blueprint directory,
# not this test's own $ROOT.
sub run_pl_cwd {
    my ($cwd, $args, %opt) = @_;
    my $n     = ++$pn;
    my $inf   = "$ROOT/in.$n";
    my $outf  = "$ROOT/out.$n";
    my $errf  = "$ROOT/err.$n";
    my $script = $opt{script} || $SCRIPT;
    write_file($inf, defined $opt{stdin} ? $opt{stdin} : '');
    write_file($outf, '');
    write_file($errf, '');
    my %extra = %{ $opt{env} || {} };
    local %ENV = (%CLEAN_ENV, %extra,
                  LGT_SCRIPT => fwd($script), LGT_IN => fwd($inf),
                  LGT_OUT    => fwd($outf),   LGT_ERR => fwd($errf), LGT_WD => fwd($cwd));
    my $rc = system('bash', '-c',
        'cd "$LGT_WD" && timeout 60 perl "$LGT_SCRIPT" "$@" < "$LGT_IN" > "$LGT_OUT" 2> "$LGT_ERR"',
        'bp-ledger', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

sub claim_check {
    my ($ledger) = @_;
    my ($rc, $out, $err) = run_pl(['claim-check', '--ledger', $ledger]);
    my $report = length($out) ? eval { JSON::PP->new->decode($out) } : undef;
    return ($rc, $out, $err, $report);
}

sub without_ledger_field {
    my ($report) = @_;
    return undef unless ref($report) eq 'HASH';
    my %copy = %$report;
    delete $copy{ledger};
    return \%copy;
}

sub migrate_oracle {
    my ($ledger, @extra) = @_;
    return run_pl(['migrate-oracle', '--ledger', $ledger, @extra]);
}

# =====================================================================================
# Ledger fixture construction (completion-claim-integrity.t shape)
# =====================================================================================

my %DEFAULT_STEP_TEXT = (
    1 => 'spec read', 2 => 'implementation', 3 => 'tests written',
    4 => 'implementation complete', 5 => 'tests pass',
    6 => 'Review || red-team complete', 7 => 'promote', 8 => 'UI pass',
);

sub mk_pipeline {
    my (%o) = @_;
    my $ticked = $o{ticked} || {};
    my $na     = $o{na}     || {};
    my @lines;
    for my $n (1 .. 8) {
        my $box = $ticked->{$n} ? '[x]' : '[ ]';
        my $t = $DEFAULT_STEP_TEXT{$n};
        $t .= ' -- N/A, this package touches no UI' if $na->{$n};
        push @lines, "- $box $n. $t";
    }
    return join("\n", @lines);
}

# Both DONE (gated) status with steps 1-7 ticked and 8 N/A -- the standard "everything else
# satisfied, only oracle findings can fire" shape used throughout AC-6..AC-9.
sub gated_pipeline { return mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }) }

# mk_oracle_record(%f) -- builds a FULL record (spec section 2.2), long form.
# no_descriptions => 1 omits the "descriptions" key while still setting descriptions_sha256,
# modelling a status "ok" record with more than ORACLE_DESCRIPTION_CAP (300) descriptions.
sub mk_oracle_record {
    my (%f) = @_;
    my %rec = (
        step        => $f{step},
        path        => $f{path},
        recorded_at => $f{recorded_at} // '2026-07-15T00:00:00Z',
        status      => $f{status}      // 'ok',
    );
    if ($rec{status} eq 'ok') {
        my @descs = @{ $f{descriptions} // [] };
        $rec{sha256}     = $f{sha256}     // ('a' x 64);
        $rec{assertions} = $f{assertions} // scalar(@descs);
        $rec{descriptions_sha256} = $f{descriptions_sha256} // sha256_hex(join("\n", @descs));
        $rec{descriptions} = \@descs unless $f{no_descriptions};
    }
    else {
        $rec{reason} = $f{reason} // 'not a readable file';
    }
    $rec{reaccept} = $f{reaccept} if exists $f{reaccept};
    return \%rec;
}

sub oracle_line {
    my (%f) = @_;
    return '- oracle ' . $J->encode(mk_oracle_record(%f));
}

sub oracle_section {
    my (@lines) = @_;
    return '' unless @lines;
    return join("\n",
        '## Oracle identity', '',
        'Machine-written by `bp-ledger.pl tick-step` at steps 3 and 5. One JSON record per line.',
        'Never hand-edit: `bp-ledger.pl claim-check` reads these to verify the completion claim.',
        '', @lines, '');
}

# mk_ledger(%o) -- status, pipeline, test_paths, oracle_records (arrayref of full
# "- oracle {...}" line strings), filler_bytes (pads ## Decisions & attempt log with that
# many bytes of seeded filler entries, for AC-2's non-vacuity requirement).
sub mk_ledger {
    my (%o) = @_;
    my $status   = defined $o{status}   ? $o{status}   : 'running';
    my $pipeline = defined $o{pipeline} ? $o{pipeline} : mk_pipeline();
    my @fm = ('---', 'package: fixture-pkg', 'blueprint: fixture-bp', "status: $status",
              'write_set:', '  - plugins/butler/scripts/bp-ledger.pl');
    push @fm, "test_paths: $o{test_paths}" if defined $o{test_paths};
    push @fm, 'mandated_means: none', 'last_updated: 2026-07-01T00:00:00Z', '---';

    my $oracle_sec = oracle_section(@{ $o{oracle_records} || [] });

    my @filler;
    if ($o{filler_bytes}) {
        my $n = 0; my $i = 0;
        while ($n < $o{filler_bytes}) {
            $i++;
            my $line = sprintf('- 2026-01-%02dT00:00:00Z -- seeded filler entry %d %s',
                                (($i - 1) % 28) + 1, $i, 'A' x 180);
            push @filler, $line;
            $n += length($line) + 1;
        }
    }
    my @log_lines = @filler ? @filler : ('- 2026-07-29T10:00:00Z -- earlier note');

    my @body = (
        '', '# fixture-pkg', '',
        '## Scope', '', 'Prose section no op may touch.', '',
        '## Next action', '', 'Do the first thing.', '',
        '## Pipeline', '', $pipeline, '',
    );
    push @body, $oracle_sec if length $oracle_sec;
    push @body, (
        '## Decisions & attempt log', '', join("\n", @log_lines), '',
        '## Outputs', '', '- ran something: exit 0', '',
        '## Escalation (when status: blocked)', '', '_(none)_', '',
        '## Dispatch log (auto)', '', '- 2026-07-01T00:00:00Z dispatched worker bp-implementer', '',
    );
    return join("\n", @fm) . join("\n", @body);
}

sub write_ledger {
    my (%o) = @_;
    my $n = ++$tfn;
    my $path = "$ROOT/ledger_$n.md";
    write_file($path, mk_ledger(%o));
    return $path;
}

# .../<bpdir>/packages/<pkg>.md shape, for AC-11's second sidecar-location requirement.
sub write_packages_ledger {
    my (%o) = @_;
    my $n     = ++$tfn;
    my $pkg   = $o{pkg} // "pkgfix$n";
    my $bpdir = "$ROOT/bp_$n";
    make_path("$bpdir/packages");
    my $path = "$bpdir/packages/$pkg.md";
    write_file($path, mk_ledger(%o));
    return $path;
}

# =====================================================================================
# Sidecar helpers (spec 2.4) -- the test computes the EXPECTED sidecar path independently,
# per the spec's own rule, so this is deriving from the spec, not the implementation.
# =====================================================================================

sub expected_sidecar_path {
    my ($ledger) = @_;
    my $p = fwd($ledger);
    # S1 (Decision 13): a bare "packages/x.md" and a "./packages/x.md" resolve to the SAME
    # sidecar a full ".../<bp>/packages/x.md" resolves to -- the prefix before "packages/" is
    # optional, and defaults to "." (the addressed cwd) rather than requiring a dir segment.
    if ($p =~ m{^(?:(.*)/)?packages/([^/]+)\.md$}) {
        my $dir = (defined($1) && length($1)) ? $1 : '.';
        return "$dir/oracle/$2.jsonl";
    }
    my ($dir, $base);
    if ($p =~ m{^(.*)/([^/]+)$}) { ($dir, $base) = ($1, $2) }
    else                          { ($dir, $base) = ('.', $p) }
    $base =~ s/\.md$//;
    return "$dir/oracle/$base.jsonl";
}

sub read_sidecar {
    my ($path) = @_;
    return [] unless -e $path;
    my @out;
    for my $line (split /\n/, read_file($path)) {
        next unless length $line;
        my $d = eval { JSON::PP->new->decode($line) };
        push @out, $d if ref($d) eq 'HASH';
    }
    return \@out;
}

# =====================================================================================
# Derivation-fixture .t generators (completion-claim-integrity.t precedent)
# =====================================================================================

sub gen_tap_fixture {
    my ($descs) = @_;
    my $path = "$ROOT/oracle_fixture_" . (++$tfn) . ".t";
    my @lines = ('#!/usr/bin/env perl', 'use strict; use warnings;', 'my @d = (');
    push @lines, join(",\n", map { my $d = $_; $d =~ s/'/\\'/g; "  '$d'" } @$descs);
    push @lines, ');', 'my $i = 0;', 'for my $d (@d) { $i++; print "ok $i - $d\n"; }';
    write_file($path, join("\n", @lines) . "\n");
    return $path;
}

# ~90-byte description text, deterministic per index, no "(" so it is never normalized away.
sub gen_desc { my ($i) = @_; return sprintf('assertion %04d %s', $i, 'x' x 75) }

# =====================================================================================
# AC-1: 15 test paths, 250 descriptions each -- every oracle line <=400 bytes, exactly 30
# lines (steps 3 and 5), and the ## Oracle identity section itself is <=12500 bytes.
# =====================================================================================

my ($AC1_LEDGER, @AC1_PATH_SEGS);
{
    my @segs;
    for my $p (1 .. 15) {
        my @descs = map { gen_desc($_) } (1 .. 250);
        my $t = gen_tap_fixture(\@descs);
        push @segs, fwd($t);
    }
    @AC1_PATH_SEGS = @segs;
    my $seg = join(':', @segs);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    $AC1_LEDGER = $ledger;

    my ($rc3) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    is($rc3, 0, 'AC-1: tick-step --step 3 on the 15-path/250-description fixture exits 0');
    my ($rc5) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5']);
    is($rc5, 0, 'AC-1: tick-step --step 5 on the same fixture exits 0');

    my $bytes = read_file($ledger);
    my @lines = ($bytes =~ /^(- oracle \{.*\})$/mg);
    is(scalar(@lines), 30, 'AC-1: exactly 30 "- oracle" lines (15 paths x steps 3 and 5)');

    my $max_len = 0;
    my $any_has_descriptions = 0;
    for my $l (@lines) {
        my $len = length($l);
        $max_len = $len if $len > $max_len;
        ok($len <= 400, "AC-1: an oracle line is at most 400 bytes including the prefix (got $len)");
        my ($json) = ($l =~ /^- oracle (\{.*\})$/);
        my $rec = $json ? eval { JSON::PP->new->decode($json) } : undef;
        $any_has_descriptions = 1 if $rec && exists $rec->{descriptions};
    }
    diag("AC-1: longest oracle line observed: $max_len bytes");
    ok(!$any_has_descriptions, 'AC-1: no compact oracle line carries a "descriptions" key');

    if ($bytes =~ /(## Oracle identity\b.*?)(?=\n## [A-Z])/s) {
        my $section = $1;
        ok(length($section) <= 12500,
            'AC-1: the ## Oracle identity section itself is 12500 bytes or less (got ' . length($section) . ')');
    }
    else {
        fail('AC-1: could not locate a bounded ## Oracle identity section to measure');
    }
}

# =====================================================================================
# AC-2: non-vacuity for AC-1 -- with a seeded >=20000-byte attempt log, the sidecar for the
# 15-path fixture is itself larger than 40000 bytes (proving long form would have blown the
# budget), while the post-tick ledger stays at/under 40000 (and at least 30000).
# =====================================================================================

my $AC2_LEDGER;
{
    my @segs = @AC1_PATH_SEGS; # re-use the same 15 generated .t fixtures
    my $seg = join(':', @segs);
    my $ledger = write_ledger(status => 'running', test_paths => $seg, filler_bytes => 20000);
    my $pre_sz = -s $ledger;
    ok($pre_sz >= 20000, "AC-2 FIXTURE-SANITY: seeded attempt log alone is >=20000 bytes (got $pre_sz)");
    $AC2_LEDGER = $ledger;

    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my ($rc5) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5']);
    is($rc5, 0, 'AC-2: tick-step --step 5 on the seeded 15-path fixture exits 0');

    my $post_sz = -s $ledger;
    ok($post_sz >= 30000, "AC-2: the post-tick ledger is at least 30000 bytes (got $post_sz)");
    ok($post_sz <= 40000, "AC-2: the post-tick ledger is 40000 bytes or less (got $post_sz)");

    my $sidecar = expected_sidecar_path($ledger);
    ok(-e $sidecar, "AC-2: the sidecar file exists at the expected path ($sidecar)");
    my $sc_sz = -e $sidecar ? -s $sidecar : 0;
    ok($sc_sz > 40000,
        "AC-2: the sidecar is itself larger than 40000 bytes (got $sc_sz), proving the long form would have "
      . 'broken the budget');
}

# =====================================================================================
# AC-3: append-attempt on the (near-budget) AC-2 ledger exits 0 with EMPTY stderr -- no
# BUDGET_OVER / LEDGER_IRREDUCIBLE notice -- and the appended text lands.
# =====================================================================================
{
    my $textfile = write_file("$ROOT/ac3-text.txt", 'an attempt recorded after the 15-path oracle tick');
    my ($rc, $out, $err) = run_pl(['append-attempt', '--ledger', $AC2_LEDGER, '--text-file', $textfile]);
    is($rc, 0, 'AC-3: append-attempt on the AC-2 ledger exits 0');
    is($err, '', 'AC-3: ...with empty stderr (no BUDGET_OVER / LEDGER_IRREDUCIBLE notice)');
    like(read_file($AC2_LEDGER), qr/an attempt recorded after the 15-path oracle tick/,
        'AC-3: the appended attempt text landed in the attempt log');
}

# =====================================================================================
# AC-4: tick-step --step 5 --reaccept-oracle / --reaccept-reason.
# =====================================================================================
{
    my $t = gen_tap_fixture(['ac4 alpha', 'ac4 beta']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running',
        pipeline => mk_pipeline(ticked => { 1 => 1, 2 => 1, 3 => 1 }), test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - ac4 alpha\n"; print "ok 2 - ac4 beta\n"; print "ok 3 - ac4 gamma (new)\n";') . "\n");

    # 4a: without --reaccept-oracle, claim-check reports ORACLE_DRIFT_UNACCEPTED naming "gamma".
    my $ledger_a = "$ROOT/ac4a.md";
    write_file($ledger_a, mk_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => $seg,
                                     oracle_records => []));
    # replay: tick-step step3 then step5 onto a done-shaped ledger built the same way tick-step would leave it.
    # $t must still hold the 2-assertion fixture for this step-3 tick -- rewrite to 3 assertions only
    # AFTER, so ledger_a's step-3 and step-5 oracle records genuinely differ (mirrors AC-4b below).
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - ac4 alpha\n"; print "ok 2 - ac4 beta\n";') . "\n");
    run_pl(['tick-step', '--ledger', $ledger_a, '--step', '3']);
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - ac4 alpha\n"; print "ok 2 - ac4 beta\n"; print "ok 3 - ac4 gamma (new)\n";') . "\n");
    my ($rc5a) = run_pl(['tick-step', '--ledger', $ledger_a, '--step', '5']);
    is($rc5a, 0, 'AC-4a: tick-step --step 5 (no reaccept) exits 0');
    my (undef, undef, undef, $report_a) = claim_check($ledger_a);
    ok($report_a, 'AC-4a: claim-check produced a decodable report');
    SKIP: {
        skip 'no report', 2 unless $report_a;
        my ($f) = grep { $_->{code} eq 'ORACLE_DRIFT_UNACCEPTED' } @{ $report_a->{findings} || [] };
        ok($f, 'AC-4a: ORACLE_DRIFT_UNACCEPTED fires without a reaccept');
        like(($f && $f->{detail}) // '', qr/gamma/, 'AC-4a: detail names the added description');
    }

    # 4b: same setup, WITH --reaccept-oracle/--reaccept-reason.
    my $t2 = gen_tap_fixture(['ac4b alpha', 'ac4b beta']);
    my $seg2 = fwd($t2);
    my $ledger_b = "$ROOT/ac4b.md";
    write_file($ledger_b, mk_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => $seg2,
                                     oracle_records => []));
    run_pl(['tick-step', '--ledger', $ledger_b, '--step', '3']);
    write_file($t2, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - ac4b alpha\n"; print "ok 2 - ac4b beta\n"; print "ok 3 - ac4b gamma (new)\n";') . "\n");
    my ($rc5b, $out5b, $err5b) = run_pl(['tick-step', '--ledger', $ledger_b, '--step', '5',
                                          '--reaccept-oracle', $seg2, '--reaccept-reason', 'AC-4 legitimate addition']);
    is($rc5b, 0, 'AC-4b: tick-step --step 5 with --reaccept-oracle/--reaccept-reason exits 0');
    my $bytes_b = read_file($ledger_b);
    my ($step5json) = ($bytes_b =~ /^- oracle (\{.*"step":5.*\})$/m);
    my $step5rec = $step5json ? eval { JSON::PP->new->decode($step5json) } : undef;
    ok($step5rec && ($step5rec->{reaccepted} || (ref($step5rec->{reaccept}) eq 'HASH')),
        'AC-4b: the step-5 line records the reaccept (compact "reaccepted":true or long-form "reaccept")');

    my $sidecar_b = expected_sidecar_path($ledger_b);
    my $sc_entries_b = read_sidecar($sidecar_b);
    my ($sc_step5) = grep { ($_->{step} // -1) == 5 && exists $_->{reaccept} } @$sc_entries_b;
    ok($sc_step5, 'AC-4b: the sidecar step-5 entry carries a reaccept block')
        or diag('sidecar entries: ' . $J->encode($sc_entries_b));
    SKIP: {
        skip 'no sidecar step-5 reaccept entry', 2 unless $sc_step5;
        is($sc_step5->{reaccept}{reason}, 'AC-4 legitimate addition',
            'AC-4b: sidecar reaccept.reason equals R');
        like(join(',', @{ $sc_step5->{reaccept}{delta}{descriptions_added} // [] }), qr/gamma/,
            'AC-4b: sidecar reaccept.delta.descriptions_added names the new description');
    }

    my (undef, undef, undef, $report_b) = claim_check($ledger_b);
    ok($report_b, 'AC-4b: claim-check produced a decodable report');
    SKIP: {
        skip 'no report', 2 unless $report_b;
        my @findings_for_p = grep { ($_->{path} // '') eq $seg2 } @{ $report_b->{findings} || [] };
        is(scalar(@findings_for_p), 0, 'AC-4b: no finding fires for the reaccepted path');
        my ($pentry) = grep { ($_->{path} // '') eq $seg2 } @{ $report_b->{oracle}{paths} || [] };
        is($pentry && $pentry->{verdict}, 'reaccepted', 'AC-4b: claim-check verdict is "reaccepted"')
            if $pentry;
    }
}

# =====================================================================================
# AC-5: same as AC-4b but SHRUNK (an assertion removed). Decision 6(3) had ORACLE_SHRANK fire
# despite any reaccept; the operator overruled that on 2026-10-23 (renamed and replaced
# descriptions gated packages forever). A reaccept recorded against this exact state names
# the vanished descriptions and the new count in its delta, so it now settles the shrink;
# completion-claim-integrity.t covers a removal the reaccept did NOT see still gating.
# =====================================================================================
{
    my $t = gen_tap_fixture(['ac5 one', 'ac5 two', 'ac5 three']);
    my $seg = fwd($t);
    my $ledger = "$ROOT/ac5.md";
    write_file($ledger, mk_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => $seg,
                                   oracle_records => []));
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    write_file($t, join("\n", '#!/usr/bin/env perl', 'print "ok 1 - ac5 one\n";') . "\n"); # shrank to 1 assertion
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5',
                        '--reaccept-oracle', $seg, '--reaccept-reason', 'AC-5 intentional removal']);
    is($rc, 0, 'AC-5: tick-step --step 5 with a reaccept over a shrunk file exits 0');
    my (undef, undef, undef, $report) = claim_check($ledger);
    ok($report, 'AC-5: claim-check produced a decodable report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_SHRANK' } @{ $report->{findings} || [] } : ();
    ok(!$f, 'AC-5: a reaccept recorded against the shrunk state settles ORACLE_SHRANK (operator ruling 2026-10-23)');
    my ($pentry) = $report ? grep { ($_->{path} // '') eq $seg } @{ $report->{oracle}{paths} || [] } : ();
    is($pentry && $pentry->{verdict}, 'reaccepted', 'AC-5: and the path verdict is "reaccepted"');
}

# =====================================================================================
# AC-6: verdict identity matrix -- long form / migrated / mixed give the SAME claim-check
# output for each of the 8 record kinds.
# =====================================================================================

sub migrate_single_record_line {
    my ($rec_line, $path_seg) = @_;
    my $tmp = write_ledger(status => 'running', test_paths => $path_seg, oracle_records => [$rec_line]);
    my ($rc) = migrate_oracle($tmp);
    return (undef, undef) unless $rc == 0;
    my $bytes = read_file($tmp);
    my ($compact_line) = ($bytes =~ /^(- oracle \{.*\})$/m);
    my $sidecar = expected_sidecar_path($tmp);
    my $sidecar_bytes = -e $sidecar ? read_file($sidecar) : '';
    return ($compact_line, $sidecar_bytes);
}

{
    my @kinds = (
        { label => 'ok_identical',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, descriptions => [qw(alpha beta gamma)]) },
          step5 => sub { my $p = shift; oracle_line(step => 5, path => $p, descriptions => [qw(alpha beta gamma)]) } },
        { label => 'ok_drifted_no_reaccept',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, descriptions => [qw(alpha beta)]) },
          step5 => sub { my $p = shift; oracle_line(step => 5, path => $p, descriptions => [qw(alpha beta gamma)]) } },
        { label => 'ok_drifted_with_reaccept',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, descriptions => [qw(alpha beta)]) },
          step5 => sub { my $p = shift; oracle_line(step => 5, path => $p, descriptions => [qw(alpha beta gamma)],
                                                     reaccept => { reason => 'ac6', delta => {} }) } },
        { label => 'shrunk',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, descriptions => [map {"d$_"} 1..20]) },
          step5 => sub { my $p = shift; oracle_line(step => 5, path => $p, descriptions => [map {"d$_"} 1..5],
                                                     reaccept => { reason => 'ac6-shrink', delta => {} }) } },
        { label => 'parenthetical_equal',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, descriptions => ['rows counted (got 0)']) },
          step5 => sub { my $p = shift; oracle_line(step => 5, path => $p, descriptions => ['rows counted (got 30)']) } },
        { label => 'unavailable_step3',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, status => 'unavailable', reason => 'run failed') },
          step5 => undef },
        { label => 'step5_missing',
          step3 => sub { my $p = shift; oracle_line(step => 3, path => $p, descriptions => [qw(x y)]) },
          step5 => undef },
        { label => 'over_cap_step3_vs_step5_with_descriptions',
          step3 => sub { my $p = shift;
              my @big = map { "d$_" } 1 .. 320;
              oracle_line(step => 3, path => $p, no_descriptions => 1, assertions => 320,
                          descriptions_sha256 => sha256_hex(join("\n", @big))) },
          step5 => sub { my $p = shift; oracle_line(step => 5, path => $p, descriptions => [qw(e1 e2 e3)]) } },
    );

    for my $k (@kinds) {
        my $path = "ac6_$k->{label}.t";
        my $step3_line = $k->{step3} ? $k->{step3}->($path) : undef;
        my $step5_line = $k->{step5} ? $k->{step5}->($path) : undef;
        my @recs = grep { defined } ($step3_line, $step5_line);

        # (i) all long form
        my $ledger_i = write_ledger(status => 'done', pipeline => gated_pipeline(),
                                     test_paths => $path, oracle_records => \@recs);
        my (undef, undef, undef, $report_i) = claim_check($ledger_i);
        ok($report_i, "AC-6 [$k->{label}]: long-form claim-check produced a decodable report");

        # (ii) fully migrated
        my $ledger_ii = write_ledger(status => 'done', pipeline => gated_pipeline(),
                                      test_paths => $path, oracle_records => \@recs);
        my ($mrc) = migrate_oracle($ledger_ii);
        is($mrc, 0, "AC-6 [$k->{label}]: migrate-oracle on the two-record ledger exits 0");
        my (undef, undef, undef, $report_ii) = claim_check($ledger_ii);
        is_deeply(without_ledger_field($report_ii), without_ledger_field($report_i),
            "AC-6 [$k->{label}]: migrated claim-check output matches long-form output");

        # (iii) mixed: keep step3 long form, convert ONLY step5
        if ($step5_line) {
            my ($compact5, $sidecar5_bytes) = migrate_single_record_line($step5_line, $path);
            SKIP: {
                skip 'migrate-oracle unavailable for the single-record extraction', 1 unless $compact5;
                my @mixed_recs = grep { defined } ($step3_line, $compact5);
                my $ledger_iii = write_ledger(status => 'done', pipeline => gated_pipeline(),
                                               test_paths => $path, oracle_records => \@mixed_recs);
                my $sidecar_iii = expected_sidecar_path($ledger_iii);
                write_file($sidecar_iii, $sidecar5_bytes // '');
                my (undef, undef, undef, $report_iii) = claim_check($ledger_iii);
                is_deeply(without_ledger_field($report_iii), without_ledger_field($report_i),
                    "AC-6 [$k->{label}]: mixed (long step3 + compact step5) claim-check output matches long-form output");
            }
        }
    }
}

# =====================================================================================
# AC-7: mixed via tick-step -- a hand-authored long-form step-3 record survives a step-5
# tick byte-identical (still long form, no "v"); the new step-5 line is compact; claim-check
# gives "ok" for an unchanged file and "drifted"/ORACLE_DRIFT_UNACCEPTED for a changed one.
# =====================================================================================
{
    # AC-7a: unchanged file -> verdict ok, no finding.
    my $t = gen_tap_fixture(['ac7 one', 'ac7 two']);
    my $seg = fwd($t);
    my $step3_line = oracle_line(step => 3, path => $seg, sha256 => sha256_hex(read_file($t)),
                                  assertions => 2, descriptions => ['ac7 one', 'ac7 two']);
    my $ledger = write_ledger(status => 'done', pipeline => gated_pipeline(),
                              test_paths => $seg, oracle_records => [$step3_line]);
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5']);
    is($rc, 0, 'AC-7a: tick-step --step 5 over a hand-authored long-form step-3 record exits 0');
    my $after = read_file($ledger);
    like($after, qr/\Q$step3_line\E/, 'AC-7a: the step-3 line is byte-identical and still present');
    my ($step3_after) = ($after =~ /^(- oracle \{.*"step":3.*\})$/m);
    unlike($step3_after // '', qr/"v":2/, 'AC-7a: the step-3 line is still long form (no "v":2)');
    my @step5lines = ($after =~ /^(- oracle \{.*"step":5.*\})$/mg);
    is(scalar(@step5lines), 1, 'AC-7a: exactly one step-5 line exists');
    like($step5lines[0] // '', qr/"v":2/, 'AC-7a: the new step-5 line is compact') if @step5lines;
    my (undef, undef, undef, $report) = claim_check($ledger);
    ok($report, 'AC-7a: claim-check produced a decodable report');
    SKIP: {
        skip 'no report', 2 unless $report;
        my ($pentry) = grep { ($_->{path} // '') eq $seg } @{ $report->{oracle}{paths} || [] };
        is($pentry && $pentry->{verdict}, 'ok', 'AC-7a: verdict is "ok" for the unchanged file') if $pentry;
        is(scalar(grep { ($_->{path} // '') eq $seg } @{ $report->{findings} || [] }), 0,
            'AC-7a: no finding for the unchanged file');
    }
}
{
    # AC-7b: changed file -> "drifted" verdict + ORACLE_DRIFT_UNACCEPTED.
    my $t = gen_tap_fixture(['ac7b one', 'ac7b two']);
    my $seg = fwd($t);
    my $step3_line = oracle_line(step => 3, path => $seg, sha256 => sha256_hex(read_file($t)),
                                  assertions => 2, descriptions => ['ac7b one', 'ac7b two']);
    my $ledger = write_ledger(status => 'done', pipeline => gated_pipeline(),
                              test_paths => $seg, oracle_records => [$step3_line]);
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - ac7b one\n"; print "ok 2 - ac7b two\n"; print "ok 3 - ac7b three (new)\n";') . "\n");
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5']);
    is($rc, 0, 'AC-7b: tick-step --step 5 over a changed file exits 0');
    my (undef, undef, undef, $report) = claim_check($ledger);
    ok($report, 'AC-7b: claim-check produced a decodable report');
    SKIP: {
        skip 'no report', 2 unless $report;
        my ($f) = grep { $_->{code} eq 'ORACLE_DRIFT_UNACCEPTED' && ($_->{path} // '') eq $seg }
                  @{ $report->{findings} || [] };
        ok($f, 'AC-7b: ORACLE_DRIFT_UNACCEPTED fires for the changed file');
        my ($pentry) = grep { ($_->{path} // '') eq $seg } @{ $report->{oracle}{paths} || [] };
        is($pentry && $pentry->{verdict}, 'drifted', 'AC-7b: verdict is "drifted"') if $pentry;
    }
}

# =====================================================================================
# AC-8: backward reading -- a long-form ledger, never migrated, gives the pinned verdicts.
# No sidecar file is created merely by running claim-check.
# =====================================================================================
{
    my $step3 = oracle_line(step => 3, path => 'ac8.t', descriptions => [map {"d$_"} 1..20]);
    my $step5 = oracle_line(step => 5, path => 'ac8.t', descriptions => [map {"d$_"} 1..5]);
    my $ledger = write_ledger(status => 'done', pipeline => gated_pipeline(),
                              test_paths => 'ac8.t', oracle_records => [$step3, $step5]);
    my $sidecar = expected_sidecar_path($ledger);
    ok(!-e $sidecar, 'AC-8 FIXTURE-SANITY: no sidecar exists before claim-check runs');
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-8: claim-check on a never-migrated long-form ledger exits 0');
    ok($report, 'AC-8: claim-check produced a decodable report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_SHRANK' } @{ $report->{findings} || [] } : ();
    ok($f, 'AC-8: the pinned ORACLE_SHRANK verdict fires exactly as it does today, unmigrated');
    ok(!-e $sidecar, 'AC-8: claim-check never creates a sidecar file as a side effect');
}

# =====================================================================================
# AC-9 / AC-10: migrate-oracle -- real run, dry-run, idempotency, validation failure, usage
# error.
# =====================================================================================
{
    my $ok3   = oracle_line(step => 3, path => 'mig_ok.t', descriptions => [qw(a b c)]);
    my $unav  = oracle_line(step => 3, path => 'mig_unav.t', status => 'unavailable', reason => 'run failed');
    my $re5   = oracle_line(step => 5, path => 'mig_re.t', descriptions => [qw(x y)],
                             reaccept => { reason => 'because', delta => {} });
    my $plain5= oracle_line(step => 5, path => 'mig_ok.t', descriptions => [qw(a b c)]);
    my @recs  = ($ok3, $unav, $re5, $plain5);
    my $ledger = write_ledger(status => 'running', test_paths => 'mig_ok.t:mig_unav.t:mig_re.t',
                              oracle_records => \@recs);
    my $before_ledger_bytes = read_file($ledger);
    my (undef, undef, undef, $report_before) = claim_check($ledger);

    my ($rc, $out, $err) = migrate_oracle($ledger);
    is($rc, 0, 'AC-9: migrate-oracle on a 4-record long-form ledger exits 0');
    is($err, '', 'AC-9: ...with empty stderr');
    my @outlines = split /\n/, $out;
    is(scalar(@outlines), 1, 'AC-9: exactly one stdout line');
    like($out, qr/^bp-ledger: migrate-oracle: \Q$ledger\E: compacted 4 of 4 oracle records; \d+ -> \d+ bytes; sidecar .+$/,
        'AC-9: the stdout summary line matches the exact pinned shape');

    my $after = read_file($ledger);
    my @lines = ($after =~ /^(- oracle \{.*\})$/mg);
    is(scalar(@lines), 4, 'AC-9: still 4 oracle lines after migration');
    ok((scalar(grep { /"v":2/ } @lines)) == 4, 'AC-9: every oracle line now carries "v":2');

    my $sidecar = expected_sidecar_path($ledger);
    my $sc_entries = read_sidecar($sidecar);
    for my $orig (@recs) {
        my ($json) = ($orig =~ /^- oracle (\{.*\})$/);
        my $orig_rec = eval { JSON::PP->new->decode($json) };
        my ($match) = grep { $J->encode($_) eq $J->encode($orig_rec) } @$sc_entries;
        ok($match, 'AC-9: each pre-migration long-form record has a byte-identical sidecar entry')
            or diag("missing sidecar entry for: $json");
    }

    my (undef, undef, undef, $report_after) = claim_check($ledger);
    is_deeply(without_ledger_field($report_after), without_ledger_field($report_before),
        'AC-9: claim-check stdout is byte-identical in structure before and after migration');

    # frontmatter and everything outside ## Oracle identity is untouched.
    (my $before_no_oracle = $before_ledger_bytes) =~ s/## Oracle identity\b.*?(?=\n## [A-Z])//s;
    (my $after_no_oracle  = $after)               =~ s/## Oracle identity\b.*?(?=\n## [A-Z])//s;
    is($after_no_oracle, $before_no_oracle,
        'AC-9: the ledger outside ## Oracle identity is byte-identical, frontmatter included');

    # AC-10: a second run reports 0 of 4, byte-identical.
    my ($rc2, $out2, $err2) = migrate_oracle($ledger);
    is($rc2, 0, 'AC-10: a second migrate-oracle run exits 0');
    like($out2, qr/compacted 0 of 4/, 'AC-10: the second run reports "compacted 0 of 4"');
    is(read_file($ledger), $after, 'AC-10: the ledger is byte-identical after the second (no-op) run');

    # AC-10: --dry-run on a fresh long-form ledger. Its own tempdir, not $ROOT -- $ROOT/oracle/
    # already exists from the real migrate-oracle run above, so a shared root can't distinguish
    # "dry-run created nothing" from "something else already created the sidecar directory".
    my $fresh_root = tempdir(CLEANUP => 1);
    my $fresh = "$fresh_root/dry.md";
    write_file($fresh, mk_ledger(status => 'running', test_paths => 'dry.t',
                              oracle_records => [oracle_line(step => 3, path => 'dry.t', descriptions => [qw(p q)])]));
    my $fresh_before = read_file($fresh);
    my $fresh_sidecar = expected_sidecar_path($fresh);
    ok(!-e $fresh_sidecar, 'AC-10 FIXTURE-SANITY: no sidecar dir exists for the dry-run fixture yet');
    my ($drc, $dout, $derr) = migrate_oracle($fresh, '--dry-run');
    is($drc, 0, 'AC-10: migrate-oracle --dry-run exits 0');
    like($dout, qr/would compact 1 of 1/, 'AC-10: --dry-run prints "would compact" in place of "compacted"');
    is(read_file($fresh), $fresh_before, 'AC-10: --dry-run leaves the ledger byte-identical');
    ok(!-e $fresh_sidecar, 'AC-10: --dry-run creates no sidecar file');
    ok(!-d dirname($fresh_sidecar), 'AC-10: --dry-run creates no oracle/ directory');

    # AC-10: last_updated in the future-skew window (or invalid bytes) exits 2, byte-identical.
    my $skew_ledger = write_ledger(status => 'running', test_paths => 'skew.t',
                                    oracle_records => [oracle_line(step => 3, path => 'skew.t', descriptions => [qw(z)])]);
    (my $skewed = read_file($skew_ledger)) =~ s/last_updated: 2026-07-01T00:00:00Z/last_updated: 2099-01-01T00:00:00Z/;
    write_file($skew_ledger, $skewed);
    my $skew_before = read_file($skew_ledger);
    my ($src, $sout, $serr) = migrate_oracle($skew_ledger);
    is($src, 2, 'AC-10: migrate-oracle on a ledger with a future-skewed last_updated exits 2');
    is(read_file($skew_ledger), $skew_before, 'AC-10: ...and the ledger is byte-identical');

    # AC-10: missing --ledger exits 3.
    my ($nrc, $nout, $nerr) = run_pl(['migrate-oracle']);
    is($nrc, 3, 'AC-10: migrate-oracle with a missing --ledger exits 3');
}

# AC-9 (N=0 case): a ledger with no ## Oracle identity section is "0 of 0", exit 0.
{
    my $ledger = write_ledger(status => 'running', test_paths => undef);
    my ($rc, $out, $err) = migrate_oracle($ledger);
    is($rc, 0, 'AC-9 (N=0): migrate-oracle on a ledger with no oracle section exits 0');
    like($out, qr/compacted 0 of 0/, 'AC-9 (N=0): reports "compacted 0 of 0"');
}

# =====================================================================================
# AC-11: sidecar holds the full assertion list; sidecar path shape for both a flat fixture
# ledger and a <bpdir>/packages/<pkg>.md ledger.
# =====================================================================================
{
    my $t = gen_tap_fixture(['alpha', 'beta (got 1)', 'gamma']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my $bytes = read_file($ledger);
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $compact = $line ? eval { JSON::PP->new->decode($line) } : undef;

    my $sidecar = expected_sidecar_path($ledger);
    my $entries = read_sidecar($sidecar);
    my ($entry) = grep { ($_->{step} // -1) == 3 } @$entries;
    ok($entry, 'AC-11: the sidecar has a step-3 entry for the ticked path');
    SKIP: {
        skip 'no sidecar entry to inspect', 2 unless $entry;
        is_deeply($entry->{descriptions}, ['alpha', 'beta', 'gamma'],
            'AC-11: the sidecar descriptions are normalized exactly as today');
        is($entry->{descriptions_sha256}, $compact && $compact->{descriptions_sha256},
            'AC-11: the sidecar entry\'s descriptions_sha256 matches the compact line\'s')
            if $compact;
    }

    is($sidecar, "$ROOT/oracle/" . (do { (my $b = $ledger) =~ s{^.*/}{}; $b =~ s/\.md$//; $b }) . '.jsonl',
        'AC-11: a flat fixture ledger\'s sidecar is <dir>/oracle/<basename>.jsonl');

    # packages/ shape
    my $pkg_ledger = write_packages_ledger(status => 'running', test_paths => $seg, pkg => 'ac11-pkg');
    run_pl(['tick-step', '--ledger', $pkg_ledger, '--step', '3']);
    my $pkg_sidecar = expected_sidecar_path($pkg_ledger);
    (my $bpdir = $pkg_ledger) =~ s{/packages/ac11-pkg\.md$}{};
    is($pkg_sidecar, "$bpdir/oracle/ac11-pkg.jsonl",
        'AC-11: a <bpdir>/packages/<pkg>.md ledger\'s sidecar is <bpdir>/oracle/<pkg>.jsonl');
    ok(-e $pkg_sidecar, 'AC-11: the packages-shaped sidecar file was actually created');
}

# =====================================================================================
# AC-12: long path -- path_sha256 substitution when the encoded path pushes the line over
# the 400-byte cap; claim-check still reports the full path and resolves it even with the
# sidecar deleted.
# =====================================================================================
{
    my $longsuffix = 'x' x 140;
    my @descs = map { gen_desc($_) } (1 .. 5);
    my $t = gen_tap_fixture(\@descs);
    # rename the fixture to a LONG path (>150 bytes) so the compact line must drop "path".
    my $longdir = "$ROOT/long_$longsuffix";
    make_path($longdir);
    my $longpath = "$longdir/oracle_fixture_long.t";
    rename($t, $longpath) or die "rename $t -> $longpath: $!";
    my $seg = fwd($longpath);
    ok(length($seg) > 150, "AC-12 FIXTURE-SANITY: the test path segment is longer than 150 bytes (" . length($seg) . ")");

    my $ledger = write_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my $bytes = read_file($ledger);
    my ($line) = ($bytes =~ /^(- oracle \{.*\})$/m);
    ok(defined $line, 'AC-12: a compact line was written for the long-path fixture');
    SKIP: {
        skip 'no line to inspect', 3 unless defined $line;
        ok(length($line) <= 400, 'AC-12: the compact line is still <=400 bytes despite the long path');
        my ($json) = ($line =~ /^- oracle (\{.*\})$/);
        my $rec = eval { JSON::PP->new->decode($json) };
        ok($rec && !exists $rec->{path} && exists $rec->{path_sha256},
            'AC-12: the record carries path_sha256 instead of path');
        is($rec && $rec->{path_sha256}, sha256_hex($seg),
            'AC-12: path_sha256 is the SHA-256 hex digest of the path string') if $rec;
    }

    my (undef, undef, undef, $report) = claim_check($ledger);
    ok($report, 'AC-12: claim-check produced a decodable report with the sidecar present');
    my ($pentry) = $report ? grep { ($_->{path} // '') eq $seg } @{ $report->{oracle}{paths} || [] } : ();
    ok($pentry, 'AC-12: claim-check reports the FULL path in oracle.paths[].path, not the digest');

    # delete the sidecar -- claim-check must still resolve the path via test_paths.
    my $sidecar = expected_sidecar_path($ledger);
    unlink $sidecar if -e $sidecar;
    my (undef, undef, undef, $report2) = claim_check($ledger);
    ok($report2, 'AC-12: claim-check still produces a decodable report with the sidecar deleted');
    my ($pentry2) = $report2 ? grep { ($_->{path} // '') eq $seg } @{ $report2->{oracle}{paths} || [] } : ();
    ok($pentry2, 'AC-12: with the sidecar deleted, claim-check still resolves the full path via test_paths');
}

# =====================================================================================
# AC-13: lost sidecar -- an identical-at-both-steps fixture still verdicts "ok" with the
# sidecar deleted, carrying "sidecar":"missing"; a drift fixture with a deleted sidecar
# still reports ORACLE_DRIFT_UNACCEPTED via the descriptions_sha256 fallback.
# =====================================================================================
{
    my $t = gen_tap_fixture(['ac13 one', 'ac13 two']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '5']); # identical file at both steps
    my $sidecar = expected_sidecar_path($ledger);
    ok(-e $sidecar, 'AC-13 FIXTURE-SANITY: the sidecar exists before deletion');
    unlink $sidecar;

    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-13: claim-check still exits 0 with the sidecar deleted');
    ok($report, 'AC-13: claim-check still produces a decodable report');
    SKIP: {
        skip 'no report', 2 unless $report;
        my ($pentry) = grep { ($_->{path} // '') eq $seg } @{ $report->{oracle}{paths} || [] };
        is($pentry && $pentry->{verdict}, 'ok', 'AC-13: verdict is still "ok" with the sidecar gone');
        is($pentry && $pentry->{sidecar}, 'missing', 'AC-13: the path entry carries "sidecar":"missing"');
    }

    # drift fixture, sidecar deleted
    my $t2 = gen_tap_fixture(['ac13b one', 'ac13b two']);
    my $seg2 = fwd($t2);
    my $ledger2 = write_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => $seg2);
    run_pl(['tick-step', '--ledger', $ledger2, '--step', '3']);
    write_file($t2, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - ac13b one\n"; print "ok 2 - ac13b two\n"; print "ok 3 - ac13b three (new)\n";') . "\n");
    run_pl(['tick-step', '--ledger', $ledger2, '--step', '5']);
    my $sidecar2 = expected_sidecar_path($ledger2);
    unlink $sidecar2 if -e $sidecar2;
    my (undef, undef, undef, $report2) = claim_check($ledger2);
    ok($report2, 'AC-13: drift fixture with sidecar deleted still produces a decodable report');
    my ($f) = $report2 ? grep { $_->{code} eq 'ORACLE_DRIFT_UNACCEPTED' } @{ $report2->{findings} || [] } : ();
    ok($f, 'AC-13: ORACLE_DRIFT_UNACCEPTED still fires via the descriptions_sha256 fallback with no sidecar');
}

# =====================================================================================
# AC-14: sidecar unwritable -- a regular FILE occupies the sidecar's directory slot.
# tick-step --step 3 exits 0, the box is ticked, the record is written LONG FORM (no "v"),
# with "descriptions". Per Decision 11's amendment, exactly ONE stderr warning naming the
# ledger and the reason is printed (this SUPERSEDES the base spec's "no stderr" line).
# =====================================================================================
{
    # Own tempdir, not $ROOT -- $ROOT/oracle/ already exists as a real directory (AC-9's
    # non-dry migrate-oracle run created it), so writing a FILE at that shared path to block
    # the directory slot would collide with AC-9/11/12/13's fixtures instead of testing anything.
    my $ac14_root = tempdir(CLEANUP => 1);
    my $t = gen_tap_fixture(['ac14 one', 'ac14 two']);
    my $seg = fwd($t);
    my $ledger = "$ac14_root/ledger.md";
    write_file($ledger, mk_ledger(status => 'running', test_paths => $seg));
    my $sidecar = expected_sidecar_path($ledger);
    my $oracle_dir = dirname($sidecar);
    make_path(dirname($oracle_dir));
    write_file($oracle_dir, "a regular file blocking the oracle/ directory slot\n"); # FILE, not a dir

    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    is($rc, 0, 'AC-14: tick-step exits 0 even when the sidecar cannot be written');
    like(read_file($ledger), qr/^- \[x\] 3\./m, 'AC-14: the checkbox for step 3 is ticked regardless');
    my ($line) = (read_file($ledger) =~ /^(- oracle \{.*\})$/m);
    ok(defined $line, 'AC-14: an oracle record line was still written');
    SKIP: {
        skip 'no line to inspect', 2 unless defined $line;
        unlike($line, qr/"v":2/, 'AC-14: the fallback record is written LONG FORM (no "v":2)');
        like($line, qr/"descriptions":/, 'AC-14: the long-form fallback record carries "descriptions"');
    }
    my @errlines = split /\n/, $err;
    is(scalar(@errlines), 1,
        "AC-14 (Decision 11 amendment): exactly one stderr warning is printed on the sidecar-write fallback")
        or diag("stderr was: $err");
    like($err, qr/\Q$ledger\E/, 'AC-14: the stderr warning names the ledger') if length $err;
}

# =====================================================================================
# AC-15: retention -- after three changed-content step-3 ticks of one path, the sidecar
# holds at most 2 entries for that (step, path), and one of them backs the current line.
# =====================================================================================
{
    my $t = gen_tap_fixture(['ac15 v1']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    for my $gen (1 .. 3) {
        write_file($t, join("\n", '#!/usr/bin/env perl', qq{print "ok 1 - ac15 v$gen\\n";}) . "\n");
        run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    }
    my $bytes = read_file($ledger);
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $cur = $line ? eval { JSON::PP->new->decode($line) } : undef;
    my $sidecar = expected_sidecar_path($ledger);
    my $entries = read_sidecar($sidecar);
    my @for_key = grep { ($_->{step} // -1) == 3 } @$entries;
    ok(scalar(@for_key) <= 2, 'AC-15: the sidecar holds at most 2 entries for the (step, path) key '
        . '(got ' . scalar(@for_key) . ')');
    my $backed = 0;
    for my $e (@for_key) {
        $backed = 1 if $cur && $J->encode(compact_projection($e)) eq $J->encode($cur);
    }
    ok($backed, 'AC-15: one of the retained sidecar entries backs the CURRENT ledger line '
        . '(per spec 2.4\'s matching rule: encode(compact_oracle_record(S)) eq encode(C))');
}

# =====================================================================================
# AC-16: perl -c passes; completion-claim-integrity.t AC-33's file-scope module scan
# stays green (Digest::SHA loaded only inside a sub).
# =====================================================================================
{
    my $cc = system('bash', '-c', qq{perl -c "$SCRIPT" > /dev/null 2>&1});
    is($cc, 0, 'AC-16: perl -c bp-ledger.pl passes');

    open my $fh, '<', $SCRIPT or die "cannot read $SCRIPT: $!";
    my @lines = <$fh>;
    close $fh;
    my @top_use;
    for my $l (@lines) {
        push @top_use, $1 if $l =~ /^(?:use|require)\s+([A-Za-z0-9_:]+)/ && $l !~ /^\s+/;
    }
    my %allowed = map { ($_ => 1) } qw(strict warnings Getopt::Long Fcntl JSON::PP B constant);
    my @violations = grep { !$allowed{$_} } @top_use;
    is_deeply(\@violations, [],
        'AC-16: no module beyond the allowed set is used at file scope (Digest::SHA must stay lazy, inside a sub)');
}

# =====================================================================================
# Held-lock safety (spec 3.12): migrate-oracle run while another process holds
# <ledger>.lock waits for the lock, as every other mutation verb does, then completes once
# released.
# =====================================================================================
{
    my $step3 = oracle_line(step => 3, path => 'lockheld.t', descriptions => ['a', 'b']);
    my $ledger = write_ledger(status => 'running', test_paths => 'lockheld.t', oracle_records => [$step3]);
    my $lockfile = "$ledger.lock";
    open(my $lk, '+>>', $lockfile) or die "open lock $lockfile: $!";
    flock($lk, LOCK_EX) or die "flock $lockfile: $!";

    my $outf = "$ROOT/lockheld.out"; my $errf = "$ROOT/lockheld.err"; my $pidf = "$ROOT/lockheld.pid";
    write_file($outf, ''); write_file($errf, ''); write_file($pidf, '');
    {
        local %ENV = (%CLEAN_ENV, LGT_SCRIPT => fwd($SCRIPT), LGT_LEDGER => fwd($ledger),
                      LGT_OUT => fwd($outf), LGT_ERR => fwd($errf), LGT_PID => fwd($pidf));
        system('bash', '-c',
            '(perl "$LGT_SCRIPT" migrate-oracle --ledger "$LGT_LEDGER" > "$LGT_OUT" 2> "$LGT_ERR" & echo $! > "$LGT_PID")');
    }
    select(undef, undef, undef, 1); # let the background process actually start and block on flock
    my $pid = read_file($pidf); $pid =~ s/\D//g;
    ok(length($pid), 'held-lock harness: the background migrate-oracle process started');
    is(-s $outf, 0, 'held-lock: migrate-oracle has produced no stdout yet while the lock is held');
    is(-s $errf, 0, 'held-lock: migrate-oracle has produced no stderr yet while the lock is held');

    flock($lk, LOCK_UN);
    close($lk);

    my $waited = 0;
    while ($waited < 10 && !-s $outf && !-s $errf) { select(undef, undef, undef, 0.2); $waited += 0.2 }

    is(read_file($errf), '', 'held-lock: migrate-oracle exits with empty stderr once the lock is released');
    like(read_file($outf), qr/^bp-ledger: migrate-oracle: /,
        'held-lock: migrate-oracle proceeded and completed once the lock was released -- it WAITED, it did not '
      . 'error out or corrupt the ledger on a held lock');
}

# =====================================================================================
# S1 (Decision 13 review ruling): the sidecar path mapping treats a bare "packages/x.md" and
# a "./packages/x.md" alike -- both, addressed with cwd == the blueprint dir, resolve to the
# SAME <bpdir>/oracle/<pkg>.jsonl sidecar that a full ".../<bp>/packages/<pkg>.md" path
# resolves to (that location is frozen by S2: never-halt 05 and tooling-fixes 05 already hold
# real sidecars there).
# =====================================================================================
{
    my $t = gen_tap_fixture(['s1 one', 's1 two']);
    my $seg = fwd($t);
    my $pkg_ledger = write_packages_ledger(status => 'running', test_paths => $seg, pkg => 's1pkg');
    (my $bpdir = $pkg_ledger) =~ s{/packages/s1pkg\.md$}{};
    my $expected_sidecar = "$bpdir/oracle/s1pkg.jsonl";

    # step 3, addressed as a BARE relative "packages/s1pkg.md" with cwd == the blueprint dir.
    my ($rc1) = run_pl_cwd($bpdir, ['tick-step', '--ledger', 'packages/s1pkg.md', '--step', '3']);
    is($rc1, 0, 'S1: tick-step --step 3 addressed via a bare packages/<pkg>.md (cwd=bpdir) exits 0');
    ok(-e $expected_sidecar,
        "S1: the bare-path tick wrote the sidecar at the frozen <bpdir>/oracle/<pkg>.jsonl location ($expected_sidecar)");
    my $entries_after_bare = read_sidecar($expected_sidecar);
    is(scalar(@$entries_after_bare), 1, 'S1 FIXTURE-SANITY: exactly one sidecar entry after the bare-path tick');

    # step 5, addressed as "./packages/s1pkg.md" -- must land in the SAME sidecar file, not a
    # second one at, say, <bpdir>/packages/oracle/s1pkg.jsonl.
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - s1 one\n"; print "ok 2 - s1 two\n"; print "ok 3 - s1 three (new)\n";') . "\n");
    my ($rc2) = run_pl_cwd($bpdir, ['tick-step', '--ledger', './packages/s1pkg.md', '--step', '5']);
    is($rc2, 0, 'S1: tick-step --step 5 addressed via ./packages/<pkg>.md (cwd=bpdir) exits 0');

    my $bad_sidecar = "$bpdir/packages/oracle/s1pkg.jsonl";
    ok(!-e $bad_sidecar,
        'S1: no SECOND sidecar was created at <bpdir>/packages/oracle/<pkg>.jsonl (the bare/./ divergence bug)');
    my $entries_after_dot = read_sidecar($expected_sidecar);
    ok(scalar(@$entries_after_dot) >= 2,
        'S1: the ./packages/<pkg>.md tick appended to the SAME sidecar file the bare form wrote to '
      . '(both a step-3 and a step-5 entry now live in one file)');
    ok((scalar grep { ($_->{step} // -1) == 3 } @$entries_after_dot),
        'S1: the sidecar retains the step-3 entry from the bare-path tick');
    ok((scalar grep { ($_->{step} // -1) == 5 } @$entries_after_dot),
        'S1: the sidecar gained the step-5 entry from the ./-path tick');

    # And it is the SAME location a full <data>/blueprints/<bp>/packages/<pkg>.md path
    # resolves to.
    is(expected_sidecar_path($pkg_ledger), $expected_sidecar,
        'S1: the full <bpdir>/packages/<pkg>.md path form maps to the identical sidecar location '
      . '(frozen by S2: this is the location already used by live committed ledgers)');
}

# =====================================================================================
# S3 (Decision 13 review ruling): the sidecar-write-failure warning (AC-14's fallback) names
# not just the ledger, but ALSO the failing step (mkdir/open/write/close/rename) and the OS
# error text ($!).
# =====================================================================================
{
    my $s3_root = tempdir(CLEANUP => 1);
    my $t = gen_tap_fixture(['s3 one', 's3 two']);
    my $seg = fwd($t);
    my $ledger = "$s3_root/ledger.md";
    write_file($ledger, mk_ledger(status => 'running', test_paths => $seg));
    my $sidecar = expected_sidecar_path($ledger);
    my $oracle_dir = dirname($sidecar);
    make_path(dirname($oracle_dir));
    write_file($oracle_dir, "a regular file blocking the oracle/ directory slot\n"); # FILE, not a dir

    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    is($rc, 0, 'S3: tick-step exits 0 even when the sidecar cannot be written');
    like($err, qr/\Q$ledger\E/, 'S3 FIXTURE-SANITY: the warning names the ledger (AC-14 baseline)');
    like($err, qr/\b(?:mkdir|open|write|close|rename)\b/i,
        'S3: the warning names the failing step (mkdir/open/write/close/rename)');
    ok(length($err) > length($ledger) + 60,
        'S3: the warning carries substantially more than just the ledger path -- the OS error text is included')
        or diag("stderr was: $err");
}

# =====================================================================================
# S4 (Decision 13 review ruling): is_compact_record requires v to be the JSON NUMBER 2. A
# record carrying "v":"2" as a JSON STRING is NOT treated as compact -- it must be handled
# exactly as an equivalent long-form record with no "v" key at all.
# =====================================================================================
{
    my @descs = qw(alpha beta gamma);
    my $step3_long = oracle_line(step => 3, path => 's4.t', descriptions => \@descs);
    my ($json3) = ($step3_long =~ /^- oracle (\{.*\})$/);
    my $rec3 = eval { JSON::PP->new->decode($json3) };
    $rec3->{v} = "2"; # JSON STRING "2", not the number 2
    my $step3_string_v = '- oracle ' . $J->encode($rec3);

    my $step5_long = oracle_line(step => 5, path => 's4.t', descriptions => \@descs);

    my $ledger_plain    = write_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => 's4.t',
                                        oracle_records => [$step3_long, $step5_long]);
    my $ledger_string_v = write_ledger(status => 'done', pipeline => gated_pipeline(), test_paths => 's4.t',
                                        oracle_records => [$step3_string_v, $step5_long]);

    my (undef, undef, undef, $report_plain) = claim_check($ledger_plain);
    my (undef, undef, undef, $report_sv)    = claim_check($ledger_string_v);
    ok($report_plain, 'S4 FIXTURE-SANITY: the no-"v"-key baseline claim-check produced a decodable report');
    ok($report_sv, 'S4: claim-check on a "v":"2" (string) record produced a decodable report');
    is_deeply(without_ledger_field($report_sv), without_ledger_field($report_plain),
        'S4: a "v":"2" (string) record produces the SAME claim-check output as an equivalent record with no '
      . '"v" key at all -- it is treated as long form, never as compact');
}

# =====================================================================================
# S5 (Decision 13 review ruling): compact_oracle_record emits no "Use of uninitialized value"
# warnings for a record missing "assertions", and the compact record OMITS the key rather than
# inventing "assertions":0.
# =====================================================================================
{
    my $rec = { step => 3, path => 's5.t', recorded_at => '2026-07-15T00:00:00Z', status => 'ok',
                sha256 => ('c' x 64), descriptions => ['s5 one', 's5 two'],
                descriptions_sha256 => sha256_hex(join("\n", 's5 one', 's5 two')) };
    # deliberately omit "assertions" -- models an ok record with the count unavailable.
    my $line = '- oracle ' . $J->encode($rec);
    my $ledger = write_ledger(status => 'running', test_paths => 's5.t', oracle_records => [$line]);

    my ($mrc, $mout, $merr) = migrate_oracle($ledger);
    is($mrc, 0, 'S5: migrate-oracle on a record missing "assertions" exits 0');
    unlike($merr, qr/uninitialized/i, 'S5: migrate-oracle prints no "Use of uninitialized value" warnings');

    my $bytes = read_file($ledger);
    my ($cline) = ($bytes =~ /^(- oracle \{.*\})$/m);
    ok(defined $cline, 'S5 FIXTURE-SANITY: a compact line was written');
    SKIP: {
        skip 'no compact line to inspect', 1 unless defined $cline;
        my ($cjson) = ($cline =~ /^- oracle (\{.*\})$/);
        my $crec = eval { JSON::PP->new->decode($cjson) };
        ok($crec && !exists $crec->{assertions},
            'S5: the compact record OMITS "assertions" entirely rather than writing 0 for a missing count');
    }

    my (undef, undef, $cerr, $report) = claim_check($ledger);
    unlike($cerr // '', qr/uninitialized/i,
        'S5: claim-check on the migrated (sidecar-hydrated) record prints no uninitialized-value warnings');
    ok($report, 'S5: claim-check still produced a decodable report');
}

# =====================================================================================
# S6 (Decision 13 review ruling): migrate-oracle applies the same future-dated last_updated
# check as every other mutating verb (exit 2), even when there are zero oracle records to
# convert -- it must not skip the check just because N=0.
# =====================================================================================
{
    my $ledger = write_ledger(status => 'running', test_paths => 's6.t');
    (my $skewed = read_file($ledger)) =~ s/last_updated: 2026-07-01T00:00:00Z/last_updated: 2099-01-01T00:00:00Z/;
    write_file($ledger, $skewed);
    my $before = read_file($ledger);
    my ($rc, $out, $err) = migrate_oracle($ledger);
    is($rc, 2, 'S6: migrate-oracle on a ledger with a future-dated last_updated exits 2, even with 0 records to convert');
    is(read_file($ledger), $before, 'S6: the ledger is byte-identical after the rejected call');
}

done_testing();
