#!/usr/bin/env perl
# platform: windows
#
# Oracle for 08-completion-claims-checked, derived ONLY from
# .ccpraxis-local-data/blueprints/butler-gate-ergonomics/specs/08-completion-claims-checked-spec.md
# (§2 contracts, §3 observable behaviors 1-21, §4 AC-1..AC-37, §5 edge cases).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. At the time this file was authored bp-ledger.pl has
# no oracle recording, no `## Oracle identity` section support, no `claim-check`
# subcommand, and no --reaccept-oracle/--reaccept-reason flags; the judge .md files do not
# mention claim-check. Every assertion below is therefore expected to FAIL for the right
# reason (missing subcommand / missing section / missing prose), never on a harness bug of
# this file's own making. A few regression-style assertions (AC-31, AC-33's `perl -c`,
# AC-36) are legitimately expected to already be GREEN today, because they assert an
# invariant that is not yet violated by anything -- they become real regression guards once
# the implementation lands. Each such case is called out at its own assertion.
#
# HARNESS RULES (per spec's own "Test construction" subsection, binding on the writer):
#   * Hermetic: tempdir(CLEANUP => 1) at $ROOT, nothing written outside it. mk_bp-style
#     pattern borrowed from conformance-gate.t:76-100.
#   * mk_ledger(%opts) builds ledger fixtures; one dimension per argument.
#   * CLI behaviour (tick-step, claim-check, set-status) runs bp-ledger.pl as a CHILD
#     PROCESS via run_pl(), following ledger-api.t's run_pl shape (separate stdout/stderr
#     capture files, %CLEAN_ENV strips ambient BP_*).
#   * Pure functions (normalize_description, parse_tap) are exercised by `require`-ing
#     bp-ledger.pl directly -- the `unless (caller)` guard at the bottom of that file makes
#     this safe (precedent: ledger-budget-fixbatch.t's guarded require, main::-qualified
#     calls).
#   * Fixture `.t` files that tick-step will actually RUN are generated fresh into $ROOT --
#     never a real repo test file.
#
# done_testing() at EOF, never a hand-counted plan.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::SHA qw(sha256_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-ledger.pl";
my $HARVEST_JUDGE    = "$BUTLER/agents/bp-harvest-judge.md";
my $CONFORMANCE_JUDGE = "$BUTLER/agents/bp-conformance-judge.md";

my $J = JSON::PP->new->canonical;

diag("subject under test: $SCRIPT "
     . (-e $SCRIPT ? "(present)" : "(ABSENT)")
     . " -- claim-check/oracle-recording are expected ABSENT at authoring time");

my $ROOT = tempdir(CLEANUP => 1);
my $pn   = 0;
my $tfn  = 0;

# A test of a script must control its environment completely.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# =====================================================================================
# Low-level file/process helpers (ledger-api.t's run_pl shape)
# =====================================================================================

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

# Runs bp-ledger.pl (or, with $opt{script}, some other perl file -- used for the
# $ORACLE_RUN_FN seam wrapper below) as a CHILD PROCESS. stdout/stderr captured
# SEPARATELY (claim-check's "stderr is empty on exit 0" is an interface fact this
# harness must be able to assert independently of stdout content).
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

# =====================================================================================
# Ledger fixture construction
# =====================================================================================

my %DEFAULT_STEP_TEXT = (
    1 => 'spec read',
    2 => 'implementation',
    3 => 'tests written',
    4 => 'implementation complete',
    5 => 'tests pass',
    6 => 'Review || red-team complete',
    7 => 'promote',
    8 => 'UI pass',
);

# mk_pipeline(%o) -- %o: ticked => {step=>1,...}, na => {step=>1,...} (appends an N/A
# marker to that step's text), text => {step=>'literal override'}.
sub mk_pipeline {
    my (%o) = @_;
    my $ticked = $o{ticked} || {};
    my $na     = $o{na}     || {};
    my $text   = $o{text}   || {};
    my @lines;
    for my $n (1 .. 8) {
        my $box = $ticked->{$n} ? '[x]' : '[ ]';
        my $t = exists $text->{$n} ? $text->{$n} : $DEFAULT_STEP_TEXT{$n};
        $t .= ' -- N/A, this package touches no UI' if $na->{$n};
        push @lines, "- $box $n. $t";
    }
    return join("\n", @lines);
}

# A `## Pipeline` section carrying a FENCED lookalike step 6 line before the real one.
sub fenced_pipeline {
    my (%o) = @_;
    my $real = mk_pipeline(%o);
    return join("\n",
        '```text',
        '- [ ] 6. fenced lookalike that must never count',
        '```',
        $real);
}

