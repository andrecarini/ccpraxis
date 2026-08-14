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
use File::Path qw(make_path);
use File::Find qw(finddepth);
use JSON::PP;
use Exporter qw(import);

our @EXPORT_OK = qw(copy_tree prune_empty_parents reconcile_copy_plan safe_dest_rel read_copy_plan prune_orphaned_dirs remove_named_legacy_dirs);

# read_copy_plan($path) -> arrayref of {src, dest_rel, ...} — the launcher's
# copy-plan manifest, which skills.pl writes with ->utf8->encode. Missing /
# unparseable -> [] (treated as "the launcher placed nothing last launch").
#
# The decode MUST be UTF-8-aware. Each `src` is a host plugin path embedding the
# user's home dir, which can contain non-ASCII bytes (e.g. ".../Users/André/...").
# Because the manifest is UTF-8 on disk, a plain ->decode would read each UTF-8
# byte as its own Latin-1 char ("André" -> "AndrÃ©"); the mangled src then fails
# EVERY `-d $src` test in reconcile_copy_plan, so it silently copies NOTHING.
# That is the exact bug that left selected host plugins (e.g. notion) "active but
# not installed" inside the sandbox — the registry listed them but their code
# never got copied. ASCII dest_rels are unaffected, so this is decode-only.
sub read_copy_plan {
    my $path = shift;
    return [] unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return [];
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return [] unless defined $bytes && length $bytes;
    my $data = eval { JSON::PP->new->utf8->decode($bytes) };
    return (ref $data eq 'ARRAY') ? $data : [];
}

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

# _force_remove_tree($path) — delete a file/dir tree even when it holds
# READ-ONLY files. remove_tree's { safe => 1 } refuses to chmod, so it cannot
# unlink read-only entries (Windows marks git object/pack files read-only) and
# leaves the parent "Directory not empty" — the marketplace reconcile hit this
# refreshing a github-source marketplace whose copied tree includes a .git/
# object store. We walk depth-first (children before parents), clearing the
# read-only bit before each unlink/rmdir. SYMLINKS are unlinked, never followed
# or chmod'd THROUGH (claude-home/plugins is container-writable; _safe_parents
# already barred a symlinked PARENT, and this bars a symlinked entry INSIDE the
# tree — File::Find does not descend symlinks by default).
sub _force_remove_tree {
    my $path = shift;
    return unless -e $path || -l $path;
    if (-l $path) { unlink $path; return; }      # top-level leaf link
    finddepth({ no_chdir => 1, wanted => sub {
        my $p = $File::Find::name;
        if (-l $p) { unlink $p; return; }        # never chmod/recurse THROUGH a link
        chmod 0700, $p;                          # clear read-only (git packs) — best effort
        if (-d $p) { rmdir $p } else { unlink $p }
    }}, $path);
    rmdir $path if -d $path && !-l $path;         # belt-and-suspenders (finddepth visits root last)
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
        elsif (-e $stale) { _force_remove_tree($stale); }    # handles read-only git packs
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
        elsif (-e $dst) { _force_remove_tree($dst); }        # clean refresh (host wins); read-only-safe
        copy_tree($src, $dst);
    }
}

# _subtree_has_file($path) -> 1 iff $path (a directory) contains at least one
# regular file anywhere in its subtree, however deep. Symlinks encountered
# during the walk are never followed (File::Find's default: it does not
# descend into a symlinked directory) and never counted as a "regular file"
# themselves (-f on a symlink to a file would still be true, but we exclude
# it deliberately -- content ownership here means real bytes this repo/its
# operator wrote, not a dangling or redirecting link).
sub _subtree_has_file {
    my $path = shift;
    my $found = 0;
    finddepth({ no_chdir => 1, wanted => sub {
        my $p = $File::Find::name;
        return if $found;
        return if -l $p;                 # never count/follow a symlink
        $found = 1 if -f $p;
    }}, $path);
    return $found;
}

