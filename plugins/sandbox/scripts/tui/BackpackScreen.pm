# tui::BackpackScreen -- the [b] screen (blueprint unified-tui-design-system,
# package 07-backpack-screen). See specs/07-backpack-screen-spec.md S2.4.
#
# A scrolling, selectable list of backpack items with a confirm-and-persist
# drop and a persist-on-approve, composed through tui::Screen, with every I/O
# boundary injected. THE ARROW RUNS ONE WAY: Dashboard.pm consumes this
# module; this module never names Dashboard (package 05's AC-P4 shape,
# repeated here for the same reason).
#
# PURE view/model logic, total, no side effects of its own: no filesystem, no
# subprocess, no clock, no console, no %ENV. Persistence (load/save/remove)
# and every I/O boundary (read_key/wait_key/term_size/render/out) reach this
# module ONLY as injected coderefs. This is what keeps t/67 incapable of
# spawning anything.
package tui::BackpackScreen;
use strict;
use warnings;
use Theme;
use BackpackApproval;
use tui::Frame;
use tui::Layout;
use tui::Screen;
use tui::DashboardScreen;

# ===========================================================================
# Accessors -- every literal a test would otherwise pin lives behind one of
# these, so t/67 derives rather than repeats a magic value (S2.4).
# ===========================================================================

use constant STATE_COL        => 9;
use constant DETAIL_ROWS      => 3;
use constant MIN_USABLE_ROWS  => 6;
use constant DROP_IS_UNDOABLE => 0;
# MEDIUM-3 (fix-batch): well beyond any real terminal width many times
# over, so no operator ever sees a difference -- see _bounded_key() below
# for why it exists.
use constant MAX_RENDERED_KEY_LEN => 200;

# _bounded_key($key) -> a length-capped copy of an item key for DISPLAY
# only (never used for identity/equality -- rows()/dispatch_key/apply keep
# the full, untruncated key). $row->{key} arrives from container-writable
# backpack.json data (BackpackApproval::item_key concatenates category +
# name with no length limit) and, unbounded, gets handed straight into a
# span. tui::Frame::fit_spans (H5, read-only) must measure a span's FULL
# display width before it can decide where to cut for the terminal -- an
# O(n) walk over the UNtruncated text on every single repaint. Measured:
# ~1.6s per repaint for a 1MB name (~16s for 10MB), and this screen
# repaints on every keystroke and every heartbeat tick while it's open.
sub _bounded_key {
    my ($key) = @_;
    $key = '' unless defined $key;
    return $key if length($key) <= MAX_RENDERED_KEY_LEN();
    return substr($key, 0, MAX_RENDERED_KEY_LEN()) . '...';
}

sub DROP_WARNING {
    return 'this action is permanent and cannot be undone';
}

sub STATUS_KINDS {
    return [ 'ok', 'noop', 'unavailable', 'failed' ];
}

sub FOOTER_LEGEND {
    return '[k/j] move  [a] approve  [d] drop  [y] confirm  [q/ESC] quit';
}

# STATE_LABEL($approved) -> 'approved'|'pending'. Total: any hostile input
# is simply treated as boolean-false. PUBLIC.
sub STATE_LABEL {
    my ($approved) = @_;
    return $approved ? 'approved' : 'pending';
}

# STATE_ROLE($approved) -> a known Theme role. PUBLIC.
sub STATE_ROLE {
    my ($approved) = @_;
    return $approved ? 'state.ok' : 'state.warn';
}

# ===========================================================================
# The row model -- one shape, two sources (S2.1).
# ===========================================================================

