#!/usr/bin/env perl
# platform: any
# The [f] fleet screen stays open until the operator closes it (operator,
# 2026-11-11, Windows Terminal: "The panel stays open, what closes is the F
# screen" -- it disappeared a few seconds after opening, no key pressed).
#
# The screen ends only on 'close', and dispatch_key returns 'close' only for
# q or a LONE ESC. A terminal escape sequence reaching a Git-for-Windows
# console split across reads -- the ESC first, the rest milliseconds later --
# was assembled as a lone ESC, because _assemble_esc only polled
# non-blockingly for the next byte. Fixed by its $settle seam (a short wait
# for the rest, then the CSI read through to its final byte). Two dead pieces
# of the screen's periodic reload were fixed alongside: its tick option was
# never accepted (a regex had lost its backslashes) and, had it been, the
# reload passed %seams where \%seams was due.
#
# Pins, for BOTH the preview's interactive [f] and the dashboard's [f]:
#   I. 30+ idle seconds (several reload ticks) -> still open, and reloading;
#   E. a split focus-in/out sequence (\e, then [I / [O later) -> still open;
#   C. it closes on q, and on a real lone ESC -- and on nothing else.
#
# Non-vacuity, measured 2026-11-11 against the pre-fix Dashboard.pm and
# FleetScreen.pm: E fails (the split \e closes the screen at once) and I's
# "reloading while idle" fails (the reload never ran).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

require Dashboard;
require tui::FleetScreen;
my $PREVIEW = "$Bin/../../../../scripts/tui-preview.pl";
ok((eval { require $PREVIEW; 1 }), 'precondition: the preview loads') or BAIL_OUT($@);
no warnings 'once';

# A scripted terminal: @$q holds what arrives, in order; undef = nothing yet
# (an idle poll). read_key is non-blocking (never returns the next scripted
# byte unless $ready), wait_key/settle take the next scripted item.
sub terminal {
    my (@script) = @_;
    my $q = [ @script ];
    my %t = (polls => 0);
    $t{wait} = sub { $t{polls}++; return @$q ? shift @$q : 'q' };       # blocking, with a timeout
    $t{read} = sub { undef };                                         # non-blocking: never ready
    return \%t;
}
my @IDLE = (undef) x 160;    # 160 polls x 0.2 s = 32 s

# --- the preview's [f] -----------------------------------------------------
{
    local $main::SCENARIO = 'fleet';
    my $loads = 0;
    my $real = \&main::fleet_sim_seams;
    no warnings 'redefine';
    local *main::fleet_sim_seams = sub { my %s = $real->(); my $l = $s{load}; $s{load} = sub { $loads++; $l->() }; %s };
    my $run = sub {
        my ($t) = @_;
        return main::run_fleet_modal(
            read_key => $t->{read},
            wait_key => sub { Dashboard::_assemble_esc($t->{wait}->(), $t->{read}, $t->{wait}) },
            term_size => sub { (120, 30) }, out => sub { }, max_ticks => 400);
    };
    my $t = terminal(@IDLE, 'q');
    my $r = $run->($t);
    cmp_ok($r->{ticks}, '>=', 160, 'I1 (preview): 32 idle seconds pass with the screen open');
    is($r->{closed}, 1, 'C1 (preview): and then [q] closes it');
    cmp_ok($loads, '>=', 160 / 5, 'I2 (preview): the list is re-read while idle (every reload tick)');

    $t = terminal(undef, undef, "\e", '[', 'I', (undef) x 20, "\e", '[', 'O', @IDLE, 'q');
    $r = $run->($t);
    cmp_ok($r->{ticks}, '>=', 180, 'E1 (preview): a split focus-in/out sequence does not close the screen');

    # 2026-11-11 (operator): ESC is never a command. A lone ESC does nothing;
    # [f] goes back, [q] quits the TUI.
    $t = terminal(@IDLE, "\e", undef, (undef) x 50, 'f');
    $r = $run->($t);
    cmp_ok($r->{ticks}, '>=', 212, 'C2 (preview): a lone ESC does nothing -- still open after it');
    is($r->{closed}, 1, 'C2 (preview): [f] then closes it');
    is($r->{quit}, 0, 'C2 (preview): ... without quitting');
    $r = $run->(terminal(undef, 'q'));
    is($r->{quit}, 1, 'C2 (preview): [q] quits');
}

# --- the dashboard's [f] ---------------------------------------------------
{
    my %fs = (shutdown => 0, operator_stop => 0, operator_stop_at => undef);
    my @RUNS = ({ blueprint => 'one', runs_dir => '/x/one', state => 'running', orchestrator_pid => 1, orchestrator_alive => 1,
                  packages => [ { status => 'running' } ], fleet => { %fs } });
    my $drive = sub {
        my (@script) = @_;
        my @wait = ('f', @script);
        my $clock = 1_000;
        my ($loads, @results) = (0);
        Dashboard::run(
            beat_interval => 120, state_interval => 2, tick_interval => 0.2, color => 0, max_ticks => 3,
            now => sub { $clock }, sleep_for => sub { $clock += $_[0] },
            read_key => sub { undef },
            wait_input => sub { $clock += 0.2; return @wait ? shift @wait : undef },
            term_size => sub { (120, 30) },
            gather => sub { { project_name => 'p', container => 'c', status => 'running', events => [], runs => \@RUNS } },
            heartbeat => sub { 'ok' }, spawn => sub { undef }, out => sub { },
            fleet_load => sub { $loads++; \@RUNS },
            fleet_screen => sub { my $r = tui::FleetScreen::run(%{ $_[0] }, max_ticks => 400); push @results, $r; $r },
        );
        return ($results[0] || {}, $loads);
    };
    my ($r, $loads) = $drive->(@IDLE, 'q');
    cmp_ok($r->{ticks} // 0, '>=', 160, 'I1 (dashboard): 32 idle seconds pass with the [f] screen open');
    is($r->{closed}, 1, 'C1 (dashboard): and then [q] closes it');
    cmp_ok($loads, '>=', 160 / 5, 'I2 (dashboard): the list is re-read while idle');

    ($r) = $drive->(undef, "\e", '[', 'I', (undef) x 20, "\e", '[', 'O', @IDLE, 'q');
    cmp_ok($r->{ticks} // 0, '>=', 180, 'E1 (dashboard): a split focus-in/out sequence does not close the screen');

    ($r) = $drive->(@IDLE, "\e", undef, (undef) x 50, 'f');
    cmp_ok($r->{ticks} // 0, '>=', 212, 'C2 (dashboard): a lone ESC does nothing -- still open after it');
    is($r->{closed}, 1, 'C2 (dashboard): [f] then closes it');
}

# --- C3: only f closes it (back), only q quits; ESC does neither --------
{
    my @closers = grep { my %ss = (rows => [], cursor => 0); tui::FleetScreen::dispatch_key(\%ss, $_) eq 'close' }
                  ('a' .. 'z', 'A' .. 'Z', 0 .. 9, ' ', "\r", "\e", 'UP', 'DOWN', '[', 'I', 'O', ';');
    is_deeply(\@closers, [ 'f' ], 'C3: f is the only key that closes the screen (back to the dashboard)');
    my @quitters = grep { my %ss = (rows => [], cursor => 0); tui::FleetScreen::dispatch_key(\%ss, $_) eq 'quit' }
                   ('a' .. 'z', 'A' .. 'Z', 0 .. 9, ' ', "\r", "\e", 'UP', 'DOWN', '[', 'I', 'O', ';');
    is_deeply(\@quitters, [ 'q' ], 'C3: q is the only key that quits');
}

done_testing();
