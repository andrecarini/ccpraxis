#!/usr/bin/env perl
# platform: any
# acxpraxis-step-2, 2026-11-05 06:12Z-07:03Z: 03-make-and-hooks's coordinator
# set its own ledger to `parked` and ended its turn, but its process stayed
# alive, waiting on a background job. Every tick the orchestrator saw an
# awaiting-human package with no queued decision and filed an orphan
# escalation; the resolver (a paid claude -p judge) answered `relaunch`;
# bp-resolve.pl found the relaunch moot because the coordinator was still live
# and archived the record -- which left the package, once again, awaiting a
# human with nothing queued. 23 resolver judges in 51 minutes, 22 of them moot
# with why=coordinator-live, until the container restart killed the process.
#
# The rule under test: while the coordinator that set the park is still alive,
# the park is escalated ONCE. Another escalation is filed only when something
# that matters changes: the coordinator exits, a different coordinator is
# running, or the ledger status moves.
#
# Every case drives the REAL BpOrch::run, one tick per call, with an injected
# launch recorder and pid_alive; nothing here starts a coordinator or a judge.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(move);
use JSON::PP;
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
require "$BUTLER/scripts/bp-orchestrator.pl";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $T0   = 1_900_000_000;
my $PID1 = 4_242_424;    # the coordinator that parked
my $PID2 = 4_343_434;    # a later coordinator of the same package
my %SEAT;    # dir -> the coordinator pid the registry records

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes; close $w or die "close $path: $!"; return $path;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/; my $c = <$r>; close $r; return defined $c ? $c : '';
}
sub events {
    my ($dir, $type, $pkg) = @_;
    my @l = grep { length } split /\n/, (read_file("$dir/runs/orchestrator.log") // '');
    return grep { ($_->{type} // '') eq $type && (!defined $pkg || ($_->{package} // '') eq $pkg) }
           map { my $e = eval { $J->decode($_) }; ref $e eq 'HASH' ? $e : () } @l;
}
sub n_orphan { scalar(events($_[0], 'orphan_escalation', 'p03-make')) }
sub set_status {
    my ($dir, $st) = @_;
    my $t = read_file("$dir/packages/p03-make.md");
    $t =~ s/^status:.*$/status: $st/m;
    write_file("$dir/packages/p03-make.md", $t);
}
# What bp-resolve.pl does with a moot `relaunch`: the record leaves the queue
# for resolved-escalations and nothing else changes.
sub resolve_moot {
    my ($dir) = @_;
    my $q = "$dir/runs/escalations";
    my $r = "$dir/runs/resolved-escalations";
    make_path($r);
    opendir(my $dh, $q) or return 0;
    my @f = grep { /\.json\z/ } readdir $dh; closedir $dh;
    move("$q/$_", "$r/$_") or die "move $_: $!" for @f;
    unlink glob("$dir/runs/escalation-resolve/*");
    return scalar @f;
}
my $bpn = 0;
sub world {
    my (%o) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    make_path("$dir/packages", "$dir/runs");
    write_file("$dir/blueprint.md", join("\n", "# T$bpn", '', '## Package status', '',
        '| pkg | deliverable | depends_on | model |', '|--|--|--|--|',
        '| p03-make | d | - | sonnet |', ''));
    write_file("$dir/packages/p03-make.md",
        "---\npackage: p03-make\nstatus: parked\nwrite_set: src/make/\ntest_paths: src/make/\n"
      . "last_updated: 2026-11-05T00:00:00Z\n---\n# p03-make\n\n## Next action\n\n"
      . "Waiting on the detached make check (pid 1795592); resume when it exits.\n");
    write_file("$dir/runs/registry.json", $J->encode({ packages => {
        q(p03-make) => { attempt => 1, status => q(running), session_id => q(sid-p03) } } }));
    $SEAT{$dir} = $o{pid} // $PID1;
    write_file("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-LCP-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-LCPREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($T0 + 400 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T00:00:00+00:00' } });
my %ALIVE;
my @LAUNCHES;
# A once=>1 run ends with bp-lifecycle.pl reconcile, which drops registry pids
# that are dead on THIS host -- and the fake pids are. The production loop never
# exits between ticks, so re-seat the pid it would still be holding.
sub seat {
    my ($dir, $pid) = @_;
    $SEAT{$dir} = $pid if defined $pid;
    my $reg = $J->decode(read_file("$dir/runs/registry.json"));
    $reg->{packages}{q(p03-make)}{pid} = $SEAT{$dir};
    write_file("$dir/runs/registry.json", $J->encode($reg));
}
sub tick {
    my ($dir, $now) = @_;
    seat($dir);
    local $SIG{__WARN__} = sub { };
    BpOrch::run({
        blueprint => "T$bpn", bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables  => { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 3, cap => 5,
                       flat => 600, watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
                       jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60, busy_path => "$dir/busy" },
        once => 1, now => sub { $now }, sleep => sub { },
        http_get  => sub { { status => 200, content => $USAGE_OK } },
        http_post => sub { { status => 200, content => '{}' } },
        pid_alive => sub { defined $_[0] && $ALIVE{$_[0]} },
        spawn_judge => sub { 0 },
        launch    => sub { push @LAUNCHES, $_[0]{pkg}; 0 },
    });
}
# one orchestrator tick followed by the resolver's moot answer, N times.
sub cycles {
    my ($dir, $from, $n) = @_;
    for my $i (0 .. $n - 1) { tick($dir, $T0 + 70 * ($from + $i)); resolve_moot($dir); }
}

# =============================================================================
# L1 -- the incident. The parked coordinator stays alive across 10
# escalate/resolve-moot cycles: one escalation, not ten.
# =============================================================================
{
    %ALIVE = ($PID1 => 1);
    my $dir = world();
    tick($dir, $T0);
    is(n_orphan($dir), 1, 'L1: a self-park is escalated on the first tick');
    is(resolve_moot($dir), 1, 'L1: one record was queued for the resolver');
    cycles($dir, 1, 10);
    is(n_orphan($dir), 1,
        'L1: while the parking coordinator stays alive, a moot resolution does not re-file the escalation')
        or diag('orphan escalations: ' . n_orphan($dir));
    is(scalar(grep { $_ eq 'p03-make' } @LAUNCHES), 0, 'L1: nothing launched over a live coordinator');

    # L2 -- the status moves while the same coordinator lives: a new question.
    set_status($dir, 'blocked');
    cycles($dir, 20, 3);
    is(n_orphan($dir), 2, 'L2: a status change under the same live coordinator is escalated once more');

    # L3 -- the coordinator exits: the park is now a real stop and is escalated.
    %ALIVE = ();
    tick($dir, $T0 + 70 * 30);
    is(n_orphan($dir), 3, 'L3: once the parking coordinator is gone, the park is escalated again');
}

# =============================================================================
# L4 -- a different coordinator (new pid) holding the same status is not the
# one that was already escalated against.
# =============================================================================
{
    %ALIVE = ($PID1 => 1, $PID2 => 1);
    my $dir = world();
    cycles($dir, 0, 3);
    is(n_orphan($dir), 1, 'L4: one escalation against the first coordinator');
    seat($dir, $PID2);
    cycles($dir, 3, 3);
    is(n_orphan($dir), 2, 'L4: a park by a different live coordinator is escalated once');
}

# =============================================================================
# L5 -- control: a park whose coordinator is already dead behaves exactly as
# before -- every tick with nothing queued files one. Without this, L1 would
# pass for an orchestrator that had stopped escalating parks altogether.
# =============================================================================
{
    %ALIVE = ();
    my $dir = world();
    cycles($dir, 0, 3);
    is(n_orphan($dir), 3, 'L5: a park by a dead coordinator is still escalated whenever nothing is queued');
}

done_testing();
