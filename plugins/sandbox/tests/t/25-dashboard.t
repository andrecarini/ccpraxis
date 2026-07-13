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

# (E) container-status alert banner: a non-running / unreachable / gone container
# surfaces a loud, actionable banner (the loop no longer exits on death).
{
    is(Dashboard::_status_alert({ status => 'running' }), undef,
       'status_alert: running -> no alert');
    is(Dashboard::_status_alert({ status => '' }), undef,
       'status_alert: empty/unknown-yet -> no alert');
    like(Dashboard::_status_alert({ status => 'exited' }), qr/not running/,
       'status_alert: exited -> "not running"');
    like(Dashboard::_status_alert({ status => 'unknown' }), qr/unreachable/,
       'status_alert: unknown -> "unreachable"');
    like(Dashboard::_status_alert({ container_gone => 1, status => 'exited' }), qr/not running/,
       'status_alert: container_gone+exited -> "not running"');
    like(Dashboard::_status_alert({ container_gone => 1, status => 'unknown' }), qr/unreachable/,
       'status_alert: container_gone+unknown -> "unreachable"');

    # A dead container must NOT advertise [c] as a relaunch: [c] only spawns a
    # connector (`podman exec` into a LIVE container), so on a dead container it
    # opens a window that instantly closes. The banner points at the real
    # relaunch path instead (quit, then re-run claude-sandbox).
    for my $dead ({ status => 'exited' },
                  { container_gone => 1, status => 'exited' },
                  { container_gone => 1, status => 'unknown' }) {
        my $msg = Dashboard::_status_alert($dead);
        unlike($msg, qr/\[c\]/, "status_alert: dead container does not offer [c] ($msg)");
        unlike($msg, qr/relaunch.*\[c\]|\[c\].*relaunch/i,
               'status_alert: [c] is never called the relaunch key');
    }
    like(Dashboard::_status_alert({ status => 'exited' }), qr/re-run claude-sandbox/,
       'status_alert: exited banner names the real relaunch path (re-run claude-sandbox)');

    my %dead = (%st, status => 'exited');
    my $f = Dashboard::compose_frame(\%dead, 12, 80);
    my @a = grep { $_->{role} eq 'alert' } @$f;
    is(scalar(@a), 1, 'compose: non-running status -> one alert row');
    like($f->[1]{text}, qr/not running/, 'compose: status alert sits under the title');
    is(scalar(@$f), 12, 'compose: status alert keeps the frame exactly $rows');

    # a status alert AND an install_warning coexist as two banners, body intact
    my %both = (%st, status => 'exited', install_warning => 'backpack install FAILED');
    my $f2 = Dashboard::compose_frame(\%both, 12, 80);
    is(scalar(grep { $_->{role} eq 'alert' } @$f2), 2, 'compose: status + install alerts coexist');
    is(scalar(@$f2), 12, 'compose: two alerts keep the frame exactly $rows');
    my $bad = grep { length($_->{text}) != 80 } @$f2;
    is($bad, 0, 'compose: alert rows keep exactly $cols');
}

