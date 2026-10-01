#!/usr/bin/env perl
# platform: windows
#
# ORACLE for blueprint package 11-plan-restored-on-last-off (tooling-fixes),
# derived ONLY from
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/11-plan-restored-on-last-off-spec.md
# (AC1-AC18) and Decision 30 / bug 20260927-174038-a7ac. NOT derived from any
# implementation: at the time this file is written, daemon_loop's _handle_signal
# takes only 4 args, no exit_plan_step/$exit_plan_step exists on E3/E4/E5/E6,
# BpPowerPlan::reconcile has no journal_noop option, and butler-continuity.pl's
# off handler never calls BpPowerPlan::reconcile at all.
#
# THE REAL POWER PLAN IS NEVER TOUCHED. Every path to powercfg goes through the
# same two seams power-plan-follows-arming.t uses: the in-process `run` coderef
# (reconcile's/daemon_loop's plan_opts.run), and $ENV{CCPRAXIS_POWERCFG} (an
# absolute path to a small fixture script) for the subprocess (`off`) tests.
# AC16 below re-exercises the last-resort guard directly.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use MIME::Base64 qw(encode_base64 decode_base64);
use Time::HiRes qw(sleep time);
use POSIX qw(WNOHANG);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
my $POWER_PLAN_MODULE = "$S/BpPowerPlan.pm";
eval { require $POWER_PLAN_MODULE };
my $MODULE_LOAD_ERROR = $@;
my $CMD = "$S/butler-continuity.pl";

sub PP {
    my ($name, @args) = @_;
    my $code;
    { no strict 'refs'; $code = \&{"BpPowerPlan::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub explain_undef { return 'PP() returned undef -- the named sub does not implement this option/behavior yet' }

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_LEASE_LIVE_SCRIPT} = "$S/BpContinuityLease.pm";

my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { kill('TERM', $pid) } }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { kill('KILL', $pid) if kill(0, $pid) } }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, WNOHANG) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ===========================================================================
# generic helpers (same idiom as power-plan-follows-arming.t)
# ===========================================================================
sub fresh_home { my $t = tempdir(CLEANUP => 1); (my $b = "$t/home") =~ s{\\}{/}g; make_path($b); return $b }
sub fresh_dir {
    my ($suffix) = @_;
    $suffix //= 'active';
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/$suffix") =~ s{\\}{/}g;
    make_path($d);
    return $d;
}
sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub jsonl_lines {
    my ($path) = @_;
    my $raw = slurp($path);
    return () unless defined $raw && length $raw;
    return split /\n/, $raw;
}
sub decode_or_undef {
    my ($line) = @_;
    my $d = eval { JSON::PP->new->utf8->decode($line) };
    return $@ ? undef : $d;
}
sub plan_records {
    my ($legacy) = @_;
    my @out;
    for my $line (jsonl_lines("$legacy/power-journal.jsonl")) {
        my $d = decode_or_undef($line);
        push @out, $d if ref $d eq 'HASH' && defined $d->{kind} && $d->{kind} eq 'plan';
    }
    return @out;
}

sub fresh_group {
    my $home   = fresh_home();
    my $legacy = fresh_dir('legacy');
    $ENV{BUTLER_STATE_DIR}               = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();
    return ($home, $legacy);
}

sub arm_one {
    my ($sid) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $tp = "$t/transcript.jsonl") =~ s{\\}{/}g;
    open(my $fh, '>', $tp) or die "open $tp: $!";
    print {$fh} "{}\n";
    close $fh;
    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp), "setup: BpHook::arm($sid) succeeds");
    return;
}

our $BAL_GUID      = '381b4222-f694-41f0-9685-ff5bb260df2e';
our $CW_NAME        = 'Continuous work';
our $CW_GUID_STORED = '54a34db5-af62-4d8a-ba50-af7155ee895a';

sub ga_bytes { my ($guid, $name) = @_; return "Power Scheme GUID: $guid  ($name)\r\n" }
sub list_bytes {
    my (@entries) = @_;
    my $body = '';
    for my $e (@entries) {
        $body .= "Power Scheme GUID: $e->{guid}  ($e->{name})" . ($e->{active} ? ' *' : '') . "\r\n";
    }
    return "\r\nExisting Power Schemes (* Active)\r\n-----------------------------------\r\n$body";
}

sub run_seam {
    my (%scn) = @_;
    my @calls;
    my $fn = sub {
        my @args = @_;
        push @calls, [ @args ];
        my $verb = defined $args[0] ? $args[0] : '';
        return $scn{getactivescheme} if $verb eq '/getactivescheme' && exists $scn{getactivescheme};
        return $scn{list}            if $verb eq '/list'            && exists $scn{list};
        return $scn{setactive}       if $verb eq '/setactive'       && exists $scn{setactive};
        return { status => 'ok', rc => 0, out => '', ms => 1 };
    };
    return ($fn, \@calls);
}
sub ok_result { my ($out) = @_; return { status => 'ok', rc => 0, out => $out, ms => 1 } }
sub rc1_result { my ($out) = @_; return { status => 'ok', rc => 1, out => (defined $out ? $out : ''), ms => 1 } }

