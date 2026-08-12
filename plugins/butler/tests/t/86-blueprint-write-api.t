#!/usr/bin/env perl
# b43-blueprint-write-api oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b43-blueprint-write-api-spec.md
# section 3 (G1..G11, DC-1..DC-11).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-blueprint.pl does not exist at the
# time this file was authored, and hooks.json has no PreToolUse block targeting blueprint.md. Every
# G assertion below must therefore fail on MISSING BEHAVIOUR, never on a bug in this file.
#
# NEVER MUTATE THE LIVE blueprint.md. Every mutating criterion runs on a File::Temp COPY. G10 copies
# the real 70-package/109,498-byte file; every other criterion may use a smaller synthetic fixture
# that satisfies parse_dag's own contract (a `|`-row containing the literal `depends_on` as header,
# contiguous rows below it).
#
# :raw ONLY, throughout (spec landmine 2 / G11). No `:encoding(UTF-8)` layer anywhere in this file.
#
# SYN-23: no assertion, fixture or comment in this file cites a line number in bp-orchestrator.pl,
# bp-validate-dag.pl or hooks.json. Everything is located by grep pattern.
#
# Landmine 1 (spec §5.1): no PreToolUse BLOCK COUNT is ever asserted here. b15 relaxed t/62/t/64 to
# `>= 4` after a standoff; re-pinning any count anywhere in this suite recreates it. This file only
# ever greps hooks.json for CONTENT (a command mentioning "blueprint"), never counts blocks.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::MD5 qw(md5_hex);
use File::Basename ();

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS  = fwd("$Bin");
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $PROJ   = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";
my $ORCH   = "$BUTLER/scripts/bp-orchestrator.pl";
my $VALDAG = "$BUTLER/scripts/bp-validate-dag.pl";
my $HOOKSJ = "$BUTLER/hooks/hooks.json";

my $BP_ROOT = "$PROJ/.ccpraxis-local-data";
# The "live" fixture is a REAL, substantial blueprint.md -- the point is to exercise the
# API against a genuine file rather than a synthetic stub. It must NOT be pinned to one
# blueprint NAME: sandbox-butler-overhaul was hardcoded here, then archived, and because
# stage_live_copy `die`d rather than skipped, the whole file aborted after G7 -- G8..G19
# silently stopped running while the suite still looked like it was only "one red". A
# fixture that names a specific initiative is a fixture with an expiry date.
#
# Resolve instead by PROPERTY: the original path, then the archive, then the largest
# blueprint.md anywhere under .ccpraxis-local-data/blueprints. Every criterion that uses
# it SKIPs when nothing qualifies.
my $BP_ROOT_DIRS = "$BP_ROOT/blueprints";
my $LIVE_BP = do {
    my @cands = grep { defined && -f && -s $_ > 50_000 } (
        "$BP_ROOT_DIRS/sandbox-butler-overhaul/blueprint.md",
        "$BP_ROOT_DIRS/_archive/sandbox-butler-overhaul/blueprint.md",
    );
    unless (@cands) {
        @cands = sort { -s $b <=> -s $a }
                 grep { -f && -s $_ > 50_000 }
                 (glob("$BP_ROOT_DIRS/*/blueprint.md"), glob("$BP_ROOT_DIRS/_archive/*/blueprint.md"));
    }
    $cands[0];
};
my $BP_DIR  = defined $LIVE_BP ? fwd(File::Basename::dirname($LIVE_BP)) : "$BP_ROOT_DIRS/(none)";
my $HAVE_LIVE = defined $LIVE_BP && -f $LIVE_BP;
$LIVE_BP //= "$BP_ROOT_DIRS/(no substantial blueprint found)/blueprint.md";

diag("subject under test: $SCRIPT "
     . (-e $SCRIPT ? "(present)"
                    : "(ABSENT -- every G assertion below is expected to fail on MISSING BEHAVIOUR)"));
diag("hooks.json under test: $HOOKSJ " . (-e $HOOKSJ ? "(present)" : "(ABSENT)"));

# require the REAL parser -- G1/G10 must compare its actual output, not a reimplementation.
require $ORCH;

my $J = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $pn = 0;

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;

# =====================================================================================
# Scaffolding
# =====================================================================================

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}

sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}

