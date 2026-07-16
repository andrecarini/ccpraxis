# Dashboard.pm — the raw-ANSI TUI dashboard framework for `claude-sandbox` (B2).
#
# Decision #19: `claude-sandbox` (the only user-typed form) always lands HERE —
# a live dashboard, not a scrolling log. The dashboard is the manager window: it
# holds the container alive via the heartbeat (over the injected podman-exec
# seam) and exposes two hotkeys (Decision #18):
#   [c] launch-claude   — spawn a NEW terminal window running `claude-sandbox
#                         --session <project>` (the existing connector + session
#                         picker), with a wt.exe -> `start` -> in-window fallback
#                         ladder (Decision #19).
#   [s] shutdown-all    — write the fleet-wide graceful-shutdown signal
#                         (`runs/.shutdown` in every blueprint, consumed by the
#                         A4 gate).
#
# This module is split into a PURE core (layout / frame composition / render
# diff / key dispatch / spawn-argv / signal-path derivation — all unit-tested in
# tests/t/25-dashboard.t with no terminal) and a thin seam-injected loop
# (`run`). Every side effect the loop performs — heartbeat touch, container
# inspect, state gather, key read, terminal size, spawn, signal write, raw-mode
# enter/leave, output — is an injected coderef, so the loop itself is driven by
# the test harness with a fake clock and a scripted key queue.
#
# RENDER MODEL (the B0 carry-forward / flicker fix): never `\e[2J` per frame.
# Clear once on a full redraw (first frame or a resize), then update only the
# rows whose text changed via `\e[<row>;1H` + text + `\e[K`, with the whole burst
# wrapped in synchronized-output `\e[?2026h` … `\e[?2026l`. Composed lines are
# plain ASCII padded to EXACTLY the terminal width (so `length` == display width
# on the Windows/André console — no box-drawing width pitfalls); color is applied
# at render time by row role. Rich panels / box-drawing are B3/B4's job.
#
# Non-TTY / no-Term::ReadKey fallback is decided by `decide_mode`; launcher.pl
# keeps its proven plain heartbeat loop for that case (graceful degradation,
# Decision #19 / B0).
package Dashboard;
use strict;
use warnings;
use JSON::PP ();
use File::Spec ();
use Time::Local ();

# ===========================================================================
# PURE CORE
# ===========================================================================

# decide_mode($is_tty, $readkey_ok, $force_plain) -> 'tui' | 'plain'
# The dashboard runs as a real TUI only on an interactive terminal with
# Term::ReadKey available and not explicitly forced off. Anything else (piped
# output, a dumb terminal, CCPRAXIS_NO_TUI) degrades to the plain loop.
sub decide_mode {
    my ($is_tty, $readkey_ok, $force_plain) = @_;
    return 'plain' if $force_plain;
    return 'plain' unless $is_tty;
    return 'plain' unless $readkey_ok;
    return 'tui';
}

# fmt_age($secs) -> compact human duration ("12s", "3m", "1h04m", "2d03h").
# undef / negative -> "—".
sub fmt_age {
    my ($s) = @_;
    return 'n/a' if !defined $s;
    $s = int($s);
    return 'n/a' if $s < 0;
    return "${s}s"               if $s < 60;
    my $m = int($s / 60);
    return "${m}m"               if $m < 60;
    my $h = int($m / 60); $m %= 60;
    return sprintf('%dh%02dm', $h, $m) if $h < 24;
    my $d = int($h / 24); $h %= 24;
    return sprintf('%dd%02dh', $d, $h);
}

# fmt_hms($secs) -> "Xh Ym Zs" with all three components always shown
# (e.g. "0h 2m 13s", "2h 5m 9s"). undef / negative -> "n/a". Used for uptime,
# where the explicit hour/minute/second breakdown reads clearer than fmt_age's
# compact form. ASCII-only, so length() == display width (the render invariant).
sub fmt_hms {
    my ($s) = @_;
    return 'n/a' if !defined $s;
    $s = int($s);
    return 'n/a' if $s < 0;
    my $h = int($s / 3600); $s %= 3600;
    my $m = int($s / 60);   $s %= 60;
    return sprintf('%dh %dm %ds', $h, $m, $s);
}

# fmt_oauth($remaining_secs) -> ASCII-only status string for the oauth line.
# undef (no token yet — sandboxes now own an independent login) ->
# 'not logged in (run /login)'; <= 0 -> 'EXPIRED'; > 0 -> 'expires in <fmt_age>'.
sub fmt_oauth {
    my ($s) = @_;
    return 'not logged in (run /login)' if !defined $s;
    return 'EXPIRED' if $s <= 0;
    return 'expires in ' . fmt_age($s);
}

# _event_time($iso_ts, $localtime_fn) -> 'HH:MM:SS' in local time.
# Parses YYYY-MM-DDThh:mm:ssZ to epoch via Time::Local::timegm (UTC), then
# applies $localtime_fn (default real localtime) to get local breakdown.
sub _event_time {
    my ($ts, $localtime_fn) = @_;
    $localtime_fn ||= sub { localtime($_[0]) };
    return '00:00:00' unless defined $ts && $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/;
    my ($yr, $mo, $dy, $h, $m, $sec) = ($1, $2, $3, $4, $5, $6);
    my $epoch = eval { Time::Local::timegm($sec, $m, $h, $dy, $mo - 1, $yr - 1900) };
    return '00:00:00' unless defined $epoch;
    my @lt = $localtime_fn->($epoch);
    return sprintf('%02d:%02d:%02d', $lt[2], $lt[1], $lt[0]);
}

