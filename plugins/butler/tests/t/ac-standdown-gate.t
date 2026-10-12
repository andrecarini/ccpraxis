#!/usr/bin/env perl
# platform: any
# ORACLE for package 11-ac-loss-clean-suspend-cycle (blueprint tooling-backlog),
# AC-9 of .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 11-ac-loss-clean-suspend-cycle-spec.md sec 2.9/3.6: the ac-standdown-gate
# PreToolUse guard that denies every subagent tool call while stood down.
#
# Neither BpHook/Guards/AcStandDown.pm nor hooks/ac-standdown-gate.sh nor
# BpAcWatch.pm (which AcStandDown.pm's run() calls into for guard_active())
# EXIST YET. The in-process half (via GuardHarness::run_module, mirroring
# BpHook::main()'s own require-and-call contract) fails open (rc 0) when the
# module cannot be required -- exactly as the real wrapper would -- so every
# DENY assertion below legibly fails (got 0, wanted 2) rather than crashing.
# The subprocess half (via GuardHarness::run_wrapper) gets a plain bash
# "No such file or directory", rc 127, until the wrapper file exists.
#
# Written BLIND to any implementation file: derived only from spec sec 2.9
# (guard contract) and 2.6/3.6 (closed event vocabulary / signal-reaches-
# workers behavior).
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $BUTLER_DIR = dirname(__FILE__) . '/../..';
my $J = JSON::PP->new->canonical;

sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path("$d/.drive-solo");
    return $d;
}

sub write_marker {
    my ($data) = @_;
    make_path("$data/.drive-solo");
    open my $fh, '>', "$data/.drive-solo/ac-standdown.json" or die $!;
    print {$fh} '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}';
    close $fh;
}

sub write_state {
    my ($data, $phase) = @_;
    open my $fh, '>', "$data/.drive-solo/ac-state.json" or die $!;
    print {$fh} $J->encode({ v => 1, phase => $phase, source => 'dc', probed_at => 0 });
    close $fh;
}

