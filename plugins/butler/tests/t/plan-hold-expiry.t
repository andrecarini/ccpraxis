#!/usr/bin/env perl
# platform: any
#
# ORACLE for blueprint package 02-plan-hold-expiry (wake-and-pause-consolidation),
# derived ONLY from
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/02-plan-hold-expiry-spec.md
# (AC1-AC14) plus the ledger's done criteria (1)-(4). NOT derived from any
# implementation: at the time this file is written, BpContinuityLease.pm has
# no holds_pending and daemon_loop has no hold-only tick, and BpPowerPlan.pm
# has no sandbox_hold_files/prune_stale_sandbox_holds. Every direct call to
# one of those not-yet-written subs goes through CL()/PP() below, which turns
# "Undefined subroutine" into a plain undef instead of dying -- the same
# technique continuity-lease-follows-arm.t's LZ() and
# power-plan-follows-arming.t's PP() already use for their own modules.
#
# THE REAL POWER PLAN, A REAL DAEMON AND REAL SLEEPING ARE NEVER USED.
#   - powercfg: every reconcile call in this file supplies a `run` seam
#     (plan_opts => { run => ... }), so BpPowerPlan::reconcile never reaches
#     powercfg_argv/run_powercfg's real path (spec 7's seam catalog).
#   - the refresher: daemon_loop is called IN-PROCESS with max_iterations and
#     a sleep seam; _spawn_daemon/_spawn_successor are never reached because
#     this file's own $0 ends in .t (_spawn_daemon's own test guard) and
#     AC6/AC8/AC12 that exercise the spawn DECISION pass their own `spawn`
#     seam rather than letting it fire for real.
#   - sleep: every daemon_loop call here passes `sleep => <seam>`; the seam
#     never calls a real sleep/select.
#
# AC -> DC mapping (ledger's Done criteria (1)-(4)):
#   AC1, AC2, AC6, AC7, AC8, AC9, AC10, AC12 -> DC(1) (and AC6/AC7 -> the
#     "start" half, ensure_daemon/cli_main)
#   AC2, AC3 -> DC(2) (the crashed-launcher plan recovery)
#   AC4, AC5, AC11 -> DC(3) (nothing stays alive with nothing to do)
#   AC13, AC14 -> DC(4) (the rest of test_paths is untouched; static guards)
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec;
use Encode qw(decode);
use MIME::Base64 qw(decode_base64);
use Config;

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/bp-keepawake.pl";
require "$S/BpPowerPlan.pm";
require "$S/BpAwakeConst.pm";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_LEASE_LIVE_SCRIPT} = "$S/BpContinuityLease.pm";

my $FRESH = $BpPowerPlan::SANDBOX_HOLD_FRESH_SECONDS;
my $BAL = '381b4222-f694-41f0-9685-ff5bb260df2e';
my $CW  = '54a34db5-af62-4d8a-ba50-af7155ee895a';

# ---------------------------------------------------------------------------
# CL(name, @args) -- call BpContinuityLease::<name> without ever crashing
# this file when the sub does not exist yet (holds_pending).
# PP(name, @args) -- same, for BpPowerPlan::<name> (sandbox_hold_files,
# prune_stale_sandbox_holds).
# ---------------------------------------------------------------------------
sub CL {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpContinuityLease::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub PP {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpPowerPlan::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub explain_undef { return 'CL()/PP() returned undef -- the sub does not exist yet' }

# ---------------------------------------------------------------------------
# generic fixtures, same shape as power-plan-sandbox-hold.t's fresh_group.
# ---------------------------------------------------------------------------
sub fresh_group {
    my $t = tempdir(CLEANUP => 1);
    (my $home = "$t/home") =~ s{\\}{/}g;
    (my $legacy = "$t/legacy") =~ s{\\}{/}g;
    make_path($home, $legacy);
    $ENV{BUTLER_STATE_DIR} = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $root = BpContinuityLease::store_root_for($legacy);
    return ($home, $legacy, $root);
}

sub hold_path { my ($root, $name) = @_; return BpPowerPlan::sandbox_hold_dir($root) . "/$name" }

sub hold_age {
    my ($root, $name) = @_;
    my $f = hold_path($root, $name);
    my $m = (stat($f))[9];
    return defined $m ? time() - $m : undef;
}

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# ---------------------------------------------------------------------------
# run_seam() -- a STATEFUL in-process fake for reconcile's `run` seam (spec
# 7). Starts active on Balanced; /setactive changes the tracked GUID;
# /getactivescheme answers the current one; /list always lists Balanced +
# Continuous work (CRLF, as in power-plan-sandbox-hold.t). Every call is
# recorded in argv order.
# ---------------------------------------------------------------------------
sub ok_result { return { status => 'ok', rc => 0, out => $_[0], ms => 1 } }
sub run_seam {
    my $active = $BAL;
    my @calls;
    my $fn = sub {
        push @calls, [@_];
        if ($_[0] eq '/getactivescheme') {
            my $name = $active eq $CW ? 'Continuous work' : 'Balanced';
            return ok_result("Power Scheme GUID: $active  ($name)\r\n");
        }
        if ($_[0] eq '/list') {
            return ok_result("\r\nExisting Power Schemes (* Active)\r\n---\r\n"
                . "Power Scheme GUID: $BAL  (Balanced)\r\nPower Scheme GUID: $CW  (Continuous work)\r\n");
        }
        if ($_[0] eq '/setactive') {
            $active = $_[1];
            return ok_result('');
        }
        return ok_result('');
    };
    return ($fn, \@calls, sub { return $active });
}
sub setactive_sequence { my ($calls) = @_; return map { $_->[1] } grep { $_->[0] eq '/setactive' } @$calls }

# ---------------------------------------------------------------------------
# make_reconcile_recorder(%o) -- builds (but does not install) a wrapper
# coderef for BpPowerPlan::reconcile (spec 7's "Reconcile recorder"). $o{hold}
# => [$root, $name] computes `age`/`exists_before` from that single hold file
# before each call; $o{after} is an optional per-call hook invoked with
# (\%call_record, $outcome) right after the real reconcile returns, so a test
# can simulate a race (AC10) or just observe. Returns ($wrapped, \@rec).
#
# THE CALLER installs it with `local *BpPowerPlan::reconcile = $wrapped;`
# directly in its own enclosing block (never inside this helper), so `local`
# restores the real sub exactly at that block's closing brace rather than
# layering recorders across blocks.
# ---------------------------------------------------------------------------
sub make_reconcile_recorder {
    my (%o) = @_;
    my $orig = \&BpPowerPlan::reconcile;
    my @rec;
    my $wrapped = sub {
        my ($d, %call_o) = @_;
        my ($age, $exists_before);
        if (ref $o{hold} eq 'ARRAY') {
            my ($root, $name) = @{ $o{hold} };
            $exists_before = (-e hold_path($root, $name)) ? 1 : 0;
            $age = hold_age($root, $name);
        }
        my $r = $orig->($d, %call_o);
        my $entry = {
            why => $call_o{why}, armed => $r->{armed}, arm_ids => $r->{arm_ids},
            age => $age, exists_before => $exists_before,
        };
        push @rec, $entry;
        $o{after}->($entry, $r) if ref $o{after} eq 'CODE';
        return $r;
    };
    return ($wrapped, \@rec);
}

# ---------------------------------------------------------------------------
# log_seam() -- collects [event, detail] pairs.
# ---------------------------------------------------------------------------
sub log_seam { my @ev; return (sub { push @ev, [@_] }, \@ev) }
sub log_count {
    my ($ev, $event, $like) = @_;
    my @m = grep { $_->[0] eq $event && (!defined $like || $_->[1] =~ $like) } @$ev;
    return scalar @m;
}

# ---------------------------------------------------------------------------
# recorder_seam() -- a generic call-recorder for kill_pid/spawn seams.
# ---------------------------------------------------------------------------
sub recorder_seam { my @calls; return (sub { push @calls, [@_]; return undef }, \@calls) }

# ---------------------------------------------------------------------------
# Addendum A (step 7) helpers.
#
# decode_encoded_command($b64) -- undoes _detached_spawn_argv's own encoding
# (base64, then UTF-16LE), returning the character string T (A.2).
#
# expected_detached_command($perl_win_bytes, $script_bytes) -- builds T from
# the spec's exact template, independently of the implementation. Inputs are
# the raw UTF-8 byte strings a caller would pass; q_escape doubles every
# single quote (PowerShell's own literal-quoting rule).
#
# run_spawn_impl(%d) -- calls BpContinuityLease::_spawn_daemon_impl directly
# (NOT through CL(), which swallows "dies") so a dying fork_exec/run_detached
# stub's propagation (AC20g) is observable. Returns ($ok, $ok ? $ret : $@).
# Never calls a real _run_detached/_fork_exec_daemon: every case below injects
# its own run_detached/fork_exec coderefs.
# ---------------------------------------------------------------------------
sub decode_encoded_command {
    my ($b64) = @_;
    my $bytes = eval { decode_base64($b64) };
    return undef unless defined $bytes;
    my $text = eval { decode('UTF-16LE', $bytes, Encode::FB_CROAK) };
    return $@ ? undef : $text;
}
sub q_escape { my ($s) = @_; (my $r = $s) =~ s/'/''/g; return $r }
sub expected_detached_command {
    my ($perl_win_bytes, $script_bytes) = @_;
    my $perl_u   = decode('UTF-8', $perl_win_bytes, Encode::FB_CROAK);
    my $script_u = decode('UTF-8', $script_bytes, Encode::FB_CROAK);
    my $arglist  = qq{"$script_u" lease --daemon};
    return "\$ErrorActionPreference = 'Stop'; \$p = Start-Process -FilePath '"
        . q_escape($perl_u) . "' -ArgumentList '" . q_escape($arglist)
        . "' -WindowStyle Hidden -PassThru; [Console]::Out.Write([string]\$p.Id)";
}
sub spawn_daemon_impl_code {
    no strict 'refs';
    return \&{"BpContinuityLease::_spawn_daemon_impl"};
}
sub run_spawn_impl {
    my (%d) = @_;
    my $code = spawn_daemon_impl_code();
    my $ret;
    my $ok = eval { $ret = $code->(%d); 1 };
    return ($ok, $ok ? $ret : $@);
}

$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ===========================================================================
# AC1 (DC1) -- one fresh hold, no arm: the sleep seam ages it past the
# window on its 2nd call. refresher-hold-tick x3 then refresher-exit; armed
# 1,1,0,0; the hold is gone after the 3rd reconcile and before the 4th;
# HOLD-PRUNED once; IDLE reason=no-live-arm once; 'done'; 3 sleep calls.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac1-aaaaaaaa';
    ok(BpPowerPlan::set_sandbox_hold($root, $name, 1), 'AC1 setup: a fresh hold is recorded');

    my ($run, $calls) = run_seam();
    my ($wrapped, $rec) = make_reconcile_recorder(hold => [$root, $name]);
    no warnings 'redefine';
    local *BpPowerPlan::reconcile = $wrapped;
    my ($log, $ev) = log_seam();
    my ($sleep_calls, $sleep_rec) = (0, []);
    my $sleep_seam = sub {
        push @$sleep_rec, $_[0];
        $sleep_calls++;
        if ($sleep_calls == 2) {
            my $old = time() - $FRESH - 5;
            utime($old, $old, hold_path($root, $name));
        }
    };

    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => (recorder_seam())[0], owner_winpid => undef,
            sleep => $sleep_seam, log => $log,
            plan_opts => { run => $run },
        );
    };
    ok(!$@, 'AC1: daemon_loop does not die') or diag($@);
    is($rv, 'done', 'AC1: daemon_loop returns done') or diag(explain_undef());

    is(scalar(@$rec), 4, 'AC1: exactly 4 reconcile calls were recorded') or diag(explain_undef());
    is_deeply([ map { $_->{why} } @$rec ],
        ['refresher-hold-tick', 'refresher-hold-tick', 'refresher-hold-tick', 'refresher-exit'],
        'AC1: the recorded whys are refresher-hold-tick x3 then refresher-exit');
    is_deeply([ map { $_->{armed} } @$rec ], [1, 1, 0, 0], 'AC1: armed is 1,1,0,0');
    is($rec->[3]{exists_before}, 0, 'AC1: the hold file is gone before the 4th reconcile')
        if @$rec >= 4;
    is($rec->[2]{exists_before}, 1, 'AC1: ...but was still there going into the 3rd')
        if @$rec >= 3;

    is(log_count($ev, 'HOLD-PRUNED', qr/name=\Q$name\E/), 1, 'AC1: HOLD-PRUNED name=<n> is logged exactly once');
    is(log_count($ev, 'IDLE', qr/reason=no-live-arm/), 1, 'AC1: IDLE reason=no-live-arm is logged exactly once');
    is($sleep_calls, 3, 'AC1: the sleep seam was called exactly 3 times');
}

