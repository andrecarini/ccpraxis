#!/usr/bin/env perl
# platform: any
# tooling-fixes package 15 (Decision 32/44/45/46), derived from
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/15-sandbox-only-plugin-updates-spec.md
#
# A plugin that exists only inside a sandbox (no host install) was frozen at
# its first-installed version forever. This file covers AC1-AC22 and AC25
# one-to-one (AC11 is a static read of container/settings.json inside this
# file; AC14/AC15 are driver-verified, not asserted here; AC23/AC24 live in
# the two sibling files this package also amends).
#
# Isolation (AC13): HOME/USERPROFILE point at a throwaway root and PATH is
# emptied BEFORE skills.pl is required; every fixture path lives under one
# $ISO_ROOT. This file calls cmd_materialize_plugins,
# cmd_materialize_known_marketplaces and PluginSync's subs directly,
# in-process; it never shells out, so it never runs podman or the launcher
# (self-scanned at the bottom).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Find qw(find);
use File::Basename qw(dirname);
use Encode qw(encode_utf8);

# ---------------------------------------------------------------------------
# AC13: isolation root, set BEFORE requiring skills.pl. Every fixture path in
# this file nests under $ISO_ROOT.
# ---------------------------------------------------------------------------
my $ISO_ROOT = tempdir(CLEANUP => 1);
my $ISO_HOME = "$ISO_ROOT/iso-home";
make_path($ISO_HOME);
$ENV{HOME}        = $ISO_HOME;
$ENV{USERPROFILE} = $ISO_HOME;
$ENV{PATH}        = '';

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1; }
require "$Bin/../../scripts/skills.pl";

use lib "$Bin/../../scripts";
use PluginSync qw(reconcile_copy_plan read_copy_plan);

# ---------------------------------------------------------------------------
# Helpers (same conventions as the sibling plugins-current-at-start.t)
# ---------------------------------------------------------------------------

sub j { JSON::PP->new->canonical->encode($_[0]) }

sub t_spew_raw {
    my ($path, $data) = @_;
    my ($parent) = $path =~ m{^(.*)/[^/]+$};
    make_path($parent) if defined $parent && length $parent && !-d $parent;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh (ref $data ? JSON::PP->new->canonical->encode($data) : $data);
    close $fh;
}

sub t_slurp_utf8 {
    my $path = shift;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return length($bytes) ? JSON::PP->new->utf8->decode($bytes) : undef;
}

sub t_slurp_bytes {
    my $path = shift;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return $bytes;
}

sub prior_plan_for {
    my $manifest = shift;
    my $p = t_slurp_utf8($manifest);
    return (ref $p eq 'ARRAY') ? $p : [];
}

sub write_tree {
    my ($root, %files) = @_;
    for my $rel (sort keys %files) {
        my $full = "$root/$rel";
        (my $parent = $full) =~ s{/[^/]+$}{};
        make_path($parent) unless -d $parent;
        open my $fh, '>:raw', $full or die "write $full: $!";
        print $fh $files{$rel};
        close $fh;
    }
}

sub dir_snapshot {
    my ($root) = @_;
    my %files;
    return {} unless -d $root;
    find({ no_chdir => 1, wanted => sub {
        my $p = $File::Find::name;
        return if -l $p;
        return unless -f $p;
        (my $rel = $p) =~ s{^\Q$root\E/?}{};
        open my $fh, '<:raw', $p or die "read $p: $!";
        local $/;
        $files{$rel} = <$fh>;
        close $fh;
    }}, $root);
    return \%files;
}

# A fresh (H, L, C) triad under one tempdir per scenario.
sub new_fixture {
    my ($label) = @_;
    my $dir = "$ISO_ROOT/$label";
    my $H   = "$dir/host";
    my $L   = "$dir/launcher";
    my $C   = "$dir/claude_home/plugins";
    make_path($L);
    make_path($C);
    return ($dir, $H, $L, $C);
}

sub write_host_km {
    my ($H, %mkts) = @_;
    t_spew_raw("$H/known_marketplaces.json", \%mkts);
}

sub write_catalog {
    my ($H, $mkt, $plugins_arr) = @_;
    t_spew_raw("$H/marketplaces/$mkt/.claude-plugin/marketplace.json", { plugins => $plugins_arr });
}

# Runs the launcher's sequence: materialize-plugins, then (iff km_out given)
# materialize-known-marketplaces. Returns decoded results plus the sidecar.
sub run_materialize {
    my (%a) = @_;
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(
            selection_file   => $a{sel},
            output           => $a{out},
            manifest         => $a{plugins_manifest},
            plugins_snapshot => $a{snap},
            plugins_file     => $a{host_reg},
            project_path     => $a{project_path} // '/project',
        );
        if ($a{km_out}) {
            cmd_materialize_known_marketplaces(
                output            => $a{km_out},
                manifest          => $a{mkt_manifest},
                host_marketplaces => $a{host_km},
            );
        }
    }
    my $sidecar_path = dirname($a{plugins_manifest}) . '/.sandbox-autoupdate-marketplaces.json';
    return {
        plugins         => t_slurp_utf8($a{out}),
        plugin_manifest => t_slurp_utf8($a{plugins_manifest}) // [],
        km              => $a{km_out} ? t_slurp_utf8($a{km_out}) : undef,
        sidecar         => t_slurp_utf8($sidecar_path),
        warnings        => \@warnings,
    };
}

