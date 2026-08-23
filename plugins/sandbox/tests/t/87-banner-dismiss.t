#!/usr/bin/env perl
# 87-banner-dismiss.t -- ORACLE for package t03-banner-dismiss (blueprint
# butler-and-dashboard-overhaul), specs/t03-banner-dismiss-spec.md. Written
# BLIND to any dismiss-key implementation in Dashboard.pm / DashboardScreen.pm
# / launcher.pl -- straight from the spec's numbered observable behaviors
# (S3) and acceptance criteria (S4, AC1-AC6). Do NOT weaken an assertion here
# to make a future implementation's life easier.
#
# TODAY'S EXPECTED STATE (measured 2026-08-14, before this package's edit):
#   - launcher.pl still carries the trailing "- run /backpack:install in the
#     session to <verb>" instruction at both $INSTALL_WARNING sites.
#   - tui::DashboardScreen::_banner_lines appends no '[d] dismiss' hint.
#   - Dashboard::dispatch_key has no 'd' mapping at all -- ('d', $pending)
#     falls through to the same inert ('', $pending) as any other unknown key.
#   - Dashboard::run's main loop has no dismiss action branch and no
#     $install_warning_dismissed lexical -- a gathered install_warning is
#     never suppressed and reappears on every regather.
# So PART 1-5 below are expected RED; PART 6 (guard/regression assertions
# that already hold today, demanded by the spec so the ruling can't silently
# widen or narrow later) is expected GREEN both before and after -- flagged
# per-block, not hidden.
#
# NON-VACUITY: every "the banner is gone" claim is paired with a "the banner
# WAS there before" liveness assertion in the SAME block (never assumed), and
# every "no such control exists" claim is paired with a positive control
# proving the detection mechanism actually fires on a hand-built counter-
# fixture that SHOULD trip it.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

my $LAUNCHER_PL = "$Bin/../../scripts/launcher.pl";
my $DASHBOARD_PM = "$Bin/../../scripts/Dashboard.pm";
my $DASHSCR_PM   = "$Bin/../../scripts/tui/DashboardScreen.pm";

my $DASH_OK = eval { require Dashboard; 1 };
ok($DASH_OK, 'plugins/sandbox/scripts/Dashboard.pm loads') or diag("  require Dashboard failed: $@");
my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'plugins/sandbox/scripts/tui/DashboardScreen.pm loads') or diag("  require tui::DashboardScreen failed: $@");