# run_seam_file($call_log_path, %scn) -- the same answering shape as run_seam,
# but the call log is appended to DISK, because this seam is also handed to a
# FORKED CHILD (E3/E4): an in-memory @calls array in the child is invisible to
# the parent once the child exits, but a file both processes share is not.
sub run_seam_file {
    my ($call_log, %scn) = @_;
    return sub {
        my @args = @_;
        if (defined $call_log) {
            open(my $fh, '>>', $call_log) or die "open $call_log: $!";
            print {$fh} join("\x1f", map { defined $_ ? $_ : '' } @args), "\n";
            close $fh;
        }
        my $verb = defined $args[0] ? $args[0] : '';
        return $scn{getactivescheme} if $verb eq '/getactivescheme' && exists $scn{getactivescheme};
        return $scn{list}            if $verb eq '/list'            && exists $scn{list};
        return $scn{setactive}       if $verb eq '/setactive'       && exists $scn{setactive};
        return { status => 'ok', rc => 0, out => '', ms => 1 };
    };
}
sub read_call_log {
    my ($path) = @_;
    return () unless defined $path && -f $path;
    open(my $fh, '<', $path) or return ();
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    return map { [ split /\x1f/, $_, -1 ] } @lines;
}

# wait_for_pattern($path, qr, deadline_s) -- polls a file for a regex, bounded.
sub wait_for_pattern {
    my ($path, $re, $deadline_s) = @_;
    my $deadline = time() + ($deadline_s // 10);
    while (time() < $deadline) {
        my $c = slurp($path);
        return 1 if defined $c && $c =~ $re;
        sleep(0.05);
    }
    return 0;
}

sub wait_child_exit {
    my ($pid, $deadline_s) = @_;
    my $deadline = time() + ($deadline_s // 30);
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return $rc;
}

ok(1, "sanity: harness loaded" . ($MODULE_LOAD_ERROR ? " (BpPowerPlan.pm failed to load: $MODULE_LOAD_ERROR)" : ''));

# ===========================================================================
# AC10 -- reconcile's new journal_noop option (DC1, in-process unit).
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac10-jn-a');
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        )),
    );
    my $outcome = PP('reconcile', $legacy, run => $run, why => 'refresher-exit', journal_noop => 1);
    SKIP: {
        skip 'AC10: journal_noop not implemented yet', 2 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'correct', 'AC10: outcome is correct when the plan already matches');
        is($outcome->{journaled}, 1, 'AC10: journaled is 1 with journal_noop set');
    }
    my @sc = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@sc), 0, 'AC10: no /setactive call for a noop reconcile');
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC10: journal_noop writes exactly one record even on a correct outcome')
        or diag(explain_undef());
    if (@recs) {
        is($recs[0]{action}, 'none', 'AC10: the noop record has action none');
        is($recs[0]{result}, 'ok', 'AC10: the noop record has result ok');
        is($recs[0]{why}, 'refresher-exit', 'AC10: the noop record carries the given why');
    }
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac10-jn-b');
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        )),
    );
    PP('reconcile', $legacy, run => $run, why => 'refresher-exit');
    is(scalar(plan_records($legacy)), 0, 'AC10: without journal_noop, a correct outcome still writes nothing (unchanged)');
}

# ===========================================================================
# AC1/AC2 -- E1 IDLE (DC1): wrong plan already covered by power-plan-follows-
# arming.t AC3; here we add the NEW noop-journaled case (behavior 2).
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    # nothing armed; plan already Balanced
    my ($run, $calls) = run_seam(getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')));
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1, journal => 0,
            plan_opts => { run => $run },
        );
    };
    is($rc, 'done', 'AC2: daemon_loop exits through IDLE with "done"') or diag($@);
    my @sc = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@sc), 0, 'AC2: no /setactive call when the plan is already Balanced');
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC2: one record is written even though the IDLE exit found the plan already correct (noop journaled)')
        or diag(explain_undef());
    if (@recs) {
        is($recs[0]{why}, 'refresher-exit', 'AC2: why is refresher-exit');
        is($recs[0]{action}, 'none', 'AC2: action is none');
        is($recs[0]{result}, 'ok', 'AC2: result is ok');
        is($recs[0]{armed}, 0, 'AC2: armed is 0');
    }
}

