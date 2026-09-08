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
# The `<1m` branch is the sub-minute floor (2026-08-26) -- see fmt_duration's
# own note. Nothing emits a bare seconds figure any more, but the \d+s branch
# stays: this constant is the SHAPE VALIDATOR for duration-looking tokens found
# anywhere on a rendered frame, and narrowing it would turn a stray seconds
# reading from something a test can catch into something it silently ignores.
use constant DURATION_RE => qr/\A(?:<1m|\d+s|\d+m|\d+h\d{2}m|\d+d\d{2}h|n\/a)\z/;

sub fmt_duration {
    my ($s) = @_;
    return 'n/a' if !defined($s) || ref($s) || $s !~ /^-?\d+(?:\.\d+)?$/;
    $s = int($s);
    return 'n/a' if $s < 0;
    # SUB-MINUTE COLLAPSES TO "<1m" (operator, 2026-08-26: "All counters in the
    # format `Xs ago` or `Xs old` could be instead `<1m ago` and then `1m ago`").
    #
    # A seconds figure on these rows was precision nobody could use. "heartbeat
    # 52s ago" and "heartbeat 8s ago" call for exactly the same response --
    # none -- while the digits churn every tick, which is motion on a panel
    # whose whole design goal is to sit still. The one thing a reader actually
    # needs from that range is "it has not been a minute yet", and "<1m" says
    # that without redrawing.
    #
    # It is also the honest shape: every other rung of this ladder is a
    # coarsening (minutes drop seconds, hours drop minutes), so the bottom rung
    # coarsening too is the rule rather than an exception to it.
    return '<1m' if $s < 60;
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

# ---------------------------------------------------------------------------
# t05-no-colons. Operator, verbatim: "we use way too many instances of the
# character `:`. Its distracting. We need none of them."
#
# GUTTER_SEP is the separator between a label and its value, defined ONCE.
# Criterion 3 is explicit that the fix belongs at the shared render site rather
# than at nineteen call sites, and the two hardcoded copies of the gutter
# sprintf that used to sit in this file are folded into gutter() below for the
# same reason: a copy that has to be edited alongside its original is how the
# next colon gets reintroduced.
#
# THREE SPACES, NOT ONE, AND THAT IS WHAT MAKES THIS SAFE TO DO EVERYWHERE AT
# ONCE (blueprint Decision 21). " : " is three display columns and so is "   ",
# so every width computation, fit_spans budget, truncation point and row-width
# assertion downstream is unchanged -- only the characters differ. Collapsing
# to a single space would have shifted every value two columns left and turned
# a cosmetic change into a layout change.
#
# WHAT THIS RULE DOES NOT TOUCH (Decision 20): values. A label gutter, a
# provider prefix and a warning sentence are text this repo AUTHORS, and they
# lose their colons. An event body, a blueprint name, a container name, a path,
# an error string from a subprocess are DATA passing through -- rewriting those
# would make the screen disagree with the thing it reports on. A blueprint
# genuinely named foo:bar renders as foo:bar. Clock times keep their colon by
# Decision 2, operator-confirmed.
use constant GUTTER_SEP => '   ';

# ONE SPACE AFTER THE CLOCK, NOT THREE (operator request, 2026-08-25):
#
#     now:    22:15   o launch_start
#     wanted: 22:15 o launch_start
#
# The column was 6 wide with two trailing spaces, so an HH:MM -- always exactly
# five columns -- was followed by three. Nothing needed the slack: the width was
# 6 for the sake of the fmt_duration fallback used only when localtime itself
# fails, and paying a permanent three-column gap on every row for a degraded
# path that renders no clock at all is the wrong trade. That path now shifts a
# wide age ("23h59m") one column right instead; it is already the branch where
# the timestamp is not a timestamp.
#
# ACTIVITY_TIME_FMT is the SINGLE definition of the prefix's shape.
# Dashboard::recent_events emits it via activity_time_text(); ACTIVITY_HANG --
# the wrap indent, which must agree with it or a wrapped event body hangs at the
# wrong column -- is derived from it rather than restated. t/98 pins the pair.
use constant ACTIVITY_TIME_W => 5;                     # HH:MM
use constant ACTIVITY_GLYPH_W => 2;                    # glyph plus one space
use constant ACTIVITY_HANG => ACTIVITY_TIME_W() + 1 + ACTIVITY_GLYPH_W();

# activity_time_text($hhmm) -> the time span's text: the clock left-padded into
# ACTIVITY_TIME_W columns, then ONE space. PUBLIC -- Dashboard::recent_events
# builds the span from it, and the activity-row oracles derive their expected
# prefix from it rather than restating the sprintf.
sub activity_time_text {
    my ($hhmm) = @_;
    $hhmm = '' if !defined $hhmm || ref($hhmm);
    return sprintf('%-*s ', ACTIVITY_TIME_W(), $hhmm);
}

# gutter($label) -> the padded label span text. PUBLIC (used by the three
# label-rendering sites in this file).
sub gutter {
    my ($label) = @_;
    $label = '' if !defined $label;
    return sprintf('%-*s%s', LABEL_GUTTER(), tui::Frame::safe($label), GUTTER_SEP());
}

# pad_label($label, $width) -> a label padded to $width plus the separator.
# For the narrower, ad-hoc gutters in the Providers panel, which do not use
# LABEL_GUTTER's width but must use the same separator.
sub pad_label {
    my ($label, $width) = @_;
    $label = '' if !defined $label;
    $width = length($label) if !defined $width || ref($width) || $width !~ /^\d+$/;
    return sprintf('%-*s%s', $width, $label, GUTTER_SEP());
}

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

    # `gutter_width` NARROWS THE LABEL COLUMN FOR AN INDENTED ROW. The Providers
    # panel nests its facts under a provider heading, and that indent used to
    # push its VALUES two columns right of every other panel's -- see
    # _FACT_GUTTER for the full reasoning. A row that spends N columns on an
    # indent asks for a label column N narrower, and its values land in the one
    # shared column again. Absent, the row pays the full LABEL_GUTTER, which is
    # every other call site.
    my $gw = $spec{gutter_width};
    my $label_text = (defined($gw) && !ref($gw) && $gw =~ /^\d+$/)
        ? pad_label(tui::Frame::safe($label), $gw)
        : gutter($label);
    my @spans = (
        { text => $label_text, role => 'text.muted' },
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
    host_swap_used host_swap_total
    host_disk_dev host_disk_used host_disk_total
    host_cpu_pct host_cores
);

# sampler_wait_spans(\%fact) -> \@spans
#
# Renders the ONE case the resources panel used to collapse: no snapshot has
# ever been written. There are four genuinely different reasons for that and
# they used to share a sentence, so the panel could never say anything but
# "sampling - no reading yet" -- including when no reading was ever coming.
#
# The distinction that matters most is "started, then gone". fork() succeeding
# is not the sampler working: the child re-execs and can die at exec, and the
# log line the operator sees is written in the PARENT immediately after fork,
# before any of that is known. So a confirmed-dead child is reported at once and
# never waits out the grace window.
#
# `child_alive` undef means "not checked yet", which must never be read as
# "dead" -- an unchecked liveness falls through to the elapsed-based branches.
#
# Decision 2 (blueprint tui-operator-feedback): no colon in any value text here.
# The label gutter's own colon is package t05-no-colons' business, not this one's.
sub sampler_wait_spans {
    my ($fact) = @_;
    my $neutral = 'sampling - no reading yet';

    my ($text, $role) = ($neutral, 'text.muted');
    if (ref($fact) eq 'HASH') {
        my $status  = $fact->{status};
        my $alive   = $fact->{child_alive};
        my $elapsed = $fact->{elapsed};
        my $grace   = $fact->{grace};
        my $numeric = sub { my ($v) = @_; defined($v) && !ref($v) && $v =~ /^-?\d+(?:\.\d+)?$/ };

        if (defined $status && !ref($status) && $status eq 'failed') {
            $text = 'FAILED - sampler failed to start; no reading possible';
            $role = 'state.crit';
        } elsif (defined $alive && !ref($alive) && !$alive) {
            # SAY WHY WHEN WE KNOW WHY. The child's own STDERR is captured now,
            # so a validation failure names itself here instead of leaving the
            # operator with a dead end. Absent/unreadable -> the bare sentence,
            # exactly as before; this never invents a cause.
            my $why = $fact->{why};
            $text = (defined $why && !ref($why) && length $why)
                  ? "FAILED - sampler exited before writing a reading - $why"
                  : 'FAILED - sampler exited before writing a reading';
            $role = 'state.crit';
        } elsif ($numeric->($elapsed) && $numeric->($grace) && $elapsed >= $grace) {
            $text = 'STALLED - sampler still running, no reading after ' . fmt_duration($elapsed);
            $role = 'state.warn';
        }
    }

    return [
        { text => gutter('snapshot'), role => 'text.muted' },
        { text => $text, role => $role },
    ];
}

# spend_wait_spans($fact) -> \@spans. PURE, total, never dies.
#
# The spend panel's counterpart to sampler_wait_spans above, and deliberately
# the same four distinctions in the same vocabulary -- an operator who has
# learned what STALLED means in the Resources panel should not have to learn a
# second dialect one panel down.
#
# What it replaces is the reason this package exists. "no active run to report
# spend for" named a RUN as the missing thing, which stopped being true when
# spend gained a run-independent snapshot (blueprint Decision 11); and it was
# useless even before that, because the operator is essentially never in a
# fleet run. The four texts below each name something that could actually be
# acted on.
#
# NO COLON in any of them (Decision 2). The label gutter's own colon belongs to
# package t05-no-colons and is not touched here.
#
# THE NEUTRAL CASE NOW SAYS NOTHING, AND RETURNS NO SPANS (operator,
# 2026-08-28: "no point in having the 'collecting - no figures yet'").
#
# It was a fourth line restating what the panel had already said three times:
# every provider row above it independently renders "not collected yet", so the
# footnote added a row and no fact. The three OTHER texts stay, and the
# asymmetry is the point -- FAILED and STALLED name a fault that appears
# NOWHERE else on the screen (a sampler that died, or one still running with
# nothing to show after its grace), and losing those would trade a redundant
# row for a silent one. "Still collecting" is the expected state; a dead
# sampler is not.
#
# Returning an empty list rather than an empty string is deliberate: a span
# with no text still occupies a row, which is the row this exists to reclaim.
# The caller must therefore test before pushing -- see providers_lines.
sub spend_wait_spans {
    my ($fact) = @_;

    my ($text, $role) = (undef, 'text.faint');
    if (ref($fact) eq 'HASH') {
        my $status  = $fact->{status};
        my $alive   = $fact->{child_alive};
        my $elapsed = $fact->{elapsed};
        my $grace   = $fact->{grace};
        my $numeric = sub { my ($v) = @_; defined($v) && !ref($v) && $v =~ /^-?\d+(?:\.\d+)?$/ };

        if (defined $status && !ref($status) && $status eq 'failed') {
            $text = 'FAILED - spend sampler failed to start; no figures possible';
            $role = 'state.crit';
        } elsif (defined $alive && !ref($alive) && !$alive) {
            # undef means NOT CHECKED and must never read as dead -- the check
            # has not run on the first render, and reading undef as false would
            # make every healthy launch flash a failure.
            # Same as the resources sampler above: name the cause when the
            # child's captured STDERR gave us one, never invent it.
            my $why = $fact->{why};
            $text = (defined $why && !ref($why) && length $why)
                  ? "FAILED - spend sampler exited before writing figures - $why"
                  : 'FAILED - spend sampler exited before writing figures';
            $role = 'state.crit';
        } elsif ($numeric->($elapsed) && $numeric->($grace) && $elapsed >= $grace) {
            $text = 'STALLED - spend sampler still running, no figures after ' . fmt_duration($elapsed);
            $role = 'state.warn';
        }
    }

    return [] unless defined $text;
    return [ { text => $text, role => $role } ];
}

# _first_probe_reason(\%errors) -> one short reason | undef.
#
# ONE reason, not all of them: this is a single row in a shared band, and when
# every probe fails they almost always fail for the SAME reason (the podman
# socket is down, the machine is not running). Listing six copies of it would
# push the panel's real content off the screen to say one thing repeatedly.
#
# Deterministic pick -- the first probe key in sorted order that has a reason --
# so the row does not flicker between equally-true messages tick to tick, which
# is what an arbitrary hash order would do.
sub _first_probe_reason {
    my ($errs) = @_;
    return undef unless ref($errs) eq 'HASH';

    # A SPECIFIC REASON BEATS THE FALLBACK, whatever the key order.
    #
    # Resources::gather writes "probe produced no output" when it observed
    # nothing and had nothing better; the sampler overwrites that with the
    # command's own stderr where it captured some. Both end up in this hash, so
    # picking by sorted key alone showed "probe produced no output" from
    # `machine` while `stats` was sitting right there saying "Cannot connect to
    # Podman socket" -- the generic answer winning purely on the alphabet.
    #
    # Within each tier the pick stays sorted-key deterministic, so the row does
    # not flicker between equally-true messages from tick to tick.
    my $generic = qr/\Aprobe produced no output\z/;
    my $fallback;
    for my $k (sort keys %$errs) {
        my $v = $errs->{$k};
        next unless defined $v && !ref $v && length $v;
        $v =~ s/\s+/ /g;
        $v = substr($v, 0, 90) if length($v) > 90;
        return $v unless $v =~ $generic;
        $fallback = $v unless defined $fallback;
    }
    return $fallback;
}

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
        my $n = scalar(grep { !defined $res->{$_} } @RESOURCE_FACT_KEYS);

        # A SNAPSHOT WITH NOTHING IN IT IS NOT "fresh".
        #
        # This read "fresh, 24s old, 14 facts unavailable" in state.ok green on
        # the operator's screen -- a healthy-looking row above an empty panel.
        # It was accurate about the plumbing (a snapshot really had just been
        # written) and useless about the machine (it contained no readings).
        # "Broken", as reported.
        #
        # Freshness describes the FILE. What the operator needs is whether
        # there is anything in it, and when there is not, why not -- which the
        # sampler now records per probe (see _resources_probes: their stderr is
        # captured rather than sent to /dev/null).
        if ($n >= scalar(@RESOURCE_FACT_KEYS)) {
            my $why = _first_probe_reason($res->{snapshot_probe_errors});
            $text = 'no readings';
            $text .= ' - ' . $why if defined $why && length $why;
            $role = 'state.crit';
        } else {
            $text = 'fresh';
            $text .= ', ' . fmt_duration($age) . ' old' if $age_numeric;
            if ($n > 0) {
                $text .= ", " . count_of($n, "fact") . " unavailable";
                my $why = _first_probe_reason($res->{snapshot_probe_errors});
                $text .= " - $why" if defined $why && length $why;
            }
            $role = 'state.ok';
        }
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
        { text => gutter('snapshot'), role => 'text.muted' },
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

    # TERSE (operator request, 2026-08-25: "too verbose"). This read
    # "5 items, 0 approved, 5 pending   [b] manage" -- long enough to wrap onto
    # a second row inside a band-shared panel, which is how a one-line summary
    # came to cost two.
    #
    # The three numbers are not independent: pending is total minus approved,
    # so stating all three says the same thing twice. "5 items, 5 pending" is
    # the pair that carries the information -- how many there are, and how many
    # still want you -- and the key drops to "[b]" because the panel it opens
    # is titled Backpack and the row is labelled backpack.
    my @spans = ( { text => count_of($total, 'item'), role => 'text.primary' } );
    push @spans, { text => ", $pending pending", role => 'state.warn' } if $pending > 0;
    push @spans, { text => '  [b]', role => 'text.muted' };
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
# container_presentation($status, $gone) -> (\%p) with keys:
#   role     the Theme role (colour)
#   glyph    the Theme glyph TOKEN for the state, or undef when the spinner
#            alone represents it (running)
#   spinner  1 when an animated spinner leads the glyph
# PUBLIC, pure.
#
# ONE MAPPING, USED BY BOTH SURFACES. The header (this module) and the window
# title (Dashboard::window_title) each had their own copy of this table, and
# they disagreed: 'initialized' was missing from both, and when it was added to
# one the two rendered the same container differently. The duplication was the
# defect, so there is now a single function and the two callers differ only in
# what they do with the result.
#
# THE SPINNER MARKS AN ONGOING ACTION (operator, 2026-08-28). created,
# initialized, stopping and removing are all mid-transition -- something is
# happening and will finish on its own -- so they carry a spinner to the LEFT of
# their state glyph. 'running' is the special case: it is not a transition, so
# the spinner IS its glyph rather than a prefix to one.
#
# The families are the operator's calls, not podman's taxonomy:
#   stopped, paused  -> treated as exited (the container is not doing anything)
#   stopping         -> treated as exited, but ongoing, so it also spins
#   unknown          -> treated as "gone" (we cannot see it, which is the same
#                       practical situation as not being able to reach it)
sub container_presentation {
    my ($status, $gone) = @_;
    my $st = defined($status) ? $status : '';
    $st =~ s/^\s+//; $st =~ s/\s+$//;

    # 'word' OVERRIDES THE STATUS STRING, and this is the ONLY case where it
    # does -- everywhere else the header prints podman's own string verbatim.
    #
    # container_gone means the heartbeat could not reach the container and a
    # follow-up inspect did not say 'running'. Whatever status string we last
    # captured is therefore STALE BY DEFINITION: we asked, and could not get an
    # answer. Printing it produced "[<warning glyph> running]" -- the glyph
    # saying unreachable while the word said executing, with the word usually
    # winning the reader's attention because it is the part in English.
    #
    # So the word says what we actually know. The operator's ruling, given the
    # choice between this, "gone (was running)", and leaving the contradiction
    # in place.
    #
    # NOTE this does NOT distinguish a removed container from a podman machine
    # that is down -- both produce a failed exec and a non-'running' inspect, so
    # both land here. The Resources panel's machine_state is where that
    # difference is visible today.
    return { role => 'state.crit', family => 'unreachable', spinner => 0,
             word => 'unreachable' } if $gone;
    return { role => 'state.ok',   family => 'running',     spinner => 1 } if $st eq 'running';

    # "we cannot determine the state" -- the same practical situation as gone.
    return { role => 'state.crit', family => 'unreachable', spinner => 0 } if $st eq 'unknown';

    # Not doing anything. 'dead' and 'restarting' are Docker names kept for a
    # $PODMAN pointed at docker; podman itself never emits them.
    return { role => 'state.crit', family => 'stopped', spinner => 0 }
        if $st =~ /^(?:exited|stopped|paused|dead)$/;

    # Not doing anything, but on its way somewhere -- so it also spins.
    return { role => 'state.crit', family => 'stopped', spinner => 1 }
        if $st =~ /^(?:stopping|removing)$/;

    # Coming up.
    return { role => 'state.warn', family => 'coming', spinner => 1 }
        if $st =~ /^(?:created|initialized|restarting)$/;

    return { role => 'state.idle', family => 'idle', spinner => 0 };
}

# THE FAMILY IS SHARED; THE GLYPH IS PER-SURFACE, and keeping those separate is
# the point.
#
# An earlier version returned a single glyph token for both callers, which
# quietly replaced the HEADER's long-standing status glyphs with the window
# title's set -- a change nobody asked for. What actually had to be unified was
# which STATES group together (and whether they spin); how each surface draws a
# group is a separate question with different constraints:
#
#   header  renders in the terminal font, next to the status WORD, alongside the
#           status.* glyphs used elsewhere on the screen
#   title   renders in the desktop UI font, alone, with no word to disambiguate
#
# NO FAMILY DRAWS THE SAME ON BOTH SURFACES, and 'unreachable' was the exception
# that proved why it should not (operator, 2026-08-28).
#
# The header used to map unreachable to 'title.gone' -- the warning sign -- on
# the grounds that the operator had asked for that mark in both places. What that
# actually did was put an emoji-block codepoint (U+26A0) into the terminal, which
# is precisely what the no-emoji rule forbids. It went unnoticed because t/64
# waives that rule by TOKEN NAME (title.*), justified by title glyphs never
# reaching a terminal -- a claim this mapping falsified. The header now uses
# 'status.gone', its own non-emoji mark, and t/64 asserts that no terminal
# surface references a title.* token again.
#
# RULED 2026-08-28: the two vocabularies stay separate, permanently. The
# question had been open on taste alone -- one glyph set is simpler to hold in
# your head. What settled it is that the single family the two surfaces drew
# alike is the one that leaked an emoji into the terminal, so the shared entry
# was not a simplification, it was the defect. Unifying them means either the
# terminal takes emoji-block codepoints or the window title gives up the marks
# that survive taskbar truncation; both surfaces lose. They answer different
# questions -- the header has a status WORD beside it and the status.* set
# around it, the title has one glyph in a UI font and nothing to disambiguate
# it -- and container_presentation already carries everything they must agree
# on, which is the family and whether it spins.
# container_glyph($surface, \%presentation) -> Theme glyph token, or undef when
# the surface draws nothing of its own (running: the spinner IS the glyph).
#
# The table lives INSIDE the sub, not at file scope. t/66's AC-P1 forbids a
# top-level print/warn/say, and it scans the source outside sub bodies -- a
# file-scoped table containing the token 'status.warn' matched that scan. The
# guard is right to be blunt about it (the same oracle already had to learn to
# strip comments for the same reason), and the table has no business being a
# top-level side-effect-free-module exception anyway. It is small and rebuilt
# per call; container_glyph runs once per surface per frame.
sub container_glyph {
    my ($surface, $pres) = @_;
    return undef unless ref($pres) eq 'HASH';
    my %family_glyph = (
        header => { running => undef, coming => 'status.' . 'warn',
                    stopped => 'status.crit', unreachable => 'status.gone', idle => undef },
        title  => { running => undef, coming => 'title.paused',
                    stopped => 'title.exited', unreachable => 'title.gone', idle => undef },
    );
    my $map = $family_glyph{ $surface || '' } or return undef;
    return $map->{ $pres->{family} || 'idle' };
}

sub _container_role {
    my ($status, $gone) = @_;
    my $st = defined($status) ? $status : '';
    $st =~ s/^\s+//;
    $st =~ s/\s+$//;
    # THE STATUS SET IS PODMAN'S, VERIFIED against libpod/define/containerstate.go
    # (2026-08-28) rather than assumed. Podman's own doc comments:
    #
    #   created      storage configured, NOT yet created in the OCI runtime
    #   initialized  created in the OCI runtime but not started
    #   running      currently executing
    #   stopped      was running but has exited
    #   paused       has been paused
    #   exited       has stopped AND been cleaned up
    #   stopping     in the process of being stopped
    #   removing     in the process of being removed
    #   unknown      an error state where information cannot be retrieved
    #
    # 'initialized' WAS MISSING and fell through to state.idle -- so a container
    # created in the runtime but not yet started rendered with the "we do not
    # recognise this" glyph, when it is plainly transitional and belongs beside
    # 'created'. That gap existed because this list was written from memory of
    # Docker's state names.
    #
    # 'dead' and 'restarting' are DOCKER names, not podman ones -- neither
    # appears in podman's set. They are kept rather than removed: they cost one
    # alternation each, and a podman that ever grows Docker compatibility (or a
    # user pointing $PODMAN at docker) would otherwise silently fall through to
    # idle. Their presence is documented so nobody later "cleans up" a branch
    # believing it is live podman coverage.
    # DELEGATES, so there is exactly one table. This function survives because
    # it has many callers that only want the colour; the mapping itself moved to
    # container_presentation when the header and title were unified.
    return container_presentation($status, $gone)->{role};
}

# DERIVED FROM Theme, never restated. The frame count changed once already
# (ten pulsing frames -> eight uniform ones, 2026-08-25) and a literal here
# would have indexed past the end of the table on the very next frame.
#
# Builder, not a top-level literal -- AC-P1 (t/66) forbids this module calling
# into Theme:: at load time, the same rule _role_map() and _run_state_role_map()
# already live under. Memoized, so the list is still built once.
my $SPINNER_NAMES_MEMO;
sub _spinner_names {
    $SPINNER_NAMES_MEMO ||= [ map { "spinner.$_" } (1 .. Theme::SPINNER_FRAMES()) ];
    return $SPINNER_NAMES_MEMO;
}

sub _spinner_frame {
    my ($idx) = @_;
    return undef if !defined($idx) || ref($idx) || $idx !~ /^-?\d+(?:\.\d+)?$/;
    my $names = _spinner_names();
    my $n = scalar @$names;
    return undef if $n < 1;
    my $i = int($idx) % $n;
    $i += $n if $i < 0;
    return Theme::glyph($names->[$i]);
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
# (spec S2.4.9): the status block, then "ccpraxis sandbox - <project> -
# <container>" as one left-aligned phrase, then padding to $cols.
#
# This is the pre-narrowing strategy for the non-wrapping title surface
# (Decision D1, specs/d02-wrap-every-surface-spec.md): content is clipped to
# $cols here, before tui::Screen::compose's $rows==1 short-circuit ever
# hands it to make_cell, by design -- not a gap.
# ===========================================================================
sub header_spans {
    my ($state, $cols) = @_;
    $state = {} if ref($state) ne 'HASH';
    $cols = 1 if !defined($cols) || ref($cols) || $cols !~ /^-?\d+(?:\.\d+)?$/ || int($cols) < 1;
    $cols = int($cols);

    # THE CLAUSE SEPARATOR IS A MIDDLE DOT, IN THE RULE ROLE (operator,
    # 2026-08-26: "I would like to replace the `-` separator with another
    # character. Maybe just a center dot with a different darker and less
    # saturated color?").
    #
    # A hyphen is a word that reads as part of the sentence -- "ccpraxis sandbox
    # - proj - claude-proj-2c052ba3" has hyphens inside the container id too, so
    # the same character was doing two different jobs on one row. A middle dot
    # is punctuation that cannot be confused for content, and painting it in the
    # 'rule' role -- the darkest, least saturated token in the palette, already
    # the one every border uses -- makes the clauses separate without the
    # separator asking to be read.
    #
    # It is a SPAN OF ITS OWN precisely so it can carry that role; the clause
    # texts keep 'accent'.
    my $pn = ref($state->{project_name}) ? undef : $state->{project_name};
    my $sep_glyph = Theme::glyph('sep.dot');
    $sep_glyph = '-' if !defined $sep_glyph || !length $sep_glyph;
    my @sep = ( { text => " $sep_glyph ", role => 'rule' } );

    my @left = ( { text => 'ccpraxis sandbox', role => 'accent' } );
    push @left, @sep, { text => tui::Frame::safe($pn), role => 'accent' }
        if defined($pn) && length($pn);

    my $ctr_raw = ref($state->{container}) ? undef : $state->{container};
    my $ctr = tui::Frame::safe(defined($ctr_raw) ? $ctr_raw : '');
    my $st_raw = ref($state->{status}) ? undef : $state->{status};
    # The word is podman's status string verbatim -- EXCEPT where the mapping
    # supplies an override (container_gone -> 'unreachable'), because there the
    # captured string is known to be stale. See container_presentation.
    my $_pres_word = container_presentation($state->{status}, $state->{container_gone})->{word};
    my $st = tui::Frame::safe(
        defined($_pres_word) ? $_pres_word
      : ((defined($st_raw) && length($st_raw)) ? $st_raw : '?'));

    my $role = _container_role($state->{status}, $state->{container_gone});

    # THE SPINNER ONLY SPINS WHEN SOMETHING IS RUNNING.
    #
    # This called _spinner_frame unconditionally, so an exited container
    # rendered as "[<spinner> exited]" -- a progress animation attached to a
    # state that is, by definition, not progressing. The operator's report:
    # "[spinner exited] no reason for a spinner if the status is exited."
    #
    # The window title already worked this way (its lead character animates only
    # while running, and every attention state keeps a literal character), so
    # this makes the header agree with the title rather than inventing a rule.
    # A non-running state gets the STATIC glyph for its own role, which is also
    # the glyph that state uses everywhere else on the screen.
    # The header and the window title now read the SAME mapping, so a state
    # cannot render as one thing here and another in the taskbar.
    #
    # A transitional state shows BOTH: the spinner (something is happening) and
    # its state glyph (what is happening). 'running' shows the spinner alone,
    # because running is not a transition -- there is no second fact to add.
    my $pres  = container_presentation($state->{status}, $state->{container_gone});
    my $token = container_glyph('header', $pres);
    my $spin  = '';
    if ($pres->{spinner}) {
        my $f = _spinner_frame($state->{spinner_idx});
        $spin .= $f if defined $f;
    }
    if (defined $token) {
        my $g = Theme::glyph($token);
        $spin .= (length($spin) ? ' ' : '') . $g if defined($g) && length($g);
    }
    # NO '?' FALLBACK HERE, deliberately -- that belongs to the window title.
    #
    # An absent spinner index is a normal transient (state not yet populated),
    # and the old contract rendered "[running]" with no glyph at all. Falling
    # back to '?' turned that into "[? running]", which reads as "we do not know
    # what this is" directly beside the word telling you exactly what it is.
    #
    # The title needs a fallback because its glyph is the ONLY thing it has. The
    # header always has the status word, so an absent glyph costs nothing and
    # inventing one costs clarity.
    $spin = undef if !length $spin;

    # The STATUS BLOCK LEADS the line (operator request, 2026-08-25).
    #
    # It used to be the last thing on the row, tucked behind the container id at
    # the far right -- the one element that changes every frame, parked in the
    # corner the eye reaches last, and the first thing clipped when the terminal
    # narrows. It is the single most important word on the screen: it is the
    # answer to "is this thing alive". So it goes where reading starts, and the
    # container id -- which never changes and is only ever read deliberately --
    # takes the right-hand slot it vacated.
    my @lead = (
        { text => '[', role => 'accent' },
        (defined($spin) ? ( { text => "$spin ", role => $role } ) : ()),
        { text => $st, role => $role },
        { text => '] ', role => 'accent' },
    );
    # THE CONTAINER ID IS NOT RIGHT-JUSTIFIED ANY MORE (operator request,
    # 2026-08-25):
    #
    #   now:    [o running] ccpraxis sandbox - proj        claude-proj-2c052ba3
    #   wanted: [o running] ccpraxis sandbox - proj - claude-proj-2c052ba3
    #
    # Justification put a variable-width gap in the middle of the row, so the id
    # sat at a column that moved with the terminal and with the project name --
    # nothing else on the screen is placed that way, and the gap read as two
    # unrelated things sharing a row rather than one sentence naming this
    # sandbox. It is now a third clause of the same phrase, joined by the same
    # separator that already joins the project to "ccpraxis sandbox", and the
    # padding goes where padding goes everywhere else: at the end.
    my @right = (length($ctr) ? ( @sep, { text => $ctr, role => 'accent' } ) : ());

    my $leadw = tui::Frame::spans_width(\@lead);
    my $lw    = tui::Frame::spans_width(\@left);
    my $rw    = tui::Frame::spans_width(\@right);

    if ($leadw + $lw + $rw <= $cols) {
        return [
            @lead,
            @left,
            @right,
            { text => (' ' x ($cols - $leadw - $lw - $rw)), role => 'accent' },
        ];
    }
    # Too narrow for all three. The status block survives and the container id
    # is dropped first -- the reverse of the old precedence, and deliberately
    # so: an operator squinting at an 80-column window needs the state far more
    # than an id they can read off `podman ps`.
    if ($leadw + $lw <= $cols) {
        return [ @lead, @{ tui::Frame::fit_spans(\@left, $cols - $leadw, 'accent') } ];
    }
    return tui::Frame::fit_spans([ @lead, @left ], $cols, 'accent');
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

# _one_run_summary_cells($s) -> \@cells, one per TABLE COLUMN, in column order.
#
# t04-blueprints-table. This used to be _one_run_summary_spans and returned one
# flat, concatenated span list per run -- variable-width fields glued together
# with two-space separators, so the state of run 2 sat under the middle of run
# 1's name and nothing below the first field lined up with anything. The
# operator's words: "hard to see with things randomly aligned."
#
# The change is that a row now describes its CELLS and lets tui::Frame::table
# decide the widths, because only the table can see the other rows. A per-row
# renderer structurally cannot align anything.
#
# The colon after the blueprint name is gone with the concatenation (Decision 2).
# In a table the column IS the separator; a colon would be decoration.
sub _one_run_summary_cells {
    my ($s) = @_;
    $s = {} unless ref($s) eq 'HASH';

    my $bp = (defined($s->{blueprint}) && !ref($s->{blueprint}) && length($s->{blueprint})) ? $s->{blueprint} : '?';
    my $state = (defined($s->{state}) && !ref($s->{state}) && length($s->{state})) ? $s->{state} : '?';
    my $done  = _nonneg_int($s->{packages_done});
    my $total = _nonneg_int($s->{packages_total});
    my $coord = _nonneg_int($s->{running_coordinators});
    # ONLY WHAT NEEDS THE OPERATOR (operator, 2026-08-28: "panel should only
    # show what actually needs me").
    #
    # decisions_waiting is the TOTAL, and it counts two different things: the
    # decisions a human must make, and the ones an automated resolver is
    # expected to triage. Showing the total meant the panel raised its hand for
    # work nobody needed to look at -- and the resolver's queue moving on its
    # own made the number tick down for no reason the operator could see.
    #
    # decisions_operator is that split's human half. FALLING BACK to the total
    # when the split is absent is deliberate and matches launcher.pl's own
    # _count_needs_you: a summary written by an older RunState has no split, and
    # erring toward "the operator owns it" is the safe direction -- silently
    # reporting zero would hide real work.
    my $waiting = defined($s->{decisions_operator})
                ? _nonneg_int($s->{decisions_operator})
                : _nonneg_int($s->{decisions_waiting});

    # decisions_triage is the automated-resolver half of the same split
    # (RunState.pm:724). It rides in the SAME cell as the waiting count --
    # not a new column -- so the two figures sit adjacent and are visible
    # together; see spec S2.2.1 for why a sixth column/new line were both
    # rejected. Its own word ("triage") and its own role (text.muted) keep
    # it distinguishable from decisions_operator's "N waiting" span.
    my $triage = _nonneg_int($s->{decisions_triage});

    my @waiting_cell = ( {
        text => ($waiting > 0 ? sprintf('%d waiting', $waiting) : ''),
        role => ($state eq 'paused' ? 'state.crit' : 'state.warn'),
    } );
    if ($triage > 0) {
        my $lead = ($waiting > 0) ? ', ' : '';
        push @waiting_cell, { text => $lead . sprintf('%d triage', $triage), role => 'text.muted' };
    }

    return [
        [ { text => $bp,    role => 'accent' } ],
        [ { text => $state, role => (_run_state_role_map()->{$state} // 'text.muted') } ],
        [ { text => sprintf('%d/%d pkg', $done, $total), role => 'text.primary' } ],
        [ { text => ($coord > 0 ? sprintf('%d coord', $coord) : ''), role => 'accent' } ],
        \@waiting_cell,
    ];
}

# _current_package_line($s) -> a spans row, or undef.
#
# THE CURRENT PACKAGE IS DELIBERATELY NOT A TABLE COLUMN, and the reason is a
# rule this project already paid for. Package d02 of the predecessor initiative
# closed bug report 20260814-093052-312a with a standing requirement, asserted
# by plugins/sandbox/tests/t/75-wrap-on-overflow.t AC1: an overflowing row must
# WRAP, and no word may be silently dropped. A table column that is given up
# when the panel is narrow drops content -- which is exactly what that rule
# forbids, and the first draft of this package did it. t/75 caught it.
#
# It is also bad table design independently. Every other field here is a short,
# bounded token (a state word, two counters); a package identifier is
# unbounded free text, and it is the single field most responsible for the
# "randomly aligned" appearance the operator reported. Measured: at a typical
# 48-column band, name + state + count + gaps already spend 45, so a `cur`
# column would have been dropped on nearly every real screen -- present in the
# design and absent from the display.
#
# As its own indented line it goes through _render_panel's ordinary wrap, so it
# wraps like any other row and stays fully readable at any width.
sub _current_package_line {
    my ($s) = @_;
    return undef unless ref($s) eq 'HASH';
    my $cp = $s->{current_package};
    return undef unless defined $cp && !ref($cp) && length $cp;
    return [ { text => '  cur ' . substr($cp, 0, 200), role => 'text.primary' } ];
}

# _paused_reason_line($s) -> a spans row, or undef.
#
# Same shape as _current_package_line above: an optional standalone line
# beneath a run's table row, not a table column. Gated on state=>'paused' IN
# ADDITION TO paused_reason being present -- paused_reason is carried forward
# from the .paused marker file and this sub has no way to prove it was
# cleared the instant a run resumed, so the row's own state cell (already
# trusted as authoritative) is what gates rendering. See spec S2.1.1.
#
# Deliberately does NOT sanitize/truncate-for-control-chars/re-encode: that is
# the render pipeline's job, done exactly once, downstream (Frame::wrap_line
# -> spanify -> safe). See spec S2.1.2.
sub _paused_reason_line {
    my ($s) = @_;
    return undef unless ref($s) eq 'HASH';
    return undef unless defined($s->{state}) && $s->{state} eq 'paused';
    my $reason = $s->{paused_reason};
    return undef unless defined $reason && !ref($reason) && length $reason;
    return [ { text => '  paused ' . substr($reason, 0, 200), role => 'state.warn' } ];
}

# The table's shape, declared once beside the cells it describes.
#
# `drop` is the order columns are given up when the panel is too narrow --
# HIGHEST FIRST -- and only two columns carry one:
#   coordinator count (2) goes first: an operational detail, not a status;
#   waiting count (1) next, because it is the only field that says a human is
#     BLOCKING the run.
# Name, state and package count have no `drop` entry and are never dropped:
# without them the row identifies nothing, and there would be no table left.
sub _BLUEPRINT_TABLE_OPTS {
    return {
        gap   => 2,
        align => [ 'left', 'left', 'right', 'right', 'right' ],
        min   => [ 8,      4,      5,       3,       3       ],
        drop  => [ undef,  undef,  undef,   2,       1       ],
    };
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
    my ($runs, $max_rows, $width) = @_;
    return [] unless ref($runs) eq 'ARRAY';
    my @summaries = grep { ref($_) eq 'HASH' } @$runs;
    return [] unless @summaries;

    $max_rows = scalar(@summaries)
        unless defined($max_rows) && !ref($max_rows) && $max_rows =~ /\A\d+\z/ && $max_rows >= 1;
    my $shown = (@summaries < $max_rows) ? scalar(@summaries) : $max_rows;

    # THE WHOLE TABLE IS BUILT AT ONCE, which is the point: column widths come
    # from every row that will be shown, so a reader can scan down a column.
    # The "+N more" footer is deliberately NOT a table row -- it belongs to no
    # column and would otherwise widen the first one for everybody.
    my $opts = { %{ _BLUEPRINT_TABLE_OPTS() } };
    $opts->{width} = $width if defined $width && !ref($width) && $width =~ /^\d+$/;
    my $rows = tui::Frame::table(
        [ map { _one_run_summary_cells($summaries[$_]) } 0 .. $shown - 1 ], $opts);

    # Interleave each run's optional sub-lines directly beneath its own row, so
    # the association is positional and needs no repeated label.
    #
    # ORDER IS DELIBERATE (spec S2.3): the paused reason comes BEFORE the
    # current-package line. A parked run's reason is why the operator is being
    # asked to look at all, so it must not be pushed below a package name that is
    # merely incidental to it. Both lines are optional and independent -- either,
    # neither, or both may render, and when neither does the run's output is
    # byte-identical to what it was before this package existed (t/182 AC9/AC10
    # pin exactly that).
    my @out;
    for my $i (0 .. $shown - 1) {
        push @out, $rows->[$i] if defined $rows->[$i];
        my $reason = _paused_reason_line($summaries[$i]);
        push @out, $reason if $reason;
        my $cur = _current_package_line($summaries[$i]);
        push @out, $cur if $cur;
    }
    if (@summaries > $max_rows) {
        my $extra = @summaries - $max_rows;
        push @out, [ { text => "+" . count_of($extra, "more blueprint"), role => 'text.muted' } ];
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

    # `needs you` now counts ONLY escalations a human must clear. It used to
    # count every queued record, most of which the escalation resolver handles
    # without waking anyone -- so the row asserted ownership over a queue it had
    # never looked inside, and said "1 decision waiting" when nothing wanted the
    # operator at all.
    my $ny = (defined($state->{needs_you}) && !ref($state->{needs_you}) && $state->{needs_you} =~ /^\d+$/) ? $state->{needs_you} : 0;
    if ($ny > 0) {
        my $ny_row = row({ label => 'needs you', value => count_of($ny, "decision") . " waiting", role => 'state.warn' });
        push @lines, $ny_row if @$ny_row;
    }

    # The rest stay VISIBLE, just not as the operator's problem. The resolver can
    # be capped or unwired -- it was entirely unwired until 2026-08-24 -- and
    # then these sit still. Muted, and only when there are any: a queue being
    # worked is not news.
    my $tq = (defined($state->{triage_queued}) && !ref($state->{triage_queued}) && $state->{triage_queued} =~ /^\d+$/) ? $state->{triage_queued} : 0;
    if ($tq > 0) {
        my $tq_row = row({ label => 'in triage', value => count_of($tq, "escalation") . " with the resolver",
                           role => 'text.muted' });
        push @lines, $tq_row if @$tq_row;
    }

    my $bp_val = backpack_summary_spans($state->{backpack});
    my $bp_row = row({ label => 'backpack', value => $bp_val });
    push @lines, $bp_row if @$bp_row;

    # THE 'oauth' ROW IS GONE (operator, 2026-08-28). It rendered only when
    # $state->{tokens} was absent, and said the same thing -- through the same
    # _fmt_oauth_like formatter -- that Providers' Claude Code "access" row
    # says. Two credential facts in two panels, told apart only by which one
    # happened to have data. The fallback now feeds that row instead; see
    # _claude_code_block's $oauth_fallback.

    # THE PODMAN INSTALLATION FACTS CLOSE THE PANEL (operator, 2026-08-27).
    # `machine` and `podman` describe the runtime this panel's runs execute in,
    # which is why they belong beside them rather than among the live gauges in
    # Resources. They come last so the run-specific rows above keep the position
    # the operator already reads them in.
    push @lines, @{ _podman_install_lines($state->{resources}) };

    return \@lines;
}

# ===========================================================================
# _blueprints_body(\%state) -- the Blueprints panel body (package
# t01-providers-panel, criteria 6/7). Relocated from the tail of _run_body:
# the row budget that used to bound Run (run_rows_max) is renamed
# blueprint_rows_max (D5) and now bounds THIS panel, never Run. Blueprints is
# unconditionally present (D4, same reasoning as Resources/Providers), so an
# empty/absent/non-array $state->{runs} renders one honest no-data line
# rather than an empty panel.
# ===========================================================================
# _blueprints_table_width($cols) -> the display columns a Blueprints row may
# actually use, or undef when $cols says nothing useful.
#
# THE TABLE HAS TO SIZE ITSELF TO THE BAND IT WILL LAND IN, not to the terminal.
# panels() is handed the FULL terminal width, but this panel is then placed into
# one band of a multi-column layout and, since t03, into the main region left of
# the activity column. Sizing to $cols would build a table two or three times
# wider than the space it gets, and _render_panel's wrap would then break the
# rows -- destroying exactly the alignment this package exists to create.
#
# So: subtract the side column, ask tui::Layout for the bands at that width,
# and take the NARROWEST. Deliberately the narrowest rather than the band this
# panel happens to occupy today: the placement depends on how many panels are
# present and on their min_cols, and a table that silently over-runs when a
# panel is added elsewhere would be a bug nobody connects to this code. The
# cost of being conservative is that the table is sometimes narrower than it
# could be; the cost of being wrong is a broken layout.
sub _blueprints_table_width {
    my ($cols) = @_;
    return undef if !defined $cols || ref($cols) || $cols !~ /^\d+$/ || $cols < 1;
    my $main = $cols - tui::Screen::side_column_width($cols);
    my $bands = tui::Layout::columns($main);
    return undef if ref($bands) ne 'ARRAY' || !@$bands;
    my $narrow;
    for my $b (@$bands) {
        next unless ref($b) eq 'HASH' && defined $b->{w};
        $narrow = $b->{w} if !defined $narrow || $b->{w} < $narrow;
    }
    return undef if !defined $narrow;
    # _render_panel bakes a two-column body indent into every row before
    # wrapping, and adds WRAP_CONTINUATION_INDENT on top for any row that does
    # wrap. Give the table the room that is actually left after the indent, so
    # a table that reports as fitting genuinely does.
    my $avail = $narrow - 2;
    return $avail > 0 ? $avail : undef;
}

sub _blueprints_body {
    my ($state, $cols) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my $lines = _run_summary_lines($state->{runs}, $state->{blueprint_rows_max},
                                   _blueprints_table_width($cols));
    return $lines if @$lines;
    # NO 'blueprints' LABEL (operator request, 2026-08-25: "that's unnecessary
    # repeating"). The panel is titled Blueprints and this is its only row, so
    # the gutter was spending eleven columns restating the title directly
    # beneath itself. Every OTHER row in this dashboard earns its label by
    # distinguishing itself from its siblings; a lone row has no siblings.
    return [ [ { text => 'no active runs', role => 'text.muted' } ] ];
}

# ===========================================================================
# The Resources panel body (spec S2.4.5, Obligation 4). Called both by
# panels() (below) and by Dashboard::_resources_lines (the direct-call
# oracle site), so the composed frame and the direct-call result can never
# diverge. Not part of the spec's headline public-surface list, but a normal
# Perl cross-package call -- Dashboard consuming tui:: is this package's
# whole point (Obligation 2).
# ===========================================================================
# ===========================================================================
# THE RESOURCES PANEL IS A TABLE, AND THE GAUGE IS ITS FIRST COLUMN
# (operator, 2026-08-26: "everything in the resources cell is misaligned. I
# wish it was a neat table instead", then: "Full table but the bars become the
# first thing").
#
# Every gauge row now has the same four columns:
#
#   <label gutter> <bar> <percent> <figures> <trailing note>
#
# The bar leading is not only what was asked for, it is what makes the rest of
# the table possible. With the figures first, the bar started wherever that
# row's numbers happened to end -- and since "2.1 GB used" and "231.3 GB used"
# are different widths, every bar and every percent landed in a different
# column. Putting the fixed-width things first means the gauges form a clean
# column immediately after the label, and the variable-width figures trail off
# to the right where their raggedness costs nothing.
#
# It also fixes the two CPU rows, which had no place in the old geometry at
# all: ctr cpu printed a bare percentage and host cpu printed a percentage
# followed by a bar, so neither lined up with anything. They are now ordinary
# gauge rows with an empty figures column.
#
# Rows with no gauge at all (snapshot, machine, podman) are unchanged: their
# text starts at the label gutter, where the bar column begins.
# ===========================================================================

# _gauge_value_spans($ratio, $pct_text, $figures, \@trail) -> \@spans -- the
# value half of a gauge row, in column order. $figures may be undef (the CPU
# rows have no used/free/total to show).
# _gauge_role($ratio) -> the role the FILL and the percent carry.
#
# COLOUR ONLY WHERE IT MEANS SOMETHING (operator, 2026-08-26: "I want the colors
# and styling of the usage bars to less distracting. I like the color coding and
# all, but right now it's not good").
#
# Every gauge row used to paint its bar, its percent AND its figures in
# pressure_role -- so a perfectly healthy machine rendered as five rows of
# bright green, and the one row that had something to say looked exactly as
# loud as the four that did not. Colour that is always on carries no
# information; it is just brightness.
#
# So the alarm palette is reserved for the alarm. Below the warn threshold --
# the normal state, and the state the panel is in nearly all the time -- a gauge
# is neutral grey and recedes into the panel. At warn and crit it takes
# pressure_role and becomes the only coloured thing on the screen, which is
# exactly when that is worth being.
# ...AND THE NORMAL FILL IS ACCENT, NOT GREY (same operator request, the
# "different colors" half).
#
# The first pass at quieting these rows made the below-warn fill text.muted --
# correct in that it stopped shouting, wrong in that it left the gauge
# indistinguishable from the label beside it. A meter is a UI element; it should
# read as one. accent is the token this design system already spends on "this is
# a thing, not prose" (the project name in the header, the used-token count in
# the statusline), it is calm, and it is nowhere near the alarm palette.
#
# So the ramp is now accent -> state.warn -> state.crit: an identity at rest, an
# alarm only under pressure. The track stays 'rule' either way.
# _gauge_role($ratio) -> the Theme role the FILL is painted in.
#
# A FOUR-STEP RAMP over the Radix step-9 palette (Theme's gauge.* roles), which
# encodes magnitude continuously AND the two thresholds categorically:
#
#     < 50%              gauge.low    blue
#     50% .. warn        gauge.mid    teal
#     warn .. crit       gauge.warn   orange
#     >= crit            gauge.crit   red
#
# The two upper boundaries are tui::Meter's own PRESSURE_WARN/PRESSURE_CRIT,
# read through pressure_role rather than restated, so this cannot drift from the
# thresholds everything else uses. Only the extra split at half is local, and it
# is what turns a three-state indicator into a ramp.
#
# This replaced a scheme that painted everything below the warn threshold in
# 'accent': a disk at 5% and a disk at 70% looked identical, so the bar's colour
# carried no information until something was already wrong.
sub _gauge_role {
    my ($ratio) = @_;
    my $r = tui::Meter::pressure_role($ratio);
    return 'gauge.low' if !defined $r;
    return 'gauge.warn' if $r eq 'state.warn';
    return 'gauge.crit' if $r eq 'state.crit';
    # state.ok: split it at half so the healthy range is not one flat colour.
    return (defined($ratio) && !ref($ratio) && $ratio =~ /^-?\d+(?:\.\d+)?$/ && $ratio >= 0.5)
        ? 'gauge.mid' : 'gauge.low';
}

sub _gauge_value_spans {
    my ($ratio, $pct_text, $figures, $trail) = @_;
    return [ { text => 'n/a', role => 'text.muted' },
             (ref($trail) eq 'ARRAY' ? @$trail : ()) ] unless defined $ratio;

    my $role = _gauge_role($ratio);
    $pct_text = tui::Meter::percent_text($ratio) unless defined $pct_text;
    $pct_text = '' unless defined $pct_text;

    # THE TRACK IS NOT THE FILL. The empty cells carry 'gauge.track', so the
    # gauge reads as a dim channel with a marked portion, rather than as ten
    # coloured blocks of two shades.
    #
    # That token used to be 'rule' -- shared with every border on the screen --
    # and it was split out because the two are held to different standards: a
    # border only needs to be visible against the background, a track also needs
    # to be distinguishable from the fill beside it. Theme.pm carries the
    # measured contrast figures behind the split.
    #
    # The separation is now carried by WEIGHT as well as colour: the fill glyph
    # is a heavy rule and the track a light one, so the gauge survives being
    # read on a terminal whose palette flattens the two greys.
    my ($fill, $track) = tui::Meter::bar_split($ratio, tui::Meter::BAR_CELLS());
    my @spans;
    # atomic: a partly-drawn gauge reads as a DIFFERENT, wrong percentage, and a
    # clipped percent is the same lie in decimal. Both are dropped whole rather
    # than truncated -- tui::Frame::fit_spans honours this. The two halves are
    # marked separately, which is safe because they are adjacent and equal-width
    # either way: the failure fit_spans must avoid is a HALF-DRAWN bar, and
    # dropping one whole half still leaves a bar that cannot be misread as a
    # percentage, because the percent column sits right beside it.
    push @spans, { text => $fill,  role => $role,  atomic => 1 } if defined $fill  && length $fill;
    push @spans, { text => $track, role => 'gauge.track', atomic => 1 } if defined $track && length $track;
    push @spans, { text => ' ', role => $role };
    push @spans, { text => sprintf('%*s', tui::Meter::PERCENT_COL_WIDTH(), $pct_text),
                   role => $role, atomic => 1 };
    # THE FIGURES ARE NEVER ALARM-COLOURED. They are the longest run of
    # characters on the row, so painting them red turned one busy disk into a
    # wall of red text; the gauge beside them already says how bad it is. That
    # holds for the span form below too: none of its three roles is a state
    # colour.
    #
    # $figures is EITHER a plain string (one span, the historical shape, still
    # used by callers that have a single opaque figure) OR an arrayref of spans
    # from tui::Meter::numbers_used_free_total_spans, which splits quantity,
    # label word and separator so they can be weighted differently. Accepting
    # both is what let the byte rows gain structure without touching every
    # caller.
    if (ref($figures) eq 'ARRAY') {
        if (@$figures) {
            push @spans, { text => '  ', role => 'text.primary' };
            push @spans, @$figures;
        }
    }
    elsif (defined $figures && length $figures) {
        push @spans, { text => '  ' . $figures, role => 'text.primary' };
    }
    push @spans, @$trail if ref($trail) eq 'ARRAY';
    return \@spans;
}

# _bytes_gauge_spans($used, $total, \@trail) -> \@spans -- a gauge row whose
# figures are a used/free/total triple.
sub _bytes_gauge_spans {
    my ($used, $total, $trail) = @_;
    my $ratio = tui::Meter::ratio($used, $total);
    return _gauge_value_spans(undef, undef, undef, $trail) unless defined $ratio;
    my $avail = (!ref($used) && !ref($total)
                 && $used  =~ /^-?\d+(?:\.\d+)?$/
                 && $total =~ /^-?\d+(?:\.\d+)?$/) ? $total - $used : undef;
    $avail = 0 if defined($avail) && $avail < 0;
    return _gauge_value_spans($ratio, undef,
                              tui::Meter::numbers_used_free_total_spans($used, $avail, $total),
                              $trail);
}

# _pct_gauge_spans($pct, \@trail) -> \@spans -- a gauge row whose only figure
# IS the percentage, so it lives in the percent column and the figures column
# is empty.
#
# The decimal is GONE. This used to keep one, on the reasoning that a CPU
# reading moves continuously and the tenth is the part that shows it moving.
# That cost more than it bought: it made this the only row shape that could
# emit six columns into the percent field, which is what knocked the cpu rows
# out of alignment with their neighbours. The bar itself already shows movement,
# and the operator asked for the fraction to go.
# _figures_only_spans($text) -> \@spans -- a row that has FIGURES but no gauge,
# with those figures starting in the same column the gauge rows put theirs.
#
# The podman row is the only one of these (operator, 2026-08-26: "have its data
# aligned with the other cells below"). It reports three storage totals with no
# ratio to gauge them against -- there is no "total podman storage" to be a
# percentage OF -- so it leaves the bar and percent columns empty and joins the
# table at the figures column, which is exactly what "aligned with the other
# cells" means here.
sub _figures_only_spans {
    my ($text) = @_;
    return [ { text => 'n/a', role => 'text.muted' } ]
        unless defined $text && length $text;
    my $pad = tui::Meter::BAR_CELLS() + 1 + tui::Meter::PERCENT_COL_WIDTH() + 2;
    return [ { text => (' ' x $pad) . $text, role => 'text.primary' } ];
}

sub _pct_gauge_spans {
    my ($pct, $trail) = @_;
    return _gauge_value_spans(undef, undef, undef, $trail)
        unless defined($pct) && !ref($pct) && $pct =~ /^-?\d+(?:\.\d+)?$/;
    my $ratio = $pct / 100;
    $ratio = 0 if $ratio < 0;
    $ratio = 1 if $ratio > 1;
    # INTEGER, via percent_text, exactly like every other gauge row.
    #
    # This used to pass sprintf('%.1f%%', $pct) and it was the only row shape
    # that did, which made it the only one that could produce a SIX-column
    # percent ("100.0%") in a five-column field. The overflow pushed its own
    # figures one column right, so the cpu rows sat out of line with the mem and
    # disk rows directly above and below them -- the misalignment the operator
    # reported, and asked to fix by dropping the fraction: "No need for
    # fractional percentages."
    #
    # Passing undef here is deliberate rather than formatting an integer
    # locally: _gauge_value_spans then calls tui::Meter::percent_text itself, so
    # there is ONE percent formatter in the module and a row cannot drift from
    # the column width again.
    return _gauge_value_spans($ratio, undef, undef, $trail);
}

# _podman_install_lines(\%resources) -> \@lines -- the `machine` and `podman`
# rows, which describe the podman INSTALLATION rather than any live reading.
#
# THEY LIVE IN THE RUN PANEL, NOT RESOURCES (operator, 2026-08-27: "From the
# Resources panel, the `machine` line and the `podman` line go into the Run
# cell. The rest stays in a Resources cell").
#
# Extracted rather than duplicated: Resources still owns the measurements and
# Run owns the installation facts, but both render the SAME two rows from the
# same snapshot, so there is one place that knows their shape. They were
# adjacent in Resources already (machine-then-storage), which is why they move
# as a pair.
sub _podman_install_lines {
    my ($r) = @_;
    return [] unless ref($r) eq 'HASH';
    my @lines;

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

    # THE PODMAN ROW IS AN ORDINARY LABELLED ROW NOW, not a figures-column row.
    #
    # It used to go through _figures_only_spans, which pads by
    # BAR_CELLS + 1 + PERCENT_COL_WIDTH + 2 so that a row with no gauge still
    # lands its figures in the same column as the gauge rows' figures. That was
    # right while it lived in Resources, beneath the gauges it was aligning to.
    # It is in RUN now, where there are no gauges at all, so the padding lined
    # the text up against a column that does not exist -- the operator saw it as
    # "unnecessary spacing", which is exactly what it was.
    #
    # STYLED LIKE THE OTHER FIGURE ROWS: the quantity in text.primary, its label
    # word in text.muted. Previously the whole string was one text.primary span,
    # so "imgs" carried the same weight as "2.8 GB" and there was nothing for
    # the eye to lock onto.
    #
    # NO '|' SEPARATORS (operator: "no need for the separators"). They earn
    # their place in the used/free/total triple, where three same-shaped
    # quantities need dividing; here each figure is already introduced by its
    # own word, so the pipes were dividing things that were not run together.
    my ($pi, $pc, $pv) = ($r->{pod_images}, $r->{pod_containers}, $r->{pod_volumes});
    my $podman_val;
    if (defined($pi) || defined($pc) || defined($pv)) {
        my @spans;
        my @parts = ([ 'imgs', $pi ], [ 'ctrs', $pc ], [ 'vols', $pv ]);
        for my $i (0 .. $#parts) {
            my ($word, $v) = @{ $parts[$i] };
            push @spans, { text => '  ', role => 'text.muted' } if $i;
            push @spans, { text => $word . ' ', role => 'text.muted' };
            push @spans, { text => tui::Meter::fmt_bytes($v), role => 'text.primary' };
        }
        $podman_val = \@spans;
    }
    else {
        $podman_val = [ { text => 'n/a', role => 'text.muted' } ];
    }
    my $podman_row = row({ label => 'podman', value => $podman_val });
    push @lines, $podman_row if @$podman_row;

    return \@lines;
}

sub _resources_body {
    my ($r) = @_;
    return [] unless ref($r) eq 'HASH';
    my @lines;

    my $snap = snapshot_spans($r);
    push @lines, $snap if ref($snap) eq 'ARRAY' && @$snap;

    # MACHINE AND PODMAN ARE NO LONGER HERE. They describe the podman
    # installation, not a live reading, and the operator moved them into the Run
    # panel on 2026-08-27 -- see _podman_install_lines, which both panels share.
    # What remains is exactly the measurements: a snapshot age, then the
    # container gauges, then the host gauges.
    my $ctrmem_row = row({ label => 'ctr mem', value => _bytes_gauge_spans($r->{ctr_mem_used}, $r->{vm_mem_total}) });
    push @lines, $ctrmem_row if @$ctrmem_row;

    my $ctrcpu_row = row({ label => 'ctr cpu', value => _pct_gauge_spans($r->{ctr_cpu_pct}) });
    push @lines, $ctrcpu_row if @$ctrcpu_row;

    my $hostram_row = row({ label => 'host ram', value => _bytes_gauge_spans($r->{host_ram_used}, $r->{host_ram_total}) });
    push @lines, $hostram_row if @$hostram_row;

    # SWAP SITS DIRECTLY UNDER RAM (operator request, 2026-08-26: "like the host
    # mem counter but for swap"), which is also where it reads best -- the two
    # are one story, and a machine paging hard is only interesting next to how
    # full its RAM is. Same builder, same columns, no special case.
    my $hostswap_row = row({ label => 'host swap', value => _bytes_gauge_spans($r->{host_swap_used}, $r->{host_swap_total}) });
    push @lines, $hostswap_row if @$hostswap_row;

    my @disk_trail;
    push @disk_trail, { text => " ($r->{host_disk_dev})", role => 'text.muted' }
        if defined($r->{host_disk_dev}) && !ref($r->{host_disk_dev}) && length($r->{host_disk_dev});
    my $hostdisk_row = row({ label => 'host disk',
                             value => _bytes_gauge_spans($r->{host_disk_used}, $r->{host_disk_total}, \@disk_trail) });
    push @lines, $hostdisk_row if @$hostdisk_row;

    # THE CORE COUNT IS GONE (operator, 2026-08-26: "can drop the cores count
    # from the `host cpu` line. unnecessary"). It is a fact about the machine,
    # not about this moment -- it cannot change while the dashboard is open, so
    # it spent a permanent slot on a row whose whole job is what is happening
    # now. host_cores is still gathered and still in the snapshot; only the
    # rendering goes.
    my $hostcpu_row = row({ label => 'host cpu', value => _pct_gauge_spans($r->{host_cpu_pct}) });
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
    my @spans = ( { text => _status_glyph($key) . ' ', role => $role } );
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
    # NO DEFAULT DIAGNOSTIC. This fell back to the literal 'usage endpoint
    # unreadable', which rendered as "usage  x unreadable -- usage endpoint
    # unreadable" -- the word "usage" three times and "unreadable" twice, to say
    # one thing. The label already names the fact, so with nothing specific to
    # add the value is just the state. A REAL diagnostic still shows, because
    # that is the case where the extra words carry information.
    my $diag = (defined($c->{diagnostic}) && !ref($c->{diagnostic}) && length($c->{diagnostic}))
             ? $c->{diagnostic} : '';
    push @spans, { text => (length($diag) ? "unreadable -- $diag" : 'unreadable'),
                   role => 'state.crit' };
    return (\@spans, 1);
}

sub _spend_go_spans {
    my ($g) = @_;
    $g = {} unless ref($g) eq 'HASH';
    my $state = (defined($g->{state}) && $g->{state} =~ /^(?:absent|unreadable|exhausted|ok)$/) ? $g->{state} : 'absent';
    my ($role, $key) = _spend_state_style($state);
    my @spans = ( { text => _status_glyph($key) . ' ', role => $role } );
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
    my @spans = ( { text => _status_glyph($key) . ' ', role => $role } );
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

# ===========================================================================
# _providers_body(\%state, $cols) -- the Providers panel body (package
# t01-providers-panel, criterion 2). Replaces the old _token_body/_spend_body/
# _spend_unavailable_body trio with ONE builder that nests each provider's
# facts under its own heading, so which provider a fact belongs to is
# discoverable from the frame itself (the operator's actual complaint --
# ambiguity of referent -- not merely screen economy).
#
# Referent clarity is mechanical (Behavior 3): a heading line carries no
# ' : ' label-gutter and is indented LESS than the fact rows nested beneath
# it (_HEADING_INDENT < _FACT_INDENT), so a reader (and a test) can tell a
# heading from a fact by shape alone, never just by position.
#
# refresh-exp (TUI-03) has no successor row anywhere below -- it is gone, not
# relocated. refreshed folds into access as ONE row (TUI-04): the same
# _fmt_oauth_like/access-state text, plus the last-refreshed duration
# appended to the SAME row when last_refreshed_age is defined -- both changes
# land in this one builder, not as two sequential edits (criteria 3 and 4).
#
# The 'nearest' row (D1, criterion 5) is unchanged in wording/logic from the
# old _spend_body :777-792 above, but is now unshifted PANEL-LEVEL, outside
# every provider block -- it summarises a cross-provider fact, so nesting it
# under any one provider would misattribute it (reintroducing the exact
# ambiguity this package removes).
# ===========================================================================
use constant _HEADING_INDENT => 0;
use constant _FACT_INDENT    => 2;

# THE NESTING INDENT MUST NOT MOVE THE VALUE COLUMN (operator, 2026-08-25):
#
#     backpack      5 items, 5 pending  [b]      <- Run
#     snapshot      fresh, 15s old, ...          <- Resources
#       access        expires in 7h21m, ...      <- Providers, two columns out
#
# Every other panel puts a value at column LABEL_GUTTER + GUTTER_SEP. Providers
# paid that in full and then added _FACT_INDENT on top, so its values -- and
# only its values -- sat two columns right of the rest of the screen.
#
# The indent itself is NOT the thing to remove. It is what makes a fact's
# referent mechanical rather than positional: a heading is indented LESS than
# the facts beneath it (_HEADING_INDENT < _FACT_INDENT), which is the shape
# t/79's Behavior 3 checks and which exists because the operator could not tell
# which provider a figure belonged to. Flattening the nesting to fix the
# alignment would trade one complaint straight back for the other.
#
# So the indent is spent out of the LABEL column instead of on top of it: a row
# indented by _FACT_INDENT asks for a label column that much narrower, and lands
# its value in the same column as everything else. The nesting is still visible
# -- the LABELS are still indented, which is what the eye follows -- while the
# values line up across the whole screen.
use constant _FACT_GUTTER => LABEL_GUTTER() - _FACT_INDENT();

sub _indent_line {
    my ($n, $line) = @_;
    return $line unless ref($line) eq 'ARRAY' && @$line;
    return [ { text => (' ' x $n), role => 'text.primary' }, @$line ];
}

# _fact_line(\%row_spec) -> ONE indented, value-aligned Providers fact row (or
# [] when row() suppresses it). The single place _FACT_INDENT and _FACT_GUTTER
# are paired, so the two can never drift apart into a misalignment.
sub _fact_line {
    my ($spec) = @_;
    return _indent_line(_FACT_INDENT(), row({ %$spec, gutter_width => _FACT_GUTTER() }));
}

sub _provider_heading {
    my ($text) = @_;
    return _indent_line(_HEADING_INDENT(), [ { text => $text, role => 'accent' } ]);
}

sub _clip_line {
    my ($line, $protect, $w) = @_;
    return $line if $protect || tui::Frame::spans_width($line) <= $w;
    return tui::Frame::fit_spans($line, $w);
}

# The three provider blocks below share one wording change from t02.
#
# Each used to render "Claude : no snapshot" / "Go     : no snapshot" /
# "Zen    : no snapshot" when no snapshot existed. Three problems in one
# string, and the operator's report quoted it:
#
#   1. It repeated the provider name that the heading immediately above it
#      already gives, padded into a column that exists nowhere else.
#   2. "no snapshot" describes OUR plumbing, not the account. It reads as
#      though the provider was asked and had nothing to say. In fact nothing
#      had asked -- claude was never fetched by anything at all, and the
#      persisted snapshot the other two came from was in a format the reader
#      could not parse (blueprint Decisions 10 and 12).
#   3. It carried a colon in the VALUE, which Decision 2 rules out. (The label
#      gutter's own colon is a separate matter and belongs to t05-no-colons.)
#
# "not collected yet" says the true thing -- nothing has been gathered for this
# provider -- and the panel-level sentence below says WHY, once, instead of
# three times. The row is kept rather than dropped so the panel's height does
# not change when figures arrive.
sub _claude_code_block {
    my ($tokens, $claude_spend, $spend_present, $w, $oauth_fallback) = @_;
    my $t = (ref($tokens) eq 'HASH') ? $tokens : {};
    my @lines = ( _provider_heading('Claude Code') );

    # THE OAUTH EXPIRY LIVES HERE NOW, not in a separate Run row.
    #
    # Run carried an 'oauth' row rendered ONLY when $state->{tokens} was absent
    # -- a fallback from before this panel existed, using this very formatter
    # (_fmt_oauth_like) to say the same kind of thing. The operator asked what
    # it was for and how it differed from Claude Code, which is the right
    # question: two credential facts in two panels, distinguishable only by
    # which one happened to have data.
    #
    # So the fallback feeds the row that already exists. When the token facts
    # are present nothing changes; when they are not, this row shows the raw
    # credential expiry instead of Run growing a row about a provider.
    my $access_state = defined($t->{access_state}) ? $t->{access_state} : 'absent';
    my $sec = ($access_state eq 'absent') ? undef : $t->{access_seconds_left};
    $sec = $oauth_fallback
        if !defined($sec) && defined($oauth_fallback) && !ref($oauth_fallback);
    my @access_spans = ( { text => _fmt_oauth_like($sec), role => _oauth_like_role($sec) } );
    if (defined $t->{last_refreshed_age}) {
        push @access_spans, { text => ', refreshed ' . fmt_duration($t->{last_refreshed_age}) . ' ago', role => 'text.primary' };
    }
    my $access_row = _fact_line({ label => 'access', value => \@access_spans, force => 1 });
    push @lines, $access_row if @$access_row;

    my @refresh_spans;
    if ($t->{refresh_present}) {
        my $fp = defined($t->{refresh_fingerprint}) ? $t->{refresh_fingerprint} : '';
        @refresh_spans = ( { text => "present ($fp)", role => 'state.ok' } );
    } else {
        @refresh_spans = ( { text => 'absent', role => 'state.crit' } );
    }
    my $refresh_row = _fact_line({ label => 'refresh', value => \@refresh_spans, force => 1 });
    push @lines, $refresh_row if @$refresh_row;

    my @present;
    for my $k (qw(subscription_type rate_limit_tier)) {
        push @present, $t->{$k} if defined($t->{$k}) && !ref($t->{$k}) && length($t->{$k});
    }
    if (@present) {
        my $acc_row = _fact_line({ label => 'account', value => [ { text => join(' / ', @present), role => 'text.primary' } ] });
        push @lines, $acc_row if @$acc_row;
    }

    push @lines, _spend_fact_row('usage', \&_spend_claude_spans, $claude_spend, $spend_present, $w);

    return \@lines;
}

# _spend_fact_row($label, $builder, $data, $present, $w) -> ONE indented,
# label-gutter-aligned line.
#
# THE ALIGNMENT BUG THIS FIXES. The spend line was the only row in the panel
# that did not use the shared label gutter. access/refresh/account are built
# with row(), which pads to LABEL_GUTTER; the spend line was built by hand as
# glyph + pad_label('Claude', 6) + value, a narrower ad-hoc column. So the
# operator saw
#
#     account       max / default_claude_max_20x
#     x Claude   unreadable -- usage endpoint unreadable
#
# with the two values starting in different places. The provider name in that
# row was redundant anyway -- the heading directly above it already says
# "Claude Code" -- and the comment above _claude_code_block has said since t02
# that it "repeated the provider name that the heading immediately above it
# already gives, padded into a column that exists nowhere else". It was removed
# from the wording and left in the layout.
#
# Now every row in the panel goes through row(), so there is ONE column, and
# the status glyph leads the VALUE rather than the line -- which also stops the
# glyph from shifting the text after it by a variable amount.
sub _spend_fact_row {
    my ($label, $builder, $data, $present, $w) = @_;
    my @value;
    if ($present) {
        my ($spans, $protect) = $builder->($data);
        @value = @$spans;
        # Clipping happens BEFORE the indent, so it must build the row itself
        # rather than go through _fact_line -- the gutter width is still the
        # nested one, which is the whole point of the pairing.
        my $line = row({ label => $label, value => \@value, gutter_width => _FACT_GUTTER() });
        return _indent_line(_FACT_INDENT(), _clip_line($line, $protect, $w));
    }
    @value = ( { text => _status_glyph('warn') . ' ', role => 'state.warn' },
               { text => 'not collected yet', role => 'text.muted' } );
    return _fact_line({ label => $label, value => \@value });
}

# ONE "OpenCode" GROUP, with Go and Zen as facts inside it.
#
# They were two top-level provider blocks -- "OpenCode Go" and "OpenCode Zen" --
# each with a heading and one fact beneath it, four lines to say two things, and
# both headings repeating the word the reader already read. They are two
# products of one provider, so they nest under it: the shared word is said once,
# the two facts align with each other and with everything else in the panel, and
# the panel gets two rows of its height back.
sub _opencode_block {
    my ($go_spend, $zen_spend, $spend_present, $w) = @_;
    return [
        _provider_heading('OpenCode'),
        _spend_fact_row('Go',  \&_spend_go_spans,  $go_spend,  $spend_present, $w),
        _spend_fact_row('Zen', \&_spend_zen_spans, $zen_spend, $spend_present, $w),
    ];
}

# _PROVIDER_GAP -- the gutter between the two provider blocks. Two columns: one
# is too tight to read as a separation, three wastes width the blocks want.
use constant _PROVIDER_GAP => 2;

# _PROVIDER_MIN_COLS -- the width ONE provider block needs before the two can be
# placed side by side.
#
# MEASURED, and the first version was badly wrong. It gated on
# tui::Meter::min_width() (75), which is the width a RESOURCES GAUGE ROW needs
# -- a label, a ten-cell bar, a percent and a used/free/total triple. A provider
# block has none of those. Measured at a generous width, the Claude Code block's
# widest line is 55 columns and OpenCode's is 30.
#
# The wrong gate demanded a 152-column panel for a pairing that fits in 112, so
# Providers rendered STACKED at every realistic terminal size -- eight rows
# where four would do. That was the direct cause of Blueprints being dropped
# entirely on a 24-row terminal: the rows Providers did not need were the rows
# Blueprints did.
#
# 56, not 55: one column of slack so the wider block is not flush against the
# gutter.
use constant _PROVIDER_MIN_COLS => 56;

# _side_by_side(\@left, \@right, $lw, $rw) -> \@lines -- two blocks of spans
# joined into one column of rows, each side fitted to its own width.
#
# The lists are almost never the same length, so the shorter one is padded with
# blank rows rather than the join stopping early -- stopping early would silently
# DROP the longer provider's tail, which is a data loss that looks like a layout
# choice.
#
# Fitting is delegated to tui::Frame::fit_spans, which both pads and clips to an
# exact width. Doing it by hand would mean re-deriving display widths that
# already have one implementation, and getting that wrong is how a row ends up
# one column too long and wraps the whole panel.
# _block_width(\@lines) -> the widest rendered line in a block of span rows.
# The natural width of a column, so two columns can be sized to their content.
sub _block_width {
    my ($lines) = @_;
    return 0 if ref($lines) ne 'ARRAY';
    my $max = 0;
    for my $l (@$lines) {
        next if ref($l) ne 'ARRAY';
        my $w = tui::Frame::spans_width($l);
        $max = $w if $w > $max;
    }
    return $max;
}

sub _side_by_side {
    my ($left, $right, $lw, $rw) = @_;
    $left  = [] if ref($left)  ne 'ARRAY';
    $right = [] if ref($right) ne 'ARRAY';
    my $n = (@$left > @$right) ? scalar(@$left) : scalar(@$right);
    my @out;
    for my $i (0 .. $n - 1) {
        my @row;
        push @row, @{ tui::Frame::fit_spans($left->[$i]  || [], $lw, 'text.primary') };
        push @row, { text => ' ' x _PROVIDER_GAP(), role => 'text.primary' };
        push @row, @{ tui::Frame::fit_spans($right->[$i] || [], $rw, 'text.primary') };
        push @out, \@row;
    }
    return \@out;
}

sub _providers_body {
    my ($state, $cols) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my $w = (defined($cols) && !ref($cols) && $cols =~ /^\d+(?:\.\d+)?$/ && $cols > 0) ? int($cols) : 80;
    my $spend = (ref($state->{spend}) eq 'HASH') ? $state->{spend} : undef;

    my @lines;

    # THE 'nearest' ROW IS GONE (operator request, 2026-08-25).
    #
    # It named the provider/window closest to exhaustion and its percentage --
    # every part of which the per-provider rows immediately below already say,
    # in the same panel, usually two lines down. A summary row sitting directly
    # above the thing it summarises is not a summary, it is a repetition, and
    # it cost a row of the tallest panel on the screen.
    #
    # It was also the most visible casualty of the utilization bug fixed in
    # SpendPanel this same commit: claude's fraction was stored as 0..100 while
    # every other provider's is 0..1, so the "nearest exhaustion" sort ranked
    # claude first unconditionally. The row was reporting a ranking that could
    # not have been anything else.
    #
    # $spend->{priority} is still computed and is now correct; nothing else
    # consumed this row, so only the rendering goes.

    # THE TWO PROVIDERS SIT SIDE BY SIDE (operator, 2026-08-27: "On Providers,
    # put Claude Code and OpenCode side by side instead of one under the
    # other"). They are peers -- two accounts, the same kinds of fact -- so
    # stacking them made the panel twice as tall as it needed to be and implied
    # a precedence that does not exist.
    #
    # Each block is composed at its OWN half-width, not at $w, or a block would
    # lay itself out for a panel twice as wide as the space it is about to be
    # fitted into. Below the two-column breakpoint they stay stacked: two
    # half-columns of a narrow panel is worse than a tall panel.
    my $half = int(($w - _PROVIDER_GAP()) / 2);
    if ($half >= _PROVIDER_MIN_COLS()) {
        my $cc = _claude_code_block($state->{tokens}, $spend ? $spend->{claude} : undef,
                                    $spend ? 1 : 0, $half, $state->{oauth_remaining});
        my $oc = _opencode_block($spend ? $spend->{go}  : undef,
                                 $spend ? $spend->{zen} : undef,
                                 $spend ? 1 : 0, $half);

        # COLUMNS ARE SIZED TO THEIR CONTENT, NOT TO HALF THE PANEL.
        #
        # Splitting 50/50 put OpenCode at the panel's midpoint however wide the
        # panel got: on a 170-column Providers panel, Claude Code's ~55 columns
        # of content sat next to thirty columns of nothing, and OpenCode began
        # at column 85. The operator's words: "the OpenCode one is all the way
        # to the right... it looks ugly."
        #
        # Two adjacent columns, each as wide as it needs to be, with a fixed
        # gutter, is what makes them read as a pair. The panel's leftover width
        # stays empty on the RIGHT, where empty space is unremarkable, instead
        # of being inserted between two things that belong together.
        my $lw = _block_width($cc);
        my $rw = _block_width($oc);
        # Never wider than the panel: if content genuinely needs more than there
        # is, fall back to sharing what exists rather than overflowing.
        if ($lw + _PROVIDER_GAP() + $rw > $w) {
            $lw = $half;
            $rw = $w - $half - _PROVIDER_GAP();
        }
        push @lines, @{ _side_by_side($cc, $oc, $lw, $rw) };
    }
    else {
        push @lines, @{ _claude_code_block($state->{tokens}, $spend ? $spend->{claude} : undef,
                                           $spend ? 1 : 0, $w, $state->{oauth_remaining}) };
        push @lines, @{ _opencode_block($spend ? $spend->{go}  : undef,
                                        $spend ? $spend->{zen} : undef,
                                        $spend ? 1 : 0, $w) };
    }

    # (t11's hot-reload rows are a BANNER, not a panel row -- see
    # hot_reload_banners below. They belong above the panels, with the other
    # things that are true of this moment rather than of the sandbox.)

    # ONE SENTENCE AT THE END SAYING WHY THERE ARE NO FIGURES.
    #
    # This used to read "a run is active but has not written runs/spend.json
    # yet" or "no active run to report spend for" -- and the operator's report
    # quoted the second one. Both named a RUN as the missing thing. Under
    # blueprint Decision 11 that is the wrong absence: every figure here (go's
    # windows, zen's balance, claude's utilizations) describes the ACCOUNT, and
    # a snapshot is now written whether or not a fleet run exists. So "no
    # active run" stopped being a reason and became a non sequitur -- accurate,
    # and useless, which is exactly what the operator said about it.
    #
    # What replaces it is the sampler's own state, in the same vocabulary t01
    # established for the resources panel next door.
    # PUSHED ONLY WHEN IT HAS SOMETHING TO SAY. spend_wait_spans returns an
    # empty list for the ordinary "still collecting" case (see its header), and
    # pushing that would put a blank row where the sentence used to be -- which
    # costs exactly what removing the sentence was meant to save.
    unless ($spend) {
        my $wait = spend_wait_spans($state->{spend_sampler});
        push @lines, $wait if ref($wait) eq 'ARRAY' && @$wait;
    }

    return \@lines;
}

# ===========================================================================
# panels(\%state, $cols) -- the panel set (spec S2.4.3, criteria 2 and 6).
# The Sandbox panel is dissolved: project/container reach the header,
# oauth reaches Providers' Claude Code block when tokens are present or Run
# when absent (never both, never neither), heartbeat/uptime move to Run.
#
# BLUEPRINTS IS ALWAYS PRESENT, a sibling of Run (package t01-providers-panel,
# criterion 6/D4) -- the blueprint-run list used to live inside Run's own
# body; it is now its own titled panel so a restructure that saves rows never
# leaves it unclear which panel a fact belongs to, and (D4) it cannot pop
# into existence mid-session the way a conditionally-present panel would.
# ===========================================================================
sub panels {
    my ($state, $cols) = @_;
    $state = {} if ref($state) ne 'HASH';
    my @out;

    # PANEL ORDER IS THE LAYOUT (operator, 2026-08-27). tui::Layout::place packs
    # consecutive panels into bands, so the order here IS the arrangement:
    #
    #     Run | Resources          -- paired, side by side
    #     Providers                -- full width
    #     Blueprints               -- full width, and takes the leftover height
    #
    # Blueprints moved out from directly under Run to below Providers, and
    # Resources moved up to sit beside Run.
    # Run declares a minimum too, and it has to. Now that a band can be split
    # UNEVENLY to satisfy a neighbour's min_cols, a panel that declares nothing
    # is treated as infinitely squeezable: beside Resources (75) in a 100-column
    # main region Run was handed 25, which cannot hold "backpack  5 items, 5
    # pending [b]". A minimum is what makes the pair demote to two rows instead
    # of rendering one of them unreadably narrow.
    #
    # DERIVED, not picked: the label column and its gutter, plus room for the
    # longest value this panel actually renders.
    push @out, { title => 'Run', lines => _run_body($state),
                 min_cols => tui::Meter::LABEL_COL_WIDTH() + 3 + 30, uneven_ok => 1 };

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
        # uneven_ok: Resources would rather sit beside Run at whatever width its
        # min_cols demands than be pushed onto its own row. See tui::Layout::place.
        push @out, { title => 'Resources', lines => _resources_body($state->{resources}),
                     min_cols => tui::Meter::min_width(), uneven_ok => 1 };
    } else {
        # No snapshot has EVER been written. Until t01 this branch rendered one
        # hardcoded sentence whatever the reason, so a sampler that failed to
        # fork looked exactly like one that started two seconds ago -- which is
        # what the operator saw, unchanged, indefinitely.
        push @out, { title => "Resources", uneven_ok => 1,
                     lines => [ sampler_wait_spans($state->{resources_sampler}) ],
                     min_cols => tui::Meter::min_width() };
    }

    # PROVIDERS IS ALWAYS PRESENT (renamed from Spend, package
    # t01-providers-panel, criterion 1). It used to be omitted whenever no
    # snapshot had been read, which is ALWAYS -- the fleet writes its spend
    # figures to its own log and returns them in-process, and has never
    # persisted the runs/spend.json this reads. So a panel the operator relied
    # on had silently not existed for the life of the feature, and its
    # absence was indistinguishable from "this launch has no runs".
    #
    # Absent-vs-empty was a real decision (never fabricate a zero) and it is
    # kept: what changes is that "we have no figures" is now SAID, in the panel,
    # instead of being expressed by the panel not being there. A missing panel
    # is not an honest absence -- it is no statement at all.
    #
    # It also now carries Claude Code's token facts (Token panel merged in,
    # criterion 2) nested under their own heading, alongside the OpenCode
    # Go/Zen spend facts each under theirs -- see _providers_body.
    push @out, { title => 'Providers', lines => _providers_body($state, $cols),
                 min_cols => tui::Meter::min_width(), full_width => 1 };

    # BLUEPRINTS IS FULL WIDTH AND CARRIES THE FLEX (operator, 2026-08-27: "Move
    # Blueprints to under Providers... The blueprints cell expands to take
    # available height").
    #
    # BUT ONLY WHEN ACTIVITY IS THE SIDE COLUMN, and that condition is the whole
    # correctness argument. flex was Activity's, and the reason it held still
    # holds: tui::Screen gives the FIRST flex panel a reservation the fixed
    # region cannot eat, and without one the last panel in the flow can be
    # squeezed out of existence entirely.
    #
    # Above the breakpoint Activity is removed from this list before placement
    # and spans the full body height by construction, so the main region's flex
    # is genuinely free and Blueprints should have it. BELOW the breakpoint
    # Activity is back in the flow as the last panel, and handing its
    # reservation to Blueprints deletes it: the sandbox suite failed with "the
    # activity panel still exists" across every short-terminal case, which is
    # exactly that.
    #
    # So the flag follows the layout rather than being asserted unconditionally.
    my $activity_is_side = (tui::Screen::side_column_width($cols) > 0) ? 1 : 0;
    push @out, { title => 'Blueprints', lines => _blueprints_body($state, $cols),
                 full_width => 1, ($activity_is_side ? (flex => 1) : ()) };

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
    # t03-activity-column: it is ALSO the side panel -- a narrow, fixed column
    # pinned to the right edge and spanning the full body height, with each
    # event row wrapping to at most three lines and then an ellipsis. Both are
    # the operator's request, in their words: "a narrow column instead of
    # expanding to fill everything", "always the last column and take the
    # entire height of the terminal", "wrap to up to three lines and then
    # ellipsis".
    #
    # `flex => 1` IS KEPT ON PURPOSE. Below tui::Screen's width threshold there
    # is no side column, and the panel falls back into the band flow -- where
    # flex is exactly what stops it being squeezed out by the panels above it.
    # Dropping the flag would have made the narrow case worse than it is today.
    # ACTIVITY_HANG is the width of an event row's fixed prefix, so a wrapped
    # row's continuation lines up under the BODY rather than under the
    # timestamp. Dashboard::recent_events builds every row as
    #   activity_time_text($hhmm)  -> 6 columns
    #   "$glyph "                  -> 2 columns
    # and the body follows at column 8. Operator, with a screenshot: the
    # wrapped text "is aligned to the hour minute `:` separator, should be
    # aligned to the text itself after the icon".
    #
    # `wrap_break => 'char'` is the other half of the same request -- "It
    # doesn't need to respect word boundaries, I would rather have it just
    # always break in a dumb way at the character". Word wrapping is actively
    # bad here: an event body is one long token (claude_json_relocation_skip),
    # so in a ~30-column column it either overflows or leaves the row half
    # empty. Breaking anywhere fills the column.
    push @out, { title       => 'Recent activity',
                 lines       => (@$ev ? [ @$ev ] : [ '(no events yet)' ]),
                 flex        => 1,
                 side        => 1,
                 wrap_cap    => 3,
                 wrap_break  => 'char',
                 wrap_indent => ACTIVITY_HANG() };

    return \@out;
}

# ===========================================================================
# Footer legend / confirm prompts / alert banners -- ported from the legacy
# Dashboard footer_legend/confirm_prompt/_footer_line/_status_alert/
# lifecycle_alert_msg (Theme roles; no Dashboard reference, AC-P4).
#
# _footer_legend/_confirm_prompt are the pre-narrowing strategy for the
# non-wrapping footer surface (Decision D1, specs/d02-wrap-every-surface-
# spec.md): they pick the widest tier of a discrete fallback ladder that
# still fits $cols, before tui::Screen::compose's $rows==2 short-circuit
# hands the result to make_cell, by design -- not a gap.
# ===========================================================================
sub _footer_legend {
    my ($cols) = @_;
    $cols = 200 if !defined $cols;
    my @tiers = (
        ' [c] launch Claude Code  [s] stop runs  [x] full shutdown  [up/down] scroll  [r] reload  [q] quit',
        ' [c] launch Claude Code  [s] stop runs  [x] shutdown  [r] reload  [q] quit',
        ' [c] launch  [s] stop  [x] shutdown  [r] reload  [q] quit',
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

# t03-banner-dismiss, step-6 red-team LOW-1 (ruled, kept): this function is
# pure over $state alone and does not consult $state->{pending}, so the
# '[d] dismiss' hint below renders even while a stop-runs/full-shutdown/
# relaunch confirm is armed -- at which point Dashboard::dispatch_key
# actually routes 'd' to cancel that confirm, not to dismiss the banner
# (Dashboard.pm's pending-branches run first, spec S2.3/S5). Kept as-is: the
# spec explicitly documents and accepts this trade-off (it never widens
# _banner_lines's contract to take $pending), the failure direction is a
# banner that STAYS VISIBLE rather than one that gets hidden (the opposite of
# this package's actual attack surface -- information suppression), and
# fixing it would require widening this function's signature and
# re-verifying every AC4 exact-string assertion in the oracle for a cosmetic
# gain. Revisit only if a future package needs _banner_lines to be
# pending-aware for an unrelated reason.
# Banners now wrap at the tui::Screen layer (Decision D1/D2, specs/d02-wrap-
# every-surface-spec.md), the same division of labor as panel bodies:
# DashboardScreen composes content, Screen.pm owns width. This function
# deliberately does NOT gain a $cols parameter -- unlike header_spans/
# panels/_footer_text, which each pre-narrow for a non-wrapping surface,
# banner content is handed through as-is and left to tui::Frame::wrap_line.
sub _banner_lines {
    my ($state) = @_;
    $state = {} unless ref($state) eq 'HASH';
    # '[d] dismiss' is offered ONLY when 'd' will actually dismiss something that
    # is on screen. It used to be glued unconditionally to install_warning while
    # 'd' cleared only that field, so the operator saw
    #     !! [r] no module changed on disk  [d] dismiss
    # pressed 'd', and watched the [r] line sit there -- the key doing something
    # different from its own label. Reported from the field, 2026-09-09.
    #
    # LATCHED vs DERIVED is the whole distinction. install_warning and the
    # hot-reload REPORT are latched, so clearing them is meaningful. The
    # "N modules changed" nudge, "launcher.pl changed", and the lifecycle/status
    # alerts are all derived from live state and would be re-derived on the very
    # next gather -- offering to dismiss those would just be a second lie.
    #
    # Suppressed entirely while a confirm is armed: Dashboard::dispatch_key runs
    # its pending-branches FIRST, so 'd' cancels the confirm and dismisses
    # nothing. Advertising dismiss there is exactly the mislabelling this guard
    # exists to stop, and is why this function now consults $state->{pending}.
    my $armed = defined($state->{pending}) && !ref($state->{pending})
                && length($state->{pending});
    my $warn  = (defined($state->{install_warning}) && !ref($state->{install_warning})
                 && length($state->{install_warning})) ? $state->{install_warning} : undef;
    my $has_report = ref($state->{hot_reload}) eq 'HASH';
    my $hint = (!$armed && (defined($warn) || $has_report)) ? '  [d] dismiss' : '';

    my @msgs = grep { defined($_) && length($_) }
        ( _lifecycle_alert_msg($state), _status_alert_msg($state) );
    my @hot = @{ hot_reload_msgs($state) };

    if (defined $warn) {
        push @msgs, $warn . $hint;   # the hint rides the warning when there is one
    }
    elsif (length($hint) && @hot) {
        $hot[0] .= $hint;            # otherwise it rides the hot-reload report line
    }
    push @msgs, @hot;
    return [ map { '  !! ' . tui::Frame::safe($_) } @msgs ];
}

# warning_entries(\%state) -> \@entries, each { id, text, key } -- EVERY
# alert-shaped message on the dashboard, as overlay entries. PUBLIC.
#
# THIS IS THE WHOLE BANNER POPULATION, and that is the point. Converting only
# the messages that happened to be in front of me was the bug: the overlay was
# built, one synthetic producer was pointed at it, and the mechanism it was
# meant to replace went on rendering everything else into the side column --
# straight over Recent activity. A capture with "warnings live 0" and a visible
# `!!` row is exactly that split, and the operator was right to call it out.
#
# So the producers are enumerated here, in one place, and _banner_lines (which
# still exists for callers that legitimately want the flowed form) reads from
# the same four sources. If a fifth is ever added, it has to be added here to
# be seen at all -- which is the property the previous arrangement lacked.
#
# IDS ARE STABLE PER PRODUCER, not per message text, so a dismissal survives the
# message being re-rendered with a different age or count in it. A dismissed
# warning whose text ticks over would otherwise reappear once a second.
sub warning_entries {
    my ($state) = @_;
    $state = {} unless ref($state) eq 'HASH';
    my @out;

    my $lifecycle = _lifecycle_alert_msg($state);
    push @out, { id => 'lifecycle', key => 'd', text => $lifecycle }
        if defined($lifecycle) && length($lifecycle);

    my $status = _status_alert_msg($state);
    push @out, { id => 'status', key => 'd', text => $status }
        if defined($status) && length($status);

    push @out, { id => 'install', key => 'd', text => $state->{install_warning} }
        if defined($state->{install_warning}) && !ref($state->{install_warning})
        && length($state->{install_warning});

    my $reload = hot_reload_msgs($state);
    if (ref($reload) eq 'ARRAY') {
        my $i = 0;
        for my $m (@$reload) {
            next unless defined($m) && length($m);
            push @out, { id => 'reload' . $i++, key => 'd', text => $m };
        }
    }

    # Explicit entries supplied by the caller come LAST, so they stack on top --
    # they are the newest thing that happened.
    if (ref($state->{warnings}) eq 'ARRAY') {
        for my $w (@{ $state->{warnings} }) {
            next unless ref($w) eq 'HASH' && defined $w->{text} && length $w->{text};
            push @out, { id => (defined $w->{id} ? $w->{id} : $w->{text}),
                         key => (defined $w->{key} ? $w->{key} : 'd'),
                         text => $w->{text} };
        }
    }

    # Dismissal is the CALLER's state, applied here so every surface honours it.
    my $dis = (ref($state->{dismissed_warnings}) eq 'HASH') ? $state->{dismissed_warnings} : {};
    return [ grep { !$dis->{ $_->{id} } } @out ];
}

# hot_reload_msgs(\%state) -> \@messages. PURE, total (t11-tui-hot-reload).
#
# Two things reach the operator here, and they answer different questions:
#
#   THE NUDGE -- "N modules changed on disk, press [r]". This is what closes
#   the half of the gap a keypress alone cannot: a promote you made and forgot
#   to pick up. Without it the feature only helps when you already remember it
#   exists.
#
#   THE REPORT -- what the last [r] actually did. Its most important line is
#   the one that fires ON SUCCESS: launcher.pl is never reloaded, so a change
#   that also touched it is only half-applied. Because every function on this
#   render path is total -- it degrades on missing input rather than dying --
#   a half-applied change renders the FALLBACK case cleanly and looks like a
#   change that did not work. Saying so is the difference between a tool that
#   speeds you up and one that costs you an afternoon.
#
# Banners are the right surface rather than a panel row: these are facts about
# this MOMENT, not about the sandbox, and the banner region is already where
# such things live and already wraps (package d02).
sub hot_reload_msgs {
    my ($state) = @_;
    return [] unless ref($state) eq 'HASH';
    my @out;

    my $r = $state->{hot_reload};
    if (ref($r) eq 'HASH') {
        my $head = (defined $r->{headline} && !ref $r->{headline}) ? $r->{headline} : 'reload reported nothing';
        push @out, "[r] $head";
        if (ref($r->{notes}) eq 'ARRAY') {
            push @out, $_ for grep { defined && !ref && length } @{ $r->{notes} };
        }
    }

    my $n = $state->{hot_reload_pending};
    if (defined $n && !ref $n && $n =~ /\A\d+\z/ && $n > 0) {
        push @out, sprintf('%d render module%s changed on disk - press [r] to reload',
                           $n, ($n == 1 ? '' : 's'));
    }

    # launcher.pl cannot be hot-RELOADED -- it is this running process -- but [r]
    # now REPLACES it, so the instruction is the same key as everything else.
    #
    # This banner exists because the alternative was actively misleading:
    # a launcher fix was invisible to the nudge (HotReload watches the thirteen
    # render modules and nothing else), so pressing [r] answered "no module
    # changed on disk" -- true, correct, and completely irrelevant to the change
    # being chased. Observed doing exactly that on 2026-08-25, twice, while a
    # sampler kept failing for a reason a restart would have cleared.
    if ($state->{launcher_changed}) {
        push @out, 'launcher.pl changed on disk - press [r] to restart into it';
    }
    return \@out;
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

    # THE HEADER IS BUILT AT THE MAIN REGION'S WIDTH, not the terminal's.
    #
    # tui::Screen now runs the side column from row 0, so the header occupies
    # the main region alone (operator request, 2026-08-25: Activity should
    # start at the top rather than sit under a full-width band carrying two
    # short strings). So it must be composed at the MAIN region's width: the
    # header no longer spans the terminal, and building it at $cols and letting
    # tui::Screen clip to the narrower region would eat the container id off the
    # right-hand end.
    #
    # This narrowing OUTLIVED the right-justification it was first written for
    # (the container id is now a left-aligned clause, 2026-08-25). It is still
    # required, for the plainer reason above: what is composed here has to be as
    # wide as the row it is composed into, no wider. tui::Screen re-renders the
    # title at $main_cols on the side-column path, and the two must agree.
    #
    # side_column_width() is public and pure, and returns 0 below the
    # breakpoint, so on a narrow terminal this is $cols unchanged.
    # FULL WIDTH AGAIN (operator, 2026-08-27). This was
    # $cols - side_column_width($cols), because the side column used to start at
    # row 0 and share that row with the header. It no longer does -- the column
    # begins below the header, aligned with the first panel -- so the header has
    # the whole terminal back and must be composed at the whole width.
    #
    # The two MUST agree: tui::Screen renders the title into a cell of exactly
    # this width, so composing narrower leaves a short row and composing wider
    # gets clipped, which is how the container id lost its right-hand end once
    # before.
    my $header_cols = $cols;
    $header_cols = 1 if $header_cols < 1;

    # THE PANELS ARE COMPOSED AT THE MAIN REGION'S WIDTH, NOT THE TERMINAL'S.
    #
    # panels() used to be handed $cols. The panels are then rendered into the
    # main region -- $cols minus the side column -- so any body that uses its
    # width to make a layout decision made that decision for a region wider than
    # the one it lands in.
    #
    # Providers made it visible and the preview harness is what showed it: at a
    # 200-column terminal it split its two provider blocks to fit a 200-wide
    # panel, was rendered into 134, and every joined row overflowed and wrapped
    # -- turning a clean two-column panel into interleaved fragments. Composing
    # at the true width is the fix; the header does the same thing directly
    # above, for the same reason.
    my $main_cols = $cols - tui::Screen::side_column_width($cols);
    $main_cols = 1 if $main_cols < 1;

    return {
        title       => header_spans($state, $header_cols),
        title_role  => 'accent',
        banners     => _banner_lines($state),
        banner_role => 'state.crit',
        panels      => panels($state, $main_cols),
        footer      => _footer_text($state, $cols),
        footer_role => _footer_role($state),
    };
}

sub compose {
    my ($state, $rows, $cols) = @_;

    # Derive the Blueprints panel's row budget from the ACTUAL terminal height
    # (renamed from run_rows_max, D5 -- it bounds Blueprints, never Run, now
    # that the blueprint-run list lives in its own panel). This is the only
    # place in the module that knows $rows, and screen()'s signature is
    # deliberately left alone (its callers and tests are many), so the budget
    # travels the one way it can: as a derived key on a shallow copy of state.
    #
    # A third of the height, floor 3: enough that a normal terminal shows every
    # blueprint (the operator had twelve, saw three, and had most of a screen
    # empty below them), while a short terminal still gets a Blueprints panel
    # that cannot crowd out everything beneath it. A caller that has already
    # set blueprint_rows_max wins -- this only supplies a default.
    if (ref($state) eq 'HASH' && !defined $state->{blueprint_rows_max}) {
        my $h = (defined($rows) && !ref($rows) && $rows =~ /\A\d+\z/) ? $rows : 0;
        my $budget = int($h / 3);
        $budget = 3 if $budget < 3;
        $state = { %$state, blueprint_rows_max => $budget };
    }

    # BANNERS NO LONGER PARTICIPATE IN LAYOUT AT ALL.
    #
    # screen() still produces them (callers and tests read that shape), but they
    # are cleared before placement and re-emitted as overlay entries below. That
    # is what makes "a warning arrives" cost zero rows: previously each banner
    # was a real row, taken from the side column when one existed -- which is
    # how they ended up painted over Recent activity.
    my $screen = screen($state, $cols);
    $screen->{banners} = [];
    my $cells = tui::Screen::compose($screen, $rows, $cols);

    # WARNINGS ARE OVERLAID LAST, over a frame that is already complete.
    #
    # This is deliberately the final step and outside screen(): the overlay must
    # not participate in layout at all. Composing it earlier -- as the old
    # install_warning banner did -- is what made an arriving warning shove the
    # whole panel grid down a row.
    #
    # warning_entries() is the single source: lifecycle and status alerts, the
    # install warning, hot-reload reports, and anything the caller added -- all
    # of them, with $state->{dismissed_warnings} already applied.
    my $warn = warning_entries($state);
    return tui::Screen::overlay_warnings($cells, $warn, $cols) if @$warn;

    return $cells;
}

1;
