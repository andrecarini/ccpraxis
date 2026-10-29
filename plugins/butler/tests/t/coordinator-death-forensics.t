#!/usr/bin/env perl
# platform: linux
# Oracle for blueprint package 03-deaths-are-diagnosable (fleet-cost-accounting).
#
# Derived ONLY from
# .ccpraxis-local-data/blueprints/fleet-cost-accounting/specs/03-deaths-are-diagnosable-spec.md
# (AC1..AC12 in section 4) plus the pre-existing turn_exhaust_streak /
# creds_backoff_secs precedents already in bp-orchestrator.pl (read for shape
# only, never for the NEW behavior under test here). WRITTEN BLIND to any
# implementation of bp-watch-child.pl (does not exist on disk yet) or of
# death_streak / death_backoff_secs / _read_exit_status in bp-orchestrator.pl.
#
# Marked "platform: linux" (per the repo's test-platform-split convention):
# bp-watch-child.pl's own contract is fork()+POSIX::setsid()+exec()+waitpid()
# with real WIFSIGNALED/WTERMSIG semantics -- Linux-only by the spec's own
# edge case 7. This file exercises that real subprocess machinery directly
# (no fake filesystem-only mocking) rather than the real `claude` CLI: every
# "coordinator" spawned below is a tiny, controllable `perl -e '...'` stand-in
# this file commands to exit 0, exit nonzero, or sleep-until-signaled.
#
# AC -> test block mapping:
#   AC1  -> BLOCK A (four classification shapes)
#   AC2  -> BLOCK F (crafted exit-status file feeds BpOrch::run()'s watchdog_relaunch)
#   AC3  -> BLOCK A (pid-identity assertion inside each BLOCK A case)
#   AC4  -> BLOCK B (pid_alive/kill_pid against the real watcher-spawned pid)
#   AC5  -> BLOCK G (death_streak increments/resets/no-cross-talk with turn_exhaust_streak)
#   AC6  -> BLOCK G (registry-only visibility check, no orchestrator.log read)
#   AC7  -> BLOCK H (5 consecutive deaths -> escalate, no 6th launch)
#   AC8  -> BLOCK H (ticks 1-4 do NOT escalate)
#   AC9  -> BLOCK D (death_backoff_secs geometric sequence)
#   AC10 -> BLOCK I (backoff, not the flat floor, gates the second relaunch)
#   AC11 -> BLOCK C (malformed bp-watch-child.pl invocations)
#   AC12 -> BLOCK E (_read_exit_status total-ness + the attempt-match race guard)
#
# Every subprocess this file spawns is tracked in @SPAWNED and reaped/killed
# in an END block, per this repo's standing rule against unguarded spawns.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use POSIX ();
use Time::HiRes qw(sleep);

my $ORCH        = "$Bin/../../scripts/bp-orchestrator.pl";
my $WATCH_CHILD = "$Bin/../../scripts/bp-watch-child.pl";
require $ORCH;   # package BpOrch

diag("subject under test: $WATCH_CHILD (new file, not yet on disk) + ${ORCH}'s "
   . "death_streak/death_backoff_secs/_read_exit_status (not yet implemented)");

my $J = JSON::PP->new->canonical;

# =====================================================================================
# Scaffolding.
# =====================================================================================
my $ROOT = tempdir(CLEANUP => 1);
my $NOW  = 2_100_000_000;
my $DEAD_PID = 2_100_000_001;   # out of range -> kill 0 fails -> not alive (house convention)

# scalar call guard (house convention, orchestrator-broken-env-turns.t): never
# lets a missing/dying sub abort the whole file -- reports as a normal failed
# assertion instead ("DIED: Undefined subroutine...").
sub sc { my $c = shift; my $r = eval { $c->() }; return $@ ? 'DIED: ' . ((split /\n/, $@)[0]) : $r }

sub spit      { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }

sub iso_of {
    my ($e) = @_;
    my @g = gmtime($e);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
}

# ---- subprocess spawn/cleanup guard --------------------------------------
my @SPAWNED;   # { kind => 'watcher'|'coordinator', pid => N, fh => $fh (watcher only) }
# A runner timeout or Ctrl-C signal exits perl WITHOUT running END blocks,
# so the reaper below would never run and every fixture would outlive the
# test (the old watcher-probe-liveness coverage leaked fourteen that way, 2026-09-23).
# Routing the signal through exit() runs END.
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);
END {
    for my $s (@SPAWNED) {
        next unless defined $s->{pid};
        eval { kill('KILL', $s->{pid}) };
        next if $s->{drained};   # drain_watcher() already read-to-EOF and closed this fh
        if ($s->{fh}) {
            eval {
                local $SIG{ALRM} = sub { die "to\n" };
                alarm(2);
                my $fh = $s->{fh};
                1 while defined <$fh>;
                alarm(0);
            };
            eval { close $s->{fh} };
        }
    }
}

