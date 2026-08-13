#!/usr/bin/env perl
# 122-h01-settings-registration.t — oracle for h01's registration DECISION
# (spec §2.5): gate-headless-background.sh and guard-judge-checks.sh register
# ONLY in .claude/settings.json, never in plugins/butler/hooks/hooks.json.
#
# WHY THIS MATTERS ON ITS OWN, separately from the scripts existing at all.
# The architect traced bp-launch.sh:112 and bp-judge.sh:169 and found both
# `cd "$PROJECT_ROOT"` immediately before `claude -p ...` with no `--settings`
# override, so .claude/settings.json (tracked, live in THIS clone immediately)
# already reaches coordinator AND judge sessions — the identical mechanism
# guard-git-mutations.sh and guard-subagent-stall.sh already rely on.
# hooks.json, by contrast, is plugin code served from the PROMOTED live
# install (~/.claude/ccpraxis) and only takes effect after a merge. A hook
# that exists but is registered nowhere live is inert — this is the package's
# own stated "central failure mode" (dispatch prompt), and it applies to
# REGISTRATION as much as to the script's existence. This file pins the
# registration; 119/121 pin the scripts' behavior once invoked.
#
# NEVER MUTATES the real .claude/settings.json — read-only assertions against
# the tracked file, exactly like plugins/sandbox/tests/t/61-settings-scope-split.t's
# C5 section, which already establishes this read-only pattern for the same
# file.
#
# Runs standalone: perl plugins/butler/tests/t/122-h01-settings-registration.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $SETTINGS = "$REPO_ROOT/.claude/settings.json";
my $HOOKS_JSON = "$REPO_ROOT/plugins/butler/hooks/hooks.json";

ok(-f $SETTINGS, '.claude/settings.json exists (tracked, per CLAUDE.md)') or BAIL_OUT('no settings.json');
ok(-f $HOOKS_JSON, 'hooks.json exists') or BAIL_OUT('no hooks.json');

sub read_json {
    my ($path) = @_;
    open my $fh, '<:raw', $path or BAIL_OUT("cannot open $path: $!");
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return ($doc, $raw, $@);
}

my ($settings, undef, $serr) = read_json($SETTINGS);
ok(ref $settings eq 'HASH', 'A1: .claude/settings.json parses as an object') or diag("decode failed: $serr");

my ($hooksjson, undef, $herr) = read_json($HOOKS_JSON);
ok(ref $hooksjson eq 'HASH', 'A2: hooks.json parses as an object') or diag("decode failed: $herr");

# ---------------------------------------------------------------------------
# Helper: does settings.json register COMMAND_RE under PreToolUse with a
# matcher covering "Bash" (as its own alternative or the sole matcher)?
# ---------------------------------------------------------------------------
sub registered_in_settings_bash {
    my ($doc, $command_re) = @_;
    return 0 unless ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH';
    for my $entry (@{ $doc->{hooks}{PreToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        my $matcher = $entry->{matcher} // '';
        my @alts = split /\|/, $matcher;
        next unless grep { $_ eq 'Bash' } @alts;
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            return 1 if ($h->{command} // '') =~ $command_re;
        }
    }
    return 0;
}

sub mentioned_anywhere {
    my ($raw, $command_re) = @_;
    return $raw =~ $command_re ? 1 : 0;
}

# ===========================================================================
# B. gate-headless-background.sh — registered in settings.json under Bash.
# ===========================================================================
{
    ok(registered_in_settings_bash($settings, qr/gate-headless-background\.sh/),
       'B1: .claude/settings.json registers gate-headless-background.sh as a '
     . 'PreToolUse hook under a matcher covering Bash')
        or diag('an unregistered hook is inert regardless of whether the script exists');

    my $raw_hooks_json = do { local (@ARGV, $/) = ($HOOKS_JSON); <> };
    unlike($raw_hooks_json, qr/gate-headless-background\.sh/,
       'B2: hooks.json does NOT also register gate-headless-background.sh — the spec is '
     . 'explicit that this is a SINGLE route, not dual registration (§2.5): a '
     . 'promotion-gated copy diverging from the live settings.json copy would produce two '
     . 'different verdicts for the same call depending on which fired first');
}

# ===========================================================================
# C. guard-judge-checks.sh — registered in settings.json under Bash.
# ===========================================================================
{
    ok(registered_in_settings_bash($settings, qr/guard-judge-checks\.sh/),
       'C1: .claude/settings.json registers guard-judge-checks.sh as a PreToolUse hook '
     . 'under a matcher covering Bash');

    my $raw_hooks_json = do { local (@ARGV, $/) = ($HOOKS_JSON); <> };
    unlike($raw_hooks_json, qr/guard-judge-checks\.sh/,
       'C2: hooks.json does NOT also register guard-judge-checks.sh — single route only');
}

# ===========================================================================
# D. Regression guard: the pre-existing guard-git-mutations.sh registration
#    (the precedent this design follows) survives untouched.
# ===========================================================================
{
    ok(registered_in_settings_bash($settings, qr/guard-git-mutations\.sh/),
       'D1: guard-git-mutations.sh'."'".'s existing PreToolUse/Bash registration is still present '
     . '(h01 must ADD a block, not replace the existing one)');
}

# ===========================================================================
# E. $CLAUDE_PROJECT_DIR-relative command form, matching every existing entry
#    in this file (guard-git-mutations.sh, guard-subagent-stall.sh) — a
#    hardcoded absolute path would not survive a clone to a different
#    location.
# ===========================================================================
{
    my $found_ph = 0;
    for my $entry (@{ $settings->{hooks}{PreToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            my $cmd = $h->{command} // '';
            next unless $cmd =~ /gate-headless-background\.sh|guard-judge-checks\.sh/;
            $found_ph = 1 if $cmd =~ /\$CLAUDE_PROJECT_DIR|\$\{CLAUDE_PROJECT_DIR\}/;
        }
    }
    ok($found_ph, 'E1: the new hook commands use $CLAUDE_PROJECT_DIR (or ${CLAUDE_PROJECT_DIR}), '
                . 'not a hardcoded absolute path');
}

done_testing();
