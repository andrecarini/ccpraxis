#!/usr/bin/env perl
# platform: any
# 06-plugins-current-at-start (sandbox-session-ux, Decision 11). Spec:
# .ccpraxis-local-data/blueprints/sandbox-session-ux/specs/06-plugins-current-at-start-spec.md
#
# Covers AC1-AC17 one-to-one (AC19 is the operator's manual popup check, out
# of scope here; AC18 is a validation-suite-level "existing tests stay green"
# criterion satisfied by running those sibling files directly, not by
# assertions inside this one). Also covers the Decision 24 addendum: a
# source-level check that README.md no longer claims the sandbox never
# touches a plugin installed inside it.
#
# AC17 amended by tooling-fixes package 15 (Decision 46). Spec:
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/15-sandbox-only-plugin-updates-spec.md
# section 2.13.1. FORCE_AUTOUPDATE_PLUGINS returns to the container settings
# (the old AC17 pinned its absence); the new AC17e/f/g pin that no host-shared
# marketplace can ever be flagged autoUpdate true despite the global gate
# being open, and that the check is not vacuous.
#
# Isolation (AC15): HOME/USERPROFILE point at a throwaway root and PATH is
# emptied BEFORE skills.pl is required, and every plugins_file/output/manifest
# path used anywhere below lives under that one root. This file calls
# cmd_materialize_plugins and PluginSync's subs directly, in-process; it never
# shells out, so it never runs podman or launcher.pl (self-scanned at the
# bottom, AC15b).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find qw(find);
use Encode qw(encode_utf8);
use Time::HiRes qw(time);

# ---------------------------------------------------------------------------
# AC15: isolation root, set BEFORE requiring skills.pl. Every fixture path in
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
# Helpers
# ---------------------------------------------------------------------------

# Fixture-input JSON: canonical, no ->utf8 (values may already be raw UTF-8
# bytes, e.g. AC12's accented path -- ->utf8 would double-encode them).
# Written with :raw so the bytes on disk are exactly what encode() produced.
sub t_spew_raw {
    my ($path, $data) = @_;
    my ($parent) = $path =~ m{^(.*)/[^/]+$};
    make_path($parent) if defined $parent && length $parent && !-d $parent;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh (ref $data ? JSON::PP->new->canonical->encode($data) : $data);
    close $fh;
}

# Reading what cmd_materialize_plugins itself wrote: spec section 2.2 says
# its output encoding is ->utf8. Matches PluginSync::read_copy_plan's own
# ->utf8->decode for the manifest.
sub t_slurp_utf8 {
    my $path = shift;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return length($bytes) ? JSON::PP->new->utf8->decode($bytes) : undef;
}

sub prior_plan_for {
    my $manifest = shift;
    my $p = t_slurp_utf8($manifest);
    return (ref $p eq 'ARRAY') ? $p : [];
}

sub write_tree {
    my ($root, %files) = @_;    # rel => bytes
    for my $rel (sort keys %files) {
        my $full = "$root/$rel";
        (my $parent = $full) =~ s{/[^/]+$}{};
        make_path($parent) unless -d $parent;
        open my $fh, '>:raw', $full or die "write $full: $!";
        print $fh $files{$rel};
        close $fh;
    }
}

# Recursive {relative path => bytes} snapshot of a real directory tree,
# regular files only (symlinks excluded, matching copy_tree's own contract).
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

my $J = JSON::PP->new->canonical;

# ===========================================================================
# AC1 / AC2 -- selected feature-dev@claude-plugins-official, host at B,
# sandbox record at A. DC1 requires this exact literal key.
# ===========================================================================
{
    my $dir       = "$ISO_ROOT/ac1";
    my $host_dir  = "$dir/host";
    my $hcache    = "$host_dir/.claude/plugins/cache/claude-plugins-official/feature-dev/bbbbbbbbbbbb";
    my $home_dir  = "$dir/claude_home";
    my $dest_root = "$home_dir/plugins";

    write_tree($hcache,
        'plugin.json'    => "{\"name\":\"feature-dev\"}\n",
        'lib/util.js'    => "module.exports = {};\n",
        '.envrc'         => "export FIXTURE=1\n",
    );

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'feature-dev@claude-plugins-official' => [ {
            scope => 'user', version => 'bbbbbbbbbbbb', installPath => $hcache,
            installedAt => '2026-01-01T00:00:00Z', lastUpdated => '2026-02-01T00:00:00Z',
            gitCommitSha => 'bbb111',
        } ],
    }});

    my $snap = "$dir/snap.json";
    t_spew_raw($snap, [ { key => 'feature-dev@claude-plugins-official', scope => 'user',
        version => 'bbbbbbbbbbbb', install_path => $hcache } ]);

    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => ['feature-dev@claude-plugins-official'] });

    my $out = "$home_dir/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => {
        'feature-dev@claude-plugins-official' => [ {
            scope => 'user', version => 'aaaaaaaaaaaa',
            installPath => '/root/.claude/plugins/cache/claude-plugins-official/feature-dev/aaaaaaaaaaaa',
            installedAt => '2025-01-01T00:00:00Z', gitCommitSha => 'aaa000',
        } ],
    }});

    my $manifest = "$dir/manifest.json";
    my $prior    = prior_plan_for($manifest);    # []: nothing placed before

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    my $rec = $result->{plugins}{'feature-dev@claude-plugins-official'}[0];
    is($rec->{version}, 'bbbbbbbbbbbb', 'AC1: selected feature-dev record version rewritten to host B');
    is($rec->{installPath}, '/root/.claude/plugins/cache/claude-plugins-official/feature-dev/bbbbbbbbbbbb',
        'AC1: installPath rewritten to the container cache path for B');
    is($rec->{gitCommitSha}, 'bbb111', 'AC1: gitCommitSha equals the chosen host B install\'s value');

    # AC2: full launcher sequence -- prior plan read (above, []), materialize
    # (above), reconcile with the new plan just written.
    my $new_plan = t_slurp_utf8($manifest);
    make_path($dest_root);
    my $orphan_dir = "$dest_root/cache/claude-plugins-official/feature-dev/bbbbbbbbbbbb";
    make_path($orphan_dir);
    write_tree($dest_root, 'cache/claude-plugins-official/feature-dev/bbbbbbbbbbbb/.orphaned_at' => '1790368006758');

    reconcile_copy_plan($prior, $new_plan, $dest_root);

    my $got  = dir_snapshot($orphan_dir);
    my $want = dir_snapshot($hcache);
    is_deeply($got, $want, 'AC2: claude-home cache dir B is byte-and-file-set complete against the host B dir');
    ok(!-e "$orphan_dir/.orphaned_at", 'AC2: a pre-seeded .orphaned_at marker absent from the host is gone after reconcile');
}

