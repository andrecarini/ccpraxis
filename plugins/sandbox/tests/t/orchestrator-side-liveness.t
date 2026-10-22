#!/usr/bin/env perl
# platform: any
#
# Orchestrator liveness across pid namespaces (todo 20261002-235037-d62e0000,
# redteam L5 of where-things-go package 13). The host dashboard used to probe
# the pid in runs/.orchestrator with a host-side prober even when a CONTAINER
# wrote it, so an unrelated host process with the same number read as live.
# bp-orchestrator.pl now records the writing side in
# runs/.orchestrator-side.json; RunState probes a pid only for a host-written
# marker and otherwise judges by runs/orchestrator.log freshness, falling back
# to unknown, never to a prober's "alive".
#
# The writer half (acquire_marker/release_marker) is exercised in-process via
# `require` of bp-orchestrator.pl (package BpOrch, the same way
# orchestrator-marker-race.t loads it); nothing here runs an orchestrator,
# starts a container or spawns launcher.pl.

use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

my $ENV_TMP = tempdir(CLEANUP => 1);
$ENV{$_} = $ENV_TMP for qw(HOME USERPROFILE ALMANAC_HOME CLAUDE_CONFIG_DIR BUTLER_STATE_DIR CCPRAXIS_DATA_DIR);
delete $ENV{CLAUDE_PROJECT_DIR};

require RunState;

my $NOW = 1_790_000_000;

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $s = <$fh>; close $fh; $s }