# ===========================================================================
# AC2 (DC1, DC2) -- the run seam's /setactive sequence is [cw, then the
# starting plan], and the final active plan is the plan active before the
# hold. Reuses the AC1 fixture shape, fresh.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac2-bbbbbbbb';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);

    my ($run, $calls, $active_of) = run_seam();
    my ($wrapped) = make_reconcile_recorder(hold => [$root, $name]);
    no warnings 'redefine';
    local *BpPowerPlan::reconcile = $wrapped;
    my $sleep_calls = 0;
    my $sleep_seam = sub {
        $sleep_calls++;
        if ($sleep_calls == 2) {
            my $old = time() - $FRESH - 5;
            utime($old, $old, hold_path($root, $name));
        }
    };

    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 40, journal => 0,
        spawn => sub { undef }, powershell_available => sub { 1 },
        kill_pid => sub { }, owner_winpid => undef,
        sleep => $sleep_seam,
        plan_opts => { run => $run },
    );

    my @seq = setactive_sequence($calls);
    is_deeply(\@seq, [$CW, $BAL], 'AC2: /setactive sequence is [Continuous work, then Balanced]')
        or diag(explain_undef());
    is($active_of->(), $BAL, 'AC2: the final active plan is the plan active before the hold');
}

# ===========================================================================
# AC3 (DC2) -- a crashed launcher, proven through cli_main + a virtual
# clock. The hold is written once by in-process cli_main; ensure_daemon is
# stubbed and STDOUT is captured to a File::Temp file (never a scalar --
# project CLAUDE.md). Then, with the reconcile recorder installed only AFTER
# cli_main returns, daemon_loop(tick=>60, sleep=>seam) runs, where each
# sleep call shifts the hold's mtime back by 60s and never really sleeps.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac3-cccccccc';

    my @ens_calls;
    my $stub = sub { push @ens_calls, [@_]; return 'idle' };
    {
        no warnings 'redefine';
        local *BpContinuityLease::ensure_daemon = $stub;

        my (undef, $outfile) = tempfile();
        open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
        open(STDOUT, '>', $outfile) or die "redirect STDOUT: $!";
        my $rc = eval { BpPowerPlan::cli_main('reconcile', '--why', 'sandbox-hold', '--hold', $name) };
        open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
        close $saved_out;
        is($rc, 0, 'AC3 setup: cli_main --hold exits 0') or diag($@ // slurp($outfile));
    }
    is(scalar(@ens_calls), 1, 'AC3: cli_main calls the stubbed ensure_daemon exactly once')
        or diag(explain_undef());
    is($ens_calls[0][0], BpContinuityLease::legacy_dir(), 'AC3: ...with legacy_dir() as its first argument')
        if @ens_calls;
    ok(-e hold_path($root, $name), 'AC3 setup: the hold file exists after cli_main --hold');

    my ($run, $calls) = run_seam();
    my ($wrapped, $rec) = make_reconcile_recorder(hold => [$root, $name]);
    no warnings 'redefine';
    local *BpPowerPlan::reconcile = $wrapped;
    my $sleep_seam = sub {
        my $f = hold_path($root, $name);
        return unless -e $f;
        my $m = (stat($f))[9];
        my $new = (defined $m ? $m : time()) - $_[0];
        utime($new, $new, $f);
    };

    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 60, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => $sleep_seam,
            plan_opts => { run => $run },
        );
    };
    is($rv, 'done', 'AC3: daemon_loop ends through done') or diag($@ // explain_undef());

    my @hold_ticks = grep { $_->{why} eq 'refresher-hold-tick' } @$rec;
    ok(scalar(@hold_ticks) >= 1, 'AC3: at least one refresher-hold-tick reconcile was recorded')
        or diag(explain_undef());
    for my $r (@hold_ticks) {
        next unless defined $r->{age} && $r->{age} <= $FRESH;
        ok($r->{armed} >= 1, "AC3: a hold-tick at age $r->{age} (<= FRESH) has armed >= 1");
    }
    my ($first_expired) = grep { defined $_->{age} && $_->{armed} == 0 && $_->{why} eq 'refresher-hold-tick' } @$rec;
    ok(defined $first_expired, 'AC3: a hold-tick eventually reports armed==0 once the virtual clock expires it')
        or diag(explain_undef());
    if (defined $first_expired) {
        cmp_ok($first_expired->{age}, '>', $FRESH, 'AC3: ...and its age is > LEASE_FRESH');
        cmp_ok($first_expired->{age}, '<=', $FRESH + 60 + 2, 'AC3: ...and age <= LEASE_FRESH + 60 + 2 (tick + slack)');
    }
    my @setactive_to_bal = grep { $_->[0] eq '/setactive' && $_->[1] eq $BAL } @$calls;
    ok(scalar(@setactive_to_bal) >= 1, 'AC3: the plan is switched back to Balanced (the no-hold result)');

    my @whys = map { $_->{why} } @$rec;
    is($whys[-1], 'refresher-exit', 'AC3: the loop finishes with a refresher-exit reconcile, as in AC1')
        or diag(explain_undef());
}

