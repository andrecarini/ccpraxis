#!/usr/bin/env perl
# Fix 2 PluginSync: the copy-model file reconcile. reconcile_copy_plan makes the
# host-tier in claude-home equal EXACTLY the current copy-plan — refresh selected
# (host authoritative), remove what was placed before that's gone now (no
# zombies, prune empty parents), and NEVER touch a dir installed inside the
# sandbox (never named in a manifest). Pure host-side file ops, no container.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use PluginSync qw(reconcile_copy_plan prune_empty_parents safe_dest_rel);

plan tests => 26;

my $root = tempdir(CLEANUP => 1);
sub spew { my ($p,$c)=@_; my ($d)=$p=~m{^(.*)/[^/]+$}; make_path($d) if $d && !-d $d;
           open my $f,'>:raw',$p or die "$p: $!"; print $f $c; close $f; }
sub slurp { my $p=shift; return undef unless -f $p; open my $f,'<:raw',$p or die; local $/; <$f> }

# Host source tree (what the launcher copies FROM).
my $host = "$root/host";
spew("$host/cache/m/A/1.0/plugin.txt", "host-A-v1");
spew("$host/cache/m/C/1.0/plugin.txt", "host-C-v1");

my $dest = "$root/dest";                 # = claude-home/plugins
# A plugin installed INSIDE the sandbox (never in any manifest) — must survive.
spew("$dest/cache/m/B/9.0/plugin.txt", "sandbox-B");

my $A = { key=>'A', src=>"$host/cache/m/A/1.0", dest_rel=>'cache/m/A/1.0' };
my $C = { key=>'C', src=>"$host/cache/m/C/1.0", dest_rel=>'cache/m/C/1.0' };

# --- initial copy: prior empty, plan = [A, C] -------------------------------
reconcile_copy_plan([], [$A, $C], $dest);
is(slurp("$dest/cache/m/A/1.0/plugin.txt"), 'host-A-v1', 'initial: A copied from host');
is(slurp("$dest/cache/m/C/1.0/plugin.txt"), 'host-C-v1', 'initial: C copied from host');
is(slurp("$dest/cache/m/B/9.0/plugin.txt"), 'sandbox-B', 'initial: sandbox install B untouched');

# --- host authoritative: scribble on A in the sandbox, re-reconcile ---------
spew("$dest/cache/m/A/1.0/plugin.txt", "TAMPERED");
reconcile_copy_plan([$A, $C], [$A, $C], $dest);
is(slurp("$dest/cache/m/A/1.0/plugin.txt"), 'host-A-v1', 'refresh: in-sandbox tamper reverted (host wins)');

# --- reconcile to a smaller selection: drop C, keep A + sandbox B -----------
reconcile_copy_plan([$A, $C], [$A], $dest);
is(slurp("$dest/cache/m/A/1.0/plugin.txt"), 'host-A-v1', 'reconcile: selected A kept');
ok(!-e "$dest/cache/m/C", 'reconcile: deselected C removed (no zombie)');
is(slurp("$dest/cache/m/B/9.0/plugin.txt"), 'sandbox-B', 'reconcile: sandbox B still preserved');
ok(-d "$dest/cache/m", 'reconcile: shared parent kept (still holds A + B)');

# --- version bump: A/1.0 -> A/2.0 -------------------------------------------
spew("$host/cache/m/A/2.0/plugin.txt", "host-A-v2");
my $A2 = { key=>'A', src=>"$host/cache/m/A/2.0", dest_rel=>'cache/m/A/2.0' };
reconcile_copy_plan([$A], [$A2], $dest);
ok(!-e "$dest/cache/m/A/1.0", 'version bump: old A/1.0 removed');
is(slurp("$dest/cache/m/A/2.0/plugin.txt"), 'host-A-v2', 'version bump: new A/2.0 copied');

# --- prune empties fully when the last host plugin of a tree is removed ------
my $dest2 = "$root/dest2";
my $X = { key=>'X', src=>"$host/cache/m/A/2.0", dest_rel=>'cache/deep/X/1.0' };
reconcile_copy_plan([], [$X], $dest2);
ok(-d "$dest2/cache/deep/X/1.0", 'prune setup: X placed');
reconcile_copy_plan([$X], [], $dest2);
ok(!-e "$dest2/cache", 'prune: removing the only plugin prunes all now-empty parents up to dest_root');

