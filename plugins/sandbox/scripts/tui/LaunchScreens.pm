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
# Encode is intentionally NOT `use`d here -- tui::Frame already loads it
# (S2.0's closed use/require list, AC-N7), and its fully-qualified
# Encode::encode is reachable once tui::Frame has been required.

# Detail-row geometry for the approval screen. The indent is two columns deeper
# than an item row's cursor marker so a detail reads as subordinate to the item
# above it; the gutter is the widest label ('rationale') so install, verify and
# rationale values start in one column and the commands can be scanned. The
# separator is DashboardScreen's, deliberately -- a second separator width would
# make two label conventions in one TUI.
use constant DETAIL_INDENT => '    ';
use constant DETAIL_GUTTER => 9;
use constant GUTTER_SEP    => tui::DashboardScreen::GUTTER_SEP();

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
    # 'prepare' covers what used to be a SILENT stretch. Between the select
    # stage ending and create beginning, the launcher ran ~1600 lines of
    # main-flow work -- skill mounts, the plugin store, credentials, a WSL
    # host-IP probe, session selection, the whole claude-home layout -- with no
    # stage marker. Since _launch_stage_begin is the only thing that repaints in
    # that phase, the frame kept showing whatever was last drawn: on a stale
    # sandbox, the operator chose an option and then watched a dead menu for
    # 20+ seconds (bug report 20260829-194441-fd0a). The work was never the
    # problem; its invisibility was.
    #
    # THE ORDER HERE IS THE ORDER THE LAUNCHER RUNS THEM IN, and it is checked
    # mechanically (t/37 AC5) rather than trusted.
    #
    # It has now moved twice, and the history is the argument for the check.
    # Originally 'preflight, select, image, ...' while the launcher built the
    # image BEFORE the picker -- so the operator watched 'skills, plugins and
    # MCP' sit pending while the row below it went green. That was corrected to
    # put image second on 2026-09-04.
    #
    # On 2026-09-07 the launcher itself changed: nothing is built until the
    # operator has answered the rebuild prompt, which cannot be asked until the
    # picker has run. So the build genuinely happens after select now, and the
    # declaration follows it back. AC5 caught this the moment the launcher
    # moved, naming both sequences -- which is exactly what it was written for,
    # and what the hand-copied pin in t/68 could never have done.
    return [ 'preflight', 'select', 'image', 'prepare', 'create', 'backpack', 'start', 'install', 'dashboard' ];
}

sub STAGE_STATES { return [ 'pending', 'active', 'ok', 'skipped', 'failed' ] }

