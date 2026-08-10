# tui::LaunchScreens -- the launch-phase screens for claude-sandbox
# (blueprint unified-tui-design-system, package 08-launcher-screens).
# See specs/08-launcher-screens-spec.md.
#
# PURE AND TOTAL. Every I/O boundary is an injected coderef: there is no
# filesystem here, no subprocess, no clock, no environment read and no
# console write. The launcher owns all of those and hands them in as seams,
# which is what lets t/68 exercise every screen with no terminal, no podman
# and no child process at all.
#
# THEME ROLES ONLY. Every span this file produces carries a role that
# tui::Frame::is_known_role accepts; the legacy vocabulary is mapped through
# tui::DashboardScreen::theme_role. The only escape sequences named below are
# the four terminal-control strings of S2.1 -- cursor/screen/title control,
# never colour.
package tui::LaunchScreens;
use strict;
use warnings;
use Theme;
use tui::Layout;
use tui::Frame;
use tui::Screen;
use tui::DashboardScreen;

# ---------------------------------------------------------------------------
# Small total helpers. Every one of these survives undef, a ref, a blessed
# object and a 10 KB string without dying and without emitting a diagnostic.
# ---------------------------------------------------------------------------

sub _is_num {
    my ($x) = @_;
    return 0 if !defined $x || ref $x;
    return ($x =~ /^-?\d+(?:\.\d+)?$/) ? 1 : 0;
}

sub _int {
    my ($x, $default) = @_;
    return $default unless _is_num($x);
    return int($x);
}

sub _str {
    my ($x) = @_;
    return '' if !defined $x || ref $x;
    return "$x";
}

sub _code {
    my ($x, $default) = @_;
    return (ref($x) eq 'CODE') ? $x : $default;
}

# _pairs(@list) -> \%hash built from a flat argument list, skipping any pair
# whose key is undef or a reference. Assigning such a list straight into a
# hash would emit a diagnostic on an undef key, and S3 behaviour 51 forbids
# this module from producing one for ANY input.
sub _pairs {
    my (@args) = @_;
    my %h;
    while (@args >= 2) {
        my $k = shift @args;
        my $v = shift @args;
        next if !defined $k || ref $k;
        $h{"$k"} = $v;
    }
    return \%h;
}

sub _try {
    my ($cb, @args) = @_;
    return unless ref($cb) eq 'CODE';
    my @r = eval { $cb->(@args) };
    return @r;
}

sub _glyph {
    my ($name) = @_;
    my $g;
    eval { $g = Theme::glyph($name); 1 };
    return (defined $g && !ref $g) ? $g : '';
}

sub _safe_text {
    my ($s) = @_;
    my $t = '';
    eval { $t = tui::Frame::safe($s); 1 };
    return defined $t && !ref $t ? $t : '';
}

# _seam(\%host, $name, $default) -> the host's seam coderef or $default.
sub _seam {
    my ($host, $name, $default) = @_;
    return $default unless ref $host eq 'HASH';
    my $s = $host->{seams};
    return $default unless ref $s eq 'HASH';
    return _code($s->{$name}, $default);
}

# ===========================================================================
# S2.1 -- terminal control and teardown. These four byte strings are the ONE
# source for what entering and leaving the alt screen means, so "exactly as
# the current teardown does" is true by construction rather than by a second
# implementation drifting away from the first.
# ===========================================================================

sub ENTER_TITLE_BYTES  { return "\e[22;0t" }
sub ENTER_SCREEN_BYTES { return "\e[?1049h\e[?25l" }
sub LEAVE_TITLE_BYTES  { return "\e]0;\a\e[23;0t" }
sub LEAVE_SCREEN_BYTES { return "\e[?25h\e[?1049l" }

sub TEARDOWN_OPS { return [ 'title-restore', 'screen-restore', 'readmode-restore' ] }

sub RENDER_TAIL_DEFAULT { return 400 }

# make_host(%seams) -> \%host. Every seam is optional and defensively
# defaulted, exactly as tui::BackpackScreen::run defaults its own.
sub make_host {
    my $s = _pairs(@_);

    my $mode = _str($s->{mode});
    $mode = 'plain' unless $mode eq 'tui';

    my $out = _code($s->{out}, sub { });
    my %seams = (
        mode      => $mode,
        out       => $out,
        err       => _code($s->{err}, $out),
        read_mode => _code($s->{read_mode}, sub { }),
        plain     => _code($s->{plain}, sub { }),
        now       => _code($s->{now}, sub { 0 }),
        heartbeat => _code($s->{heartbeat}, sub { }),
        term_size => _code($s->{term_size}, sub { (80, 24) }),
        render    => _code($s->{render}, sub { '' }),
        title     => _str($s->{title}),
        keep      => (_is_num($s->{keep}) ? int($s->{keep}) : RENDER_TAIL_DEFAULT()),
    );

    return {
        mode     => $mode,
        active   => 0,
        entered  => 0,
        left     => 0,
        ops      => [],
        stages   => [],
        capture  => capture_new(@_),
        banners  => [],
        degraded => 0,
        seams    => \%seams,
    };
}

# host_enter(\%host) -> 0|1.
sub host_enter {
    my ($host) = @_;
    return 0 unless ref $host eq 'HASH';
    return 0 unless _str($host->{mode}) eq 'tui';
    return 0 if $host->{entered};

    my $out = _seam($host, 'out', undef);
    my $rm  = _seam($host, 'read_mode', undef);

    _try($rm, 'cbreak');
    _try($out, ENTER_TITLE_BYTES());
    _try($out, ENTER_SCREEN_BYTES());

    my $seams = ref $host->{seams} eq 'HASH' ? $host->{seams} : {};
    my $title = _str($seams->{title});
    if (length $title) {
        _try($out, "\e]0;" . _safe_text($title) . "\a");
    }

    $host->{entered} = 1;
    $host->{active}  = 1;
    $host->{ops} = [] unless ref $host->{ops} eq 'ARRAY';
    push @{ $host->{ops} }, 'enter';
    return 1;
}

# host_leave(\%host) -> 0|1. The title pop is once-only (a second Ctrl-C
# during teardown must not pop a stack entry belonging to an outer
# application); the screen restore and the read-mode restore run every time.
# Never dies: a seam that blows up still leaves the remaining steps to run,
# because a teardown that gives up half-way is the failure this ordering
# exists to prevent.
sub host_leave {
    my ($host) = @_;
    return 0 unless ref $host eq 'HASH';
    return 0 unless $host->{entered};

    my $out = _seam($host, 'out', undef);
    my $rm  = _seam($host, 'read_mode', undef);
    $host->{ops} = [] unless ref $host->{ops} eq 'ARRAY';
    my $ops = $host->{ops};

    my $n = _int($host->{left}, 0);
    $host->{left} = $n + 1;

    if ($n == 0) {
        _try($out, LEAVE_TITLE_BYTES());
        push @$ops, 'title-restore';
    }
    _try($out, LEAVE_SCREEN_BYTES());
    push @$ops, 'screen-restore';
    _try($rm, 'restore');
    push @$ops, 'readmode-restore';

    $host->{active} = 0;
    return 1;
}

# host_handover(\%host) -> 0|1 -- the dashboard takes the same alt screen
# over. NO leave bytes are emitted, so the screen is owned continuously and
# the operator never sees a flash between the launch frame and the dashboard.
sub host_handover {
    my ($host) = @_;
    return 0 unless ref $host eq 'HASH';
    $host->{active} = 0;
    $host->{ops} = [] unless ref $host->{ops} eq 'ARRAY';
    push @{ $host->{ops} }, 'handover';
    return 1;
}