sub mk_oracle_record {
    my (%f) = @_;
    my %rec = (
        step         => $f{step},
        path         => $f{path},
        recorded_at  => $f{recorded_at}  // '2026-07-15T00:00:00Z',
        status       => $f{status}       // 'ok',
    );
    if ($rec{status} eq 'ok') {
        my @descs = @{ $f{descriptions} // [] };
        $rec{sha256}              = $f{sha256} // ('a' x 64);
        $rec{assertions}          = $f{assertions} // scalar(@descs);
        $rec{descriptions}        = \@descs;
        $rec{descriptions_sha256} = $f{descriptions_sha256} // sha256_hex(join("\n", @descs));
    }
    else {
        $rec{reason} = $f{reason} // 'not a readable file';
    }
    $rec{reaccept} = $f{reaccept} if exists $f{reaccept};
    return $rec{path} eq '' ? undef : \%rec;
}

sub oracle_line {
    my (%f) = @_;
    my $rec = mk_oracle_record(%f);
    return '- oracle ' . $J->encode($rec);
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

# mk_ledger(%o) -- status, pipeline (raw text; default all-unticked 8-step template),
# test_paths (undef => key omitted entirely; string => scalar colon-delimited form),
# oracle_records (arrayref of `- oracle {...}` line strings, from oracle_line() above).
sub mk_ledger {
    my (%o) = @_;
    my $status   = defined $o{status}   ? $o{status}   : 'running';
    my $pipeline = defined $o{pipeline} ? $o{pipeline} : mk_pipeline();
    my @fm = ('---', 'package: fixture-pkg', 'blueprint: fixture-bp', "status: $status",
              'write_set:', '  - plugins/butler/scripts/bp-ledger.pl');
    push @fm, "test_paths: $o{test_paths}" if defined $o{test_paths};
    push @fm, 'mandated_means: none', 'last_updated: 2026-07-01T00:00:00Z', '---';

    my $oracle_sec = oracle_section(@{ $o{oracle_records} || [] });

    my @body = (
        '', '# fixture-pkg', '',
        '## Scope', '', 'Prose section no op may touch.', '',
        '## Next action', '', 'Do the first thing.', '',
        '## Pipeline', '', $pipeline, '',
    );
    push @body, $oracle_sec if length $oracle_sec;
    push @body, (
        '## Decisions & attempt log', '', '- 2026-07-29T10:00:00Z -- earlier note', '',
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

# =====================================================================================
# Derivation-fixture .t generators -- always fresh files under $ROOT, never a repo test.
# =====================================================================================

# A hermetic .t emitting exactly one top-level TAP "ok N - $desc" line per @$descs, via a
# loop so the SOURCE contains no literal "ok(" / "is(" occurrences (AC-2's requirement
# that assertion count come from the file's own TAP output, not a source grep).
sub gen_tap_fixture {
    my ($descs, %opt) = @_;
    my $path = "$ROOT/oracle_fixture_" . (++$tfn) . ".t";
    my @lines = ('#!/usr/bin/env perl', 'use strict; use warnings;', 'my @d = (');
    push @lines, join(",\n", map { my $d = $_; $d =~ s/'/\\'/g; "  '$d'" } @$descs);
    push @lines, ');', 'my $i = 0;',
                 'for my $d (@d) { $i++; print "ok $i - $d\n"; }';
    if ($opt{indented_extra}) {
        push @lines, 'print "    ok 99 - indented subtest line, must not count\n";';
    }
    write_file($path, join("\n", @lines) . "\n");
    return $path;
}

sub gen_loop_fixture {
    my ($n) = @_;
    my $path = "$ROOT/loop_fixture_" . (++$tfn) . ".t";
    write_file($path,
        "#!/usr/bin/env perl\nuse strict; use warnings;\n"
      . "for my \$i (1..$n) { print \"ok \$i - loop assertion \$i\\n\" }\n");
    return $path;
}

sub gen_broken_fixture {
    my $path = "$ROOT/broken_fixture_" . (++$tfn) . ".t";
    write_file($path, "this is not perl {{{ \x00\n");
    return $path;
}

sub gen_no_tap_fixture {
    my $path = "$ROOT/notap_fixture_" . (++$tfn) . ".t";
    write_file($path, "#!/usr/bin/env perl\nprint \"hello, no TAP here\\n\";\n");
    return $path;
}

sub gen_sleep_fixture {
    my $path = "$ROOT/sleep_fixture_" . (++$tfn) . ".t";
    write_file($path, "#!/usr/bin/env perl\nsleep(9999);\nprint \"ok 1 - never reached\\n\";\n");
    return $path;
}

sub gen_missing_path { return "$ROOT/does_not_exist_" . (++$tfn) . ".t" }

sub gen_dir_fixture {
    my $path = "$ROOT/dir_fixture_" . (++$tfn) . ".t";
    make_path($path);
    return $path;
}

# Wrapper .pl that requires bp-ledger.pl in-process, overrides $main::ORACLE_RUN_FN, then
# calls main::op_tick_step(@ARGV) as a CHILD PROCESS (op_tick_step ends in exit(0) via
# run_op, so it must never be called in OUR process). This is the CLI-observable form of
# the §2.2 in-process code seam.
sub write_die_seam_wrapper {
    my $path = "$ROOT/seam_wrapper_" . (++$tfn) . ".pl";
    my $script_fwd = fwd($SCRIPT);
    write_file($path, <<"PL");
require "$script_fwd";
\$main::ORACLE_RUN_FN = sub { die "boom from AC-12 test seam\\n" };
main::op_tick_step(\@ARGV);
PL
    return $path;
}

# =====================================================================================
# AC-1..AC-3: basic recording on tick-step --step 3
# =====================================================================================

{
    my $t = gen_tap_fixture(['first thing', 'second thing', 'third thing']);
    my $rel = 'oracle_fixture.t'; # symlink-free: use the real generated path relative form
    # test_paths must literally be the segment recorded in the report per §2.4, so use the
    # generated path's basename resolved against $ROOT via a relative-looking form is not
    # required by the spec (it only says "the test_paths segment verbatim") -- use the
    # absolute fwd'd path as the segment, which is a legal filesystem path bp-ledger.pl can
    # run directly.
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    is($rc, 0, 'AC-1: tick-step --step 3 with a readable .t test_paths segment exits 0');
    my $bytes = read_file($ledger);
    like($bytes, qr/^## Oracle identity$/m, 'AC-1: a ## Oracle identity section was created');
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    ok(defined $line, 'AC-1: a "- oracle {...}" record line is present')
        or diag("ledger bytes:\n$bytes");
    SKIP: {
        skip 'no record line to decode', 5 unless defined $line;
        my $rec = eval { JSON::PP->new->decode($line) };
        ok($rec, 'AC-1: the record line decodes as JSON') or diag("decode failed: $@");
        SKIP: {
            skip 'record did not decode', 4 unless $rec;
            is($rec->{step}, 3, 'AC-1: record step == 3');
            is($rec->{path}, $seg, 'AC-1: record path equals the test_paths segment verbatim');
            is($rec->{status}, 'ok', 'AC-1: record status == "ok"');
            like($rec->{sha256} // '', qr/^[0-9a-f]{64}$/, 'AC-1: record sha256 is 64 lowercase hex');
            is($rec->{sha256}, sha256_hex(read_file($t)), 'AC-1: sha256 equals sha256_hex of the file bytes');
            like($rec->{assertions} // '', qr/^\d+$/, 'AC-1: record carries an integer assertions count');
        }
    }
}

{
    # AC-2: assertions comes from the file's own TAP output (loop-generated, N=17), never a
    # source grep of "ok(" / "is(" -- the source below contains ZERO such literal tokens.
    my $t = gen_loop_fixture(17);
    my $src = read_file($t);
    unlike($src, qr/\b(?:ok|is)\s*\(/, 'AC-2 fixture sanity: the source has no literal ok(/is( calls');
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my $bytes = read_file($ledger);
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $rec = $line ? eval { JSON::PP->new->decode($line) } : undef;
    is($rec && $rec->{assertions}, 17,
        'AC-2: assertions == 17 (the TAP line count), not 0 (a source grep of ok(/is()');
}

{
    # AC-3: two .t segments -> exactly two step-3 records, one per path, never an aggregate.
    my $a = gen_tap_fixture(['a one', 'a two']);
    my $b = gen_tap_fixture(['b one', 'b two', 'b three']);
    my $seg = fwd($a) . ':' . fwd($b);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my $bytes = read_file($ledger);
    my @lines = ($bytes =~ /^- oracle (\{.*\})$/mg);
    is(scalar(@lines), 2, 'AC-3: exactly two step-3 oracle records for two test_paths segments');
    my %by_path;
    for my $l (@lines) {
        my $r = eval { JSON::PP->new->decode($l) };
        $by_path{$r->{path}} = $r if $r;
    }
    is($by_path{fwd($a)}{assertions}, 2, 'AC-3: path a has its own distinct assertion count (2)');
    is($by_path{fwd($b)}{assertions}, 3, 'AC-3: path b has its own distinct assertion count (3)');
    isnt($by_path{fwd($a)}{sha256}, $by_path{fwd($b)}{sha256}, 'AC-3: distinct sha256 per path');
}

# =====================================================================================
# AC-4..AC-7: step-5 re-derivation, step-4 inertness, idempotency, replace-in-place
# =====================================================================================

{
    # AC-4: step 5 re-derives from scratch and differs from step 3 when the file changed.
    my $t = gen_tap_fixture(['one', 'two']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running',
        pipeline => mk_pipeline(ticked => { 1 => 1, 2 => 1, 3 => 1 }), test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    write_file($t, read_file($t) . "\n");
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - one\n"; print "ok 2 - two\n"; print "ok 3 - three (new)\n";') . "\n");
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5']);
    is($rc, 0, 'AC-4: tick-step --step 5 exits 0');
    my $bytes = read_file($ledger);
    my @lines = ($bytes =~ /^- oracle (\{.*\})$/mg);
    my @step5 = grep { $_->{step} == 5 } map { eval { JSON::PP->new->decode($_) } } @lines;
    is(scalar(@step5), 1, 'AC-4: exactly one step-5 record written');
    is($step5[0]{assertions}, 3, 'AC-4: the step-5 record reflects the CURRENT file (3 assertions), not step-3\'s 2')
        if @step5;
}

{
    # AC-5: tick-step --step 4 never touches ## Oracle identity, given a ledger that
    # already has step-3 records.
    my $rec = oracle_line(step => 3, path => 'X.t', descriptions => ['a']);
    my $ledger = write_ledger(status => 'running',
        pipeline => mk_pipeline(ticked => { 1 => 1, 2 => 1, 3 => 1 }),
        test_paths => 'X.t', oracle_records => [$rec]);
    my $before = read_file($ledger);
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '4']);
    is($rc, 0, 'AC-5: tick-step --step 4 exits 0');
    my $after = read_file($ledger);
    # the checkbox for step 4 flips; the Oracle identity section content is otherwise
    # untouched -- assert the existing record line is byte-identical and still present.
    like($after, qr/\Q$rec\E/, 'AC-5: the pre-existing step-3 record line is untouched by a step-4 tick');
}

{
    # AC-6: re-running an identical tick-step --step 3 is byte-identical, exit 0.
    my $t = gen_tap_fixture(['stable one', 'stable two']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my $after_first = read_file($ledger);
    my ($rc) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    is($rc, 0, 'AC-6: second identical tick-step --step 3 exits 0');
    is(read_file($ledger), $after_first,
        'AC-6: re-running an identical tick with an unchanged file leaves the ledger byte-identical');
}

{
    # AC-7: a changed oracle re-tick REPLACES the (3, path) record; never a second line.
    my $t = gen_tap_fixture(['v1 only']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    write_file($t, join("\n", '#!/usr/bin/env perl',
        'print "ok 1 - v2 one\n"; print "ok 2 - v2 two\n";') . "\n");
    run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    my $bytes = read_file($ledger);
    my @step3 = grep { $_->{step} == 3 && $_->{path} eq $seg }
                map  { eval { JSON::PP->new->decode($_) } } ($bytes =~ /^- oracle (\{.*\})$/mg);
    is(scalar(@step3), 1, 'AC-7: exactly one (step 3, path) record remains after a re-tick on a changed file');
    is($step3[0]{assertions}, 2, 'AC-7: ...and it reflects the NEW file content') if @step3;
}

# =====================================================================================
# AC-8..AC-14: fail-silent mandate
# =====================================================================================

sub assert_fail_silent_tick {
    my ($name, $seg, %extra_env) = @_;
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3'],
                                   env => \%extra_env);
    is($rc, 0, "$name: tick-step exits 0 despite the derivation failure");
    is($err, '', "$name: stderr is empty");
    my $bytes = read_file($ledger);
    like($bytes, qr/^- \[x\] 3\./m, "$name: the checkbox for step 3 is flipped regardless");
    return $bytes;
}

{
    my $bytes = assert_fail_silent_tick('AC-8', fwd(gen_missing_path()));
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $rec = $line ? eval { JSON::PP->new->decode($line) } : undef;
    is($rec && $rec->{status}, 'unavailable', 'AC-8: record status is "unavailable" for a missing .t path');
    is($rec && $rec->{reason}, 'not a readable file', 'AC-8: reason is exactly "not a readable file"');
}

{
    my $bytes = assert_fail_silent_tick('AC-9', fwd(gen_dir_fixture()));
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $rec = $line ? eval { JSON::PP->new->decode($line) } : undef;
    is($rec && $rec->{status}, 'unavailable', 'AC-9: record status is "unavailable" for a directory ending in .t');
}

{
    my $bytes = assert_fail_silent_tick('AC-10', fwd(gen_broken_fixture()));
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $rec = $line ? eval { JSON::PP->new->decode($line) } : undef;
    ok($rec && scalar(grep { ($rec->{reason} // '') eq $_ } ('no TAP output', 'run failed')),
        'AC-10: reason is "no TAP output" or "run failed" for a file that fails to compile')
        or diag('reason was: ' . (($rec && $rec->{reason}) // '(no record)'));
}

{
    my $t = gen_sleep_fixture();
    my $bytes = assert_fail_silent_tick('AC-11', fwd($t), BP_ORACLE_TIMEOUT_S => '1');
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $rec = $line ? eval { JSON::PP->new->decode($line) } : undef;
    is($rec && $rec->{reason}, 'timed out', 'AC-11: reason is exactly "timed out" for a run past BP_ORACLE_TIMEOUT_S');
}

{
    # AC-12: $ORACLE_RUN_FN overridden to die -- no exception escapes tick-step.
    my $t = gen_tap_fixture(['irrelevant']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    my $wrapper = write_die_seam_wrapper();
    my ($rc, $out, $err) = run_pl(['--ledger', $ledger, '--step', '3'], script => $wrapper);
    is($rc, 0, 'AC-12: tick-step still exits 0 when $ORACLE_RUN_FN dies');
    is($err, '', 'AC-12: stderr is still empty when $ORACLE_RUN_FN dies');
    my $bytes = read_file($ledger);
    like($bytes, qr/^- \[x\] 3\./m, 'AC-12: the checkbox for step 3 is still flipped');
    my ($line) = ($bytes =~ /^- oracle (\{.*\})$/m);
    my $rec = $line ? eval { JSON::PP->new->decode($line) } : undef;
    is($rec && $rec->{status}, 'unavailable',
        'AC-12: the record (once implemented) reflects the derivation failure rather than silently omitting it');
}

{
    # AC-13: a derived description containing a ref-address-shaped byte sequence must not
    # trip validate_bytes V1 / validate_no_new_ref_addr; exit 0 and the resulting ledger
    # still validates clean.
    my $t = gen_tap_fixture(['boom HASH(0x5c7bd4bd3308) description']);
    my $seg = fwd($t);
    my $ledger = write_ledger(status => 'running', test_paths => $seg);
    my ($rc, $out, $err) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3']);
    is($rc, 0, 'AC-13: tick-step exits 0 even with a ref-address-shaped description');
    my ($vrc) = run_pl(['validate', '--ledger', $ledger]);
    is($vrc, 0, 'AC-13: the resulting ledger still passes bp-ledger.pl validate --ledger');
}

{
    # AC-14: BP_ORACLE_RECORD=0 makes tick-step --step 3 byte-identical to the no-test_paths
    # baseline, on a ledger that DOES have test_paths.
    my $t = gen_tap_fixture(['whatever']);
    my $seg = fwd($t);
    my $baseline_ledger = write_ledger(status => 'running', test_paths => undef);
    my $suppressed_ledger = write_ledger(status => 'running', test_paths => $seg);
    # both start from the identical unticked-pipeline template except for the test_paths:
    # frontmatter line, so compare the POST-tick byte length / checkbox state, not raw
    # equality (the frontmatter differs by construction).
    run_pl(['tick-step', '--ledger', $baseline_ledger, '--step', '3']);
    my ($rc) = run_pl(['tick-step', '--ledger', $suppressed_ledger, '--step', '3'],
                       env => { BP_ORACLE_RECORD => '0' });
    is($rc, 0, 'AC-14: tick-step --step 3 with BP_ORACLE_RECORD=0 exits 0');
    unlike(read_file($suppressed_ledger), qr/^## Oracle identity$/m,
        'AC-14: BP_ORACLE_RECORD=0 suppresses recording entirely -- no ## Oracle identity section');
}

# =====================================================================================
# AC-15..AC-20: pipeline check
# =====================================================================================

sub claim_check {
    my ($ledger) = @_;
    my ($rc, $out, $err) = run_pl(['claim-check', '--ledger', $ledger]);
    my $report = length($out) ? eval { JSON::PP->new->decode($out) } : undef;
    return ($rc, $out, $err, $report);
}

{
    # AC-15 / 519f, verbatim: done ledger, steps 1 and 6 unticked -> two findings.
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { 2 => 1, 3 => 1, 4 => 1, 5 => 1, 7 => 1 }, na => { 8 => 1 }));
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-15: claim-check exits 0 on a done ledger with unticked steps');
    is($err, '', 'AC-15: stderr is empty on exit 0');
    ok($report, 'AC-15: stdout decodes as JSON') or diag("stdout was: $out");
    SKIP: {
        skip 'no report to inspect', 2 unless $report;
        my @codes = grep { $_->{code} eq 'PIPELINE_STEP_UNTICKED' } @{ $report->{findings} || [] };
        is(scalar(@codes), 2, 'AC-15: exactly two PIPELINE_STEP_UNTICKED findings (steps 1 and 6)');
        my %steps = map { $_->{step} => 1 } @codes;
        ok($steps{1} && $steps{6}, 'AC-15: the two findings name step 1 and step 6 respectively');
    }
}

{
    # AC-16: steps 1-7 ticked, step 8 unticked with N/A -> no finding (clean fixture --
    # also serves AC-37's "clean fixture" requirement).
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }));
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-16: claim-check exits 0');
    is_deeply($report && $report->{findings}, [], 'AC-16: findings: [] for steps 1-7 ticked, step 8 N/A')
        if $report;
}

{
    # AC-17: same ledger, step 8 unticked and N/A text removed -> one finding for step 8.
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }));
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-17: claim-check exits 0');
    SKIP: {
        skip 'no report', 1 unless $report;
        my @codes = grep { $_->{code} eq 'PIPELINE_STEP_UNTICKED' } @{ $report->{findings} || [] };
        is_deeply([ sort map { $_->{step} } @codes ], [8],
            'AC-17: exactly one PIPELINE_STEP_UNTICKED finding, naming step 8');
    }
}

{
    # AC-18: N/A on unticked step 6 does NOT satisfy it (conditionality is by step number).
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { 1 => 1, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 7 => 1 },
                                 na => { 6 => 1, 8 => 1 }));
    my ($rc, $out, $err, $report) = claim_check($ledger);
    unless (ok($report, 'AC-18: claim-check produced a decodable JSON report')) {
        fail('AC-18: step 6 still fires PIPELINE_STEP_UNTICKED even carrying an N/A marker (no report)');
    }
    else {
        my @step6 = grep { $_->{code} eq 'PIPELINE_STEP_UNTICKED' && $_->{step} == 6 }
                    @{ $report->{findings} || [] };
        ok(@step6, 'AC-18: step 6 still fires PIPELINE_STEP_UNTICKED even carrying an N/A marker');
    }
}

{
    # AC-19: a running ledger with unticked steps -> gated:false, findings:[].
    my $ledger = write_ledger(status => 'running',
        pipeline => mk_pipeline(ticked => { 1 => 1 }));
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-19: claim-check exits 0 on a running ledger');
    ok($report, 'AC-19: claim-check produced a decodable JSON report');
    is($report && $report->{gated}, 0, 'AC-19: gated is false for status: running');
    is_deeply($report && $report->{findings}, [], 'AC-19: findings: [] for a running ledger');
}

{
    # AC-20: a fenced `- [ ] 6.` lookalike inside ## Pipeline is not a pipeline item.
    my $ledger = write_ledger(status => 'done',
        pipeline => fenced_pipeline(ticked => { 1 => 1, 2 => 1, 3 => 1, 4 => 1, 5 => 1, 6 => 1, 7 => 1 },
                                     na => { 8 => 1 }));
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-20: claim-check produced a decodable JSON report');
    is_deeply($report && $report->{findings}, [],
        'AC-20: the real (ticked) step 6 satisfies the item; the fenced lookalike is not read as a second item');
}

# =====================================================================================
# AC-21..AC-29: oracle comparison
# =====================================================================================

{
    # AC-21 / 2d94, verbatim: step-5 assertions (5) < step-3 (20) -> ORACLE_SHRANK, with
    # delta.assertions_before/after == 20/5.
    my $step3 = oracle_line(step => 3, path => 'shrink.t',
        descriptions => [ map { "assertion $_" } 1 .. 20 ], assertions => 20);
    my $step5 = oracle_line(step => 5, path => 'shrink.t',
        descriptions => [ map { "assertion $_" } 1 .. 5 ], assertions => 5);
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'shrink.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-21: claim-check exits 0');
    SKIP: {
        skip 'no report', 2 unless $report;
        my ($f) = grep { $_->{code} eq 'ORACLE_SHRANK' } @{ $report->{findings} || [] };
        ok($f, 'AC-21: ORACLE_SHRANK fires for a shrunk step-5 assertion count');
        SKIP: {
            skip 'no finding', 1 unless $f;
            is_deeply([ $f->{delta}{assertions_before}, $f->{delta}{assertions_after} ], [20, 5],
                'AC-21: delta.assertions_before/after are 20/5');
        }
    }
}

{
    # AC-22: AC-21's fixture WITH a reaccept still fires ORACLE_SHRANK (DC-4).
    my $step3 = oracle_line(step => 3, path => 'shrink2.t',
        descriptions => [ map { "assertion $_" } 1 .. 20 ], assertions => 20);
    my $step5 = oracle_line(step => 5, path => 'shrink2.t',
        descriptions => [ map { "assertion $_" } 1 .. 5 ], assertions => 5,
        reaccept => { reason => 'we removed dead code', delta => {} });
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'shrink2.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-22: claim-check produced a decodable JSON report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_SHRANK' } @{ $report->{findings} || [] } : ();
    ok($f, 'AC-22: ORACLE_SHRANK STILL fires even when the step-5 record carries a reaccept');
}

{
    # AC-23: strict-superset step-5 description set + reaccept -> no finding.
    my $step3 = oracle_line(step => 3, path => 'grow.t', descriptions => ['alpha', 'beta']);
    my $step5 = oracle_line(step => 5, path => 'grow.t', descriptions => ['alpha', 'beta', 'gamma'],
        reaccept => { reason => 'legitimate fix-batch addition', delta => {} });
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'grow.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-23: claim-check produced a decodable JSON report');
    is_deeply($report && $report->{findings}, [],
        'AC-23: an additive step-5 change with a reaccept produces no finding');
}

{
    # AC-24: the SAME additive change WITHOUT a reaccept -> ORACLE_DRIFT_UNACCEPTED, naming
    # the added descriptions.
    my $step3 = oracle_line(step => 3, path => 'grow2.t', descriptions => ['alpha', 'beta']);
    my $step5 = oracle_line(step => 5, path => 'grow2.t', descriptions => ['alpha', 'beta', 'gamma']);
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'grow2.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-24: claim-check produced a decodable JSON report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_DRIFT_UNACCEPTED' } @{ $report->{findings} || [] } : ();
    ok($f, 'AC-24: ORACLE_DRIFT_UNACCEPTED fires for an additive change with no reaccept');
    like(($f && $f->{detail}) // '', qr/gamma/, 'AC-24: detail names the added description(s)');
}

{
    # AC-25 (DC-5): parenthetical-only differences normalize equal -> no finding.
    my $step3 = oracle_line(step => 3, path => 'norm.t', descriptions => ['rows counted (got 0)']);
    my $step5 = oracle_line(step => 5, path => 'norm.t', descriptions => ['rows counted (got 30)']);
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'norm.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-25: claim-check produced a decodable JSON report');
    is_deeply($report && $report->{findings}, [],
        'AC-25: descriptions differing only in a parenthetical value normalize equal, no finding');
}

