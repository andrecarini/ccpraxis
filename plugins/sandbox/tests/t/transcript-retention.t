#!/usr/bin/env perl
# platform: windows
# Oracle tests for b39, derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b39-spec.md
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
#   reports/b39/test-writer-step3.md):
#   A1 : both files set cleanupPeriodDays, identical value
#   A2 : value is exactly 180, a JSON number, integer, >= 1
#   A3 : both files are valid JSON and keep their $schema declaration
#   A4 : every pre-existing key is preserved vs. a captured baseline
#   A5 : CLAUDE_CODE_SKIP_PROMPT_HISTORY is absent from both env blocks
#   A6 : the container file is the one the launcher actually installs
#   A7 : struck — no assertion, slot retained (see bottom of file)
#
# 02-disable-builtin-tasks (operator-ui-tweaks), derived from
#   .ccpraxis-local-data/blueprints/operator-ui-tweaks/specs/02-disable-builtin-tasks-spec.md
# AC-3/AC-4 pin that CLAUDE_CODE_TODO_REMINDER_MODE is set to 'off' in both
# live settings.json files' env blocks. A4(a) pins baseline preservation for
# both baselines below. AC-5 through AC-9 pin things already true of the repo
# (the key is absent from live env blocks under other names, this file's own
# DELIBERATE DECLARATION comments, and %permitted_additions).
#   AC-3 : host env.CLAUDE_CODE_TODO_REMINDER_MODE is exactly 'off'
#   AC-4 : container env.CLAUDE_CODE_TODO_REMINDER_MODE is exactly 'off'
#   AC-5 : CLAUDE_CODE_ENABLE_TASKS (and CLAUDE_CODE_ENABLE_TODO_TOOLS) are
#          absent from both env blocks
#   AC-6 : neither file has a top-level todoFeatureEnabled key
#   AC-7 : $HOST_BASELINE's CLAUDE_CODE_TODO_REMINDER_MODE entry is preceded
#          by a DELIBERATE DECLARATION comment
#   AC-8 : $CONTAINER_BASELINE's entry is preceded by the same
#   AC-9 : %permitted_additions carries no env.CLAUDE_CODE_TODO_REMINDER_MODE
#          entry (the key is declared in-baseline, not permitted-as-extra)
#
# 03-strip-claude-code-bloat (operator-ui-tweaks), derived from
#   .ccpraxis-local-data/blueprints/operator-ui-tweaks/specs/03-strip-claude-code-bloat-spec.md
# Adds 8 new DELIBERATE DECLARATION keys to both baselines: three top-level
# booleans, one 15-entry skillOverrides object, and four env keys. None of
# S4 (disableFastMode) or S9 (the anthropic-skills switch) is set — both are
# explicitly out of scope (spec §6) and asserted absent (AC-6/B-5).
#   AC-1  : both files parse and keep $schema (covered by existing A3)
#   AC-2  : B-1 -- disableArtifact/disableRemoteControl/disableClaudeAiConnectors
#           are JSON boolean true, in both files
#   AC-3  : B-2 -- skillOverrides is exactly the 15 names -> 'off', in both files
#   AC-4  : B-3 -- skillOverrides has no update-config/keybindings-help/`:`-key
#   AC-5  : B-4 -- the four env keys are exactly '1', in both files
#   AC-6  : B-5 -- disableFastMode absent; no anthropic-skills enabledPlugins key
#   AC-7  : all 8 new keys are present in $HOST_BASELINE (A4(a)), each with a
#           DELIBERATE DECLARATION comment (B-6)
#   AC-8  : the same in $CONTAINER_BASELINE
#   AC-9  : B-7 -- none of the new paths is in %permitted_additions
#   AC-10 : A4(a)/(b) pass for both files (existing assert_baseline_preserved)
#   AC-11 : this file exits 0 with no not ok lines (not expected yet -- the
#           keys are not in the live settings files until the implementer acts)
#   AC-12 : promote-syncs-global-config.t, promote-drops-retired-keys.t and
#           global-config-perl-hook-guard.t are unaffected (run, not edited)
#
# tooling-fixes package 15 (Decision 46), derived from
#   .ccpraxis-local-data/blueprints/tooling-fixes/specs/15-sandbox-only-plugin-updates-spec.md
# §2.13.2. FORCE_AUTOUPDATE_PLUGINS returns to the container baseline (removed
# by 06-plugins-current-at-start, Decision 11) under a DELIBERATE DECLARATION
# comment explaining why it is now safe: it reopens the global plugin-update
# gate that DISABLE_AUTOUPDATER shuts, and the per-marketplace `autoUpdate`
# flag the launcher writes every launch into known_marketplaces.json is the
# effective gate -- false for every marketplace with a host-shared plugin.
#   TF15-1 (AC24a) : $CONTAINER_BASELINE declares FORCE_AUTOUPDATE_PLUGINS =>
#                    '1' under a DELIBERATE DECLARATION comment
#   TF15-2 (AC24b) : %permitted_additions carries no env.FORCE_AUTOUPDATE_PLUGINS
#                    entry -- the key is declared in-baseline (A4(a) covers it)
#   TF15-3 (AC24c) : no extraKnownMarketplaces.*.autoUpdate key exists in the
#                    live container file or in %permitted_additions

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
# AC-3/AC-4 (02-disable-builtin-tasks spec §2/§4) — host and container
# env.CLAUDE_CODE_TODO_REMINDER_MODE is exactly the string 'off'. is(), not
# ok(): claude.exe 2.1.282's D.enum(["baseline","off"]) match is
# case-sensitive after a trim, so 'Off'/'OFF'/'0' would silently resolve to
# undefined and re-arm both reminders (spec §1.2, §5).
# =====================================================================