# add_banner(\%host, \@lines, $emit_role) -> count added. Banners are ordered
# most-important-first, so tui::Screen::compose drops the least important one
# first when the frame is short.
sub add_banner {
    my ($host, $lines, $role) = @_;
    return 0 unless ref $host eq 'HASH';
    my @l;
    if (ref $lines eq 'ARRAY') { @l = @$lines }
    elsif (defined $lines && !ref $lines) { @l = ($lines) }
    return 0 unless @l;

    my $tr = emit_theme_role(defined $role ? $role : 'warn');
    $host->{banners} = [] unless ref $host->{banners} eq 'ARRAY';
    my $n = 0;
    for my $ln (@l) {
        next if ref $ln;
        push @{ $host->{banners} }, [ { text => _str($ln), role => $tr } ];
        $n++;
    }
    return $n;
}

# ===========================================================================
# S2.2 -- the capture pipeline. TWO SINKS, and only one of them is lossy.
#
#   raw sink    -- receives every payload VERBATIM, before any sanitising,
#                  wrapping, width fitting or re-encoding, and is unbounded.
#                  This is what a failure report replays.
#   render ring -- bounded to `keep` entries and lossy by design. It exists
#                  only to draw a live tail inside the frame.
#
# The whole of done-criterion 2 rests on those being two sinks rather than
# one: the frame can truncate because the raw sink cannot.
# ===========================================================================

sub capture_new {
    my $s = _pairs(@_);
    my $keep = _is_num($s->{keep}) ? int($s->{keep}) : RENDER_TAIL_DEFAULT();
    $keep = 1 if $keep < 1;

    my $buf = '';
    my $rw  = _code($s->{raw_write}, undef);
    my $rr  = _code($s->{raw_read},  undef);

    return {
        keep      => $keep,
        ring      => [],
        count     => 0,
        errors    => 0,
        raw_write => ($rw ? $rw : sub { $buf .= (defined $_[0] && !ref $_[0]) ? $_[0] : ''; 1 }),
        raw_read  => ($rr ? $rr : sub { $buf }),
    };
}

# capture_line(\%cap, $bytes, $role) -> 0|1. An ABSENT line is not an empty
# line: undef is a no-op on every sink and returns 0, while '' is forwarded
# and returns 1.
sub capture_line {
    my ($cap, $bytes, $role) = @_;
    return 0 unless ref $cap eq 'HASH';
    return 0 if !defined $bytes || ref $bytes;

    my $ok = eval { $cap->{raw_write}->($bytes) if ref $cap->{raw_write} eq 'CODE'; 1 };
    $cap->{errors} = _int($cap->{errors}, 0) + 1 unless $ok;

    eval {
        my $t = _safe_text($bytes);
        $cap->{ring} = [] unless ref $cap->{ring} eq 'ARRAY';
        push @{ $cap->{ring} }, { text => $t, role => emit_theme_role($role) };
        my $keep = _int($cap->{keep}, RENDER_TAIL_DEFAULT());
        $keep = 1 if $keep < 1;
        my $over = scalar(@{ $cap->{ring} }) - $keep;
        splice(@{ $cap->{ring} }, 0, $over) if $over > 0;
        1;
    };

    $cap->{count} = _int($cap->{count}, 0) + 1;
    return 1;
}

sub capture_replay {
    my ($cap) = @_;
    return '' unless ref $cap eq 'HASH';
    my $v;
    eval { $v = $cap->{raw_read}->() if ref $cap->{raw_read} eq 'CODE'; 1 };
    return (defined $v && !ref $v) ? $v : '';
}

sub capture_tail {
    my ($cap) = @_;
    return [] unless ref $cap eq 'HASH';
    return ref $cap->{ring} eq 'ARRAY' ? $cap->{ring} : [];
}

sub capture_count {
    my ($cap) = @_;
    return 0 unless ref $cap eq 'HASH';
    return _int($cap->{count}, 0);
}

sub capture_sink_errors {
    my ($cap) = @_;
    return 0 unless ref $cap eq 'HASH';
    return _int($cap->{errors}, 0);
}

# fanout(\@sinks, $bytes) -> the number that did not blow up. The payload is
# passed IDENTICALLY to every sink, which is what lets the transcript and the
# display be provably fed the same bytes from one call site.
sub fanout {
    my ($sinks, $bytes) = @_;
    return 0 unless ref $sinks eq 'ARRAY';
    my $n = 0;
    for my $s (@$sinks) {
        next unless ref $s eq 'CODE';
        my $ok = eval { $s->($bytes); 1 };
        $n++ if $ok;
    }
    return $n;
}

# ===========================================================================
# S2.3 -- the emit seam. One route for every launch-phase byte.
# ===========================================================================

sub EMIT_ROLES { return [ 'step', 'ok', 'warn', 'err', 'plain' ] }

# infer_role($stream, $text) -> an emit role. Pure. This is what lets the
# re-plumb leave every existing message string verbatim in launcher.pl: the
# role is DERIVED from the text rather than re-authored beside it.
sub infer_role {
    my ($stream, $text) = @_;
    return 'plain' if !defined $text || ref $text;
    my $t = _safe_text($text);
    $t =~ s/\A\s+//;
    return 'err'  if index($t, 'ERROR') == 0;
    return 'warn' if index($t, 'WARNING') == 0;
    return 'warn' if index($t, 'NOTE') == 0;
    return 'err'  if _str($stream) eq 'err';
    return 'plain';
}

# emit_theme_role($emit_role) -> a Theme role, obtained through
# tui::DashboardScreen::theme_role and never spelled as an escape or a hex
# literal. Every colour on the TUI path comes from here.
sub emit_theme_role {
    my ($r) = @_;
    my %legacy = (
        step  => 'accent',
        ok    => 'good',
        warn  => 'warn',
        err   => 'bad',
        plain => 'body',
    );
    my $k = _str($r);
    my $l = exists $legacy{$k} ? $legacy{$k} : 'body';
    my $out;
    eval { $out = tui::DashboardScreen::theme_role($l); 1 };
    return (defined $out && !ref $out) ? $out : 'text.primary';
}

# emit(\%host, \%rec) -> 0|1. On the plain path the record goes to the plain
# seam exactly once and NOTHING is captured -- the plain path's bytes stay
# exactly today's. emit never touches the transcript; that is a separate sink
# with an unchanged feed.
sub emit {
    my ($host, $rec) = @_;
    $rec = {} unless ref $rec eq 'HASH';

    if (ref $host ne 'HASH' || _str($host->{mode}) ne 'tui' || !$host->{active}) {
        my $p = _seam($host, 'plain', undef);
        _try($p, $rec);
        return 0;
    }

    my $role = (defined $rec->{role} && !ref $rec->{role} && length "$rec->{role}")
        ? "$rec->{role}"
        : infer_role($rec->{stream}, $rec->{text});
    capture_line($host->{capture}, $rec->{text}, $role);
    repaint($host);
    return 1;
}

# STREAM_REPAINT_EVERY -- how many streamed subprocess lines share one frame
# repaint. A `podman build` emits thousands of lines and a repaint is a full
# compose + diff + a real GetTerminalSize ioctl, so one repaint per line makes
# the frame the slowest part of the build. The tail is a tail: coalescing a
# handful of lines into one paint is invisible to the operator and the
# residual is always flushed by the stage_end repaint that follows every
# streamed command.
sub STREAM_REPAINT_EVERY { return 8 }

