# tui::FleetScreen -- the [f] fleet screen (operator, 2026-11-11: "Maybe the
# TUI should just show if fleet is running or not and let me start or stop
# them, but don't start automatically upon just launching the tui").
#
# A selectable list of the project's FLEET runs (blueprints with a
# runs/registry.json), each with its state and the one action available for
# it: stop a running or paused fleet, start a stopped one. Both actions arm a
# confirm first; nothing happens without [y].
#
# Built the way tui::BackpackScreen is, and for the same reasons: init /
# dispatch_key / apply are the model, run() is the modal loop, compose() goes
# through tui::Screen, and EVERY I/O boundary arrives as an injected coderef
# (load, start, stop, read_key, wait_key, term_size, render, out, heartbeat).
# This module never names Dashboard, spawns nothing, reads no clock and
# touches no file -- the start (a bounded `podman exec ... bp-orchestrate.sh`)
# and the stop (the runs/.shutdown + runs/.stopped-by-operator markers) live
# behind the seams, in Dashboard.pm and launcher.pl.
#
# THE STATE IS NOT DECIDED HERE. tui::DashboardScreen::fleet_status is the one
# verdict, shared with the blueprint line, so the screen and the panel can
# never disagree about whether a fleet is running.
package tui::FleetScreen;
use strict;
use warnings;
use Theme;
use tui::Layout;
use tui::Screen;
use tui::DashboardScreen;

use constant MAX_NAME_LEN => 64;

sub _bounded {
    my ($t) = @_;
    $t = '' unless defined $t && !ref $t;
    $t =~ s/[\x00-\x1f\x7f]/ /g;
    return length($t) > MAX_NAME_LEN() ? substr($t, 0, MAX_NAME_LEN()) . '...' : $t;
}

# rows(\@summaries) -> \@rows, one per summary that fleet_status recognises:
# { blueprint, runs_dir, fs, s }. Order is the summaries' own (RunState's
# ascending blueprint order). PUBLIC.
sub rows {
    my ($runs) = @_;
    $runs = [] unless ref($runs) eq 'ARRAY';
    my @out;
    for my $s (@$runs) {
        next unless ref($s) eq 'HASH';
        my $fs = tui::DashboardScreen::fleet_status($s);
        next unless $fs;
        push @out, { blueprint => $s->{blueprint}, runs_dir => $s->{runs_dir}, fs => $fs, s => $s };
    }
    return \@out;
}

# state_spans(\%row) -> \@spans: the dot, then the state words, in the same
# glyphs and roles the blueprint line uses. PUBLIC.
sub state_spans {
    my ($row) = @_;
    return [] unless ref($row) eq 'HASH' && ref($row->{fs}) eq 'HASH';
    my $st = $row->{fs}{state};
    my ($gname, $grole, $text, $role);
    if ($st eq 'running') {
        ($gname, $grole, $text, $role) = ('status.ok', 'state.ok', 'running', 'state.ok');
    }
    elsif ($st eq 'paused') {
        ($gname, $grole, $role) = ('thread.idle', 'state.warn', 'state.warn');
        $text = 'paused ' . tui::DashboardScreen::_pause_words($row->{s});
    }
    else {
        ($text, $role) = tui::DashboardScreen::fleet_words($row->{fs});
        ($gname, $grole) = $st eq 'stopping'                         ? ('status.warn', 'state.warn')
                         : ($st eq 'stopped' && $row->{fs}{by_operator}) ? ('status.idle', 'text.muted')
                         : $st eq 'stopped'                          ? ('status.crit', 'state.crit')
                         :                                             ('status.idle', 'text.muted');
    }
    my $g = Theme::glyph($gname); $g = '' unless defined $g;
    return [ { text => $g, role => $grole }, { text => " $text", role => $role } ];
}

