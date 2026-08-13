#!/usr/bin/env perl
# Oracle for b02-backpack-owns-path — DC1, `cmd_install --profile-path`.
# Spec section 2.3. This file NEVER writes to a real /etc/profile.d — every
# case below uses --profile-path pointed at a File::Temp tempdir, exactly as
# the spec says the flag exists for.
#
# AC3: fragment contains the floor + declared bin_dirs, deduped, floor-then-
#      file order; PATHDIRS emitted.
# AC4: byte-identical fragment across two unchanged consecutive runs.
# AC5: removing a bin_dirs entry between runs removes its dir from the next
#      fragment (no accumulation).
# AC6: an unwritable --profile-path degrades to a non-fatal WARNING; exit
#      code is governed solely by item outcomes.
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

sub slurp {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
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
# AC3 — floor + declared bin_dirs, deduped, floor-then-file order; PATHDIRS.
# Uses a bin dir that is NOT one of the three hardcoded directories named in
# the spec's Context section (/opt/tools/bin, /opt/tools/flutter/bin,
# /opt/tools/google-cloud-sdk/bin) -- /opt/tools/custom-thing/bin -- so an
# implementation that hardcodes the three known directories instead of
# deriving from bin_dirs fails this case even though it might pass a naive
# test built only from the spec's own example dirs.
# ===========================================================================
{
    my $set   = "$dir/ac3-set.json";
    my $profile = "$dir/ac3/backpack-path.sh";
    write_backpack($set,
        item('a', bin_dirs => ['/opt/tools/custom-thing/bin']),
        item('b'),   # no bin_dirs at all -- contributes nothing beyond the floor
    );

    my ($out, $rc) = run_bp('install', $set, '--profile-path', $profile);
    is($rc, 0, 'AC3: install with a clean bin_dirs set exits 0') or diag($out);

    my $content = slurp($profile);
    if (ok(defined $content, 'AC3: the profile fragment file was created')) {
        like($content, qr{^export PATH="/opt/tools/bin:/opt/tools/custom-thing/bin:\$PATH"$}m,
            'AC3: fragment line is floor-then-declared, exact dedup order, no hardcoded flutter/gcloud dirs')
            or diag($content);
    } else {
        fail('AC3: fragment content check skipped -- no file was written');
    }
    like($out, qr/^PROFILE_PATH: \Q$profile\E$/m, 'AC3: PROFILE_PATH is emitted with the given path')
        or diag($out);
    like($out, qr/^PATHDIRS: 2$/m, 'AC3: PATHDIRS counts floor + the one declared dir (2)') or diag($out);
}

# ---------------------------------------------------------------------------
# AC3 (behavior 5) -- two items declaring the SAME dir as the floor: no
# duplicate, no warning.
# ---------------------------------------------------------------------------
{
    my $set   = "$dir/ac3-dup-set.json";
    my $profile = "$dir/ac3-dup/backpack-path.sh";
    write_backpack($set,
        item('a', bin_dirs => ['/opt/tools/bin']),
        item('b', bin_dirs => ['/opt/tools/bin']),
    );

    my ($out, $rc) = run_bp('install', $set, '--profile-path', $profile);
    is($rc, 0, 'AC3dup: install exits 0') or diag($out);
    my $content = slurp($profile);
    if (ok(defined $content, 'AC3dup: the profile fragment file was created')) {
        my $count = () = ($content =~ m{/opt/tools/bin}g);
        is($count, 1, 'AC3dup: /opt/tools/bin appears exactly once in the fragment (dedup, incl. the floor)')
            or diag($content);
    } else {
        fail('AC3dup: dedup-count check skipped -- no file was written');
    }
    unlike($out, qr/warn/i, 'AC3dup: no warning is printed for a redundant dedup') or diag($out);
    like($out, qr/^PATHDIRS: 1$/m, 'AC3dup: PATHDIRS counts the deduped total (1), not 2') or diag($out);
}

# ===========================================================================
# AC4 — byte-identical fragment across two unchanged consecutive runs.
# ===========================================================================
{
    my $set   = "$dir/ac4-set.json";
    my $profile = "$dir/ac4/backpack-path.sh";
    write_backpack($set, item('a', bin_dirs => ['/opt/tools/flutter/bin']));

    my ($out1, $rc1) = run_bp('install', $set, '--profile-path', $profile);
    is($rc1, 0, 'AC4: first run exits 0') or diag($out1);
    my $first = slurp($profile);
    my $first_ok = ok(defined $first, 'AC4: fragment exists after first run');

    my ($out2, $rc2) = run_bp('install', $set, '--profile-path', $profile);
    is($rc2, 0, 'AC4: second run exits 0') or diag($out2);
    my $second = slurp($profile);

    # Guarded explicitly: Test::More's is() treats undef==undef as a PASS,
    # which would let "neither run ever wrote a file" masquerade as
    # byte-identical. Both sides must be independently confirmed present.
    if ($first_ok && ok(defined $second, 'AC4: fragment exists after second run')) {
        is($second, $first, 'AC4: the fragment is byte-identical across two unchanged consecutive runs');
    } else {
        fail('AC4: byte-identical check skipped/failed -- at least one run wrote no file');
    }
}

# ===========================================================================
# AC5 — removing a bin_dirs entry between runs removes its dir from the next
# fragment. No accumulation.
# ===========================================================================
{
    my $set1  = "$dir/ac5-set1.json";
    my $set2  = "$dir/ac5-set2.json";
    my $profile = "$dir/ac5/backpack-path.sh";

    write_backpack($set1, item('a', bin_dirs => ['/opt/tools/flutter/bin']));
    my ($out1, $rc1) = run_bp('install', $set1, '--profile-path', $profile);
    is($rc1, 0, 'AC5: first run (with bin_dirs) exits 0') or diag($out1);
    my $first = slurp($profile);
    my $first_had_dir = defined($first) && $first =~ m{/opt/tools/flutter/bin};
    ok($first_had_dir, 'AC5: first fragment contains the declared dir') or diag($first // '(no file)');

    write_backpack($set2, item('a'));   # same item, bin_dirs REMOVED
    my ($out2, $rc2) = run_bp('install', $set2, '--profile-path', $profile);
    is($rc2, 0, 'AC5: second run (bin_dirs removed) exits 0') or diag($out2);
    my $second = slurp($profile);

    # Guarded: unlike(undef, ...) would trivially "pass" if the second run
    # wrote no file at all, masking exactly the case AC5 exists to catch.
    # Require BOTH that the first run's dir was really seen AND the second
    # file really exists before trusting the negative assertion.
    if ($first_had_dir && ok(defined $second, 'AC5: second fragment file exists')) {
        unlike($second, qr{/opt/tools/flutter/bin},
            'AC5: the second fragment no longer contains the removed dir (no accumulation)')
            or diag($second);
        like($second, qr{/opt/tools/bin}, 'AC5: the floor dir is still present') or diag($second);
    } else {
        fail('AC5: no-accumulation check skipped -- precondition (first run had the dir, second file exists) unmet');
        fail('AC5: floor-still-present check skipped -- same precondition unmet');
    }
}

# ===========================================================================
# AC6 — an unwritable --profile-path degrades to a non-fatal WARNING; exit
# code is governed solely by item outcomes (unchanged from b01).
# ===========================================================================
{
    my $set = "$dir/ac6-set.json";
    write_backpack($set, item('p'));   # trivially-idempotent -> SKIP path, exit 0

    # A regular FILE where a directory is expected: --profile-path points
    # UNDER a path that is itself a plain file, so make_path (or an
    # equivalent mkdir) must fail.
    my $blocker = "$dir/ac6-blocker-file";
    open my $fh, '>', $blocker or die $!;
    print $fh "not a directory\n";
    close $fh;
    my $unwritable_profile = "$blocker/backpack-path.sh";

    my ($out, $rc) = run_bp('install', $set, '--profile-path', $unwritable_profile);
    is($rc, 0, 'AC6: an unwritable --profile-path does not change the exit code (still item-governed, 0 here)')
        or diag($out);
    like($out, qr/WARNING: could not write profile fragment \(\Q$unwritable_profile\E\)/,
        'AC6: a non-fatal WARNING is printed naming the intended path') or diag($out);
    ok(!-f $unwritable_profile, 'AC6: no fragment file exists at the unwritable location');
    like($out, qr/^SKIP: other:p /m, 'AC6: the item itself still processes normally despite the write failure')
        or diag($out);
}

done_testing();
