#!/usr/bin/env perl
# B2 dashboard framework: Dashboard.pm — the raw-ANSI TUI for `claude-sandbox`.
#
# PART 1  pure helpers: decide_mode, fmt_age, clip_pad, find_exe.
# PART 2  frame composition: exact dimensions, tiny-terminal degradation,
#         content placement, the shutdown-confirm footer.
# PART 3  render diff: full-redraw-once vs per-row diff, synchronized-output
#         wrappers, only-changed rows touched (the B0 flicker fix).
# PART 4  key dispatch incl. the two-step shutdown confirm.
# PART 5  spawn: mode ladder (wt -> start -> inline) + argv construction.
# PART 6  events: B1 launch-log tail parsing + last-N + skip-garbage.
# PART 7  signal paths: blueprint runs/.shutdown derivation + write.
# PART 8  the loop (run) driven by a fake clock + scripted keys with every side
#         effect injected: heartbeat timing, [c] spawn, [s][y] shutdown, [q] quit.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# PART 1 — pure helpers
# ===========================================================================
is(Dashboard::decide_mode(1, 1, 0), 'tui',   'mode: tty + readkey + not-forced -> tui');
is(Dashboard::decide_mode(0, 1, 0), 'plain', 'mode: no tty -> plain');
is(Dashboard::decide_mode(1, 0, 0), 'plain', 'mode: no Term::ReadKey -> plain');
is(Dashboard::decide_mode(1, 1, 1), 'plain', 'mode: force_plain -> plain');

is(Dashboard::fmt_age(0),       '0s',     'age: 0s');
is(Dashboard::fmt_age(59),      '59s',    'age: 59s');
is(Dashboard::fmt_age(60),      '1m',     'age: 60s -> 1m');
is(Dashboard::fmt_age(3599),    '59m',    'age: 59m');
is(Dashboard::fmt_age(3600),    '1h00m',  'age: 1h00m');
is(Dashboard::fmt_age(3660),    '1h01m',  'age: 1h01m');
is(Dashboard::fmt_age(90000),   '1d01h',  'age: 1d01h');
is(Dashboard::fmt_age(undef),   'n/a',    'age: undef -> n/a (ASCII, width-safe)');
is(Dashboard::fmt_age(-5),      'n/a',    'age: negative -> n/a');

# fmt_hms: uptime in explicit "Xh Ym Zs", all three components always shown.
is(Dashboard::fmt_hms(0),       '0h 0m 0s',  'hms: zero');
is(Dashboard::fmt_hms(13),      '0h 0m 13s', 'hms: seconds only');
is(Dashboard::fmt_hms(133),     '0h 2m 13s', 'hms: minutes + seconds');
is(Dashboard::fmt_hms(7509),    '2h 5m 9s',  'hms: hours + minutes + seconds');
is(Dashboard::fmt_hms(undef),   'n/a',       'hms: undef -> n/a');
is(Dashboard::fmt_hms(-1),      'n/a',       'hms: negative -> n/a');

is(length(Dashboard::clip_pad('hi', 5)), 5,  'clip_pad: pads up to width');
is(Dashboard::clip_pad('hi', 5),  'hi   ',   'clip_pad: right-pads with spaces');
is(Dashboard::clip_pad('hello world', 5), 'hello', 'clip_pad: truncates to width');
is(Dashboard::clip_pad('x', 0),   '',        'clip_pad: width 0 -> empty');
is(Dashboard::clip_pad(undef, 3), '   ',     'clip_pad: undef -> spaces');

{
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/wt.exe" or die; print $fh "x"; close $fh;
    my $path = "/nope${\ ';'}$dir${\ ';'}/also-nope";
    is(Dashboard::find_exe('wt.exe', $path, ';'), "$dir/wt.exe",
        'find_exe: locates the file on a ;-separated PATH');
    is(Dashboard::find_exe('absent.exe', $path, ';'), undef,
        'find_exe: undef when not found');
    is(Dashboard::find_exe('wt.exe', undef, ';'), undef,
        'find_exe: undef PATH -> undef');
}

