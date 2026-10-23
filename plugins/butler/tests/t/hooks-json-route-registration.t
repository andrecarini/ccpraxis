#!/usr/bin/env perl
# platform: any
# REWRITTEN oracle for batch B of blueprint hook-continuity-remake, package
# 16-cutover (specs/16-cutover-spec.md sec 2.2/2.3/2.4, acceptance B-1).
#
# The file's ORIGINAL subject (guard-bash.sh's predecessors'
# settings.json-vs-hooks.json route, packages g02/h01)
# is retired here rather than carried: both scripts are on the batch-B
# deletion list (spec sec 4 batch-B file list), so a route decision about a
# deleted script cannot be an oracle for the tree this package leaves behind.
# What replaces it is the full sec 2.3 target registration set: the exact
# (event, matcher, file, args) multiset hooks.json must decode to, that every
# command string is byte-identical to the sec 2.2 template for its own file
# and args, and that every named file actually exists directly under
# plugins/butler/hooks/ (never hooks/next/).
#
# READ-ONLY against the tracked hooks.json and the hooks/ directory listing --
# never writes to either. Runs standalone: perl this file.
#
# RIGHT NOW (before batch B lands) this file is red: hooks.json still carries
# the pre-cutover 30-ish-command layout and the sec 2.3 files still live under
# hooks/next/ and hooks/next/guards/, not directly under hooks/. That is the
# correct shape of red for an oracle written from the spec, not from the
# unfinished tree.

use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 } # package 16 post-fix-batch (Decision 80): this file names a wake-lock actuator, in prose or a path check, never a real invocation -- the guard is the cheap side of test-wakelock-hygiene.t's deliberate over-matching.
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $HOOKS_DIR  = "$REPO_ROOT/plugins/butler/hooks";
my $HOOKS_JSON = "$HOOKS_DIR/hooks.json";

ok(-f $HOOKS_JSON, 'hooks.json exists') or BAIL_OUT('no hooks.json');

sub read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or BAIL_OUT("cannot open $path: $!");
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return ($doc, $raw, $@);
}

my ($doc, $raw, $err) = read_json($HOOKS_JSON);
unless (ref $doc eq 'HASH') {
    fail('A1: hooks.json parses as an object');
    diag("decode failed: $err");
    BAIL_OUT('unparseable hooks.json');
}
pass('A1: hooks.json parses as an object');

# ---------------------------------------------------------------------------
# sec 2.2 template builder. <args> is '' or ' --only-during-butler-run' (one
# leading space, per spec). ${CLAUDE_PLUGIN_ROOT} form for hooks.json.
# ---------------------------------------------------------------------------
sub hooksjson_template {
    my ($file, $args) = @_;
    $args //= '';
    return qq{unset BASH_ENV ; f="\${CLAUDE_PLUGIN_ROOT}/hooks/$file" ; w="\${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" ; [ -f "\$f" ] && [ -f "\$w" ] || exit 0 ; bash -n "\$f" 2>/dev/null && bash -n "\$w" 2>/dev/null || exit 0 ; exec env -u SHELLOPTS bash "\$f"$args};
}

