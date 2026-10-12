#!/usr/bin/env perl
# platform: any
# Regression oracle for almanac bug 20261001-234949-c44b: bp-ledger.pl's
# _widen_check_inflight_conflict (bp-ledger.pl ~1968-2032) decodes
# .drive-solo/inflight.json with JSON::PP->new->utf8->decode, which UTF-8-flags
# any decoded string that itself contains a non-ASCII byte (e.g. an inflight
# entry's `ledger` field naming a path with an accented "Andre" segment). That
# flagged string is then concatenated with $data_dir -- a RAW-BYTES path read
# from the command line/filesystem, never decoded -- at:
#
#   $oledger_fs = "$data_dir/$oledger_fs";
#
# Perl's string concatenation upgrades the non-flagged operand to match the
# flagged one by reinterpreting each of its raw bytes as a Latin-1 code point,
# which silently corrupts any non-ASCII byte $data_dir carries (its own
# "Andre"-accented segment, in the real bug's repro: a non-ASCII TMPDIR). The
# resulting path then fails -f/open, so the conflict check can't read the
# other package's ledger and reports "no conflict" even when one exists --
# fail-OPEN on a refusal check is the dangerous direction.
#
# This file builds that scenario directly on disk (no reliance on the host's
# own TMPDIR/username) and asserts the conflict is correctly DETECTED. Pre-fix,
# this must fail because the current code wrongly reports no conflict and lets
# the write-set-widening operation through where it should refuse.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $LEDGER_PL = "$Bin/../../scripts/bp-ledger.pl";
my $TEMPLATE  = "$Bin/../../../blueprint/templates/package-ledger.md";
ok(-f $LEDGER_PL && -f $TEMPLATE, 'bp-ledger.pl and the ledger template exist') or BAIL_OUT('missing inputs');

# Raw UTF-8 bytes for "e with acute" (U+00E9), built via \x{} escapes rather
# than a literal non-ASCII source character so the fixture's byte content
# never depends on how this .t file itself happens to be saved/read. Matches
# the "Andr\xC3\xA9" convention already used by blueprint-set-title.t.
my $ACCENT = "\x{c3}\x{a9}";

sub slurp { my ($p) = @_; open my $f, '<:raw', $p or die "$p: $!"; local $/; my $s = <$f>; close $f; $s }

sub run_cli {
    my (@args) = @_;
    my $dir = tempdir(CLEANUP => 1);
    my $out = "$dir/out";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDOUT, '>', $out or die; open STDERR, '>&', \*STDOUT or die;
        exec($^X, $LEDGER_PL, @args) or exit 127;
    }
    waitpid($pid, 0);
    return ($? >> 8, slurp($out));
}

sub write_set { my ($l) = @_; my ($v) = slurp($l) =~ /^write_set:\s*(.*?)\s*$/m; $v }

# nonascii_fixture() -> ($own_ledger, $other_ledger, $data_dir, $new_path).
#
# Layout (all under one tempdir, mirroring _widen_check_inflight_conflict's
# own "4 levels up from the ledger" data-dir resolution):
#
#   $data_dir/                                    <- itself carries a raw non-ASCII
#                                                      byte segment (like a real
#                                                      non-ASCII TMPDIR)
#     .drive-solo/inflight.json                   <- hand-written, raw bytes
#     blueprints/own-bp/packages/01-own.md        <- package under test
#     blueprints/Andre-other-bp/packages/02-other.md  <- the OTHER in-flight
#                                                      package; its directory
#                                                      name is ALSO non-ASCII so
#                                                      inflight.json's `ledger`
#                                                      field value itself
#                                                      contains a non-ASCII
#                                                      byte (only a string that
#                                                      itself holds one gets
#                                                      UTF-8-flagged by
#                                                      JSON::PP's decode --
#                                                      confirmed empirically
#                                                      against this host's
#                                                      JSON::PP).
#
# inflight.json's `ledger` field is a path RELATIVE to $data_dir (no leading
# '/' or drive letter), so it takes the vulnerable concatenation branch rather
# than being treated as already-absolute.
sub nonascii_fixture {
    my $root      = tempdir(CLEANUP => 1);
    my $data_dir  = "$root/Andr${ACCENT}-ledger-test";
    my $other_dir = "Andr${ACCENT}-other-bp";

    make_path("$data_dir/blueprints/own-bp/packages");
    make_path("$data_dir/blueprints/$other_dir/packages");
    make_path("$data_dir/.drive-solo");

    my $own_ledger = "$data_dir/blueprints/own-bp/packages/01-own.md";
    my ($rc1, $out1) = run_cli('create', '--ledger', $own_ledger, '--package', '01-own',
                                '--blueprint', 'own-bp', '--template', $TEMPLATE,
                                '--write-set', 'src/a.pl:t/a.t');
    die "fixture: own ledger create failed ($rc1): $out1" unless $rc1 == 0;

    open my $bw, '>:raw', "$data_dir/blueprints/own-bp/blueprint.md" or die $!;
    print $bw "# own-bp\n\n## Decisions\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n"
            . "| 7 | Re-scope: package 01 also ships src/shared.pl. | driver | 2026-10-03 |\n";
    close $bw;

    my $other_ledger = "$data_dir/blueprints/$other_dir/packages/02-other.md";
    my ($rc2, $out2) = run_cli('create', '--ledger', $other_ledger, '--package', '02-other',
                                '--blueprint', 'other-bp', '--template', $TEMPLATE,
                                '--write-set', 'src/shared.pl:t/shared.t');
    die "fixture: other ledger create failed ($rc2): $out2" unless $rc2 == 0;
    ok(-f $other_ledger, 'fixture precondition: the other package\'s ledger genuinely exists on disk');

    my $oledger_rel = "blueprints/$other_dir/packages/02-other.md";
    my $inflight_json = qq({"packages":[{"blueprint":"other-bp","package":"02-other",)
                       . qq("ledger":"$oledger_rel"}]});
    open my $ifh, '>:raw', "$data_dir/.drive-solo/inflight.json" or die $!;
    print $ifh $inflight_json;
    close $ifh;

    return ($own_ledger, $other_ledger, $data_dir, 'src/shared.pl');
}