# ===========================================================================
# AC3/AC4 -- E3 signal (DC1, DC3): forked child, real TERM.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac3sig');
    my $call_log = "$legacy/.calls-ac3";
    my $run = run_seam_file($call_log,
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        local $BpContinuityLease::PLATFORM = 'windows';
        eval {
            BpContinuityLease::daemon_loop($legacy,
                tick => 1, journal => 0,
                spawn => sub { 9201 }, powershell_available => sub { 1 }, kill_pid => sub { },
                plan_opts => { run => $run },
            );
        };
        exit 0;
    }
    push @KILL_PIDS, $pid;

    ok(wait_for_pattern("$legacy/lease.log", qr/\bTICK\b/, 15), 'AC3 setup: child logs at least one TICK');
    ok(BpHook::disarm('ac3sig', actor => 'agent', reason => 'ac3 cleanup'), 'AC3 setup: the arm is removed before TERM');
    kill('TERM', $pid);
    my $rc = wait_child_exit($pid, 20);
    is($rc, 0, 'AC3: the signalled child exits 0');

    my $log = slurp("$legacy/lease.log") // '';
    like($log, qr/RELEASE reason=term/, 'AC3: lease.log has RELEASE reason=term');
    like($log, qr/EXIT reason=released/, 'AC3: lease.log has EXIT reason=released');

    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC3: exactly one kind:plan record from the signal exit') or diag(explain_undef());
    if (@recs) {
        is($recs[0]{why}, 'refresher-signal', 'AC3: why is refresher-signal');
        is($recs[0]{action}, 'set', 'AC3: action is set');
        is($recs[0]{wanted_guid}, $BAL_GUID, 'AC3: wanted_guid is Balanced');
        is($recs[0]{armed}, 0, 'AC3: armed is 0 (the arm was removed before TERM)');
    }
    my @sc = grep { $_->[0] eq '/setactive' } read_call_log($call_log);
    is(scalar(@sc), 1, 'AC3: exactly one /setactive call recorded by the forked child\'s seam')
        or diag(explain_undef());
}
{
    # AC4 -- TERM while the arm is STILL live and the plan is already correct:
    # one record, action none, armed 1.
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac4sig');
    my $call_log = "$legacy/.calls-ac4";
    my $run = run_seam_file($call_log,
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
    );
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        local $BpContinuityLease::PLATFORM = 'windows';
        eval {
            BpContinuityLease::daemon_loop($legacy,
                tick => 1, journal => 0,
                spawn => sub { 9202 }, powershell_available => sub { 1 }, kill_pid => sub { },
                plan_opts => { run => $run },
            );
        };
        exit 0;
    }
    push @KILL_PIDS, $pid;
    ok(wait_for_pattern("$legacy/lease.log", qr/\bTICK\b/, 15), 'AC4 setup: child logs at least one TICK');
    kill('TERM', $pid);
    my $rc = wait_child_exit($pid, 20);
    is($rc, 0, 'AC4: the signalled child exits 0');
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC4: exactly one record even though the plan was already correct at signal time')
        or diag(explain_undef());
    if (@recs) {
        is($recs[0]{why}, 'refresher-signal', 'AC4: why is refresher-signal');
        is($recs[0]{action}, 'none', 'AC4: action is none');
        is($recs[0]{armed}, 1, 'AC4: armed is 1 (the arm was never removed)');
    }
    my @sc = grep { $_->[0] eq '/setactive' } read_call_log($call_log);
    is(scalar(@sc), 0, 'AC4: no /setactive call when the plan was already correct');
}

# ===========================================================================
# AC5 -- _handle_signal unit (DC1), forked children (it exit()s).
# ===========================================================================
sub fork_handle_signal {
    my ($reason, $handing_over, $step_behavior, $events_path) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my $log = sub {
            my ($ev, $detail) = @_;
            open(my $fh, '>>', $events_path) or exit 97;
            print {$fh} "LOG:$ev:" . (defined $detail ? $detail : '') . "\n";
            close $fh;
        };
        my $release = sub {
            open(my $fh, '>>', $events_path) or exit 97;
            print {$fh} "RELEASE\n";
            close $fh;
        };
        my $step;
        if ($step_behavior eq 'record') {
            $step = sub {
                my ($why) = @_;
                open(my $fh, '>>', $events_path) or exit 97;
                print {$fh} "STEP:$why\n";
                close $fh;
            };
        }
        elsif ($step_behavior eq 'die') {
            $step = sub { die "fixture: step dies\n" };
        }
        elsif ($step_behavior eq 'undef') {
            $step = undef;
        }
        BpContinuityLease::_handle_signal($reason, $handing_over, $release, $log, $step);
        exit 99;   # unreachable: _handle_signal always exit()s
    }
    push @KILL_PIDS, $pid;
    return $pid;
}

