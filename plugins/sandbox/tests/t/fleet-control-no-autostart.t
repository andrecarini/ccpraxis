#!/usr/bin/env perl
# platform: any
# fleet-control, part 3 of 3: NO AUTOMATIC START, ANYWHERE. The operator's
# words (2026-11-11): "... let me start or stop them, but don't start
# automatically upon just launching the tui".
#
# Pins:
#   N1. Dashboard::run, started over a project whose fleets are all STOPPED
#       (the case that would tempt an auto-restart) and left running for many
#       ticks and gathers with no key pressed, never calls fleet_start and
#       never opens the fleet screen.
#   N2. Opening the screen ([f]) calls nothing either; only [f] [enter] [y]
#       starts, exactly once, the fleet under the cursor.
#   N3. 'f' is the only key that opens it, and 'F' does not (End's CSI byte).
#   N4. Source: the only call to Dashboard::fleet_start in launcher.pl is
#       inside the fleet_start seam it hands Dashboard::run, no sandbox script
#       or container file names bp-orchestrate.sh except Dashboard.pm's argv
#       builder, and Dashboard.pm calls $fleet_start nowhere but by handing
#       it to the screen.
#
# Stubs only: no launcher.pl, no podman, no orchestrator, no terminal.
#
# Non-vacuity, measured 2026-11-11 with HEAD (8418620) Dashboard.pm and
# launcher.pl (and this change's FleetScreen/DashboardScreen/RunState): 9 of
# 20 fail -- N2 "[f] opens" and "starts once", N3 (no f key), all of
# N4. N1 passes there too, as a regression guard should.
# N1 and N4's negatives are each paired with a positive control that proves
# the same counter / scanner fires (N2 for the counter, N4-ctrl for the scan).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

require Dashboard;
require tui::FleetScreen;

sub sm {
    my (%o) = @_;
    return { blueprint => $o{bp}, runs_dir => "/tmp/runs-$o{bp}", state => 'stale',
             orchestrator_pid => 13, orchestrator_alive => 0,
             packages => [ { status => 'running' }, { status => 'pending' } ],
             packages_total => 2, packages_done => 0,
             fleet => { shutdown => 0, operator_stop => 0, operator_stop_at => undef } };
}
my @RUNS = (sm(bp => 'one-stopped'), sm(bp => 'two-stopped'));

sub drive {
    my (%a) = @_;
    my @keys = @{ $a{keys} || [] };
    # Keys meant for the SCREEN arrive through wait_input, and only once the
    # screen is open: the screen discards type-ahead when a confirm arms (so
    # a queued [y] cannot answer it), which is exactly what a real operator
    # never trips over and a key queue always would.
    my @modal = @{ $a{modal_keys} || [] };
    my $open = 0;
    my $clock = 1000;
    my %n = (start => [], stop => 0, screen => 0, gathers => 0, load => 0);
    Dashboard::run(
        beat_interval => 1, state_interval => 0, tick_interval => 0.25, color => 0,
        max_ticks => $a{max_ticks} // 60, bp_max_ticks => 12,
        now => sub { $clock }, sleep_for => sub { $clock += $_[0] },
        read_key => sub { @keys ? shift @keys : undef },
        wait_input => sub { $clock += $_[0]; return ($open && @modal) ? shift @modal : undef },
        term_size => sub { (130, 40) },
        gather => sub { $n{gathers}++; { project_name => 'demo', container => 'c1', status => 'running',
                                         events => [], runs => \@RUNS } },
        heartbeat => sub { 'ok' }, spawn => sub { undef },
        enter_raw => sub { }, leave_raw => sub { }, out => sub { },
        fleet_load  => sub { $n{load}++; \@RUNS },
        fleet_start => sub { push @{ $n{start} }, $_[0]{blueprint}; { ok => 1, detail => 'started' } },
        fleet_stop  => sub { $n{stop}++; { ok => 1 } },
        ($a{wrap_screen} ? (fleet_screen => sub { $n{screen}++; $open = 1; tui::FleetScreen::run(%{$_[0]}) }) : ()),
    );
    return \%n;
}

