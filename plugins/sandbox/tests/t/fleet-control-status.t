#!/usr/bin/env perl
# platform: any
# fleet-control, part 1 of 3: the fleet STATUS (operator, 2026-11-11: "Maybe
# the TUI should just show if fleet is running or not and let me start or
# stop them, but don't start automatically upon just launching the tui").
#
# Pins:
#   A. RunState's `fleet` evidence: undef without runs/registry.json; with one,
#      { shutdown, operator_stop, operator_stop_at } read from the markers.
#   B. tui::DashboardScreen::fleet_status for every state -- running, paused,
#      stopping, stopped (crash), stopped by the operator, settled -- and the
#      action each offers; unknown liveness with a marker is never "stopped".
#   C. The blueprint line: running/paused render exactly as before (green
#      driver, pause text); stopped is the crash cross plus "stopped"; an
#      operator stop is the idle dot plus "stopped by you"; settled says so;
#      a fleet with no driver evidence left still names its orchestrator.
#   D. A summary WITHOUT `fleet` (every pre-existing fixture) renders exactly
#      as it did, span for span.
#
# Non-vacuity, measured 2026-11-11 by running this file against a HEAD
# (8418620) copy of plugins/sandbox/scripts: RunState emits no `fleet` key,
# so A1-A4 fail (5 not ok), and the file then dies (exit 2) at the first
# fleet_status call, which HEAD's DashboardScreen does not have.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN {
    my $pin = File::Temp::tempdir(CLEANUP => 1);
    $ENV{HOME} = $pin; $ENV{USERPROFILE} = $pin; $ENV{ALMANAC_HOME} = $pin;
}

require Theme;
require tui::Layout;
require tui::DashboardScreen;
require RunState;

my $NOW = 1_762_000_000;
sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
sub text_of { my ($spans) = @_; return join '', map { $_->{text} } @$spans; }
sub span_with { my ($spans, $text) = @_; for (@$spans) { return $_ if $_->{text} eq $text } return undef; }

sub write_file { my ($p, $c) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $c; close $f; }

# fixture(%o) -> blueprints root with one blueprint 'bp1'.
#   registry => 0|1, statuses => [..], orch => pid|undef, paused => 0|1,
#   shutdown => 0|1, op => undef | json-text
sub fixture {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    my $bp   = "$root/bp1";
    make_path("$bp/packages", "$bp/runs");
    my @st = @{ $o{statuses} || ['running', 'pending'] };
    my $i = 0;
    for my $s (@st) {
        $i++;
        write_file(sprintf('%s/packages/%02d-p.md', $bp, $i), "---\nstatus: $s\n---\n# p\n");
    }
    write_file("$bp/runs/registry.json", '{"packages":{}}') if $o{registry} // 1;
    write_file("$bp/runs/.orchestrator", "$o{orch}\n") if defined $o{orch};
    write_file("$bp/runs/.paused", '{"reason":"usage","relaunch_at":' . ($NOW + 3600) . '}') if $o{paused};
    write_file("$bp/runs/.shutdown", '') if $o{shutdown};
    write_file("$bp/runs/.stopped-by-operator", $o{op}) if defined $o{op};
    return $root;
}
sub summary {
    my (%o) = @_;
    my $alive = delete $o{alive};
    no warnings q{once};
    local $RunState::PID_ALIVE = sub { $alive };
    my $root = fixture(%o);
    my $r = RunState::summarize($root);
    return $r->[0];
}