# prune_orphaned_dirs($dest_root, $keep_names) -> list of { name, removed }
#   $dest_root  : directory to scan (immediate children only -- skills are
#                 always flat).
#   $keep_names : arrayref of names selected THIS launch; never
#                 inspected/touched -- not even to check emptiness.
#
# spec.md §2.3 / §0's operator ruling: an unowned, CONTENT-BEARING directory
# is warned about, never deleted -- by this function, unconditionally, both
# for the standing per-launch reconcile AND for the one-time legacy pass the
# launcher gates on manifest absence. Only a directory holding literally zero
# regular files anywhere in its subtree is safe to remove outright (it holds
# no data to lose). The caller (launcher.pl) decides whether/when to invoke
# this at all; this function itself has no notion of "once" and is safe to
# call repeatedly -- idempotent (a removed dir won't exist to remove again; a
# kept or non-empty dir is left untouched every time).
sub prune_orphaned_dirs {
    my ($dest_root, $keep_names) = @_;
    return () unless defined $dest_root && -d $dest_root && !-l $dest_root;
    my %keep = map { $_ => 1 } @{ $keep_names || [] };

    my @results;
    opendir(my $dh, $dest_root) or return ();
    my @kids = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;

    for my $name (@kids) {
        next if $keep{$name};             # selected this launch -- never inspected, never touched
        my $path = "$dest_root/$name";
        next if -l $path;                 # symlink: skipped entirely, never reported
        next unless -d $path;             # non-directory: skipped entirely, never reported

        if (_subtree_has_file($path)) {
            push @results, { name => $name, removed => 0 };
        } else {
            _force_remove_tree($path);
            push @results, { name => $name, removed => 1 };
        }
    }
    return @results;
}

# remove_named_legacy_dirs($dest_root, $names, $keep_names) -> list of
# { name, removed => 1 } — one entry per name in $names that was actually
# removed.
#
# THIS IS NOT A GENERAL-PURPOSE "delete content-bearing dirs" primitive, and
# must never be called with a computed/predicate-derived list. It exists for
# exactly one purpose: p01-sandbox-plugin-provisioning's operator-authorised,
# ONE-TIME removal of the two named pre-manifest legacy skill specimens
# (`plan`, `work-plan`) that predate any host-tier manifest and therefore have
# no provenance record `prune_orphaned_dirs`'s standing (permanent) policy can
# use to justify auto-removing content it can't prove it owns. The caller
# (launcher.pl's one-time gate, itself already scoped to fire on exactly one
# launch) is responsible for BOTH the "once" semantics AND for hard-coding the
# exact two names authorised by the operator — this function only executes
# whatever explicit list it is handed; it applies NO heuristic of its own
# (unlike prune_orphaned_dirs's empty-vs-content-bearing test) and is
# deliberately dumber than that function so it cannot silently grow scope.
#
#   $dest_root  : directory to scan (immediate children only).
#   $names      : arrayref of EXACT directory names authorised for removal —
#                 the caller must name them explicitly (e.g. ['plan',
#                 'work-plan']), never compute this list from disk contents.
#   $keep_names : arrayref of names selected THIS launch; a currently-selected
#                 name is NEVER removed even if it appears in $names (mirrors
#                 prune_orphaned_dirs's keep discipline) — an operator
#                 re-selecting something literally named "plan" today must not
#                 be at risk from this one-time pass.
#
# A name in $names that doesn't exist, is a symlink, or is not a directory is
# silently skipped (not reported) — this function only reports what it
# actually removed, same discipline as prune_orphaned_dirs.
sub remove_named_legacy_dirs {
    my ($dest_root, $names, $keep_names) = @_;
    return () unless defined $dest_root && -d $dest_root && !-l $dest_root;
    my %keep = map { $_ => 1 } @{ $keep_names || [] };

    my @results;
    for my $name (@{ $names || [] }) {
        next if $keep{$name};              # currently selected -- never touched
        my $path = "$dest_root/$name";
        next if -l $path;                  # symlink: never removed by this pass
        next unless -d $path;              # not a directory: never removed by this pass
        _force_remove_tree($path);
        push @results, { name => $name, removed => 1 };
    }
    return @results;
}

1;
