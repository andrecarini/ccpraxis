#!/usr/bin/env perl
# Oracle for b02-backpack-owns-path — fix-batch step7 regressions.
#
# Covers the findings the step6 red-team/reviewer surfaced that survived to
# the fix-batch:
#   CRITICAL-1: an unconstrained bin_dirs entry (any absolute directory) rode
#     into the PERSISTENT profile fragment, ahead of $PATH, for the whole
#     container's life -- invisible to both the approval-hash gate and the
#     human review screen (neither of which is in this write set). Fix:
#     constrain to the backpack's own install root (dirname of the floor
#     dir, i.e. /opt/tools).
#   CRITICAL-2: a single shared aggregate PATH let one item's bin_dirs
#     binary make an UNRELATED, never-installed item falsely report itself
#     present. Fix: PATH is scoped per item (floor + that item's own
#     bin_dirs only), both in cmd_install's loop and cmd_audit.
#   MEDIUM: bin_dirs entries had no length cap, and (for the NEW root check
#     specifically) a single bad entry must not abort the whole pass with
#     zero per-item output.
#   LOW: a null bin_dirs entry silently passed validation and produced an
#     empty PATH segment in the fragment (a POSIX shell reads "" as ".").
#
# See the fix-batch report for why the root-containment check does NOT
# change cmd_install's exit code (0/1/2 stay exactly as b01/b02 defined
# them) and instead surfaces via REJECTED lines + a BIN_DIRS_REJECTED
# count: t/10-reinstall-loop.t's oracle fixture legitimately declares a
# bin_dirs directory OUTSIDE /opt/tools (a tempdir, standing in for
# wherever a real item's own install actually lands binaries), and that
# fixture's per-item PATH scope (used to run ITS OWN verify/install) is
# deliberately root-UNFILTERED -- only the persisted fragment is filtered.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $BP = $ENV{BP_UNDER_TEST} // "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl under test exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

sub item {
    my ($name, %extra) = @_;
    return { category => 'other', name => $name, install => 'true', verify => 'true', %extra };
}

sub write_backpack {
    my ($path, @items) = @_;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh encode_json({ version => 2, items => \@items });
    close $fh;
}

