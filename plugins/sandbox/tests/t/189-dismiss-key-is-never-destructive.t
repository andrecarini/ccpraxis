#!/usr/bin/env perl
# t/189 -- the key that DISMISSES on one screen must not DESTROY on another.
#
# Bug 20260908-193156-2cee, mechanism 2. The operator's words were "there's an
# issue with every instance where [d] appears on screen, and it needs to be
# sorted out". Two of the four mechanisms in that report were about the hint
# lying (t/183 pins those). This one is about the key itself:
#
#   Dashboard        'd' -> dismiss a banner        benign, reversible
#   BackpackScreen   'd' -> drop an item            permanent (DROP_WARNING)
#
# Same letter, two screens, and on one of them it destroys something. An
# operator learns 'd' on the dashboard -- the screen they are looking at nearly
# all the time -- and carries the reflex into the backpack screen, which they
# visit occasionally.
#
# THE DESTRUCTIVE ONE MOVED, not the benign one, on two grounds. Muscle memory
# flows from the constant screen to the occasional one, so the occasional screen
# is where a surprise costs least. And 'x' already meant "tear this down, with a
# confirm" on the dashboard (full-shutdown), so what this leaves behind is a
# pairing an operator can actually hold: 'd' never destroys anything anywhere,
# 'x' always asks first.
#
# The dismiss key is DERIVED here rather than hardcoded. A test that spelled
# 'd' twice would keep passing if the dashboard rebound dismiss to some other
# letter that the backpack screen also happened to use destructively -- which is
# precisely the bug, reintroduced, with the guard still green.
use strict;
use warnings;
use Test::More;
use lib 'plugins/sandbox/scripts';

require Dashboard;
require tui::BackpackScreen;

# --- Find the dashboard's dismiss key, by asking the dashboard. --------------
my @dismiss_keys;
for my $k ('a' .. 'z', 'A' .. 'Z') {
    my ($action) = Dashboard::dispatch_key($k, '');
    push @dismiss_keys, $k if defined($action) && $action eq 'dismiss-install-warning';
}
is(scalar @dismiss_keys, 1, 'A1: exactly one key on the dashboard dismisses banners')
    or diag("dismiss keys: @dismiss_keys");
my $DISMISS = $dismiss_keys[0] // 'd';
is($DISMISS, 'd', 'A2: and it is still the one the banner labels, [d]');

# --- Find every key the backpack screen treats as destructive. ---------------
sub bp_state {
    return tui::BackpackScreen::init(
        items     => [ { category => 'cat', name => 'zq189', install => 'i', verify => 'v' } ],
        approvals => {},
        remove    => sub { return (1, {}) },
    );
}

my @destructive;
for my $k ('a' .. 'z', 'A' .. 'Z') {
    my $ss = bp_state();
    $ss->{cursor} = 0;
    my $action = tui::BackpackScreen::dispatch_key($ss, $k);
    push @destructive, $k
        if defined($action) && ($action eq 'confirm-drop' || $action eq 'drop');
}

is(scalar @destructive, 1, 'B1: exactly one key on the backpack screen arms a drop')
    or diag("destructive keys: @destructive");
my $DROP = $destructive[0] // '';

# THE INVARIANT. ------------------------------------------------------------
isnt($DROP, $DISMISS,
     "C1: the backpack screen's destructive key ('$DROP') is not the dashboard's "
   . "dismiss key ('$DISMISS')");

{
    my $ss = bp_state();
    $ss->{cursor} = 0;
    my $action = tui::BackpackScreen::dispatch_key($ss, $DISMISS);
    is($action, '', "C2: '$DISMISS' on the backpack screen returns no action at all");
    # init() seeds confirm => undef, so `exists` is always true here -- an
    # armed confirm is specifically a HASH.
    isnt(ref($ss->{confirm}), 'HASH',
         "C2: and arms nothing -- an operator arriving with dashboard reflexes destroys nothing");
}

# --- The re-key must not have cost the confirm gate. -------------------------
{
    my @removed;
    my $seams = { items     => [ { category => 'cat', name => 'zq189b', install => 'i', verify => 'v' } ],
                  approvals => {},
                  remove    => sub { push @removed, $_[0]; return (1, {}) } };
    my $ss = tui::BackpackScreen::init(%$seams);
    $ss->{cursor} = 0;

    my $arm = tui::BackpackScreen::dispatch_key($ss, $DROP);
    is($arm, 'confirm-drop', "D1: '$DROP' arms the confirm rather than dropping outright");
    tui::BackpackScreen::apply($ss, $arm, $seams);
    is(scalar @removed, 0, 'D1: nothing removed on the arming keypress');

    my $cancel = tui::BackpackScreen::dispatch_key($ss, 'n');
    is($cancel, 'cancel-drop', 'D2: any other key still cancels');
    tui::BackpackScreen::apply($ss, $cancel, $seams);
    is(scalar @removed, 0, 'D2: and nothing was removed');

    # And the confirmed path still works -- a guard that broke drop entirely
    # would satisfy every assertion above.
    my $arm2 = tui::BackpackScreen::dispatch_key($ss, $DROP);
    tui::BackpackScreen::apply($ss, $arm2, $seams);
    my $yes = tui::BackpackScreen::dispatch_key($ss, 'y');
    is($yes, 'drop', 'D3: y after arming still confirms');
    tui::BackpackScreen::apply($ss, $yes, $seams);
    is(scalar @removed, 1, 'D3: and the item is actually dropped -- the gate moved, it did not vanish');
}

# --- The footer must advertise what is actually bound. -----------------------
{
    my $footer = tui::BackpackScreen::FOOTER_LEGEND();
    like($footer, qr/\[\Q$DROP\E\] drop/,
         "E1: the footer advertises '[$DROP] drop', the key that is really bound");
    unlike($footer, qr/\[\Q$DISMISS\E\]/,
           "E2: and never offers '[$DISMISS]' on a screen where it does nothing");
}

# The action vocabulary is unchanged: the key moved, nothing downstream did.
{
    my $ss = bp_state();
    $ss->{cursor} = 0;
    is(tui::BackpackScreen::dispatch_key($ss, $DROP), 'confirm-drop',
       'F1: the action token is still confirm-drop, so no caller had to change');
}

done_testing();
