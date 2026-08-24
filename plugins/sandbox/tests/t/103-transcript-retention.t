#!/usr/bin/env perl
# Oracle tests for b39-transcript-retention, derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b39-transcript-retention-spec.md
#
# IMMUTABLE ORACLE: the implementer conforms to the values specified there.
# Neither settings file carries `cleanupPeriodDays` at the time this file is
# authored, so A1/A2 (and the A1/A2-shaped parts of any future change) are
# EXPECTED TO FAIL until that key is added to both files. A3/A4/A5/A6 assert
# things that are already true of the repo today (schema declarations,
# pre-existing keys, absence of an unrelated env var, and the launcher's
# wiring of the container settings file) and are expected to PASS right now.
#
# Criterion mapping (full table also in
#   reports/b39-transcript-retention/test-writer-step3.md):
#   A1 : both files set cleanupPeriodDays, identical value
#   A2 : value is exactly 180, a JSON number, integer, >= 1
#   A3 : both files are valid JSON and keep their $schema declaration
#   A4 : every pre-existing key is preserved vs. a captured baseline
#   A5 : CLAUDE_CODE_SKIP_PROMPT_HISTORY is absent from both env blocks
#   A6 : the container file is the one the launcher actually installs
#   A7 : struck — no assertion, slot retained (see bottom of file)

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);
use JSON::PP;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# $Bin = .../plugins/sandbox/tests/t  ->  repo root is four levels up.
my $REPO_ROOT = "$Bin/../../../..";

my $HOST_FILE      = "$REPO_ROOT/global-config/settings.json";
my $CONTAINER_FILE = "$REPO_ROOT/plugins/sandbox/container/settings.json";
my $LAUNCHER_FILE  = "$REPO_ROOT/plugins/sandbox/scripts/launcher.pl";

ok(-f $HOST_FILE,      "sanity: host settings file exists at $HOST_FILE");
ok(-f $CONTAINER_FILE, "sanity: container settings file exists at $CONTAINER_FILE");
ok(-f $LAUNCHER_FILE,  "sanity: launcher.pl exists at $LAUNCHER_FILE");

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot open $path: $!";
    local $/;
    return <$fh>;
}

# =====================================================================
# A3 — both files are valid JSON and keep their $schema declaration.
#
# NO NETWORK FETCH. Per spec §2.4/A3: no JSON-schema validator is installed
# or permitted in this repo (stock Perl, no toolchain install), so schema
# conformance is asserted locally (valid JSON + the $schema string literal +
# the integer/>=1 constraints checked under A2) rather than fetched from
# https://json.schemastore.org/claude-code-settings.json. Do NOT "fix" this
# by adding a network call — that would fail in the sandbox, in CI, and on
# an offline host.
# =====================================================================

my ($host_data, $host_err)      = do { my $d = eval { decode_json(slurp($HOST_FILE)) }; ($d, $@) };
my ($container_data, $cont_err) = do { my $d = eval { decode_json(slurp($CONTAINER_FILE)) }; ($d, $@) };

ok(defined $host_data,      'A3: global-config/settings.json parses as valid JSON')
    or diag("JSON error: $host_err");
ok(defined $container_data, 'A3: plugins/sandbox/container/settings.json parses as valid JSON')
    or diag("JSON error: $cont_err");

is($host_data->{'$schema'}, 'https://json.schemastore.org/claude-code-settings.json',
    'A3: host $schema is exactly the claude-code-settings.json schema URL');
is($container_data->{'$schema'}, 'https://json.schemastore.org/claude-code-settings.json',
    'A3: container $schema is exactly the claude-code-settings.json schema URL');

# =====================================================================
# A1 — both files set the key, and to the same value.
# A2 — the value is exactly 180, a JSON NUMBER (not a string), an integer,
#      and >= 1 (the documented minimum; 0 is a validation error upstream).
# =====================================================================

my $host_val      = $host_data->{cleanupPeriodDays};
my $container_val = $container_data->{cleanupPeriodDays};

ok(exists $host_data->{cleanupPeriodDays},
    'A1: global-config/settings.json has a top-level cleanupPeriodDays key');
ok(exists $container_data->{cleanupPeriodDays},
    'A1: plugins/sandbox/container/settings.json has a top-level cleanupPeriodDays key');

SKIP: {
    skip 'A1: cannot compare values — at least one file is missing cleanupPeriodDays', 1
        unless defined $host_val && defined $container_val;
    is($host_val + 0, $container_val + 0,
        'A1: host and container cleanupPeriodDays values are numerically equal');
}

