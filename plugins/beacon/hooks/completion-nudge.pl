#!/usr/bin/env perl
# completion-nudge.pl — UserPromptSubmit hook for the beacon plugin.
#
# Detects completion-signal phrases in user prompts and nudges Claude — via
# additionalContext — to consider offering /beacon:off. Never auto-acts; the
# nudge passes through Claude's existing trigger evaluation + mandatory
# AskUserQuestion confirmation gate. This is the propose-only complement to
# the behavioral path documented in skill descriptions and CLAUDE.md.
#
# Hook contract (per code.claude.com/docs/en/hooks):
#   stdin:  { session_id, transcript_path, cwd, permission_mode,
#             hook_event_name: "UserPromptSubmit", prompt }
#   stdout: exit 0 + JSON { hookSpecificOutput: { hookEventName,
#           additionalContext } } → context injected on next model turn
#           exit 0 + no stdout → silent allow
#   On any error → exit 0 silent. A hook MUST NOT block the prompt.
#
# Fires only when ALL of:
#   1. Payload is well-formed and event_name = UserPromptSubmit
#   2. The prompt text contains a known completion-signal phrase
#   3. A beacon record currently exists for this session_id
#
# Optimization: the phrase scan runs BEFORE the beacon.pl subprocess, so the
# common path (most prompts contain no completion phrase) only pays the perl
# cold-start + regex cost — no fork/exec.

use strict;
use warnings;
use JSON::PP;
use IPC::Open3;
use Symbol 'gensym';
use FindBin qw($Bin);

my $payload = do { local $/; <STDIN> };
exit 0 unless defined $payload && length $payload;

my $data = eval { decode_json($payload) };
exit 0 unless $data && ref $data eq 'HASH';
exit 0 unless ($data->{hook_event_name} // '') eq 'UserPromptSubmit';

my $session_id = $data->{session_id} // '';
my $prompt     = $data->{prompt}     // '';
exit 0 unless length $session_id && length $prompt;

# 1. Cheap regex — skip the subprocess in the common no-signal case. Errs on
#    the side of catching more; Claude does the fine-grained sub-task vs
#    session-completion judgment on its next turn with full conversation
#    context.
exit 0 unless prompt_has_completion_signal($prompt);

# 2. Confirm a beacon exists. Sibling beacon.pl resolves vault + sandbox +
#    registered-sandbox-projects paths uniformly. Shelled via Open3 with
#    stdout/stderr drained so the script's STATUS/JSON output doesn't leak
#    into THIS hook's stdout (where it would be misread as additionalContext).
my $beacon_pl = "$Bin/../scripts/beacon.pl";
exit 0 unless -f $beacon_pl;

my $exit_code = run_silently('perl', $beacon_pl, 'get', '--session-id', $session_id);
# exit 0 = found (the only path that triggers a nudge)
# exit 2 = not_found → no beacon, no nudge
# exit 1 = error (malformed payload, corrupt record) → silent (defensive)
exit 0 unless $exit_code == 0;

# 3. Emit the nudge. Claude Code wraps additionalContext in a system reminder
#    on the next model turn; the user does not see it as a chat message.
print encode_json({
    hookSpecificOutput => {
        hookEventName     => "UserPromptSubmit",
        additionalContext =>
              "[beacon] This session has an active beacon AND the user's message contains a possible completion signal. "
            . "Per the /beacon:off trigger contract, evaluate whether the user is signaling that the SESSION's work is "
            . "finished (vs. a sub-task or meta-acknowledgment like \"done with X, now Y\" or \"done reading\"). "
            . "If yes, ASK the user via AskUserQuestion BEFORE invoking /beacon:off — this is a proactive invocation, "
            . "so consent must come first. (Direct slash-command invocation is its own consent and skips the question.)",
    },
});

exit 0;

# ── Helpers ───────────────────────────────────────────────────────────

# Word-boundary, case-insensitive regex over a hand-tuned phrase set.
# Mirrors the description's phrase list; multi-word phrases tried first so
# the single-word alternation doesn't pre-match a fragment.
sub prompt_has_completion_signal {
    my $text = shift;
    return 1 if $text =~ m{\b(?:
        let'?s\s+call\s+it           |
        call\s+it\s+(?:a\s+day|done) |
        wrapping\s+up                |
        ship(?:ped)?\s+it            |
        pr(?:'s)?\s+(?:up|opened|out|merged) |
        that'?s\s+(?:it|a\s+wrap|all)        |
        we'?re\s+(?:good|done)       |
        all\s+good                   |
        looks?\s+good                |
        done\s+for\s+(?:now|today)   |
        for\s+today                  |
        ship\s+it
    )\b}xi;
    return 1 if $text =~ m{\b(?:done|shipped|merged|deployed|landed|committed|finished|complete|lgtm|wrapped)\b}i;
    return 0;
}

# Spawn child via Open3, drain stdout+stderr (neither must leak into our own
# stdout — the hook contract treats any non-JSON text on stdout as
# additionalContext), return the child's exit code. Mirrors beacon.pl's
# run_cmd. Returns -1 on spawn failure (treated as "not 0" → silent).
sub run_silently {
    my @cmd = @_;
    my $in  = gensym();
    my $out = gensym();
    my $err = gensym();
    my $pid = eval { open3($in, $out, $err, @cmd) };
    return -1 if !$pid || $@;
    close $in;
    do { local $/; <$out> };
    do { local $/; <$err> };
    close $out;
    close $err;
    waitpid($pid, 0);
    return $? >> 8;
}
