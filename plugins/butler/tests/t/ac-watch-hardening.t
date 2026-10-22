#!/usr/bin/env perl
# platform: any
# Regression tests for the deferred LOW red-team findings of package
# 11-ac-loss-clean-suspend-cycle (todo 20261003-004707-628d0000; report
# blueprints/tooling-backlog/reports/11-ac-loss-clean-suspend-cycle/
# redteam-1.md):
#   L1  guard_active fails CLOSED on an undecodable/missing state file
#       under a present marker; the stale self-heal runs under
#       ac-state.lock with a bounded wait.
#   L2  observe() probes when probed_at lies in the future.
#   L4  a parsed main-session payload is never failed closed.
#   L5  log_event strips C0/C1/U+2028/U+2029 from kv values and reason,
#       without mangling ordinary UTF-8.
#   L6  run-hook.sh's acstanddown atom does not start perl for a leftover
#       marker whose state phase is ac/grace/reconnected.
#   L8  probe_source keeps a valid ac/dc reading from a "partial" probe.
# Everything runs in temp dirs; nothing touches a real data dir, nothing
# spawns launcher.pl, and the only subprocesses are the run-hook.sh wrapper
# runs (bounded by GuardHarness's timeout).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use JSON::PP ();
use MIME::Base64 ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib "$Bin/../lib";
use GuardHarness;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

my $S = "$Bin/../../scripts"; $S =~ s{\\}{/}g;
require "$S/BpAcWatch.pm";

my $J = JSON::PP->new->canonical;

sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path("$d/.drive-solo");
    return $d;
}
sub marker_path { "$_[0]/.drive-solo/ac-standdown.json" }
sub state_path  { "$_[0]/.drive-solo/ac-state.json" }