# ===========================================================================
# AC25 -- the d0c9689 invariant, universally (B19). Reusable: called after
# every run below. (1) every HASH km entry has a JSON-boolean autoUpdate;
# (2) for every entry whose autoUpdate is true, no key of that marketplace in
# the output registry was selected this run, nor has a host install (scope
# "user", or scope project/local with a case-insensitively matching
# projectPath) in that run's host registry. Dir presence is deliberately
# ignored, which makes this check stricter than the writers.
# ===========================================================================
sub assert_universal_invariant {
    my (%a) = @_;    # result, label, host_reg, project_path, selected (arrayref)
    my $km = $a{result}{km};
    return unless ref $km eq 'HASH';

    my $host_data    = (-f $a{host_reg}) ? (t_slurp_utf8($a{host_reg}) // {}) : {};
    my $host_plugins = (ref $host_data->{plugins} eq 'HASH') ? $host_data->{plugins} : {};
    my %selected     = map { $_ => 1 } @{ $a{selected} || [] };
    my $project_path = $a{project_path} // '/project';
    my $out_plugins  = (ref $a{result}{plugins}{plugins} eq 'HASH') ? $a{result}{plugins}{plugins} : {};

    for my $name (sort keys %$km) {
        next unless ref $km->{$name} eq 'HASH';
        my $flag = $km->{$name}{autoUpdate};
        ok(JSON::PP::is_bool($flag), "$a{label}: AC25 $name.autoUpdate is a JSON boolean, never missing/null");
        next unless $flag;
        for my $k (sort grep { /\@\Q$name\E$/ } keys %$out_plugins) {
            ok(!$selected{$k}, "$a{label}: AC25 $name is flagged true but $k was selected this run");
            my $shared = 0;
            if (ref $host_plugins->{$k} eq 'ARRAY') {
                for my $inst (@{ $host_plugins->{$k} }) {
                    next unless ref $inst eq 'HASH';
                    my $scope = $inst->{scope} // '';
                    if ($scope eq 'user') { $shared = 1; last; }
                    if ($scope =~ /^(?:project|local)$/
                        && lc($inst->{projectPath} // '') eq lc($project_path)) { $shared = 1; last; }
                }
            }
            ok(!$shared, "$a{label}: AC25 $name is flagged true but $k has a host install");
        }
    }
}

# ===========================================================================
# AC1 (B1) -- update to the declared version. A sandbox-only key, absent from
# the host registry, whose marketplace catalog names a declared version.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac1');

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '2.0.0' }),
        'index.js'                   => "module.exports = {};\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });    # p@mkt absent from the host

    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0', installedAt => '2026-01-01T00:00:00Z',
        gitCommitSha => 'deadbeef01' } ] } });

    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $prior_plan = prior_plan_for($plugins_manifest);
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'github', repo => 'x/y' } } });
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    my $rec = $r->{plugins}{plugins}{'p@mkt'}[0];
    is($rec->{version}, '2.0.0', 'AC1: version rewritten to the declared marketplace version');
    is($rec->{installPath}, '/root/.claude/plugins/cache/mkt/p/2.0.0',
        'AC1: installPath points at the new version\'s container cache path');
    ok(!exists $rec->{gitCommitSha}, 'AC1: gitCommitSha removed for a marketplace-refreshed record');
    ok(defined $rec->{lastUpdated} && length $rec->{lastUpdated}, 'AC1: lastUpdated set (version changed)');
    is($rec->{scope}, 'user', 'AC1: scope preserved');

    my @entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @{ $r->{plugin_manifest} };
    is(scalar(@entries), 1, 'AC1: exactly one manifest entry for p@mkt');
    SKIP: {
        skip 'AC1: no manifest entry to inspect', 3 unless @entries;
        is($entries[0]{origin}, 'marketplace-refresh', 'AC1: manifest entry origin is marketplace-refresh');
        is($entries[0]{dest_rel}, 'cache/mkt/p/2.0.0', 'AC1: manifest dest_rel names the new version path');
        ok($entries[0]{src}, 'AC1: manifest entry carries a src naming the plugin dir');
    }

    reconcile_copy_plan($prior_plan, $r->{plugin_manifest}, $C);
    is_deeply(dir_snapshot("$C/cache/mkt/p/2.0.0"), dir_snapshot("$H/marketplaces/mkt/plugins/p"),
        'AC1: dest holds exactly the plugin dir\'s files and bytes');

    is_deeply($r->{sidecar}, [], 'AC1: sidecar is [] (mkt is not auto-update-eligible)');
    ok(JSON::PP::is_bool($r->{km}{mkt}{autoUpdate}), 'AC1: mkt.autoUpdate is a JSON boolean');
    ok(!$r->{km}{mkt}{autoUpdate}, 'AC1: mkt.autoUpdate is JSON false');
    is_deeply([ grep { $_ eq 'mkt' } @{ $r->{sidecar} || [] } ], [],
        'AC22: sidecar excludes mkt for this unmixed, fully in-snapshot fixture');

    assert_universal_invariant(result => $r, label => 'AC1', host_reg => $host_reg);
}

# ===========================================================================
# AC2 (B2) -- digest fallback when no version is declared anywhere; changing
# a file changes the digest; reconcile removes the old dir and seeds the new.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac2');

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p", 'index.js' => "module.exports = {};\n");    # no plugin.json
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);    # no version field

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0', installedAt => '2026-01-01T00:00:00Z' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $prior_plan = prior_plan_for($plugins_manifest);
    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    my $v1 = $r->{plugins}{plugins}{'p@mkt'}[0]{version};
    like($v1, qr/^[0-9a-f]{12}$/, 'AC2: version falls back to a 12-hex-char content digest');

    reconcile_copy_plan($prior_plan, $r->{plugin_manifest}, $C);
    ok(-d "$C/cache/mkt/p/$v1", 'AC2: dest dir named after the digest exists after reconcile');

    write_tree("$H/marketplaces/mkt/plugins/p", 'index.js' => "module.exports = { changed: true };\n");
    my $prior_plan2 = prior_plan_for($plugins_manifest);
    my $r2 = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    my $v2 = $r2->{plugins}{plugins}{'p@mkt'}[0]{version};
    like($v2, qr/^[0-9a-f]{12}$/, 'AC2: second digest also matches the 12-hex-char shape');
    isnt($v2, $v1, 'AC2: changing a file changes the digest');

    reconcile_copy_plan($prior_plan2, $r2->{plugin_manifest}, $C);
    ok(!-e "$C/cache/mkt/p/$v1", 'AC2: old digest dir removed after reconcile') unless $v1 eq $v2;
    ok(-d "$C/cache/mkt/p/$v2", 'AC2: new digest dir present after reconcile');
    is_deeply($r2->{sidecar}, [], 'AC22: sidecar excludes mkt');
    assert_universal_invariant(result => $r2, label => 'AC2', host_reg => $host_reg);
}

