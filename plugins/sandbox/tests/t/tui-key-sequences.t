#!/usr/bin/env perl
# platform: any
# The TUI's one key parser (Dashboard::_assemble_esc) and its key rules
# (operator, 2026-11-11):
#   "I pressed f then as I was navigating down it went back to the main panel"
#   "Why not just get rid of esc for anything, then. q to close tui, f to switch
#    between fleet panel and out of it"
#
# A scripted console replays byte streams WITH TIMING: each byte arrives at a
# given millisecond; a non-blocking read sees only what has arrived, a timed
# read waits (on a fake clock) up to its limit. Pins:
#   A. arrows and navigation keys in every form assemble, split or not:
#      \e +120ms [B, \eOB, \e[1;5B, \e[5~ \e[6~ \e[H \eOF ..., split mid-CSI;
#   B. ESC is never a command: a lone ESC (300 ms of silence), and every
#      sequence, unknown or cut off, leaves the fleet screen, the backpack
#      screen and the dashboard exactly where they were;
#   C. [f] toggles the fleet screen, [b] the backpack screen;
#   D. [q] quits -- from the dashboard, and from inside either screen, through
#      the dashboard's own quit (run() returns its quit rc, the loop ends);
#   E. CCPRAXIS_KEYLOG records each raw read, each sequence and each action.
#
# Non-vacuity, measured 2026-11-11 against the code before this change (the
# 50 ms settle, ESC closing a screen): A1 (\e +120 ms [B) assembled a lone
# ESC and the fleet screen closed; B and C fail (ESC closed, f/b did not).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);

require Dashboard;
require tui::FleetScreen;
require tui::BackpackScreen;

