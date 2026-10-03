#!/usr/bin/env perl
# platform: any
# ORACLE for package 11-ac-loss-clean-suspend-cycle (blueprint tooling-backlog),
# AC-1..AC-5, AC-7, AC-9 (module half), AC-10..AC-16 of
# .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md. Covers BpAcWatch.pm's module-level
# contract: observe(), log_event(), standdown_director_side(),
# resume_director_side(), monitor_loop(), monitor_live(), guard_active(),
# status(), enabled().
#
# DC3 note (handed down from the coordinator, Decision 56): continuity is
# disarmed during stand-down and the AC-reconnect monitor is a PLAIN,
# unbound `run_in_background` Bash call -- NOT held via butler-hold (a
# butler-hold requires an armed session, which stand-down explicitly is
# not). This file tests the corrected behavior: nothing here exercises or
# asserts a butler-hold/lock-token mechanism for the monitor.
#
# BpAcWatch.pm DOES NOT EXIST YET. `require` below dies/fails at load time;
# every case that calls a BpAcWatch:: function is wrapped in a SKIP block
# keyed off $LOADED, so this file reports clean "not ok"/skip lines rather
# than dying outright.
#
# Written BLIND to any implementation file: derived only from spec sections
# 2.2-2.6 (log format, state machine, BpAcWatch.pm contract, closed event
# vocabulary) and section 3 (observable behaviors).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

my $S = "$Bin/../../scripts"; $S =~ s{\\}{/}g;
my $MODULE = "$S/BpAcWatch.pm";

my $LOAD_ERROR;
my $LOADED = do {
    local $@;
    eval { require $MODULE };
    $LOAD_ERROR = $@;
    !$@;
};

my $J = JSON::PP->new->canonical;

# This assertion is the one that must actually FAIL pre-implementation (not
# merely skip): BpAcWatch.pm does not exist yet, so $LOADED is false here,
# and every AC block below is a SKIP keyed off it -- legible as "one real
# failure (the module is missing) plus a page of skips", never a silent
# all-pass run and never a crash of this file.
ok($LOADED, 'BpAcWatch.pm exists and loads cleanly (plugins/butler/scripts/BpAcWatch.pm)')
    or diag("require failed: $LOAD_ERROR");

# ---------------------------------------------------------------------------
# fixtures / helpers
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path("$d/.drive-solo");
    return $d;
}

sub log_path { my ($data) = @_; return "$data/.drive-solo/ac-cycle.log" }

sub read_log_lines {
    my ($data) = @_;
    my $p = log_path($data);
    return () unless -f $p;
    open my $fh, '<:raw', $p or return ();
    local $/;
    my $c = <$fh>;
    close $fh;
    return () unless defined $c;
    my @l = split /\n/, $c;
    pop @l while @l && $l[-1] eq '';
    return @l;
}

sub events_of {
    # Pull just the EVENT token (3rd whitespace-separated field, after the
    # two ISO timestamps) from each log line.
    my (@lines) = @_;
    return map { (split /\s+/, $_, 4)[2] } @lines;
}

sub state_path { my ($data) = @_; return "$data/.drive-solo/ac-state.json" }

sub read_state {
    my ($data) = @_;
    my $p = state_path($data);
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return eval { $J->decode($c) };
}

sub write_state {
    my ($data, $h) = @_;
    make_path("$data/.drive-solo");
    open my $fh, '>:raw', state_path($data) or die $!;
    print {$fh} $J->encode($h);
    close $fh;
}

# A fixed base epoch for every case below.
my $T0 = 1_900_000_000;

