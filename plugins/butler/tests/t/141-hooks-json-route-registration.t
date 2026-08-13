#!/usr/bin/env perl
# 141-hooks-json-route-registration.t -- oracle for the REGISTRATION-ROUTE
# half of g02's fix (spec §2.1/§2.2/§2.3/§2.4, AC3/AC4/AC7, done criteria
# 3/4/6). Complements 140 (which pins the SCRIPTS' cwd/env independence,
# already true today). This file pins the thing that is NOT yet true: that
# gate-headless-background.sh and guard-judge-checks.sh are registered via
# ${CLAUDE_PLUGIN_ROOT} (hooks.json, machine-wide, reaches any project once
# promoted -- scout-step1.md item 1) and are registered NOWHERE in
# .claude/settings.json ($CLAUDE_PROJECT_DIR-relative, ccpraxis-only, dead
# everywhere else). BEFORE this package's edit, block B below fails (the
# entries are absent from hooks.json) and block C below fails (the entries
# are still present in settings.json) -- that is the correct, expected shape
# of red for a test written from the spec before the fix exists.
#
# NON-VACUITY NOTE, since this is a JSON-structure file and structural
# checks are exactly the kind of oracle this package exists to distrust.
# What makes THESE structural checks different from t/61's and t/112's
# registration-only checks (which this package's whole point is that they
# proved nothing about reach): this file does not stand alone as evidence of
# reach -- 140 supplies the "the script itself doesn't care where it's
# invoked from" half, and scout-step1.md's item 1 (${CLAUDE_PLUGIN_ROOT}
# resolves machine-wide, independent of driven project, confirmed against
# DAME's own settings.local.json) supplies the "the route itself reaches
# other projects" half at the mechanism level. This file's job is narrower
# and more honest: prove the SOURCE FILES were actually edited as the spec
# demands, not that the edit causes a session to fire (spec §6: that would
# require launching a real session, out of reach for this suite).
#
# NEVER MUTATES the real files -- read-only assertions, same discipline as
# 122-h01-settings-registration.t and plugins/sandbox/tests/t/61-settings-scope-split.t.
#
# Runs standalone: perl plugins/butler/tests/t/141-hooks-json-route-registration.t

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use JSON::PP;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $SETTINGS   = "$REPO_ROOT/.claude/settings.json";
my $HOOKS_JSON = "$REPO_ROOT/plugins/butler/hooks/hooks.json";

ok(-f $SETTINGS,   '.claude/settings.json exists') or BAIL_OUT('no settings.json');
ok(-f $HOOKS_JSON, 'hooks.json exists')             or BAIL_OUT('no hooks.json');

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or BAIL_OUT("cannot open $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    return $raw;
}

sub read_json {
    my ($path) = @_;
    my $raw = slurp($path);
    my $doc = eval { JSON::PP->new->utf8->decode($raw) };
    return ($doc, $raw, $@);
}

my ($settings, $settings_raw, $serr) = read_json($SETTINGS);
ok(ref $settings eq 'HASH', 'A1: .claude/settings.json parses as an object') or diag("decode failed: $serr");

my ($hooksjson, $hooksjson_raw, $herr) = read_json($HOOKS_JSON);
ok(ref $hooksjson eq 'HASH', 'A2: hooks.json parses as an object') or diag("decode failed: $herr");

