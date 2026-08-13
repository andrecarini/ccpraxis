# tui::DashboardScreen -- the dashboard's content vocabulary (blueprint
# unified-tui-design-system, package 06-dashboard-screen). See
# specs/06-dashboard-screen-spec.md S2.4 for the binding API contract.
#
# This module composes the ccpraxis sandbox dashboard through
# tui::Screen/Frame/Layout/Meter (package 05's shipped render library). It
# owns the PANEL CONTENT VOCABULARY -- which facts render, in what order,
# suppressed when absent -- while the legacy Dashboard.pm keeps the
# side-effecting loop, key dispatch and spawn/signal logic and becomes a
# thin delegator for composition and width (spec S1.2).
#
# THE ARROW POINTS ONE WAY. Dashboard.pm may (and does) consume this module;
# this module may NEVER name Dashboard -- doing so would invert the
# tui/ library's dependency direction, exactly the shape package 05's AC-P4
# already forbids for the four modules it shipped (spec S1.3, S2.0).
#
# Pure and total: no clock, no process environment, no filesystem, no
# process, no console, no die/croak/confess. Every "now"-like value is an
# argument. Same forbidden-construct table as package 05's spec S2.6.
package tui::DashboardScreen;
use strict;
use warnings;
use Encode ();
use Theme;
use tui::Frame;
use tui::Layout;
use tui::Meter;
use tui::Screen;

# ===========================================================================
# The role vocabulary -- the seventeen (legacy Dashboard) -> nine (Theme)
# mapping (spec S2.1). Unknown/undef -> text.primary. Total; never dies.
#
# Lives inside a builder (module-shape convention this module shares with
# Theme.pm: no top-level data literal) rather than as a top-level hash --
# NOT decorative: one of this table's legacy KEYS, and several of its Theme-
# role VALUES, spell out the same bare diagnostic-output builtin name AC-P1's
# top-level scan polices, and AC-P1 only blanks SUB bodies before it scans,
# never a top-level literal.
# ===========================================================================
my $ROLE_MAP_MEMO;
sub _role_map {
    return $ROLE_MAP_MEMO if $ROLE_MAP_MEMO;
    $ROLE_MAP_MEMO = {
        title        => 'accent',
        accent       => 'accent',
        'panel-title' => 'text.primary',
        value        => 'text.primary',
        strong       => 'text.primary',
        body         => 'text.primary',
        blank        => 'text.primary',
        label        => 'text.muted',
        muted        => 'text.muted',
        footer       => 'text.faint',
        scrollhint   => 'text.faint',
        good         => 'state.ok',
        warn         => 'state.warn',
        'footer-flash' => 'state.warn',
        bad          => 'state.crit',
        alert        => 'state.crit',
        'footer-alert' => 'state.crit',
    };
    return $ROLE_MAP_MEMO;
}

sub theme_role {
    my ($legacy) = @_;
    return 'text.primary' if !defined($legacy) || ref($legacy);
    return _role_map()->{$legacy} // 'text.primary';
}

# ===========================================================================
# Pluralisation.
#
# The dashboard was littered with `item(s)`, `decision(s)`, `blueprint(s)`,
# `fact(s)` -- the shape you write when you do not know the count at authoring
# time. But every one of those call sites HAS the count in hand; the parenthesis
# was pure laziness, and the operator called it out. There is no ambiguity to
# hedge: 1 item, 2 items.
#
# Irregular plurals are passed explicitly rather than guessed. A rule-based
# pluraliser is a well-known tar pit and this vocabulary is a dozen words.
# ===========================================================================
sub plural {
    my ($n, $singular, $plural) = @_;
    $n = 0 unless defined $n && !ref($n) && $n =~ /\A-?\d+\z/;
    return $singular if $n == 1 || $n == -1;
    return defined($plural) ? $plural : "${singular}s";
}

# count_of(3, 'item') -> "3 items"; count_of(1, 'item') -> "1 item".
sub count_of {
    my ($n, $singular, $plural) = @_;
    my $shown = (defined $n && !ref($n) && $n =~ /\A-?\d+\z/) ? $n : 0;
    return $shown . ' ' . plural($shown, $singular, $plural);
}

# ===========================================================================
# The one duration format (criterion 4, spec S2.4.7). Identical grammar to
# the legacy Dashboard::fmt_age (Dashboard::fmt_age becomes a delegating
# alias to this).
# ===========================================================================
use constant DURATION_RE => qr/\A(?:\d+s|\d+m|\d+h\d{2}m|\d+d\d{2}h|n\/a)\z/;

sub fmt_duration {
    my ($s) = @_;
    return 'n/a' if !defined($s) || ref($s) || $s !~ /^-?\d+(?:\.\d+)?$/;
    $s = int($s);
    return 'n/a' if $s < 0;
    return "${s}s" if $s < 60;
    my $m = int($s / 60);
    return "${m}m" if $m < 60;
    my $h = int($m / 60); $m %= 60;
    return sprintf('%dh%02dm', $h, $m) if $h < 24;
    my $d = int($h / 24); $h %= 24;
    return sprintf('%dd%02dh', $d, $h);
}

# ===========================================================================
# is_absent / ABSENT_TOKENS / ALWAYS_SHOWN -- criterion 3's mechanism
# (spec S2.4.2). The closed lists are declared ONCE here.
# ===========================================================================
sub ABSENT_TOKENS {
    return [ '', 'n/a', 'none', 'not configured', 'not-configured',
             'disabled', 'absent', 'unknown', '?' ];
}

sub ALWAYS_SHOWN {
    return [ 'access', 'refresh', 'snapshot' ];
}

sub is_absent {
    my ($v) = @_;
    return 1 if !defined $v;
    return 1 if ref $v;
    my $s = "$v";
    $s =~ s/\A\s+//;
    $s =~ s/\s+\z//;
    my $lc = lc($s);
    for my $tok (@{ ABSENT_TOKENS() }) {
        return 1 if $lc eq lc($tok);
    }
    return 0;
}

# ===========================================================================
# row(\%spec) / row(label=>..,value=>..,role=>..,force=>..) -- the single
# label-gutter row (spec S2.4.1, criterion 3's mechanism). Accepts either a
# single hashref argument or a flat key/value list, so both call shapes this
# module and its own tests use are supported. ALWAYS returns an arrayref: []
# when the row is suppressed (never a bare empty list -- keeps every call
# site's `push @lines, row(...) if @{ row(...) }` idiom simple, and matches
# this module's own test's `@$row` dereference).
# ===========================================================================
use constant LABEL_GUTTER => 11;