sub slurp_or_undef {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
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

# ===========================================================================
# 1 -- a bin_dirs entry outside the install root is rejected by `add`
#      (the authoring path), including a '..'-escape that normalises out of
#      the root even though it passes a naive string-prefix check.
# ===========================================================================
{
    my $path = "$dir/root1.json";
    my ($out, $rc) = run_bp('add', $path,
        '--category', 'other', '--name', 'x',
        '--install', 'true', '--verify', 'true',
        '--bin_dirs', '/tmp/attacker-writable');
    isnt($rc, 0, 'root-1a: add with a bin_dirs entry outside /opt/tools fails') or diag($out);
    ok(index(lc($out), 'bin_dirs') >= 0, 'root-1a: the failure message names bin_dirs') or diag($out);
    ok(!-f $path, 'root-1a: no file was created by the rejected add');
}
{
    my $path = "$dir/root1b.json";
    my ($out, $rc) = run_bp('add', $path,
        '--category', 'other', '--name', 'x',
        '--install', 'true', '--verify', 'true',
        '--bin_dirs', '/opt/tools/../../etc/x');
    isnt($rc, 0, 'root-1b: a lexical ..-escape that normalises OUTSIDE /opt/tools is rejected '
        . '(not just a raw string-prefix check)') or diag($out);
    ok(index(lc($out), 'bin_dirs') >= 0, 'root-1b: the failure message names bin_dirs') or diag($out);
}
{
    # Negative-space: a well-formed, IN-root entry must still be accepted --
    # keeps 1a/1b from being satisfiable by an implementation that just
    # rejects everything bin_dirs-shaped.
    my $path = "$dir/root1c.json";
    my ($out, $rc) = run_bp('add', $path,
        '--category', 'other', '--name', 'x',
        '--install', 'true', '--verify', 'true',
        '--bin_dirs', '/opt/tools/flutter/bin');
    is($rc, 0, 'root-1c: an in-root bin_dirs entry is accepted by add') or diag($out);
}

# ===========================================================================
# 2 -- null / empty / whitespace-only bin_dirs entries are rejected, and no
#      empty PATH segment ever reaches the generated fragment.
# ===========================================================================
{
    my $path = "$dir/null2.json";
    open my $fh, '>:raw', $path or die $!;
    # Hand-crafted JSON: JSON::PP has no way to encode a bare undef inside an
    # array element from Perl data cleanly for this purpose, so the raw JSON
    # is written directly -- this is exactly the "hand-edited/synced file"
    # shape the red-team's threat model describes.
    print $fh '{"version":2,"items":[{"category":"other","name":"a","install":"true","verify":"true","bin_dirs":["/opt/tools/x",null]}]}';
    close $fh;
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, '2a: a null bin_dirs entry -> STATUS: invalid') or diag($out);
    isnt($rc, 0, '2a: a null bin_dirs entry -> nonzero exit');
    ok(index($out, 'bin_dirs entry') >= 0 && index($out, 'null') >= 0,
        '2a: the error names bin_dirs and calls out the null') or diag($out);
}
{
    my $path = "$dir/empty2.json";
    write_backpack($path, item('a', bin_dirs => ['/opt/tools/x', '   ']));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, '2b: a whitespace-only bin_dirs entry -> STATUS: invalid') or diag($out);
    isnt($rc, 0, '2b: nonzero exit');
}
{
    my $path = "$dir/empty2c.json";
    write_backpack($path, item('a', bin_dirs => ['/opt/tools/x', '']));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, '2c: an empty-string bin_dirs entry -> STATUS: invalid') or diag($out);
    isnt($rc, 0, '2c: nonzero exit');
}
{
    # Positive-space: a normal, all-valid multi-entry install never produces
    # an empty PATH segment in the fragment -- no "::" anywhere, and the
    # quoted value neither starts nor ends with a bare ':' immediately
    # inside the quotes.
    my $set     = "$dir/frag-clean-set.json";
    my $profile = "$dir/frag-clean/backpack-path.sh";
    write_backpack($set,
        item('a', bin_dirs => ['/opt/tools/flutter/bin']),
        item('b', bin_dirs => ['/opt/tools/google-cloud-sdk/bin']),
    );
    my ($out, $rc) = run_bp('install', $set, '--profile-path', $profile);
    is($rc, 0, '2d: a clean multi-item install exits 0') or diag($out);
    my $content = slurp_or_undef($profile);
    if (ok(defined $content, '2d: the fragment was written')) {
        unlike($content, qr/::/, '2d: the fragment contains no empty PATH segment ("::")') or diag($content);
        unlike($content, qr/PATH="\s*:/, '2d: the quoted PATH value does not start with a bare \':\'') or diag($content);
    } else {
        fail('2d: no-empty-segment checks skipped -- no fragment written');
    }
}

# ===========================================================================
# 3 -- CRITICAL-2: one item's bin_dirs does NOT make a DIFFERENT,
#      never-installed item report itself present (neither `install` nor
#      `audit`).
# ===========================================================================
{
    my $sharedname = "bp-crit2-shared-$$";
    my $bindir = "$dir/crit2-bin";
    mkdir $bindir or die $!;

    my $toolA = item('toolA',
        install  => "mkdir -p '$bindir' && printf '#!/bin/sh\\nexit 0\\n' > '$bindir/$sharedname' && chmod +x '$bindir/$sharedname'",
        verify   => "command -v $sharedname >/dev/null 2>&1",
        bin_dirs => [$bindir],
    );
    my $toolB = item('toolB-never-installed',
        install => 'false',   # would fail loudly if actually invoked
        verify  => "command -v $sharedname >/dev/null 2>&1",
        # NO bin_dirs of its own.
    );

    my $set     = "$dir/crit2-set.json";
    my $profile = "$dir/crit2/backpack-path.sh";
    write_backpack($set, $toolA, $toolB);

    my ($out, $rc) = run_bp('install', $set, '--profile-path', $profile);
    like($out, qr/^INSTALL: other:toolA$/m, '3a: toolA installs (its own verify legitimately fails first)') or diag($out);
    like($out, qr/^OK: other:toolA$/m, '3a: toolA confirms OK via its OWN bin_dirs scope') or diag($out);
    unlike($out, qr/^SKIP: other:toolB-never-installed/m,
        "3a: toolB is NOT falsely SKIPped just because toolA's bin_dirs binary matches its verify command name")
        or diag($out);
    like($out, qr/^INSTALL: other:toolB-never-installed$/m,
        '3a: toolB genuinely attempts install (its own scope, floor only, does not see toolA\'s binary)')
        or diag($out);
    like($out, qr/^FAIL: other:toolB-never-installed/m,
        '3a: toolB genuinely FAILs (its install is `false`) -- the real, honest outcome, not a silent false-present')
        or diag($out);

    # Same fixture, via `audit` (no install step -- toolA's binary already
    # exists on disk from the run above).
    my ($out2, $rc2) = run_bp('audit', $set);
    like($out2, qr/other:toolA - verify ok/, '3b: audit still finds toolA present (its own scope)') or diag($out2);
    like($out2, qr/other:toolB-never-installed - verify FAILED/,
        '3b: audit correctly reports toolB as GONE -- not falsely "verify ok" via toolA\'s bin_dirs') or diag($out2);
    like($out2, qr/^GONE: 1$/m, '3b: audit\'s GONE count is 1 (toolB), not 0') or diag($out2);
}

# ===========================================================================
# 4 -- an over-long bin_dirs entry is rejected.
# ===========================================================================
{
    my $huge = '/opt/tools/' . ('x' x 2000);
    my $path = "$dir/long4.json";
    write_backpack($path, item('a', bin_dirs => [$huge]));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: invalid$/m, '4a: an over-long bin_dirs entry -> STATUS: invalid') or diag($out);
    isnt($rc, 0, '4a: nonzero exit');
    ok(index($out, 'exceeds maximum length') >= 0,
        '4a: the error names the length-cap rule') or diag($out);
}
{
    # Negative-space: an ordinary-length entry is unaffected.
    my $path = "$dir/long4b.json";
    write_backpack($path, item('a', bin_dirs => ['/opt/tools/flutter/bin']));
    my ($out, $rc) = run_bp('validate', $path);
    like($out, qr/^STATUS: ok$/m, '4b: a normal-length entry still validates clean') or diag($out);
}