# action_text(\%row) -> the action column's words. PUBLIC.
# _load_all(\%seams) -> \@summaries: load->() when wired (and it answers),
# else the runs handed in. The detail pane lays these ALL out the way the
# Blueprints panel does, so it needs every summary, not only the fleets.
sub _load_all {
    my ($seams) = @_;
    if (ref($seams->{load}) eq 'CODE') {
        my $r = eval { $seams->{load}->() };
        return $r if ref($r) eq 'ARRAY';
    }
    return (ref($seams->{runs}) eq 'ARRAY') ? $seams->{runs} : [];
}
sub _load { my ($seams) = @_; return rows(_load_all($seams)); }
# _refresh(\%ss, \%seams): re-read every summary, rebuild the fleet rows.
sub _refresh {
    my ($ss, $seams) = @_;
    $ss->{all}  = _load_all($seams);
    $ss->{rows} = rows($ss->{all});
    _clamp($ss);
}

sub _selected {
    my ($ss) = @_;
    my $rows = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
    my $c = $ss->{cursor};
    return undef unless defined($c) && !ref($c) && $c =~ /\A\d+\z/ && $c < @$rows;
    return $rows->[$c];
}

sub _clamp {
    my ($ss) = @_;
    my $n = scalar @{ $ss->{rows} || [] };
    my $c = (defined($ss->{cursor}) && !ref($ss->{cursor}) && $ss->{cursor} =~ /\A-?\d+\z/) ? int($ss->{cursor}) : 0;
    $c = $n - 1 if $c > $n - 1;
    $c = 0 if $c < 0;
    $ss->{cursor} = $c;
}

# init(%seams) -> \%ss. PUBLIC.
sub init {
    my (%seams) = @_;
    my $ss = { cursor => 0, confirm => undef, status => undef, busy => undef,
               rows => [], all => [], started => 0, stopped => 0, failures => 0,
               now => $seams{now}, spend => $seams{spend} };
    _refresh($ss, \%seams);
    return $ss;
}