{
    # AC-26: whitespace / trailing "# TODO" differences also normalize equal.
    my $step3 = oracle_line(step => 3, path => 'norm2.t', descriptions => ['spaced   out description']);
    my $step5 = oracle_line(step => 5, path => 'norm2.t', descriptions => ['spaced out description # TODO fix later']);
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'norm2.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-26: claim-check produced a decodable JSON report');
    is_deeply($report && $report->{findings}, [],
        'AC-26: whitespace-squeeze + trailing directive strip normalize equal, no finding');
}

{
    # AC-27: normalize_description unit assertions, via a guarded direct require.
    my $ok = eval { require $SCRIPT; 1 };
    ok($ok, 'AC-27 harness: bp-ledger.pl is require-able for pure-function unit tests')
        or diag("require failed: $@");
    SKIP: {
        skip 'require failed', 4 unless $ok;
        my $nd = main->can('normalize_description');
        ok($nd, 'AC-27: main::normalize_description exists');
        SKIP: {
            skip 'normalize_description not yet defined', 4 unless $nd;
            is(main::normalize_description('rows counted (got 0)'), 'rows counted',
                'AC-27: truncates at the FIRST "("');
            is(main::normalize_description('a  b   c'), 'a b c',
                'AC-27: squeezes internal whitespace to single spaces');
            is(main::normalize_description('desc here # SKIP not ready'), 'desc here',
                'AC-27: strips a trailing TAP directive before normalizing');
            is(main::normalize_description('   (only a parenthetical)  '), '',
                'AC-27: a description that normalizes to nothing returns the empty string');
        }
    }
}