# ===========================================================================
# AC3 -- sandbox-only key: absent from the host registry entirely. Preserved
# verbatim, no manifest entry, its cache dir untouched.
# ===========================================================================
{
    my $dir       = "$ISO_ROOT/ac3";
    my $home_dir  = "$dir/claude_home";
    my $dest_root = "$home_dir/plugins";

    my $host_reg = "$dir/host/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $existing_record = [ { scope => 'user', version => '9.9.9',
        installPath => '/root/.claude/plugins/cache/fixture-mkt/sandbox-only/9.9.9', installedAt => '2026-01-01' } ];
    my $out = "$dest_root/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'sandbox-only@fixture-mkt' => $existing_record } });

    my $sentinel_rel = 'cache/fixture-mkt/sandbox-only/9.9.9/sentinel.txt';
    write_tree($dest_root, $sentinel_rel => "sandbox-only content\n");

    my $manifest = "$dir/manifest.json";
    my $prior    = prior_plan_for($manifest);

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    is_deeply($result->{plugins}{'sandbox-only@fixture-mkt'}, $existing_record,
        'AC3: sandbox-only record kept deep-equal, untouched by materialize');
    my $plan = t_slurp_utf8($manifest);
    my @entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'sandbox-only@fixture-mkt' } @$plan;
    is(scalar(@entries), 0, 'AC3: no manifest entry for the sandbox-only key');

    reconcile_copy_plan($prior, $plan, $dest_root);
    my $sentinel_path = "$dest_root/$sentinel_rel";
    ok(-f $sentinel_path, 'AC3: sentinel file still present after reconcile');
    open my $fh, '<:raw', $sentinel_path or die $!;
    local $/; my $body = <$fh>; close $fh;
    is($body, "sandbox-only content\n", 'AC3: sentinel file bytes unchanged after reconcile');
}

# ===========================================================================
# AC4 -- sandbox-newer (Decision 14, host wins): selected key at host B, but
# the sandbox already holds an in-container-updated C. C is left untouched;
# the record still moves to B; versions are never compared.
# ===========================================================================
{
    my $dir       = "$ISO_ROOT/ac4";
    my $host_dir  = "$dir/host";
    my $hcache    = "$host_dir/.claude/plugins/cache/fixture-mkt/sandbox-newer/bbbbbbbbbbbb";
    my $home_dir  = "$dir/claude_home";
    my $dest_root = "$home_dir/plugins";

    write_tree($hcache, 'manifest.json' => "{}\n", 'src/a.js' => "1;\n");

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'sandbox-newer@fixture-mkt' => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01', gitCommitSha => 'bbb222' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, [ { key => 'sandbox-newer@fixture-mkt', scope => 'user',
        version => 'bbbbbbbbbbbb', install_path => $hcache } ]);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => ['sandbox-newer@fixture-mkt'] });

    my $c_rel = 'cache/fixture-mkt/sandbox-newer/cccccccccccc';
    write_tree($dest_root, "$c_rel/sentinel.txt" => "in-container update\n");

    my $out = "$dest_root/installed_plugins.json";
    t_spew_raw($out, { plugins => {
        'sandbox-newer@fixture-mkt' => [ { scope => 'user', version => 'cccccccccccc',
            installPath => '/root/.claude/plugins/cache/fixture-mkt/sandbox-newer/cccccccccccc',
            installedAt => '2026-01-05' } ],
    }});

    my $manifest = "$dir/manifest.json";
    my $prior    = prior_plan_for($manifest);    # [] -- C was never placed by the launcher

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    is($result->{plugins}{'sandbox-newer@fixture-mkt'}[0]{version}, 'bbbbbbbbbbbb',
        'AC4: record moves to the host version B, never compared against sandbox C');

    my $plan = t_slurp_utf8($manifest);
    reconcile_copy_plan($prior, $plan, $dest_root);

    is_deeply(dir_snapshot("$dest_root/cache/fixture-mkt/sandbox-newer/bbbbbbbbbbbb"), dir_snapshot($hcache),
        'AC4: dir B is complete after reconcile');
    ok(-f "$dest_root/$c_rel/sentinel.txt", 'AC4: sandbox-newer dir C is still present');
    open my $fh, '<:raw', "$dest_root/$c_rel/sentinel.txt" or die $!;
    local $/; my $body = <$fh>; close $fh;
    is($body, "in-container update\n", 'AC4: dir C sentinel bytes unchanged -- never modified');
}