# stream_line(\%host, $bytes) -> 0|1 -- the sink _tee_system hands each
# subprocess line to. The heartbeat tick here is the ONLY one available
# during a long blocking in-container install pass, which has no key loop of
# its own (S2.12), so it fires on EVERY line -- only the PAINT is throttled.
sub stream_line {
    my ($host, $bytes) = @_;
    return 0 if ref $host ne 'HASH' || _str($host->{mode}) ne 'tui' || !$host->{active};
    capture_line($host->{capture}, $bytes, 'plain');
    _try(_seam($host, 'heartbeat', undef));

    my $every   = STREAM_REPAINT_EVERY();
    my $pending = _int($host->{stream_pending}, 0) + 1;
    if ($pending >= $every) {
        $host->{stream_pending} = 0;
        repaint($host);
    }
    else {
        $host->{stream_pending} = $pending;
    }
    return 1;
}

# tee_should_fork($host_active, $has_transcript) -> 0|1. With the host active
# we must capture even when there is no transcript, because a child with
# inherited stdio paints straight over the frame.
sub tee_should_fork {
    my ($active, $has_transcript) = @_;
    return 1 if $active;
    return $has_transcript ? 1 : 0;
}

# tee_fallback_route($host_active) -> where an unforkable command must go.
sub tee_fallback_route {
    my ($active) = @_;
    return $active ? 'plain-after-teardown' : 'plain';
}

# ===========================================================================
# S2.4 -- the progress screen.
# ===========================================================================

sub STAGE_IDS {
    return [ 'preflight', 'select', 'image', 'create', 'backpack', 'start', 'install', 'dashboard' ];
}

sub STAGE_STATES { return [ 'pending', 'active', 'ok', 'skipped', 'failed' ] }

sub STAGE_LABEL {
    my ($id) = @_;
    my %label = (
        preflight => 'preflight checks',
        select    => 'skills, plugins and MCP',
        image     => 'image build',
        create    => 'container create',
        backpack  => 'backpack approval',
        start     => 'container start',
        install   => 'in-container install',
        dashboard => 'dashboard',
    );
    my $k = _str($id);
    return exists $label{$k} ? $label{$k} : '';
}

sub _stage_role {
    my ($state) = @_;
    my %role = (
        pending => 'text.faint',
        active  => 'accent',
        ok      => 'state.ok',
        skipped => 'text.muted',
        failed  => 'state.crit',
    );
    my $k = _str($state);
    return exists $role{$k} ? $role{$k} : 'text.faint';
}

sub _stage_glyph {
    my ($state) = @_;
    my %g = (
        pending => 'status.idle',
        active  => 'cursor',
        ok      => 'status.ok',
        skipped => 'sep.dot',
        failed  => 'status.crit',
    );
    my $k = _str($state);
    return exists $g{$k} ? _glyph($g{$k}) : '';
}

sub stages_init {
    my ($ids) = @_;
    my @ids = (ref $ids eq 'ARRAY')
        ? (grep { defined($_) && !ref($_) } @$ids)
        : @{ STAGE_IDS() };
    return [ map { { id      => "$_",
                     label   => STAGE_LABEL($_),
                     state   => 'pending',
                     started => undef,
                     ended   => undef } } @ids ];
}

sub _find_stage {
    my ($stages, $id) = @_;
    return undef unless ref $stages eq 'ARRAY';
    my $k = _str($id);
    for my $s (@$stages) {
        next unless ref $s eq 'HASH';
        return $s if _str($s->{id}) eq $k;
    }
    return undef;
}

# stage_state -> undef for an id the model does not carry. An UNKNOWN stage
# and a NOT-YET-STARTED stage are different facts and must not collapse.
sub stage_state {
    my ($stages, $id) = @_;
    my $s = _find_stage($stages, $id);
    return undef unless $s;
    return _str($s->{state});
}

sub stage_begin {
    my ($stages, $id, $now) = @_;
    my $s = _find_stage($stages, $id);
    return 0 unless $s;
    $s->{state}   = 'active';
    $s->{started} = _is_num($now) ? $now + 0 : undef;
    return 1;
}

sub stage_end {
    my ($stages, $id, $state, $now) = @_;
    my $st = _str($state);
    my %valid = map { $_ => 1 } @{ STAGE_STATES() };
    return 0 unless $valid{$st};
    my $s = _find_stage($stages, $id);
    return 0 unless $s;
    $s->{state} = $st;
    $s->{ended} = _is_num($now) ? $now + 0 : undef;
    return 1;
}

# _output_min_cols($cols) -- the output panel's layout demand.
#
# The intent is fixed: the output tail always owns a FULL-WIDTH band row, at
# every terminal width, so the stage list and the log tail never sit side by
# side in half a screen each. tui::Layout::place demotes a band row when a
# panel's min_cols exceeds its band width, so the honest expression of "give
# me the whole row" is "more than half of what is available" -- floored at
# the library's two-column breakpoint, which is the value the narrow case
# needs and the only breakpoint constant this module is allowed to name.
#
# The breakpoint ALONE is not sufficient: past twice its width a two-way
# split already gives each band more than the breakpoint, so the demotion
# silently stops happening exactly on the wide terminals where a split would
# be most visible.
#
# The remainder matters, and getting it wrong is silent. tui::Layout::divide
# hands the leftover column to the LAST band, and the output panel IS the last
# panel -- so at an ODD width the last band is int($c/2)+1 wide, exactly what
# an int($c/2)+1 demand asks for, and `min_cols > band_width` is then FALSE.
# The demotion stopped happening at 179, 181, 183 ... 259 while every sampled
# even width kept working. Ask for one more than the band actually gets:
# ($c - int($c/2)) IS the last band's width, so +1 is strictly greater at
# every width, odd and even alike.
sub _output_min_cols {
    my ($cols) = @_;
    my $c = _int($cols, 80);
    $c = 80 if $c < 1;
    my $bp   = tui::Layout::BREAKPOINT_TWO_COL();
    my $half = $c - int($c / 2) + 1;
    return ($bp > $half) ? $bp : $half;
}

# _output_height($rows, $n_banners, $n_stages) -- how many tail entries the
# output panel may carry. Deliberately CONSERVATIVE: tui::Screen clips a
# panel's body from the TOP, so handing it more lines than fit would drop the
# NEWEST ones -- the exact opposite of a tail that follows.
sub _output_height {
    my ($rows, $nb, $ns) = @_;
    my $r = _int($rows, 24);
    my $h = $r - 2 - _int($nb, 0) - (_int($ns, 0) + 2) - 1;
    return $h < 1 ? 1 : $h;
}

