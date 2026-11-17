#!/usr/bin/env perl
# platform: any
# launcher.pl's wiring of the sandbox settings merge, read as TEXT ONLY --
# never spawned (it would build an image and start a container). The merge
# itself, the backups and the declined-preset memory are driven directly in
# sandbox-settings-merge.t; the registry in sandbox-registry.t. This file
# pins that the launcher actually routes through them:
#
#   W1  a Rebuild no longer refreshes the per-project copies before the create
#       (that refresh is what made the create overwrite in-sandbox changes)
#   W2  every create merges the CURRENT preset into the sandbox settings and
#       refreshes CLAUDE.md through SandboxSettings, with the conflict prompt
#       as the resolver; nothing copies a per-project copy over claude-home
#   W3  the drift check honours a declined version, and "Continue" records it
#   W4  the stale prompt says what a new container does to the sandbox's
#       settings
#   W5  the conflict prompt: TUI only on an active frame, q/ESC keeps the
#       sandbox value, and with no terminal nothing reads STDIN
#   W6  the sandbox is recorded in the machine's sandbox list, fail-soft,
#       before the container starts
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $fh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read $LAUNCHER: $!");
my $SRC = do { local $/; <$fh> };
close $fh;

sub extract_sub_body {
    my ($src, $name) = @_;
    my $at = index($src, "sub $name ");
    $at = index($src, "sub $name\n") if $at < 0;
    return undef if $at < 0;
    my $open = index($src, '{', $at);
    return undef if $open < 0;
    my $depth = 0;
    for my $i ($open .. length($src) - 1) {
        my $c = substr($src, $i, 1);
        $depth++ if $c eq '{';
        if ($c eq '}') {
            $depth--;
            return substr($src, $open, $i - $open + 1) if $depth == 0;
        }
    }
    return undef;
}