sub write_file {
    my ($p, $c) = @_;
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
}
sub read_file {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_marker { write_file(marker_path($_[0]), '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}') }
sub write_state  {
    my ($d, $phase, %extra) = @_;
    write_file(state_path($d), $J->encode({ v => 1, phase => $phase, source => 'dc', probed_at => 0, %extra }));
}
sub age_marker {
    my ($d, $secs) = @_;
    my $t = time() - $secs;
    utime($t, $t, marker_path($d)) or die "utime: $!";
}

# ===========================================================================
# L1: fail closed on an undecodable / missing state under a present marker.
# ===========================================================================
{
    my $d = fresh_data();
    write_marker($d);
    write_file(state_path($d), '{"phase":"monit');   # truncated/corrupt
    is(BpAcWatch::guard_active($d), 1, 'L1: marker + undecodable state reads as ACTIVE (fail closed)');

    unlink state_path($d);
    is(BpAcWatch::guard_active($d), 1, 'L1: marker + missing state reads as ACTIVE (fail closed)');

    write_file(state_path($d), '[1,2,3]');
    is(BpAcWatch::guard_active($d), 1, 'L1: marker + a non-object state reads as ACTIVE');

    write_state($d, 'reconnected');
    is(BpAcWatch::guard_active($d), 0, 'L1: a decodable non-active phase still disarms the guard');
}

# ===========================================================================
# L1 + self-heal: a STALE marker with a corrupt state and no live monitor
# still self-heals (under the lock), so fail-closed can never wedge forever.
# ===========================================================================
{
    my $d = fresh_data();
    write_marker($d);
    write_file(state_path($d), 'not json at all');
    age_marker($d, BpAcWatch::STALE_AFTER() + 120);
    is(BpAcWatch::guard_active($d), 0, 'self-heal: stale marker + corrupt state + no monitor -> inactive');
    ok(!-e marker_path($d), 'self-heal: the stale marker is removed');
    my $st = eval { JSON::PP->new->decode(read_file(state_path($d)) // '') };
    is(ref $st eq 'HASH' ? $st->{phase} : undef, 'ac', 'self-heal: the state is reset to phase ac');
    like(read_file("$d/.drive-solo/ac-cycle.log") // '', qr/MARKER-CLEARED .*src=guard/,
        'self-heal: MARKER-CLEARED is logged from the guard');
}

# ===========================================================================
# Self-heal lock: while another holder owns ac-state.lock, the heal waits a
# BOUNDED time, writes nothing, and allows the call; once the lock is free
# the heal proceeds.
# ===========================================================================
{
    my $d = fresh_data();
    write_marker($d);
    write_state($d, 'monitoring');
    age_marker($d, BpAcWatch::STALE_AFTER() + 120);

    open(my $lfh, '>>', "$d/.drive-solo/ac-state.lock") or die $!;
    flock($lfh, LOCK_EX) or die "flock: $!";
    # Only meaningful when a second open of the same file in this process
    # really conflicts (BSD flock semantics, true on Linux and Cygwin/MSYS).
    open(my $probe, '>>', "$d/.drive-solo/ac-state.lock") or die $!;
    my $conflicts = flock($probe, LOCK_EX | LOCK_NB) ? 0 : 1;
    flock($probe, LOCK_UN) unless $conflicts;
    close $probe;
    SKIP: {
        skip 'flock does not conflict between two opens in one process here', 3 unless $conflicts;
        my $t0 = time();
        my $r = BpAcWatch::guard_active($d);
        my $took = time() - $t0;
        is($r, 0, 'self-heal lock: a stale marker is still allowed while the lock is busy');
        ok($took <= BpAcWatch::GUARD_LOCK_TIMEOUT() + 3, "self-heal lock: the wait is bounded (took ${took}s)");
        ok(-e marker_path($d), 'self-heal lock: nothing was written without the lock (marker kept)');
    }
    flock($lfh, LOCK_UN);
    close $lfh;

    is(BpAcWatch::guard_active($d), 0, 'self-heal lock: once the lock is free the heal proceeds');
    ok(!-e marker_path($d), 'self-heal lock: ... and removes the marker');
}

# A marker younger than STALE_AFTER is never healed.
{
    my $d = fresh_data();
    write_marker($d);
    write_state($d, 'standing-down');
    is(BpAcWatch::guard_active($d), 1, 'a fresh marker with an active phase stays active');
    ok(-e marker_path($d), 'a fresh marker is not removed');
}

# ===========================================================================
# L2: a probed_at in the future does not suppress probing.
# ===========================================================================
{
    my $d = fresh_data();
    my $now = time();
    write_state($d, 'ac', source => 'ac', probed_at => $now + 86400);
    my $calls = 0;
    my $obs = BpAcWatch::observe($d, src => 'holder', now => $now, probe => sub { $calls++; 'dc' });
    is($calls, 1, 'L2: a future probed_at triggers a probe');
    is($obs->{probed}, 1, 'L2: observe reports probed 1');
    is($obs->{phase}, 'grace', 'L2: the dc reading starts the grace period');

    # control: a genuinely recent probed_at still uses the cache.
    my $d2 = fresh_data();
    write_state($d2, 'ac', source => 'ac', probed_at => $now - 1);
    my $calls2 = 0;
    BpAcWatch::observe($d2, src => 'holder', now => $now, probe => sub { $calls2++; 'dc' });
    is($calls2, 0, 'L2 control: a recent past probed_at still reuses the cached reading');
}

# ===========================================================================
# L5: log_event sanitising.
# ===========================================================================
{
    my $d = fresh_data();
    my $evil = "a\x1b[31mb\x00c\x{85}d\x{2028}e\x{2029}f\x7fg\x9bh";
    BpAcWatch::log_event($d, 'guard', 'STANDDOWN-DENIED', { tool => $evil, agent => "x\ty" },
        "reason\x1b]0;title\x07 with\x{85}NEL\x{2028}LS");
    my $log = read_file("$d/.drive-solo/ac-cycle.log") // '';
    my @lines = split /\n/, $log;
    is(scalar(@lines), 1, 'L5: exactly one log line');
    my $line = $lines[0] // '';
    utf8::decode($line);
    unlike($line, qr/[\x00-\x1f\x7f-\x9f\x{2028}\x{2029}]/, 'L5: no C0/C1/LS/PS character reaches the log');
    like($line, qr/\btool=a_\[31mb_c_d_e_f_g_h\b/, 'L5: control runs in a kv value are flattened to _');
    like($line, qr/\bagent=x_y\b/, 'L5: whitespace is still flattened to _');
    like($line, qr/-- reason \]0;title  with NEL LS$/, 'L5: controls in reason become spaces');

    # Ordinary UTF-8 (whose continuation bytes fall in 0x80-0x9f) survives.
    my $d2 = fresh_data();
    my $utf8_bytes = "caf\xc3\xa9\xe2\x80\x94ok";   # "cafe-acute" + em dash, as bytes
    BpAcWatch::log_event($d2, 'cli', 'MARKER-CLEARED', { note => $utf8_bytes }, "why \xe2\x80\x94 because");
    my $log2 = read_file("$d2/.drive-solo/ac-cycle.log") // '';
    like($log2, qr/note=caf\xc3\xa9\xe2\x80\x94ok/, 'L5: valid UTF-8 bytes in a kv value are kept byte-exact');
    like($log2, qr/why \xe2\x80\x94 because/, 'L5: valid UTF-8 bytes in reason are kept byte-exact');
}

# ===========================================================================
# L8: a "partial" probe keeps a valid power reading.
# ===========================================================================
{
    require "$S/BpPowerJournal.pm";
    my $payload;
    no warnings qw(redefine once);
    local *BpPowerJournal::probe_argv = sub { ['probe'] };
    local *BpPowerJournal::run_bounded = sub { return { status => 'ok', out => $payload } };
    my $enc = sub { MIME::Base64::encode_base64(JSON::PP->new->encode($_[0]), '') };

    $payload = $enc->({ power => { line => 'Offline', chg => 'Discharging', pct => 0.5 }, err => { plan => 'boom' } });
    my $parsed = BpPowerJournal::parse_probe($payload);
    is($parsed->{status}, 'partial', 'L8 precondition: parse_probe calls this probe partial');
    is(BpAcWatch::probe_source(), 'dc', 'L8: a partial probe with a good power part reads dc');

    $payload = $enc->({ power => { line => 'Online', chg => 'Charging', pct => 0.9 }, err => { cs => 'x' } });
    is(BpAcWatch::probe_source(), 'ac', 'L8: a partial probe with a good power part reads ac');

    $payload = $enc->({ power => { line => 'Online' }, err => { power => 'failed' } });
    is(BpAcWatch::probe_source(), 'unknown', 'L8: a failed power part still reads unknown');
}

# ===========================================================================
# L4: AcStandDown never fails a parsed main-session call closed.
# ===========================================================================
{
    my $d = fresh_data();
    write_marker($d);
    write_state($d, 'standing-down');

    my $main = GuardHarness::run_module('Guards::AcStandDown', { tool_input => {}, cwd => $d },
        env => { CCPRAXIS_DATA_DIR => $d });
    is($main->{rc}, 0, 'L4: a parsed main-session payload with no tool_name is allowed');

    my $sub = GuardHarness::run_module('Guards::AcStandDown', { agent_id => 'sub-1', cwd => $d },
        env => { CCPRAXIS_DATA_DIR => $d });
    is($sub->{rc}, 2, 'L4: a subagent payload with no tool_name still fails closed');

    my $bad = GuardHarness::run_module('Guards::AcStandDown', '{not valid json',
        env => { CCPRAXIS_DATA_DIR => $d });
    is($bad->{rc}, 2, 'L4: an unparseable payload still fails closed');

    my $mainb = GuardHarness::run_module('Guards::AcStandDown', { tool_name => 'Bash', tool_input => {}, cwd => $d },
        env => { CCPRAXIS_DATA_DIR => $d });
    is($mainb->{rc}, 0, 'L4: an ordinary main-session call is allowed');
}

# ===========================================================================
# L6: the acstanddown atom skips perl for a leftover marker whose phase is
# not an active one, and still starts it for an active or undecodable one.
# ===========================================================================
{
    my $p = { tool_name => 'Bash', tool_input => {}, agent_id => 'sub-1' };
    for my $phase (qw(reconnected ac grace)) {
        my $d = fresh_data();
        write_marker($d);
        write_state($d, $phase);
        my $res = GuardHarness::run_shim('ac-standdown-gate', { %$p, cwd => $d },
            env => { CCPRAXIS_DATA_DIR => $d });
        is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 0,
            "L6: marker + phase $phase -> perl is never spawned");
        is($res->{rc}, 0, "L6: marker + phase $phase -> the call is allowed");
    }
    my %cases = (
        'phase standing-down' => sub { write_state($_[0], 'standing-down') },
        'phase monitoring'    => sub { write_state($_[0], 'monitoring') },
        'an undecodable state' => sub { write_file(state_path($_[0]), '{"phase":"ac"') },
        'a missing state'      => sub { },
        'a two-line state'     => sub { write_file(state_path($_[0]), qq({"phase":"ac"}\n{"phase":"monitoring"}\n)) },
    );
    for my $name (sort keys %cases) {
        my $d = fresh_data();
        write_marker($d);
        $cases{$name}->($d);
        my $res = GuardHarness::run_shim('ac-standdown-gate', { %$p, cwd => $d },
            env => { CCPRAXIS_DATA_DIR => $d });
        is(GuardHarness::count_lines($res->{shim_log}, 'perl'), 1,
            "L6: marker + $name -> perl still runs and decides");
        is($res->{rc}, 2, "L6: marker + $name -> the subagent call is denied");
    }
}

done_testing();