# ===========================================================================
# AC5 / AC6 / AC7 -- preserved-and-refreshable key: host-refresh, stability
# across a second run, and retain-then-remove across a third and fourth.
# ===========================================================================
{
    my $dir       = "$ISO_ROOT/ac567";
    my $host_dir  = "$dir/host";
    my $hcache    = "$host_dir/.claude/plugins/cache/fixture-mkt/refresh-me/bbbbbbbbbbbb";
    my $home_dir  = "$dir/claude_home";
    my $dest_root = "$home_dir/plugins";
    my $dest_rel  = 'cache/fixture-mkt/refresh-me/bbbbbbbbbbbb';

    write_tree($hcache, 'plugin.json' => "{}\n", 'assets/logo.png' => "\x89PNGfixture");

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'refresh-me@fixture-mkt' => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01', gitCommitSha => 'bbb333' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);    # refresh-me is NOT selected-and-discovered this launch
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $out = "$dest_root/installed_plugins.json";
    t_spew_raw($out, { plugins => {
        'refresh-me@fixture-mkt' => [ { scope => 'project', projectPath => '/project',
            version => 'aaaaaaaaaaaa',
            installPath => '/root/.claude/plugins/cache/fixture-mkt/refresh-me/aaaaaaaaaaaa',
            installedAt => '2025-06-01T00:00:00Z', gitCommitSha => 'aaa444' } ],
    }});

    my $manifest = "$dir/manifest.json";
    my $prior1   = prior_plan_for($manifest);    # [] -- never placed by the launcher before

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $r1 = t_slurp_utf8($out);
    my $e1 = $r1->{plugins}{'refresh-me@fixture-mkt'}[0];
    is($e1->{version}, 'bbbbbbbbbbbb', 'AC5: preserved-and-refreshable record moves to host B');
    is($e1->{gitCommitSha}, 'bbb333', 'AC5: gitCommitSha refreshed to the host\'s value');
    is($e1->{scope}, 'project', 'AC5: sandbox scope kept');
    is($e1->{projectPath}, '/project', 'AC5: sandbox projectPath kept');
    is($e1->{installedAt}, '2025-06-01T00:00:00Z', 'AC5: sandbox installedAt kept');

    my $plan1 = t_slurp_utf8($manifest);
    my ($entry1) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'refresh-me@fixture-mkt' } @$plan1;
    ok($entry1, 'AC5: manifest carries an entry for the refreshed key');
    is($entry1->{origin}, 'host-refresh', 'AC5: manifest entry origin is host-refresh');

    reconcile_copy_plan($prior1, $plan1, $dest_root);
    is_deeply(dir_snapshot("$dest_root/$dest_rel"), dir_snapshot($hcache),
        'AC5: cache dir B is complete after reconcile');

    # AC6 -- stability: run again with unchanged inputs.
    my $prior2 = prior_plan_for($manifest);    # plan1, carrying origin=host-refresh
    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );
    my $r2 = t_slurp_utf8($out);
    is($r2->{plugins}{'refresh-me@fixture-mkt'}[0]{version}, 'bbbbbbbbbbbb',
        'AC6: second run keeps the key at the host version (not dropped as deselected)');
    my $plan2 = t_slurp_utf8($manifest);
    my ($entry2) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'refresh-me@fixture-mkt' } @$plan2;
    ok($entry2, 'AC6: a host-refresh entry is emitted again on the second run');
    is($entry2->{origin}, 'host-refresh', 'AC6: origin is still host-refresh, not treated as newly placed');
    reconcile_copy_plan($prior2, $plan2, $dest_root);
    ok(-d "$dest_root/$dest_rel", 'AC6: dir B still present after the second reconcile');

    # AC7 -- retain: remove the host install, run a third time.
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $prior3 = prior_plan_for($manifest);    # plan2, origin=host-refresh
    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );
    my $r3 = t_slurp_utf8($out);
    is($r3->{plugins}{'refresh-me@fixture-mkt'}[0]{version}, 'bbbbbbbbbbbb',
        'AC7: record kept at B (last written) once the host install disappears');
    my $plan3 = t_slurp_utf8($manifest);
    my ($entry3) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'refresh-me@fixture-mkt' } @$plan3;
    ok($entry3, 'AC7: a manifest entry is still emitted once the host install is gone');
    is($entry3->{origin}, 'host-refresh-retained', 'AC7: origin is host-refresh-retained');
    is($entry3->{dest_rel}, $dest_rel, 'AC7: retain entry dest_rel matches the prior entry\'s');
    ok(!exists $entry3->{src}, 'AC7: retain entry carries no src');
    reconcile_copy_plan($prior3, $plan3, $dest_root);
    ok(-d "$dest_root/$dest_rel", 'AC7: dir B is still present after reconcile with a retain entry');

    # AC7 continued -- the operator then deletes the sandbox record too.
    my $r3b = t_slurp_utf8($out);
    delete $r3b->{plugins}{'refresh-me@fixture-mkt'};
    t_spew_raw($out, $r3b);
    my $prior4 = prior_plan_for($manifest);    # plan3, origin=host-refresh-retained
    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );
    my $plan4 = t_slurp_utf8($manifest);
    my @entries4 = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'refresh-me@fixture-mkt' } @$plan4;
    is(scalar(@entries4), 0, 'AC7: no manifest entry once the sandbox record itself is deleted');
    reconcile_copy_plan($prior4, $plan4, $dest_root);
    ok(!-e "$dest_root/$dest_rel", 'AC7: reconcile removes dir B once nothing references it any more');
}

# ===========================================================================
# AC8 -- directory-source key stays a live bind: preserved verbatim, no
# manifest entry, even though the host has an install with a present dir.
# ===========================================================================
{
    my $dir      = "$ISO_ROOT/ac8";
    my $host_dir = "$dir/host";
    my $hcache   = "$host_dir/.claude/plugins/cache/fixture-dir/p/bbbbbbbbbbbb";
    make_path($hcache);

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'p@fixture-dir' => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01' } ],
    }});
    t_spew_raw("$host_dir/known_marketplaces.json", {
        'fixture-dir' => { source => { source => 'directory', path => "$dir/mkt-src" } },
    });

    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $existing_record = [ { scope => 'user', version => 'aaaaaaaaaaaa',
        installPath => '/root/.claude/plugins/marketplaces/fixture-dir/p', installedAt => '2025-01-01' } ];
    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'p@fixture-dir' => $existing_record } });

    my $manifest = "$dir/manifest.json";
    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    is_deeply($result->{plugins}{'p@fixture-dir'}, $existing_record,
        'AC8: directory-source key kept verbatim despite a present host install');
    my $plan = t_slurp_utf8($manifest);
    my @entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'p@fixture-dir' } @$plan;
    is(scalar(@entries), 0, 'AC8: no manifest entry for the directory-source key');
}