sub digest_of { md5_hex(read_file($_[0]) // '') }

my $dn = 0;
sub fresh_dir { my $d = "$ROOT/w" . (++$dn); mkdir $d or die "mkdir $d: $!"; return $d }

sub stage_bytes {
    my ($bytes, $name) = @_;
    $name = 'blueprint.md' unless defined $name;
    my $d = fresh_dir();
    return write_file("$d/$name", $bytes);
}

# Copy the REAL live blueprint.md into a fresh temp dir. The live file is NEVER opened for writing.
sub stage_live_copy {
    my $d = fresh_dir();
    my $dst = "$d/blueprint.md";
    # Returns undef rather than dying. A `die` here does not fail ONE criterion -- it
    # aborts the whole file, so every criterion below it stops running while the suite
    # still reports a single red. That is how G8..G19 went dark when the pinned fixture
    # blueprint was archived.
    my $bytes = defined $LIVE_BP ? read_file($LIVE_BP) : undef;
    return undef unless defined $bytes;
    write_file($dst, $bytes);
    return $dst;
}

sub run_pl {
    my ($args, %opt) = @_;
    my $n    = ++$pn;
    my $inf  = "$ROOT/in.$n";
    my $outf = "$ROOT/out.$n";
    my $errf = "$ROOT/err.$n";
    write_file($inf, defined $opt{stdin} ? $opt{stdin} : '');
    write_file($outf, '');
    write_file($errf, '');
    my %extra = %{ $opt{env} || {} };
    local %ENV = (%CLEAN_ENV, %extra,
                  BWA_SCRIPT => fwd($SCRIPT), BWA_IN => fwd($inf),
                  BWA_OUT    => fwd($outf),   BWA_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$BWA_SCRIPT" "$@" < "$BWA_IN" > "$BWA_OUT" 2> "$BWA_ERR"',
        'bp-blueprint', @$args);
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

sub run_hook {
    my ($hook_path, $payload, %env) = @_;
    my $n    = ++$pn;
    my $pf   = write_file("$ROOT/payload.$n.json", $payload);
    my $outf = write_file("$ROOT/hout.$n", '');
    my $errf = write_file("$ROOT/herr.$n", '');
    local %ENV = (%CLEAN_ENV, %env,
                  BWA_HOOK => fwd($hook_path), BWA_IN => fwd($pf),
                  BWA_OUT  => fwd($outf),      BWA_ERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 bash "$BWA_HOOK" < "$BWA_IN" > "$BWA_OUT" 2> "$BWA_ERR"');
    return ($rc >> 8, read_file($outf) // '', read_file($errf) // '');
}

# A minimal blueprint.md-shaped fixture: legend prose (no `depends_on` token anywhere above the
# table -- SYN-14 clean), then a package-status table `parse_dag` can latch onto, contiguous rows,
# then a trailing decisions section. Carries one non-ASCII path (Andr\x{e9}-class) and one multi-byte
# status glyph, per G11.
my $DONE    = "\xE2\x9C\x85"; # U+2705 white heavy check mark
my $PENDING = "\xE2\xAC\x9C"; # U+2B1C white large square
sub base_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Status legend',
        '',
        "$DONE done, $PENDING pending",
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | $DONE done | sonnet |",
        "| b02 | second thing (path /home/Andr\xC3\xA9/work) | b01 | $PENDING pending | sonnet |",
        '',
        '## Decisions',
        '',
        '- SYN-01: an earlier decision, no hazard token here.',
        '',
    );
}

# =====================================================================================
# b42-decision-context-split-spec §4 fixtures. ADDITIVE ONLY (per spec §6): these are
# NEW fixtures for NEW assertions below; nothing above this point is altered.
# =====================================================================================

# Same package table as base_fixture, but the Decisions section is TABLE-shaped (b42's
# target shape: a `|`-row header + `|---` separator, then `| ID | text |` rows) instead
# of the legacy bullet list. $header lets callers exercise the widened header regex
# (default is the classic literal "## Decisions", proving the widening does not narrow).
sub table_decisions_fixture {
    my ($header) = @_;
    $header = '## Decisions' unless defined $header;
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Status legend',
        '',
        "$DONE done, $PENDING pending",
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | $DONE done | sonnet |",
        "| b02 | second thing (path /home/Andr\xC3\xA9/work) | b01 | $PENDING pending | sonnet |",
        '',
        $header,
        '',
        '| # | Decision |',
        '|---|---|',
        '| SYN-01 | an earlier decision, no hazard token here. |',
        '| SYN-02 | another decision row, also hazard-free. |',
        '',
    );
}

# Same as base_fixture (bullet-shaped Decisions section) but under the WIDER header
# spelling "## Synthesis decisions" -- proves the widened regex still recognizes a
# bullet-shaped section exactly as it always has for "## Decisions".
sub synthesis_bullet_fixture {
    return join("\n",
        '# Blueprint: fixture-bp',
        '',
        '## Status legend',
        '',
        "$DONE done, $PENDING pending",
        '',
        '## Packages',
        '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | $DONE done | sonnet |",
        "| b02 | second thing | b01 | $PENDING pending | sonnet |",
        '',
        '## Synthesis decisions',
        '',
        '- SYN-01: an earlier decision, no hazard token here.',
        '',
    );
}

# =====================================================================================
# G0: harness self-checks (expected to pass even with bp-blueprint.pl absent).
# =====================================================================================

ok(-e $LIVE_BP, "FIXTURE-SANITY: the live blueprint.md exists at the expected path");
# NOT an exact byte count. This oracle belongs to the package whose whole purpose is
# MUTATING blueprint.md, so pinning its size guarantees the test breaks the first time
# the API is used for real -- which is exactly what happened (109,498 -> 109,842 after one
# set-status and one add-package). Assert the property that matters: it is a substantial,
# real blueprint rather than a stub.
cmp_ok(-s $LIVE_BP, ">", 50_000,
   "FIXTURE-SANITY: the live blueprint.md is a substantial real file (>50 KB), not a stub");
{
    my $b = base_fixture();
    ok($b =~ /depends_on/, "FIXTURE-SANITY: base_fixture carries the depends_on column");
    ok($b =~ /Andr\xC3\xA9/, "FIXTURE-SANITY: base_fixture carries a non-ASCII (Andr\x{e9}-class) byte sequence");
    ok($b =~ /$DONE/ && $b =~ /$PENDING/, "FIXTURE-SANITY: base_fixture carries multi-byte status glyphs");
    my $dag = BpOrch::parse_dag($b);
    ok(exists $dag->{b01} && exists $dag->{b02}, "FIXTURE-SANITY: the real parse_dag sees both fixture packages");
    is_deeply($dag->{b02}, ['b01'], "FIXTURE-SANITY: parse_dag resolves b02's dependency on b01");
    is_deeply($dag->{b01}, [], "FIXTURE-SANITY: parse_dag sees b01 as depending on nothing (em-dash rejected)");
}
{
    my $live = read_file($LIVE_BP);
    my $dag  = BpOrch::parse_dag($live);
    ok(scalar(keys %$dag) > 0, "FIXTURE-SANITY: the real parse_dag parses at least one package out of the live file");
}

# =====================================================================================
# G1 (DC-1): every write round-trips -- parse_dag output byte-identical (structurally) before/after
# a mutation that should not change the DAG (set-status, add-decision).
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my $dag_before = BpOrch::parse_dag(read_file($p));
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b02', '--status', 'done']);
    is($rc, 0, "G1: set-status --pkg b02 --status done exits 0");
    my $dag_after = BpOrch::parse_dag(read_file($p));
    is_deeply($dag_after, $dag_before,
       "G1: parse_dag's structural output is unchanged by a status-only mutation (set-status)");
}
{
    my $p = stage_bytes(base_fixture());
    my $dag_before = BpOrch::parse_dag(read_file($p));
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $p, '--id', 'SYN-99', '--text', 'a harmless new decision']);
    is($rc, 0, "G1: add-decision --id SYN-99 exits 0");
    my $dag_after = BpOrch::parse_dag(read_file($p));
    is_deeply($dag_after, $dag_before,
       "G1: parse_dag's structural output is unchanged by add-decision");
}