{
    # AC-27b (bug 20261012-014847-ded4): a skipped point's TAP line is
    # `ok N # skip <reason>`, so parse_tap captures the bare directive
    # `# skip <reason>` as its "description". It asserts nothing; normalizing
    # it to '' keeps a SKIP guard that later runs for real from reading as a
    # removed assertion.
    my $ok = eval { require $SCRIPT; 1 };
    SKIP: {
        skip 'require failed', 5 unless $ok && main->can('normalize_description');
        is(main::normalize_description('# skip glyph not found'), '',
            'AC-27b: a bare "# skip <reason>" directive normalizes to the empty string');
        is(main::normalize_description('# SKIP not ready'), '',
            'AC-27b: ...case-insensitively');
        is(main::normalize_description('#TODO later'), '',
            'AC-27b: a bare "# TODO" directive normalizes to the empty string too');
        is(main::normalize_description('# of rows counted'), '# of rows counted',
            'AC-27b: an authored description that merely starts with "#" is kept');
        is(main::normalize_description('# skipped rows are not counted'), '# skipped rows are not counted',
            'AC-27b: "# skipped" is not the skip directive (word boundary)');
    }
}

{
    # AC-27c: a skip-reason string present at step 3 and gone at step 5 (the
    # guarded points now run for real) is DRIFT, not a shrink. No reaccept ->
    # ORACLE_DRIFT_UNACCEPTED and no ORACLE_SHRANK.
    my $step3 = oracle_line(step => 3, path => 'skipflip.t',
        descriptions => ['alpha', '# skip the thread segment is not on row 1'], assertions => 3);
    my $step5 = oracle_line(step => 5, path => 'skipflip.t',
        descriptions => ['alpha', 'thread count is primary', 'thread glyph is muted'], assertions => 3);
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'skipflip.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-27c: claim-check produced a decodable JSON report');
    my @codes = $report ? map { $_->{code} } @{ $report->{findings} || [] } : ();
    ok(!grep({ $_ eq 'ORACLE_SHRANK' } @codes),
        'AC-27c: a vanished skip-reason string alone is NOT an ORACLE_SHRANK');
    ok(scalar(grep { $_ eq 'ORACLE_DRIFT_UNACCEPTED' } @codes),
        'AC-27c: ...it is drift, which still needs a reaccept');
}