is($host_data->{env}{CLAUDE_CODE_TODO_REMINDER_MODE}, 'off',
    "AC-3: host env.CLAUDE_CODE_TODO_REMINDER_MODE is exactly 'off'");
is($container_data->{env}{CLAUDE_CODE_TODO_REMINDER_MODE}, 'off',
    "AC-4: container env.CLAUDE_CODE_TODO_REMINDER_MODE is exactly 'off'");

# =====================================================================
# AC-5 (spec §1.1, §2, Decision 3(2)) — CLAUDE_CODE_ENABLE_TASKS (and its
# sibling CLAUDE_CODE_ENABLE_TODO_TOOLS, spec §3 observable behavior 3 /
# §6) are absent from both env blocks, at any value. Setting ENABLE_TASKS
# would flip Uw() to false, which re-enables TodoWrite via
# isEnabled(){return!Uw()&&U$()} for every model in the czo set; ENABLE_TODO_TOOLS
# has no effect at all (U$() only checks ===!0). Neither belongs here.
# =====================================================================

ok(!exists $host_data->{env}{CLAUDE_CODE_ENABLE_TASKS},
    'AC-5: host env block does not set CLAUDE_CODE_ENABLE_TASKS');
ok(!exists $container_data->{env}{CLAUDE_CODE_ENABLE_TASKS},
    'AC-5: container env block does not set CLAUDE_CODE_ENABLE_TASKS');
ok(!exists $host_data->{env}{CLAUDE_CODE_ENABLE_TODO_TOOLS},
    'AC-5: host env block does not set CLAUDE_CODE_ENABLE_TODO_TOOLS');
ok(!exists $container_data->{env}{CLAUDE_CODE_ENABLE_TODO_TOOLS},
    'AC-5: container env block does not set CLAUDE_CODE_ENABLE_TODO_TOOLS');

# =====================================================================
# AC-6 (spec §1.3) — todoFeatureEnabled is absent from both files at the
# top level. settings.json is a source claude.exe 2.1.282 resolves it from,
# but no code path reads the resolved value (5-occurrence trace, spec
# §1.3) — it would be a declared key with no observable effect.
# =====================================================================

ok(!exists $host_data->{todoFeatureEnabled},
    'AC-6: host settings.json does not set a top-level todoFeatureEnabled');
ok(!exists $container_data->{todoFeatureEnabled},
    'AC-6: container settings.json does not set a top-level todoFeatureEnabled');

# =====================================================================
# B-1..B-5 (03-strip-claude-code-bloat spec §2.3, done criterion 5) — targeted
# assertions on the 8 new switches, both files.
# =====================================================================

my @BOOL_SWITCHES = qw(disableArtifact disableRemoteControl disableClaudeAiConnectors);
my @ENV_SWITCHES  = qw(CLAUDE_CODE_DISABLE_ADVISOR_TOOL CLAUDE_CODE_DISABLE_FAST_MODE
                       DISABLE_BUG_COMMAND DISABLE_FEEDBACK_COMMAND);
my @SKILL_NAMES = qw(
    artifact-capabilities artifact-design artifact-diagramming batch claude-api
    code-review dataviz fewer-permission-prompts loop run run-skill-generator
    security-review simplify team-onboarding verify
);
my %EXPECTED_SKILL_OVERRIDES = map { $_ => 'off' } @SKILL_NAMES;