# =====================================================================================
# G2 (DC-2): add-package inserts a contiguous row; a mutation breaking contiguity is refused.
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $p, '--pkg', 'b03',
                                    '--deliverable', 'third thing', '--deps', 'b02']);
    is($rc, 0, "G2: add-package --pkg b03 exits 0");
    my $new = read_file($p);
    my $dag = BpOrch::parse_dag($new);
    ok(exists $dag->{b03}, "G2: the real parse_dag now sees the new package b03");
    is_deeply($dag->{b03}, ['b02'], "G2: b03's dependency on b02 parses correctly");
    # Contiguity: every table row (the header line through the last package line) must be an
    # unbroken block of `|`-prefixed lines -- exactly parse_dag's own termination rule.
    my @lines = split /\n/, $new;
    my ($hdr_i) = grep { $lines[$_] =~ /^\s*\|/ && $lines[$_] =~ /depends_on/ } 0 .. $#lines;
    ok(defined $hdr_i, "G2: the depends_on header row is still present after add-package");
    my @pkg_lines;
    for my $i ($hdr_i + 1 .. $#lines) {
        last unless $lines[$i] =~ /^\s*\|/;
        push @pkg_lines, $lines[$i];
    }
    my $body_after_table = join("\n", @lines[$hdr_i + 1 + scalar(@pkg_lines) .. $#lines]);
    unlike($body_after_table, qr/^\s*\|.*\bb03\b/m,
       "G2: b03's row is inside the contiguous table block, not stranded below it");
}
{
    # A mutation that would break contiguity (inserting a package row after a non-`|` line has
    # already terminated the table, i.e. targeting a pkg id that does not exist so there is no
    # contiguous insertion point) must be REFUSED, not attempted.
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['add-package', '--file', $p, '--pkg', "b04\n\nstray prose\n\n| not | a | row |",
                                    '--deliverable', 'malformed id']);
    isnt($rc, 0, "G2: add-package with a --pkg value that cannot form a contiguous row is refused (non-zero exit)");
    is(read_file($p), $orig, "G2: ...and the file is left byte-identical (refused, not attempted)");
}

# =====================================================================================
# G3 (DC-3): the depends_on / SYN-14 hazard is enforced mechanically at write time.
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $p, '--id', 'SYN-14b',
                                    '--text', 'a table with a depends_on column would go here']);
    isnt($rc, 0, "G3: add-decision whose --text contains the literal 'depends_on' is refused (non-zero exit)");
    is($out, '', "G3: stdout empty on refusal");
    like($err, qr/SYN-14/, "G3: stderr names SYN-14 as the reason for refusal");
    is(read_file($p), $orig, "G3: file left byte-identical by the refusal");
}
{
    # The hazard is specifically about a SECOND depends_on-bearing block landing ABOVE the real
    # status table. A --text containing the token is refused regardless of insertion point in this
    # API (decisions are appended after the table today), so this is the mechanical, position-
    # independent form of the check the spec requires.
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $p, '--id', 'SYN-14c',
                                    '--text', 'no hazard token here']);
    is($rc, 0, "G3: add-decision with text that does NOT contain depends_on is accepted");
    isnt(read_file($p), $orig, "G3: ...and the file actually changed (proves the accept path really ran)");
}

# =====================================================================================
# G4 (DC-4): status values validate against the six-glyph vocabulary; unknown status refused.
# =====================================================================================

