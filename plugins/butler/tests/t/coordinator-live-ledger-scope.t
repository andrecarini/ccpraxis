#!/usr/bin/env perl
# platform: any
# A coordinator's write guard took write_set/test_paths only from the
# BP_WRITE_SET/BP_TEST_PATHS snapshot bp-launch.sh exports. A widening
# recorded mid-session through bp-ledger.pl (which requires a blueprint
# Decision naming the path) never reached that snapshot, so the coordinator
# was refused its own sanctioned paths and parked for a relaunch that only
# re-reads the same ledger (judged-continuity-disarm/02 and /03,
# 2026-10-22/23). The guard now unions the ledger's live fields in.
#
# Safety half: a path in neither the snapshot nor the ledger is still
# denied, a missing ledger leaves the snapshot alone, and a narrowing in the
# ledger does not revoke what the snapshot granted (unchanged behaviour:
# only a relaunch narrows).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use HostCaps qw(tempdir_args);
use GuardHarness;

my $J = JSON::PP->new->canonical;
my $ROOT = tempdir(tempdir_args(), CLEANUP => 1);
$ROOT =~ s{\\}{/}g;
my $n = 0;

sub spit {
    my ($path, $body) = @_;
    (my $dir = $path) =~ s{/[^/]*\z}{};
    make_path($dir);
    open(my $fh, '>:raw', $path) or die "fixture: $path: $!";
    print {$fh} $body;
    close $fh;
}

sub env_for {
    my (%o) = @_;
    $n++;
    my $proj = "$ROOT/proj$n";
    my $bpd  = "$ROOT/bp$n";
    make_path($proj, "$bpd/runs", "$bpd/packages");
    if (defined $o{ledger_ws}) {
        spit("$bpd/packages/pkg.md", "---\npackage: pkg\nstatus: running\nwrite_set: $o{ledger_ws}\n"
            . "test_paths: " . ($o{ledger_tp} // '') . "\n---\n# pkg\n");
    }
    my %env = (BP_LEDGER => "$bpd/packages/pkg.md", BP_DIR => $bpd, BP_PROJECT_ROOT => $proj,
               BP_PACKAGE => 'pkg', BP_WRITE_SET => $o{env_ws}, BP_TEST_PATHS => ($o{env_tp} // ''));
    return ($proj, \%env);
}

sub edit {
    my ($proj, $env, $rel) = @_;
    my $p = { tool_name => 'Edit', cwd => $proj, tool_input => { file_path => "$proj/$rel" } };
    return GuardHarness::run_module('WriteGuards', $p, env => $env, args => ['writes']);
}

{
    my ($proj, $env) = env_for(env_ws => 'src/a/', ledger_ws => 'src/a/:src/b/new.pm');
    is(edit($proj, $env, 'src/a/x.pm')->{rc}, 0, 'a launch-snapshot path is allowed');
    is(edit($proj, $env, 'src/b/new.pm')->{rc}, 0, 'a path widened in the ledger mid-session is allowed without a relaunch');
    my $r = edit($proj, $env, 'src/c/other.pm');
    is($r->{rc}, 2, 'a path in neither the snapshot nor the ledger is still denied');
    like($r->{err} . $r->{out}, qr/ledger is re-read on every write/, 'and the refusal names the in-session recovery');
}
{
    my ($proj, $env) = env_for(env_ws => 'src/a/', env_tp => 't/a.t', ledger_ws => 'src/a/', ledger_tp => 't/a.t:t/b.t');
    is(edit($proj, $env, 't/b.t')->{rc}, 0, 'a test path added to the ledger mid-session is allowed');
}
{
    my ($proj, $env) = env_for(env_ws => 'src/a/');   # no ledger file at all
    is(edit($proj, $env, 'src/a/x.pm')->{rc}, 0, 'with no ledger file the snapshot still applies');
    is(edit($proj, $env, 'src/b/new.pm')->{rc}, 2, 'and grants nothing beyond it');
}
{
    my ($proj, $env) = env_for(env_ws => 'src/a/:src/b/', ledger_ws => 'src/a/');
    is(edit($proj, $env, 'src/b/x.pm')->{rc}, 0, 'a ledger narrowing does not revoke the snapshot mid-session (unchanged)');
}

done_testing();