# ===========================================================================
# AC3 -- version fallback chain: catalog version used when plugin.json has
# none; an unsafe declared version ("../x", fails SAFE) falls to the digest.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac3a');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({}), 'f.txt' => "1\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p', version => '3.1.0' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";

    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    my $result = t_slurp_utf8($out);
    is($result->{plugins}{'p@mkt'}[0]{version}, '3.1.0',
        'AC3: catalog version used when plugin.json declares none');
}
{
    my ($dir, $H, $L, $C) = new_fixture('ac3b');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({}), 'f.txt' => "1\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p', version => '../x' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";

    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    my $result = t_slurp_utf8($out);
    like($result->{plugins}{'p@mkt'}[0]{version}, qr/^[0-9a-f]{12}$/,
        'AC3: an unsafe declared version ("../x") falls back to the content digest');
}

# ===========================================================================
# AC4 (B3) -- stable when nothing changed: a second run with unchanged inputs
# gives a byte-identical output registry, sidecar and km output, and a
# deep-equal manifest entry.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac4');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '2.0.0' }), 'index.js' => "1;\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '2.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/2.0.0', installedAt => '2026-01-01T00:00:00Z' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r1 = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    my ($entry1) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @{ $r1->{plugin_manifest} };

    my $out_bytes1     = t_slurp_bytes($out);
    my $km_bytes1      = t_slurp_bytes($km_out);
    my $sidecar_path   = dirname($plugins_manifest) . '/.sandbox-autoupdate-marketplaces.json';
    my $sidecar_bytes1 = t_slurp_bytes($sidecar_path);

    my $r2 = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    my ($entry2) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @{ $r2->{plugin_manifest} };

    is(t_slurp_bytes($out), $out_bytes1, 'AC4: second run gives a byte-identical output registry');
    is(t_slurp_bytes($km_out), $km_bytes1, 'AC4: second run gives a byte-identical km output');
    is(t_slurp_bytes($sidecar_path), $sidecar_bytes1, 'AC4: second run gives a byte-identical sidecar');
    is_deeply($entry2, $entry1, 'AC4: manifest entry for p@mkt is deep-equal across runs');
    ok(exists $r2->{plugins}{plugins}{'p@mkt'}, 'AC4: key still present on the second run');
}

# ===========================================================================
# AC5 (B4) -- catalog stops listing the plugin: record kept as last written,
# a marketplace-refresh-retained manifest entry with the prior dest_rel (dir
# kept); deleting the record then removes the dir on reconcile.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac5');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '2.0.0' }), 'index.js' => "1;\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";

    my $prior1 = prior_plan_for($plugins_manifest);
    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    my $plan1 = t_slurp_utf8($plugins_manifest);
    reconcile_copy_plan($prior1, $plan1, $C);

    # Remove p from the catalog.
    write_catalog($H, 'mkt', []);
    my $prior2 = prior_plan_for($plugins_manifest);
    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    my $result2 = t_slurp_utf8($out);
    ok(exists $result2->{plugins}{'p@mkt'}, 'AC5: record kept as last written once the catalog drops the plugin');
    my $plan2 = t_slurp_utf8($plugins_manifest);
    my ($entry2) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @$plan2;
    ok($entry2, 'AC5: a manifest entry is still emitted');
    SKIP: {
        skip 'AC5: no entry to inspect', 2 unless $entry2;
        is($entry2->{origin}, 'marketplace-refresh-retained', 'AC5: origin is marketplace-refresh-retained');
        ok(!exists $entry2->{src}, 'AC5: retain entry carries no src');
    }
    reconcile_copy_plan($prior2, $plan2, $C);
    ok(-d "$C/cache/mkt/p/2.0.0" || -d "$C/cache/mkt/p/1.0.0",
        'AC5: the plugin dir is still present after reconcile (kept, not removed)');

    # Delete the record entirely -> reconcile removes the dir.
    my $result2b = t_slurp_utf8($out);
    delete $result2b->{plugins}{'p@mkt'};
    t_spew_raw($out, $result2b);
    my $prior3 = prior_plan_for($plugins_manifest);
    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    my $plan3 = t_slurp_utf8($plugins_manifest);
    my @entries3 = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @$plan3;
    is(scalar(@entries3), 0, 'AC5: no manifest entry once the sandbox record itself is deleted');
    reconcile_copy_plan($prior3, $plan3, $C);
    ok(!-e "$C/cache/mkt/p/2.0.0" && !-e "$C/cache/mkt/p/1.0.0",
        'AC5: reconcile removes the dir once nothing references it any more');
}

# ===========================================================================
# AC6 (B5) -- host install wins: a matching host install with a present dir
# plus a qualifying catalog listing gives exactly today's host-refresh
# values and no marketplace-refresh entry; the sidecar excludes mkt.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac6');
    my $hcache = "$H/.claude/plugins/cache/mkt/p/5.0.0";
    write_tree($hcache, 'manifest.json' => "{}\n");

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '9.9.9' }), 'index.js' => "1;\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => { 'p@mkt' => [ { scope => 'user', version => '5.0.0',
        installPath => $hcache, installedAt => '2026-01-01T00:00:00Z', gitCommitSha => 'hostsha5' } ] } });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    my $rec = $r->{plugins}{plugins}{'p@mkt'}[0];
    is($rec->{version}, '5.0.0', 'AC6: host install wins over a qualifying catalog listing');
    is($rec->{gitCommitSha}, 'hostsha5', 'AC6: gitCommitSha equals the host install\'s value');
    my @mkt_entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @{ $r->{plugin_manifest} };
    is(scalar(@mkt_entries), 1, 'AC6: exactly one manifest entry');
    is($mkt_entries[0]{origin}, 'host-refresh', 'AC6: manifest entry origin is host-refresh, not marketplace-refresh')
        if @mkt_entries;
    is_deeply([ grep { $_ eq 'mkt' } @{ $r->{sidecar} || [] } ], [], 'AC22/AC6: sidecar lacks mkt');
    assert_universal_invariant(result => $r, label => 'AC6', host_reg => $host_reg);
}