{
    for my $glyph ("$DONE done", "$PENDING pending", "\xF0\x9F\x94\xA7 running",
                   "\xF0\x9F\x94\x8D reviewing", "\xE2\x9B\x94 blocked", "\xE2\x8F\xB8 parked") {
        my $p = stage_bytes(base_fixture());
        my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b02', '--status', $glyph]);
        is($rc, 0, "G4: --status '$glyph' (one of the six live glyphs) is accepted");
    }
}
{
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b02', '--status', 'bogus-status']);
    isnt($rc, 0, "G4: an unknown status value is refused (non-zero exit)");
    is(read_file($p), $orig, "G4: ...and the file is left byte-identical");
}

# =====================================================================================
# G5 (DC-5): dependency cells normalise to one spelling on write; every dependency resolves to a
# real package id (bp-validate-dag.pl's own check, enforced at write time).
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my ($rc, $out, $err) = run_pl(['set-deps', '--file', $p, '--pkg', 'b01', '--deps', 'b02, b02   b02']);
    is($rc, 0, "G5: set-deps with duplicate/mixed-separator input exits 0");
    my $new = read_file($p);
    like($new, qr/\|\s*b01\s*\|/, "G5: b01's row is still present");
    ok($new =~ /\|\s*b01\s*\|[^\n|]*\|\s*([^|]*)\|/,
       "G5: b01's depends_on cell is capturable for normalisation inspection");
    my ($cell) = $new =~ /\|\s*b01\s*\|[^\n|]*\|\s*([^|]*)\|/;
    $cell = defined $cell ? $cell : '';
    my @toks = grep { length } split /[,\s]+/, $cell;
    is(scalar(@toks), 1, "G5: the written depends_on cell normalises to exactly one spelling (deduplicated)");
}
{
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    my ($rc, $out, $err) = run_pl(['set-deps', '--file', $p, '--pkg', 'b01', '--deps', 'no-such-package-xyz']);
    isnt($rc, 0, "G5: a dependency that does not resolve to a real package id is refused (non-zero exit)");
    like($err, qr/no-such-package-xyz/, "G5: stderr names the unresolved dependency");
    is(read_file($p), $orig, "G5: ...and the file is left byte-identical");
}

# =====================================================================================
# G6 (DC-6): concurrent writers serialise or one fails loudly; never partially written.
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my $before = digest_of($p);
    my $dag_before = BpOrch::parse_dag(read_file($p));
    my @kids;
    for my $i (1 .. 2) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            local %ENV = (%CLEAN_ENV,
                          BWA_SCRIPT => fwd($SCRIPT), BWA_PKG => "b0$i");
            exec('bash', '-c',
                'timeout 30 perl "$BWA_SCRIPT" set-status --file "$0" --pkg "$BWA_PKG" --status done '
              . '>/dev/null 2>/dev/null', $p);
            exit(127);
        }
        push @kids, $pid;
    }
    my @rc;
    for my $pid (@kids) { waitpid($pid, 0); push @rc, ($? >> 8) }
    ok((grep { $_ == 0 } @rc) >= 1,
       "G6: at least one of two concurrent set-status invocations succeeds (proves both actually ran)");
    my $after = read_file($p);
    ok(defined $after && length($after) > 0, "G6: the file exists and is non-empty after concurrent writers");
    my @lines = split /\n/, $after;
    my $table_ok = 1;
    my ($hdr_i) = grep { $lines[$_] =~ /^\s*\|/ && $lines[$_] =~ /depends_on/ } 0 .. $#lines;
    $table_ok = 0 unless defined $hdr_i;
    ok($table_ok, "G6: the table header is still intact (no torn/partial write) after concurrent access");
    my $dag_after = eval { BpOrch::parse_dag($after) };
    ok(ref $dag_after eq 'HASH' && scalar(keys %$dag_after) == scalar(keys %$dag_before),
       "G6: the file still parses to the same package COUNT afterward (no truncation/interleaving)");
}

# =====================================================================================
# G7 (DC-7): a refused operation leaves the file byte-identical -- asserted on a DIGEST.
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my $before_digest = digest_of($p);
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b02', '--status', 'not-a-real-status']);
    isnt($rc, 0, "G7: the refusing operation itself exits non-zero (proves the op actually ran and was refused)");
    # `isnt($rc,0)` alone is NOT enough and would leave this criterion vacuous: a MISSING
    # script also exits non-zero ("Can't open perl script", rc=2), and then "digest
    # unchanged" is trivially true. Distinguish a genuine API REFUSAL from an absent
    # tool, so G7 can only pass once refusal is really implemented.
    unlike($err, qr/Can't open perl script|No such file or directory/,
           "G7: the non-zero exit is a REFUSAL, not the script being absent");
    like($err, qr/not-a-real-status/,
         "G7: the refusal names the offending value (a real diagnostic, not a bare failure)");
    my $after_digest = digest_of($p);
    is($after_digest, $before_digest, "G7: the file's MD5 digest is unchanged by the refused operation");
}
{
    my $p = stage_bytes(base_fixture());
    my $before_digest = digest_of($p);
    my ($rc, $out, $err) = run_pl(['set-deps', '--file', $p, '--pkg', 'b01', '--deps', 'nonexistent-pkg']);
    isnt($rc, 0, "G7: a dependency-resolution refusal exits non-zero");
    is(digest_of($p), $before_digest, "G7: ...and the digest is unchanged (not merely 'no error visible')");
}

# =====================================================================================
# G8 (DC-8): read commands return only the requested slice; show <pkg> bounded well under the
# whole-file size.
# =====================================================================================

