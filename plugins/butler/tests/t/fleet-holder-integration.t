#!/usr/bin/env perl
# platform: any
# ORACLE for package 08 of blueprint hook-continuity-remake:
# specs/08-fleet-on-holder-spec.md's acceptance criteria AC-1..AC-15 (AC-16 is
# validated OUTSIDE this file, per its own row: it re-runs the sibling gate
# and shutdown-clear suites unmodified). The Decision 19 switch is the env var
# BUTLER_CONCURRENCY: "on" only when its value is exactly "1". With it off,
# bp-launch.sh and the two new BpOrch subs (fleet_holder_on, coordinator_holding)
# must be byte-for-byte today's behavior. With it on, the fleet grows a holder
# path that a coordinator-shaped session can wait through and stop on.
#
# fleet_holder_on() and coordinator_holding() DO NOT EXIST YET on bp-orchestrator.pl,
# and bp-launch.sh's BUTLER_CONCURRENCY branch does not exist either. Every
# switch-on assertion below is written to fail LEGIBLY against that absence: a
# direct call to either new sub dies "Undefined subroutine", wrapped in eval so
# one missing sub cannot take down the rest of this file; the watchdog-holder
# tick simply behaves exactly as it does today (kills a wedged coordinator
# immediately, never defers for a holder); and the launcher's env/PATH/warning
# checks simply see nothing changed. The switch-OFF assertions describe TODAY's
# behavior and are expected to pass now, unmodified.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

# ---------------------------------------------------------------------------
# process bookkeeping -- every spawned pid is TERM-ed then KILL-ed in END,
# routed through exit() so END always runs (per driver instructions).
# ---------------------------------------------------------------------------
my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('TERM', $pid) }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid) if kill(0, $pid) }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, 0) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ---------------------------------------------------------------------------
# hermetic environment
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
my ($REAL_BPDATA, $REAL_BPDATA_EXISTS, $REAL_BPDATA_MTIME);
{
    my $rh = $ENV{HOME} // $ENV{USERPROFILE};
    if (defined $rh && length $rh) {
        (my $rhn = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE = "$rhn/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
        $REAL_BPDATA = "$rhn/.ccpraxis-local-data";
        $REAL_BPDATA_EXISTS = -d $REAL_BPDATA ? 1 : 0;
        $REAL_BPDATA_MTIME  = $REAL_BPDATA_EXISTS ? (stat($REAL_BPDATA))[9] : undef;
    }
}
my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME} = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;

sub fresh_state_root { my $t = tempdir(CLEANUP => 1); (my $r = "$t/state") =~ s{\\}{/}g; return $r }

(my $BUTLER  = "$Bin/../..") =~ s{\\}{/}g;
my $SCRIPTS  = "$BUTLER/scripts";
my $ORCH     = "$SCRIPTS/bp-orchestrator.pl";
my $LAUNCH   = "$SCRIPTS/bp-launch.sh";
my $BPHOOKPM = "$SCRIPTS/BpHook.pm";
my $STOPGATE = "$SCRIPTS/BpHook/StopGate.pm";
my $HOLDPL   = "$SCRIPTS/butler-hold.pl";
my $HOLDSHIM = "$BUTLER/bin/butler-hold";
my $SKILL    = "$BUTLER/skills/coordinator-protocol/SKILL.md";

ok(-r $ORCH,     "subject present: bp-orchestrator.pl ($ORCH)");
ok(-r $LAUNCH,   "subject present: bp-launch.sh ($LAUNCH)");
ok(-r $BPHOOKPM, "subject present: BpHook.pm ($BPHOOKPM)");
ok(-r $STOPGATE, "subject present: BpHook/StopGate.pm ($STOPGATE)");
ok(-r $HOLDPL,   "subject present: butler-hold.pl ($HOLDPL)");

require "$BPHOOKPM";
require "$STOPGATE";
require "$ORCH";    # BpOrch:: -- caller-guarded (bp-orchestrator.pl:5846 `unless (caller)`)

# ---------------------------------------------------------------------------
# small shared helpers
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}
sub lines_of {
    my ($text) = @_;
    my @l = split /\n/, $text;
    pop @l while @l && $l[-1] eq '';
    return @l;
}
sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes;
    close $w;
}
my $J = JSON::PP->new->utf8->canonical;
# RV: Time::HiRes::time() returns a FRACTIONAL epoch. Every epoch this file
# writes to disk (a holder deadline, a creds expiresAt) must be a plain
# integer -- both bp-contract.pl's validate_creds (_is_int, /^\d+$/) and this
# spec's own coordinator_holding rule (deadline =~ /^\d+$/) reject a float
# outright, which silently wedges the whole simulation in a creds-drift pause
# loop rather than failing any single assertion legibly. Use this for every
# epoch that is written, never bare time().
sub epoch_now { return int(Time::HiRes::time()) }
my $sidn = 0;
sub next_sid { return sprintf('f08-%04x', ++$sidn) }
sub sid8 { return substr($_[0], 0, 8) }

sub wait_pid_bounded {
    my ($pid, $timeout) = @_;
    my $deadline = time() + $timeout;
    my $status;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $status = $?; last }
        sleep(0.02);
    }
    unless (defined $status) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        return -1;
    }
    # shell-style exit-code convention: 128+signal on a signal death, else the
    # real exit code -- see AC-10 (a SIGTERM'd holder "exits 143").
    return ($status & 127) ? (128 + ($status & 127)) : ($status >> 8);
}

# ---------------------------------------------------------------------------
# AC-6/9/10/12: BUTLER_STATE_DIR holder-record + ledger fixtures, in-process
# StopGate driving (dup STDERR through a File::Temp file, never a scalar).
# ---------------------------------------------------------------------------
sub with_captured_stderr {
    my ($code) = @_;
    my (undef, $path) = tempfile();
    open(my $saved, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDERR, '>', $path) or die "redirect STDERR: $!";
    my $rc = $code->();
    close STDERR;
    open(STDERR, '>&', $saved) or die "restore STDERR: $!";
    close $saved;
    my $err = slurp($path);
    unlink $path;
    return ($rc, $err);
}
sub gate_run {
    my ($payload, %env) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }
    my ($rc, $err) = with_captured_stderr(sub { return BpHook::StopGate::run($payload) });
    return { rc => $rc, err => $err };
}
my $bpn = 0;
sub mk_bp {
    my ($status, $next, %sig) = @_;
    my $dir = tempdir(CLEANUP => 1); (my $dirn = $dir) =~ s{\\}{/}g;
    $bpn++;
    make_path("$dirn/runs", "$dirn/packages");
    open my $l, '>:raw', "$dirn/packages/p.md" or die $!;
    print {$l} "---\npackage: p\nstatus: $status\nlast_updated: 2026-06-24T00:00:00Z\n---\n# p\n\n## Next action\n\n$next\n";
    close $l;
    for my $s (qw(shutdown paused)) {
        if ($sig{$s}) { open my $h, '>', "$dirn/runs/.$s" or die $!; close $h }
    }
    if ($sig{forcestop}) { open my $h, '>', "$dirn/runs/p.force-stop" or die $!; close $h }
    return ($dirn, "$dirn/packages/p.md");
}
sub env_for {
    my ($dir, $led, $root, %extra) = @_;
    return (BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir,
            BUTLER_STATE_DIR => $root, %extra);
}
sub write_holder {
    my ($root, $sid, %fields) = @_;
    my $hdir = "$root/continuity/holder";
    make_path($hdir);
    my %rec = (session_id => $sid, token => 'aaaaaaaa', items => ['A'], %fields);
    open my $fh, '>:raw', "$hdir/$sid.json" or die $!;
    print {$fh} $J->encode(\%rec);
    close $fh;
}
sub payload {
    my ($sid, %extra) = @_;
    return { session_id => $sid, hook_event_name => 'Stop', %extra };
}

