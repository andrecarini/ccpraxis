#!/usr/bin/env perl
# platform: any
# fleet-control, part 2 of 3: the [f] fleet screen (tui::FleetScreen) and the
# two actions behind it (Dashboard::fleet_start / Dashboard::fleet_stop).
#
# Pins:
#   R. rendering (the stacked screen, 2026-11-11): list rows in the Blueprints
#      panel's language with the state saying WHEN, aligned columns; the
#      detail = the Blueprints panel's own package rows, byte for byte; the
#      facts line; the action line per selection, its confirm in place, the
#      progress and the failure; full-width rules, no divider, the legend on
#      the last row; the "+N rows hidden" cut.
#   K. start and stop each need [enter] then [y]; any other key cancels and
#      calls nothing; a settled/stopping fleet offers nothing; type-ahead
#      cannot answer a confirm; the confirmed action hits the row that was
#      selected when it armed.
#   S. fleet_start builds exactly `podman exec -w /project <ctr> bash -c
#      '<PATH has /root/.local/bin>; exec bash "$0" "$@"' <bp-orchestrate.sh> <bp>`,
#      runs it through the injected bounded runner with a generous wall clock,
#      reports rc/timeout/last line, and on success drops the operator-stop
#      record. A hostile name never reaches the runner.
#   T. fleet_stop writes the operator-stop record, THEN runs/.shutdown, and
#      refuses a directory that is not a fleet run.
#
# Every boundary is a stub: no podman, no launcher.pl, no orchestrator, no
# terminal. P1 scans tui/FleetScreen.pm to keep it that way.
#
# Non-vacuity, measured 2026-11-11 against a HEAD (8418620) copy of
# plugins/sandbox/scripts: the require of tui/FleetScreen.pm fails (exit 2,
# no assertion passes). With only FleetScreen, DashboardScreen and RunState
# new and HEAD's Dashboard.pm, R and K pass and the file dies (exit 255) at
# the first Dashboard::fleet_start call, so S and T cannot pass on HEAD.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path ();
use JSON::PP ();

require Theme;
require tui::DashboardScreen;
require tui::FleetScreen;
require Dashboard;