# console(@events): events are [ms, byte] (absolute arrival times).
sub console {
    my (@ev) = @_;
    my %c = (now => 0, q => [ @ev ]);
    $c{raw} = sub {                                    # raw(-1) non-blocking, raw($secs) timed
        my ($t) = @_;
        my $q = $c{q};
        if (@$q && $q->[0][0] <= $c{now}) { return (shift @$q)->[1]; }
        return undef unless defined($t) && $t > 0;
        my $limit = $c{now} + $t * 1000;
        if (@$q && $q->[0][0] <= $limit) { $c{now} = $q->[0][0]; return (shift @$q)->[1]; }
        $c{now} = $limit;
        return undef;
    };
    $c{read} = sub { my $k = $c{raw}->(-1); defined $k ? Dashboard::_assemble_esc($k, sub { $c{raw}->(-1) }, sub { $c{raw}->($_[0]) }) : undef };
    $c{wait} = sub { my $k = $c{raw}->($_[0]); defined $k ? Dashboard::_assemble_esc($k, sub { $c{raw}->(-1) }, sub { $c{raw}->($_[0]) }) : undef };
    return \%c;
}
sub bytes_at { my ($ms, $s) = @_; return map { [ $ms, $_ ] } split //, $s; }
sub decode { my (@ev) = @_; my $c = console(@ev); my @out; while (@{ $c->{q} }) { my $k = $c->{wait}->(0.2); push @out, $k if defined $k; } return \@out; }

# --- A ---------------------------------------------------------------------
is_deeply(decode(bytes_at(0, "\e"), bytes_at(120, '[B')), ['DOWN'], 'A1: \e, 120 ms, then [B -> DOWN (never a lone ESC)');
is_deeply(decode(bytes_at(0, "\eOB")), ['DOWN'], 'A2: SS3 \eOB -> DOWN');
is_deeply(decode(bytes_at(0, "\eOA")), ['UP'],   'A2: SS3 \eOA -> UP');
is_deeply(decode(bytes_at(0, "\e[1;5B")), ['DOWN'], 'A3: \e[1;5B (Ctrl+Down) -> DOWN');
is_deeply(decode(bytes_at(0, "\e["), bytes_at(150, '1;5'), bytes_at(300, 'B')), ['DOWN'], 'A4: a CSI split mid-way, 150 ms apart -> DOWN');
my %nav = ("\e[H" => 'HOME', "\e[F" => 'END', "\eOH" => 'HOME', "\eOF" => 'END', "\e[1~" => 'HOME', "\e[4~" => 'END',
           "\e[5~" => 'PGUP', "\e[6~" => 'PGDN', "\e[7~" => 'HOME', "\e[8~" => 'END', "\e[C" => 'RIGHT', "\e[D" => 'LEFT');
is_deeply(decode(bytes_at(0, $_)), [ $nav{$_} ], "A5: " . join(' ', map { sprintf '%02x', ord } split //, $_) . " -> $nav{$_}") for sort keys %nav;
is_deeply(decode(bytes_at(0, "\e[I"), bytes_at(5, 'j')), ['j'], 'A6: an unknown complete sequence (focus \e[I) is dropped whole; the next key survives');
is_deeply(decode(bytes_at(0, "\e[2"), bytes_at(900, 'j')), ['j'], 'A6: a sequence cut off half way is dropped, not turned into ESC');
is_deeply(decode(bytes_at(0, "\e"), bytes_at(400, 'j')), [ "\e", 'j' ], 'A7: a lone ESC (300+ ms of silence) is ESC -- for the screens to ignore');

# --- B, C, D: the fleet screen ----------------------------------------------
my @RUNS = map { { blueprint => "bp$_", runs_dir => "/x/$_", state => 'running', orchestrator_pid => 1, orchestrator_alive => 1,
                   packages_done => 0, packages_total => 1, packages => [ { status => 'running' } ],
                   fleet => { shutdown => 0, operator_stop => 0, operator_stop_at => undef } } } 1 .. 3;
sub fleet {
    my ($c, %o) = @_;
    my @log;
    my $r = tui::FleetScreen::run(runs => \@RUNS, read_key => $c->{read}, wait_key => sub { $c->{wait}->($_[0]) },
                                  term_size => sub { (120, 30) }, max_ticks => $o{max} // 60,
                                  keylog => sub { push @log, "$_[0] -> $_[1]" });
    return ($r, \@log);
}
{
    my ($r, $log) = fleet(console(bytes_at(0, "\e"), bytes_at(120, '[B'), bytes_at(400, 'f')));
    is($r->{closed}, 1, 'B1 precondition: [f] closes the screen at the end');
    ok((grep { $_ eq 'DOWN -> move' } @$log), 'A1/B1 (fleet screen): the split DOWN moves the cursor');
    ok(!(grep { /-> (?:close|quit)\z/ && !/\Af -> close\z/ } @$log), 'B1: nothing but the final [f] closed it') or diag(join "\n", @$log);

    ($r, $log) = fleet(console(bytes_at(0, "\e"), bytes_at(500, "\e[1;5B"), bytes_at(700, "\e[I"), bytes_at(900, "\e[2"), bytes_at(2000, 'f')));
    is(scalar(grep { /-> close/ } @$log), 1, 'B2: a lone ESC, Ctrl+Down, a focus event and a cut-off sequence close nothing');
    is($log->[-1], 'f -> close', 'B2: only [f] does');
    ok((grep { $_ eq "\e -> (none)" } @$log), 'B2: the lone ESC arrived and did nothing');

    ($r) = fleet(console(bytes_at(0, 'f')));
    is($r->{closed}, 1, 'C1: [f] closes the fleet screen (back to the dashboard)');
    is($r->{quit}, 0, 'C1: ... and is not a quit');
    ($r) = fleet(console(bytes_at(0, 'q')));
    is($r->{quit}, 1, 'D1: [q] in the fleet screen asks the dashboard to quit');
}

# --- B, C, D: the backpack screen -------------------------------------------
{
    my $bp = sub {
        my ($c) = @_;
        return tui::BackpackScreen::run(items => [ { key => 'cat/a', approved => 0 }, { key => 'cat/b', approved => 1 } ],
                                        read_key => $c->{read}, wait_key => sub { $c->{wait}->($_[0]) },
                                        term_size => sub { (100, 24) }, max_ticks => 60);
    };
    my $r = $bp->(console(bytes_at(0, "\e"), bytes_at(400, "\e"), bytes_at(800, 'q')));
    is($r->{quit}, 1, 'B3/D2 (backpack): two lone ESCs did nothing; [q] then quits');
    cmp_ok($r->{ticks}, '>=', 3, 'B3 (backpack): it was still open for the ESCs');
    $r = $bp->(console(bytes_at(0, 'b')));
    is($r->{closed}, 1, 'C2: [b] closes the backpack screen');
    is($r->{quit}, 0, 'C2: ... and is not a quit');
    my %ss = (rows => [], cursor => 0);
    is(tui::BackpackScreen::dispatch_key(\%ss, "\e"), '', 'B3: ESC is not a backpack command');
    unlike(tui::BackpackScreen::FOOTER_LEGEND(), qr/esc/i, 'B4: the backpack legend no longer mentions ESC');
    like(tui::BackpackScreen::FOOTER_LEGEND(), qr/\[b\] back   \[q\] quit\z/, 'B4: it says [b] back, [q] quit');
    unlike(tui::FleetScreen::FOOTER_LEGEND(), qr/esc/i, 'B4: nor does the fleet legend');
    like(tui::FleetScreen::FOOTER_LEGEND(), qr/\A\[\S+\] move   \[enter\] start\/stop   \[f\] back   \[q\] quit\z/, 'B4: fleet legend as specified');
}

# --- C, D: through Dashboard::run ------------------------------------------
sub dash {
    my (@ev) = @_;
    my $c = console(@ev);
    my (@opened, @screens);
    my $rc = Dashboard::run(
        beat_interval => 120, state_interval => 2, tick_interval => 0.2, color => 0, max_ticks => 30,
        now => sub { int($c->{now} / 1000) + 1000 }, sleep_for => sub { $c->{now} += $_[0] * 1000 },
        read_key => $c->{read}, wait_input => sub { $c->{raw}->($_[0]) },
        term_size => sub { (120, 30) },
        gather => sub { { project_name => 'p', container => 'c', status => 'running', events => [], runs => \@RUNS } },
        heartbeat => sub { 'ok' }, spawn => sub { undef }, out => sub { },
        fleet_screen    => sub { push @opened, 'fleets';   my $r = tui::FleetScreen::run(%{ $_[0] }, max_ticks => 30); push @screens, $r; $r },
        backpack_screen => sub { push @opened, 'backpack'; my $r = tui::BackpackScreen::run(%{ $_[0] }, max_ticks => 30); push @screens, $r; $r },
    );
    return ($rc, \@opened, \@screens, $c);
}
{
    my ($rc, $opened, $screens, $c) = dash(bytes_at(0, 'f'), bytes_at(300, 'f'), bytes_at(600, 'b'), bytes_at(900, 'b'), bytes_at(1200, 'q'));
    is_deeply($opened, [ 'fleets', 'backpack' ], 'C3 (dashboard): f opened the fleet screen, f closed it, b opened the backpack screen, b closed it');
    is($rc, 0, 'D3 (dashboard): then [q] quit with the dashboard quit rc 0');
    ok(!@{ $c->{q} }, 'D3: every key was consumed');

    ($rc, $opened, $screens, $c) = dash(bytes_at(0, 'f'), bytes_at(300, 'q'), bytes_at(5000, 'z'));
    is_deeply($opened, [ 'fleets' ], 'D4: [q] inside the fleet screen ...');
    is($screens->[0]{quit}, 1, 'D4: ... is a quit ...');
    is($rc, 0, 'D4: ... and the dashboard quits with its own rc 0');
    is(scalar(@{ $c->{q} }), 1, 'D4: the loop ended at once (the later key was never read)');

    ($rc, $opened, $screens) = dash(bytes_at(0, 'b'), bytes_at(300, 'q'), bytes_at(5000, 'z'));
    is($screens->[0]{quit}, 1, 'D5: [q] inside the backpack screen quits the dashboard too');

    ($rc, $opened) = dash(bytes_at(0, "\e"), bytes_at(400, "\e[B"), bytes_at(800, "\e[1;5B"), bytes_at(1200, 'q'));
    is_deeply($opened, [], 'B5 (dashboard): ESC and arrow sequences open nothing');
    is($rc, 0, 'B5 (dashboard): only the [q] quit');
}

# --- E: the key log ---------------------------------------------------------
{
    my $dir = tempdir(CLEANUP => 1);
    local $ENV{CCPRAXIS_KEYLOG} = "$dir/keys.log";
    my $c = console(bytes_at(0, "\e"), bytes_at(120, '[B'));
    my $raw = Dashboard::keylog_reader($c->{raw});
    my $k = $raw->(0.2);
    is(Dashboard::_assemble_esc($k, sub { $raw->(-1) }, sub { $raw->($_[0]) }), 'DOWN', 'E1 precondition: the logged reader still assembles DOWN');
    Dashboard::keylog('key', 'fleets DOWN -> move');
    open my $fh, '<', "$dir/keys.log" or die; my @l = <$fh>; close $fh;
    like($l[0], qr/\A\d\d:\d\d:\d\d\.\d{3} read 1b\n\z/, 'E1: each raw read is one line: ms timestamp and hex');
    ok((grep { /read-timeout 0\.200s/ } @l) || (grep { /read 5b/ } @l), 'E1: the gap shows as a read boundary');
    ok((grep { /seq 1b 5b 42 -> DOWN/ } @l), 'E2: the assembled sequence and what it became');
    ok((grep { /key fleets DOWN -> move/ } @l), 'E3: the key and the action');
    local $ENV{CCPRAXIS_KEYLOG} = '';
    Dashboard::keylog('key', 'x');
    open $fh, '<', "$dir/keys.log" or die; my @l2 = <$fh>; close $fh;
    is(scalar(@l2), scalar(@l), 'E4: unset, nothing is written');
}

done_testing();