# rows(\@items, \%approvals) -> \@rows -- each row is
# { key, approved, item }. Never re-sorts; a non-arrayref \@items -> [].
# PUBLIC.
sub rows {
    my ($items, $appr) = @_;
    $items = [] if ref($items) ne 'ARRAY';
    $appr  = {} if ref($appr)  ne 'HASH';

    my @out;
    for my $it (@$items) {
        if (ref($it) eq 'HASH' && (exists $it->{category} || exists $it->{name})) {
            push @out, {
                key      => BackpackApproval::item_key($it),
                approved => BackpackApproval::is_approved($it, $appr) ? 1 : 0,
                item     => $it,
            };
        } elsif (ref($it) eq 'HASH' && exists $it->{key}) {
            push @out, {
                key      => (defined($it->{key}) ? $it->{key} : '?'),
                approved => $it->{approved} ? 1 : 0,
                item     => undef,
            };
        } else {
            push @out, { key => '?', approved => 0, item => undef };
        }
    }
    return \@out;
}

# counts(\@rows) -> { total, approved, pending }. PUBLIC.
sub counts {
    my ($rows_ref) = @_;
    $rows_ref = [] if ref($rows_ref) ne 'ARRAY';
    my $total = scalar @$rows_ref;
    my $approved = 0;
    for my $r (@$rows_ref) {
        $approved++ if ref($r) eq 'HASH' && $r->{approved};
    }
    return { total => $total, approved => $approved, pending => $total - $approved };
}

# ===========================================================================
# Private helpers.
# ===========================================================================

# _load_rows(\%seams) -> (\@rows, \%approvals, \%error|undef). Source
# precedence, stated once (S2.4.1): if seams{load} is a coderef it is the
# ONLY source; items/approvals are otherwise used and never reloaded.
sub _load_rows {
    my ($seams) = @_;
    $seams = {} if ref($seams) ne 'HASH';
    if (ref($seams->{load}) eq 'CODE') {
        my $bp = eval { $seams->{load}->() };
        $bp = {} if ref($bp) ne 'HASH';
        my $items = (ref($bp->{items})     eq 'ARRAY') ? $bp->{items}     : [];
        my $appr  = (ref($bp->{approvals}) eq 'HASH')  ? $bp->{approvals} : {};
        my $error = (ref($bp->{error})     eq 'HASH')  ? $bp->{error}    : undef;
        return (rows($items, $appr), $appr, $error);
    }
    my $items = (ref($seams->{items})     eq 'ARRAY') ? $seams->{items}     : [];
    my $appr  = (ref($seams->{approvals}) eq 'HASH')  ? $seams->{approvals} : {};
    return (rows($items, $appr), $appr, undef);
}

# _err_detail(\%err) -> the first non-empty of message, errno, else the
# fixed fallback (S2.4.2).
sub _err_detail {
    my ($err) = @_;
    return 'no detail' unless ref($err) eq 'HASH';
    return $err->{message} if defined($err->{message}) && length($err->{message});
    return $err->{errno}   if defined($err->{errno})   && length($err->{errno});
    return 'no detail';
}

sub _selected_row {
    my ($ss) = @_;
    return undef unless ref($ss) eq 'HASH';
    my $rows_ref = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
    my $c = $ss->{cursor};
    return undef unless defined($c) && !ref($c) && $c =~ /^-?\d+$/;
    $c = int($c);
    return undef if $c < 0 || $c >= scalar(@$rows_ref);
    return $rows_ref->[$c];
}

sub _selected_key {
    my ($ss) = @_;
    my $row = _selected_row($ss);
    return (ref($row) eq 'HASH' && defined($row->{key})) ? $row->{key} : undef;
}

# ===========================================================================
# init/dispatch_key/apply -- the model (S2.4.3, S2.4.4).
# ===========================================================================

# init(%seams) -> \%ss. PUBLIC.
sub init {
    my (%seams) = @_;
    my $ss = {
        cursor    => 0,
        confirm   => undef,
        status    => undef,
        rows      => [],
        approvals => {},
        approved  => 0,
        dropped   => 0,
        failures  => 0,
        load_error => undef,
    };
    my ($rows_ref, $appr, $error) = _load_rows(\%seams);
    $ss->{rows}       = $rows_ref;
    $ss->{approvals}  = $appr;
    $ss->{load_error} = $error;
    if (ref($error) eq 'HASH' && $error->{broken}) {
        $ss->{status} = { kind => 'failed', op => 'load', key => undef, detail => _err_detail($error) };
    }
    return $ss;
}

