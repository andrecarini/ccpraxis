#!/usr/bin/env perl
# block-nul-redirect.pl — PreToolUse hook on Bash.
#
# Blocks commands that redirect to `NUL` (case-insensitive), which on Git Bash
# for Windows creates a literal file named `NUL` in the cwd instead of
# discarding output — the Windows NUL device only resolves from cmd.exe /
# PowerShell, not from Git Bash. The resulting stray file is hard to delete
# from Explorer and clutters every repo it lands in. Suggests `/dev/null` as
# the cross-shell-safe alternative.
#
# Wired in global-config/settings.json under hooks.PreToolUse with
# matcher "Bash", so it fires on every Bash tool call from any project.
#
# Spec (Claude Code PreToolUse hook):
#   stdin  — JSON: { tool_name, tool_input: { command, ... }, ... }
#   exit 0 — allow (default; nothing on stdout/stderr)
#   exit 2 — block; stderr is fed back to Claude as the deny reason
#   other  — non-blocking error (logged to the user)

use strict;
use warnings;
use JSON::PP qw(decode_json);

binmode STDIN,  ':raw';
binmode STDERR, ':raw';

local $/;
my $input = <STDIN>;
exit 0 unless defined $input && length $input;

my $payload = eval { decode_json($input) };
exit 0 unless ref $payload eq 'HASH';
exit 0 unless ($payload->{tool_name} // '') eq 'Bash';

my $cmd = $payload->{tool_input}{command} // '';
exit 0 unless length $cmd;

# Match `> NUL`, `>NUL`, `>>NUL`, `2> NUL`, `2>NUL`, `&> NUL`, `&>NUL`, etc.
# Pattern: a `>` (with optional preceding `2`, `&`, or another `>`), then
# optional whitespace, then `NUL` as a word-boundary token. Case-insensitive
# because Windows treats NUL/nul/Nul as the same device.
if ($cmd =~ />>?\s*NUL\b/i) {
    print STDERR
        "Blocked by block-nul-redirect.pl: this Bash command redirects to 'NUL'.\n",
        "  On Git Bash for Windows, '> NUL' creates a literal file named NUL\n",
        "  in the working directory (the NUL device only resolves from cmd.exe\n",
        "  / PowerShell). The resulting stray file is painful to delete.\n",
        "  Use '/dev/null' instead — e.g. '> /dev/null', '2> /dev/null',\n",
        "  '2>&1 > /dev/null'. From PowerShell, use '\$null' (e.g. '*> \$null').\n",
        "  Command attempted: $cmd\n";
    exit 2;
}

exit 0;
