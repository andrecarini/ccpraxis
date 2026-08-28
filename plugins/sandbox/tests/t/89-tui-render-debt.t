#!/usr/bin/env perl
# 89-tui-render-debt.t -- ORACLE for package t08-tui-render-debt (blueprint
# tui-operator-feedback), specs/t08-tui-render-debt-spec.md. Written BLIND to
# any implementation of the three fixes (c8b0/59a4/9897) -- straight from the
# spec's numbered observable behaviors (S"Observable behaviors" 1-17) and
# acceptance criteria (AC1-16, minus AC6/AC16 which the spec itself rules
# report-only and unverifiable in-process -- see this package's final report
# for those two). Do NOT weaken an assertion here to make a future
# implementation's life easier.
#
# TODAY'S EXPECTED STATE (measured against the clone before this package's
# edit):
#   - Dashboard::render_frame's $full formula still ORs in $opts->{full}
#     (Dashboard.pm:2103) -- dead code, zero call sites, but still present
#     as a literal token in the source (AC5/behavior 6 below is RED today).
#   - Dashboard::run's loop never tracks last-seen (cols,rows) -- a
#     width-only resize at the next periodic poll produces NO \e[2J\e[H in
#     the next frame (AC1/behavior 1 below is RED today; the per-row diff
#     touches every row instead, per t/25-dashboard.t:795-800's own pin).
#   - tui::Frame::bound_for_wrap does not exist at all -- every direct call
#     below is wrapped in eval and expected to die ("Undefined subroutine"),
#     reported explicitly (AC7/AC8/AC9 below are RED today for a die, not a
#     wrong value).
#   - tui::Screen::compose()'s banner loop still wraps the FULL message
#     before slicing to budget -- unbounded, so behavior 12's timing
#     assertion is RED today (measured ~10.5s for a 100,000-char single
#     token at cols=1 on this host, vs. the well-under-5s target).
#   - The "[d] dismiss" hint can still land split across a wrap boundary at
#     cols=40 for a shaped-to-trigger fixture (AC11/behavior 14 below is RED
#     today for exactly that reason).
#   - _banner_lines (AC10/behavior 13), the row-budget invariant
#     (AC12/behavior 15), the multi-char-bracket-word control
#     (AC13/behavior 16) and the wrap_line fast path (AC14/behavior 17) are
#     all ALREADY GREEN today and must stay green -- regression guards, not
#     missing-behavior probes.
#
# NON-VACUITY: every "does not happen" assertion (no \e[2J, no split) is
# paired with a fixture hand-tuned (via direct experimentation against this
# clone) to actually trigger the failure mode today, not a fixture that
# happens to dodge it by luck.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Time::HiRes ();
use Encode ();

my $SCRIPTS = "$Bin/../../scripts";
use lib "$Bin/../../scripts";

# ===========================================================================
# Module load gates (mirrors t/75/t/87/t/88 convention)
# ===========================================================================
my $DASH_OK = eval { require Dashboard; 1 };
ok($DASH_OK, 'plugins/sandbox/scripts/Dashboard.pm loads') or diag("  require Dashboard failed: $@");
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'tui/Layout.pm loads') or diag("  require tui::Layout failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'tui/Frame.pm loads') or diag("  require tui::Frame failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'tui/Screen.pm loads') or diag("  require tui::Screen failed: $@");
my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'tui/DashboardScreen.pm loads') or diag("  require tui::DashboardScreen failed: $@");

my $DASHBOARD_PM = "$SCRIPTS/Dashboard.pm";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "cannot open $f: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# plain($cell) -> de-SGR'd text, same convention as t/75/t/88.
sub plain {
    my ($c) = @_;
    my $t = ref($c) eq 'HASH' ? $c->{text} : '';
    $t = '' if !defined $t;
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}

sub banner_rows_by_role {
    my ($f, $role) = @_;
    return grep { defined($_->{role}) && $_->{role} eq $role } @$f;
}

