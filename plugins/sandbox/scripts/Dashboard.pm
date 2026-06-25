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

# build_panels(\%state) -> ordered list of { title => str, lines => [str,...] }.
# THE extension point: B3 adds container/heartbeat/busy/needs-you panels, B4 the
# backpack panel, simply by appending here. B2 ships a minimal Sandbox panel +
# an Activity panel (proving the B1 launch-log event stream is read).
sub build_panels {
    my ($s) = @_;
    $s ||= {};
    my @p;

    my @sb;
    push @sb, 'project   : ' . (defined $s->{project_name} ? $s->{project_name} : '?');
    push @sb, 'container : ' . (defined $s->{container} ? $s->{container} : '?')
            . '  [' . (defined $s->{status} ? $s->{status} : '?') . ']';
    push @sb, 'heartbeat : ' . (defined $s->{beat_age} ? fmt_age($s->{beat_age}) . ' ago' : 'n/a');
    push @sb, 'uptime    : ' . (defined $s->{uptime}   ? fmt_hms($s->{uptime})        : 'n/a');
    push @p, { title => 'Sandbox', lines => \@sb };

    my $ev = (ref $s->{events} eq 'ARRAY') ? $s->{events} : [];
    push @p, { title => 'Recent activity',
               lines => (@$ev ? [@$ev] : ['(no events yet)']) };

    return @p;
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
    my $legend = $pending eq 'shutdown'
        ? 'Shut down ALL coordinators in this project? [y] confirm   [any other] cancel'
        : ' [c] launch claude   [s] shutdown-all   [r] refresh   [q] quit';
    return clip_pad($legend, $cols);
}

# _alert_line($msg, $cols) -> a full-width banner row (rendered red via the
# 'alert' role). Used for the backpack-install-failure warning so it can't be
# lost behind the alt-screen the way the pre-dashboard stdout warning was.
sub _alert_line {
    my ($msg, $cols) = @_;
    return clip_pad('  !! ' . _safe(defined $msg ? $msg : ''), $cols);
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
            push @out, { text => clip_pad('  ' . _safe($ln), $cols), role => 'body' };
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

    my $footer_role = (defined $state->{pending} && $state->{pending} eq 'shutdown')
        ? 'footer-alert' : 'footer';
    my $footer = { text => _footer_line($state, $cols), role => $footer_role };

    if ($rows == 2) {
        push @frame, $footer;
        return \@frame;
    }

    # Optional alert banner directly under the title (e.g. backpack install
    # failures). Needs room for title + alert + >=1 body + footer, so only when
    # rows >= 4 — a tiny terminal silently drops it rather than crowding out the
    # body. The launcher surfaces this where the pre-dashboard stdout warning
    # would otherwise be wiped by the alt-screen.
    my @alert;
    my $warn = $state->{install_warning};
    if (defined $warn && length $warn && $rows >= 4) {
        push @alert, { text => _alert_line($warn, $cols), role => 'alert' };
    }

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
    return "\e[1;37;41m"  if $role eq 'alert';        # bold white on red (banner)
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

# recent_events(\@json_lines, $n) -> arrayref of the last $n one-line event
# summaries parsed from B1 launch-log JSON lines. Unparseable lines are skipped.
sub recent_events {
    my ($lines, $n) = @_;
    $lines ||= [];
    $n = 10 if !defined $n || $n < 1;
    my $jp = JSON::PP->new;
    my @ev;
    for my $ln (@$lines) {
        next unless defined $ln && $ln =~ /\S/;
        my $rec = eval { $jp->decode($ln) };
        next unless $rec && ref $rec eq 'HASH';
        my $ts  = defined $rec->{ts} ? $rec->{ts} : '';
        my $hms = ($ts =~ /T(\d\d:\d\d:\d\d)/) ? $1 : substr($ts, 0, 8);
        my $type = defined $rec->{type} ? $rec->{type} : 'event';
        my $extra = '';
        $extra .= " exit=$rec->{exit}"   if defined $rec->{exit};
        $extra .= " state=$rec->{state}" if defined $rec->{state};
        push @ev, length $hms ? "$hms  $type$extra" : "$type$extra";
    }
    my @last = @ev > $n ? @ev[-$n .. -1] : @ev;
    return \@last;
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
                    if (defined $hb && $hb eq 'gone') { $rc = 0; last; }
                }

                # state refresh (slower cadence than input polling)
                if (!defined $last_state || $t - $last_state >= $state_int) {
                    ($cols, $rows) = $term_size->();
                    my $base = $gather->() || {};
                    %state = %$base;
                    $last_state = $t;
                    # B5: re-evaluate the wake-lock on the freshly gathered state
                    # (carries busy_age). The launcher's seam owns the decision.
                    $keepawake->(\%state);
                }
                $state{beat_age} = $t - $last_beat;
                $state{uptime}   = $t - $start;
                $state{pending}  = $pending;

                my $frame = compose_frame(\%state, $rows, $cols);
                $out->(render_frame($prev, $frame, { color => $color }));
                $prev = $frame;

                # input (non-blocking)
                my $key = $read_key->();
                if (defined $key && length $key) {
                    my ($action, $np) = dispatch_key($key, $pending);
                    $pending = $np;
                    if ($action eq 'quit') { $rc = 0; last; }
                    elsif ($action eq 'launch') {
                        my $r = $spawn->();
                        $prev = undef if defined $r && $r eq 'redraw';
                    }
                    elsif ($action eq 'shutdown') {
                        $write_sig->();
                    }
                    elsif ($action eq 'refresh') {
                        $last_state = undef;   # force a gather next tick
                    }
                    # confirm-shutdown / cancel-shutdown only toggle $pending
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
