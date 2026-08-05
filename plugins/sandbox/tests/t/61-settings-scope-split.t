#!/usr/bin/env perl
# Oracle for the settings-scope split: machine-local state in
# .claude/settings.local.json, shared project state in .claude/settings.json.
#
# WHY THIS FILE EXISTS
#
# Claude Code documents the two project settings files as:
#   .claude/settings.json        "checked into source control and shared with your team"
#   .claude/settings.local.json  personal, not checked in (it even auto-adds this
#                                one to your global git excludes)
# and resolves them Local-over-Project.
#
# skills.pl inverted that. discover_plugins read settings.json ONLY, on the
# stated reasoning that it was "the project's source of truth regardless of
# whether the project commits it", and cmd_select_interactive's Phase B wrote
# the TUI's per-launch, per-machine plugin selection straight back into it. The
# shared file therefore churned on every single sandbox launch, so this repo
# gitignored its own project config (.gitignore, removed 2026-08-06) — and that
# is why the butler git-guard's hook registration could not be tracked, leaving
# a fresh clone silently running with no guard at all.
#
# So the assertions here are not stylistic. C5 in particular is the end-to-end
# point of the whole change.
#
# NEVER build an image or start a container here. skills.pl is `require`d with
# SANDBOX_SKILLS_NO_DISPATCH=1 (the harness hook it already provides) and driven
# against File::Temp fixtures; the real project is never touched.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);
use JSON::PP;

my $REPO_ROOT = abs_path("$Bin/../../../..");
BAIL_OUT("cannot resolve repo root from $Bin/../../../..") unless defined $REPO_ROOT;

my $SKILLS = "$REPO_ROOT/plugins/sandbox/scripts/skills.pl";
BAIL_OUT("cannot find skills.pl at $SKILLS") unless -f $SKILLS;

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1 }
require "$REPO_ROOT/plugins/sandbox/scripts/skills.pl";

my $J = JSON::PP->new->canonical(1)->pretty;

sub write_json_file {
    my ($path, $data) = @_;
    my $dir = $path; $dir =~ s{/[^/]+$}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or BAIL_OUT("cannot write $path: $!");
    print $fh $J->encode($data);
    close $fh;
}

# Build a fixture project: a project-scope install of every key we care about,
# so partition is decided purely by the settings files (which is what we test).
sub fixture {
    my (%arg) = @_;                      # settings => {...}, local => {...}
    my $root = tempdir(CLEANUP => 1);
    (my $proj = $root) =~ s{\\}{/}g;

    my @keys = qw(alpha@mkt bravo@mkt charlie@mkt delta@mkt echo@mkt);
    my %plugins = map {
        $_ => [ { installPath => "$proj/.fake/$_", scope => 'project',
                  projectPath => $proj, version => '1.0.0' } ]
    } @keys;
    my $plugins_file = "$proj/installed_plugins.json";
    write_json_file($plugins_file, { plugins => \%plugins });

    write_json_file("$proj/.claude/settings.json", $arg{settings}) if $arg{settings};
    write_json_file("$proj/.claude/settings.local.json", $arg{local}) if $arg{local};

    return ($proj, $plugins_file);
}

sub by_key {
    my ($rows) = @_;
    return { map { $_->{key} => $_ } @$rows };
}