# dispatch_key(\%ss, $key) -> $action -- pure, view-state only. Mutates only
# $ss->{cursor} and $ss->{confirm}. Never persists, never renders (S2.4.3).
# PUBLIC.
sub dispatch_key {
    my ($ss, $key) = @_;
    $ss = {} if ref($ss) ne 'HASH';
    return '' if !defined($key) || !length("$key");

    if (ref($ss->{confirm}) eq 'HASH') {
        delete $ss->{confirm};
        return 'drop' if $key =~ /^[yY]$/;
        return 'cancel-drop';
    }

    # S1, now APPLIED: the spec's closed token set (S2.4.3) names this
    # 'close'. The first attempt at this rename was reverted, because t/67's
    # forbidden-construct scanner matched a bare `\bclose\b` and so fired on
    # this STRING LITERAL exactly as it would on a real close() call -- the
    # same vacuity-trap shape already fixed once for 'warn' vs 'state.warn',
    # reproduced here only because nothing had previously needed the literal
    # 'close' in this module. The scanner is now narrowed to the call form
    # `\bclose\s*\(` (t/67 AC-S4/AC-P2, with fixtures proving it still fires
    # on a genuine close($fh) and does not fire on this literal), so the
    # rename lands cleanly. Report the broken guard, fix the guard, then make
    # the change -- never work around the guard.
    return 'close' if $key eq 'q' || $key eq "\e";

    my $rows_ref = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
    my $total    = scalar @$rows_ref;

    if ($key eq 'UP' || $key eq 'k') {
        my $c = (defined($ss->{cursor}) && !ref($ss->{cursor}) && $ss->{cursor} =~ /^-?\d+$/)
              ? int($ss->{cursor}) : 0;
        $c--;
        $c = 0 if $c < 0;
        $ss->{cursor} = $c;
        return 'move';
    }
    if ($key eq 'DOWN' || $key eq 'j') {
        my $c = (defined($ss->{cursor}) && !ref($ss->{cursor}) && $ss->{cursor} =~ /^-?\d+$/)
              ? int($ss->{cursor}) : 0;
        $c++;
        $c = $total - 1 if $c > $total - 1;
        $c = 0 if $c < 0;
        $ss->{cursor} = $c;
        return 'move';
    }
    if ($key eq 'a') {
        return 'approve';
    }
    if ($key eq 'd') {
        $ss->{confirm} = { op => 'drop', key => _selected_key($ss) };
        return 'confirm-drop';
    }
    return '';
}