# ===========================================================================
# AC9 -- preserved key whose host install exists on record but whose host
# dir is absent on disk: kept verbatim, no manifest entry, no warning.
# ===========================================================================
{
    my $dir      = "$ISO_ROOT/ac9";
    my $host_dir = "$dir/host";
    my $missing_hcache = "$host_dir/.claude/plugins/cache/fixture-mkt/gone-dir/bbbbbbbbbbbb";   # never created

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'gone-dir@fixture-mkt' => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $missing_hcache, installedAt => '2026-01-01' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $existing_record = [ { scope => 'user', version => 'aaaaaaaaaaaa',
        installPath => '/root/.claude/plugins/cache/fixture-mkt/gone-dir/aaaaaaaaaaaa', installedAt => '2025-01-01' } ];
    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'gone-dir@fixture-mkt' => $existing_record } });

    my $manifest = "$dir/manifest.json";
    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    is_deeply($result->{plugins}{'gone-dir@fixture-mkt'}, $existing_record,
        'AC9: kept verbatim when the host dir does not exist on disk');
    my $plan = t_slurp_utf8($manifest);
    my @entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'gone-dir@fixture-mkt' } @$plan;
    is(scalar(@entries), 0, 'AC9: no manifest entry when the host dir is absent');
}

# ===========================================================================
# M1 (review 06-review.md, MUST-FIX) -- a preserved-and-refreshable key whose
# EXISTING record is not an array (the old v1 schema stored one object per
# key, and any in-container write can leave any other shape) must not make
# cmd_materialize_plugins die. skills.pl:2245 today dereferences the existing
# record as an array unconditionally in the refresh branch, which dies with
# "Not an ARRAY reference" for a HASH-shaped or null record. Since a hash-shaped OR null
# existing record are both non-array shapes that must fall through to the
# verbatim branch, each sub-case is wrapped in eval so a die here reports as
# a failed assertion, not a suite-aborting crash that would swallow every
# later AC in this file.
# ===========================================================================
for my $case (
    { label => 'v1 object-shaped', value => { scope => 'user', version => 'aaaaaaaaaaaa',
        installPath => '/root/.claude/plugins/cache/fixture-mkt/m1-plugin/aaaaaaaaaaaa' } },
    { label => 'null', value => undef },
) {
    my $dir       = "$ISO_ROOT/ac-m1-" . ($case->{label} =~ /object/ ? 'obj' : 'null');
    my $host_dir  = "$dir/host";
    my $key       = 'm1-plugin@fixture-mkt';
    my $hcache    = "$host_dir/.claude/plugins/cache/fixture-mkt/m1-plugin/bbbbbbbbbbbb";
    write_tree($hcache, 'plugin.json' => "{}\n");

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        $key => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01', gitCommitSha => 'bbb999' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);    # not selected-and-discovered -> takes the refresh/preserve branch
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => { $key => $case->{value} } });
    my $manifest = "$dir/manifest.json";

    my $died;
    eval {
        cmd_materialize_plugins(
            selection_file => $sel, output => $out, manifest => $manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
        );
        1;
    } or $died = $@;
    ok(!$died, "M1 ($case->{label} existing record): cmd_materialize_plugins does not die")
        or diag($died);

    SKIP: {
        skip "cmd_materialize_plugins died, output/manifest not trustworthy", 2 if $died;
        my $result = t_slurp_utf8($out);
        is_deeply($result->{plugins}{$key}, $case->{value},
            "M1 ($case->{label} existing record): record comes out byte-for-byte unchanged, not refreshed");
        my $plan = t_slurp_utf8($manifest) // [];
        my @plan_entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq $key } @$plan;
        is(scalar(@plan_entries), 0,
            "M1 ($case->{label} existing record): no host-refresh manifest entry for a non-array record");
    }
}

# ===========================================================================
# S3 (review 06-review.md, SHOULD-FIX) -- the refresh path's non-ASCII
# branch: a preserved-and-refreshable key whose HOST cache dir sits under a
# path segment carrying a raw UTF-8 U+00E9 byte (never a literal accented
# char in this file's source, same convention as AC12/host-only-masks-any-
# layer.t:72). The refreshed installPath and the manifest src must be
# correct, and the dir must be found present.
# ===========================================================================
{
    my $accent    = encode_utf8("\x{e9}");
    my $dir       = "$ISO_ROOT/ac-s3/Andr${accent}";
    my $host_dir  = "$dir/host";
    my $key       = 's3-plugin@fixture-mkt';
    my $hcache    = "$host_dir/.claude/plugins/cache/fixture-mkt/s3-plugin/bbbbbbbbbbbb";
    write_tree($hcache, 'plugin.json' => "{}\n", 'lib/x.js' => "1;\n");

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        $key => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01', gitCommitSha => 'bbb777' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);    # not selected-and-discovered -> the refresh branch
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => { $key => [ { scope => 'user', version => 'aaaaaaaaaaaa',
        installPath => '/root/.claude/plugins/cache/fixture-mkt/s3-plugin/aaaaaaaaaaaa',
        installedAt => '2025-01-01' } ] } });
    my $manifest = "$dir/manifest.json";
    my $prior    = prior_plan_for($manifest);

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    is($result->{plugins}{$key}[0]{installPath},
        '/root/.claude/plugins/cache/fixture-mkt/s3-plugin/bbbbbbbbbbbb',
        'S3: refreshed installPath is correct under a non-ASCII host path segment');

    my $plan = read_copy_plan($manifest);
    my ($entry) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq $key } @$plan;
    ok($entry, 'S3: a host-refresh manifest entry is emitted under a non-ASCII host path segment');
    is($entry->{origin}, 'host-refresh', 'S3: manifest entry origin is host-refresh');
    is(encode_utf8($entry->{src}), $hcache, 'S3: manifest src round-trips byte-exact');

    my $dest_root = "$dir/claude_home/plugins";
    reconcile_copy_plan($prior, $plan, $dest_root);
    is_deeply(dir_snapshot("$dest_root/cache/fixture-mkt/s3-plugin/bbbbbbbbbbbb"), dir_snapshot($hcache),
        'S3: the host dir is found and copied complete under a non-ASCII host path segment');
}

