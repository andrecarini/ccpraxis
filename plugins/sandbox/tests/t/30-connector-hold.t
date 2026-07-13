#!/usr/bin/env perl
# Fix 3 — ConnectorHold: when a connector's `podman exec -it ... claude` drops
# because the engine/container died (vs a clean user quit), the launcher must
# hold the Windows Terminal tab open with a diagnostic instead of vanishing.
# The decision + message are pure (no container) so they're unit-tested here;
# the actual State.Status probe + keypress-hold live in launcher.pl.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use ConnectorHold;

plan tests => 25;

# ---- should_hold_window($rc, $state) ----------------------------------------
# Clean user quit -> never hold, whatever the container is doing.
is(ConnectorHold::should_hold_window(0, 'running'), 0, 'clean quit + running -> no hold');
is(ConnectorHold::should_hold_window(0, 'exited'),  0, 'clean quit + exited  -> no hold');
is(ConnectorHold::should_hold_window(0, ''),        0, 'clean quit + gone    -> no hold');

# claude error while the container is STILL running -> not a lost sandbox.
is(ConnectorHold::should_hold_window(1,   'running'), 0, 'claude error + running -> no hold (not a lost container)');
is(ConnectorHold::should_hold_window(137, 'running'), 0, 'SIGKILL rc + running    -> no hold');

# LOST container: nonzero exit AND not running -> hold.
is(ConnectorHold::should_hold_window(1,   'exited'),  1, 'nonzero + exited  -> HOLD');
is(ConnectorHold::should_hold_window(1,   'stopped'), 1, 'nonzero + stopped -> HOLD');
is(ConnectorHold::should_hold_window(137, ''),        1, 'nonzero + gone (empty status) -> HOLD');
is(ConnectorHold::should_hold_window(1,   undef),     1, 'nonzero + undef status (inspect failed) -> HOLD');

# Defensive: an undefined rc never holds.
is(ConnectorHold::should_hold_window(undef, ''), 0, 'undef rc -> no hold (defensive)');

# ---- lost_message($name) ----------------------------------------------------
my $msg = ConnectorHold::lost_message('claude-myproj-abc123');
like($msg, qr/\bLOST\b/,                      'message announces the connection was LOST');
like($msg, qr/claude-myproj-abc123/,          'message names the container');
like($msg, qr/conversation is SAFE/i,         'message reassures the conversation is safe');
like($msg, qr/claude-sandbox/,                'message tells the user how to resume');

# ---- is_dismiss_key($key) ---------------------------------------------------
# The held window closes ONLY on Enter (CR/LF) — never on a stray focus/mouse
# byte or an incidental key, so focusing the tab can't dismiss it.
is(ConnectorHold::is_dismiss_key("\r"),  1, 'CR (Enter) dismisses');
is(ConnectorHold::is_dismiss_key("\n"),  1, 'LF (Enter) dismisses');
is(ConnectorHold::is_dismiss_key('a'),   0, 'a letter does not dismiss');
is(ConnectorHold::is_dismiss_key(' '),   0, 'space does not dismiss');
is(ConnectorHold::is_dismiss_key("\e"),  0, 'a lone ESC (focus/mouse seq lead) does not dismiss');
is(ConnectorHold::is_dismiss_key(''),    0, 'empty string does not dismiss');
is(ConnectorHold::is_dismiss_key(undef), 0, 'undef (no key pending) does not dismiss');

# ---- terminal_reset_seq() ---------------------------------------------------
# Emitted before the hold to turn off the mouse/focus modes claude left on, so
# touching the window can't generate a sequence the read would consume.
my $seq = ConnectorHold::terminal_reset_seq();
is(substr($seq, 0, 1), "\e",       'reset sequence starts with ESC');
like($seq, qr/\Q?1004l\E/,         'disables focus-event reporting (?1004l)');
like($seq, qr/\Q?1000l\E/,         'disables mouse click reporting (?1000l)');
unlike($seq, qr/\n/,               'reset sequence emits no newline');