{
    # AC-27d: AC-27c's fixture WITH a reaccept -> no finding at all.
    my $step3 = oracle_line(step => 3, path => 'skipflip2.t',
        descriptions => ['alpha', '# skip glyph not found'], assertions => 3);
    my $step5 = oracle_line(step => 5, path => 'skipflip2.t',
        descriptions => ['alpha', 'glyph is declared', 'glyph width is 1'], assertions => 3,
        reaccept => { reason => 'skip guard now runs for real', delta => {} });
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'skipflip2.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-27d: claim-check produced a decodable JSON report');
    is_deeply($report && $report->{findings}, [],
        'AC-27d: a skip-to-real flip with a reaccept produces no finding');
}

{
    # AC-27e: a REAL authored description removed alongside a skip string still
    # shrinks -- the fix only discounts skip directives, never real assertions.
    my $step3 = oracle_line(step => 3, path => 'skipflip3.t',
        descriptions => ['alpha', 'beta', '# skip x'], assertions => 3);
    my $step5 = oracle_line(step => 5, path => 'skipflip3.t',
        descriptions => ['alpha', 'gamma', 'delta'], assertions => 3,
        reaccept => { reason => 'trying to bless a removal', delta => {} });
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'skipflip3.t', oracle_records => [$step3, $step5]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-27e: claim-check produced a decodable JSON report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_SHRANK' } @{ $report->{findings} || [] } : ();
    ok($f, 'AC-27e: a removed authored description still fires ORACLE_SHRANK, reaccept or not');
    is_deeply($f ? $f->{delta}{descriptions_removed} : undef, ['beta'],
        'AC-27e: ...and the removed set names only the real description, not the skip string');
}

