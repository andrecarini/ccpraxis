#!/usr/bin/env perl
# 122-h01-settings-registration.t — oracle for the REVISED registration
# decision (g02 spec §2.1-§2.3, INVERTING h01's original §2.5 decision):
# gate-headless-background.sh and guard-judge-checks.sh register ONLY in
# plugins/butler/hooks/hooks.json (${CLAUDE_PLUGIN_ROOT}-relative), never in
# .claude/settings.json.
#
# THIS FILE WAS ORIGINALLY WRITTEN FOR THE OPPOSITE DESIGN, AND THAT DESIGN
# SHIPPED A DEFECT. h01's architect traced bp-launch.sh:112 and bp-judge.sh:169
# and found both `cd "$PROJECT_ROOT"` immediately before `claude -p ...` with
# no `--settings` override, and concluded .claude/settings.json (tracked,
# live in THIS clone immediately) "already reaches coordinator AND judge
# sessions". That conclusion is true ONLY when the project being driven is
# ccpraxis itself: $PROJECT_ROOT for a coordinator driving DAME or GSA is
# THAT project's root, whose tree has no plugins/butler/hooks/ at all and
# whose own .claude/settings.json contains no such entry either (g02 scout,
# verified against both). Coordinators and judges overwhelmingly run in
# OTHER projects, so the original design was inert exactly where the
# incident it cites (2026-08-11 GSA fleet collapse) happened. g02 exists to
# fix that scope error. THE FIX IS A ROUTE CHANGE, NOT A BEHAVIOR CHANGE:
# ${CLAUDE_PLUGIN_ROOT} resolves machine-wide via the live install regardless
# of which project is being driven (g02 scout item 1, confirmed against
# DAME's own settings.local.json already carrying butler@ccpraxis-local),
# and 119/121 continue to pin the scripts' own behavior once invoked,
# unmodified by this package. This file pins the (now-corrected) registration
# route; it does not re-litigate anything 119/121 already own.
#
# THE HONEST COST, so a future reader does not assume this was free (g02
# spec §1, done criterion 3): the settings.json route's liveness advantage —
# no promotion needed, read straight off this clone's disk — is GIVEN UP for
# these two hooks, in every case, including a coordinator driven from THIS
# very clone. hooks.json is plugin code, resolved via the marketplace
# mechanism to the PROMOTED live install (~/.claude/ccpraxis), never to this
# clone, for any session. A mid-run edit to either script or to hooks.json's
# registration of them is invisible until `git -C ~/.claude/ccpraxis pull
# <clone> main`. That is not independently re-provable by this file (it
# would require launching and promoting a real session — out of reach for
# this suite, g02 spec §6) — it is recorded here in prose so the trade is
# visible, not silently assumed away.
#
# NEVER MUTATES the real .claude/settings.json or hooks.json — read-only
# assertions against the tracked files, exactly like
# plugins/sandbox/tests/t/61-settings-scope-split.t's C5 section, which
# already establishes this read-only pattern for the same settings.json file.
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

# ---------------------------------------------------------------------------
# Helper: does hooks.json register COMMAND_RE under PreToolUse with a matcher
# covering "Bash"? Structurally identical logic to registered_in_settings_bash
# above, kept as a separate sub (rather than parameterising the doc-shape
# assumption) because the two files' hook entries differ in key order and
# this mirrors 141's own bash_matcher_blocks()/commands_matching() helpers —
# same shape, independently written, so a bug in one is unlikely to be
# mirrored in the other.
# ---------------------------------------------------------------------------
sub registered_in_hooksjson_bash {
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

# ===========================================================================
# B. gate-headless-background.sh — registered in hooks.json under Bash,
#    ${CLAUDE_PLUGIN_ROOT}-relative. INVERTED from the original design (see
#    file header): settings.json must NOT register it any more.
# ===========================================================================
{
    my $raw_settings = do { local (@ARGV, $/) = ($SETTINGS); <> };
    unlike($raw_settings, qr/gate-headless-background\.sh/,
       'B1: .claude/settings.json does NOT register gate-headless-background.sh anywhere — '
     . 'a reversion to the settings.json-only route would be exactly the scope defect g02 fixed');

    ok(registered_in_hooksjson_bash($hooksjson, qr/gate-headless-background\.sh/),
       'B2: hooks.json registers gate-headless-background.sh as a PreToolUse hook under a '
     . 'matcher covering Bash, via ${CLAUDE_PLUGIN_ROOT} — the single route, reaching any '
     . 'project once promoted (g02 spec §2.1)')
        or diag('an unregistered hook is inert regardless of whether the script exists');
}

# ===========================================================================
# C. guard-judge-checks.sh — registered in hooks.json under Bash,
#    ${CLAUDE_PLUGIN_ROOT}-relative. Same inversion as B.
# ===========================================================================
{
    my $raw_settings = do { local (@ARGV, $/) = ($SETTINGS); <> };
    unlike($raw_settings, qr/guard-judge-checks\.sh/,
       'C1: .claude/settings.json does NOT register guard-judge-checks.sh anywhere');

    ok(registered_in_hooksjson_bash($hooksjson, qr/guard-judge-checks\.sh/),
       'C2: hooks.json registers guard-judge-checks.sh as a PreToolUse hook under a matcher '
     . 'covering Bash, via ${CLAUDE_PLUGIN_ROOT} — single route only');
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
# E. $CLAUDE_PROJECT_DIR-relative command form — SCOPED to guard-git-mutations.sh
#    and guard-subagent-stall.sh only (the two hooks NOT moving; g02 spec §5
#    edge case is explicit that this regex must be re-scoped once
#    gate-headless-background.sh/guard-judge-checks.sh no longer use this
#    form at all — asserting it across the whole file after the inversion
#    would be vacuously satisfied by entries this file no longer contains
#    opinions about).
# ===========================================================================
{
    my $found_ph = 0;
    for my $entry (@{ $settings->{hooks}{PreToolUse} // [] },
                    @{ $settings->{hooks}{PostToolUse} // [] },
                    @{ $settings->{hooks}{Stop} // [] }) {
        next unless ref $entry eq 'HASH';
        for my $h (@{ $entry->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            my $cmd = $h->{command} // '';
            next unless $cmd =~ /guard-git-mutations\.sh|guard-subagent-stall\.sh/;
            $found_ph = 1 if $cmd =~ /\$CLAUDE_PROJECT_DIR|\$\{CLAUDE_PROJECT_DIR\}/;
        }
    }
    ok($found_ph, 'E1: guard-git-mutations.sh'."'".' and guard-subagent-stall.sh'."'".' commands (the two hooks '
                . 'g02 deliberately leaves alone) still use $CLAUDE_PROJECT_DIR — not a hardcoded '
                . 'absolute path, and not re-scoped to hooks.json by this package');

    # F. Mirror check: gate-headless-background.sh/guard-judge-checks.sh must
    #    NOT appear anywhere using the old $CLAUDE_PROJECT_DIR form (would
    #    catch a half-migration that left a dead settings.json fragment with
    #    the old path style but under a different key).
    my $raw_settings = do { local (@ARGV, $/) = ($SETTINGS); <> };
    unlike($raw_settings, qr/\$CLAUDE_PROJECT_DIR.{0,80}(gate-headless-background|guard-judge-checks)\.sh/s,
       'F1: no $CLAUDE_PROJECT_DIR-relative fragment mentioning either moved hook survives anywhere '
     . 'in settings.json, under any key');
}

done_testing();