# progress_screen(\%host, $cols, $rows) -> \%screen. $rows is an optional
# third argument compose_progress threads through so the output tail can be
# sliced to what will actually fit; a two-argument call gets a sane default.
sub progress_screen {
    my ($host, $cols, $rows) = @_;
    $host = {} unless ref $host eq 'HASH';
    my $c = _int($cols, 80);
    $c = 80 if $c < 1;

    my $cap = ref $host->{capture} eq 'HASH' ? $host->{capture} : undef;

    my @banners;
    my $lost = $cap ? capture_sink_errors($cap) : 0;
    if ($lost > 0) {
        push @banners, [ { text => 'diagnostic output was lost: '
                                 . $lost . ' line(s) never reached the capture sink',
                           role => 'state.crit' } ];
    }
    if (ref $host->{banners} eq 'ARRAY') {
        for my $b (@{ $host->{banners} }) {
            push @banners, $b if ref $b eq 'ARRAY';
        }
    }

    my @stages = (ref $host->{stages} eq 'ARRAY') ? @{ $host->{stages} } : ();
    my @stage_rows;
    for my $s (@stages) {
        next unless ref $s eq 'HASH';
        my $state = _str($s->{state});
        $state = 'pending' unless length $state;
        my $role  = _stage_role($state);
        my $glyph = _stage_glyph($state);
        push @stage_rows, [
            { text => $glyph . ' ',        role => $role },
            { text => _str($s->{label}),   role => 'text.primary' },
            { text => '  ' . $state,       role => $role },
        ];
    }

    my @entries = $cap ? @{ capture_tail($cap) } : ();
    my $oh = _output_height($rows, scalar @banners, scalar @stage_rows);
    my $vp = tui::Screen::viewport(scalar @entries, $oh, undef);
    my @out_rows;
    if (scalar(@entries) && $vp->{count} > 0) {
        for my $i ($vp->{first} .. $vp->{last}) {
            my $e = ref $entries[$i] eq 'HASH' ? $entries[$i] : {};
            my $role = _str($e->{role});
            $role = 'text.primary' unless tui::Frame::is_known_role($role);
            push @out_rows, [ { text => _str($e->{text}), role => $role } ];
        }
    }
    push @out_rows, [ { text => '(no output yet)', role => 'text.muted' } ] unless @out_rows;

    my $seams = ref $host->{seams} eq 'HASH' ? $host->{seams} : {};
    my $title = _str($seams->{title});
    $title = 'claude-sandbox' unless length $title;

    return {
        title       => [ { text => $title, role => 'accent' } ],
        title_role  => 'accent',
        banners     => \@banners,
        banner_role => 'state.warn',
        panels      => [
            { title => 'stages', lines => \@stage_rows, body => \@stage_rows },
            { title => 'output', lines => \@out_rows,   body => \@out_rows,
              min_cols => _output_min_cols($c) },
        ],
        footer      => 'Ctrl-C aborts the launch',
        footer_role => 'text.faint',
    };
}

sub compose_progress {
    my ($host, $rows, $cols) = @_;
    my $r = _int($rows, 24);
    my $c = _int($cols, 80);
    $r = 24 if $r < 1;
    $c = 80 if $c < 1;
    return tui::Screen::compose(progress_screen($host, $c, $r), $r, $c);
}

sub repaint {
    my ($host) = @_;
    return 0 unless ref $host eq 'HASH';
    return 0 unless _str($host->{mode}) eq 'tui' && $host->{active};

    my ($c, $r) = (80, 24);
    my @dim = _try(_seam($host, 'term_size', undef));
    if (@dim >= 2) {
        $c = _int($dim[0], 80);
        $r = _int($dim[1], 24);
    }
    $c = 80 if $c < 1;
    $r = 24 if $r < 1;

    my $frame = compose_progress($host, $r, $c);
    my @bytes = _try(_seam($host, 'render', undef), $host->{prev}, $frame);
    my $b = (@bytes && defined $bytes[0] && !ref $bytes[0]) ? $bytes[0] : '';
    _try(_seam($host, 'out', undef), $b);
    $host->{prev} = $frame;
    $host->{stream_pending} = 0;   # this paint discharged the streamed backlog
    return 1;
}

# failure_report(\%host, %opts) -> \@chunks.
#
# A build/create/start failure LEAVES the TUI entirely and then writes the
# captured output verbatim to the restored normal screen. A fixed-height
# frame cannot show a 200-line build failure without truncating it or
# inventing a pager, and the operator's next action is to read and copy the
# error out of scroll-back -- which requires it to BE in scroll-back. The
# live in-frame tail is what the run needs; the full text on exit is what
# done-criterion 2 needs, and the two-sink capture is what makes them
# compatible.
#
# The observable property: the joined chunks contain capture_replay() as an
# exact substring, for every corpus.
sub failure_report {
    my ($host, @rest) = @_;
    my $o = _pairs(@rest);

    my $cap = (ref $host eq 'HASH' && ref $host->{capture} eq 'HASH') ? $host->{capture} : undef;
    my $replay = $cap ? capture_replay($cap) : '';

    my $stage = _str($o->{stage});
    my $msg   = _str($o->{message});

    my $head = 'launch failed';
    $head .= " at stage '" . $stage . "'" if length $stage;
    $head .= ': ' . $msg                  if length $msg;
    $head .= ' (code ' . int($o->{exit}) . ')' if _is_num($o->{exit});

    return [ $replay, "\n" . ('-' x 60) . "\n", $head . "\n" ];
}

# ===========================================================================
# S2.5 -- the list screen. One screen, three modes: a multi-select picker, a
# single-choice list and the backpack triage differ only in what a keystroke
# does to a row's state.
# ===========================================================================

sub LIST_MODES     { return [ 'multi', 'single', 'triage' ] }
sub TRIAGE_STATES  { return [ 'defer', 'approve', 'remove' ] }
sub DROP_IS_UNDOABLE { return 0 }

sub DROP_WARNING {
    return 'removing an item rewrites backpack.json on disk - it is permanent and cannot be undone';
}

sub LIST_FOOTER_LEGEND {
    my ($mode) = @_;
    my $m = _str($mode);
    return 'up/down move   space or enter choose   q cancel' if $m eq 'single';
    return 'up/down move   space cycle   a approve   n defer   r remove   enter confirm   q cancel'
        if $m eq 'triage';
    return 'up/down move   space toggle   a all in group   n none in group   enter confirm   q cancel';
}

sub _ls_items {
    my ($ls) = @_;
    return [] unless ref $ls eq 'HASH';
    return $ls->{items} if ref $ls->{items} eq 'ARRAY';
    my $m = $ls->{model};
    return $m->{items} if ref $m eq 'HASH' && ref $m->{items} eq 'ARRAY';
    return [];
}

sub _landable {
    my ($items, $i) = @_;
    return 0 unless ref $items eq 'ARRAY';
    return 0 unless _is_num($i);
    $i = int($i);
    return 0 if $i < 0 || $i > $#$items;
    my $it = $items->[$i];
    return 0 unless ref $it eq 'HASH';
    return 0 unless _str($it->{kind}) eq 'row';
    return 0 if $it->{disabled};
    return 1;
}

sub list_init {
    my $s = _pairs(@_);
    my $model = ref $s->{model} eq 'HASH' ? $s->{model} : {};

    my $mode = _str($model->{mode});
    my %ok = map { $_ => 1 } @{ LIST_MODES() };
    $mode = 'multi' unless $ok{$mode};

    my $err = $model->{error};
    $err = (defined $err && !ref $err && length "$err") ? "$err" : undef;

    my $notice = $model->{notice};
    $notice = (defined $notice && !ref $notice && length "$notice") ? "$notice" : undef;

    # SHORTCUTS (package 12): { 'r' => '<row id>' } -- a single-keystroke alias
    # for "move the cursor to that row and choose it", used by single-mode
    # screens converted from hand-rolled menus that already advertised letter
    # keys. Normalised here so list_dispatch_key never has to think about
    # shape: lowercased, single printable characters only, non-scalar values
    # dropped. An id that names no landable row is NOT rejected at init (the
    # rows can legitimately be built later) -- the dispatch looks it up and
    # ignores a miss.
    my %short;
    if (ref $model->{shortcuts} eq 'HASH') {
        for my $k (keys %{ $model->{shortcuts} }) {
            next if ref $k;
            my $lk = lc "$k";
            next unless length($lk) == 1;
            my $id = $model->{shortcuts}{$k};
            next if ref $id;
            next unless defined($id) && length "$id";
            $short{$lk} = "$id";
        }
    }

    my $ls = {
        mode        => $mode,
        shortcuts   => \%short,
        notice      => $notice,
        notice_role => _str($model->{notice_role}),
        label     => _str($model->{label}),
        error     => $err,
        items     => (ref $model->{items} eq 'ARRAY' ? $model->{items} : []),
        model     => $model,
        cursor    => undef,
        confirm   => undef,
        status    => undef,
        confirmed => 0,
        cancelled => 0,
        closed    => 0,
    };
    $ls->{cursor} = list_first_row($ls);
    return $ls;
}

