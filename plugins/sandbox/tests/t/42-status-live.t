#!/usr/bin/env perl
# s07-live-status: spinner + status colour + OS window title.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s07-live-status (spec 04-live-status-spec.md, S2 interfaces / S3
# observable behaviours / S4 acceptance criteria). It is written BLIND to
# Dashboard.pm/launcher.pl's implementation -- directly from the spec -- so
# it can serve as an oracle rather than an echo of whatever the implementer
# eventually writes.
#
# Coverage: AC-1 .. AC-12, AC-14 (AC-13 is the whole-suite gate, verified by
# the coordinator running run-tests.pl separately -- not a unit assertion
# here).
#
# The two new subs under test (Dashboard::spinner_frame, Dashboard::
# window_title) and the loop wiring (wall-clock spinner_idx, OSC emission in
# Dashboard::run, launcher.pl's enter_raw/leave_raw title save+restore) DO
# NOT YET EXIST / behave per-spec on package load -- most assertions below
# are EXPECTED to fail with "Undefined subroutine" or a wrong-value mismatch
# until the implementer lands s07. That is correct and by design.
#
# Hard constraint (mirrors t/39 S8 / t/40 S4.6): this file MUST NOT `use
# utf8`. Glyph literals are written as "\x{...}" escapes (the decoded-
# character path) or via Encode::encode (the UTF-8-byte path), per the
# spec's own S2.1 code block.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Encode qw(encode decode);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# Fixture: the ten spinner codepoints in dots-1..dots-10 order, taken
# VERBATIM from spec S2.1's code block (these are the ten codepoints already
# allow-listed at Dashboard.pm:230-239; the spec cites their exact order).
# Independent of whatever @SPINNER list the implementer writes.
# ===========================================================================
my @SPINNER_CP = (0x280B, 0x2819, 0x2839, 0x2838, 0x283C,
                   0x2834, 0x2826, 0x2827, 0x2807, 0x280F);
my @SPINNER_BYTES = map { encode('UTF-8', chr($_)) } @SPINNER_CP;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or BAIL_OUT("open $path: $!");
    local $/;
    return <$fh>;
}

my $dashboard_pm = "$Bin/../../scripts/Dashboard.pm";
my $launcher_pl  = "$Bin/../../scripts/launcher.pl";
ok(-f $dashboard_pm, 'Dashboard.pm present') or BAIL_OUT;
ok(-f $launcher_pl,  'launcher.pl present')  or BAIL_OUT;
my $dash_src = _slurp($dashboard_pm);

