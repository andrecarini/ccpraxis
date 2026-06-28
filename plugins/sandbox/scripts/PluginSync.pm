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

our @EXPORT_OK = qw(copy_tree prune_empty_parents reconcile_copy_plan);

# copy_tree($src, $dst) — recursive, portable, pure-perl (no `cp -a`, which on
# Git-for-Windows hits MSYS path-form issues with winified `C:/` paths). Plugins
# are plain files + dirs; symlinks / special files are skipped.
sub copy_tree {
    my ($src, $dst) = @_;
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
        my $stale = "$dest_root/$e->{dest_rel}";
        remove_tree($stale, { safe => 1 }) if -e $stale;
        prune_empty_parents($dest_root, $e->{dest_rel});
    }
    # 2. (re)copy the current host-tier set, host authoritative.
    for my $e (@$new) {
        next unless ref $e eq 'HASH' && defined $e->{src} && defined $e->{dest_rel};
        my $src = $winify->($e->{src});
        next unless -d $src;
        my $dst = "$dest_root/$e->{dest_rel}";
        remove_tree($dst, { safe => 1 }) if -e $dst;   # clean refresh (host wins)
        copy_tree($src, $dst);
    }
}

1;