sub list_first_row {
    my ($ls) = @_;
    my $items = _ls_items($ls);
    for my $i (0 .. $#$items) {
        return $i if _landable($items, $i);
    }
    return undef;
}

# list_advance(\%ls, $delta) -> the landed index, or undef when there is no
# landable row at all. Headers, subheaders and disabled rows are skipped; the
# cursor clamps at both ends.
sub list_advance {
    my ($ls, $delta) = @_;
    return undef unless ref $ls eq 'HASH';
    my $items = _ls_items($ls);
    return undef unless @$items;

    my $d = _is_num($delta) ? int($delta) : 1;
    $d = 1 if $d == 0;
    my $cur = _is_num($ls->{cursor}) ? int($ls->{cursor}) : -1;

    my $i = $cur + $d;
    while ($i >= 0 && $i <= $#$items) {
        if (_landable($items, $i)) {
            $ls->{cursor} = $i;
            return $i;
        }
        $i += $d;
    }
    return $cur if _landable($items, $cur);
    return undef;
}

sub _cursor_item {
    my ($ls) = @_;
    my $items = _ls_items($ls);
    return undef unless ref $ls eq 'HASH';
    my $cur = _is_num($ls->{cursor}) ? int($ls->{cursor}) : -1;
    return undef unless _landable($items, $cur);
    return $items->[$cur];
}

sub _group_of {
    my ($it) = @_;
    my $g = _str(ref $it eq 'HASH' ? $it->{group} : '');
    return length $g ? $g : 'default';
}

sub _set_group {
    my ($ls, $value) = @_;
    my $cur = _cursor_item($ls);
    return 0 unless $cur;
    my $g = _group_of($cur);
    my $items = _ls_items($ls);
    for my $it (@$items) {
        next unless ref $it eq 'HASH';
        next unless _str($it->{kind}) eq 'row';
        next if $it->{disabled};
        next unless _group_of($it) eq $g;
        $it->{selected} = $value;
    }
    return 1;
}

sub _select_only_cursor {
    my ($ls) = @_;
    my $cur = _cursor_item($ls);
    my $items = _ls_items($ls);
    for my $it (@$items) {
        next unless ref $it eq 'HASH';
        $it->{selected} = 0 if _str($it->{kind}) eq 'row';
    }
    $cur->{selected} = 1 if $cur;
    return 1;
}

# list_dispatch_key(\%ls, $key) -> one of the closed action set. Mutates only
# the cursor, the armed confirm and a row's selected/state; it never persists
# and never renders.
#
# RULE ORDER: the armed-confirm arm is checked FIRST, before the cancel keys,
# so 'q' while a remove is armed cancels the MARK and does not also close the
# screen. All action keys are lowercase apart from the 'Y' alias: an
# unassembled CSI sequence arrives as '[' then a single uppercase letter, and
# with no uppercase action keys such a sequence degrades to inert keystrokes
# rather than to an accidental destructive action.
sub list_dispatch_key {
    my ($ls, $key) = @_;
    return '' unless ref $ls eq 'HASH';
    my $k = (defined $key && !ref $key) ? "$key" : '';
    return '' unless length $k;

    my $mode = _str($ls->{mode});
    $mode = 'multi' unless length $mode;

    if (ref $ls->{confirm} eq 'HASH') {
        my $idx = $ls->{confirm}{index};
        $ls->{confirm} = undef;
        if ($k eq 'y' || $k eq 'Y') {
            my $items = _ls_items($ls);
            if (_landable($items, $idx)) {
                $items->[int($idx)]{state} = 'remove';
            }
            return 'mark-remove';
        }
        return 'cancel-remove';
    }

    # A transient status ("unavailable - no removable row") belongs to the
    # keystroke that produced it, not to the rest of the screen's life. Only a
    # SUCCESSFUL 'r' used to clear it, so a single mis-aimed 'r' left a warn
    # banner pinned above every later frame, permanently mis-describing rows
    # the operator had since moved to. Any subsequent keystroke retires it;
    # the arm below re-sets it if the condition is still true.
    $ls->{status} = undef;

    return 'cancel' if $k eq 'q' || $k eq 'ESC' || $k eq "\e";

    if ($k eq 'UP' || $k eq 'k') { list_advance($ls, -1); return 'move' }
    if ($k eq 'DOWN' || $k eq 'j') { list_advance($ls, 1); return 'move' }

    if ($k eq 'ENTER') {
        _select_only_cursor($ls) if $mode eq 'single';
        return 'confirm';
    }

    if ($k eq 'SPACE') {
        if ($mode eq 'single') {
            _select_only_cursor($ls);
            return 'confirm';
        }
        my $cur = _cursor_item($ls);
        return '' unless $cur;
        if ($mode eq 'triage') {
            my $st = _str($cur->{state});
            $cur->{state} = ($st eq 'approve') ? 'defer' : 'approve';
        } else {
            $cur->{selected} = $cur->{selected} ? 0 : 1;
        }
        return 'toggle';
    }

    # Single-keystroke row aliases, checked BEFORE the a/n/r blocks below:
    # each of those returns '' for single mode, so a shortcut sharing one of
    # those letters would otherwise be swallowed as inert. Deliberately AFTER
    # cancel and movement, so 'q' stays cancel and 'j'/'k' stay movement no
    # matter what a caller declares -- a screen must not be able to redefine
    # the keys every other screen shares.
    if ($mode eq 'single' && ref $ls->{shortcuts} eq 'HASH' && length($k) == 1) {
        my $want = $ls->{shortcuts}{ lc $k };
        if (defined $want && length $want) {
            my $items = _ls_items($ls);
            for my $i (0 .. $#$items) {
                next unless _landable($items, $i);
                next unless _str($items->[$i]{id}) eq $want;
                $ls->{cursor} = $i;
                _select_only_cursor($ls);
                return 'confirm';
            }
        }
    }

    if ($k eq 'a') {
        return '' if $mode eq 'single';
        if ($mode eq 'triage') {
            my $cur = _cursor_item($ls);
            return '' unless $cur;
            $cur->{state} = 'approve';
            return 'group-all';
        }
        return '' unless _set_group($ls, 1);
        return 'group-all';
    }

    if ($k eq 'n') {
        return '' if $mode eq 'single';
        if ($mode eq 'triage') {
            my $cur = _cursor_item($ls);
            return '' unless $cur;
            $cur->{state} = 'defer';
            return 'group-none';
        }
        return '' unless _set_group($ls, 0);
        return 'group-none';
    }

    if ($k eq 'r') {
        return '' unless $mode eq 'triage';
        # NEVER ARM A CONFIRM YOU CANNOT FIRE. With no landable cursor row
        # there is nothing to remove, so the screen says so instead of
        # showing a warning for an action that would then do nothing.
        my $cur = _cursor_item($ls);
        unless ($cur) {
            $ls->{status} = { text => 'unavailable - no removable row under the cursor',
                              role => 'state.warn' };
            return '';
        }
        $ls->{status}  = undef;
        $ls->{confirm} = { index => int($ls->{cursor}), id => _str($cur->{id}) };
        return 'confirm-remove';
    }

    return '';
}

sub list_apply {
    my ($ls, $action) = @_;
    return 0 unless ref $ls eq 'HASH';
    my $a = _str($action);
    if ($a eq 'confirm') {
        $ls->{confirmed} = 1;
        $ls->{cancelled} = 0;
        $ls->{closed}    = 1;
        return 1;
    }
    if ($a eq 'cancel') {
        $ls->{cancelled} = 1;
        $ls->{confirmed} = 0;
        $ls->{closed}    = 1;
        return 1;
    }
    return 0;
}