# ===========================================================================
# AC4 (DC3) -- no hold and no arm: daemon_loop returns done, sleep seam
# never called, no HOLD-TICK; ensure_daemon returns idle, spawn seam never
# called. Checked for: absent dir, empty dir, a dir with only non-counting
# entries.
# ===========================================================================
for my $case (qw(absent empty junk-only)) {
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';

    if ($case eq 'empty') {
        make_path(BpPowerPlan::sandbox_hold_dir($root));
    } elsif ($case eq 'junk-only') {
        my $d = BpPowerPlan::sandbox_hold_dir($root);
        make_path($d);
        open(my $fh, '>', "$d/.hidden") or die $!;
        close $fh;
        open(my $fh2, '>', "$d/bad name") or die $!;
        close $fh2;
        make_path("$d/claude-x");
    }
    # 'absent': the sandbox-holds dir is never created.

    my ($run) = run_seam();
    my ($log, $ev) = log_seam();
    my $sleep_calls = 0;
    my $sleep_seam = sub { $sleep_calls++ };

    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => $sleep_seam, log => $log,
            plan_opts => { run => $run },
        );
    };
    is($rv, 'done', "AC4 ($case): daemon_loop returns done") or diag($@);
    is($sleep_calls, 0, "AC4 ($case): the sleep seam is never called");
    is(log_count($ev, 'HOLD-TICK'), 0, "AC4 ($case): no HOLD-TICK is ever logged");

    delete local $ENV{CCPRAXIS_NO_WAKELOCK};
    my ($sp, $sp_calls) = recorder_seam();
    my $verdict = BpContinuityLease::ensure_daemon($legacy, spawn => $sp);
    is($verdict, 'idle', "AC4 ($case): ensure_daemon returns idle") or diag(explain_undef());
    is(scalar(@$sp_calls), 0, "AC4 ($case): ...and never calls the spawn seam");
}

# ===========================================================================
# AC5 (DC3) -- off Windows, holds_pending/daemon_loop's hold-only mode are
# inert even with a fresh hold file.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'posix';
    my $name = 'claude-ac5-dddddddd';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);

    is(CL('holds_pending', $legacy), 0, 'AC5: holds_pending is 0 off Windows with a fresh hold')
        or diag(explain_undef());

    my ($run) = run_seam();
    my $sleep_calls = 0;
    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { $sleep_calls++ },
            plan_opts => { run => $run },
        );
    };
    is($rv, 'done', 'AC5: daemon_loop still returns done off Windows') or diag($@);
    is($sleep_calls, 0, 'AC5: ...after zero sleep-seam calls');

    delete local $ENV{CCPRAXIS_NO_WAKELOCK};
    my ($sp, $sp_calls) = recorder_seam();
    is(BpContinuityLease::ensure_daemon($legacy, spawn => $sp), 'idle',
        'AC5: ensure_daemon (no arm) returns idle off Windows too');
}

# ===========================================================================
# AC6 (DC1, start half) -- B8: ensure_daemon's decision with a hold present,
# no arm.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac6-eeeeeeee';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);

    {
        delete local $ENV{CCPRAXIS_NO_WAKELOCK};
        # ensure_daemon only returns 'spawned' when the spawn seam yields a defined pid
        # (recorder_seam()'s stub always returns undef, which yields 'refused' instead).
        my @sp_calls;
        my $sp = sub { push @sp_calls, [@_]; return 9001 };
        my $v = BpContinuityLease::ensure_daemon($legacy, spawn => $sp);
        is($v, 'spawned', 'AC6: with a hold present, no arm, no lease.pid: ensure_daemon returns spawned')
            or diag(explain_undef());
        is(scalar(@sp_calls), 1, 'AC6: ...and the spawn seam was called exactly once');
        is($sp_calls[0][0], $legacy, 'AC6: ...with $dir') if @sp_calls;
    }
    {
        delete local $ENV{CCPRAXIS_NO_WAKELOCK};
        my $pf = BpContinuityLease::daemon_pid_file($legacy);
        unless (-e $pf) {
            open(my $fh, '>', $pf) or die "open $pf: $!";
            print {$fh} "$$\n";
            close $fh;
        }
        utime(time(), time(), $pf);
        my ($sp, $sp_calls) = recorder_seam();
        my $v = BpContinuityLease::ensure_daemon($legacy, spawn => $sp);
        is($v, 'running', 'AC6: with a fresh lease.pid: ensure_daemon returns running');
        is(scalar(@$sp_calls), 0, 'AC6: ...and does not spawn');
    }
    {
        local $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        my ($sp, $sp_calls) = recorder_seam();
        my $v = BpContinuityLease::ensure_daemon($legacy, spawn => $sp);
        is($v, 'refused', 'AC6: with CCPRAXIS_NO_WAKELOCK set: ensure_daemon returns refused');
        is(scalar(@$sp_calls), 0, 'AC6: ...and does not spawn');
    }
}

