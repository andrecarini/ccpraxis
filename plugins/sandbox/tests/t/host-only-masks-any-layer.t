#!/usr/bin/env perl
# platform: any
# Oracle for blueprint package 05-host-only-masks (sandbox-session-ux), Decision
# 10: a plugin's host-only skills must be masked in the container whenever ANY
# settings layer the container can see enables it -- the picker's own selection,
# the project's tracked settings, the project's local settings, or either of the
# container's two user-level settings files -- never only picker-selected
# plugins. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-session-ux/specs/05-host-only-masks-spec.md
# section 4 (the 13-row acceptance table) plus Decisions 10 and 15. NOT derived
# from skills.pl's or launcher.pl's implementation of the new option handling --
# that does not exist yet, which is exactly why most assertions below are
# expected to fail today.
#
# THE BUG THIS CLOSES: this repo's own tracked .claude/settings.json enables
# sandbox@ccpraxis-local, an all-host-only plugin, at project scope. It is
# never picker-selected, so today's mask pass never sees it and its two
# host-only skills leak into every container. AC1-4 reproduce that shape with
# a synthetic fixture instead of this repo's real settings (Decision 15).
#
# FIXTURE, all synthetic (Decision 15) -- one directory-source marketplace,
# fixture-local, with four plugins:
#   allhost  -- alpha, beta,        both host-only
#   mixed    -- keeper (safe), gone-a, gone-b (host-only)
#   safe     -- one,               container-safe
#   noskills -- a hooks/ dir only, no SKILL.md anywhere
# plus a second, NON-directory marketplace, fixture-copied, carrying a plugin
# "copied" with a host-only skill in a throwaway tree the launcher never binds
# -- proving resolution never masks a copied marketplace's plugin even when
# every layer enables it (AC6, spec Observable 7).
#
# HARNESS, following host-only-plugin-skills.t: skills.pl is run as a genuine
# child process via list-form open '-|' under a throwaway HOME (never the
# operator's real one). No container is started and launcher.pl is never
# executed -- AC13 proves this two ways: a self-scan of this file's own source
# (the literal spec ask), plus a PATH tripwire (below) that is the stronger
# check the ledger asked for.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Config ();
use Encode qw(encode_utf8);

# Config::perlpath, never $^X: $^X on this host is the bare string "perl", a
# PATH-relative name -- useless once AC13's tripwire empties $ENV{PATH} below.
# Config::perlpath is resolved once, statically, from perl's own build data,
# with no PATH lookup involved at all.
my $PERL_BIN = $Config::Config{perlpath};

my $SKILLS_PL = "$Bin/../../scripts/skills.pl";
my $LAUNCHER  = "$Bin/../../scripts/launcher.pl";
ok(-f $SKILLS_PL, 'skills.pl present') or BAIL_OUT('no skills.pl');

# ---------------------------------------------------------------------------
# A throwaway root. tempdir(CLEANUP => 1) removes it on normal exit AND on a
# die that unwinds through global destruction, so no explicit die-handler is
# needed -- the same discipline host-only-plugin-skills.t already relies on.
# ---------------------------------------------------------------------------
my $root = tempdir(CLEANUP => 1);

# NON-ASCII fixture path (review m5): the real bug's own marketplace root was
# C:/Users/André/.claude/ccpraxis/plugins. Built from a numeric codepoint via
# encode_utf8, never a literal accented character in this file's own source --
# this file carries no `use utf8;`, so a literal multi-byte char here would be
# decoded as two stray Latin-1 bytes instead of one codepoint (the "Ã©"
# corruption pattern). $accent is therefore the raw UTF-8 byte pair, matching
# how the rest of this codebase represents non-ASCII paths.
my $accent = encode_utf8("\x{e9}");
my $home = "$root/Andr${accent}/home";
my $mkt  = "$root/Andr${accent}/marketplace";  # the directory-source marketplace
my $copied_src = "$root/copied-src";   # fixture-copied's files -- never bound

sub write_file {
    my ($path, $body) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+$}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $body;
    close $fh;
}

sub write_json {
    my ($path, $data) = @_;
    write_file($path, JSON::PP->new->canonical(1)->encode($data));
}

sub unlink_if_exists {
    my ($path) = @_;
    unlink $path if -e $path;
}