{
    # Behavior 5: handover branch -- step called once, release NEVER called.
    my $events = tempdir(CLEANUP => 1) . '/events-ac5-handover.log';
    my $pid = fork_handle_signal('term', \1, 'record', $events);
    my $rc = wait_child_exit($pid, 10);
    is($rc, 0, 'AC5 (handover branch): the child exits 0');
    my @lines = split /\n/, (slurp($events) // '');
    is(scalar(grep { /^STEP:refresher-signal$/ } @lines), 1,
        'AC5 (handover branch): the exit step runs exactly once, with why=refresher-signal')
        or diag(explain_undef());
    is(scalar(grep { /^RELEASE$/ } @lines), 0, 'AC5 (handover branch): release is never called');
    ok((grep { /^LOG:EXIT:reason=signal-during-handover$/ } @lines),
        'AC5 (handover branch): EXIT reason=signal-during-handover is logged') or diag(join('|', @lines));
}
{
    # Behavior 6: normal branch -- step runs BEFORE release.
    my $events = tempdir(CLEANUP => 1) . '/events-ac5-normal.log';
    my $pid = fork_handle_signal('int', \0, 'record', $events);
    my $rc = wait_child_exit($pid, 10);
    is($rc, 0, 'AC5 (normal branch): the child exits 0');
    my @lines = split /\n/, (slurp($events) // '');
    my ($step_i)    = grep { $lines[$_] =~ /^STEP:refresher-signal$/ } 0 .. $#lines;
    my ($release_i) = grep { $lines[$_] eq 'RELEASE' } 0 .. $#lines;
    ok(defined $step_i, 'AC5 (normal branch): the exit step runs') or diag(explain_undef());
    ok(defined $release_i, 'AC5 (normal branch): release runs');
    if (defined $step_i && defined $release_i) {
        ok($step_i < $release_i, 'AC5 (normal branch): the exit step runs BEFORE release');
    }
}
{
    # undef step: behaves exactly as today (release runs, exit 0, no crash).
    my $events = tempdir(CLEANUP => 1) . '/events-ac5-undef.log';
    my $pid = fork_handle_signal('int', \0, 'undef', $events);
    my $rc = wait_child_exit($pid, 10);
    is($rc, 0, 'AC5 (undef step): the child exits 0 (back-compat)');
    my @lines = split /\n/, (slurp($events) // '');
    ok((grep { $_ eq 'RELEASE' } @lines), 'AC5 (undef step): release still runs with no step at all');
}
{
    # a dying step: release still runs, exit status is still 0.
    my $events = tempdir(CLEANUP => 1) . '/events-ac5-dies.log';
    my $pid = fork_handle_signal('int', \0, 'die', $events);
    my $rc = wait_child_exit($pid, 10);
    is($rc, 0, 'AC5 (dying step): the child still exits 0');
    my @lines = split /\n/, (slurp($events) // '');
    ok((grep { $_ eq 'RELEASE' } @lines), 'AC5 (dying step): release still runs despite the step dying')
        or diag(explain_undef());
}

# ===========================================================================
# AC6 -- E5 handover (DC1, in-process).
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac6handover');
    local $ENV{CCPRAXIS_LEASE_LIVE_SCRIPT} = "$legacy/not-the-real-module.pm";   # forces not-live
    local $BpContinuityLease::HANDOVER_TIMEOUT_SECONDS = 5;
    my $foreign_pid = $$ + 123456;

    my $handover_spawn = sub {
        open(my $fh, '>', "$legacy/lease.handover") or die $!;
        print {$fh} "$foreign_pid\n";
        close $fh;
        open(my $fh2, '>', "$legacy/lease.pid") or die $!;
        print {$fh2} "$foreign_pid\n";
        close $fh2;
        return $foreign_pid;
    };

    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );

    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 5, tick => 1, journal => 0,
            spawn => sub { 9601 }, powershell_available => sub { 1 }, kill_pid => sub { },
            handover_spawn => $handover_spawn,
            plan_opts => { run => $run },
        );
    };
    is($rc, 'handed-over', 'AC6: daemon_loop returns handed-over') or diag($@);

    my $log = slurp("$legacy/lease.log") // '';
    like($log, qr/HANDOVER-DONE.*EXIT reason=handed-over/s, 'AC6: lease.log has HANDOVER-DONE then EXIT reason=handed-over');

    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC6: exactly one kind:plan record from the handover exit') or diag(explain_undef());
    if (@recs) {
        is($recs[0]{why}, 'refresher-handover', 'AC6: why is refresher-handover');
        is($recs[0]{action}, 'set', 'AC6: action is set (armed wants Continuous work)');
        is($recs[0]{armed}, 1, 'AC6: armed is 1');
    }
}