sub slurp {
    my ($f) = @_;
    open my $fh, '<:raw', $f or die "cannot open $f: $!";
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# ===========================================================================
# PART 1 -- AC2 (done criterion 2): trailing instruction dropped at BOTH
# $INSTALL_WARNING sites, and left untouched at the four out-of-scope sites.
# Spec S2.1: "declared items never reached install - run /backpack:install
# in the session to reconcile" -> "declared items never reached install";
# "some items failed - run /backpack:install in the session to retry" ->
# "some items failed". Text search rather than a line-number citation,
# because the ledger's own line numbers have already drifted twice during
# this package's authoring (spec S1 table) -- pinning line numbers here
# would make the oracle brittle to the exact same drift, not resistant to it.
# ===========================================================================
{
    my $src = slurp($LAUNCHER_PL);

    unlike($src,
        qr/run \/backpack:install in the session to reconcile/,
        'AC2: the "reconcile" trailing instruction is gone from launcher.pl entirely');
    unlike($src,
        qr/run \/backpack:install in the session to retry/,
        'AC2: the "retry" trailing instruction is gone from launcher.pl entirely');

    # AMENDED BY t05-no-colons. The separator inside these two sentences is
    # now " - " (operator: "we use way too many instances of the character
    # `:`. Its distracting. We need none of them."). The INTENT is unchanged
    # and is what the description says: the warning is the bare sentence,
    # semicolon-terminated, with no dangling instruction after it -- the two
    # `unlike` checks above are what enforce the "no dangling instruction"
    # half, and they are untouched. Only the separator inside the sentence
    # moved.
    like($src,
        qr/\$INSTALL_WARNING\s*=\s*'backpack install - declared items never reached install';/,
        'AC2: the reconcile-mismatch $INSTALL_WARNING is now the bare sentence, semicolon-terminated (no dangling instruction)');
    like($src,
        qr/\$INSTALL_WARNING\s*=\s*'backpack install - some items failed';/,
        'AC2: the some-items-failed $INSTALL_WARNING is now the bare sentence, semicolon-terminated (no dangling instruction)');

    # Counter-fixture (hand-built, not the production source): proves the
    # unlike() regexes above are not vacuously passing because they are
    # shaped wrong -- fed a string carrying the anti-pattern, they must
    # match it.
    my $cf = "\$INSTALL_WARNING = 'backpack install: some items failed - run /backpack:install in the session to retry';";
    like($cf, qr/run \/backpack:install in the session to retry/,
        'AC2 non-vacuity: the trailing-instruction detector fires on a hand-built string carrying the anti-pattern');
}

# ===========================================================================
# PART 1b -- the four sites the spec rules OUT of scope must stay untouched.
# Guard against the ruling being silently widened OR narrowed later (spec
# S4 AC2). These pass both before and after this package's edit -- they are
# not claiming new (red) coverage, only pinning the boundary of the change.
# ===========================================================================
{
    my $src = slurp($LAUNCHER_PL);
    like($src,
        qr/\$INSTALL_WARNING\s*=\s*'backpack present but host backpack\.pl missing - install skipped';/,
        'AC2 scope guard: "backpack present but host backpack.pl missing" site is unchanged (no action verb, ruled out of scope)');
    like($src,
        qr/\$INSTALL_WARNING\s*=\s*'backpack\.json failed validation - install skipped \(see launch transcript\)';/,
        'AC2 scope guard: "backpack.json failed validation" site is unchanged (parenthetical is a pointer, not an instruction)');
    like($src,
        qr/\$INSTALL_WARNING\s*=\s*'backpack\.pl not mounted in container - install skipped';/,
        'AC2 scope guard: "backpack.pl not mounted" site is unchanged');
    like($src,
        qr/\$INSTALL_WARNING\s*=\s*'could not write backpack install-set - install skipped';/,
        'AC2 scope guard: "could not write backpack install-set" site is unchanged');
}

# ===========================================================================
# PART 2 -- AC4/AC5 (done criteria 4, 5): tui::DashboardScreen::_banner_lines
# gets the '[d] dismiss' hint attached ONLY to a present install_warning,
# never to lifecycle/status alerts, and the three-source composition/order
# is otherwise unchanged (spec S2.2, observable behaviors 2-4).
# ===========================================================================
SKIP: {
    skip('tui::DashboardScreen did not load', 8) unless $DS_OK;

    # Behavior 3: nothing present -> [] (unaffected by this package).
    is_deeply(tui::DashboardScreen::_banner_lines({}), [],
        'AC5 baseline: _banner_lines({}) is still [] -- absence stays absence');

    # Behavior 2: install_warning alone -> one line, prefix + literal suffix.
    my $one = tui::DashboardScreen::_banner_lines({ install_warning => 'backpack install: some items failed' });
    is_deeply($one,
        ['  !! backpack install: some items failed  [d] dismiss'],
        'AC4/behavior 2: _banner_lines with only install_warning appends the literal "  [d] dismiss" suffix to the one rendered line');

    # AC4, discoverability: the literal substring is present (redundant with
    # the above is_deeply, kept as an independently-named, narrower assertion
    # per AC4's own wording -- "the rendered banner line itself contains the
    # literal substring [d] dismiss").
    like($one->[0], qr/\Q[d] dismiss\E/,
        'AC4: the install-warning banner line contains the literal discoverability hint "[d] dismiss"');

    # Behavior 4 / AC5: lifecycle + install_warning together -> TWO lines,
    # lifecycle FIRST and UNCHANGED (no suffix), install_warning SECOND WITH
    # the suffix -- dismissal must not be able to swallow a different banner.
    my $two = tui::DashboardScreen::_banner_lines({
        lifecycle       => { mode => 'stop-runs', active => 0, summary => 'zqx-lifecycle-7714' },
        install_warning => 'backpack install: some items failed',
    });
    is(scalar(@$two), 2, 'AC5: lifecycle + install_warning together produce exactly two banner lines');
    like($two->[0], qr/zqx-lifecycle-7714/, 'AC5: first line is the lifecycle summary, unmodified');
    unlike($two->[0], qr/\[d\] dismiss/, 'AC5: the lifecycle line itself carries NO dismiss hint -- dismiss is install_warning-only');
    like($two->[1], qr/backpack install: some items failed/, 'AC5: second line is the install_warning message');
    like($two->[1], qr/\[d\] dismiss/, 'AC5: second line (install_warning) carries the dismiss hint');

    # AC5, the actual dismissal scenario: lifecycle + status + install_warning
    # all present; dismissing means the loop supplies install_warning => undef
    # (per spec S2.4's loop-level mechanism) -- confirm the OTHER two banners
    # are untouched, in the same order, when that happens.
    my $before = tui::DashboardScreen::_banner_lines({
        lifecycle       => { mode => 'full-shutdown', active => 0, summary => 'zqx-fs-7714' },
        status          => 'exited',
        install_warning => 'backpack install: some items failed',
    });
    my $after_dismiss = tui::DashboardScreen::_banner_lines({
        lifecycle       => { mode => 'full-shutdown', active => 0, summary => 'zqx-fs-7714' },
        status          => 'exited',
        install_warning => undef,
    });
    is(scalar(@$before), 3, 'AC5 sanity: with all three sources present, three lines render (proves the fixture actually exercises all three)');
    is(scalar(@$after_dismiss), 2, 'AC5: after a simulated dismiss (install_warning => undef), exactly the OTHER two lines remain');
    is_deeply($after_dismiss, [ @$before[0, 1] ],
        'AC5: the surviving lifecycle+status lines are BYTE-IDENTICAL to their pre-dismiss form and same relative order -- dismissing install_warning cannot alter or reorder a different banner');
}

# ===========================================================================
# PART 3 -- AC1 (done criterion 1), dispatch_key mapping (spec S2.3,
# observable behaviors 5-7).
# ===========================================================================
SKIP: {
    skip('Dashboard did not load', 4) unless $DASH_OK;

    is_deeply([ Dashboard::dispatch_key('d', '') ], ['dismiss-install-warning', ''],
        'AC1/behavior5: dispatch_key("d", "") returns the dismiss action, pending unchanged');

    # behavior 6: uppercase D is the LEFT-arrow CSI final byte -- deliberately
    # NOT bound, unlike almost every other letter here which accepts both
    # cases. This assertion cannot go red against TODAY's code (today nothing
    # binds 'd' OR 'D'), but it is the direct regression guard against the
    # single most likely wrong implementation: a case-insensitive /d/i match.
    is_deeply([ Dashboard::dispatch_key('D', '') ], ['', ''],
        'AC1/behavior6: dispatch_key("D", "") stays INERT -- uppercase is deliberately unbound (CSI-collision rationale)');

    # behavior 7: 'd' while a confirm is armed cancels it like any other key,
    # never dismisses the banner (the branch is unreached while pending).
    is_deeply([ Dashboard::dispatch_key('d', 'stop-runs') ], ['cancel-stop-runs', ''],
        'AC1/behavior7: dispatch_key("d", "stop-runs") cancels the armed stop-runs confirm, does NOT dismiss');
    is_deeply([ Dashboard::dispatch_key('d', 'full-shutdown') ], ['cancel-full-shutdown', ''],
        'AC1/behavior7: dispatch_key("d", "full-shutdown") cancels the armed full-shutdown confirm, does NOT dismiss');
}

# ===========================================================================
# PART 4 -- AC3 (done criterion 3): no show-errors control anywhere.
# Grep-shaped assertions per spec S4 AC3, each with a counter-fixture proving
# the detector actually fires on a hand-built violation.
# ===========================================================================
{
    my $dash_src = slurp($DASHBOARD_PM);
    # Isolate just the dispatch_key sub body so a comment or an unrelated
    # string elsewhere in the 4000-line file (e.g. "error" appearing in
    # error-handling prose) can't produce a false positive.
    my ($dispatch_body) = $dash_src =~ /^sub dispatch_key \{(.*?)^\}/ms;
    ok(defined $dispatch_body && length $dispatch_body,
        'AC3 harness: dispatch_key sub body isolated for scanning (non-vacuity precondition)');

    my @action_strings = ($dispatch_body // '') =~ /return\s*\(\s*'([^']*)'/g;
    ok(scalar(@action_strings) > 0, 'AC3 harness: at least one action string extracted from dispatch_key (non-vacuity)');

    my @forbidden = grep { /show|error|transcript/i } @action_strings;
    is_deeply(\@forbidden, [],
        'AC3: dispatch_key defines no action name containing show/error/transcript -- TUI-07\'s retracted show-errors half stays retracted');

    # Counter-fixture: the detector regex itself DOES fire on a violation.
    my @cf = grep { /show|error|transcript/i } ('dismiss-install-warning', 'show-install-errors', 'launch');
    is_deeply(\@cf, ['show-install-errors'],
        'AC3 non-vacuity: the show/error/transcript detector fires on a hand-built "show-install-errors" action name');

    # No new single-letter key mapping besides 'd' itself was introduced for
    # this purpose. Probe a spread of plausible show-errors mnemonics ('e'
    # for errors, 't' for transcript, 'v' for view) and require them inert,
    # UNLESS they already had an unrelated pre-existing meaning (none of
    # these do, per the dispatch_key source read at authoring time).
    SKIP: {
        skip('Dashboard did not load', 3) unless $DASH_OK;
        for my $probe (qw(e t v)) {
            is_deeply([ Dashboard::dispatch_key($probe, '') ], ['', ''],
                "AC3: dispatch_key('$probe', '') stays inert -- no show-errors mnemonic was bound");
        }
    }
}
{
    # AC3, the rendered side: _banner_lines' install_warning line contains no
    # path-like substring for any of the SIX actual $INSTALL_WARNING literals
    # in launcher.pl (spec S1 table) -- none of them is a path, so none of
    # their _banner_lines renderings should look like one either.
    my $src = slurp($LAUNCHER_PL);
    my @literals = $src =~ /\$INSTALL_WARNING\s*=\s*'([^']*)'/g;
    ok(scalar(@literals) >= 6, 'AC3 harness: at least the six known $INSTALL_WARNING literal sites found in launcher.pl');
    my @path_like = grep { /\.log\b|claude-home|\/root\/|C:\\|transcript path/i } @literals;
    is_deeply(\@path_like, [],
        'AC3: none of the $INSTALL_WARNING literal strings is path-like (no .log, no claude-home, no transcript path) -- the dashboard never surfaces the underlying transcript location');

    # Counter-fixture proving the path-like detector fires on a violation.
    my @cf = grep { /\.log\b|claude-home|\/root\/|C:\\|transcript path/i } ('some items failed', 'see /root/.claude/.launcher/install.log for detail');
    is_deeply(\@cf, ['see /root/.claude/.launcher/install.log for detail'],
        'AC3 non-vacuity: the path-like detector fires on a hand-built string containing a real path');
}

