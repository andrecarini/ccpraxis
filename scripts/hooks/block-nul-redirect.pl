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
#
# DELIBERATELY TEXT-ONLY, WITH NO QUOTE AWARENESS. It cannot tell a real
# redirect from the same characters appearing inside a search pattern or a
# string literal, so it also blocks `grep '>NUL' .` and a test fixture that
# quotes the shape. Those are false positives and they are real: three fired
# in one session on 2026-09-06, one of them while writing the regression test
# for the very bug this hook guards.
#
# The fix is NOT to make the regex quote-aware. That looks obvious and has a
# hole: `cmd 2>"NUL"` quotes the TARGET and still creates the file, so
# stripping quoted spans before matching would let a genuine redirect through.
# False negatives here cost an undeletable file; false positives cost a retry.
# The strictness stays.
#
# Instead there is an explicit escape hatch, below: the caller asserts, in
# words, that this particular command is a mention rather than a redirect. The
# assertion is deliberate, visible in the command itself, and logged.
# The optional ['"] is not cosmetic. `cmd 2>"NUL"` quotes the TARGET and still
# creates the file — quoting a redirect target changes nothing about the
# redirection — and without it this pattern let that form straight through.
# Found on 2026-09-07 by t/17 while pinning the shapes; the hook had shipped
# with the hole since it was written.
if ($cmd =~ />>?\s*['"]?NUL\b/i) {

    # ESCAPE HATCH: CCPRAXIS_ALLOW_NUL=<reason>
    #
    # Written as a shell variable assignment so the command still RUNS
    # correctly (`VAR=x cmd` is ordinary bash) while being plainly visible to a
    # human reading it. The reason must be substantive -- a bare `=1` is
    # rejected -- because the point is to make the override an assertion
    # somebody stands behind, not a reflex for getting past a block.
    if ($cmd =~ /CCPRAXIS_ALLOW_NUL=(?:"([^"]*)"|'([^']*)'|(\S+))/) {
        my $reason = defined $1 ? $1 : defined $2 ? $2 : (defined $3 ? $3 : '');
        $reason =~ s/^\s+|\s+$//g;

        if (length($reason) >= 6 && $reason =~ /[A-Za-z]/) {
            # Best-effort audit trail. An override that leaves no trace is a
            # silently weakened guard; this keeps it reviewable after the fact
            # without putting noise in the conversation.
            my $home = $ENV{HOME} // $ENV{USERPROFILE};
            if (defined $home && length $home) {
                $home =~ s{\\}{/}g;
                # One mkdir, best-effort. Without it the append silently fails
                # wherever ~/.claude does not exist yet, and a log that quietly
                # does not write is worse than no log: it looks like an audit
                # trail while recording nothing.
                mkdir "$home/.claude" unless -d "$home/.claude";
                if (open my $log, '>>', "$home/.claude/.nul-overrides.log") {
                    my @t = gmtime(time);
                    printf {$log} "%04d-%02d-%02dT%02d:%02d:%02dZ\t%s\t%s\n",
                        $t[5]+1900, $t[4]+1, @t[3,2,1,0], $reason, $cmd;
                    close $log;
                }
            }
            exit 0;
        }

        print STDERR
            "Blocked by block-nul-redirect.pl: CCPRAXIS_ALLOW_NUL needs a real reason.\n",
            "  Got: '$reason'\n",
            "  The override exists so you can state WHY this is a false positive,\n",
            "  not to wave the check through. Give at least 6 characters including\n",
            "  a letter, e.g.:\n",
            "    CCPRAXIS_ALLOW_NUL=\"search pattern, not a redirect\" grep ...\n";
        exit 2;
    }

    print STDERR
        "Blocked by block-nul-redirect.pl: this Bash command redirects to 'NUL'.\n",
        "  On Git Bash for Windows, '> NUL' creates a literal file named NUL\n",
        "  in the working directory (the NUL device only resolves from cmd.exe\n",
        "  / PowerShell). The resulting stray file is painful to delete.\n",
        "  Use '/dev/null' instead — e.g. '> /dev/null', '2> /dev/null',\n",
        "  '2>&1 > /dev/null'. From PowerShell, use '\$null' (e.g. '*> \$null').\n",
        "\n",
        "  FALSE POSITIVE? This check reads the command as text and cannot tell a\n",
        "  redirect from the same characters inside a search pattern or a string\n",
        "  literal. If nothing here actually redirects — you are grepping for the\n",
        "  pattern, or quoting it as test data — retry with an explicit reason:\n",
        "    CCPRAXIS_ALLOW_NUL=\"search pattern, not a redirect\" <your command>\n",
        "  It runs as an ordinary shell assignment, and the override is logged to\n",
        "  ~/.claude/.nul-overrides.log. Do NOT use it to force through a command\n",
        "  that really does redirect — it will create the file.\n",
        "  Command attempted: $cmd\n";
    exit 2;
}

exit 0;