# dispatch_key(\%ss, $key) -> $action. Pure; mutates only cursor and confirm.
# PUBLIC.
sub dispatch_key {
    my ($ss, $key) = @_;
    $ss = {} unless ref($ss) eq 'HASH';
    return '' if !defined($key) || !length("$key");
    if (ref($ss->{confirm}) eq 'HASH') {
        my $op = $ss->{confirm}{op};
        if ($key =~ /\A[yY]\z/) {
            $ss->{armed} = delete $ss->{confirm};
            return $op;
        }
        delete $ss->{confirm};
        return 'cancel';
    }
    # THE KEYS (operator, 2026-11-11: "Why not just get rid of esc for
    # anything, then. q to close tui, f to switch between fleet panel and out
    # of it"): [f] toggles back to the dashboard, [q] quits the whole TUI the
    # way the dashboard's own [q] does, and ESC is never a command -- a lone
    # ESC, or any sequence Dashboard::_assemble_esc could not name, is inert.
    return 'close' if $key eq 'f';
    return 'quit'  if $key eq 'q';
    my $n = scalar @{ (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [] };
    if ($key eq 'HOME' || $key eq 'PGUP') { $ss->{cursor} = 0; return 'move'; }
    if ($key eq 'END'  || $key eq 'PGDN') { $ss->{cursor} = $n ? $n - 1 : 0; return 'move'; }
    if ($key eq 'UP' || $key eq 'k') {
        my $c = (defined($ss->{cursor}) && $ss->{cursor} =~ /\A\d+\z/) ? $ss->{cursor} : 0;
        $ss->{cursor} = $c > 0 ? $c - 1 : 0;
        return 'move';
    }
    if ($key eq 'DOWN' || $key eq 'j') {
        my $c = (defined($ss->{cursor}) && $ss->{cursor} =~ /\A\d+\z/) ? $ss->{cursor} : 0;
        $ss->{cursor} = ($c + 1 < $n) ? $c + 1 : ($n ? $n - 1 : 0);
        return 'move';
    }
    if ($key eq "\r" || $key eq "\n") {
        my $row = _selected($ss);
        my $a = $row ? $row->{fs}{action} : undef;
        return 'no-action' unless defined $a;
        $ss->{confirm} = { op => $a, blueprint => $row->{blueprint}, runs_dir => $row->{runs_dir} };
        return 'confirm';
    }
    return '';
}

# _target(\%ss) -> the row a confirmed action applies to: the one that was
# selected when the confirm armed, found again by name (a reload in between
# may have reordered or dropped rows; acting on whatever now sits under the
# cursor would start or stop the wrong fleet).
sub _target {
    my ($ss) = @_;
    my $armed = delete $ss->{armed};
    return undef unless ref($armed) eq 'HASH' && defined $armed->{blueprint};
    for my $r (@{ $ss->{rows} || [] }) {
        return $r if defined($r->{blueprint}) && $r->{blueprint} eq $armed->{blueprint};
    }
    return undef;
}

# apply(\%ss, $action, \%seams) -> 0|1 (1 = close now). PUBLIC.
sub apply {
    my ($ss, $action, $seams) = @_;
    $ss = {} unless ref($ss) eq 'HASH';
    $seams = {} unless ref($seams) eq 'HASH';
    $action = '' unless defined $action;

    return 1 if $action eq 'close';
    if ($action eq 'quit') { $ss->{quit} = 1; return 1; }
    # no-action: the action line already says "nothing to do"; leave it.
    return 0 if $action eq 'no-action';
    if ($action eq 'cancel') {
        $ss->{status} = { kind => 'noop', op => '', detail => 'cancelled' };
        return 0;
    }
    if ($action eq 'start' || $action eq 'stop') {
        my $row = _target($ss);
        if (!$row || !defined($row->{fs}{action}) || $row->{fs}{action} ne $action) {
            $ss->{status} = { kind => 'noop', op => $action, detail => 'the fleet changed state meanwhile - nothing done' };
            return 0;
        }
        my $seam = $seams->{$action};
        if (ref($seam) ne 'CODE') {
            $ss->{status} = { kind => 'unavailable', op => $action, detail => "no $action seam wired" };
            return 0;
        }
        my $bp = _bounded($row->{blueprint});
        $ss->{busy} = { op => $action, blueprint => $bp, elapsed => 0 };
        my $progress = ref($seams->{progress}) eq 'CODE' ? $seams->{progress} : sub { };
        my $r = eval { $seam->($row, $progress) };
        my $err = $@;
        $ss->{busy} = undef;
        if ($err || ref($r) ne 'HASH') {
            $err = 'no result' unless $err;
            $err =~ s/\s+/ /g;
            $ss->{failures}++;
            $ss->{status} = { kind => 'failed', op => $action, detail => "$bp - $err" };
        }
        elsif ($r->{ok}) {
            $ss->{ $action eq 'start' ? 'started' : 'stopped' }++;
            my $d = (defined($r->{detail}) && length($r->{detail})) ? " - $r->{detail}" : '';
            $ss->{status} = { kind => 'ok', op => $action,
                              detail => ($action eq 'start' ? "started $bp" : "stopping $bp") . $d };
        }
        else {
            $ss->{failures}++;
            my $d = (defined($r->{detail}) && length($r->{detail})) ? $r->{detail} : 'no detail';
            $ss->{status} = { kind => 'failed', op => $action, detail => "$bp - $d" };
        }
        _refresh($ss, $seams);
        return 0;
    }
    # Moving to another fleet clears the last result: the action line then
    # speaks for the new selection.
    delete $ss->{status} if $action eq 'move';
    return 0;
}

# ===========================================================================
# run(%seams) -> \%result -- the modal loop, shaped exactly like
# tui::BackpackScreen::run (heartbeat every iteration, max_ticks bound,
# type-ahead discarded when a confirm arms).
# ===========================================================================
sub run {
    my (%seams) = @_;
    my $ss = init(%seams);
    my $read_key  = (ref($seams{read_key})  eq 'CODE') ? $seams{read_key}  : sub { undef };
    my $wait_key  = (ref($seams{wait_key})  eq 'CODE') ? $seams{wait_key}  : undef;
    my $term_size = (ref($seams{term_size}) eq 'CODE') ? $seams{term_size} : sub { (80, 24) };
    my $render    = (ref($seams{render})    eq 'CODE') ? $seams{render}    : sub { '' };
    my $out       = (ref($seams{out})       eq 'CODE') ? $seams{out}       : sub { };
    my $heartbeat = (ref($seams{heartbeat}) eq 'CODE') ? $seams{heartbeat} : sub { };
    my $tick      = defined($seams{tick}) ? $seams{tick} : 0.2;
    my $max_ticks = $seams{max_ticks};
    # reload_ticks: re-read the list every N idle polls, so a fleet that is
    # STOPPING turns into stopped (or a start that took turns into running)
    # while the screen is open. Unset: the list is read only after an action.
    my $reload = $seams{reload_ticks};
    $reload = undef unless defined($reload) && !ref($reload) && $reload =~ /\A\d+\z/ && $reload >= 1;

    my $prev;
    my $paint = sub {
        my ($cols, $rows_n) = $term_size->();
        $cols   = 80 if !defined($cols)   || ref($cols)   || $cols   !~ /\A\d+\z/;
        $rows_n = 24 if !defined($rows_n) || ref($rows_n) || $rows_n !~ /\A\d+\z/;
        my $frame = compose($ss, $rows_n, $cols);
        $out->($render->($prev, $frame));
        $prev = $frame;
    };
    # The start seam calls this while bp-orchestrate.sh runs (the bounded
    # runner's on_tick): keep the container alive and show the time going by.
    my %apply_seams = (%seams, progress => sub {
        my ($elapsed) = @_;
        $ss->{busy}{elapsed} = $elapsed if ref($ss->{busy}) eq 'HASH' && defined($elapsed) && !ref($elapsed);
        eval { $heartbeat->() };
        $paint->();
    });

    $paint->();
    my ($ticks, $closed) = (0, 0);
    while (1) {
        last if defined($max_ticks) && $ticks >= $max_ticks;
        eval { $heartbeat->() };
        my $key = $read_key->();
        if (!defined($key) || !length("$key")) {
            last unless ref($wait_key) eq 'CODE';
            $key = $wait_key->($tick);
        }
        $ticks++;
        if (!(defined($key) && length("$key"))) {
            if ($reload && $ticks % $reload == 0 && !ref($ss->{confirm})) {
                # A reload that fails keeps the list it has: nothing about
                # refreshing may ever end the screen (only [f] or [q] does).
                eval { _refresh($ss, \%seams) };
                eval { $paint->() };
            }
            next;
        }
        my $action = dispatch_key($ss, $key);
        eval { $seams{keylog}->($key, (length $action ? $action : '(none)')) } if ref($seams{keylog}) eq 'CODE';
        if ($action eq 'confirm') {
            # Type-ahead must not answer a confirm nobody has seen yet.
            my $guard = 0;
            while ($guard++ < 1000) {
                my $k = $read_key->();
                last unless defined($k) && length("$k");
            }
        }
        my $done = apply($ss, $action, \%apply_seams);
        $paint->();
        if ($done) { $closed = 1; last; }
    }
    return { closed => $closed, quit => ($ss->{quit} ? 1 : 0), started => $ss->{started}, stopped => $ss->{stopped},
             failures => $ss->{failures}, ticks => $ticks, status => $ss->{status} };
}

# ===========================================================================
# Composition (operator, 2026-11-11: a STACKED screen, no vertical split).
#
#   - Fleets --------------------------------------------------------
#   > o payments-ledger    =====----------  2/7   running 6h      3 live   ! 1
#     x sandbox-reaper     ======---------  2/5   stopped (crashed 12:04)
#
#   - <selected fleet> ----------------------------------------------
#     <its package rows, exactly as the Blueprints panel draws them>
#     orchestrator up 30h . paused for the 5h limit until 02:00 . usage 5h 85% / 7d 40%
#     <padding: the detail fills the remaining height>
#     [enter] stop this fleet   (it finishes each package's current step, then halts)
#   -----------------------------------------------------------------
#   [^v] move   [enter] start/stop   [f] back   [q] quit
# ===========================================================================

sub FOOTER_LEGEND {
    my $u = Theme::glyph('arrow.up');   $u = '^' unless defined $u && length $u;
    my $d = Theme::glyph('arrow.down'); $d = 'v' unless defined $d && length $d;
    return "[$u$d] move   [enter] start/stop   [f] back   [q] quit";
}

# CONFIRM_TEXT($op, $bp) -> the action line while a confirm is armed. PUBLIC.
sub CONFIRM_TEXT {
    my ($op, $bp) = @_;
    $bp = '?' unless defined $bp;
    return ((defined($op) && $op eq 'start') ? 'Start' : 'Stop') . " $bp? [y] yes, any other key cancels";
}

# ACTION_TEXT(\%fleet_status) -> the action line for a selection. PUBLIC.
sub ACTION_TEXT {
    my ($fs) = @_;
    my $a = (ref($fs) eq 'HASH') ? $fs->{action} : undef;
    return "[enter] stop this fleet   (it finishes each package's current step, then halts)" if defined($a) && $a eq 'stop';
    return '[enter] start this fleet   (runs its hooks self-test first, a few minutes)'     if defined($a) && $a eq 'start';
    return 'nothing to do - a graceful stop is draining' if ref($fs) eq 'HASH' && ($fs->{state} // '') eq 'stopping';
    return 'nothing to do - settled';
}

sub _epoch_ok { my ($v) = @_; return (defined($v) && !ref($v) && $v =~ /\A\d{1,12}\z/ && $v > 0) ? 1 : 0; }

# state_words(\%row, $now) -> (\@state_spans, \@extra_spans): the list row's
# state, saying WHEN. PUBLIC.
#   running   running 6h                (+ "N live", "<flag> n")
#   paused    paused <dot> until 02:00   (or the pause words without a time)
#   stopping  stopping
#   stopped   stopped (crashed 12:04)   from the orchestrator log's last write
#   by you    stopped by you 1h ago     from the operator-stop record's `at`
#   settled   settled
sub state_words {
    my ($row, $now) = @_;
    return ([], []) unless ref($row) eq 'HASH' && ref($row->{fs}) eq 'HASH';
    my ($fs, $s) = ($row->{fs}, $row->{s} || {});
    my $f = (ref($s->{fleet}) eq 'HASH') ? $s->{fleet} : {};
    my $st = $fs->{state};
    my $dot = Theme::glyph('sep.dot'); $dot = '-' unless defined $dot;
    my $ago = sub { my ($t) = @_; return (_epoch_ok($t) && _epoch_ok($now) && $now >= $t) ? tui::DashboardScreen::_block_elapsed($now - $t) : undef; };
    my ($text, $role);
    my @extra;
    if ($st eq 'running') {
        my $up = $ago->($s->{orchestrator_started_at});
        ($text, $role) = ('running' . (defined $up ? " $up" : ''), 'state.ok');
        my $live = $s->{running_coordinators};
        push @extra, { text => "$live live", role => 'text.muted' } if defined($live) && !ref($live) && $live =~ /\A\d+\z/ && $live > 0;
    }
    elsif ($st eq 'paused') {
        my $rw = tui::DashboardScreen::_resume_words($s, $now);
        ($text, $role) = ('paused ' . $dot . ' ' . (length $rw ? $rw : tui::DashboardScreen::_pause_words($s)), 'state.warn');
    }
    elsif ($st eq 'stopping') {
        ($text, $role) = ('stopping', 'state.warn');
    }
    elsif ($st eq 'stopped' && $fs->{by_operator}) {
        my $a = $ago->($f->{operator_stop_at});
        ($text, $role) = ('stopped by you' . (defined $a ? " $a ago" : ''), 'state.warn');
    }
    elsif ($st eq 'stopped') {
        my $L = $f->{last_seen_local};
        my $when;
        if (ref($L) eq 'HASH' && defined $L->{hhmm}) {
            my $old = _epoch_ok($f->{last_seen_at}) && _epoch_ok($now) && $now - $f->{last_seen_at} >= 86400;
            $when = $old && defined($L->{wday}) ? "$L->{wday} $L->{hhmm}" : $L->{hhmm};
        }
        ($text, $role) = ('stopped' . (defined $when ? " (crashed $when)" : ''), 'state.crit');
    }
    else {
        ($text, $role) = ('settled', 'text.muted');
    }
    my $n = $s->{inbox_waiting};
    if (defined($n) && !ref($n) && $n =~ /\A\d+\z/ && $n > 0) {
        my $g = Theme::glyph('icon.decisions'); $g = '!' unless defined $g;
        push @extra, { text => "$g $n", role => 'state.warn' };
    }
    return ([ { text => $text, role => $role } ], \@extra);
}

sub _dw { my ($t) = @_; return tui::Layout::display_width(defined $t ? $t : '') // 0; }
sub _spans_w { my ($sp) = @_; my $w = 0; $w += _dw($_->{text}) for @$sp; return $w; }

# list_lines(\%ss) -> \@lines: one row per fleet, columns aligned across the
# list the way the Blueprints panel aligns its blueprint lines. PUBLIC.
sub list_lines {
    my ($ss) = @_;
    my $rows = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
    return [ [ { text => '(no fleet runs - a blueprint gets one the first time /butler:dispatch-fleet starts it)',
                 role => 'text.muted' } ] ] unless @$rows;
    my $now = $ss->{now};
    my $max = tui::DashboardScreen::BP_NAME_MAX();
    my (@name, @count, @state, @extra);
    my ($NW, $CW, $SW) = (0, 0, 0);
    for my $r (@$rows) {
        my $n = tui::DashboardScreen::_clip_name(_bounded($r->{blueprint}), $max);
        my $s = $r->{s} || {};
        my $c = tui::DashboardScreen::_nonneg_int($s->{packages_done}) . '/' . tui::DashboardScreen::_nonneg_int($s->{packages_total});
        my ($sp, $ex) = state_words($r, $now);
        push @name, $n; push @count, $c; push @state, $sp; push @extra, $ex;
        $NW = _dw($n) if _dw($n) > $NW;
        $CW = _dw($c) if _dw($c) > $CW;
        $SW = _spans_w($sp) if @$ex && _spans_w($sp) > $SW;
    }
    my @dots = map { state_spans($_)->[0] || { text => '', role => 'text.muted' } } @$rows;
    my $DW = 1;
    for my $d (@dots) { $DW = _dw($d->{text}) if _dw($d->{text}) > $DW; }
    my $cg = Theme::glyph('cursor'); $cg = '>' unless defined $cg;
    my $cw = Theme::glyph_width('cursor') // 1;
    my $cur = defined($ss->{cursor}) ? $ss->{cursor} : 0;
    my @lines;
    for my $i (0 .. $#$rows) {
        my $r = $rows->[$i];
        my $s = $r->{s} || {};
        my $dot = $dots[$i];
        my @l = (
            { text => ($i == $cur ? "$cg " : ' ' x ($cw + 1)), role => 'accent' },
            # one dot slot for the list, as wide as its widest glyph (the
            # pause glyph carries its Theme pad), the Blueprints panel's rule
            { text => $dot->{text} . (' ' x ($DW - _dw($dot->{text}) + 1)), role => $dot->{role} },
            { text => $name[$i] . (' ' x ($NW - _dw($name[$i]))) . '   ', role => 'accent' },
            @{ tui::DashboardScreen::_meter_spans($s->{packages_done}, $s->{packages_total}, 'gauge.full', 'gauge.empty') },
            { text => '  ' . $count[$i] . (' ' x ($CW - _dw($count[$i]))) . '   ', role => 'text.primary' },
            @{ $state[$i] },
        );
        if (@{ $extra[$i] }) {
            push @l, { text => ' ' x ($SW - _spans_w($state[$i]) + 3), role => 'text.muted' };
            my $first = 1;
            for my $e (@{ $extra[$i] }) {
                push @l, { text => '   ', role => 'text.muted' } unless $first;
                push @l, $e;
                $first = 0;
            }
        }
        push @lines, \@l;
    }
    return \@lines;
}

# package_lines(\%ss, $cols) -> \@lines: the selected fleet's package rows,
# laid out by the Blueprints panel's own code (_panel_blocks over EVERY
# summary at the panel's own body width), so they are byte-identical to what
# the panel draws for that fleet. PUBLIC.
sub package_lines {
    my ($ss, $cols) = @_;
    my $sel = _selected($ss);
    return [] unless $sel;
    my @all = grep { ref($_) eq 'HASH' } @{ (ref($ss->{all}) eq 'ARRAY') ? $ss->{all} : [] };
    my $w = tui::DashboardScreen::_blueprints_body_width($cols);
    my $blocks = tui::DashboardScreen::_panel_blocks(\@all, $ss->{now}, $w);
    my ($bi) = grep { defined($all[$_]{blueprint}) && defined($sel->{blueprint}) && $all[$_]{blueprint} eq $sel->{blueprint} } 0 .. $#all;
    return [] unless defined($bi) && ref($blocks->[$bi]) eq 'HASH';
    my $b = $blocks->[$bi];
    my @out;
    for my $ln (@{ $b->{lines} || [] }) {
        next if ($ln->{kind} // '') eq 'blueprint';
        push @out, @{ tui::DashboardScreen::_line_rows($b, $ln, $w) };
    }
    return \@out;
}

# facts_line(\%ss) -> \@spans: orchestrator uptime or not running, the pause
# and its end, usage 5h/7d. PUBLIC.
sub facts_line {
    my ($ss) = @_;
    my $sel = _selected($ss);
    return [] unless $sel;
    my ($s, $fs, $now) = ($sel->{s} || {}, $sel->{fs}, $ss->{now});
    my $dot = Theme::glyph('sep.dot'); $dot = '-' unless defined $dot;
    my @p;
    my $alive = tui::DashboardScreen::_alive_flag($s->{orchestrator_alive});
    if (defined($alive) && $alive == 1) {
        my $up = (_epoch_ok($s->{orchestrator_started_at}) && _epoch_ok($now) && $now >= $s->{orchestrator_started_at})
               ? tui::DashboardScreen::_block_elapsed($now - $s->{orchestrator_started_at}) : undef;
        push @p, 'orchestrator up' . (defined $up ? " $up" : '');
    } elsif (!defined($alive) && defined($s->{orchestrator_pid})) {
        push @p, 'orchestrator liveness unknown';
    } else {
        push @p, 'orchestrator not running';
    }
    if (($fs->{state} // '') eq 'paused') {
        my $rw = tui::DashboardScreen::_resume_words($s, $now);
        my $why = tui::DashboardScreen::_pause_words($s);
        push @p, ($why =~ /limit\z/ ? "paused for the $why" : "paused - $why") . (length $rw ? " $rw" : '');
    }
    my $u = usage_words($ss->{spend});
    push @p, $u if defined $u;
    return [ { text => '  ' . join(" $dot ", @p), role => 'text.muted' } ];
}

# usage_words(\%spend) -> "usage 5h 85% / 7d 40%" | undef, from the
# dashboard's spend state (SpendPanel::status output). PUBLIC.
sub usage_words {
    my ($spend) = @_;
    return undef unless ref($spend) eq 'HASH' && ref($spend->{claude}) eq 'HASH';
    my $c = $spend->{claude};
    my @w;
    for my $win (ref($c->{windows}) eq 'ARRAY' ? @{ $c->{windows} } : ()) {
        next unless ref($win) eq 'HASH' && defined($win->{name}) && defined($win->{text});
        push @w, ($win->{name} eq 'seven_day' ? '7d' : '5h') . " $win->{text}";
    }
    return @w ? 'usage ' . join(' / ', @w) : undef;
}

# action_line(\%ss) -> \@spans: progress while an action runs, the confirm
# in place, the last result, or the selection's action. PUBLIC.
sub action_line {
    my ($ss) = @_;
    my $sp = _action_line($ss);
    return @$sp ? [ { text => '  ', role => 'text.muted' }, @$sp ] : $sp;
}
sub _action_line {
    my ($ss) = @_;
    if (ref($ss->{busy}) eq 'HASH') {
        my $e = $ss->{busy}{elapsed};
        my $secs = (defined($e) && !ref($e) && $e =~ /\A\d+(?:\.\d+)?\z/) ? int($e) : 0;
        my $verb = $ss->{busy}{op} eq 'start' ? 'starting' : 'stopping';
        return [ { text => "$verb $ss->{busy}{blueprint} - bp-orchestrate.sh is running in the container, ${secs}s",
                   role => 'state.warn' } ];
    }
    if (ref($ss->{confirm}) eq 'HASH') {
        return [ { text => CONFIRM_TEXT($ss->{confirm}{op}, _bounded($ss->{confirm}{blueprint})), role => 'state.warn' } ];
    }
    if (ref($ss->{status}) eq 'HASH') {
        my ($k, $d, $op) = map { $ss->{status}{$_} // '' } qw(kind detail op);
        return [ { text => $d, role => 'state.ok' } ] if $k eq 'ok';
        return [ { text => 'FAILED' . (length $op ? " $op" : '') . " - $d", role => 'state.crit' } ] if $k eq 'failed';
        return [ { text => "unavailable - $d", role => 'state.warn' } ] if $k eq 'unavailable';
        return [ { text => $d, role => 'text.muted' } ] if length $d;
    }
    my $sel = _selected($ss);
    return [] unless $sel;
    return [ { text => ACTION_TEXT($sel->{fs}), role => (defined($sel->{fs}{action}) ? 'text.primary' : 'text.muted') } ];
}

# The legacy banner accessor: everything the screen announces now lives on
# the action line, so there are no banners. Kept for callers that ask.
sub banners { return []; }

# detail_lines(\%ss, $rows, $cols) -> \@lines, exactly the height the detail
# pane has: package rows (cut with the panel's "+N rows hidden" notice when
# they do not fit), the facts line, padding, a blank, the action line.
sub detail_lines {
    my ($ss, $rows_n, $cols) = @_;
    my $pk = package_lines($ss, $cols);
    my $facts = facts_line($ss);
    my $act = action_line($ss);
    # tui::Screen: the list panel is its title + lines + one blank row, the
    # detail its title + lines, around the chrome (title, footer rule, footer).
    my $list_n = scalar @{ list_lines($ss) };
    my $H = defined($rows_n) ? $rows_n - tui::Screen::chrome_rows() - (1 + $list_n + 1) - 1 : undef;
    my $tail = 1 + 1 + 1;    # facts, blank, action
    my @p = @$pk;
    if (defined($H) && @p + $tail > $H) {
        my $room = $H - $tail - 1;
        $room = 0 if $room < 0;
        my $hidden = @p - $room;
        @p = (@p[0 .. $room - 1], tui::DashboardScreen::_collapse_notice($hidden)) if $hidden > 0;
        @p = () if $H - $tail < 1;
    }
    my @l = (@p, $facts);
    my $pad = defined($H) ? $H - scalar(@l) - 2 : 0;
    push @l, [ { text => '', role => 'text.muted' } ] for 1 .. ($pad > 0 ? $pad : 0);
    push @l, [ { text => '', role => 'text.muted' } ], $act;
    return \@l;
}

sub screen {
    my ($ss, $cols, $rows_n) = @_;
    $ss = {} unless ref($ss) eq 'HASH';
    my @panels = ( { title => 'Fleets', lines => list_lines($ss), full_width => 1 } );
    my $sel = _selected($ss);
    push @panels, { title => ($sel ? _bounded($sel->{blueprint}) : 'no fleet'), lines => detail_lines($ss, $rows_n, $cols),
                    full_width => 1, flex => 1 };
    return {
        title       => [ { text => 'fleet control', role => 'accent' } ],
        title_role  => 'accent',
        banners     => [],
        banner_role => 'text.muted',
        panels      => \@panels,
        footer      => FOOTER_LEGEND(),
        footer_role => 'text.faint',
    };
}

# compose(\%ss, $rows, $cols) -> \@cells, exactly $rows cells. PUBLIC.
sub compose {
    my ($ss, $rows_n, $cols) = @_;
    return tui::Screen::compose(screen($ss, $cols, $rows_n), $rows_n, $cols);
}

1;
