#!/usr/bin/env perl
# Oracle for b02-backpack-owns-path — DC3, THE LOAD-BEARING CRITERION.
#
# Spec section 2.3/2.4: writing /etc/profile.d/backpack-path.sh is NOT
# sufficient to close the reinstall loop, because the install pass runs
# every verify/install command through a non-login `bash -c` (run_bash),
# which never sources /etc/profile.d. The fix is `$ENV{PATH}` set
# IN-PROCESS, in the parent backpack.pl process, before the loop begins
# (cmd_install) and again for cmd_audit (no disk write).
#
# THE DISTINGUISHING DESIGN, spelled out because it is the entire point of
# this file: --profile-path below points at a path this test never sources
# and bash never sources either (it isn't /etc/profile.d, it's a tempdir).
# So if an implementation writes the fragment file correctly but never
# touches $ENV{PATH} in the parent process, the confirming `verify` (a bare
# `command -v <name>`, run in a FRESH bash -c child that inherits only the
# unmodified process environment) has no way to find the fake binary and
# MUST fail. Only an implementation that actually augments $ENV{PATH} before
# spawning that child can make this pass. A "wrote the file, forgot the env"
# implementation is red here even though it would be green on a naive test
# that merely inspects the fragment's bytes (see 09-profile-fragment.t,
# which is deliberately silent on this point).
#
# AC7: bare-command install/verify succeeds within a single install pass.
# AC8: re-running install does not re-trigger install (SKIP, not FAIL-retry)
#      -- the reinstall loop itself is closed, not just one pass of it.
# AC9: cmd_audit reports the same item present, with NO --profile-path and
#      NO disk write.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use File::Find qw(find);

my $BP = $ENV{BP_UNDER_TEST} // "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl under test exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}
unless (system('bash -c "command -v true" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash lacks command -v on this host';
}

my $dir = tempdir(CLEANUP => 1);

sub write_backpack {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh encode_json({ version => 2, items => \@items });
    close $fh;
}

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
    close $fh;
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc);
}

sub snapshot_files {
    my ($root) = @_;
    my @found;
    find(sub { push @found, $File::Find::name if -f $_ }, $root) if -d $root;
    return { map { $_ => 1 } @found };
}

# ---------------------------------------------------------------------------
# Fixture: a bin dir that is NOT already on this test process's own PATH
# (unique per-PID name so no real command could ever collide with it), and
# an item whose install/verify use ONLY a bare command name -- no absolute
# path anywhere, no hand-rolled `export PATH=...` preamble. This is exactly
# the shape a migrated project-setup:gh-auth-style entry has after DC2.
# ---------------------------------------------------------------------------
my $bindir  = "$dir/oracle-bin";
mkdir $bindir or die "mkdir $bindir: $!";
my $binname = "bp-oracle-fake-$$";

my $item = {
    category => 'other',
    name     => 'fakebin',
    install  => "printf '#!/bin/sh\\necho ok\\n' > '$bindir/$binname' && chmod +x '$bindir/$binname'",
    verify   => "command -v $binname >/dev/null 2>&1",
    bin_dirs => [$bindir],
    rationale => 'b02 DC3/AC9 oracle fixture -- migrated shape, bare command only',
};

my $set     = "$dir/loop-set.json";
my $profile = "$dir/never-sourced/backpack-path.sh";   # deliberately NOT /etc/profile.d
write_backpack($set, $item);

ok(!-f "$bindir/$binname", 'precondition: the fake binary does not exist before any install run');

# ===========================================================================
# AC7 -- first pass: verify fails (nothing installed yet), install runs,
# the CONFIRMING verify (same pass, bare command) succeeds.
# ===========================================================================
my ($out1, $rc1) = run_bp('install', $set, '--profile-path', $profile);