# ===========================================================================
# 5 -- one bad (out-of-root) bin_dirs entry does not abort the whole install
#      pass -- the other items still get their own per-item disposition
#      lines, and the offending item's bin_dirs is named in a REJECTED line
#      rather than silently dropped or aborting everything.
# ===========================================================================
{
    my $good1 = item('good1');
    my $bad   = item('bad-bindirs', bin_dirs => ['/tmp/outside-root']);
    my $good2 = item('good2');

    my $set     = "$dir/mixed5-set.json";
    my $profile = "$dir/mixed5/backpack-path.sh";
    write_backpack($set, $good1, $bad, $good2);

    my ($out, $rc) = run_bp('install', $set, '--profile-path', $profile);
    like($out, qr/^SKIP: other:good1 \(already present\)$/m,
        '5a: good1 still gets its own disposition line -- the pass was NOT aborted') or diag($out);
    like($out, qr/^SKIP: other:good2 \(already present\)$/m,
        '5a: good2 (which comes AFTER the bad item in file order) still gets processed too') or diag($out);
    like($out, qr/^SKIP: other:bad-bindirs \(already present\)$/m,
        '5a: the offending item itself still installs/verifies normally (its own scope is unaffected)')
        or diag($out);
    like($out, qr/^REJECTED: other:bad-bindirs bin_dirs entry '\/tmp\/outside-root' is outside the install root/m,
        '5a: a REJECTED line names the item and the offending directory') or diag($out);
    like($out, qr/^BIN_DIRS_REJECTED: 1$/m, '5a: BIN_DIRS_REJECTED counts exactly the one rejected entry') or diag($out);

    my $content = slurp_or_undef($profile);
    if (ok(defined $content, '5a: the fragment was still written despite the rejection')) {
        unlike($content, qr{/tmp/outside-root}, '5a: the rejected directory is EXCLUDED from the persisted fragment')
            or diag($content);
    } else {
        fail('5a: fragment-exclusion check skipped -- no fragment written');
    }
    is($rc, 0, '5a: the pass still exits 0 (all items genuinely SKIP/OK; a rejection alone does not '
        . 'change the exit code -- see the fix-batch report for why, vs. t/10\'s legitimately '
        . 'out-of-root DC3 fixture)') or diag($out);
}

done_testing();