# ---------------------------------------------------------------------------
# sec 2.3's target set for hooks.json -- 18 commands. A group with an empty
# matcher string below means "no matcher key" in the decoded JSON.
# ---------------------------------------------------------------------------
my @EXPECT = (
    { event => 'PreToolUse',  matcher => 'Bash',                                        file => 'guard-bash.sh',              args => '' },
    { event => 'PreToolUse',  matcher => 'Bash',                                        file => 'guard-git-mutations.sh',     args => ' --only-during-butler-run' },
    { event => 'PreToolUse',  matcher => 'Bash',                                        file => 'arm-on-entry.sh',            args => '' },
    { event => 'PreToolUse',  matcher => 'Bash',                                        file => 'continuity-off-check.sh',    args => '' },
    { event => 'PreToolUse',  matcher => 'Edit|Write|MultiEdit|NotebookEdit',           file => 'guard-writes.sh',            args => '' },
    { event => 'PreToolUse',  matcher => 'Edit|Write|MultiEdit|NotebookEdit',           file => 'ledger-guard.sh',             args => '' },
    { event => 'PreToolUse',  matcher => 'Edit|Write|MultiEdit|NotebookEdit',           file => 'guard-blueprint-write.sh',    args => '' },
    { event => 'PreToolUse',  matcher => 'Edit|Write|MultiEdit|NotebookEdit|Task|Agent', file => 'gate-shutdown.sh',           args => '' },
    { event => 'PreToolUse',  matcher => 'Task|Agent',                                  file => 'bind-dispatch.sh',            args => '' },
    { event => 'PreToolUse',  matcher => 'Task|Agent',                                  file => 'track-dispatch.sh',           args => '' },
    { event => 'PreToolUse',  matcher => 'Task|Agent|Bash',                             file => 'context-ceiling.sh',          args => '' },
    { event => 'PreToolUse',  matcher => 'Task|Agent',                                  file => 'guard-fork.sh',               args => '' },
    { event => 'PreToolUse',  matcher => '',                                            file => 'wait-shape-guard.sh',         args => '' },
    { event => 'PreToolUse',  matcher => 'AskUserQuestion',                             file => 'guard-ask-operator.sh',       args => '' },
    { event => 'PostToolUse', matcher => 'Task|Agent',                                  file => 'track-dispatch.sh',           args => '' },
    { event => 'PostToolUse', matcher => 'Task|Agent|Bash',                             file => 'context-ceiling.sh',          args => '' },
    { event => 'SubagentStop',matcher => '',                                            file => 'track-dispatch.sh',           args => '' },
    { event => 'Stop',        matcher => '',                                            file => 'stop-gate.sh',                args => '' },
    # never-halt package 06 (Decision 9/40): Notification/PermissionDenied
    # record-only hooks, registered through the same guarded 2.2 template.
    { event => 'Notification',      matcher => 'permission_prompt', file => 'record-prompt.sh', args => '' },
    { event => 'PermissionDenied',  matcher => '',                  file => 'record-denial.sh', args => '' },
    # never-halt package 07 (Decision 15, spec sec 2.10): denial-breaker.sh is
    # registered 4x, no matcher, one new PostToolUseFailure top-level key, plus
    # a SessionStart registration (FIX-3) resetting the per-session
    # total_since offset so a resumed session isn't permanently falsely
    # tripped.
    { event => 'PreToolUse',          matcher => '', file => 'denial-breaker.sh', args => '' },
    { event => 'PostToolUse',         matcher => '', file => 'denial-breaker.sh', args => '' },
    { event => 'PostToolUseFailure',  matcher => '', file => 'denial-breaker.sh', args => '' },
    { event => 'SessionStart',        matcher => '', file => 'denial-breaker.sh', args => '' },
    # never-halt package 11 (Decision 43, N3): a new UserPromptSubmit route,
    # no matcher, guarded 2.2 template, arm-nudge-prompt.sh.
    { event => 'UserPromptSubmit',    matcher => '', file => 'arm-nudge-prompt.sh', args => '' },
    # never-halt package 12 (Decision 43, N6/N1-now): a second, matcher-less
    # SessionStart group, after denial-breaker.sh's, guarded 2.2 template,
    # session-start-nudge.sh.
    { event => 'SessionStart',        matcher => '', file => 'session-start-nudge.sh', args => '' },
    # package 11-ac-loss-clean-suspend-cycle (tooling-backlog blueprint, spec
    # sec 2.9): a new matcher-less PreToolUse group, guarded 2.2 template,
    # ac-standdown-gate.sh -- the PreToolUse guard that refuses subagent tool
    # calls while an AC-loss stand-down is in effect.
    { event => 'PreToolUse',          matcher => '', file => 'ac-standdown-gate.sh', args => '' },
    # judged-continuity-disarm package 03 (spec sec 2.5.4): a 5th entry in the
    # existing PreToolUse Bash group, after continuity-off-check.sh, guarded
    # 2.2 template, guard-disarm-judge-readonly.sh -- restricts the disarm
    # judge's own Bash to the Decision-7 read-only allowlist.
    { event => 'PreToolUse',  matcher => 'Bash',                                        file => 'guard-disarm-judge-readonly.sh', args => '' },
    # 2026-10-23 continuity-state guard (operator ruling: guidance, not a
    # security boundary): its own PreToolUse group on the shell and edit
    # tools, guarded 2.2 template, guard-continuity-state.sh.
    { event => 'PreToolUse',  matcher => 'Bash|Edit|Write|MultiEdit|NotebookEdit',      file => 'guard-continuity-state.sh', args => '' },
);
is(scalar(@EXPECT), 29, 'sanity: this file\'s own sec 2.3 fixture table has 29 rows (never-halt 06 adds 2, never-halt 07 adds 4, never-halt 11 adds 1, never-halt 12 adds 1, tooling-backlog package 11 adds 1, judged-continuity-disarm package 03 adds 1, the continuity-state guard adds 1)');

sub expect_key { my ($r) = @_; return join("\x1e", $r->{event}, $r->{matcher}, $r->{file}, $r->{args}) }