# find_exe default separator: ONLY native MSWin32 perl uses ';'. The Git-for-
# Windows perl that runs the launcher is $^O 'cygwin'/'msys' with a colon-PATH, so
# the default must be ':' there. Regression: the old `cygwin|msys -> ;` split a
# colon-PATH into one element -> wt.exe never found -> launch-claude silently
# opened a bare PowerShell console instead of a Windows Terminal window.
SKIP: {
    skip 'native MSWin32 perl uses a ;-separated PATH', 1 if $^O eq 'MSWin32';
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/wt.exe" or die; print $fh 'x'; close $fh;
    is(Dashboard::find_exe('wt.exe', "/nope:$dir:/also-nope"), "$dir/wt.exe",
        'find_exe: default sep is : on cygwin/msys/unix (not ;)');
}

# find_wt: PATH hit wins; else the %LOCALAPPDATA%\Microsoft\WindowsApps fallback;
# else undef. This is the "Windows Terminal is required" assertion the launcher
# uses before launch-claude (it fails loudly when this returns undef).
{
    my $pdir = tempdir(CLEANUP => 1);
    open my $f1, '>', "$pdir/wt.exe" or die; print $f1 'x'; close $f1;
    is(Dashboard::find_wt($pdir, undef), "$pdir/wt.exe", 'find_wt: located on PATH');

    my $la = tempdir(CLEANUP => 1);
    my $wa = File::Spec->catdir($la, 'Microsoft', 'WindowsApps');
    make_path($wa);
    open my $f2, '>', "$wa/wt.exe" or die; print $f2 'x'; close $f2;
    is(Dashboard::find_wt('/nope:/also-nope', $la),
        File::Spec->catfile($wa, 'wt.exe'),
        'find_wt: falls back to %LOCALAPPDATA%\\Microsoft\\WindowsApps');

    is(Dashboard::find_wt('/nope:/also-nope', undef), undef,
        'find_wt: undef when WT is installed nowhere (-> launcher fails loudly)');
}

# ===========================================================================
# PART 2 — frame composition
# ===========================================================================
my %st = (
    project_name => 'demo',
    container    => 'claude-demo-abcd1234',
    status       => 'running',
    beat_age     => 12,
    uptime       => 3660,
    events       => ['10:00:01  launch_start', '10:00:05  container_start exit=0'],
);

{
    my $f = Dashboard::compose_frame(\%st, 24, 80);
    is(scalar(@$f), 24, 'compose: exactly $rows rows');
    is(length($f->[0]{text}), 80, 'compose: every row exactly $cols wide (row 0)');
    my $bad = grep { length($_->{text}) != 80 } @$f;
    is($bad, 0, 'compose: ALL rows exactly $cols wide');
    is($f->[0]{role}, 'title', 'compose: row 0 is the title');
    like($f->[0]{text}, qr/ccpraxis sandbox/, 'compose: title text present');
    like($f->[0]{text}, qr/\Qclaude-demo-abcd1234\E.*\[running\]/, 'compose: container+status right-justified');
    is($f->[-1]{role}, 'footer', 'compose: last row is the footer');
    like($f->[-1]{text}, qr/\[q\] quit/, 'compose: footer legend present');
    my $joined = join "\n", map { $_->{text} } @$f;
    like($joined, qr/-- Sandbox /,        'compose: Sandbox panel title rendered');
    like($joined, qr/container : claude-demo/, 'compose: Sandbox panel body rendered');
    like($joined, qr/-- Recent activity /, 'compose: Activity panel rendered');
    like($joined, qr/\Qlaunch_start\E/,   'compose: B1 event surfaced in Activity');
    like($joined, qr/uptime    : 1h 1m 0s/, 'compose: uptime rendered as Xh Ym Zs');
}

# tiny-terminal degradation
{
    my $f1 = Dashboard::compose_frame(\%st, 1, 40);
    is(scalar(@$f1), 1, 'compose: 1 row -> title only');
    is($f1->[0]{role}, 'title', 'compose: 1-row frame is the title');

    my $f2 = Dashboard::compose_frame(\%st, 2, 40);
    is(scalar(@$f2), 2, 'compose: 2 rows -> title + footer');
    is($f2->[1]{role}, 'footer', 'compose: 2-row frame ends in footer');

    my $f0 = Dashboard::compose_frame(\%st, 0, 40);
    is(scalar(@$f0), 0, 'compose: 0 rows -> empty');

    my $ftiny = Dashboard::compose_frame(\%st, 3, 1);
    is(length($ftiny->[0]{text}), 1, 'compose: width 1 -> 1-char rows (no crash)');
}