# ===========================================================================
# PART 5 -- AC1 (done criterion 1), loop-level: dispatch through
# Dashboard::run's real main loop (spec S2.4), the mechanism the ledger flags
# as the actual trap ("%state is wholesale-replaced on every gather; a naive
# single mutation is undone within seconds"). Each `out` call is captured as
# its OWN element (not concatenated) so presence/absence is checked per
# rendered frame, immune to the diff-vs-full-render ambiguity of a
# concatenated string.
# ===========================================================================
SKIP: {
    skip('Dashboard did not load', 3) unless $DASH_OK;

    my $MARK = 'zqx-banner-dismiss-7714';

    sub _drive_frames {
        my (%args) = @_;
        my @keys = @{ $args{keys} || [] };
        my $clock = 1000;
        my @frames;
        my $rc = Dashboard::run(
            beat_interval   => 1000,          # never fires within these few ticks
            state_interval  => $args{state_interval},
            tick_interval   => 0.25,
            color           => 0,
            max_ticks       => $args{max_ticks} // 10,
            now             => sub { $clock },
            sleep_for       => sub { $clock += $_[0]; },
            read_key        => sub { @keys ? shift @keys : undef },
            term_size       => sub { (80, 24) },
            gather          => sub {
                { project_name => 'demo', container => 'c1', status => 'running',
                  events => [], install_warning => $MARK };
            },
            heartbeat       => sub { 'ok' },
            spawn           => sub { undef },
            enter_raw       => sub { },
            leave_raw       => sub { },
            keepawake       => sub { },
            out             => sub { push @frames, $_[0]; },
        );
        return (\@frames, $rc);
    }

    # IMPORTANT RENDERER FACT (verified: tui::Screen::compose, Screen.pm
    # :269-307) that shapes every fixture below: the composed row array is
    # ALWAYS PADDED to exactly $rows cells (title + banners + body-padded-to-
    # fill + footer), regardless of how many banners are present. So the
    # per-row diff renderer (render_frame's _cell_sig comparison) SUPPRESSES
    # output for a row whose content hasn't changed since the last frame --
    # once the install-warning banner has been rendered once, an unrelated
    # tick where nothing about it changes produces NO further occurrence of
    # $MARK in the output stream, dismissed or not. A naive "count $MARK
    # occurrences across the whole run" is therefore VACUOUS: it would read
    # exactly 1 even with dispatch_key('d',...) doing nothing at all, because
    # diff suppression alone hides the (never-dismissed) repeat. Every
    # fixture below forces a periodic 'r' (refresh) key, which sets $prev =
    # undef and so guarantees the NEXT primary render is a full, unconditional
    # repaint of every row from current %state -- the only way to positively
    # observe "is the mark ACTUALLY gone from state right now", immune to
    # diff suppression in either direction.

    # --- Baseline / non-vacuity control: with NO dismiss key, periodic
    # forced full repaints (via 'r') each show the still-present banner.
    # Proves the fixture and the 'r'-forces-a-full-repaint technique actually
    # produce repeated, independently-observable positive occurrences of
    # $MARK -- so a later "count == 1" is a meaningful claim about dismissal,
    # not an artifact of the technique never being able to show more than 1.
    {
        my ($frames) = _drive_frames(
            keys => ['r', undef, 'r', undef, 'r', undef, 'q'],
            state_interval => 0,
            max_ticks => 10,
        );
        my $n = grep { /\Q$MARK\E/ } @$frames;
        ok($n >= 3,
            "loop non-vacuity: with no dismiss key, three forced full repaints each independently show the still-present banner (got $n occurrences, need >=3) -- confirms the 'r'-forced-repaint technique can positively detect presence, repeatedly");
    }

    # --- Behavior 8 AND 9 together: 'd' is drained on the very first tick
    # (the only gather this fixture ever needs to prove the point). A
    # subsequent 'r' forces a full, unconditional repaint from whatever
    # %state holds AT THAT LATER TICK -- so if dismissal was a bare one-shot
    # mutation of %state{install_warning} (the landmine spec S2.4 names)
    # rather than a lexical flag re-applied every tick, a regather between
    # 'd' and 'r' (state_interval => 0 forces one on every tick) resurrects
    # the field and the forced repaint WILL show $MARK again -- caught here,
    # not hidden by diff suppression. With state_interval => 1000 (a second
    # fixture, no further regather ever occurs) the same forced-repaint check
    # isolates the same-tick immediacy half of the claim (behavior 8) from
    # the regather-survival half (behavior 9).
    for my $case (
        { label => 'behavior8 (single gather; no further regather ever occurs)', state_interval => 1000 },
        { label => 'behavior9 (a fresh regather fires on every tick)',           state_interval => 0 },
    ) {
        my ($frames) = _drive_frames(
            keys => ['d', undef, 'r', undef, 'q'],
            state_interval => $case->{state_interval},
            max_ticks => 8,
        );
        my $n = grep { /\Q$MARK\E/ } @$frames;
        is($n, 1,
            "AC1 [$case->{label}]: 'd' on the first tick + a later forced full repaint together show \$MARK in EXACTLY ONE frame (the pre-dismiss one) -- the repaint after dismissal proves the state is ACTUALLY clear, not just undiffed (got $n)");
    }
}