sub write_skill {
    my ($dir, $plugin, $name, $host_only) = @_;
    my $fm = "---\nname: $name\ndescription: fixture\n"
           . ($host_only ? "host-only: true\n" : "")
           . "---\n\n# $name\n";
    write_file("$dir/$plugin/skills/$name/SKILL.md", $fm);
}

sub write_plugin_manifest {
    my ($dir, $plugin) = @_;
    write_file("$dir/$plugin/.claude-plugin/plugin.json",
               qq({\n  "name": "$plugin",\n  "version": "0.1.0"\n}\n));
}

# ── fixture-local: the four plugins the spec's fixture table names ────────
write_plugin_manifest($mkt, $_) for qw(allhost mixed safe noskills);
write_skill($mkt, 'allhost', 'alpha',  1);
write_skill($mkt, 'allhost', 'beta',   1);
write_skill($mkt, 'mixed',   'keeper', 0);
write_skill($mkt, 'mixed',   'gone-a', 1);
write_skill($mkt, 'mixed',   'gone-b', 1);
write_skill($mkt, 'safe',    'one',    0);
make_path("$mkt/noskills/hooks");

write_json("$mkt/.claude-plugin/marketplace.json", {
    name    => 'fixture-local',
    plugins => [
        { name => 'allhost',  source => './allhost'  },
        { name => 'mixed',    source => './mixed'    },
        { name => 'safe',     source => './safe'     },
        { name => 'noskills', source => './noskills' },
    ],
});

# ── fixture-copied: a NON-directory marketplace. Its plugin ships a real
# host-only skill on disk, but under a path the launcher never binds live --
# AC6/Observable-7 proves resolution bails before ever reaching this tree. ──
write_plugin_manifest($copied_src, 'copied');
write_skill($copied_src, 'copied', 'secret', 1);
write_json("$copied_src/.claude-plugin/marketplace.json", {
    name    => 'fixture-copied',
    plugins => [ { name => 'copied', source => './copied' } ],
});

write_json("$home/.claude/plugins/known_marketplaces.json", {
    'fixture-local'  => { source => { source => 'directory', path => $mkt } },
    'fixture-copied' => { source => { source => 'github', repo => 'fixture-org/fixture-copied' } },
});

# installed_plugins.json deliberately carries NO record for allhost@fixture-local
# (spec fixture note) -- resolution must never need one (spec Observable 6).
write_json("$home/.claude/plugins/installed_plugins.json", {
    plugins => {
        'mixed@fixture-local' => [ { scope => 'user', version => '0.1.0',
                                      installPath => "$root/dead-cache/mixed/0.1.0" } ],
    },
});

my $project = "$root/project";
make_path($project);

my $PROJ_SETTINGS = "$project/.claude/settings.json";
my $PROJ_LOCAL    = "$project/.claude/settings.local.json";
my $USER_SETTINGS = "$root/user-settings.json";   # stands for claude-home/settings.json
my $SEED_SETTINGS = "$root/seed-settings.json";   # stands for $CONTAINER_SETTINGS_JSON
my $SEL_FILE      = "$root/selection.json";
my $MISSING_SEL   = "$root/no-such-selection.json";

sub write_selection {
    my ($keys) = @_;
    write_json($SEL_FILE, {
        schema_version            => 1,
        selected                  => [],
        selected_plugins          => $keys,
        mounted_at_create         => [],
        mounted_plugins_at_create => [],
    });
}

sub write_enabled {
    my ($path, $enabled) = @_;
    write_json($path, { enabledPlugins => $enabled });
}

sub reset_layers {
    unlink_if_exists($_) for ($PROJ_SETTINGS, $PROJ_LOCAL, $USER_SETTINGS, $SEED_SETTINGS);
    write_selection([]);
}

# ---------------------------------------------------------------------------
# AC13 hardening (stronger than a self-grep): every subprocess below inherits
# an EMPTY $ENV{PATH}, never the operator's. skills.pl's own subcommand needs
# no external binary, so this changes nothing for a correct implementation --
# but a defect that shells out to a bare "podman" or "launcher.pl" by name
# fails loudly (ENOENT) instead of silently reaching a real container runtime.
# Verified live below, not merely asserted: a bare `podman` lookup under this
# PATH is proven unreachable BEFORE it is trusted as a guard for anything else.
# ---------------------------------------------------------------------------
my $empty_path_dir = tempdir(CLEANUP => 1);   # deliberately empty, nothing on it
{
    local $ENV{PATH} = $empty_path_dir;
    my $rc = system('podman', '--version');
    isnt($rc, 0,
        'AC13 tripwire sanity: a bare "podman" lookup is unreachable under the emptied PATH '
      . 'every host-only-masks invocation below runs under');
}