# ===========================================================================
# AC7 (DC1, start half) -- B7: cli_main's call into ensure_daemon.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();

    my $run_case = sub {
        my (@argv) = @_;
        my @ens_calls;
        no warnings 'redefine';
        local *BpContinuityLease::ensure_daemon = sub { push @ens_calls, [@_]; return 'idle' };
        my (undef, $outfile) = tempfile();
        open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
        open(STDOUT, '>', $outfile) or die "redirect STDOUT: $!";
        my $rc = eval { BpPowerPlan::cli_main(@argv) };
        open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
        close $saved_out;
        return (\@ens_calls, (defined $rc ? $rc : -1), slurp($outfile));
    };

    my ($c1) = $run_case->('reconcile', '--release', 'claude-ac7-ffffffff');
    is(scalar(@$c1), 0, 'AC7: --release never calls ensure_daemon');

    my ($c2) = $run_case->('reconcile');
    is(scalar(@$c2), 0, 'AC7: a plain reconcile (no hold flag) never calls ensure_daemon');

    my ($c3) = $run_case->('reconcile', '--hold', '../x');
    is(scalar(@$c3), 0, 'AC7: a bad hold name (usage error) never calls ensure_daemon');

    {
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = 'relative/x';
        my ($c4) = $run_case->('reconcile', '--hold', 'claude-ac7-ffffffff');
        is(scalar(@$c4), 0, 'AC7: an unresolvable dir never calls ensure_daemon');
    }

    my ($c5, $rc5) = $run_case->('reconcile', '--hold', 'claude-ac7-ffffffff');
    is(scalar(@$c5), 1, 'AC7: a valid --hold calls ensure_daemon exactly once') or diag(explain_undef());
    is($rc5, 0, 'AC7: ...and still exits 0');

    # Byte-identical stdout/exit code across stub verdicts idle/spawned/refused/dies.
    my %outs;
    for my $verdict (qw(idle spawned refused dies)) {
        no warnings 'redefine';
        local *BpContinuityLease::ensure_daemon = sub {
            die "boom\n" if $verdict eq 'dies';
            return $verdict;
        };
        my (undef, $outfile) = tempfile();
        open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
        open(STDOUT, '>', $outfile) or die "redirect STDOUT: $!";
        my $rc = eval { BpPowerPlan::cli_main('reconcile', '--hold', 'claude-ac7-gggggggg') };
        open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
        close $saved_out;
        $outs{$verdict} = { out => slurp($outfile), rc => (defined $rc ? $rc : -1) };
    }
    my @verdicts = qw(idle spawned refused dies);
    for my $v (@verdicts[1 .. $#verdicts]) {
        is($outs{$v}{out}, $outs{idle}{out}, "AC7: stdout is byte-identical for verdict '$v' vs 'idle'")
            or diag(explain_undef());
        is($outs{$v}{rc}, $outs{idle}{rc}, "AC7: exit code is identical for verdict '$v' vs 'idle'");
    }
}

# ===========================================================================
# AC8 (DC1) -- B9: two holds, one stale. One hold-only tick: armed==1 with
# arm_ids [sandbox:<fresh>], the stale file removed, the fresh file kept.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my ($fresh_name, $stale_name) = ('claude-ac8-fresh0001', 'claude-ac8-stale0001');
    BpPowerPlan::set_sandbox_hold($root, $fresh_name, 1);
    BpPowerPlan::set_sandbox_hold($root, $stale_name, 1);
    my $old = time() - $FRESH - 5;
    utime($old, $old, hold_path($root, $stale_name));

    my ($run) = run_seam();
    my ($wrapped, $rec) = make_reconcile_recorder();
    {
        no warnings 'redefine';
        local *BpPowerPlan::reconcile = $wrapped;

        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { },
            plan_opts => { run => $run },
        );
    }

    is(scalar(@$rec), 1, 'AC8: exactly one reconcile call on the one hold-only tick') or diag(explain_undef());
    if (@$rec) {
        is($rec->[0]{armed}, 1, 'AC8: armed is 1 (only the fresh hold counts)');
        is_deeply($rec->[0]{arm_ids}, ["sandbox:$fresh_name"], 'AC8: arm_ids is [sandbox:<fresh>]');
    }
    ok(!-e hold_path($root, $stale_name), 'AC8: the stale file was removed');
    ok(-e hold_path($root, $fresh_name), 'AC8: the fresh file was kept');
}

# ===========================================================================
# AC9 (DC1) -- sandbox_hold_files / prune_stale_sandbox_holds unit, no
# daemon.
# ===========================================================================
{
    my (undef, undef, $root) = fresh_group();
    my $d = BpPowerPlan::sandbox_hold_dir($root);
    make_path($d);
    my %mtime = (
        fresh    => time(),
        'edge-in' => time() - ($FRESH - 2),
        stale    => time() - ($FRESH + 2),
        future   => time() + 300,
        'bad name' => time() - ($FRESH + 2),
    );
    for my $n (keys %mtime) {
        open(my $fh, '>', "$d/$n") or die $!;
        close $fh;
        utime($mtime{$n}, $mtime{$n}, "$d/$n");
    }
    make_path("$d/claude-x");

    my $files = PP('sandbox_hold_files', $root);
    is_deeply($files, ['edge-in', 'fresh', 'future', 'stale'],
        'AC9: sandbox_hold_files returns exactly the matching regular files, sorted') or diag(explain_undef());

    my $result = PP('prune_stale_sandbox_holds', $root);
    if (ref $result eq 'HASH') {
        is(scalar(@{ $result->{removed} }), 1, 'AC9: prune removes exactly one file') or diag(explain_undef());
        if (@{ $result->{removed} }) {
            is($result->{removed}[0]{name}, 'stale', 'AC9: the removed one is "stale"');
            cmp_ok($result->{removed}[0]{age}, '>=', $FRESH + 2, 'AC9: its reported age is >= FRESH + 2');
        }
        is_deeply($result->{failed}, [], 'AC9: failed is empty');
    } else {
        fail('AC9: prune_stale_sandbox_holds returned a non-HASH result');
        diag(explain_undef());
    }
    for my $n (qw(fresh edge-in future), 'bad name') {
        ok(-e "$d/$n", "AC9: '$n' still exists after prune");
    }
    ok(-d "$d/claude-x", 'AC9: the subdirectory claude-x still exists after prune');

    # a root with no sandbox-holds/ at all
    my (undef, undef, $root2) = fresh_group();
    my $result2 = PP('prune_stale_sandbox_holds', $root2);
    if (ref $result2 eq 'HASH') {
        is_deeply($result2, { removed => [], failed => [] },
            'AC9: a root with no sandbox-holds/ returns {removed=>[],failed=>[]}') or diag(explain_undef());
    } else {
        fail('AC9: prune_stale_sandbox_holds (no dir) returned a non-HASH result');
        diag(explain_undef());
    }
    ok(!-d BpPowerPlan::sandbox_hold_dir($root2), 'AC9: ...and does not create the directory');
}

# ===========================================================================
# AC10 (DC1) -- B10: a hold rewritten between the reconcile read and the
# prune survives that tick. The reconcile recorder's after-hook, on the
# first tick where the hold is stale and only on that tick, touches the hold
# to now AFTER the real reconcile returns.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac10-iiiiiiii';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);

    my ($run) = run_seam();
    my $touched_once = 0;
    my ($wrapped, $rec) = make_reconcile_recorder(
        hold => [$root, $name],
        after => sub {
            my ($entry, $outcome) = @_;
            if (!$touched_once && defined $entry->{age} && $outcome->{armed} == 0) {
                $touched_once = 1;
                utime(time(), time(), hold_path($root, $name));
            }
        },
    );
    no warnings 'redefine';
    local *BpPowerPlan::reconcile = $wrapped;
    my $sleep_calls = 0;
    my $sleep_seam = sub {
        $sleep_calls++;
        if ($sleep_calls == 2) {
            my $old = time() - $FRESH - 5;
            utime($old, $old, hold_path($root, $name));
        } elsif ($sleep_calls == 5) {
            my $old = time() - $FRESH - 5;
            utime($old, $old, hold_path($root, $name));
        }
    };

    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => $sleep_seam,
            plan_opts => { run => $run },
        );
    };
    is($rv, 'done', 'AC10: the run still ends through done') or diag($@ // explain_undef());

    ok($touched_once, 'AC10 setup: the race-simulation after-hook fired once') or diag(explain_undef());
    my @hold_ticks_after_race = grep { $_->{why} eq 'refresher-hold-tick' } @$rec;
    ok(scalar(@hold_ticks_after_race) >= 2,
        'AC10: the loop continued with further refresher-hold-tick calls after the simulated race')
        or diag(explain_undef());
    my @whys = map { $_->{why} } @$rec;
    is($whys[-1], 'refresher-exit', 'AC10: the run eventually ends with refresher-exit') or diag(explain_undef());
}