# apply(\%ss, $action, \%seams) -> 0|1 (1 = the screen should close now).
# The persistence flows (S2.4.4). PUBLIC.
sub apply {
    my ($ss, $action, $seams) = @_;
    $ss     = {} if ref($ss) ne 'HASH';
    $seams  = {} if ref($seams) ne 'HASH';
    $action = ''  unless defined $action;

    if ($action eq 'approve') {
        my $row = _selected_row($ss);
        if (!$row) {
            $ss->{status} = { kind => 'noop', op => 'approve', key => undef, detail => 'nothing selected' };
            return 0;
        }
        if (!defined $row->{item}) {
            # N1: status_spans() (below) already prefixes an 'unavailable'
            # kind's banner with the literal word 'unavailable' -- this
            # detail used to repeat it ("unavailable - approve: item
            # detail unavailable - ..."). Say only what's missing.
            $ss->{status} = { kind => 'unavailable', op => 'approve', key => $row->{key},
                               detail => 'item detail needed - approve needs the backpack file' };
            return 0;
        }
        if ($row->{approved}) {
            $ss->{status} = { kind => 'noop', op => 'approve', key => $row->{key}, detail => 'already approved' };
            return 0;
        }
        if (ref($seams->{save}) ne 'CODE') {
            $ss->{status} = { kind => 'unavailable', op => 'approve', key => $row->{key},
                               detail => 'no approvals store wired' };
            return 0;
        }
        $ss->{approvals} = {} if ref($ss->{approvals}) ne 'HASH';
        BackpackApproval::approve($row->{item}, $ss->{approvals});
        my ($ok, $err) = $seams->{save}->($ss->{approvals});
        if ($ok) {
            $row->{approved} = 1;
            $ss->{approved}  = ($ss->{approved} || 0) + 1;
            $ss->{status} = { kind => 'ok', op => 'approve', key => $row->{key},
                               detail => "approved $row->{key}" };
        } else {
            BackpackApproval::forget($row->{item}, $ss->{approvals});
            $ss->{failures} = ($ss->{failures} || 0) + 1;
            $ss->{status} = { kind => 'failed', op => 'approve', key => $row->{key}, detail => _err_detail($err) };
        }
        return 0;
    }

    if ($action eq 'confirm-drop') {
        my $row = _selected_row($ss);
        if (!$row || !defined($row->{item}) || ref($seams->{remove}) ne 'CODE') {
            delete $ss->{confirm};
            # N1: don't repeat 'unavailable' -- status_spans() already
            # prefixes it for the 'unavailable' kind.
            $ss->{status} = { kind => 'unavailable', op => 'drop',
                               key => (ref($row) eq 'HASH' ? $row->{key} : undef),
                               detail => 'dropping needs the backpack file and a remove seam' };
        }
        return 0;
    }

    if ($action eq 'cancel-drop') {
        $ss->{status} = { kind => 'noop', op => 'drop', key => undef, detail => 'cancelled' };
        return 0;
    }

    if ($action eq 'drop') {
        my $row = _selected_row($ss);
        if (!$row || !defined($row->{item}) || ref($seams->{remove}) ne 'CODE') {
            $ss->{status} = { kind => 'unavailable', op => 'drop',
                               key => (ref($row) eq 'HASH' ? $row->{key} : undef),
                               detail => 'dropping needs the backpack file and a remove seam' };
            return 0;
        }
        my ($ok, $err) = $seams->{remove}->($row->{item});
        if (!$ok) {
            $ss->{failures} = ($ss->{failures} || 0) + 1;
            $ss->{status} = { kind => 'failed', op => 'drop', key => $row->{key}, detail => _err_detail($err) };
            return 0;
        }

        $ss->{approvals} = {} if ref($ss->{approvals}) ne 'HASH';
        BackpackApproval::forget($row->{item}, $ss->{approvals});

        my $cleanup_failed = 0;
        my $cleanup_detail;
        if (ref($seams->{save}) eq 'CODE') {
            my ($ok2, $err2) = $seams->{save}->($ss->{approvals});
            if (!$ok2) {
                $cleanup_failed  = 1;
                $cleanup_detail  = "$row->{key} was dropped from the backpack but its approval record "
                                  . 'could not be cleared - ' . _err_detail($err2);
                $ss->{failures}  = ($ss->{failures} || 0) + 1;
            }
        }

        _refresh_after_drop($ss, $seams, $row->{key});
        $ss->{dropped} = ($ss->{dropped} || 0) + 1;

        if ($cleanup_failed) {
            $ss->{status} = { kind => 'failed', op => 'approval-cleanup', key => $row->{key}, detail => $cleanup_detail };
        } else {
            $ss->{status} = { kind => 'ok', op => 'drop', key => $row->{key}, detail => "dropped $row->{key}" };
        }
        return 0;
    }

    if ($action eq 'close') {
        return 1;
    }

    # 'move', '', and anything else: no status change, no mutation (the
    # status persists until another approve/confirm-drop/drop/cancel-drop
    # action replaces it -- a failure cannot be scrolled away by accident).
    return 0;
}