# Spawns bp-watch-child.pl via the classic "fork, then open a read pipe"
# idiom (perlipc) so the PARENT (this test) gets the WATCHER's own real pid
# back directly from open()'s return value -- exactly the mechanism AC3
# names. The forked child execs bp-watch-child.pl in place.
sub spawn_watch_child {
    my (@args) = @_;
    my $watcher_pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $watcher_pid;
    if ($watcher_pid == 0) {
        exec($^X, $WATCH_CHILD, @args);
        POSIX::_exit(127);
    }
    push @SPAWNED, { kind => 'watcher', pid => $watcher_pid, fh => $fh };
    return ($watcher_pid, $fh);
}

# Poll PIDFILE up to ~10s for a plain-integer pid (byte-for-byte the format
# AC1/§2.1 4a promises). Returns undef on timeout, never dies.
sub poll_pidfile {
    my ($pidfile) = @_;
    for (1 .. 30) {
        if (-s $pidfile) {
            my $v = slurp_raw($pidfile);
            if (defined $v && $v =~ /^(\d+)\s*$/) { return $1 + 0; }
        }
        sleep(0.1);
    }
    return undef;
}

# Poll STATUSFILE up to ~3s for valid decodable JSON. Returns undef/hashref.
sub poll_statusfile {
    my ($statusfile) = @_;
    for (1 .. 30) {
        if (-s $statusfile) {
            my $raw = slurp_raw($statusfile);
            my $obj = eval { $J->decode($raw) };
            return $obj if ref $obj eq 'HASH';
        }
        sleep(0.1);
    }
    return undef;
}

# Reads the watcher's whole stdout to EOF (waits for it to exit) and closes
# it, which reaps the forked watcher process (avoiding a zombie).
sub drain_watcher {
    my ($fh) = @_;
    local $/;
    my $out = <$fh>;
    close $fh;
    for my $s (@SPAWNED) { $s->{drained} = 1 if defined $s->{fh} && $s->{fh} == $fh }
    return $out;
}

