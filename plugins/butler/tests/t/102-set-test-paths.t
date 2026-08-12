#!/usr/bin/env perl
# t/102-set-test-paths.t — a02-api-and-guard-defects, DEFECT 2.
# `bp-blueprint.pl set-test-paths` does not exist yet: nothing today can change a
# package ledger's `test_paths:` frontmatter field short of a hand-edit -- which the
# write guard forbids. Spec §2.2 / AC-5, AC-6, AC-7.
#
# WRITTEN BLIND TO THE IMPLEMENTATION. The verb is entirely new, so EVERY assertion
# below is expected to fail against the pre-change tree: `set-test-paths` is not in
# %DISPATCH, so bp-blueprint.pl exits with "unknown subcommand 'set-test-paths'"
# (exit 3) for every case, including the ones this file expects to succeed (exit 0).
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
    print $w $bytes;
    close $w or die "close $path: $!";
    return $path;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/; my $c = <$r>; close $r;
    return defined $c ? $c : '';
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

sub fresh_ledger {
    my (%o) = @_;
    my $n = ++$pn;
    my $dir = "$ROOT/d$n";
    mkdir $dir or die;
    my $path = "$dir/pkg.md";
    my $body = $o{body} // (
        "---\n"
      . "package: pkg1\n"
      . "blueprint: bp1\n"
      . "status: running\n"
      . "model: sonnet\n"
      . "max_turns: 80\n"
      . "write_set: old/write/\n"
      . "test_paths: old/\n"
      . "last_updated: 2026-08-01T00:00:00Z\n"
      . "---\n\n# pkg1\n\nsome body text\n"
    );
    write_file($path, $body);
    return $path;
}