# ---------------------------------------------------------------------------
# B1: decode every actual (event, matcher, command) entry, extract its file
# name (first .sh-ending token per sec 2.2) and infer which of '' /
# ' --only-during-butler-run' the command's args tail equals -- WITHOUT
# assuming the command already matches the sec 2.2 template (it may be the
# stale pre-cutover form entirely).
# ---------------------------------------------------------------------------
my @actual;
my @template_mismatches;
if (ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH') {
    for my $event (sort keys %{ $doc->{hooks} }) {
        for my $group (@{ $doc->{hooks}{$event} // [] }) {
            next unless ref $group eq 'HASH';
            my $matcher = defined $group->{matcher} ? $group->{matcher} : '';
            for my $h (@{ $group->{hooks} // [] }) {
                next unless ref $h eq 'HASH';
                my $cmd = $h->{command} // '';
                my ($file) = $cmd =~ m{([A-Za-z0-9_.-]+\.sh)};
                $file //= '';
                my $args = '';
                $args = ' --only-during-butler-run' if $cmd =~ /--only-during-butler-run\z/;
                my $expected_cmd = length($file) ? hooksjson_template($file, $args) : '';
                push @template_mismatches, "$event/$matcher: $cmd"
                    unless length($file) && $cmd eq $expected_cmd;
                push @actual, { event => $event, matcher => $matcher, file => $file, args => $args, command => $cmd };
            }
        }
    }
}

my @expect_keys = sort map { expect_key($_) } @EXPECT;
my @actual_keys = sort map { expect_key($_) } @actual;
is_deeply(\@actual_keys, \@expect_keys,
    'B1a: hooks.json\'s (event, matcher, file, args) multiset equals sec 2.3 exactly (28 commands)')
    or diag("actual:\n" . join("\n", @actual_keys) . "\nexpected:\n" . join("\n", @expect_keys));

is(scalar(@template_mismatches), 0,
    'B1b: every command string in hooks.json equals the sec 2.2 template for its own file and args')
    or diag("mismatched commands:\n" . join("\n", @template_mismatches));

# ---------------------------------------------------------------------------
# B1c: every <file> named in sec 2.3 exists directly under
# plugins/butler/hooks/ (never only under hooks/next/ or hooks/next/guards/).
# ---------------------------------------------------------------------------
my %want_file = map { $_->{file} => 1 } @EXPECT;
my @missing = grep { !-f "$HOOKS_DIR/$_" } sort keys %want_file;
is(scalar(@missing), 0,
    'B1c: every sec 2.3 <file> exists directly under plugins/butler/hooks/')
    or diag('missing under hooks/ (top level): ' . join(', ', @missing));

# ===========================================================================
# AC-18 (blueprint where-things-go, package 10-gatherer-and-digest spec
# sec 4): session-start-nudge.sh is registered exactly once, matcher-less,
# on SessionStart (already proven above via @EXPECT/B1a: it is the only
# entry anywhere with file session-start-nudge.sh, and its matcher is '').
# No OTHER registered command's own script file mentions Gather,
# almanac-gather or reattach -- the one SessionStart route this package adds
# must stay the ONLY caller of the new gatherer. The SessionStart command
# set is exactly {denial-breaker.sh, session-start-nudge.sh} (already proven
# above via @files).
# ===========================================================================
{
    my @nudge_entries = grep { $_->{file} eq 'session-start-nudge.sh' } @actual;
    is(scalar(@nudge_entries), 1,
        'AC-18: session-start-nudge.sh is registered exactly once across all of hooks.json');
    ok((!@nudge_entries || $nudge_entries[0]{matcher} eq ''),
        'AC-18: session-start-nudge.sh\'s one registration is matcher-less')
        if @nudge_entries;

    my @session_start_files = sort map { $_->{file} } grep { $_->{event} eq 'SessionStart' } @actual;
    is_deeply(\@session_start_files, ['denial-breaker.sh', 'session-start-nudge.sh'],
        'AC-18: the SessionStart command set is exactly {denial-breaker.sh, session-start-nudge.sh}');

    my %other_files = map { ($_->{file} => 1) } grep { $_->{file} ne 'session-start-nudge.sh' } @actual;
    my @leaked;
    for my $f (sort keys %other_files) {
        my $path = "$HOOKS_DIR/$f";
        next unless -f $path;
        my $src = _read_file_raw($path);
        for my $needle (qw(Gather almanac-gather reattach)) {
            push @leaked, "$f mentions '$needle'" if index($src, $needle) >= 0;
        }
    }
    is(scalar(@leaked), 0,
        'AC-18: no other registered command\'s script references Gather, almanac-gather or reattach')
        or diag(join("\n", @leaked));
}

sub _read_file_raw {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

done_testing();