# =====================================================================
# A -- discover_plugins merges both files, Local over Project
# =====================================================================
{
    my ($proj, $pf) = fixture(
        settings => { enabledPlugins => {
            'alpha@mkt'   => JSON::PP::true,     # project only, on
            'bravo@mkt'   => JSON::PP::true,     # overridden off locally
            'charlie@mkt' => JSON::PP::false,    # overridden on locally
        } },
        local => { enabledPlugins => {
            'bravo@mkt' => JSON::PP::false,
            'charlie@mkt' => JSON::PP::true,
            'delta@mkt'   => JSON::PP::true,     # local only -- the TUI's own write
        } },
        # echo@mkt appears in NEITHER file
    );

    my $rows = by_key(discover_plugins(plugins_file => $pf, project_path => $proj));

    is($rows->{'alpha@mkt'}{partition}, 'project',
       'A1: key present only in settings.json partitions as project');
    ok($rows->{'alpha@mkt'}{enabled}, 'A1: ...and is enabled');

    ok(!$rows->{'bravo@mkt'}{enabled},
       'A2: settings.json true + settings.local.json false => DISABLED (Local overrides Project)')
        or diag('local override was ignored -- this is the precedence Claude Code documents');
    is($rows->{'bravo@mkt'}{partition}, 'project',
       'A2: a local `false` override still partitions as project (a decision was made)');

    ok($rows->{'charlie@mkt'}{enabled},
       'A3: settings.json false + settings.local.json true => ENABLED (Local overrides Project)');

    is($rows->{'delta@mkt'}{partition}, 'project',
       'A4: a key present ONLY in settings.local.json still partitions as project')
        or diag('presence must count in EITHER file, else every TUI selection demotes itself '
              . 'back to a suggestion on the next launch');
    ok($rows->{'delta@mkt'}{enabled}, 'A4: ...and is enabled');

    is($rows->{'echo@mkt'}{partition}, 'suggestion',
       'A5: a key in neither settings file is a suggestion');
    ok(!$rows->{'echo@mkt'}{enabled}, 'A5: ...and is not enabled');
}

# =====================================================================
# A6 -- neither file present at all: no crash, everything a suggestion
# (the fresh-clone / brand-new-project path)
# =====================================================================
{
    my ($proj, $pf) = fixture();
    my $rows = by_key(discover_plugins(plugins_file => $pf, project_path => $proj));
    is($rows->{'alpha@mkt'}{partition}, 'suggestion',
       'A6: with no settings files at all, every row is a suggestion (no crash)');
}

# =====================================================================
# B -- the writer, pointed at settings.local.json, leaves settings.json alone
# =====================================================================
{
    my ($proj) = fixture(settings => {
        enabledPlugins => { 'alpha@mkt' => JSON::PP::true },
        hooks          => { PreToolUse => [] },
    });
    my $shared = "$proj/.claude/settings.json";
    my $local  = "$proj/.claude/settings.local.json";

    open my $rfh, '<:raw', $shared or BAIL_OUT("cannot read $shared");
    my $shared_before = do { local $/; <$rfh> };
    close $rfh;

    ok(!-e $local, 'B0: settings.local.json does not exist yet');

    my $n = _apply_settings_json_changes($local, enabledPlugins => { 'delta@mkt' => 1 });
    ok($n > 0, 'B1: writing an override reports a change');
    ok(-f $local, 'B1: ...and creates settings.local.json');

    open my $lfh, '<:raw', $local or BAIL_OUT("cannot read $local");
    my $ldata = JSON::PP->new->decode(do { local $/; <$lfh> });
    close $lfh;
    ok($ldata->{enabledPlugins}{'delta@mkt'}, 'B1: ...containing the override');

    open my $rfh2, '<:raw', $shared or BAIL_OUT("cannot read $shared");
    my $shared_after = do { local $/; <$rfh2> };
    close $rfh2;
    is($shared_after, $shared_before,
       'B2: settings.json is byte-identical afterwards -- the shared file is untouched')
        or diag('the entire point of the split is that a launch cannot dirty the tracked file');

    # Deleting via undef
    my $n2 = _apply_settings_json_changes($local, enabledPlugins => { 'delta@mkt' => undef });
    ok($n2 > 0, 'B3: an undef value is a delete request and reports a change');
    open my $lfh2, '<:raw', $local or BAIL_OUT("cannot read $local");
    my $ldata2 = JSON::PP->new->decode(do { local $/; <$lfh2> });
    close $lfh2;
    ok(!exists $ldata2->{enabledPlugins}{'delta@mkt'},
       'B3: ...and the key is gone (this is how a redundant override is dropped)');
}