for my $case (
    [ 'global-config/settings.json',                 $host_data ],
    [ 'plugins/sandbox/container/settings.json',      $container_data ],
) {
    my ($label, $data) = @$case;

    # B-1
    for my $key (@BOOL_SWITCHES) {
        ok(JSON::PP::is_bool($data->{$key}) && $data->{$key},
            "B-1: $label $key is a JSON boolean true");
    }

    # B-2
    is_deeply($data->{skillOverrides}, \%EXPECTED_SKILL_OVERRIDES,
        "B-2: $label skillOverrides is exactly the 15-name object, every value 'off'");

    # B-3
    SKIP: {
        skip "B-3: $label skillOverrides is not a hash -- cannot check for stray keys", 1
            unless ref($data->{skillOverrides}) eq 'HASH';
        my @stray = grep {
            $_ eq 'update-config' || $_ eq 'keybindings-help' || /:/
        } keys %{ $data->{skillOverrides} };
        is_deeply(\@stray, [],
            "B-3: $label skillOverrides has no update-config/keybindings-help/`:`-qualified key");
    }

    # B-4
    for my $key (@ENV_SWITCHES) {
        is($data->{env}{$key}, '1', "B-4: $label env.$key is exactly '1'");
    }

    # B-5
    ok(!exists $data->{disableFastMode},
        "B-5: $label has no top-level disableFastMode");
    my @anthropic_skill_plugins = grep { /anthropic-skills/ }
        keys %{ $data->{enabledPlugins} || {} };
    is_deeply(\@anthropic_skill_plugins, [],
        "B-5: $label has no anthropic-skills key in enabledPlugins");
}

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
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): turn off the
    # Artifact tool family and /artifacts. claude.exe 2.1.282 marks this key
    # "Deprecated: use enableArtifact: false" but STILL HONOURS it via the
    # legacyDisableKey resolver (var C={legacyDisableKey:"disableArtifact",...};
    # a true value in any scanned settings layer flips mst()/g()/I$n()/ET()/kT()
    # to disabled). This also removes the artifact-design and
    # artifact-diagramming bundled skills (isEnabled:ET), overlapping with
    # skillOverrides below deliberately. Re-check on every Claude Code update.
    disableArtifact                => JSON::PP::true,
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): turn off claude.ai
    # MCP cloud connectors. claude.exe 2.1.282 reads this via ale(), true if any
    # settings source sets it; gates both the auto-fetch of claudeai-mcp servers
    # and the connect path for claudeai-scope servers only -- plugin-provided
    # MCP servers (chrome-devtools-mcp, the notion plugin) are a different scope
    # and are unaffected. Re-check on every Claude Code update.
    disableClaudeAiConnectors      => JSON::PP::true,
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): turn off Remote
    # Control (claude.ai/code, `claude remote-control`, --remote-control/--rc,
    # auto-start, the in-session toggle). claude.exe 2.1.282 reads this via
    # gH() = QP()?.settings.disableRemoteControl===!0, off merged settings
    # (userSettings included). Re-check on every Claude Code update.
    disableRemoteControl           => JSON::PP::true,
    # DELIBERATE DECLARATION, operator request 2026-09-27: turn off Claude Code's
    # Workflows feature (the Workflow tool), which ccpraxis does not use. butler's
    # director does its own orchestration. Schema: "Disable the Workflows
    # feature (also via CLAUDE_CODE_DISABLE_WORKFLOWS)".
    disableWorkflows               => JSON::PP::true,
    # DELIBERATE DECLARATION, operator request 2026-09-27: turn off agent view
    # (claude agents, --bg, /background, the attach/stop/logs subcommands, the
    # daemon). A Left arrow on an empty prompt backgrounded a live session, and
    # the re-attached renderer lost mouse reporting. A trace of claude.exe
    # 2.1.282 found the gate only in the CLI dispatcher and agent-view UI, never
    # in Task/Bash/Monitor/SendMessage/resume.
    disableAgentView               => JSON::PP::true,
    editorMode                     => 'vim',
    effortLevel                    => 'high',
    enabledPlugins => {
        'backpack@ccpraxis-local'                 => JSON::PP::true,
        'blueprint@ccpraxis-local'                 => JSON::PP::true,
        'butler@ccpraxis-local'                    => JSON::PP::true,
        'feature-dev@claude-plugins-official'      => JSON::PP::true,
        'frontend-design@claude-plugins-official'  => JSON::PP::true,
        'sandbox@ccpraxis-local'                   => JSON::PP::true,
        'steward@ccpraxis-local'                   => JSON::PP::true,
    },
    env => {
        CLAUDE_AUTO_BACKGROUND_TASKS               => '1',
        CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR   => '0',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): hides the
        # advisor server tool and /advisor. claude.exe 2.1.282 reads this via
        # D.bool() (true only for "1"/"true"/"yes"/"on"), gating urt()/$S();
        # with urt() false the advisor tool is never attached to the request.
        # Re-check on every Claude Code update.
        CLAUDE_CODE_DISABLE_ADVISOR_TOOL           => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): hides /fast.
        # claude.exe 2.1.282 reads this via D.bool(), gating oo(); /fast's
        # isHidden is !oo(). Re-check on every Claude Code update.
        CLAUDE_CODE_DISABLE_FAST_MODE              => '1',
        CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY        => '1',
        CLAUDE_CODE_ENABLE_AWAY_SUMMARY            => '1',
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL          => 'true',
        CLAUDE_CODE_NEW_INIT                       => '1',
        CLAUDE_CODE_NO_FLICKER                     => '1',
        CLAUDE_CODE_SCROLL_SPEED                   => '3',
        # DELIBERATE DECLARATION, operator-approved 2026-09-26: the env override
        # for Claude Code's internal tengu_ticklish_whisper flag (read from the
        # claude.exe 2.1.282 source). When auto mode hits 3 consecutive
        # classifier blocks in the main session, the prompt then auto-denies
        # after 120s instead of halting an unattended run. It is undocumented, so
        # re-check it on every Claude Code update.
        CLAUDE_CODE_TICKLISH_WHISPER               => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 02-disable-builtin-tasks): suppresses
        # both the built-in "task tools haven't been used recently" reminder
        # and the TodoWrite reminder. claude.exe 2.1.282 reads this via
        # D.enum(["baseline","off"]) — a case-sensitive, trimmed match, so
        # only the exact string "off" (not "Off", "OFF" or "0") is honoured;
        # anything else silently falls back to the remote default. The key is
        # undocumented, so re-check it on every Claude Code update.
        CLAUDE_CODE_TODO_REMINDER_MODE             => 'off',
        CLAUDE_CODE_USE_POWERSHELL_TOOL            => '1',
        DISABLE_AUTOUPDATER                        => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): disables
        # /bug. claude.exe 2.1.282's Rj() reads DISABLE_FEEDBACK_COMMAND first,
        # then this key (D.bool()); either alone is sufficient, both are set
        # per Decision 7. Re-check on every Claude Code update.
        DISABLE_BUG_COMMAND                        => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): disables
        # /feedback, the feedback tip, and (via Crr()) the already-denied
        # SendFeedback tool's fourth lever. claude.exe 2.1.282's Rj() reads
        # this via D.bool(). Re-check on every Claude Code update.
        DISABLE_FEEDBACK_COMMAND                   => '1',
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
                        # 2026-09-24 -- guarded form, declared on the operator's instruction:
                        # a bare `perl <missing script>` exits 2, which blocks every Bash
                        # call while the live install is absent (hook-continuity-remake 01
                        # red-team H1). Pinned by global-config-perl-hook-guard.t.
                        command => 'f="$HOME/.claude/ccpraxis/scripts/hooks/block-nul-redirect.pl"; [ -f "$f" ] || exit 0; exec perl "$f"',
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
            # Skill(todo:*) removed: almanac-records 13, Decision 14.
            'Bash(find *)', 'Bash(grep *)', 'Bash(wc *)', 'Bash(awk *)', 'Bash(echo *)',
            'Bash(claude --version)', 'Bash(where claude*)', 'Bash(which claude*)',
            'Bash(git add *)', 'Bash(git commit *)', 'Bash(git rm *)',
            'Bash(perl ~/.claude/ccpraxis/scripts/*)',
            'Bash(perl ~/.claude/ccpraxis/plugins/steward/scripts/*)',
            'Bash(bash ~/.claude/ccpraxis/plugins/steward/scripts/*)',
            # DELIBERATE DECLARATION: commit 29cd74c, approved by the operator on
            # 2026-09-26 ("sounds good to me, go ahead"). Routine read-only and
            # test commands, allowed outright so they never reach the auto-mode
            # classifier, whose blocks escalate to a prompt that halts unattended
            # runs. Every entry reads or runs this repo's own tests; none writes
            # outside the repo, deletes, pushes or installs anything. The
            # BP_VALIDATE_LEDGER mid-wildcard entry was dropped by never-halt 03
            # (Decision 6); --ledger rides the plain runner rule.
            'Bash(perl scripts/run-tests.pl *)',
            'Bash(perl -c *)',
            'Bash(git diff *)', 'Bash(git log *)', 'Bash(git show *)',
            'Bash(git status *)', 'Bash(git ls-files *)',
            'Bash(ls *)', 'Bash(cat *)', 'Bash(head *)', 'Bash(tail *)',
            'Bash(sed -n *)', 'Bash(sha256sum *)',
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
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): sets all 15
    # named bundled prompt skills to "off" via claude.exe 2.1.282's
    # skillOverrides enum (["on","name-only","user-invocable-only","off"] --
    # not a boolean; "off" is the only value used here). The reader chain is
    # nIn()/OOe()/S2()/N0(): "off" fails WQ(), so the skill never reaches the
    # Skill tool's command set (mT) nor the skill_listing text the model
    # reads, and a typed /name is refused with "disabled via skillOverrides".
    # Plugin skills always resolve to "on" (OOe: e.source==="plugin" => "on"),
    # so no ccpraxis-local skill is affected. update-config and
    # keybindings-help are deliberately NOT keys here (they are not on the
    # operator's list and must stay "on" -- see B-3 below). Re-check this
    # list on every Claude Code update, since skillOverrides matches by name.
    skillOverrides => {
        'artifact-capabilities'    => 'off',
        'artifact-design'          => 'off',
        'artifact-diagramming'     => 'off',
        'batch'                    => 'off',
        'claude-api'               => 'off',
        'code-review'              => 'off',
        'dataviz'                  => 'off',
        'fewer-permission-prompts' => 'off',
        'loop'                     => 'off',
        'run'                      => 'off',
        'run-skill-generator'      => 'off',
        'security-review'          => 'off',
        'simplify'                 => 'off',
        'team-onboarding'          => 'off',
        'verify'                   => 'off',
    },
    skipAutoPermissionPrompt     => JSON::PP::true,
    statusLine => {
        # 2026-09-24 -- same guarded form as the perl hooks (see block-nul-redirect above).
        command => 'f="$HOME/.claude/ccpraxis/scripts/statusline.pl"; [ -f "$f" ] || exit 0; exec perl "$f"',
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
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): turn off the
    # Artifact tool family and /artifacts. claude.exe 2.1.282 marks this key
    # "Deprecated: use enableArtifact: false" but STILL HONOURS it via the
    # legacyDisableKey resolver (var C={legacyDisableKey:"disableArtifact",...};
    # a true value in any scanned settings layer flips mst()/g()/I$n()/ET()/kT()
    # to disabled). This also removes the artifact-design and
    # artifact-diagramming bundled skills (isEnabled:ET), overlapping with
    # skillOverrides below deliberately. Re-check on every Claude Code update.
    disableArtifact         => JSON::PP::true,
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): turn off claude.ai
    # MCP cloud connectors. claude.exe 2.1.282 reads this via ale(), true if any
    # settings source sets it; gates both the auto-fetch of claudeai-mcp servers
    # and the connect path for claudeai-scope servers only -- plugin-provided
    # MCP servers (chrome-devtools-mcp, the notion plugin) are a different scope
    # and are unaffected. Re-check on every Claude Code update.
    disableClaudeAiConnectors => JSON::PP::true,
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): turn off Remote
    # Control (claude.ai/code, `claude remote-control`, --remote-control/--rc,
    # auto-start, the in-session toggle). claude.exe 2.1.282 reads this via
    # gH() = QP()?.settings.disableRemoteControl===!0, off merged settings
    # (userSettings included). Re-check on every Claude Code update.
    disableRemoteControl    => JSON::PP::true,
    editorMode              => 'vim',
    effortLevel             => 'high',
    enabledPlugins => {
        'feature-dev@claude-plugins-official'     => JSON::PP::true,
        'frontend-design@claude-plugins-official' => JSON::PP::true,
    },
    env => {
        CLAUDE_AUTO_BACKGROUND_TASKS             => '1',
        CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR => '0',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): hides the
        # advisor server tool and /advisor. claude.exe 2.1.282 reads this via
        # D.bool() (true only for "1"/"true"/"yes"/"on"), gating urt()/$S();
        # with urt() false the advisor tool is never attached to the request.
        # Re-check on every Claude Code update.
        CLAUDE_CODE_DISABLE_ADVISOR_TOOL         => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): hides /fast.
        # claude.exe 2.1.282 reads this via D.bool(), gating oo(); /fast's
        # isHidden is !oo(). Re-check on every Claude Code update.
        CLAUDE_CODE_DISABLE_FAST_MODE            => '1',
        CLAUDE_CODE_ENABLE_AWAY_SUMMARY          => '1',
        CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL        => 'true',
        CLAUDE_CODE_NEW_INIT                     => '1',
        CLAUDE_CODE_NO_FLICKER                   => '1',
        CLAUDE_CODE_SCROLL_SPEED                 => '3',
        DISABLE_AUTOUPDATER                      => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): disables
        # /bug. claude.exe 2.1.282's Rj() reads DISABLE_FEEDBACK_COMMAND first,
        # then this key (D.bool()); either alone is sufficient, both are set
        # per Decision 7. Re-check on every Claude Code update.
        DISABLE_BUG_COMMAND                      => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 03-strip-claude-code-bloat): disables
        # /feedback, the feedback tip, and (via Crr()) the already-denied
        # SendFeedback tool's fourth lever. claude.exe 2.1.282's Rj() reads
        # this via D.bool(). Re-check on every Claude Code update.
        DISABLE_FEEDBACK_COMMAND                 => '1',
        DISABLE_INSTALL_GITHUB_APP_COMMAND       => '1',
        DISABLE_LOGIN_COMMAND                    => '0',
        DISABLE_LOGOUT_COMMAND                   => '0',
        DISABLE_UPGRADE_COMMAND                  => '1',
        ENABLE_PROMPT_CACHING_1H                 => '1',
        # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
        # operator-ui-tweaks, package 02-disable-builtin-tasks): suppresses
        # both the built-in "task tools haven't been used recently" reminder
        # and the TodoWrite reminder. claude.exe 2.1.282 reads this via
        # D.enum(["baseline","off"]) — a case-sensitive, trimmed match, so
        # only the exact string "off" (not "Off", "OFF" or "0") is honoured;
        # anything else silently falls back to the remote default. The key is
        # undocumented, so re-check it on every Claude Code update.
        CLAUDE_CODE_TODO_REMINDER_MODE           => 'off',
        # DELIBERATE DECLARATION, tooling-fixes package 15 (Decision 46):
        # reopens the global plugin-update gate that DISABLE_AUTOUPDATER shuts
        # (claude.exe 2.1.282's bee() requires FORCE_AUTOUPDATE_PLUGINS once
        # DISABLE_AUTOUPDATER is set). The per-marketplace `autoUpdate` flag
        # the launcher writes every launch into known_marketplaces.json is the
        # effective gate -- false for every marketplace with a host-shared
        # plugin, true only for a marketplace whose sandbox plugins are all
        # sandbox-only, so a host-shared plugin can never be moved past the
        # host's version by this flag. Re-check on every Claude Code update.
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
    # DELIBERATE DECLARATION, operator request 2026-09-27 (blueprint
    # operator-ui-tweaks, package 03-strip-claude-code-bloat): sets all 15
    # named bundled prompt skills to "off" via claude.exe 2.1.282's
    # skillOverrides enum (["on","name-only","user-invocable-only","off"] --
    # not a boolean; "off" is the only value used here). The reader chain is
    # nIn()/OOe()/S2()/N0(): "off" fails WQ(), so the skill never reaches the
    # Skill tool's command set (mT) nor the skill_listing text the model
    # reads, and a typed /name is refused with "disabled via skillOverrides".
    # Plugin skills always resolve to "on" (OOe: e.source==="plugin" => "on"),
    # so no ccpraxis-local skill is affected. update-config and
    # keybindings-help are deliberately NOT keys here (they are not on the
    # operator's list and must stay "on" -- see B-3 below). Re-check this
    # list on every Claude Code update, since skillOverrides matches by name.
    skillOverrides => {
        'artifact-capabilities'    => 'off',
        'artifact-design'          => 'off',
        'artifact-diagramming'     => 'off',
        'batch'                    => 'off',
        'claude-api'               => 'off',
        'code-review'              => 'off',
        'dataviz'                  => 'off',
        'fewer-permission-prompts' => 'off',
        'loop'                     => 'off',
        'run'                      => 'off',
        'run-skill-generator'      => 'off',
        'security-review'          => 'off',
        'simplify'                 => 'off',
        'team-onboarding'          => 'off',
        'verify'                   => 'off',
    },
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
        # bug 20260922-213748-6c76 -- the operator wants SendFeedback never
        # loaded into any agent's context, host or sandbox. Three independent
        # levers, each of which alone leaves the tool out, so losing one to a
        # /config rewrite or a re-stated deny array does not bring it back:
        # feedbackDrafts "off" is the tool's own isEnabled() switch,
        # CLAUDE_CODE_SEND_FEEDBACK=0 its documented env gate, and a bare-name
        # deny removes a tool from context. Both files carry all three.
        'permissions.deny[1]'           => 1,
        'feedbackDrafts'                => 1,
        'env.CLAUDE_CODE_SEND_FEEDBACK' => 1,
        # 2026-08-29 -- two guards promoted from prose to enforcement, both
        # registered globally so they apply in EVERY project, not just ccpraxis.
        #
        # block-nonascii-ps1: the ASCII-only rule for .ps1 was already written
        # down in CLAUDE.md, in detail, with the failure spelled out -- and BOTH
        # .ps1 files in this repo violated it anyway, the sandbox launcher among
        # them, carrying an ODD number of 0x94 bytes. Same conclusion
        # guard-git-mutations.sh reached: a written instruction is not an
        # enforcement mechanism.
        #
        # reap-orphans-hook: a SessionStart sweep for processes left behind by
        # sessions that already ended (bug 20260828-095201-7c1e). Per-machine
        # rather than per-project -- that orphan was spawned by a ccpraxis
        # session and found from an unrelated one.
        'hooks.PreToolUse[1].matcher'            => 1,
        'hooks.PreToolUse[1].hooks[0].type'      => 1,
        'hooks.PreToolUse[1].hooks[0].command'   => 1,
        'hooks.SessionStart[0].hooks[0].type'    => 1,
        'hooks.SessionStart[0].hooks[0].command' => 1,
        'env.CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION' => 1,
                                       # 2026-08-28 -- the built-in 200-subagent
                                       # ceiling refused a blueprint's mandatory
                                       # auditor gate in a session that had spawned
                                       # none of its own. A butler fleet run reaches
                                       # that ceiling legitimately: seven packages
                                       # times a scout/architect/test-writer/
                                       # implementer-loop/reviewer/redteam/fix-batch
                                       # pipeline, plus judges and relaunches, is
                                       # already in the hundreds. Raised on all
                                       # three surfaces (host payload, its live
                                       # mirror, and the container blueprint) so a
                                       # sandbox is not left with the old cap.
        # env todo-tools switch removed on both surfaces, almanac-records 13 / Decision 23.
        'enabledPlugins.almanac@ccpraxis-local' => 1,
                                       # 2026-09-10 (34a84b9) -- almanac shipped
                                       # complete and unregistered: no entry in
                                       # plugins/.claude-plugin/marketplace.json,
                                       # so /almanac:bug-report and
                                       # /almanac:bug-triage existed nowhere and
                                       # guard-almanac-write.sh, registered via
                                       # ${CLAUDE_PLUGIN_ROOT}, never ran. Enabled
                                       # here (the host payload) alongside the
                                       # marketplace entry. Host-only by nature:
                                       # the container blueprint enables no
                                       # ccpraxis plugin -- those come from the
                                       # launcher's picker -- so unlike the two
                                       # env keys above this lands on one surface,
                                       # not three.
        'timeFormat' => 1,             # 2026-09-28 -- the operator's 24-hour clock,
                                       # on both surfaces. First added in 1b080f9
                                       # without a line here; the red A4 it left
                                       # was cleared by c04c1e6 rewriting both
                                       # payloads from copies that lacked it, and
                                       # the next promotion would then have deleted
                                       # it from the live settings too.
        # 2026-09-28 /steward:backup -- live-only keys the operator chose to
        # export to the host payload and propagate to the container. The two
        # builtin-plugin switches: agents-md@builtin (loading AGENTS.md as
        # project instructions; off by default in 2.1.282, so pinned rather
        # than changed) and telemetry@builtin (analytics from Claude Code's
        # builtin plugins; on by default, so this is a real opt-out).
        'enabledPlugins.agents-md@builtin'        => 1,
        'enabledPlugins.telemetry@builtin'        => 1,
        'modelSettings.claude-opus-5-5.effortLevel' => 1,
        'modelSettings.claude-sonnet-5.effortLevel' => 1,
        'tui'                                     => 1,
        # Host-payload keys that reached the container in the same run.
        # disableAgentView, disableWorkflows and CLAUDE_CODE_TICKLISH_WHISPER
        # are declared in $HOST_BASELINE already; these entries admit them
        # on the container side.
        'disableAgentView'                        => 1,
        'disableWorkflows'                        => 1,
        'env.CLAUDE_CODE_TICKLISH_WHISPER'        => 1,
        # 2026-10-22 -- operator answer to inbox 20261001-004728
        # (operator-ui-tweaks 03): stop syncing the skills enabled on
        # claude.ai into Claude Code. Both surfaces: the sandbox signs in
        # to the same account and would sync them just the same.
        'syncClaudeAiSkills'                      => 1,
    );
    my @unexpected = grep {
        !exists $baseline_flat->{$_} && !$permitted_additions{$_}
    } sort keys %$live_flat;
    $maybe_notice->($_) for @unexpected;
    is_deeply(\@unexpected, [],
        "A4: $label introduces no key path outside the baseline other than the "
      . scalar(keys %permitted_additions) . " named permitted additions");
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