# ===========================================================================
# AC7 -- E6 uncaught die (DC1, in-process).
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac7err');
    my $tick_seen = 0;
    my @events;
    my $log = sub {
        my ($ev, $detail) = @_;
        if ($ev eq 'TICK' && !$tick_seen++) { die "fixture-error\n" }
        push @events, [ $ev, defined $detail ? $detail : '' ];
    };
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );
    my $completed = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 3, tick => 1, journal => 0,
            spawn => sub { 9701 }, powershell_available => sub { 1 }, kill_pid => sub { },
            log => $log, plan_opts => { run => $run },
        );
        1;
    };
    my $err = $@;
    ok(!$completed, 'AC7: daemon_loop dies rather than returning normally');
    like($err, qr/fixture-error/, 'AC7: the original exception propagates ($@ matches message M)');

    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC7: exactly one kind:plan record (why=refresher-error) is written before the re-throw')
        or diag(explain_undef());
    is($recs[0]{why}, 'refresher-error', 'AC7: why is refresher-error') if @recs;

    my @tokens = map { $_->[0] } @events;
    ok((grep { $_ eq 'ERROR' } @tokens), 'AC7: the log events include ERROR') or diag(join(',', @tokens));
    ok((grep { $_ eq 'RELEASE' } @tokens), 'AC7: the log events include RELEASE') or diag(join(',', @tokens));
    my ($rel) = grep { $_->[0] eq 'RELEASE' } @events;
    is($rel ? $rel->[1] : undef, 'reason=error', 'AC7: RELEASE carries reason=error') if $rel;
    ok((grep { $_ eq 'EXIT' } @tokens), 'AC7: the log events include EXIT') or diag(join(',', @tokens));
    ok(!-f "$legacy/lease.pid", 'AC7: lease.pid is removed after the error exit');
}

# ===========================================================================
# AC8 -- E2 max_iterations is deliberately EXCLUDED: no exit step (DC1, DC4).
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac8maxiter');
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        )),
    );
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1, journal => 0,
            spawn => sub { 9801 }, powershell_available => sub { 1 }, kill_pid => sub { },
            plan_opts => { run => $run },
        );
    };
    is($rc, 'done', 'AC8: daemon_loop completes via max_iterations') or diag($@);
    is(scalar(plan_records($legacy)), 0, 'AC8: max_iterations runs NO exit step (package 06 AC1/AC2/AC5d/AC9 stay green)');
}

# ===========================================================================
# AC8b -- a pre-lock exit (P1-P3 family) runs no exit step either.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac8b-prelock');
    open(my $lockfh, '>>', "$legacy/lease.lock") or die $!;
    flock($lockfh, 2) or diag("could not take the test's own lock: $!");   # LOCK_EX
    my ($run, $calls) = run_seam(getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')));
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1, journal => 0,
            plan_opts => { run => $run },
        );
    };
    is($rc, 'duplicate', 'AC8b: a second daemon_loop against an already-locked dir returns duplicate') or diag($@);
    is(scalar(@$calls), 0, 'AC8b: the plan seam is never called on the pre-lock duplicate path');
    is(scalar(plan_records($legacy)), 0, 'AC8b: no plan record on the pre-lock duplicate path');
    close $lockfh;
}

# ===========================================================================
# AC9 -- the full key set on every NEW why (refresher-signal, -handover,
# -error) is already enforced structurally by power-plan-follows-arming.t
# AC11 for refresher-tick/refresher-exit; here we check the new whys reuse
# the identical record shape (same _write_plan_record call).
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac9keys');
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        )),
    );
    PP('reconcile', $legacy, run => $run, why => 'refresher-signal', journal_noop => 1);
    my @recs = plan_records($legacy);
    SKIP: {
        skip 'AC9: no record written (journal_noop not implemented yet)', 20 unless @recs;
        my $r = $recs[0];
        for my $key (qw(v kind ts utc local pid why armed arm_ids found_guid found_name
                        wanted_guid wanted_name wanted_basis action result error detail rc ms)) {
            ok(exists $r->{$key}, "AC9: a refresher-signal record has key '$key'");
        }
        is($r->{kind}, 'plan', 'AC9: kind is plan');
    }
}

# ===========================================================================
# OFF (DC2, DC3) -- subprocess harness, reused ticket-binding shape from
# continuity-command-verbs.t.
# ===========================================================================
my $FAKE_POWERCFG_SCRIPT;
sub write_fake_powercfg {
    my (%behavior) = @_;
    unless (defined $FAKE_POWERCFG_SCRIPT) {
        my (undef, $path) = tempfile();
        open(my $fh, '>', $path) or die "open $path: $!";
        print {$fh} <<'PERLSRC';
use strict; use warnings;
use MIME::Base64 ();
use JSON::PP ();
my $control = $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL};
my %cfg;
if (defined $control && -f $control) {
    open(my $cf, '<:raw', $control) or exit 9;
    local $/; my $raw = <$cf>; close $cf;
    my $d = eval { JSON::PP::decode_json($raw) };
    %cfg = %$d if ref $d eq 'HASH';
}
my $verb = shift(@ARGV) // '';
my $key = $verb eq '/getactivescheme' ? 'getactivescheme'
        : $verb eq '/list'            ? 'list'
        : $verb eq '/setactive'       ? 'setactive'
        : 'unknown';
if (defined $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG}) {
    open(my $lfh, '>>', $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG}) or exit 9;
    print {$lfh} join(' ', $verb, @ARGV), "\n";
    close $lfh;
}
my $c = (ref $cfg{$key} eq 'HASH') ? $cfg{$key} : {};
if (defined $c->{out_b64}) {
    binmode(STDOUT);
    print MIME::Base64::decode_base64($c->{out_b64});
}
exit(defined $c->{rc} ? $c->{rc} : 0);
PERLSRC
        close $fh;
        $FAKE_POWERCFG_SCRIPT = $path;
    }
    my %ctrl;
    for my $k (qw(getactivescheme list setactive)) {
        next unless ref $behavior{$k} eq 'HASH';
        my %c;
        $c{rc} = $behavior{$k}{rc} if defined $behavior{$k}{rc};
        $c{out_b64} = encode_base64($behavior{$k}{out}, '') if defined $behavior{$k}{out};
        $ctrl{$k} = \%c;
    }
    my (undef, $ctrl_path) = tempfile();
    open(my $cf, '>', $ctrl_path) or die "open $ctrl_path: $!";
    print {$cf} JSON::PP->new->utf8->encode(\%ctrl);
    close $cf;
    return ($FAKE_POWERCFG_SCRIPT, $ctrl_path);
}