# ===========================================================================
# AC11 (DC3) -- B11: a prune failure is logged once and stops keeping the
# refresher alive; the next tick takes the IDLE exit.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac11-jjjjjjjj';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);
    my $old = time() - $FRESH - 5;
    utime($old, $old, hold_path($root, $name));

    no warnings 'redefine';
    local *BpPowerPlan::prune_stale_sandbox_holds = sub {
        return { removed => [], failed => [$name] };
    };

    my ($run) = run_seam();
    my ($log, $ev) = log_seam();
    my ($wrapped, $rec) = make_reconcile_recorder();
    local *BpPowerPlan::reconcile = $wrapped;

    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
    };
    is($rv, 'done', 'AC11: the run ends through done') or diag($@ // explain_undef());
    is(log_count($ev, 'HOLD-PRUNE-FAILED', qr/name=\Q$name\E/), 1,
        'AC11: HOLD-PRUNE-FAILED name=<n> is logged exactly once') or diag(explain_undef());
    my @whys = map { $_->{why} } @$rec;
    is($whys[-1], 'refresher-exit', 'AC11: the next tick takes the IDLE exit (refresher-exit reconcile last)')
        or diag(explain_undef());
    ok(-e hold_path($root, $name), 'AC11: the stale file still exists (the prune genuinely failed)');
}

# ===========================================================================
# AC12 (DC1) -- B12: a host helper held under keepawake.pid is released on
# the hold-only tick's sync(active=>0); the spawn seam is never called.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac12-kkkkkkkk';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);
    open(my $fh, '>', "$legacy/keepawake.pid") or die $!;
    print {$fh} "4242\n";
    close $fh;

    my ($run) = run_seam();
    my ($kill_seam, $kill_calls) = recorder_seam();
    my ($sp, $sp_calls) = recorder_seam();

    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        spawn => $sp, powershell_available => sub { 1 },
        kill_pid => $kill_seam, owner_winpid => undef,
        sleep => sub { },
        plan_opts => { run => $run },
    );

    is(scalar(@$kill_calls), 1, 'AC12: the kill_pid seam is called exactly once') or diag(explain_undef());
    is($kill_calls->[0][0], 4242, 'AC12: ...with the recorded winpid 4242') if @$kill_calls;
    is(scalar(@$sp_calls), 0, 'AC12: the spawn seam is never called');
}

# ===========================================================================
# AC13 (DC4) -- out of scope for THIS file by design: the ledger's write set
# allows editing only plan-hold-expiry.t among test_paths, so the other
# test_paths files passing is verified by running THEM (unmodified), never
# by assertions added here. See the step-3 report for how that was checked.
# ===========================================================================
note('AC13: verified externally by running the sibling test_paths files unmodified (see report)');

# ===========================================================================
# AC14 (DC4, guard) -- static: the IDLE log text and cli_main's usage string
# are unchanged.
# ===========================================================================
{
    my $lease_src = slurp("$S/BpContinuityLease.pm");
    like($lease_src, qr/\$log->\('IDLE', 'reason=no-live-arm'\)/,
        "AC14: daemon_loop's IDLE log text is exactly 'reason=no-live-arm'");
    my $plan_src = slurp("$S/BpPowerPlan.pm");
    like($plan_src, qr/\QUSAGE = "usage: bp-power-plan reconcile [--why WORD] [--json] [--hold NAME | --release NAME]\n"\E/,
        "AC14: cli_main's \$USAGE string is unchanged");
}

# ===========================================================================
# Addendum A (step 7): the detached Windows spawn, prune-race fix, future-
# dated-hold fix, and the arm-tick-never-prunes guard. None of these may
# spawn a real process, powershell, or touch the real power plan -- every
# assertion below goes through the pure helpers (CL()/direct) or injected
# dependencies (run_detached/fork_exec/unlink), never a production effector.
# ===========================================================================

# ===========================================================================
# AC15 (DC2, DC3) -- _spawn_method: pure, 6 cases from A.2's table.
# ===========================================================================
{
    is(CL('_spawn_method', platform => 'windows', ps_available => 1, perl_win => 'C:/p/perl.exe'),
        'detached', 'AC15: windows + ps_available + a usable perl_win -> detached') or diag(explain_undef());
    is(CL('_spawn_method', platform => 'windows', ps_available => 0, perl_win => 'C:/p/perl.exe'),
        'fork', 'AC15: windows, ps_available 0 -> fork') or diag(explain_undef());
    is(CL('_spawn_method', platform => 'windows', ps_available => 1, perl_win => undef),
        'fork', 'AC15: windows, ps_available 1, perl_win undef -> fork') or diag(explain_undef());
    is(CL('_spawn_method', platform => 'windows', ps_available => 1, perl_win => ''),
        'fork', "AC15: windows, ps_available 1, perl_win '' -> fork") or diag(explain_undef());
    is(CL('_spawn_method', platform => 'posix', ps_available => 1, perl_win => 'C:/p/perl.exe'),
        'fork-setsid', 'AC15: posix (any ps/perl) -> fork-setsid') or diag(explain_undef());
    is(CL('_spawn_method', platform => 'unsupported', ps_available => 0, perl_win => undef),
        'fork-setsid', 'AC15: unsupported (any ps/perl) -> fork-setsid') or diag(explain_undef());
}