# ===========================================================================
# AC10 -- a selected key absent from discovery: warns, no host record, and
# is dropped iff it was in the prior plan without origin (a); otherwise an
# existing sandbox record is preserved (b).
# ===========================================================================
{
    my $dir      = "$ISO_ROOT/ac10a";
    my $host_reg = "$dir/host/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);    # missing-key is NOT in discovery
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => ['missing-key@fixture-mkt'] });

    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'missing-key@fixture-mkt' => [ { scope => 'user',
        version => '1.0', installPath => '/root/.claude/plugins/cache/fixture-mkt/missing-key/1.0' } ] } });

    # Prior plan placed this key WITHOUT origin -- "placed by the launcher".
    my $manifest = "$dir/manifest.json";
    t_spew_raw($manifest, [ { key => 'missing-key@fixture-mkt',
        src => "$dir/host/cache/fixture-mkt/missing-key/1.0", dest_rel => 'cache/fixture-mkt/missing-key/1.0' } ]);

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(
            selection_file => $sel, output => $out, manifest => $manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
        );
    }
    ok((grep { /missing-key\@fixture-mkt/ } @warnings), 'AC10(a): a warning names the selected-but-undiscovered key')
        or diag(join('', @warnings));

    my $result = t_slurp_utf8($out);
    ok(!exists $result->{plugins}{'missing-key@fixture-mkt'},
        'AC10(a): no host record, and the prior-placed (no origin) record is dropped');
    my $plan = t_slurp_utf8($manifest);
    my @entries = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'missing-key@fixture-mkt' } @$plan;
    is(scalar(@entries), 0, 'AC10(a): dropped key gets no manifest entry');
}
{
    my $dir      = "$ISO_ROOT/ac10b";
    my $host_reg = "$dir/host/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => ['missing-key-b@fixture-mkt'] });

    my $existing_record = [ { scope => 'user', version => '1.0',
        installPath => '/root/.claude/plugins/cache/fixture-mkt/missing-key-b/1.0' } ];
    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'missing-key-b@fixture-mkt' => $existing_record } });

    my $manifest = "$dir/manifest.json";
    t_spew_raw($manifest, []);    # never placed by the launcher before

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(
            selection_file => $sel, output => $out, manifest => $manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
        );
    }
    ok((grep { /missing-key-b\@fixture-mkt/ } @warnings), 'AC10(b): a warning names the selected-but-undiscovered key');
    my $result = t_slurp_utf8($out);
    is_deeply($result->{plugins}{'missing-key-b@fixture-mkt'}, $existing_record,
        'AC10(b): a sandbox record never placed by the launcher is preserved, not dropped');
}

# ===========================================================================
# AC11 -- output top-level version mirrors the host file's, iff it's a JSON
# integer.
# ===========================================================================
{
    my $dir = "$ISO_ROOT/ac11";
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);

    my $host_int = "$dir/host_int.json";
    t_spew_raw($host_int, '{"version":2,"plugins":{}}');
    my $out_int = "$dir/out_int.json";
    cmd_materialize_plugins(selection_file => $sel, output => $out_int, manifest => "$dir/m_int.json",
        plugins_snapshot => $snap, plugins_file => $host_int, project_path => '/project');
    is(t_slurp_utf8($out_int)->{version}, 2, 'AC11: host version:2 (integer) carries through to the output');

    my $host_missing = "$dir/host_missing.json";
    t_spew_raw($host_missing, '{"plugins":{}}');
    my $out_missing = "$dir/out_missing.json";
    cmd_materialize_plugins(selection_file => $sel, output => $out_missing, manifest => "$dir/m_missing.json",
        plugins_snapshot => $snap, plugins_file => $host_missing, project_path => '/project');
    ok(!exists t_slurp_utf8($out_missing)->{version}, 'AC11: no host version key -> no output version key');

    my $host_str = "$dir/host_str.json";
    t_spew_raw($host_str, '{"version":"2","plugins":{}}');
    my $out_str = "$dir/out_str.json";
    cmd_materialize_plugins(selection_file => $sel, output => $out_str, manifest => "$dir/m_str.json",
        plugins_snapshot => $snap, plugins_file => $host_str, project_path => '/project');
    ok(!exists t_slurp_utf8($out_str)->{version}, 'AC11: a non-integer (string) host version -> no output version key');
}

# ===========================================================================
# AC12 -- non-ASCII: the host root lives under a directory named with a raw
# UTF-8-byte U+00E9 (never a literal accented char in this file's source, per
# host-only-masks-any-layer.t:72's convention). AC1+AC2 hold: complete copy,
# and the manifest src round-trips byte-exact through read_copy_plan.
# ===========================================================================
{
    my $accent    = encode_utf8("\x{e9}");
    my $dir       = "$ISO_ROOT/ac12/Andr${accent}";
    my $host_dir  = "$dir/host";
    my $hcache    = "$host_dir/.claude/plugins/cache/claude-plugins-official/feature-dev/bbbbbbbbbbbb";
    my $home_dir  = "$dir/claude_home";
    my $dest_root = "$home_dir/plugins";

    write_tree($hcache, 'plugin.json' => "{}\n", 'lib/util.js' => "1;\n", '.envrc' => "F=1\n");

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'feature-dev@claude-plugins-official' => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01', gitCommitSha => 'bbb555' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, [ { key => 'feature-dev@claude-plugins-official', scope => 'user',
        version => 'bbbbbbbbbbbb', install_path => $hcache } ]);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => ['feature-dev@claude-plugins-official'] });
    my $out = "$dest_root/installed_plugins.json";
    t_spew_raw($out, { plugins => {} });
    my $manifest = "$dir/manifest.json";
    my $prior    = prior_plan_for($manifest);

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    is($result->{plugins}{'feature-dev@claude-plugins-official'}[0]{version}, 'bbbbbbbbbbbb',
        'AC12: AC1 holds when the host root path contains a non-ASCII byte');

    my $plan = read_copy_plan($manifest);
    my ($entry) = grep { ref($_) eq 'HASH' && ($_->{key} // '') eq 'feature-dev@claude-plugins-official' } @$plan;
    ok($entry, 'AC12: manifest entry present for the accented-path fixture');
    is(encode_utf8($entry->{src}), $hcache,
        'AC12: manifest src round-trips byte-exact through PluginSync::read_copy_plan');

    reconcile_copy_plan($prior, $plan, $dest_root);
    is_deeply(dir_snapshot("$dest_root/cache/claude-plugins-official/feature-dev/bbbbbbbbbbbb"), dir_snapshot($hcache),
        'AC12: complete copy under a non-ASCII host root');
}

# ===========================================================================
# AC13 -- MSYS/path shape: no selected or refreshed installPath/src is ever
# usable as a HOST:CONTAINER-style MSYS mount-spec fragment (no ';', no '\',
# no drive letter, no literal '-v'-style colon inside the container path).
# ===========================================================================
{
    my $dir       = "$ISO_ROOT/ac13";
    my $host_dir  = "$dir/host";
    my $hcache    = "$host_dir/.claude/plugins/cache/fixture-mkt/shape-check/bbbbbbbbbbbb";
    make_path($hcache);
    write_tree($hcache, 'f.txt' => "1\n");

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'shape-check@fixture-mkt' => [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01' } ],
    }});
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, [ { key => 'shape-check@fixture-mkt', scope => 'user',
        version => 'bbbbbbbbbbbb', install_path => $hcache } ]);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => ['shape-check@fixture-mkt'] });
    my $out = "$dir/claude_home/plugins/installed_plugins.json";
    t_spew_raw($out, { plugins => {} });
    my $manifest = "$dir/manifest.json";

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );

    my $result = t_slurp_utf8($out);
    for my $key (keys %{ $result->{plugins} }) {
        for my $inst (@{ $result->{plugins}{$key} }) {
            like($inst->{installPath}, qr{^/root/\.claude/plugins/cache/[^;\\:]+$},
                "AC13: $key installPath matches the safe container-cache shape");
        }
    }
    my $plan = t_slurp_utf8($manifest);
    for my $e (@$plan) {
        next unless ref($e) eq 'HASH' && defined $e->{src};
        unlike($e->{src}, qr{\\}, "AC13: manifest src for $e->{key} contains no backslash");
    }
}