# shutdown-confirm footer
{
    my %sc = (%st, pending => 'shutdown');
    my $f = Dashboard::compose_frame(\%sc, 10, 80);
    is($f->[-1]{role}, 'footer-alert', 'compose: pending shutdown -> footer-alert role');
    like($f->[-1]{text}, qr/Shut down ALL/, 'compose: confirm prompt shown in footer');
}

# install-failure alert banner (#20): a backpack-install failure must surface in
# the dashboard (the pre-dashboard stdout warning is wiped by the alt-screen).
{
    my %sw = (%st, install_warning => 'backpack install FAILED - run /backpack:install');
    my $f = Dashboard::compose_frame(\%sw, 10, 80);
    my @alert = grep { $_->{role} eq 'alert' } @$f;
    is(scalar(@alert), 1, 'compose: install_warning -> exactly one alert row');
    is($f->[1]{role}, 'alert', 'compose: alert sits directly under the title');
    like($f->[1]{text}, qr/backpack install FAILED/, 'compose: alert shows the warning text');
    is(scalar(@$f), 10, 'compose: alert keeps the frame exactly $rows');
    my $bad = grep { length($_->{text}) != 80 } @$f;
    is($bad, 0, 'compose: alert row keeps every row exactly $cols');
    is($f->[-1]{role}, 'footer', 'compose: footer still last with an alert present');

    my $f2 = Dashboard::compose_frame(\%st, 10, 80);   # %st has no warning
    is(scalar(grep { $_->{role} eq 'alert' } @$f2), 0, 'compose: no warning -> no alert row');

    my $f3 = Dashboard::compose_frame(\%sw, 3, 80);
    is(scalar(grep { $_->{role} eq 'alert' } @$f3), 0, 'compose: rows<4 suppresses the alert (no crash)');

    like(Dashboard::sgr_for_role('alert'), qr/\e\[1;37;41m/, 'sgr: alert role -> bold white on red');
}

# C3 regression: a non-ASCII project name must NOT break the exactly-$cols
# width invariant (bytes outside printable ASCII map 1:1 to '?').
{
    my %sx = (%st, project_name => "caf\xC3\xA9");   # "café" as UTF-8 bytes
    my $f = Dashboard::compose_frame(\%sx, 10, 40);
    my $bad = grep { length($_->{text}) != 40 } @$f;
    is($bad, 0, 'compose: non-ASCII project name keeps EVERY row exactly $cols');
    my $joined = join "\n", map { $_->{text} } @$f;
    unlike($joined, qr/\xC3\xA9/, 'compose: raw non-ASCII bytes not emitted (sanitized to ?)');
}

# H3 regression: a control char (newline) smuggled into a B1 log field must not
# inject extra line breaks into a composed row.
{
    my @lines = ('{"ts":"2026-06-24T10:00:09Z","type":"oops","state":"a\nb"}');
    my $events = Dashboard::recent_events(\@lines, 5);
    my %se = (%st, events => $events);
    my $f = Dashboard::compose_frame(\%se, 12, 50);
    my $bad = grep { length($_->{text}) != 50 } @$f;
    is($bad, 0, 'compose: event with embedded newline keeps rows exactly $cols');
    my $joined = join "\n", map { $_->{text} } @$f;
    is(scalar(() = $joined =~ /\n/g), scalar(@$f) - 1,
       'compose: smuggled newline stripped (no extra row breaks)');
}

# ===========================================================================
# PART 3 — render diff (the flicker fix)
# ===========================================================================
{
    my $a = Dashboard::compose_frame(\%st, 10, 60);
    # first render: no prev -> full redraw
    my $full = Dashboard::render_frame(undef, $a, { color => 0 });
    like($full, qr/^\e\[\?2026h/,  'render: opens with synchronized-output begin');
    like($full, qr/\e\[\?2026l$/,  'render: closes with synchronized-output end');
    like($full, qr/\e\[2J\e\[H/,   'render: full redraw clears the screen ONCE');

    # identical next frame -> diff touches no rows (no cursor moves besides wrappers)
    my $b = Dashboard::compose_frame(\%st, 10, 60);
    my $none = Dashboard::render_frame($a, $b, { color => 0 });
    unlike($none, qr/\e\[2J/, 'render: steady state does NOT clear screen (no flicker)');
    unlike($none, qr/\e\[\d+;1H/, 'render: identical frame -> zero row repaints');

    # change one row -> only that row repainted
    my %st2 = (%st, beat_age => 99);   # changes the heartbeat line only
    my $c = Dashboard::compose_frame(\%st2, 10, 60);
    my $diff = Dashboard::render_frame($a, $c, { color => 0 });
    unlike($diff, qr/\e\[2J/, 'render: single-field change is a diff, not a clear');
    my @moves = ($diff =~ /\e\[(\d+);1H/g);
    is(scalar(@moves), 1, 'render: exactly one row repainted for a one-row change');

    # resize (row count changes) -> full redraw
    my $resized = Dashboard::compose_frame(\%st, 12, 60);
    my $rdiff = Dashboard::render_frame($a, $resized, { color => 0 });
    like($rdiff, qr/\e\[2J/, 'render: row-count change (resize) forces a full redraw');

    # width-only resize (same rows, new width) -> diff, not clear; \e[K saves it
    my $wider = Dashboard::compose_frame(\%st, 10, 80);   # $a was 10x60
    my $wdiff = Dashboard::render_frame($a, $wider, { color => 0 });
    unlike($wdiff, qr/\e\[2J/, 'render: width-only resize is a diff, not a clear');
    my @wmoves = ($wdiff =~ /\e\[(\d+);1H/g);
    is(scalar(@wmoves), 10, 'render: width-only resize repaints all rows (all text changed)');

    # color mode emits SGR for the title row
    my $colored = Dashboard::render_frame(undef, $a, { color => 1 });
    like($colored, qr/\e\[1;36m/, 'render: color mode emits title SGR');
    like($colored, qr/\e\[0m/,    'render: color mode resets SGR');

    # regression: a trailing \e[K erased the last cell of a full-width row,
    # chopping the title's closing "]" (the "[running" bug). \e[K must come
    # BEFORE the text, never after.
    my $tf = Dashboard::compose_frame(\%st, 6, 80);
    like($tf->[0]{text}, qr/\[running\]$/, 'compose: title row ends with the full [running]');
    my $tr = Dashboard::render_frame(undef, $tf, { color => 0 });
    like($tr,   qr/\e\[1;1H\e\[K/, 'render: line cleared BEFORE the text (\e[K precedes it)');
    unlike($tr, qr/\]\e\[K/,       'render: no \e[K right after "]" (last cell preserved)');
}

# ===========================================================================
# PART 4 — key dispatch
# ===========================================================================
{
    is_deeply([Dashboard::dispatch_key('c', '')],   ['launch', ''],   'key: c -> launch');
    is_deeply([Dashboard::dispatch_key("\r", '')],  ['launch', ''],   'key: Enter -> launch');
    is_deeply([Dashboard::dispatch_key('q', '')],   ['quit', ''],     'key: q -> quit');
    is_deeply([Dashboard::dispatch_key('r', '')],   ['refresh', ''],  'key: r -> refresh');
    is_deeply([Dashboard::dispatch_key('s', '')],   ['confirm-shutdown', 'shutdown'],
        'key: s -> arm shutdown confirm');
    is_deeply([Dashboard::dispatch_key('y', 'shutdown')], ['shutdown', ''],
        'key: y while pending -> fire shutdown');
    is_deeply([Dashboard::dispatch_key('n', 'shutdown')], ['cancel-shutdown', ''],
        'key: any non-y while pending -> cancel');
    is_deeply([Dashboard::dispatch_key('x', '')],   ['', ''],         'key: unknown -> inert');
    is_deeply([Dashboard::dispatch_key("\e", '')],  ['', ''],         'key: ESC -> inert (arrows ignored)');
}

# ===========================================================================
# PART 5 — spawn ladder + argv
# ===========================================================================
{
    is(Dashboard::decide_spawn_mode(1, 1, 'MSWin32'), 'wt',     'spawn-mode: wt present -> wt');
    is(Dashboard::decide_spawn_mode(0, 1, 'MSWin32'), 'start',  'spawn-mode: no wt, win+comspec -> start');
    is(Dashboard::decide_spawn_mode(0, 0, 'MSWin32'), 'inline', 'spawn-mode: no wt, no comspec -> inline');
    is(Dashboard::decide_spawn_mode(0, 1, 'linux'),   'inline', 'spawn-mode: non-windows -> inline');

    my @cmd = ('powershell.exe', '-NoProfile', '-File', 'C:/s/claude-sandbox.ps1', '--session', 'C:/proj');
    my %ctx = (cmd => \@cmd, comspec => 'C:/Windows/cmd.exe');
    is_deeply(Dashboard::spawn_argv('wt', \%ctx),
        ['wt.exe', '-w', 'new', @cmd],
        'spawn-argv: wt wraps the command in a new window');
    is_deeply(Dashboard::spawn_argv('start', \%ctx),
        ['C:/Windows/cmd.exe', '/c', 'start', '', @cmd],
        'spawn-argv: start wraps the command in a new console');
    is(Dashboard::spawn_argv('inline', \%ctx), undef, 'spawn-argv: inline -> undef (run in-process)');
}

# ===========================================================================
# PART 6 — B1 event tail
# ===========================================================================
{
    my @lines = (
        '{"ts":"2026-06-24T10:00:01Z","type":"launch_start","pid":1}',
        'not json at all',
        '{"ts":"2026-06-24T10:00:05Z","type":"container_start","exit":0}',
        '{"ts":"2026-06-24T10:00:09Z","type":"container_gone","state":"exited"}',
        '',
    );
    my $ev = Dashboard::recent_events(\@lines, 10);
    is(scalar(@$ev), 3, 'events: garbage + blank lines skipped');
    is($ev->[0], '10:00:01  launch_start', 'events: ts -> HH:MM:SS + type');
    like($ev->[1], qr/container_start exit=0/, 'events: exit field surfaced');
    like($ev->[2], qr/container_gone state=exited/, 'events: state field surfaced');

    my $last2 = Dashboard::recent_events(\@lines, 2);
    is(scalar(@$last2), 2, 'events: honors the last-N limit');
    like($last2->[-1], qr/container_gone/,  'events: keeps the most recent (last)');
    like($last2->[0],  qr/container_start/, 'events: preserves chronological order (oldest-of-N first)');
}

# ===========================================================================
# PART 7 — shutdown signal paths
# ===========================================================================
{
    my $proj = tempdir(CLEANUP => 1);
    make_path("$proj/.ccpraxis-local-data/blueprints/alpha/runs");
    make_path("$proj/.ccpraxis-local-data/blueprints/beta/runs");
    make_path("$proj/.ccpraxis-local-data/blueprints/gamma");  # no runs/ -> excluded

    my @dirs = Dashboard::blueprint_runs_dirs("$proj/.ccpraxis-local-data");
    is(scalar(@dirs), 2, 'signals: only blueprints WITH a runs/ dir counted');

    my @targets = Dashboard::shutdown_targets($proj);
    is(scalar(@targets), 2, 'signals: one .shutdown target per blueprint runs dir');
    ok((grep { m{/alpha/runs/\.shutdown$} } @targets), 'signals: alpha target path correct');
    ok((grep { m{/beta/runs/\.shutdown$}  } @targets), 'signals: beta target path correct');

    my $n = Dashboard::write_shutdown_signals(@targets);
    is($n, 2, 'signals: write touches every target');
    ok(-f "$proj/.ccpraxis-local-data/blueprints/alpha/runs/.shutdown", 'signals: alpha .shutdown created');
    ok(-f "$proj/.ccpraxis-local-data/blueprints/beta/runs/.shutdown",  'signals: beta .shutdown created');

    # empty project -> no targets, no crash
    my $empty = tempdir(CLEANUP => 1);
    is(scalar(Dashboard::shutdown_targets($empty)), 0, 'signals: project with no blueprints -> 0 targets');
}

# ===========================================================================
# PART 8 — the loop (run) with a fake clock + scripted keys
# ===========================================================================

# helper: build a run() invocation over injected seams. Returns captured effects.
sub drive {
    my (%args) = @_;
    my @keys = @{ $args{keys} || [] };
    my $clock = 1000;
    my %eff = (heartbeats => 0, spawns => 0, signals => 0, gathers => 0, frames => 0);
    my $out = '';

    my $rc = Dashboard::run(
        beat_interval  => $args{beat_interval}  // 1,
        state_interval => $args{state_interval} // 0,   # gather every tick
        tick_interval  => 0.25,
        color          => 0,
        max_ticks      => $args{max_ticks} // 20,
        now            => sub { $clock },
        sleep_for      => sub { $clock += $_[0]; },     # advance the fake clock
        read_key       => sub { @keys ? shift @keys : undef },
        term_size      => sub { (60, 12) },
        gather         => sub { $eff{gathers}++; { project_name => 'demo', container => 'c1', status => 'running', events => [], busy_age => $args{busy_age} } },
        heartbeat      => sub { $eff{heartbeats}++; $args{hb_returns} ? $args{hb_returns}->() : 'ok' },
        spawn          => sub { $eff{spawns}++; undef },
        write_signals  => sub { $eff{signals}++; 1 },
        enter_raw      => sub { $eff{entered} = 1 },
        leave_raw      => sub { $eff{left} = ($eff{left} || 0) + 1 },
        keepawake      => sub { $eff{keepawake_calls}++; $eff{last_busy_age} = $_[0]{busy_age} },
        out            => sub { $out .= $_[0]; $eff{frames}++ },
    );
    $eff{rc} = $rc;
    $eff{out} = $out;
    return \%eff;
}

{
    # 'q' quits promptly and restores the terminal exactly once.
    my $e = drive(keys => ['q'], max_ticks => 50);
    is($e->{rc}, 0, 'loop: q exits with rc 0');
    ok($e->{entered}, 'loop: entered raw mode');
    is($e->{left}, 1, 'loop: left raw mode exactly once (clean restore)');
    ok($e->{frames} >= 1, 'loop: rendered at least one frame');
    like($e->{out}, qr/\e\[\?2026h/, 'loop: output uses synchronized rendering');
}

{
    # heartbeat fires on the first tick, then on cadence as the clock advances.
    my $e = drive(keys => [(undef) x 30], beat_interval => 1, max_ticks => 6);
    ok($e->{heartbeats} >= 2, 'loop: heartbeat fires repeatedly on the time cadence');
}

{
    # B5: the keepawake seam fires on every state refresh, receiving the freshly
    # gathered state (busy_age) so the launcher can drive the wake-lock.
    my $e = drive(keys => [(undef) x 10], busy_age => 42, state_interval => 0, max_ticks => 5);
    ok($e->{keepawake_calls} >= 1, 'loop: keepawake seam fires on state refresh');
    is($e->{last_busy_age}, 42, 'loop: keepawake seam receives the gathered busy_age');
}

{
    # container 'gone' from the heartbeat ends the loop.
    my $e = drive(keys => [(undef) x 30], hb_returns => sub { 'gone' }, max_ticks => 50);
    is($e->{heartbeats}, 1, 'loop: a single heartbeat reporting "gone" ...');
    is($e->{spawns}, 0, '... ends the loop before any further work');
    is($e->{left}, 1, 'loop: still restores the terminal on container-gone exit');
}

{
    # 'c' launches a session (spawn), then 'q'.
    my $e = drive(keys => ['c', 'q'], max_ticks => 50);
    is($e->{spawns}, 1, 'loop: c -> exactly one spawn');
    is($e->{rc}, 0, 'loop: then q exits');
}

{
    # 's' then 'y' fires the shutdown signal; 's' then 'n' does not.
    my $e1 = drive(keys => ['s', 'y', 'q'], max_ticks => 50);
    is($e1->{signals}, 1, 'loop: s,y -> shutdown signal written once');
    my $e2 = drive(keys => ['s', 'n', 'q'], max_ticks => 50);
    is($e2->{signals}, 0, 'loop: s,n -> shutdown cancelled (no signal)');
}

done_testing();