# ===========================================================================
# AC16 (DC2) -- _detached_spawn_argv: exact argv shape and the decoded
# -EncodedCommand text (base64 -> UTF-16LE), including a non-ASCII (U+00E9)
# byte in the script path.
# ===========================================================================
{
    my $perl_win     = 'C:/Program Files/Git/usr/bin/perl.exe';
    my $script_bytes = "/c/Users/Andr\xc3\xa9/x/BpContinuityLease.pm"; # UTF-8 bytes for "André"
    my @argv = CL('_detached_spawn_argv', $perl_win, $script_bytes);

    is(scalar(@argv), 5, 'AC16: _detached_spawn_argv returns exactly 5 elements') or diag(explain_undef());
    is_deeply([ @argv[0 .. 3] ], ['powershell.exe', '-NoProfile', '-NonInteractive', '-EncodedCommand'],
        'AC16: the first four elements are powershell.exe -NoProfile -NonInteractive -EncodedCommand')
        if @argv >= 4;
    ok(!(grep { $_ eq '-WindowStyle' } @argv), 'AC16: no element equals -WindowStyle');
    if (@argv >= 5) {
        like($argv[4], qr/\A[A-Za-z0-9+\/]+=*\z/, 'AC16: element 5 is base64 (and does not start with /)');
        unlike($argv[4], qr/\A\//, 'AC16: element 5 does not start with /') if defined $argv[4];
        ok(!(grep { defined $_ && (index($_, ':') >= 0 || index($_, ';') >= 0) } @argv),
            'AC16: no element contains : or ;');

        my $decoded = decode_encoded_command($argv[4]);
        my $expected = expected_detached_command($perl_win, $script_bytes);
        is($decoded, $expected, 'AC16: the decoded -EncodedCommand text is exactly T, with e-acute as U+00E9')
            or diag(explain_undef());
    } else {
        fail('AC16: argv has fewer than 5 elements, cannot check the encoded command');
        diag(explain_undef());
    }
}

# ===========================================================================
# AC17 (DC2) -- quoting (every ' doubled) and refusal cases.
# ===========================================================================
{
    my $perl_win = "C:/O'Brien/perl.exe";
    my $script   = '/c/x/BpContinuityLease.pm';
    my @argv = CL('_detached_spawn_argv', $perl_win, $script);
    if (@argv >= 5) {
        my $decoded = decode_encoded_command($argv[4]);
        like($decoded // '', qr/'C:\/O''Brien\/perl\.exe'/,
            "AC17: a perl_win containing ' appears doubled, as 'C:/O''Brien/perl.exe'")
            or diag(explain_undef());
    } else {
        fail("AC17: _detached_spawn_argv refused a perl_win containing '");
        diag(explain_undef());
    }

    my $perl_win2 = 'C:/p/perl.exe';
    my $script2   = "/c/x/B'p.pm";
    my @argv2 = CL('_detached_spawn_argv', $perl_win2, $script2);
    if (@argv2 >= 5) {
        my $decoded2 = decode_encoded_command($argv2[4]);
        like($decoded2 // '', qr/"\/c\/x\/B''p\.pm" lease --daemon/,
            "AC17: a script containing ' is doubled the same way inside the ArgumentList")
            or diag(explain_undef());
    } else {
        fail("AC17: _detached_spawn_argv refused a script containing '");
        diag(explain_undef());
    }
}
{
    my @refusals = (
        ['perl not in drive form' => '/usr/bin/perl', '/c/x/BpContinuityLease.pm'],
        ['bare perl.exe, no drive' => 'perl.exe', '/c/x/BpContinuityLease.pm'],
        ['script undef' => 'C:/p/perl.exe', undef],
        ["script ''" => 'C:/p/perl.exe', ''],
        ['perl_win contains "' => 'C:/p"/perl.exe', '/c/x/BpContinuityLease.pm'],
        ['script contains "' => 'C:/p/perl.exe', '/c/x/B"p.pm'],
        ["perl_win contains \\n" => "C:/p/perl.exe\n", '/c/x/BpContinuityLease.pm'],
        ["script contains \\n" => 'C:/p/perl.exe', "/c/x/B\np.pm"],
        ['script invalid UTF-8' => 'C:/p/perl.exe', "\xff\xfe"],
    );
    for my $case (@refusals) {
        my ($label, $perl_win, $script) = @$case;
        my @argv = CL('_detached_spawn_argv', $perl_win, $script);
        is(scalar(@argv), 0, "AC17: refuses ($label) -- returns the empty list")
            or diag(explain_undef());
    }
}

# ===========================================================================
# AC18 (DC2) -- _native_exe_path: pure cases plus one host-conditional case
# (msys/cygwin only).
# ===========================================================================
{
    is(CL('_native_exe_path', 'C:\\a b\\perl.exe'), 'C:/a b/perl.exe',
        'AC18: backslashes fold to /, .exe already present') or diag(explain_undef());
    is(CL('_native_exe_path', 'C:/x/perl'), 'C:/x/perl.exe',
        'AC18: a drive-form path with no extension gets .exe appended') or diag(explain_undef());
    is(CL('_native_exe_path', 'C:/x/PERL.EXE'), 'C:/x/PERL.EXE',
        'AC18: an existing .EXE (any case) is left unchanged') or diag(explain_undef());
    is(CL('_native_exe_path', '/c/x/perl'), 'C:/x/perl.exe',
        'AC18: a /c/... POSIX-looking path is rewritten to C:/x/perl.exe') or diag(explain_undef());
    is(CL('_native_exe_path', ''), undef, "AC18: '' -> undef") or diag(explain_undef());
    is(CL('_native_exe_path', undef), undef, 'AC18: undef -> undef') or diag(explain_undef());

    SKIP: {
        skip 'AC18 host-conditional case only applies under msys/cygwin', 2
            unless $^O =~ /^(?:msys|cygwin)$/;
        my $p = CL('_native_exe_path', $^X);
        like($p // '', qr/\A[A-Za-z]:\/.+\.exe\z/i,
            'AC18: _native_exe_path($^X) matches the drive-form .exe shape on msys/cygwin')
            or diag(explain_undef());
        ok(defined $p && -f $p, 'AC18: ...and that file actually exists') or diag(explain_undef());
    }

    # Driver ruling (ledger attempt log, amending spec Addendum A.2 step 5,
    # 2026-11-04): a bare/relative interpreter name (e.g. the literal 'perl',
    # which is what $^X is under `perl file`) is resolved through
    # $Config{perlpath} (absolute) rather than refused outright; undef is
    # returned only when no absolute path can be obtained at all (the ''
    # and undef refusals above still hold -- there is nothing to resolve).
    SKIP: {
        skip 'AC18 (ruling) only applies on the Windows family', 1
            unless $^O =~ /^(?:MSWin32|msys|cygwin)$/;
        is(CL('_native_exe_path', 'perl'), CL('_native_exe_path', $Config{perlpath}),
            'AC18 (ruling): a bare interpreter name resolves through $Config{perlpath} to the same absolute Windows-form .exe path')
            or diag(explain_undef());
    }
}

# ===========================================================================
# AC19 (DC2) -- _parse_spawned_pid: pure cases.
# ===========================================================================
{
    is(CL('_parse_spawned_pid', '12345', 0), 12345, 'AC19: a clean pid, status 0 -> 12345')
        or diag(explain_undef());
    is(CL('_parse_spawned_pid', "  12345\r\n", 0), 12345, 'AC19: whitespace-padded pid -> 12345')
        or diag(explain_undef());
    is(CL('_parse_spawned_pid', '12345', 256), undef, 'AC19: a non-zero status -> undef')
        or diag(explain_undef());
    is(CL('_parse_spawned_pid', '', 0), undef, "AC19: '' -> undef") or diag(explain_undef());
    is(CL('_parse_spawned_pid', undef, 0), undef, 'AC19: undef out -> undef') or diag(explain_undef());
    is(CL('_parse_spawned_pid', '0', 0), undef, "AC19: '0' -> undef (not 1-9 leading)")
        or diag(explain_undef());
    is(CL('_parse_spawned_pid', 'abc', 0), undef, 'AC19: non-numeric -> undef') or diag(explain_undef());
    is(CL('_parse_spawned_pid', '12 34', 0), undef, 'AC19: embedded space -> undef')
        or diag(explain_undef());
}

# ===========================================================================
# AC20 (DC2, DC3) -- _spawn_daemon_impl, orchestration with injected
# run_detached/fork_exec. Cases (a)-(g) from A.2's pseudocode.
# ===========================================================================
{
    my $script = '/c/x/BpContinuityLease.pm';
    my $perl   = 'C:/p/perl.exe';

    # (a) detached path succeeds.
    {
        my (@rd, @fe);
        my ($ok, $ret) = run_spawn_impl(
            script => $script, platform => 'windows', ps_available => 1, perl_win => $perl,
            run_detached => sub { push @rd, [@_]; return 4321 },
            fork_exec    => sub { push @fe, [@_]; return 777 },
        );
        ok($ok, 'AC20a: _spawn_daemon_impl does not die on the detached success path') or diag($ret);
        is($ret, 4321, 'AC20a: ...and returns run_detached\'s pid') if $ok;
        is(scalar(@rd), 1, 'AC20a: run_detached is called exactly once') or diag(explain_undef());
        if (@rd) {
            my @expected_argv = CL('_detached_spawn_argv', $perl, $script);
            is_deeply($rd[0][0], \@expected_argv,
                'AC20a: ...with an argv equal to _detached_spawn_argv(perl_win, script)')
                or diag(explain_undef());
        }
        is(scalar(@fe), 0, 'AC20a: fork_exec is never called');
    }

    # (b) run_detached returns undef -> fallback to fork_exec(script, 0).
    {
        my (@rd, @fe);
        my ($ok, $ret) = run_spawn_impl(
            script => $script, platform => 'windows', ps_available => 1, perl_win => $perl,
            run_detached => sub { push @rd, [@_]; return undef },
            fork_exec    => sub { push @fe, [@_]; return 777 },
        );
        ok($ok, 'AC20b: does not die when run_detached returns undef') or diag($ret);
        is($ret, 777, 'AC20b: ...and returns fork_exec\'s pid') if $ok;
        is(scalar(@fe), 1, 'AC20b: fork_exec is called exactly once') or diag(explain_undef());
        is_deeply($fe[0], [$script, 0], 'AC20b: ...with (script, 0)') if @fe;
    }

    # (c) run_detached dies -> same fallback.
    {
        my (@rd, @fe);
        my ($ok, $ret) = run_spawn_impl(
            script => $script, platform => 'windows', ps_available => 1, perl_win => $perl,
            run_detached => sub { push @rd, [@_]; die "nope\n" },
            fork_exec    => sub { push @fe, [@_]; return 777 },
        );
        ok($ok, 'AC20c: does not die when run_detached itself dies (caught internally)') or diag($ret);
        is($ret, 777, 'AC20c: ...and returns fork_exec\'s pid') if $ok;
        is(scalar(@fe), 1, 'AC20c: fork_exec is called exactly once') or diag(explain_undef());
        is_deeply($fe[0], [$script, 0], 'AC20c: ...with (script, 0)') if @fe;
    }

    # (d) windows/ps1 with a script containing " -> argv refused -> fork_exec fallback,
    # run_detached never called.
    {
        my $bad_script = '/c/x/"quoted".pm';
        my (@rd, @fe);
        my ($ok, $ret) = run_spawn_impl(
            script => $bad_script, platform => 'windows', ps_available => 1, perl_win => $perl,
            run_detached => sub { push @rd, [@_]; return 4321 },
            fork_exec    => sub { push @fe, [@_]; return 777 },
        );
        ok($ok, 'AC20d: does not die when the argv is refused') or diag($ret);
        is(scalar(@rd), 0, 'AC20d: run_detached is never called (argv refused)') or diag(explain_undef());
        is(scalar(@fe), 1, 'AC20d: fork_exec is called exactly once') or diag(explain_undef());
        is_deeply($fe[0], [$bad_script, 0], 'AC20d: ...with (script, 0)') if @fe;
    }

    # (e) windows/ps_available 0 -> fork_exec(script, 0) only ('fork' method).
    {
        my (@rd, @fe);
        run_spawn_impl(
            script => $script, platform => 'windows', ps_available => 0, perl_win => $perl,
            run_detached => sub { push @rd, [@_]; return 4321 },
            fork_exec    => sub { push @fe, [@_]; return 777 },
        );
        is(scalar(@rd), 0, 'AC20e: windows, ps_available 0: run_detached is never called')
            or diag(explain_undef());
        is(scalar(@fe), 1, 'AC20e: ...fork_exec is called exactly once') or diag(explain_undef());
        is_deeply($fe[0], [$script, 0], 'AC20e: ...with (script, 0)') if @fe;
    }

    # (f) posix -> fork_exec(script, 1) only ('fork-setsid' method), run_detached never called.
    {
        my (@rd, @fe);
        run_spawn_impl(
            script => $script, platform => 'posix', ps_available => 1, perl_win => $perl,
            run_detached => sub { push @rd, [@_]; return 4321 },
            fork_exec    => sub { push @fe, [@_]; return 777 },
        );
        is(scalar(@rd), 0, 'AC20f: posix: run_detached is never called') or diag(explain_undef());
        is(scalar(@fe), 1, 'AC20f: ...fork_exec is called exactly once') or diag(explain_undef());
        is_deeply($fe[0], [$script, 1], 'AC20f: ...with (script, 1) (setsid requested)') if @fe;
    }

    # (g) a dying fork_exec propagates the die (ensure_daemon's own eval turns it into
    # 'refused', as today -- that happens one level up, not inside _spawn_daemon_impl).
    {
        my ($ok, $err) = run_spawn_impl(
            script => $script, platform => 'posix', ps_available => 0, perl_win => undef,
            run_detached => sub { die "should not be called\n" },
            fork_exec    => sub { die "boom\n" },
        );
        ok(!$ok, 'AC20g: a dying fork_exec propagates the die out of _spawn_daemon_impl')
            or diag('unexpectedly returned: ' . (defined $err ? $err : 'undef'));
        like($err // '', qr/boom/, 'AC20g: ...and the die text is boom') if !$ok;
    }
}

# ===========================================================================
# AC21 (DC3, DC4) -- _spawn_daemon($fixture_dir), called directly from this
# .t, returns undef (B17). Static: the \.t\z guard appears before
# _spawn_daemon_impl in the source, and the body still names
# BpContinuityLease.pm.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $ret = CL('_spawn_daemon', $legacy);
    is($ret, undef, 'AC21: _spawn_daemon called directly from a .t returns undef (the .t guard)')
        or diag(explain_undef());
}
{
    my $src = slurp("$S/BpContinuityLease.pm");
    my ($body) = ($src =~ /\bsub\s+_spawn_daemon\b(.*?)\n\}\n/s);
    ok(defined $body, 'AC21: sub _spawn_daemon is found by the source regex (lease-refresher-hygiene.t\'s own)')
        or diag(explain_undef());
    if (defined $body) {
        my $guard_idx = index($body, '\.t\z');
        my $impl_idx  = index($body, '_spawn_daemon_impl');
        ok($guard_idx >= 0, 'AC21: the \.t\z guard literal is present in the body') or diag(explain_undef());
        ok($impl_idx >= 0, 'AC21: _spawn_daemon_impl is referenced in the body') or diag(explain_undef());
        ok($guard_idx >= 0 && $impl_idx >= 0 && $guard_idx < $impl_idx,
            'AC21: the \.t\z guard appears before _spawn_daemon_impl is reached')
            or diag(explain_undef());
        like($body, qr/BpContinuityLease\.pm/, 'AC21: the body still names BpContinuityLease.pm literally');
    }
}