# list_selection(\%ls) -> \%decision. Ids within a group preserve MODEL
# order and are never sorted. A cancel decides nothing: the selection is
# empty and all three triage lists are empty.
sub list_selection {
    my ($ls) = @_;
    $ls = {} unless ref $ls eq 'HASH';
    my $cancelled = $ls->{cancelled} ? 1 : 0;
    my $confirmed = $ls->{confirmed} ? 1 : 0;

    my %sel;
    my %tri = (approve => [], remove => [], defer => []);
    my $cursor_id;

    unless ($cancelled) {
        my $items = _ls_items($ls);
        my $mode  = _str($ls->{mode});
        my $cur   = _is_num($ls->{cursor}) ? int($ls->{cursor}) : -1;
        if ($cur >= 0 && $cur <= $#$items && ref $items->[$cur] eq 'HASH') {
            my $cid = _str($items->[$cur]{id});
            $cursor_id = $cid if length $cid;
        }
        for my $it (@$items) {
            next unless ref $it eq 'HASH';
            next unless _str($it->{kind}) eq 'row';
            my $id = _str($it->{id});
            next unless length $id;
            if ($mode eq 'triage') {
                my $st = _str($it->{state});
                $st = 'defer' unless exists $tri{$st};
                push @{ $tri{$st} }, $id;
            }
            elsif ($it->{selected}) {
                push @{ $sel{ _group_of($it) } ||= [] }, $id;
            }
        }
    }

    # POSITION, not name. Two distinct backpack items can share one
    # "category:name" identity string ({npm-global, "a:b"} and
    # {"npm-global:a", b} both key as "npm-global:a:b"), and a decision map
    # keyed by that string silently applies ONE row's answer to the OTHER row
    # -- a confirmed non-undoable remove landing on the item the operator just
    # approved. The row's position in the model is unique by construction, so
    # the caller gets an index-keyed answer alongside the id-keyed one and
    # applies whichever its own model supports.
    my %tri_idx = (approve => [], remove => [], defer => []);
    unless ($cancelled) {
        my $items = _ls_items($ls);
        if (_str($ls->{mode}) eq 'triage') {
            for my $it (@$items) {
                next unless ref $it eq 'HASH';
                next unless _str($it->{kind}) eq 'row';
                next unless _is_num($it->{index});
                my $st = _str($it->{state});
                $st = 'defer' unless exists $tri_idx{$st};
                push @{ $tri_idx{$st} }, int($it->{index});
            }
        }
    }

    return {
        confirmed    => $confirmed,
        cancelled    => $cancelled,
        selected     => \%sel,
        cursor_id    => $cursor_id,
        triage       => \%tri,
        triage_index => \%tri_idx,
    };
}

sub list_banners {
    my ($ls) = @_;
    $ls = {} unless ref $ls eq 'HASH';
    my @b;

    my $err = $ls->{error};
    if (defined $err && !ref $err && length "$err") {
        push @b, [ { text => 'list unavailable - ' . "$err", role => 'state.crit' } ];
    }
    if (ref $ls->{confirm} eq 'HASH') {
        my $id = _str($ls->{confirm}{id});
        push @b, [ { text => 'remove ' . $id . ' - ' . DROP_WARNING()
                           . '  [y] confirms, any other key cancels',
                     role => 'state.warn' } ];
    }
    # A standing, model-declared warning about what confirming this screen
    # actually does. The plain approval walk has always printed one ("These
    # install/verify commands run AS ROOT in the container"); without an
    # equivalent here the TUI path would be the only route to an as-root
    # approval that never says so.
    my $notice = $ls->{notice};
    if (defined $notice && !ref $notice && length "$notice") {
        my $role = _str($ls->{notice_role});
        $role = 'state.crit' unless tui::Frame::is_known_role($role);
        push @b, [ { text => "$notice", role => $role } ];
    }
    if (ref $ls->{status} eq 'HASH') {
        my $role = _str($ls->{status}{role});
        $role = 'state.warn' unless tui::Frame::is_known_role($role);
        push @b, [ { text => _str($ls->{status}{text}), role => $role } ];
    }
    return \@b;
}

sub _row_spans {
    my ($ls, $items, $i) = @_;
    my $it = $items->[$i];
    return [ { text => '', role => 'text.muted' } ] unless ref $it eq 'HASH';

    my $kind = _str($it->{kind});
    my $disp = _str($it->{display});
    return [ { text => $disp, role => 'accent' } ]            if $kind eq 'header';
    return [ { text => '  ' . $disp, role => 'text.muted' } ] if $kind eq 'subheader';

    my $cur = _is_num($ls->{cursor}) ? int($ls->{cursor}) : -1;
    my $marker = ($i == $cur) ? (_glyph('cursor') . ' ') : '  ';

    my $mode = _str($ls->{mode});
    my ($mark, $mark_role);
    if ($mode eq 'triage') {
        my $st = _str($it->{state});
        $st = 'defer' unless length $st;
        $mark = '[' . $st . ']';
        $mark_role = $st eq 'approve' ? 'state.ok'
                   : $st eq 'remove'  ? 'state.crit'
                   :                    'text.muted';
    }
    elsif ($mode eq 'single') {
        # NO CHECKBOX. A single-choice menu has exactly one answer and the
        # cursor already IS that answer, so a '[x]'/'[ ]' column states the
        # same fact twice while promising something it cannot deliver: a
        # checkbox is an invitation to tick more than one, and in this mode
        # the first tick closes the screen. Rendering multi-select chrome on
        # a menu is a UX lie, not a cosmetic wrinkle -- it was reported from
        # a live launch as "it's not a select-multiple step and shouldn't
        # have the semantics of one".
        $mark = '';
        $mark_role = 'text.faint';
    }
    else {
        $mark = $it->{selected} ? '[x]' : '[ ]';
        $mark_role = $it->{selected} ? 'state.ok' : 'text.faint';
    }

    my @spans = (
        { text => $marker, role => 'accent' },
        (length($mark) ? { text => $mark . ' ', role => $mark_role } : ()),
        { text => $disp,   role => ($it->{disabled} ? 'text.muted' : 'text.primary') },
    );
    my $badge = _str($it->{badge});
    push @spans, { text => ' (' . $badge . ')', role => 'text.faint' } if length $badge;
    return \@spans;
}