# can_launch: [c] may only attach a connector to a RUNNING container; every
# other state suppresses the spawn (else the spawned terminal's `podman exec`
# fails and the window vanishes — the bug this guards).
{
    ok( Dashboard::can_launch({ status => 'running' }), 'can_launch: running -> yes');
    ok(!Dashboard::can_launch({ status => 'exited' }),  'can_launch: exited -> no');
    ok(!Dashboard::can_launch({ status => 'stopped' }), 'can_launch: stopped -> no');
    ok(!Dashboard::can_launch({ status => 'created' }), 'can_launch: created -> no');
    ok(!Dashboard::can_launch({ status => 'restarting' }), 'can_launch: restarting -> no');
    ok(!Dashboard::can_launch({ status => '' }),        'can_launch: not-yet-known -> no');
    ok(!Dashboard::can_launch({ status => 'running', container_gone => 1 }),
       'can_launch: heartbeat says gone -> no (overrides a stale running status)');

    # When a flash is active the footer shows it (with the footer-flash role),
    # not the command legend; absent a flash the legend returns.
    my %fl = (%st, footer_flash => Dashboard::launch_blocked_msg());
    my $ff = Dashboard::compose_frame(\%fl, 12, 80);
    is($ff->[-1]{role}, 'footer-flash', 'compose: active flash -> footer row uses footer-flash role');
    like($ff->[-1]{text}, qr/container is down/, 'compose: flash text occupies the footer');
    unlike($ff->[-1]{text}, qr/\[s\] shutdown-all/, 'compose: flash replaces the command legend');
    is(length($ff->[-1]{text}), 80, 'compose: flash footer kept exactly $cols');
    like(Dashboard::sgr_for_role('footer-flash'), qr/\e\[1;33m/, 'sgr: footer-flash -> bold yellow');

    my $nf = Dashboard::compose_frame(\%st, 12, 80);   # %st has no footer_flash
    like($nf->[-1]{text}, qr/\[c\] launch/, 'compose: no flash -> normal command legend');
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
# PART 2b — B3 (run / wakefulness) + B4 (backpack) panels
# ===========================================================================
{
    # Run panel: fresh lease + stay_awake -> active / holding; needs-you count.
    my @p = Dashboard::build_panels({ %st, busy_age => 30, stay_awake => 1, needs_you => 2 });
    my ($run) = grep { $_->{title} eq 'Run' } @p;
    ok($run, 'panels: a Run panel is present');
    my $rtext = join "\n", @{ $run->{lines} };
    like($rtext, qr/busy-lease.*active/,   'run: fresh lease + stay_awake -> active');
    like($rtext, qr/keep-awake.*holding/,  'run: stay_awake -> keep-awake holding');
    like($rtext, qr/needs you.*2 decision/,'run: needs-you count surfaced');
}
{
    # Stale lease (stay_awake false) -> idle / released; zero decisions -> none.
    my @p = Dashboard::build_panels({ %st, busy_age => 9999, stay_awake => 0, needs_you => 0 });
    my $rtext = join "\n", @{ (grep { $_->{title} eq 'Run' } @p)[0]->{lines} };
    like($rtext, qr/busy-lease.*idle/,     'run: stale lease -> idle');
    like($rtext, qr/keep-awake.*released/, 'run: not awake -> released (PC may sleep)');
    like($rtext, qr/needs you.*none/,      'run: zero decisions -> none');
}
{
    # No run at all (no busy_age) -> busy-lease none.
    my @p = Dashboard::build_panels({ %st });
    my $rtext = join "\n", @{ (grep { $_->{title} eq 'Run' } @p)[0]->{lines} };
    like($rtext, qr/busy-lease.*none/, 'run: absent lease -> none (no active run)');
}
{
    # Backpack panel present only when a backpack structure was gathered.
    my @no = grep { $_->{title} eq 'Backpack' } Dashboard::build_panels({ %st });
    ok(!@no, 'backpack: no panel without a gathered structure');

    my $bp = { total => 3, approved => 2, items => [
        { key => 'apt:jq',              approved => 1 },
        { key => 'apt:chromium',        approved => 0 },
        { key => 'npm-global:prettier', approved => 1 },
    ] };
    my ($bk) = grep { $_->{title} eq 'Backpack' } Dashboard::build_panels({ %st, backpack => $bp });
    ok($bk, 'backpack: panel present when gathered');
    my $btext = join "\n", @{ $bk->{lines} };
    like($btext, qr/3 item\(s\) - 2 approved \(\+\), 1 pending \(-\)/, 'backpack: header counts');
    like($btext, qr/\[\+\] apt:jq/,       'backpack: approved item marked +');
    like($btext, qr/\[-\] apt:chromium/,  'backpack: pending item marked -');
}
{
    # _backpack_lines: empty + cap-with-"+N more" (cap is never silent).
    my @empty = Dashboard::_backpack_lines({ total => 0 });
    like($empty[0], qr/no backpack/, 'backpack: total 0 -> "no backpack"');

    my @items = map { { key => "apt:p$_", approved => 1 } } (1 .. 20);
    my @l = Dashboard::_backpack_lines({ total => 20, approved => 20, items => \@items });
    like(join("\n", @l), qr/\.\.\. \+12 more/, 'backpack: caps at 8, shows "+12 more"');
    is(scalar(grep { /^\[\+\]/ } @l), 8, 'backpack: exactly 8 item lines shown');
}
{
    # End-to-end: compose_frame surfaces the new panels (and stays exactly sized).
    my $bp = { total => 1, approved => 0, items => [{ key => 'apt:jq', approved => 0 }] };
    my $f = Dashboard::compose_frame(
        { %st, busy_age => 5, stay_awake => 1, needs_you => 1, backpack => $bp }, 30, 80);
    is(scalar(grep { length($_->{text}) != 80 } @$f), 0, 'compose: new panels keep rows exactly $cols');
    my $joined = join "\n", map { $_->{text} } @$f;
    like($joined, qr/-- Run /,             'compose: Run panel title rendered');
    like($joined, qr/-- Backpack /,        'compose: Backpack panel title rendered');
    like($joined, qr/keep-awake.*holding/, 'compose: keep-awake state surfaced in a frame');
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
    is_deeply([Dashboard::dispatch_key("\e", '')],  ['', ''],         'key: lone ESC -> inert');
    is_deeply([Dashboard::dispatch_key('UP', '')],   ['scroll-up', ''],   'key: UP -> scroll-up');
    is_deeply([Dashboard::dispatch_key('DOWN', '')], ['scroll-down', ''], 'key: DOWN -> scroll-down');
    is_deeply([Dashboard::dispatch_key('k', '')],    ['scroll-up', ''],   'key: k -> scroll-up (alias)');
    is_deeply([Dashboard::dispatch_key('j', '')],    ['scroll-down', ''], 'key: j -> scroll-down (alias)');
    # scroll keys must not disturb a pending shutdown confirm (any key cancels)
    is_deeply([Dashboard::dispatch_key('DOWN', 'shutdown')], ['cancel-shutdown', ''],
        'key: arrow while shutdown-pending still cancels');
}

# activity_view: newest-first + up/down scroll window
{
    my $chrono = ['a', 'b', 'c', 'd'];   # oldest -> newest
    is_deeply(Dashboard::activity_view($chrono, 0), ['d','c','b','a'],
        'activity: offset 0 -> newest-first, full list');
    is_deeply(Dashboard::activity_view($chrono, 1), ['c','b','a'],
        'activity: offset 1 -> newest scrolled off the top');
    is_deeply(Dashboard::activity_view($chrono, 3), ['a'],
        'activity: offset at last -> oldest only');
    is_deeply(Dashboard::activity_view($chrono, 99), ['a'],
        'activity: offset clamps past the end');
    is_deeply(Dashboard::activity_view([], 0), [],
        'activity: empty list -> empty view');
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
    # A4: inject \&CORE::gmtime seam so these assertions stay deterministic once
    # recent_events converts timestamps to local-time.  The 3rd arg is currently
    # IGNORED by the 2-param implementation, so these tests remain green now and
    # will continue to pass after the seam is wired (gmtime == UTC == the ts value).
    my $ev = Dashboard::recent_events(\@lines, 10, \&CORE::gmtime);
    is(scalar(@$ev), 3, 'events: garbage + blank lines skipped');
    is($ev->[0], '10:00:01  launch_start', 'events: ts -> HH:MM:SS + type');
    like($ev->[1], qr/container_start exit=0/, 'events: exit field surfaced');
    like($ev->[2], qr/container_gone state=exited/, 'events: state field surfaced');

    my $last2 = Dashboard::recent_events(\@lines, 2, \&CORE::gmtime);
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
        term_size      => sub { ($args{cols} // 60, $args{rows} // 12) },
        gather         => sub { $eff{gathers}++; { project_name => 'demo', container => 'c1', status => ($args{status} // 'running'), events => ($args{events} // []), busy_age => $args{busy_age}, oauth_expires_at => $args{oauth_expires_at} } },
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
    # (E) container 'gone' from the heartbeat must NOT end the loop — the
    # dashboard stays open so the user can see the dead state and relaunch/quit.
    my $e = drive(keys => [(undef) x 30], hb_returns => sub { 'gone' },
                  status => 'exited', beat_interval => 1, max_ticks => 8);
    ok($e->{heartbeats} >= 2, 'loop: keeps heartbeating after "gone" (does not exit early)');
    is($e->{rc}, 0, 'loop: runs to max_ticks rather than a gone-exit');
    like($e->{out}, qr/not running|unreachable/, 'loop: surfaces a container-dead alert');
    is($e->{left}, 1, 'loop: restores the terminal exactly once at the end');
}

{
    # (D) [r] forces a FULL repaint (blank \e[2J + redraw). The first frame is
    # always a full clear; refresh produces a SECOND one.
    my $e = drive(keys => [undef, 'r', undef, 'q'], max_ticks => 50);
    my $clears = () = ($e->{out} =~ /\e\[2J/g);
    ok($clears >= 2, 'loop: refresh triggers an extra full-screen clear (hard refresh)');
}

{
    # Activity: newest-first, and DOWN/q scrolls without crashing (a tall enough
    # terminal so the Activity panel renders under the Sandbox/Run panels). The
    # newest-first + offset correctness itself is covered by activity_view tests.
    my @evs = ('10:00:01  launch_start', '10:00:02  container_start', '10:00:03  manager_ready');
    my $top = drive(keys => ['q'], events => \@evs, rows => 30, max_ticks => 50);
    like($top->{out}, qr/manager_ready/, 'activity: newest event is rendered');

    my $scrolled = drive(keys => ['DOWN', 'DOWN', undef, 'q'], events => \@evs, rows => 30, max_ticks => 50);
    is($scrolled->{rc}, 0, 'activity: DOWN scrolling runs cleanly to quit');
    like($scrolled->{out}, qr/launch_start/, 'activity: events still render while scrolling');
}

{
    # 'c' launches a session (spawn), then 'q'.
    my $e = drive(keys => ['c', 'q'], max_ticks => 50);
    is($e->{spawns}, 1, 'loop: c -> exactly one spawn');
    is($e->{rc}, 0, 'loop: then q exits');
}

{
    # 'c' on a NON-running container must NOT spawn (the connector window would
    # just open and vanish); instead the footer flashes the real recovery path.
    my $e = drive(keys => ['c', undef, 'q'], status => 'exited', max_ticks => 50);
    is($e->{spawns}, 0, 'loop: c on a dead container -> no doomed spawn');
    like($e->{out}, qr/container is down/, 'loop: c on a dead container -> footer flash shown');
    is($e->{rc}, 0, 'loop: then q exits');
}

{
    # 's' then 'y' fires the shutdown signal; 's' then 'n' does not.
    my $e1 = drive(keys => ['s', 'y', 'q'], max_ticks => 50);
    is($e1->{signals}, 1, 'loop: s,y -> shutdown signal written once');
    my $e2 = drive(keys => ['s', 'n', 'q'], max_ticks => 50);
    is($e2->{signals}, 0, 'loop: s,n -> shutdown cancelled (no signal)');
}

# ===========================================================================
# PART 9 — scroll fix: capacity, windowing, overflow hint, drain coalescing
# ===========================================================================

# _scroll_hint: ASCII-only (no unicode arrows — the renderer maps non-ASCII to ?)
is(Dashboard::_scroll_hint(0, 5), 'v 5 more below', 'hint: only-below shows v');
is(Dashboard::_scroll_hint(3, 0), '^ 3 more above', 'hint: only-above shows ^');
is(Dashboard::_scroll_hint(2, 4), '^ 2 more above    v 4 more below', 'hint: both directions');
is(Dashboard::_scroll_hint(0, 0), undef, 'hint: nothing hidden -> undef');
unlike(Dashboard::_scroll_hint(1, 1), qr/[^\x20-\x7E]/, 'hint: pure ASCII (width-safe)');

# activity_capacity: mirrors compose_frame's budget (deterministic for %st).
# %st has Sandbox(4 lines)+Run(3 lines) fixed = (1+4+1)+(1+3+1)=11; body=rows-2.
is(Dashboard::activity_capacity(\%st, 24, 80), 10, 'capacity: 24 rows, no alert -> 10 event rows');
is(Dashboard::activity_capacity({ %st, status => 'exited' }, 24, 80), 9,
   'capacity: a status alert costs one row');
is(Dashboard::activity_capacity(\%st, 12, 80), 0,
   'capacity: too short for the fixed panels -> 0 (no negative)');

# activity_window: fits / overflow / scroll / clamp.
my @D = ('e5','e4','e3','e2','e1');   # newest-first (already descending)
{
    my $w = Dashboard::activity_window(\@D, 0, 10);
    is_deeply($w->{lines}, \@D, 'window: everything fits -> all shown');
    is($w->{hint}, undef,       'window: fits -> no hint');
    is($w->{max_offset}, 0,     'window: fits -> max_offset 0 (no scroll)');
}
{
    my $w = Dashboard::activity_window(\@D, 0, 3);   # cap 3 -> visible 2 + hint
    is_deeply($w->{lines}, ['e5','e4'], 'window: overflow at top shows newest page');
    is($w->{hint}{text}, 'v 3 more below', 'window: top -> below-only hint');
    is($w->{hint}{role}, 'scrollhint',     'window: hint row is dim (scrollhint role)');
    is($w->{max_offset}, 3, 'window: max_offset = total - visible');
}
{
    my $w = Dashboard::activity_window(\@D, 1, 3);
    is_deeply($w->{lines}, ['e4','e3'], 'window: scrolled one down');
    is($w->{hint}{text}, '^ 1 more above    v 2 more below', 'window: middle -> both hints');
}
{
    my $w = Dashboard::activity_window(\@D, 99, 3);  # past the end -> clamp
    is($w->{offset}, 3, 'window: offset clamped to max_offset (no scrolling past end)');
    is_deeply($w->{lines}, ['e2','e1'], 'window: clamped view = the oldest page');
    is($w->{hint}{text}, '^ 3 more above', 'window: at the end -> above-only hint');
}
is_deeply(Dashboard::activity_window([], 0, 5)->{lines}, [], 'window: empty -> empty');
is_deeply(Dashboard::activity_window(\@D, 0, 0)->{lines}, [], 'window: zero capacity -> empty');

is(Dashboard::sgr_for_role('scrollhint'), "\e[2m", 'sgr: scrollhint -> dim (\e[2m, like the footer)');

{
    # The loop puts windowed event lines + a { text, role => scrollhint } hint
    # into state.events; compose_frame + render must carry that row through DIM
    # (the per-line-role plumbing). The windowing that PRODUCES the hint is
    # covered by activity_window above; the loop integration by the drain test.
    my %ov = (%st, events => [ 'evt-newest', { text => 'v 7 more below', role => 'scrollhint' } ]);
    my $f = Dashboard::compose_frame(\%ov, 24, 80);
    my ($hint) = grep { $_->{role} eq 'scrollhint' } @$f;
    ok($hint, 'compose: a scrollhint line in events renders as a scrollhint row');
    like($hint->{text}, qr/more below/, 'compose: the hint text is carried through');
    is(scalar(grep { length($_->{text}) != 80 } @$f), 0, 'compose: hint row keeps rows exactly $cols');
    my $rendered = Dashboard::render_frame(undef, $f, { color => 1 });
    like($rendered, qr/\e\[2m.*more below/, 'render: the hint row is emitted dim');
}

{
    # DRAIN coalescing: three DOWN keys in ONE tick advance the offset by three
    # (not one-per-tick). With 20 events on a 24-row terminal (capacity 10) the
    # list overflows, so after 3 DOWNs the panel shows "3 more above".
    my @evs = map { "evt$_" } (1 .. 20);
    my $e = drive(keys => ['DOWN','DOWN','DOWN', undef, 'q'],
                  events => \@evs, rows => 24, max_ticks => 50);
    is($e->{rc}, 0, 'drain: scrolls then quits cleanly');
    like($e->{out}, qr/3 more above/,
         'drain: 3 DOWNs in one tick coalesce -> offset advanced by 3');
}

# ===========================================================================
# PART 10 — scroll-responsiveness oracle (spec 01-scroll-responsiveness A–E)
#
# These tests encode the IMMUTABLE acceptance criteria.  They are written
# against the UNFIXED code and therefore FAIL for the right reason now.
# The implementer must satisfy them without weakening any assertion.
#
# Seam recap (Dashboard.pm::run):
#   $out      (:709)   — called once per render; we count calls per tick
#   $gather   (:702)   — must NOT fire on a pure-scroll tick (criterion B)
#   $sleep_for(:699)   — called once per tick (after the drain, before next iter);
#                        used as the tick-boundary signal for per-tick accounting
#
# Key encodings (dispatch_key, confirmed by PART 4 tests above):
#   'UP'   -> scroll-up    'DOWN' -> scroll-down
#   'k'    -> scroll-up    'j'    -> scroll-down
# ===========================================================================

# drive_per_tick: like drive(), but records the OUT-call count for each
# completed tick (indexed 0..N-1) so tests can assert per-tick render counts.
#
# sleep_for is the tick-end sentinel: it fires after the drain and after the
# max_ticks guard, so the delta of $frames at each sleep_for invocation is the
# number of $out calls that tick produced.  The final tick (where max_ticks fires
# the `last`) does NOT call sleep_for; its render count is inferred from the
# total minus the sum of recorded ticks.
#
# Returns a hashref with the same keys as drive() plus:
#   frames_per_tick => [ count_tick0, count_tick1, ... ]  (all completed ticks)
#   gathers_per_tick => [ count_tick0, count_tick1, ... ]
sub drive_per_tick {
    my (%args) = @_;
    my @keys       = @{ $args{keys} || [] };
    my $clock      = 1000;
    my %eff        = (heartbeats => 0, spawns => 0, signals => 0, gathers => 0, frames => 0);
    my $out_str    = '';
    my $prev_frames  = 0;
    my $prev_gathers = 0;
    my @fps;   # frames per tick (completed ticks only)
    my @gps;   # gathers per tick

    my $rc = Dashboard::run(
        beat_interval  => $args{beat_interval}  // 9999,
        state_interval => $args{state_interval} // 999,   # suppress mid-run gathers unless overridden
        tick_interval  => 0.25,
        color          => 0,
        max_ticks      => $args{max_ticks} // 5,
        now            => sub { $clock },
        sleep_for      => sub {
            $clock += $_[0];
            push @fps, $eff{frames}  - $prev_frames;
            push @gps, $eff{gathers} - $prev_gathers;
            $prev_frames  = $eff{frames};
            $prev_gathers = $eff{gathers};
        },
        read_key  => sub { @keys ? shift @keys : undef },
        term_size => sub { ($args{cols} // 60, $args{rows} // 24) },
        gather    => sub {
            $eff{gathers}++;
            {   project_name => 'demo',
                container    => 'c1',
                status       => 'running',
                events       => ($args{events} // []),
            }
        },
        heartbeat     => sub { 'ok' },
        spawn         => sub { $eff{spawns}++; undef },
        write_signals => sub { $eff{signals}++; 1 },
        enter_raw     => sub { },
        leave_raw     => sub { },
        keepawake     => sub { },
        out           => sub { $out_str .= $_[0]; $eff{frames}++ },
    );

    $eff{rc}             = $rc;
    $eff{out}            = $out_str;
    $eff{frames_per_tick}  = \@fps;
    $eff{gathers_per_tick} = \@gps;
    return \%eff;
}

# ---------------------------------------------------------------------------
# A — PROMPTNESS (THE KEY ASSERTION)
#
# A DOWN scroll key injected on tick 1 must cause an ADDITIONAL $out call
# within THAT SAME TICK — i.e. the scroll tick has >= 2 renders.
#
# Current code (render-before-drain): renders once per tick unconditionally,
# before the drain.  The scroll key is read in the drain AFTER the render, so
# the scroll effect is only visible on tick 2.  Therefore frames_per_tick[1]
# == 1 now.  This test FAILS until the post-drain re-render is added.
#
# Key sequence: [undef, 'DOWN', undef, undef]
#   Tick 0 drain: undef -> drain empty      (no scroll)
#   Tick 1 drain: 'DOWN' then undef -> DOWN drain ends (scroll fires)
#   Tick 2 drain: undef -> drain empty      (no scroll)
#   Tick 3: max_ticks fires (no sleep_for for this tick)
# The 20-event list ensures $activity_max > 0 so the DOWN actually mutates offset.
# ---------------------------------------------------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);
    my $e = drive_per_tick(
        keys       => [undef, 'DOWN', undef, undef],
        events     => \@evs,
        rows       => 24,
        max_ticks  => 4,
        state_interval => 999,   # gather only on tick 0 (last_state=undef gate)
    );
    # frames_per_tick[1] is the scroll tick (ticks 0/1/2 each call sleep_for; tick 3 exits)
    my $scroll_tick_renders = $e->{frames_per_tick}[1];
    cmp_ok($scroll_tick_renders, '>=', 2,
        'A: scroll-responsiveness: DOWN tick emits >=2 out calls (post-drain re-render)');
}

# ---------------------------------------------------------------------------
# B — NO GATHER ON PURE SCROLL
#
# The re-render after a scroll must reuse @all_events (already in scope).
# gather() must NOT be called during a tick where the only key is a scroll key.
#
# gathers_per_tick[0] == 1  (forced on first tick because last_state=undef)
# gathers_per_tick[1] == 0  (scroll tick — no new gather allowed)
# ---------------------------------------------------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);
    my $e = drive_per_tick(
        keys       => [undef, 'DOWN', undef, undef],
        events     => \@evs,
        rows       => 24,
        max_ticks  => 4,
        state_interval => 999,
    );
    is($e->{gathers_per_tick}[1], 0,
        'B: pure-scroll tick does NOT call the gather seam');
}

# ---------------------------------------------------------------------------
# C — GATHER CADENCE UNCHANGED
#
# A tick past state_interval with NO input must still gather exactly once.
# The scroll path must not perturb the gather timer.
#
# Setup: state_interval => 1, tick_interval => 0.25 (so sleep_for adds 0.25 to
# the clock each tick).  After 4 ticks (4 * 0.25 = 1s) the clock has advanced
# 1s from the initial gather, so tick 4 fires a gather.  Verify gathers_per_tick
# for a quiet (no-key) run: tick 0 gathers (last_state=undef), ticks 1-3 don't,
# tick 4 does (1s elapsed).
#
# Drive 5 completed ticks (max_ticks=6: ticks 0..4 each call sleep_for,
# tick 5 exits via max_ticks without sleep_for).
# ---------------------------------------------------------------------------
{
    my $e = drive_per_tick(
        keys           => [],       # no input at all
        rows           => 24,
        max_ticks      => 6,
        state_interval => 1,        # gather when clock advances >= 1s
    );
    my @gpt = @{ $e->{gathers_per_tick} };
    is($gpt[0], 1, 'C: tick 0 gathers (last_state=undef gate fires unconditionally)');
    is($gpt[1], 0, 'C: tick 1 does NOT gather (state_interval not elapsed)');
    is($gpt[2], 0, 'C: tick 2 does NOT gather');
    is($gpt[3], 0, 'C: tick 3 does NOT gather');
    is($gpt[4], 1, 'C: tick 4 gathers (1s elapsed -> state_interval fires again)');
}

# ---------------------------------------------------------------------------
# D — NO EXTRA RENDER WITHOUT SCROLL
#
# A tick with no scroll input emits EXACTLY ONE $out call.
# Guards against an "always re-render" regression: the re-render must be gated
# strictly on a scroll-dirty flag, not on every tick unconditionally.
#
# frames_per_tick for a quiet-key run must be 1 for every completed tick.
# ---------------------------------------------------------------------------
{
    my $e = drive_per_tick(
        keys      => [],    # no input
        rows      => 24,
        max_ticks => 4,
        state_interval => 999,
    );
    my @fps = @{ $e->{frames_per_tick} };
    # All completed ticks (those that called sleep_for) must have exactly 1 render.
    my @bad = grep { $_ != 1 } @fps;
    is(scalar(@bad), 0,
        'D: no-input ticks emit exactly 1 out call each (no spurious extra render)');
}

# ---------------------------------------------------------------------------
# E — $prev BASELINE AFTER DOUBLE RENDER
#
# After a scroll tick's double render, the NEXT tick's diff must be computed
# against the re-rendered frame (the second one), NOT the pre-drain frame.
#
# The landmine (scout risk 3): if $prev is NOT updated after the re-render,
# the next tick's render_frame diffs against a stale baseline and emits wrong
# row updates.
#
# Observable proxy: with no state change between tick 1 (scroll) and tick 2
# (no input, no gather), the tick-2 render must be a DIFF render (not a
# full-clear).  If $prev is stale (not updated after the re-render), the
# baseline mismatch causes wrong/extra row repaints.
#
# We assert this at the $out seam level: if the fix is correct, the TOTAL
# number of row-move escapes (\e[R;1H) in the THIRD render (tick-2's single
# render) must be 0 — because the frame content is identical to the re-rendered
# frame from tick 1 (same events, same offset, same state).
#
# Implementation: capture each individual $out call in sequence; inspect the
# third call (index 2) — i.e. render #3 — for row-repaint escapes.
# With the FIX the sequence is: render#1(tick0), render#2(tick1-primary),
# render#3(tick1-scroll-rerender), render#4(tick2) — so render#4 should have 0
# row moves.
# Without the FIX there is no render#3, so render#3==tick2's render, which
# diffs against tick1-primary ($prev still the pre-drain frame) — but since
# offset was also not updated in the render, the frame IS the same as tick0's
# render, so render#3 also has 0 row moves.  This means E cannot produce a
# false-positive failure right now; it passes vacuously (or with the fix).
# We therefore frame E as a NON-regression assertion: the number of row moves
# in the first quiet-tick render after a scroll is 0 — correct with or without
# the fix, but catches a broken $prev update path.
#
# The critical non-vacuous E test: with the fix, frames_per_tick[1] == 2 AND
# the post-scroll tick still shows 0 spurious row repaints.  We capture all
# $out calls individually to inspect.
# ---------------------------------------------------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);
    my @renders;    # each individual $out call, in order
    my $clock = 1000;
    my %eff = (gathers => 0, frames => 0);
    my @keys_e = (undef, 'DOWN', undef, undef);

    Dashboard::run(
        beat_interval  => 9999,
        state_interval => 999,
        tick_interval  => 0.25,
        color          => 0,
        max_ticks      => 4,
        now            => sub { $clock },
        sleep_for      => sub { $clock += $_[0]; },
        read_key       => sub { @keys_e ? shift @keys_e : undef },
        term_size      => sub { (60, 24) },
        gather         => sub {
            $eff{gathers}++;
            { project_name => 'demo', container => 'c1', status => 'running',
              events => \@evs }
        },
        heartbeat     => sub { 'ok' },
        spawn         => sub { undef },
        write_signals => sub { 1 },
        enter_raw     => sub { },
        leave_raw     => sub { },
        keepawake     => sub { },
        out           => sub { push @renders, $_[0]; $eff{frames}++ },
    );

    # With the fix: renders are [tick0, tick1-primary, tick1-rerender, tick2].
    # Without the fix: renders are [tick0, tick1, tick2, tick3].
    # In both cases the LAST render in a quiet, no-gather tick should have 0 row moves.
    # The real guard: the render IMMEDIATELY AFTER the scroll tick must have
    # 0 row-repaint escapes (the diff sees no change vs the last emitted frame).
    #
    # We target the render that follows the scroll event.  With the fix, that is
    # renders[-1] (tick2's render, index 3 in a 4-render sequence).
    # Without the fix, that is renders[2] (tick2's render, no re-render existed).
    # We use frames_per_tick to locate it: the render right after the scroll tick.
    my $total = scalar @renders;
    ok($total >= 3, 'E: at least 3 out calls produced (enough to inspect post-scroll render)');

    # The last render in the captured sequence is the one for the quiet tick
    # that follows the scroll tick (tick2, no scroll, no gather).
    my $post_scroll_render = $renders[-1];
    my @row_moves = ($post_scroll_render =~ /\e\[\d+;1H/g);
    is(scalar(@row_moves), 0,
        'E: post-scroll quiet-tick render has 0 row repaints (prev baseline is current, not stale)');
}

# ===========================================================================
# PART 11 — 01-dashboard-localtime-oauth acceptance criteria
# ===========================================================================

# ---------------------------------------------------------------------------
# A1–A3  _event_time / recent_events with a $localtime_fn seam
#
# _event_time($iso_ts, $localtime_fn) does NOT exist yet.  We guard every call
# with an eval{} so a missing sub causes a per-test FAIL, not a file-level die.
#
# The seams are closures over a fixed epoch offset (CORE::gmtime == UTC, so
# A1 expects unchanged output; +2h and -5h offsets shift the HH:MM:SS).
#
# "2026-06-24T10:00:01Z" is epoch 1750759201 (UTC 10:00:01).
# A gmtime seam returns the UTC breakdown, so HH:MM:SS is still "10:00:01".
# A +2h seam shifts the epoch forward 7200s before formatting -> "12:00:01".
# A -5h seam shifts the epoch back 18000s -> "05:00:01".
# ---------------------------------------------------------------------------
{
    my $epoch_10 = 1750759201;   # 2026-06-24T10:00:01Z

    # gmtime seam: returns UTC breakdown unchanged (== A1 oracle)
    my $gmtime_seam = sub { CORE::gmtime($_[0]) };

    # +2h seam: pretend the local clock is 2 hours ahead of UTC
    my $plus2h_seam = sub {
        my @lt = CORE::gmtime($_[0] + 7200);
        return @lt;
    };

    # -5h seam: pretend the local clock is 5 hours behind UTC
    my $minus5h_seam = sub {
        my @lt = CORE::gmtime($_[0] - 18000);
        return @lt;
    };

    my $ts = '2026-06-24T10:00:01Z';

    # A1: gmtime seam -> UTC unchanged -> "10:00:01"
    my $a1 = eval { Dashboard::_event_time($ts, $gmtime_seam) };
    is($a1, '10:00:01',
        'A1: _event_time with gmtime seam (UTC offset 0) -> 10:00:01');

    # A2: +2h seam -> "12:00:01"
    my $a2 = eval { Dashboard::_event_time($ts, $plus2h_seam) };
    is($a2, '12:00:01',
        'A2: _event_time with +2h localtime seam -> 12:00:01');

    # A3: -5h seam -> "05:00:01"
    my $a3 = eval { Dashboard::_event_time($ts, $minus5h_seam) };
    is($a3, '05:00:01',
        'A3: _event_time with -5h localtime seam -> 05:00:01');

    # A1 via recent_events 3rd-param seam (end-to-end path): parse the same ts
    # through the seam and confirm the event string carries the local HH:MM:SS.
    my @lines_a1 = ('{"ts":"2026-06-24T10:00:01Z","type":"launch_start","pid":1}');
    my $ev_a1 = eval { Dashboard::recent_events(\@lines_a1, 1, $gmtime_seam) };
    if ($ev_a1) {
        like($ev_a1->[0], qr/^10:00:01\b/,
            'A1 (recent_events): gmtime seam preserves UTC HH:MM:SS in event string');
    } else {
        fail('A1 (recent_events): recent_events 3-arg form not yet wired (expected failure)');
    }

    # A2 via recent_events
    my $ev_a2 = eval { Dashboard::recent_events(\@lines_a1, 1, $plus2h_seam) };
    if ($ev_a2) {
        like($ev_a2->[0], qr/^12:00:01\b/,
            'A2 (recent_events): +2h seam yields 12:00:01 in event string');
    } else {
        fail('A2 (recent_events): recent_events 3-arg seam not yet wired (expected failure)');
    }

    # A3 via recent_events
    my $ev_a3 = eval { Dashboard::recent_events(\@lines_a1, 1, $minus5h_seam) };
    if ($ev_a3) {
        like($ev_a3->[0], qr/^05:00:01\b/,
            'A3 (recent_events): -5h seam yields 05:00:01 in event string');
    } else {
        fail('A3 (recent_events): recent_events 3-arg seam not yet wired (expected failure)');
    }
}

# ---------------------------------------------------------------------------
# B1–B5  fmt_oauth($remaining_secs)
#
# fmt_oauth does NOT exist yet.  Each call is wrapped in eval{} so the missing
# sub produces a per-assertion FAIL rather than aborting the file.
# ---------------------------------------------------------------------------
{
    my $have_fmt_oauth = Dashboard->can('fmt_oauth');

    # B1: undef -> 'unknown'
    my $b1 = eval { Dashboard::fmt_oauth(undef) };
    is($b1, 'unknown',
        'B1: fmt_oauth(undef) eq "unknown"');

    # B2: negative -> 'EXPIRED'
    my $b2 = eval { Dashboard::fmt_oauth(-5) };
    is($b2, 'EXPIRED',
        'B2: fmt_oauth(-5) eq "EXPIRED"');

    # B3: zero -> 'EXPIRED'
    my $b3 = eval { Dashboard::fmt_oauth(0) };
    is($b3, 'EXPIRED',
        'B3: fmt_oauth(0) eq "EXPIRED"');

    # B4: 3h12m -> 'expires in 3h12m'
    my $b4 = eval { Dashboard::fmt_oauth(3*3600 + 12*60) };
    is($b4, 'expires in 3h12m',
        'B4: fmt_oauth(3*3600+12*60) eq "expires in 3h12m"');

    # B5: sub-minute -> 'expires in 45s'
    my $b5 = eval { Dashboard::fmt_oauth(45) };
    is($b5, 'expires in 45s',
        'B5: fmt_oauth(45) eq "expires in 45s"');

    # B-ascii: all non-undef returns are ASCII-only (no multi-byte chars)
    for my $secs (-5, 0, 45, 3*3600+12*60) {
        my $r = eval { Dashboard::fmt_oauth($secs) };
        if (defined $r) {
            unlike($r, qr/[^\x20-\x7E]/,
                "B-ascii: fmt_oauth($secs) returns ASCII-only string");
        }
    }
}

# ---------------------------------------------------------------------------
# C1  activity_capacity with oauth_remaining defined -> one extra fixed row
#
# When oauth_remaining is defined, _fixed_panels gains an oauth line in the
# Sandbox panel, reducing the activity row budget by 1 (from 10 to 9).
# C2 (undef -> 10) is already green at line 641 above; this test encodes C1.
# ---------------------------------------------------------------------------
{
    my %st_oauth = (%st, oauth_remaining => 3*3600 + 12*60);
    is(Dashboard::activity_capacity(\%st_oauth, 24, 80), 9,
        'C1: oauth_remaining defined -> Sandbox gains an oauth line -> capacity 9 (not 10)');
}

# ---------------------------------------------------------------------------
# D  Loop integration: oauth_expires_at in the gather hash -> "expires in 3h12m"
#    appears in the rendered Sandbox panel output.
#
# drive() already threads oauth_expires_at from %args into the gather hash.
# With seed clock=1000 and oauth_expires_at=12520, run() must compute
# oauth_remaining = 12520 - 1000 = 11520 = 3*3600+12*60 and render
# "expires in 3h12m" in the Sandbox panel.
# ---------------------------------------------------------------------------
{
    my $e = drive(
        keys           => ['q'],
        max_ticks      => 50,
        rows           => 30,
        oauth_expires_at => 12520,   # 1000 + 3*3600 + 12*60
    );
    is($e->{rc}, 0, 'D: loop with oauth_expires_at exits cleanly');
    like($e->{out}, qr/expires in 3h12m/,
        'D: rendered Sandbox panel contains "expires in 3h12m" when oauth_expires_at set');
}

done_testing();