# N1 -- launch and idle
{
    my $n = drive(wrap_screen => 1, max_ticks => 120);
    cmp_ok($n->{gathers}, '>', 3, 'N1 precondition: the dashboard gathered the stopped fleets repeatedly');
    is_deeply($n->{start}, [], 'N1: with every fleet stopped and no key pressed, fleet_start is NEVER called');
    is($n->{screen}, 0, 'N1: and the fleet screen is never opened on its own');
    is($n->{stop}, 0, 'N1: nor is anything stopped');
}

# N2 -- opening is not starting; only enter + y starts
{
    my $n = drive(wrap_screen => 1, keys => ['f']);
    is($n->{screen}, 1, 'N2: [f] opens the fleet screen');
    is_deeply($n->{start}, [], 'N2: opening it starts nothing');

    $n = drive(wrap_screen => 1, keys => ['f'], modal_keys => ["\r"]);
    is_deeply($n->{start}, [], 'N2: [enter] alone only arms the confirm');

    $n = drive(wrap_screen => 1, keys => ['f'], modal_keys => ["\r", 'n']);
    is_deeply($n->{start}, [], 'N2: [enter] then any key but [y] cancels');

    $n = drive(wrap_screen => 1, keys => ['f'], modal_keys => ["\r", 'y']);
    is_deeply($n->{start}, ['one-stopped'], 'N2: [f] [enter] [y] starts exactly the fleet under the cursor, once');
}

# N3 -- the key
{
    is_deeply([ Dashboard::dispatch_key('f', '') ], [ 'fleets', '' ], 'N3: f opens the fleet screen, arming no dashboard confirm');
    isnt((Dashboard::dispatch_key('F', ''))[0], 'fleets', 'N3: F does not (it is the End key\'s CSI final byte)');
    my @openers = grep { (Dashboard::dispatch_key($_, ''))[0] eq 'fleets' } ('a' .. 'z', 'A' .. 'Z', "\r", "\n", ' ');
    is_deeply(\@openers, ['f'], 'N3: and no other key opens it');
    like(tui::DashboardScreen::_footer_legend(200), qr/\[f\] fleets/, 'N3: the legend names it');
}

# N4 -- source
sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $s = <$fh>; close $fh; return $s }
sub strip_comments { my ($s) = @_; $s =~ s/^\s*#.*$//mg; return $s }
{
    my $L = strip_comments(slurp("$Bin/../../scripts/launcher.pl"));
    my @calls = ($L =~ /Dashboard::fleet_start\s*\(/g);
    is(scalar(@calls), 1, 'N4: launcher.pl calls Dashboard::fleet_start exactly once');
    my $at = index($L, 'Dashboard::fleet_start(');
    my $seam = rindex($L, 'fleet_start => sub', $at);
    ok($seam > 0 && $at - $seam < 600, 'N4: and that call is inside the fleet_start seam handed to Dashboard::run');

    my $dir = "$Bin/../../scripts";
    my @hits;
    for my $f (glob("$dir/*.pl"), glob("$dir/*.pm"), glob("$dir/tui/*.pm"), glob("$Bin/../../container/*")) {
        next unless -f $f;
        my $s = strip_comments(slurp($f));
        push @hits, $f if $s =~ /bp-orchestrate/;
    }
    is_deeply([ sort map { (split m{/}, $_)[-1] } @hits ], ['Dashboard.pm', 'FleetScreen.pm'],
        'N4: no sandbox script or container file names bp-orchestrate.sh except Dashboard.pm (its argv builder) and FleetScreen.pm (display text only; it spawns nothing, fleet-control-screen.t P1)');

    my $D = strip_comments(slurp("$dir/Dashboard.pm"));
    my @uses = ($D =~ /\$fleet_start\b(?!\s*=)/g);
    my ($ctx) = $D =~ /(start => \$fleet_start)/;
    is(scalar(@uses), 1, 'N4: Dashboard::run references $fleet_start once after taking it...');
    ok(defined $ctx, 'N4: ...and that one use hands it to the fleet screen, never calls it');

    # positive control for the scanner: it does find a name planted in source
    ok(strip_comments("x\n my \$c = 'bp-orchestrate.sh';\n") =~ /bp-orchestrate/, 'N4-ctrl: the scan fires on a live mention');
    ok(strip_comments("x\n # bp-orchestrate.sh\n") !~ /bp-orchestrate/, 'N4-ctrl: and ignores a comment');
}

done_testing();