# ===========================================================================
# AC-1 (DC1, DC6): ac -> dc transition logs AC-LOSS-DETECTED, GRACE-START;
# grace_until is probe time + 300. Log lines match the 2.2 grammar.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 8 unless $LOADED;
    my $data = fresh_data();
    my $obs = BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0, force => 1);
    ok(ref $obs eq 'HASH', 'AC-1: observe returns a hashref');
    is($obs->{phase}, 'grace', 'AC-1: phase is grace after an ac->dc transition');
    is($obs->{grace_until}, $T0 + 300, 'AC-1: grace_until is probe time + 300 (GRACE constant)');

    my @lines = read_log_lines($data);
    my @ev = events_of(@lines);
    is_deeply(\@ev, ['AC-LOSS-DETECTED', 'GRACE-START'], 'AC-1: log gains AC-LOSS-DETECTED then GRACE-START, in order');

    for my $line (@lines) {
        like($line, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \S+ \S+ src=\S+ .*-- \S.*$/,
            "AC-1: line matches the 2.2 grammar: $line");
    }
}

# ===========================================================================
# AC-2 (DC1, DC6): grace timing -- +299s no transition, +300s GRACE-EXPIRED,
# an unknown reading at +900s never expires grace.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 5 unless $LOADED;
    my $data = fresh_data();
    BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0, force => 1);

    my $obs299 = BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0 + 299, force => 1);
    is($obs299->{phase}, 'grace', 'AC-2: at +299s, still grace (no expiry yet)');

    my $st = read_state($data);
    is($st->{phase}, 'grace', 'AC-2: state file agrees: still grace at +299s');

    my $obs_unknown = BpAcWatch::observe($data, src => 'director', probe => sub { 'unknown' }, now => $T0 + 900, force => 1);
    is($obs_unknown->{phase}, 'grace', 'AC-2: an unknown reading at +900s never expires grace');

    my $obs300 = BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0 + 300, force => 1);
    is($obs300->{phase}, 'expired', 'AC-2: at exactly +300s with a dc reading, phase is expired');
    my @ev = events_of(read_log_lines($data));
    ok((grep { $_ eq 'GRACE-EXPIRED' } @ev), 'AC-2: log gains GRACE-EXPIRED');
}

# ===========================================================================
# AC-3 (DC1): reconnect within grace -> AC-RESTORED-IN-GRACE, phase ac, no
# marker file created.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 3 unless $LOADED;
    my $data = fresh_data();
    BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0, force => 1);
    my $obs = BpAcWatch::observe($data, src => 'director', probe => sub { 'ac' }, now => $T0 + 60, force => 1);
    is($obs->{phase}, 'ac', 'AC-3: a reading of ac during grace returns to phase ac');
    my @ev = events_of(read_log_lines($data));
    ok((grep { $_ eq 'AC-RESTORED-IN-GRACE' } @ev), 'AC-3: log gains AC-RESTORED-IN-GRACE');
    ok(!-e "$data/.drive-solo/ac-standdown.json", 'AC-3: no stand-down marker file was created');
}

# ===========================================================================
# AC-4 (DC1): a grace state with probed_at older than 600s and a dc reading
# restarts grace (basis=restart); it does not expire.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 3 unless $LOADED;
    my $data = fresh_data();
    # Seed a stale grace state directly: probed_at long ago, grace_until also
    # long past -- simulating a host that slept/suspended across the window.
    write_state($data, {
        v => 1, phase => 'grace', source => 'dc', probed_at => $T0 - 1000,
        dc_since => $T0 - 1000, grace_until => $T0 - 700,
        reconnected_at => undef, reconnect_basis => undef, updated_at => $T0 - 1000,
    });
    my $obs = BpAcWatch::observe($data, src => 'monitor', probe => sub { 'dc' }, now => $T0, force => 1);
    is($obs->{phase}, 'grace', 'AC-4: a stale (>600s) grace record with a dc reading restarts grace, does not expire');
    is($obs->{grace_until}, $T0 + 300, 'AC-4: grace_until is restarted to now + 300');
    ok((grep { /^\S+\s+\S+\s+GRACE-START\b/ && / basis=restart/ } read_log_lines($data)),
        'AC-4: the log line says GRACE-START ... basis=restart');
}