{
    # AC-28: done, step 3 ticked, a .t in test_paths, NO step-3 record -> ORACLE_NOT_RECORDED.
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'unrecorded.t', oracle_records => []);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-28: claim-check produced a decodable JSON report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_NOT_RECORDED' } @{ $report->{findings} || [] } : ();
    ok($f, 'AC-28: ORACLE_NOT_RECORDED fires when step 3 is ticked but no record exists for the path');
}

{
    # AC-29: a step-3 record with status "unavailable" -> ORACLE_UNDERIVABLE, quoting reason.
    my $rec = oracle_line(step => 3, path => 'bad.t', status => 'unavailable', reason => 'run failed');
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'bad.t', oracle_records => [$rec]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    ok($report, 'AC-29: claim-check produced a decodable JSON report');
    my ($f) = $report ? grep { $_->{code} eq 'ORACLE_UNDERIVABLE' } @{ $report->{findings} || [] } : ();
    ok($f, 'AC-29: ORACLE_UNDERIVABLE fires for an "unavailable" record');
    like(($f && $f->{detail}) // '', qr/run failed/, 'AC-29: detail quotes the reason');
}

# =====================================================================================
# AC-30: usage errors for --reaccept-oracle / --reaccept-reason
# =====================================================================================

{
    my $t = gen_tap_fixture(['x']);
    my $ledger = write_ledger(status => 'running', test_paths => fwd($t));
    my $before = read_file($ledger);
    my ($rc1, $out1, $err1) = run_pl(['tick-step', '--ledger', $ledger, '--step', '5',
                                       '--reaccept-oracle', fwd($t)]);
    is($rc1, 3, 'AC-30: --reaccept-oracle without --reaccept-reason exits 3');
    my @errlines1 = split /\n/, $err1;
    is(scalar(@errlines1), 1, 'AC-30: ...with exactly one stderr line') if length $err1;
    is(read_file($ledger), $before, 'AC-30: ...and the ledger is byte-identical after the rejected call');

    my ($rc2, $out2, $err2) = run_pl(['tick-step', '--ledger', $ledger, '--step', '3',
                                       '--reaccept-oracle', fwd($t), '--reaccept-reason', 'why']);
    is($rc2, 3, 'AC-30: --reaccept-oracle with --step 3 (not 5) exits 3');
    is(read_file($ledger), $before, 'AC-30: ...and the ledger is byte-identical after that rejected call too');
}

# =====================================================================================
# AC-31..AC-33: no-refusal invariant
# =====================================================================================

{
    # AC-31: set-status --status done on a ledger with EVERY step unticked exits 0, stderr
    # empty. This is the specific regression the spec names by commit (089cfcc / 092eff7);
    # NOTE this assertion is expected to be GREEN already today (089cfcc was reverted well
    # before this package), and remains a load-bearing regression guard: if a future
    # refusal is reintroduced, THIS is the assertion that turns red.
    my $ledger = write_ledger(status => 'running', pipeline => mk_pipeline());
    my ($rc, $out, $err) = run_pl(['set-status', '--ledger', $ledger, '--status', 'done']);
    is($rc, 0, 'AC-31: set-status --status done with every pipeline step unticked exits 0 (no refusal)');
    is($err, '', 'AC-31: ...and stderr is empty');
}

{
    # AC-32: claim-check on a ledger carrying every finding code at once still exits 0 with
    # empty stderr -- there is no exit code meaning "findings exist".
    my $step3_shrink = oracle_line(step => 3, path => 'multi.t', descriptions => [map { "a$_" } 1..10]);
    my $step5_shrink = oracle_line(step => 5, path => 'multi.t', descriptions => [map { "a$_" } 1..2]);
    my $bad = oracle_line(step => 3, path => 'multi2.t', status => 'unavailable', reason => 'run failed');
    my $ledger = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { 2 => 1, 3 => 1, 4 => 1, 5 => 1 }),
        test_paths => 'multi.t:multi2.t:multi3.t',
        oracle_records => [$step3_shrink, $step5_shrink, $bad]);
    my ($rc, $out, $err, $report) = claim_check($ledger);
    is($rc, 0, 'AC-32: claim-check exits 0 even with multiple simultaneous finding codes');
    is($err, '', 'AC-32: ...and stderr is empty');
    ok($report && scalar(@{ $report->{findings} || [] }) >= 3,
        'AC-32: ...while findings[] itself carries multiple entries (visible only in JSON, not exit code)')
        if $report;
}

