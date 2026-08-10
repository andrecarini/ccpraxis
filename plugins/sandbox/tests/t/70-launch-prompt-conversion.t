#!/usr/bin/env perl
# Package 12 — the launch prompts package 08 handed back.
#
# Package 08 moved the launch flow into the TUI but deliberately excluded three
# hand-rolled menus (spec 08 §6), all on paths that only fire when a container
# or image already exists — which is exactly why criterion 1 ("a launch with no
# existing container") could pass while the operator still met a raw menu on
# screen. This file is the oracle for closing that.
#
# ⚠ NOTHING HERE SPAWNS launcher.pl. It is read as SOURCE TEXT and the pure
# module is driven directly. launcher.pl builds a container image and starts a
# container; a test that runs it does real work on the host.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Encode ();

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
my $LSPM     = "$Bin/../../scripts/tui/LaunchScreens.pm";

use_ok('tui::LaunchScreens') or BAIL_OUT('LaunchScreens.pm did not load');

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or BAIL_OUT("cannot read $p: $!");
    local $/; my $s = <$fh>; close $fh;
    return defined $s ? $s : '';
}

# Comments are BLANKED before every source scan. A scan that reads prose
# punishes a file for documenting its own reasoning — and this package's whole
# subject is discussed at length in comments that name the very constructs the
# scans below forbid. This has bitten at least six oracles in this repo.
sub blank_comments {
    my ($src) = @_;
    my @out;
    for my $line (split /\n/, $src, -1) {
        $line =~ s/^(\s*)#.*$/$1/;
        push @out, $line;
    }
    return join("\n", @out);
}

my $LSRC_RAW = slurp($LAUNCHER);
my $LSRC     = blank_comments($LSRC_RAW);
my $MSRC     = blank_comments(slurp($LSPM));

# extract_sub_body($src, $name) -> the balanced body of `sub $name`, or undef.
sub extract_sub_body {
    my ($src, $name) = @_;
    my $at = index($src, "sub $name");
    return undef if $at < 0;
    my $open = index($src, '{', $at);
    return undef if $open < 0;
    my $depth = 0;
    for my $i ($open .. length($src) - 1) {
        my $c = substr($src, $i, 1);
        $depth++ if $c eq '{';
        if ($c eq '}') {
            $depth--;
            return substr($src, $open, $i - $open + 1) if $depth == 0;
        }
    }
    return undef;
}


# ===========================================================================
# A. menu_model — the shared single-choice builder
# ===========================================================================
{
    my $m = tui::LaunchScreens::menu_model(
        label   => 'Sandbox may be stale',
        detail  => [ 'reason one', 'reason two' ],
        options => [
            { id => 'rebuild',  key => 'r', display => '[r] Rebuild' },
            { id => 'continue', key => 'c', display => '[c] Continue as-is' },
        ],
    );

    is($m->{mode}, 'single', 'A1 menu_model is a single-choice screen');
    is($m->{label}, 'Sandbox may be stale', 'A2 label carried');

    my @rows    = grep { $_->{kind} eq 'row' } @{ $m->{items} };
    my @details = grep { $_->{kind} ne 'row' } @{ $m->{items} };
    is(scalar(@rows), 2, 'A3 one row per option');
    is(scalar(@details), 2, 'A4 one non-row per detail line');

    ok(!grep({ !$_->{disabled} } @details),
       'A5 detail lines are NOT landable — the cursor must not stop on the reasons');

    is($rows[0]{id}, 'rebuild',  'A6 option order preserved (rebuild first)');
    is($rows[1]{id}, 'continue', 'A7 option order preserved (continue second)');
    is($m->{shortcuts}{r}, 'rebuild',  'A8 shortcut r -> rebuild');
    is($m->{shortcuts}{c}, 'continue', 'A9 shortcut c -> continue');

    # The letter must be VISIBLE. A shortcut nobody can see is not an
    # affordance — the hand-rolled menu advertised "r/c: shortcut" in its
    # footer, and the conversion must not silently drop that.
    like($rows[0]{display}, qr/\[r\]/, 'A10 the shortcut letter is on the row');
    like($rows[1]{display}, qr/\[c\]/, 'A11 the shortcut letter is on the row');
}