# clip_pad($str, $w) -> exactly $w characters: truncated if longer, space-padded
# if shorter. $w <= 0 -> ''. The invariant the renderer relies on: every
# composed row is exactly the terminal width wide.
sub clip_pad {
    my ($s, $w) = @_;
    $w = 0 if !defined $w || $w < 0;
    $s = '' if !defined $s;
    $s = substr($s, 0, $w) if length($s) > $w;
    $s .= ' ' x ($w - length($s)) if length($s) < $w;
    return $s;
}

# _safe($s) -> $s with every byte outside printable ASCII (0x20-0x7E) mapped to
# '?'. This is the invariant guard the whole render relies on: composed rows are
# measured/padded with length()/substr() (byte ops), so a multi-byte UTF-8 char
# (an `André`/non-ASCII project name) or a control byte (a newline smuggled into
# a B1 log field) would make a row's byte length differ from its display width
# and corrupt the diff. Mapping each offending byte 1:1 to a single-column '?'
# keeps length() == display columns for ALL dynamic content. (Fixes the C3 width
# bug and the H3 control-char-in-log-field bug at one chokepoint.)
sub _safe {
    my ($s) = @_;
    return '' if !defined $s;
    $s =~ s/[^\x20-\x7E]/?/g;
    return $s;
}

# _justify($left, $right, $w) -> $left ... $right filling exactly $w. If they
# don't both fit (plus a gap), the right side is dropped and the left clipped.
sub _justify {
    my ($left, $right, $w) = @_;
    $left  = '' if !defined $left;
    $right = '' if !defined $right;
    if (length($left) + length($right) + 1 <= $w) {
        my $gap = $w - length($left) - length($right);
        return $left . (' ' x $gap) . $right;
    }
    return clip_pad($left, $w);
}

# _fixed_panels(\%state) -> the panels ABOVE the scrollable Activity panel
# (Sandbox, Run, Backpack). Split out so activity_capacity can measure their
# total height to compute how many event rows the Activity panel has left.
sub _fixed_panels {
    my ($s) = @_;
    $s ||= {};
    my @p;

    my @sb;
    push @sb, 'project   : ' . (defined $s->{project_name} ? $s->{project_name} : '?');
    push @sb, 'container : ' . (defined $s->{container} ? $s->{container} : '?')
            . '  [' . (defined $s->{status} ? $s->{status} : '?') . ']';
    push @sb, 'heartbeat : ' . (defined $s->{beat_age} ? fmt_age($s->{beat_age}) . ' ago' : 'n/a');
    push @sb, 'uptime    : ' . (defined $s->{uptime}   ? fmt_hms($s->{uptime})        : 'n/a');
    # Always shown: a fresh sandbox has no token until an in-container /login
    # (each sandbox owns an independent grant), and "not logged in" is exactly
    # the actionable cue the user needs — so never silently drop the line.
    push @sb, 'oauth     : ' . fmt_oauth($s->{oauth_remaining});
    push @p, { title => 'Sandbox', lines => \@sb };

    # B3: run + wakefulness state. busy-lease freshness (the orchestrator only
    # refreshes /tmp/.butler-busy while there's active work / pending auto-resume)
    # drives keep-awake; `stay_awake` is the launcher's single computed decision
    # (KeepAwake::should_stay_awake) so this view never re-derives the threshold.
    my @run;
    my $busy = !defined $s->{busy_age} ? 'none (no active run)'
             : $s->{stay_awake}        ? 'active (' . fmt_age($s->{busy_age}) . ' ago)'
             :                           'idle ('   . fmt_age($s->{busy_age}) . ' ago)';
    push @run, 'busy-lease : ' . $busy;
    push @run, 'keep-awake : ' . ($s->{stay_awake} ? 'holding (PC stays awake)'
                                                    : 'released (PC may sleep)');
    my $ny = (defined $s->{needs_you} && $s->{needs_you} =~ /^\d+$/) ? $s->{needs_you} : 0;
    push @run, 'needs you  : ' . ($ny > 0 ? "$ny decision(s) waiting" : 'none');
    push @p, { title => 'Run', lines => \@run };

    # B4: backpack view — per-item approval state (#21). Present only when the
    # launcher gathered a backpack structure for this project.
    if (ref $s->{backpack} eq 'HASH') {
        push @p, { title => 'Backpack', lines => [ _backpack_lines($s->{backpack}) ] };
    }
    return @p;
}

# build_panels(\%state) -> ordered list of { title => str, lines => [line,...] },
# where a line is a plain string OR { text, role } (the Activity panel's scroll
# hint uses the latter to render dim). The Activity panel is always LAST (the
# scrollable, height-flexible one); the loop fills state.events with the
# already-windowed lines + optional hint (see activity_window).
sub build_panels {
    my ($s) = @_;
    $s ||= {};
    my @p = _fixed_panels($s);
    my $ev = (ref $s->{events} eq 'ARRAY') ? $s->{events} : [];
    push @p, { title => 'Recent activity',
               lines => (@$ev ? [@$ev] : ['(no events yet)']) };
    return @p;
}