{
    # AC-33: perl -c passes, and no module beyond the allowed set is `use`d/`require`d at
    # file scope (Digest::SHA must appear only inside a sub). Static scan, no execution.
    my ($rc, $out, $err) = run_pl(['validate', '--stdin'], stdin => "not a ledger\n");
    # (sanity call above just exercises the CLI path; the real assertions are static below)
    open my $fh, '<', $SCRIPT or die "cannot read $SCRIPT: $!";
    my @lines = <$fh>;
    close $fh;
    my @top_use;
    my $depth = 0;
    for my $l (@lines) {
        # crude but sufficient: a `use`/`require` line NOT indented (file-scope, not inside
        # a sub) and not itself inside a quoted string/heredoc region far exceeds this
        # spec's needs -- track brace depth loosely via leading whitespace as a heuristic
        # is unreliable, so instead: a file-scope `use X` line has NO leading whitespace.
        push @top_use, $1 if $l =~ /^(?:use|require)\s+([A-Za-z0-9_:]+)/ && $l !~ /^\s+/;
    }
    my %allowed = map { ($_ => 1) } qw(strict warnings Getopt::Long Fcntl JSON::PP B constant);
    my @violations = grep { !$allowed{$_} } @top_use;
    is_deeply(\@violations, [],
        'AC-33: no module beyond strict/warnings/Getopt::Long/Fcntl/JSON::PP/B is used at file scope '
      . '(Digest::SHA must be lazy, inside a sub, per §2.3)');
    my $cc = system('bash', '-c', qq{perl -c "$SCRIPT" > /dev/null 2>&1});
    is($cc, 0, 'AC-33: perl -c bp-ledger.pl passes');
}