# =====================================================================================
# BLOCK A — AC1 + AC3: four classification shapes, spawned directly (no
# claude, no bp-launch.sh). Each case also asserts the pid-identity invariant
# (AC3): the pid PIDFILE carries is the fake coordinator's OWN pid, never the
# watcher's.
# =====================================================================================
{
    my $dir = tempdir(DIR => $ROOT, CLEANUP => 1);

    # ---- exited-zero -------------------------------------------------------
    {
        my $pidfile = "$dir/a1.pid"; my $statusfile = "$dir/a1.exit-status";
        my ($watcher_pid, $fh) = spawn_watch_child($pidfile, $statusfile, 1, '--', $^X, '-e', 'exit 0');
        my $coord_pid = poll_pidfile($pidfile);
        ok(defined $coord_pid, 'AC1 exited-zero: PIDFILE was written within 10s')
            or diag('bp-watch-child.pl likely missing or never wrote a pidfile');
        isnt($coord_pid, $watcher_pid, 'AC3 exited-zero: PIDFILE pid != bp-watch-child.pl\'s own (watcher) pid');
        my $st = poll_statusfile($statusfile);
        drain_watcher($fh);
        ok(ref $st eq 'HASH', 'AC1 exited-zero: STATUSFILE decodes as JSON') or diag('no/invalid statusfile');
        is($st && $st->{classification}, 'exited-zero', 'AC1 classification == exited-zero');
        is($st && $st->{exit_code}, 0,      'AC1 exited-zero: exit_code == 0');
        is($st && $st->{signal},    undef,  'AC1 exited-zero: signal is null');
        is($st && $st->{signal_name}, undef,'AC1 exited-zero: signal_name is null');
        is($st && $st->{pid}, $coord_pid,   'AC1 exited-zero: STATUSFILE.pid matches the coordinator pid');
        is($st && $st->{attempt}, 1,        'AC1 exited-zero: STATUSFILE.attempt echoes the ATTEMPT arg');
    }

    # ---- exited-nonzero -----------------------------------------------------
    {
        my $pidfile = "$dir/a2.pid"; my $statusfile = "$dir/a2.exit-status";
        my ($watcher_pid, $fh) = spawn_watch_child($pidfile, $statusfile, 2, '--', $^X, '-e', 'exit 7');
        my $coord_pid = poll_pidfile($pidfile);
        ok(defined $coord_pid, 'AC1 exited-nonzero: PIDFILE was written');
        isnt($coord_pid, $watcher_pid, 'AC3 exited-nonzero: PIDFILE pid != watcher pid');
        my $st = poll_statusfile($statusfile);
        drain_watcher($fh);
        is($st && $st->{classification}, 'exited-nonzero', 'AC1 classification == exited-nonzero');
        is($st && $st->{exit_code}, 7,       'AC1 exited-nonzero: exit_code == 7');
        is($st && $st->{signal},    undef,   'AC1 exited-nonzero: signal is null');
        is($st && $st->{signal_name}, undef, 'AC1 exited-nonzero: signal_name is null');
    }

    # ---- killed-sigterm -------------------------------------------------------
    {
        my $pidfile = "$dir/a3.pid"; my $statusfile = "$dir/a3.exit-status";
        my ($watcher_pid, $fh) = spawn_watch_child($pidfile, $statusfile, 3, '--', $^X, '-e', 'sleep 30');
        my $coord_pid = poll_pidfile($pidfile);
        ok(defined $coord_pid, 'AC1 killed-sigterm: PIDFILE was written before the kill');
        isnt($coord_pid, $watcher_pid, 'AC3 killed-sigterm: PIDFILE pid != watcher pid');
        ok(kill(0, $coord_pid), 'AC1 killed-sigterm: coordinator is alive just before the TERM')
            if defined $coord_pid;
        kill('TERM', $coord_pid) if defined $coord_pid;
        my $st = poll_statusfile($statusfile);
        drain_watcher($fh);
        is($st && $st->{classification}, 'killed-sigterm', 'AC1 classification == killed-sigterm');
        is($st && $st->{exit_code}, undef,  'AC1 killed-sigterm: exit_code is null');
        is($st && $st->{signal}, 15,        'AC1 killed-sigterm: signal == 15');
        is($st && $st->{signal_name}, 'SIGTERM', 'AC1 killed-sigterm: signal_name == SIGTERM');
    }

    # ---- killed-sigkill (the OOM shape) ---------------------------------------
    {
        my $pidfile = "$dir/a4.pid"; my $statusfile = "$dir/a4.exit-status";
        my ($watcher_pid, $fh) = spawn_watch_child($pidfile, $statusfile, 4, '--', $^X, '-e', 'sleep 30');
        my $coord_pid = poll_pidfile($pidfile);
        ok(defined $coord_pid, 'AC1 killed-sigkill: PIDFILE was written before the kill');
        isnt($coord_pid, $watcher_pid, 'AC3 killed-sigkill: PIDFILE pid != watcher pid');
        kill('KILL', $coord_pid) if defined $coord_pid;
        my $st = poll_statusfile($statusfile);
        drain_watcher($fh);
        is($st && $st->{classification}, 'killed-sigkill', 'AC1 classification == killed-sigkill (the OOM shape)');
        is($st && $st->{exit_code}, undef, 'AC1 killed-sigkill: exit_code is null');
        is($st && $st->{signal}, 9,        'AC1 killed-sigkill: signal == 9');
        is($st && $st->{signal_name}, 'SIGKILL', 'AC1 killed-sigkill: signal_name == SIGKILL');
    }

    # ---- finished_at is a real, plausible ISO-ish stamp on at least one case --
    {
        my $pidfile = "$dir/a5.pid"; my $statusfile = "$dir/a5.exit-status";
        my ($watcher_pid, $fh) = spawn_watch_child($pidfile, $statusfile, 5, '--', $^X, '-e', 'exit 0');
        poll_pidfile($pidfile);
        my $st = poll_statusfile($statusfile);
        drain_watcher($fh);
        like($st && $st->{finished_at}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?$/,
            'AC1: STATUSFILE.finished_at looks like a real timestamp')
            if $st;
        ok((ref $st eq 'HASH' && exists $st->{finished_at}), 'AC1: STATUSFILE always carries finished_at');
    }
}

# =====================================================================================
# BLOCK B — AC4: pid_alive/kill_pid (unmodified by this package) still work
# correctly against the pid the new topology records.
# =====================================================================================
{
    my $dir = tempdir(DIR => $ROOT, CLEANUP => 1);
    my $pidfile = "$dir/b1.pid"; my $statusfile = "$dir/b1.exit-status";
    my ($watcher_pid, $fh) = spawn_watch_child($pidfile, $statusfile, 1, '--', $^X, '-e', 'sleep 30');
    my $coord_pid = poll_pidfile($pidfile);
    ok(defined $coord_pid, 'AC4 fixture: PIDFILE was written') or diag('cannot proceed without a real pid');

  SKIP: {
        skip 'AC4: no coordinator pid to test against (bp-watch-child.pl missing/broken)', 3
            unless defined $coord_pid;

        is(BpOrch::pid_alive($coord_pid), 1,
            'AC4: pid_alive() reports the watcher-spawned coordinator as alive');

        BpOrch::kill_pid($coord_pid);
        my $reaped = 0;
        for (1 .. 50) { last if !kill(0, $coord_pid); $reaped = 1; sleep(0.1); }
        ok(!kill(0, $coord_pid),
            'AC4: kill_pid()\'s TERM-then-KILL-with-process-group invocation still reaches the coordinator '
          . '-- the child\'s own setsid() before exec keeps the group topology identical to today');
    }
    my $st = poll_statusfile($statusfile);
    drain_watcher($fh);
    ok((!defined $st) || $st->{classification} =~ /^killed-/,
        'AC4 sanity: the watcher observed the kill_pid()-induced death as a signal, not a clean exit')
        if $st;
}