# _refresh_after_drop(\%ss, \%seams, $dropped_key) -- re-init from load->()
# when wired; otherwise splice the row out in place. Clamps the cursor.
sub _refresh_after_drop {
    my ($ss, $seams, $dropped_key) = @_;
    if (ref($seams->{load}) eq 'CODE') {
        my ($rows_ref, $appr, undef) = _load_rows($seams);
        $ss->{rows}      = $rows_ref;
        $ss->{approvals} = $appr;
    } else {
        my $rows_ref = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
        my @kept = grep {
            !(ref($_) eq 'HASH' && defined($_->{key}) && defined($dropped_key) && $_->{key} eq $dropped_key)
        } @$rows_ref;
        $ss->{rows} = \@kept;
    }
    my $total = scalar @{ $ss->{rows} || [] };
    my $c = $ss->{cursor};
    $c = 0 if !defined($c) || ref($c) || $c !~ /^-?\d+$/;
    $c = int($c);
    $c = $total - 1 if $c > $total - 1;
    $c = 0 if $c < 0;
    $ss->{cursor} = $c;
}

# ===========================================================================
# run(%seams) -> \%result -- the modal loop (S2.4.1's termination guarantee).
# PUBLIC.
# ===========================================================================
sub run {
    my (%seams) = @_;
    my $ss = init(%seams);

    my $read_key  = (ref($seams{read_key})  eq 'CODE') ? $seams{read_key}  : sub { undef };
    my $wait_key  = (ref($seams{wait_key})  eq 'CODE') ? $seams{wait_key}  : undef;
    my $term_size = (ref($seams{term_size}) eq 'CODE') ? $seams{term_size} : sub { (80, 24) };
    my $render    = (ref($seams{render})    eq 'CODE') ? $seams{render}    : sub { '' };
    my $out       = (ref($seams{out})       eq 'CODE') ? $seams{out}       : sub { };
    my $tick      = defined($seams{tick}) ? $seams{tick} : 0.2;
    my $max_ticks = $seams{max_ticks};
    # MEDIUM-1: an injected keep-alive tick, called once per loop iteration
    # below. Defaults to a no-op so this module stays pure/testable (no
    # clock of its own, S2.0) -- the caller (Dashboard::run) is the one that
    # decides how often a real touch actually fires; this module has no
    # opinion beyond "call it every iteration".
    my $heartbeat = (ref($seams{heartbeat}) eq 'CODE') ? $seams{heartbeat} : sub { };

    my $prev;
    my $ticks  = 0;
    my $closed = 0;

    my $paint = sub {
        my ($cols, $rows_n) = $term_size->();
        $cols   = 80 if !defined($cols)   || ref($cols)   || $cols   !~ /^-?\d+(?:\.\d+)?$/;
        $rows_n = 24 if !defined($rows_n) || ref($rows_n) || $rows_n !~ /^-?\d+(?:\.\d+)?$/;
        my $frame = compose($ss, $rows_n, $cols);
        $out->($render->($prev, $frame));
        $prev = $frame;
    };

    $paint->();

    while (1) {
        last if defined($max_ticks) && $ticks >= $max_ticks;

        # MEDIUM-1: tick the keep-alive on every iteration of THIS loop,
        # not just when a key arrives -- an idle operator (the exact case
        # that needs the touch) spends most iterations here, in the
        # wait_key poll below. eval-guarded: a dying seam must not kill the
        # modal (this module is Total, S2.0).
        eval { $heartbeat->() };

        my $key = $read_key->();
        if (!defined($key) || !length("$key")) {
            if (ref($wait_key) eq 'CODE') {
                $key = $wait_key->($tick);
            } else {
                last;   # no input source at all: the loop cannot proceed
            }
        }
        $ticks++;
        next unless defined($key) && length("$key");   # an idle poll: try again

        my $action = dispatch_key($ss, $key);
        my $done   = apply($ss, $action, \%seams);
        # MEDIUM-2: the instant a drop confirm ARMS (never on any other
        # action -- dispatch_key's own confirm-branch, rule 2, always
        # disarms before returning), discard whatever is already sitting
        # in the input buffer. Without this, type-ahead (a 'y' typed or
        # queued before the operator could possibly have seen
        # DROP_WARNING(), e.g. a fast "dy") fires the non-undoable drop
        # with the warning never actually displayed to anyone. read_key is
        # non-blocking by contract (S2.4.1): this only discards bytes
        # ALREADY queued, it never waits for more. Bounded so a hostile/
        # infinite read_key stub can't hang the modal (S2.0 totality).
        if ($action eq 'confirm-drop' && ref($ss->{confirm}) eq 'HASH') {
            my $guard = 0;
            while ($guard++ < 1000) {
                my $flushed = $read_key->();
                last unless defined($flushed) && length("$flushed");
            }
        }
        $paint->();
        if ($done) { $closed = 1; last; }
    }

    return {
        closed   => $closed ? 1 : 0,
        approved => $ss->{approved} || 0,
        dropped  => $ss->{dropped}  || 0,
        failures => $ss->{failures} || 0,
        ticks    => $ticks,
        status   => $ss->{status},
    };
}