# ===========================================================================
# AC14 -- launch-cost bound: 10 selected plugins x 50 ~1KiB files, full
# sequence (materialize + reconcile) under 15s wall time, generous on purpose.
# ===========================================================================
{
    my $dir       = "$ISO_ROOT/ac14";
    my $host_dir  = "$dir/host";
    my $home_dir  = "$dir/claude_home";
    my $dest_root = "$home_dir/plugins";
    my $n         = 10;
    my $blob      = ('x' x 1024);

    my (@snap_entries, %plugins, @selected);
    for my $i (0 .. $n - 1) {
        my $key   = "perf-plugin-$i\@fixture-mkt";
        my $hcache = "$host_dir/.claude/plugins/cache/fixture-mkt/perf-plugin-$i/bbbbbbbbbbbb";
        my %files;
        $files{"f$_.dat"} = $blob for (1 .. 50);
        write_tree($hcache, %files);
        $plugins{$key} = [ { scope => 'user', version => 'bbbbbbbbbbbb',
            installPath => $hcache, installedAt => '2026-01-01', gitCommitSha => "sha$i" } ];
        push @snap_entries, { key => $key, scope => 'user', version => 'bbbbbbbbbbbb', install_path => $hcache };
        push @selected, $key;
    }

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => \%plugins });
    my $snap = "$dir/snap.json";
    t_spew_raw($snap, \@snap_entries);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => \@selected });
    my $out = "$dest_root/installed_plugins.json";
    t_spew_raw($out, { plugins => {} });
    my $manifest = "$dir/manifest.json";
    my $prior    = prior_plan_for($manifest);

    my $t0 = time();
    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );
    my $plan = t_slurp_utf8($manifest);
    reconcile_copy_plan($prior, $plan, $dest_root);
    my $elapsed = time() - $t0;

    is(scalar(@$plan), $n, "AC14: manifest has exactly $n entries");
    cmp_ok($elapsed, '<', 15, "AC14: full sequence for $n plugins x 50 files completed in ${elapsed}s (< 15s)");
}

# ===========================================================================
# AC16 -- wiring, static read of launcher.pl (never executed): in source
# order, _read_copy_plan($PLUGINS_COPY_MANIFEST), 'materialize-plugins', and
# sync_copy_plan($prior_plugins_plan all appear before the launch-emit marker.
# ===========================================================================
{
    my $launcher_path = "$Bin/../../scripts/launcher.pl";
    open my $fh, '<:raw', $launcher_path or die "read $launcher_path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    my $i1 = index($src, '_read_copy_plan($PLUGINS_COPY_MANIFEST)');
    my $i2 = index($src, "'materialize-plugins'");
    my $i3 = index($src, 'sync_copy_plan($prior_plugins_plan');
    my $marker = index($src, '# >>> launch-emit:create:BEGIN');

    ok($i1 >= 0, 'AC16: launcher.pl reads the prior plugins copy plan');
    ok($i2 >= 0, "AC16: launcher.pl invokes 'materialize-plugins'");
    ok($i3 >= 0, 'AC16: launcher.pl reconciles the new plugins copy plan');
    ok($marker >= 0, 'AC16: the launch-emit:create marker is present');
    ok($i1 >= 0 && $i1 < $marker, 'AC16: read-prior-plan precedes launch-emit:create');
    ok($i2 >= 0 && $i2 < $marker, 'AC16: materialize-plugins precedes launch-emit:create');
    ok($i3 >= 0 && $i3 < $marker, 'AC16: sync-copy-plan precedes launch-emit:create');
    ok($i1 < $i2 && $i2 < $i3, 'AC16: the three steps appear in read -> materialize -> sync order');
}

# ===========================================================================
# AC17 -- container settings.json: plugin auto-update gate open, gated per
# marketplace; host-shared marketplaces never flagged (tooling-fixes package
# 15, Decision 46, spec section 2.13.1).
# ===========================================================================
{
    my $settings_path = "$Bin/../../container/settings.json";
    open my $fh, '<:raw', $settings_path or die "read $settings_path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    my $settings = JSON::PP->new->decode($bytes);

    is($settings->{env}{FORCE_AUTOUPDATE_PLUGINS}, '1',
        'AC17a: container settings.json sets env.FORCE_AUTOUPDATE_PLUGINS to "1"');
    is($settings->{env}{DISABLE_AUTOUPDATER}, '1', 'AC17b: env.DISABLE_AUTOUPDATER stays "1"');
    ok($settings->{enabledPlugins}{'feature-dev@claude-plugins-official'},
        'AC17c: feature-dev@claude-plugins-official still user-enabled');
    ok($settings->{enabledPlugins}{'frontend-design@claude-plugins-official'},
        'AC17d: frontend-design@claude-plugins-official still user-enabled');

    my $ekm = $settings->{extraKnownMarketplaces} // {};
    is_deeply(
        [ sort grep { ref $ekm->{$_} eq 'HASH' && exists $ekm->{$_}{autoUpdate} } keys %$ekm ],
        [],
        'AC17e: no extraKnownMarketplaces.*.autoUpdate key anywhere in container settings.json'
    );
}

