#!/usr/bin/env perl
# s11-lifecycle-stop: stop-runs + full-shutdown, staged feedback, TUI-persistent.
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s11-lifecycle-stop (specs/08-lifecycle-stop-spec.md). It is written
# BLIND to any Dashboard.pm / launcher.pl implementation -- directly from the
# spec -- so it can serve as an oracle rather than an echo of whatever the
# implementer eventually writes. Do NOT weaken an assertion to make a future
# implementation's life easier.
#
# Coverage: AC-1..AC-21 (spec S4). AC-22 (whole-suite-green gate) is a
# coordinator-side check, not encoded here (same convention as t/45's AC-27).
#
# Hard constraints honoured here:
#   * NO real podman: every container/machine interaction goes through an
#     injected seam fake (build_seams(), below). No system/qx/backtick/exec
#     against podman anywhere in this file.
#   * NO real sleeping: await_quiet and run_stages are driven with injected
#     now/sleep_for fakes throughout; build_seams()'s default now/sleep_for
#     is itself a fake incrementing clock (never real wall-clock time), so
#     even a "never quiet" probe cannot cause a real wait.
#   * launcher.pl is NEVER require'd/do'ne for AC-21 -- source-text slurp +
#     regex only (t/36's stated convention, followed by t/43/t/44/t/45).
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $DASHBOARD_SRC = "$SCRIPTS_DIR/Dashboard.pm";
my $LAUNCHER_SRC  = "$SCRIPTS_DIR/launcher.pl";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# ===========================================================================
# count_banner_starts(\@alert_rows) -- fix-batch step 7 (d02-wrap-every-
# surface, reviewer MUST-FIX #1, red-team follow-up).
#
# Duplicated (deliberately, per this fix-batch's write set: no shared lib
# between t/25 and t/46) from the identical helper in t/25-dashboard.t --
# see that copy's doc comment for the full derivation, including why
# anchoring to `/^!! /` (the reviewer's own suggested minimal fix) is WRONG
# (undercounts an unwrapped banner alongside a wrapped one), why the
# structural discriminator (first span's role) is authoritative, and the
# ruled width floor: banner-start COUNTING is undefined at $cols < 3
# (wrap_line's degenerate-budget path drops the leading-indent span
# entirely at 1-2 columns, so no discriminator -- structural or textual --
# can recover a count there), but IS still correct at $cols == 3 exactly
# via the structural check alone (driver-verified). All existing call sites
# in THIS file use $cols in (40, 80, 100, 200) -- comfortably clear of that
# floor -- so this file makes no cols<3 assertion of its own; the pinned
# width-floor coverage lives in t/25.
my $CONTINUATION_ROLE = 'text.primary';   # Screen.pm's wrap-continuation indent role
my $BANNER_ROLE       = 'state.crit';     # Screen.pm's banner_role (spec 06 S2.4.9)
# _strip_title_status($row, $is_title) -> a row whose banner-role spans exclude
# the TITLE's own status block.
#
# Row 0 has to be examined -- the side column starts there, so a banner can
# live on it -- but the header carries a state.crit span for "exited", which is
# not a banner. Left in, it joins AHEAD of the banner text, so
# count_banner_starts sees "exited !! full shutdown..." and its ^\s*!! start
# test misses: two banners were counted as one.
#
# Only the title row is filtered, and only for an exact status word. A banner's
# own continuation legitimately contains words like "running" (the lifecycle
# detail ends "- running"), and stripping those would corrupt the text the
# full-detail assertion joins back together.
sub _strip_title_status {
    my ($row, $is_title) = @_;
    return $row unless $is_title && ref($row->{spans}) eq 'ARRAY';
    my @keep = grep {
        !( ($_->{role} // '') eq 'state.crit'
           && ($_->{text} // '') =~ /\A(?:running|exited|stopped|paused|created|restarting|stopping|dead|removing|unknown|\?)\z/ )
    } @{ $row->{spans} };
    return { %$row, spans => \@keep };
}

sub count_banner_starts {
    my ($rows) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    my $count = 0;
    for my $row (@$rows) {
        next if ref($row) ne 'HASH';
        my $spans = (ref($row->{spans}) eq 'ARRAY') ? $row->{spans} : undef;
        # ANCHORED TO THE BANNER'S OWN TEXT, not to span 0 of the row.
        #
        # This used to read "span 0's role is not the continuation indent
        # role", which held only while banners were full-width and therefore
        # always began at column 0. Banners now render into the SIDE COLUMN at
        # widths that have one (operator request, 2026-08-25), so span 0 of
        # such a row belongs to the MAIN region and carries text.primary -- the
        # continuation role -- and every banner row looked like a continuation.
        # The count silently became 0 at cols=200 while the banners were
        # plainly on screen.
        #
        # Concatenating just the banner-role spans gives the banner's own text
        # wherever it sits. A START begins with the "!! " marker; a
        # CONTINUATION begins with wrapped content, because the hanging indent
        # is a separate span carrying the continuation role and is excluded
        # here. That is why this is not the naive unanchored /!! / scan the
        # file's header warns about: it cannot see a "!! " that merely appears
        # inside wrapped prose, since such text is not at the START of the
        # banner region.
        #
        # No spans array -> cannot identify a continuation -> counts as a start
        # (defensive default; every cell this codebase emits carries spans).
        if (!$spans || !@$spans) { $count++; next }
        my $btext = join '', map { defined($_->{text}) ? $_->{text} : '' }
                             grep { ($_->{role} // '') eq $BANNER_ROLE } @$spans;
        $count++ if $btext =~ /^\s*!!\s/;
    }
    return $count;
}

# --- source-text helpers (Dashboard.pm / launcher.pl are never require'd for
#     these particular assertions; both are read as plain text). -----------
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub extract_sub_body {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced_braces($src, $idx);
}
sub _balanced_parens {
    my ($src, $from) = @_;
    my $idx = index($src, '(', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '(') { $depth++; }
        elsif ($c eq ')') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub extract_call_block {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced_parens($src, $idx);
}

# --- seam harness for Dashboard::run_stages -------------------------------
# build_seams(%over) -> (\%seams, \@calls, \@progress, \@logs)
#
# @calls records seam invocation ORDER as bare tags ('signal_runs',
# 'quiet_probe', 'stop_container', 'list_containers', 'stop_machine',
# 'await_quiet') -- pushed by the wrapper BEFORE delegating to the real
# implementation, so a dying override still leaves a call record (matching
# spec 2.5's per-stage sequencing: seam call happens before its outcome is
# known).
#
# The default now/sleep_for pair is a FAKE incrementing clock (never real
# wall-clock time) so that even a probe that never goes quiet reaches
# await_quiet's timeout via fake time, never a real sleep.
#
# ABSENT is a sentinel: build_seams(list_containers => ABSENT) omits that key
# from %seams entirely (simulating the seam not being supplied at all).
use constant ABSENT => 'ABSENT-SEAM-MARKER';

sub build_seams {
    my (%over) = @_;
    my @calls;
    my @progress;
    my @logs;
    my $self = $over{self_container} // 'self-container';
    my %default_impl = (
        signal_runs     => sub { 3 },
        quiet_probe     => sub { 1 },
        stop_container  => sub { { ok => 1, detail => 'stopped' } },
        list_containers => sub { [ $self ] },
        stop_machine    => sub { { ok => 1, detail => 'machine stopped' } },
    );
    my %seams;
    for my $tag (keys %default_impl) {
        if (exists $over{$tag}) {
            next if !ref($over{$tag}) && $over{$tag} eq ABSENT;
            my $impl = $over{$tag};
            $seams{$tag} = sub { push @calls, $tag; return $impl->(@_); };
        }
        else {
            my $impl = $default_impl{$tag};
            $seams{$tag} = sub { push @calls, $tag; return $impl->(@_); };
        }
    }
    # await_quiet is an OVERRIDE seam (2.5): only wire it if the test supplies
    # one explicitly. Absent, the driver must fall back to its own default
    # composition over quiet_probe/now/sleep_for (that's the path most tests
    # below exercise).
    if (exists $over{await_quiet} && !(!ref($over{await_quiet}) && $over{await_quiet} eq ABSENT)) {
        my $impl = $over{await_quiet};
        $seams{await_quiet} = sub { push @calls, 'await_quiet'; return $impl->(@_); };
    }
    my $t = 1000;   # fake clock -- NEVER real time
    $seams{now}       = $over{now}       // sub { $t };
    $seams{sleep_for} = $over{sleep_for} // sub { $t += $_[0]; };
    $seams{status_cb} = sub { push @progress, $_[0]; };
    $seams{log_cb}    = sub { push @logs, [ $_[0], $_[1] ]; };
    return (\%seams, \@calls, \@progress, \@logs);
}

sub stage_of {
    my ($result, $id) = @_;
    return undef unless ref($result) eq 'HASH' && ref($result->{stages}) eq 'ARRAY';
    my ($s) = grep { $_->{id} eq $id } @{ $result->{stages} };
    return $s;
}

# field($h,$k) -> $h->{$k} if $h is a hashref, else undef. Several subs below
# (await_quiet, run_stages, ...) DO NOT EXIST YET; every call to them is
# wrapped in eval so a missing sub degrades to a clean per-assertion FAIL
# (this file's stated convention -- see t/45's identical rationale) rather
# than a fatal "Undefined subroutine" aborting the whole file. field() is the
# companion accessor: it lets the assertions below dereference a possibly-
# undef result WITHOUT a second-order crash.
sub field { my ($h, $k) = @_; return (ref($h) eq 'HASH') ? $h->{$k} : undef; }

# _seq_order_ok(\@calls, @expect) -> true iff each expected tag's LAST
# occurrence index precedes the NEXT expected tag's FIRST occurrence index.
# Tolerates a single stage's seam being polled more than once (e.g.
# quiet_probe polled across several await_quiet iterations) while still
# proving strict stage-to-stage ordering.
sub _seq_order_ok {
    my ($calls, @expect) = @_;
    my $floor = -1;
    for my $tag (@expect) {
        my @idxs = grep { $calls->[$_] eq $tag } 0 .. $#$calls;
        return 0 unless @idxs;
        return 0 if $idxs[0] <= $floor;
        $floor = $idxs[-1];
    }
    return 1;
}

# ===========================================================================
# PART 1 -- dispatch_key (AC-1..AC-4 / B1-B4)
# ===========================================================================
{
    # AC-1: pinned (action,pending) pairs, no pending armed.
    is_deeply([Dashboard::dispatch_key('s', '')], ['confirm-stop-runs', 'stop-runs'],
        'AC-1: s -> confirm-stop-runs/stop-runs');
    is_deeply([Dashboard::dispatch_key('S', '')], ['confirm-stop-runs', 'stop-runs'],
        'AC-1: S -> confirm-stop-runs/stop-runs');
    is_deeply([Dashboard::dispatch_key('x', '')], ['confirm-full-shutdown', 'full-shutdown'],
        'AC-1: x -> confirm-full-shutdown/full-shutdown');
    is_deeply([Dashboard::dispatch_key('X', '')], ['confirm-full-shutdown', 'full-shutdown'],
        'AC-1: X -> confirm-full-shutdown/full-shutdown');
    is_deeply([Dashboard::dispatch_key('c', '')], ['launch', ''], 'AC-1: c -> launch');
    is_deeply([Dashboard::dispatch_key('C', '')], ['launch', ''], 'AC-1: C -> launch');
    is_deeply([Dashboard::dispatch_key("\r", '')], ['launch', ''], 'AC-1: CR -> launch');
    is_deeply([Dashboard::dispatch_key("\n", '')], ['launch', ''], 'AC-1: LF -> launch');
    is_deeply([Dashboard::dispatch_key('r', '')], ['refresh', ''], 'AC-1: r -> refresh');
    is_deeply([Dashboard::dispatch_key('R', '')], ['refresh', ''], 'AC-1: R -> refresh');
    is_deeply([Dashboard::dispatch_key('q', '')], ['quit', ''], 'AC-1: q -> quit');
    is_deeply([Dashboard::dispatch_key('Q', '')], ['quit', ''], 'AC-1: Q -> quit');
    is_deeply([Dashboard::dispatch_key('UP', '')], ['scroll-up', ''], 'AC-1: UP -> scroll-up');
    is_deeply([Dashboard::dispatch_key('DOWN', '')], ['scroll-down', ''], 'AC-1: DOWN -> scroll-down');
    is_deeply([Dashboard::dispatch_key('k', '')], ['scroll-up', ''], 'AC-1: k -> scroll-up');
    is_deeply([Dashboard::dispatch_key('j', '')], ['scroll-down', ''], 'AC-1: j -> scroll-down');
    is_deeply([Dashboard::dispatch_key('z', '')], ['', ''], 'AC-1: unknown key -> inert');
    is_deeply([Dashboard::dispatch_key("\e", '')], ['', ''], 'AC-1: lone ESC -> inert');
    is_deeply([Dashboard::dispatch_key(undef, undef)], ['', ''],
        'AC-1: undef key/pending normalize to empty string -> inert');

    # AC-2 (B2): confirm -> fire, clearing pending.
    is_deeply([Dashboard::dispatch_key('y', 'stop-runs')], ['stop-runs', ''],
        'AC-2: y while stop-runs armed -> fire stop-runs, pending cleared');
    is_deeply([Dashboard::dispatch_key('Y', 'stop-runs')], ['stop-runs', ''],
        'AC-2: Y while stop-runs armed -> fire stop-runs, pending cleared');
    is_deeply([Dashboard::dispatch_key('y', 'full-shutdown')], ['full-shutdown', ''],
        'AC-2: y while full-shutdown armed -> fire full-shutdown, pending cleared');
    is_deeply([Dashboard::dispatch_key('Y', 'full-shutdown')], ['full-shutdown', ''],
        'AC-2: Y while full-shutdown armed -> fire full-shutdown, pending cleared');

    # AC-3 (B3): any-other-key -> cancel, own action, empty pending.
    for my $k ('n', 'UP', 'j', 'q', 'c', 'r', "\e") {
        my $disp = ($k eq "\e") ? 'ESC' : $k;
        is_deeply([Dashboard::dispatch_key($k, 'stop-runs')], ['cancel-stop-runs', ''],
            "AC-3: key '$disp' while stop-runs armed -> cancel-stop-runs, pending cleared");
        is_deeply([Dashboard::dispatch_key($k, 'full-shutdown')], ['cancel-full-shutdown', ''],
            "AC-3: key '$disp' while full-shutdown armed -> cancel-full-shutdown, pending cleared");
    }

    # AC-4 (B4): confirm independence + bare-y-with-nothing-armed inertness.
    is_deeply([Dashboard::dispatch_key('x', 'stop-runs')], ['cancel-stop-runs', ''],
        'AC-4: x while stop-runs armed cancels it (does NOT fire/re-arm full-shutdown)');
    is_deeply([Dashboard::dispatch_key('s', 'full-shutdown')], ['cancel-full-shutdown', ''],
        'AC-4: s while full-shutdown armed cancels it (does NOT fire/re-arm stop-runs)');
    is_deeply([Dashboard::dispatch_key('y', '')], ['', ''],
        'AC-4: bare y with nothing armed fires nothing (inert)');

    # Normalization: a $pending value that is not one of the two pinned
    # tokens (e.g. the retired 'shutdown') is treated as '' (no confirm armed).
    is_deeply([Dashboard::dispatch_key('s', 'shutdown')], ['confirm-stop-runs', 'stop-runs'],
        "AC-4/normalization: legacy pending 'shutdown' is not a recognized token -- s arms stop-runs fresh");
    is_deeply([Dashboard::dispatch_key('y', 'shutdown')], ['', ''],
        "AC-4/normalization: legacy pending 'shutdown' is not a recognized token -- y is inert, not a fire");
    is_deeply([Dashboard::dispatch_key('y', 'bogus-token')], ['', ''],
        'AC-4/normalization: an unrecognized non-empty pending value is treated as no pending armed');
}

# ===========================================================================
# PART 2 -- footer_legend / confirm_prompt / _footer_line / compose_frame
#           footer role (AC-5, AC-6, AC-7 / B5, B6, B7)
# ===========================================================================
{
    # AC-5 (B5): footer_legend tiering, exact pinned strings at the extremes.
    # footer_legend does NOT exist yet -- every call is wrapped in eval so a
    # missing sub degrades to a clean per-assertion FAIL, not a fatal abort.
    my $t1 = eval { tui::DashboardScreen::_footer_legend(200) };
    is($t1, ' [c] launch Claude Code  [s] stop runs  [x] full shutdown  [up/down] scroll  [r] reload  [q] quit',
        'AC-5: footer_legend(200) is the pinned T1 string, byte-for-byte');

    my $at80 = eval { tui::DashboardScreen::_footer_legend(80) };
    like($at80 // '', qr/\[c\] launch Claude Code/,
        'AC-5: footer_legend(80) still contains "[c] launch Claude Code" (T2, per spec B5)');

    my $t3 = eval { tui::DashboardScreen::_footer_legend(40) };
    is($t3, ' [c] launch  [s] stop  [x] shutdown  [r] reload  [q] quit',
        'AC-5: footer_legend(40) is the pinned T3 string, byte-for-byte');

    for my $tier ([$t1, 200], [$at80, 80], [$t3, 40]) {
        my ($str, $cols) = @$tier;
        for my $k (qw(c s x r q)) {
            like($str // '', qr/\[\Q$k\E\]/, "AC-5: footer_legend($cols) names key [$k]");
        }
    }

    # AC-6 (B6): confirm prompts name their exact effects, at wide + narrow.
    # confirm_prompt does NOT exist yet -- every call is wrapped in eval.
    for my $cols (40, 80, 200) {
        my $sr = eval { tui::DashboardScreen::_confirm_prompt('stop-runs', $cols) };
        ok(defined $sr, "AC-6: confirm_prompt('stop-runs', $cols) is defined");
        if (defined $sr) {
            like($sr, qr/butler runs|ALL .*runs/i, "AC-6: stop-runs prompt names its effect at cols=$cols");
            like($sr, qr/stay(s)? up/i, "AC-6: stop-runs prompt says the container/machine stay(s) up at cols=$cols");
            like($sr, qr/\[y\] confirm/, "AC-6: stop-runs prompt has [y] confirm at cols=$cols");
            like($sr, qr/cancel/i, "AC-6: stop-runs prompt mentions cancel at cols=$cols");
        }
        else {
            fail("AC-6: stop-runs prompt names its effect at cols=$cols");
            fail("AC-6: stop-runs prompt says the container/machine stay(s) up at cols=$cols");
            fail("AC-6: stop-runs prompt has [y] confirm at cols=$cols");
            fail("AC-6: stop-runs prompt mentions cancel at cols=$cols");
        }

        my $fs = eval { tui::DashboardScreen::_confirm_prompt('full-shutdown', $cols) };
        ok(defined $fs, "AC-6: confirm_prompt('full-shutdown', $cols) is defined");
        if (defined $fs) {
            like($fs, qr/STOP (THIS )?CONTAINER/, "AC-6: full-shutdown prompt says STOP (THIS) CONTAINER at cols=$cols");
            like($fs, qr/machine/i, "AC-6: full-shutdown prompt mentions the machine at cols=$cols");
            like($fs, qr/\[y\] confirm/, "AC-6: full-shutdown prompt has [y] confirm at cols=$cols");
            like($fs, qr/cancel/i, "AC-6: full-shutdown prompt mentions cancel at cols=$cols");
        }
        else {
            fail("AC-6: full-shutdown prompt says STOP (THIS) CONTAINER at cols=$cols");
            fail("AC-6: full-shutdown prompt mentions the machine at cols=$cols");
            fail("AC-6: full-shutdown prompt has [y] confirm at cols=$cols");
            fail("AC-6: full-shutdown prompt mentions cancel at cols=$cols");
        }
    }
    is(eval { tui::DashboardScreen::_confirm_prompt('', 80) }, undef, "AC-6: confirm_prompt('', 80) is undef");
    is(eval { tui::DashboardScreen::_confirm_prompt('shutdown', 80) }, undef,
        "AC-6: confirm_prompt('shutdown', 80) (legacy token) is undef");

    # AC-7 (B7): compose_frame footer role selection.
    # RETARGETED 2026-08-08 (package 06-dashboard-screen, driver scope grant
    # E-B/E-D): package 02's Theme-token role vocabulary (spec 06 S2.1's
    # mapping table) moves 'footer-alert' -> 'state.crit' ("bad, alert,
    # footer-alert -> state.crit") and 'footer' -> 'text.faint' ("footer,
    # scrollhint -> text.faint"). Subject moved, claim held: this still
    # asserts the footer carries the ATTENTION role while a confirm prompt is
    # pending, and the ordinary/muted role otherwise.
    my %base = (project_name => 'demo', container => 'c1', status => 'running', events => []);
    for my $tok ('stop-runs', 'full-shutdown') {
        my %s = (%base, pending => $tok);
        my $f = Dashboard::compose_frame(\%s, 10, 80);
        is($f->[-1]{role}, 'state.crit',
            "AC-7: pending='$tok' -> footer role is state.crit (was footer-alert -- Theme token migration)");
        my $prompt = eval { tui::DashboardScreen::_confirm_prompt($tok, 80) };
        like($f->[-1]{text}, qr/\Q$prompt\E/, "AC-7: pending='$tok' -> footer text carries the confirm prompt")
            if defined $prompt;
        fail("AC-7: pending='$tok' -> footer text carries the confirm prompt") unless defined $prompt;
    }
    my %none = (%base, pending => '');
    my $f2 = Dashboard::compose_frame(\%none, 10, 80);
    is($f2->[-1]{role}, 'text.faint',
        'AC-7: no pending -> footer role is text.faint (was footer -- Theme token migration)');
    like($f2->[-1]{text}, qr/\[q\] quit/, 'AC-7: no pending -> legend text shown');
}

# ===========================================================================
# PART 3 -- stage plans: full_shutdown_plan / stop_runs_plan (AC-8 / B8)
# ===========================================================================
{
    my @pinned4 = (
        { id => 'signal-runs',     label => 'signal butler runs' },
        { id => 'await-quiet',     label => 'wait for runs to wind down' },
        { id => 'stop-container',  label => 'stop container' },
        { id => 'stop-machine',    label => 'stop podman machine' },
    );

    # full_shutdown_plan / stop_runs_plan do NOT exist yet -- every call is
    # wrapped in eval so a missing sub degrades to a clean per-assertion
    # FAIL, not a fatal abort.
    is_deeply(scalar(eval { Dashboard::full_shutdown_plan({ machine_capable => 1 }) }), \@pinned4,
        'AC-8: full_shutdown_plan({machine_capable=>1}) -> the 4 pinned stages, in order');
    is_deeply(scalar(eval { Dashboard::full_shutdown_plan({}) }), [ @pinned4[0, 1, 2] ],
        'AC-8: full_shutdown_plan({}) -> the first 3 stages only (machine_capable falsy)');
    is_deeply(scalar(eval { Dashboard::full_shutdown_plan(undef) }), [ @pinned4[0, 1, 2] ],
        'AC-8: full_shutdown_plan(undef) -> the first 3 stages only');
    is_deeply(scalar(eval { Dashboard::full_shutdown_plan({ machine_capable => 0 }) }), [ @pinned4[0, 1, 2] ],
        'AC-8: full_shutdown_plan({machine_capable=>0}) -> the first 3 stages only');

    is_deeply(scalar(eval { Dashboard::stop_runs_plan({ machine_capable => 1 }) }), [ @pinned4[0, 1] ],
        'AC-8: stop_runs_plan(anything) -> always exactly the first 2 stages');
    is_deeply(scalar(eval { Dashboard::stop_runs_plan(undef) }), [ @pinned4[0, 1] ],
        'AC-8: stop_runs_plan(undef) -> always exactly the first 2 stages');
    is_deeply(scalar(eval { Dashboard::stop_runs_plan({}) }), [ @pinned4[0, 1] ],
        'AC-8: stop_runs_plan({}) -> always exactly the first 2 stages');

    # Purity: identical input -> identical output on repeat calls.
    is_deeply(scalar(eval { Dashboard::full_shutdown_plan({ machine_capable => 1 }) }),
              scalar(eval { Dashboard::full_shutdown_plan({ machine_capable => 1 }) }),
        'AC-8: full_shutdown_plan is pure -- identical output on repeat calls');
    is_deeply(scalar(eval { Dashboard::stop_runs_plan({ x => 1 }) }), scalar(eval { Dashboard::stop_runs_plan({ x => 1 }) }),
        'AC-8: stop_runs_plan is pure -- identical output on repeat calls');

    # Prefix-consistency invariant (spec 2.3): stop_runs_plan(X) deep-equals
    # the first two elements of full_shutdown_plan(X).
    for my $x ({ machine_capable => 1 }, {}, undef, { machine_capable => 0 }) {
        my $sp = eval { Dashboard::stop_runs_plan($x) };
        my $fp = eval { Dashboard::full_shutdown_plan($x) };
        my $fp_prefix = (ref($fp) eq 'ARRAY') ? [ @{$fp}[0, 1] ] : undef;
        is_deeply($sp, $fp_prefix,
            'AC-8: stop_runs_plan(X) deep-equals the first two elements of full_shutdown_plan(X)');
    }

    # Source scan: no system/qx/backtick/exec inside either plan sub's body.
    my $src = slurp($DASHBOARD_SRC);
    ok(length($src) > 0, 'AC-8: Dashboard.pm is readable for the plan-purity source scan')
        or diag("expected at $DASHBOARD_SRC");
    for my $sub_name (qw(full_shutdown_plan stop_runs_plan)) {
        my $body = extract_sub_body($src, "sub $sub_name");
        if (defined $body) {
            my $stripped = $body;
            $stripped =~ s/#[^\n]*//g;
            unlike($stripped, qr/\bsystem\s*\(/, "AC-8: sub $sub_name body contains no system(...)");
            unlike($stripped, qr/`/,              "AC-8: sub $sub_name body contains no backtick");
            unlike($stripped, qr/\bqx\b/,          "AC-8: sub $sub_name body contains no qx");
            unlike($stripped, qr/\bexec\s*\(/,     "AC-8: sub $sub_name body contains no exec(...)");
        }
        else {
            fail("AC-8: sub $sub_name body contains no system(...) [sub not found in Dashboard.pm yet]");
            fail("AC-8: sub $sub_name body contains no backtick [sub not found]");
            fail("AC-8: sub $sub_name body contains no qx [sub not found]");
            fail("AC-8: sub $sub_name body contains no exec(...) [sub not found]");
        }
    }
}

# ===========================================================================
# PART 4 -- await_quiet (AC-9 / B9, B10, B11)
# ===========================================================================
{
    # B9: already-quiet on the FIRST poll -- no sleep, polls==1, waited==0.
    {
        my @sleeps;
        my $r = Dashboard::await_quiet(
            probe     => sub { 1 },
            now       => sub { 100 },
            sleep_for => sub { push @sleeps, $_[0]; },
        );
        is($r->{outcome}, 'already-quiet', 'AC-9/B9: truthy on first poll -> outcome already-quiet');
        is($r->{ok}, 1, 'AC-9/B9: already-quiet -> ok 1');
        is($r->{polls}, 1, 'AC-9/B9: already-quiet -> polls 1');
        is($r->{waited}, 0, 'AC-9/B9: already-quiet -> waited 0');
        is(scalar(@sleeps), 0, 'AC-9/B9: already-quiet -> sleep_for is NEVER called');
    }

    # B10: false twice then true -- exact poll/sleep counts, interval passed through.
    {
        my @results = (0, 0, 1);
        my $i = 0;
        my @sleeps;
        my $r = Dashboard::await_quiet(
            probe     => sub { return $results[$i++]; },
            now       => sub { 100 },   # never advances -- timeout never fires
            sleep_for => sub { push @sleeps, $_[0]; },
            interval  => 5,
            timeout   => 60,
        );
        is($r->{outcome}, 'quiet', 'AC-9/B10: false,false,true -> outcome quiet');
        is($r->{ok}, 1, 'AC-9/B10: quiet -> ok 1');
        is($r->{polls}, 3, 'AC-9/B10: quiet -> polls 3');
        is(scalar(@sleeps), 2, 'AC-9/B10: quiet -> sleep_for called exactly twice');
        is_deeply(\@sleeps, [5, 5], 'AC-9/B10: sleep_for called each time with the injected interval');
    }

    # B11: never quiet, fake clock jumps past timeout -- outcome timeout, ok 0.
    {
        my $t = 1000;
        my @sleeps;
        my $r = Dashboard::await_quiet(
            probe     => sub { 0 },
            now       => sub { $t },
            sleep_for => sub { push @sleeps, $_[0]; $t += 1000; },   # fake jump, no real time
            interval  => 1,
            timeout   => 10,
        );
        is($r->{outcome}, 'timeout', 'AC-9/B11: never quiet + fake clock past timeout -> outcome timeout');
        is($r->{ok}, 0, 'AC-9/B11: timeout -> ok 0');
        cmp_ok($r->{polls}, '>=', 1, 'AC-9/B11: timeout -> polls >= 1');
        cmp_ok($r->{waited}, '>=', 10, 'AC-9/B11: timeout -> waited >= timeout');
    }

    # no-probe: probe missing entirely -> outcome no-probe, polls 0, no sleep.
    {
        my @sleeps;
        my $r = Dashboard::await_quiet(now => sub { 100 }, sleep_for => sub { push @sleeps, $_[0]; });
        is($r->{outcome}, 'no-probe', 'AC-9: missing probe -> outcome no-probe');
        is($r->{ok}, 1, 'AC-9: no-probe -> ok 1');
        is($r->{polls}, 0, 'AC-9: no-probe -> polls 0');
        is(scalar(@sleeps), 0, 'AC-9: no-probe -> sleep_for never called');
    }

    # detail: hashref-form probe carries a detail string through verbatim.
    {
        my $r = Dashboard::await_quiet(probe => sub { { quiet => 1, detail => 'all quiet' } }, now => sub { 1 });
        is($r->{detail}, 'all quiet', 'AC-9: hashref-form probe detail is carried through on success');
    }

    # detail: a dying probe's error is appended (chomped, newline -> space).
    {
        my $i = 0;
        my $r = Dashboard::await_quiet(
            probe     => sub { $i++; die "boom\n" if $i < 2; return 1; },
            now       => sub { 100 },
            sleep_for => sub { },
            interval  => 1,
            timeout   => 60,
        );
        is($r->{outcome}, 'quiet', 'AC-9: a probe that dies once then succeeds still reaches quiet');
        like($r->{detail}, qr/boom/, 'AC-9: the last die message is folded into detail');
        unlike($r->{detail}, qr/\n/, 'AC-9: detail has no embedded newline (chomped, \\n -> space)');
    }

    # defaults: now defaults to real time, sleep_for defaults to a no-op,
    # timeout defaults to 60, interval defaults to 1 -- exercised WITHOUT
    # ever letting the loop actually iterate (already-quiet short-circuits
    # before any of the defaults matter for real time).
    {
        my $r = Dashboard::await_quiet(probe => sub { 1 });
        is($r->{outcome}, 'already-quiet', 'AC-9: defaulted now/sleep_for/timeout/interval do not disturb an immediate already-quiet result');
    }
}

# ===========================================================================
# PART 5 -- run_stages: order, guard, modes, timeouts, dual-channel, dying
#           seams (AC-10..AC-16 / B12-B19)
# ===========================================================================

# --- AC-10 (B12): full-shutdown happy path, exact call order. -------------
{
    my ($seams, $calls, $progress, $logs) = build_seams(self_container => 'self-container');
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams,
        self_container => 'self-container');
    is_deeply($calls, [qw(signal_runs quiet_probe stop_container list_containers stop_machine)],
        'AC-10: full-shutdown happy path -- exact seam-call order');
    is($result->{ok}, 1, 'AC-10: result.ok == 1');
    is($result->{machine_stopped}, 1, 'AC-10: machine_stopped == 1');
    is_deeply($result->{others}, [], 'AC-10: others == [] (only self enumerated)');
    is($result->{others_known}, 1, 'AC-10: others_known == 1');
    like($result->{summary}, qr/container stopped/i, 'AC-10: summary says container stopped');
    like($result->{summary}, qr/machine stopped/i, 'AC-10: summary says machine stopped');
}

# --- AC-11 (B13): machine guard fires -- others present. ------------------
{
    my ($seams, $calls) = build_seams(
        list_containers => sub { ['claude-me-deadbeef', 'other-thing']; },
        self_container  => 'claude-me-deadbeef',
    );
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams,
        self_container => 'claude-me-deadbeef');
    is_deeply($calls, [qw(signal_runs quiet_probe stop_container list_containers)],
        'AC-11: guard fires -- order stops after list_containers (stop_machine never invoked)');
    ok(!(grep { $_ eq 'stop_machine' } @$calls), 'AC-11: stop_machine is NEVER called');
    is($result->{machine_stopped}, 0, 'AC-11: machine_stopped == 0');
    is_deeply($result->{others}, ['other-thing'], 'AC-11: others == the one other container (self excluded)');
    my $mstage = stage_of($result, 'stop-machine');
    ok($mstage, 'AC-11: a stop-machine stage is present in the result');
    if ($mstage) {
        is($mstage->{state}, 'skipped', 'AC-11: stop-machine stage state is skipped');
        like($mstage->{detail}, qr/other container/i, 'AC-11: stop-machine detail says other container(s) running');
        like($mstage->{detail}, qr/other-thing/, 'AC-11: stop-machine detail names the offending container');
    }
    my $cstage = stage_of($result, 'stop-container');
    is($cstage->{state}, 'ok', 'AC-11: stop-container stage is still ok (the container DOES stop)') if $cstage;
    like($result->{summary}, qr/container stopped/i, 'AC-11: summary says container stopped');
    like($result->{summary}, qr/machine left running/i, 'AC-11: summary says machine left running');
}

# --- AC-11 (further): unfiltered enumeration, only self excluded by exact match. ---
{
    # Blank / whitespace-only entries are skipped; only the EXACT self_container
    # string is excluded -- nothing else is filtered (Decision #15: unfiltered).
    my ($seams) = build_seams(
        list_containers => sub { [ 'self', '', '   ', 'real-other' ]; },
        self_container  => 'self',
    );
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams, self_container => 'self');
    is_deeply($result->{others}, ['real-other'],
        'AC-11: blank/whitespace-only names are skipped; only self is excluded by exact string match');
}

# --- AC-11 (further): the offending-name cap at 3 + "+N more". ------------
{
    my @others_in = map { "container-$_" } (1 .. 5);
    my ($seams) = build_seams(
        list_containers => sub { [ 'self', @others_in ]; },
        self_container  => 'self',
    );
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams, self_container => 'self');
    is(scalar(@{ $result->{others} }), 5, 'AC-11: others carries ALL 5 other names (unfiltered), only self excluded');
    my $mstage = stage_of($result, 'stop-machine');
    if ($mstage) {
        like($mstage->{detail}, qr/\+2 more/, 'AC-11: detail caps the name list at 3 then "+N more"');
        for my $n (@others_in[0 .. 2]) {
            like($mstage->{detail}, qr/\Q$n\E/, "AC-11: detail names the offending container $n");
        }
    }
    like($result->{summary}, qr/\d/, 'AC-11: summary reports the other-container COUNT');
}

# --- AC-12 (B14): guard fails closed on an unusable enumeration. ----------
{
    for my $case (
        ['absent',       ABSENT],
        ['dying',        sub { die "enum boom\n" }],
        ['non-arrayref', sub { 'not-an-array' }],
    ) {
        my ($label, $impl) = @$case;
        my ($seams, $calls) = build_seams(list_containers => $impl, self_container => 'self');
        my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
        my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams, self_container => 'self');
        ok(!(grep { $_ eq 'stop_machine' } @$calls), "AC-12 [$label]: stop_machine is NEVER called");
        my $mstage = stage_of($result, 'stop-machine');
        ok($mstage, "AC-12 [$label]: a stop-machine stage is present");
        if ($mstage) {
            is($mstage->{state}, 'skipped', "AC-12 [$label]: stop-machine stage state is skipped");
            like($mstage->{detail}, qr/could not enumerate/, "AC-12 [$label]: detail matches /could not enumerate/");
        }
        is($result->{others_known}, 0, "AC-12 [$label]: others_known == 0");
    }
}

# --- AC-12 (B15): guard fails closed on a failed container stop. ----------
{
    my ($seams, $calls) = build_seams(stop_container => sub { { ok => 0, detail => 'boom' } }, self_container => 'self');
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams, self_container => 'self');
    is_deeply($calls, [qw(signal_runs quiet_probe stop_container)],
        'AC-12/B15: container-stop failed -- list_containers is NOT called, order stops at stop_container');
    ok(!(grep { $_ eq 'stop_machine' } @$calls), 'AC-12/B15: stop_machine is NOT called');
    my $mstage = stage_of($result, 'stop-machine');
    if ($mstage) {
        is($mstage->{state}, 'skipped', 'AC-12/B15: stop-machine stage state is skipped');
        like($mstage->{detail}, qr/container stop failed/, 'AC-12/B15: detail matches /container stop failed/');
    }
    is($result->{ok}, 0, 'AC-12/B15: result.ok == 0 (a real stage failed)');
    is($result->{others_known}, 0, 'AC-12/B15: others_known == 0 (enumeration never ran)');
}

# --- AC-13 (B16): stop-runs mode never touches podman. --------------------
{
    my ($seams, $calls) = build_seams(self_container => 'self');
    my $plan = Dashboard::stop_runs_plan({});
    my $result = Dashboard::run_stages(plan => $plan, mode => 'stop-runs', %$seams, self_container => 'self');
    is_deeply($calls, [qw(signal_runs quiet_probe)],
        'AC-13/B16: stop-runs mode calls ONLY signal_runs and quiet_probe');
    is($result->{machine_stopped}, 0, 'AC-13: stop-runs -> machine_stopped == 0');
    is_deeply($result->{others}, [], 'AC-13: stop-runs -> others == []');
    is($result->{others_known}, 0, 'AC-13: stop-runs -> others_known == 0');
    like($result->{summary}, qr/runs stopped/i, 'AC-13: summary matches /runs stopped/i');
    like($result->{summary}, qr/container .*(stays|left) (up|running)/i,
        'AC-13: summary says the container stays/is left up/running');
}

# --- AC-14 (B17): an await-quiet timeout does not abort the sequence. -----
{
    my $t = 1000;
    my ($seams, $calls) = build_seams(
        quiet_probe => sub { 0 },              # never quiet
        now         => sub { $t },
        sleep_for   => sub { $t += 100; },      # fake jump -- no real time
        self_container => 'self-container',
    );
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams,
        self_container => 'self-container', await_timeout => 5, await_interval => 1);
    ok(_seq_order_ok($calls, qw(signal_runs quiet_probe stop_container list_containers stop_machine)),
        'AC-14: later stages (stop_container, list_containers, stop_machine) still run in order after a timeout');
    my $astage = stage_of($result, 'await-quiet');
    is($astage->{state}, 'timeout', 'AC-14: await-quiet stage state is timeout') if $astage;
    is($result->{timed_out}, 1, 'AC-14: result.timed_out == 1');
    like($result->{summary}, qr/timed out/i, 'AC-14: summary matches /timed out/i');
    # the sequence still completed successfully otherwise
    is($result->{machine_stopped}, 1, 'AC-14: the machine still stops -- a timeout does not block later stages');
}

# --- AC-15 (B18): both channels, every stage; pinned event names/keys. ----
{
    my ($seams, $calls, $progress, $logs) = build_seams(self_container => 'self-container');
    my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });   # n = 4
    my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams,
        self_container => 'self-container');
    my $n = scalar(@$plan);
    is(scalar(@$progress), 2 * $n + 1, "AC-15: status_cb called exactly 2n+1 times (n=$n)");
    is(scalar(@$logs), $n + 2, "AC-15: log_cb called exactly n+2 times");

    is($logs->[0][0], 'lifecycle_start', 'AC-15: first log event is lifecycle_start');
    is($logs->[0][1]{mode}, 'full-shutdown', 'AC-15: lifecycle_start.mode');
    is($logs->[0][1]{stages}, $n, 'AC-15: lifecycle_start.stages == n (integer count)');

    for my $i (0 .. $n - 1) {
        my ($ev, $fields) = @{ $logs->[1 + $i] };
        is($ev, 'lifecycle_stage', "AC-15: stage log #$i event name is lifecycle_stage");
        is($fields->{mode}, 'full-shutdown', "AC-15: stage log #$i .mode");
        is($fields->{stage}, $plan->[$i]{id}, "AC-15: stage log #$i .stage matches plan order");
        is($fields->{index}, $i + 1, "AC-15: stage log #$i .index is 1-based");
        is($fields->{total}, $n, "AC-15: stage log #$i .total == n");
        ok((grep { $fields->{state} eq $_ } qw(ok fail skipped timeout)), "AC-15: stage log #$i .state is a pinned enum value");
        ok(defined $fields->{detail}, "AC-15: stage log #$i .detail is defined");
        for my $v (values %$fields) { ok(!ref($v), "AC-15: stage log #$i payload values are scalars (no nested refs)"); }
    }

    my ($lev, $lfields) = @{ $logs->[-1] };
    is($lev, 'lifecycle_done', 'AC-15: last log event is lifecycle_done');
    is($lfields->{mode}, 'full-shutdown', 'AC-15: lifecycle_done.mode');
    ok(defined $lfields->{ok}, 'AC-15: lifecycle_done.ok is defined');
    ok(defined $lfields->{timed_out}, 'AC-15: lifecycle_done.timed_out is defined');
    ok(defined $lfields->{summary} && length($lfields->{summary}), 'AC-15: lifecycle_done.summary is a non-empty string');
    ok(defined $lfields->{machine_stopped}, 'AC-15: lifecycle_done (full-shutdown) carries machine_stopped');
    ok(defined $lfields->{others}, 'AC-15: lifecycle_done (full-shutdown) carries others');
    ok(!ref($lfields->{others}), 'AC-15: lifecycle_done.others is a scalar COUNT, not an arrayref');
    ok(defined $lfields->{others_known}, 'AC-15: lifecycle_done (full-shutdown) carries others_known');

    is($progress->[-1]{active}, 0, 'AC-15: the FINAL status_cb call has active => 0');
    is($progress->[-1]{state}, 'done', 'AC-15: the FINAL status_cb call has state => done');
    ok(length($progress->[-1]{summary} // ''), 'AC-15: the FINAL status_cb call has a non-empty summary');
}
{
    # AC-15 (further): for stop-runs, lifecycle_done does NOT carry the
    # full-shutdown-only keys (spec 2.9: "plus, for full-shutdown only").
    my ($seams, $calls, $progress, $logs) = build_seams(self_container => 'self');
    my $plan = Dashboard::stop_runs_plan({});
    Dashboard::run_stages(plan => $plan, mode => 'stop-runs', %$seams, self_container => 'self');
    my ($lev, $lfields) = @{ $logs->[-1] };
    is($lev, 'lifecycle_done', 'AC-15: stop-runs -- last log event is lifecycle_done');
    ok(!exists $lfields->{machine_stopped}, 'AC-15: stop-runs lifecycle_done has NO machine_stopped key');
    ok(!exists $lfields->{others}, 'AC-15: stop-runs lifecycle_done has NO others key');
    ok(!exists $lfields->{others_known}, 'AC-15: stop-runs lifecycle_done has NO others_known key');
}

# --- AC-16 (B19): a dying seam never dies out. ----------------------------
{
    my @cases = (
        ['signal_runs',           'signal_runs',  'signal-runs'],
        ['await_quiet (override)','await_quiet',  'await-quiet'],
        ['stop_container',        'stop_container','stop-container'],
        ['stop_machine',          'stop_machine', 'stop-machine'],
    );
    for my $c (@cases) {
        my ($label, $seam_key, $stage_id) = @$c;
        my ($seams, $calls) = build_seams($seam_key => sub { die "boom\n" }, self_container => 'self-container');
        my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
        my $result = eval {
            Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams, self_container => 'self-container');
        };
        my $err = $@;
        ok(!$err, "AC-16 [$label]: run_stages does not die (\$@ = " . ($err // '') . ')');
        if (ref($result) eq 'HASH') {
            pass("AC-16 [$label]: returns a well-formed hashref result");
            my $st = stage_of($result, $stage_id);
            ok($st, "AC-16 [$label]: stage '$stage_id' is present in the result");
            if ($st) {
                is($st->{state}, 'fail', "AC-16 [$label]: stage '$stage_id' is marked fail");
                like($st->{detail}, qr/boom/, "AC-16 [$label]: stage detail carries the error text ('boom')");
            }
            else {
                fail("AC-16 [$label]: stage '$stage_id' is marked fail (stage not found)");
                fail("AC-16 [$label]: stage detail carries the error text (stage not found)");
            }
        }
        else {
            fail("AC-16 [$label]: returns a well-formed hashref result");
            fail("AC-16 [$label]: stage '$stage_id' is present in the result");
            fail("AC-16 [$label]: stage '$stage_id' is marked fail");
            fail("AC-16 [$label]: stage detail carries the error text");
        }
    }
    # remaining stages still run despite an earlier failure (signal_runs case):
    # the sequence is not aborted just because an early, non-guarded stage failed.
    {
        my ($seams, $calls) = build_seams(signal_runs => sub { die "boom\n" }, self_container => 'self-container');
        my $plan = Dashboard::full_shutdown_plan({ machine_capable => 1 });
        my $result = Dashboard::run_stages(plan => $plan, mode => 'full-shutdown', %$seams, self_container => 'self-container');
        ok(_seq_order_ok($calls, qw(signal_runs quiet_probe stop_container list_containers stop_machine)),
            'AC-16: signal_runs dying still lets quiet_probe/stop_container/list_containers/stop_machine run in order');
    }
}

# ===========================================================================
# PART 6 -- Dashboard::run loop integration (AC-17, AC-18 / B20, B21)
# ===========================================================================

# drive2: like t/25's drive(), but wires the NEW stop_runs/full_shutdown
# seams (spec 2.7) instead of the retired write_signals seam, and captures
# every individual $out call (not just the concatenation) so AC-18 can
# inspect each frame's synchronized-output wrapper.
sub drive2 {
    my (%args) = @_;
    my @keys = @{ $args{keys} || [] };
    my $clock = 1000;
    my %eff = (stop_runs_calls => 0, full_shutdown_calls => 0, frames => 0);
    my @out_calls;

    my $rc = Dashboard::run(
        beat_interval  => $args{beat_interval}  // 9999,
        state_interval => $args{state_interval} // 999,
        tick_interval  => 0.25,
        color          => 0,
        max_ticks      => $args{max_ticks} // 20,
        now            => sub { $clock },
        sleep_for      => sub { $clock += $_[0]; },   # fake clock -- no real time
        read_key       => sub { @keys ? shift @keys : undef },
        term_size      => sub { ($args{cols} // 80, $args{rows} // 24) },
        gather         => sub { { project_name => 'demo', container => 'c1', status => 'running', events => [] } },
        heartbeat      => sub { 'ok' },
        spawn          => sub { undef },
        write_signals  => sub { 1 },   # run() must tolerate this unknown/legacy key
        stop_runs      => sub {
            my ($state, $progress) = @_;
            $eff{stop_runs_calls}++;
            return { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                      machine_stopped => 0, others => [], others_known => 0,
                      summary => 'stop-runs ok' };
        },
        full_shutdown  => sub {
            my ($state, $progress) = @_;
            $eff{full_shutdown_calls}++;
            for my $i (1 .. ($args{progress_ticks} // 0)) {
                $progress->({ active => 1, mode => 'full-shutdown', stage => "stage$i", label => "label$i",
                              index => $i, total => ($args{progress_ticks} // 0), state => 'running', detail => '' });
            }
            $progress->({ active => 0, mode => 'full-shutdown', state => 'done', index => 0, total => 0,
                          summary => 'TESTMARKER123' });
            return { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                      machine_stopped => 1, others => [], others_known => 1, summary => 'TESTMARKER123' };
        },
        enter_raw => sub { },
        leave_raw => sub { },
        keepawake => sub { },
        out       => sub { push @out_calls, $_[0]; $eff{frames}++; },
    );
    $eff{rc}        = $rc;
    $eff{out}       = join('', @out_calls);
    $eff{out_calls} = \@out_calls;
    return \%eff;
}

# --- AC-17 (B20): neither lifecycle action exits the loop. ----------------
{
    my $e = drive2(keys => ['s', 'y', 'x', 'y', 'q'], max_ticks => 50);
    is($e->{rc}, 0, 'AC-17: q exits with rc 0 after s,y and x,y');
    is($e->{stop_runs_calls}, 1, 'AC-17: stop_runs seam called exactly once');
    is($e->{full_shutdown_calls}, 1, 'AC-17: full_shutdown seam called exactly once');
}
{
    my $e = drive2(keys => ['s', 'y'], max_ticks => 3);
    is($e->{rc}, 0, 'AC-17: without q, the loop reaches max_ticks (rc 0) -- stop-runs did not end it');
    is($e->{stop_runs_calls}, 1, 'AC-17: stop_runs still fired once even though the loop kept running');
}

# --- AC-18 (B21): the loop's $progress coderef repaints between stages. --
{
    my $base     = drive2(keys => ['x', 'y', 'q'], max_ticks => 50, progress_ticks => 0);
    my $withprog = drive2(keys => ['x', 'y', 'q'], max_ticks => 50, progress_ticks => 3);
    cmp_ok($withprog->{frames} - $base->{frames}, '>=', 3,
        'AC-18: 3 mid-sequence progress calls -> at least 3 additional $out writes during the drain');

    # ONE named, documented exception (s07-live-status Decision #8,
    # Dashboard.pm:3017-3026): the OSC window-title emit is its OWN $out call and
    # is deliberately NOT wrapped -- an OS window-title escape cannot live inside
    # a TUI frame-sync marker.  window_title() guarantees
    # /\A[\x20-\x7E]{1,80}\z/, so the whole call is exactly this shape.  The
    # pattern is FULLY anchored (\A/\z, not ^/$) so no multi-line render fragment
    # and no merely-OSC-prefixed string can slip through.  The wrap-check itself
    # is unchanged; nothing else is excused.
    # PAYLOAD CLASS WIDENED 2026-08-25, NARROWNESS PRESERVED. The title's lead
    # character now animates through the ten braille frames, so the payload is
    # no longer pure ASCII and /[\x20-\x7E]/ rejected a legitimate emit. What
    # this exception must never admit is a RENDER FRAGMENT smuggled inside OSC
    # delimiters -- and every render fragment contains ESC (\x1B), so excluding
    # control bytes keeps the counter-fixture below passing for the same reason
    # the ASCII class did. The project name, where operator-supplied text
    # enters, is still hard-clamped to ASCII inside window_title itself.
    my $OSC_TITLE = qr/\A\e\]0;[^\x00-\x1F\x7F]*\a\z/;
    my $unwrapped = sub {
        return scalar grep { $_ !~ $OSC_TITLE && (!/^\e\[\?2026h/ || !/\e\[\?2026l$/) } @_;
    };
    my $bad = $unwrapped->(@{ $withprog->{out_calls} });
    is($bad, 0, 'AC-18: every $out call except the named OSC window-title emit is wrapped in \\e[?2026h ... \\e[?2026l (synchronized output)');

    # The exception must be NARROW.  Feed the SAME check two deliberately
    # unwrapped synthetic calls: one that is not OSC at all, and one that starts
    # with the OSC introducer but is not a valid title emit (trailing bytes after
    # the BEL).  Both must still be counted bad, and the delta must be exactly 2
    # -- i.e. attributable to the fakes, not to any real call.
    my $bad_aug = $unwrapped->(@{ $withprog->{out_calls} }, "\e[1;1Hnot a frame", "\e]0;fake\aTRAILING", "\e]0;\e[1;1Hx\e[Ky\a");
    is($bad_aug, $bad + 3,
        'AC-18-exception-is-narrow: a deliberately-unwrapped non-OSC $out call, an OSC-prefixed near-miss, AND an OSC-delimited call whose payload smuggles a render fragment are ALL still caught (pins the [\x20-\x7E] payload class, not just the \z anchor)');
}

# ===========================================================================
# PART 7 -- lifecycle_alert_msg + _alert_msgs precedence (AC-19 / B22)
# ===========================================================================
{
    is(Dashboard::lifecycle_alert_msg({}), undef, 'AC-19: no lifecycle key -> undef');
    is(Dashboard::lifecycle_alert_msg({ lifecycle => 'not a hashref' }), undef,
        'AC-19: non-hashref lifecycle value -> undef');
    is(Dashboard::lifecycle_alert_msg(undef), undef, 'AC-19: undef state -> undef (never dies)');
    is(Dashboard::lifecycle_alert_msg('not a hashref either'), undef,
        'AC-19: non-hashref state -> undef (never dies)');

    my $active = Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 1, mode => 'full-shutdown', index => 3, total => 4,
        stage => 'stop-container', label => 'stop container', state => 'running',
    } });
    is($active, 'full shutdown 3/4: stop container - running',
        'AC-19: active message matches the pinned example format exactly');

    my $active_sr = Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 1, mode => 'stop-runs', index => 1, total => 2,
        stage => 'signal-runs', label => 'signal butler runs', state => 'running',
    } });
    is($active_sr, 'stop runs 1/2: signal butler runs - running',
        'AC-19: mode label "stop-runs" -> "stop runs"');

    my $done = Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 0, mode => 'stop-runs', summary => 'runs stopped; container stays up',
    } });
    is($done, 'stop runs done: runs stopped; container stays up',
        'AC-19: finished message is "<mode label> done: <summary>"');

    # missing keys degrade to '?' rather than dying.
    my $partial = eval { Dashboard::lifecycle_alert_msg({ lifecycle => { active => 1, mode => 'stop-runs' } }) };
    ok(!$@, 'AC-19: missing index/total/stage/label never dies');
    like($partial // '', qr/\?/, 'AC-19: missing index/total/stage/label degrade to "?"');

    # a pre-capped name list riding through `summary` passes through unchanged
    # (the cap-at-3+N-more duty is exercised end-to-end via run_stages/AC-11;
    # lifecycle_alert_msg's own job is not to re-truncate or otherwise mangle
    # a summary/detail string it is simply relaying -- see report note).
    my $capped = Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 0, mode => 'full-shutdown',
        summary => 'container stopped; machine left running: c1, c2, c3, +2 more',
    } });
    like($capped, qr/\+2 more/, 'AC-19: a pre-capped name list embedded in summary passes through unchanged');

    # _alert_msgs precedence: lifecycle_alert_msg is FIRST.
    my %state = (
        lifecycle => { active => 1, mode => 'stop-runs', index => 1, total => 2,
                       stage => 'signal-runs', label => 'signal butler runs', state => 'running' },
        status => 'exited',
        install_warning => 'backpack install FAILED',
    );
    my @msgs = Dashboard::_alert_msgs(\%state, 20);
    ok(scalar(@msgs) >= 1, 'AC-19: _alert_msgs returns at least one message with lifecycle+status+install_warning present');
    like($msgs[0], qr/stop runs 1\/2: signal butler runs - running/,
        'AC-19: lifecycle_alert_msg is the FIRST (highest-priority) message in _alert_msgs');
}

# --- AC-19 (further): 'refresh' clears $state{lifecycle} in the loop. -----
{
    my $e = drive2(keys => ['x', 'y', 'r', undef, 'q'], max_ticks => 50, progress_ticks => 0);
    my @out_calls = @{ $e->{out_calls} };
    my ($marker_idx) = grep { $out_calls[$_] =~ /TESTMARKER123/ } 0 .. $#out_calls;
    ok(defined $marker_idx, 'AC-19: the full-shutdown summary marker appears in a frame before refresh');
    if (defined $marker_idx) {
        my $after_r = join('', @out_calls[$marker_idx + 1 .. $#out_calls]);
        unlike($after_r, qr/TESTMARKER123/, 'AC-19: refresh (r) clears the lifecycle banner from subsequent frames');
    }
    else {
        fail('AC-19: refresh (r) clears the lifecycle banner from subsequent frames (marker never appeared)');
    }
}

# ===========================================================================
# PART 8 -- render invariant (Decision #12, hard gate) (AC-20 / B23)
# ===========================================================================
{
    for my $cols (40, 80, 100, 200) {
        my $rows = 24;
        my %st = (
            project_name => 'demo', container => 'claude-demo-abcd1234', status => 'running',
            events => [], beat_age => 1, uptime => 10,
            lifecycle => {
                active => 1, mode => 'full-shutdown', index => 3, total => 4,
                stage => 'stop-container', label => 'stop container', state => 'running',
                detail => ('a very long detail string that is far longer than any terminal ' x 5),
            },
        );
        my $f = Dashboard::compose_frame(\%st, $rows, $cols);
        is(scalar(@$f), $rows, "AC-20: frame has exactly $rows rows at cols=$cols (lifecycle banner + overlong detail)");
        my $bad = grep { Dashboard::display_width($_->{text}) != $cols } @$f;
        is($bad, 0, "AC-20: EVERY cell is exactly $cols display columns wide at cols=$cols");

        my @bad_spans = grep { !$_->{spans} || ref($_->{spans}) ne 'ARRAY' || !@{ $_->{spans} } } @$f;
        is(scalar(@bad_spans), 0, "AC-20: every cell (incl. the lifecycle alert row) has a non-empty spans arrayref at cols=$cols");

        my $full = Dashboard::render_frame(undef, $f, { color => 0 });
        like($full, qr/^\e\[\?2026h/, "AC-20: render_frame (no prev) opens with the sync-output wrapper at cols=$cols");
        like($full, qr/\e\[\?2026l$/, "AC-20: render_frame (no prev) closes with the sync-output wrapper at cols=$cols");

        my $f2 = Dashboard::compose_frame(\%st, $rows, $cols);   # identical state -> identical frame
        my $diff = Dashboard::render_frame($f, $f2, { color => 0 });
        unlike($diff, qr/\e\[2J/, "AC-20: identical successive frames -> no full clear (per-row diff preserved) at cols=$cols");
        like($diff, qr/^\e\[\?2026h/, "AC-20: diff render still opens with the sync-output wrapper at cols=$cols");
        like($diff, qr/\e\[\?2026l$/, "AC-20: diff render still closes with the sync-output wrapper at cols=$cols");

        # lifecycle alert renders BEFORE a coexisting status alert.
        # RETARGETED 2026-08-08 (package 06-dashboard-screen, driver scope
        # grant E-B/E-D): the CELL-level 'alert' role also moves under Theme
        # token adoption -- spec 06 S2.1's mapping table ("bad, alert,
        # footer-alert -> state.crit") applies to banner/alert rows just as
        # it does to spans; confirmed against tui::Screen's screen()
        # composition (spec 06 S2.4.9: banner_role => 'state.crit'). Subject
        # moved, claim held: still counting the banner rows by role.
        my %st2 = (%st, status => 'exited');
        my $f3 = Dashboard::compose_frame(\%st2, $rows, $cols);
        # BY SPAN ROLE, NOT ROW ROLE. Banners render into the SIDE COLUMN at
        # widths that have one (operator request, 2026-08-25) rather than as
        # full-width rows above the panels. _join_row_cells gives a joined row
        # the LEFT cell's role, so a side-column banner's row is no longer
        # role 'state.crit' even though its own spans still are -- the old
        # row-level filter simply stopped seeing them at cols=200. Looking at
        # the spans finds a banner in either placement, which is what these
        # assertions were always about; t/105 owns WHERE it lands.
        my @alerts = grep {
            # A banner-role span that is JUST THE STATUS WORD belongs to the
            # title row's own status block, not to a banner. Row 0 has to be
            # examined (the side column starts there, so a banner can live on
            # it) but its header carries state.crit for "exited" -- excluding
            # the row wholesale loses real banners, and including it blindly
            # counts the header as one. Discriminate on the SPAN, which is
            # exact: a status word is a closed vocabulary, a banner is prose.
            ref($_->{spans}) eq 'ARRAY'
                ? scalar(grep { ($_->{role} // '') eq 'state.crit'
                                && ($_->{text} // '') !~ /\A(?:running|exited|stopped|paused|created|restarting|stopping|dead|removing|unknown|\?)\z/ }
                         @{ $_->{spans} })
                : ($_->{role} // '') eq 'state.crit'
        } map { _strip_title_status($_, $_ == $f3->[0]) } @{$f3}[ 0 .. $#{$f3} - 1 ];
        # AMENDED by package d02-wrap-every-surface, Decision D1
        # (specs/d02-wrap-every-surface-spec.md, Section 0): banners now wrap
        # instead of truncate, so "one row per banner" stopped being a valid
        # proxy for "how many banners are present" -- at cols=40 these two
        # banners occupy 5 rows, at cols=80 they occupy 3 (driver-verified
        # against tui::Screen::compose directly: total frame rows stayed
        # exactly $rows in every case, so nothing is lost, it is just spread
        # across more rows). The intent of the original assertion -- "the
        # lifecycle alert and the status alert both surface, distinct from
        # one another" -- is preserved by counting banner-START rows instead
        # of raw rows.
        # RE-AMENDED, fix-batch step 7 (reviewer MUST-FIX #1): the previous
        # unanchored `/!! /` text scan over-counts when a CONTINUATION row's
        # own wrapped content happens to contain "!! " -- see
        # count_banner_starts's doc comment (top of this file) for the full
        # derivation, including why the reviewer's own suggested anchored
        # `/^!! /` fix is ALSO wrong (undercounts a wrapped+unwrapped banner
        # pair). Use the structural discriminator instead.
        my $banner_starts = count_banner_starts(\@alerts);
        is($banner_starts, 2,
            "AC-20: lifecycle + status alerts coexist as two banners (banner-start rows, not raw rows) at cols=$cols");
        # Ordering is asserted with a WIDTH-SAFE discriminator. The pinned message
        # (spec S2.6) is "full shutdown 3/4: stop container - running" = 42 cols, and
        # _alert_line prefixes "  !! " (5) for 47 -- so at cols=40 clip_pad MUST
        # truncate it to "  !! full shutdown 3/4: stop container -". Matching the
        # "- running" tail there would contradict the render invariant asserted 20
        # lines up (every cell exactly $cols, which passes). "full shutdown 3/4"
        # fits at every width and still discriminates the lifecycle banner from the
        # status alert ("container is exited ..."), which is what this AC is about.
        like($alerts[0]{text}, qr{full shutdown 3/4},
            "AC-20: the lifecycle alert is the FIRST alert row (before the status alert) at cols=$cols") if @alerts;
        # The full pinned detail is still asserted wherever it actually fits --
        # but ACROSS the banner's rows, not within one of them.
        #
        # "wherever it fits" used to mean cols >= 80, because a full-width
        # banner at 80 columns had room for the whole phrase on one row. Banners
        # now render into the side column at widths that have one, and that
        # column is ~39 columns wide regardless of how wide the terminal is --
        # so at cols=200 the phrase wraps and no single row carries it. That is
        # wrapping working, not detail being lost, and the distinction is the
        # whole point: joining the banner-role spans across the banner's rows
        # asserts the text SURVIVED, which is the claim, while leaving where the
        # line breaks fall to the wrap engine.
        my $joined = join '', map {
            my $s = ref($_->{spans}) eq 'ARRAY' ? $_->{spans} : [];
            join '', map { defined($_->{text}) ? $_->{text} : '' }
                     grep { ($_->{role} // '') eq $BANNER_ROLE } @$s;
        } @alerts;
        $joined =~ s/\s+/ /g;
        like($joined, qr/stop container - running/,
            "AC-20: the lifecycle alert carries the full pinned detail across its rows at cols=$cols")
            if @alerts && $cols >= 80;
    }
}

# ===========================================================================
# count_banner_starts pin (fix-batch step 7, MUST-FIX #1) -- same two
# fixtures pinned in t/25-dashboard.t, exercised here too since THIS file's
# own PART 8 assertion (immediately above) is the other amended call site
# the reviewer flagged.
# ===========================================================================
{
    my %st = (
        project_name => 'demo', container => 'claude-demo-abcd1234', status => 'running',
        events => [], beat_age => 1, uptime => 10,
    );

    # Reviewer's repro, generalized: an install_warning whose text pushes
    # "urgent!!" onto a wrapped CONTINUATION row must not inflate the count
    # of ONE real banner into two.
    my $urgent_text = 'padding words to push the marker off the first '
        . 'wrapped row into a continuation line padding words to push the '
        . 'marker off the first wrapped row into a continuation line '
        . 'urgent!! check this now please and thanks';
    for my $cols (40, 80) {
        my %one = (%st, install_warning => $urgent_text);
        my $fo = Dashboard::compose_frame(\%one, 12, $cols);
        my @ao = grep {
            # A banner-role span that is JUST THE STATUS WORD belongs to the
            # title row's own status block, not to a banner. Row 0 has to be
            # examined (the side column starts there, so a banner can live on
            # it) but its header carries state.crit for "exited" -- excluding
            # the row wholesale loses real banners, and including it blindly
            # counts the header as one. Discriminate on the SPAN, which is
            # exact: a status word is a closed vocabulary, a banner is prose.
            ref($_->{spans}) eq 'ARRAY'
                ? scalar(grep { ($_->{role} // '') eq 'state.crit'
                                && ($_->{text} // '') !~ /\A(?:running|exited|stopped|paused|created|restarting|stopping|dead|removing|unknown|\?)\z/ }
                         @{ $_->{spans} })
                : ($_->{role} // '') eq 'state.crit'
        } @{$fo}[ 0 .. $#{$fo} - 1 ];
        is(count_banner_starts(\@ao), 1,
            "AC-20 (fix-batch step 7): one real banner with an urgent!! continuation trap still counts as ONE at cols=$cols");
    }

    # The `/^!! /`-anchor trap: a WRAPPED banner (status alert, loses its
    # leading indent on row 0) and an UNWRAPPED banner (install_warning,
    # keeps its leading indent) in the SAME frame must both count once.
    my %mixed = (%st, status => 'exited', install_warning => 'backpack install FAILED');
    my $fm = Dashboard::compose_frame(\%mixed, 12, 80);
    my @am = grep {
        ref($_->{spans}) eq 'ARRAY'
            ? scalar(grep { ($_->{role} // '') eq 'state.crit' } @{ $_->{spans} })
            : ($_->{role} // '') eq 'state.crit'
    } @{$fm}[ 0 .. $#{$fm} - 1 ];
    is(count_banner_starts(\@am), 2,
        'AC-20 (fix-batch step 7): a wrapped banner and an unwrapped banner together still count as TWO');
}

# ===========================================================================
# PART 9 -- launcher.pl wiring: source-text assertions (AC-21 / B24)
#
# launcher.pl is NEVER require'd/do'ne here -- these are source-text
# assertions standing in for launcher-side impure behaviour that cannot be
# unit-tested without a real podman/container (spec S7's stated limitation).
# ===========================================================================
{
    my $src = slurp($LAUNCHER_SRC);
    ok(length($src) > 0, 'AC-21: launcher.pl is readable on disk') or BAIL_OUT("cannot read $LAUNCHER_SRC");

    like($src, qr/Dashboard::run\s*\(/, 'AC-21: launcher.pl calls Dashboard::run(');
    my $run_call = extract_call_block($src, 'Dashboard::run(');
    ok(defined $run_call, 'AC-21: the Dashboard::run( ... ) call block is balanced/extractable');
    if (defined $run_call) {
        like($run_call, qr/\bstop_runs\s*=>/, 'AC-21: Dashboard::run( block contains "stop_runs =>"');
        like($run_call, qr/\bfull_shutdown\s*=>/, 'AC-21: Dashboard::run( block contains "full_shutdown =>"');
    }
    else {
        fail('AC-21: Dashboard::run( block contains "stop_runs =>" (call block not found)');
        fail('AC-21: Dashboard::run( block contains "full_shutdown =>" (call block not found)');
    }

    like($src, qr/\bmachine_capable\b/, 'AC-21: launcher.pl source contains "machine_capable" (added to gather)');

    my $lr_body = extract_sub_body($src, 'sub _lifecycle_run');
    if (defined $lr_body) {
        like($lr_body, qr/\$PODMAN\s+ps\s+--format\s+"\{\{\.Names\}\}"/,
            'AC-21: _lifecycle_run\'s list_containers seam uses `$PODMAN ps --format "{{.Names}}"`');
        unlike($lr_body, qr/\bps\s+-a\b/,
            'AC-21: _lifecycle_run body never uses `ps -a` (must enumerate RUNNING containers only)');
        unlike($lr_body, qr/--filter/,
            'AC-21: _lifecycle_run body applies no --filter to the enumeration (Decision #15: unfiltered)');
        if ($lr_body =~ /_keepawake_release_global\s*\(\s*\)\s*;(.*?)\$PODMAN\s+stop/s) {
            pass('AC-21: _keepawake_release_global() precedes the $PODMAN stop invocation in the stop_container seam');
        }
        else {
            fail('AC-21: _keepawake_release_global() precedes the $PODMAN stop invocation in the stop_container seam');
        }
    }
    else {
        fail('AC-21: sub _lifecycle_run exists in launcher.pl (list_containers uses ps, no -a)');
        fail('AC-21: _lifecycle_run body never uses `ps -a` (sub not found)');
        fail('AC-21: _lifecycle_run body applies no --filter (sub not found)');
        fail('AC-21: _keepawake_release_global precedes $PODMAN stop (sub not found)');
    }

    unlike($src, qr/shutdown_all/, 'AC-21: the string "shutdown_all" no longer appears anywhere in launcher.pl');
}

done_testing();