# Gate: "unlike FAIL" below would trivially PASS if the whole install pass
# aborted at option-parsing (e.g. --profile-path not yet recognized) before
# ever reaching the per-item loop -- no FAIL line would appear either way,
# for the wrong reason entirely. Require positive evidence the loop actually
# ran on this item (ANY disposition line for it) before trusting the
# negative assertion.
my $loop1_ran = $out1 =~ /^(?:INSTALL|SKIP|OK|FAIL): other:fakebin/m;
ok($loop1_ran,
    'AC7 precondition: the install pass reached the per-item loop for other:fakebin '
    . '(not an early option-parse abort -- e.g. an unrecognized --profile-path flag)')
    or diag($out1);

if ($loop1_ran) {
    like($out1, qr/^INSTALL: other:fakebin$/m,
        'AC7: the first verify (nothing installed yet) failed, so install ran') or diag($out1);
    unlike($out1, qr/^FAIL: other:fakebin/m,
        'AC7: the confirming verify did NOT fail -- this is the load-bearing assertion. '
        . 'If this line is present, $ENV{PATH} was not augmented in-process before the '
        . 'confirming verify ran, and the reinstall loop this package exists to close is '
        . 'still open') or diag($out1);
    like($out1, qr/^OK: other:fakebin$/m,
        'AC7: the confirming verify (bare `command -v`, no absolute path) succeeded within '
        . 'the SAME install pass') or diag($out1);
} else {
    fail('AC7: first-verify-failed check skipped -- the loop never ran');
    fail('AC7: confirming-verify-did-not-fail check skipped -- the loop never ran');
    fail('AC7: confirming-verify-succeeded check skipped -- the loop never ran');
}
is($rc1, 0, 'AC7: the pass exits 0') or diag($out1);
ok(-f "$bindir/$binname", 'AC7: the fake binary now exists on disk (install actually ran)');

# ===========================================================================
# AC8 -- re-running install does not re-trigger install: SKIP, not another
# FAIL-then-retry. The reinstall loop is closed, not just one lucky pass.
# ===========================================================================
my ($out2, $rc2) = run_bp('install', $set, '--profile-path', $profile);

my $loop2_ran = $out2 =~ /^(?:INSTALL|SKIP|OK|FAIL): other:fakebin/m;
ok($loop2_ran,
    'AC8 precondition: the second install pass also reached the per-item loop')
    or diag($out2);

if ($loop2_ran) {
    like($out2, qr/^SKIP: other:fakebin \(already present\)$/m,
        'AC8: re-running install SKIPs the item -- the first verify (bare command, fresh bash '
        . 'child) now succeeds on its own, proving the in-process PATH is applied on EVERY run, '
        . 'not just the one that happened to install') or diag($out2);
    unlike($out2, qr/^INSTALL: other:fakebin$/m,
        'AC8: install is NOT re-triggered on the second pass') or diag($out2);
    unlike($out2, qr/^FAIL: other:fakebin/m,
        'AC8: no FAIL line on the second pass either') or diag($out2);
} else {
    fail('AC8: SKIP-on-rerun check skipped -- the loop never ran');
    fail('AC8: no-reinstall check skipped -- the loop never ran');
    fail('AC8: no-FAIL check skipped -- the loop never ran');
}
is($rc2, 0, 'AC8: the second pass exits 0') or diag($out2);

# ===========================================================================
# AC9 -- cmd_audit reports the same item present, with NO --profile-path
# flag (audit doesn't take one) and NO disk write anywhere.
# ===========================================================================
my $before = snapshot_files($dir);
my ($out3, $rc3) = run_bp('audit', $set);
my $after  = snapshot_files($dir);

is_deeply($after, $before,
    'AC9: cmd_audit creates NO new file anywhere under the fixture tree (read-only by design)');
unlike($out3, qr/^PROFILE_PATH:/m,
    'AC9: audit never emits a PROFILE_PATH line (it has no --profile-path flag at all)') or diag($out3);
like($out3, qr/^GONE: 0$/m,
    'AC9: audit reports GONE: 0 -- the migrated, bare-command item is NOT falsely reported gone')
    or diag($out3);
like($out3, qr/verify ok/,
    'AC9: the item\'s detail line says "verify ok"') or diag($out3);
unlike($out3, qr/verify FAILED/,
    'AC9: the item\'s detail line does NOT say "verify FAILED"') or diag($out3);

done_testing();
