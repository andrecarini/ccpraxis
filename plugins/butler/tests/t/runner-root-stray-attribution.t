#!/usr/bin/env perl
# platform: any
# The post-sweep audit names WHICH test files were running when a stray appeared at the repo root.
#
# A PowerShell ModuleAnalysisCache (Microsoft/Windows/PowerShell/...) appeared at the ccpraxis repo
# root during two full sweeps (2026-09-26, 2026-10-21). The audit caught the second one but could
# only say that a path was new, and no single-file rerun has reproduced it since. run-tests.pl now
# lists the repo root after every test file exits and records each new top-level entry with the
# files in flight at that moment, so the next occurrence names its candidates.
#
# Drives a COPY of the real scripts/run-tests.pl in a throwaway git repo (the runner-nested-audit.t
# pattern): one fixture plants a directory at that repo's root, one stays clean.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use POSIX ();

use lib "$Bin/../lib";
use HostCaps ();
use RunnerStateHarness qw(repo_root reap_with_grace slurp_raw);

sub write_file { my ($p, $c) = @_; make_path(dirname($p)); open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }

sub fake_repo {
    my (%fixtures) = @_;
    my $repo = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real = repo_root();
    make_path(File::Spec->catdir($repo, 'scripts'), File::Spec->catdir($repo, qw(plugins butler tests lib)));
    copy(File::Spec->catfile($real, 'scripts', $_), File::Spec->catfile($repo, 'scripts', $_)) or die "copy $_: $!"
        for qw(run-tests.pl run-tests-container.pl);
    copy(File::Spec->catfile($real, qw(plugins butler tests lib TestPlatform.pm)),
         File::Spec->catfile($repo, qw(plugins butler tests lib TestPlatform.pm))) or die "copy TestPlatform.pm: $!";
    write_file(File::Spec->catfile($repo, qw(plugins x tests t), $_), $fixtures{$_}) for keys %fixtures;
    my $gp = HostCaps::git_path($repo);
    system('git', '-C', $gp, 'init', '-q') == 0 or die 'git init';
    system('git', '-C', $gp, 'add', '-A') == 0 or die 'git add';
    system('git', '-C', $gp, '-c', 'user.email=t@ccpraxis.test', '-c', 'user.name=t', 'commit', '-q', '-m', 'init') == 0
        or die 'git commit';
    return $repo;
}

sub sweep {
    my ($repo) = @_;
    my $home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $out = File::Temp->new(UNLINK => 0); my $op = "$out"; close $out;
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        delete $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT};
        $ENV{HOME} = $home;
        open(STDOUT, '>', $op) or POSIX::_exit(97);
        open(STDERR, '>&', \*STDOUT) or POSIX::_exit(98);
        exec($^X, File::Spec->catfile($repo, 'scripts', 'run-tests.pl')) or POSIX::_exit(99);
    }
    my ($rc, $timed_out) = reap_with_grace($pid, timeout => 120);
    my $text = slurp_raw($op) // '';
    unlink $op;
    return ($rc, $timed_out, $text);
}

my $GREEN = "# platform: any
use Test::More; ok(1, 'clean'); done_testing();\n";
my $PLANT = <<'T';
# platform: any
use strict; use warnings; use Test::More; use FindBin qw($Bin); use File::Path qw(make_path);
my $root = "$Bin/../../../..";
make_path("$root/StrayDir/Windows");
open my $fh, '>', "$root/StrayDir/Windows/cache" or die $!; print {$fh} "x"; close $fh;
ok(-e "$root/StrayDir/Windows/cache", 'planted a stray at the repo root');
done_testing();
T

{
    my $repo = fake_repo('plants-root-stray.t' => $PLANT, 'stays-clean.t' => $GREEN);
    my ($rc, $timed_out, $out) = sweep($repo);
    ok(!$timed_out, 'the stray sweep finished in time') or diag($out);
    isnt($rc, 0, 'a stray at the repo root fails the sweep (unchanged audit)');
    like($out, qr{AUDIT FAILED}, 'the audit section is printed');
    like($out, qr{^\s+StrayDir/Windows/cache$}m, 'git-status audit still names the new path');
    my ($line) = $out =~ /^\s*(StrayDir first appeared at the repo root while running: .*)$/m;
    ok(defined $line, 'THE NEW LINE: the stray is attributed') or diag($out);
    like($line // '', qr{plants-root-stray\.t}, 'and the file that planted it is among the candidates');
}

{
    my $repo = fake_repo('stays-clean.t' => $GREEN, 'also-clean.t' => $GREEN);
    my ($rc, $timed_out, $out) = sweep($repo);
    ok(!$timed_out, 'the clean sweep finished in time');
    # Not "rc == 0": run inside a real sweep, the nested audit also sees the wake-lock-style
    # processes other test files start and stop concurrently, which can fail it for reasons
    # that have nothing to do with this repo. What a clean repo guarantees is narrower.
    unlike($out, qr{new repo path\(s\) appeared}, 'a clean sweep reports no new repo path') or diag($out);
    unlike($out, qr{first appeared at the repo root}, 'and attributes nothing');
}

done_testing();