# ===========================================================================
# AC-5 (batch C, spec 16-cutover 2.8, reason SW): fleet_holder_on() is
# deleted -- the holder path is unconditional now, so there is no switch left
# to exercise. Proves the sub itself is gone rather than merely inert.
# ===========================================================================
{
    ok(!defined(&BpOrch::fleet_holder_on),
        'SW (2.8): BpOrch::fleet_holder_on no longer exists -- the holder path is unconditional');
}

# ===========================================================================
# AC-6 -- coordinator_holding($sid,$now) truth table (switch on), plus the
# switch-off case run in a genuinely separate child perl that asserts
# BpHook.pm never entered %INC.
# ===========================================================================
{
    my $now = epoch_now();
    my $root = fresh_state_root();
    my $sid  = next_sid();
    write_holder($root, $sid, deadline => $now + 1800);
    local %ENV = %ENV;
    $ENV{BUTLER_CONCURRENCY} = 1;
    $ENV{BUTLER_STATE_DIR}   = $root;

    my $r = eval { BpOrch::coordinator_holding($sid, $now) };
    diag("died: $@") if $@;
    is($r, 1, 'AC-6: a valid, unexpired record within the 1h cap gives 1');

    my $sid_exp = next_sid();
    write_holder($root, $sid_exp, deadline => $now - 10);
    my $r_exp = eval { BpOrch::coordinator_holding($sid_exp, $now) };
    diag("died: $@") if $@;
    is($r_exp, 0, 'AC-6: an expired record gives 0');

    my $sid_far = next_sid();
    write_holder($root, $sid_far, deadline => $now + 4000);
    my $r_far = eval { BpOrch::coordinator_holding($sid_far, $now) };
    diag("died: $@") if $@;
    is($r_far, 0, 'AC-6: a deadline more than 1h out (now+4000) gives 0');

    my $sid_nan = next_sid();
    write_holder($root, $sid_nan, deadline => 'not-a-number');
    my $r_nan = eval { BpOrch::coordinator_holding($sid_nan, $now) };
    diag("died: $@") if $@;
    is($r_nan, 0, 'AC-6: a non-numeric deadline gives 0');

    my $sid_other = next_sid();
    write_holder($root, $sid_other, deadline => $now + 1800);
    my $r_wrong = eval { BpOrch::coordinator_holding(next_sid(), $now) };
    diag("died: $@") if $@;
    is($r_wrong, 0, 'AC-6: a record that exists but is for another sid gives 0');

    my $r_missing = eval { BpOrch::coordinator_holding(next_sid(), $now) };
    diag("died: $@") if $@;
    is($r_missing, 0, 'AC-6: no record at all gives 0');

    my $r_bad = eval { BpOrch::coordinator_holding('bad/sid with spaces', $now) };
    diag("died: $@") if $@;
    is($r_bad, 0, 'AC-6: a bad-shaped sid gives 0');

    # R9-C1 (review m5): a corrupt/unparseable record -- not merely a wrong
    # TYPE of value, but bytes that are not JSON at all -- must also give 0
    # and never die.
    my $sid_corrupt = next_sid();
    write_file("$root/continuity/holder/$sid_corrupt.json", "{ this is not json ][\x00\xff");
    my $r_corrupt = eval { BpOrch::coordinator_holding($sid_corrupt, $now) };
    diag("died: $@") if $@;
    is($r_corrupt, 0, 'R9-C1: a corrupt, unparseable JSON record gives 0');

    # Batch C (spec 16-cutover 2.8, reason SW): the switch-off child-perl
    # case above is retired -- there is no more "switch off" state to prove
    # a fresh child never loads BpHook.pm for.
}