# ===========================================================================
# PART 7 -- fix-batch step 7, F1 (step-6 red-team MEDIUM-1): the dismiss
# mechanism is a blanket, content-blind, per-process mute (Dashboard.pm
# $install_warning_dismissed) -- once armed, EVERY future $state{install_warning}
# is suppressed, not just the one string that was on screen when 'd' was
# pressed. That is safe ONLY because of a cross-file invariant spec S2.4
# proves by hand: every $INSTALL_WARNING assignment in launcher.pl executes
# BEFORE Dashboard::run's loop is ever entered (_launch_stage_begin('dashboard')),
# so no "new, different" warning can ever arise while the loop -- and hence
# the mute -- is live. Before this block, that invariant was enforced by
# NOTHING: a future edit that added or moved an $INSTALL_WARNING assignment
# to after the dashboard stage would silently start swallowing a live,
# different warning, and every other assertion in this file would stay green
# (they all use fixed/static warning text, never a changing one across a
# single process's life).
#
# WHAT THIS PROVES: launcher.pl's $INSTALL_WARNING assignments are, TEXTUALLY,
# all positioned before the _launch_stage_begin('dashboard') call in the
# source file, which is the same evidence the reviewer/red-team verified by
# hand (redteam-step6.md MEDIUM-1) and the same evidence spec S2.4 itself
# relies on.
# WHAT THIS DOES NOT PROVE: that source-textual order equals RUNTIME
# execution order in every possible control-flow shape (e.g. it would not
# catch an assignment hoisted into a sub that is itself called after the
# dashboard stage begins, or reached via goto/eval). launcher.pl is a flat,
# top-to-bottom script with no such indirection around this code today
# (verified by reading the surrounding control flow at each site), so for
# THIS file, textual order is execution order -- but a reader relying on
# this test as a substitute for reading the code around a future assignment
# would be trusting a weaker guarantee than it looks like at first glance.
# ===========================================================================
{
    my $src = slurp($LAUNCHER_PL);

    my $stage_marker = "_launch_stage_begin('dashboard')";
    my $stage_pos = index($src, $stage_marker);
    ok($stage_pos >= 0,
        "F1 harness: the $stage_marker marker was found in launcher.pl (non-vacuity precondition)");

    # Match ANY assignment form, not just `= '...'`. The six sites in
    # launcher.pl today all happen to assign a single-quoted literal, so a
    # scan anchored on `'` would be green by accident of current formatting
    # -- and would silently miss the very thing this guard exists to catch:
    # a FUTURE `$INSTALL_WARNING = "...$interpolated..."` or `= $var` placed
    # after the dashboard stage. The (?!=) keeps `==` comparisons out.
    my @assign_pos;
    while ($src =~ /\$INSTALL_WARNING\s*=(?!=)/g) {
        push @assign_pos, $-[0];
    }
    ok(scalar(@assign_pos) >= 6,
        'F1 harness: at least six $INSTALL_WARNING assignment sites found in launcher.pl (non-vacuity precondition)');

    my @late = grep { $_ > $stage_pos } @assign_pos;
    is_deeply(\@late, [],
        "F1: every \$INSTALL_WARNING assignment in launcher.pl occurs textually BEFORE $stage_marker -- the invariant Dashboard.pm's blanket per-process dismiss-mute depends on for safety (spec S2.4; step-6 red-team MEDIUM-1). A violation here means a NEW/different install warning could arise while the dashboard loop is running and be silently swallowed by an earlier dismiss.");

    # Counter-fixture: a hand-built SCRATCH snippet (never the real launcher.pl,
    # never written to disk) with an $INSTALL_WARNING assignment placed after
    # the stage marker -- proves the scan above is not vacuously green because
    # it is structurally incapable of ever going red.
    # Three assignment FORMS, deliberately: single-quoted (what launcher.pl
    # uses today), double-quoted-interpolated, and a bare scalar. A scan
    # anchored on `'` passes the first and misses the other two, which is
    # precisely the accident this guard must not depend on.
    for my $case (
        [ 'single-quoted literal', "\$INSTALL_WARNING = 'invented after the dashboard started';\n" ],
        [ 'double-quoted interpolated', "\$INSTALL_WARNING = \"invented after \$stage started\";\n" ],
        [ 'bare scalar', "\$INSTALL_WARNING = \$some_late_warning;\n" ],
    ) {
        my ($label, $late_assign) = @$case;
        my $violating = "_launch_stage_begin('dashboard');\n" . $late_assign;
        my $v_stage_pos = index($violating, $stage_marker);
        my @v_assign_pos;
        while ($violating =~ /\$INSTALL_WARNING\s*=(?!=)/g) {
            push @v_assign_pos, $-[0];
        }
        my @v_late = grep { $_ > $v_stage_pos } @v_assign_pos;
        ok(scalar(@v_late) >= 1,
            "F1 non-vacuity ($label): the same scan DOES flag a hand-built scratch snippet carrying an \$INSTALL_WARNING assignment placed after _launch_stage_begin('dashboard') -- confirms the detector can actually fail for this assignment form; the real launcher.pl is never mutated by this test");
    }
}

done_testing();
