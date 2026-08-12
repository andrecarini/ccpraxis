#!/usr/bin/env perl
# t/103-add-decision-newline-refusal.t — a02-api-and-guard-defects, DEFECT 3.
# `add-decision --text` currently accepts a newline/CR and SILENTLY SQUASHES it
# (bp-blueprint.pl:766, `$text =~ s/[\r\n]+/ /g`) while `--id` is validated with
# field_safe and refused outright for the same input. Spec §2.3 / AC-8, AC-9.
#
# WRITTEN BLIND TO THE IMPLEMENTATION. Every "must refuse" assertion below is
# expected to FAIL against the pre-change tree: today the newline is squashed and
# the command exits 0, appending a decision -- never exit 3.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";

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
    my ($args) = @_;
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

sub fresh_fixture {
    my $n = ++$pn;
    my $dir = "$ROOT/d$n"; mkdir $dir or die;
    my $path = "$dir/blueprint.md";
    write_file($path, join("\n",
        '# Blueprint: fixture-bp', '',
        '## Package status', '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| b01 | first thing | \xE2\x80\x94 | $DONE done | sonnet |",
        "| b02 | second thing | b01 | $PENDING pending | sonnet |",
        '',
        '## Decisions', '',
        '- SYN-01: an earlier decision, no hazard token here.',
        '',
    ));
    return $path;
}

# ── AC-8: --text with a literal newline -> exit 3, byte-identical, constraint named ──
{
    my $path = fresh_fixture();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-99',
                                     '--text', "line one\nline two"]);
    is($rc, 3, 'AC-8(text newline): exits 3');
    is(read_file($path), $before, 'AC-8(text newline): blueprint.md byte-identical');
    like($err, qr/pipe or newline/i, 'AC-8(text newline): stderr names the newline/pipe constraint');
}

# ── AC-8: --text with a literal CR -> exit 3 ────────────────────────────────────
{
    my $path = fresh_fixture();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-98',
                                     '--text', "line one\rline two"]);
    is($rc, 3, 'AC-8(text CR): exits 3');
    is(read_file($path), $before, 'AC-8(text CR): blueprint.md byte-identical');
}

# ── AC-8: --text with a pipe -> exit 3, same message family ─────────────────────
{
    my $path = fresh_fixture();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-97',
                                     '--text', 'a decision | with a pipe in it']);
    is($rc, 3, 'AC-8(text pipe): exits 3');
    is(read_file($path), $before, 'AC-8(text pipe): blueprint.md byte-identical');
    like($err, qr/pipe or newline/i, 'AC-8(text pipe): stderr names the constraint');
}

# ── AC-8: --decided with a newline -> exit 3 ────────────────────────────────────
{
    my $path = fresh_fixture();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-96',
                                     '--text', 'a clean single-line decision',
                                     '--decided', "user\nname"]);
    is($rc, 3, 'AC-8(decided newline): exits 3');
    is(read_file($path), $before, 'AC-8(decided newline): blueprint.md byte-identical');
    like($err, qr/pipe or newline/i, 'AC-8(decided newline): stderr names the constraint');
}

# ── AC-8: --date with a newline -> exit 3 ───────────────────────────────────────
{
    my $path = fresh_fixture();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-95',
                                     '--text', 'a clean single-line decision',
                                     '--date', "2026-08-12\nextra"]);
    is($rc, 3, 'AC-8(date newline): exits 3');
    is(read_file($path), $before, 'AC-8(date newline): blueprint.md byte-identical');
    like($err, qr/pipe or newline/i, 'AC-8(date newline): stderr names the constraint');
}

# ── AC-9: a single-line --text still appends the decision and exits 0 (positive gate) ──
{
    my $path = fresh_fixture();
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-90',
                                     '--text', 'a perfectly ordinary single-line decision']);
    is($rc, 0, 'AC-9: single-line --text exits 0') or diag("stderr: $err");
    my $after = read_file($path);
    like($after, qr/SYN-90.*a perfectly ordinary single-line decision/,
        'AC-9: the decision was actually appended to the file');
}

# ── AC-16: --text containing the literal 'depends_on' is still refused (SYN-14,
#           pre-existing, must be unchanged by this fix) ───────────────────────
{
    my $path = fresh_fixture();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['add-decision', '--file', $path, '--id', 'SYN-89',
                                     '--text', 'mentions depends_on directly']);
    is($rc, 3, 'AC-16: --text containing the literal depends_on token still exits 3');
    is(read_file($path), $before, 'AC-16: blueprint.md byte-identical');
    like($err, qr/SYN-14/, 'AC-16: the existing SYN-14 message is preserved');
}

done_testing();