SKIP: {
    skip('G8: no substantial blueprint.md available as a live fixture', 3) unless $HAVE_LIVE;
    my $p = stage_live_copy();
    my ($rc, $out, $err) = run_pl(['show', '--file', $p, '--pkg', 'b13-deterministic-ledger-api']);
    is($rc, 0, "G8: show --pkg b13-deterministic-ledger-api exits 0 against the live-shaped file");
    ok(length($out) > 0, "G8: show emits some output (proves the read path actually ran)");
    ok(length($out) <= 8192,
       "G8: show <pkg> output is <= 8 KB, nowhere near the 109,498-byte whole file (b42's context goal)");
    ok(length($out) < -s $p, "G8: show <pkg> output is strictly smaller than the whole file it read from");
}

# =====================================================================================
# G9 (DC-9): the PreToolUse hook denies a direct Write/Edit to blueprint.md, and does NOT deny the
# API's own writer.
# =====================================================================================

{
    my $raw = read_file($HOOKSJ);
    my $decoded = eval { $J->decode($raw) };
    ok(ref $decoded eq 'HASH', "G9: hooks.json parses as JSON");
    # hooks.json nests the event arrays under a top-level "hooks" key:
    #   { "hooks": { "PreToolUse": [...], "PostToolUse": [...], "Stop": [...] } }
    # Reading $decoded->{PreToolUse} directly yields undef, so G9 reported "no
    # blueprint hook registered" even once one WAS registered — a false negative that
    # blamed the implementation for an oracle defect. Sibling t/62-repeat-guard.t and
    # t/64-ledger-guard.t both read $H->{hooks}{PreToolUse}; match them.
    my @pretooluse = ref $decoded eq 'HASH' && ref $decoded->{hooks} eq 'HASH'
                     && ref $decoded->{hooks}{PreToolUse} eq 'ARRAY'
                   ? @{ $decoded->{hooks}{PreToolUse} } : ();
    my @commands;
    for my $block (@pretooluse) {
        next unless ref $block eq 'HASH' && ref $block->{hooks} eq 'ARRAY';
        for my $h (@{ $block->{hooks} }) {
            push @commands, $h->{command} if ref $h eq 'HASH' && defined $h->{command};
        }
    }
    my ($blueprint_hook_cmd) = grep { /blueprint/i } @commands;
    ok(defined $blueprint_hook_cmd,
       "G9: hooks.json registers a PreToolUse hook whose command mentions 'blueprint' "
     . "(the new 6th block this package ships)");

  SKIP: {
        skip("no blueprint-targeting hook registered yet -- see prior assertion", 2)
            unless defined $blueprint_hook_cmd;
        my ($hook_path) = $blueprint_hook_cmd =~ /"([^"]*\.sh)"/;
        $hook_path =~ s/\$\{CLAUDE_PLUGIN_ROOT\}/$BUTLER/ if defined $hook_path;
        skip("could not extract a hook script path from: $blueprint_hook_cmd", 2)
            unless defined $hook_path && -e $hook_path;

        my $deny_payload = $J->encode({ tool_name => 'Write', cwd => $PROJ,
                            tool_input => { file_path => $LIVE_BP, content => 'direct hand-edit attempt' } });
        my ($rc1, $out1, $err1) = run_hook($hook_path, $deny_payload);
        isnt($rc1, 0, "G9: the hook DENIES a direct Write targeting the live blueprint.md path");

        my $allow_payload = $J->encode({ tool_name => 'Bash', cwd => $PROJ,
                            tool_input => { command => "perl $SCRIPT set-status --file $LIVE_BP --pkg x --status done" } });
        my ($rc2, $out2, $err2) = run_hook($hook_path, $allow_payload);
        is($rc2, 0, "G9: the hook does NOT deny a Bash invocation of the API's own writer (bp-blueprint.pl)");
    }
}

# =====================================================================================
# G10 (DC-10): round-trip on the LIVE 70-package file: parse -> no-op rewrite -> digest unchanged.
# =====================================================================================

SKIP: {
    skip('G10: no substantial blueprint.md available as a live fixture', 3) unless $HAVE_LIVE;
    my $p = stage_live_copy();
    my $live_digest = digest_of($p);
    my $dag_before = BpOrch::parse_dag(read_file($p));
    # A FLOOR, not an exact count -- same reason as the size check above. The blueprint gains
# packages over its life (b46 was added through this very API minutes after this test was
# written, taking it 70 -> 71). G10 s real claim is the ROUND TRIP below, not the census.
cmp_ok(scalar(keys %$dag_before), ">=", 60,
   "G10: the real parse_dag sees a full-size package set in the live-copied file");

    # A no-op rewrite: read the current status of a known package and set it to the SAME value.
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b13-deterministic-ledger-api', '--status', "$DONE done"]);
    is($rc, 0, "G10: a no-op set-status against the live-shaped full-size file exits 0");

    my $dag_after = BpOrch::parse_dag(read_file($p));
    is_deeply($dag_after, $dag_before,
       "G10: parse_dag structural output on the live copy is unchanged after the no-op rewrite");
}

# =====================================================================================
# G11 (DC-11): non-ASCII survives byte-for-byte -- Andr\x{e9}-class paths and multi-byte glyphs.
# =====================================================================================