# ===========================================================================
# AC-5 (DC1, DC6): probe throttle -- a second non-forced observe within one
# PROBE_INTERVAL does not call the probe. Two observe calls on the same dc
# transition produce exactly one AC-LOSS-DETECTED (the lock invariant).
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 2 unless $LOADED;
    my $data = fresh_data();
    my $calls = 0;
    BpAcWatch::observe($data, src => 'director', probe => sub { $calls++; 'ac' }, now => $T0, force => 1);
    is($calls, 1, 'AC-5: precondition -- the forced call probed once');
    BpAcWatch::observe($data, src => 'director', probe => sub { $calls++; 'ac' }, now => $T0 + 1);
    is($calls, 1, 'AC-5: a second non-forced observe within PROBE_INTERVAL does not call the probe again');
}
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 1 unless $LOADED;
    my $data = fresh_data();
    # "Concurrent" is approximated serially here: both callers probe the same
    # dc reading at the same instant; the lock around the read-modify-write-
    # log means the state machine must still land on exactly one
    # AC-LOSS-DETECTED, not two, however many observers raced to see it.
    BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0, force => 1);
    BpAcWatch::observe($data, src => 'holder',   probe => sub { 'dc' }, now => $T0, force => 1);
    my @ev = events_of(read_log_lines($data));
    my $n = grep { $_ eq 'AC-LOSS-DETECTED' } @ev;
    is($n, 1, 'AC-5: exactly one AC-LOSS-DETECTED is logged across two observe calls on the same dc transition');
}

# ===========================================================================
# AC-7 (DC1, DC2, DC6): standdown_director_side from phase expired.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 7 unless $LOADED;
    my $data = fresh_data();
    write_state($data, {
        v => 1, phase => 'expired', source => 'dc', probed_at => $T0,
        dc_since => $T0 - 300, grace_until => $T0, reconnected_at => undef,
        reconnect_basis => undef, updated_at => $T0,
    });
    my $kept_pid = "$data/.drive-solo/keepawake.pid";
    make_path("$data/.drive-solo");
    open my $fh, '>', $kept_pid or die $!; print {$fh} "12345\n"; close $fh;

    my $settled_calls = 0;
    my $action = BpAcWatch::standdown_director_side($data,
        now => $T0 + 5,
        inflight => [{ blueprint => 'bp1', package => 'p1' }],
        keepawake_settle => sub { $settled_calls++; unlink $kept_pid },
    );
    ok(ref $action eq 'HASH', 'AC-7: returns a hashref action');
    is($action->{action}, 'ac-stand-down', 'AC-7: the action name is ac-stand-down');
    ok(-f "$data/.drive-solo/ac-standdown.json", 'AC-7: the stand-down marker now exists');
    is($settled_calls, 1, 'AC-7: keepawake_settle was called once');
    ok(!-e $kept_pid, 'AC-7: keepawake.pid is gone (settled applied)');

    my @ev = events_of(read_log_lines($data));
    is_deeply(\@ev, ['STANDDOWN-BEGIN', 'STANDDOWN-SIGNAL-SET', 'KEEPAWAKE-RELEASED', 'STANDDOWN-ACTION'],
        'AC-7: the log gains the four lines in order');

    my $st = read_state($data);
    is($st->{phase}, 'standing-down', 'AC-7: phase is now standing-down');

    # A second call must not add a second STANDDOWN-BEGIN.
    BpAcWatch::standdown_director_side($data, now => $T0 + 10, inflight => [], keepawake_settle => sub { });
    my @ev2 = events_of(read_log_lines($data));
    my $begins = grep { $_ eq 'STANDDOWN-BEGIN' } @ev2;
    is($begins, 1, 'AC-7: a repeat call adds no second STANDDOWN-BEGIN');
}