for my $case (
    [ 'global-config/settings.json',                 $host_val ],
    [ 'plugins/sandbox/container/settings.json',      $container_val ],
) {
    my ($label, $val) = @$case;

    ok(defined $val, "A2: $label cleanupPeriodDays is present (defined)");

    SKIP: {
        skip "A2: $label cleanupPeriodDays is not present — cannot check its shape", 4
            unless defined $val;

        my $reencoded = JSON::PP->new->allow_nonref->encode($val);
        is($reencoded, '180',
            "A2: $label cleanupPeriodDays re-encodes as the bare JSON number 180 (not \"180\")");
        ok($val == 180, "A2: $label cleanupPeriodDays == 180");
        ok($val == int($val), "A2: $label cleanupPeriodDays is an integer");
        ok($val >= 1, "A2: $label cleanupPeriodDays >= 1 (the documented minimum)");
    }
}

# =====================================================================
# A5 — CLAUDE_CODE_SKIP_PROMPT_HISTORY is absent from both env blocks, at
# any value. It disables transcript WRITES — the opposite of this package's
# purpose — and is asserted absent so nobody reaches for it by name-similarity.
# =====================================================================

ok(!exists $host_data->{env}{CLAUDE_CODE_SKIP_PROMPT_HISTORY},
    'A5: host env block does not set CLAUDE_CODE_SKIP_PROMPT_HISTORY');
ok(!exists $container_data->{env}{CLAUDE_CODE_SKIP_PROMPT_HISTORY},
    'A5: container env block does not set CLAUDE_CODE_SKIP_PROMPT_HISTORY');

# =====================================================================
# A4 — every pre-existing key is preserved, checked against a captured
# baseline (fully-qualified key paths -> scalar values), NOT a whole-file
# byte snapshot (spec §A4: both files are under concurrent edit by other
# tracks, so a byte oracle would go red on unrelated future settings
# changes). The baseline below is a literal transcription of both files as
# they stood immediately before this package's edit (captured 2026-08-03).
#
# Assertion is directional:
#   (a) every baseline key path still exists in the live file, with an
#       equal value — this catches this package clobbering/dropping a key;
#   (b) the live file has no key path outside baseline union
#       {cleanupPeriodDays} — this catches this package adding anything
#       else it shouldn't.
# =====================================================================

# ---- generic path flattener: HASH/ARRAY -> {"a.b[0].c" => scalar, ...} ----
sub flatten {
    my ($data, $prefix, $out) = @_;
    $out ||= {};
    my $ref = ref $data;
    if ($ref eq 'HASH') {
        for my $k (keys %$data) {
            my $path = length($prefix) ? "$prefix.$k" : $k;
            flatten($data->{$k}, $path, $out);
        }
    }
    elsif ($ref eq 'ARRAY') {
        for my $i (0 .. $#$data) {
            flatten($data->[$i], "$prefix\[$i]", $out);
        }
    }
    else {
        $out->{$prefix} = norm_scalar($data);
    }
    return $out;
}

sub norm_scalar {
    my ($v) = @_;
    return '<undef>' unless defined $v;
    return ($v ? '1' : '0') if ref($v) && ref($v) =~ /Boolean/;
    return "$v";
}