# list_screen(\%ls, $cols, $rows) -> \%screen. $rows is an optional third
# argument compose_list threads through so the visible window can be computed
# with tui::Screen::viewport rather than re-implemented here.
sub list_screen {
    my ($ls, $cols, $rows) = @_;
    $ls = {} unless ref $ls eq 'HASH';
    my $c = _int($cols, 80);
    my $r = _int($rows, 24);
    $c = 80 if $c < 1;
    $r = 24 if $r < 1;

    my $banners = list_banners($ls);
    my $items   = _ls_items($ls);
    my $total   = scalar @$items;

    my $lh = $r - 2 - scalar(@$banners) - 1 - 1;
    $lh = 0 if $lh < 0;
    my $vp = tui::Screen::viewport($total, $lh, $ls->{cursor});

    my $err = $ls->{error};
    $err = (defined $err && !ref $err && length "$err") ? "$err" : undef;

    my @lines;
    if (defined $err) {
        push @lines, [ { text => '(list unavailable - ' . $err . ')', role => 'state.crit' } ];
    }
    elsif ($total == 0) {
        push @lines, [ { text => '(nothing to choose)', role => 'text.muted' } ];
    }
    elsif ($vp->{count} > 0) {
        for my $i ($vp->{first} .. $vp->{last}) {
            push @lines, _row_spans($ls, $items, $i);
        }
    }

    my $nrows = 0;
    my $nsel  = 0;
    my $mode  = _str($ls->{mode});
    for my $it (@$items) {
        next unless ref $it eq 'HASH';
        next unless _str($it->{kind}) eq 'row';
        $nrows++;
        if ($mode eq 'triage') { $nsel++ if _str($it->{state}) eq 'approve' }
        else                   { $nsel++ if $it->{selected} }
    }

    # "N item(s), M selected" is MULTI-SELECT LANGUAGE and belongs only to a
    # screen where a count is a real quantity the operator is accumulating. On
    # a single-choice menu the count is always "one, eventually", so the line
    # says nothing and actively miscommunicates -- it reads as a running tally
    # on a screen that has no tally. Single mode keeps the scroll hints, which
    # are still true and still useful, and drops the counter.
    my @summary;
    push @summary, { text => $nrows . ' item(s), ' . $nsel . ' selected', role => 'text.muted' }
        unless $mode eq 'single';
    my @extra;
    push @extra, '+' . $vp->{above} . ' above' if $vp->{above};
    push @extra, '+' . $vp->{below} . ' below' if $vp->{below};
    if (@extra) {
        push @summary, { text => (@summary ? '   ' : '') . join(', ', @extra), role => 'text.faint' };
    }
    push @lines, \@summary if @summary;

    my $label = _str($ls->{label});
    $label = 'select' unless length $label;

    return {
        title       => [ { text => $label, role => 'accent' } ],
        title_role  => 'accent',
        banners     => $banners,
        banner_role => 'state.warn',
        # 'items' is inventory language; a menu offers OPTIONS. The divider is
        # the one piece of panel chrome the operator cannot switch off, so it
        # should at least name what it is dividing.
        panels      => [ { title => ($mode eq 'single' ? 'options' : 'items'),
                           lines => \@lines, body => \@lines } ],
        footer      => LIST_FOOTER_LEGEND($mode),
        footer_role => 'text.faint',
    };
}

sub compose_list {
    my ($ls, $rows, $cols) = @_;
    my $r = _int($rows, 24);
    my $c = _int($cols, 80);
    $r = 24 if $r < 1;
    $c = 80 if $c < 1;
    return tui::Screen::compose(list_screen($ls, $c, $r), $r, $c);
}

# IDLE_POLL_LIMIT -- the fourth exit, and the one that does not depend on the
# caller getting the mode gate right.
#
# The three contract exits (list_apply returned 1, max_ticks, a null poll with
# no wait_key) all fail to fire for a host whose STDIN is at EOF: wait_key IS
# a coderef, so the null-poll exit is skipped, and a blocking read on a closed
# stdin returns immediately rather than blocking, so the loop spins at 100%
# CPU inside an alt screen with no reachable exit. That is not hypothetical --
# `claude-sandbox </dev/null` reached exactly this state. The mode gate is
# fixed too, but a liveness guarantee that rests entirely on the caller is not
# a guarantee.
#
# The bound is on CONSECUTIVE empty polls, so any keystroke resets it. At the
# 0.2s default tick a real idle operator would need hours of untouched
# keyboard to reach it, while an EOF spin (each poll returning instantly)
# burns through it in a fraction of a second.
sub IDLE_POLL_LIMIT { return 100_000 }

# list_run(%seams) -> \%result -- the modal loop.
#
# TERMINATION IS GUARANTEED BY CONSTRUCTION, three ways: list_apply returned
# 1, max_ticks was reached, or a poll yielded nothing and wait_key is not a
# coderef -- plus IDLE_POLL_LIMIT above as the backstop for the EOF case none
# of the three covers. A test scripting a finite read_key with no wait_key
# therefore cannot hang.
#
# The heartbeat is ticked once per iteration, before the key poll, INCLUDING
# idle iterations -- an idle operator is precisely the case the container's
# keep-alive exists for, and a tick cap is not a substitute.
sub list_run {
    my $s = _pairs(@_);
    my $ls = list_init(model => $s->{model});

    my $read_key  = _code($s->{read_key}, sub { undef });
    my $wait_key  = _code($s->{wait_key}, undef);
    my $term_size = _code($s->{term_size}, sub { (80, 24) });
    my $render    = _code($s->{render}, sub { '' });
    my $out       = _code($s->{out}, sub { });
    my $heartbeat = _code($s->{heartbeat}, sub { });
    my $tick      = _is_num($s->{tick}) ? $s->{tick} + 0 : 0.2;
    my $max_ticks = _is_num($s->{max_ticks}) ? int($s->{max_ticks}) : undef;

    my $idle_limit = _is_num($s->{idle_limit}) ? int($s->{idle_limit}) : IDLE_POLL_LIMIT();
    $idle_limit = 1 if $idle_limit < 1;

    my $prev;
    my $ticks = 0;
    my $idle  = 0;

    my $paint = sub {
        my ($c, $r) = (80, 24);
        my @dim = _try($term_size);
        if (@dim >= 2) { $c = _int($dim[0], 80); $r = _int($dim[1], 24) }
        $c = 80 if $c < 1;
        $r = 24 if $r < 1;
        my $frame = compose_list($ls, $r, $c);
        my @b = _try($render, $prev, $frame);
        my $bytes = (@b && defined $b[0] && !ref $b[0]) ? $b[0] : '';
        _try($out, $bytes);
        $prev = $frame;
    };

    $paint->();

    while (1) {
        last if defined($max_ticks) && $ticks >= $max_ticks;
        eval { $heartbeat->() };

        my @k = _try($read_key);
        my $key = @k ? $k[0] : undef;
        if (!defined($key) || ref($key) || !length("$key")) {
            if ($wait_key) {
                my @w = _try($wait_key, $tick);
                $key = @w ? $w[0] : undef;
            }
            else { last }
        }
        $ticks++;
        unless (defined($key) && !ref($key) && length("$key")) {
            # A poll that yielded nothing. Bounded so a wait_key that cannot
            # block (EOF on stdin) cannot spin here forever; any real key
            # resets the run.
            last if ++$idle >= $idle_limit;
            next;
        }
        $idle = 0;

        my $action = list_dispatch_key($ls, $key);
        my $done   = list_apply($ls, $action);

        # The instant a remove confirm ARMS, discard whatever is already
        # queued in the non-blocking input buffer. Without this, type-ahead
        # (a 'y' entered before the operator could possibly have seen the
        # warning) fires a non-undoable action with the warning never
        # actually displayed. Bounded, so a hostile read_key cannot hang it.
        if ($action eq 'confirm-remove' && ref $ls->{confirm} eq 'HASH') {
            my $guard = 0;
            while ($guard++ < 1000) {
                my @f = _try($read_key);
                my $flushed = @f ? $f[0] : undef;
                last unless defined($flushed) && !ref($flushed) && length("$flushed");
            }
        }

        $paint->();
        last if $done;
    }

    my $decision = list_selection($ls);
    return {
        closed    => 1,
        confirmed => $decision->{confirmed},
        cancelled => $decision->{cancelled},
        ticks     => $ticks,
        decision  => $decision,
    };
}

# ===========================================================================
# S2.6 -- the backpack triage model.
#
# Item identity is carried, never recomputed: the launch-side planner stamps
# each item with the exact approval key it produced, and this module passes
# that byte string through unchanged. Nothing here decodes on one side and
# encodes on the other -- the display copy may be width-bounded, the identity
# copy never is.
# ===========================================================================

sub _item_key {
    my ($it) = @_;
    return '' unless ref $it eq 'HASH';
    for my $field ('_approval_key', 'id', 'key') {
        my $v = $it->{$field};
        return "$v" if defined $v && !ref $v && length "$v";
    }
    return '';
}