{
    my $p = stage_bytes(base_fixture());
    my $orig = read_file($p);
    ok(index($orig, "Andr\xC3\xA9") >= 0, "G11: fixture carries the raw UTF-8 bytes for 'Andr\x{e9}'");
    my ($rc, $out, $err) = run_pl(['set-status', '--file', $p, '--pkg', 'b01', '--status', "$PENDING pending"]);
    is($rc, 0, "G11: set-status against a non-ASCII-bearing file exits 0");
    my $new = read_file($p);
    ok(index($new, "Andr\xC3\xA9") >= 0, "G11: the Andr\x{e9}-class byte sequence survives byte-for-byte after the mutation");
    ok(index($new, $DONE) >= 0 || index($new, $PENDING) >= 0,
       "G11: multi-byte status glyphs survive byte-for-byte after the mutation");
}
SKIP: {
    # The live file itself is the strongest instance of this criterion (spec: "the live file carries
    # Andr\x{e9}-class paths"). Prove that too, on a COPY, never the live path.
    skip('G11: no substantial blueprint.md available as a live fixture', 3) unless $HAVE_LIVE;
    my $p = stage_live_copy();
    my $orig = read_file($p);
    ok(index($orig, "Andr\xC3\xA9") >= 0,
       "G11: the live blueprint.md (copied) actually contains the raw UTF-8 bytes for 'Andr\x{e9}'");
    my ($rc) = run_pl(['set-status', '--file', $p, '--pkg', 'b13-deterministic-ledger-api', '--status', "$DONE done"]);
    is($rc, 0, "G11: a mutation against the live-shaped copy exits 0");
    my $new = read_file($p);
    is(index($new, "Andr\xC3\xA9") >= 0 ? 1 : 0, 1,
       "G11: the Andr\x{e9}-class bytes in the live copy survive the mutation byte-for-byte");
}

# =====================================================================================
# b42-decision-context-split-spec §4 (ADDITIVE ONLY -- see spec §6 / file header comment):
# header widening, table-shape detection, the new set-decision op, its refusals, and
# add-decision's refusal against a table-shaped section.
# =====================================================================================

# G12 (header widening): both the classic "## Decisions" and the wider
# "## Synthesis decisions" (mixed case) spellings are recognised identically.
for my $header ('## Decisions', '## Synthesis decisions', '## SYNTHESIS DECISIONS') {
    my $p = stage_bytes(table_decisions_fixture($header));
    my $orig = read_file($p);
    my $dag_before = BpOrch::parse_dag($orig);
    my ($rc, $out, $err) = run_pl(['set-decision', '--file', $p, '--id', 'SYN-02',
                                    '--text', 'a replaced decision text']);
    is($rc, 0, "G12: set-decision --id SYN-02 exits 0 under header '$header'");
    my $new = read_file($p);
    isnt($new, $orig, "G12: ...and the file actually changed under header '$header'");
    like($new, qr/\|\s*SYN-02\s*\|\s*a replaced decision text\s*\|/,
       "G12: SYN-02's row now contains the new text verbatim under header '$header'");
    unlike($new, qr/another decision row, also hazard-free/,
       "G12: the old text for SYN-02 is gone under header '$header'");
    like($new, qr/an earlier decision, no hazard token here\./,
       "G12: SYN-01's row is untouched under header '$header'");
    my $dag_after = BpOrch::parse_dag($new);
    is_deeply($dag_after, $dag_before,
       "G12: parse_dag's structural output is unchanged by set-decision under header '$header'");
}

# G13 (widened header still works for the legacy BULLET shape, unchanged behaviour):
# add-decision and the `decisions` read op both recognise "## Synthesis decisions".
{
    my $p = stage_bytes(synthesis_bullet_fixture());
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $p, '--id', 'SYN-77',
                                    '--text', 'a widened-header bullet decision']);
    is($rc, 0, "G13: add-decision recognises the widened '## Synthesis decisions' header and exits 0");
    my $new = read_file($p);
    like($new, qr/SYN-77: a widened-header bullet decision/,
       "G13: the new bullet was appended under the widened header");

    my ($rc2, $out2, $err2) = run_pl(['decisions', '--file', $p]);
    is($rc2, 0, "G13: the 'decisions' read op also recognises the widened header and exits 0");
    like($out2, qr/SYN-77: a widened-header bullet decision/,
       "G13: ...and lists the newly-added decision");
}

# G14 — RETARGETED (SYN-21: a mandated later change invalidating a done sibling's
# assertion, owned and updated rather than left red).
#
# G14 originally asserted that add-decision REFUSES a table-shaped section. That refusal
# left a hole nobody could get through: set-decision requires a row that already exists,
# so a table-shaped section could never receive a NEW decision -- and the template ships
# that shape, making a freshly initialised blueprint un-authorable through the API. The
# refusal message even pointed at a verb that cannot create rows.
#
# G14's INTENT is preserved exactly and is what is asserted now: add-decision must never
# CORRUPT the table. It no longer refuses; it appends a well-formed row, and a bullet
# must never appear in a table-shaped section. (G19 covers contiguity and duplicate ids.)
{
    my $p = stage_bytes(table_decisions_fixture());
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $p, '--id', 'SYN-99',
                                    '--text', 'an appended row, not a bullet']);
    is($rc, 0, "G14: add-decision against a table-shaped Decisions section succeeds");

    my $new = read_file($p) // '';
    like($new, qr/^\|\s*SYN-99\s*\|.*an appended row, not a bullet/m,
        "G14: ...by appending a well-formed TABLE ROW");

    # The corruption G14 has always existed to prevent: a bullet inside a table.
    my ($sec) = $new =~ /^##[ \t]+Decisions[ \t]*\n(.*?)(?=^##[ \t]|\z)/ms;
    $sec = '' unless defined $sec;
    unlike($sec, qr/^\s*-\s+SYN-99/m,
        "G14: and NEVER as a bullet inside the table (the original defect)");
}