# Degenerate inputs must not produce a screen that cannot be used.
{
    my $m = tui::LaunchScreens::menu_model();
    is($m->{mode}, 'single', 'A12 no options still yields a well-formed model');
    ok($m->{empty}, 'A13 an option-less menu reports empty rather than pretending');

    my $m2 = tui::LaunchScreens::menu_model(
        options => [ { id => 'only' }, { id => '' }, 'not-a-hash', { display => 'no id' } ],
    );
    my @rows = grep { $_->{kind} eq 'row' } @{ $m2->{items} };
    is(scalar(@rows), 1, 'A14 options without an id are dropped, not rendered as blanks');
    is($rows[0]{display}, 'only', 'A15 a display-less option falls back to its id');
}


# ===========================================================================
# B. single-mode shortcut dispatch
# ===========================================================================
{
    my $mk = sub {
        return tui::LaunchScreens::list_init(model => tui::LaunchScreens::menu_model(
            detail  => [ 'ctx' ],
            options => [
                { id => 'rebuild',  key => 'r', display => '[r] Rebuild' },
                { id => 'continue', key => 'c', display => '[c] Continue' },
            ],
        ));
    };

    my $ls = $mk->();
    is(tui::LaunchScreens::list_dispatch_key($ls, 'c'), 'confirm',
       'B1 a shortcut key confirms immediately');
    my $d = tui::LaunchScreens::list_selection($ls);
    is($d->{cursor_id}, 'continue',
       'B2 the shortcut chose ITS row, not whatever the cursor was on');

    # The cursor started on 'rebuild'; the shortcut must have MOVED it, not
    # merely returned a value, or the painted frame would disagree with the
    # answer for the instant before the screen closes.
    $ls = $mk->();
    tui::LaunchScreens::list_dispatch_key($ls, 'c');
    my $items = $ls->{items};
    is($items->[ $ls->{cursor} ]{id}, 'continue', 'B3 the shortcut moved the cursor');

    # Uppercase is the same key.
    $ls = $mk->();
    is(tui::LaunchScreens::list_dispatch_key($ls, 'R'), 'confirm', 'B4 shortcuts are case-insensitive');
    is(tui::LaunchScreens::list_selection($ls)->{cursor_id}, 'rebuild', 'B5 uppercase R -> rebuild');

    # SHARED KEYS ARE NOT OVERRIDABLE. A screen must not be able to redefine
    # the keys every other screen uses, or the operator's muscle memory
    # becomes screen-dependent.
    my $hostile = tui::LaunchScreens::list_init(model => tui::LaunchScreens::menu_model(
        options => [ { id => 'first', key => 'q' }, { id => 'second', key => 'j' } ],
    ));
    is(tui::LaunchScreens::list_dispatch_key($hostile, 'q'), 'cancel',
       'B6 q stays cancel even when a model claims it as a shortcut');
    is(tui::LaunchScreens::list_dispatch_key($hostile, 'j'), 'move',
       'B7 j stays movement even when a model claims it as a shortcut');

    # An unknown letter is inert, NOT a confirm.
    $ls = $mk->();
    is(tui::LaunchScreens::list_dispatch_key($ls, 'z'), '', 'B8 an unmapped letter does nothing');
    ok(!tui::LaunchScreens::list_selection($ls)->{confirmed}, 'B9 ... and does not confirm');

    # COUNTER-FIXTURE: without a shortcuts table the same keystroke is inert,
    # so B1 is proving the table works rather than passing for free.
    my $plain = tui::LaunchScreens::list_init(model => {
        mode  => 'single',
        items => [ { kind => 'row', id => 'rebuild', display => 'Rebuild' },
                   { kind => 'row', id => 'continue', display => 'Continue' } ],
    });
    is(tui::LaunchScreens::list_dispatch_key($plain, 'c'), '',
       'B10 counter-fixture: with no shortcuts declared, c is inert '
     . '(if this ever fails, B1 is guarding nothing)');

    # A shortcut naming a row that does not exist must be inert, not a crash
    # and not a confirm of something else.
    my $dangling = tui::LaunchScreens::list_init(model => tui::LaunchScreens::menu_model(
        options => [ { id => 'real', key => 'r' } ],
    ));
    $dangling->{shortcuts}{x} = 'ghost';
    is(tui::LaunchScreens::list_dispatch_key($dangling, 'x'), '',
       'B11 a shortcut pointing at no row is inert');
}