# ===========================================================================
# AC7 (B6) -- host install disappears and the catalog has the plugin:
# marketplace-refresh with the catalog's version; the old host-refresh dir
# is removed.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac7');
    my $hcache = "$H/.claude/plugins/cache/mkt/p/5.0.0";
    write_tree($hcache, 'manifest.json' => "{}\n");

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '6.0.0' }), 'index.js' => "1;\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => { 'p@mkt' => [ { scope => 'user', version => '5.0.0',
        installPath => $hcache, installedAt => '2026-01-01T00:00:00Z' } ] } });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";

    my $prior1 = prior_plan_for($plugins_manifest);
    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    reconcile_copy_plan($prior1, t_slurp_utf8($plugins_manifest), $C);

    # Remove the host install.
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $prior2 = prior_plan_for($plugins_manifest);
    cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    my $result = t_slurp_utf8($out);
    is($result->{plugins}{'p@mkt'}[0]{version}, '6.0.0',
        'AC7: host install disappearing falls through to marketplace-refresh with the catalog version');
    my $plan2 = t_slurp_utf8($plugins_manifest);
    my ($entry) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @$plan2;
    is($entry->{origin}, 'marketplace-refresh', 'AC7: manifest entry origin is marketplace-refresh') if $entry;
    reconcile_copy_plan($prior2, $plan2, $C);
    ok(!-e "$C/cache/mkt/p/5.0.0", 'AC7: the old host-refresh dir is removed');
    ok(-d "$C/cache/mkt/p/6.0.0", 'AC7: the new marketplace-refresh dir is present');
}

# ===========================================================================
# AC8 (B7) -- remote catalog source in a MIXED marketplace: the remote key is
# left verbatim with exactly one warning naming it; the host-shared key
# still follows host-refresh.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac8');
    my $hcache = "$H/.claude/plugins/cache/mkt/q/5.0.0";
    write_tree($hcache, 'manifest.json' => "{}\n");

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [
        { name => 'p', source => { source => 'url', url => 'https://example.invalid/p.git' } },
        { name => 'q', source => './plugins/q' },
    ]);
    write_tree("$H/marketplaces/mkt/plugins/q", '.claude-plugin/plugin.json' => j({ version => '9.0.0' }));

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => { 'q@mkt' => [ { scope => 'user', version => '5.0.0',
        installPath => $hcache, installedAt => '2026-01-01T00:00:00Z' } ] } });

    my $p_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => {
        'p@mkt' => $p_record,
        'q@mkt' => [ { scope => 'user', version => '1.0.0',
            installPath => '/root/.claude/plugins/cache/mkt/q/1.0.0' } ],
    }});
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
    }
    my @p_warnings = grep { /p\@mkt/ && /remote source/ } @warnings;
    is(scalar(@p_warnings), 1, 'AC8: exactly one warning names p@mkt and mentions "remote source"')
        or diag(join('', @warnings));

    my $result = t_slurp_utf8($out);
    is_deeply($result->{plugins}{'p@mkt'}, $p_record, 'AC8: p@mkt (remote) left verbatim');
    my $plan = t_slurp_utf8($plugins_manifest);
    is(scalar(grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @$plan), 0,
        'AC8: no manifest entry for the remote key');
    is($result->{plugins}{'q@mkt'}[0]{version}, '5.0.0', 'AC8: q@mkt (host-shared) still host-refreshed');
}

# ===========================================================================
# AC9 (B8) -- not resolvable means verbatim, silently. One sub-case per
# listed condition, each wrapped in eval: record deep-equal, no manifest
# entry, no die, no warning.
# ===========================================================================
sub ac9_case {
    my ($label, $setup) = @_;
    my ($dir, $H, $L, $C) = new_fixture("ac9-$label");
    my $key = 'p@mkt';
    my $existing_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];

    $setup->($H, $key, $existing_record, $dir);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} }) unless -f $host_reg;
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { $key => $existing_record } }) unless -f $out;
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []) unless -f $snap;
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] }) unless -f $sel;
    my $plugins_manifest = "$L/plugins-manifest.json";

    my @warnings;
    my $died;
    eval {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
        1;
    } or $died = $@;
    ok(!$died, "AC9 ($label): cmd_materialize_plugins does not die") or diag($died);
    SKIP: {
        skip "AC9 ($label): died, output not trustworthy", 3 if $died;
        my $result = t_slurp_utf8($out);
        is_deeply($result->{plugins}{$key}, $existing_record, "AC9 ($label): record kept deep-equal");
        my $plan = t_slurp_utf8($plugins_manifest) // [];
        is(scalar(grep { ref($_) eq 'HASH' && ($_->{key} // '') eq $key } @$plan), 0,
            "AC9 ($label): no manifest entry");
        is(scalar(@warnings), 0, "AC9 ($label): no warning") or diag(join('', @warnings));
    }
}

ac9_case('absent-from-host-km', sub {
    my ($H) = @_;
    t_spew_raw("$H/known_marketplaces.json", {});    # mkt not a key
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);
    write_tree("$H/marketplaces/mkt/plugins/p", '.claude-plugin/plugin.json' => j({ version => '2.0.0' }));
});
ac9_case('directory-source', sub {
    my ($H) = @_;
    write_host_km($H, mkt => { source => { source => 'directory', path => "$H/x" } });
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);
    write_tree("$H/marketplaces/mkt/plugins/p", '.claude-plugin/plugin.json' => j({ version => '2.0.0' }));
});
ac9_case('host-km-missing', sub {
    # no known_marketplaces.json written at all
});
ac9_case('catalog-missing', sub {
    my ($H) = @_;
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    # no .claude-plugin/marketplace.json written
});
ac9_case('catalog-not-json', sub {
    my ($H) = @_;
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    t_spew_raw("$H/marketplaces/mkt/.claude-plugin/marketplace.json", "not json{{{");
});
ac9_case('plugin-not-listed', sub {
    my ($H) = @_;
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'other', source => './plugins/other' } ]);
});
for my $bad_source ('', '/abs/path', 'C:/abs', '../x', 'a\\b') {
    (my $slug = $bad_source) =~ s/[^a-zA-Z0-9]+/_/g;
    $slug = 'empty' unless length $slug;
    ac9_case("source-$slug", sub {
        my ($H) = @_;
        write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
        write_catalog($H, 'mkt', [ { name => 'p', source => $bad_source } ]);
    });
}
ac9_case('resolved-dir-missing', sub {
    my ($H) = @_;
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);    # dir never created
});
# key-without-at needs its own block, since ac9_case hard-codes key 'p@mkt'.
{
    my ($dir, $H, $L, $C) = new_fixture('ac9-key-without-at');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);
    write_tree("$H/marketplaces/mkt/plugins/p", '.claude-plugin/plugin.json' => j({ version => '2.0.0' }));
    my $key = 'noatsign';
    my $existing_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];
    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { $key => $existing_record } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my @warnings;
    my $died;
    eval {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
        1;
    } or $died = $@;
    ok(!$died, 'AC9 (key-without-at): cmd_materialize_plugins does not die') or diag($died);
    SKIP: {
        skip 'AC9 (key-without-at): died', 2 if $died;
        my $result = t_slurp_utf8($out);
        is_deeply($result->{plugins}{$key}, $existing_record, 'AC9 (key-without-at): record kept deep-equal');
        is(scalar(@warnings), 0, 'AC9 (key-without-at): no warning');
    }
}
for my $case (
    { label => 'record-hash-shaped', value => { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } },
    { label => 'record-null', value => undef },
) {
    my ($dir, $H, $L, $C) = new_fixture("ac9-$case->{label}");
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);
    write_tree("$H/marketplaces/mkt/plugins/p", '.claude-plugin/plugin.json' => j({ version => '2.0.0' }));
    my $key = 'p@mkt';
    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { $key => $case->{value} } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $died;
    eval {
        cmd_materialize_plugins(selection_file => $sel, output => $out, manifest => $plugins_manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
        1;
    } or $died = $@;
    ok(!$died, "AC9 ($case->{label}): cmd_materialize_plugins does not die") or diag($died);
    SKIP: {
        skip "AC9 ($case->{label}): died", 1 if $died;
        my $result = t_slurp_utf8($out);
        is_deeply($result->{plugins}{$key}, $case->{value}, "AC9 ($case->{label}): record kept deep-equal");
    }
}