# _backpack_lines(\%backpack) -> body lines for the B4 panel. {total, approved,
# items=>[{key, approved}]}. Caps the per-item list (the panel is a summary; the
# full review is #21's job) and shows "+N more" so the cap is never silent.
sub _backpack_lines {
    my ($bp) = @_;
    $bp ||= {};
    my $total = (defined $bp->{total} && $bp->{total} =~ /^\d+$/) ? $bp->{total} : 0;
    return ('(no backpack for this project)') if $total == 0;
    my $appr = (defined $bp->{approved} && $bp->{approved} =~ /^\d+$/) ? $bp->{approved} : 0;
    my $pend = $total - $appr; $pend = 0 if $pend < 0;
    my @out = ("$total item(s) - $appr approved (+)"
               . ($pend > 0 ? ", $pend pending (-)" : ''));
    my $items = (ref $bp->{items} eq 'ARRAY') ? $bp->{items} : [];
    my $cap = 8;
    my $shown = 0;
    for my $it (@$items) {
        last if $shown >= $cap;
        my $mark = $it->{approved} ? '+' : '-';
        push @out, "[$mark] " . (defined $it->{key} ? $it->{key} : '?');
        $shown++;
    }
    my $more = scalar(@$items) - $shown;
    push @out, "... +$more more (see /backpack:list)" if $more > 0;
    return @out;
}

# _title_line / _footer_line / _panel_title_line — single rows, exactly $cols.
sub _title_line {
    my ($s, $cols) = @_;
    my $left = 'ccpraxis sandbox';
    $left .= ' - ' . _safe($s->{project_name}) if defined $s->{project_name} && length $s->{project_name};
    my $ctr = _safe(defined $s->{container} ? $s->{container} : '');
    my $st  = _safe(defined $s->{status}    ? $s->{status}    : '?');
    my $right = length $ctr ? "$ctr [$st]" : "[$st]";
    return _justify($left, $right, $cols);
}

sub _footer_line {
    my ($s, $cols) = @_;
    my $pending = defined $s->{pending} ? $s->{pending} : '';
    my $legend;
    if ($pending eq 'shutdown') {
        $legend = 'Shut down ALL coordinators in this project? [y] confirm   [any other] cancel';
    } elsif (defined $s->{footer_flash} && length $s->{footer_flash}) {
        $legend = ' ' . $s->{footer_flash};   # transient [c]-on-dead-container notice
    } else {
        $legend = ' [c] launch   [s] shutdown-all   [up/down] scroll   [r] refresh   [q] quit';
    }
    return clip_pad($legend, $cols);
}

# _alert_line($msg, $cols) -> a full-width banner row (rendered red via the
# 'alert' role). Used for the backpack-install-failure warning so it can't be
# lost behind the alt-screen the way the pre-dashboard stdout warning was.
sub _alert_line {
    my ($msg, $cols) = @_;
    return clip_pad('  !! ' . _safe(defined $msg ? $msg : ''), $cols);
}

# _status_alert(\%state) -> a one-line banner string when the container is no
# longer running or no longer reachable, else undef. This drives the "dashboard
# stays open after the container dies" behavior: the loop no longer exits on
# container death, so this makes the dead/unreachable state loud and tells the
# user what to do. 'unknown' = inspect couldn't read the container (podman down
# or the host slept); empty/running/created/restarting are healthy-or-transient
# and stay quiet.
#
# The dead-state banner deliberately does NOT offer [c]: [c] only spawns a
# connector (`podman exec` into a LIVE container), so on a dead container it
# opens a Windows Terminal that instantly closes (the exec has nothing to attach
# to). The real relaunch is to quit ([q]) and re-run `claude-sandbox`, which
# `podman start`s the exited container — so that is what the banner points at.
# [r] retry stays for the 'unknown'/unreachable case, where the same container
# may simply reappear once podman/the host is back.
sub _status_alert {
    my ($s) = @_;
    $s ||= {};
    my $st = defined $s->{status} ? lc $s->{status} : '';
    if ($s->{container_gone}) {
        return ($st && $st ne 'unknown')
            ? "container is not running ($st) - [q] quit, then re-run claude-sandbox to relaunch"
            : 'container unreachable - [r] retry or [q] quit';
    }
    return undef if $st eq '' || $st eq '?' || $st eq 'running'
                 || $st eq 'created' || $st eq 'restarting';
    return 'container unreachable (podman down or host asleep) - [r] retry, [q] quit'
        if $st eq 'unknown';
    return "container is $st (not running) - [q] quit, then re-run claude-sandbox to relaunch";
}

# can_launch(\%state) -> 1 iff the container is in a state where the [c] hotkey
# can actually attach a connector. [c] spawns `claude-sandbox --session`, which
# `podman exec`s into the container — and exec needs a RUNNING container. On any
# other state (exited / stopped / created / restarting / gone / not-yet-known)
# the exec instantly fails and the spawned Windows Terminal vanishes, so the
# loop SUPPRESSES the spawn and flashes launch_blocked_msg() instead. This is
# _status_alert's "is it alive?" judgement seen from the launch side.
sub can_launch {
    my ($s) = @_;
    $s ||= {};
    return 0 if $s->{container_gone};
    my $st = defined $s->{status} ? lc $s->{status} : '';
    return $st eq 'running' ? 1 : 0;
}

# launch_blocked_msg() -> the transient footer notice shown when [c] is pressed
# on a non-running container (see can_launch). Names the real relaunch path so
# the key never feels dead. The "container is down" lead is deliberately
# distinct from the persistent _status_alert banner wording, so the two never
# read as one duplicated line and each is independently greppable.
sub launch_blocked_msg {
    return 'container is down - [q] quit, then re-run claude-sandbox to relaunch';
}

sub _panel_title_line {
    my ($title, $cols) = @_;
    my $s = '-- ' . _safe($title) . ' ';
    $s .= '-' x ($cols - length $s) if length($s) < $cols;
    return clip_pad($s, $cols);
}