# --- safe_dest_rel: path-traversal / absolute / drive guard ------------------
ok( safe_dest_rel('cache/m/A/1.0'), 'safe: a normal relative path is allowed');
ok(!safe_dest_rel('../etc'),        'safe: leading .. rejected');
ok(!safe_dest_rel('a/../b'),        'safe: interior .. rejected');
ok(!safe_dest_rel('/etc/passwd'),   'safe: absolute path rejected');
ok(!safe_dest_rel('C:/Windows'),    'safe: drive-letter path rejected');
ok(!safe_dest_rel(''),              'safe: empty rejected');

# A traversal dest_rel must NOT delete/copy outside dest_root.
my $dest3 = "$root/dest3";
my $outside = "$root/OUTSIDE_SENTINEL";
spew("$outside/keep.txt", 'do-not-touch');
make_path($dest3);
reconcile_copy_plan([{ src=>"$host/cache/m/A/2.0", dest_rel=>'../OUTSIDE_SENTINEL' }], [], $dest3);
ok(-e "$outside/keep.txt", 'safe: a ../ dest_rel in the prior plan does NOT delete outside dest_root');

# --- Bug-2 regression: read_copy_plan MUST decode the manifest UTF-8-aware -----
#     skills.pl writes the manifest with ->utf8->encode. Each `src` embeds the
#     user's home dir, which can hold non-ASCII bytes (".../André/..."). A plain
#     (non-utf8) decode splits each é into two Latin-1 chars, so the mangled src
#     fails every `-d $src` in reconcile and NOTHING copies — the exact bug that
#     left selected host plugins (e.g. notion) "active but not installed". This
#     locks the decode invariant (portable: no non-ASCII filename on disk).
{
    my $mf = "$root/manifest-utf8.json";
    my $src_in = "/c/Users/Andr\x{e9}/.claude/plugins/cache/mkt/P/1.0";  # é = U+00E9
    open my $w, '>:raw', $mf or die "$mf: $!";
    print $w JSON::PP->new->canonical->utf8->encode(
        [ { key=>'P', src=>$src_in, dest_rel=>'cache/mkt/P/1.0' } ]);
    close $w;
    my $plan = PluginSync::read_copy_plan($mf);
    is(scalar(@$plan), 1, 'utf8 manifest: one entry decoded');
    is($plan->[0]{src}, $src_in,
       'utf8 manifest: non-ASCII src round-trips byte-faithfully (->utf8 decode)');
    is(length($plan->[0]{src}), length($src_in),
       'utf8 manifest: src char-length preserved (é not split into two Latin-1 chars)');
}

# --- robust removal of READ-ONLY trees (github marketplace .git object packs) --
#     remove_tree({safe=>1}) refuses to chmod, so it can't delete read-only files
#     and leaves "Directory not empty" — reconcile must force-clear the read-only
#     bit first. Mirrors a copied github-source marketplace's read-only
#     .git/objects/pack/*.pack files (the exact reconcile failure observed).
{
    my $ro = "$root/ro-remove";
    spew("$ro/repo/.git/objects/pack/p.pack", "packbytes");
    spew("$ro/repo/.git/HEAD",                "ref: refs/heads/main");
    spew("$ro/repo/keep.txt",                 "x");
    chmod 0444, "$ro/repo/.git/objects/pack/p.pack";
    chmod 0444, "$ro/repo/.git/HEAD";
    PluginSync::_force_remove_tree("$ro/repo");
    ok(!-e "$ro/repo", 'force-remove deletes a tree containing read-only files (git packs)');
}

# --- symlink defense (red-team MEDIUM-1): a container-planted symlink in the
#     RW claude-home/plugins tree must not let reconcile escape dest_root.
#     Skipped where the perl/FS can't make a followable symlink (Git-for-Windows
#     turns them into junctions/copies); runs on the Linux sandbox test pass.
SKIP: {
    my $sroot   = "$root/sym";
    my $outside = "$sroot/outside";
    spew("$outside/secret.txt", 'host-secret');     # lives OUTSIDE the dest_root
    my $droot = "$sroot/dest";
    make_path("$droot/cache");
    my $made = eval { symlink($outside, "$droot/cache/evil"); 1 };
    skip 'no followable symlinks on this perl/filesystem', 3
        unless $made && -l "$droot/cache/evil";

    ok(!PluginSync::_safe_parents($droot, 'cache/evil/x/1.0'),
       'symlink: a symlinked intermediate component is refused');
    # Reconcile-remove of a leaf symlink must unlink the LINK, never its target.
    reconcile_copy_plan([{ src=>"$host/cache/m/A/2.0", dest_rel=>'cache/evil' }], [], $droot);
    ok(!-e "$droot/cache/evil", 'symlink: the planted leaf link is removed');
    ok(-e "$outside/secret.txt", 'symlink: the target OUTSIDE dest_root is untouched (no escape)');
}