sub payload {
    my (%o) = @_;
    my $p = { tool_name => ($o{tool} // 'Bash'), tool_input => {}, cwd => $o{cwd} };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    $p->{session_id} = $o{session_id} if exists $o{session_id};
    return $p;
}

my $STAND_L1 = 'STAND-DOWN: AC power lost; this host is on battery and may sleep. Tool calls are refused until AC returns.';
my $STAND_L2 = 'Do not retry. Reply now with your report: what you changed, each file\'s state, and what was in progress.';

# ===========================================================================
# Static shape (mirrors SH-1/SH-2 of guards-remake-gate-shutdown.t).
# ===========================================================================
{
    my $wrapper = "$BUTLER_DIR/hooks/ac-standdown-gate.sh";
    my $module  = "$BUTLER_DIR/scripts/BpHook/Guards/AcStandDown.pm";
    ok(-f $wrapper, 'precondition: ac-standdown-gate.sh exists on disk')
        or diag("missing: $wrapper (package 11 has not written it yet)");
    SKIP: {
        skip 'wrapper missing', 2 unless -f $wrapper;
        my $rc = system('bash', '-n', $wrapper);
        is($rc, 0, 'bash -n on ac-standdown-gate.sh passes');
        my $src = read_bytes($wrapper) // '';
        like($src, qr/Guards::AcStandDown/, 'the wrapper names the Guards::AcStandDown module');
    }
    ok(-f $module, 'precondition: BpHook/Guards/AcStandDown.pm exists on disk')
        or diag("missing: $module (package 11 has not written it yet)");
    SKIP: {
        skip 'module missing', 2 unless -f $module;
        my $rc = system('perl', "-I$BUTLER_DIR/scripts", '-c', $module);
        is($rc, 0, 'perl -c on AcStandDown.pm passes');
        my $src = read_bytes($module) // '';
        $src =~ s/^\s*#.*$//mg;
        unlike($src, qr/\bsystem\s*\(|\bexec\s*\(|\bexec\s+\S|`|\bqx\b|open\s*\([^)]*\|/,
            'the module source never spawns (no system/exec/backtick/qx/pipe-open)');
    }
}

# ===========================================================================
# AC-9: an active marker plus phase standing-down denies a subagent payload
# (rc 2, both STAND-DOWN lines, logs STANDDOWN-DENIED). Allows a
# main-session payload. In-process, via GuardHarness::run_module.
# ===========================================================================
{
    my $data = fresh_data();
    write_marker($data);
    write_state($data, 'standing-down');

    my $res = GuardHarness::run_module('Guards::AcStandDown',
        payload(tool => 'Bash', agent_id => 'sub-1', cwd => $data),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 2, 'AC-9: active marker + standing-down denies a subagent tool call (rc 2)');
    like($res->{err}, qr/\Q$STAND_L1\E/, 'AC-9: stderr carries the first STAND-DOWN line');
    like($res->{err}, qr/\Q$STAND_L2\E/, 'AC-9: stderr carries the second STAND-DOWN line');

    my $log = read_bytes("$data/.drive-solo/ac-cycle.log") // '';
    like($log, qr/STANDDOWN-DENIED/, 'AC-9: the denial is logged as STANDDOWN-DENIED') if length $log;

    my $res_main = GuardHarness::run_module('Guards::AcStandDown',
        payload(tool => 'Bash', cwd => $data),   # no agent_id => main session
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res_main->{rc}, 0, 'AC-9: a main-session call (no agent_id) is allowed even while stood down');
}

# ===========================================================================
# AC-9: once phase is reconnected or ac, everything is allowed even if the
# marker file still exists on disk.
# ===========================================================================
{
    my $data = fresh_data();
    write_marker($data);
    write_state($data, 'reconnected');
    my $res = GuardHarness::run_module('Guards::AcStandDown',
        payload(tool => 'Bash', agent_id => 'sub-1', cwd => $data),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 0, 'AC-9: phase reconnected allows a subagent call even with the marker still present');
}
{
    my $data = fresh_data();
    write_marker($data);
    write_state($data, 'ac');
    my $res = GuardHarness::run_module('Guards::AcStandDown',
        payload(tool => 'Bash', agent_id => 'sub-1', cwd => $data),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 0, 'AC-9: phase ac allows a subagent call even with the marker still present');
}

# ===========================================================================
# AC-9: no marker at all -> allowed, regardless of agent_id.
# ===========================================================================
{
    my $data = fresh_data();
    my $res = GuardHarness::run_module('Guards::AcStandDown',
        payload(tool => 'Bash', agent_id => 'sub-1', cwd => $data),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 0, 'AC-9: no marker at all allows a subagent call');
}

# ===========================================================================
# AC-9: fail-closed -- an active marker + unparseable payload or a missing
# tool_name from a subagent denies (GateShutdown's own pattern).
# ===========================================================================
{
    my $data = fresh_data();
    write_marker($data);
    write_state($data, 'monitoring');
    my $res = GuardHarness::run_module('Guards::AcStandDown', '{not valid json',
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 2, 'AC-9: an active marker + unparseable payload fails closed (denies)');
}
{
    my $data = fresh_data();
    write_marker($data);
    write_state($data, 'monitoring');
    my $p = { agent_id => 'sub-1', cwd => $data };   # no tool_name at all
    my $res = GuardHarness::run_module('Guards::AcStandDown', $p, env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 2, 'AC-9: an active marker + no tool_name from a subagent fails closed (denies)');
}

# ===========================================================================
# AC-9: through run-hook.sh, the acstanddown atom does not hold when the
# marker is absent, so perl is never started (process-budget half, package
# 03's convention: GuardHarness::run_shim + count_lines).
# ===========================================================================
{
    my $data = fresh_data();   # no marker written
    my $res = GuardHarness::run_shim('ac-standdown-gate',
        payload(tool => 'Bash', agent_id => 'sub-1', cwd => $data),
        env => { CCPRAXIS_DATA_DIR => $data });
    is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0,
        'AC-9: with the marker absent, the acstanddown atom holds false and perl is never spawned');
}
{
    my $data = fresh_data();
    write_marker($data);
    write_state($data, 'standing-down');
    my $res = GuardHarness::run_wrapper('ac-standdown-gate',
        payload(tool => 'Bash', agent_id => 'sub-1', cwd => $data),
        env => { CCPRAXIS_DATA_DIR => $data });
    is($res->{rc}, 2, 'AC-9: through the real wrapper+run-hook.sh, an active marker denies a subagent call (rc 2)');
    like($res->{err}, qr/\Q$STAND_L1\E/, 'AC-9: the real wrapper path prints the first STAND-DOWN line on stderr');
}

done_testing();