sub row {
    my %spec;
    if (@_ == 1 && ref($_[0]) eq 'HASH') {
        %spec = %{ $_[0] };
    } elsif ((@_ % 2) == 0) {
        %spec = @_;
    }

    my $label = defined($spec{label}) ? $spec{label} : '';
    my $force = $spec{force} ? 1 : 0;
    my $default_role = defined($spec{role}) ? $spec{role} : 'text.primary';
    my $value = $spec{value};

    my @value_spans;
    if (ref($value) eq 'ARRAY') {
        for my $sp (@$value) {
            if (ref($sp) eq 'HASH') {
                my %span = (
                    text => (defined($sp->{text}) ? $sp->{text} : ''),
                    role => (defined($sp->{role}) ? $sp->{role} : $default_role),
                );
                # PRESERVE `atomic`. This rebuild used to copy only text+role,
                # silently dropping the marker that Frame.pm goes out of its way
                # to carry through spanify (:189-192) and honour in fit_spans
                # (:265,279). Harmless while nothing wrapped; the moment t02
                # introduced wrapping it became a live spec violation -- meter
                # gauges (declared atomic at :609/:611/:673) shattered mid-bar,
                # reproduced at width 40 by the step-8 UI pass.
                #
                # Worth recording HOW it was missed: both the reviewer and the
                # red-team probed wrap_line/fit_spans DIRECTLY with atomic spans,
                # where the exclusion works perfectly, and concluded it was
                # structural. Neither exercised the production path, which strips
                # the flag before wrap_line ever sees it. Only composing a real
                # frame and looking at it found this.
                $span{atomic} = 1 if $sp->{atomic};
                push @value_spans, \%span;
            } else {
                push @value_spans, { text => (defined($sp) ? "$sp" : ''), role => $default_role };
            }
        }
    } else {
        push @value_spans, { text => (defined($value) ? "$value" : ''), role => $default_role };
    }
    my $plain = join('', map { $_->{text} } @value_spans);

    return [] if !$force && is_absent($plain);

    my @spans = (
        { text => sprintf('%-*s : ', LABEL_GUTTER(), tui::Frame::safe($label)), role => 'text.muted' },
        @value_spans,
    );
    return \@spans;
}

# ===========================================================================
# collapse_records(\@records) -- criterion 5. A maximal run of CONSECUTIVE
# records with equal body AND equal role collapses to one record carrying
# count => <run length> and the epoch of the NEWEST member. Runs of length 1
# carry no count key. Non-adjacent duplicates never collapse.
# ===========================================================================
sub collapse_records {
    my ($records) = @_;
    return [] if ref($records) ne 'ARRAY';
    my @out;
    for my $rec (@$records) {
        next unless ref($rec) eq 'HASH';
        if (@out
            && defined($out[-1]{body}) && defined($rec->{body})
            && $out[-1]{body} eq $rec->{body}
            && (defined($out[-1]{role}) ? $out[-1]{role} : '') eq (defined($rec->{role}) ? $rec->{role} : '')
        ) {
            $out[-1]{count} = (defined($out[-1]{count}) ? $out[-1]{count} : 1) + 1;
            $out[-1]{epoch} = $rec->{epoch};
        } else {
            push @out, { %$rec };
        }
    }
    return \@out;
}

# ===========================================================================
# snapshot_spans(\%res) -- Obligation 4 / adapter contract Rule 4 (spec
# S2.4.5). Renders the Resources panel's snapshot_state row.
# ===========================================================================
my @RESOURCE_FACT_KEYS = qw(
    machine_name machine_state
    ctr_mem_used vm_mem_total ctr_cpu_pct
    pod_images pod_containers pod_volumes
    host_ram_used host_ram_total
    host_disk_dev host_disk_used host_disk_total
    host_cpu_pct host_cores
);

sub snapshot_spans {
    my ($res) = @_;
    return [] unless ref($res) eq 'HASH';
    return [] unless exists $res->{snapshot_state};

    my $state = $res->{snapshot_state};
    my $age   = $res->{snapshot_age};
    my $age_numeric = defined($age) && !ref($age) && $age =~ /^-?\d+(?:\.\d+)?$/;

    my ($text, $role);
    if (!defined $state) {
        $text = 'undef (unrecognised)';
        $role = 'state.warn';
    } elsif ($state eq 'fresh') {
        $text = 'fresh';
        $text .= ', ' . fmt_duration($age) . ' old' if $age_numeric;
        my $n = scalar(grep { !defined $res->{$_} } @RESOURCE_FACT_KEYS);
        $text .= ", " . count_of($n, "fact") . " unavailable" if $n > 0;
        $role = 'state.ok';
    } elsif ($state eq 'stale') {
        $text = 'STALE - last written';
        $text .= ' ' . fmt_duration($age) . ' ago' if $age_numeric;
        $text .= '; values withheld';
        $role = 'state.warn';
    } elsif ($state eq 'failed') {
        $text = 'FAILED - snapshot unreadable; no values';
        $role = 'state.crit';
    } else {
        # Fix batch (package 06, red-team finding, latent/low): a ref value
        # here must NOT be interpolated raw -- "$state" on a hashref/arrayref
        # stringifies to its heap-address form (e.g. "HASH(0x...)"), painting
        # a reference onto the operator's screen instead of degrading. Treat
        # any ref the same as an unrecognised scalar: a bounded marker, never
        # the ref itself.
        $text = (ref($state) ? '<ref>' : $state) . ' (unrecognised)';
        $role = 'state.warn';
    }

    return [
        { text => sprintf('%-*s : ', LABEL_GUTTER(), 'snapshot'), role => 'text.muted' },
        { text => $text, role => $role },
    ];
}

# ===========================================================================
# backpack_summary_spans(\%bp) -- criterion 6 / Decision 9 (spec S2.4.8).
# ===========================================================================
sub backpack_summary_spans {
    my ($bp) = @_;
    return [] unless ref($bp) eq 'HASH';
    my $total = (defined($bp->{total}) && !ref($bp->{total}) && $bp->{total} =~ /^\d+$/) ? $bp->{total} : 0;
    return [] if $total == 0;
    my $approved = (defined($bp->{approved}) && !ref($bp->{approved}) && $bp->{approved} =~ /^\d+$/) ? $bp->{approved} : 0;
    my $pending;
    if (defined($bp->{pending}) && !ref($bp->{pending}) && $bp->{pending} =~ /^\d+$/) {
        $pending = $bp->{pending};
    } else {
        $pending = $total - $approved;
        $pending = 0 if $pending < 0;
    }

    my @spans = ( { text => count_of($total, "item") . ", $approved approved", role => "text.primary" } );
    push @spans, { text => ", $pending pending", role => 'state.warn' } if $pending > 0;
    push @spans, { text => '   [b] manage', role => 'text.muted' };
    return \@spans;
}