# Every script this file actually spawns, in call order -- the real check
# AC13(b) below replaces the old tautological ok(1) with (review m3): this
# file's OWN spawn record must never contain anything other than skills.pl,
# in particular never the launcher script that starts a container.
my @SPAWNED_SCRIPTS;

sub run_skills {
    my (@args) = @_;
    local $ENV{HOME}        = $home;
    local $ENV{USERPROFILE} = $home;
    local $ENV{PATH}        = $empty_path_dir;
    push @SPAWNED_SCRIPTS, $SKILLS_PL;
    open my $ph, '-|', $PERL_BIN, $SKILLS_PL, @args or die "spawn skills.pl: $!";
    my $out = do { local $/; <$ph> };
    close $ph;
    my $rc = $? == -1 ? -1 : ($? >> 8);
    return (defined $out ? $out : '', $rc);
}

sub decode_masks {
    my ($raw) = @_;
    my $decoded = eval { JSON::PP->new->decode($raw) };
    return $decoded;
}

sub sorted_paths {
    my ($masks) = @_;
    return [] unless ref $masks eq 'ARRAY';
    my @paths = map { $_->{container_path} } @$masks;
    return [ sort @paths ];
}

my @ALLHOST_MASKS = (
    '/root/.claude/plugins/marketplaces/fixture-local/allhost/skills/alpha',
    '/root/.claude/plugins/marketplaces/fixture-local/allhost/skills/beta',
);

# =============================================================================
# AC1 -- enabled true in project settings.json, not selected -> both masks.
# =============================================================================
reset_layers();
write_enabled($PROJ_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'AC1: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    ok(ref $masks eq 'ARRAY', 'AC1: output decodes as a JSON array') or diag("raw: $raw");
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC1: an all-host-only plugin enabled (true) only in project settings.json, '
      . 'and not selected, produces one mask per skill it ships');
}

# =============================================================================
# AC2 -- same, but enablement lives only in settings.local.json.
# =============================================================================
reset_layers();
write_enabled($PROJ_LOCAL, { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'AC2: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC2: enablement via settings.local.json alone (settings.json absent) produces the same masks');
}

# =============================================================================
# AC3 -- enablement via --user-settings alone, and separately via
# --seed-settings alone. Both stand for a container user-level layer.
# =============================================================================
reset_layers();
write_enabled($USER_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project,
        '--user-settings', $USER_SETTINGS);
    is($rc, 0, 'AC3 (user-settings): host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC3: enablement via --user-settings alone produces the same masks');
}

reset_layers();
write_enabled($SEED_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project,
        '--seed-settings', $SEED_SETTINGS);
    is($rc, 0, 'AC3 (seed-settings): host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC3: enablement via --seed-settings alone produces the same masks');
}

# =============================================================================
# AC4 -- a MIXED plugin enabled that way masks only its host-only skills.
# =============================================================================
reset_layers();
write_enabled($PROJ_SETTINGS, { 'mixed@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'AC4: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks),
        [ '/root/.claude/plugins/marketplaces/fixture-local/mixed/skills/gone-a',
          '/root/.claude/plugins/marketplaces/fixture-local/mixed/skills/gone-b' ],
        'AC4: a mixed plugin enabled via a settings layer masks exactly its host-only skills');
    my $has_keeper = grep { $_ =~ m{/keeper$} } @{ sorted_paths($masks) };
    ok(!$has_keeper, 'AC4: no mask path ends in /keeper -- the container-safe skill is untouched');
}

# =============================================================================
# AC5 -- false/null in every layer, nothing selected -> [].
# =============================================================================
reset_layers();
write_enabled($PROJ_SETTINGS, {
    'allhost@fixture-local' => JSON::PP::false,
    'mixed@fixture-local'   => JSON::PP::false,
});
write_enabled($PROJ_LOCAL, {
    'allhost@fixture-local' => undef,
    'mixed@fixture-local'   => JSON::PP::false,
});
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project,
        '--user-settings', $USER_SETTINGS, '--seed-settings', $SEED_SETTINGS);
    is($rc, 0, 'AC5: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is_deeply($masks, [], 'AC5: false/null in every layer, nothing selected, yields []');
}