# ---- baseline: global-config/settings.json, captured pre-change ----
my $HOST_BASELINE = {
    '$schema'                     => 'https://json.schemastore.org/claude-code-settings.json',
    agentPushNotifEnabled         => JSON::PP::true,
    attribution                   => { commit => '', pr => '' },
    autoScrollEnabled              => JSON::PP::false,
    editorMode                     => 'vim',
    effortLevel                    => 'high',
    enabledPlugins => {
        'backpack@ccpraxis-local'                 => JSON::PP::true,
        'beacon@ccpraxis-local'                    => JSON::PP::true,
        'blueprint@ccpraxis-local'                 => JSON::PP::true,
        'butler@ccpraxis-local'                    => JSON::PP::true,
        'feature-dev@claude-plugins-official'      => JSON::PP::true,
        'frontend-design@claude-plugins-official'  => JSON::PP::true,
        'sandbox@ccpraxis-local'                   => JSON::PP::true,
        'steward@ccpraxis-local'                   => JSON::PP::true,
        'todo@ccpraxis-local'                      => JSON::PP::true,
    },
    env => {
        CLAUDE_AUTO_BACKGROUND_TASKS               => '1',
        CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR   => '0',
        CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY        => '1',
        CLAUDE_CODE_ENABLE_AWAY_SUMMARY            => '1',
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL          => 'true',
        CLAUDE_CODE_NEW_INIT                       => '1',
        CLAUDE_CODE_NO_FLICKER                     => '1',
        CLAUDE_CODE_SCROLL_SPEED                   => '3',
        CLAUDE_CODE_USE_POWERSHELL_TOOL            => '1',
        DISABLE_AUTOUPDATER                        => '1',
        DISABLE_INSTALL_GITHUB_APP_COMMAND         => '1',
        DISABLE_UPGRADE_COMMAND                    => '1',
        ENABLE_PROMPT_CACHING_1H                   => '1',
        FORCE_AUTOUPDATE_PLUGINS                   => '1',
    },
    extraKnownMarketplaces => {
        'ccpraxis-local' => {
            source => { path => 'C:/Users/André/.claude/ccpraxis/plugins', source => 'directory' },
        },
        'notion-plugin-marketplace' => {
            source => { repo => 'makenotion/claude-code-notion-plugin', source => 'github' },
        },
    },
    hooks => {
        PreToolUse => [
            {
                matcher => 'Bash',
                hooks   => [
                    {
                        command => 'perl "$HOME/.claude/ccpraxis/scripts/hooks/block-nul-redirect.pl"',
                        type    => 'command',
                    },
                ],
            },
        ],
    },
    inputNeededNotifEnabled => JSON::PP::true,
    permissions => {
        allow => [
            'Read',
            'Skill(beacon:delete)', 'Skill(beacon:list)', 'Skill(beacon:off)',
            'Skill(beacon:on)', 'Skill(beacon:view)',
            'Skill(blueprint:create)', 'Skill(blueprint:manage)',
            'Skill(butler:dispatch-fleet)', 'Skill(butler:drive-solo)',
            # DELIBERATE DECLARATION, not a sync (00-suite-baseline-green B8/AC-10).
            # Added by commit 6946510 "feat(butler): /butler:feedback -- byte-exact
            # capture, one question round, a read-only verifier" (git log -S
            # 'Skill(butler:feedback)' -- global-config/settings.json). The skill
            # file it grants, plugins/butler/skills/feedback/SKILL.md, ships in
            # this repo; butler@ccpraxis-local is already in enabledPlugins above;
            # and every sibling butler skill (dispatch-fleet, drive-solo, reporter,
            # status) is already allowlisted here -- this is the same grant class
            # as its siblings, not a new capability. NOT WebSearch/commit 075b073:
            # that was this package's own corrected misdiagnosis (see spec §1.2) --
            # WebSearch was already present in this baseline before this change and
            # only appeared to move because inserting an entry here shifts every
            # later index (see $PERMISSION_GATE_NOTICE below, and spec §5.6).
            'Skill(butler:feedback)',
            'Skill(butler:reporter)', 'Skill(butler:status)',
            'Skill(steward:audit)', 'Skill(steward:backup)',
            'Skill(steward:ccpraxis-extend)', 'Skill(steward:setup-project)',
            'Skill(steward:update)', 'Skill(steward:usage-audit)',
            'Skill(todo:create)', 'Skill(todo:manage)', 'Skill(todo:resume)',
            'Bash(find *)', 'Bash(grep *)', 'Bash(wc *)', 'Bash(awk *)', 'Bash(echo *)',
            'Bash(claude --version)', 'Bash(where claude*)', 'Bash(which claude*)',
            'Bash(git add *)', 'Bash(git commit *)', 'Bash(git rm *)',
            'Bash(perl ~/.claude/ccpraxis/plugins/beacon/scripts/*)',
            'Bash(perl ~/.claude/ccpraxis/scripts/*)',
            'Bash(perl ~/.claude/ccpraxis/plugins/steward/scripts/*)',
            'Bash(bash ~/.claude/ccpraxis/plugins/steward/scripts/*)',
            'WebFetch', 'WebSearch',
        ],
        ask                          => [],
        defaultMode                  => 'default',
        deny                         => [],
        disableBypassPermissionsMode => 'disable',
    },
    promptSuggestionEnabled      => JSON::PP::false,
    remoteControlAtStartup      => JSON::PP::false,
    showClearContextOnPlanAccept => JSON::PP::true,
    showThinkingSummaries        => JSON::PP::true,
    skipAutoPermissionPrompt     => JSON::PP::true,
    statusLine => {
        command => 'perl "$HOME/.claude/ccpraxis/scripts/statusline.pl"',
        type    => 'command',
    },
    useAutoModeDuringPlan => JSON::PP::true,
    worktree              => { baseRef => 'fresh' },
};