# =====================================================================
# AC-7/AC-8/AC-9 (02-disable-builtin-tasks spec §2/§4, AC-7 to AC-9) —
# self-read checks on THIS test file's own source, not on the settings
# files. AC-7/AC-8: each baseline's CLAUDE_CODE_TODO_REMINDER_MODE entry is
# preceded by a comment block containing "DELIBERATE DECLARATION" (the same
# convention as disableWorkflows/disableAgentView/CLAUDE_CODE_TICKLISH_WHISPER
# above). AC-9: %permitted_additions carries no
# env.CLAUDE_CODE_TODO_REMINDER_MODE entry — the key is declared in-baseline
# (A4(a) covers it), never treated as an extra the live file is merely
# permitted to carry.
# =====================================================================

my $self_src = slurp("$Bin/transcript-retention.t");
my @self_lines = split /\n/, $self_src;

my ($host_marker_idx)      = grep { $self_lines[$_] =~ /\$HOST_BASELINE\s*=\s*\{/ } 0 .. $#self_lines;
my ($container_marker_idx) = grep { $self_lines[$_] =~ /\$CONTAINER_BASELINE\s*=\s*\{/ } 0 .. $#self_lines;

ok(defined $host_marker_idx,      'sanity: found $HOST_BASELINE = { in this file\'s own source');
ok(defined $container_marker_idx, 'sanity: found $CONTAINER_BASELINE = { in this file\'s own source');

sub declaration_comment_ok {
    my ($lines, $target_idx, $label, $key_name) = @_;
    $key_name = 'CLAUDE_CODE_TODO_REMINDER_MODE' unless defined $key_name;
    my @comment_lines;
    for (my $i = $target_idx - 1; $i >= 0; $i--) {
        my $line = $lines->[$i];
        last if $line !~ /^\s*#/;
        unshift @comment_lines, $line;
    }
    my $block = join("\n", @comment_lines);
    like($block, qr/DELIBERATE DECLARATION/,
        "$label: $key_name is preceded by a DELIBERATE DECLARATION comment");
}

SKIP: {
    skip 'AC-7: CLAUDE_CODE_TODO_REMINDER_MODE not found in $HOST_BASELINE source', 1
        unless defined $host_marker_idx && defined $container_marker_idx;

    my ($host_key_idx) = grep {
        $_ > $host_marker_idx && $_ < $container_marker_idx
            && $self_lines[$_] =~ /CLAUDE_CODE_TODO_REMINDER_MODE\s*=>\s*'off'/
    } 0 .. $#self_lines;

    skip 'AC-7: CLAUDE_CODE_TODO_REMINDER_MODE not found in $HOST_BASELINE source', 1
        unless defined $host_key_idx;
    declaration_comment_ok(\@self_lines, $host_key_idx, 'AC-7');
}

SKIP: {
    skip 'AC-8: CLAUDE_CODE_TODO_REMINDER_MODE not found in $CONTAINER_BASELINE source', 1
        unless defined $container_marker_idx;

    my ($container_key_idx) = grep {
        $_ > $container_marker_idx
            && $self_lines[$_] =~ /CLAUDE_CODE_TODO_REMINDER_MODE\s*=>\s*'off'/
    } 0 .. $#self_lines;

    skip 'AC-8: CLAUDE_CODE_TODO_REMINDER_MODE not found in $CONTAINER_BASELINE source', 1
        unless defined $container_key_idx;
    declaration_comment_ok(\@self_lines, $container_key_idx, 'AC-8');
}

unlike($self_src, qr/'env\.CLAUDE_CODE_TODO_REMINDER_MODE'\s*=>/,
    'AC-9: %permitted_additions carries no env.CLAUDE_CODE_TODO_REMINDER_MODE entry');

# =====================================================================
# B-6/B-7 (03-strip-claude-code-bloat spec §2.3 item 5) — self-read checks,
# generalising AC-7/AC-8/AC-9 to the 8 new keys.
# =====================================================================

my ($container_end_idx) = grep {
    $_ > $container_marker_idx && $self_lines[$_] =~ /^\};\s*$/
} 0 .. $#self_lines;

my @b6_cases = (
    [ 'disableArtifact',               qr/^\s*disableArtifact\s*=>/ ],
    [ 'disableClaudeAiConnectors',      qr/^\s*disableClaudeAiConnectors\s*=>/ ],
    [ 'disableRemoteControl',           qr/^\s*disableRemoteControl\s*=>/ ],
    [ 'skillOverrides',                 qr/^\s*skillOverrides\s*=>\s*\{/ ],
    [ 'CLAUDE_CODE_DISABLE_ADVISOR_TOOL', qr/^\s*CLAUDE_CODE_DISABLE_ADVISOR_TOOL\s*=>/ ],
    [ 'CLAUDE_CODE_DISABLE_FAST_MODE',  qr/^\s*CLAUDE_CODE_DISABLE_FAST_MODE\s*=>/ ],
    [ 'DISABLE_BUG_COMMAND',            qr/^\s*DISABLE_BUG_COMMAND\s*=>/ ],
    [ 'DISABLE_FEEDBACK_COMMAND',       qr/^\s*DISABLE_FEEDBACK_COMMAND\s*=>/ ],
);

SKIP: {
    skip 'B-6: baseline markers not found in this file\'s own source',
        scalar(@b6_cases) * 2
        unless defined $host_marker_idx && defined $container_marker_idx && defined $container_end_idx;

    for my $case (@b6_cases) {
        my ($name, $pattern) = @$case;

        my ($host_key_idx) = grep {
            $_ > $host_marker_idx && $_ < $container_marker_idx && $self_lines[$_] =~ $pattern
        } 0 .. $#self_lines;
        SKIP: {
            skip "B-6: $name not found in \$HOST_BASELINE source", 1
                unless defined $host_key_idx;
            declaration_comment_ok(\@self_lines, $host_key_idx, "B-6 ($name, host)", $name);
        }

        my ($container_key_idx) = grep {
            $_ > $container_marker_idx && $_ < $container_end_idx && $self_lines[$_] =~ $pattern
        } 0 .. $#self_lines;
        SKIP: {
            skip "B-6: $name not found in \$CONTAINER_BASELINE source", 1
                unless defined $container_key_idx;
            declaration_comment_ok(\@self_lines, $container_key_idx, "B-6 ($name, container)", $name);
        }
    }
}

for my $pattern (
    qr/'disableArtifact'\s*=>/,
    qr/'disableRemoteControl'\s*=>/,
    qr/'disableClaudeAiConnectors'\s*=>/,
    qr/'skillOverrides\./,
    qr/'env\.CLAUDE_CODE_DISABLE_ADVISOR_TOOL'/,
    qr/'env\.CLAUDE_CODE_DISABLE_FAST_MODE'/,
    qr/'env\.DISABLE_BUG_COMMAND'/,
    qr/'env\.DISABLE_FEEDBACK_COMMAND'/,
) {
    unlike($self_src, $pattern,
        "B-7: %permitted_additions carries no entry matching $pattern");
}

# =====================================================================
# TF15-1/TF15-2/TF15-3 (tooling-fixes package 15, Decision 46, spec §2.13.2
# item 4) -- self-read checks pinning the FORCE_AUTOUPDATE_PLUGINS
# re-addition and the extraKnownMarketplaces.*.autoUpdate invariant.
# =====================================================================

my ($force_autoupdate_idx) = grep {
    $_ > $container_marker_idx && $_ < $container_end_idx
        && $self_lines[$_] =~ /^\s*FORCE_AUTOUPDATE_PLUGINS\s*=>\s*'1'/
} 0 .. $#self_lines;

ok(defined $force_autoupdate_idx,
    'TF15-1: FORCE_AUTOUPDATE_PLUGINS => \'1\' found in $CONTAINER_BASELINE source, strictly inside the hash');

SKIP: {
    skip 'TF15-1: FORCE_AUTOUPDATE_PLUGINS not found in $CONTAINER_BASELINE source', 1
        unless defined $force_autoupdate_idx;
    declaration_comment_ok(\@self_lines, $force_autoupdate_idx, 'TF15-1', 'FORCE_AUTOUPDATE_PLUGINS');
}

unlike($self_src, qr/'env\.FORCE_AUTOUPDATE_PLUGINS'\s*=>/,
    'TF15-2: %permitted_additions carries no env.FORCE_AUTOUPDATE_PLUGINS entry');

{
    my $ekm = (ref $container_data->{extraKnownMarketplaces} eq 'HASH')
        ? $container_data->{extraKnownMarketplaces} : {};
    my @with_autoupdate = sort grep {
        ref $ekm->{$_} eq 'HASH' && exists $ekm->{$_}{autoUpdate}
    } keys %$ekm;
    is_deeply(\@with_autoupdate, [],
        'TF15-3: no extraKnownMarketplaces.*.autoUpdate key in the live container file');

    unlike($self_src, qr/'extraKnownMarketplaces\.[^']*autoUpdate'\s*=>/,
        'TF15-3: %permitted_additions carries no extraKnownMarketplaces.*.autoUpdate entry');
}

done_testing();
