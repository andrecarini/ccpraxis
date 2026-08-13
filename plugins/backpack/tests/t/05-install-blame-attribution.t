#!/usr/bin/env perl
# ORACLE for b01-backpack-install-accounting criterion 5 (spec section 2.4,
# case 8 of spec section 3), written BLIND to any implementation. Reproduces
# the incident's actual misattribution shape: `project-setup:gh-auth` fails
# exit 127 BECAUSE `gh` was never installed, but at HEAD the only signal a
# reader sees is gh-auth's own FAIL line -- nothing at all names `gh`.
#
# Uses the same --declared reconciliation interface as
# 03-install-declared-reconciliation.t (see that file's header for why this
# specific CLI shape was chosen: launcher.pl can never be executed by this
# suite, so backpack.pl's CLI is the only testable home for the declared-vs-
# processed comparison the "N never reached install" peer fact needs).
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
    close $fh;   # reaps the child; sets $? -- do NOT waitpid again afterward (that would
                 # reap a nonexistent process and clobber $? with an undefined value)
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc, $timed_out);
}

# ---------------------------------------------------------------------------
# Case 8 (spec section 3 #8): an exit-127 failure whose dependency never
# installed surfaces the missing dependency, AND the "N never reached
# install" fact is present as a PEER fact (not a footnote beneath the FAIL
# line -- an un-indented line of its own, per spec section 2.4).
#
# Fixture mirrors the incident exactly: `curl-script:gh` is DECLARED but
# never made it into the install-set (the silent upstream drop); `gh-auth`
# depends_on gh and its install command invokes a binary that genuinely does
# not exist on this host, reproducing the real exit-127 signature (rather
# than asserting an exact code some other tool coincidentally also returns).
# ---------------------------------------------------------------------------
{
    my $gh = { category => 'curl-script', name => 'gh', install => 'true', verify => 'true' };
    my $ghauth = {
        category   => 'project-setup', name => 'gh-auth',
        install    => '__no_such_bin_zzzqqq127__ auth status',
        verify     => 'false',
        depends_on => [ 'curl-script:gh' ],
    };

    my $declared_path = "$dir/blame-declared.json";
    my $set_path       = "$dir/blame-set.json";
    write_backpack($declared_path, $gh, $ghauth);
    write_backpack($set_path,      $ghauth);          # gh silently absent from the subset, exactly like the incident

    my ($out, $rc, $timed_out) = run_bp('install', $set_path, '--declared', $declared_path);
    ok(!$timed_out, 'blame: install terminates');
    isnt($rc, 0, 'blame: install exits non-zero (gh-auth genuinely fails)') or diag("  got:\n$out");

    like($out, qr/FAIL: project-setup:gh-auth.*exited 127/,
        'blame: the symptom -- gh-auth still gets its normal FAIL line, exit 127');

    like($out, qr/curl-script:gh/,
        'blame: the output names the missing dependency (curl-script:gh) — the real cause')
        or diag("  got:\n$out");
    like($out, qr/missing dependenc/i,
        'blame: the missing-dependency callout is explicit, not merely coincidental substring match')
        or diag("  got:\n$out");

    # The peer fact: "N declared items never reached install" -- and it must
    # NOT be indented under the FAIL block (spec: "a peer fact ... not a
    # footnote beneath it"). backpack.pl's own indented FAIL sub-lines start
    # with 6 spaces (see :458,475 "      install:"/"      verify:"); a peer
    # fact must start at column 0.
    like($out, qr/^\S.*\b1\b.*never reached install/mi,
        'blame: "1 ... never reached install" appears as an un-indented, top-level peer fact')
        or diag("  got:\n$out");
}

done_testing();