# ---- baseline: plugins/sandbox/container/settings.json, captured pre-change ----
my $CONTAINER_BASELINE = {
    '$schema'              => 'https://json.schemastore.org/claude-code-settings.json',
    agentPushNotifEnabled  => JSON::PP::true,
    attribution            => { commit => '', pr => '' },
    autoScrollEnabled       => JSON::PP::false,
    editorMode              => 'vim',
    effortLevel             => 'high',
    enabledPlugins => {
        'feature-dev@claude-plugins-official'     => JSON::PP::true,
        'frontend-design@claude-plugins-official' => JSON::PP::true,
    },
    env => {
        CLAUDE_AUTO_BACKGROUND_TASKS             => '1',
        CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR => '0',
        CLAUDE_CODE_ENABLE_AWAY_SUMMARY          => '1',
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL        => 'true',
        CLAUDE_CODE_NEW_INIT                     => '1',
        CLAUDE_CODE_NO_FLICKER                   => '1',
        CLAUDE_CODE_SCROLL_SPEED                 => '3',
        DISABLE_AUTOUPDATER                      => '1',
        DISABLE_INSTALL_GITHUB_APP_COMMAND       => '1',
        DISABLE_LOGIN_COMMAND                    => '0',
        DISABLE_LOGOUT_COMMAND                   => '0',
        DISABLE_UPGRADE_COMMAND                  => '1',
        ENABLE_PROMPT_CACHING_1H                 => '1',
        FORCE_AUTOUPDATE_PLUGINS                 => '1',
        CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY       => '1',
    },
    extraKnownMarketplaces => {
        'notion-plugin-marketplace' => {
            source => { repo => 'makenotion/claude-code-notion-plugin', source => 'github' },
        },
    },
    hooks => {
        PostToolUse => [
            {
                matcher => 'Bash',
                hooks   => [
                    {
                        command => '[ -f "$HOME/.claude/auto-declare.pl" ] && perl "$HOME/.claude/auto-declare.pl" || true',
                        type    => 'command',
                    },
                ],
            },
        ],
    },
    inputNeededNotifEnabled      => JSON::PP::true,
    promptSuggestionEnabled      => JSON::PP::false,
    remoteControlAtStartup       => JSON::PP::false,
    showClearContextOnPlanAccept => JSON::PP::true,
    showThinkingSummaries        => JSON::PP::true,
    skipDangerousModePermissionPrompt => JSON::PP::true,
    statusLine => {
        command => 'perl "$HOME/.claude/statusline.pl"',
        type    => 'command',
    },
    worktree => { baseRef => 'fresh' },
};

# 00-suite-baseline-green B9/AC-12 — taught once, on demand, to the next
# reader who hits a permissions.allow disagreement here. This gate exists
# because global-config/settings.json installs to ~/.claude/settings.json
# and grants its permissions to EVERY project on this machine — the drift
# that motivated this notice (Skill(butler:feedback) landing at index 10,
# see $HOST_BASELINE's permissions.allow comment above) was a genuine,
# undeclared change to that shipped set, and this gate caught it exactly as
# designed. §5.6 below is why a single mid-list insertion fans out into
# ~28 "changed" diags plus one surplus key: flatten() keys arrays by
# INDEX, so everything after the insertion point shifts by one. Read the
# *position* of the surplus/changed key, not its value, to find the real
# addition.
my $PERMISSION_GATE_NOTICE = <<'NOTICE';
permissions.allow drift detected in global-config/settings.json.

This baseline is a CONSCIOUS-DECLARATION GATE, not a change detector.
global-config/settings.json installs to ~/.claude/settings.json and grants its
permissions to EVERY project on this machine, so each entry must be declared by a
human before it ships.

If the new entry is intended: add it to $HOST_BASELINE's permissions.allow in this
file, AT THE SAME POSITION as in global-config/settings.json, with a comment naming
the commit and why the grant is safe.

Do NOT widen this check to accept whatever the live file contains, do NOT auto-sync
the baseline from the live file, and do NOT delete the entry from the shipped config
just to turn this test green. Any of those deletes the control.
NOTICE