# ===========================================================================
# C. menu_choice — a cancel is not a choice
# ===========================================================================
{
    is(tui::LaunchScreens::menu_choice(
        { decision => { confirmed => 1, cancelled => 0, cursor_id => 'rebuild' } }, 'cancel'),
       'rebuild', 'C1 a confirmed choice returns the chosen id');

    is(tui::LaunchScreens::menu_choice(
        { decision => { confirmed => 0, cancelled => 1, cursor_id => 'rebuild' } }, 'cancel'),
       'cancel',
       'C2 a CANCEL returns the default even though a cursor_id is present — '
     . 'escape must never enact the row the cursor happened to rest on');

    is(tui::LaunchScreens::menu_choice({ decision => { confirmed => 0, cancelled => 0 } }, 'cancel'),
       'cancel', 'C3 neither confirmed nor cancelled -> default');
    is(tui::LaunchScreens::menu_choice(undef, 'cancel'), 'cancel', 'C4 a garbage result -> default');
    is(tui::LaunchScreens::menu_choice({ decision => { confirmed => 1, cursor_id => '' } }, 'cancel'),
       'cancel', 'C5 a confirm with no cursor id -> default');
}


# ===========================================================================
# C2. END-TO-END through the real modal loop.
#
# B and C drive list_dispatch_key and menu_choice in isolation, which proves
# the pieces but not the wiring — a model that never reaches list_run, or a
# result shape menu_choice cannot read, would pass every assertion above and
# still hand the launcher the wrong answer. So run the actual loop.
# ===========================================================================
{
    my $model = sub {
        return tui::LaunchScreens::menu_model(
            label   => 'Sandbox may be stale',
            detail  => [ 'image drifted' ],
            options => [
                { id => 'rebuild',  key => 'r', display => '[r] Rebuild' },
                { id => 'continue', key => 'c', display => '[c] Continue as-is' },
            ],
        );
    };

    # A scripted read_key with NO wait_key is guaranteed to terminate:
    # list_run's loop exits when a poll yields nothing and wait_key is absent.
    my $run = sub {
        my @keys = @_;
        my $ticks = 0;
        return tui::LaunchScreens::list_run(
            model     => $model->(),
            read_key  => sub { shift @keys },
            render    => sub { '' },
            out       => sub { },
            heartbeat => sub { $ticks++ },
            term_size => sub { (100, 30) },
        );
    };

    is(tui::LaunchScreens::menu_choice($run->('r'), 'cancel'), 'rebuild',
       'C2-1 pressing r all the way through the real loop returns rebuild');
    is(tui::LaunchScreens::menu_choice($run->('c'), 'cancel'), 'continue',
       'C2-2 pressing c returns continue');
    is(tui::LaunchScreens::menu_choice($run->('ENTER'), 'cancel'), 'rebuild',
       'C2-3 bare ENTER takes the first row, as the old menu did');
    is(tui::LaunchScreens::menu_choice($run->('DOWN', 'ENTER'), 'cancel'), 'continue',
       'C2-4 DOWN then ENTER takes the second row');
    is(tui::LaunchScreens::menu_choice($run->('q'), 'cancel'), 'cancel',
       'C2-5 q cancels, and a cancel is not a choice');
    is(tui::LaunchScreens::menu_choice($run->("\e"), 'cancel'), 'cancel',
       'C2-6 ESC cancels too');

    # The cursor must never land on a detail line, or the first ENTER would
    # confirm nothing and the screen would look frozen.
    is(tui::LaunchScreens::menu_choice($run->('UP', 'UP', 'UP', 'ENTER'), 'cancel'), 'rebuild',
       'C2-7 UP past the top clamps to the first ROW, never onto the detail lines');

    # Rule 5: the heartbeat is ticked, including on idle iterations.
    my $ticks = 0;
    tui::LaunchScreens::list_run(
        model     => $model->(),
        read_key  => sub { undef },
        render    => sub { '' },
        out       => sub { },
        heartbeat => sub { $ticks++ },
        term_size => sub { (100, 30) },
    );
    ok($ticks >= 1,
       'C2-8 the heartbeat ticks even when the operator presses nothing — an idle '
     . 'operator is exactly the case the container keep-alive exists for');
}