# ===========================================================================
# AC17f/AC17g -- shared-marketplace fixture (tooling-fixes package 15,
# Decision 46, spec section 2.13.1). A marketplace with any host-shared key
# (selected this launch, host-refreshed, or a host install whose dir is
# missing) must never come out autoUpdate true, even when the host side, the
# prior container km output, and a stale sidecar all say true. AC17g is the
# non-vacuity control: the same fixture, made unmixed, must flip to true.
# ===========================================================================

# Minimal inline version of the AC25 d0c9689-invariant predicate (the full,
# reusable helper lives in sandbox-only-plugin-updates.t): a true-flagged
# marketplace must hold no selected-or-host-installed registry key. Applied
# here to claude-plugins-official specifically, per spec's "AC17f applies the
# same predicate inline".
sub ac17_invariant_ok {
    my ($km_result, $label) = @_;
    my $flag = $km_result->{'claude-plugins-official'}{autoUpdate};
    ok(JSON::PP::is_bool($flag), "$label: claude-plugins-official.autoUpdate is a JSON boolean");
    return $flag;
}

sub run_shared_marketplace_case {
    my (%opt) = @_;    # label, selected, host_dir_present, prior_feature_dev
    my $dir      = "$ISO_ROOT/ac17f-$opt{label}";
    my $host_dir = "$dir/host";
    my $L        = "$dir/launcher";
    my $C        = "$dir/claude_home/plugins";
    make_path($L);

    my $hcache = "$host_dir/.claude/plugins/cache/claude-plugins-official/feature-dev/1.0.0";
    write_tree($hcache, 'plugin.json' => "{\"name\":\"feature-dev\"}\n");
    unless ($opt{host_dir_present}) {
        require File::Path;
        File::Path::remove_tree($hcache);
    }

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {
        'feature-dev@claude-plugins-official' => [ { scope => 'user', version => '1.0.0',
            installPath => $hcache, installedAt => '2026-01-01T00:00:00Z', gitCommitSha => 'feat100' } ],
    }});

    t_spew_raw("$host_dir/known_marketplaces.json", {
        'claude-plugins-official' => {
            source => { source => 'github', repo => 'anthropics/claude-plugins-official' },
            installLocation => "$host_dir/marketplaces/claude-plugins-official",
            autoUpdate => JSON::PP::true,
        },
    });

    write_tree("$host_dir/marketplaces/claude-plugins-official/plugins/feature-dev",
        'plugin.json' => "{\"name\":\"feature-dev\",\"version\":\"1.0.0\"}\n");
    t_spew_raw("$host_dir/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json", {
        plugins => [
            { name => 'feature-dev', source => './plugins/feature-dev' },
            { name => 'remote-x', source => { source => 'url', url => 'https://example.invalid/x.git' } },
        ],
    });

    my $remote_x_record = [ { scope => 'user', version => '0.1.0',
        installPath => '/root/.claude/plugins/cache/claude-plugins-official/remote-x/0.1.0',
        installedAt => '2026-01-01T00:00:00Z' } ];
    my %c_plugins = ( 'remote-x@claude-plugins-official' => $remote_x_record );
    if ($opt{prior_feature_dev}) {
        $c_plugins{'feature-dev@claude-plugins-official'} = [ { scope => 'user', version => '0.9.0',
            installPath => '/root/.claude/plugins/cache/claude-plugins-official/feature-dev/0.9.0',
            installedAt => '2025-12-01T00:00:00Z' } ];
    }
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => \%c_plugins });

    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { 'claude-plugins-official' => {
        source => { source => 'github', repo => 'anthropics/claude-plugins-official' },
        autoUpdate => JSON::PP::true,
    }});

    my $plugins_manifest = "$L/plugins-manifest.json";    # no prior manifest -- never written
    my $mkt_manifest     = "$L/mkt-manifest.json";
    t_spew_raw("$L/.sandbox-autoupdate-marketplaces.json", ['claude-plugins-official']);    # stale

    my $snap = "$dir/snap.json";
    my $sel  = "$dir/sel.json";
    if ($opt{selected}) {
        t_spew_raw($snap, [ { key => 'feature-dev@claude-plugins-official', scope => 'user',
            version => '1.0.0', install_path => $hcache } ]);
        t_spew_raw($sel, { schema_version => 3, selected_plugins => ['feature-dev@claude-plugins-official'] });
    } else {
        t_spew_raw($snap, []);
        t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });
    }

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        cmd_materialize_plugins(
            selection_file => $sel, output => $out, manifest => $plugins_manifest,
            plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
        );
        cmd_materialize_known_marketplaces(
            output => $km_out, manifest => $mkt_manifest, host_marketplaces => "$host_dir/known_marketplaces.json",
        );
    }

    return {
        plugins_result => t_slurp_utf8($out),
        km_result      => t_slurp_utf8($km_out),
        sidecar        => t_slurp_utf8("$L/.sandbox-autoupdate-marketplaces.json"),
        warnings       => \@warnings,
        remote_x_record => $remote_x_record,
    };
}