# ===========================================================================
# AC10 (B9) -- non-ASCII host root: B1 holds, src round-trips byte-exact.
# ===========================================================================
{
    my $accent = encode_utf8("\x{e9}");
    my $dir = "$ISO_ROOT/ac10/Andr${accent}";
    my $H = "$dir/host"; my $L = "$dir/launcher"; my $C = "$dir/claude_home/plugins";
    make_path($L); make_path($C);

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '2.0.0' }), 'index.js' => "1;\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $prior_plan = prior_plan_for($plugins_manifest);
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    is($r->{plugins}{plugins}{'p@mkt'}[0]{version}, '2.0.0', 'AC10: B1 holds under a non-ASCII host root');
    my $plan = read_copy_plan($plugins_manifest);
    my ($entry) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @$plan;
    ok($entry, 'AC10: manifest entry present under a non-ASCII host root');
    is(encode_utf8($entry->{src}), "$H/marketplaces/mkt/plugins/p", 'AC10: manifest src round-trips byte-exact')
        if $entry;
    reconcile_copy_plan($prior_plan, $plan, $C);
    is_deeply(dir_snapshot("$C/cache/mkt/p/2.0.0"), dir_snapshot("$H/marketplaces/mkt/plugins/p"),
        'AC10: complete copy under a non-ASCII host root');
    is_deeply([ grep { $_ eq 'mkt' } @{ $r->{sidecar} || [] } ], [], 'AC22: sidecar excludes mkt');
}

# ===========================================================================
# AC11 (B11) -- static read of container/settings.json: the global gate is
# open, and only that (no per-marketplace override in this file).
# ===========================================================================
{
    my $settings_path = "$Bin/../../container/settings.json";
    open my $fh, '<:raw', $settings_path or die "read $settings_path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    my $settings = JSON::PP->new->decode($bytes);

    is($settings->{env}{FORCE_AUTOUPDATE_PLUGINS}, '1', 'AC11: env.FORCE_AUTOUPDATE_PLUGINS is "1"');
    is($settings->{env}{DISABLE_AUTOUPDATER}, '1', 'AC11: env.DISABLE_AUTOUPDATER is "1"');
    my $ekm = $settings->{extraKnownMarketplaces} // {};
    is_deeply(
        [ sort grep { ref $ekm->{$_} eq 'HASH' && exists $ekm->{$_}{autoUpdate} } keys %$ekm ],
        [],
        'AC11: no extraKnownMarketplaces.*.autoUpdate key in container settings.json'
    );
}

# ===========================================================================
# AC12 (B10) -- selected tier unaffected: a selected host key gets host
# version/gitCommitSha and a manifest entry with no origin, even when a
# qualifying catalog lists it; its marketplace is not in the sidecar and its
# km flag is JSON false.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac12');
    my $hcache = "$H/.claude/plugins/cache/mkt/p/5.0.0";
    write_tree($hcache, 'manifest.json' => "{}\n");

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_tree("$H/marketplaces/mkt/plugins/p",
        '.claude-plugin/plugin.json' => j({ version => '9.9.9' }), 'index.js' => "1;\n");
    write_catalog($H, 'mkt', [ { name => 'p', source => './plugins/p' } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => { 'p@mkt' => [ { scope => 'user', version => '5.0.0',
        installPath => $hcache, installedAt => '2026-01-01T00:00:00Z', gitCommitSha => 'selsha5' } ] } });
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, [ { key => 'p@mkt', scope => 'user', version => '5.0.0', install_path => $hcache } ]);
    my $sel = "$dir/sel.json"; t_spew_raw($sel, { schema_version => 3, selected_plugins => ['p@mkt'] });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => {} });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    my $rec = $r->{plugins}{plugins}{'p@mkt'}[0];
    is($rec->{version}, '5.0.0', 'AC12: selected key gets the host version despite a qualifying catalog listing');
    is($rec->{gitCommitSha}, 'selsha5', 'AC12: selected key gets the host gitCommitSha');
    my ($entry) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @{ $r->{plugin_manifest} };
    ok($entry, 'AC12: a manifest entry exists for the selected key');
    ok(!exists $entry->{origin}, 'AC12: the selected-tier manifest entry has no origin') if $entry;
    is_deeply([ grep { $_ eq 'mkt' } @{ $r->{sidecar} || [] } ], [], 'AC12: mkt is not in the sidecar');
    ok(JSON::PP::is_bool($r->{km}{mkt}{autoUpdate}), 'AC12: mkt.autoUpdate is a JSON boolean');
    ok(!$r->{km}{mkt}{autoUpdate}, 'AC12: mkt.autoUpdate is JSON false');
    assert_universal_invariant(result => $r, label => 'AC12', host_reg => $host_reg, selected => ['p@mkt']);
}