# ===========================================================================
# C3. A MENU MUST NOT WEAR MULTI-SELECT CHROME.
#
# Reported from a live launch: the converted stale prompt rendered as
#
#     -- items ---------------------------------------------------
#           - Containerfile has changed since last build
#         [ ] [r] Rebuild ? fresh container with Claude Code v2.1.219
#       > [x] [c] Continue as-is
#       2 item(s), 1 selected
#
# "It's not a select-multiple step and shouldn't have the semantics of one."
# Correct: a checkbox invites a second tick that this mode cannot accept (the
# first choice closes the screen), and "N item(s), M selected" is a running
# tally on a screen with no tally. This asserts against the RENDERED FRAME,
# not the model — the model was right the whole time and every unit assertion
# passed while the screen was wrong.
# ===========================================================================
{
    my $ls = tui::LaunchScreens::list_init(model => tui::LaunchScreens::menu_model(
        label   => 'Sandbox may be stale',
        detail  => [ 'Containerfile has changed since last build' ],
        options => [
            { id => 'rebuild',  key => 'r', display => '[r] Rebuild' },
            { id => 'continue', key => 'c', display => '[c] Continue as-is' },
        ],
    ));
    my $frame = tui::LaunchScreens::compose_list($ls, 24, 100);
    my $text  = join "\n", map { tui::Frame::spans_text($_->{spans} || []) } @$frame;

    unlike($text, qr/\[ \]/, 'C3-1 no empty checkbox on a single-choice menu');
    unlike($text, qr/\[x\]/, 'C3-2 no ticked checkbox either');
    unlike($text, qr/item\(s\)/,
           'C3-3 no "N item(s), M selected" tally — the count is always '
         . '"one, eventually", so the line says nothing');
    unlike($text, qr/\bselected\b/, 'C3-4 no multi-select vocabulary anywhere in the frame');

    # The options are still THERE and still distinguishable.
    like($text, qr/\[r\] Rebuild/,      'C3-5 the rebuild option still renders');
    like($text, qr/\[c\] Continue/,     'C3-6 the continue option still renders');
    like($text, qr/Sandbox may be stale/, 'C3-7 the title still renders');
    like($text, qr/Containerfile has changed/, 'C3-8 the reason still renders');

    # The cursor is what shows the choice now, so it had better be visible.
    my $cursor = Theme::glyph('cursor');
    like($text, qr/\Q$cursor\E/,
         'C3-9 the cursor glyph renders — with the checkbox gone it is the '
       . 'ONLY thing indicating which option is selected');

    # The footer must not advertise multi-select keys.
    unlike($text, qr/all in group|toggle/,
           'C3-10 the footer legend does not offer multi-select actions');

    # COUNTER-FIXTURE: multi mode still HAS the chrome, so C3-1..C3-4 are
    # proving single-mode differs rather than that the boxes vanished for all.
    my $multi = tui::LaunchScreens::list_init(model => {
        mode  => 'multi',
        items => [ { kind => 'row', id => 'a', display => 'alpha' } ],
    });
    my $mtext = join "\n",
        map { tui::Frame::spans_text($_->{spans} || []) }
        @{ tui::LaunchScreens::compose_list($multi, 24, 100) };
    like($mtext, qr/\[ \]/,
         'C3-11 counter-fixture: multi mode STILL renders checkboxes '
       . '(if this ever fails, C3-1 is guarding nothing)');
    like($mtext, qr/item\(s\)/,
         'C3-12 counter-fixture: multi mode still renders the tally');
}