my $OFF_TUID = 0;
sub off_write_ticket {
    my ($sid, $argv, %o) = @_;
    my $tuid = sprintf('tu%06x', ++$OFF_TUID);
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path},
        cwd             => $o{cwd},
    };
    return BpHook::write_ticket($p, 'butler-continuity', $argv, operator => 0, background => 0);
}

sub off_run_cmd {
    my ($env, @args) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{$_} = $env->{$_} for keys %$env;
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, $CMD, @args);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $rc = wait_child_exit($pid, 30);
    my $out = slurp($outfile) // '';
    my $err = slurp($errfile) // '';
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
}

# off_fixture() -- a fresh (home, project, override_root/legacy, decoy-home)
# quadruple, wired exactly as AC12 of power-plan-follows-arming.t wires it
# (Decision 24: CCPRAXIS_POWER_PLAN_LIVE_ROOT + <root>/.continuity-active).
sub off_fixture {
    my $home          = fresh_home();
    my $project       = fresh_dir('project');
    make_path("$project/.ccpraxis-local-data");
    my $override_root = fresh_dir('off-live-root');
    my $legacy        = "$override_root/.continuity-active";
    make_path($legacy);
    my $decoy_home    = fresh_dir('decoy-home');
    return {
        home => $home, project => $project, override_root => $override_root,
        legacy => $legacy, decoy_home => $decoy_home,
    };
}
sub off_env {
    my ($fx, %extra) = @_;
    return {
        BUTLER_STATE_DIR               => $fx->{home},
        CCPRAXIS_CONTINUITY_ACTIVE_DIR => $fx->{legacy},
        CCPRAXIS_POWER_PLAN_LIVE_ROOT  => $fx->{override_root},
        CLAUDE_PROJECT_DIR             => $fx->{project},
        HOME                           => $fx->{decoy_home},
        USERPROFILE                    => $fx->{decoy_home},
        CCPRAXIS_NO_WAKELOCK           => 1,
        %extra,
    };
}