# Code only: comment lines out, so prose naming a variable cannot satisfy or
# break an assertion about what the code does.
sub code_of { my ($s) = @_; return join "\n", grep { !/^\s*#/ } split /\n/, ($s // '') }

# ---- W1 ----
{
    my ($block) = $SRC =~ /\nif \(\$do_rebuild\) \{\n(.*?)\n\}\n/s;
    ok(defined $block, 'W1 found the Rebuild block');
    my $code = code_of($block);
    unlike($code, qr/\$CONTAINER_SETTINGS_JSON|\$CONTAINER_CLAUDE_MD\b|\$SETTINGS_HASH_FILE|\$CLAUDE_MD_HASH_FILE/,
        'W1 the Rebuild block no longer writes the per-project copies or their hashes');
}

# ---- W2 ----
{
    my $body = extract_sub_body($SRC, 'apply_blueprints_to_host_data');
    ok(defined $body, 'W2 apply_blueprints_to_host_data exists');
    my $code = code_of($body);
    like($code, qr/SandboxSettings::refresh_claude_md\(/, 'W2 CLAUDE.md goes through SandboxSettings::refresh_claude_md');
    like($code, qr/SandboxSettings::merge_settings\(/,    'W2 settings.json goes through SandboxSettings::merge_settings');
    like($code, qr/resolve\s*=>\s*\\&_ask_settings_conflict/, 'W2 a key changed on both sides is asked about (_ask_settings_conflict)');
    like($code, qr/backup_dir_maker\(\$LAUNCHER_DIR/, 'W2 backups go under the launcher dir');
    like($code, qr/_write_file\(\$SETTINGS_HASH_FILE,[^;]*\$CONTAINER_SETTINGS_JSON/,
        'W2 the settings hash records the base actually given');
    like($code, qr/if \(\$st->\{base_recorded\}\)/, 'W2 ... and only when the merge recorded it');
    unlike(code_of($SRC), qr/_copy_file\(\s*\$CONTAINER_SETTINGS_JSON/,
        'W2 nothing copies the per-project settings copy over anything any more');
    unlike(code_of($SRC), qr/_copy_file\(\s*\$CONTAINER_CLAUDE_MD/,
        'W2 nothing copies the per-project CLAUDE.md copy over anything any more');

    my ($create) = $SRC =~ /# >>> launch-emit:create:BEGIN\n(.*?)# <<< launch-emit:create:END/s;
    ok(defined $create, 'W2 found the create block');
    my $ccode = code_of($create);
    like($ccode, qr/apply_blueprints_to_host_data\(\);/, 'W2 the create block applies them');
    unlike($ccode, qr/if \(! -f \$CONTAINER_SETTINGS_JSON\)/,
        'W2 ... on every create, not only when no per-project copy exists (a recreate takes the current preset)');
}

# ---- W3 ----
{
    my $code = code_of($SRC);
    like($code, qr/\$SETTINGS_DRIFT = SandboxSettings::drift_state\(\s*saved\s*=>\s*_read_file\(\$SETTINGS_HASH_FILE\),\s*current\s*=>\s*\$CURRENT_SETTINGS_HASH,\s*declined\s*=>\s*_read_file\(\$SETTINGS_DECLINED_FILE\)\)/,
        'W3 the preset drift check reads the declined version');
    like($code, qr/push \@STALE_REASONS, "  - Container settings\.json upstream changed since last sandbox refresh"\s*\n\s*if \$SETTINGS_DRIFT eq 'changed';/,
        'W3 a declined preset version is not a stale reason');
    like($code, qr/if \(defined \$answer && \$answer eq 'continue' && \$ANSWER_WAS_INTERACTIVE\) \{\s*_write_file\(\$SETTINGS_DECLINED_FILE,\s*"\$CURRENT_SETTINGS_HASH\\n"\)\s*if \$SETTINGS_DRIFT eq 'changed';/,
        'W3 "Continue" over a preset change remembers that version');
    like($code, qr/my \$ANSWER_WAS_INTERACTIVE = \(\(\$LAUNCH_MODE ne 'plain' && \$LAUNCH_HOST && \$LAUNCH_HOST->\{active\}\) \|\| -t STDIN\) \? 1 : 0;/,
        'W3 ... only when somebody answered (a screen or a terminal), never a headless EOF default');
    my $plan_at     = index($SRC, 'my $PLAN = decide_launch_plan(');
    my $declined_at = index($SRC, "_write_file(\$SETTINGS_DECLINED_FILE");
    ok($plan_at > 0 && $declined_at > $plan_at, 'W3 ... after the answer is in');
    like($SRC, qr/\$SETTINGS_DECLINED_FILE\s*=\s*"\$LAUNCHER_DIR\//, 'W3 the memory is per project (under its launcher dir)');
}

# ---- W4 ----
{
    my $body = extract_sub_body($SRC, 'prompt_stale_action');
    like(code_of($body), qr/push \@reasons, '', sandbox_settings_create_note\(\);/,
        'W4 the stale prompt carries the settings note in every path (TUI detail, plain lists)');
    my $note = join ' ', grep { defined } (code_of(extract_sub_body($SRC, 'sandbox_settings_create_note')) =~ /"([^"]*)"/g);
    like($note, qr/merged/,     'W4 the note says settings.json is merged');
    like($note, qr/backed up/,  'W4 the note says the old file is backed up');
    like($note, qr/\.launcher\/backups\//, 'W4 the note says where');
    like($note, qr/keep/,       'W4 the note says what the default is');
}

# ---- W5 ----
{
    my $body = code_of(extract_sub_body($SRC, '_ask_settings_conflict'));
    ok(length $body, 'W5 _ask_settings_conflict exists');
    like($body, qr/\$LAUNCH_HOST->\{active\}/, 'W5 the TUI path is gated on an ACTIVE frame');
    like($body, qr/menu_choice\(_launch_run_list\(\$model\), 'keep'\)/, 'W5 q/ESC on the screen keeps the sandbox value');
    my $tty_at  = index($body, "return 'keep' unless -t STDIN && -t STDOUT;");
    my $read_at = index($body, '<STDIN>');
    ok($tty_at > 0 && $read_at > $tty_at, 'W5 with no terminal it keeps the sandbox value without reading STDIN');
    like($body, qr/->ascii/, 'W5 container-written values are shown ASCII-escaped');
    my $start_at = index($SRC, "_tee_system(\$PODMAN, 'start'");
    $start_at = index($SRC, "system(\$PODMAN, 'start'") if $start_at < 0;
    ok($start_at > index($SRC, 'sub _ask_settings_conflict'), 'W5 the prompt is defined before podman start (no STDIN read after it)');
}

# ---- W6 ----
{
    my $end_at = index($SRC, '# <<< launch-emit:create:END');
    my $reg_at = index($SRC, 'SandboxRegistry::register(');
    ok($reg_at > $end_at, 'W6 the sandbox is registered after the create block');
    my ($call) = $SRC =~ /(SandboxRegistry::register\(.*?\);)/s;
    like($call // '', qr/registry\s*=>\s*SandboxRegistry::registry_path\(\$CLAUDE_HOST_CONFIG\)/, 'W6 in the host ~/.claude, never in the project');
    like($call // '', qr/launcher\s*=>\s*\$SandboxIdentity::ID/, 'W6 with the launcher identity');
    my $win = substr($SRC, $reg_at - 200, 900);
    like($win, qr/my \$reg = eval \{/, 'W6 fail-soft: a registry failure cannot stop the launch');
}

done_testing();
