#!/usr/bin/env perl
# platform: any
# bp-drive-next.pl park/migration locking (todo 20261002-185449-c3eb0000):
#
#   L4(b)  park --needs-operator runs list -> check -> file under blueprint.md's
#          own lock (the one an unpark holds while closing park items), so two
#          concurrent filers, or a filer and an unpark, cannot interleave.
#          Bounded: a lock it cannot get is the documented exit 3 "re-run".
#   L1     the legacy parks.json migration runs read -> park -> unlink under
#          .drive-solo/parks.migrate.lock, re-checking the file once held.
#          Bounded: a lock it cannot get fails the call closed (exit 2), the
#          legacy file untouched.
#
# Each lock is held by a CHILD process standing in for the concurrent caller.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX ();
use Time::HiRes ();

my $FAKE_HOME = tempdir(CLEANUP => 1);
$ENV{$_} = $FAKE_HOME for qw(HOME USERPROFILE ALMANAC_HOME);
delete $ENV{CLAUDE_PROJECT_DIR};

my $SCRIPTS = "$Bin/../../scripts";
require "$SCRIPTS/bp-drive-next.pl";
require "$Bin/../../../almanac/scripts/almanac-inbox.pl";

my $J   = JSON::PP->new->canonical;
my $NOW = 1_830_297_600;

sub write_file {
    my ($path, $content) = @_;
    (my $d = $path) =~ s{[\\/][^\\/]+\z}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }

sub make_bp_dir {
    my ($proj, $name, $status) = @_;
    my $bp = "$proj/.ccpraxis-local-data/blueprints/$name";
    make_path("$bp/packages");
    write_file("$bp/blueprint.md", "# $name\n\n```\nstatus: $status\n" . ($status eq 'parked' ? "parked_reason: earlier\n" : '')
        . "```\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n"
        . "|-----|-------------|------------|-------|--------|\n| p1 | thing | \xe2\x80\x94 | sonnet | pending |\n");
    write_file("$bp/packages/p1.md", "---\npackage: p1\nblueprint: $name\nstatus: pending\nmodel: sonnet\n"
        . "max_turns: 80\nwrite_set: x/\ntest_paths: x/\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# p1\n");
    return $bp;
}

sub capture_run {
    my ($argv, $opts) = @_;
    $opts->{now}                  //= sub { $NOW };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    my ($ofh, $opath) = tempfile('bplk-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('bplk-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die;
    open my $olderr, '>&STDERR' or die;
    open STDOUT, '>:raw', $opath or die;
    open STDERR, '>:raw', $epath or die;
    my $t0 = Time::HiRes::time();
    my $rc = eval { BpDrive::run($argv, $opts) };
    my $err = $@;
    my $took = Time::HiRes::time() - $t0;
    open STDOUT, '>&', $oldout; close $oldout;
    open STDERR, '>&', $olderr; close $olderr;
    my ($out, $eout) = (slurp($opath) // '', slurp($epath) // '');
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out, $eout, $took);
}

sub hold_lock {
    my ($path) = @_;
    my $ready = "$path.held-ready";
    unlink $ready;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(my $fh, '>>', $path) or POSIX::_exit(1);
        flock($fh, LOCK_EX) or POSIX::_exit(1);
        if (open(my $r, '>', $ready)) { close $r; }
        sleep 600;
        POSIX::_exit(0);
    }
    my $deadline = time + 15;
    Time::HiRes::sleep(0.05) until -e $ready || time > $deadline;
    return $pid;
}
sub release_lock { my ($pid) = @_; kill 'KILL', $pid; waitpid($pid, 0); }

# ---- L4(b) ---------------------------------------------------------------
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    # Already parked, so park writes nothing through set-meta and goes
    # straight to the filing sequence under test.
    my $bp = make_bp_dir($P, 'lk', 'parked');
    my $h = hold_lock("$bp/blueprint.md.lock");
    my ($rc, $out, $err, $took) = capture_run(['park', 'lk', '--needs-operator', 'needs a human'], { data_dir => $data });
    release_lock($h);
    is($rc, 3, "L4(b): with blueprint.md's lock held, filing is deferred with exit 3 (took ${took}s)") or diag($err);
    like($err, qr/re-run the same command/, 'L4(b): and says to re-run');
    cmp_ok($took, '<', 30, 'L4(b): the wait is bounded');
    my $items = eval { Almanac::Inbox::list_items(root => $P) } || [];
    is(scalar(@$items), 0, 'L4(b): nothing was filed while another holder had the lock');

    my ($rc2) = capture_run(['park', 'lk', '--needs-operator', 'needs a human'], { data_dir => $data });
    is($rc2, 0, 'L4(b): the re-run files once the lock is free');
    $items = eval { Almanac::Inbox::list_items(root => $P) } || [];
    is(scalar(@$items), 1, 'L4(b): exactly one item');
}

# ---- L1 ------------------------------------------------------------------
{
    my $P = tempdir(CLEANUP => 1); $P =~ s{\\}{/}g;
    my $data = "$P/.ccpraxis-local-data";
    my $bp = make_bp_dir($P, 'mg', 'audited');
    make_path("$data/.drive-solo");
    write_file("$data/.drive-solo/order.json", $J->encode({ order => ['mg'], recorded_at => $NOW }));
    write_file("$data/.drive-solo/parks.json", $J->encode([ { blueprint => 'mg', reason => 'legacy park' } ]));
    my $h = hold_lock("$data/.drive-solo/parks.migrate.lock");
    my ($rc, $out, $err, $took) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    release_lock($h);
    isnt($rc, 0, "L1: with the migration lock held by another caller, the call fails closed (took ${took}s)");
    cmp_ok($took, '<', 30, 'L1: the wait is bounded');
    ok(-e "$data/.drive-solo/parks.json", 'L1: the legacy file is untouched');
    unlike(slurp("$bp/blueprint.md") // '', qr/^status: parked/m, 'L1: nothing was parked by the blocked caller');

    my ($rc2) = capture_run(['next', '--scope', 'all'], { data_dir => $data });
    is($rc2, 0, 'L1: once the lock is free the migration runs');
    ok(!-e "$data/.drive-solo/parks.json", 'L1: and removes the legacy file');
    like(slurp("$bp/blueprint.md") // '', qr/^status: parked/m, 'L1: the entry is now parked in blueprint.md');
}

done_testing();