# ── AC-5: replaces ONLY test_paths:, every other byte (incl. last_updated) unchanged ──
{
    my $path = fresh_ledger();
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/:b/']);
    is($rc, 0, 'AC-5: set-test-paths --paths a/:b/ exits 0') or diag("stderr: $err");
    my $after = read_file($path);
    like($after, qr/^test_paths:\s*a\/:b\/\s*$/m, 'AC-5: test_paths: line now reads a/:b/');
    unlike($after, qr/test_paths:\s*old\//, 'AC-5: the old test_paths value is gone');

    (my $before_sans = $before) =~ s/^test_paths:.*$/<TP>/m;
    (my $after_sans  = $after)  =~ s/^test_paths:.*$/<TP>/m;
    is($after_sans, $before_sans, 'AC-5: every OTHER byte (incl. last_updated:) unchanged');
}

# ── AC-5(idempotent, run_write's no-op path): re-running exits 0, byte-identical ──
{
    my $path = fresh_ledger();
    run_pl(['set-test-paths', '--file', $path, '--paths', 'a/:b/']);
    my $mid = read_file($path);
    my ($rc2, $out2, $err2) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/:b/']);
    is($rc2, 0, 'AC-5(rerun): re-running the identical command exits 0') or diag("stderr: $err2");
    is(read_file($path), $mid, 'AC-5(rerun): file byte-identical to the first run\'s result');
}

# ── AC-6: no frontmatter block at all -> exit 2, byte-identical, precondition named ──
{
    my $path = fresh_ledger(body => "# just a markdown file\n\nno frontmatter here\n");
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/']);
    is($rc, 2, 'AC-6(no frontmatter): exit 2');
    is(read_file($path), $before, 'AC-6(no frontmatter): file byte-identical');
    like($err, qr/not a package ledger|frontmatter/i, 'AC-6(no frontmatter): stderr names the precondition');
}

# ── AC-6: frontmatter present but no `package:` line -> exit 2, refused ──────────
{
    my $path = fresh_ledger(body =>
        "---\nblueprint: bp1\nstatus: running\ntest_paths: old/\nlast_updated: 2026-08-01T00:00:00Z\n---\n\n# x\n");
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/']);
    is($rc, 2, 'AC-6(no package:): exit 2');
    is(read_file($path), $before, 'AC-6(no package:): file byte-identical');
    like($err, qr/package/i, 'AC-6(no package:): stderr names the missing `package:` precondition');
}

# ── AC-6: frontmatter + package: present but no `test_paths:` line -> exit 2 ─────
{
    my $path = fresh_ledger(body =>
        "---\npackage: pkg1\nblueprint: bp1\nstatus: running\nlast_updated: 2026-08-01T00:00:00Z\n---\n\n# x\n");
    my $before = read_file($path);
    my ($rc, $out, $err) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/']);
    is($rc, 2, 'AC-6(no test_paths:): exit 2');
    is(read_file($path), $before, 'AC-6(no test_paths:): file byte-identical');
    like($err, qr/test_paths/i, 'AC-6(no test_paths:): stderr names the missing `test_paths:` precondition');
}

# ── AC-7: --paths validation -- exit 3, NOTHING opened/written, constraint named ──
{
    my %cases = (
        empty            => '',
        'whitespace-only'=> '   ',
        pipe             => 'a|b',
        newline          => "a\nb",
        absolute         => '/abs/path',
        'dot-dot'        => 'x/../y',
    );
    for my $label (sort keys %cases) {
        my $path = fresh_ledger();
        my $before = read_file($path);
        my $before_mtime = (stat($path))[9];
        my ($rc, $out, $err) = run_pl(['set-test-paths', '--file', $path, '--paths', $cases{$label}]);
        is($rc, 3, "AC-7($label): --paths '$cases{$label}' exits 3");
        is(read_file($path), $before, "AC-7($label): file byte-identical (nothing written)");
        is((stat($path))[9], $before_mtime, "AC-7($label): mtime unchanged (nothing even opened for write)");
        ok(length($err) > 0, "AC-7($label): stderr names the constraint");
    }
}

# ── ORACLE-GAP (redteam MAJOR-3, step6): a pattern so broad it loses every
#    specificity comparison silently disables the whole-package implementer
#    guard (guard-writes.sh's ranking: length 1 loses to virtually every
#    write_set pattern). set-test-paths's own validation refuses empty,
#    pipe/newline, absolute and `..` entries but NOT pure-wildcard entries.
#    Measured against the real script: rc=0 (accepted) for every row below;
#    must be rc=3 (refused), same as AC-7's other entries. ─────────────────
{
    my %cases = (
        star          => '*',
        'double-star' => '**',
        'root-dot'    => '.',
        'glob-all'    => '**/*',
    );
    for my $label (sort keys %cases) {
        my $path = fresh_ledger();
        my $before = read_file($path);
        my $before_mtime = (stat($path))[9];
        my ($rc, $out, $err) = run_pl(['set-test-paths', '--file', $path, '--paths', $cases{$label}]);
        is($rc, 3, "ORACLE-GAP(MAJOR-3,$label): --paths '$cases{$label}' must be REFUSED (exit 3)")
            or diag("stderr: $err");
        is(read_file($path), $before, "ORACLE-GAP(MAJOR-3,$label): file byte-identical (nothing written)");
        is((stat($path))[9], $before_mtime, "ORACLE-GAP(MAJOR-3,$label): mtime unchanged (nothing even opened for write)");
    }
}

# ── AC-7/11: missing --file / --paths, unknown option, trailing positional args ──
{
    my $path = fresh_ledger();
    my ($rc1) = run_pl(['set-test-paths', '--paths', 'a/']);
    is($rc1, 3, 'AC-11: missing --file exits 3');

    my ($rc2) = run_pl(['set-test-paths', '--file', $path]);
    is($rc2, 3, 'AC-11: missing --paths exits 3');

    my ($rc3) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/', '--bogus-opt', 'x']);
    is($rc3, 3, 'AC-11: unknown option exits 3');

    my ($rc4) = run_pl(['set-test-paths', '--file', $path, '--paths', 'a/', 'extra-positional']);
    is($rc4, 3, 'AC-11: trailing positional argument exits 3');
}

done_testing();