# G15 (set-decision refusal: --text containing the literal 'depends_on', SYN-14 wording
# class identical to op_add_decision's own check -- spec §4 / §3 of the b42 spec).
{
    my $p = stage_bytes(table_decisions_fixture());
    my $before_digest = digest_of($p);
    my ($rc, $out, $err) = run_pl(['set-decision', '--file', $p, '--id', 'SYN-01',
                                    '--text', 'a table with a depends_on column would go here']);
    isnt($rc, 0, "G15: set-decision whose --text contains the literal 'depends_on' is refused");
    is($out, '', "G15: stdout empty on refusal");
    like($err, qr/SYN-14/, "G15: stderr names SYN-14 as the reason for refusal");
    is(digest_of($p), $before_digest, "G15: ...and the file is left byte-identical");
}

# G16 (set-decision refusal: --id / --text containing a pipe or newline -- field_safe).
{
    my @cases = (
        [ 'id-with-pipe',    ['--id', 'SYN|01',   '--text', 'harmless text'] ],
        [ 'id-with-newline', ["--id", "SYN-01\nbogus", '--text', 'harmless text'] ],
        [ 'text-with-pipe',  ['--id', 'SYN-01',   '--text', 'harmless | text'] ],
        [ 'text-with-newline', ['--id', 'SYN-01', '--text', "harmless\ntext"] ],
    );
    for my $case (@cases) {
        my ($label, $extra_args) = @$case;
        my $p = stage_bytes(table_decisions_fixture());
        my $before_digest = digest_of($p);
        my ($rc, $out, $err) = run_pl(['set-decision', '--file', $p, @$extra_args]);
        isnt($rc, 0, "G16: set-decision with $label is refused (non-zero exit)");
        is(digest_of($p), $before_digest, "G16: ...and the file is left byte-identical ($label)");
        ok(length($err) > 0, "G16: stderr names a cause for the refusal ($label)");
    }
}

# G17 (set-decision refusal: --id not present in the table -- never creates a row).
{
    my $p = stage_bytes(table_decisions_fixture());
    my $before_digest = digest_of($p);
    my $orig = read_file($p);
    my $rows_before = () = ($orig =~ /^\|\s*SYN-/mg);
    my ($rc, $out, $err) = run_pl(['set-decision', '--file', $p, '--id', 'SYN-404',
                                    '--text', 'this id does not exist']);
    isnt($rc, 0, "G17: set-decision with an unknown --id is refused (non-zero exit)");
    like($err, qr/SYN-404/, "G17: stderr names the unknown id as the cause");
    is(digest_of($p), $before_digest, "G17: ...and the file is left byte-identical");
    my $new = read_file($p);
    my $rows_after = () = ($new =~ /^\|\s*SYN-/mg);
    is($rows_after, $rows_before, "G17: ...and no new row was created (add-decision's job, not set-decision's)");
}