# =====================================================================================
# BLOCK C — AC11: malformed bp-watch-child.pl invocations never write a
# pidfile or a statusfile, and exit loudly non-zero.
# =====================================================================================
{
    my $dir = tempdir(DIR => $ROOT, CLEANUP => 1);

    my @cases = (
        [ 'missing --separator',   [ "$dir/c1.pid", "$dir/c1.exit-status", 1, $^X, '-e', 'exit 0' ] ],
        [ 'non-numeric ATTEMPT',   [ "$dir/c2.pid", "$dir/c2.exit-status", 'abc', '--', $^X, '-e', 'exit 0' ] ],
        [ 'zero CMD tokens',       [ "$dir/c3.pid", "$dir/c3.exit-status", 1, '--' ] ],
    );
    for my $c (@cases) {
        my ($label, $args) = @$c;
        my ($pidfile, $statusfile) = @$args[0,1];
        my $rc = system($^X, $WATCH_CHILD, @$args);
        isnt($rc, 0, "AC11 ($label): bp-watch-child.pl exits non-zero (or fails to invoke -- also non-zero)");
        ok(!-e $pidfile,    "AC11 ($label): no PIDFILE was written");
        ok(!-e $statusfile, "AC11 ($label): no STATUSFILE was written");
    }
}

# =====================================================================================
# BLOCK D — AC9: death_backoff_secs() pure geometric shape, mirroring
# creds_backoff_secs's own already-proven shape but with its OWN tunable keys.
# =====================================================================================
{
    is(sc(sub { BpOrch::death_backoff_secs(1, {}) }), 30,  'AC9 death_backoff_secs(1,{}) default == 30');
    is(sc(sub { BpOrch::death_backoff_secs(2, {}) }), 60,  'AC9 death_backoff_secs(2,{}) default == 60');
    is(sc(sub { BpOrch::death_backoff_secs(3, {}) }), 120, 'AC9 death_backoff_secs(3,{}) default == 120');
    is(sc(sub { BpOrch::death_backoff_secs(4, {}) }), 240, 'AC9 death_backoff_secs(4,{}) default == 240');
    is(sc(sub { BpOrch::death_backoff_secs(5, {}) }), 480, 'AC9 death_backoff_secs(5,{}) default == 480');
    is(sc(sub { BpOrch::death_backoff_secs(0, {}) }), 30,     'AC9 death_backoff_secs(0,{}) treated as n=1 -> 30');
    is(sc(sub { BpOrch::death_backoff_secs(undef, {}) }), 30, 'AC9 death_backoff_secs(undef,{}) treated as n=1 -> 30');

    my $t = { death_bo_base => 10, death_bo_mult => 3, death_bo_max => 50 };
    is(sc(sub { BpOrch::death_backoff_secs(1, $t) }), 10, 'AC9 custom tunables n=1 -> 10');
    is(sc(sub { BpOrch::death_backoff_secs(2, $t) }), 30, 'AC9 custom tunables n=2 -> 30');
    is(sc(sub { BpOrch::death_backoff_secs(3, $t) }), 50, 'AC9 custom tunables n=3 -> 50 (90 capped)');
    is(sc(sub { BpOrch::death_backoff_secs(4, $t) }), 50, 'AC9 custom tunables n=4 -> 50 (still capped)');
    is(sc(sub { BpOrch::death_backoff_secs(5, $t) }), 50, 'AC9 custom tunables n=5 -> 50 (still capped)');

    isnt(sc(sub { BpOrch::death_backoff_secs(2, {}) }), sc(sub { BpOrch::creds_backoff_secs(2, {}) }),
        'AC9 sanity: death_backoff_secs is a DISTINCT sequence from creds_backoff_secs '
      . '(different default base: 30 vs 60), not an alias for it');
}

# =====================================================================================
# BLOCK E — AC12: _read_exit_status($runs, $pkg, $expected_attempt) total-ness
# and the attempt-match race guard (spec Edge case #1).
# =====================================================================================
{
    my $runs = "$ROOT/e_runs"; mkdir $runs;

    is(sc(sub { BpOrch::_read_exit_status($runs, 'nosuch', 1) }), undef,
        'AC12: missing file -> undef');

    spit("$runs/malformed.exit-status", '{not valid json');
    is(sc(sub { BpOrch::_read_exit_status($runs, 'malformed', 1) }), undef,
        'AC12: malformed JSON -> undef, never dies');

    spit("$runs/mismatch.exit-status", $J->encode({ pid => 111, attempt => 2,
        classification => 'exited-zero', exit_code => 0, signal => undef, signal_name => undef,
        finished_at => iso_of($NOW) }));
    is(sc(sub { BpOrch::_read_exit_status($runs, 'mismatch', 1) }), undef,
        'AC12: attempt field (2) != expected_attempt (1) -> undef, treated as ABSENT not stale-but-trusted');

    spit("$runs/match.exit-status", $J->encode({ pid => 222, attempt => 3,
        classification => 'killed-sigkill', exit_code => undef, signal => 9, signal_name => 'SIGKILL',
        finished_at => iso_of($NOW) }));
    my $got = sc(sub { BpOrch::_read_exit_status($runs, 'match', 3) });
    ok(ref $got eq 'HASH', 'AC12: matching attempt -> returns a hashref') or diag('got: ' . (defined($got) ? $got : 'undef'));
    is(ref($got) eq 'HASH' ? $got->{classification} : undef, 'killed-sigkill', 'AC12: returned hashref carries the real classification');
    is(ref($got) eq 'HASH' ? $got->{pid} : undef, 222, 'AC12: returned hashref carries the real pid');
}