# ===========================================================================
# AC22 (DC1) -- prune race (A.3.1/B18/B20) through the new `unlink` seam.
# (a)-(c) direct prune_stale_sandbox_holds calls; (d) through daemon_loop.
# ===========================================================================
sub one_stale_fixture {
    my ($name) = @_;
    my (undef, $legacy, $root) = fresh_group();
    BpPowerPlan::set_sandbox_hold($root, $name, 1);
    my $old = time() - $FRESH - 5;
    utime($old, $old, hold_path($root, $name));
    return ($legacy, $root);
}
{
    # (a) the seam really unlinks, then re-creates the file fresh, and returns true.
    my ($legacy, $root) = one_stale_fixture('claude-ac22a-aaaaaaaa');
    my $r = 'claude-ac22a-aaaaaaaa';
    my $seam = sub {
        my ($f) = @_;
        return 0 unless unlink($f);
        open(my $fh, '>', $f) or return 0;
        close $fh;
        utime(time(), time(), $f);
        return 1;
    };
    my $result = PP('prune_stale_sandbox_holds', $root, unlink => $seam);
    if (ref $result eq 'HASH') {
        is_deeply([ map { $_->{name} } @{ $result->{removed} || [] } ], [$r],
            'AC22a: removed == [r] (reported, even though the seam recreated it)') or diag(explain_undef());
        is_deeply($result->{failed} || [], [], 'AC22a: failed == [] (never also pushed there)')
            or diag(explain_undef());
    } else {
        fail('AC22a: prune_stale_sandbox_holds(unlink seam) returned a non-HASH result');
        diag(explain_undef());
    }
    ok(-e hold_path($root, $r), 'AC22a: the file exists afterwards (the seam re-created it)');
}
{
    # (b) the seam returns false and leaves the file stale.
    my ($legacy, $root) = one_stale_fixture('claude-ac22b-bbbbbbbb');
    my $r = 'claude-ac22b-bbbbbbbb';
    my $seam = sub { return 0 };
    my $result = PP('prune_stale_sandbox_holds', $root, unlink => $seam);
    if (ref $result eq 'HASH') {
        is_deeply($result->{removed} || [], [], 'AC22b: removed == []') or diag(explain_undef());
        is_deeply($result->{failed} || [], [$r], 'AC22b: failed == [r]') or diag(explain_undef());
    } else {
        fail('AC22b: prune_stale_sandbox_holds(unlink seam) returned a non-HASH result');
        diag(explain_undef());
    }
    ok(-e hold_path($root, $r), 'AC22b: the stale file is still there (the unlink genuinely failed)');
}
{
    # (c) the seam touches the file to now and returns false.
    my ($legacy, $root) = one_stale_fixture('claude-ac22c-cccccccc');
    my $r = 'claude-ac22c-cccccccc';
    my $seam = sub { my ($f) = @_; utime(time(), time(), $f); return 0 };
    my $result = PP('prune_stale_sandbox_holds', $root, unlink => $seam);
    if (ref $result eq 'HASH') {
        is_deeply($result->{removed} || [], [], 'AC22c: removed == []') or diag(explain_undef());
        is_deeply($result->{failed} || [], [], 'AC22c: failed == [] (fresh again by the re-stat)')
            or diag(explain_undef());
    } else {
        fail('AC22c: prune_stale_sandbox_holds(unlink seam) returned a non-HASH result');
        diag(explain_undef());
    }
}
{
    # (d) through daemon_loop: case (a)'s seam injected on the first
    # prune_stale_sandbox_holds call only; later calls go to the original
    # with no options.
    my ($legacy, $root) = one_stale_fixture('claude-ac22d-dddddddd');
    local $BpContinuityLease::PLATFORM = 'windows';
    my $r = 'claude-ac22d-dddddddd';
    my $orig_prune = \&BpPowerPlan::prune_stale_sandbox_holds;
    my $calls = 0;
    my $seam = sub {
        my ($f) = @_;
        return 0 unless unlink($f);
        open(my $fh, '>', $f) or return 0;
        close $fh;
        utime(time(), time(), $f);
        return 1;
    };
    no warnings 'redefine';
    local *BpPowerPlan::prune_stale_sandbox_holds = sub {
        my ($root_arg, @rest) = @_;
        $calls++;
        return $calls == 1 ? $orig_prune->($root_arg, unlink => $seam) : $orig_prune->($root_arg);
    };

    my ($run) = run_seam();
    my ($log, $ev) = log_seam();
    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 2, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
    };
    ok(!$@, 'AC22d: daemon_loop does not die') or diag($@);
    is(log_count($ev, 'HOLD-PRUNED', qr/name=\Q$r\E/), 1, 'AC22d: HOLD-PRUNED name=r is logged exactly once')
        or diag(explain_undef());
    is(log_count($ev, 'HOLD-PRUNE-FAILED'), 0, 'AC22d: no HOLD-PRUNE-FAILED is logged') or diag(explain_undef());
    is(log_count($ev, 'HOLD-TICK'), 2, 'AC22d: the 2nd tick is again a HOLD-TICK (not IDLE)')
        or diag(explain_undef());
    is(log_count($ev, 'IDLE'), 0, 'AC22d: ...so IDLE never fires inside max_iterations=>2')
        or diag(explain_undef());
}