subtest 'AC1: widen-write-set detects an overlap with another in-flight package when the data dir is non-ASCII' => sub {
    my ($own_ledger, $other_ledger, $data_dir, $new_path) = nonascii_fixture();
    my $before = slurp($own_ledger);

    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $own_ledger, '--decision', '7',
                              '--path', $new_path);

    is($rc, 3, 'refused with exit 3 (conflict detected, not silently missed)') or diag($out);
    like($out, qr/overlap in-flight.*other-bp\/02-other/, 'names the conflicting in-flight package')
        or diag($out);
    is(slurp($own_ledger), $before, 'own ledger is byte-for-byte unchanged after the refusal');
};

subtest 'AC1: set-write-set (the other call site of the same conflict check) detects the overlap too' => sub {
    my ($own_ledger, $other_ledger, $data_dir, $new_path) = nonascii_fixture();
    my $before = slurp($own_ledger);
    my $existing_ws = write_set($own_ledger); # 'src/a.pl:t/a.t'

    my ($rc, $out) = run_cli('set-write-set', '--ledger', $own_ledger, '--decision', '7',
                              '--path', 'src/a.pl', '--path', 't/a.t', '--path', $new_path);

    is($rc, 3, 'refused with exit 3 (conflict detected, not silently missed)') or diag($out);
    like($out, qr/overlap in-flight.*other-bp\/02-other/, 'names the conflicting in-flight package')
        or diag($out);
    is(slurp($own_ledger), $before, 'own ledger is byte-for-byte unchanged after the refusal');
};

subtest 'AC1 sanity: the SAME fixture shape with an ASCII-only data dir already detects the conflict' => sub {
    # Establishes that the conflict-detection LOGIC itself is sound and the
    # non-ASCII cases above are failing (pre-fix) specifically because of the
    # non-ASCII byte-path handling, not some other fixture mistake.
    my $root      = tempdir(CLEANUP => 1);
    my $data_dir  = "$root/ledger-test";
    make_path("$data_dir/blueprints/own-bp/packages");
    make_path("$data_dir/blueprints/other-bp/packages");
    make_path("$data_dir/.drive-solo");

    my $own_ledger = "$data_dir/blueprints/own-bp/packages/01-own.md";
    my ($rc1, $out1) = run_cli('create', '--ledger', $own_ledger, '--package', '01-own',
                                '--blueprint', 'own-bp', '--template', $TEMPLATE,
                                '--write-set', 'src/a.pl:t/a.t');
    die "fixture: own ledger create failed ($rc1): $out1" unless $rc1 == 0;
    open my $bw, '>:raw', "$data_dir/blueprints/own-bp/blueprint.md" or die $!;
    print $bw "# own-bp\n\n## Decisions\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n"
            . "| 7 | Re-scope: package 01 also ships src/shared.pl. | driver | 2026-10-03 |\n";
    close $bw;

    my $other_ledger = "$data_dir/blueprints/other-bp/packages/02-other.md";
    my ($rc2, $out2) = run_cli('create', '--ledger', $other_ledger, '--package', '02-other',
                                '--blueprint', 'other-bp', '--template', $TEMPLATE,
                                '--write-set', 'src/shared.pl:t/shared.t');
    die "fixture: other ledger create failed ($rc2): $out2" unless $rc2 == 0;

    open my $ifh, '>:raw', "$data_dir/.drive-solo/inflight.json" or die $!;
    print $ifh qq({"packages":[{"blueprint":"other-bp","package":"02-other",)
             . qq("ledger":"blueprints/other-bp/packages/02-other.md"}]});
    close $ifh;

    my ($rc, $out) = run_cli('widen-write-set', '--ledger', $own_ledger, '--decision', '7',
                              '--path', 'src/shared.pl');
    is($rc, 3, 'ASCII-only control case: refused with exit 3') or diag($out);
};

done_testing();