# =====================================================================================
# AC-34..AC-36: judge wiring
# =====================================================================================

{
    my $harvest = read_file($HARVEST_JUDGE) // '';
    like($harvest, qr/claim-check/, 'AC-34: bp-harvest-judge.md contains the literal string "claim-check"');
    like($harvest, qr/findings.{0,80}fail|non-empty.{0,40}fail/is,
        'AC-34: bp-harvest-judge.md states a non-empty findings array forces verdict: fail');
}

{
    my $conformance = read_file($CONFORMANCE_JUDGE) // '';
    like($conformance, qr/claim-check/, 'AC-35: bp-conformance-judge.md contains the literal string "claim-check"');
}

{
    my $harvest = read_file($HARVEST_JUDGE) // '';
    like($harvest, qr/Write.{0,10}is for.{0,10}verdict_path.{0,10}only/s,
        'AC-36: bp-harvest-judge.md still limits Write to verdict_path only -- '
      . 'claim-check wiring must not gain any instruction to write to a ledger');
    unlike($harvest, qr/(?:edit|update|mutate|modify)\s+(?:the\s+)?ledger/i,
        'AC-36: no instruction anywhere tells the harvest judge to edit/update/mutate the ledger');
}

# =====================================================================================
# AC-37: fixture non-vacuity (519f-shaped, 2d94-shaped, and a clean fixture)
# =====================================================================================

{
    # These three re-use the AC-15 / AC-21 / AC-16 fixtures above, asserted here again
    # explicitly under their AC-37 framing so the "non-vacuity in both directions" claim
    # is not merely implicit in earlier blocks.
    my $done_unticked = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { 2 => 1, 3 => 1, 4 => 1, 5 => 1, 7 => 1 }, na => { 8 => 1 }));
    my (undef, undef, undef, $r1) = claim_check($done_unticked);
    ok($r1 && @{ $r1->{findings} || [] } > 0,
        'AC-37: a 519f-shaped fixture (done + unticked unconditional step) produces a NON-EMPTY findings[]');

    my $step3 = oracle_line(step => 3, path => 'ac37shrink.t', descriptions => [map { "d$_" } 1..20]);
    my $step5 = oracle_line(step => 5, path => 'ac37shrink.t', descriptions => [map { "d$_" } 1..5]);
    my $shrunk = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }),
        test_paths => 'ac37shrink.t', oracle_records => [$step3, $step5]);
    my (undef, undef, undef, $r2) = claim_check($shrunk);
    ok($r2 && scalar(grep { $_->{code} eq 'ORACLE_SHRANK' } @{ $r2->{findings} || [] }),
        'AC-37: a 2d94-shaped fixture (shrunk oracle) produces an ORACLE_SHRANK finding');

    my $clean = write_ledger(status => 'done',
        pipeline => mk_pipeline(ticked => { map { $_ => 1 } 1 .. 7 }, na => { 8 => 1 }));
    my (undef, undef, undef, $r3) = claim_check($clean);
    is_deeply($r3 && $r3->{findings}, [],
        'AC-37: a clean fixture (everything satisfied) produces findings: [] -- non-vacuity the other way too');
}

done_testing();