# ===========================================================================
# AC-7 / AC-8 -- watchdog: alive coordinator, frozen log past flat. With the
# switch on and a holder deadline in the future, watchdog_flat_held logs and
# no cold-relaunch happens until the deadline passes; with the switch off (or
# once the deadline passes), watchdog_kill_wedged fires as it does today.
# ---------------------------------------------------------------------------
# Mechanics mirror orchestrator-loop-simulation.t's run_sim: a fake clock
# driven entirely by the injected `sleep` closure, a single package "A" whose
# fake coordinator grows its jsonl once at launch and then freezes (a wedge),
# and injected launch/pid_alive/now seams. sleep() itself watches the growing
# orchestrator.log and stops the run (via die, caught below) once it has seen
# what each variant needs to see, rather than guessing an exact tick count.
# ===========================================================================
sub write_creds {
    my ($p, $now) = @_;
    write_file($p, $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => ($now + 100 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
}
sub base_tun08 {
    my %o = @_;
    return { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 2, cap => 5, flat => 25, watch_tick => 10,
              keeper_int => 600, keeper_bo => 120, thresh_min => 60, jit_lo => 0, jit_hi => 0, tele_retry => 3,
              usage_fail => 60, busy_path => $o{busy_path}, harvest => 'audit', resolve_cap => 1, corr_cap => 1,
              judge_to => 100000, judge_spawn_cap => 3, %o };
}
sub grow_jsonl08 {
    my ($runs, $pkg, $clock) = @_;
    my $f = "$runs/$pkg.jsonl";
    my @t = gmtime($clock);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000Z', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    open my $w, '>>', $f or return;
    print $w $J->encode({ type => 'assistant', timestamp => $iso,
                          message => { usage => { cache_read_input_tokens => 4096, cache_creation_input_tokens => 0 } } }), "\n";
    close $w;
    utime $clock, $clock, $f;
}
sub epoch_to_iso08 {
    my ($clock) = @_;
    my @t = gmtime($clock);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}
sub mk_bp08 {
    my $dir = tempdir(CLEANUP => 1); (my $dirn = $dir) =~ s{\\}{/}g;
    make_path("$dirn/packages", "$dirn/runs");
    open my $b, '>:utf8', "$dirn/blueprint.md" or die $!;
    print $b "# T08\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n| A | d | \x{2014} | sonnet | pending |\n";
    close $b;
    open my $l, '>', "$dirn/packages/A.md" or die $!;
    print $l "---\npackage: A\nblueprint: T08\nstatus: pending\nwrite_set: p/a/\ntest_paths: p/a/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# A\n\n## Next action\n\ngo\n";
    close $l;
    return $dirn;
}

# run_wedge_sim(%o) -> { err, log, launched, root, now0, deadline }
sub run_wedge_sim {
    my (%o) = @_;
    my $dir  = mk_bp08();
    my $runs = "$dir/runs";
    my $now0 = epoch_now();
    write_creds("$dir/creds.json", $now0);
    my $root = fresh_state_root();
    local $ENV{BUTLER_STATE_DIR} = $root;
    my $sid  = 'sid-A';
    my $deadline = $now0 + $o{deadline_offset};
    if ($o{with_holder}) {
        make_path("$root/continuity/holder");
        write_holder($root, $sid, deadline => $deadline,
            (defined $o{holder_started_at} ? (started_at => $now0 + $o{holder_started_at}) : ()));
    }
    my $tun = base_tun08(busy_path => "$dir/busy");
    my $clock = $now0;
    my $relaunches = 0;
    my %alive;
    my $pidn = 900000;
    my @launched;
    my $launch = sub {
        my ($a) = @_;
        push @launched, { %$a, clock => $clock };
        $relaunches++;
        my $mypid = ++$pidn;
        $alive{$mypid} = 1;
        my $att = (BpOrch::read_registry($runs)->{A}{attempt} // 0) + 1;
        # R9-M2: a real bp-launch.sh writes launched_at into the registry
        # alongside pid/session_id at every launch (bp-orchestrator.pl:309-314);
        # the sim's fake launch seam does the same so a stale pre-launch holder
        # record can be told apart from one belonging to this incarnation.
        BpOrch::update_registry_pkg($runs, 'A', { pid => $mypid, status => 'running', attempt => $att,
            session_id => $sid, launched_at => epoch_to_iso08($clock) });
        grow_jsonl08($runs, 'A', $clock);
        return (0, $mypid);
    };
    my ($first_pid);
    my $pid_alive = sub { my $p = shift; return (defined $p && $alive{$p}) ? 1 : 0 };
    my $ticks = 0;
    my $mid_snapshot;
    my $sleep = sub {
        my ($secs) = @_;
        $clock += ($secs || $tun->{watch_tick});
        $ticks++;
        die "AC0708-GUARD: too many ticks\n" if $ticks > 400;
        # once the coordinator has been relaunched (cold), let the NEW one
        # finish cleanly on its very next observation, so the sim can idle down.
        if ($relaunches >= 2) {
            for my $p (keys %alive) { delete $alive{$p} }
            open my $s, '>:raw', "$dir/packages/A.md" or die $!;
            print $s "---\npackage: A\nblueprint: T08\nstatus: done\nwrite_set: p/a/\ntest_paths: p/a/\nlast_updated: 2026-06-24T00:00:00Z\n---\n# A\n\n## Next action\n\n\n";
            close $s;
        }
        my $logtxt = slurp("$runs/orchestrator.log");
        if (!defined $mid_snapshot && $logtxt =~ /watchdog_flat_held/) {
            $mid_snapshot = $logtxt;
        }
        die "AC0708-DONE\n" if $logtxt =~ /watchdog_kill_wedged/;
    };
    my $err;
    eval {
        BpOrch::run({ blueprint => 'T08', bp_dir => $dir, creds_path => "$dir/creds.json", tunables => $tun,
            now => sub { $clock }, sleep => $sleep,
            http_get => sub { { status => 200, content => $J->encode({
                five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } }) } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => $launch, pid_alive => $pid_alive, spawn_judge => sub { 0 } });
        1;
    } or $err = $@;
    if (defined $err && $err eq "AC0708-DONE\n") { $err = undef }
    return { err => $err, log => slurp("$runs/orchestrator.log"), mid => $mid_snapshot,
             launched => \@launched, now0 => $now0, deadline => $deadline, flat => $tun->{flat} };
}

{
    # AC-7: switch on, holder deadline comfortably in the future (well beyond
    # the flat window, but within the 1h cap).
    local %ENV = %ENV;
    $ENV{BUTLER_CONCURRENCY} = 1;
    my $r = run_wedge_sim(with_holder => 1, deadline_offset => 1800);
    ok(defined $r->{mid} || defined $r->{log},
        'AC-7 setup: the simulation produced an orchestrator.log') or diag("err=" . ($r->{err} // '(none)'));
    like($r->{mid} // '', qr/watchdog_flat_held/,
        'AC-7: switch on, holder deadline in the future -- watchdog_flat_held is logged while still flat')
        or diag("full log:\n" . $r->{log});
    unlike($r->{mid} // '', qr/watchdog_kill_wedged/,
        'AC-7: ...and watchdog_kill_wedged has NOT fired yet at that same snapshot (deadline still future)')
        or diag("full log:\n" . $r->{log});

    # R9-C2 (review m4 / red-team MEDIUM-1): the SAME run must eventually see
    # the held-to-killed transition once the hold lapses -- this is not a
    # separate already-expired fixture (that is $r2 below, which has no prior
    # held tick and is unaffected by the grace-period fix). AC-7's spec
    # behavior 6 requires "once the deadline passes, kill", so this run must
    # still end in a cold relaunch.
    like($r->{log}, qr/watchdog_kill_wedged/,
        'R9-C2 [AC-7]: the same run that logged watchdog_flat_held also gets watchdog_kill_wedged once its hold lapses')
        or diag("full log:\n" . $r->{log});
    cmp_ok(scalar(@{ $r->{launched} }), '>=', 2,
        'R9-C2 [AC-7] setup: a cold relaunch happened after the hold lapsed') or diag("log:\n" . $r->{log});
    SKIP: {
        skip 'R9-M1: no relaunch captured', 1 unless @{ $r->{launched} } >= 2;
        # R9-M1 (red-team MEDIUM-1): the hold must RESTART the flat clock at
        # the deadline, not merely suspend it while held. Without the fix,
        # the tick right after the deadline already sees a huge mtime-based
        # quiet time (the log has been frozen since launch) and the very next
        # tick kills the coordinator. The fix measures quiet from
        # max(mtime, last hold deadline), so a live coordinator gets one full
        # `flat` window of grace after its hold ends before it is judged
        # wedged. AMENDS AC-7's earlier "kill fires the instant the deadline
        # passes" expectation: it now fires only after deadline + flat.
        cmp_ok($r->{launched}[1]{clock}, '>=', $r->{deadline} + $r->{flat},
            'R9-M1: the kill/relaunch happens only after a full flat window past the deadline, not immediately after it')
            or diag("launched[1]{clock}=" . $r->{launched}[1]{clock} . " deadline=" . $r->{deadline} . " flat=" . $r->{flat});
    }

    # R9-C3 (review m2 / red-team LOW-3): watchdog_flat_held must log once per
    # hold (on the transition into held), never once per tick -- a 1800s hold
    # at a 10s watch_tick would otherwise write ~150+ identical lines.
    my $held_count = () = $r->{log} =~ /watchdog_flat_held/g;
    is($held_count, 1, 'R9-C3: watchdog_flat_held is logged once per hold, not on every flat tick')
        or diag("held_count=$held_count\nfull log:\n" . $r->{log});

    # A second run whose holder deadline is already in the PAST at start:
    # the watchdog must kill+cold-relaunch on the very first flat tick,
    # exactly as an expired hold means no hold at all.
    my $r2 = run_wedge_sim(with_holder => 1, deadline_offset => -10);
    like($r2->{log}, qr/watchdog_kill_wedged/,
        'AC-7: once the holder deadline has passed, the same package gets watchdog_kill_wedged')
        or diag("err=" . ($r2->{err} // '(none)') . "\nlog:\n" . $r2->{log});
    cmp_ok(scalar(@{ $r2->{launched} }), '>=', 2,
        'AC-7: ...and a cold relaunch actually happened (launched at least twice)');
}

# AC-8 (batch C, spec 16-cutover 2.8, reason SW): the switch-off wedge
# fixture is retired -- there is no more "switch off" state in which a
# holder is ignored and the coordinator is killed immediately.
# [fixed here, package 16 batch D]: batch C left this as an EMPTY bare block
# ({ # comment-only \n }), which does not compile -- Perl's heuristic for a
# statement-position "{" with nothing but a comment inside parses ambiguously
# and the file fails perl -c. Replaced with a plain comment (no block).

# ===========================================================================
# R9-M2 (red-team MEDIUM-2a): a holder record whose started_at PREDATES this
# package's own launched_at (as written into the registry at launch, per
# bp-orchestrator.pl:309-314) must NOT spare the coordinator, even with a
# comfortably-future deadline. Such a record belongs to an earlier, already-
# dead incarnation of this session id (a warm resume that inherited the
# stale holder record of a process that died mid-hold) -- it is not evidence
# that the CURRENT process is legitimately waiting.
# ===========================================================================
{
    local %ENV = %ENV;
    $ENV{BUTLER_CONCURRENCY} = 1;
    my $r = run_wedge_sim(with_holder => 1, deadline_offset => 1800,
        holder_started_at => -500);   # 500s before this incarnation's own launched_at
    unlike($r->{mid} // $r->{log}, qr/watchdog_flat_held/,
        'R9-M2: a holder record started before this package\'s own launched_at never grants the flat exemption')
        or diag("full log:\n" . $r->{log});
    like($r->{log}, qr/watchdog_kill_wedged/,
        'R9-M2: ...and the coordinator is killed as wedged rather than spared')
        or diag("full log:\n" . $r->{log});
    cmp_ok(scalar(@{ $r->{launched} }), '>=', 2, 'R9-M2 setup: a cold relaunch happened') or diag("log:\n" . $r->{log});
    SKIP: {
        skip 'R9-M2: no relaunch captured', 1 unless @{ $r->{launched} } >= 2;
        cmp_ok($r->{launched}[1]{clock}, '<', $r->{now0} + 100,
            'R9-M2: ...and the kill happens promptly, not deferred until anywhere near the stale record\'s (now+1800) deadline');
    }
}

# ===========================================================================
# AC-9 -- Behaviors 8a-8f in order, in-process, against one session id.
# ===========================================================================
{
    my $root = fresh_state_root();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $sid = next_sid();
    my %env = env_for($dir, $led, $root);

    {
        local %ENV = %ENV;
        for my $k (keys %env) { $ENV{$k} = $env{$k} }
        is(BpHook::role({ session_id => $sid }), 'coordinator', 'AC-9: precondition -- BpHook::role is coordinator');
        ok(BpHook::is_armed($sid), 'AC-9: precondition -- BpHook::is_armed is 1');
    }
    ok(!-e "$root/continuity/armed/$sid", 'AC-9: precondition -- no armed/<sid> file exists (armed by construction)');

    # (a) deny: non-terminal ledger, no holder yet.
    my $p_running = payload($sid, background_tasks => [{ id => 'A', type => 'subagent', status => 'running' }]);
    local %ENV = %ENV;
    for my $k (keys %env) { $ENV{$k} = $env{$k} }
    my ($rc_a, $err_a) = with_captured_stderr(sub { return BpHook::StopGate::run($p_running) });
    is($rc_a, 2, 'AC-9 (8a): before any holder -- refused, exit 2');
    my ($reason, $tok) = ((lines_of($err_a))[0] // '') =~ /^Coordinator stop refused: (.+)\. Stop token: ([0-9a-f]{8})$/;
    like((lines_of($err_a))[0] // '', qr/status 'running' is not terminal/, "AC-9 (8a): stderr line 1 names the ledger reason");
    ok(defined $tok, 'AC-9 (8a): a stop token was minted') or diag($err_a);

    SKIP: {
        skip 'AC-9: no token minted, cannot continue the sequence', 12 unless defined $tok;

        # (b) hold: a real butler-hold.pl, backgrounded, with the test seam.
        my ($pid, $outfile, $errfile) = (undef, undef, undef);
        {
            (undef, $outfile) = tempfile();
            (undef, $errfile) = tempfile();
            $pid = fork();
            die "fork: $!" unless defined $pid;
            if ($pid == 0) {
                delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
                $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
                $ENV{BUTLER_STATE_DIR} = $root;
                $ENV{BUTLER_HOLD_TEST_MODE}    = 1;
                $ENV{BUTLER_HOLD_TEST_SECONDS} = 3;
                $ENV{BUTLER_HOLD_TEST_TICK}    = 0.2;
                open(STDOUT, '>', $outfile) or _exit(126);
                open(STDERR, '>', $errfile) or _exit(126);
                exec('bash', $HOLDSHIM, '--token', $tok, 'A');
                _exit(127);
            }
        }
        push @KILL_PIDS, $pid;

        my $deadline1 = time() + 10;
        my $h;
        while (time() < $deadline1) {
            local %ENV = %ENV;
            $ENV{BUTLER_STATE_DIR} = $root;
            $h = BpHook::holder($sid);
            last if ref $h eq 'HASH';
            sleep(0.02);
        }
        ok(ref $h eq 'HASH', 'AC-9 (8b): holder/<sid>.json appears after the background become') or diag(slurp($errfile));

        my $out_deadline = time() + 10;
        my $out = '';
        while (time() < $out_deadline) {
            $out = slurp($outfile);
            last if $out =~ /^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/m;
            sleep(0.05);
        }
        like($out, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until \d\d:\d\d \(\d\d:\d\dZ\): A$/m,
            'AC-9 (8b): stdout prints "<T> holding session <sid8> until <D>: A"') or diag("stdout was: $out");

        # (c) allow: the same (a) payload now gives 0 (holder alive, A running).
        my ($rc_c) = with_captured_stderr(sub { return BpHook::StopGate::run($p_running) });
        is($rc_c, 0, 'AC-9 (8c): the same payload as (a), with the holder alive -- allowed, exit 0');

        # (d) wrong-shape deny: A completed / A absent / A a shell task.
        for my $variant (
            ['completed' => payload($sid, background_tasks => [{ id => 'A', type => 'subagent', status => 'completed' }])],
            ['shell'     => payload($sid, background_tasks => [{ id => 'A', type => 'shell',    status => 'running'   }])],
            ['absent'    => payload($sid, background_tasks => [])],
        ) {
            my ($label, $p) = @$variant;
            my ($rc_d, $err_d) = with_captured_stderr(sub { return BpHook::StopGate::run($p) });
            is($rc_d, 2, "AC-9 (8d) [$label]: gives 2 while the holder is alive but A is not a running subagent");
            like((lines_of($err_d))[0] // '', qr/the held ids are not running background subagents/,
                "AC-9 (8d) [$label]: reason names the held-ids rule");
        }

        # (e) the holder exits 0 at its (3s test-seam) deadline; the record is gone.
        my $rc_hold = wait_pid_bounded($pid, 10);
        @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
        is($rc_hold, 0, 'AC-9 (8e): the holder process exits 0 at its deadline');
        my $gone_deadline = time() + 10;
        my $gone = 0;
        while (time() < $gone_deadline) {
            local %ENV = %ENV;
            $ENV{BUTLER_STATE_DIR} = $root;
            unless (ref BpHook::holder($sid) eq 'HASH') { $gone = 1; last }
            sleep(0.02);
        }
        ok($gone, 'AC-9 (8e): the holder record is gone after the deadline');

        # (f) deny again: the (a) payload once more, with no holder left.
        my ($rc_f, $err_f) = with_captured_stderr(sub { return BpHook::StopGate::run($p_running) });
        is($rc_f, 2, 'AC-9 (8f): with no holder left, the (a) payload is refused again, exit 2');
        like((lines_of($err_f))[0] // '', qr/status 'running' is not terminal/, 'AC-9 (8f): the ledger reason, not the held-ids reason');

        unlink $outfile, $errfile;
    }
}

# ===========================================================================
# AC-10 -- a killed holder (headless-kill outcome): SIGTERM exits 143 (shell
# convention), the record survives, the stop is allowed until the deadline
# and denied after it.
# ===========================================================================
{
    my $root = fresh_state_root();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $sid = next_sid();
    my %env = env_for($dir, $led, $root);

    my $tok = do {
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = $root; $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
        BpHook::mint_stop_token($sid, { hook_event_name => 'Stop' });
    };
    ok(defined $tok, 'AC-10: precondition -- a stop token was minted');

    SKIP: {
        skip 'AC-10: no token minted', 6 unless defined $tok;
        my (undef, $outfile) = tempfile();
        my (undef, $errfile) = tempfile();
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
            $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
            $ENV{BUTLER_STATE_DIR} = $root;
            $ENV{BUTLER_HOLD_TEST_MODE}    = 1;
            $ENV{BUTLER_HOLD_TEST_SECONDS} = 3;
            $ENV{BUTLER_HOLD_TEST_TICK}    = 0.2;
            open(STDOUT, '>', $outfile) or _exit(126);
            open(STDERR, '>', $errfile) or _exit(126);
            exec('bash', $HOLDSHIM, '--token', $tok, 'K');
            _exit(127);
        }
        push @KILL_PIDS, $pid;

        my $deadline1 = time() + 10;
        my $h;
        while (time() < $deadline1) {
            local %ENV = %ENV;
            $ENV{BUTLER_STATE_DIR} = $root;
            $h = BpHook::holder($sid);
            last if ref $h eq 'HASH';
            sleep(0.02);
        }
        ok(ref $h eq 'HASH', 'AC-10: precondition -- the holder became') or diag(slurp($errfile));
        my $expected_deadline = ref $h eq 'HASH' ? $h->{deadline} : undef;

        kill('TERM', $pid);
        my $rc = wait_pid_bounded($pid, 10);
        @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
        is($rc, 143, 'AC-10: a SIGTERM to the holder exits 143 (shell convention: 128+SIGTERM)');

        my $h2 = do {
            local %ENV = %ENV; $ENV{BUTLER_STATE_DIR} = $root; BpHook::holder($sid);
        };
        ok(ref $h2 eq 'HASH', 'AC-10: the record still exists after the holder is killed');

        SKIP: {
            skip 'AC-10: no deadline captured', 2 unless defined $expected_deadline;
            my $p = payload($sid, background_tasks => [{ id => 'K', type => 'subagent', status => 'running' }]);
            local %ENV = %ENV;
            for my $k (keys %env) { $ENV{$k} = $env{$k} }
            my ($rc_before) = with_captured_stderr(sub { return BpHook::StopGate::run($p) });
            is($rc_before, 0, 'AC-10: while the deadline is still in the future, the stop is still allowed (no pid check)');

            my $wait = $expected_deadline - time() + 1;
            sleep($wait) if $wait > 0;
            my ($rc_after) = with_captured_stderr(sub { return BpHook::StopGate::run($p) });
            is($rc_after, 2, 'AC-10: once the deadline has passed, the stop is denied');
        }
        unlink $outfile, $errfile;
    }
}

# ===========================================================================
# AC-11 -- terminal fresh ledger, no holder at all -> 0. A non-terminal
# ledger without a holder is still refused (batch C, spec 16-cutover, reason
# SW: the "switch off" half is retired -- there is only one behaviour now).
# ===========================================================================
{
    my $root = fresh_state_root();
    my ($dir, $led) = mk_bp('done', '');
    my %env = env_for($dir, $led, $root);
    my ($rc) = with_captured_stderr(sub { return BpHook::StopGate::run(payload(next_sid(), background_tasks => [])) });
    local %ENV = %ENV; for my $k (keys %env) { $ENV{$k} = $env{$k} }
    my $res = gate_run(payload(next_sid(), background_tasks => []), %env);
    is($res->{rc}, 0, 'AC-11: a terminal, fresh ledger with no holder at all gives 0');

    my ($dir2, $led2) = mk_bp('running', 'keep going');
    my $res2 = gate_run(payload(next_sid()), env_for($dir2, $led2, fresh_state_root()));
    is($res2->{rc}, 2, 'AC-11: a non-terminal ledger with no holder is still refused');
}

# ===========================================================================
# AC-12 -- Behavior 11's gate part: force-stop, pause+terminal, pause+shutdown
# (batch C, spec 16-cutover, reason SW: the "switch off"/"switch on" pairing
# is retired -- there is only one behaviour now, with no BUTLER_CONCURRENCY
# in the environment at all).
# ===========================================================================
{
    {
        my ($dir, $led) = mk_bp('running', 'keep going', forcestop => 1);
        my $before = slurp($led);
        my $res = gate_run(payload(next_sid()), env_for($dir, $led, fresh_state_root()));
        is($res->{rc}, 0, 'AC-12 [force-stop]: exit 0');
        ok(!-e "$dir/runs/p.force-stop", 'AC-12 [force-stop]: the force-stop file is removed');
        is(slurp($led), $before, 'AC-12 [force-stop]: ledger bytes unchanged');
    }

    {
        my ($dir, $led) = mk_bp('done', 'Reviewed and closed.', paused => 1);
        my $root = fresh_state_root();
        my $sid = next_sid();
        write_holder($root, $sid, deadline => epoch_now() + 1800);
        my $res = gate_run(payload($sid, background_tasks => [{ id => 'A', type => 'subagent', status => 'running' }]),
            env_for($dir, $led, $root));
        is($res->{rc}, 2, 'AC-12 [pause+terminal]: exit 2 even with a live holder');
        like((lines_of($res->{err}))[0] // '', qr/a fleet pause is active and status 'done' is terminal/,
            'AC-12 [pause+terminal]: reason names the pause+terminal rule');
        ok(-e "$dir/runs/.paused", 'AC-12 [pause+terminal]: .paused left in place');
    }

    {
        my ($dir, $led) = mk_bp('running', 'keep going', paused => 1, shutdown => 1);
        my $res = gate_run(payload(next_sid()), env_for($dir, $led, fresh_state_root()));
        is($res->{rc}, 2, 'AC-12 [pause+shutdown]: falls through to the ledger rule, exit 2');
        like((lines_of($res->{err}))[0] // '', qr/status 'running' is not terminal/,
            'AC-12 [pause+shutdown]: the ledger reason');
    }
}

# ===========================================================================
# AC-13 -- Behavior 11's orchestrator part: run({once=>1}) with runs/.shutdown
# present, then separately with an active runs/.paused, records identical
# launch-seam calls between the two switch states, and never touches those
# files differently.
# ===========================================================================
sub run_once_marker {
    my ($marker, $conc) = @_;
    my $dir = mk_bp08();
    my $runs = "$dir/runs";
    write_creds("$dir/creds.json", time());
    make_path($runs);
    open my $h, '>', "$runs/.$marker" or die $!;
    close $h;
    my @calls;
    local %ENV = %ENV;
    if (defined $conc) { $ENV{BUTLER_CONCURRENCY} = $conc } else { delete $ENV{BUTLER_CONCURRENCY} }
    my $err;
    eval {
        BpOrch::run({ blueprint => 'T08', bp_dir => $dir, creds_path => "$dir/creds.json",
            tunables => base_tun08(busy_path => "$dir/busy"), once => 1,
            now => sub { time }, sleep => sub { },
            http_get => sub { { status => 200, content => $J->encode({
                five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } }) } },
            http_post => sub { { status => 200, content => '{}' } },
            launch => sub { push @calls, { pkg => $_[0]{pkg}, kind => $_[0]{kind} }; return 0 },
            pid_alive => sub { 0 }, spawn_judge => sub { 0 } });
        1;
    } or $err = $@;
    return { calls => \@calls, marker_present => (-e "$runs/.$marker" ? 1 : 0), err => $err };
}
{
    for my $marker (qw(shutdown paused)) {
        my $off = run_once_marker($marker, undef);
        my $on  = run_once_marker($marker, 1);
        is_deeply($off->{calls}, $on->{calls},
            "AC-13 [.$marker]: the launch-seam calls recorded are identical between switch off and on");
        is($off->{marker_present}, $on->{marker_present},
            "AC-13 [.$marker]: the marker file's post-run presence is identical between switch off and on");
    }
}

# AC-15 deleted [PIN, package 16 batch D]: it pinned the butler-hold coordinator-arming
# recipe (the switch-off path) that package 16 retires -- butler-hold itself is gone
# (batch B/E1) and the "scripts/butler-hold --arm" recipe no longer exists anywhere,
# per spec 16 section 4 batch D and reports/15-skills-prose/pin-audit.md.

# ===========================================================================
# AC-1 / AC-2 / AC-3 / AC-4 / AC-14 -- bp-launch.sh driven with a fake `claude`
# on PATH, borrowing effort-and-profiles.t's technique. Skipped on a host
# without jq/flock/setsid/realpath (bp-launch.sh's own require_cmd list),
# stated by name.
# ===========================================================================
sub have_cmd { my ($c) = @_; my $o = `bash -c "command -v $c" 2>/dev/null`; return ($o =~ /\S/) ? 1 : 0 }
my $HAVE_JQ      = have_cmd('jq');
my $HAVE_FLOCK   = have_cmd('flock');
my $HAVE_SETSID  = have_cmd('setsid');
my $HAVE_REALPATH= have_cmd('realpath');
my $LAUNCH_OK = $HAVE_JQ && $HAVE_FLOCK && $HAVE_SETSID && $HAVE_REALPATH;
my @missing;
push @missing, 'jq'       unless $HAVE_JQ;
push @missing, 'flock'    unless $HAVE_FLOCK;
push @missing, 'setsid'   unless $HAVE_SETSID;
push @missing, 'realpath' unless $HAVE_REALPATH;
my $LAUNCH_SKIP_REASON = "missing on this host: " . join(', ', @missing) . " (bp-launch.sh's require_cmd would exit before doing anything)";

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';
my $LROOT = tempdir(CLEANUP => 1);
my $FAKEBIN = "$LROOT/fakebin";
make_path($FAKEBIN);
my $FAKE_CLAUDE = "$FAKEBIN/claude";
write_file($FAKE_CLAUDE, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_CALLLOG:-}" ]; then
  { printf 'CALL'; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$FAKE_CALLLOG"
fi
if [ -n "${FAKE_ENVLOG:-}" ]; then
  {
    echo "BUTLER_CONCURRENCY=${BUTLER_CONCURRENCY-<unset>}"
    echo "PATH=$PATH"
    echo "BUTLER_HOLD=$(command -v butler-hold 2>/dev/null || echo '<none>')"
    echo "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-<unset>}"
  } > "$FAKE_ENVLOG"
fi
printf '{"type":"system","subtype":"init","session_id":"fake-sid-%s"}\n' "$$"
sleep "${FAKE_ALIVE_SECS:-2}"
exit "${FAKE_EXIT:-0}"
SH
chmod 0755, $FAKE_CLAUDE or die "chmod $FAKE_CLAUDE: $!";

my $lctr = 0;
sub mk_bp_dir08 {
    my $n = ++$lctr;
    my $proj = "$LROOT/proj$n";
    my $data = "$proj/.ccpraxis-local-data";
    my $bp   = "$data/blueprints/T";
    make_path("$proj", "$bp/packages", "$bp/runs");
    return ($proj, $data, $bp);
}
sub mk_ledger08 {
    my ($bp, $pkg) = @_;
    write_file("$bp/packages/$pkg.md", join("\n", '---', "package: $pkg", 'blueprint: T', 'status: pending',
        "write_set: p/$pkg/", "test_paths: p/$pkg/", 'model: sonnet', 'max_turns: 80',
        'last_updated: 2026-06-24T00:00:00Z', '---', '', "# $pkg", '', '## Next action', '', 'go', '') . "\n");
}
sub run_launch08 {
    my ($proj, $data, $bpname, $pkg, $extra_args, %envover) = @_;
    my $n = ++$lctr;
    my $calllog = "$data/CALL-$n.log";
    my $envlog  = "$data/ENV-$n.log";
    my $errfile = "$data/stderr-$n.txt";
    local %ENV = (%CLEAN_ENV, PATH => "$FAKEBIN:$REAL_PATH",
                  BP_PROJECT_ROOT => $proj, CCPRAXIS_DATA_DIR => $data,
                  IS_SANDBOX => 1, FAKE_CALLLOG => $calllog, FAKE_ENVLOG => $envlog, FAKE_ALIVE_SECS => 2,
                  LAUNCH_BIN => $LAUNCH, ERRFILE => $errfile, %envover);
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 30 "$LAUNCH_BIN" "$@" 2>"$ERRFILE"', 'bash', $bpname, $pkg, @$extra_args)
        or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc  = $? >> 8;
    my $err = -e $errfile ? slurp($errfile) : '';
    my $argv;
    if (-e $calllog) {
        my $content = slurp($calllog) // '';
        if ($content =~ /\S/) {
            $content =~ s/\ACALL//;
            $content =~ s/\n\z//;
            my @f = split /\x1f/, $content, -1;
            shift @f;
            $argv = \@f;
        }
    }
    my $env_out = -e $envlog ? slurp($envlog) : undef;
    return ($rc, $out, $err, $argv, $env_out);
}

SKIP: {
    skip $LAUNCH_SKIP_REASON . ' (AC-1 NOT exercised)', 3 unless $LAUNCH_OK;
    for my $case (['unset', undef], ['zero', 0]) {
        my ($label, $val) = @$case;
        my ($proj, $data, $bp) = mk_bp_dir08();
        mk_ledger08($bp, 'p');
        my %env = defined $val ? (BUTLER_CONCURRENCY => $val) : ();
        my ($rc, $out, $err, $argv, $envlog) = run_launch08($proj, $data, 'T', 'p', [], %env);
        ok(defined $argv, "AC-1 [$label]: claude was actually invoked") or diag("rc=$rc err=$err");
        my $expect_line = defined $val ? "BUTLER_CONCURRENCY=$val" : 'BUTLER_CONCURRENCY=<unset>';
        like($envlog // '', qr/^\Q$expect_line\E$/m, "AC-1 [$label]: the child sees BUTLER_CONCURRENCY as $label")
            or diag("envlog: " . ($envlog // '(none)'));
        unlike($err, qr/butler-hold/, "AC-1 [$label]: stderr has no butler-hold line");
    }
}

# R9-C4 (review NIT n1): the butler-hold shim check must use -x (executable),
# not -f (merely exists) -- a shim that lost its exec bit (e.g. a checkout
# with core.fileMode=false, or a Windows-to-container bind mount) must warn,
# not silently pass. A launcher AC: skips on this host like the others above.
SKIP: {
    skip $LAUNCH_SKIP_REASON . ' (R9-C4 NOT exercised)', 1 unless $LAUNCH_OK;
    my $launch_src = slurp($LAUNCH);
    like($launch_src, qr{\[\s*-x\s+"\$PLUGIN_ROOT/bin/butler-hold"\s*\]},
        'R9-C4: bp-launch.sh checks the butler-hold shim with -x (executable), not just -f (exists)')
        or diag("bp-launch.sh butler-hold check line was not -x-based");
}

SKIP: {
    skip $LAUNCH_SKIP_REASON . ' (AC-2/AC-3 NOT exercised)', 8 unless $LAUNCH_OK;
    # The bash -c script is single-quoted for BASH's benefit, but perl's
    # backticks interpolate the whole string regardless of that quoting, so
    # perl's own (empty) $1 was being substituted in before bash ever saw
    # it, silently collapsing "cd $1" to "cd " and reporting $BUTLER's
    # parent (/project) instead of $BUTLER itself (/project/plugins/butler).
    # \$1 escapes it so bash's positional parameter reaches bash unharmed.
    my $plugin_root_pwd = do { my $o = `bash -c 'cd "\$1" && pwd' bash '$BUTLER'`; chomp $o; $o };
    $plugin_root_pwd ||= $BUTLER;

    my ($proj1, $data1, $bp1) = mk_bp_dir08();
    mk_ledger08($bp1, 'p');
    my ($rc1, $o1, $e1, $argv1, $envlog1) = run_launch08($proj1, $data1, 'T', 'p', [], BUTLER_CONCURRENCY => 1);
    ok(defined $argv1, 'AC-2 setup: cold launch, switch on, invoked claude') or diag("rc=$rc1 err=$e1");
    like($envlog1 // '', qr/^BUTLER_CONCURRENCY=1$/m, 'AC-2: child env has BUTLER_CONCURRENCY=1');
    like($envlog1 // '', qr/^PATH=\Q$plugin_root_pwd\E\/bin:/m, 'AC-2: child PATH starts with "<plugin>/bin:"');
    like($envlog1 // '', qr{^BUTLER_HOLD=\Q$plugin_root_pwd\E/bin/butler-hold$}m,
        'AC-2: "command -v butler-hold" names <plugin>/bin/butler-hold') or diag("envlog: " . ($envlog1 // '(none)'));
    # Bug 20261022-104840-4600: `claude -p` kills held background workers
    # after 600s of idle waiting unless this is set; 0 waits indefinitely.
    like($envlog1 // '', qr/^CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0$/m,
        'bug 4600: the coordinator runs with no background-wait ceiling (CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0)');

    my $dispatch1 = slurp("$bp1/dispatch/p.md");

    # AC-3 fix (ledger 2026-09-25T20:40:39Z, tests 79/80/82): switch-on and
    # switch-off are launched against two DIFFERENT fixture project roots
    # (mk_bp_dir08 mints a fresh tempdir every call), so an absolute path
    # baked into argv or dispatch/p.md differs by construction even when
    # everything else is identical. Normalise each side's own project root
    # to a fixed placeholder before comparing, so the comparison is over
    # content, not over which tempdir happened to be minted.
    my $norm_text = sub {
        my ($text, $root) = @_;
        return $text unless defined $text;
        (my $t = $text) =~ s/\Q$root\E/<PROJECT>/g;
        return $t;
    };
    my $norm_argv = sub {
        my ($argv, $root) = @_;
        return $argv unless ref $argv eq 'ARRAY';
        return [ map { $norm_text->($_, $root) } @$argv ];
    };

    # AC-3: byte-identical argv and dispatch prompt vs. switch-off, fresh.
    my ($proj2, $data2, $bp2) = mk_bp_dir08();
    mk_ledger08($bp2, 'p');
    my ($rc2, $o2, $e2, $argv2, $envlog2) = run_launch08($proj2, $data2, 'T', 'p', []);
    ok(defined $argv2, 'AC-3 setup: cold launch, switch off, invoked claude') or diag("rc=$rc2 err=$e2");
    is_deeply($norm_argv->($argv1, $proj1), $norm_argv->($argv2, $proj2),
        'AC-3: the recorded argv is byte-identical between switch-on and switch-off (fresh)')
        or diag("argv1=@{[ map { qq(\"$_\") } @{$argv1||[]} ]}\nargv2=@{[ map { qq(\"$_\") } @{$argv2||[]} ]}");
    is($norm_text->(slurp("$bp2/dispatch/p.md"), $proj2), $norm_text->($dispatch1, $proj1),
        'AC-3: dispatch/p.md bytes are identical between switch-on and switch-off (fresh)');

    # AC-3: warm (--resume-session) argv equal too.
    my ($proj3, $data3, $bp3) = mk_bp_dir08();
    mk_ledger08($bp3, 'p');
    my ($rc3, $o3, $e3, $argv3w) = run_launch08($proj3, $data3, 'T', 'p', ['--resume-session', 'sid-warm-0001'], BUTLER_CONCURRENCY => 1);
    my ($proj4, $data4, $bp4) = mk_bp_dir08();
    mk_ledger08($bp4, 'p');
    my ($rc4, $o4, $e4, $argv4w) = run_launch08($proj4, $data4, 'T', 'p', ['--resume-session', 'sid-warm-0001']);
    ok(defined $argv3w && defined $argv4w, 'AC-3 setup: both warm launches invoked claude') or diag("rc3=$rc3 e3=$e3 rc4=$rc4 e4=$e4");
    is_deeply($norm_argv->($argv3w, $proj3), $norm_argv->($argv4w, $proj4),
        'AC-3: the recorded argv is byte-identical between switch-on and switch-off (warm, --resume-session)');
}

SKIP: {
    skip $LAUNCH_SKIP_REASON . ' (AC-4 NOT exercised)', 3 unless $LAUNCH_OK;
    my $copy_root = "$LROOT/copy4";
    make_path("$copy_root/scripts", "$copy_root/templates", "$copy_root/bin");
    system('bash', '-c', 'cp -r "$1"/. "$2"/', 'x', "$BUTLER/scripts", "$copy_root/scripts");
    system('bash', '-c', 'cp -r "$1"/. "$2"/', 'x', "$BUTLER/templates", "$copy_root/templates");
    # deliberately no bin/butler-hold in the copy.
    my $copy_launch = "$copy_root/scripts/bp-launch.sh";
    ok(-x $copy_launch || -f $copy_launch, "AC-4 setup: a temp copy of scripts+templates exists, without bin/butler-hold");

    my ($proj, $data, $bp) = mk_bp_dir08();
    mk_ledger08($bp, 'p');
    my $n = ++$lctr;
    my $calllog = "$data/CALL-$n.log";
    my $envlog  = "$data/ENV-$n.log";
    my $errfile = "$data/stderr-$n.txt";
    local %ENV = (%CLEAN_ENV, PATH => "$FAKEBIN:$REAL_PATH",
                  BP_PROJECT_ROOT => $proj, CCPRAXIS_DATA_DIR => $data,
                  IS_SANDBOX => 1, FAKE_CALLLOG => $calllog, FAKE_ENVLOG => $envlog, FAKE_ALIVE_SECS => 2,
                  LAUNCH_BIN => $copy_launch, ERRFILE => $errfile, BUTLER_CONCURRENCY => 1);
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 30 "$LAUNCH_BIN" "$@" 2>"$ERRFILE"', 'bash', 'T', 'p') or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc  = $? >> 8;
    my $err = -e $errfile ? slurp($errfile) : '';
    is($rc, 0, 'AC-4: rc 0 -- a missing butler-hold is a warning, never a refusal');
    my @errlines = lines_of($err);
    my @matching = grep { /butler-hold is missing/ } @errlines;
    is(scalar(@matching), 1, 'AC-4: exactly one stderr line matches "butler-hold is missing"') or diag("stderr:\n$err");
    my $envlog_txt = -e $envlog ? slurp($envlog) : undef;
    like($envlog_txt // '', qr/^BUTLER_CONCURRENCY=1$/m, 'AC-4: ...and the child still gets the behavior-2 env (BUTLER_CONCURRENCY=1)')
        or diag("envlog: " . ($envlog_txt // '(none, claude never ran)'));
}

SKIP: {
    skip $LAUNCH_SKIP_REASON . ' (AC-14 NOT exercised)', 2 unless $LAUNCH_OK;
    for my $case ([undef, 'off'], [1, 'on']) {
        my ($val, $label) = @$case;
        my ($proj, $data, $bp) = mk_bp_dir08();
        mk_ledger08($bp, 'p');
        make_path("$bp/runs");
        open my $h, '>', "$bp/runs/p.force-stop" or die $!;
        close $h;
        my %env = defined $val ? (BUTLER_CONCURRENCY => $val) : ();
        my ($rc) = run_launch08($proj, $data, 'T', 'p', [], %env);
        ok(!-e "$bp/runs/p.force-stop", "AC-14 [switch $label]: a pre-existing runs/p.force-stop is gone after launch");
    }
}

# ---------------------------------------------------------------------------
# hermeticity guards: real ~/.claude/butler-state and ~/.ccpraxis-local-data
# were never touched.
# ---------------------------------------------------------------------------
if (defined $REAL_BSTATE) {
    my $exists_after = -d $REAL_BSTATE ? 1 : 0;
    is($exists_after, $REAL_BSTATE_EXISTS, 'hygiene: real ~/.claude/butler-state existence unchanged');
    if ($REAL_BSTATE_EXISTS && $exists_after) {
        is((stat($REAL_BSTATE))[9], $REAL_BSTATE_MTIME, 'hygiene: real ~/.claude/butler-state mtime unchanged');
    }
}
if (defined $REAL_BPDATA) {
    my $exists_after = -d $REAL_BPDATA ? 1 : 0;
    is($exists_after, $REAL_BPDATA_EXISTS, 'hygiene: real ~/.ccpraxis-local-data existence unchanged');
    if ($REAL_BPDATA_EXISTS && $exists_after) {
        is((stat($REAL_BPDATA))[9], $REAL_BPDATA_MTIME, 'hygiene: real ~/.ccpraxis-local-data mtime unchanged');
    }
}

done_testing();