# ===========================================================================
# A. RunState evidence
# ===========================================================================
{
    my $s = summary(registry => 0, orch => undef);
    ok(ref($s) eq 'HASH', 'A0: a ledger-only blueprint still yields a summary');
    ok(exists $s->{fleet}, 'A1: the summary carries the fleet key');
    ok(!defined $s->{fleet}, 'A1: and it is undef without runs/registry.json (not a fleet)');

    $s = summary(orch => 4242, alive => 1);
    is(ref($s->{fleet}), 'HASH', 'A2: with runs/registry.json, fleet is a HASH');
    is_deeply({ map { $_ => $s->{fleet}{$_} } qw(shutdown operator_stop operator_stop_at) }, { shutdown => 0, operator_stop => 0, operator_stop_at => undef },
        'A2: no markers -> shutdown 0, operator_stop 0, no time');

    $s = summary(orch => 4242, alive => 1, shutdown => 1, op => '{"v":1,"at":1761999000,"by":"dashboard"}');
    is_deeply({ map { $_ => $s->{fleet}{$_} } qw(shutdown operator_stop operator_stop_at) }, { shutdown => 1, operator_stop => 1, operator_stop_at => 1761999000 },
        'A3: .shutdown and .stopped-by-operator are both read, with the record time');

    $s = summary(orch => undef, op => 'not json at all');
    is($s->{fleet}{operator_stop}, 1, 'A4: an unreadable record still counts as an operator stop');
    ok(!defined $s->{fleet}{operator_stop_at}, 'A4: but yields no time');

    $s = summary(registry => 0, orch => 4242, alive => 1);
    is(ref($s->{fleet}), 'HASH', 'A5: an .orchestrator marker without registry.json is a fleet too (started, nothing launched yet)');
    is(tui::DashboardScreen::fleet_status($s)->{state}, 'running', 'A5: and reads running');
}