# Isolate row 1's rendered segment out of a render_frame() ANSI string: every
# row (full paint or diff) is emitted as "\e[<n>;1H\e[K<text>", so row 1's
# text runs from its own "\e[1;1H\e[K" up to the next row-move escape or the
# synchronized-output end.
sub _row1_segment {
    my ($frame) = @_;
    return $1 if $frame =~ /\e\[1;1H\e\[K(.*?)(?:\e\[\d+;1H|\e\[\?2026l)/s;
    return undef;
}

# ---------------------------------------------------------------------------
# Shared drive() helper for the loop-level ACs (AC-6a/c, AC-10). Returns the
# plain list of $out calls, in order (the t/25-dashboard.t "drive" idiom).
# AC-6b and AC-7/AC-11 need their own bespoke clock-tracking / verbatim
# shape and are written standalone below, per the task's explicit
# instruction to keep AC-7's assertion shape essentially as spec'd.
# ---------------------------------------------------------------------------
sub _run_live {
    my (%o) = @_;
    my $clock = $o{clock_start} // 0;
    my @calls;
    Dashboard::run(
        color          => 0,
        beat_interval  => 9999,
        state_interval => 0,
        tick_interval  => $o{tick_interval} // 0.25,
        max_ticks      => $o{max_ticks} // 6,
        now            => sub { $clock },
        sleep_for      => ($o{sleep_for} // sub { $clock += $_[0] }),
        read_key       => sub { undef },
        term_size      => sub { (80, 20) },
        gather         => ($o{gather} // sub {
            { project_name => 'demo', container => 'ctr1', status => 'running' }
        }),
        heartbeat      => sub { 'ok' },
        spawn          => sub { undef },
        stop_runs      => sub { { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                                   machine_stopped => 0, others => [], others_known => 0,
                                   summary => 'stop-runs ok' } },
        full_shutdown  => sub { { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                                   machine_stopped => 1, others => [], others_known => 1,
                                   summary => 'full shutdown ok' } },
        enter_raw      => sub { },
        leave_raw      => sub { },
        keepawake      => sub { },
        out            => sub { push @calls, $_[0] },
    );
    return \@calls;
}

# ===========================================================================
# AC-1 -- spinner_frame exists and satisfies B1: 10 distinct frames for
# indices 0..9, each display_width == 1, each a key of Dashboard::glyph_table().
# ===========================================================================
{
    my $table = eval { Dashboard::glyph_table() };
    my %seen;
    for my $idx (0 .. 9) {
        my $bytes = eval { Dashboard::spinner_frame($idx) };
        is($@, '', "AC-1: spinner_frame($idx) does not die");
        ok(defined $bytes && length($bytes), "AC-1: spinner_frame($idx) returns a defined non-empty value");
        next unless defined $bytes;
        $seen{$bytes}++;
        is(Dashboard::display_width($bytes), 1, "AC-1: display_width(spinner_frame($idx)) == 1");
        my $decoded = eval { decode('UTF-8', $bytes) };
        ok(defined $table && defined $decoded && exists $table->{$decoded},
            "AC-1: spinner_frame($idx) decodes to a key of Dashboard::glyph_table()");
    }
    is(scalar(keys %seen), 10, 'AC-1: spinner_frame(0..9) yields 10 DISTINCT frames');
}

# ===========================================================================
# AC-2 -- periodic mod 10 and total: B2 + B3, with $SIG{__WARN__} armed to
# fail on any warning.
# ===========================================================================
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };

    for my $i (-13, -10, -3, -1, 0, 1, 3, 7, 9, 10, 13, 23) {
        my $a = eval { Dashboard::spinner_frame($i) };
        my $b = eval { Dashboard::spinner_frame($i + 10) };
        is($a, $b, "AC-2: spinner_frame($i) eq spinner_frame(" . ($i + 10) . ') (period 10)');
    }
    is(eval { Dashboard::spinner_frame(10) }, eval { Dashboard::spinner_frame(0) },
        'AC-2: spinner_frame(10) eq spinner_frame(0)');
    is(eval { Dashboard::spinner_frame(-1) }, eval { Dashboard::spinner_frame(9) },
        'AC-2: spinner_frame(-1) eq spinner_frame(9)');

    for my $case ([undef, 'undef'], ['abc', "'abc'"], [[], 'arrayref'], [{}, 'hashref']) {
        my ($input, $label) = @$case;
        my $got = eval { Dashboard::spinner_frame($input) };
        is($@, '', "AC-2: spinner_frame($label) does not die");
        is($got, eval { Dashboard::spinner_frame(0) }, "AC-2: spinner_frame($label) eq spinner_frame(0) (B3 totality)");
    }
    is(scalar(@warnings), 0, 'AC-2: no warnings emitted across any of the above calls');
}

# ===========================================================================
# AC-3 -- spinner_frame never reads the clock: (a) behavioural -- same index
# returns the same glyph with the process clock free-running between calls;
# (b) mechanical -- the sub body's source region contains no time()/now() call.
# ===========================================================================
{
    my $before = time();
    my $f1 = eval { Dashboard::spinner_frame(4) };
    select(undef, undef, undef, 0.05);   # let the process clock advance
    my $f2 = eval { Dashboard::spinner_frame(4) };
    ok(time() >= $before, 'AC-3: sanity -- the process clock did advance between the two calls');
    is($f1, $f2, 'AC-3: spinner_frame(4) called twice with the clock free-running returns the same glyph');

    my ($body) = $dash_src =~ /sub\s+spinner_frame\b(.*?)\n\}/s;
    ok(defined $body && length($body), 'AC-3: spinner_frame sub body found in Dashboard.pm source')
        or diag('spinner_frame is not implemented in Dashboard.pm yet');
  SKIP: {
        skip 'spinner_frame sub body not found in source', 1 unless defined $body && length($body);
        unlike($body, qr/\b(?:CORE::)?time\s*\(|\bnow\s*\(/,
            'AC-3: spinner_frame source body contains no time()/now() call');
    }
}

# ===========================================================================
# AC-4 -- title row renders the spinner in the status colour role: B4 + B6,
# over status running/stopped/exited and container_gone=1. Role comes from
# Dashboard::container_status_style itself, never a literal role table.
# ===========================================================================
{
    for my $case (
        { status => 'running', gone => 0, label => 'running' },
        { status => 'stopped', gone => 0, label => 'stopped' },
        { status => 'exited',  gone => 0, label => 'exited' },
        { status => 'running', gone => 1, label => 'running+container_gone' },
    ) {
        my $idx   = 3;
        my $state = { project_name => 'p', container => 'ctr1',
                      status => $case->{status}, container_gone => $case->{gone},
                      spinner_idx => $idx };
        my $frame = eval { Dashboard::compose_frame($state, 12, 80) };
        is($@, '', "AC-4 ($case->{label}): compose_frame does not die");
        SKIP: {
            skip 'compose_frame died', 6 if $@;
            my $row0 = $frame->[0];
            my $spin = eval { Dashboard::spinner_frame($idx) } // '';
            like($row0->{text}, qr/\[\Q$spin\E \Q$case->{status}\E\]/,
                "AC-4 ($case->{label}): B4 -- spinner glyph sits immediately before the status word inside [...]");
            is(Dashboard::display_width($row0->{text}), 80,
                "AC-4 ($case->{label}): B4 -- display_width(title text) == 80");
            unlike($row0->{text}, qr/[\e\a]/, "AC-4 ($case->{label}): B4 -- title text contains no ESC/BEL");

            my ($expect_role) = (Dashboard::container_status_style($case->{status}, $case->{gone}))[1];
            my @spans = @{ $row0->{spans} || [] };
            my ($status_span) = grep { $_->{text} eq $case->{status} } @spans;
            ok($status_span, "AC-4 ($case->{label}): B6 -- a span carries the bare status word");
            is($status_span->{role}, $expect_role,
                "AC-4 ($case->{label}): B6 -- status span role == container_status_style(...)[1] ('$expect_role')")
                if $status_span;
            my ($spin_span) = grep { $_->{text} eq "$spin " } @spans;
            ok($spin_span, "AC-4 ($case->{label}): B6 -- a span carries the spinner glyph");
            is($spin_span->{role}, $expect_role,
                "AC-4 ($case->{label}): B6 -- spinner span role == container_status_style(...)[1] ('$expect_role')")
                if $spin_span;
            is($spans[0]{role}, 'title', "AC-4 ($case->{label}): B6 -- the left span keeps role 'title'");
        }
    }
}

# ===========================================================================
# AC-5 -- width/sanitation hold with the spinner in place, over
# $cols in {40,60,80,120,200}, 12-row frame. Plus B5: absent spinner_idx
# leaves the text byte-identical to today's ("...[running]" ending).
# left/container chosen short enough (34 display cols) to fit at cols=40.
# ===========================================================================
{
    for my $cols (40, 60, 80, 120, 200) {
        my $state = { project_name => 'p', container => 'c', status => 'running', spinner_idx => 5 };
        my $frame = eval { Dashboard::compose_frame($state, 12, $cols) };
        is($@, '', "AC-5 (cols=$cols): compose_frame does not die");
        SKIP: {
            skip 'compose_frame died', 4 if $@;
            my $row0 = $frame->[0];
            is(Dashboard::display_width($row0->{text}), $cols,
                "AC-5 (cols=$cols): display_width(title text) == $cols");
            is(Dashboard::spans_width($row0->{spans}), $cols,
                "AC-5 (cols=$cols): spans_width(title spans) == $cols");
            is($row0->{text}, Dashboard::spans_text($row0->{spans}),
                "AC-5 (cols=$cols): title text eq spans_text(title spans)");
            unlike($row0->{text}, qr/[\e\a]/, "AC-5 (cols=$cols): title text contains no ESC/BEL");
        }

        # B5: absent spinner_idx -> byte-identical to today's output.
        my $state_no_spin = { project_name => 'p', container => 'c', status => 'running' };
        my $frame_ns = eval { Dashboard::compose_frame($state_no_spin, 12, $cols) };
        SKIP: {
            skip 'compose_frame died', 1 if $@ || !$frame_ns;
            like($frame_ns->[0]{text}, qr/\[running\]$/,
                "AC-5/B5 (cols=$cols): absent spinner_idx -> title row still ends '[running]' unchanged");
        }
    }
}

# ===========================================================================
# AC-6 -- the loop feeds a WALL-CLOCK index (Decision #21), never $ticks.
# (a) every post-first render repaints exactly row 1, no full clear.
# (b) the spinner glyph visible in successive renders walks @SPINNER in the
#     order dictated by int($t/$tick_interval) % 10, tracked against the
#     SAME fake clock the run() call advances.
# (c) driving the SAME iteration count with a non-advancing clock produces
#     ZERO row repaints -- the index tracks the clock, not the tick count.
# ===========================================================================
{
    # (a) + (b): manual clock tracking so we know exactly which $t produced
    # each render, independent of any assumption about ticks-per-render.
    my $clock = 0;
    my $tick_int = 0.25;
    my (@renders, @t_at_render);
    Dashboard::run(
        color => 0, beat_interval => 9999, state_interval => 0,
        tick_interval => $tick_int, max_ticks => 12,
        now       => sub { $clock },
        sleep_for => sub { $clock += $_[0] },
        read_key  => sub { undef },
        term_size => sub { (80, 20) },
        gather    => sub { { project_name => 'demo', container => 'ctr1', status => 'running' } },
        heartbeat => sub { 'ok' },
        spawn     => sub { undef },
        stop_runs => sub { { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                              machine_stopped => 0, others => [], others_known => 0, summary => 'x' } },
        full_shutdown => sub { { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                              machine_stopped => 1, others => [], others_known => 1, summary => 'y' } },
        enter_raw => sub { }, leave_raw => sub { }, keepawake => sub { },
        out => sub {
            my ($s) = @_;
            if ($s =~ /\A\e\[\?2026h/) { push @renders, $s; push @t_at_render, $clock; }
        },
    );

    ok(scalar(@renders) >= 3, 'AC-6a: at least 3 primary renders captured (clock-advancing run)');
    for my $i (1 .. $#renders) {
        unlike($renders[$i], qr/\e\[2J/, "AC-6a: render $i (post-first, idle) has no full repaint");
        my @moves = ($renders[$i] =~ /\e\[(\d+);1H/g);
        is(scalar(@moves), 1, "AC-6a: render $i (post-first, idle) repaints exactly one row");
        is($moves[0], 1, "AC-6a: render $i (post-first, idle) row repaint is the title row (row 1)");
    }

    for my $i (0 .. $#renders) {
        my $expected_idx   = int($t_at_render[$i] / $tick_int) % 10;
        my $expected_bytes = $SPINNER_BYTES[$expected_idx];
        my $seg = _row1_segment($renders[$i]);
        ok(defined $seg, "AC-6b: render $i -- row 1 segment isolated from the ANSI stream");
        SKIP: {
            skip 'row 1 segment not isolated', 1 unless defined $seg;
            if ($seg =~ /\[(.*?) running\]/) {
                is($1, $expected_bytes,
                    "AC-6b: render $i -- spinner glyph == \@SPINNER[int($t_at_render[$i]/$tick_int) % 10] == index $expected_idx");
            } else {
                fail("AC-6b: render $i -- row 1 segment did not contain the expected '[<spin> running]' shape");
            }
        }
    }

    # (c) same iteration budget, non-advancing clock -> zero row repaints.
    my $calls_c = _run_live(max_ticks => 6, sleep_for => sub { });
    my @renders_c = grep { /\A\e\[\?2026h/ } @$calls_c;
    ok(scalar(@renders_c) >= 2, 'AC-6c: at least 2 primary renders captured (non-advancing clock)');
    for my $i (1 .. $#renders_c) {
        my @moves = ($renders_c[$i] =~ /\e\[(\d+);1H/g);
        is(scalar(@moves), 0,
            "AC-6c: render $i with a NON-advancing clock repaints ZERO rows (index tracks the clock, not the tick count)");
    }
}

# ===========================================================================
# AC-7 -- consecutive idle ticks are a single-row update, not a full repaint.
# Exact assertion shape per spec S4 AC-7 (matching t/25-dashboard.t:419-420,
# :1115-1117 and t/40-layout-responsive.t:530-558's idiom), used essentially
# as written. AC-11's width-invisibility checks reuse this SAME capture.
# ===========================================================================
{
    my $clock = 1000;
    my @calls;                                    # every $out call, in order
    Dashboard::run(
        color => 0, tick_interval => 0.25, max_ticks => 5,
        beat_interval => 9999, state_interval => 0,
        now => sub { $clock }, sleep_for => sub { $clock += $_[0] },
        read_key => sub { undef }, term_size => sub { (80, 20) },
        gather => sub { { project_name => 'demo', container => 'ctr1', status => 'running' } },
        heartbeat => sub { 'ok' }, spawn => sub { undef },
        stop_runs => sub { { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                              machine_stopped => 0, others => [], others_known => 0, summary => 'x' } },
        full_shutdown => sub { { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                              machine_stopped => 1, others => [], others_known => 1, summary => 'y' } },
        enter_raw => sub { }, leave_raw => sub { }, keepawake => sub { },
        out  => sub { push @calls, $_[0] },
    );
    my @renders = grep { /\A\e\[\?2026h/ } @calls;              # frames only; OSC calls excluded
    for my $i (1 .. $#renders) {                                # skip [0]: first frame is a full paint
        unlike($renders[$i], qr/\e\[2J/,  "AC-7: idle tick $i: no full repaint");
        my @moves = ($renders[$i] =~ /\e\[(\d+);1H/g);
        is(scalar(@moves), 1, "AC-7: idle tick $i: exactly one row repainted");
        is($moves[0], 1,      "AC-7: idle tick $i: and it is the title row");
    }

    # -----------------------------------------------------------------
    # AC-11 (width-invisibility, over the SAME capture): B13 -- no captured
    # $out call contains both a frame open and an OSC; every OSC call
    # matches the exact shape; no ESC/BEL leaks into any composed row's
    # text; removing OSC calls from the stream leaves AC-7 unchanged.
    # -----------------------------------------------------------------
    for my $c (@calls) {
        if ($c =~ /\A\e\[\?2026h/) {
            unlike($c, qr/\e\]0;/, 'AC-11/B13: a frame call never contains an OSC title sequence');
        }
        if ($c =~ /\A\e\]0;/) {
            like($c, qr/\A\e\]0;[\x20-\x7E]*\a\z/, 'AC-11/B13: an OSC call matches /\A\e\]0;[\\x20-\\x7E]*\a\z/ exactly');
            unlike($c, qr/\e\[\?2026h/, 'AC-11/B13: an OSC call never contains a frame-open sequence');
        }
    }

    my @calls_without_osc = grep { !/\A\e\]0;/ } @calls;
    my @renders2 = grep { /\A\e\[\?2026h/ } @calls_without_osc;
    is_deeply(\@renders2, \@renders,
        'AC-11: removing OSC calls from the captured stream leaves the AC-7 render sequence unchanged');
}

# ===========================================================================
# AC-8 -- window_title per state: B8 over the five states, the two
# precedence cases, and the needs_you non-numeric/negative/undef == 0 rule.
# The five characters are hard-coded here per the spec's explicit
# instruction (S2.2's "bp-test-writer hard-codes these" table).
# ===========================================================================
{
    is(eval { Dashboard::window_title({ project_name => 'demo', status => 'running' }) }, '* demo',
        "AC-8/B8: window_title(running) eq '* demo'");

    for my $status (qw(paused created restarting stopping stopped)) {
        is(eval { Dashboard::window_title({ project_name => 'demo', status => $status }) }, '- demo',
            "AC-8: window_title(status=$status) eq '- demo' (stopped family)");
    }
    for my $status (qw(dead removing unknown exited)) {
        is(eval { Dashboard::window_title({ project_name => 'demo', status => $status }) }, 'x demo',
            "AC-8: window_title(status=$status) eq 'x demo' (exited family)");
    }
    is(eval { Dashboard::window_title({ project_name => 'demo', status => 'running', needs_you => 1 }) }, '! demo',
        "AC-8: window_title(running, needs_you=1) eq '! demo'");
    is(eval { Dashboard::window_title({ project_name => 'demo', container_gone => 1 }) }, '? demo',
        "AC-8: window_title(container_gone=1) eq '? demo'");

    # Precedence: gone > exited > stopped > needs-you > running > fallback.
    is(eval { Dashboard::window_title({ project_name => 'demo', status => 'running', container_gone => 1 }) }, '? demo',
        "AC-8: precedence -- container_gone=1 with status='running' -> '?' (gone beats running)");
    is(eval { Dashboard::window_title({ project_name => 'demo', status => 'exited', needs_you => 3 }) }, 'x demo',
        "AC-8: precedence -- status='exited' with needs_you=3 -> 'x' (exited beats needs-you)");
    is(eval { Dashboard::window_title({ project_name => 'demo', status => 'stopped', needs_you => 5 }) }, '- demo',
        "AC-8: precedence -- status='stopped' with needs_you=5 -> '-' (stopped beats needs-you)");

    # needs_you non-numeric / negative / undef counts as 0.
    for my $nc (undef, -3, 'abc', 0) {
        my $label = defined $nc ? "'$nc'" : 'undef';
        is(eval { Dashboard::window_title({ project_name => 'demo', status => 'running', needs_you => $nc }) }, '* demo',
            "AC-8: needs_you=$label counts as 0 -> '* demo' (not '!')");
    }
}

# ===========================================================================
# AC-9 -- window_title is ASCII-safe and total: B9 + B10 + malformed-input
# cases, asserting /\A[\x20-\x7E]{1,80}\z/ on every result, $SIG{__WARN__} armed.
# ===========================================================================
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $ascii_re = qr/\A[\x20-\x7E]{1,80}\z/;

    # B10: no project name -> no trailing space.
    is(eval { Dashboard::window_title({ status => 'running' }) }, '*',
        "AC-9/B10: window_title(no project_name) eq '*' (no trailing space)");

    # B15 (edge case): {} -> title '?'.
    is(eval { Dashboard::window_title({}) }, '?', "AC-9: window_title({}) eq '?'");

    # Malformed %state -> treated as {} -> '?'.
    for my $case ([undef, 'undef'], ['not a hashref', 'plain string'], [[1,2,3], 'arrayref'], [42, 'number']) {
        my ($input, $label) = @$case;
        my $got = eval { Dashboard::window_title($input) };
        is($@, '', "AC-9: window_title($label) does not die");
        is($got, '?', "AC-9: window_title($label) treated as {} -> '?'");
    }

    # B9: non-ASCII project name (decoded-char path and UTF-8-byte path).
    is(eval { Dashboard::window_title({ project_name => "Andr\x{E9}", status => 'running' }) }, '* Andr?',
        "AC-9/B9: window_title(project_name='Andr\\x{E9}' decoded) eq '* Andr?'");
    is(eval { Dashboard::window_title({ project_name => encode('UTF-8', "Andr\x{E9}"), status => 'running' }) }, '* Andr?',
        "AC-9/B9: window_title(project_name='Andr\\x{E9}' UTF-8 bytes) eq '* Andr?'");

    # B9: control bytes, an SGR escape, and a literal BEL in the project name.
    for my $case (
        [ "a\x01b",        'control byte' ],
        [ "a\e[31mb",      'SGR escape' ],
        [ "a\ab",          'literal BEL' ],
        [ "a\nb",          'embedded newline' ],
    ) {
        my ($name, $label) = @$case;
        my $got = eval { Dashboard::window_title({ project_name => $name, status => 'running' }) };
        is($@, '', "AC-9/B9: window_title(project_name with $label) does not die");
        like($got, $ascii_re, "AC-9/B9: window_title(project_name with $label) matches /\\A[\\x20-\\x7E]{1,80}\\z/");
        unlike($got, qr/[\x00-\x1F\x7F]/, "AC-9/B9: window_title(project_name with $label) contains no control byte");
    }

    # B9: 500-character project name truncates to 80 total.
    {
        my $long = 'x' x 500;
        my $got = eval { Dashboard::window_title({ project_name => $long, status => 'running' }) };
        is($@, '', 'AC-9/B9: window_title(500-char project name) does not die');
        like($got, $ascii_re, 'AC-9/B9: window_title(500-char project name) matches the ASCII-safe regex');
        is(length($got // ''), 80, 'AC-9/B9: window_title(500-char project name) truncates to exactly 80 chars');
        is($got, '* ' . ('x' x 78), "AC-9/B9: window_title(500-char project name) eq '* ' + 78 x's (plain truncation)");
    }

    is(scalar(@warnings), 0, 'AC-9: no warnings emitted across any window_title call above');
}

# ===========================================================================
# AC-10 -- OSC is emitted only on change: B11 + B12.
# ===========================================================================
{
    # B11: constant gather over N>=4 ticks -> exactly one OSC payload, on the
    # first tick (i.e. it precedes the first frame call).
    my $calls_b11 = _run_live(max_ticks => 4);
    my @osc_b11 = grep { /\A\e\]0;[^\a]*\a/ } @$calls_b11;
    is(scalar(@osc_b11), 1, 'AC-10/B11: exactly one OSC payload emitted across a constant-gather 4-tick run');
    my ($first_frame_idx) = grep { $calls_b11->[$_] =~ /\A\e\[\?2026h/ } 0 .. $#$calls_b11;
    my ($osc_idx)         = grep { $calls_b11->[$_] =~ /\A\e\]0;/ }     0 .. $#$calls_b11;
    ok(defined $first_frame_idx, 'AC-10/B11: at least one primary render captured');
    ok(defined $osc_idx && defined $first_frame_idx && $osc_idx < $first_frame_idx,
        'AC-10/B11: the single OSC call precedes the first primary render (emitted on the first tick)');

    # B12: status flips running -> exited partway through the run.
    my $gather_n = 0;
    my $flip_after = 4;
    my $g = sub {
        $gather_n++;
        return { project_name => 'demo', container => 'ctr1',
                 status => ($gather_n > $flip_after ? 'exited' : 'running') };
    };
    my $calls_b12 = _run_live(gather => $g, max_ticks => 8);
    my @osc_b12 = grep { /\A\e\]0;/ } @$calls_b12;
    is(scalar(@osc_b12), 2, 'AC-10/B12: exactly two OSC payloads across a status-flip run');
    SKIP: {
        skip 'did not get exactly two OSC payloads', 2 unless scalar(@osc_b12) == 2;
        is($osc_b12[0], "\e]0;* demo\a", "AC-10/B12: first OSC payload is exactly '* demo' (running)");
        is($osc_b12[1], "\e]0;x demo\a", "AC-10/B12: second OSC payload is exactly 'x demo' (exited)");
    }
}

# ===========================================================================
# AC-11 (composed-row-text half) -- no composed row's text in ANY frame
# contains ESC/BEL, extended across every row (not just row 0) of a 12-row
# frame with a spinner_idx present.
# ===========================================================================
{
    my $state = { project_name => 'p', container => 'c', status => 'running', spinner_idx => 7 };
    my $frame = eval { Dashboard::compose_frame($state, 12, 80) };
    is($@, '', 'AC-11: compose_frame(with spinner_idx) does not die');
    SKIP: {
        skip 'compose_frame died', 1 if $@;
        my $bad = grep { $_->{text} =~ /[\e\a]/ } @$frame;
        is($bad, 0, 'AC-11: no composed row text in the frame contains ESC or BEL');
    }
}

# ===========================================================================
# AC-12 -- launcher.pl enter_raw/leave_raw wiring, source-level (the same
# technique t/02-launcher-bind-mount-shape.t uses for mount args -- the
# closures run from signal handlers and need a real tty, so the seam is
# pinned structurally).
# ===========================================================================
{
    my $launcher_src = _slurp($launcher_pl);

    # (e) exactly one enter_raw / leave_raw pair in the file.
    my $enter_count = () = $launcher_src =~ /\benter_raw\s*=>\s*sub\s*\{/g;
    my $leave_count = () = $launcher_src =~ /\bleave_raw\s*=>\s*sub\s*\{/g;
    is($enter_count, 1, 'AC-12(e): exactly one enter_raw => sub {...} in launcher.pl');
    is($leave_count, 1, 'AC-12(e): exactly one leave_raw => sub {...} in launcher.pl');

    my ($enter_body) = $launcher_src =~ /\benter_raw\s*=>\s*sub\s*\{\n(.*?)\n[ \t]*\},/s;
    my ($leave_body) = $launcher_src =~ /\bleave_raw\s*=>\s*sub\s*\{\n(.*?)\n[ \t]*\},/s;
    ok(defined $enter_body && length($enter_body), 'AC-12: enter_raw closure body extracted')
        or diag('enter_raw title-save code is not implemented in launcher.pl yet');
    ok(defined $leave_body && length($leave_body), 'AC-12: leave_raw closure body extracted')
        or diag('leave_raw title-restore code is not implemented in launcher.pl yet');

    SKIP: {
        skip 'enter_raw body not found', 2 unless defined $enter_body;
        # (a) \e[22;0t (XTPUSHTITLE) appears BEFORE the \e]0; title set.
        my $push_pos  = index($enter_body, '\e[22;0t');
        my $title_pos = index($enter_body, '\e]0;');
        ok($push_pos >= 0 && $title_pos >= 0 && $push_pos < $title_pos,
            'AC-12(a): enter_raw contains \\e[22;0t (XTPUSHTITLE) BEFORE its \\e]0; title set')
            or diag("push_pos=$push_pos title_pos=$title_pos");
        # (b) enter_raw's title set calls Dashboard::window_title.
        like($enter_body, qr/Dashboard::window_title/,
            "AC-12(b): enter_raw's title set calls Dashboard::window_title");
    }

    SKIP: {
        skip 'leave_raw body not found', 3 unless defined $leave_body;
        # (c) \e]0;\a (neutral clear) appears BEFORE \e[23;0t (XTPOPTITLE).
        my $neutral_pos = index($leave_body, '\e]0;\a');
        my $pop_pos     = index($leave_body, '\e[23;0t');
        ok($neutral_pos >= 0 && $pop_pos >= 0 && $neutral_pos < $pop_pos,
            "AC-12(c): leave_raw contains \\e]0;\\a (neutral clear) BEFORE \\e[23;0t (XTPOPTITLE)")
            or diag("neutral_pos=$neutral_pos pop_pos=$pop_pos");
        # (d) both appear before ReadMode('restore') in leave_raw.
        my $restore_pos = index($leave_body, "ReadMode('restore')");
        ok($restore_pos >= 0 && $neutral_pos >= 0 && $neutral_pos < $restore_pos,
            "AC-12(d): leave_raw's \\e]0;\\a set happens BEFORE ReadMode('restore')");
        ok($restore_pos >= 0 && $pop_pos >= 0 && $pop_pos < $restore_pos,
            "AC-12(d): leave_raw's \\e[23;0t pop happens BEFORE ReadMode('restore')");
    }

    # (f) no OSC / title-stack sequence was added to the _spawn_session
    # error-recovery bounce (:4176/:4188) -- that path is out of scope.
    my ($spawn_body) = $launcher_src =~ /sub\s+_spawn_session\s*\{(.*?)\n\}/s;
    ok(defined $spawn_body && length($spawn_body), 'AC-12(f): _spawn_session sub body extracted');
    SKIP: {
        skip '_spawn_session body not found', 1 unless defined $spawn_body;
        unlike($spawn_body, qr/\\e\]0;|\\e\[22;0t|\\e\[23;0t/,
            'AC-12(f): _spawn_session (the alt-screen bounce at :4176/:4188) gained no OSC/title-stack sequence');
    }
}

# ===========================================================================
# AC-14 -- $ticks remains spinner-free: B15 (max_ticks still stops the loop
# after exactly that many iterations) + a source assertion that the only
# occurrences of $ticks in Dashboard.pm are the declaration, the max_ticks
# guard, and the increment -- no code this package adds may read it.
# ===========================================================================
{
    # B15: no scroll/lifecycle keys -> exactly max_ticks primary renders.
    my $calls = _run_live(max_ticks => 7);
    my @renders = grep { /\A\e\[\?2026h/ } @$calls;
    is(scalar(@renders), 7, 'AC-14/B15: max_ticks=7 with no scroll/lifecycle keys -> exactly 7 primary renders');

    my @ticks_lines = grep { /\$ticks\b/ } split /\n/, $dash_src;
    is(scalar(@ticks_lines), 3,
        'AC-14: exactly 3 source lines in Dashboard.pm reference $ticks (declaration + increment + guard)')
        or diag(explain(\@ticks_lines));
    ok((grep { /my\s+\$ticks\s*=\s*0/ } @ticks_lines) ? 1 : 0,
        "AC-14: one \$ticks line is the declaration 'my \$ticks = 0'");
    ok((grep { /\$ticks\+\+/ } @ticks_lines) ? 1 : 0,
        'AC-14: one $ticks line is the increment ($ticks++)');
    ok((grep { /\$ticks\s*>=\s*\$o\{max_ticks\}/ } @ticks_lines) ? 1 : 0,
        'AC-14: one $ticks line is the max_ticks guard ($ticks >= $o{max_ticks})');
}

done_testing();