# ---------------------------------------------------------------------------
# Helper: find all PreToolUse/Bash-matcher command hooks in a hooks.json-style
# decoded document ({hooks:{PreToolUse:[...]}} for hooks.json,
# {hooks:{PreToolUse:[...]}} for settings.json -- same shape).
# ---------------------------------------------------------------------------
sub bash_matcher_blocks {
    my ($doc) = @_;
    return () unless ref $doc eq 'HASH' && ref $doc->{hooks} eq 'HASH';
    my @blocks;
    for my $entry (@{ $doc->{hooks}{PreToolUse} // [] }) {
        next unless ref $entry eq 'HASH';
        my $matcher = $entry->{matcher} // '';
        my @alts = split /\|/, $matcher;
        push @blocks, $entry if grep { $_ eq 'Bash' } @alts;
    }
    return @blocks;
}

sub commands_matching {
    my ($doc, $command_re) = @_;
    my @found;
    for my $block (bash_matcher_blocks($doc)) {
        for my $h (@{ $block->{hooks} // [] }) {
            next unless ref $h eq 'HASH';
            push @found, $h->{command} // '' if ($h->{command} // '') =~ $command_re;
        }
    }
    return @found;
}

# ===========================================================================
# B. hooks.json GAINS gate-headless-background.sh and guard-judge-checks.sh,
#    under the EXISTING Bash-matcher PreToolUse block, ${CLAUDE_PLUGIN_ROOT}-
#    relative (spec §2.1, behavior 3, AC3). THIS IS THE BLOCK THAT FAILS
#    BEFORE THE FIX -- hooks.json today has no mention of either script.
# ===========================================================================
{
    my @bash_blocks = bash_matcher_blocks($hooksjson);
    is(scalar(@bash_blocks), 1,
       'B1: hooks.json has exactly ONE PreToolUse block whose matcher covers Bash -- '
     . 'the spec requires appending into the existing block, never opening a third one '
     . '(a count of 2 here means a new block was opened instead of appending)')
        or diag('found ' . scalar(@bash_blocks) . ' Bash-matcher blocks');

    my @gate = commands_matching($hooksjson, qr/gate-headless-background\.sh/);
    is(scalar(@gate), 1,
       'B2: hooks.json registers gate-headless-background.sh exactly once under the Bash matcher')
        or diag('an unregistered or duplicated hook cannot be the single, correct route');
    if (@gate) {
        like($gate[0], qr/\$\{CLAUDE_PLUGIN_ROOT\}/,
             'B3: ...using ${CLAUDE_PLUGIN_ROOT} (machine-wide live-install-relative, per scout item 1) '
           . '-- NOT $CLAUDE_PROJECT_DIR (the dead route being replaced) and not a hardcoded path');
        unlike($gate[0], qr/\$CLAUDE_PROJECT_DIR/,
             'B4: ...and specifically does NOT use $CLAUDE_PROJECT_DIR');
    }

    my @judge = commands_matching($hooksjson, qr/guard-judge-checks\.sh/);
    is(scalar(@judge), 1,
       'B5: hooks.json registers guard-judge-checks.sh exactly once under the Bash matcher');
    if (@judge) {
        like($judge[0], qr/\$\{CLAUDE_PLUGIN_ROOT\}/,
             'B6: ...using ${CLAUDE_PLUGIN_ROOT}');
        unlike($judge[0], qr/\$CLAUDE_PROJECT_DIR/,
             'B7: ...and specifically does NOT use $CLAUDE_PROJECT_DIR');
    }

    # Sibling entries (guard-bash.sh, mark-wakeup.sh) must still be present,
    # unmoved -- the spec requires APPENDING, not replacing the block's
    # existing contents.
    my @siblings = commands_matching($hooksjson, qr/guard-bash\.sh|mark-wakeup\.sh/);
    is(scalar(@siblings), 2,
       'B8: the pre-existing guard-bash.sh and mark-wakeup.sh entries in the same block '
     . 'are still present, unremoved by this edit');
}

# ===========================================================================
# C. .claude/settings.json LOSES all mention of gate-headless-background.sh
#    and guard-judge-checks.sh anywhere in the file (spec §2.2, behavior 4,
#    AC4). THIS IS THE OTHER BLOCK THAT FAILS BEFORE THE FIX -- today the
#    h01 block is still present.
# ===========================================================================
{
    unlike($settings_raw, qr/gate-headless-background\.sh/,
       'C1: .claude/settings.json contains NO mention of gate-headless-background.sh anywhere '
     . 'in the raw file -- single route, no dual registration (h01 spec §2.5, adopted by citation)');
    unlike($settings_raw, qr/guard-judge-checks\.sh/,
       'C2: .claude/settings.json contains NO mention of guard-judge-checks.sh anywhere in the raw file');
}

# ===========================================================================
# D. Regression: the PRE-EXISTING guard-git-mutations.sh and
#    guard-subagent-stall.sh registrations in .claude/settings.json survive
#    BYTE-IDENTICAL (structurally, via deep equality on the decoded JSON
#    entries -- spec §2.2's "byte-for-byte untouched", behavior 5, AC4/AC6).
#    Expected structures captured from the file BEFORE this package's edit
#    (read while writing this test, from the still-unedited tracked file).
# ===========================================================================
{
    my $expect_git_mutations = {
        'matcher' => 'Bash',
        'hooks' => [
            {
                'command' => '"$CLAUDE_PROJECT_DIR"/plugins/butler/hooks/guard-git-mutations.sh',
                'type' => 'command',
            },
        ],
    };
    my $expect_stall_post = {
        'matcher' => 'Task|Bash',
        'hooks' => [
            {
                'command' => '"$CLAUDE_PROJECT_DIR"/plugins/butler/hooks/guard-subagent-stall.sh',
                'type' => 'command',
            },
        ],
    };
    my $expect_stall_stop = {
        'hooks' => [
            {
                'command' => '"$CLAUDE_PROJECT_DIR"/plugins/butler/hooks/guard-subagent-stall.sh',
                'type' => 'command',
            },
        ],
    };

    my @pretooluse = @{ $settings->{hooks}{PreToolUse} // [] };
    my ($git_block) = grep {
        ref $_ eq 'HASH'
        && grep { ($_->{command} // '') =~ /guard-git-mutations\.sh/ } @{ $_->{hooks} // [] }
    } @pretooluse;
    ok(defined $git_block, 'D1: a PreToolUse/Bash block for guard-git-mutations.sh still exists')
        or diag('guard-git-mutations.sh is explicitly OUT of this package'."'".'s write-set-legal scope '
               . '(spec §2.4) -- its disappearance would be a different, worse defect than the one fixed');
    is_deeply($git_block, $expect_git_mutations,
       'D2: ...and it is structurally IDENTICAL to its pre-edit form -- not merely present, '
     . 'but untouched (matcher, command string, and type all pinned)')
        if defined $git_block;

    is(scalar(@pretooluse), 1,
       'D3: .claude/settings.json'."'".' PreToolUse array now has exactly ONE block (guard-git-mutations.sh) -- '
     . 'the h01 block was DELETED, not merely emptied or left as an empty array entry')
        or diag('found ' . scalar(@pretooluse) . ' PreToolUse blocks; expected exactly 1 after the h01 block is removed');

    my @posttooluse = @{ $settings->{hooks}{PostToolUse} // [] };
    my ($stall_post) = grep { ref $_ eq 'HASH' } @posttooluse;
    ok(defined $stall_post, 'D4: the PostToolUse/Task|Bash guard-subagent-stall.sh block still exists');
    is_deeply($stall_post, $expect_stall_post,
       'D5: ...structurally identical to its pre-edit form') if defined $stall_post;

    my @stop = @{ $settings->{hooks}{Stop} // [] };
    my ($stall_stop) = grep { ref $_ eq 'HASH' } @stop;
    ok(defined $stall_stop, 'D6: the Stop guard-subagent-stall.sh block still exists');
    is_deeply($stall_stop, $expect_stall_stop,
       'D7: ...structurally identical to its pre-edit form') if defined $stall_stop;
}

# ===========================================================================
# E. AC7 -- hooks.json does NOT gain guard-git-mutations.sh or
#    guard-subagent-stall.sh as a side effect of this edit (spec §2.4,
#    behavior 6). Neither carries bp_hook_gate/BP_LEDGER, so widening either
#    would apply it to EVERY session on this machine, butler-related or not
#    -- this is the regression guard that makes "not a side effect" checkable.
# ===========================================================================
{
    unlike($hooksjson_raw, qr/guard-git-mutations\.sh/,
       'E1: hooks.json does not mention guard-git-mutations.sh anywhere '
     . '(deferred by write-set construction, spec §2.4 -- widening it is a materially larger, '
     . 'separately-decided policy change, not a side effect of this package)');
    unlike($hooksjson_raw, qr/guard-subagent-stall\.sh/,
       'E2: hooks.json does not mention guard-subagent-stall.sh anywhere either');
}

# ===========================================================================
# F. Both files remain valid, parseable JSON post-edit -- a syntactically
#    broken hooks.json would silently disable all NINE pre-existing hooks,
#    not just the two this package adds (spec §5 edge case). Re-asserts A1/A2
#    explicitly as a named, independent check rather than relying solely on
#    the BAIL_OUT guards above (which would abort the whole file rather than
#    report a clean failure).
# ===========================================================================
{
    ok(defined $settings, 'F1: .claude/settings.json is valid JSON after the edit');
    ok(defined $hooksjson, 'F2: hooks.json is valid JSON after the edit');
}

done_testing();