# =====================================================================================
# LOOP HARNESS — mirrors orchestrator-broken-env-turns.t / remediation-attempt-
# cap.t's own mk_bp/write_ledger/tun/go shape exactly, for the BpOrch::run()
# integration blocks below (F, G, H, I).
# =====================================================================================
my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;   # pkgs = [ [name, status, body] ]
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | - | sonnet | $_->[1] |\n" for @$pkgs;
    close $b;
    write_ledger($dir, @$_) for @$pkgs;
    if ($registry) { spit("$dir/runs/registry.json", $J->encode({ packages => $registry })); }
    spit("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-SCN-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-SCNREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}
sub write_ledger {
    my ($dir, $name, $status, $body) = @_;
    $body //= '';
    open my $l, '>', "$dir/packages/$name.md" or die;
    print $l "---\npackage: $name\nblueprint: T\nstatus: $status\nwrite_set: p/$name/\n"
           . "test_paths: p/$name/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $name\n\n## Next action\n\ngo\n" . $body;
    close $l;
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });
sub tun {
    my (%o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>10, cap=>99, flat=>600, watch_tick=>0,
             keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
             tele_retry=>3, usage_fail=>60, busy_path=>"$ROOT/busy" . (++$bpn),
             harvest=>'audit', resolve_cap=>0, corr_cap=>1, judge_to=>600, judge_spawn_cap=>3,
             turn_starved_thresh => 100, min_relaunch => 30,
             death_thresh => 5, death_bo_base => 30, death_bo_mult => 2, death_bo_max => 1800,
             %o };
}
sub go {
    my (%o) = @_;
    my $dir = $o{dir};
    my (@L, $err);
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, kind => $a->{kind}, args => [ @{ $a->{args} || [] } ] };
        return $o{launch} ? $o{launch}->($a) : 0;
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => $o{tunables}, once => 1,
            now => ($o{now} || sub { $NOW }), sleep => sub {},
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => sub { 0 },
            launch => $seam,
        });
        1;
    } or $err = $@;
    return (\@L, ($err // ''));
}
sub log_events {
    my ($dir) = @_;
    my $c = slurp_raw("$dir/runs/orchestrator.log");
    return () unless defined $c;
    return map { eval { $J->decode($_) } || {} } grep { /\S/ } split /\n/, $c;
}
sub log_of_pkg { my ($dir, $type, $pkg) = @_; return grep { (($_->{type} // '') eq $type) && (($_->{package} // '') eq $pkg) } log_events($dir) }
sub explain_log { my ($dir) = @_; return join("\n", map { $J->encode($_) } log_events($dir)) }
sub reg_raw { my ($dir) = @_; my $raw = slurp_raw("$dir/runs/registry.json"); return eval { $J->decode($raw) } || {} }
sub reg_of  { my ($dir, $pkg) = @_; my $r = reg_raw($dir); return (ref($r->{packages}{$pkg}) eq 'HASH') ? $r->{packages}{$pkg} : {} }
sub error_line { my (%o) = @_; return { type=>'result', timestamp=>iso_of($o{epoch}), session_id=>$o{sid}//'sid-x',
    num_turns=>$o{num_turns}//10, is_error=>JSON::PP::true, subtype=>'error_other', terminal_reason=>'error' } }
sub success_line { my (%o) = @_; return { type=>'result', timestamp=>iso_of($o{epoch}), session_id=>$o{sid}//'sid-x',
    num_turns=>$o{num_turns}//10, is_error=>JSON::PP::false, subtype=>'success' } }
sub maxturns_line { my (%o) = @_; return { type=>'result', timestamp=>iso_of($o{epoch}), session_id=>$o{sid}//'sid-x',
    num_turns=>$o{num_turns}//5, is_error=>JSON::PP::true, subtype=>'error_max_turns', terminal_reason=>'max_turns' } }
sub jline { return $J->encode($_[0]) . "\n" }
sub set_terminal { my ($dir, $pkg, $line) = @_; spit("$dir/runs/$pkg.jsonl", qq({"type":"assistant","message":{}}\n) . jline($line)) }
sub clear_jsonl  { my ($dir, $pkg) = @_; unlink "$dir/runs/$pkg.jsonl" }
sub set_checkboxes { my ($dir, $pkg, $n) = @_; my $f = "$dir/packages/$pkg.md"; my $t = slurp_raw($f) // '';
                     $t =~ s/\n## Pipeline\n.*\z//s; spit($f, $t . "\n## Pipeline\n" . join('', map { "- [x] step $_\n" } 1..$n)) }

# =====================================================================================
# BLOCK F — AC2: a crafted (already-written) exit-status file feeds a real
# BpOrch::run() tick's watchdog_relaunch log record.
# =====================================================================================
{
    my $pkg = 'f-crafted';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-f' } };
    my $dir = mk_bp([[$pkg, 'running']], $reg);
    clear_jsonl($dir, $pkg);   # no terminal jsonl -> tv->{verdict} eq 'unknown', the 436-relaunches shape
    spit("$dir/runs/$pkg.exit-status", $J->encode({
        pid => 999999, attempt => 1, classification => 'killed-sigkill',
        exit_code => undef, signal => 9, signal_name => 'SIGKILL', finished_at => iso_of($NOW - 5) }));

    my ($L, $err) = go(dir => $dir, tunables => tun());
    is($err, '', 'AC2: go() ran without a Perl exception') or diag($err);

    my ($relaunch) = log_of_pkg($dir, 'watchdog_relaunch', $pkg);
    ok($relaunch, 'AC2: a watchdog_relaunch event was logged for the crafted-death package')
        or diag(explain_log($dir));
    is($relaunch && $relaunch->{exit_status}, 'killed-sigkill',
        'AC2: watchdog_relaunch.exit_status matches the crafted exit-status file\'s classification');
    is($relaunch && $relaunch->{signal_name}, 'SIGKILL',
        'AC2: watchdog_relaunch.signal_name matches the crafted file');
    is($relaunch && exists($relaunch->{exit_code}) ? $relaunch->{exit_code} : 'MISSING-KEY', undef,
        'AC2: watchdog_relaunch.exit_code is null, matching the crafted file (a signaled death has none)');
}

# =====================================================================================
# BLOCK G — AC5/AC6: death_streak increments on unknown|error only, resets on
# max_turns-with-progress, is left unchanged by max_turns-without-progress
# (no cross-talk with turn_exhaust_streak), and is readable from
# runs/registry.json directly (AC6) without ever touching orchestrator.log
# for that specific assertion.
# =====================================================================================
{
    my $pkg = 'g-streak';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-g' } };
    my $dir = mk_bp([[$pkg, 'running', "\n## Pipeline\n- [x] a\n- [x] b\n"]], $reg);   # 2 checkboxes to start

    # tick 1: unknown (no terminal jsonl at all)
    clear_jsonl($dir, $pkg);
    my ($L1, $e1) = go(dir => $dir, tunables => tun());
    is($e1, '', 'AC5 tick 1 (unknown): go() ran without a Perl exception') or diag($e1);
    is(reg_of($dir, $pkg)->{death_streak}, 1, 'AC5 tick 1 (unknown verdict): death_streak == 1');

    # tick 2: error
    set_terminal($dir, $pkg, error_line(epoch => $NOW - 300));
    my ($L2, $e2) = go(dir => $dir, tunables => tun());
    is($e2, '', 'AC5 tick 2 (error): go() ran without a Perl exception') or diag($e2);
    is(reg_of($dir, $pkg)->{death_streak}, 2, 'AC5 tick 2 (error verdict): death_streak == 2');

    # tick 3: unknown again
    clear_jsonl($dir, $pkg);
    my ($L3, $e3) = go(dir => $dir, tunables => tun());
    is($e3, '', 'AC5 tick 3 (unknown): go() ran without a Perl exception') or diag($e3);
    is(reg_of($dir, $pkg)->{death_streak}, 3, 'AC5 tick 3 (unknown verdict): death_streak == 3');

    # ---- AC6: readable straight from runs/registry.json, no log parsing ----
    my $raw_registry = slurp_raw("$dir/runs/registry.json");
    my $decoded = eval { $J->decode($raw_registry) };
    is(ref($decoded) eq 'HASH' ? $decoded->{packages}{$pkg}{death_streak} : 'BAD-JSON', 3,
        'AC6: death_streak (3) is readable directly from a raw decode of runs/registry.json -- '
      . 'this assertion never calls log_events()/reads orchestrator.log at all');

    # tick 4: max_turns WITH progress (2 -> 3 checkboxes) -> resets death_streak to 0
    set_checkboxes($dir, $pkg, 3);
    set_terminal($dir, $pkg, maxturns_line(epoch => $NOW - 200));
    my ($L4, $e4) = go(dir => $dir, tunables => tun());
    is($e4, '', 'AC5 tick 4 (max_turns+progress): go() ran without a Perl exception') or diag($e4);
    is(reg_of($dir, $pkg)->{death_streak}, 0,
        'AC5 tick 4: a max_turns exit WITH forward progress resets death_streak to 0 (behavior 8)');

    # tick 5: max_turns WITHOUT progress (still 3 checkboxes) -> death_streak UNCHANGED (still 0)
    set_terminal($dir, $pkg, maxturns_line(epoch => $NOW - 100));
    my ($L5, $e5) = go(dir => $dir, tunables => tun());
    is($e5, '', 'AC5 tick 5 (max_turns, no progress): go() ran without a Perl exception') or diag($e5);
    is(reg_of($dir, $pkg)->{death_streak}, 0,
        'AC5 tick 5: a fruitless max_turns exhaustion (B8, its own separate turn_exhaust_streak escalation) '
      . 'leaves death_streak UNCHANGED at 0 -- proves no cross-talk between the two counters (edge case 5)');
    cmp_ok(reg_of($dir, $pkg)->{turn_exhaust_streak} // 0, '>=', 1,
        'AC5 tick 5 sanity: turn_exhaust_streak DID increment on this fruitless exhaustion -- the two '
      . 'counters are genuinely independent axes, not one counter under two names');
}

# =====================================================================================
# BLOCK H — AC7/AC8: a fixture that dies 5 times consecutively escalates
# exactly on the 5th (never the 4th, never the 6th).
# =====================================================================================
{
    my $pkg = 'h-escalator';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-h' } };
    my $dir = mk_bp([[$pkg, 'running']], $reg);

    my @launch_calls;
    my $seam = sub { my ($a) = @_; push @launch_calls, $a->{pkg}; return 0 };

    for my $n (1 .. 4) {
        set_terminal($dir, $pkg, error_line(epoch => $NOW - 300, sid => "sid-h-$n"));
        my ($L, $err) = go(dir => $dir, tunables => tun(death_thresh => 5), launch => $seam);
        is($err, '', "AC8 tick $n: go() ran without a Perl exception") or diag($err);
        is(reg_of($dir, $pkg)->{death_streak}, $n, "AC8 tick $n: death_streak == $n");
        my ($relaunch) = log_of_pkg($dir, 'watchdog_relaunch', $pkg);
        ok($relaunch, "AC8 tick $n: still relaunched (watchdog_relaunch present), NOT yet escalated")
            or diag(explain_log($dir));
        isnt(BpOrch::ledger_fm($dir, $pkg, 'status'), 'blocked',
            "AC8 tick $n: ledger status is NOT blocked yet (death_streak $n < thresh 5)");
    }
    is(scalar(@launch_calls), 4, 'AC8: exactly 4 launch-seam calls after ticks 1-4');

    # tick 5 -- the 5th consecutive death: escalate, do not relaunch.
    set_terminal($dir, $pkg, error_line(epoch => $NOW - 300, sid => 'sid-h-5'));
    my ($L5, $e5) = go(dir => $dir, tunables => tun(death_thresh => 5), launch => $seam);
    is($e5, '', 'AC7 tick 5: go() ran without a Perl exception') or diag($e5);
    is(reg_of($dir, $pkg)->{death_streak}, 5, 'AC7 tick 5: death_streak reached exactly 5');
    is(BpOrch::ledger_fm($dir, $pkg, 'status'), 'blocked',
        'AC7: on the 5th consecutive death, the ledger status is flipped to blocked via _escalate_stuck '
      . '(resolve_cap=>0 in this fixture\'s tunables makes escalation_verdict go straight to _block_and_queue, '
      . 'the same convention remediation-attempt-cap.t uses for its own attempt-cap escalation)')
        or diag(explain_log($dir));
    is(scalar(@launch_calls), 4,
        'AC7: the injected launch seam recorded NO 6th call for this package -- escalated instead of relaunched, '
      . 'past the 5-consecutive-deaths threshold, exactly as bp-orchestrator.pl already does for the pre-existing '
      . 'attempt-cap block verdict');
}

# =====================================================================================
# BLOCK I — AC10: the death backoff (not the pre-existing flat min_relaunch
# floor) gates the SECOND relaunch of a package with an active death streak.
# Single continuous BpOrch::run() invocation across two ticks (t=0, t=40),
# per r01's own documented requirement that %last_relaunch_at is loop-scope
# and never persists across separate go()/run() calls.
# =====================================================================================
{
    my $pkg = 'i-backoff';
    my $reg = { $pkg => { attempt => 1, pid => $DEAD_PID, status => 'running', session_id => 'sid-i' } };
    my $dir = mk_bp([[$pkg, 'running']], $reg);
    set_terminal($dir, $pkg, error_line(epoch => $NOW - 300, sid => 'sid-i'));

    my @offsets = (0, 40);
    my $tick = 0;
    my (@L, $err);
    my $seam = sub {
        my ($a) = @_;
        push @L, { pkg => $a->{pkg}, at_offset => $offsets[$tick] };
        return 0;
    };
    my $now_fn   = sub { return $NOW + ($offsets[$tick] // $offsets[-1]) };
    my $sleep_fn = sub {
        $tick++;
        if ($tick >= scalar(@offsets)) { spit("$dir/runs/.shutdown", ''); }
    };
    eval {
        BpOrch::run({
            blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => tun(min_relaunch => 30, death_bo_base => 60, death_bo_mult => 2, death_bo_max => 1800),
            now => $now_fn, sleep => $sleep_fn,
            http_get  => sub { { status => 200, content => $USAGE_OK } },
            http_post => sub { { status => 200, content => '{}' } },
            spawn_judge => sub { 0 },
            launch => $seam,
        });
        1;
    } or $err = $@;
    is($err // '', '', 'AC10: multi-tick go() ran without a Perl exception') or diag($err);

    my @relaunches = log_of_pkg($dir, 'watchdog_relaunch', $pkg);
    is(scalar(@relaunches), 1,
        'AC10: only ONE actual relaunch happened across the 2 ticks (t=0 and t=40) -- the t=40 relaunch was '
      . 'deferred by the death backoff (60s), not permitted by the flat min_relaunch floor (30s)')
        or diag(explain_log($dir));

    my @deferred = log_of_pkg($dir, 'relaunch_deferred', $pkg);
    ok(scalar(@deferred) >= 1, 'AC10: at least one relaunch_deferred event was logged for the t=40 tick')
        or diag(explain_log($dir));
    my ($death_deferred) = grep { ($_->{reason} // '') =~ /death/i } @deferred;
    ok($death_deferred,
        'AC10: the deferral names the DEATH backoff as its reason (distinct from the pre-existing '
      . '"min_interval" reason string) -- proving the backoff, not the flat 30s floor, is what gated it '
      . '(40s since last launch is < death_backoff_secs(1,$t)=60s but > the flat 30s floor)')
        or diag(explain_log($dir));
}

# =====================================================================================
# BLOCK J — red-team HIGH / reviewer SHOULD-FIX 3: a PIDFILE-write failure
# must not leave the already-exec()'d coordinator running untracked. Forces
# open() to fail by pointing PIDFILE at an existing DIRECTORY (open '>' on a
# directory fails with EISDIR on every POSIX-ish platform, including this
# host's Cygwin/MSYS perl -- no chmod/permission trickery needed).
#
# Timing, not liveness-polling, is the ONLY non-racy oracle here: fork()+
# exec() on this host's fork emulation is measurably slower than the
# parent's open()+kill() sequence, so a coordinator started with a LONG
# sleep can be (and empirically is) killed before it ever completes its own
# process startup -- there is no reliable point at which a side channel the
# coordinator itself would write could be observed as "definitely written
# before it might have already been killed". But the watcher's own code
# path on this failure calls waitpid($pid, 0) AFTER attempting the kill, so
# drain_watcher() (which blocks until the watcher itself exits) cannot
# return until that waitpid() resolves. If the kill is missing or broken,
# waitpid() only resolves once the coordinator's `sleep 20` finishes
# naturally -- so wall-clock elapsed time for drain_watcher() is a fully
# deterministic proxy for "was the child actually killed" that requires no
# racy observation of the coordinator's own execution at all.
# =====================================================================================
{
    my $dir = tempdir(DIR => $ROOT, CLEANUP => 1);
    mkdir "$dir/j1.pid" or die "mkdir $dir/j1.pid: $!";   # a DIRECTORY at the pidfile path
    my $statusfile = "$dir/j1.exit-status";

    my ($watcher_pid, $fh) = spawn_watch_child("$dir/j1.pid", $statusfile, 1, '--',
        $^X, '-e', 'sleep 20');

    my $t0 = time();
    drain_watcher($fh);   # blocks until the watcher itself exits (and is reaped)
    my $elapsed = time() - $t0;

    cmp_ok($elapsed, '<', 10,
        'BLOCK J (red-team HIGH / reviewer SHOULD-FIX 3): on a PIDFILE-write failure, the watcher '
      . 'exits well before the coordinator\'s own 20s sleep could finish naturally -- proving the '
      . 'already-exec()\'d coordinator was actively killed (TERM/KILL) rather than left running '
      . 'untracked with no pidfile, no statusfile, and no registry entry (if the kill were missing '
      . 'or broken, the watcher\'s own waitpid() -- called right after the kill attempt -- would '
      . 'block for the full 20s instead)')
        or diag("drain_watcher took ${elapsed}s -- looks like the coordinator ran to completion instead of being killed");

    # "Still just the bare directory" means an EMPTY directory. `-s` on a
    # directory is not that test: it reports the directory's own allocation,
    # which is 0 on NTFS but 64 bytes for an empty APFS directory and 4096 on
    # ext4, so it only ever held on Windows.
    my $j1_entries = -1;
    if (opendir(my $dh, "$dir/j1.pid")) {
        $j1_entries = scalar(grep { $_ ne '.' && $_ ne '..' } readdir $dh);
        closedir $dh;
    }
    ok(-d "$dir/j1.pid" && $j1_entries == 0, 'BLOCK J: PIDFILE was never successfully written (still just the bare directory)');
    ok(!-e $statusfile, 'BLOCK J: STATUSFILE was never written either -- the failure short-circuits before that point');
}

done_testing();
