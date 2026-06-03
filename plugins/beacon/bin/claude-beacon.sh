#!/bin/bash
# claude-beacon — TUI for selecting and resuming a beaconed Claude Code session.
# All logic lives in claude-beacon.pl; this script just locates the plugin and execs.
exec perl "$HOME/.claude/ccpraxis/plugins/beacon/scripts/claude-beacon.pl" "$@"