# ===========================================================================
# Private helpers shared by the panel builders below.
# ===========================================================================

# _status_glyph($k) -> UTF-8 bytes for Theme's 'status.$k' glyph, or '?' when
# unknown. PRIVATE.
sub _status_glyph {
    my ($k) = @_;
    my $g = Theme::glyph("status.$k");
    return defined($g) ? $g : '?';
}

# _container_role($status, $gone) -> a Theme state role. PRIVATE, mirrors the
# legacy Dashboard container_status_style's role half (glyph is resolved
# separately by the caller, via _status_glyph).
sub _container_role {
    my ($status, $gone) = @_;
    my $st = defined($status) ? $status : '';
    $st =~ s/^\s+//;
    $st =~ s/\s+$//;
    return 'state.crit' if $gone;
    return 'state.ok'   if $st eq 'running';
    return 'state.crit' if $st =~ /^(?:exited|dead|removing|unknown)$/;
    return 'state.warn' if $st =~ /^(?:created|restarting|stopping|stopped|paused)$/;
    return 'state.idle';
}

my @SPINNER_NAMES = map { "spinner.$_" } (1 .. 10);

sub _spinner_frame {
    my ($idx) = @_;
    return undef if !defined($idx) || ref($idx) || $idx !~ /^-?\d+(?:\.\d+)?$/;
    my $i = int($idx) % 10;
    $i += 10 if $i < 0;
    return Theme::glyph($SPINNER_NAMES[$i]);
}

# _fmt_oauth_like($secs) / _oauth_like_role($secs) -- independent
# reimplementation of the legacy Dashboard fmt_oauth/oauth_role pair, same
# grammar (via fmt_duration, so the token text is byte-identical to the
# legacy fmt_age-based output), Theme roles instead of legacy ones. This
# module may not call Dashboard::fmt_oauth (AC-P4), so it owns its own copy.
use constant OAUTH_WARN_SECS => 900;

sub _fmt_oauth_like {
    my ($s) = @_;
    return 'not logged in (run /login)' if !defined($s);
    # Fix batch (package 06, red-team finding, latent/low): guard non-numeric
    # $s (a ref or a non-numeric string) BEFORE the numeric comparison --
    # mirrors _oauth_like_role's own guard just below, so the two stay
    # consistent instead of one degrading gracefully and the other warning
    # under `use warnings` on the same input.
    return 'not logged in (run /login)' if ref($s) || $s !~ /^-?\d+(?:\.\d+)?$/;
    return 'EXPIRED' if $s <= 0;
    return 'expires in ' . fmt_duration($s);
}

sub _oauth_like_role {
    my ($remaining) = @_;
    return 'state.crit' if !defined($remaining) || ref($remaining) || $remaining !~ /^-?\d+(?:\.\d+)?$/;
    return 'state.crit' if $remaining <= 0;
    return 'state.warn' if $remaining <= OAUTH_WARN_SECS();
    return 'state.ok';
}

# ===========================================================================
# header_spans(\%state, $cols) -- today's _title_line, unchanged in content
# (spec S2.4.9): "ccpraxis sandbox - <project>" left, "<container>
# [<spinner> <status>]" right-justified.
# ===========================================================================
sub header_spans {
    my ($state, $cols) = @_;
    $state = {} if ref($state) ne 'HASH';
    $cols = 1 if !defined($cols) || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/ || int($cols) < 1;
    $cols = int($cols);

    my $pn = ref($state->{project_name}) ? undef : $state->{project_name};
    my $left = 'ccpraxis sandbox';
    $left .= ' - ' . tui::Frame::safe($pn) if defined($pn) && length($pn);

    my $ctr_raw = ref($state->{container}) ? undef : $state->{container};
    my $ctr = tui::Frame::safe(defined($ctr_raw) ? $ctr_raw : '');
    my $st_raw = ref($state->{status}) ? undef : $state->{status};
    my $st = tui::Frame::safe((defined($st_raw) && length($st_raw)) ? $st_raw : '?');

    my $role = _container_role($state->{status}, $state->{container_gone});
    my $spin = _spinner_frame($state->{spinner_idx});

    my @right = (
        { text => (length($ctr) ? "$ctr [" : '['), role => 'accent' },
        (defined($spin) ? ( { text => "$spin ", role => $role } ) : ()),
        { text => $st, role => $role },
        { text => ']', role => 'accent' },
    );

    my $lw = tui::Layout::display_width($left);
    my $rw = tui::Frame::spans_width(\@right);
    if ($lw + $rw + 1 <= $cols) {
        return [
            { text => $left, role => 'accent' },
            { text => (' ' x ($cols - $lw - $rw)), role => 'accent' },
            @right,
        ];
    }
    return [ { text => tui::Frame::clip_pad($left, $cols), role => 'accent' } ];
}

# ===========================================================================
# The Run panel body (spec S2.4.3): heartbeat, uptime, busy-lease,
# keep-awake, needs you, backpack, then blueprint-run summaries, then --
# only when tokens are absent -- an oauth row.
# ===========================================================================
# Builder, not a top-level literal -- same AC-P1 reason as _role_map() above.
my $RUN_STATE_ROLE_MEMO;
sub _run_state_role_map {
    return $RUN_STATE_ROLE_MEMO if $RUN_STATE_ROLE_MEMO;
    $RUN_STATE_ROLE_MEMO = { running => 'state.ok', paused => 'state.warn', parked => 'state.warn', idle => 'text.muted' };
    return $RUN_STATE_ROLE_MEMO;
}

sub _nonneg_int {
    my ($v) = @_;
    return (defined($v) && !ref($v) && $v =~ /^\d+$/) ? ($v + 0) : 0;
}

