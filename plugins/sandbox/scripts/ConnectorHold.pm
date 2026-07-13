package ConnectorHold;
# Fix 3 — a connector window must not vanish silently when the sandbox dies.
#
# The dashboard's [c] hotkey spawns a fresh Windows Terminal tab running
# `claude-sandbox --session`, which connects via `podman exec -it ... claude`.
# When the podman engine or the container dies mid-session the exec drops,
# `claude` exits nonzero, and (historically) the launcher did `exit $rc` — so
# Windows Terminal closed the tab with no explanation. The conversation was
# always SAFE (session jsonl is written to claude-home/ continuously), but the
# user lost their window and any context about WHY.
#
# This module is the PURE decision + the diagnostic message. The launcher does
# the actual State.Status probe and the keypress-hold; keeping the decision and
# the wording here makes both unit-testable on the host with no container.
use strict;
use warnings;

# should_hold_window($claude_rc, $container_state) -> 1|0
#   Hold the window open ONLY when claude exited nonzero AND the container is no
#   longer running — i.e. the connection was LOST (engine/container died). We do
#   NOT hold on:
#     - a clean user quit (rc 0), whatever the container state, and
#     - a claude-level error while the container is STILL running (rc != 0 but
#       state 'running') — that's not a lost sandbox, and the existing
#       tab-closes behavior is fine there.
#   $container_state is podman's `{{.State.Status}}` string: 'running',
#   'exited', 'stopped', or ''/undef when `inspect` found no such container
#   (it was removed) — all of the latter mean "not running".
sub should_hold_window {
    my ($rc, $state) = @_;
    return 0 unless defined $rc;
    $state = defined $state ? $state : '';
    return ($rc != 0 && $state ne 'running') ? 1 : 0;
}

# lost_message($container_name) -> the diagnostic printed before the hold.
# Plain text only (no ANSI); the container name is launcher-derived, not
# attacker-influenced, but we still keep it on its own labeled line.
sub lost_message {
    my ($name) = @_;
    $name = (defined $name && length $name) ? $name : '(unknown)';
    return join("\n",
        "",
        "============================================================",
        "  Connection to the sandbox was LOST",
        "============================================================",
        "  The container is no longer running — the podman engine or",
        "  the container stopped while your session was connected.",
        "",
        "  Your conversation is SAFE. Session history is written to",
        "  disk continuously (in claude-home/), so nothing was lost.",
        "",
        "  To get back in:",
        "    1. run  claude-sandbox   (restarts the sandbox + dashboard)",
        "    2. pick this session from the resume picker, or press [c]",
        "       in the dashboard to start a new connector.",
        "",
        "  Container: $name",
        "============================================================",
        "",
    ) . "\n";
}

# terminal_reset_seq() -> the ANSI bytes to emit BEFORE holding the window open.
# The connector ran `claude` (a full-screen TUI). When the `podman exec` dropped
# (engine/container death) claude was killed WITHOUT its normal teardown, so the
# terminal modes it had turned ON are still on: mouse reporting (?1000 click,
# ?1002 drag, ?1003 any-motion, plus the ?1006 SGR / ?1015 urxvt encodings) and
# focus-event reporting (?1004). With those live, merely CLICKING the tab to
# focus it (or moving the mouse across it) makes the terminal emit an escape
# sequence — which the hold's key-read consumed, so the window vanished the
# instant the user touched it. Turn those modes (and bracketed paste ?2004) back
# off so no stray sequence is generated, then wait for a real Enter. Disabling a
# mode that wasn't on is a harmless no-op.
sub terminal_reset_seq {
    return "\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1015l\e[?1004l\e[?2004l";
}

# is_dismiss_key($key) -> 1 iff $key should close the held window. Per the user's
# request the window closes ONLY on Enter (CR or LF) — never on a stray byte from
# a focus/mouse event or an incidental keypress. undef/empty are non-dismissing
# (a non-blocking read with nothing pending must not close the window).
sub is_dismiss_key {
    my ($k) = @_;
    return 0 unless defined $k;
    return ($k eq "\r" || $k eq "\n") ? 1 : 0;
}

1;