# ===========================================================================
# The composed screen (S2.4.5).
# ===========================================================================

# window(\%ss, $rows, $cols) -> \%viewport -- a derivation of
# tui::Screen::viewport (S2.4.6). PUBLIC.
sub window {
    my ($ss, $rows_n, $cols) = @_;
    $ss = {} if ref($ss) ne 'HASH';
    my $rows_ref = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
    my $total    = scalar @$rows_ref;
    my $nb       = scalar @{ banners($ss) };
    my $hd       = $total ? 1 : 0;
    my $lh       = list_height($rows_n, $cols, $nb, $hd);
    return tui::Screen::viewport($total, $lh, $ss->{cursor});
}

# list_height($rows,$cols,$n_banners,$has_detail) -> int, never negative
# (S2.4.6). PUBLIC.
sub list_height {
    my ($rows_n, $cols, $n_banners, $has_detail) = @_;
    $rows_n    = 0 if !defined($rows_n)    || ref($rows_n)    || $rows_n    !~ /^-?\d+(?:\.\d+)?$/;
    $cols      = 0 if !defined($cols)      || ref($cols)      || $cols      !~ /^-?\d+(?:\.\d+)?$/;
    $n_banners = 0 if !defined($n_banners) || ref($n_banners) || $n_banners !~ /^-?\d+(?:\.\d+)?$/;
    $rows_n    = int($rows_n);
    $cols      = int($cols);
    $n_banners = int($n_banners);

    my $body = $rows_n - 2 - $n_banners;
    my $det  = (tui::Layout::arrangement($cols) eq 'two-column') ? 0
             : ($has_detail ? 1 + DETAIL_ROWS() : 0);
    my $h = $body - 1 - 1 - $det;
    return $h < 0 ? 0 : $h;
}

# banners(\%ss) -> \@banners -- at most two: the confirm banner, then the
# status banner (S2.4.5). PUBLIC.
sub banners {
    my ($ss) = @_;
    $ss = {} if ref($ss) ne 'HASH';
    my @out;
    if (ref($ss->{confirm}) eq 'HASH') {
        my $key  = defined($ss->{confirm}{key}) ? _bounded_key($ss->{confirm}{key}) : '?';
        my $text = '!! drop ' . $key . ' - ' . DROP_WARNING() . ' [y] confirm, any other key cancels';
        push @out, [ { text => $text, role => 'state.warn' } ];
    }
    if (ref($ss->{status}) eq 'HASH') {
        push @out, status_spans($ss->{status});
    }
    return \@out;
}