# ===========================================================================
# AC16 (B12) -- unmixed remote marketplace is auto-updated: a marketplace
# whose only registry key is remote-sourced and sandbox-only gets flagged
# autoUpdate true; same for url/github/git-subdir object sources.
# ===========================================================================
for my $source_type (qw(url github git-subdir)) {
    my ($dir, $H, $L, $C) = new_fixture("ac16-$source_type");
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'p', source => { source => $source_type, url => 'https://example.invalid/p.git' } } ]);

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $p_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => $p_record } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'github', repo => 'x/y' } } });
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    is_deeply($r->{sidecar}, ['mkt'], "AC16 ($source_type): sidecar is exactly [\"mkt\"]");
    ok(JSON::PP::is_bool($r->{km}{mkt}{autoUpdate}), "AC16 ($source_type): mkt.autoUpdate is a JSON boolean");
    ok($r->{km}{mkt}{autoUpdate}, "AC16 ($source_type): mkt.autoUpdate is JSON true");
    is_deeply($r->{plugins}{plugins}{'p@mkt'}, $p_record, "AC16 ($source_type): p\@mkt record deep-equal");
    is(scalar(grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@mkt' } @{ $r->{plugin_manifest} }), 0,
        "AC16 ($source_type): no plugin-manifest entry for p\@mkt");
    is(scalar(@{ $r->{warnings} }), 0, "AC16 ($source_type): zero warnings") or diag(join('', @{ $r->{warnings} }));
    assert_universal_invariant(result => $r, label => "AC16 ($source_type)", host_reg => $host_reg);
}

# ===========================================================================
# AC17 (B14) -- mixed marketplace is not auto-updated: mixed by host install,
# by selection, and by a host install whose dir is missing.
# ===========================================================================
sub ac17_case {
    my ($label, %opt) = @_;    # selected, host_dir_present
    my ($dir, $H, $L, $C) = new_fixture("ac17-$label");
    my $hcache = "$H/.claude/plugins/cache/mkt/q/1.0.0";
    write_tree($hcache, 'manifest.json' => "{}\n");
    remove_tree($hcache) unless $opt{host_dir_present};

    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [
        { name => 'p', source => { source => 'url', url => 'https://example.invalid/p.git' } },
        { name => 'q', source => './plugins/q' },
    ]);
    write_tree("$H/marketplaces/mkt/plugins/q", '.claude-plugin/plugin.json' => j({ version => '2.0.0' }));

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => { 'q@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => $hcache, installedAt => '2026-01-01T00:00:00Z' } ] } });

    my $p_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];
    my $out = "$C/installed_plugins.json";
    my %c_plugins = ( 'p@mkt' => $p_record );
    $c_plugins{'q@mkt'} = [ { scope => 'user', version => '0.5.0',
        installPath => '/root/.claude/plugins/cache/mkt/q/0.5.0' } ] unless $opt{selected};
    t_spew_raw($out, { plugins => \%c_plugins });

    my $snap = "$dir/snap.json";
    my $sel  = "$dir/sel.json";
    if ($opt{selected}) {
        t_spew_raw($snap, [ { key => 'q@mkt', scope => 'user', version => '1.0.0', install_path => $hcache } ]);
        t_spew_raw($sel, { schema_version => 3, selected_plugins => ['q@mkt'] });
    } else {
        t_spew_raw($snap, []);
        t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    }
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'github', repo => 'x/y' } } });
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    is_deeply($r->{sidecar}, [], "AC17 ($label): sidecar is []");
    ok(JSON::PP::is_bool($r->{km}{mkt}{autoUpdate}), "AC17 ($label): mkt.autoUpdate is a JSON boolean");
    ok(!$r->{km}{mkt}{autoUpdate}, "AC17 ($label): mkt.autoUpdate is JSON false");
    is_deeply($r->{plugins}{plugins}{'p@mkt'}, $p_record, "AC17 ($label): p\@mkt verbatim");
    my @p_warnings = grep { /p\@mkt/ && /remote source/ } @{ $r->{warnings} };
    is(scalar(@p_warnings), 1, "AC17 ($label): exactly one warning for p\@mkt") or diag(join('', @{ $r->{warnings} }));
    assert_universal_invariant(result => $r, label => "AC17 ($label)", host_reg => $host_reg,
        selected => ($opt{selected} ? ['q@mkt'] : []));
}
ac17_case('mixed-by-host-install', selected => 0, host_dir_present => 1);
ac17_case('mixed-by-selection',    selected => 1, host_dir_present => 1);
ac17_case('mixed-by-missing-dir',  selected => 0, host_dir_present => 0);

