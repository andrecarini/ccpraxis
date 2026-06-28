package PluginSync;
# Fix 2 tier-2 plugin store (copy model) — the pure file-reconcile core, split
# out of launcher.pl so it's unit-testable on the host with no container.
#
# The launcher COPIES the selected host plugins (+ marketplace metadata) into
# claude-home/plugins/ each manager launch, driven by copy-plan manifests
# skills.pl writes (arrayrefs of {src, dest_rel}). reconcile_copy_plan makes the
# host-tier in claude-home equal EXACTLY the current plan: it removes what the
# launcher placed last launch that isn't in the plan now (deselected / removed
# on the host -> no zombies) and (re)copies the current set from the host (host
# authoritative -> no drift, in-container scribbling reverted). Dirs never named
# in a manifest (plugins installed INSIDE the sandbox) are left untouched.
use strict;
use warnings;
use File::Path qw(make_path remove_tree);
use Exporter qw(import);

our @EXPORT_OK = qw(copy_tree prune_empty_parents reconcile_copy_plan safe_dest_rel);

# safe_dest_rel($rel) -> 1 iff $rel is a safe RELATIVE path under dest_root: a
# non-empty `/`-joined chain of plain names, with NO absolute root, NO drive
# letter, NO `..`/`.`/empty component, no backslash, no NUL. Defense-in-depth so
# a malformed manifest dest_rel can never make reconcile remove/copy OUTSIDE
# claude-home/plugins (the dest_rels are launcher-derived from the host
# registry, not container-writable, but this is the belt-and-suspenders guard).
sub safe_dest_rel {
    my $rel = shift;
    return 0 unless defined $rel && length $rel;
    return 0 if $rel =~ m{\\} || $rel =~ /\0/;       # backslash / NUL
    return 0 if $rel =~ m{^/} || $rel =~ m{^[A-Za-z]:};   # absolute / drive
    for my $part (split m{/}, $rel) {
        return 0 if $part eq '' || $part eq '.' || $part eq '..';
    }
    return 1;
}

# copy_tree($src, $dst) — recursive, portable, pure-perl (no `cp -a`, which on
# Git-for-Windows hits MSYS path-form issues with winified `C:/` paths). Plugins
# are plain files + dirs; SYMLINKS ARE SKIPPED (checked before -d/-f, which would
# otherwise FOLLOW the link) — both as a defense (a symlinked source component
# could escape) and to avoid symlink-loop recursion.
sub copy_tree {
    my ($src, $dst) = @_;
    return if -l $src;                       # never follow a symlink
    if (-d $src) {
        make_path($dst) unless -d $dst;
        opendir(my $dh, $src) or do { warn "PluginSync: opendir $src: $!\n"; return; };
        my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        copy_tree("$src/$_", "$dst/$_") for @kids;
    } elsif (-f $src) {
        _copy_file($src, $dst);
    }
}

# _safe_parents($dest_root, $rel) -> 1 iff $dest_root is not a symlink and no
# EXISTING intermediate component of $dest_root/$rel (excluding the leaf) is a
# symlink. claude-home/plugins is RW from the container, so it could plant a
# symlink at a cache path; remove_tree/copy_tree/make_path would then resolve
# THROUGH it and escape claude-home. We refuse to operate through any such link.
# Missing intermediates are fine — copy_tree's make_path creates them as real
# dirs. The leaf is handled by the caller (a leaf symlink is unlinked, not
# followed).
sub _safe_parents {
    my ($dest_root, $rel) = @_;
    return 0 if -l $dest_root;
    my @parts = split m{/}, $rel;
    pop @parts;                              # the leaf is the caller's concern
    my $cur = $dest_root;
    for my $p (@parts) {
        $cur .= "/$p";
        next unless -e $cur || -l $cur;
        return 0 if -l $cur;                 # an existing symlink component -> refuse
    }
    return 1;
}

sub _copy_file {
    my ($src, $dst) = @_;
    open my $in, '<:raw', $src or do { warn "PluginSync: read $src: $!\n"; return; };
    local $/;
    my $bytes = <$in>;
    close $in;
    # Parent dir must exist (copy_tree makes the dir entries, but a top-level
    # file copy may not have).
    my ($parent) = $dst =~ m{^(.*)/[^/]+$};
    make_path($parent) if defined $parent && length $parent && !-d $parent;
    open my $out, '>:raw', $dst or do { warn "PluginSync: write $dst: $!\n"; return; };
    print $out (defined $bytes ? $bytes : '');
    close $out;
}

# prune_empty_parents($dest_root, $rel) — rmdir empty parent dirs of
# $dest_root/$rel, walking UP but never past $dest_root. rmdir only removes an
# empty dir, so it stops at the first parent still holding something (e.g. a
# sibling sandbox-installed plugin under the same marketplace).
sub prune_empty_parents {
    my ($dest_root, $rel) = @_;
    return unless defined $rel && length $rel;
    my @parts = split m{/}, $rel;
    pop @parts;                          # drop the leaf (already removed)
    while (@parts) {
        my $dir = "$dest_root/" . join('/', @parts);
        last if -l $dir;                 # never rmdir at/through a symlink
        last unless -d $dir;
        last unless rmdir $dir;          # non-empty -> stop
        pop @parts;
    }
}

# reconcile_copy_plan($prior, $new, $dest_root, %opt) — see the package doc.
#   $prior, $new : arrayrefs of {src, dest_rel}.
#   $dest_root   : where dest_rel is rooted (claude-home/plugins).
#   opt.winify   : coderef applied to each src (default identity); the launcher
#                  passes winify_path so `/c/...` host paths become `C:/...`.
sub reconcile_copy_plan {
    my ($prior, $new, $dest_root, %opt) = @_;
    $prior ||= []; $new ||= [];
    my $winify = $opt{winify} || sub { $_[0] };
    make_path($dest_root) unless -d $dest_root;

    my %new_dests = map { $_->{dest_rel} => 1 }
        grep { ref $_ eq 'HASH' && defined $_->{dest_rel} } @$new;

    # 1. remove what we placed last launch that isn't in the plan now.
    for my $e (@$prior) {
        next unless ref $e eq 'HASH' && defined $e->{dest_rel};
        next if $new_dests{$e->{dest_rel}};
        next unless safe_dest_rel($e->{dest_rel});           # no ../ or absolute
        next unless _safe_parents($dest_root, $e->{dest_rel}); # no symlinked parent
        my $stale = "$dest_root/$e->{dest_rel}";
        if    (-l $stale) { unlink $stale; }                 # remove the link, NOT its target
        elsif (-e $stale) { remove_tree($stale, { safe => 1 }); }
        prune_empty_parents($dest_root, $e->{dest_rel});
    }
    # 2. (re)copy the current host-tier set, host authoritative.
    for my $e (@$new) {
        next unless ref $e eq 'HASH' && defined $e->{src} && defined $e->{dest_rel};
        next unless safe_dest_rel($e->{dest_rel});
        next unless _safe_parents($dest_root, $e->{dest_rel});
        my $src = $winify->($e->{src});
        next unless -d $src && !-l $src;                      # don't follow a symlinked source
        my $dst = "$dest_root/$e->{dest_rel}";
        if    (-l $dst) { unlink $dst; }                     # drop a planted leaf symlink
        elsif (-e $dst) { remove_tree($dst, { safe => 1 }); } # clean refresh (host wins)
        copy_tree($src, $dst);
    }
}

1;