# =============================================================================
# AC6 -- safe, noskills and the COPIED plugin, enabled everywhere -> [].
# =============================================================================
reset_layers();
my %enable_harmless = (
    'safe@fixture-local'     => JSON::PP::true,
    'noskills@fixture-local' => JSON::PP::true,
    'copied@fixture-copied'  => JSON::PP::true,
);
write_enabled($PROJ_SETTINGS, \%enable_harmless);
write_enabled($PROJ_LOCAL,    \%enable_harmless);
write_enabled($USER_SETTINGS, \%enable_harmless);
write_enabled($SEED_SETTINGS, \%enable_harmless);
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project,
        '--user-settings', $USER_SETTINGS, '--seed-settings', $SEED_SETTINGS);
    is($rc, 0, 'AC6: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is_deeply($masks, [],
        'AC6: a container-safe-only plugin, a skill-less plugin, and a plugin from a NON-directory '
      . 'marketplace add no masks even when every layer enables all three');
}

# =============================================================================
# AC7 -- selected AND enabled in two layers -> each mask exactly once.
# =============================================================================
reset_layers();
write_selection(['allhost@fixture-local']);
write_enabled($PROJ_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
write_enabled($PROJ_LOCAL,    { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'AC7: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is(scalar(@{ $masks || [] }), 2,
        'AC7: a plugin both selected AND enabled in two layers still produces exactly 2 masks');
    my @paths = sort map { $_->{container_path} } @{ $masks || [] };
    my %seen;
    $seen{$_}++ for @paths;
    my @dupes = grep { $seen{$_} > 1 } keys %seen;
    is(scalar(@dupes), 0, 'AC7: no container_path is duplicated');
}

# =============================================================================
# AC8 -- no --selection-file at all, and a --selection-file naming a
# nonexistent file: both still mask from the settings layers, and the
# nonexistent file is never created as a side effect.
# =============================================================================
reset_layers();
write_enabled($PROJ_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks', '--project-path', $project);
    is($rc, 0, 'AC8 (no --selection-file): host-only-masks still exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC8 (no --selection-file): masks still come from the settings layer');
}
{
    ok(!-e $MISSING_SEL, 'AC8 setup: the nonexistent selection file genuinely does not exist yet');
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $MISSING_SEL, '--project-path', $project);
    is($rc, 0, 'AC8 (nonexistent --selection-file): host-only-masks still exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC8 (nonexistent --selection-file): same masks as AC1');
    ok(!-e $MISSING_SEL, 'AC8: the nonexistent selection file is still not created as a side effect');
}

# =============================================================================
# AC9 -- malformed layers are skipped silently; other layers still count.
# =============================================================================
reset_layers();
write_enabled($PROJ_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
write_file($PROJ_LOCAL, "{ this is not valid json");
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'AC9 (malformed JSON): host-only-masks still exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC9 (malformed JSON): the valid layer still counts, the malformed one is skipped silently');
}

reset_layers();
write_enabled($PROJ_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
write_json($USER_SETTINGS, { enabledPlugins => [ 'allhost@fixture-local' ] });   # array, not object
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project,
        '--user-settings', $USER_SETTINGS);
    is($rc, 0, 'AC9 (enabledPlugins is an array): host-only-masks still exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'AC9 (enabledPlugins is an array): the non-object layer is skipped, the object layer still counts');
}

# =============================================================================
# M3 (review m2) -- a settings file saved with a UTF-8 BOM is still parsed,
# not silently skipped. A Windows editor that adds a BOM to settings.json
# must never bring back the exact under-mask this package closes.
# =============================================================================
reset_layers();
{
    my $bom  = "\xEF\xBB\xBF";
    my $json = JSON::PP->new->canonical(1)->encode({
        enabledPlugins => { 'allhost@fixture-local' => JSON::PP::true },
    });
    write_file($PROJ_SETTINGS, $bom . $json);
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'M3 (UTF-8 BOM): host-only-masks still exits 0');
    my $masks = decode_masks($raw);
    is_deeply(sorted_paths($masks), \@ALLHOST_MASKS,
        'M3 (UTF-8 BOM): a settings.json saved with a leading UTF-8 BOM is still parsed, and its '
      . 'enabled plugin is still masked -- not silently treated as an empty/malformed layer');
}