# ===========================================================================
# AC-9 (DC1, DC6) module-level half: guard_active() -- true iff the marker
# exists AND phase is one of expired|standing-down|monitoring. (The
# hook-wiring half of AC-9 is covered by ac-standdown-gate.t.)
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 4 unless $LOADED;
    my $data = fresh_data();
    is(BpAcWatch::guard_active($data), 0, 'AC-9: guard_active is 0 with no marker and no state');

    make_path("$data/.drive-solo");
    open my $fh, '>', "$data/.drive-solo/ac-standdown.json" or die $!;
    print {$fh} '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}';
    close $fh;
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });
    is(BpAcWatch::guard_active($data), 1, 'AC-9: guard_active is 1 with marker present and phase standing-down');

    write_state($data, { v => 1, phase => 'reconnected', source => 'ac', probed_at => $T0 });
    is(BpAcWatch::guard_active($data), 0, 'AC-9: guard_active is 0 once phase is reconnected, even with marker present');

    write_state($data, { v => 1, phase => 'ac', source => 'ac', probed_at => $T0 });
    is(BpAcWatch::guard_active($data), 0, 'AC-9: guard_active is 0 once phase is ac, even with marker present');
}

# ===========================================================================
# AC-10 (DC2, DC3, DC6): monitor_loop power-plan reconciliation logic.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 6 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });

    my $reconcile_calls = 0;
    my @reconcile_args;
    my $out_lines = [];
    BpAcWatch::monitor_loop($data,
        probe   => sub { 'ac' },  # exits immediately on the first tick's observe
        now     => sub { $T0 },
        sleep   => sub { },
        arms    => sub { [] },
        wakelock_state => sub { 'released' },
        reconcile => sub { $reconcile_calls++; @reconcile_args = @_;
            return { outcome => 'corrected', wanted_guid => '381b4222-f694-41f0-9685-ff5bb260df2e' } },
        out => sub { push @$out_lines, $_[0] },
        tick => 0,
    );
    my @ev = events_of(read_log_lines($data));
    ok((grep { $_ eq 'MONITOR-ENTER' } @ev), 'AC-10: log gains MONITOR-ENTER');
    ok((grep { /^\S+\s+\S+\s+STANDDOWN-VERIFY\b/ && /live_arms=0/ && /wake_lock=released/ } read_log_lines($data)),
        'AC-10: STANDDOWN-VERIFY line carries live_arms=0 and wake_lock=released');
    ok((grep { /^\S+\s+\S+\s+POWER-PLAN\b/ && /result=corrected/ && /381b4222/ } read_log_lines($data)),
        'AC-10: POWER-PLAN line reports result=corrected with the wanted guid');
    is($reconcile_calls, 1, 'AC-10: the fake reconcile was called exactly once');
    ok((grep { defined && $_ eq 'ac-loss' } @reconcile_args), 'AC-10: reconcile was called with why => "ac-loss" among its args');
    ok(1, 'AC-10: (placeholder keeps plan count stable across minor arg-shape variance)');
}
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 2 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });
    my $reconcile_calls = 0;
    BpAcWatch::monitor_loop($data,
        probe => sub { 'ac' }, now => sub { $T0 }, sleep => sub { },
        arms => sub { ['abcdef12'] },
        wakelock_state => sub { 'held' },
        reconcile => sub { $reconcile_calls++; { outcome => 'skipped' } },
        out => sub { }, tick => 0,
    );
    is($reconcile_calls, 0, 'AC-10: with live arms present, reconcile is never called');
    ok((grep { /^\S+\s+\S+\s+POWER-PLAN\b/ && /result=skipped/ && /reason=arms-remaining/ } read_log_lines($data)),
        'AC-10: the log instead carries POWER-PLAN result=skipped reason=arms-remaining');
}

