#!/usr/bin/env perl
# platform: any
# scripts/tui-preview.pl's interactive [f]: the REAL tui::FleetScreen over the
# synthetic fleets, with start/stop SIMULATED (operator, 2026-11-11: "see and
# test the fleet-control UX interactively, on the fake data").
#
# Pins:
#   K. the interactive key handler sends [f] to the fleet screen and [x] to a
#      hint, and leaves every other key to the loop (scripted keys, no tty);
#   S. start goes through Dashboard::fleet_start -- the dashboard's own seam --
#      with the simulated runner: progress + elapsed, then success, and the
#      fleet flips to running in the screen AND in the panel's state;
#   F. sandbox-reaper's start fails, and the failure is displayed;
#   T. stop writes nothing, goes stopping -> stopped by you;
#   N. nothing is ever executed: a poisoned podman/bash on PATH is never run,
#      BoundedRun::run is never called, and no file is written;
#   D. --dump output is unchanged by the simulation's existence (empty state).
#
# Non-vacuity, measured 2026-11-11 against the tree before this change: the
# preview has no run_fleet_modal / preview_special_key / %FLEET_SIM, so the
# first call dies (exit 255) after the load assertion.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);

my $PREVIEW = "$Bin/../../../../scripts/tui-preview.pl";
ok((eval { require $PREVIEW; 1 }), 'precondition: scripts/tui-preview.pl loads in-process') or BAIL_OUT($@);
require tui::DashboardScreen;
require BoundedRun;