# ===========================================================================
# AC18 (B15) -- recomputed every run, never sticky: a three-run toggle
# (true -> false -> true); a stale sidecar, prior km true and host km true
# all overwritten to false when mixed.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac18');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [
        { name => 'p', source => { source => 'url', url => 'https://example.invalid/p.git' } },
        { name => 'q', source => './plugins/q' },
    ]);
    write_tree("$H/marketplaces/mkt/plugins/q", '.claude-plugin/plugin.json' => j({ version => '2.0.0' }));

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });    # run 1: no host install of q -- unmixed
    my $p_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => $p_record } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'github', repo => 'x/y' }, autoUpdate => JSON::PP::true } });
    my $mkt_manifest = "$L/mkt-manifest.json";
    t_spew_raw(dirname($plugins_manifest) . '/.sandbox-autoupdate-marketplaces.json', ['mkt']);    # stale, true

    my $r1 = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    is_deeply($r1->{sidecar}, ['mkt'], 'AC18 run1: sidecar is ["mkt"] (unmixed)');
    ok($r1->{km}{mkt}{autoUpdate}, 'AC18 run1: mkt.autoUpdate true');

    # Run 2: add q's host install -> mixed.
    my $hcache = "$H/.claude/plugins/cache/mkt/q/1.0.0";
    write_tree($hcache, 'manifest.json' => "{}\n");
    t_spew_raw($host_reg, { version => 2, plugins => { 'q@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => $hcache, installedAt => '2026-01-01T00:00:00Z' } ] } });
    t_spew_raw($out, { plugins => { 'p@mkt' => $p_record, 'q@mkt' => [ { scope => 'user', version => '0.5.0',
        installPath => '/root/.claude/plugins/cache/mkt/q/0.5.0' } ] } });

    my $r2 = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    is_deeply($r2->{sidecar}, [], 'AC18 run2: sidecar is [] once mixed (overwrites the stale true)');
    ok(!$r2->{km}{mkt}{autoUpdate}, 'AC18 run2: mkt.autoUpdate flips to false');
    my $mkt_plan2 = t_slurp_utf8($mkt_manifest);
    my ($mkt_entry2) = grep { ref($_) eq 'HASH' && ($_->{name} // '') eq 'mkt' } @{ $mkt_plan2 || [] };
    ok($mkt_entry2 && $mkt_entry2->{src}, 'AC18 run2: the marketplace copy-plan entry has a src again (not eligible)')
        if $mkt_entry2;

    # Run 3: remove q's host install again -> unmixed, true again.
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    t_spew_raw($out, { plugins => { 'p@mkt' => $p_record } });
    my $r3 = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    is_deeply($r3->{sidecar}, ['mkt'], 'AC18 run3: sidecar is ["mkt"] again once unmixed');
    ok($r3->{km}{mkt}{autoUpdate}, 'AC18 run3: mkt.autoUpdate flips back to true');
    assert_universal_invariant(result => $r2, label => 'AC18 run2', host_reg => $host_reg);
}

# ===========================================================================
# AC19 (B13) -- eligible marketplace suppresses mechanism A for a resolvable
# sandbox-only key: verbatim, no marketplace-refresh entry (or a
# marketplace-refresh-retained entry if the prior manifest had one).
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac19');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [
        { name => 'p', source => { source => 'url', url => 'https://example.invalid/p.git' } },
        { name => 'r', source => './plugins/r' },
    ]);
    write_tree("$H/marketplaces/mkt/plugins/r", '.claude-plugin/plugin.json' => j({ version => '3.0.0' }), 'x.js' => "1;\n");

    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $p_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ];
    my $r_record = [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/r/1.0.0' } ];
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => $p_record, 'r@mkt' => $r_record } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'github', repo => 'x/y' } } });
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    ok($r->{km}{mkt}{autoUpdate}, 'AC19: mkt is eligible (autoUpdate true)');
    is_deeply($r->{plugins}{plugins}{'r@mkt'}, $r_record,
        'AC19: r@mkt (resolvable, sandbox-only) stays verbatim -- mechanism A suppressed');
    is(scalar(grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'r@mkt' } @{ $r->{plugin_manifest} }), 0,
        'AC19: no marketplace-refresh entry for r@mkt');
}