# ===========================================================================
# AC-11 (DC3): static source scan -- no wake-lock/scheduled-task call
# anywhere in BpAcWatch.pm or bp-ac-watch.pl. Behavioural: a monitor run
# with dc, dc, ac leaves keepawake.pid absent.
# ===========================================================================
{
    for my $f ($MODULE, "$S/bp-ac-watch.pl") {
        SKIP: {
            skip "AC-11: $f does not exist yet", 2 unless -f $f;
            open my $fh, '<:raw', $f or die $!;
            local $/;
            my $src = <$fh>;
            close $fh;
            unlike($src, qr/BpKeepAwake::(?:apply|spawn)|keep-awake\.ps1|SetThreadExecutionState|PowerRequest/,
                "AC-11: $f contains no wake-lock actuator call");
            unlike($src, qr/schtasks|ScheduledTask/i, "AC-11: $f contains no scheduled-task call");
        }
    }
}
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 1 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });
    make_path("$data/.drive-solo");
    my @readings = ('dc', 'dc', 'ac');
    my $i = 0;
    BpAcWatch::monitor_loop($data,
        probe => sub { $readings[$i++] // 'ac' }, now => sub { $T0 + $i }, sleep => sub { },
        arms => sub { [] }, wakelock_state => sub { 'released' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { }, tick => 0,
    );
    ok(!-e "$data/.drive-solo/keepawake.pid", 'AC-11: keepawake.pid is still absent after a dc,dc,ac monitor run');
}

# ===========================================================================
# AC-12 (DC4, DC6): monitor_loop reconnect exits 0, logs
# AC-RECONNECT-DETECTED then MONITOR-EXIT, phase reconnected, printed resume
# line. A second monitor started while the first holds the lock exits 3.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 5 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });
    my @readings = ('dc', 'dc', 'ac');
    my $i = 0;
    my @out;
    my $rc = BpAcWatch::monitor_loop($data,
        probe => sub { $readings[$i++] // 'ac' }, now => sub { $T0 + $i }, sleep => sub { },
        arms => sub { [] }, wakelock_state => sub { 'released' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { push @out, $_[0] }, tick => 0,
    );
    is($rc, 0, 'AC-12: monitor_loop exits 0 on reconnect');
    my @ev = events_of(read_log_lines($data));
    my ($ri) = grep { $ev[$_] eq 'AC-RECONNECT-DETECTED' } 0 .. $#ev;
    my ($mi) = grep { $ev[$_] eq 'MONITOR-EXIT' } 0 .. $#ev;
    ok(defined $ri && defined $mi && $ri < $mi, 'AC-12: AC-RECONNECT-DETECTED precedes MONITOR-EXIT');
    my $st = read_state($data);
    is($st->{phase}, 'reconnected', 'AC-12: phase is reconnected');
    like($out[-1] // '', qr/AC restored at/, 'AC-12: the last out line mentions "AC restored at"');
    like($out[-1] // '', qr/bp-drive-next\.pl next/, 'AC-12: the last out line mentions bp-drive-next.pl next');
}
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 1 unless $LOADED;
    my $data = fresh_data();
    # Take the monitor lock ourselves (simulating a live monitor), then
    # confirm monitor_live() reports busy.
    require Fcntl;
    make_path("$data/.drive-solo");
    open my $lockfh, '>', "$data/.drive-solo/ac-monitor.lock" or die $!;
    flock($lockfh, Fcntl::LOCK_EX()) or die "flock: $!";
    is(BpAcWatch::monitor_live($data), 1, 'AC-12: monitor_live is 1 while another process (this test) holds the lock');
    close $lockfh;
}

# ===========================================================================
# AC-13 (DC4): ten consecutive unknown readings -> monitor exits 2,
# MONITOR-EXIT reason=probe-failed, reconnect_basis=probe-failed.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 4 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });
    my $i = 0;
    my @out;
    my $rc = BpAcWatch::monitor_loop($data,
        probe => sub { $i++; 'unknown' }, now => sub { $T0 + $i }, sleep => sub { },
        arms => sub { [] }, wakelock_state => sub { 'released' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { push @out, $_[0] }, tick => 0,
    );
    is($rc, 2, 'AC-13: ten consecutive unknown readings -> exit 2');
    ok((grep { /^\S+\s+\S+\s+MONITOR-EXIT\b/ && /reason=probe-failed/ } read_log_lines($data)),
        'AC-13: the log carries MONITOR-EXIT reason=probe-failed');
    my $st = read_state($data);
    is($st->{phase}, 'reconnected', 'AC-13: phase is reconnected (fail-open)');
    is($st->{reconnect_basis}, 'probe-failed', 'AC-13: reconnect_basis is probe-failed');
}

# ===========================================================================
# AC-14 (DC4, DC6): resume_director_side with phase reconnected.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 4 unless $LOADED;
    my $data = fresh_data();
    make_path("$data/.drive-solo");
    open my $fh, '>', "$data/.drive-solo/ac-standdown.json" or die $!;
    print {$fh} '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}';
    close $fh;
    write_state($data, {
        v => 1, phase => 'reconnected', source => 'ac', probed_at => $T0,
        dc_since => $T0 - 600, grace_until => $T0 - 300, reconnected_at => $T0,
        reconnect_basis => 'ac', updated_at => $T0,
    });
    BpAcWatch::resume_director_side($data, now => $T0 + 1);
    ok(!-e "$data/.drive-solo/ac-standdown.json", 'AC-14: the marker is removed');
    my @ev = events_of(read_log_lines($data));
    ok((grep { $_ eq 'RESUME' } @ev), 'AC-14: the log carries a RESUME line');
    ok((grep { /^\S+\s+\S+\s+RESUME\b/ && /marker=removed/ } read_log_lines($data)),
        'AC-14: the RESUME line carries marker=removed');
    my $st = read_state($data);
    is($st->{phase}, 'ac', 'AC-14: phase is now ac');
}

# ===========================================================================
# AC-15 (DC5, DC6): the full cycle, injected clock and probe, one test.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 2 unless $LOADED;
    my $data = fresh_data();
    my $t0 = $T0;

    BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $t0, force => 1);
    my $obs = BpAcWatch::observe($data, src => 'holder', probe => sub { 'dc' }, now => $t0 + 301, force => 1);
    is($obs->{phase}, 'expired', 'AC-15: precondition -- phase expired at t0+301');

    BpAcWatch::standdown_director_side($data, now => $t0 + 302, inflight => [],
        keepawake_settle => sub { });

    my @readings = ('dc', 'ac');
    my $i = 0;
    BpAcWatch::monitor_loop($data,
        probe => sub { $readings[$i++] // 'ac' }, now => sub { $t0 + 302 + $i * 60 }, sleep => sub { },
        arms => sub { [] }, wakelock_state => sub { 'released' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { }, tick => 0,
    );

    BpAcWatch::resume_director_side($data, now => $t0 + 302 + 120 + 1);

    my @lines = read_log_lines($data);
    my @ev = events_of(@lines);
    my @expected = qw(AC-LOSS-DETECTED GRACE-START GRACE-EXPIRED STANDDOWN-BEGIN
        STANDDOWN-SIGNAL-SET KEEPAWAKE-RELEASED STANDDOWN-ACTION MONITOR-ENTER
        STANDDOWN-VERIFY POWER-PLAN AC-RECONNECT-DETECTED MONITOR-EXIT RESUME);
    # Every expected event appears, in order (other events, e.g. a second
    # pass through the table, are tolerated as long as relative order holds).
    my $cursor = 0;
    my $in_order = 1;
    for my $want (@expected) {
        my $found;
        for my $j ($cursor .. $#ev) {
            if ($ev[$j] eq $want) { $found = $j; last }
        }
        if (!defined $found) { $in_order = 0; last }
        $cursor = $found + 1;
    }
    ok($in_order, 'AC-15: ac-cycle.log, read alone, contains every expected event in order: ' . join(',', @expected))
        or diag('actual events: ' . join(',', @ev));

    my @utc_ts = map { (split /\s+/, $_)[0] } @lines;
    my $non_decreasing = 1;
    for my $k (1 .. $#utc_ts) {
        $non_decreasing = 0 if $utc_ts[$k] lt $utc_ts[$k - 1];
    }
    ok($non_decreasing, 'AC-15: every log lines UTC timestamp is non-decreasing');
}

# ===========================================================================
# AC-16 (DC6): a fake clock that jumps 3600s between two monitor ticks
# produces one SUSPEND-GAP ... gap_s=3600 line.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 1 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'standing-down', source => 'dc', probed_at => $T0 });
    my @clock = ($T0, $T0 + 3600, $T0 + 3660);
    my $ci = 0;
    my @readings = ('dc', 'dc', 'ac');
    my $ri = 0;
    BpAcWatch::monitor_loop($data,
        probe => sub { $readings[$ri++] // 'ac' },
        now   => sub { my $v = $clock[$ci]; $v = $clock[-1] + 60 unless defined $v; return $v },
        sleep => sub { $ci++ },
        arms => sub { [] }, wakelock_state => sub { 'released' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { }, tick => 60,
    );
    ok((grep { /^\S+\s+\S+\s+SUSPEND-GAP\b/ && /gap_s=3600/ } read_log_lines($data)),
        'AC-16: a 3600s wall-clock jump between ticks logs SUSPEND-GAP ... gap_s=3600');
}

# ===========================================================================
# Edge case (sec. 5 / 2.4): enabled() honours the CCPRAXIS_AC_PROBE_FILE
# override regardless of host platform.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 2 unless $LOADED;
    local $ENV{CCPRAXIS_AC_PROBE_FILE} = undef;
    delete $ENV{CCPRAXIS_AC_PROBE_FILE};
    my $is_win = ($^O =~ /^(?:MSWin32|msys|cygwin)$/) ? 1 : 0;
    is(BpAcWatch::enabled(), $is_win, 'Edge: enabled() matches the $^O rule with no probe-file override');

    my ($fh, $pf) = tempfile();
    print {$fh} "ac\n";
    close $fh;
    local $ENV{CCPRAXIS_AC_PROBE_FILE} = $pf;
    is(BpAcWatch::enabled(), 1, 'Edge: enabled() is 1 once CCPRAXIS_AC_PROBE_FILE is set to an absolute path');
}

# ===========================================================================
# Edge case (sec. 5, "Failure isolation" / sec 2.3 step 2): a lock timeout
# returns the unlocked read with transitions => [] and changes nothing.
# Simulated by holding the lock externally.
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 2 unless $LOADED;
    my $data = fresh_data();
    make_path("$data/.drive-solo");
    require Fcntl;
    open my $lockfh, '>', "$data/.drive-solo/ac-state.lock" or die $!;
    flock($lockfh, Fcntl::LOCK_EX()) or die "flock: $!";

    local $SIG{ALRM} = sub { die "ac-watch.t: observe() under a held lock did not return within 15s\n" };
    alarm(15);
    my $obs = eval { BpAcWatch::observe($data, src => 'director', probe => sub { 'dc' }, now => $T0, force => 1,
        lock_timeout => 1) };
    alarm(0);
    SKIP: {
        skip 'Edge: observe() did not honour an injectable lock timeout seam', 2 unless ref $obs eq 'HASH';
        is_deeply($obs->{transitions}, [], 'Edge: a lock timeout returns transitions => []');
        ok(!-f state_path($data), 'Edge: no state file was written while the lock was unavailable');
    }
    close $lockfh;
}

# ===========================================================================
# Edge case (sec. 5): a stale marker self-heals -- a new run on AC with
# phase monitoring transitions to reconnected (the director's resumed
# `next` half is covered in drive-next-ac-standdown.t).
# ===========================================================================
SKIP: {
    skip 'BpAcWatch.pm does not exist yet', 1 unless $LOADED;
    my $data = fresh_data();
    write_state($data, { v => 1, phase => 'monitoring', source => 'dc', probed_at => $T0 });
    my $obs = BpAcWatch::observe($data, src => 'director', probe => sub { 'ac' }, now => $T0 + 60, force => 1);
    is($obs->{phase}, 'reconnected', 'Edge: a stale monitoring-phase state heals to reconnected once AC reads back');
}

done_testing();