# =============================================================================
# AC10 -- shape: exactly key/skill/container_path, key names the enabler.
# =============================================================================
reset_layers();
write_enabled($PROJ_SETTINGS, { 'allhost@fixture-local' => JSON::PP::true });
{
    my ($raw, $rc) = run_skills('host-only-masks',
        '--selection-file', $SEL_FILE, '--project-path', $project);
    is($rc, 0, 'AC10: host-only-masks exits 0');
    my $masks = decode_masks($raw);
    is(scalar(@{ $masks || [] }), 2, 'AC10: two elements to check the shape of');
    for my $m (@{ $masks || [] }) {
        my @keys = sort keys %$m;
        is_deeply(\@keys, [ 'container_path', 'key', 'skill' ],
            'AC10: element has exactly the keys key/skill/container_path');
        is($m->{key}, 'allhost@fixture-local',
            'AC10: key equals the enabling plugin key');
    }
}

# =============================================================================
# AC11 -- regression: discover-plugins still drops the all-host-only plugin,
# even though it is now enabled and masked. The picker is untouched (DC3).
# =============================================================================
{
    my ($raw, $rc) = run_skills('discover-plugins', '--project-path', $project);
    is($rc, 0, 'AC11: discover-plugins exits 0');
    my $found = decode_masks($raw);
    ok(ref $found eq 'ARRAY', 'AC11: discover-plugins returned a JSON array') or diag("raw: $raw");
    my %by_key = map { $_->{key} => 1 } @{ $found || [] };
    ok(!exists $by_key{'allhost@fixture-local'},
        'AC11: discover-plugins still drops the all-host-only plugin from the picker '
      . '-- masking it does not change picker discovery');
}

