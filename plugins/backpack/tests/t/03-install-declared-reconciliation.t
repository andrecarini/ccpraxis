#!/usr/bin/env perl
# ORACLE for b01-backpack-install-accounting criteria 2/3 (spec section 2.1/
# 2.2, cases 1/2/3 of spec section 3), written BLIND to any implementation --
# backpack.pl at HEAD has no --declared flag, no ABSENT disposition, and no
# RECONCILE line at all. Do NOT weaken these assertions to make a future
# implementation's life easier.
#
# DESIGN COMMITMENT (documented so a reviewer can tell a deliberate interface
# choice from an accidental pin): the spec explicitly leaves open whether the
# fix lands in launcher.pl or is "passed into backpack.pl explicitly"
# (spec section 2.1). launcher.pl builds/starts containers and this suite is
# forbidden from ever executing it, so the only executable, black-box-testable
# home for this behavior is backpack.pl's CLI. This file therefore commits to
# ONE concrete shape for that explicit hand-off:
#
#   backpack.pl install <install-set-path> --declared <declared-backpack-path>
#
# emitting (in addition to the existing PATH/ITEMS/INSTALLED/SKIPPED/FAILED
# lines): `DECLARED: N`, one `ABSENT: category:name (declared, not in
# install-set)` line per declared item absent from the handed install-set,
# and a `RECONCILE: OK` / `RECONCILE: MISMATCH` line. Omitting --declared
# must leave today's behavior byte-for-byte unchanged (criterion 7's
# backward-compatibility property, exercised again here for this specific
# flag).
#
# THE NON-VACUITY DISCIPLINE THIS FILE EXISTS TO ENFORCE: reconciling inside
# backpack.pl against the HANDED file's own item count is a structural
# identity (INSTALLED+SKIPPED+FAILED == the handed ITEMS, always, by
# construction -- see backpack.pl:437,441-483). A reconciliation that only
# ever compares declared==processed can never distinguish a real check from
# that identity. Case 2 below is the one assertion that tells them apart: it
# constructs declared != processed and requires the check to FIRE.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $BP = "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

# item($name) -> a trivially-idempotent item (verify already true -> SKIP
# path, never touches the filesystem) so these tests are fast and immune to
# host tool availability.
sub item {
    my ($name) = @_;
    return { category => 'other', name => $name, install => 'true', verify => 'true' };
}

sub write_backpack {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh encode_json({ version => 2, items => \@items });
    close $fh;
}

# run_bp(@args) -> ($combined_out, $rc) -- bounded to 20s so a future
# reconciliation bug (e.g. an infinite retry loop) cannot hang this suite.
# Same pattern as backpack.pl's own diagnose_verify(): pipe-open + alarm +
# hard SIGKILL on timeout.
sub run_bp {
    my (@args) = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null');
        open(STDERR, '>&', \*STDOUT);
        exec($^X, $BP, @args);
        CORE::exit(127);
    }
    my @lines;
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        @lines = <$fh>;
        alarm 0;
    };
    if ($@) { $timed_out = 1; kill 'KILL', $pid; }
    alarm 0;
    close $fh;   # reaps the child; sets $? -- do NOT waitpid again afterward (that would
                 # reap a nonexistent process and clobber $? with an undefined value)
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc);
}

# ---------------------------------------------------------------------------
# Case 1 (spec section 3 #1): every declared item yields exactly one
# disposition line, including one declared-but-absent-from-the-install-set
# item, which must be reported, not silent.
# ---------------------------------------------------------------------------
{
    my $declared_path = "$dir/case1-declared.json";
    my $set_path       = "$dir/case1-set.json";
    write_backpack($declared_path, item('a'), item('b'), item('c'));
    write_backpack($set_path,       item('a'), item('b'));   # 'c' is declared but never made it into the subset

    my ($out, $rc) = run_bp('install', $set_path, '--declared', $declared_path);

    like($out, qr/^DECLARED: 3$/m, 'case1: DECLARED reports the full declared count (3), not the subset (2)');
    like($out, qr/^ABSENT: other:c \(declared, not in install-set\)$/m,
        'case1: the declared-but-absent item gets a loud disposition line, not silence');

    my @disposition_lines = ($out =~ /^(?:INSTALL|SKIP|OK|FAIL|ABSENT): /mg);
    is(scalar(@disposition_lines), 3,
        'case1: exactly one disposition line per DECLARED item (3), not per install-set item (2)')
        or diag("  got:\n$out");
}

# ---------------------------------------------------------------------------
# Case 2 (spec section 3 #2): NON-VACUITY. declared != processed must make
# the reconciliation FIRE. This is the assertion the whole package exists
# for -- see the file header.
# ---------------------------------------------------------------------------
{
    my $declared_path = "$dir/case2-declared.json";
    my $set_path       = "$dir/case2-set.json";
    write_backpack($declared_path, item('x'), item('y'), item('z'));
    write_backpack($set_path,       item('x'), item('y'));   # 'z' dropped upstream -- declared(3) != processed(2)

    my ($out, $rc) = run_bp('install', $set_path, '--declared', $declared_path);

    like($out, qr/^RECONCILE: MISMATCH$/m,
        'case2 (NON-VACUITY): declared(3) != processed(2) makes the reconciliation FIRE with MISMATCH')
        or diag("  got:\n$out");
    unlike($out, qr/^RECONCILE: OK$/m,
        'case2: a real mismatch must never also claim OK');
}

# ---------------------------------------------------------------------------
# Case 3 (spec section 3 #3): no false alarm when declared == processed.
# ---------------------------------------------------------------------------
{
    my $declared_path = "$dir/case3-declared.json";
    my $set_path       = "$dir/case3-set.json";
    write_backpack($declared_path, item('p'), item('q'));
    write_backpack($set_path,       item('p'), item('q'));   # identical sets

    my ($out, $rc) = run_bp('install', $set_path, '--declared', $declared_path);

    like($out, qr/^RECONCILE: OK$/m,
        'case3: declared(2) == processed(2) reconciles OK -- no false alarm')
        or diag("  got:\n$out");
    unlike($out, qr/^ABSENT: /m, 'case3: no ABSENT lines when nothing is actually absent');
}

# ---------------------------------------------------------------------------
# Backward compatibility for THIS flag specifically: omitting --declared must
# reproduce today's exact output (no DECLARED/RECONCILE/ABSENT lines at all).
# (Criterion 7's broader depends_on backward-compat gets its own file/test;
# this is the --declared-flag-specific slice of it.)
# ---------------------------------------------------------------------------
{
    my $set_path = "$dir/bc-set.json";
    write_backpack($set_path, item('m'));
    my ($out, $rc) = run_bp('install', $set_path);

    unlike($out, qr/^DECLARED: /m,  'backward-compat: no DECLARED line when --declared is omitted');
    unlike($out, qr/^RECONCILE: /m, 'backward-compat: no RECONCILE line when --declared is omitted');
    unlike($out, qr/^ABSENT: /m,    'backward-compat: no ABSENT line when --declared is omitted');
    is($rc, 0, 'backward-compat: install without --declared still exits 0 on an all-SKIP run');
}

done_testing();