# --- N: poison everything that could run --------------------------------
my $poison = tempdir(CLEANUP => 1);
my $marker = "$poison/RAN";
for my $exe (qw(podman podman.exe bash wsl)) {
    open my $fh, '>', "$poison/$exe" or die; print {$fh} "#!/bin/sh\necho ran > '$marker'\nexit 0\n"; close $fh;
    chmod 0755, "$poison/$exe";
}
local $ENV{PATH} = "$poison:" . ($ENV{PATH} // '');
my $bounded_calls = 0;
{ no warnings qw(redefine once); *BoundedRun::run = sub { $bounded_calls++; die "BoundedRun::run must never be called by the preview\n" }; }

# A fake clock: the 5 s simulated start passes instantly.
my $clock = 1_000;
{ no warnings 'once';
  $main::SIM_NOW   = sub { $clock };
  $main::SIM_SLEEP = sub { $clock += $_[0] };
  $main::SCENARIO  = 'fleet'; }

sub plain { my ($t) = @_; $t =~ s/\e\[[0-9;?]*[A-Za-z]//g; return $t; }
sub modal {
    my (@keys) = @_;
    my @frames;
    my $res = main::run_fleet_modal(
        read_key  => sub { undef },
        wait_key  => sub { @keys ? shift @keys : 'q' },
        term_size => sub { (130, 30) },
        # whole composed frames, not render_frame's row diffs
        render    => sub { my ($p, $f) = @_; return join("
", map { $_->{text} // q{} } @$f) },
        out       => sub { push @frames, plain($_[0]) },
        max_ticks => 40,
    );
    return ($res, join("\n", @frames));
}
sub fs_of {
    my ($bp) = @_;
    my $st = main::synth_state(10, undef, undef);
    my ($s) = grep { $_->{blueprint} eq $bp } @{ $st->{runs} };
    my $fs = tui::DashboardScreen::fleet_status($s);
    return $fs ? $fs->{state} . ($fs->{by_operator} ? '/op' : '') : 'none';
}
no warnings 'once';

# --- K: the key handler --------------------------------------------------
{
    my ($opened, $toast) = (0, '');
    my %ctx = (open_fleets => sub { $opened++ }, toast => sub { $toast = $_[0] });
    my @handled = map { main::preview_special_key($_, \%ctx) ? $_ : () } ('a', 'f', 's', 'x', 'q', ' ', 'c');
    is_deeply(\@handled, [ 'f', 'x' ], 'K1: of a scripted key sequence, only [f] and [x] are taken by the fleet handler');
    is($opened, 1, 'K2: [f] opens the fleet screen');
    like($toast, qr/not simulated/, 'K3: [x] shows a hint instead of doing anything');
    is(main::preview_special_key(undef, \%ctx), 0, 'K4: no key, nothing handled');
}

# --- the list ------------------------------------------------------------
my ($r, $all) = modal('q');
like($all, qr/payments-ledger +\S+ +\d+\/\d+ +running 6h/, 'L1: the screen lists the running fleet, with its uptime');
like($all, qr/theme-tokens +\S+ +\d+\/\d+ +stopped by you 15m ago/, 'L1: and the operator-stopped one, with when');
like($all, qr/\[enter\] stop this fleet/, 'L1: the selected (running) fleet offers stop on its action line');
unlike($all, qr/tui-operator-feedback/, 'L2: the drive-solo run is not a fleet');
is($r->{closed}, 1, 'L3: [q] closes the screen');

# --- S: a start that succeeds (theme-tokens is row 4) ----------------------
is(fs_of('theme-tokens'), 'stopped/op', 'S0 precondition: theme-tokens starts out stopped by you');
@main::SIM_RUNNER_CALLS = ();
($r, $all) = modal('j', 'j', 'j', "\r", 'y', 'q');
like($all, qr/Start theme-tokens\? \[y\] yes, any other key cancels/, 'S1: [enter] asks first, in place');
like($all, qr/starting theme-tokens - bp-orchestrate\.sh is running in the container, [1-4]s/, 'S2: progress with an elapsed counter while it runs');
like($all, qr/started theme-tokens - orchestrator started for theme-tokens/, 'S3: then the result');
like($all, qr/theme-tokens +\S+ +\d+\/\d+ +running/, 'S4: the screen\'s list shows it running');
is(fs_of('theme-tokens'), 'running', 'S5: and so does the panel (synth_state)');
is(scalar(@main::SIM_RUNNER_CALLS), 1, 'S6: the simulated runner was called once');
my $argv = $main::SIM_RUNNER_CALLS[0];
is($argv->[0], 'podman', 'S6: handed the argv Dashboard::fleet_start builds (the dashboard\'s own seam)');
like($argv->[-2], qr{butler/scripts/bp-orchestrate\.sh\z}, 'S6: for bp-orchestrate.sh');
is($argv->[-1], 'theme-tokens', 'S6: for the selected fleet');

# --- F: a start that fails (sandbox-reaper is row 3) -----------------------
($r, $all) = modal('j', 'j', "\r", 'y', 'q');
like($all, qr/FAILED start - sandbox-reaper - exit 6 - bp-orchestrate: hooks self-test failed/, 'F1: the failure is displayed with its exit code and reason');
is(fs_of('sandbox-reaper'), 'stopped', 'F2: and the fleet stays stopped');
is($r->{failures}, 1, 'F3: counted as a failure');

# --- T: a stop -----------------------------------------------------------
($r, $all) = modal("\r", 'y', 'q');
like($all, qr/Stop payments-ledger\? \[y\] yes, any other key cancels/, 'T1: stop asks first, in place');
like($all, qr/payments-ledger +\S+ +\d+\/\d+ +stopping/, 'T2: it shows stopping');
is(fs_of('payments-ledger'), 'stopping/op', 'T3: in the panel too');
$clock += 10;
main::sim_advance();
is(fs_of('payments-ledger'), 'stopped/op', 'T4: then stopped by you');
($r, $all) = modal('q');
like($all, qr/payments-ledger +\S+ +\d+\/\d+ +stopped by you/, 'T5: and the screen shows it stopped by you');
like($all, qr/\[enter\] start this fleet/, 'T5: offering start again');

# --- N -----------------------------------------------------------------
ok(!-e $marker, 'N1: nothing on the poisoned PATH ever ran');
is($bounded_calls, 0, 'N2: BoundedRun::run was never called');
ok(!-e '/tmp/ccpraxis-preview-runs', 'N3: no runs directory was written');

# --- D -----------------------------------------------------------------
%main::FLEET_SIM = ();
my $d1 = main::render_plain(main::synth_state(10, undef, undef), 50, 121, 0, 10);
like($d1, qr/theme-tokens .*stopped by you/, 'D1: with the simulation reset, the dump is the scenario as written');

done_testing();