# ===========================================================================
# AC11/AC12 -- off, last live arm (DC2, DC3).
# ===========================================================================
{
    my $fx = off_fixture();
    local $ENV{BUTLER_STATE_DIR} = $fx->{home};
    my $sid = 'ac11offsid';
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC11 setup: session armed');
    off_write_ticket($sid, ['off', '--reason', 'wrapping up now'], cwd => $fx->{project});

    my ($fake, $ctrl) = write_fake_powercfg(
        getactivescheme => { out => ga_bytes($CW_GUID_STORED, $CW_NAME) },
        list            => { out => list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        ) },
        setactive => { rc => 0 },
    );
    my $call_log = "$fx->{legacy}/.ac11-calls";
    my $env = off_env($fx,
        CCPRAXIS_POWERCFG                  => $fake,
        CCPRAXIS_TEST_POWERCFG_CONTROL     => $ctrl,
        CCPRAXIS_TEST_POWERCFG_CALL_LOG    => $call_log,
    );
    my ($out, $err, $rc) = off_run_cmd($env, 'off', '--reason', 'wrapping up now');
    is($rc, 0, 'AC11: off exits 0') or diag("stderr: $err");
    like($out, qr/^continuity off for session \w{8} \(actor agent\); reason logged\.$/m,
        'AC11: stdout is unchanged') or diag($out);
    is($err, '', 'AC11: no stderr warning') or diag($err);

    my @calls = split /\n/, (slurp($call_log) // '');
    ok((grep { /^\/getactivescheme/ } @calls), 'AC11: the fake received /getactivescheme') or diag(explain_undef());
    ok((grep { /^\/setactive/ } @calls), 'AC11: the fake received /setactive') or diag(explain_undef());
    ok(!(grep { /^\/list/ } @calls), 'AC11: /list is never called when the exit is unarmed');

    my @recs = plan_records($fx->{legacy});
    is(scalar(@recs), 1, 'AC11: exactly one kind:plan record from off') or diag(explain_undef());
    if (@recs) {
        is($recs[0]{why}, 'continuity-off', 'AC11: why is continuity-off');
        is($recs[0]{action}, 'set', 'AC11: action is set');
        is($recs[0]{armed}, 0, 'AC11: armed is 0');
    }
}
{
    # AC12 -- plan already Balanced: one noop record, no /setactive.
    my $fx = off_fixture();
    my $sid = 'ac12offsid';
    local $ENV{BUTLER_STATE_DIR} = $fx->{home};
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC12 setup: session armed');
    off_write_ticket($sid, ['off', '--reason', 'wrapping up now'], cwd => $fx->{project});

    my ($fake, $ctrl) = write_fake_powercfg(
        getactivescheme => { out => ga_bytes($BAL_GUID, 'Balanced') },
    );
    my $call_log = "$fx->{legacy}/.ac12-calls";
    my $env = off_env($fx,
        CCPRAXIS_POWERCFG               => $fake,
        CCPRAXIS_TEST_POWERCFG_CONTROL  => $ctrl,
        CCPRAXIS_TEST_POWERCFG_CALL_LOG => $call_log,
    );
    my ($out, $err, $rc) = off_run_cmd($env, 'off', '--reason', 'wrapping up now');
    is($rc, 0, 'AC12: off exits 0') or diag("stderr: $err");
    is($err, '', 'AC12: no stderr warning');
    my @calls = split /\n/, (slurp($call_log) // '');
    ok(!(grep { /^\/setactive/ } @calls), 'AC12: no /setactive when the plan is already Balanced');
    my @recs = plan_records($fx->{legacy});
    is(scalar(@recs), 1, 'AC12: one record is written even for the noop') or diag(explain_undef());
    if (@recs) {
        is($recs[0]{action}, 'none', 'AC12: action is none');
        is($recs[0]{result}, 'ok', 'AC12: result is ok');
    }
}

# ===========================================================================
# AC13 -- off, NOT the last live arm: no reconcile at all.
# ===========================================================================
{
    my $fx = off_fixture();
    local $ENV{BUTLER_STATE_DIR} = $fx->{home};
    ok(BpHook::arm('ac13-a', role => 'manual', by => 'on'), 'AC13 setup: session A armed');
    ok(BpHook::arm('ac13-b', role => 'manual', by => 'on'), 'AC13 setup: session B armed');
    off_write_ticket('ac13-a', ['off', '--reason', 'done with my part'], cwd => $fx->{project});

    my ($fake, $ctrl) = write_fake_powercfg(getactivescheme => { out => ga_bytes($CW_GUID_STORED, $CW_NAME) });
    my $call_log = "$fx->{legacy}/.ac13-calls";
    my $env = off_env($fx,
        CCPRAXIS_POWERCFG               => $fake,
        CCPRAXIS_TEST_POWERCFG_CONTROL  => $ctrl,
        CCPRAXIS_TEST_POWERCFG_CALL_LOG => $call_log,
    );
    my ($out, $err, $rc) = off_run_cmd($env, 'off', '--reason', 'done with my part');
    is($rc, 0, 'AC13: off exits 0') or diag("stderr: $err");
    ok(!-s $call_log, 'AC13: the fake powercfg call log is empty/absent (reconcile never ran)');
    is(scalar(plan_records($fx->{legacy})), 0, 'AC13: no continuity-off record when another arm is still live');
}

# ===========================================================================
# AC14 -- off, nothing was live before the call.
# ===========================================================================
{
    my $fx = off_fixture();
    local $ENV{BUTLER_STATE_DIR} = $fx->{home};
    off_write_ticket('ac14sid', ['off', '--reason', 'never armed at all'], cwd => $fx->{project});

    my ($fake, $ctrl) = write_fake_powercfg(getactivescheme => { out => ga_bytes($CW_GUID_STORED, $CW_NAME) });
    my $call_log = "$fx->{legacy}/.ac14-calls";
    my $env = off_env($fx,
        CCPRAXIS_POWERCFG               => $fake,
        CCPRAXIS_TEST_POWERCFG_CONTROL  => $ctrl,
        CCPRAXIS_TEST_POWERCFG_CALL_LOG => $call_log,
    );
    my ($out, $err, $rc) = off_run_cmd($env, 'off', '--reason', 'never armed at all');
    is($rc, 0, 'AC14: off exits 0') or diag("stderr: $err");
    like($out, qr/was not armed/, 'AC14: stdout mentions "was not armed"');
    ok(!-s $call_log, 'AC14: the fake powercfg call log is empty/absent');
    is(scalar(plan_records($fx->{legacy})), 0, 'AC14: no continuity-off record when nothing was live before');
}

# ===========================================================================
# AC15 -- off, /setactive fails: exit 0, stdout unchanged, one stderr
# warning, one error record.
# ===========================================================================
{
    my $fx = off_fixture();
    local $ENV{BUTLER_STATE_DIR} = $fx->{home};
    my $sid = 'ac15offsid';
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC15 setup: session armed');
    off_write_ticket($sid, ['off', '--reason', 'wrapping up now'], cwd => $fx->{project});

    my ($fake, $ctrl) = write_fake_powercfg(
        getactivescheme => { out => ga_bytes($CW_GUID_STORED, $CW_NAME) },
        list            => { out => list_bytes(
            { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        ) },
        setactive => { rc => 1 },
    );
    my $call_log = "$fx->{legacy}/.ac15-calls";
    my $env = off_env($fx,
        CCPRAXIS_POWERCFG               => $fake,
        CCPRAXIS_TEST_POWERCFG_CONTROL  => $ctrl,
        CCPRAXIS_TEST_POWERCFG_CALL_LOG => $call_log,
    );
    my ($out, $err, $rc) = off_run_cmd($env, 'off', '--reason', 'wrapping up now');
    is($rc, 0, 'AC15: off still exits 0 despite the reconcile failure') or diag("stderr: $err");
    like($out, qr/^continuity off for session \w{8} \(actor agent\); reason logged\.$/m,
        'AC15: stdout is unchanged') or diag($out);
    my @warn_lines = grep { /\S/ } split /\n/, $err;
    is(scalar(@warn_lines), 1, 'AC15: exactly one stderr line') or diag($err);
    like($err, qr/^butler-continuity: warning: power plan not restored \(setactive-failed/m,
        'AC15: the stderr warning names setactive-failed') or diag($err);

    my @recs = plan_records($fx->{legacy});
    is(scalar(@recs), 1, 'AC15: one error record is written') or diag(explain_undef());
    if (@recs) {
        is($recs[0]{why}, 'continuity-off', 'AC15: why is continuity-off');
        is($recs[0]{result}, 'error', 'AC15: result is error');
        is($recs[0]{error}, 'setactive-failed', 'AC15: error is setactive-failed');
    }
}

# ===========================================================================
# AC16 -- the real plan is NEVER touched (DC3).
# ===========================================================================
{
    local $ENV{CCPRAXIS_POWERCFG};
    delete $ENV{CCPRAXIS_POWERCFG};
    local $BpContinuityLease::PLATFORM = 'windows';
    is(PP('powercfg_argv', '/getactivescheme'), undef,
        'AC16: powercfg_argv returns undef under this .t with no CCPRAXIS_POWERCFG (the real binary is never named)')
        or diag(explain_undef());
}

# ===========================================================================
# AC17 -- structural backstop (source-level): off references reconcile via
# plan_after_off with why=>'continuity-off', no OTHER verb block does, and
# _handle_signal takes a 5th parameter.
# ===========================================================================
{
    my $src = do { local $/; open(my $fh, '<:raw', $CMD) or die $!; <$fh> };
    like($src, qr/plan_after_off/, 'AC17: butler-continuity.pl references plan_after_off')
        or diag(explain_undef());
    like($src, qr/BpPowerPlan::reconcile/, 'AC17: butler-continuity.pl references BpPowerPlan::reconcile');
    like($src, qr/why\s*=>\s*'continuity-off'/, "AC17: the reconcile call passes why => 'continuity-off'");

    # no OTHER verb block (on/silence/status) calls plan_after_off/reconcile.
    for my $verb_marker (qr/if\s*\(\s*\$verb\s+eq\s+'on'\s*\)\s*\{/,
                          qr/if\s*\(\s*\$verb\s+eq\s+'silence'\s*\)\s*\{/) {
        if ($src =~ /$verb_marker(.{0,2000}?)\n\}\n/s) {
            my $block = $1;
            unlike($block, qr/plan_after_off|BpPowerPlan::reconcile/,
                'AC17: a non-off verb block does not call plan_after_off/reconcile');
        }
        else {
            fail('AC17: could not locate the verb block to check (regex needs updating against the real source)');
        }
    }

    my $module_src = do { local $/; open(my $fh, '<:raw', "$S/BpContinuityLease.pm") or die $!; <$fh> };
    my ($sig_sub) = $module_src =~ /sub\s+_handle_signal\s*\{\s*\n\s*my\s*\(([^)]*)\)\s*=\s*\@_;/s;
    ok(defined $sig_sub, 'AC17 sanity: _handle_signal\'s arg-unpack line is locatable');
    if (defined $sig_sub) {
        my @params = grep { /\S/ } split /,/, $sig_sub;
        is(scalar(@params), 5, '_handle_signal unpacks 5 parameters (gained exit_plan_step)')
            or diag("unpack line vars: $sig_sub");
    }
}

done_testing();
