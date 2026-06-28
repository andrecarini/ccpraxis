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
use PluginSync qw(reconcile_copy_plan prune_empty_parents);

plan tests => 12;

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