# _body_rows(\%state, $cols, $maxh) -> up to $maxh { text, role } rows: each
# panel rendered as a title line, its (indented) body lines, then a blank
# separator, clipped to $maxh.
sub _body_rows {
    my ($state, $cols, $maxh) = @_;
    my @out;
    return @out if $maxh < 1;
    for my $p (build_panels($state)) {
        last if @out >= $maxh;
        push @out, { text => _panel_title_line($p->{title}, $cols), role => 'panel-title' };
        for my $ln (@{ $p->{lines} || [] }) {
            last if @out >= $maxh;
            # A line is a plain string (role 'body') or { text, role } — the
            # latter lets the Activity panel render its scroll hint dim.
            my ($txt, $role) = ref $ln eq 'HASH'
                ? ($ln->{text}, $ln->{role} // 'body') : ($ln, 'body');
            push @out, { text => clip_pad('  ' . _safe($txt), $cols), role => $role };
        }
        push @out, { text => clip_pad('', $cols), role => 'blank' } if @out < $maxh;
    }
    @out = @out[0 .. $maxh - 1] if @out > $maxh;
    return @out;
}

# compose_frame(\%state, $rows, $cols) -> arrayref of EXACTLY $rows
# { text => <exactly $cols chars>, role } cells. Layout: title row, a body
# region of stacked panels, and a footer legend reserved on the last row.
# Degrades cleanly to tiny terminals (1xN -> title only; 2xN -> title+footer).
sub compose_frame {
    my ($state, $rows, $cols) = @_;
    $state ||= {};
    $rows = 0 if !defined $rows || $rows < 0;
    $cols = 1 if !defined $cols || $cols < 1;
    my @frame;
    return \@frame if $rows < 1;

    push @frame, { text => _title_line($state, $cols), role => 'title' };
    return \@frame if $rows == 1;

    my $footer_role = 'footer';
    if (defined $state->{pending} && $state->{pending} eq 'shutdown') {
        $footer_role = 'footer-alert';
    } elsif (defined $state->{footer_flash} && length $state->{footer_flash}) {
        $footer_role = 'footer-flash';   # transient launch-blocked notice
    }
    my $footer = { text => _footer_line($state, $cols), role => $footer_role };

    if ($rows == 2) {
        push @frame, $footer;
        return \@frame;
    }

    # Optional alert banner(s) directly under the title: a container that is no
    # longer running / reachable (so the dashboard staying open after a container
    # death is obvious and actionable) and/or a backpack-install failure. Each
    # needs room for title + alert + >=1 body + footer; on a tiny terminal we
    # drop the lowest-priority alerts (install_warning first) rather than crowd
    # out the body. The launcher surfaces these where a pre-dashboard stdout
    # warning would otherwise be wiped by the alt-screen.
    my @msgs = _alert_msgs($state, $rows);
    my @alert = map { { text => _alert_line($_, $cols), role => 'alert' } } @msgs;

    my $body_h = $rows - 2 - scalar(@alert);
    my @body = _body_rows($state, $cols, $body_h);
    while (@body < $body_h) {
        push @body, { text => clip_pad('', $cols), role => 'blank' };
    }
    push @frame, @alert, @body;
    push @frame, $footer;
    return \@frame;
}

# sgr_for_role($role) -> the SGR escape for a row role (color mode only).
sub sgr_for_role {
    my ($role) = @_;
    $role = '' if !defined $role;
    return "\e[1;36m"     if $role eq 'title';        # bold cyan
    return "\e[1m"        if $role eq 'panel-title';  # bold
    return "\e[2m"        if $role eq 'footer';       # dim
    return "\e[1;33;41m"  if $role eq 'footer-alert'; # bold yellow on red
    return "\e[1;33m"     if $role eq 'footer-flash'; # bold yellow — transient notice
    return "\e[1;37;41m"  if $role eq 'alert';        # bold white on red (banner)
    return "\e[2m"        if $role eq 'scrollhint';   # dim — like the footer command row
    return '';
}

# _row_ansi($row, \%cell, $color) -> the ANSI to (re)draw one 1-based row.
# The line is cleared (\e[K) BEFORE the text, never after: every composed row is
# exactly $cols wide, so writing it parks the cursor in the last cell (deferred
# auto-wrap). A trailing \e[K would then erase that last cell — invisibly on a
# dash separator, but visibly chopping the title's closing "]" (the "[running"
# bug). Clearing first wipes any stale tail (a width-shrink diff) and leaves the
# final character intact.
sub _row_ansi {
    my ($row, $cell, $color) = @_;
    my $s = "\e[${row};1H\e[K";
    $s .= sgr_for_role($cell->{role}) if $color;
    $s .= $cell->{text};
    $s .= "\e[0m" if $color;
    return $s;
}

# render_frame($prev_frame, $new_frame, \%opts) -> the ANSI string to apply.
# Full redraw (clear + every row) when there is no previous frame, the row count
# changed (a resize), or opts.full is set; otherwise a per-row diff that touches
# ONLY changed rows. The whole burst is wrapped in synchronized-output markers
# (\e[?2026h/l) so the terminal presents it atomically — the B0 flicker fix.
sub render_frame {
    my ($prev, $new, $opts) = @_;
    $opts ||= {};
    my $color = $opts->{color};
    my $full  = $opts->{full} || !$prev || !@$prev || @$prev != @$new;

    my $out = "\e[?2026h";   # begin synchronized output
    $out .= "\e[2J\e[H" if $full;
    for my $i (0 .. $#$new) {
        unless ($full) {
            next if $prev->[$i]{text} eq $new->[$i]{text}
                 && $prev->[$i]{role} eq $new->[$i]{role};
        }
        $out .= _row_ansi($i + 1, $new->[$i], $color);
    }
    $out .= "\e[?2026l";     # end synchronized output
    return $out;
}

# dispatch_key($key, $pending) -> ($action, $new_pending).
# Single-letter hotkeys; shutdown is a two-step confirm (s -> pending 'shutdown',
# then y -> fire, any other key -> cancel). Unknown keys are inert.
sub dispatch_key {
    my ($key, $pending) = @_;
    $pending = '' if !defined $pending;
    $key = '' if !defined $key;

    if ($pending eq 'shutdown') {
        return ('shutdown', '')        if $key =~ /^[yY]$/;
        return ('cancel-shutdown', ''); # any other key cancels
    }
    return ('launch', '')             if $key =~ /^[cC]$/ || $key eq "\r" || $key eq "\n";
    return ('confirm-shutdown', 'shutdown') if $key =~ /^[sS]$/;
    return ('refresh', '')            if $key =~ /^[rR]$/;
    return ('quit', '')               if $key =~ /^[qQ]$/;
    # Up/down scroll the Activity panel. The read-key seam assembles the arrow
    # escape sequences into the 'UP'/'DOWN' tokens (also accept k/j as aliases).
    return ('scroll-up', $pending)    if $key eq 'UP'   || $key eq 'k';
    return ('scroll-down', $pending)  if $key eq 'DOWN' || $key eq 'j';
    return ('', $pending);
}

# find_exe($name, $path, $sep) -> first existing $path-dir/$name, or undef.
# Used to detect wt.exe. $sep defaults to the platform PATH separator.
sub find_exe {
    my ($name, $path, $sep) = @_;
    return undef if !defined $name || !length $name;
    return undef if !defined $path;
    # ONLY native Windows perl (Strawberry/ActiveState, $^O eq 'MSWin32') presents
    # $ENV{PATH} semicolon-separated. The Git-for-Windows perl that actually runs
    # the launcher reports $^O 'cygwin' (or 'msys') and presents a POSIX
    # colon-separated PATH (/c/foo:/c/bar) — so it must split on ':', NOT ';'.
    # (Regression: the old `cygwin|msys -> ;` guess split a colon-PATH into one
    # element, so find_exe never found wt.exe and launch-claude silently fell back
    # to a bare PowerShell console instead of a Windows Terminal window.)
    $sep = ($^O eq 'MSWin32') ? ';' : ':' if !defined $sep;
    for my $dir (split /\Q$sep\E/, $path) {
        next unless length $dir;
        my $cand = File::Spec->catfile($dir, $name);
        return $cand if -f $cand || -x $cand;
    }
    return undef;
}

# find_wt($path, $localappdata) -> the resolved wt.exe path, or undef if Windows
# Terminal is not installed. wt.exe is normally a per-user app-execution alias on
# PATH under %LOCALAPPDATA%\Microsoft\WindowsApps; we look there directly too, so a
# stripped PATH entry can't hide an installed WT. launch-claude REQUIRES Windows
# Terminal (no silent console fallback), so this is the gate the launcher asserts.
sub find_wt {
    my ($path, $localappdata) = @_;
    my $p = find_exe('wt.exe', $path);
    return $p if defined $p;
    if (defined $localappdata && length $localappdata) {
        my $cand = File::Spec->catfile($localappdata, 'Microsoft', 'WindowsApps', 'wt.exe');
        return $cand if -e $cand || -x $cand;
    }
    return undef;
}

# decide_spawn_mode($wt, $comspec, $os) -> 'wt' | 'start' | 'inline'.
# Prefer a real new Windows Terminal window; else a new console via cmd `start`;
# else reuse the dashboard window (Decision #19's fallback ladder).
sub decide_spawn_mode {
    my ($wt, $comspec, $os) = @_;
    return 'wt'    if $wt;
    my $is_win = (defined $os ? $os : $^O) =~ /^(MSWin32|cygwin|msys)$/;
    return 'start' if $is_win && $comspec;
    return 'inline';
}

# spawn_argv($mode, \%ctx) -> argv arrayref to run, or undef for 'inline'.
# ctx.cmd is the caller-supplied command list to run in the new window (the
# launcher's internal connector entry, `claude-sandbox --session <project>`);
# this function only wraps it with the window-spawning prefix. Keeping the
# command opaque means the wrapping logic stays pure/testable while the launcher
# owns the platform-correct invocation (a native wt.exe/`start` can't exec the
# .ps1 by bare name, so the launcher passes a `powershell.exe -File …` cmd).
# ctx: { cmd => [...], comspec }.
sub spawn_argv {
    my ($mode, $ctx) = @_;
    $ctx ||= {};
    my @cmd = @{ $ctx->{cmd} || [] };
    return ['wt.exe', '-w', 'new', @cmd]                            if $mode eq 'wt';
    return [($ctx->{comspec} || 'cmd.exe'), '/c', 'start', '', @cmd] if $mode eq 'start';
    return undef;   # inline: caller runs the connector in-process
}

# recent_events(\@json_lines, $n, $localtime_fn) -> arrayref of the last $n
# one-line event summaries parsed from B1 launch-log JSON lines. Unparseable
# lines are skipped. Optional 3rd arg $localtime_fn is the time seam passed
# to _event_time; omit for real localtime (2-arg callers unchanged).
sub recent_events {
    my ($lines, $n, $localtime_fn) = @_;
    $lines ||= [];
    $n = 10 if !defined $n || $n < 1;
    my $jp = JSON::PP->new;
    my @ev;
    for my $ln (@$lines) {
        next unless defined $ln && $ln =~ /\S/;
        my $rec = eval { $jp->decode($ln) };
        next unless $rec && ref $rec eq 'HASH';
        my $ts   = defined $rec->{ts} ? $rec->{ts} : '';
        my $hms  = _event_time($ts, $localtime_fn);
        my $type = defined $rec->{type} ? $rec->{type} : 'event';
        my $extra = '';
        $extra .= " exit=$rec->{exit}"   if defined $rec->{exit};
        $extra .= " state=$rec->{state}" if defined $rec->{state};
        push @ev, length $hms ? "$hms  $type$extra" : "$type$extra";
    }
    my @last = @ev > $n ? @ev[-$n .. -1] : @ev;
    return \@last;
}

# activity_view(\@events_chrono, $offset) -> the events to DISPLAY in the Activity
# panel, NEWEST-FIRST (descending), starting $offset items down from the newest.
# $offset is the up/down scroll position (0 = newest at top); it's clamped to
# [0, last index] so scrolling can't run off either end. Pure / unit-tested; the
# loop keeps the offset and feeds the result to the panel each frame. (Retained;
# activity_window is the capacity-aware successor used by the loop.)
sub activity_view {
    my ($events, $offset) = @_;
    $events ||= [];
    my @desc = reverse @$events;
    return [] unless @desc;
    $offset = 0       if !defined $offset || $offset < 0;
    $offset = $#desc  if $offset > $#desc;
    return [ @desc[$offset .. $#desc] ];
}

# _alert_msgs(\%state, $rows) -> the (priority-capped) alert banner messages a
# frame will show: the container-status alert and/or the backpack-install
# warning, trimmed so they never crowd out title + >=1 body + footer. Factored
# out of compose_frame so activity_capacity can subtract the same alert rows.
sub _alert_msgs {
    my ($state, $rows) = @_;
    $state ||= {};
    my @msgs = grep { defined && length } (_status_alert($state), $state->{install_warning});
    my $max_alert = (defined $rows ? $rows : 0) - 3;   # title + >=1 body + footer
    $max_alert = 0 if $max_alert < 0;
    if (@msgs > $max_alert) {
        @msgs = $max_alert > 0 ? @msgs[0 .. $max_alert - 1] : ();
    }
    return @msgs;
}

# activity_capacity(\%state, $rows, $cols) -> how many EVENT rows the Activity
# panel has room for, mirroring compose_frame's budget: total rows minus the
# title + footer + alert banners + the fixed panels (each title + lines + blank)
# + the Activity panel's own title. Used by the loop to clamp the scroll offset
# and to window the events (so scrolling can't run off the end, and the overflow
# hint reserves a row). Returns >= 0.
sub activity_capacity {
    my ($state, $rows, $cols) = @_;
    $state ||= {};
    $rows = 0 if !defined $rows || $rows < 0;
    my $alerts = scalar(_alert_msgs($state, $rows));
    my $body_h = $rows - 2 - $alerts;             # 2 = title + footer
    my $fixed  = 0;
    for my $p (_fixed_panels($state)) {
        $fixed += 1 + scalar(@{ $p->{lines} || [] }) + 1;   # title + lines + blank
    }
    my $cap = $body_h - $fixed - 1;               # -1 = Activity panel title
    return $cap > 0 ? $cap : 0;
}

# _scroll_hint($above, $below) -> a dim, ASCII-only overflow indicator string, or
# undef when nothing is hidden. ASCII only because the renderer maps any
# non-ASCII byte to '?' (the width invariant), so no unicode arrows.
sub _scroll_hint {
    my ($above, $below) = @_;
    my @bits;
    push @bits, "^ $above more above" if $above && $above > 0;
    push @bits, "v $below more below" if $below && $below > 0;
    return @bits ? join('    ', @bits) : undef;
}

# activity_window(\@events_desc, $offset, $capacity) -> the Activity panel's view:
#   { lines => [event strings, newest-first], hint => undef|{text,role=>scrollhint},
#     offset => clamped scroll position, max_offset => clamp ceiling }
# When the events fit in $capacity there's no scroll and no hint. When they
# overflow, one row is reserved for a dim hint showing how many are hidden above
# (scrolled past) and below (off the bottom); $offset is clamped to [0,
# max_offset] so you can't scroll past the last full page. Pure / unit-tested.
sub activity_window {
    my ($desc, $offset, $cap) = @_;
    $desc ||= [];
    my $total = scalar @$desc;
    $cap    = 0 if !defined $cap    || $cap < 0;
    $offset = 0 if !defined $offset || $offset < 0;

    return { lines => [], hint => undef, offset => 0, max_offset => 0 }
        if $total == 0 || $cap == 0;

    if ($total <= $cap) {                      # everything fits: no scroll/hint
        return { lines => [ @$desc ], hint => undef, offset => 0, max_offset => 0 };
    }

    my $visible = $cap - 1;                    # reserve a row for the hint
    $visible = 1 if $visible < 1;
    my $max_offset = $total - $visible;
    $max_offset = 0 if $max_offset < 0;
    $offset = $max_offset if $offset > $max_offset;
    my $end = $offset + $visible - 1;
    $end = $total - 1 if $end > $total - 1;

    my @lines = @{$desc}[$offset .. $end];
    my $above = $offset;
    my $below = $total - 1 - $end;
    my $hint  = _scroll_hint($above, $below);
    return {
        lines => \@lines,
        hint  => (defined $hint ? { text => $hint, role => 'scrollhint' } : undef),
        offset => $offset, max_offset => $max_offset,
    };
}

# blueprint_runs_dirs($data_root) -> the runs/ dir of every blueprint under
# $data_root/blueprints/. opendir (not glob) — safe for spaces / André paths.
sub blueprint_runs_dirs {
    my ($data_root) = @_;
    return () if !defined $data_root;
    my $bp = "$data_root/blueprints";
    return () unless -d $bp;
    opendir(my $dh, $bp) or return ();
    my @dirs;
    for my $e (sort readdir $dh) {
        next if $e eq '.' || $e eq '..';
        my $runs = "$bp/$e/runs";
        push @dirs, $runs if -d $runs;
    }
    closedir $dh;
    return @dirs;
}

# shutdown_targets($project_path) -> the `runs/.shutdown` path for every
# blueprint under the project. Mirrors heartbeat.sh's signal_graceful_shutdown
# (host side): the A4 gate reads each blueprint's runs/.shutdown.
sub shutdown_targets {
    my ($project) = @_;
    return () if !defined $project;
    return map { "$_/.shutdown" } blueprint_runs_dirs("$project/.ccpraxis-local-data");
}

# write_shutdown_signals(@targets) -> count written. Idempotent touch.
sub write_shutdown_signals {
    my (@targets) = @_;
    my $n = 0;
    for my $t (@targets) {
        if (open my $fh, '>', $t) { close $fh; $n++; }
    }
    return $n;
}

# ===========================================================================
# THE LOOP (seam-injected; every side effect is a coderef)
# ===========================================================================
#
# Required seams (launcher.pl supplies the real ones; the test harness supplies
# fakes): now, sleep_for, read_key, term_size, gather, heartbeat, spawn,
# write_signals, enter_raw, leave_raw, out. Optional: color, beat_interval,
# state_interval, tick_interval, max_ticks (bounded run for tests), and
# keepawake->(\%state) — B5's hook, called once per state refresh with the freshly
# gathered state so the launcher can drive the wake-lock off busy_age (the loop
# itself stays ignorant of the keep-awake decision; that lives in KeepAwake.pm).
#
# gather->() returns the base state hashref (project_name, container, status,
# events); the loop augments it with beat_age, uptime and pending. heartbeat->()
# returns 'ok' | 'fail' | 'gone' ('gone' ends the loop). spawn->() may return
# 'redraw' to force a full repaint (the inline fallback suspends/repaints).
sub run {
    my (%o) = @_;
    my $now        = $o{now}        || sub { time };
    my $sleep_for  = $o{sleep_for}  || sub { select undef, undef, undef, $_[0] };
    my $read_key   = $o{read_key}   || sub { undef };
    my $term_size  = $o{term_size}  || sub { (80, 24) };
    my $gather     = $o{gather}     || sub { {} };
    my $heartbeat  = $o{heartbeat}  || sub { 'ok' };
    my $spawn      = $o{spawn}      || sub { undef };
    my $write_sig  = $o{write_signals} || sub { 0 };
    my $enter_raw  = $o{enter_raw}  || sub { };
    my $leave_raw  = $o{leave_raw}  || sub { };
    my $keepawake  = $o{keepawake}  || sub { };   # B5: drive the wake-lock off fresh state
    my $out        = $o{out}        || sub { print STDOUT $_[0] };
    my $color      = exists $o{color} ? $o{color} : 1;
    my $beat_int   = defined $o{beat_interval}  ? $o{beat_interval}  : 120;
    my $state_int  = defined $o{state_interval} ? $o{state_interval} : 2;
    my $tick_int   = defined $o{tick_interval}  ? $o{tick_interval}  : 0.2;

    $enter_raw->();

    my $start     = $now->();
    my $last_beat = $start - $beat_int;   # heartbeat fires on the first tick
    my $last_state = undef;               # forces a gather on the first tick
    my ($cols, $rows) = $term_size->();
    my $prev;
    my %state;
    my $pending = '';
    my $hb_state = 'ok';        # last heartbeat result; 'gone' no longer exits the loop
    my @all_events;             # full chronological event list from the last gather
    my $activity_offset = 0;    # up/down scroll position in the Activity panel
    my $activity_max    = 0;    # scroll ceiling (set each frame by activity_window)
    my $flash_until = 0;        # footer-flash expiry (set when [c] hit a dead container)
    my $rc = 0;
    my $ticks = 0;

    my $err;
    {
        local $SIG{INT}  = sub { $leave_raw->(); exit 130 };
        local $SIG{TERM} = sub { $leave_raw->(); exit 143 };
        eval {
            while (1) {
                my $t = $now->();

                # heartbeat (token-free keep-alive of the container)
                if ($t - $last_beat >= $beat_int) {
                    my $hb = $heartbeat->();
                    $last_beat = $t;
                    # (E) Do NOT exit when the container is gone/unreachable. Keep
                    # the dashboard open so the user can see the dead state and
                    # recover ([q] quit, then re-run claude-sandbox) — surfaced as
                    # a status alert. Keep heartbeating: if the container comes
                    # back (podman/host woke), the dashboard recovers on its own.
                    $hb_state = $hb if defined $hb;
                }

                # state refresh (slower cadence than input polling)
                if (!defined $last_state || $t - $last_state >= $state_int) {
                    ($cols, $rows) = $term_size->();
                    my $base = $gather->() || {};
                    %state = %$base;
                    @all_events = @{ $base->{events} || [] };   # chronological
                    $activity_offset = 0 if $activity_offset < 0;
                    $last_state = $t;
                    # B5: re-evaluate the wake-lock on the freshly gathered state
                    # (carries busy_age). The launcher's seam owns the decision.
                    $keepawake->(\%state);
                }
                $state{beat_age}       = $t - $last_beat;
                $state{uptime}         = $t - $start;
                $state{pending}        = $pending;
                $state{container_gone} = ($hb_state eq 'gone') ? 1 : 0;
                $state{oauth_remaining} = defined $state{oauth_expires_at}
                    ? $state{oauth_expires_at} - $t : undef;
                # Transient footer notice when [c] was pressed on a non-running
                # container (set in the launch branch below). Auto-expires so the
                # normal command legend returns on its own.
                $state{footer_flash} = ($t < $flash_until) ? launch_blocked_msg() : undef;
                # Activity: capacity-aware window (newest-first) + a dim overflow
                # hint. activity_window clamps the offset to the last page (so you
                # can't scroll past the end) and tells us the scroll ceiling.
                my $cap  = activity_capacity(\%state, $rows, $cols);
                my @desc = reverse @all_events;
                my $win  = activity_window(\@desc, $activity_offset, $cap);
                $activity_offset = $win->{offset};
                $activity_max    = $win->{max_offset};
                my @ev_lines = @{ $win->{lines} };
                push @ev_lines, $win->{hint} if $win->{hint};
                $state{events} = (@ev_lines ? \@ev_lines : ['(no events yet)']);

                my $frame = compose_frame(\%state, $rows, $cols);
                $out->(render_frame($prev, $frame, { color => $color }));
                $prev = $frame;

                # input (non-blocking) — DRAIN all pending keys this tick, not one.
                # read_key polls non-blocking, so a fast burst of scroll events
                # (mouse wheel) otherwise queued one-per-tick and took seconds to
                # settle. Coalescing them into a single frame keeps scrolling
                # responsive. The cap is a runaway-input backstop.
                my $quit = 0;
                my $drained = 0;
                my $scroll_dirty = 0;   # set when a scroll mutates the view
                while ($drained < 256) {
                    my $key = $read_key->();
                    last unless defined $key && length $key;
                    $drained++;
                    my ($action, $np) = dispatch_key($key, $pending);
                    $pending = $np;
                    if ($action eq 'quit') { $rc = 0; $quit = 1; last; }
                    elsif ($action eq 'launch') {
                        if (can_launch(\%state)) {
                            my $r = $spawn->();
                            $prev = undef if defined $r && $r eq 'redraw';
                        } else {
                            # Container isn't running: a connector's `podman exec`
                            # would instantly fail and the spawned Windows Terminal
                            # would vanish. Suppress the spawn and flash the real
                            # recovery path in the footer for a couple of seconds.
                            $flash_until = $t + 2;
                        }
                    }
                    elsif ($action eq 'shutdown') {
                        $write_sig->();
                    }
                    elsif ($action eq 'refresh') {
                        $last_state      = undef;   # force a gather next tick
                        $prev            = undef;   # (D) force a FULL repaint: blank
                                                    # (\e[2J) then redraw every row fresh
                        $activity_offset = 0;       # back to the newest events
                    }
                    elsif ($action eq 'scroll-up') {
                        # Only a view-changing scroll marks the frame dirty; a no-op
                        # scroll at the top boundary needs no same-tick re-render.
                        if ($activity_offset > 0) { $activity_offset--; $scroll_dirty = 1; }
                    }
                    elsif ($action eq 'scroll-down') {
                        if ($activity_offset < $activity_max) { $activity_offset++; $scroll_dirty = 1; }
                    }
                    # confirm-shutdown / cancel-shutdown only toggle $pending
                }
                last if $quit;

                # Post-drain re-render: if a scroll changed the view, re-compose and
                # re-render immediately (same tick) using @all_events already in scope —
                # NO new gather. Update $prev so the next tick diffs against the last
                # frame actually emitted, not a stale pre-drain baseline.
                if ($scroll_dirty) {
                    # Refresh the fields the drain may have mutated, so this same-tick
                    # re-render matches what the NEXT primary render will show rather
                    # than their stale pre-drain values: $pending (mutated at :801) and
                    # the footer flash (set at :812 when [c] was pressed on a non-running
                    # container during THIS drain). Mirrors the primary path (:766/:771).
                    $state{pending}      = $pending;
                    $state{footer_flash} = ($t < $flash_until) ? launch_blocked_msg() : undef;
                    my $cap2  = activity_capacity(\%state, $rows, $cols);
                    my @desc2 = reverse @all_events;
                    my $win2  = activity_window(\@desc2, $activity_offset, $cap2);
                    $activity_offset = $win2->{offset};
                    $activity_max    = $win2->{max_offset};
                    my @ev2 = @{ $win2->{lines} };
                    push @ev2, $win2->{hint} if $win2->{hint};
                    $state{events} = (@ev2 ? \@ev2 : ['(no events yet)']);
                    my $frame2 = compose_frame(\%state, $rows, $cols);
                    $out->(render_frame($prev, $frame2, { color => $color }));
                    $prev = $frame2;
                }

                $ticks++;
                last if defined $o{max_ticks} && $ticks >= $o{max_ticks};
                $sleep_for->($tick_int);
            }
        };
        $err = $@;
    }

    $leave_raw->();
    die $err if $err;
    return $rc;
}

1;