sub assert_baseline_preserved {
    my ($label, $baseline, $live) = @_;

    my $baseline_flat = flatten($baseline, '');
    my $live_flat      = flatten($live, '');
    my $notice_shown   = 0;
    my $maybe_notice   = sub {
        my ($path) = @_;
        return unless $path =~ /^permissions\.allow\[/;
        return if $notice_shown;
        $notice_shown = 1;
        diag($PERMISSION_GATE_NOTICE);
    };

    # (a) every baseline key path still present, with an equal value.
    my $all_preserved = 1;
    for my $path (sort keys %$baseline_flat) {
        unless (exists $live_flat->{$path}
            && $live_flat->{$path} eq $baseline_flat->{$path}) {
            $all_preserved = 0;
            diag("A4: $label lost or changed baseline key '$path' "
                . "(expected '$baseline_flat->{$path}', got "
                . (exists $live_flat->{$path} ? "'$live_flat->{$path}'" : '<missing>') . ")");
            $maybe_notice->($path);
        }
    }
    ok($all_preserved, "A4: $label preserves every baseline key path with its original value");

    # (b) no live key path outside baseline union the explicitly-permitted set.
    #
    # SYN-21, 2026-08-03: `env.CCPRAXIS_SANDBOX` added. s17's done criteria
    # MANDATE that container/settings.json set a sandbox marker, which
    # scripts/statusline.pl reads to decide whether to render the sandbox badge
    # -- the badge must NOT appear on the operator's host, so the variable has
    # to live in the container's settings file specifically.
    #
    # This is the recurring shape the standing rule warns about: assert your own
    # package's contribution, never the whole file's shape, because the latter
    # forbids every later package from extending it. Part (a) above is the real
    # protection and is untouched -- no baseline key may be lost or changed.
    # Part (b) is deliberately kept, rather than deleted, so an ACCIDENTAL new
    # key is still caught; only this one deliberate, mandated addition is
    # permitted, by name.
    my %permitted_additions = (
        'cleanupPeriodDays'    => 1,
        'env.CCPRAXIS_SANDBOX' => 1,   # s17-statusline-and-output-hygiene
        'autoMemoryEnabled'    => 1,   # 1edc0d3 -- auto-memory is disabled in
                                       # every settings layer on purpose; project
                                       # guidance lives in-repo instead.
        'permissions.deny[0]'  => 1,   # 1edc0d3 -- the belt to autoMemoryEnabled's
                                       # braces: Read(~/.claude/projects/**/memory/**).
                                       # Both files carry exactly this one entry.
    );
    my @unexpected = grep {
        !exists $baseline_flat->{$_} && !$permitted_additions{$_}
    } sort keys %$live_flat;
    $maybe_notice->($_) for @unexpected;
    is_deeply(\@unexpected, [],
        "A4: $label introduces no key path outside the baseline other than cleanupPeriodDays");
}

assert_baseline_preserved('global-config/settings.json',            $HOST_BASELINE,      $host_data);
assert_baseline_preserved('plugins/sandbox/container/settings.json', $CONTAINER_BASELINE, $container_data);

# =====================================================================
# A6 — the container file is the one the launcher actually installs
# (ledger criterion 6, spec §2.3). Read launcher.pl as TEXT ONLY and grep
# for the wiring — NEVER spawn launcher.pl itself (it would build an image
# and start a container). Match on stable identifiers, tolerant of
# whitespace, not on line numbers (SYN-23).
# =====================================================================

my $launcher_src = slurp($LAUNCHER_FILE);

like($launcher_src, qr{\$CONTAINER_CONFIG\s*=\s*"\$SANDBOX_PLUGIN/container"},
    'A6: $CONTAINER_CONFIG is assigned "$SANDBOX_PLUGIN/container"');

like($launcher_src, qr{\$CONTAINER_SETTINGS_JSON\s*=\s*"\$LAUNCHER_DIR},
    'A6: $CONTAINER_SETTINGS_JSON is assigned a path under $LAUNCHER_DIR');

like($launcher_src,
    qr{_copy_file\(\s*"\$CONTAINER_CONFIG/settings\.json"\s*,\s*\$CONTAINER_SETTINGS_JSON\s*\)},
    'A6: $CONTAINER_CONFIG/settings.json is copied to $CONTAINER_SETTINGS_JSON');

like($launcher_src,
    qr{_copy_file\(\s*\$CONTAINER_SETTINGS_JSON\s*,\s*"\$host_data/settings\.json"\s*\)},
    'A6: $CONTAINER_SETTINGS_JSON is copied to a settings.json under the host-data (claude-home) dir');

# =====================================================================
# A7 — struck by the operator's six-month ruling (spec §4/A7). No
# assertion. The numbered slot is retained deliberately so the acceptance
# criteria list is not silently renumbered.
# =====================================================================

done_testing();