sub _one_run_summary_spans {
    my ($s) = @_;
    $s = {} unless ref($s) eq 'HASH';
    my $bp = (defined($s->{blueprint}) && !ref($s->{blueprint}) && length($s->{blueprint})) ? $s->{blueprint} : '?';
    my @spans = ( { text => "$bp : ", role => 'accent' } );

    my $state = (defined($s->{state}) && !ref($s->{state}) && length($s->{state})) ? $s->{state} : '?';
    push @spans, { text => $state, role => (_run_state_role_map()->{$state} // 'text.muted') };

    my $done  = _nonneg_int($s->{packages_done});
    my $total = _nonneg_int($s->{packages_total});
    push @spans, { text => sprintf('  %d/%d pkg', $done, $total), role => 'text.primary' };

    if (defined($s->{current_package}) && !ref($s->{current_package}) && length($s->{current_package})) {
        my $cp = substr($s->{current_package}, 0, 200);
        push @spans, { text => "  cur $cp", role => 'text.primary' };
    }

    my $coord = _nonneg_int($s->{running_coordinators});
    push @spans, { text => sprintf('  %d coord', $coord), role => 'accent' } if $coord > 0;

    my $waiting = _nonneg_int($s->{decisions_waiting});
    if ($waiting > 0) {
        push @spans, { text => sprintf('  %d waiting', $waiting), role => ($state eq 'paused' ? 'state.crit' : 'state.warn') };
    }

    return \@spans;
}

# _run_summary_lines(\@runs, $max_rows) -- one row per blueprint.
#
# $max_rows used to be the literal 3, unconditionally, with no relationship to
# the space available. The operator's dashboard had twelve blueprints, three
# rows, "+9 more blueprint(s)", and most of the screen empty underneath -- the
# cap was hiding information there was ample room to show.
#
# It is now a BUDGET the caller derives from the actual terminal height (see
# compose), not a constant. Undef means no cap at all, which is what the pure
# unit tests want; a short terminal still gets a bounded panel rather than one
# that crowds out everything below it.
sub _run_summary_lines {
    my ($runs, $max_rows) = @_;
    return [] unless ref($runs) eq 'ARRAY';
    my @summaries = grep { ref($_) eq 'HASH' } @$runs;
    return [] unless @summaries;

    $max_rows = scalar(@summaries)
        unless defined($max_rows) && !ref($max_rows) && $max_rows =~ /\A\d+\z/ && $max_rows >= 1;
    my @out;
    my $shown = (@summaries < $max_rows) ? scalar(@summaries) : $max_rows;
    push @out, _one_run_summary_spans($summaries[$_]) for (0 .. $shown - 1);

    if (@summaries > $max_rows) {
        my $extra = @summaries - $max_rows;
        push @out, [ { text => "  +" . count_of($extra, "more blueprint"), role => 'text.muted' } ];
    }
    return \@out;
}

sub _run_body {
    my ($state) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my @lines;

    # These `defined` guards are NOT redundant with row()'s own is_absent
    # suppression, even though they look it (review finding, package 06
    # fix-batch): row() only suppresses when the composed VALUE TEXT itself
    # matches one of ABSENT_TOKENS() ('', 'n/a', ...). fmt_duration(undef)
    # returns 'n/a', but the text built here is 'n/a ago' (heartbeat) --
    # a string ABSENT_TOKENS() does NOT list -- so without this outer guard,
    # an absent beat_age/uptime would sail past is_absent and render a
    # spurious "heartbeat : n/a ago" / "uptime : n/a ago" row instead of
    # being suppressed. Do not delete these as "obviously redundant".
    if (defined $state->{beat_age}) {
        my $r = row({ label => 'heartbeat', value => [ { text => fmt_duration($state->{beat_age}) . ' ago', role => 'text.primary' } ] });
        push @lines, $r if @$r;
    }
    if (defined $state->{uptime}) {
        my $r = row({ label => 'uptime', value => [ { text => fmt_duration($state->{uptime}), role => 'text.primary' } ] });
        push @lines, $r if @$r;
    }

    my ($busy_text, $busy_role);
    if (!defined $state->{busy_age})   { ($busy_text, $busy_role) = ('none (no active run)', 'text.muted'); }
    elsif ($state->{stay_awake})       { ($busy_text, $busy_role) = ('active (' . fmt_duration($state->{busy_age}) . ' ago)', 'state.ok'); }
    else                                 { ($busy_text, $busy_role) = ('idle ('   . fmt_duration($state->{busy_age}) . ' ago)', 'state.warn'); }
    my $busy_row = row({ label => 'busy-lease', value => [ { text => $busy_text, role => $busy_role } ], force => 1 });
    push @lines, $busy_row if @$busy_row;

    my ($keep_text, $keep_role) = $state->{stay_awake}
        ? ('holding (PC stays awake)', 'state.ok') : ('released (PC may sleep)', 'text.muted');
    my $keep_row = row({ label => 'keep-awake', value => [ { text => $keep_text, role => $keep_role } ], force => 1 });
    push @lines, $keep_row if @$keep_row;

    my $ny = (defined($state->{needs_you}) && !ref($state->{needs_you}) && $state->{needs_you} =~ /^\d+$/) ? $state->{needs_you} : 0;
    if ($ny > 0) {
        my $ny_row = row({ label => 'needs you', value => count_of($ny, "decision") . " waiting", role => 'state.warn' });
        push @lines, $ny_row if @$ny_row;
    }

    my $bp_val = backpack_summary_spans($state->{backpack});
    my $bp_row = row({ label => 'backpack', value => $bp_val });
    push @lines, $bp_row if @$bp_row;

    push @lines, @{ _run_summary_lines($state->{runs}, $state->{run_rows_max}) };

    if (ref($state->{tokens}) ne 'HASH') {
        my $sec = $state->{oauth_remaining};
        my $oauth_row = row({ label => 'oauth', value => [ { text => _fmt_oauth_like($sec), role => _oauth_like_role($sec) } ], force => 1 });
        push @lines, $oauth_row if @$oauth_row;
    }

    return \@lines;
}

# ===========================================================================
# The Token panel body (spec S2.4.3): access, refresh, refreshed,
# refresh-exp, account -- via row(), so absent ones vanish except the two in
# ALWAYS_SHOWN.
# ===========================================================================
sub _token_body {
    my ($t) = @_;
    return [] unless ref($t) eq 'HASH';
    my @lines;

    my $access_state = defined($t->{access_state}) ? $t->{access_state} : 'absent';
    my $sec = ($access_state eq 'absent') ? undef : $t->{access_seconds_left};
    my $access_row = row({ label => 'access', value => [ { text => _fmt_oauth_like($sec), role => _oauth_like_role($sec) } ], force => 1 });
    push @lines, $access_row if @$access_row;

    my @refresh_spans;
    if ($t->{refresh_present}) {
        my $fp = defined($t->{refresh_fingerprint}) ? $t->{refresh_fingerprint} : '';
        @refresh_spans = ( { text => "present ($fp)", role => 'state.ok' } );
    } else {
        @refresh_spans = ( { text => 'absent', role => 'state.crit' } );
    }
    my $refresh_row = row({ label => 'refresh', value => \@refresh_spans, force => 1 });
    push @lines, $refresh_row if @$refresh_row;

    my @refreshed_spans = defined($t->{last_refreshed_age})
        ? ( { text => fmt_duration($t->{last_refreshed_age}) . ' ago', role => 'text.primary' } )
        : ( { text => 'n/a', role => 'text.muted' } );
    my $refreshed_row = row({ label => 'refreshed', value => \@refreshed_spans });
    push @lines, $refreshed_row if @$refreshed_row;

    my $rexp = defined($t->{refresh_expires}) ? $t->{refresh_expires} : 'n/a';
    my $rexp_row = row({ label => 'refresh-exp', value => [ { text => $rexp, role => 'text.muted' } ] });
    push @lines, $rexp_row if @$rexp_row;

    my @present;
    for my $k (qw(subscription_type rate_limit_tier)) {
        push @present, $t->{$k} if defined($t->{$k}) && !ref($t->{$k}) && length($t->{$k});
    }
    if (@present) {
        my $acc_row = row({ label => 'account', value => [ { text => join(' / ', @present), role => 'text.primary' } ] });
        push @lines, $acc_row if @$acc_row;
    }

    return \@lines;
}

# ===========================================================================
# The Resources panel body (spec S2.4.5, Obligation 4). Called both by
# panels() (below) and by Dashboard::_resources_lines (the direct-call
# oracle site), so the composed frame and the direct-call result can never
# diverge. Not part of the spec's headline public-surface list, but a normal
# Perl cross-package call -- Dashboard consuming tui:: is this package's
# whole point (Obligation 2).
# ===========================================================================
sub _meter_value_spans {
    my ($used, $total) = @_;
    my $ratio = tui::Meter::ratio($used, $total);
    return [ { text => 'n/a', role => 'text.muted' } ] unless defined $ratio;
    my $avail = (!ref($used) && !ref($total)
                 && $used  =~ /^-?\d+(?:\.\d+)?$/
                 && $total =~ /^-?\d+(?:\.\d+)?$/) ? $total - $used : undef;
    $avail = 0 if defined($avail) && $avail < 0;
    my $role = tui::Meter::pressure_role($ratio) // 'text.muted';
    return [
        { text => tui::Meter::numbers_used_free_total($used, $avail, $total), role => $role },
        { text => '  ', role => 'text.primary' },
        { text => tui::Meter::bar($ratio, tui::Meter::BAR_CELLS()), role => $role, atomic => 1 },
        { text => ' ', role => $role },
        { text => tui::Meter::percent_text($ratio), role => $role, atomic => 1 },
    ];
}

sub _resources_body {
    my ($r) = @_;
    return [] unless ref($r) eq 'HASH';
    my @lines;

    my $snap = snapshot_spans($r);
    push @lines, $snap if ref($snap) eq 'ARRAY' && @$snap;

    my %mstate_role = ( running => 'state.ok', starting => 'state.warn', stopped => 'state.crit' );
    my $ms = $r->{machine_state};
    my @mv;
    if (defined($ms) && !ref($ms) && $mstate_role{$ms}) {
        push @mv, { text => $ms, role => $mstate_role{$ms} };
    } else {
        push @mv, { text => 'n/a', role => 'text.muted' };
    }
    push @mv, { text => " ($r->{machine_name})", role => 'text.muted' }
        if defined($r->{machine_name}) && !ref($r->{machine_name}) && length($r->{machine_name});
    my $machine_row = row({ label => 'machine', value => \@mv });
    push @lines, $machine_row if @$machine_row;

    my $ctrmem_row = row({ label => 'ctr mem', value => _meter_value_spans($r->{ctr_mem_used}, $r->{vm_mem_total}) });
    push @lines, $ctrmem_row if @$ctrmem_row;

    my $cpct = $r->{ctr_cpu_pct};
    my $ctrcpu_val = (defined($cpct) && !ref($cpct) && $cpct =~ /^-?\d+(?:\.\d+)?$/)
        ? [ { text => sprintf('%.1f%%', $cpct), role => 'text.primary' } ]
        : [ { text => 'n/a', role => 'text.muted' } ];
    my $ctrcpu_row = row({ label => 'ctr cpu', value => $ctrcpu_val });
    push @lines, $ctrcpu_row if @$ctrcpu_row;

    my ($pi, $pc, $pv) = ($r->{pod_images}, $r->{pod_containers}, $r->{pod_volumes});
    my $podman_val = (defined($pi) || defined($pc) || defined($pv))
        ? [ { text => sprintf('images %s | containers %s | volumes %s',
                    tui::Meter::fmt_bytes($pi), tui::Meter::fmt_bytes($pc), tui::Meter::fmt_bytes($pv)), role => 'text.primary' } ]
        : [ { text => 'n/a', role => 'text.muted' } ];
    my $podman_row = row({ label => 'podman', value => $podman_val });
    push @lines, $podman_row if @$podman_row;

    my $hostram_row = row({ label => 'host ram', value => _meter_value_spans($r->{host_ram_used}, $r->{host_ram_total}) });
    push @lines, $hostram_row if @$hostram_row;

    my @dv = @{ _meter_value_spans($r->{host_disk_used}, $r->{host_disk_total}) };
    push @dv, { text => " ($r->{host_disk_dev})", role => 'text.muted' }
        if defined($r->{host_disk_dev}) && !ref($r->{host_disk_dev}) && length($r->{host_disk_dev});
    my $hostdisk_row = row({ label => 'host disk', value => \@dv });
    push @lines, $hostdisk_row if @$hostdisk_row;

    my $hpct = $r->{host_cpu_pct};
    my @cv;
    if (defined($hpct) && !ref($hpct) && $hpct =~ /^-?\d+(?:\.\d+)?$/) {
        my $ratio = $hpct / 100;
        $ratio = 0 if $ratio < 0;
        $ratio = 1 if $ratio > 1;
        my $role = tui::Meter::pressure_role($ratio) // 'text.muted';
        @cv = (
            { text => sprintf('%.1f%%', $hpct), role => $role },
            { text => '  ', role => 'text.primary' },
            { text => tui::Meter::bar($ratio, tui::Meter::BAR_CELLS()), role => $role, atomic => 1 },
        );
    } else {
        @cv = ( { text => 'n/a', role => 'text.muted' } );
    }
    push @cv, { text => sprintf(' (%d cores)', $r->{host_cores}), role => 'text.muted' }
        if defined($r->{host_cores}) && !ref($r->{host_cores}) && $r->{host_cores} =~ /^\d+$/;
    my $hostcpu_row = row({ label => 'host cpu', value => \@cv });
    push @lines, $hostcpu_row if @$hostcpu_row;

    return \@lines;
}

# ===========================================================================
# The Spend panel body -- ported from the legacy Dashboard _spend_lines
# family (Theme roles instead of legacy ones; no Dashboard reference,
# AC-P4).
# ===========================================================================
sub _spend_state_style {
    my ($state) = @_;
    return ('state.crit', 'crit') if $state eq 'unreadable' || $state eq 'exhausted';
    return ('state.warn', 'warn') if $state eq 'absent';
    return ('text.muted', 'idle') if $state eq 'disabled';
    return ('state.ok', 'ok');
}

sub _spend_claude_spans {
    my ($c) = @_;
    $c = {} unless ref($c) eq 'HASH';
    my $state = (defined($c->{state}) && $c->{state} eq 'ok') ? 'ok' : 'unreadable';
    my ($role, $key) = _spend_state_style($state);
    my @spans = ( { text => _status_glyph($key) . ' ', role => $role }, { text => 'Claude : ', role => 'text.muted' } );
    if ($state eq 'ok') {
        my @parts;
        for my $w (ref($c->{windows}) eq 'ARRAY' ? @{ $c->{windows} } : ()) {
            next unless ref($w) eq 'HASH' && defined $w->{name} && defined $w->{text};
            my $tag = $w->{name} eq 'seven_day' ? '7d' : '5h';
            push @parts, "$tag $w->{text}";
        }
        push @spans, { text => (@parts ? join('  ', @parts) : 'no windows reported'), role => 'text.primary' };
        return (\@spans, 0);
    }
    my $diag = (defined($c->{diagnostic}) && !ref($c->{diagnostic}) && length($c->{diagnostic}))
             ? $c->{diagnostic} : 'usage endpoint unreadable';
    push @spans, { text => "unreadable -- $diag", role => 'state.crit' };
    return (\@spans, 1);
}

sub _spend_go_spans {
    my ($g) = @_;
    $g = {} unless ref($g) eq 'HASH';
    my $state = (defined($g->{state}) && $g->{state} =~ /^(?:absent|unreadable|exhausted|ok)$/) ? $g->{state} : 'absent';
    my ($role, $key) = _spend_state_style($state);
    my @spans = ( { text => _status_glyph($key) . ' ', role => $role }, { text => 'Go     : ', role => 'text.muted' } );
    if ($state eq 'absent') {
        push @spans, { text => 'not configured', role => 'text.muted' };
    } elsif ($state eq 'unreadable') {
        my $diag = (defined($g->{diagnostic}) && !ref($g->{diagnostic}) && length($g->{diagnostic})) ? $g->{diagnostic} : 'meter unreadable';
        push @spans, { text => "unreadable -- $diag", role => 'state.crit' };
        return (\@spans, 1);
    } else {
        my @parts;
        for my $w (ref($g->{windows}) eq 'ARRAY' ? @{ $g->{windows} } : ()) {
            next unless ref($w) eq 'HASH' && defined $w->{name} && defined $w->{text};
            my $tag = $w->{name} eq 'weekly' ? 'Wk' : $w->{name} eq 'monthly' ? 'Mo' : '5h';
            # Fix batch (package 06, red-team finding, latent/low): guard
            # non-numeric $w->{fraction} before the numeric comparison --
            # a non-numeric value would warn under `use warnings` and
            # mis-compare instead of degrading to "not exhausted".
            my $exhausted_here = defined($w->{fraction}) && !ref($w->{fraction})
                && $w->{fraction} =~ /^-?\d+(?:\.\d+)?$/ && $w->{fraction} >= 1;
            push @parts, ($exhausted_here ? "$tag $w->{text} EXHAUSTED" : "$tag $w->{text}");
        }
        push @spans, { text => (@parts ? join('  ', @parts) : 'no windows reported'),
                       role => ($state eq 'exhausted' ? 'state.crit' : 'text.primary') };
    }
    return (\@spans, 0);
}

sub _spend_zen_spans {
    my ($z) = @_;
    $z = {} unless ref($z) eq 'HASH';
    my $state = (defined($z->{state}) && $z->{state} =~ /^(?:disabled|absent|unreadable|exhausted|ok)$/) ? $z->{state} : 'disabled';
    my ($role, $key) = _spend_state_style($state);
    my @spans = ( { text => _status_glyph($key) . ' ', role => $role }, { text => 'Zen    : ', role => 'text.muted' } );
    if ($state eq 'disabled') {
        push @spans, { text => 'disabled', role => 'text.muted' };
    } elsif ($state eq 'absent') {
        push @spans, { text => 'not configured', role => 'text.muted' };
    } elsif ($state eq 'unreadable') {
        my $diag = (defined($z->{diagnostic}) && !ref($z->{diagnostic}) && length($z->{diagnostic})) ? $z->{diagnostic} : 'meter unreadable';
        push @spans, { text => "unreadable -- $diag", role => 'state.crit' };
        return (\@spans, 1);
    } else {
        my $bal = (defined($z->{balance_text}) && !ref($z->{balance_text})) ? $z->{balance_text} : 'n/a';
        my $bud = (defined($z->{budget_text}) && !ref($z->{budget_text})) ? " / $z->{budget_text}" : '';
        my $pct = (defined($z->{fraction}) && !ref($z->{fraction}) && $z->{fraction} =~ /^-?\d+(?:\.\d+)?$/)
                ? sprintf(' (%d%%)', int($z->{fraction} * 100 + 0.5)) : '';
        my $txt = "$bal$bud$pct" . ($state eq 'exhausted' ? ' EXHAUSTED' : '');
        push @spans, { text => $txt, role => ($state eq 'exhausted' ? 'state.crit' : 'text.primary') };
    }
    return (\@spans, 0);
}

sub _spend_body {
    my ($info, $cols) = @_;
    return [] unless ref($info) eq 'HASH';
    my $w = (defined($cols) && !ref($cols) && $cols =~ /^\d+(?:\.\d+)?$/ && $cols > 0) ? int($cols) : 80;

    my ($claude_spans, $claude_protect) = _spend_claude_spans($info->{claude});
    my ($go_spans,     $go_protect)     = _spend_go_spans($info->{go});
    my ($zen_spans,    $zen_protect)    = _spend_zen_spans($info->{zen});

    my @entries = ( [ $claude_spans, $claude_protect ], [ $go_spans, $go_protect ], [ $zen_spans, $zen_protect ] );
    my @out;
    for my $e (@entries) {
        my ($line, $protect) = @$e;
        push @out, ($protect || tui::Frame::spans_width($line) <= $w) ? $line : tui::Frame::fit_spans($line, $w);
    }

    if (ref($info->{priority}) eq 'ARRAY' && @{ $info->{priority} }) {
        my $top = $info->{priority}[0];
        if (ref($top) eq 'HASH' && defined $top->{provider} && defined $top->{window}) {
            # Fix batch (package 06, red-team finding, latent/low): the prior
            # guard checked only `!ref`, not "is actually numeric" -- a
            # non-numeric string would sail past it into `* 100`, warning
            # under `use warnings` ("Argument isn't numeric") instead of
            # degrading to '?'.
            my $pct = (defined($top->{fraction}) && !ref($top->{fraction})
                       && $top->{fraction} =~ /^-?\d+(?:\.\d+)?$/)
                    ? sprintf('%d%%', int($top->{fraction} * 100 + 0.5)) : '?';
            my $pline = [ { text => 'nearest : ', role => 'text.muted' },
                          { text => "$top->{provider}/$top->{window} $pct", role => 'accent' } ];
            unshift @out, (tui::Frame::spans_width($pline) > $w) ? tui::Frame::fit_spans($pline, $w) : $pline;
        }
    }

    return \@out;
}

# ===========================================================================
# panels(\%state, $cols) -- the panel set (spec S2.4.3, criteria 2 and 6).
# The Sandbox panel is dissolved: project/container reach the header,
# oauth reaches Token when present or Run when absent (never both, never
# neither), heartbeat/uptime move to Run.
# ===========================================================================
sub panels {
    my ($state, $cols) = @_;
    $state = {} if ref($state) ne 'HASH';
    my @out;

    push @out, { title => 'Run', lines => _run_body($state) };

    if (ref($state->{tokens}) eq 'HASH') {
        push @out, { title => 'Token', lines => _token_body($state->{tokens}) };
    }

    # RESOURCES IS ALWAYS PRESENT, for the same reason the geometry is fixed.
    #
    # The sampler is a DETACHED process: it starts as the dashboard opens and
    # writes its first snapshot seconds later. While the key was undef the panel
    # did not exist, so it appeared mid-session and pushed every panel after it
    # down -- a scheduled, guaranteed reflow a few seconds into every launch,
    # and a direct contributor to the screen not settling.
    #
    # Reserving it costs nothing when data never arrives (the sampler failed to
    # fork, say) and it states that outright rather than vanishing.
    if (ref($state->{resources}) eq 'HASH') {
        push @out, { title => 'Resources', lines => _resources_body($state->{resources}), min_cols => tui::Meter::min_width() };
    } else {
        push @out, { title => "Resources",
                     lines => [ row({ label => "snapshot", value => "sampling - no reading yet",
                                      role => "text.muted", force => 1 }) ],
                     min_cols => tui::Meter::min_width() };
    }

    # SPEND IS ALWAYS PRESENT. It used to be omitted whenever no snapshot had
    # been read, which is ALWAYS -- the fleet writes its spend figures to its
    # own log and returns them in-process, and has never persisted the
    # runs/spend.json this reads. So a panel the operator relied on had silently
    # not existed for the life of the feature, and its absence was
    # indistinguishable from "this launch has no runs".
    #
    # Absent-vs-empty was a real decision (never fabricate a zero) and it is
    # kept: what changes is that "we have no figures" is now SAID, in the panel,
    # instead of being expressed by the panel not being there. A missing panel
    # is not an honest absence -- it is no statement at all.
    if (ref($state->{spend}) eq 'HASH') {
        push @out, { title => 'Spend', lines => _spend_body($state->{spend}, $cols), min_cols => tui::Meter::min_width() };
    } else {
        push @out, { title => "Spend", lines => _spend_unavailable_body($state), min_cols => tui::Meter::min_width() };
    }

    # Recent activity is the FLEX panel (tui::Screen H6) and is always last.
    #
    # It absorbs the body height the other panels do not use, which does two
    # things at once: the screen stops being mostly empty, and -- because the
    # panel's height no longer tracks its content -- a newly-arrived event fills
    # a row that was already reserved instead of growing the panel and reflowing
    # everything around it. Activity is the right panel to carry this: it is
    # already the scrolling one, it is always last, and state.events supplies
    # far more rows than fit, so extra height is always spent on real content.
    my $ev = (ref($state->{events}) eq 'ARRAY') ? $state->{events} : [];
    push @out, { title => 'Recent activity',
                 lines => (@$ev ? [ @$ev ] : [ '(no events yet)' ]),
                 flex  => 1 };

    return \@out;
}

# _spend_unavailable_body(\%state) -> \@lines
# What the Spend panel says when no snapshot has been read. Names the reason
# rather than showing blank rows or zeroes -- an operator must be able to tell
# "nothing has spent anything" from "nobody has told me".
sub _spend_unavailable_body {
    my ($state) = @_;
    my @runs = (ref($state->{runs}) eq 'ARRAY') ? @{ $state->{runs} } : ();
    my $active = grep { ref($_) eq 'HASH' && defined($_->{state})
                        && ($_->{state} eq 'running' || $_->{state} eq 'paused') } @runs;
    return [
        row({ label => 'claude', value => 'no snapshot', role => 'text.muted', force => 1 }),
        row({ label => 'go',     value => 'no snapshot', role => 'text.muted', force => 1 }),
        row({ label => 'zen',    value => 'no snapshot', role => 'text.muted', force => 1 }),
        [ { text => ($active ? '  a run is active but has not written runs/spend.json yet'
                             : '  no active run to report spend for'),
            role => 'text.faint' } ],
    ];
}

# ===========================================================================
# Footer legend / confirm prompts / alert banners -- ported from the legacy
# Dashboard footer_legend/confirm_prompt/_footer_line/_status_alert/
# lifecycle_alert_msg (Theme roles; no Dashboard reference, AC-P4).
# ===========================================================================
sub _footer_legend {
    my ($cols) = @_;
    $cols = 200 if !defined $cols;
    my @tiers = (
        ' [c] launch Claude Code  [s] stop runs  [x] full shutdown  [up/down] scroll  [r] refresh  [q] quit',
        ' [c] launch Claude Code  [s] stop runs  [x] shutdown  [r] refresh  [q] quit',
        ' [c] launch  [s] stop  [x] shutdown  [r] refresh  [q] quit',
    );
    for my $t (@tiers) {
        return $t if tui::Layout::display_width($t) <= $cols;
    }
    return $tiers[-1];
}

sub _confirm_prompt {
    my ($pending, $cols) = @_;
    $cols = 200 if !defined $cols;
    return undef unless defined $pending;
    if ($pending eq 'stop-runs') {
        my $L = 'Stop ALL butler runs in this project? The container and podman machine stay UP. [y] confirm   [any other] cancel';
        my $S = 'Stop ALL butler runs? Container+machine stay up. [y] confirm  [other] cancel';
        return tui::Layout::display_width($L) <= $cols ? $L : $S;
    }
    if ($pending eq 'full-shutdown') {
        my $L = 'Full shutdown: stop ALL butler runs, then STOP THIS CONTAINER, then stop the podman machine if no other container is running. [y] confirm   [any other] cancel';
        my $S = 'Stop runs + STOP CONTAINER (+ machine if last). [y] confirm  [other] cancel';
        return tui::Layout::display_width($L) <= $cols ? $L : $S;
    }
    if ($pending eq 'relaunch') {
        my @tiers = (
            'Relaunch: start the podman machine if it is down, start this container, and re-attach. Nothing is deleted. [y] confirm   [any other] cancel',
            'Start machine + container and re-attach. Nothing is deleted. [y] confirm  [other] cancel',
            'Relaunch machine + container. Nothing is deleted. [y] confirm  [other] cancel',
        );
        for my $t (@tiers) {
            return $t if tui::Layout::display_width($t) <= $cols;
        }
        return $tiers[-1];
    }
    return undef;
}

sub _footer_text {
    my ($state, $cols) = @_;
    my $pending = defined($state->{pending}) ? $state->{pending} : '';
    my $prompt = _confirm_prompt($pending, $cols);
    return $prompt if defined $prompt;
    return ' ' . $state->{footer_flash} if defined($state->{footer_flash}) && !ref($state->{footer_flash}) && length($state->{footer_flash});
    return _footer_legend($cols);
}

sub _footer_role {
    my ($state) = @_;
    my $pending = $state->{pending};
    if (defined($pending) && !ref($pending) && ($pending eq 'stop-runs' || $pending eq 'full-shutdown' || $pending eq 'relaunch')) {
        return 'state.crit';
    }
    if (defined($state->{footer_flash}) && !ref($state->{footer_flash}) && length($state->{footer_flash})) {
        return 'state.warn';
    }
    return 'text.faint';
}

sub _status_alert_msg {
    my ($s) = @_;
    $s = {} unless ref($s) eq 'HASH';
    my $st = (defined($s->{status}) && !ref($s->{status})) ? lc($s->{status}) : '';
    my $ms = (defined($s->{machine_state}) && !ref($s->{machine_state})) ? lc($s->{machine_state}) : '';
    return 'podman machine is stopped - [l] relaunch to start the machine and container, or [q] quit'
        if $ms eq 'stopped';
    if ($s->{container_gone}) {
        return ($st && $st ne 'unknown')
            ? "container is not running ($st) - [l] relaunch, or [q] quit and re-run claude-sandbox"
            : 'container unreachable - [l] relaunch, [r] retry, or [q] quit';
    }
    return undef if $st eq '' || $st eq '?' || $st eq 'running'
                 || $st eq 'created' || $st eq 'restarting';
    return 'container unreachable (podman down or host asleep) - [l] relaunch, [r] retry, [q] quit'
        if $st eq 'unknown';
    return "container is $st (not running) - [l] relaunch, or [q] quit and re-run claude-sandbox";
}

sub _lifecycle_alert_msg {
    my ($state) = @_;
    return undef unless ref($state) eq 'HASH';
    my $lc = $state->{lifecycle};
    return undef unless ref($lc) eq 'HASH';
    my %mode_label = ('stop-runs' => 'stop runs', 'full-shutdown' => 'full shutdown', 'recover' => 'recover');
    # Fix batch (package 06, red-team finding, latent/low): every field below
    # is guarded with `!ref` (treated the same as absent -> '?') before it
    # can reach a string interpolation -- without it, a hashref/arrayref
    # value (untrusted lifecycle state) would stringify to its heap-address
    # form (e.g. "HASH(0x...)") straight onto the operator's screen.
    my $mode  = (defined($lc->{mode}) && !ref($lc->{mode})) ? $lc->{mode} : '';
    my $label = $mode_label{$mode};
    $label = (length($mode) ? $mode : '?') unless defined $label;
    if ($lc->{active}) {
        my $index  = (defined($lc->{index})  && !ref($lc->{index}))  ? $lc->{index}  : '?';
        my $total  = (defined($lc->{total})  && !ref($lc->{total}))  ? $lc->{total}  : '?';
        my $slabel = (defined($lc->{label})  && !ref($lc->{label}))  ? $lc->{label}  : '?';
        my $sstate = (defined($lc->{state})  && !ref($lc->{state}))  ? $lc->{state}  : '?';
        return "$label $index/$total: $slabel - $sstate";
    }
    my $summary = (defined($lc->{summary}) && !ref($lc->{summary})) ? $lc->{summary} : '?';
    return "$label done: $summary";
}

sub _banner_lines {
    my ($state) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my @msgs = grep { defined($_) && length($_) }
        ( _lifecycle_alert_msg($state), _status_alert_msg($state),
          (defined($state->{install_warning}) && !ref($state->{install_warning}) ? $state->{install_warning} : undef) );
    return [ map { '  !! ' . tui::Frame::safe($_) } @msgs ];
}

# ===========================================================================
# screen(\%state, $cols) / compose(\%state, $rows, $cols) -- composition,
# header and reflow (spec S2.4.9, criterion 7, Decisions 13/14).
# ===========================================================================
sub screen {
    my ($state, $cols) = @_;
    $state = {} if ref($state) ne 'HASH';
    $cols = 1 if !defined($cols) || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/ || int($cols) < 1;
    $cols = int($cols);

    return {
        title       => header_spans($state, $cols),
        title_role  => 'accent',
        banners     => _banner_lines($state),
        banner_role => 'state.crit',
        panels      => panels($state, $cols),
        footer      => _footer_text($state, $cols),
        footer_role => _footer_role($state),
    };
}

sub compose {
    my ($state, $rows, $cols) = @_;

    # Derive the Run panel's row budget from the ACTUAL terminal height. This is
    # the only place in the module that knows $rows, and screen()'s signature is
    # deliberately left alone (its callers and tests are many), so the budget
    # travels the one way it can: as a derived key on a shallow copy of state.
    #
    # A third of the height, floor 3: enough that a normal terminal shows every
    # blueprint (the operator had twelve, saw three, and had most of a screen
    # empty below them), while a short terminal still gets a Run panel that
    # cannot crowd out everything beneath it. A caller that has already set
    # run_rows_max wins -- this only supplies a default.
    if (ref($state) eq 'HASH' && !defined $state->{run_rows_max}) {
        my $h = (defined($rows) && !ref($rows) && $rows =~ /\A\d+\z/) ? $rows : 0;
        my $budget = int($h / 3);
        $budget = 3 if $budget < 3;
        $state = { %$state, run_rows_max => $budget };
    }

    return tui::Screen::compose(screen($state, $cols), $rows, $cols);
}

1;