# status_spans(\%status) -> \@spans -- role per the S2.4.4 table. PUBLIC.
sub status_spans {
    my ($status) = @_;
    return [] unless ref($status) eq 'HASH';
    my $kind   = defined($status->{kind})   ? $status->{kind}   : '';
    my $op     = defined($status->{op})     ? $status->{op}     : '';
    my $detail = defined($status->{detail}) ? $status->{detail} : '';

    my $role = $kind eq 'ok'          ? 'state.ok'
             : $kind eq 'failed'      ? 'state.crit'
             : $kind eq 'unavailable' ? 'state.warn'
             :                          'text.muted';

    my $text;
    if ($kind eq 'failed') {
        # S2.4.4's table requires FAILED, the op and the %err detail here --
        # deliberately NOT the item key: the row's own key is what a reader
        # would otherwise use to tell this banner apart from the list row,
        # but $detail already carries the identifying context it needs.
        # t05-no-colons: the separator is an en-dash-style " - ", matching the
        # one the `unavailable` branch below already used between its own two
        # parts. Operator: "we use way too many instances of the character `:`.
        # Its distracting. We need none of them." $detail is DATA and is passed
        # through untouched (blueprint Decision 20) -- only the separator this
        # file authors changes.
        $text = 'FAILED' . (length($op) ? " $op" : '') . ' - ' . $detail;
    } elsif ($kind eq 'unavailable') {
        $text = 'unavailable' . (length($op) ? " - $op" : '') . ' - ' . $detail;
    } else {
        $text = $detail;
    }
    return [ { text => $text, role => $role } ];
}

# _list_row_spans(\%row, $is_selected) -> \@spans (S2.4.5).
sub _list_row_spans {
    my ($row, $is_selected) = @_;
    $row = {} if ref($row) ne 'HASH';
    my $approved = $row->{approved} ? 1 : 0;
    my $glyph    = Theme::glyph('cursor');
    $glyph = '' if !defined $glyph;
    my $gw = Theme::glyph_width('cursor');
    $gw = 1 if !defined $gw;
    my $prefix = $is_selected ? ($glyph . ' ') : (' ' x ($gw + 1));
    return [
        { text => $prefix, role => 'accent' },
        { text => sprintf('%-*s ', STATE_COL() - 1, STATE_LABEL($approved)), role => STATE_ROLE($approved) },
        { text => _bounded_key($row->{key}), role => 'text.primary' },
    ];
}

# _summary_row(\@rows, \%vp) -> \@spans -- always exactly one row (S2.4.5).
sub _summary_row {
    my ($rows_ref, $vp) = @_;
    my $c = counts($rows_ref);
    # Pluralised through the one helper, not hand-written: this row and the
    # dashboard's backpack summary state the SAME counts and are asserted
    # against each other (t/67 AC-L7), so they must also share the grammar.
    my $text = tui::DashboardScreen::count_of($c->{total}, 'item') . ", $c->{approved} approved";
    $text .= ", $c->{pending} pending" if $c->{pending} > 0;
    my @spans = ( { text => $text, role => 'text.muted' } );
    my @extra;
    if (ref($vp) eq 'HASH') {
        push @extra, "+$vp->{above} above" if $vp->{above};
        push @extra, "+$vp->{below} below" if $vp->{below};
    }
    push @spans, { text => '   ' . join(', ', @extra), role => 'text.faint' } if @extra;
    return \@spans;
}

# _detail_lines(\%row|undef) -> \@lines (S2.4.5). At most DETAIL_ROWS() rows.
sub _detail_lines {
    my ($row) = @_;
    my @lines;
    if (ref($row) eq 'HASH' && defined($row->{item}) && ref($row->{item}) eq 'HASH') {
        my $it = $row->{item};
        my $n = 0;
        for my $spec ( [ 'install', $it->{install} ], [ 'verify', $it->{verify} ], [ 'rationale', $it->{rationale} ] ) {
            last if $n >= DETAIL_ROWS();
            my $r = tui::DashboardScreen::row(label => $spec->[0], value => $spec->[1]);
            next unless ref($r) eq 'ARRAY' && @$r;
            push @lines, $r;
            $n++;
        }
    } else {
        push @lines, tui::DashboardScreen::row(
            label => 'detail', value => 'unavailable - the backpack file is not wired to this screen', force => 1);
    }
    return \@lines;
}