# AS_ROOT_WARNING -- the TUI path's equivalent of the plain walk's banner. An
# approval gate whose whole purpose is a root-privileged command must SAY that
# on the screen where the approval happens.
sub AS_ROOT_WARNING {
    return 'these install/verify commands run AS ROOT inside the container - review each one';
}

# _detail_row($label, $value) -> a non-landable subheader carrying one of the
# commands being approved. The cursor skips subheaders, so these read as
# annotation on the row above them rather than as separately-selectable rows.
sub _detail_row {
    my ($label, $value) = @_;
    my $v = _str($value);
    $v = '(none given)' unless length $v;
    return { kind => 'subheader', disabled => 1, display => _str($label) . ': ' . $v };
}

sub triage_model {
    my ($pending, $approved, @rest) = @_;
    my $o = _pairs(@rest);

    my @items;
    my $i = -1;
    for my $it (@{ ref $pending eq 'ARRAY' ? $pending : [] }) {
        $i++;
        next unless ref $it eq 'HASH';
        my $key = _item_key($it);
        next unless length $key;
        # `index` is the row's POSITION in the caller's pending array, and it
        # is what the caller's decision map is keyed by. Two items can share
        # one "category:name" identity string; they cannot share a position.
        push @items, { kind     => 'row',
                       id       => $key,
                       index    => $i,
                       group    => 'backpack',
                       display  => $key,
                       disabled => 0,
                       state    => 'defer' };
        # THE COMMANDS THEMSELVES. Rendering only the item's NAME made the
        # screen approve, as root, text the operator was never shown -- which
        # also made BackpackReview::_safe and backpack.pl validate's
        # control-character rejection pointless, since both exist purely to
        # make a DISPLAYED command trustworthy. tui::Frame::safe sanitises
        # every span on the way into a cell; this is the second half of that
        # belt and braces, not a replacement for it.
        push @items, _detail_row('install',   $it->{install});
        push @items, _detail_row('verify',    $it->{verify});
        push @items, _detail_row('rationale', $it->{rationale});
    }

    my @ok = grep { ref $_ eq 'HASH' } @{ ref $approved eq 'ARRAY' ? $approved : [] };
    if (@ok) {
        push @items, { kind => 'subheader', display => 'already approved' };
        for my $it (@ok) {
            my $key = _item_key($it);
            next unless length $key;
            push @items, { kind     => 'row',
                           id       => $key,
                           group    => 'backpack',
                           display  => $key,
                           disabled => 1,
                           state    => 'defer' };
        }
    }

    my $err = $o->{error};
    $err = (defined $err && !ref $err && length "$err") ? "$err" : undef;

    return {
        mode        => 'triage',
        label       => 'backpack approval',
        error       => $err,
        notice      => AS_ROOT_WARNING(),
        notice_role => 'state.crit',
        items       => \@items,
    };
}

# ===========================================================================
# Package 12 -- the single-choice menu model.
#
# The launch flow had three hand-rolled menus that package 08 deliberately
# left alone (spec 08 section 6): the stale/rebuild prompt, the orphan-claude kill
# confirm, and the connector's lost-container hold. Each painted its own
# highlight, drove its own cbreak, and redrew in place with \e[<n>A -- so the
# launcher had to tear the TUI frame DOWN and hand the real terminal back for
# their duration. This builder replaces all three with one model, which is
# the point: three menus meant three chances to get teardown wrong, and the
# operator saw three different visual languages in a single launch.
#
# menu_model(%opts) -> a single-mode list model.
#   label    -- the screen title
#   detail   -- \@lines of context ABOVE the options (the stale reasons, the
#               orphan list, the reason a container was lost). Non-landable:
#               the cursor skips them, so they read as annotation.
#   options  -- \@[ { id, display, key } ] in presentation order. `key` is
#               optional; when given it becomes a single-keystroke alias so a
#               converted menu keeps the letter shortcut it used to advertise.
#   notice   -- optional one-line banner, with notice_role for its colour.
#
# The display string is left to the caller INCLUDING any "[r] " prefix: the
# shortcut letter has to be visible on the row, and only the caller knows
# whether it declared one.
sub menu_model {
    my %o = %{ _pairs(@_) };

    my @items;
    for my $line (@{ ref $o{detail} eq 'ARRAY' ? $o{detail} : [] }) {
        next if ref $line;
        next unless defined $line;
        push @items, { kind => 'subheader', disabled => 1, display => _str($line) };
    }

    my %short;
    for my $opt (@{ ref $o{options} eq 'ARRAY' ? $o{options} : [] }) {
        next unless ref $opt eq 'HASH';
        my $id = _str($opt->{id});
        next unless length $id;
        my $disp = _str($opt->{display});
        $disp = $id unless length $disp;
        push @items, { kind => 'row', id => $id, group => 'menu', display => $disp };
        my $key = _str($opt->{key});
        $short{ lc $key } = $id if length($key) == 1;
    }

    return {
        mode        => 'single',
        label       => _str($o{label}),
        notice      => (defined $o{notice} && !ref $o{notice} && length "$o{notice}")
                        ? "$o{notice}" : undef,
        notice_role => _str($o{notice_role}),
        error       => undef,
        empty       => (@items ? 0 : 1),
        shortcuts   => \%short,
        items       => \@items,
    };
}

# menu_choice(\%result, $default) -> the chosen option id.
#
# A CANCEL IS NOT A CHOICE. It returns $default, and every caller passes the
# conservative option -- the legacy menus all treated q/ESC as "do the
# non-destructive thing", and a converted screen that instead returned the
# cursor's row would silently rebuild a container because the operator hit
# escape.
sub menu_choice {
    my ($res, $default) = @_;
    $default = _str($default);
    return $default unless ref $res eq 'HASH';
    my $d = ref $res->{decision} eq 'HASH' ? $res->{decision} : {};
    return $default if $d->{cancelled};
    return $default unless $d->{confirmed};
    my $id = _str($d->{cursor_id});
    return length($id) ? $id : $default;
}

# ===========================================================================
# S2.11 -- the mode gate. This module may not name the dashboard module, so
# the decision arrives as a seam and the launcher binds it to the existing,
# unmodified three-argument gate. The safe degradation is ALWAYS plain.
# ===========================================================================
sub choose_mode {
    my ($cb, $is_tty, $readkey_ok, $force_plain) = @_;
    return 'plain' unless ref $cb eq 'CODE';
    my $r;
    my $ok = eval { $r = $cb->($is_tty, $readkey_ok, $force_plain); 1 };
    return 'plain' unless $ok;
    return 'plain' if !defined $r || ref $r;
    return "$r" if $r eq 'tui' || $r eq 'plain';
    return 'plain';
}

# ===========================================================================
# S2.9 -- the units of launcher.pl the emit re-plumb must cover. Declared
# here so the oracle derives its scan targets rather than repeating a list.
# The list may grow.
# ===========================================================================
sub EMIT_UNITS {
    return [
        { kind => 'sub',    name => 'build_image' },
        { kind => 'sub',    name => 'run_perl_or_die' },
        { kind => 'sub',    name => '_capture_or_die' },
        { kind => 'sub',    name => '_surface_last_reap' },
        { kind => 'sub',    name => 'pick_session_action' },
        { kind => 'sub',    name => '_tee_system' },
        { kind => 'region', name => 'launch-emit:select' },
        { kind => 'region', name => 'launch-emit:ports' },
        { kind => 'region', name => 'launch-emit:create' },
        { kind => 'region', name => 'launch-emit:backpack' },
    ];
}

1;