# The em dash in a real option label must reach the frame intact. This is the
# '?' in "Rebuild ? fresh container" from the live report — fixed in
# tui::Frame::safe_char, asserted here at the level the operator actually sees.
{
    my $ls = tui::LaunchScreens::list_init(model => tui::LaunchScreens::menu_model(
        options => [ { id => 'rebuild', key => 'r',
                       display => "[r] Rebuild \x{2014} fresh container with Claude Code v2.1.219" } ],
    ));
    my $text = join "\n",
        map { tui::Frame::spans_text($_->{spans} || []) }
        @{ tui::LaunchScreens::compose_list($ls, 24, 120) };

    # Compare in ONE domain. The frame comes back as UTF-8 BYTES while a
    # \x{2014} in this file's source is a CHARACTER, so a naive `like` fails
    # against a frame that is perfectly correct — which is exactly what
    # happened on the first run of this assertion. Normalise, then compare.
    my $dtext = eval { Encode::decode('UTF-8', $text, Encode::FB_CROAK()) };
    $dtext = $text unless defined $dtext;

    like($dtext, qr/Rebuild \x{2014} fresh container/,
         'C3-13 an em dash in an option label survives to the rendered frame');
    unlike($dtext, qr/Rebuild \? fresh/,
           'C3-14 ... and specifically is not the "?" the operator was shown');
}


# ===========================================================================
# D. launcher.pl — the stale/rebuild prompt is converted
# ===========================================================================
{
    my $body = extract_sub_body($LSRC, 'prompt_stale_action');
    ok(defined $body, 'D1 prompt_stale_action still exists');

    like($body, qr/LaunchScreens::menu_model/, 'D2 it builds a menu model');
    like($body, qr/_launch_run_list/,          'D3 it runs through the shared list runner');
    like($body, qr/menu_choice\s*\(\s*\$res\s*,\s*'cancel'\s*\)/,
         'D4 q/ESC maps to cancel, exactly as the hand-rolled menu did');

    # The TUI branch must be gated on {active}, not on the mode alone —
    # _tee_system's plain-after-teardown fallback leaves the mode saying 'tui'
    # with the host already torn down.
    like($body, qr/\$LAUNCH_HOST->\{active\}/,
         'D5 the TUI branch is gated on the host being ACTIVE, not just on the mode');

    # The plain paths SURVIVE. Criterion 4: the non-TTY path stays plain.
    like($body, qr/Term::ReadKey/, 'D6 the cbreak fallback is still present');
    like($body, qr/<STDIN>/,       'D7 the line-read fallback is still present');
    like($body, qr/-t\s+STDIN/,    'D8 it still tests for a TTY before using one');
}