# ===========================================================================
# AC23 (DC1, DC3) -- future-dated hold (A.3.2/B19): a mtime more than FRESH in
# the future is prunable; up to FRESH in the future is still kept.
# ===========================================================================
{
    my (undef, undef, $root) = fresh_group();
    my $d = BpPowerPlan::sandbox_hold_dir($root);
    make_path($d);
    my %mtime = (
        far    => time() + $FRESH + 60,
        near   => time() + $FRESH - 2,
        future => time() + 300,
    );
    for my $n (keys %mtime) {
        open(my $fh, '>', "$d/$n") or die $!;
        close $fh;
        utime($mtime{$n}, $mtime{$n}, "$d/$n");
    }
    my $result = PP('prune_stale_sandbox_holds', $root);
    if (ref $result eq 'HASH') {
        is(scalar(@{ $result->{removed} || [] }), 1, 'AC23: prune removes exactly the far-future file')
            or diag(explain_undef());
        if (@{ $result->{removed} || [] }) {
            is($result->{removed}[0]{name}, 'far', 'AC23: the removed one is "far"');
            cmp_ok($result->{removed}[0]{age}, '<=', -($FRESH + 58), 'AC23: its age is <= -(FRESH+58)');
        }
    } else {
        fail('AC23: prune_stale_sandbox_holds returned a non-HASH result');
        diag(explain_undef());
    }
    ok(-e "$d/near", 'AC23: a hold up to FRESH in the future ("near") is kept');
    ok(-e "$d/future", 'AC23: AC9\'s own "future" (now + 300) is kept, unchanged');
}
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac23-far000001';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);
    my $far = time() + $FRESH + 60;
    utime($far, $far, hold_path($root, $name));

    my ($run) = run_seam();
    my ($log, $ev) = log_seam();
    my $sleep_calls = 0;
    my $rv = eval {
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 40, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { $sleep_calls++ }, log => $log,
            plan_opts => { run => $run },
        );
    };
    is($rv, 'done', 'AC23: daemon_loop (future hold only) ends through done') or diag($@ // explain_undef());
    is(log_count($ev, 'HOLD-TICK'), 1, 'AC23: exactly one HOLD-TICK is logged') or diag(explain_undef());
    is(log_count($ev, 'HOLD-PRUNED', qr/name=\Q$name\E\s+age=-/), 1,
        'AC23: HOLD-PRUNED name=<n> age=-<n>s (negative age) is logged') or diag(explain_undef());
    is(log_count($ev, 'IDLE', qr/reason=no-live-arm/), 1,
        'AC23: IDLE reason=no-live-arm is logged once the far-future hold is gone') or diag(explain_undef());
    is($sleep_calls, 1, 'AC23: the sleep seam was called exactly once');
}

# ===========================================================================
# AC24 (DC4, guard) -- arm ticks never prune (reviewer MINOR-4): a live arm
# plus a stale hold file -> TICK logged, no HOLD-TICK, reconcile why is
# refresher-tick, the stale file survives, no HOLD-PRUNED.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $stale = 'claude-ac24-stale0001';
    BpPowerPlan::set_sandbox_hold($root, $stale, 1);
    my $old = time() - $FRESH - 5;
    utime($old, $old, hold_path($root, $stale));

    my $t = tempdir(CLEANUP => 1);
    (my $tp = "$t/transcript.jsonl") =~ s{\\}{/}g;
    open(my $fh, '>', $tp) or die $!;
    print {$fh} "{}\n";
    close $fh;
    ok(BpHook::arm('ac24-sid', role => 'manual', by => 'on', transcript_path => $tp),
        'AC24 setup: BpHook::arm succeeds');

    my ($run) = run_seam();
    my ($wrapped, $rec) = make_reconcile_recorder();
    my ($log, $ev) = log_seam();
    no warnings 'redefine';
    local *BpPowerPlan::reconcile = $wrapped;

    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        spawn => sub { undef }, powershell_available => sub { 1 },
        kill_pid => sub { }, owner_winpid => undef,
        sleep => sub { }, log => $log,
        plan_opts => { run => $run },
    );

    is(log_count($ev, 'TICK'), 1, 'AC24: exactly one TICK (an arm tick) is logged') or diag(explain_undef());
    is(log_count($ev, 'HOLD-TICK'), 0, 'AC24: no HOLD-TICK is logged while an arm is live')
        or diag(explain_undef());
    is_deeply([ map { $_->{why} } @$rec ], ['refresher-tick'], 'AC24: reconcile\'s why is refresher-tick')
        or diag(explain_undef());
    ok(-e hold_path($root, $stale), 'AC24: the stale hold file still exists (arm ticks never prune)');
    is(log_count($ev, 'HOLD-PRUNED'), 0, 'AC24: no HOLD-PRUNED is logged');
}

# ===========================================================================
# AC26 (DC4) -- testable slice only (A.3.6): this test file itself no longer
# contains ok(1,, @KILL_PIDS, or the is($r->{armed}, 1, ...) if ... guard
# conditional. The comment-presence parts of AC26 (A.3.3/A.3.4/A.3.5, in
# BpContinuityLease.pm/BpPowerPlan.pm) are the spec's own "reviewed, not
# tested" and are not implementation this test file can assert on itself.
# ===========================================================================
{
    # Checked against the PREFIX of this file only, up to this very section's
    # own marker comment -- the AC26 section's own descriptions necessarily
    # name the forbidden tokens (to describe what must be absent), so
    # including them in the haystack would make this self-defeating. A.3.6's
    # cleanup touches AC1-AC13 (lines well before this marker); checking the
    # prefix is exactly checking the part that could still regress.
    my $self_src = slurp(__FILE__);
    my $marker = 'AC26 (DC4) -- testable slice only';
    my $idx = index($self_src, $marker);
    my $checked = $idx >= 0 ? substr($self_src, 0, $idx) : $self_src;
    ok($idx >= 0, 'AC26 setup: the section marker was found, so the checked prefix is well-defined');
    unlike($checked, qr/\bok\(1,/, 'AC26: the checked prefix no longer contains ok(1,');
    unlike($checked, qr/\@KILL_PIDS\b/, 'AC26: the checked prefix no longer contains @KILL_PIDS');
    unlike($checked, qr/is\(\s*\$r->\{armed\},\s*1,.*?\)\s*if\b/,
        'AC26: the checked prefix no longer contains the is($r->{armed}, 1, ...) if ... conditional');
}

done_testing();