# has_bound_for_wrap() / call_bound_for_wrap(@args) -- t/75's convention for
# a sub that does not exist yet: never let a die escape the test file, but
# report it as a distinct, honest RED signal (not silently swallowed).
sub has_bound_for_wrap { return $FRAME_OK && defined &tui::Frame::bound_for_wrap; }
sub call_bound_for_wrap {
    my (@args) = @_;
    my $r = eval { tui::Frame::bound_for_wrap(@args) };
    return ($r, $@);
}

# char_len($s) -- decoded-character count, mirroring tui::Frame's own
# private _decode_str heuristic (a string already carrying a codepoint above
# 0xFF is treated as already-decoded; otherwise it is UTF-8 bytes). This is
# this file's own scaffolding copy, not a reach into Frame.pm's private sub.
sub char_len {
    my ($s) = @_;
    return 0 if !defined $s;
    return length($s) if $s =~ /[^\x00-\xFF]/;
    return length(Encode::decode('UTF-8', $s, Encode::FB_QUIET()));
}

# make_term_size(@seq) -> a term_size callback that returns each [cols,rows]
# tuple of @seq in order, one per call, and stays on the LAST tuple once
# exhausted (sticky), so a caller that keeps polling after the scripted
# sequence ends observes steady-state geometry rather than an error.
sub make_term_size {
    my (@seq) = @_;
    my $i = 0;
    return sub {
        my $v = $seq[ $i < $#seq ? $i++ : $#seq ];
        return @$v;
    };
}

# run_case(%args) -> { rc, outs => \@all_out_calls, frames => \@sync_frames }
# Drives Dashboard::run over injected seams, exactly as t/25-dashboard.t's
# own drive() helper does (this file's own copy, per t/75/t/88's "no shared
# test-lib import" convention). frames is the subset of out() calls that
# open a synchronized-output burst (i.e. an actual render_frame() emission,
# as opposed to the separate OSC window-title out() call the loop also
# makes), in emission order -- so frames[0] is the FIRST rendered frame,
# frames[1] the second, etc.
sub run_case {
    my (%args) = @_;
    my @keys  = @{ $args{keys} || [] };
    my $clock = 1000;
    my @outs;
    my $rc = Dashboard::run(
        beat_interval  => 100000,        # never fires during these short runs
        # The geometry poll no longer rides this throttle (see PART 1b), but the
        # PART 1 cases still want a gather every tick so each tick emits a frame.
        state_interval => (exists $args{state_interval} ? $args{state_interval} : 0),
        tick_interval  => 0,
        color          => 0,
        max_ticks      => $args{max_ticks} // 10,
        now            => sub { $clock },
        sleep_for      => sub { $clock += $_[0]; },
        read_key       => sub { @keys ? shift @keys : undef },
        term_size      => $args{term_size},
        gather         => sub { { project_name => 'demo', container => 'c1', status => 'running', events => [] } },
        heartbeat      => sub { 'ok' },
        spawn          => sub { undef },
        enter_raw      => sub { },
        leave_raw      => sub { },
        keepawake      => sub { },
        out            => sub { push @outs, $_[0]; },
    );
    my @frames = grep { /\e\[\?2026h/ } @outs;
    return { rc => $rc, outs => \@outs, frames => \@frames };
}

# a minimal compose_frame() fixture, this file's own copy (per t/25's %st).
my %ST = (
    project_name => 'demo',
    container    => 'claude-demo-abcd1234',
    status       => 'running',
    beat_age     => 12,
    uptime       => 3660,
    events       => ['10:00:01  launch_start'],
);

# ===========================================================================
# PART 1 -- AC1/AC2/AC3 (DC1): width-only resize forces a full repaint via
# Dashboard::run()'s loop bookkeeping, decided AGAINST render_frame's own
# formula (Decision 1). Behaviors 1, 2, 3.
# ===========================================================================
SKIP: {
    skip 'Dashboard.pm did not load', 6 unless $DASH_OK;

    # --- AC1/behavior 1 + AC2/behavior 2: width-only change (80x24 -> 40x24)
    # detected at the next periodic poll, then held steady at 40x24.
    my $ts = make_term_size([80, 24], [80, 24], [40, 24], [40, 24], [40, 24]);
    my $r = run_case(term_size => $ts, keys => [undef, undef, undef, 'q'], max_ticks => 10);
    is(scalar(@{ $r->{frames} }), 4, 'PART1 sanity: 4 frames captured before [q] quit')
        or diag("  outs: " . scalar(@{ $r->{outs} }) . " frames: " . scalar(@{ $r->{frames} }));

    SKIP: {
        skip 'did not capture the expected 4 frames', 3 if @{ $r->{frames} } != 4;
        like($r->{frames}[1], qr/\e\[2J\e\[H/,
            'AC1 (DC1/behavior 1): a width-only geometry change (80->40 cols, rows unchanged) detected at the next periodic poll forces \e[2J\e[H in the NEXT emitted frame');
        unlike($r->{frames}[2], qr/\e\[2J/,
            'AC2 (DC1/behavior 2): geometry held steady (40x24) across the NEXT poll after the resize emits no \e[2J (no flicker, B0 preserved)');
        unlike($r->{frames}[3], qr/\e\[2J/,
            'AC2 (DC1/behavior 2): geometry still steady one poll further emits no \e[2J');
    }

    # --- AC3/behavior 3: row-count change still forces a full repaint
    # (regression guard on the PRE-EXISTING trigger this package does not
    # touch -- render_frame's own !@$prev || @$prev != @$new clause).
    my $ts2 = make_term_size([80, 24], [80, 24], [80, 12], [80, 12]);
    my $r2  = run_case(term_size => $ts2, keys => [undef, undef, 'q'], max_ticks => 10);
    is(scalar(@{ $r2->{frames} }), 3, 'PART1 sanity: 3 frames captured before [q] quit (row-count case)')
        or diag("  outs: " . scalar(@{ $r2->{outs} }) . " frames: " . scalar(@{ $r2->{frames} }));
    SKIP: {
        skip 'did not capture the expected 3 frames', 1 if @{ $r2->{frames} } != 3;
        like($r2->{frames}[1], qr/\e\[2J\e\[H/,
            'AC3 (DC1/behavior 3, regression guard): a row-count change (24->12 rows) still forces a full repaint, unaffected by this package');
    }
}

# ===========================================================================
# PART 1b -- the geometry poll does not ride the GATHER throttle.
#
# Operator: "there's something wrong with the logic for detecting terminal
# window size changes and then repainting the TUI. It takes a long time for the
# repaint to trigger or it may not even trigger at all. But the moment I e.g.
# scroll my mouse, everything repaints nicely."
#
# The cause: term_size() was polled INSIDE run()'s state-refresh block, so a
# resize could not be noticed until the next gather round -- $state_int (2s in
# production) plus however long the gather itself took. Scrolling papered over
# it because $activity_offset is in the frame-cache signature.
#
# This case pins the fix where PART 1 cannot: state_interval is set so large
# that NO second gather happens during the run. Every frame after the first is
# therefore attributable to geometry alone. Under the old code term_size() was
# called exactly once and the resize was never seen at all.
# ===========================================================================
SKIP: {
    skip 'Dashboard.pm did not load', 3 unless $DASH_OK;

    my $ts = make_term_size([80, 24], [80, 24], [40, 24], [40, 24]);
    my $r  = run_case(term_size      => $ts,
                      state_interval => 100000,   # exactly one gather, on tick 1
                      keys           => [undef, undef, undef, 'q'],
                      max_ticks      => 10);
    cmp_ok(scalar(@{ $r->{frames} }), '>=', 2,
       'PART1b: with no second gather, a frame is still emitted for the resize -- geometry alone '
     . 'is enough to produce one')
        or diag("  frames: " . scalar(@{ $r->{frames} }));

    SKIP: {
        skip 'did not capture at least 2 frames', 3 if @{ $r->{frames} } < 2;
        like($r->{frames}[0], qr/\e\[2J\e\[H/,
             'PART1b: the first frame is the ordinary first-open full repaint');
        like($r->{frames}[1], qr/\e\[2J\e\[H/,
             'PART1b: a resize is noticed on the TICK it happens, without waiting for a gather round');

        # THE SETTLE WINDOW (operator, 2026-08-26: a MAXIMIZE would not repaint
        # while a drag-resize would; "it only repaints after I scroll").
        #
        # A drag reports its geometry many times, so some poll always lands
        # after the terminal has finished reflowing. A maximize reports once --
        # we repaint immediately, and the terminal then reflows ON TOP of that
        # repaint. From there the per-row diff has nothing to emit, because our
        # model and the screen disagree and only the screen knows it.
        #
        # So a geometry change keeps every row being re-emitted for a few ticks
        # afterwards. Those follow-up frames must NOT clear again -- one clear
        # is repair, a repeated clear is the flicker AC2 above forbids -- and
        # they must genuinely carry rows, or the window would be inert.
        my @after = @{ $r->{frames} }[ 2 .. $#{ $r->{frames} } ];
        SKIP: {
            skip 'no post-resize frames captured', 2 unless @after;
            my $cleared = grep { /\e\[2J/ } @after;
            is($cleared, 0,
               'PART1b: the settle frames after the resize re-emit WITHOUT clearing again -- one '
             . 'clear repairs, a repeated clear is flicker');
            my $carrying = grep { /\e\[\d+;1H/ } @after;
            is($carrying, scalar(@after),
               'PART1b: ...and every settle frame actually carries rows, so the window repairs a '
             . 'late reflow rather than merely existing');
        }
    }
}

# ===========================================================================
# PART 2 -- AC4 (DC1): render_frame's OWN unit-level contract (behaviors 4
# and 5) is unchanged by this package -- concrete evidence the fix lives in
# run()'s bookkeeping, not in render_frame's formula. Mirrors
# t/25-dashboard.t:768-800's own pins directly, in THIS package's oracle.
# ===========================================================================
SKIP: {
    skip 'Dashboard.pm did not load', 2 unless $DASH_OK;

    my $a = Dashboard::compose_frame(\%ST, 10, 60);
    my $full = Dashboard::render_frame(undef, $a, { color => 0 });
    like($full, qr/\e\[2J\e\[H/,
        'AC4 (DC1/behavior 4): render_frame(undef, $frame, ...) is STILL a full repaint (first-open path, unaffected by this package)');

    my %st2 = (%ST, beat_age => 99);
    my $b = Dashboard::compose_frame(\%st2, 10, 60);   # same row count, different content
    my $diff = Dashboard::render_frame($a, $b, { color => 0 });
    unlike($diff, qr/\e\[2J/,
        'AC4 (DC1/behavior 5): render_frame() for two same-row-count, different-content frames is STILL a per-row diff, never a clear (t/25:795-800\'s pin, unaffected)');
}

# ===========================================================================
# PART 3 -- AC5 (DC1): $opts->{full} is fully removed, not merely unused.
# Source-scan assertion, mirroring this suite's existing self-scan
# convention (e.g. t/87-banner-dismiss.t's slurp() + unlike()).
# ===========================================================================
{
    my $src = slurp($DASHBOARD_PM);
    unlike($src, qr/opts->\{full\}/,
        'AC5 (DC1/behavior 6): the literal token "opts->{full}" no longer appears anywhere in Dashboard.pm');
    unlike($src, qr/\bfull\s*=>/,
        'AC5 (DC1/behavior 6): no "full =>" hash-key token remains (opts is not re-wired with a renamed key either)');
}

# ===========================================================================
# PART 4 -- AC7 (DC2): tui::Frame::bound_for_wrap's own contract -- behaviors
# 7 (pass-through under budget), 8 (empty on invalid input), 9 (safe/
# generous cut over budget, display-width-safe).
# ===========================================================================
{
    # behavior 7: pass-through, byte-identical, when already in budget.
    my ($r7, $err7) = call_bound_for_wrap('hello', 10, 80);   # limit = 800 >> display_width('hello')=5
    ok(!$err7, 'AC7 (DC2/behavior 7): bound_for_wrap callable without dying on an in-budget input') or diag("  died: $err7");
    SKIP: {
        skip 'bound_for_wrap not implemented yet', 1 if $err7;
        is($r7, 'hello', 'AC7 (DC2/behavior 7): input already within budget is returned unchanged, byte-identical');
    }

    # behavior 8: empty/invalid input -> ''.
    for my $case (
        ['undef text',  [undef, 5, 10]],
        ['empty text',  ['',    5, 10]],
        ['n<=0',        ['abc', 0, 10]],
        ['n negative',  ['abc', -3, 10]],
        ['w<=0',        ['abc', 5, 0]],
        ['w negative',  ['abc', 5, -2]],
    ) {
        my ($label, $args) = @$case;
        my ($r8, $err8) = call_bound_for_wrap(@$args);
        ok(!$err8, "AC7 (DC2/behavior 8): bound_for_wrap callable without dying on $label") or diag("  died: $err8");
        SKIP: {
            skip 'bound_for_wrap not implemented yet', 1 if $err8;
            is($r8, '', "AC7 (DC2/behavior 8): $label -> ''");
        }
    }

    # behavior 9: over-budget input -- generous cut, never under-cuts, never
    # LENGTHENS the decoded text. Mixed ASCII + a display-width-2 glyph (the
    # same WIDE fixture t/75/t/77/t/88 use) so a byte-vs-char-vs-column
    # miscount cannot hide.
    my $WIDE  = chr(0xFF5C);
    my $text9 = ($WIDE x 100) . ('x' x 5000);   # decoded len 5100, display width 5200
    my $limit9 = 5 * 10;                        # $max_rows=5, $w=10 -> 50
    my ($r9, $err9) = call_bound_for_wrap($text9, 5, 10);
    ok(!$err9, 'AC7 (DC2/behavior 9): bound_for_wrap callable without dying on an over-budget wide-glyph input') or diag("  died: $err9");
    SKIP: {
        skip 'bound_for_wrap not implemented yet', 2 if $err9;
        cmp_ok(tui::Layout::display_width($r9), '>=', $limit9,
            "AC7 (DC2/behavior 9): the cut result's display width is >= the budget ($limit9) -- generous, never under-cuts");
        cmp_ok(char_len($r9), '<=', char_len($text9),
            'AC7 (DC2/behavior 9): the cut result is no LONGER than the original in decoded characters');
    }
}

# ===========================================================================
# PART 5 -- AC8 (DC2): behavior 10 -- bounding never changes what wrap_line
# ultimately displays, verified by comparing bounded-then-wrapped vs.
# unbounded-then-wrapped on the SAME long input, sliced to the same budget.
# ===========================================================================
{
    my $cols   = 40;
    my $indent = tui::Screen::WRAP_CONTINUATION_INDENT();
    my $role   = 'text.primary';
    my $budget = 5;
    my $text10 = ('word ' x 20000);   # 100,000 chars, whitespace-breakable
    my ($bounded, $err_b) = call_bound_for_wrap($text10, $budget, $cols);
    ok(!$err_b, 'AC8 (DC2/behavior 10): bound_for_wrap callable without dying on a 100,000-char input') or diag("  died: $err_b");
    SKIP: {
        skip 'bound_for_wrap not implemented yet', 1 if $err_b;
        my $wrapped_bounded   = eval { tui::Frame::wrap_line($bounded, $role, $cols, $indent) };
        my $wrapped_unbounded = eval { tui::Frame::wrap_line($text10,  $role, $cols, $indent) };
        ok(!$@ && ref($wrapped_bounded) eq 'ARRAY' && ref($wrapped_unbounded) eq 'ARRAY',
            'AC8 (DC2/behavior 10): both wrap_line calls succeed') or diag("  died: $@");
        my @slice_b = @$wrapped_bounded[0 .. ($budget - 1 > $#$wrapped_bounded ? $#$wrapped_bounded : $budget - 1)];
        my @slice_u = @$wrapped_unbounded[0 .. ($budget - 1 > $#$wrapped_unbounded ? $#$wrapped_unbounded : $budget - 1)];
        is_deeply(\@slice_b, \@slice_u,
            'AC8 (DC2/behavior 10): wrap_line(bound_for_wrap($text,$budget,$cols),...) sliced to $budget rows is is_deeply-identical to wrap_line($text,...) sliced to the same $budget rows, for a 100,000-character input -- the bound never changes displayed content');
    }
}

# ===========================================================================
# PART 6 -- AC9 (DC2): behaviors 11 and 12 -- the stated timing bounds, and
# a recorded comparison to the filed report's own original measurement.
# ===========================================================================
{
    # behavior 11: 2,000,000-char single UNBREAKABLE token -> bound_for_wrap
    # alone completes in well under 1 wall-clock second.
    my $word11 = 'x' x 2_000_000;
    my ($elapsed11, $r11, $err11);
    {
        my $t0 = Time::HiRes::time();
        ($r11, $err11) = call_bound_for_wrap($word11, 5, 10);
        $elapsed11 = Time::HiRes::time() - $t0;
    }
    ok(!$err11, 'AC9 (DC2/behavior 11): bound_for_wrap callable without dying on a 2,000,000-character single token')
        or diag("  died: $err11");
    SKIP: {
        skip 'bound_for_wrap not implemented yet', 1 if $err11;
        cmp_ok($elapsed11, '<', 1,
            sprintf('AC9 (DC2/behavior 11): 2,000,000-char single-token bound_for_wrap completes in well under 1s (measured %.3fs)', $elapsed11));
    }

    # behavior 12: tui::Screen::compose() given a >=20,000-char single
    # unbreakable-token banner at cols=1 completes in well under 5s -- the
    # SAME shape of fixture (a long unbreakable token) as the filed report's
    # own ~8.5s measurement at 50,000 chars. 100,000 chars is used here
    # (still "at least 20,000" per the spec) because on THIS host the
    # unbounded path only crosses 5s well past 50,000 chars -- measured
    # directly against this clone before writing this assertion: 20,000
    # chars ~2.3s, 50,000 chars ~5.7s, 100,000 chars ~10.5s (unbounded).
    # Recorded here, not just asserted, so the improvement is demonstrated,
    # not merely an arbitrary ceiling picked in a vacuum.
    SKIP: {
        skip 'tui::Screen / tui::DashboardScreen did not load', 1 unless $SCREEN_OK && $DS_OK;
        my $token12 = 'x' x 100_000;
        my $state12 = { status => 'running', install_warning => $token12 };
        my ($elapsed12, $f12);
        {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm(60);
            my $t0 = Time::HiRes::time();
            $f12 = tui::DashboardScreen::compose($state12, 24, 1);
            $elapsed12 = Time::HiRes::time() - $t0;
            alarm(0);
        }
        diag(sprintf('  AC9/behavior12: compose() on a 100,000-char single-token banner at cols=1 took %.3fs (unbounded-path baseline on this host: ~10.5s; filed report measured ~8.5s at 50,000 chars on the operator\'s host)', $elapsed12));
        cmp_ok($elapsed12, '<', 5,
            sprintf('AC9 (DC2/behavior 12): compose() on a 100,000-char single-token install_warning banner at cols=1 completes in well under 5s (measured %.3fs)', $elapsed12));
    }
}

# ===========================================================================
# PART 7 -- AC10 (DC3): behavior 13 -- _banner_lines is PROVABLY unchanged.
# Byte-identical regression guard, both this package's own AC and the thing
# that keeps the FOREIGN, already-closed t/87-banner-dismiss.t oracle green.
# ===========================================================================
SKIP: {
    skip 'tui::DashboardScreen did not load', 1 unless $DS_OK;
    is_deeply(
        tui::DashboardScreen::_banner_lines({ install_warning => 'backpack install: some items failed' }),
        ['  !! backpack install: some items failed  [d] dismiss'],
        'AC10 (DC3/behavior 13): _banner_lines({install_warning=>...}) return value is byte-identical to today -- this package must not touch it (protects t/87-banner-dismiss.t\'s pinned oracle)');
}

# ===========================================================================
# PART 8 -- AC11/AC12 (DC3): behaviors 14 and 15 -- the dismiss hint never
# splits across two emitted rows at cols=40, and the row-budget invariant
# holds at the same time. Fixture hand-tuned against THIS clone (7 repeats
# of a 12-char filler word) to actually reproduce the split TODAY -- a
# smaller/larger filler count does not trigger it (verified directly).
# ===========================================================================
SKIP: {
    skip 'tui::DashboardScreen (or a dependency) did not load', 3 unless $DS_OK && $SCREEN_OK;

    my $filler = join(' ', ('wordwordword') x 7);
    my $install_warning = "zqx $filler failed";
    my $state = { status => 'running', install_warning => $install_warning };
    my $f = tui::DashboardScreen::compose($state, 24, 40);

    is(scalar(@$f), 24,
        'AC12 (DC3/behavior 15): compose() still returns exactly 24 cells (row-budget invariant) for the split-triggering fixture');

    my @banner_cells = banner_rows_by_role($f, 'overlay.warn');
    ok(scalar(@banner_cells) >= 1, 'AC11 sanity: at least one banner row is emitted (liveness control before checking same-row containment)');

    my $found_same_row = 0;
    for my $c (@banner_cells) {
        $found_same_row = 1 if index(plain($c), '[d] dismiss') >= 0;
    }
    ok($found_same_row,
        "AC11 (DC3/behavior 14): at cols=40, SOME SINGLE emitted row's plain text contains the literal substring '[d] dismiss' -- the hotkey and its label are never split across two different rows (STRICTLY STRONGER than t/88-banner-wrap-every-surface.t's cross-row-tolerant adjacency check)")
        or diag('  rows: [' . join('|', map { plain($_) } @banner_cells) . ']');
}

# ===========================================================================
# PART 9 -- AC13 (DC3): behavior 16 -- the multi-character-bracket-word
# control is unaffected: '[running]' immediately followed by another word,
# at a width where they land on separate rows via an ordinary WORD-boundary
# split, is unaffected by the merge rule (which requires exactly one
# non-bracket character inside the brackets).
# ===========================================================================
SKIP: {
    skip 'tui/Frame.pm did not load', 2 unless $FRAME_OK;
    my $line = 'context [running] tailwordx';
    my $cells = eval { tui::Frame::wrap_line($line, 'text.primary', 12, 2) };
    ok(!$@ && ref($cells) eq 'ARRAY', 'AC13 (DC3/behavior 16): wrap_line callable without dying on the multi-char-bracket-word control') or diag("  died: $@");
    SKIP: {
        skip 'wrap_line did not return an arrayref', 1 if $@ || ref($cells) ne 'ARRAY';
        my @plain_rows = map { plain($_) } @$cells;
        my $bracket_row_i = -1;
        my $tail_row_i    = -1;
        for my $i (0 .. $#plain_rows) {
            $bracket_row_i = $i if $plain_rows[$i] =~ /\[running\]/;
            $tail_row_i    = $i if $plain_rows[$i] =~ /tailwordx/;
        }
        ok($bracket_row_i >= 0 && $tail_row_i >= 0 && $bracket_row_i != $tail_row_i,
            "AC13 (DC3/behavior 16): '[running]' (multi-char bracket token, does NOT match the single-char hotkey-glue rule) and the following word 'tailwordx' land on DIFFERENT rows, unaffected by the merge rule")
            or diag('  rows: [' . join('|', @plain_rows) . ']');
    }
}

# ===========================================================================
# PART 10 -- AC14 (DC3): behavior 17 -- the wrap_line fast path (spans_width
# <= $w) is unaffected for a hotkey-bearing row that fits on one line:
# byte-identical to make_cell's direct output for that row.
# ===========================================================================
SKIP: {
    skip 'tui/Frame.pm did not load', 1 unless $FRAME_OK;
    my $line = 'ok [d] dismiss';
    my $cells = eval { tui::Frame::wrap_line($line, 'text.primary', 40, 2) };
    my $mc    = eval { tui::Frame::make_cell($line, 'text.primary', 40) };
    ok(!$@ && ref($cells) eq 'ARRAY' && ref($mc) eq 'HASH', 'AC14 (DC3/behavior 17): wrap_line/make_cell both callable without dying on a single-line hotkey row') or diag("  died: $@");
    SKIP: {
        skip 'wrap_line or make_cell did not return the expected shape', 2 if $@ || ref($cells) ne 'ARRAY' || ref($mc) ne 'HASH';
        is(scalar(@$cells), 1, 'AC14 (DC3/behavior 17): a hotkey row that fits on one line produces exactly one wrapped cell (fast path taken)');
        is($cells->[0]{text}, $mc->{text},
            "AC14 (DC3/behavior 17): wrap_line's fast-path output is byte-identical to make_cell's direct output for the same row -- the merge step never executes on the fast path");
    }
}

# ===========================================================================
# PART 11 -- REGRESSION, added by the driver 2026-08-19 after this package's
# red-team found a CRITICAL that THIS FILE passed straight through.
#
# bound_for_wrap under-cut and silently dropped real banner content whenever
# $cols <= WRAP_CONTINUATION_INDENT, because wrap_line's degenerate
# content_w == $w fallback removes the slack the old $max_rows * $w limit
# accidentally relied on. Every one of the six literal install-warning strings
# diverged from the unbounded wrap at cols 1 and 2; the driver reproduced 48
# diverging combinations out of 96.
#
# WHY THIS FILE MISSED IT, which is the part worth pinning: AC8's content
# check hardcodes cols=40, and the only cols=1 check (AC9/behavior 12) uses a
# single unbreakable token and asserts timing rather than content. The two
# never overlapped on the vulnerable shape -- word-separated text at a
# degenerate width -- so 47/47 was green over a live bug. The invariant below
# is stated directly instead: for ANY text, width and row budget, bounding
# then wrapping must produce the same surviving rows as wrapping unbounded.
# That is the whole contract of the bound; it exists to skip work, never to
# change what the operator sees.
# ===========================================================================
SKIP: {
    skip 'tui/Frame.pm did not load', 1 unless $FRAME_OK;
    my @texts = (
        '  !! backpack install FAILED: 3 of 7 items could not be restored  [d] dismiss',
        '  !! alpha beta gamma delta epsilon',
        '  !! one two',
        '  !! ' . ('word ' x 12),
        '  !! ' . ('a ' x 40),
    );
    my ($checked, $diverged, $first) = (0, 0, '');
    for my $t (@texts) {
        for my $cols (1, 2, 3, 4, 5, 8, 13, 40, 80) {
            for my $rows (1, 2, 3, 4, 6, 12) {
                $checked++;
                my $un  = eval { tui::Frame::wrap_line($t, 'state.warn', $cols) } or next;
                my $cut = eval { tui::Frame::bound_for_wrap($t, $rows, $cols) };
                my $bo  = eval { tui::Frame::wrap_line($cut, 'state.warn', $cols) } or next;
                my $n   = $rows < scalar(@$un) ? $rows : scalar(@$un);
                for my $i (0 .. $n - 1) {
                    my $a = $un->[$i]{text} // '';
                    my $b = defined $bo->[$i] ? ($bo->[$i]{text} // '') : '';
                    next if $a eq $b;
                    $diverged++;
                    $first ||= "cols=$cols rows=$rows row=$i unbounded=[$a] bounded=[$b]";
                    last;
                }
            }
        }
    }
    is($diverged, 0,
        "PART 11 (driver regression): bounding then wrapping matches the unbounded wrap "
      . "for every surviving row across $checked text/width/budget combinations -- the "
      . 'bound skips work, it never changes what is displayed')
        or diag("  first divergence: $first");
}

done_testing();