# ===========================================================================
# B. fleet_status
# ===========================================================================
my $FS = \&tui::DashboardScreen::fleet_status;
sub fs_of { my $r = $FS->($_[0]); return $r ? "$r->{state}/" . ($r->{by_operator} ? 'op' : '-') . '/' . ($r->{action} // '-') : 'undef'; }

my %CASE = (
    running   => [ orch => 4242, alive => 1 ],
    paused    => [ orch => 4242, alive => 1, paused => 1 ],
    stopping  => [ orch => 4242, alive => 1, shutdown => 1, op => '{"at":1761999000}' ],
    crashed   => [ orch => 4242, alive => 0 ],
    reaped    => [ orch => undef, shutdown => 1 ],
    opstop    => [ orch => undef, shutdown => 1, op => '{"at":1761999000}' ],
    settled   => [ orch => undef, statuses => ['done', 'dropped', 'done'] ],
    unknown   => [ orch => 4242, alive => undef ],
);
my %S = map { $_ => summary(@{ $CASE{$_} }) } keys %CASE;

is(fs_of($S{running}),  'running/-/stop',   'B1: alive orchestrator -> running, offers stop');
is(fs_of($S{paused}),   'paused/-/stop',    'B2: alive + .paused -> paused (usage), offers stop');
is(fs_of($S{stopping}), 'stopping/op/-',    'B3: alive + .shutdown -> stopping, no action while it drains');
is(fs_of($S{crashed}),  'stopped/-/start',  'B4: marker present, pid checked dead, unsettled -> stopped (not by operator), offers start');
is(fs_of($S{reaped}),   'stopped/-/start',  'B5: no orchestrator, .shutdown without a record (a reap) -> stopped, not by operator');
is(fs_of($S{opstop}),   'stopped/op/start', 'B6: no orchestrator + operator record -> stopped by operator, offers start');
is(fs_of($S{settled}),  'settled/-/-',      'B7: no orchestrator, every package done/dropped -> settled, no action');
is(fs_of($S{unknown}),  'running/-/stop',   'B8: marker present, liveness UNKNOWN -> running, never called stopped');
is(fs_of({ blueprint => 'x', state => 'running' }), 'undef', 'B9: a summary without fleet evidence is not a fleet');
is(fs_of(undef), 'undef', 'B9: total on undef');
is(fs_of({ fleet => {}, state => 'idle', orchestrator_alive => 1, packages => [ { status => 'done' } ] }),
   'running/-/stop', 'B10: a live orchestrator outranks settled (it may still be judging)');

# ===========================================================================
# C. the blueprint line
# ===========================================================================
sub line { my ($s) = @_; return tui::DashboardScreen::_blueprint_line($s, $NOW)->{spans}; }

{
    my $sp = line($S{running});
    ok(span_with($sp, G('status.ok')), 'C1: running -> the green driver dot');
    is(span_with($sp, G('status.ok'))->{role}, 'state.ok', 'C1: in state.ok');
    unlike(text_of($sp), qr/\b(?:stopped|settled|stopping)\b/, 'C1: and no fleet state word beside a green driver');

    $sp = line($S{paused});
    like(text_of($sp), qr/\Q@{[G('thread.idle')]}\E usage limit/, 'C2: paused keeps the pause text');

    $sp = line($S{crashed});
    my $dot = span_with($sp, G('status.crit'));
    ok($dot, 'C3: a crashed fleet keeps the crash cross');
    is($dot && $dot->{role}, 'state.crit', 'C3: in state.crit');
    my $w = span_with($sp, 'stopped');
    ok($w, 'C3: and says "stopped"') or diag(text_of($sp));
    is($w && $w->{role}, 'state.crit', 'C3: in state.crit');
    unlike(text_of($sp), qr/\bstale\b/, 'C3: the RunState word "stale" is replaced');

    $sp = line($S{opstop});
    $w = span_with($sp, 'stopped by you');
    ok($w, 'C4: an operator stop says "stopped by you"') or diag(text_of($sp));
    is($w && $w->{role}, 'state.warn', 'C4: in state.warn, not state.crit');
    ok(!span_with($sp, G('status.crit')), 'C4: and carries no crash cross');
    my $idle = span_with($sp, G('status.idle'));
    ok($idle, 'C4: the driver dot is the idle dot');
    is($idle && $idle->{role}, 'text.muted', 'C4: muted');
    like(text_of($sp), qr/\Q@{[G('status.idle')]}\E orchestrator/, 'C4: the line still names the orchestrator (synthesised: no marker, no thread left)');
    unlike(text_of($sp), qr/\bparked\b/, 'C4: the RunState word "parked" is replaced');

    $sp = line($S{reaped});
    like(text_of($sp), qr/\Q@{[G('status.crit')]}\E orchestrator\s+stopped\z/, 'C5: a reaped fleet reads "<cross> orchestrator   stopped"');

    $sp = line($S{settled});
    $w = span_with($sp, 'settled');
    ok($w, 'C6: a settled fleet says "settled"') or diag(text_of($sp));
    is($w && $w->{role}, 'text.muted', 'C6: muted');
    ok(!span_with($sp, G('status.crit')), 'C6: and is not drawn as a crash');

    $sp = line($S{stopping});
    $w = span_with($sp, 'stopping');
    ok($w, 'C7: a draining fleet says "stopping"') or diag(text_of($sp));
    is($w && $w->{role}, 'state.warn', 'C7: in state.warn');
    ok(span_with($sp, G('status.ok')), 'C7: its orchestrator is still alive, so the driver stays green');
}

# ===========================================================================
# D. no fleet evidence -> byte-for-byte the old line
# ===========================================================================
{
    for my $k (sort keys %S) {
        my %plain = %{ $S{$k} };
        my $fleet = delete $plain{fleet};
        next unless $k =~ /\A(?:running|paused|unknown)\z/;   # states whose line the change must not touch
        my $a = line($S{$k});
        my $b = line(\%plain);
        is_deeply($a, $b, "D1: $k -- a fleet that is up renders exactly as a summary without fleet evidence");
    }
    my %solo = %{ $S{crashed} };
    delete $solo{fleet};
    like(text_of(line(\%solo)), qr/\bstale\z/, 'D2: without fleet evidence a dead orchestrator still reads "stale" (non-fleet behaviour unchanged)');
}

done_testing();