# =============================================================================
# AC12 -- launcher.pl source, read-only, never executed. The gate loses its
# -f $SELECTION_FILE clause, and the call within 1500 chars after the marker
# names both new options plus the container's own settings path. The nesting
# ordering property (mask pushed after the marketplace bind) still holds.
#
# M1 (review, MAJOR) -- the mask-discovery call site itself must fail OPEN:
# a non-zero exit from that step must warn and continue without masks, never
# abort the launch the way run_perl_to_file's die-on-nonzero-exit does.
#
# M2 (review, MAJOR) -- a changed mask set must trigger container recreation.
# Masks only ever reach `podman create`'s argv (review M2), so a plugin newly
# enabled by a settings layer is invisible until the container is rebuilt --
# the exact bug this package closes, recurring one layer up. Checked
# structurally against the launcher's existing @STALE_REASONS recreate-trigger
# mechanism (the same list Containerfile/launcher/skill drift already feed),
# never by starting a container.
#
# m4 (review, minor) -- AC12 must pin WHICH seed expression is passed, not
# merely that some --seed-settings flag is present.
# =============================================================================
SKIP: {
    skip 'launcher.pl not present', 11 unless -f $LAUNCHER;
    open my $fh, '<:raw', $LAUNCHER or skip 'cannot read launcher.pl', 11;
    my $src = do { local $/; <$fh> };
    close $fh;

    ok(index($src, '@PLUGIN_MOUNTS && -f $SELECTION_FILE') == -1,
        'AC12: the mask-pass gate no longer requires -f $SELECTION_FILE');

    my $marker_at = index($src, 'host-only mask discovery');
    cmp_ok($marker_at, '>=', 0, 'AC12: found the host-only mask discovery call site');

    my $window = substr($src, $marker_at, 1500);
    ok(index($window, '--user-settings') >= 0,
        'AC12: --user-settings is passed within 1500 chars of the mask discovery call');
    ok(index($window, '--seed-settings') >= 0,
        'AC12: --seed-settings is passed within 1500 chars of the mask discovery call');
    ok(index($window, '$CLAUDE_DATA/settings.json') >= 0,
        'AC12: the container user settings path is passed within 1500 chars of the mask discovery call');

    my $bind_at = index($src, 'host_path}:${container_path}:ro');
    cmp_ok($bind_at, '>=', 0, 'AC12: found the marketplace bind push');
    cmp_ok($marker_at, '>', $bind_at,
        'AC12: masks are still pushed after the marketplace bind they nest inside');

    # ---- m4 / M1: a wider block that also reaches BEFORE the marker, since
    # both the seed-settings expression (m4) and the callee name (M1's
    # run_perl_to_file, today) sit in the few lines ABOVE the call, not after
    # it -- the marker string is the call's own first argument.
    my $block_start = $marker_at > 250 ? $marker_at - 250 : 0;
    my $mask_block  = substr($src, $block_start, 3000);

    # 2026-11-02: these masks only reach `podman create`, and the create merges
    # the CURRENT preset into the sandbox settings (SandboxSettings), so the
    # seed is the current preset itself; the preset the sandbox was last given
    # ($CONTAINER_SETTINGS_JSON) stays the drift signature's seed.
    like($mask_block, qr{my \$seed_settings = "\$CONTAINER_CONFIG/settings\.json";},
        'm4: the create-time mask seed is the current preset, $CONTAINER_CONFIG/settings.json');
    my ($sig_body) = $src =~ m{sub _host_only_mask_signature \{(.*?)\n\}}s;
    like($sig_body // '', qr{-f \$CONTAINER_SETTINGS_JSON\s*\?\s*\$CONTAINER_SETTINGS_JSON\s*:\s*"\$CONTAINER_CONFIG/settings\.json"},
        'm4: the drift signature still seeds from $CONTAINER_SETTINGS_JSON, falling back to the shipped template');
    ok(index($mask_block, 'run_perl_to_file') == -1,
        'M1: the mask-discovery call site no longer goes through run_perl_to_file '
      . '(which exits the launcher on a non-zero child exit)');
    my $capture_at = index($mask_block, '_capture_out_err');
    ok($capture_at >= 0,
        'M1: the mask-discovery call site uses the fail-soft _capture_out_err helper instead');
    ok($capture_at >= 0 && index($mask_block, '_emit_err', $capture_at) > $capture_at,
        'M1: a warning follows the capture call -- a non-zero exit is reported, never silently swallowed '
      . 'and never left to run_perl_to_file\'s exit(1)');

    # ---- M2: the mask set is part of the recreate trigger, proven against the
    # SAME @STALE_REASONS mechanism the pre-existing Containerfile/launcher/
    # skill-drift checks already feed (launcher.pl "Skill/plugin drift" /
    # "Container-config blueprint drift" blocks). Never executes podman.
    my @stale_reason_pushes = grep { /push\s*\@STALE_REASONS/ } split /\n/, $src;
    cmp_ok(scalar(@stale_reason_pushes), '>', 0,
        'M2 setup: launcher.pl has a @STALE_REASONS recreate-trigger mechanism to extend '
      . '(non-vacuity: this file exists and is not empty)');
    my @mask_aware_pushes = grep { /mask/i } @stale_reason_pushes;
    cmp_ok(scalar(@mask_aware_pushes), '>', 0,
        'M2: at least one @STALE_REASONS push names the host-only mask set, so a plugin newly '
      . 'enabled by any settings layer -- and therefore newly masked -- triggers a recreate prompt '
      . 'instead of silently staying invisible in an already-created container');
}

# =============================================================================
# AC13 -- this file never runs launcher.pl or podman.
#
# (a) The literal spec ask: a self-scan of this file's own source finds no
#     process-spawning call whose command references the launcher script
#     that starts a container.
# (b) The stronger check (review m3 -- the old ok(1) here proved nothing):
#     this file's OWN spawn record, populated by every run_skills() call
#     above, must contain skills.pl and NOTHING else -- in particular never
#     the launcher script that starts a container. Unlike the emptied-PATH
#     tripwire, this is real regardless of PATH or absolute-path spawning.
# =============================================================================
{
    open my $fh, '<:raw', $0 or die "read self: $!";
    my @lines = <$fh>;
    close $fh;
    my @violations = grep {
        /launcher\.pl/ && (/\bsystem\s*\(/ || /\bexec\s*\(/ || /'-\|'/)
    } @lines;
    is(scalar(@violations), 0,
        'AC13(a): no system/exec/open(-|) call in this file references launcher.pl')
        or diag(join('', @violations));
}
{
    cmp_ok(scalar(@SPAWNED_SCRIPTS), '>', 0,
        'AC13(b) setup: at least one subprocess was actually spawned by this file (non-vacuity)');
    my @not_skills = grep { $_ ne $SKILLS_PL } @SPAWNED_SCRIPTS;
    is(scalar(@not_skills), 0,
        'AC13(b): every subprocess this file actually spawned was skills.pl -- never launcher.pl, '
      . 'never podman, never anything else')
        or diag(join(', ', @not_skills));
}

done_testing();