# panels(\%ss, $cols, $rows) -> \@panels -- the list panel is always first
# (S2.4.5). $rows is an internal third argument compose() threads through
# for real windowing; the spec's public form (S2.4) is panels(\%ss, $cols)
# -- 2 arguments. S2 fix: a bare 2-argument call used to compute window()
# with a height of 0 (an absent $rows_n coerces to 0 -- S2.4.6), which
# tui::Screen::viewport correctly reports as "0 visible rows" -- so EVERY
# item row silently vanished whenever the list was non-empty, even though
# $total was never zero and the empty-state fallback below therefore never
# fired either. A direct 2-argument caller now gets every row, unwindowed
# (no scroll clipping to compute without a terminal-row budget); compose()
# still always supplies $rows_n and gets the real windowed viewport exactly
# as before -- tui::Screen::compose's own height clipping (S2.4.5) is what
# ultimately bounds what reaches the terminal in that path.
sub panels {
    my ($ss, $cols, $rows_n) = @_;
    $ss = {} if ref($ss) ne 'HASH';
    my $rows_ref = (ref($ss->{rows}) eq 'ARRAY') ? $ss->{rows} : [];
    my $total    = scalar @$rows_ref;
    my $vp       = defined($rows_n)
        ? window($ss, $rows_n, $cols)
        : { first => 0, last => $total - 1, above => 0, below => 0, count => $total };

    my @lines;
    if ($vp->{count} > 0) {
        my $cursor = $ss->{cursor};
        $cursor = 0 if !defined($cursor) || ref($cursor) || $cursor !~ /^-?\d+$/;
        for my $i ($vp->{first} .. $vp->{last}) {
            push @lines, _list_row_spans($rows_ref->[$i], ($i == $cursor));
        }
    } elsif (!$total) {
        if (ref($ss->{load_error}) eq 'HASH' && $ss->{load_error}{broken}) {
            push @lines, [ { text => '(listing unavailable - the backpack could not be read)', role => 'state.crit' } ];
        } else {
            push @lines, [ { text => '(no backpack items)', role => 'text.muted' } ];
        }
    }
    push @lines, _summary_row($rows_ref, $vp);

    my @panels_out = ( { title => 'items', lines => \@lines } );

    my $sel = _selected_row($ss);
    if ($total > 0) {
        push @panels_out, { title => 'selected item', lines => _detail_lines($sel) };
    }

    return \@panels_out;
}

# screen(\%ss, $cols, $rows) -> \%screen (S2.4.5).
sub screen {
    my ($ss, $cols, $rows_n) = @_;
    $ss = {} if ref($ss) ne 'HASH';
    return {
        title       => [ { text => 'backpack', role => 'accent' } ],
        title_role  => 'accent',
        banners     => banners($ss),
        # S3 (fix-batch, deliberately NOT applied): the spec's S2.4.5 table
        # pins this fallback literal to state.crit. Tried and reverted: this
        # value governs the PADDING tui::Frame::make_cell adds behind every
        # banner whose own spans don't fill the row width -- not just
        # failed ones. Setting it to state.crit paints crit-coloured
        # padding behind an 'ok'/'noop'/'unavailable' banner too (any
        # banner shorter than the terminal width, i.e. almost always), and
        # directly reddened AC-W2 ("no state.crit span is produced when
        # save succeeds") -- an already-passing acceptance criterion that
        # is itself a direct expression of behaviour 25/criterion 5 ("only
        # a broken/failed condition produces state.crit"). The spec's own
        # literal table conflicts with its own deeper behavioural
        # requirement here; flagged for the driver rather than shipped
        # alongside a regression in a criterion-5 core assertion. Fallback
        # ONLY: every banner this module builds supplies its own span role
        # explicitly (S2.4.5 #1/#2).
        banner_role => 'text.muted',
        panels      => panels($ss, $cols, $rows_n),
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