# =====================================================================
# B4 -- a no-op change set must not spawn an empty settings.local.json
# =====================================================================
{
    my ($proj) = fixture(settings => { enabledPlugins => {} });
    my $local = "$proj/.claude/settings.local.json";
    my $n = _apply_settings_json_changes($local, enabledPlugins => {});
    is($n, 0, 'B4: an empty change set reports no changes');
    ok(!-e $local,
       'B4: ...and does NOT create settings.local.json (a quiet launch leaves no litter)');
}

# =====================================================================
# C -- source + repo-level regression guards
#
# The Phase B delta rule lives in a closure inside cmd_select_interactive,
# which needs a TTY to drive, so C1/C2 assert its WIRING at source level
# rather than its behaviour. Stated plainly rather than dressed up: these two
# are structural checks, and A/B above are the behavioural ones.
# =====================================================================
{
    open my $fh, '<:raw', $SKILLS or BAIL_OUT("cannot open skills.pl");
    my $src = do { local $/; <$fh> };
    close $fh;

    ok($src =~ /_apply_settings_json_changes\(\s*\$settings_local\s*,\s*\n\s*enabledPlugins\s*=>/,
       'C1: Phase B routes enabledPlugins to $settings_local (settings.local.json)')
        or diag('enabledPlugins is machine-local state; writing it to the shared file is the '
              . 'bug this whole change exists to fix');

    ok($src =~ /_apply_settings_json_changes\(\s*\$settings_file\s*,\s*\n\s*enabledMcpjsonServers/,
       'C2: Phase B still routes the MCP lists to $settings_file (settings.json)')
        or diag('discover_mcp implements a two-tier semantic where settings.json means '
              . '"project" -- redirecting MCP would collapse every row to a permanent suggestion');

    ok($src !~ /settings\.local\.json is intentionally NOT consulted/,
       'C3: the stale "settings.local.json is intentionally NOT consulted" rationale is gone');
}

# =====================================================================
# C4/C5 -- the repo-level outcome. These are the reason the change exists.
# =====================================================================
{
    my $gi = "$REPO_ROOT/.gitignore";
    open my $fh, '<:raw', $gi or BAIL_OUT("cannot open .gitignore");
    my @gi = <$fh>;
    close $fh;
    my @code = grep { !/^\s*#/ } @gi;

    ok(!(grep { /^\s*\.claude\/settings\.json\s*$/ } @code),
       'C4a: .gitignore no longer ignores .claude/settings.json')
        or diag('while it is ignored, the butler git-guard registration cannot be tracked '
              . 'and a fresh clone runs with no guard');

    ok((grep { /^\s*\.claude\/settings\.local\.json\s*$/ } @code),
       'C4b: .gitignore still ignores .claude/settings.local.json (machine state stays out)');

    my $proj_settings = "$REPO_ROOT/.claude/settings.json";
  SKIP: {
        skip 'no .claude/settings.json in this checkout', 2 unless -f $proj_settings;
        open my $sfh, '<:raw', $proj_settings or BAIL_OUT("cannot open $proj_settings");
        my $raw = do { local $/; <$sfh> };
        close $sfh;
        my $s = eval { JSON::PP->new->utf8->decode($raw) };
        ok(ref $s eq 'HASH', 'C5a: the project settings.json parses as an object')
            or diag("decode failed: $@");

        my $registered = 0;
        if (ref $s eq 'HASH' && ref $s->{hooks} eq 'HASH') {
            for my $entry (@{ $s->{hooks}{PreToolUse} // [] }) {
                next unless ref $entry eq 'HASH';
                for my $h (@{ $entry->{hooks} // [] }) {
                    next unless ref $h eq 'HASH';
                    $registered = 1 if ($h->{command} // '') =~ /guard-git-mutations/;
                }
            }
        }
        ok($registered,
           'C5b: settings.json registers guard-git-mutations.sh as a PreToolUse/Bash hook')
            or diag('The guard script is tracked but nothing tracked REGISTERS it, so a fresh '
                  . 'clone gets the file and never runs it. That hook exists because a '
                  . 'prohibited `git stash` destroyed a completed fix-batch (commit ef272c3); '
                  . 'leaving its registration untracked repeats the very mistake it was '
                  . 'written to prevent -- an instruction is not an enforcement mechanism.');
    }
}

done_testing();