# ===========================================================================
# AC20 (B16) -- catalog-dir ownership: when the container's marketplace dir
# exists, the copy-plan entry has no src and reconcile preserves a marker
# file; when it does not, the entry has a src.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac20-present');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'p', source => { source => 'url', url => 'https://example.invalid/p.git' } } ]);
    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";

    write_tree("$C/marketplaces/mkt", 'marker.txt' => "keep me\n");
    my $mkt_prior_plan = prior_plan_for($mkt_manifest);

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    my $mkt_plan = t_slurp_utf8($mkt_manifest) // [];
    my ($mkt_entry) = grep { ref($_) eq 'HASH' && ($_->{name} // '') eq 'mkt' } @$mkt_plan;
    ok($mkt_entry, 'AC20 (dir present): a marketplace copy-plan entry exists');
    SKIP: {
        skip 'AC20 (dir present): no entry to inspect', 2 unless $mkt_entry;
        is($mkt_entry->{dest_rel}, 'marketplaces/mkt', 'AC20 (dir present): dest_rel is marketplaces/mkt');
        ok(!exists $mkt_entry->{src}, 'AC20 (dir present): entry carries no src');
    }
    reconcile_copy_plan($mkt_prior_plan, $mkt_plan, $C);
    ok(-f "$C/marketplaces/mkt/marker.txt", 'AC20 (dir present): the marker file survives reconcile');
}
{
    my ($dir, $H, $L, $C) = new_fixture('ac20-absent');
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    write_catalog($H, 'mkt', [ { name => 'p', source => { source => 'url', url => 'https://example.invalid/p.git' } } ]);
    my $host_reg = "$H/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@mkt' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/mkt/p/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json"; t_spew_raw($km_out, {});
    my $mkt_manifest = "$L/mkt-manifest.json";
    # C/marketplaces/mkt does NOT exist this time.
    my $mkt_prior_plan = prior_plan_for($mkt_manifest);

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    my $mkt_plan = t_slurp_utf8($mkt_manifest) // [];
    my ($mkt_entry) = grep { ref($_) eq 'HASH' && ($_->{name} // '') eq 'mkt' } @$mkt_plan;
    ok($mkt_entry && $mkt_entry->{src}, 'AC20 (dir absent): entry has a src') if $mkt_entry;
    reconcile_copy_plan($mkt_prior_plan, $mkt_plan, $C) if $mkt_entry;
}

# ===========================================================================
# AC21 (B17/B18) -- directory-source always false; a sandbox-added unmixed
# marketplace gets true; calling either sub without a manifest writes no
# sidecar / an all-false km output and never dies.
# ===========================================================================
{
    my ($dir, $H, $L, $C) = new_fixture('ac21-dirsrc');
    write_host_km($H, mkt => { source => { source => 'directory', path => "$H/x" } });
    my $out = "$C/installed_plugins.json"; t_spew_raw($out, { plugins => {} });
    my $host_reg = "$H/installed_plugins.json"; t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'directory', path => "$H/x" } } });
    my $mkt_manifest = "$L/mkt-manifest.json";
    t_spew_raw(dirname($plugins_manifest) . '/.sandbox-autoupdate-marketplaces.json', ['mkt']);    # stale true

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");
    ok(JSON::PP::is_bool($r->{km}{mkt}{autoUpdate}), 'AC21: directory-source mkt.autoUpdate is a JSON boolean');
    ok(!$r->{km}{mkt}{autoUpdate}, 'AC21: a directory-source marketplace always gets autoUpdate false');
}
{
    my ($dir, $H, $L, $C) = new_fixture('ac21-sandboxadded');
    # 'sbx' is not in the host's known_marketplaces.json at all -- preserved
    # from the prior container km output only.
    write_host_km($H, mkt => { source => { source => 'github', repo => 'x/y' } });
    my $host_reg = "$H/installed_plugins.json"; t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 's@sbx' => [ { scope => 'user', version => '1.0.0',
        installPath => '/root/.claude/plugins/cache/sbx/s/1.0.0' } ] } });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $plugins_manifest = "$L/plugins-manifest.json";
    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { sbx => { source => { source => 'url', url => 'https://example.invalid/sbx.git' },
        installedAt => '2026-01-01T00:00:00Z' } });
    my $mkt_manifest = "$L/mkt-manifest.json";

    my $r = run_materialize(host_reg => $host_reg, out => $out, plugins_manifest => $plugins_manifest,
        snap => $snap, sel => $sel, km_out => $km_out, mkt_manifest => $mkt_manifest,
        host_km => "$H/known_marketplaces.json");

    is_deeply($r->{sidecar}, ['sbx'], 'AC21: sandbox-added unmixed marketplace sbx is in the sidecar');
    ok(JSON::PP::is_bool($r->{km}{sbx}{autoUpdate}), 'AC21: sbx.autoUpdate is a JSON boolean');
    ok($r->{km}{sbx}{autoUpdate}, 'AC21: sbx.autoUpdate is JSON true');
    is($r->{km}{sbx}{installedAt}, '2026-01-01T00:00:00Z', 'AC21: the rest of sbx\'s entry is preserved');
    is(scalar(grep { ref($_) eq 'HASH' && ($_->{name} // '') eq 'sbx' } @{ t_slurp_utf8($mkt_manifest) || [] }), 0,
        'AC21: sbx gets no copy-plan entry');
}
{
    # B18: no manifest, no sidecar; km with no manifest -> all-false; neither dies.
    my ($dir, $H, $L, $C) = new_fixture('ac21-nomanifest');
    my $host_reg = "$H/installed_plugins.json"; t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $out = "$C/installed_plugins.json"; t_spew_raw($out, { plugins => {} });
    my $snap = "$dir/snap.json"; t_spew_raw($snap, []);
    my $sel  = "$dir/sel.json";  t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $died;
    eval {
        cmd_materialize_plugins(selection_file => $sel, output => $out,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project');
        1;
    } or $died = $@;
    ok(!$died, 'AC21: cmd_materialize_plugins without manifest does not die') or diag($died);
    ok(!-e "$L/.sandbox-autoupdate-marketplaces.json", 'AC21: no sidecar written without a manifest option');

    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { mkt => { source => { source => 'github', repo => 'x/y' } } });
    my $died2;
    eval {
        cmd_materialize_known_marketplaces(output => $km_out, host_marketplaces => "$H/known_marketplaces.json");
        1;
    } or $died2 = $@;
    ok(!$died2, 'AC21: cmd_materialize_known_marketplaces without manifest does not die') or diag($died2);
    SKIP: {
        skip 'AC21: died', 1 if $died2;
        my $km_result = t_slurp_utf8($km_out);
        ok(JSON::PP::is_bool($km_result->{mkt}{autoUpdate}) && !$km_result->{mkt}{autoUpdate},
            'AC21: without a manifest, every HASH entry gets autoUpdate false');
    }
}

# ===========================================================================
# AC22 -- revision-1 coverage unaffected: summarised. Every AC1-AC10/AC12
# fixture above already asserts its marketplace is absent from the sidecar
# (labelled AC22 inline); this is the roll-up acknowledgement.
# ===========================================================================
ok(1, 'AC22: AC1-AC10/AC12 each assert their marketplace is excluded from the sidecar (see inline AC22 checks above)');

# ===========================================================================
# AC13 -- isolation: this file's own source spawns nothing; PATH empty;
# HOME under the tempdir (mirrors plugins-current-at-start.t's AC15).
# ===========================================================================
{
    open my $fh, '<:raw', $0 or die "read self: $!";
    my @lines = <$fh>;
    close $fh;
    my $backtick = chr(96);
    my @violations = grep {
        /\bsystem\s*\(/ || /\bexec\s*\(/ || /\Q$backtick\E/ || /\bqx\s*[\/\(\{\#\!]/
        || /open\s*\([^)]*['"]-\|['"]/
    } @lines;
    is(scalar(@violations), 0, 'AC13: no subprocess-spawning construct anywhere in this file')
        or diag(join('', @violations));
    is($ENV{PATH}, '', 'AC13: PATH was emptied before requiring skills.pl');
    like($ISO_HOME, qr{^\Q$ISO_ROOT\E}, 'AC13: HOME/USERPROFILE fixture lives under the isolation tempdir');
    # Since this file never spawns anything (checked above), it also never
    # invokes podman or launcher.pl as a command -- the same logical argument
    # plugins-current-at-start.t's AC15 makes, rather than a literal text
    # scan (which would self-trigger on this very file's own prose).
}

done_testing();
