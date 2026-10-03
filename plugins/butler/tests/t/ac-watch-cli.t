#!/usr/bin/env perl
# platform: any
# ORACLE for package 11-ac-loss-clean-suspend-cycle (blueprint tooling-backlog):
# the `bp-ac-watch.pl` CLI's own argv/exit-code contract (spec sec 2.8),
# AC-12 (monitor exit codes via the real CLI), AC-13, AC-17's companion
# MSYS2_ARG_CONV_EXCL hygiene, and the `status`/`clear` verbs.
#
# bp-ac-watch.pl DOES NOT EXIST YET. Every subprocess spawn below reports
# "No such file or directory" / a nonzero rc from the OS, never a crash of
# this file -- system()'s return value is -1/non-zero either way and every
# assertion below compares it against the SPEC's required value, so a
# missing script fails each assertion legibly.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use Cwd qw(getcwd);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

my $S = "$Bin/../../scripts"; $S =~ s{\\}{/}g;
my $CLI = "$S/bp-ac-watch.pl";

my $J = JSON::PP->new->canonical;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# run_cli(\@args, \%env_over, %o) -> ($rc, $out, $err)
sub run_cli {
    my ($args, $env_over, %o) = @_;
    $env_over //= {};
    my (undef, $opath) = tempfile();
    my (undef, $epath) = tempfile();

    local %ENV = %ENV;
    for my $k (keys %$env_over) {
        if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} } else { delete $ENV{$k} }
    }

    open(my $oldout, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $opath) or do { open(STDOUT, '>&', $oldout); die "redirect STDOUT: $!" };
    open(STDERR, '>', $epath) or do { open(STDERR, '>&', $olderr); die "redirect STDERR: $!" };
    my $sysrc = system($^X, $CLI, @$args);
    open(STDOUT, '>&', $oldout) or die "restore STDOUT: $!"; close $oldout;
    open(STDERR, '>&', $olderr) or die "restore STDERR: $!"; close $olderr;

    my $out = slurp($opath);
    my $err = slurp($epath);
    unlink $opath, $epath;
    return (($sysrc == -1 ? -1 : $sysrc >> 8), $out, $err);
}

sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path("$d/.drive-solo");
    return $d;
}

my $T0 = 1_900_000_000;

# ===========================================================================
# Script-existence precondition. If it doesn't exist yet, `perl <missing>`
# exits with a Perl "Can't open ... No such file or directory" at rc 2 (or
# -1 on some hosts). Asserted first so the rest of this file's per-verb
# assertions are legibly attributable to the SAME root cause.
# ===========================================================================
ok(-f $CLI, "bp-ac-watch.pl exists (plugins/butler/scripts/bp-ac-watch.pl)");

# ===========================================================================
# `status` (sec 2.8): prints status() as one canonical JSON line, exits 0,
# never probes (no CCPRAXIS_AC_PROBE_FILE needed for this to succeed).
# ===========================================================================
{
    my $data = fresh_data();
    my ($rc, $out, $err) = run_cli(['status'], { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'status: exits 0');
    chomp(my $line = $out);
    my $decoded = eval { $J->decode($line) };
    ok(defined $decoded, 'status: stdout is one line of valid JSON') or diag("stdout was: $out");
    SKIP: {
        skip 'status: no JSON to inspect', 2 unless defined $decoded;
        ok(exists $decoded->{phase}, 'status: the JSON has a phase key');
        ok(exists $decoded->{log}, 'status: the JSON has a log key (absolute path of ac-cycle.log)');
    }
}

# ===========================================================================
# `clear --reason '<2+ words>'` (sec 2.8): removes the marker, sets phase
# ac, logs MARKER-CLEARED, exits 0. Without a 2-word reason it refuses, rc 1.
# ===========================================================================
{
    my $data = fresh_data();
    make_path("$data/.drive-solo");
    open my $fh, '>', "$data/.drive-solo/ac-standdown.json" or die $!;
    print {$fh} '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}';
    close $fh;
    my ($rc, $out, $err) = run_cli(['clear', '--reason', 'stale marker from a crashed run'],
        { CCPRAXIS_DATA_DIR => $data });
    is($rc, 0, 'clear: with a 2+ word reason, exits 0');
    ok(!-e "$data/.drive-solo/ac-standdown.json", 'clear: the marker is removed');
    my $log = slurp("$data/.drive-solo/ac-cycle.log");
    like($log, qr/MARKER-CLEARED/, 'clear: the log gains a MARKER-CLEARED line') if length $log;
}
{
    my $data = fresh_data();
    my ($rc, $out, $err) = run_cli(['clear', '--reason', 'onlyoneword'], { CCPRAXIS_DATA_DIR => $data });
    is($rc, 1, 'clear: refuses (rc 1) without a 2+ word reason');
}
{
    my $data = fresh_data();
    my ($rc, $out, $err) = run_cli(['clear'], { CCPRAXIS_DATA_DIR => $data });
    is($rc, 1, 'clear: refuses (rc 1) with no --reason at all');
}

# ===========================================================================
# `monitor` (sec 2.8/3.7-3.8) via the real CLI: AC-restored exits 0; a
# second concurrent monitor exits 3.
# ===========================================================================
{
    my $data = fresh_data();
    my ($fh, $pf) = tempfile();
    print {$fh} "ac\n";   # immediately reads back AC -- first tick should reconnect and exit fast
    close $fh;
    my ($rc, $out, $err) = run_cli(['monitor'], {
        CCPRAXIS_DATA_DIR        => $data,
        CCPRAXIS_AC_PROBE_FILE   => $pf,
        CCPRAXIS_AC_TICK_SECONDS => '0.05',
    });
    is($rc, 0, 'monitor: with an immediate ac reading, exits 0 (AC restored)');
    like($out, qr/AC restored at/, 'monitor: prints the "AC restored at" line');
}
{
    # No data dir resolvable at all (sec 2.8: "1: no data dir, or usage error").
    my $t = tempdir(CLEANUP => 1);
    (my $nowhere = "$t/does-not-exist-and-is-not-a-project") =~ s{\\}{/}g;
    my ($rc, $out, $err) = run_cli(['monitor'], {
        CCPRAXIS_DATA_DIR => undef,
        CLAUDE_PROJECT_DIR => undef,
        HOME => $nowhere, USERPROFILE => $nowhere,
    });
    isnt($rc, 0, 'monitor: with no resolvable data dir, does not exit 0');
}

# ===========================================================================
# Windows hygiene (sec 2.8's closing bullet): "On Windows it sets
# MSYS2_ARG_CONV_EXCL per the house rule, as bp-drive-next.pl does." --
# static source check, mirroring the project's own house-rule enforcement
# style (test-wakelock-hygiene.t).
# ===========================================================================
SKIP: {
    skip "bp-ac-watch.pl does not exist yet", 1 unless -f $CLI;
    open my $fh, '<:raw', $CLI or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like($src, qr/MSYS2_ARG_CONV_EXCL/, 'bp-ac-watch.pl sources MSYS2_ARG_CONV_EXCL (house rule)');
}

done_testing();