# =====================================================================================
# G18 — A BLUEPRINT CAN BE AUTHORED END TO END THROUGH THIS API.
#
# The gap this closes: `guard-blueprint-write.sh` denies Write/Edit to ANY blueprint.md
# path -- including one that does not exist yet -- while /blueprint:create step 4 said
# "Write blueprint.md from templates/blueprint.md". The documented create flow was
# therefore impossible to execute as written, and the only way through was to `cp` a
# hand-authored file past a hook that cannot see Bash: exactly the hand-splice this API
# exists to prevent.
#
# No single assertion caught it because every existing criterion starts from a blueprint
# that ALREADY EXISTS. This one starts from nothing, which is the case the author is in.
# =====================================================================================
{
    my $dir  = tempdir(CLEANUP => 1);
    my $tpl  = "$BUTLER/../blueprint/templates/blueprint.md";
    my $bp   = "$dir/nested/blueprint.md";      # nested: init must create the parent

    SKIP: {
        skip('G18: blueprint template not present in this checkout', 9) unless -f $tpl;

        my ($rc) = run_pl([ 'init', '--file', $bp, '--template', $tpl,
                              '--name', 'g18-demo', '--created', '2026-01-02' ]);
        is($rc, 0, 'G18: init creates a blueprint from the template (and its parent dir)');
        ok(-f $bp, 'G18: the file exists afterwards');

        my $txt = read_file($bp) // '';
        like($txt, qr/^blueprint:\s*g18-demo$/m, 'G18: --name is substituted');
        like($txt, qr/^status:\s*drafting\b/m,   'G18: a fresh blueprint starts as drafting');

        # The template's illustrative rows must NOT survive: parse_dag would read
        # `01-<slug>` as a real package with no ledger, so a brand-new blueprint would
        # fail its own DAG validation.
        unlike($txt, qr/^\|\s*01-<slug>/m,
            'G18: template placeholder package row is stripped');

        # Refuse-rather-than-overwrite: an existing blueprint is somebody's initiative.
        my ($rc2) = run_pl([ 'init', '--file', $bp, '--template', $tpl, '--name', 'g18-demo' ]);
        isnt($rc2, 0, 'G18: init refuses to overwrite an existing blueprint');

        # Prose has a typed verb, so the author never needs Write.
        my $body = "$dir/body.md";
        write_file($body, "A real objective.\n");
        my ($rc3) = run_pl([ 'set-section', '--file', $bp,
                               '--section', 'Objective', '--text-file', $body ]);
        is($rc3, 0, 'G18: set-section fills a prose section');
        like(read_file($bp) // '', qr/A real objective\./, 'G18: ...and the text landed');

        # Structured sections keep their own verbs -- free text must never overwrite the
        # table parse_dag reads.
        my ($rc4) = run_pl([ 'set-section', '--file', $bp,
                               '--section', 'Package status', '--text-file', $body ]);
        isnt($rc4, 0, 'G18: set-section refuses a structured section');
    }
}

# =====================================================================================
# G19 — add-decision works on a TABLE-shaped Decisions section.
#
# b42 converted that section to a table and did not update the appender: add-decision
# refused tables, and set-decision requires a row that already exists -- so a
# table-shaped section could never receive a NEW decision, and the refusal message
# pointed at a verb that cannot create one. The template ships the table shape, so a
# freshly initialised blueprint was un-authorable.
# =====================================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $tpl = "$BUTLER/../blueprint/templates/blueprint.md";
    my $bp  = "$dir/blueprint.md";

    SKIP: {
        skip('G19: blueprint template not present in this checkout', 4) unless -f $tpl;
        run_pl([ 'init', '--file', $bp, '--template', $tpl, '--name', 'g19-demo' ]);

        my ($rc1) = run_pl([ 'add-decision', '--file', $bp, '--id', '1',
                               '--text', 'First decision', '--decided', 'user', '--date', '2026-01-02' ]);
        is($rc1, 0, 'G19: add-decision appends a ROW to a table-shaped section');

        my ($rc2) = run_pl([ 'add-decision', '--file', $bp, '--id', '2',
                               '--text', 'Second decision', '--decided', 'user', '--date', '2026-01-02' ]);
        is($rc2, 0, 'G19: ...and a second one');

        # Contiguity is the real assertion. A blank line between the separator and a row
        # TERMINATES the table, orphaning the row -- which is exactly what the first
        # implementation did by appending at the section end rather than after the last row.
        my $txt = read_file($bp) // '';
        like($txt, qr/^\|---.*\n\|\s*1\s*\|.*\n\|\s*2\s*\|/m,
            'G19: rows are contiguous with the separator (a blank line would end the table)');

        my ($rc3) = run_pl([ 'add-decision', '--file', $bp, '--id', '1', '--text', 'dupe' ]);
        isnt($rc3, 0, 'G19: a duplicate decision id is refused');
    }
}

# =====================================================================================
# G20 -- the Harvest log must be REACHABLE by some typed verb.
#
# Same hole shape as G19, one section over. `set-section` refuses "Harvest log" as
# orchestrator-owned, the PreToolUse guard refuses a direct Edit, and for a long time no
# orchestrator verb existed -- so the section was writable by NO path at all and every
# blueprint's harvest log stayed empty. That silently voids any package done-criterion
# phrased "recorded in the harvest log" (unified-tui-design-system's
# 11-operator-visual-signoff, criterion 2, is exactly that). Found 2026-08-12.
#
# The assertion is deliberately about REACHABILITY plus table integrity, not about the
# template's specific 4 columns -- the table's shape belongs to the blueprint author.
# =====================================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $tpl = "$BUTLER/../blueprint/templates/blueprint.md";
    my $bp  = "$dir/blueprint.md";

    SKIP: {
        skip('G20: blueprint template not present in this checkout', 5) unless -f $tpl;
        run_pl([ 'init', '--file', $bp, '--template', $tpl, '--name', 'g20-demo' ]);

        my ($rcs) = run_pl([ 'set-section', '--file', $bp, '--section', 'Harvest log',
                             '--text-file', $tpl ]);
        isnt($rcs, 0, 'G20: set-section still refuses Harvest log (it is typed-verb territory)');

        my ($rc1) = run_pl([ 'add-harvest', '--file', $bp, '--pkg', '01-alpha',
                             '--outputs', 'specs/01-alpha-spec.md; suite green',
                             '--by', 'orchestrator', '--date', '2026-01-02' ]);
        is($rc1, 0, 'G20: add-harvest appends a row -- the section is reachable');

        my ($rc2) = run_pl([ 'add-harvest', '--file', $bp, '--pkg', '02-beta',
                             '--outputs', 'reports/02-beta/review.md',
                             '--by', 'orchestrator', '--date', '2026-01-03' ]);
        is($rc2, 0, 'G20: ...and a second one');

        # Contiguity, exactly as G19: a blank line between the separator and a row ends
        # the table and orphans the row.
        my $txt = read_file($bp) // '';
        like($txt, qr/^\|-+.*\n\|\s*01-alpha\s*\|.*\n\|\s*02-beta\s*\|/m,
            'G20: rows are contiguous with the separator');

        # The template ships a placeholder `| | | |`; leaving it above real rows renders
        # a permanently empty leading row.
        unlike($txt, qr/^\|(?:\s*\|)+\s*$/m,
            'G20: the placeholder blank row is dropped once a real row exists');
    }
}

done_testing();