sub STAGE_LABEL {
    my ($id) = @_;
    my %label = (
        preflight => 'preflight checks',
        select    => 'skills, plugins and MCP',
        # 'base image build', not 'image build'. The operator asked whether
        # 'image build  skipped' meant their Rebuild had been ignored, or
        # whether they were "confusing things on image build vs container
        # create" -- and both readings were available from the row alone. This
        # stage is the SHARED claude-sandbox:latest image, built once and reused
        # by every project; 'container create' below it is this project's own
        # container. Skipping the first while doing the second is the normal
        # case, and the word 'base' is what says so.
        image     => 'base image build',
        prepare   => 'host files and mounts',
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

# STAGE_ELAPSED_AFTER -- seconds an ACTIVE stage runs before its row starts
# showing how long it has been running (bug report 20261110-165535-d71b: a
# wedged podman left "skills, plugins and MCP" looking exactly like a slow
# step). Below it every healthy stage finishes before the figure would be
# read, so the panel stays still; past it the elapsed time is the difference
# between "slow" and "stuck". The figure is tui::DashboardScreen::fmt_duration's
# -- the one duration format -- so it reads "<1m", then "1m", "2m" ...
sub STAGE_ELAPSED_AFTER { return 10 }

# stage_elapsed(\%stage, $now) -> seconds an active stage has run, or undef
# when it is not active, has no start time, or $now is not a real clock
# reading (the host's default now seam answers 0).
sub stage_elapsed {
    my ($s, $now) = @_;
    return undef unless ref $s eq 'HASH' && _str($s->{state}) eq 'active';
    return undef unless _is_num($s->{started}) && _is_num($now) && $now > 0;
    my $e = $now - $s->{started};
    return $e < 0 ? undef : $e;
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
    # chrome_rows(), not the literal 2 it was: the chrome is title + the footer
    # rule + footer since 2026-08. Read from tui::Screen -- being one row
    # optimistic here is not cosmetic, it makes tui::Screen clip the panel from
    # the top and drop the NEWEST output line, which is the one thing this
    # function exists to protect.
    my $h = $r - tui::Screen::chrome_rows() - _int($nb, 0) - (_int($ns, 0) + 2) - 1;
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

    # PAD THE LABEL COLUMN so the states form one. This used to emit
    # label . '  ' . state with no padding, which put the state at a different
    # column on every row -- 'dashboard  pending' and
    # 'skills, plugins and MCP  ok' share nothing to read down. The states are
    # the only part of this panel that changes, so they are exactly what wants
    # to be scannable in a vertical line.
    #
    # Measured, not assumed: this alignment is only real if every glyph is the
    # same width, since the glyph precedes the label. All five
    # (status.idle/ok/crit, cursor, sep.dot) measure display_width 1 -- they are
    # U+25CB, U+25CF, U+00D7, U+25B6, U+00B7, none of them the double-width
    # CJK-range characters that would silently shift a row by a column.
    # t/68 pins that property so a future glyph swap cannot quietly break this.
    #
    # display_width, not length: labels are ASCII today and length would agree,
    # but the padding must stay correct for whatever a label becomes.
    my $label_w = 0;
    for my $s (@stages) {
        next unless ref $s eq 'HASH';
        my $w = tui::Layout::display_width(_str($s->{label}));
        $label_w = $w if $w > $label_w;
    }

    my ($now) = _try(_seam($host, 'now', undef));
    my @stage_rows;
    for my $s (@stages) {
        next unless ref $s eq 'HASH';
        my $state = _str($s->{state});
        $state = 'pending' unless length $state;
        my $role  = _stage_role($state);
        my $glyph = _stage_glyph($state);
        my $label = _str($s->{label});
        my $pad   = $label_w - tui::Layout::display_width($label);
        $pad = 0 if $pad < 0;
        my $el = stage_elapsed($s, $now);
        my $suffix = (defined $el && $el >= STAGE_ELAPSED_AFTER())
            ? '  ' . tui::DashboardScreen::fmt_duration($el) : '';
        push @stage_rows, [
            { text => $glyph . ' ',              role => $role },
            { text => $label . (' ' x $pad),     role => 'text.primary' },
            { text => '  ' . $state . $suffix,   role => $role },
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

# ===========================================================================
# S2.13 -- the session picker's shared card renderer (blueprint
# sandbox-session-ux, package 03-picker-cards). ONE renderer for both the
# plain select-session.pl loop and this dashboard's 'c' screen -- see
# specs/03-picker-cards-spec.md S2.
# ===========================================================================

# RESIZE_SETTLE_POLLS -- how many EXTRA full repaints follow a detected
# resize, mirroring Dashboard.pm's RESIZE_SETTLE_TICKS lesson: a maximize can
# reflow after it is first reported.
sub RESIZE_SETTLE_POLLS { return 2 }

# _bytes($x) -- UTF-8-encode a CHARACTER string for a span's text. Every card
# field is a character string by contract (S2.1); this is the one place that
# turns it into the bytes tui::Frame::safe expects. Total over any input.
sub _bytes {
    my ($x) = @_;
    return '' unless defined $x && !ref $x;
    my $t = "$x";
    my $out = eval { Encode::encode('UTF-8', $t) };
    return defined $out ? $out : '';
}

# _card_str($x, $default) -- a defined/non-empty character string, or $default.
sub _card_str {
    my ($x, $default) = @_;
    return $default unless defined $x && !ref $x && length "$x";
    return "$x";
}

# _card_dash($x) -- a card field, dash-defaulted (started/active/ago).
sub _card_dash {
    my ($x) = @_;
    return _bytes(_card_str($x, '-'));
}

# _gutter_span($selected, $is_first_line) -- the 2-column card gutter (S2.1).
sub _gutter_span {
    my ($selected, $is_first_line) = @_;
    if ($selected) {
        my $g = $is_first_line ? _glyph('cursor') : _glyph('rule.v');
        return { text => $g . ' ', role => 'accent' };
    }
    return { text => '  ', role => 'text.primary' };
}

# _sep_spans() -- the ' <dot> ' separator, role 'rule', as THREE spans (a
# leading space, the dot glyph alone, a trailing space) so a caller looking
# for a span whose text is EXACTLY the dot glyph (S2.1's D contract) finds
# one -- a single combined span would never satisfy that exact-text lookup.
sub _sep_spans {
    return ( { text => ' ', role => 'rule' },
             { text => _glyph('sep.dot'), role => 'rule' },
             { text => ' ', role => 'rule' } );
}

# _badge_spans(\%card) -- the kind_label badge (state.warn) followed by every
# entry of card.badges (package 07's extension point), falling back to
# text.muted for an unknown role. Never dies for a hostile shape.
sub _badge_spans {
    my ($card) = @_;
    my @out;
    my $kl = ref($card) eq 'HASH' ? $card->{kind_label} : undef;
    if (defined $kl && !ref $kl && length "$kl") {
        push @out, { text => _bytes(' [' . $kl . ']'), role => 'state.warn' };
    }
    my $badges = (ref($card) eq 'HASH' && ref $card->{badges} eq 'ARRAY') ? $card->{badges} : [];
    for my $b (@$badges) {
        next unless ref $b eq 'HASH';
        my $t = (defined($b->{text}) && !ref($b->{text})) ? "$b->{text}" : '';
        next unless length $t;
        my $role = (defined($b->{role}) && !ref($b->{role}) && tui::Frame::is_known_role("$b->{role}"))
                 ? "$b->{role}" : 'text.muted';
        push @out, { text => _bytes(' [' . $t . ']'), role => $role };
    }
    return @out;
}

# _normalize_msg($s) -- collapse whitespace to single spaces, drop non-
# whitespace C0/DEL/C1 control characters, trim. undef in, undef out.
sub _normalize_msg {
    my ($s) = @_;
    return undef unless defined $s && !ref $s;
    my $t = "$s";
    $t =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\x{80}-\x{9F}]//g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A\s+//;
    $t =~ s/\s+\z//;
    return $t;
}

# _message_block($cols, $selected, $label, $text_raw) -> \@lines (1 or 2).
sub _message_block {
    my ($cols, $selected, $label, $text_raw) = @_;
    my $Lw = ($label eq 'Message:') ? 9 : 7;
    my $norm = _normalize_msg($text_raw);
    my $has_text = defined($norm) && length($norm);
    my $text_w = $cols - 4 - $Lw;

    my @lines;
    if ($text_w < 1) {
        my $g = _gutter_span($selected, 0);
        my @spans = ( $g, { text => '  ', role => 'text.muted' },
                      { text => sprintf('%-*s', $Lw, $label), role => 'text.muted' } );
        my $w = eval { tui::Frame::spans_width(\@spans) };
        if (defined($w) && $w > $cols) {
            my $fitted = eval { tui::Frame::fit_spans(\@spans, $cols, 'text.muted') };
            @spans = (ref($fitted) eq 'ARRAY') ? @$fitted : @spans;
        }
        push @lines, \@spans;
        return \@lines;
    }

    # M2: bound the text handed to wrap_capped -- at most 2 rows of $text_w
    # columns are ever shown, and after safe() every character is at least 1
    # column, so nothing beyond 2*text_w characters can ever be displayed.
    # A margin of $text_w on top of that (2.5x total, rounded up by +1)
    # covers combining/zero-width characters that collapse to fewer columns
    # than characters, while keeping the cut tight enough that per-card cost
    # stays comfortably inside the frame budget (M2's own timing bound). The
    # overflow/ellipsis decision and the displayed output are unchanged --
    # every dropped character was already beyond what 2*text_w columns could
    # ever show.
    my $cut = int(2.5 * $text_w) + 1;
    if ($has_text && length($norm) > $cut) {
        $norm = substr($norm, 0, $cut);
    }

    my $text_role = $has_text ? 'text.primary' : 'text.faint';
    my $display_text = $has_text ? _bytes($norm) : _bytes('(no message)');
    # pad_role deliberately differs from $text_role: fit_spans (inside
    # wrap_line/make_cell) merges its right-pad into the LAST span only when
    # that span's own role matches the pad role, and the content span here
    # carries its own explicit role ($text_role) via the {text,role} hashref
    # -- so a distinct pad_role keeps the pad as a separate trailing span,
    # and the content span's text stays EXACTLY the message text (S2.1's
    # "message text is text.primary" / "(no message) is text.faint" hold as
    # an exact span, not a padded one).
    my $rows = eval {
        tui::Frame::wrap_capped({ text => $display_text, role => $text_role }, 'text.muted', $text_w, 0, 2);
    };
    $rows = [] unless ref $rows eq 'ARRAY';
    @$rows = ( tui::Frame::make_cell('', $text_role, $text_w) ) unless @$rows;

    for my $i (0 .. $#$rows) {
        my $cell = $rows->[$i];
        my $g = _gutter_span($selected, 0);
        my @prefix;
        if ($i == 0) {
            # Label span kept EXACT (no padding merged in); alignment is a
            # SEPARATE span so a caller looking for the bare label text
            # ("Message:"/"First:"/"Last:") finds it verbatim.
            push @prefix, { text => '  ', role => 'text.muted' },
                           { text => $label, role => 'text.muted' },
                           { text => (' ' x ($Lw - length($label))), role => 'text.muted' };
        }
        else {
            push @prefix, { text => ('  ' . (' ' x $Lw)), role => 'text.muted' };
        }
        my $cell_spans = (ref($cell) eq 'HASH' && ref $cell->{spans} eq 'ARRAY') ? [ @{ $cell->{spans} } ] : [];
        # Drop the trailing right-pad fit_spans added to reach exactly
        # $text_w: it is always the pad_role ('text.muted') and pure
        # whitespace (see the note above the wrap_capped call), so this is
        # unambiguous. A message row is a NATURAL-length row, never padded --
        # AC-4's "no double space reaches the rendered paragraph".
        while (@$cell_spans) {
            my $last = $cell_spans->[-1];
            last unless ref($last) eq 'HASH' && _str($last->{role}) eq 'text.muted';
            my $t = defined($last->{text}) ? $last->{text} : '';
            last if $t =~ /\S/;
            pop @$cell_spans;
        }
        push @lines, [ $g, @prefix, @$cell_spans ];
    }
    return \@lines;
}

# ---------------------------------------------------------------------------
# Card render cache (Decision 30). session_card_lines is a pure function of
# (card content, cols, selected), but both picker paths sum every card's
# height on every frame to size the scroll window -- ~250ms for 300 cards.
# Height and, cheaply, the rendered lines themselves are memoised so a
# repaint after a keypress does not recompute cards that did not change.
#
# The cache key is built from the card's OWN CONTENT plus cols (and, for
# lines, selected) -- never from the hashref's address. That is deliberate:
# a refaddr-keyed cache would let a garbage-collected card's address be
# reused by an unrelated later card, silently serving that card's stale
# lines. Keying on content instead means a resize (cols changes) or a
# changed item (any content field changes) can only ever produce a
# different key, so a stale entry is never read -- there is nothing to
# invalidate, because the old key simply stops being asked for.
# ---------------------------------------------------------------------------
my %_card_height_cache;
my %_card_lines_cache;
my $_card_cache_cols;   # the terminal width the two caches above were filled at

# _card_cache_check_width($cols) -- drop both caches whole when $cols differs
# from the width they were last filled at. Keeps the memo bounded to one
# width's worth of cards no matter how many widths a resize passes through,
# since every entry for the old width is discarded together rather than
# accumulating alongside the new one.
sub _card_cache_check_width {
    my ($cols) = @_;
    $cols = _int($cols, 80);
    if (!defined($_card_cache_cols) || $_card_cache_cols != $cols) {
        %_card_height_cache = ();
        %_card_lines_cache  = ();
        $_card_cache_cols = $cols;
    }
}

# session_card_cache_clear() -- PUBLIC. Empties both memoisation caches and
# forgets the width they were filled at. Callers (e.g. a first-paint
# benchmark) use this to force a cold measurement.
sub session_card_cache_clear {
    %_card_height_cache = ();
    %_card_lines_cache  = ();
    $_card_cache_cols = undef;
    return 1;
}

# session_card_cache_size() -- PUBLIC, test-only. Returns the combined entry
# count across both caches, so a test can assert the memo stays bounded
# after cycling through several widths.
sub session_card_cache_size {
    return scalar(keys %_card_height_cache) + scalar(keys %_card_lines_cache);
}

sub _card_cache_key {
    my ($card, $cols) = @_;
    $card = {} unless ref $card eq 'HASH';
    # package 07-host-session-fork: append the badges too. Without this, a
    # host original and its fork -- identical timestamps and messages --
    # would collide on one cache entry and render each other's badge.
    my $badges = (ref $card->{badges} eq 'ARRAY') ? $card->{badges} : [];
    my $badge_key = join("\x1f", map {
        my $b = $_;
        ref($b) eq 'HASH'
            ? ((defined($b->{role}) ? $b->{role} : '') . "\x1f" . (defined($b->{text}) ? $b->{text} : ''))
            : '';
    } @$badges);
    return join("\x1e", _int($cols, 80),
        defined($card->{started})    ? $card->{started}    : '',
        defined($card->{active})     ? $card->{active}     : '',
        defined($card->{ago})        ? $card->{ago}        : '',
        defined($card->{first})      ? $card->{first}      : '',
        defined($card->{last})       ? $card->{last}       : '',
        defined($card->{kind_label}) ? $card->{kind_label} : '',
        $badge_key,
    );
}

# session_card_height(\%card, $cols) -> $height (int). Memoised per
# item-content + terminal width. Used by the "sum every card's height" pass
# (both picker paths) so sizing the scroll window never re-renders an
# off-screen card just to count its lines.
sub session_card_height {
    my ($card, $cols) = @_;
    _card_cache_check_width($cols);
    my $key = _card_cache_key($card, $cols);
    return $_card_height_cache{$key} if exists $_card_height_cache{$key};
    my $ln = session_card_lines($card, $cols, 0);
    my $h = (ref $ln eq 'ARRAY' && @$ln) ? scalar(@$ln) : 3;
    $_card_height_cache{$key} = $h;
    return $h;
}

# session_card_lines_cached(\%card, $cols, $selected) -> \@lines. Same
# memoisation, keyed additionally on $selected (selection changes the
# gutter/timestamp colour, never the line count). Only ever used for the
# visible window, so the cache stays small; also warms the height cache
# for free since the count is the same regardless of $selected.
sub session_card_lines_cached {
    my ($card, $cols, $selected) = @_;
    $selected = $selected ? 1 : 0;
    _card_cache_check_width($cols);
    my $hkey = _card_cache_key($card, $cols);
    my $key  = $hkey . "\x1e" . $selected;
    return $_card_lines_cache{$key} if exists $_card_lines_cache{$key};
    my $ln = session_card_lines($card, $cols, $selected);
    $_card_lines_cache{$key} = $ln;
    $_card_height_cache{$hkey} = (ref $ln eq 'ARRAY' && @$ln) ? scalar(@$ln) : 3;
    return $ln;
}

# session_card_lines(\%card, $cols, $selected) -> \@lines. PUBLIC, total: see
# S2.1's contract table. Height is always 3..6 lines; the last is a blank
# separator.
sub session_card_lines {
    my ($card, $cols, $selected) = @_;
    $card = {} unless ref $card eq 'HASH';
    my $c = _int($cols, 80);
    $c = 1 if $c < 1;
    $selected = $selected ? 1 : 0;

    my $ts_role = $selected ? 'accent' : 'text.primary';
    my $S = { text => _card_dash($card->{started}), role => $ts_role };
    my $A = { text => _card_dash($card->{active}),  role => $ts_role };
    my $AGO = { text => _card_dash($card->{ago}), role => 'text.faint' };

    my @f1 = ( { text => 'started ', role => 'text.muted' }, $S, _sep_spans(),
               { text => 'last active ', role => 'text.muted' }, $A, _sep_spans(), $AGO );
    my @f2 = ( $S, _sep_spans(), $A, _sep_spans(), $AGO );
    my @f3 = ( $A, _sep_spans(), $AGO );

    my @badges = _badge_spans($card);
    my $budget = $c - 2;
    $budget = 0 if $budget < 0;

    my @body;
    my $picked = 0;
    for my $cand (\@f1, \@f2, \@f3) {
        my @full = (@$cand, @badges);
        my $w = eval { tui::Frame::spans_width(\@full) };
        if (defined($w) && $w <= $budget) { @body = @full; $picked = 1; last; }
    }
    unless ($picked) {
        my @full = (@f3, @badges);
        my $room = $budget - tui::Frame::ELLIPSIS_COLS();
        if ($room > 0) {
            my $trimmed = eval { tui::Frame::fit_spans(\@full, $room, 'text.faint') };
            @body = (ref($trimmed) eq 'ARRAY' ? @$trimmed : ());
        }
        push @body, { text => tui::Frame::ELLIPSIS(), role => 'text.faint' };
    }

    my $g1 = _gutter_span($selected, 1);
    my @line1 = ( $g1, @body );
    # Safety net for pathologically narrow widths (cols < 3) where even the
    # ellipsis-only fallback above cannot fit alongside the 2-column gutter:
    # only ever engages when line 1 is ALREADY over budget, so it never
    # touches (and never pads) the exact-text cases the AC table pins.
    my $w1 = eval { tui::Frame::spans_width(\@line1) };
    if (defined($w1) && $w1 > $c) {
        my $fitted = eval { tui::Frame::fit_spans(\@line1, $c, 'text.faint') };
        @line1 = (ref($fitted) eq 'ARRAY') ? @$fitted : @line1;
    }
    my @lines = ( \@line1 );

    my $first = _normalize_msg($card->{first});
    $first = undef unless defined($first) && length($first);
    my $last  = _normalize_msg($card->{last});
    $last = undef unless defined($last) && length($last);

    if (defined($first) && defined($last) && $first ne $last) {
        push @lines, @{ _message_block($c, $selected, 'First:', $card->{first}) };
        push @lines, @{ _message_block($c, $selected, 'Last:',  $card->{last}) };
    }
    else {
        my $src = defined($first) ? $card->{first} : (defined($last) ? $card->{last} : undef);
        push @lines, @{ _message_block($c, $selected, 'Message:', $src) };
    }

    push @lines, [];
    return \@lines;
}

# session_new_lines($cols, $selected) -> \@lines, height 2: the "+ Start a new
# session" row and a blank separator.
sub session_new_lines {
    my ($cols, $selected) = @_;
    my $g = _gutter_span($selected, 1);
    return [ [ $g, { text => '+ Start a new session', role => 'accent' } ], [] ];
}

# card_window(\@heights, $cursor, $budget, $top) -> {first,last,above,below}.
# Pure; see S2.1's pseudocode. Never dies for any input.
sub card_window {
    my ($heights, $cursor, $budget, $top) = @_;
    my @h = (ref $heights eq 'ARRAY') ? @$heights : ();
    @h = map { (_is_num($_) && $_ >= 1) ? int($_) : 1 } @h;
    my $n = scalar @h;
    return { first => 0, last => -1, above => 0, below => 0 } if $n == 0;

    $cursor = _is_num($cursor) ? int($cursor) : 0;
    $cursor = 0 if $cursor < 0;
    $cursor = $n - 1 if $cursor > $n - 1;
    $top = _is_num($top) ? int($top) : 0;
    $top = 0 if $top < 0;
    $top = $n - 1 if $top > $n - 1;
    $budget = _is_num($budget) ? int($budget) : 1;
    $budget = 1 if $budget < 1;

    my $sum = sub {
        my ($a, $b) = @_;
        my $s = 0;
        $s += $h[$_] for $a .. $b;
        return $s;
    };

    $top = $cursor if $cursor < $top;
    while ($top < $cursor && $sum->($top, $cursor) > $budget) { $top++; }
    my $last = $cursor;
    while ($last + 1 < $n && $sum->($top, $last + 1) <= $budget) { $last++; }
    while ($top > 0 && $sum->($top - 1, $last) <= $budget) { $top--; }

    return { first => $top, last => $last, above => $top, below => $n - 1 - $last };
}

# session_pick_model(\@rows, $label, $error) -> \%model -- the TUI 'c' screen's
# model, built from --list-json rows. Rows that are not hashes or lack a
# defined uuid are skipped.
sub session_pick_model {
    my ($rows, $label, $error) = @_;
    my @rows = (ref $rows eq 'ARRAY') ? @$rows : ();

    my $new_row = sub {
        return { kind => 'row', id => 'NEW', group => 'sessions',
                 display => '+ Start a new session', disabled => 0, selected => 0 };
    };

    my (@user_items, @butler_items);
    for my $r (@rows) {
        next unless ref $r eq 'HASH';
        next unless defined $r->{uuid};
        my $card = (ref $r->{card} eq 'HASH') ? $r->{card} : {};
        # package 07-host-session-fork: a host row's item id is "host:<uuid>"
        # so the launcher can spawn select-session.pl --fork on it; every
        # other row (sandbox, fork) keeps its bare uuid.
        #
        # red-team S1 (defense in depth): a non-host row's `uuid` field is
        # content this module cannot fully trust (S1's spoof plants
        # `"sessionId":"host:<real host uuid>"` in a sandbox-writable file,
        # which SessionIndex's id fallback then hands straight through as
        # the row's `uuid`). If that literal string were used verbatim as a
        # non-host item id, it would ALREADY start with "host:" and be
        # indistinguishable from a genuine host row's item id at every
        # downstream consumer that matches on the "host:" prefix. Any
        # non-host row whose uuid is not itself uuid-shaped is therefore
        # given a distinct, unambiguous id prefix instead of its bare uuid
        # -- this can never collide with "host:<uuid>" and never fires for
        # a real sandbox/fork row, whose uuid is always a v4 uuid.
        my $is_host = defined($r->{origin}) && $r->{origin} eq 'host';
        my $uuid_shaped = "$r->{uuid}" =~ /\A[0-9A-Za-z]{8}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{12}\z/;
        my $id = $is_host        ? "host:$r->{uuid}"
               : $uuid_shaped    ? "$r->{uuid}"
               :                   "row:$r->{uuid}";
        my $item = { kind => 'row', id => $id, group => 'sessions', card => $card,
                     display => "$r->{uuid}", disabled => 0, selected => 0 };
        if ($r->{is_butler}) { push @butler_items, $item }
        else                 { push @user_items,   $item }
    }
    unshift @user_items,   $new_row->();
    unshift @butler_items, $new_row->();

    return {
        mode  => 'single',
        label => _str($label),
        error => (defined($error) && !ref($error) && length("$error")) ? "$error" : undef,
        items => \@user_items,
        views => [
            { name => 'user',   items => \@user_items,   empty_note => '(no user sessions)' },
            { name => 'butler', items => \@butler_items, empty_note => '(no butler sessions)' },
        ],
    };
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

    # Card mode (package 03-picker-cards): model.views is an arrayref of
    # exactly 2 hashes, each carrying an arrayref items. Anything else behaves
    # exactly as before -- ls.views stays unset.
    my $views = $model->{views};
    if (ref $views eq 'ARRAY' && @$views == 2
        && ref $views->[0] eq 'HASH' && ref $views->[0]{items} eq 'ARRAY'
        && ref $views->[1] eq 'HASH' && ref $views->[1]{items} eq 'ARRAY') {
        $ls->{views}      = $views;
        $ls->{view_index} = 0;
        $ls->{items}      = $views->[0]{items};
        $ls->{card_top}   = 0;
    }

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

    # Card mode's [t] view toggle (package 03-picker-cards). Lowercase ONLY --
    # an unassembled CSI sequence degrades to a single uppercase letter, and
    # 'T' must never toggle. Checked after cancel/movement, before shortcuts.
    if ($mode eq 'single' && ref $ls->{views} eq 'ARRAY' && $k eq 't') {
        my $vi = _is_num($ls->{view_index}) ? int($ls->{view_index}) : 0;
        $vi = $vi ? 0 : 1;
        $ls->{view_index} = $vi;
        $ls->{items}     = (ref $ls->{views}[$vi] eq 'HASH' && ref $ls->{views}[$vi]{items} eq 'ARRAY')
                          ? $ls->{views}[$vi]{items} : [];
        $ls->{cursor}    = list_first_row($ls);
        $ls->{card_top}  = 0;
        return 'toggle-view';
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
    return [ { text => $disp, role => 'accent' } ] if $kind eq 'header';

    if ($kind eq 'subheader') {
        # A structured detail row (see _detail_row) renders as three spans:
        # a pure-whitespace indent, a label padded to a shared gutter, and the
        # value. Indenting DEEPER than the item row above it is what makes the
        # detail read as belonging to that item -- the whole block used to sit
        # at the item's own indent, so nothing said which item the commands
        # were for.
        if (exists $it->{detail_label}) {
            my $label = _str($it->{detail_label});
            my $value = _str($it->{detail_value});
            return [ { text => '', role => 'text.faint' } ]
                unless length($label) || length($value);

            my $vrole = _str($it->{detail_role});
            $vrole = 'text.primary' unless tui::Frame::is_known_role($vrole);
            return [
                { text => DETAIL_INDENT(), role => 'text.faint' },
                { text => sprintf('%-*s%s', DETAIL_GUTTER(), $label, GUTTER_SEP()),
                  role => 'text.faint' },
                { text => $value, role => $vrole },
            ];
        }
        return [ { text => '  ' . $disp, role => 'text.muted' } ];
    }

    my $cur = _is_num($ls->{cursor}) ? int($ls->{cursor}) : -1;
    my $marker = ($i == $cur) ? (_glyph('cursor') . ' ') : '  ';

    my $mode = _str($ls->{mode});
    my ($mark, $mark_role);
    if ($mode eq 'triage') {
        my $st = _str($it->{state});
        $st = 'defer' unless length $st;
        # PADDED TO THE WIDEST STATE, so the item names start in one column
        # instead of stepping left and right as decisions change. '[approve]'
        # is the widest at 9; the states are a closed set (TRIAGE_STATES), so
        # this cannot be outgrown by a longer word arriving later.
        $mark = sprintf('%-*s', 9, '[' . $st . ']');
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

    # chrome_rows(), not the literal 2 it was -- see _output_height above.
    my $lh = $r - tui::Screen::chrome_rows() - scalar(@$banners) - 1 - 1;
    $lh = 0 if $lh < 0;

    # Card mode (package 03-picker-cards): a wholly separate body/footer
    # composition, sharing only the banners computed above. The non-card mode
    # below is byte-identical to before this package.
    return _card_list_screen($ls, $c, $lh, $banners) if ref $ls->{views} eq 'ARRAY';

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
    if ($mode eq 'triage') {
        # THE SAME REASONING AS 'single', APPLIED WHERE IT ALSO HOLDS. The
        # approval walk shows ONE item per screen and puts the position in the
        # label ("backpack approval - item 1 of 1"), so the footer rendered
        # "1 item(s), 0 selected": a running tally of a set with one member,
        # restating the header, with a stray "(s)" -- on a screen whose scarce
        # resource is the rows that show commands. A count earns its row only
        # once there is more than one thing to count, and then it is phrased as
        # the decision being accumulated rather than as a selection.
        push @summary, { text => $nsel . ' of ' . $nrows . ' approved',
                         role => 'text.muted' }
            if $nrows > 1;
    }
    elsif ($mode ne 'single') {
        push @summary, { text => $nrows . ' item(s), ' . $nsel . ' selected',
                         role => 'text.muted' };
    }
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
                           lines => \@lines, body => \@lines,
                           # HANGING INDENT TO THE VALUE COLUMN, for triage only.
                           # Every detail row is a label padded to a shared
                           # gutter followed by its value, and `rationale` is
                           # agent-written and routinely long. Wrapping it back
                           # to the default two columns put the continuation
                           # nowhere near the column it continued -- the value
                           # started at 16 and resumed at 6. Other modes declare
                           # nothing and keep the default.
                           #
                           # This is the distance BEYOND the row's own leading
                           # indent, not the absolute column: wrap_line adds the
                           # continuation indent on top of the indent the row
                           # already carries (DETAIL_INDENT, recovered by its
                           # step 3a-pre). Gutter + separator is exactly what
                           # remains, and 4 + 12 lands the continuation under
                           # the value.
                           ($mode eq 'triage'
                              ? (wrap_indent => DETAIL_GUTTER() + length(GUTTER_SEP()))
                              : ()) } ],
        footer      => LIST_FOOTER_LEGEND($mode),
        footer_role => 'text.faint',
    };
}

# _card_list_screen(\%ls, $cols, $lh, \@banners) -> \%screen -- list_screen's
# card-mode body/footer. ls.card_top is the only ls field this writes.
sub _card_list_screen {
    my ($ls, $c, $lh, $banners) = @_;
    my $items = _ls_items($ls);
    my $total = scalar @$items;

    my $err = $ls->{error};
    $err = (defined $err && !ref $err && length "$err") ? "$err" : undef;

    my @lines;
    my $win = { first => 0, last => -1, above => 0, below => 0 };

    if (defined $err) {
        push @lines, [ { text => '(list unavailable - ' . $err . ')', role => 'state.crit' } ];
    }
    elsif ($total == 0) {
        push @lines, [ { text => '(nothing to choose)', role => 'text.muted' } ];
    }
    else {
        my @heights;
        for my $it (@$items) {
            if (ref $it eq 'HASH' && _str($it->{id}) eq 'NEW') {
                push @heights, 2;
            }
            else {
                my $card = (ref $it eq 'HASH' && ref $it->{card} eq 'HASH') ? $it->{card} : {};
                my $h = eval { session_card_height($card, $c) };
                push @heights, (defined $h && $h >= 1) ? $h : 3;
            }
        }
        my $cursor = _is_num($ls->{cursor})   ? int($ls->{cursor})   : 0;
        my $top    = _is_num($ls->{card_top}) ? int($ls->{card_top}) : 0;
        my $budget = ($lh > 0) ? $lh : 1;
        $win = card_window(\@heights, $cursor, $budget, $top);
        $ls->{card_top} = _int($win->{first}, 0);

        if ($win->{last} >= $win->{first}) {
            for my $i ($win->{first} .. $win->{last}) {
                my $it  = $items->[$i];
                my $sel = ($i == $cursor) ? 1 : 0;
                my $ln;
                if (ref $it eq 'HASH' && _str($it->{id}) eq 'NEW') {
                    $ln = session_new_lines($c, $sel);
                }
                else {
                    my $card = (ref $it eq 'HASH' && ref $it->{card} eq 'HASH') ? $it->{card} : {};
                    $ln = eval { session_card_lines_cached($card, $c, $sel) };
                }
                push @lines, @$ln if ref $ln eq 'ARRAY';
            }
        }
        @lines = @lines[0 .. $lh - 1] if $lh > 0 && @lines > $lh;

        my $has_rows = grep { ref $_ eq 'HASH' && _str($_->{kind}) eq 'row' && _str($_->{id}) ne 'NEW' } @$items;
        if (!$has_rows && (!$lh || @lines < $lh)) {
            my $vi = _is_num($ls->{view_index}) ? int($ls->{view_index}) : 0;
            my $vw = (ref $ls->{views} eq 'ARRAY' && ref $ls->{views}[$vi] eq 'HASH') ? $ls->{views}[$vi] : {};
            my $note = _str($vw->{empty_note});
            push @lines, [ { text => '    ' . $note, role => 'text.muted' } ] if length $note;
        }
    }

    my @summary;
    my @extra;
    push @extra, '+' . $win->{above} . ' above' if $win->{above};
    push @extra, '+' . $win->{below} . ' below' if $win->{below};
    push @summary, { text => join(', ', @extra), role => 'text.faint' } if @extra;
    push @lines, \@summary if @summary;

    my $vi         = _is_num($ls->{view_index}) ? int($ls->{view_index}) : 0;
    my $view_name  = (ref $ls->{views} eq 'ARRAY' && ref $ls->{views}[$vi]     eq 'HASH') ? _str($ls->{views}[$vi]{name})     : '';
    my $other_name = (ref $ls->{views} eq 'ARRAY' && ref $ls->{views}[1 - $vi] eq 'HASH') ? _str($ls->{views}[1 - $vi]{name}) : '';
    my $footer = 'view: ' . $view_name . '   [t] show ' . $other_name . ' sessions   ' . LIST_FOOTER_LEGEND('single');

    my $label = _str($ls->{label});
    $label = 'select' unless length $label;

    return {
        title       => [ { text => $label, role => 'accent' } ],
        title_role  => 'accent',
        banners     => $banners,
        banner_role => 'state.warn',
        panels      => [ { title => 'options', lines => \@lines, body => \@lines } ],
        footer      => $footer,
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

    # Resize detection (package 03-picker-cards, S2.2): the (cols,rows) of the
    # last paint, and how many settle repaints remain armed. Neither is reset
    # by idle counting -- a resize must not look like operator activity.
    my ($last_cols, $last_rows);
    my $settle = 0;

    my $paint = sub {
        my ($c, $r) = (80, 24);
        my @dim = _try($term_size);
        if (@dim >= 2) { $c = _int($dim[0], 80); $r = _int($dim[1], 24) }
        $c = 80 if $c < 1;
        $r = 24 if $r < 1;
        $last_cols = $c;
        $last_rows = $r;
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
            # A poll that yielded nothing: the idle-resize seam (S2.2). A size
            # change repaints in full and arms RESIZE_SETTLE_POLLS() further
            # full repaints (a maximize can reflow after first being
            # reported); with no change, settle repaints (if any remain) keep
            # firing until exhausted. Neither branch touches $idle.
            my ($cc, $rr) = (80, 24);
            my @dim = _try($term_size);
            if (@dim >= 2) { $cc = _int($dim[0], 80); $rr = _int($dim[1], 24) }
            $cc = 80 if $cc < 1;
            $rr = 24 if $rr < 1;
            if (defined($last_cols) && ($cc != $last_cols || $rr != $last_rows)) {
                $settle = RESIZE_SETTLE_POLLS();
                $prev = undef;
                $paint->();
            }
            elsif ($settle > 0) {
                $settle--;
                $prev = undef;
                $paint->();
            }
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

# _detail_row($label, $value, $role) -> a non-landable subheader carrying one of
# the commands being approved. The cursor skips subheaders, so these read as
# annotation on the row above them rather than as separately-selectable rows.
#
# THE MODEL CARRIES CONTENT, THE RENDERER DECIDES LAYOUT. This used to pre-glue
# "label: value" into one display string, which _row_spans then prepended two
# more columns to -- so the row reached the wrapper as a single span whose text
# began with spaces, which was exactly the shape whose leading indent the
# wrapper dropped (almanac 20260909-223849-1870). Worse, all three rows of an
# item then rendered at one indent in one role, so `rationale` -- agent-written,
# unbounded, and by far the longest -- carried the same visual weight as the
# command about to run as root. Structured label/value lets _row_spans own the
# indent and the gutter, and lets each half take the role its content deserves.
sub _detail_row {
    my ($label, $value, $role) = @_;
    my $v = _str($value);
    $v = '(none given)' unless length $v;
    return {
        kind         => 'subheader',
        disabled     => 1,
        detail_label => _str($label),
        detail_value => $v,
        detail_role  => _str($role),
        # display stays populated so anything reading the model as text (a
        # self-audit, a test, a future plain-text fallback) still sees the row.
        display      => _str($label) . ': ' . $v,
    };
}

# A blank non-landable row. With more than one item on screen the three detail
# rows of one item ran straight into the next item's identity row, so where an
# item ENDED was invisible.
sub _spacer_row {
    return { kind => 'subheader', disabled => 1, detail_label => '',
             detail_value => '', display => '' };
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
        #
        # WEIGHTED, BECAUSE THE THREE ARE NOT EQUAL. install and verify are what
        # runs as root -- the thing actually being approved -- so they take the
        # primary role. rationale is context for the decision (design
        # conventions require it be shown, not merely a name), and it is
        # agent-written and unbounded, so it takes a muted role and comes last.
        # It is NOT truncated: this gate collects consent, and clamping the
        # reason someone asked for root is a product call, not a layout one.
        push @items, _detail_row('install',   $it->{install},   'text.primary');
        push @items, _detail_row('verify',    $it->{verify},    'text.primary');
        push @items, _detail_row('rationale', $it->{rationale}, 'text.muted');
        push @items, _spacer_row() if $i < $#{ ref $pending eq 'ARRAY' ? $pending : [] };
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

    # `label` is overridable so the caller can say WHERE IN THE WALK this screen
    # is ("backpack approval - item 3 of 9"). It defaults to the string this
    # model has always used, so every existing caller renders identically.
    #
    # The progress belongs in the label rather than in a row of its own: this
    # screen is a security gate whose whole job is to show the operator the
    # commands about to run as root, and a wizard that spends a body row on
    # bookkeeping is spending it against that job.
    my $label = $o->{label};
    $label = (defined $label && !ref $label && length "$label")
           ? "$label" : 'backpack approval';

    return {
        mode        => 'triage',
        label       => $label,
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