# fixture(%o) -> ($root, $runs): one blueprint "bp" with a ledger and a
# runs/.orchestrator naming pid 4242; optional side record and log age.
sub fixture {
    my (%o) = @_;
    my $P = tempdir(CLEANUP => 1);
    my $root = "$P/.ccpraxis-local-data/blueprints";
    make_path("$root/bp/packages", "$root/bp/runs");
    write_file("$root/bp/packages/01-x.md", "---\nstatus: running\n---\n\n## Pipeline\n\n- [ ] 1. scout\n");
    my $runs = "$root/bp/runs";
    write_file("$runs/.orchestrator", "4242\n");
    write_file("$runs/.orchestrator-side.json", $o{side_raw} // JSON::PP->new->encode({ v => 1, pid => $o{side_pid} // 4242, side => $o{side} }))
        if defined $o{side} || defined $o{side_raw};
    if (defined $o{log_age}) {
        write_file("$runs/orchestrator.log", qq({"type":"busy_lease_tick"}\n));
        my $t = $NOW - $o{log_age};
        utime($t, $t, "$runs/orchestrator.log") or die "utime: $!";
    }
    return ($root, $runs);
}

sub alive_of {
    my ($root) = @_;
    my ($s) = grep { ref $_ eq 'HASH' && $_->{blueprint} eq 'bp' } @{ RunState::summarize($root) };
    return $s;
}

# Every case runs with a prober that says ALIVE for any pid -- the
# host-collision scenario -- and counts its calls.
my $calls;
local $RunState::PID_ALIVE = sub { $calls++; 1 };
local $RunState::NOW = sub { $NOW };

{
    $calls = 0;
    my ($root) = fixture(side => 'container', log_age => 5);
    my $s = alive_of($root);
    is($s->{orchestrator_alive}, 1, 'container marker + fresh log -> alive');
    is($calls, 0, 'container marker + fresh log -> the pid is never probed');
    is($s->{state}, 'running', 'container marker + fresh log -> state running');
}
{
    $calls = 0;
    my ($root) = fixture(side => 'container', log_age => 600);
    my $s = alive_of($root);
    is($s->{orchestrator_alive}, undef, 'container marker + stale log + prober "alive" -> unknown, never alive');
    is($s->{state}, 'running', '... and unknown liveness does not demote the run to stale');
}
{
    my ($root) = fixture(side => 'container', log_age => 600);
    local $RunState::PID_ALIVE = sub { 0 };
    is(alive_of($root)->{orchestrator_alive}, 0, 'container marker + stale log + prober "dead" (census) -> dead');
}
{
    my ($root) = fixture(side => 'container');   # no log at all
    is(alive_of($root)->{orchestrator_alive}, undef, 'container marker + no log -> unknown');
}
{
    my ($root) = fixture(side => 'container', log_age => 5);
    local $RunState::NOW;
    is(alive_of($root)->{orchestrator_alive}, undef, 'container marker + no injected clock -> unknown');
}
{
    my ($root) = fixture(side => 'container', log_age => -100000);   # far-future mtime
    is(alive_of($root)->{orchestrator_alive}, undef, 'container marker + far-future log mtime -> unknown');
}
{
    my ($root) = fixture(side => 'container', log_age => -60);   # small skew
    is(alive_of($root)->{orchestrator_alive}, 1, 'container marker + slightly-future log mtime (clock skew) -> alive');
}
{
    my ($root) = fixture(side => 'container', log_age => 90);
    is(alive_of($root)->{orchestrator_alive}, 1, 'the freshness bound is inclusive at 90s');
}

SKIP: {
    skip 'this reader is itself inside a container', 2 if -e '/run/.containerenv' || -e '/.dockerenv';
    $calls = 0;
    my ($root) = fixture(side => 'host', log_age => 600);
    is(alive_of($root)->{orchestrator_alive}, 1, 'host marker on a host reader -> the pid probe decides, as before');
    is($calls, 1, 'host marker -> exactly one probe');
}

# Old markers (no side record) -- unknown side.
{
    $calls = 0;
    my ($root) = fixture(log_age => 5);
    is(alive_of($root)->{orchestrator_alive}, 1, 'old marker + fresh log -> alive');
    is($calls, 0, 'old marker + fresh log -> no probe');
}
{
    my ($root) = fixture(log_age => 600);
    is(alive_of($root)->{orchestrator_alive}, undef, 'old marker + stale log + prober "alive" -> unknown, never alive');
}
{
    my ($root) = fixture();   # no log, so freshness cannot be judged
    is(alive_of($root)->{orchestrator_alive}, 1, 'old marker + no log -> the pre-sidecar pid probe');
}
{
    my ($root) = fixture(side => 'container', side_pid => 9999, log_age => 600);
    is(alive_of($root)->{orchestrator_alive}, undef, 'a side record for another pid is ignored (unknown side, stale log -> unknown)');
}
{
    my ($root) = fixture(side_raw => '{not json', log_age => 600);
    is(alive_of($root)->{orchestrator_alive}, undef, 'a malformed side record is unknown side');
}
{
    my ($root) = fixture(side => 'mars', log_age => 600);
    is(alive_of($root)->{orchestrator_alive}, undef, 'an unrecognised side value is unknown side');
}

# A thread owned by the orchestrator gets the same verdict.
{
    my ($root) = fixture(side => 'container', log_age => 600);
    (my $P = $root) =~ s{/\.ccpraxis-local-data/blueprints\z}{};
    make_path("$P/.ccpraxis-local-data/almanac/thread");
    my @t = gmtime($NOW);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    write_file("$P/.ccpraxis-local-data/almanac/thread/fleet.md",
        "---\ncreated: $iso\nstate: live\nowner_kind: orchestrator\nowner_id: bp\nblueprints: bp\n---\n");
    my $s = alive_of($root);
    ok(ref $s->{thread} eq 'HASH', 'thread owner precondition: bp carries the thread');
    is($s->{thread} && $s->{thread}{owner}{alive}, undef, 'thread owner: container marker + stale log -> unknown, not the prober\'s alive');
}

# ---------------------------------------------------------------------------
# Writer half: acquire_marker records the side; release_marker removes it.
# ---------------------------------------------------------------------------
{
    my $orch = "$Bin/../../../butler/scripts/bp-orchestrator.pl";
    $orch =~ s{\\}{/}g;
    my $ok = eval { local $SIG{__WARN__} = sub { }; require $orch; 1 };
    ok($ok, 'bp-orchestrator.pl loads as package BpOrch') or diag($@);
    SKIP: {
        skip 'bp-orchestrator.pl did not load', 7 unless $ok;
        my $runs = tempdir(CLEANUP => 1);
        my $mk = "$runs/.orchestrator";
        my $fh = BpOrch::acquire_marker($mk);
        ok($fh, 'acquire_marker succeeds');
        is(slurp($mk), "$$\n", 'the marker itself is still exactly "<pid>\\n" (every digits-only reader keeps working)');
        my $rec = eval { JSON::PP->new->decode(slurp("$mk-side.json") // '') };
        ok(ref $rec eq 'HASH', 'the side record is JSON');
        is($rec && $rec->{pid}, $$, 'the side record carries the marker pid');
        my $want = (-e '/run/.containerenv' || -e '/.dockerenv') ? 'container' : 'host';
        is($rec && $rec->{side}, $want, "the side record says '$want' here");
        BpOrch::release_marker($fh, $mk);
        ok(!-e "$mk-side.json", 'release_marker removes the side record');
        ok(!-e $mk, 'release_marker removes the marker');
    }
}

done_testing();