# The suspend/resume pair is GONE, and nothing calls it.
{
    ok(!defined extract_sub_body($LSRC, '_launch_suspend'),
       'D9 _launch_suspend is gone — nothing needs the frame handed back now');
    ok(!defined extract_sub_body($LSRC, '_launch_resume'), 'D10 _launch_resume is gone');

    my @calls = ($LSRC =~ /_launch_(?:suspend|resume)\s*\(/g);
    is(scalar(@calls), 0, 'D11 no call site survives the removal');
}

# The old hand-rolled highlight and in-place redraw must not be what the TUI
# path uses. They may still appear inside the cbreak fallback, so this is
# scoped to the sub and asserted as "not before the fallback".
{
    my $body = extract_sub_body($LSRC, 'prompt_stale_action');
    my $tui_at   = index($body, 'menu_model');
    my $fall_at  = index($body, 'Term::ReadKey');
    ok($tui_at >= 0 && $fall_at > $tui_at,
       'D12 the TUI branch comes first and the raw fallback after it');

    my $tui_part = substr($body, 0, $fall_at);
    unlike($tui_part, qr/\\e\[1;36m/, 'D13 the TUI branch has no hand-rolled cyan highlight');
    unlike($tui_part, qr/\\e\[\$\{?\w+\}?A/, 'D14 the TUI branch has no in-place cursor-up redraw');
}


# ===========================================================================
# E. launcher.pl — the orphan-kill confirm is converted, and ordered correctly
# ===========================================================================
{
    my $body = extract_sub_body($LSRC, 'kill_orphan_claudes_if_user_confirms');
    ok(defined $body, 'E1 kill_orphan_claudes_if_user_confirms still exists');
    like($body, qr/LaunchScreens::menu_model/, 'E2 it builds a menu model');
    like($body, qr/<STDIN>/, 'E3 the line-read fallback survives for the plain path');

    # ESC must not fire kill -9.
    like($body, qr/menu_choice\s*\(\s*\$res\s*,\s*'skip'\s*\)/,
         'E4 a cancelled confirm SKIPS — escape must never fire an irreversible kill -9');

    # ORDERING, and it is the whole point of the teardown callback: the screen
    # needs the frame up, the kill spawns inherit stdio and would paint over
    # it. Decide, tear down, then act.
    my $decide_at   = index($body, 'menu_choice');
    my $teardown_at = index($body, '$teardown->()');
    my $spawn_at    = index($body, 'system(');
    ok($decide_at >= 0 && $teardown_at > $decide_at,
       'E5 the teardown runs AFTER the decision (the screen needs the frame up)');
    ok($spawn_at > $teardown_at,
       'E6 the kill spawns run AFTER the teardown (they inherit stdio)');
}

# The connector call site had to move host_leave; assert the new order.
{
    my $call_at = index($LSRC, 'kill_orphan_claudes_if_user_confirms(');
    ok($call_at > 0, 'E7 the connector still offers orphan cleanup');

    # The unconditional host_leave now FOLLOWS the offer.
    my $leave_at = index($LSRC, 'host_leave($LAUNCH_HOST) if $LAUNCH_HOST;', $call_at);
    ok($leave_at > $call_at,
       'E8 the frame is torn down AFTER the offer, so the offer can render in it');

    # ... and still BEFORE the exec that takes the tty outright.
    my $exec_at = index($LSRC, "'exec', '-it'", $call_at);
    ok($exec_at > $leave_at,
       'E9 ... and still before podman exec -it, which takes the terminal outright');
}


# ===========================================================================
# F. hold_for_keypress is DELIBERATELY NOT converted
#
# Spec 08 §6 lumped it in with the other two, but it is a different animal and
# converting it would be a regression: it runs after `podman exec` has exited
# and the frame is long gone, and its entire purpose is to keep the RESTORED
# screen readable — the operator is looking at claude's dying output and the
# lost-container explanation. An alt screen would hide exactly what they are
# being held there to read.
#
# Asserted so the omission is a recorded decision rather than an oversight
# somebody "fixes" later.
# ===========================================================================
{
    my $body = extract_sub_body($LSRC, 'hold_for_keypress');
    ok(defined $body, 'F1 hold_for_keypress still exists');
    unlike($body, qr/menu_model|_launch_run_list/,
           'F2 hold_for_keypress is deliberately NOT a screen — it must leave the '
         . 'restored scrollback visible, which is the whole reason it exists');
    like($body, qr/ConnectorHold::terminal_reset_seq/,
         'F3 it still resets the modes claude left enabled');
}


# ===========================================================================
# F2. The launch records WHICH MODE it ran in.
#
# This exists because of how package 12 was found. The operator reported a
# screen "still using the old layout"; the two candidate causes — the launch
# having fallen back to plain, versus a defect in the TUI path — have entirely
# different fixes, and NOTHING on disk could tell them apart after the fact.
# The launch log recorded the container, the session and the heartbeats, but
# never the one decision that governs how every screen renders.
# ===========================================================================
{
    my $at = index($LSRC, "log_ev('launch_mode'");
    ok($at > 0, 'F2-1 the launch logs the mode it chose');

    my $rec = substr($LSRC, $at, 400);
    like($rec, qr/mode\s*=>\s*\$LAUNCH_MODE/, 'F2-2 ... the resolved mode itself');

    # The INPUTS matter as much as the verdict: "mode=plain" alone does not say
    # whether the terminal was not a tty, Term::ReadKey was missing, or the
    # operator had CCPRAXIS_NO_TUI set. Each is a different conversation.
    like($rec, qr/tty\s*=>/,     'F2-3 ... and whether stdio was a tty');
    like($rec, qr/readkey\s*=>/, 'F2-4 ... and whether Term::ReadKey was available');
    like($rec, qr/no_tui\s*=>/,  'F2-5 ... and whether CCPRAXIS_NO_TUI forced it');

    # It must be logged AFTER the log is opened, or every field is discarded.
    my $open_at = index($LSRC, 'LaunchLog::open_log');
    ok($open_at > 0 && $at > $open_at,
       'F2-6 the mode is logged AFTER the log file is opened — before it, log_ev '
     . 'is a silent no-op and the record would never reach disk');
}


# ===========================================================================
# G. Adapter contract Rule 5 — every screen still owes the heartbeat
# ===========================================================================
{
    my $body = extract_sub_body($LSRC, '_launch_run_list');
    ok(defined $body, 'G1 the shared list runner exists');
    like($body, qr/heartbeat\s*=>/,
         'G2 it passes a heartbeat seam — a screen that suspends the render loop '
       . 'still owes the container its keep-alive touch (adapter contract Rule 5)');

    # Both converted prompts go through it, so neither can forget.
    for my $sub (qw(prompt_stale_action kill_orphan_claudes_if_user_confirms)) {
        my $b = extract_sub_body($LSRC, $sub);
        like($b, qr/_launch_run_list/,
             "G3 $sub runs through the shared runner, inheriting the heartbeat");
    }

    # COUNTER-FIXTURE: prove the heartbeat check can fail.
    my $fake = 'sub x { my $r = list_run(model => $m, render => \&p); }';
    unlike($fake, qr/heartbeat\s*=>/,
           'G4 counter-fixture: a runner without a heartbeat seam is detectable '
         . '(if this ever fails, G2 is guarding nothing)');
}


# ===========================================================================
# H. This oracle cannot spawn the launcher
#
# ⚠ THE TOKEN IS ASSEMBLED AT RUNTIME, and the labels below never spell it.
# Written the obvious way, this section fails against ITSELF: a label reading
# "no system() of launcher.pl" contains both halves of the pattern it is
# testing for, and the whole-file scan duly matches it. That is not a
# hypothetical — it fired on the first run of this file (H1 and H2 red, the
# scanned source being their own assertion labels), which is the same
# bare-word-scanner shape that has now bitten several oracles here.
# ===========================================================================
{
    my $self = blank_comments(slurp("$Bin/70-launch-prompt-conversion.t"));
    my $L = 'launcher' . '.pl';

    unlike($self, qr/system\s*\(\s*[^)\n]*\Q$L\E/,  'H1 no system() spawn of the launcher');
    unlike($self, qr/`[^`]*\Q$L\E/,                 'H2 no backtick spawn of the launcher');
    unlike($self, qr/qx[({\/][^\n]*\Q$L\E/,         'H3 no qx spawn of the launcher');
    unlike($self, qr/open\s*\([^)]*\|\s*['"]?[^)]*\Q$L\E/, 'H4 no piped open of the launcher');

    # COUNTER-FIXTURE: the four scans above must be able to FIRE. Without
    # this, assembling the token at runtime could just as easily have made
    # them unsatisfiable — which would read exactly like a clean pass.
    my $bad = "system(\$^X, 'plugins/sandbox/scripts/$L');";
    like($bad, qr/system\s*\(\s*[^)\n]*\Q$L\E/,
         'H5 counter-fixture: a real spawn IS detected '
       . '(if this ever fails, H1 is guarding nothing)');
}

done_testing();