for my $case (
    { label => 'i-selected',    selected => 1, host_dir_present => 1, prior_feature_dev => 0,
      expect_version => '1.0.0', expect_sha => 'feat100' },
    { label => 'ii-host-refresh', selected => 0, host_dir_present => 1, prior_feature_dev => 1,
      expect_version => '1.0.0', expect_sha => 'feat100' },
    { label => 'iii-dir-missing', selected => 0, host_dir_present => 0, prior_feature_dev => 1,
      expect_version => '0.9.0', expect_sha => undef },
) {
    my $r = run_shared_marketplace_case(%$case);

    ok((ref($r->{sidecar}) eq 'ARRAY'), "AC17f ($case->{label}): sidecar decodes to an array");
    ok(!(grep { $_ eq 'claude-plugins-official' } @{ $r->{sidecar} || [] }),
        "AC17f ($case->{label}): sidecar does not contain claude-plugins-official");

    my $flag = ac17_invariant_ok($r->{km_result}, "AC17f ($case->{label})");
    ok(!$flag, "AC17f ($case->{label}): claude-plugins-official.autoUpdate is false despite host/prior/stale-sidecar true");

    is_deeply($r->{plugins_result}{plugins}{'remote-x@claude-plugins-official'}, $r->{remote_x_record},
        "AC17f ($case->{label}): remote-x\@claude-plugins-official record deep-equal to its input");

    my $fd = $r->{plugins_result}{plugins}{'feature-dev@claude-plugins-official'}[0];
    is($fd->{version}, $case->{expect_version}, "AC17f ($case->{label}): feature-dev version as stated for this case");
    if (defined $case->{expect_sha}) {
        is($fd->{gitCommitSha}, $case->{expect_sha}, "AC17f ($case->{label}): feature-dev gitCommitSha refreshed from the host");
    }
}

# AC17g -- control: the same fixture shape, but feature-dev has no host
# install and no container/selection record at all, making the marketplace
# unmixed. Proves AC17f is not vacuous (a wrong implementation that always
# emits false would fail here).
{
    my $dir      = "$ISO_ROOT/ac17g-control";
    my $host_dir = "$dir/host";
    my $L        = "$dir/launcher";
    my $C        = "$dir/claude_home/plugins";
    make_path($L);

    my $host_reg = "$host_dir/installed_plugins.json";
    t_spew_raw($host_reg, { version => 2, plugins => {} });    # no feature-dev host install

    t_spew_raw("$host_dir/known_marketplaces.json", {
        'claude-plugins-official' => {
            source => { source => 'github', repo => 'anthropics/claude-plugins-official' },
            autoUpdate => JSON::PP::true,
        },
    });
    write_tree("$host_dir/marketplaces/claude-plugins-official/plugins/feature-dev", 'plugin.json' => "{}\n");
    t_spew_raw("$host_dir/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json", {
        plugins => [
            { name => 'feature-dev', source => './plugins/feature-dev' },
            { name => 'remote-x', source => { source => 'url', url => 'https://example.invalid/x.git' } },
        ],
    });

    my $remote_x_record = [ { scope => 'user', version => '0.1.0',
        installPath => '/root/.claude/plugins/cache/claude-plugins-official/remote-x/0.1.0',
        installedAt => '2026-01-01T00:00:00Z' } ];
    my $out = "$C/installed_plugins.json";
    t_spew_raw($out, { plugins => { 'remote-x@claude-plugins-official' => $remote_x_record } });    # no feature-dev key

    my $km_out = "$C/known_marketplaces.json";
    t_spew_raw($km_out, { 'claude-plugins-official' => {
        source => { source => 'github', repo => 'anthropics/claude-plugins-official' },
        autoUpdate => JSON::PP::false,
    }});

    my $plugins_manifest = "$L/plugins-manifest.json";
    my $mkt_manifest     = "$L/mkt-manifest.json";

    my $snap = "$dir/snap.json";
    t_spew_raw($snap, []);
    my $sel = "$dir/sel.json";
    t_spew_raw($sel, { schema_version => 3, selected_plugins => [] });

    cmd_materialize_plugins(
        selection_file => $sel, output => $out, manifest => $plugins_manifest,
        plugins_snapshot => $snap, plugins_file => $host_reg, project_path => '/project',
    );
    cmd_materialize_known_marketplaces(
        output => $km_out, manifest => $mkt_manifest, host_marketplaces => "$host_dir/known_marketplaces.json",
    );

    my $sidecar = t_slurp_utf8("$L/.sandbox-autoupdate-marketplaces.json");
    is_deeply($sidecar, ['claude-plugins-official'],
        'AC17g (control): sidecar is exactly ["claude-plugins-official"] once the marketplace is unmixed');

    my $km_result = t_slurp_utf8($km_out);
    my $flag = ac17_invariant_ok($km_result, 'AC17g (control)');
    ok($flag, 'AC17g (control): claude-plugins-official.autoUpdate is true once unmixed -- proves AC17f is not vacuous');
}

# ===========================================================================
# Decision 24 addendum -- README.md (plugin-store section) no longer claims
# the sandbox "never touches" a plugin installed inside it; it instead
# describes host-wins materialisation (host-refresh) for a preserved record.
# ===========================================================================
{
    my $readme_path = "$Bin/../../README.md";
    open my $fh, '<:raw', $readme_path or die "read $readme_path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;

    unlike($text, qr/never touches a dir it didn'?t place/i,
        'Decision 24: README no longer claims the reconcile never touches a dir it didn\'t place');
    unlike($text, qr/never touches\b[^.]*\bplugins? you installed/i,
        'Decision 24: README no longer claims the sandbox never touches plugins installed inside it');
    like($text, qr/host[- ]?(?:refresh|wins|authoritative)/i,
        'Decision 24: README describes host-wins / host-refresh materialisation for a preserved record');
}

# ===========================================================================
# AC15(a) -- this file's own source spawns nothing at all: no system call,
# exec call, backtick-quoting, qx call, or piped-open, anywhere. Since it
# never spawns anything, it also never invokes podman or launcher.pl (b).
#
# The backtick character is matched via chr(96), never written literally,
# and "qx" is matched only immediately before an opening delimiter -- so
# this very check, and its own diagnostic text, cannot self-trigger.
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
    is(scalar(@violations), 0,
        'AC15: no subprocess-spawning construct anywhere in this file')
        or diag(join('', @violations));
    is($ENV{PATH}, '', 'AC15: PATH was emptied before requiring skills.pl');
    like($ISO_HOME, qr{^\Q$ISO_ROOT\E}, 'AC15: HOME/USERPROFILE fixture lives under the isolation tempdir');
}

done_testing();