my $NOW = 1_762_000_000;
sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
sub frame_text { my ($cells) = @_; return join "\n", map { my $t = $_->{text} // ''; $t =~ s/\e\[[0-9;]*m//g; $t } @$cells; }

# Synthetic summaries -- the shape RunState emits, only the keys fleet_status
# and the screen read.
sub sm {
    my (%o) = @_;
    return { blueprint => $o{bp}, runs_dir => "/tmp/runs-$o{bp}", state => $o{state} // 'running',
             orchestrator_pid => $o{pid}, orchestrator_alive => $o{alive},
             paused_reason => $o{reason}, paused_window => $o{window},
             packages => [ map { { status => $_ } } @{ $o{st} || ['running', 'pending'] } ],
             fleet => exists $o{fleet} ? $o{fleet} : { shutdown => 0, operator_stop => 0, operator_stop_at => undef } };
}
my @RUNS = (
    sm(bp => 'alpha-run',  pid => 11, alive => 1),
    sm(bp => 'beta-pause', pid => 12, alive => 1, state => 'paused', reason => 'usage', window => 'five_hour'),
    sm(bp => 'gamma-dead', pid => 13, alive => 0, state => 'stale'),
    sm(bp => 'delta-mine', pid => undef, alive => undef, state => 'parked',
       fleet => { shutdown => 1, operator_stop => 1, operator_stop_at => $NOW - 60 }),
    sm(bp => 'eps-done',   pid => undef, alive => undef, state => 'idle', st => ['done', 'dropped']),
    sm(bp => 'zeta-solo',  pid => undef, alive => undef, state => 'solo', fleet => undef),
);

# ===========================================================================
# R. rendering -- the STACKED screen (operator, 2026-11-11): a Fleets list in
# the Blueprints panel's own language, the selected fleet's detail below it
# (its package rows exactly as the Blueprints panel draws them, a facts line),
# one action line, full-width rules, the legend on the last row.
# ===========================================================================
sub rich {
    my (%o) = @_;
    my $s = sm(%o);
    return { %$s, packages_done => $o{d} // 1, packages_total => $o{t} // 4, running_coordinators => $o{live} // 0,
             inbox_waiting => $o{flags} // 0, orchestrator_started_at => $o{started},
             relaunch_at => $o{relaunch_at}, relaunch_local => $o{relaunch_local},
             packages => [ map { { name => $_->[0], status => $_->[1], step_word => $_->[2], attempt => $_->[3] // 1,
                                   attempt_cap => 5, agents => [] } } @{ $o{pkgs} || [ [ '01-a', 'running', 'tests' ] ] } ] };
}
my %FS0 = (shutdown => 0, operator_stop => 0, operator_stop_at => undef, last_seen_at => undef, last_seen_local => undef);
my @RICH = (
    rich(bp => 'alpha-run', pid => 11, alive => 1, started => $NOW - 6 * 3600, live => 3, flags => 1, d => 2, t => 7,
         pkgs => [ [ '03-make-and-hooks', 'running', 'implementation', 3 ], [ '04-schema', 'running', 'review' ],
                   [ '05-waits', 'blocked', undef ] ]),
    rich(bp => 'beta-pause', pid => 12, alive => 1, state => 'paused', reason => 'usage', window => 'five_hour',
         started => $NOW - 30 * 3600, relaunch_at => $NOW + 7200,
         relaunch_local => { wday => 'Thu', hhmm => '02:00', day => '01', mon => 'Jan' }),
    rich(bp => 'gamma-dead', pid => 13, alive => 0, state => 'stale',
         fleet => { %FS0, last_seen_at => $NOW - 3 * 3600, last_seen_local => { wday => 'Thu', hhmm => '12:04', day => '01', mon => 'Jan' } }),
    rich(bp => 'delta-mine', pid => undef, alive => undef, state => 'parked',
         fleet => { %FS0, shutdown => 1, operator_stop => 1, operator_stop_at => $NOW - 3600 }),
    rich(bp => 'eps-done', pid => undef, alive => undef, state => 'idle', d => 2, t => 2,
         pkgs => [ [ '01-a', 'done' ], [ '02-b', 'dropped' ] ]),
    rich(bp => 'zeta-solo', pid => undef, alive => undef, state => 'solo', fleet => undef),
);
my $SPEND = { claude => { state => 'ok', windows => [ { name => 'five_hour', text => '85%' }, { name => 'seven_day', text => '40%' } ] } };
sub ss_at { my ($i) = @_; my $ss = tui::FleetScreen::init(runs => \@RICH, now => $NOW, spend => $SPEND); $ss->{cursor} = $i; return $ss; }
sub T_ { my ($sp) = @_; return join '', map { $_->{text} } @$sp; }
{
    my $rows = tui::FleetScreen::rows(\@RICH);
    is_deeply([ map { $_->{blueprint} } @$rows ], [qw(alpha-run beta-pause gamma-dead delta-mine eps-done)],
        'R1: one row per fleet, in summary order; the drive-solo blueprint is not listed');

    # R2: the state says WHEN.
    my $D = G('sep.dot');
    my %want = ('alpha-run' => 'running 6h', 'beta-pause' => "paused $D until 02:00",
                'gamma-dead' => 'stopped (crashed 12:04)', 'delta-mine' => 'stopped by you 1h ago', 'eps-done' => 'settled');
    my %role = ('alpha-run' => 'state.ok', 'beta-pause' => 'state.warn', 'gamma-dead' => 'state.crit',
                'delta-mine' => 'state.warn', 'eps-done' => 'text.muted');
    for my $r (@$rows) {
        my ($sp, $ex) = tui::FleetScreen::state_words($r, $NOW);
        is(T_($sp), $want{ $r->{blueprint} }, "R2: $r->{blueprint} -- '$want{ $r->{blueprint} }'");
        is($sp->[0]{role}, $role{ $r->{blueprint} }, "R2: $r->{blueprint} -- in $role{ $r->{blueprint} }");
    }
    my (undef, $ex) = tui::FleetScreen::state_words($rows->[0], $NOW);
    is(join('|', map { $_->{text} } @$ex), '3 live|' . G('icon.decisions') . ' 1', 'R2: a running fleet adds its live coordinators and its flags');
    my $old = { %{ $rows->[2] }, s => { %{ $rows->[2]{s} }, fleet => { %{ $rows->[2]{s}{fleet} }, last_seen_at => $NOW - 3 * 86400 } } };
    is(T_((tui::FleetScreen::state_words($old, $NOW))[0]), 'stopped (crashed Thu 12:04)', 'R2: a crash more than a day old names the day too');

    # R3: the list's columns line up the way the Blueprints panel's do.
    my $list = [ map { T_($_) } @{ tui::FleetScreen::list_lines(ss_at(0)) } ];
    my $col = sub { my ($t, $n) = @_; my $i = index($t, $n); $i < 0 ? undef : tui::Layout::display_width(substr($t, 0, $i)) };
    my @meter = map { my $t = $_; my ($m) = grep { defined } map { $col->($t, $_) } (G('gauge.full'), G('gauge.empty')); $m } @$list;
    my @count = map { my ($c) = m{(\d+/\d+)}; $col->($_, $c) } @$list;
    is(scalar(keys %{{ map { $_ => 1 } @meter }}), 1, 'R3: every meter starts in one column');
    is(scalar(keys %{{ map { $_ => 1 } @count }}), 1, 'R3: every count starts in one column');
    my @state = map { my $t = $_; my ($w) = grep { defined } map { $col->($t, $_) } ('running', 'paused', 'stopped', 'settled'); $w } @$list;
    is(scalar(keys %{{ map { $_ => 1 } @state }}), 1, 'R3: every state starts in one column');
    unlike(join("\n", @$list), qr/\[enter\]/, 'R3: no per-row action column');
    like($list->[0], qr/\A\Q@{[G('cursor')]}\E /, 'R3: the cursor marks the selected row');

    # R4: the detail's package rows are the Blueprints panel's own, byte for byte.
    for my $cols (121, 180) {
        my $ss = ss_at(0);
        my $mine = [ map { T_($_) } @{ tui::FleetScreen::package_lines($ss, $cols) } ];
        my $panel = tui::DashboardScreen::_run_summary_lines(\@RICH, undef, tui::DashboardScreen::_blueprints_body_width($cols), $NOW);
        my @ptext = map { T_($_) } @$panel;
        my ($from) = grep { $ptext[$_] =~ /alpha-run/ } 0 .. $#ptext;
        my @expect = @ptext[$from + 1 .. $from + 3];
        is_deeply($mine, \@expect, "R4 ($cols): alpha-run's package rows are byte-identical to the Blueprints panel's");
    }

    # R5: the facts line.
    is(T_(tui::FleetScreen::facts_line(ss_at(1))), "  orchestrator up 30h $D paused for the 5h limit until 02:00 $D usage 5h 85% / 7d 40%",
        'R5: uptime, the pause and its end, usage 5h/7d');
    is(T_(tui::FleetScreen::facts_line(ss_at(2))), "  orchestrator not running $D usage 5h 85% / 7d 40%", 'R5: a dead orchestrator says so');

    # R6: the action line, per selection, and the confirm in place.
    is(T_(tui::FleetScreen::action_line(ss_at(0))), "  [enter] stop this fleet   (it finishes each package's current step, then halts)", 'R6: running -> stop');
    is(T_(tui::FleetScreen::action_line(ss_at(2))), '  [enter] start this fleet   (runs its hooks self-test first, a few minutes)', 'R6: stopped -> start');
    is(T_(tui::FleetScreen::action_line(ss_at(4))), '  nothing to do - settled', 'R6: settled -> nothing to do');
    my $ss = ss_at(2);
    tui::FleetScreen::dispatch_key($ss, "\r");
    is(T_(tui::FleetScreen::action_line($ss)), '  Start gamma-dead? [y] yes, any other key cancels', 'R6: [enter] turns the line into the confirm, in place');
    $ss = ss_at(0);
    tui::FleetScreen::dispatch_key($ss, "\r");
    is(T_(tui::FleetScreen::action_line($ss)), '  Stop alpha-run? [y] yes, any other key cancels', 'R6: ... for stop too');
    $ss->{busy} = { op => 'start', blueprint => 'gamma-dead', elapsed => 42.7 };
    like(T_(tui::FleetScreen::action_line($ss)), qr/starting gamma-dead - bp-orchestrate\.sh is running in the container, 42s/, 'R6: a running start shows its progress');
    delete $ss->{busy}; delete $ss->{confirm};
    $ss->{status} = { kind => 'failed', op => 'start', detail => 'gamma-dead - exit 6 - hooks self-test failed' };
    my $fl = tui::FleetScreen::action_line($ss);
    is(T_($fl), '  FAILED start - gamma-dead - exit 6 - hooks self-test failed', 'R6: a failure shows the exit code and last line');
    is($fl->[-1]{role}, 'state.crit', 'R6: in crit');

    # R7: the frame -- title, full-width rules, the legend on the last row.
    for my $geo ([121, 50], [180, 50], [121, 24]) {
        my ($c, $h) = @$geo;
        my $cells = tui::FleetScreen::compose(ss_at(1), $h, $c);
        is(scalar(@$cells), $h, "R7 ${c}x$h: exactly the terminal's rows");
        my @t = map { $_->{text} // '' } @$cells;
        my $R = G('rule.h');
        my @titles = grep { /\A\Q$R\E (?:Fleets|beta-pause) / } @t;
        is(scalar(@titles), 2, "R7 ${c}x$h: two stacked panels, titled Fleets and the selected fleet");
        like($t[1], qr/\A\Q$R\E Fleets \Q$R\E/, "R7 ${c}x$h: the list is titled '$R Fleets $R'");
        my @rules = grep { /\A(?:\Q$R\E)/ } @t;
        is(scalar(grep { tui::Layout::display_width($_) != $c } @rules), 0, "R7 ${c}x$h: every rule spans the full width");
        unlike(join("\n", @t), qr/\x{2502}|\xe2\x94\x82/, "R7 ${c}x$h: no vertical divider");
        like($t[-1], qr/\[enter\] start\/stop   \[f\] back   \[q\] quit *\z/, "R7 ${c}x$h: the key legend is on the last row");
        like($t[-3], qr/\[enter\] stop this fleet/, "R7 ${c}x$h: the action line sits right above the footer rule");
    }
    my $empty = frame_text(tui::FleetScreen::compose(tui::FleetScreen::init(runs => []), 20, 100));
    like($empty, qr/\(no fleet runs/, 'R8: no fleets -> an honest empty line');

    # R9: too many packages -> the panel's "+N rows hidden" convention.
    my @many = map { [ sprintf('%02d-pkg', $_), 'running', 'tests' ] } 1 .. 40;
    my $big = [ rich(bp => 'big-fleet', pid => 1, alive => 1, started => $NOW - 60, pkgs => \@many) ];
    my $bs = tui::FleetScreen::init(runs => $big, now => $NOW);
    my @bt = map { $_->{text} // '' } @{ tui::FleetScreen::compose($bs, 24, 121) };
    ok((grep { /\A\+\d+ rows? hidden \(short panel\)/ } @bt), 'R9: a long package list is cut with the "+N rows hidden" notice');
    is(scalar(@bt), 24, 'R9: and the screen is still exactly the terminal');
}

# ===========================================================================
# K. keys, confirm, and the actions
# ===========================================================================
# drive(\@wait_keys, %seams) -> (\%result, \%calls, \@frames). Keys arrive one
# per wait_key call; read_key is the type-ahead source (empty unless given).
sub drive {
    my ($keys, %o) = @_;
    my @k = @$keys;
    my @ahead = @{ delete $o{ahead} || [] };
    my %calls = (start => [], stop => [], hb => 0, load => 0);
    my @frames;
    my $res = tui::FleetScreen::run(
        runs      => \@RUNS,
        load      => sub { $calls{load}++; return \@RUNS },
        start     => sub { my ($row, $p) = @_; push @{ $calls{start} }, $row->{blueprint};
                           $p->(5); $p->(17); return { ok => 1, detail => 'orchestrator started for x (pid 9)' } },
        stop      => sub { my ($row) = @_; push @{ $calls{stop} }, $row->{blueprint}; return { ok => 1, detail => 'parks' } },
        read_key  => sub { @ahead ? shift @ahead : undef },
        wait_key  => sub { @k ? shift @k : undef },
        term_size => sub { (130, 30) },
        render    => sub { my ($prev, $f) = @_; return frame_text($f) },
        out       => sub { push @frames, $_[0] },
        heartbeat => sub { $calls{hb}++ },
        max_ticks => 40,
        %o,
    );
    return ($res, \%calls, \@frames);
}

{
    # stop: cursor 0 is alpha-run (running)
    my ($r, $c) = drive(["\r", 'n', 'q']);
    is_deeply($c->{stop}, [], 'K1: [enter] then a non-y key cancels: stop is NOT called');
    is_deeply($c->{start}, [], 'K1: nor start');
    is($r->{closed}, 1, 'K1: [q] closes');

    ($r, $c) = drive(["\r", 'y', 'q']);
    is_deeply($c->{stop}, ['alpha-run'], 'K2: [enter] [y] on a running fleet calls stop once, for that fleet');
    is_deeply($c->{start}, [], 'K2: and never start');
    is($r->{stopped}, 1, 'K2: counted');

    ($r, $c) = drive(['j', "\r", 'Y', 'q']);
    is_deeply($c->{stop}, ['beta-pause'], 'K3: a paused fleet offers stop too ([Y] confirms)');

    my $frames;
    ($r, $c, $frames) = drive(['j', 'j', "\r", 'y', 'q']);
    is_deeply($c->{start}, ['gamma-dead'], 'K4: [enter] [y] on a stopped fleet calls start once, for that fleet');
    is_deeply($c->{stop}, [], 'K4: and never stop');
    ok((grep { /starting gamma-dead - .*17s/ } @$frames), 'K4: the progress callback repaints the modal with the elapsed time');
    ok((grep { /started gamma-dead - orchestrator started for x/ } @$frames), 'K4: the result is shown');
    cmp_ok($c->{hb}, '>=', 2, 'K4: the heartbeat keeps ticking through the run (and while idle)');
    cmp_ok($c->{load}, '>=', 2, 'K4: the list is reloaded after the action');

    ($r, $c) = drive(['j', 'j', 'j', 'j', "\r", 'y', 'q']);
    is_deeply([ @{ $c->{start} }, @{ $c->{stop} } ], [], 'K5: a settled fleet offers nothing: [enter] [y] calls no seam');

    ($r, $c) = drive(['j', 'j', "\r", 'q'], ahead => []);
    is_deeply($c->{start}, [], 'K6: [enter] then [q] (not y) cancels the start');

    # type-ahead: the y is already queued when the confirm arms -> discarded
    my @k = ('j', 'j', "\r");
    my @ahead;
    my %calls = (start => 0);
    tui::FleetScreen::run(
        runs => \@RUNS, start => sub { $calls{start}++; { ok => 1 } },
        read_key => sub { @ahead ? shift @ahead : undef },
        wait_key => sub { my $x = shift @k; @ahead = ('y') if defined $x && $x eq "\r"; return $x },
        term_size => sub { (100, 24) }, max_ticks => 10);
    is($calls{start}, 0, 'K7: a [y] already in the input buffer when the confirm arms cannot fire the start');

    # the action applies to the row armed, even if a reload reorders the list
    my $ss = tui::FleetScreen::init(runs => \@RUNS);
    $ss->{cursor} = 2;
    tui::FleetScreen::dispatch_key($ss, "\r");
    my @reordered = reverse @RUNS;
    my $hit;
    $ss->{rows} = tui::FleetScreen::rows(\@reordered);
    my $act = tui::FleetScreen::dispatch_key($ss, 'y');
    tui::FleetScreen::apply($ss, $act, { start => sub { $hit = $_[0]{blueprint}; { ok => 1 } } });
    is($hit, 'gamma-dead', 'K8: the confirmed start hits the fleet that was selected when it armed');

    # no seam wired -> unavailable, nothing thrown
    ($r, $c) = drive(["\r", 'y', 'q'], stop => undef);
    is(($r->{status} || {})->{kind}, 'unavailable', 'K9: with no stop seam the screen reports it unavailable');
}

# ===========================================================================
# S. Dashboard::fleet_start
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    open my $f, '>', "$tmp/.stopped-by-operator" or die; close $f;
    my @seen;
    my $runner = sub { my (%o) = @_; push @seen, \%o; $o{on_tick}->(3);
                       return { rc => 0, out => "x\norchestrator started for bp1 (pid 77)\nlog: /x\n", err => '', timed_out => 0, elapsed => 4 } };
    my $ticks = 0;
    my $r = Dashboard::fleet_start(bp => 'bp1', podman => 'podman.exe', container => 'claude-p-1',
                                   runs_dir => $tmp, runner => $runner, on_tick => sub { $ticks++ }, env => {});
    is(scalar(@seen), 1, 'S1: the runner is called exactly once');
    is_deeply($seen[0]{cmd}, [ 'podman.exe', 'exec', '-w', '/project', 'claude-p-1', 'bash', '-c',
                               'export PATH="/root/.local/bin:$PATH"; exec bash "$0" "$@"',
                               '/root/.claude/plugins/marketplaces/ccpraxis-local/butler/scripts/bp-orchestrate.sh', 'bp1' ],
        'S1: podman exec in /project, PATH led by /root/.local/bin, bp-orchestrate.sh <bp> passed positionally');
    is($seen[0]{timeout}, 900, 'S2: a generous wall-clock bound (900s) by default');
    ok(!exists $seen[0]{idle_timeout}, 'S2: and no inactivity watchdog (the self-test is silent while it works)');
    is($ticks, 1, 'S3: the runner\'s on_tick reaches the caller (progress)');
    ok($r->{ok}, 'S4: rc 0 -> ok');
    is($r->{detail}, 'log: /x', 'S4: the last line of output is the detail');
    ok(!-e "$tmp/.stopped-by-operator", 'S5: a successful start drops the operator-stop record');

    @seen = ();
    $r = Dashboard::fleet_start(bp => 'bp1', podman => 'p', container => 'c', runner => $runner,
                                env => { SANDBOX_FLEET_START_TIMEOUT => '1200' });
    is($seen[0]{timeout}, 1200, 'S6: SANDBOX_FLEET_START_TIMEOUT overrides the bound');

    $r = Dashboard::fleet_start(bp => 'bp1', podman => 'p', container => 'c', env => {},
        runner => sub { { rc => 6 << 8, out => "bp-orchestrate: hooks self-test failed - refusing to start the fleet\n", timed_out => 0 } });
    ok(!$r->{ok}, 'S7: a non-zero exit is a failure');
    is($r->{detail}, 'exit 6 - bp-orchestrate: hooks self-test failed - refusing to start the fleet', 'S7: with the exit code and the last line');

    $r = Dashboard::fleet_start(bp => 'bp1', podman => 'p', container => 'c', env => {},
        runner => sub { { rc => 124 << 8, timed_out => 1, out => '' } });
    ok(!$r->{ok} && $r->{timed_out}, 'S8: a timeout is a failure');
    like($r->{detail}, qr/no answer after 900s/, 'S8: and says how long it waited');

    my $called = 0;
    for my $bad ('-x', '../etc', 'a b', '', undef, 'x;rm') {
        $r = Dashboard::fleet_start(bp => $bad, podman => 'p', container => 'c', runner => sub { $called++; {} });
        ok(!$r->{ok}, 'S9: refused: ' . (defined $bad ? "'$bad'" : 'undef'));
    }
    is($called, 0, 'S9: a hostile blueprint name never reaches the runner');
    $r = Dashboard::fleet_start(bp => 'bp1', podman => 'p', container => '', runner => sub { $called++; {} });
    ok(!$r->{ok} && $called == 0, 'S10: no container -> refused before running anything');
}

# ===========================================================================
# T. Dashboard::fleet_stop
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $r = Dashboard::fleet_stop(runs_dir => $tmp, now => $NOW);
    ok(!$r->{ok}, 'T1: a directory without registry.json is not a fleet: refused');
    ok(!-e "$tmp/.shutdown", 'T1: and nothing is written');

    open my $f, '>', "$tmp/registry.json" or die; print {$f} '{}'; close $f;
    $r = Dashboard::fleet_stop(runs_dir => $tmp, now => $NOW);
    ok($r->{ok}, 'T2: a fleet run is stopped');
    ok(-e "$tmp/.shutdown", 'T2: through runs/.shutdown, the graceful stop the orchestrator honours');
    ok(-e "$tmp/.stopped-by-operator", 'T2: and the stop is recorded as the operator\'s');
    open my $g, '<', "$tmp/.stopped-by-operator" or die; my $j = do { local $/; <$g> }; close $g;
    my $rec = eval { JSON::PP->new->decode($j) };
    is_deeply($rec, { v => 1, at => $NOW, by => 'dashboard' }, 'T3: the record is {v, at, by}');
    cmp_ok((stat "$tmp/.stopped-by-operator")[9], '<=', (stat "$tmp/.shutdown")[9], 'T4: the record is written no later than .shutdown');

    # source order: mark_operator_stop is called before .shutdown is opened
    open my $s, '<', "$Bin/../../scripts/Dashboard.pm" or die; my $src = do { local $/; <$s> }; close $s;
    my ($body) = $src =~ /^sub fleet_stop \{(.*?)^\}/ms;
    ok(defined $body && index($body, 'mark_operator_stop') < index($body, '.shutdown"'), 'T4: fleet_stop writes the record BEFORE .shutdown');
    unlike($body // '', qr/\bkill\b|\bsystem\b|\bexec\b/, 'T5: fleet_stop kills nothing and spawns nothing');

    # an orchestrator marker alone is fleet evidence too (a fleet started
    # moments ago, before its first launch wrote registry.json)
    my $fresh = tempdir(CLEANUP => 1);
    open my $o, '>', "$fresh/.orchestrator" or die; print {$o} "77\n"; close $o;
    ok(Dashboard::fleet_stop(runs_dir => $fresh, now => $NOW)->{ok}, 'T2b: a fleet with only its .orchestrator marker can be stopped');

    # [s]/[x] mark only fleets that are UP (fleet_status offers stop)
    my @d = map { tempdir(CLEANUP => 1) } 1 .. 4;
    my @sums = (
        sm(bp => 'up',     pid => 1, alive => 1),
        sm(bp => 'paused', pid => 2, alive => 1, state => 'paused'),
        sm(bp => 'dead',   pid => 3, alive => 0, state => 'stale'),
        sm(bp => 'solo',   pid => undef, alive => undef, state => 'solo', fleet => undef),
    );
    $sums[$_]{runs_dir} = $d[$_] for 0 .. 3;
    is_deeply([ Dashboard::operator_stop_targets(\@sums) ], [ $d[0], $d[1] ],
        'T6: [s]/[x] record an operator stop only for fleets that are running or paused, never a dead one or a solo run');
    is_deeply([ Dashboard::operator_stop_targets(undef) ], [], 'T6: total on undef');
}

# ===========================================================================
# P. purity of tui/FleetScreen.pm
# ===========================================================================
{
    open my $fh, '<', "$Bin/../../scripts/tui/FleetScreen.pm" or die;
    my $src = do { local $/; <$fh> }; close $fh;
    $src =~ s/^\s*#.*$//mg;
    unlike($src, qr/\b(?:system|exec|fork|readpipe|qx|kill|unlink|rename|open|opendir|time)\s*\(|`/,
        'P1: tui/FleetScreen.pm spawns nothing, touches no file and reads no clock');
    unlike($src, qr/\bDashboard::/, 'P2: and never names Dashboard (the arrow runs one way)');
}

done_testing();
