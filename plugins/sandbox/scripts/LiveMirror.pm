package LiveMirror;
# LiveMirror.pm -- the macOS sandbox's copy of the live install: the part of it
# that containers mount (plugins/, skills/, scripts/statusline.pl), kept equal
# to the source by refresh(). The podman machine shares this copy, never the
# live install.
#
# WHY. On applehv the machine's "ro" shares are writable from inside the VM
# (measured: podman 6.1.4 records the flag, vfkit 0.6.4 has no read-only
# virtio-fs share). With the live install shared, a process that escaped a
# container into the VM could rewrite hooks, scripts/statusline.pl and
# .git/hooks, all of which later run on the Mac. Operator decision 2026-10-30:
# share a COPY of exactly what containers mount. The Mac never runs anything
# from it; the VM may scribble on it, and the next refresh puts it back.
#
# WHERE. mirror_dir(): ~/.cache/ccpraxis/live-mirror for the live install at
# ~/.claude/ccpraxis. A launcher running from any other install root (a fork's
# checkout, a dev clone run by path) gets ~/.cache/ccpraxis/live-mirror-<8 hex
# of that root>, so it never puts its own code into the copy the live install's
# sandboxes read. ~/.cache/ccpraxis itself is never shared, so the VM cannot
# replace the mirror directory, only what is inside it.
#
# WHO REFRESHES. launcher.pl before each container create and before each
# start; scripts/promote.pl after it fast-forwards the live install, so a
# promotion reaches running sandboxes without a relaunch, as it did when they
# bound the live install directly. PodmanMachine.pm puts the mirror in the
# machine's share list in place of the live install.
#
# HOW, AND WHY THIS WAY.
#   * In place, file by file. Directories keep their inodes: a running
#     container's bind of plugins/ or skills/<name> holds the directory, so a
#     whole new tree swapped in by rename would leave running sandboxes on the
#     old one. Each file is written under a temporary name and renamed over the
#     old one, so no reader ever sees a truncated file. While a refresh runs, a
#     reader can see some files new and some old -- exactly what the git
#     checkout that updates the live install itself has always shown them.
#     New and changed entries are written before stale ones are removed.
#   * The mirror is treated as hostile, because the VM can write it. Nothing
#     inside it is followed: each directory is entered with fchdir on a handle
#     whose device and inode match an lstat of the name, and every write is a
#     relative name in that directory -- a temp file opened O_CREAT|O_EXCL|
#     O_NOFOLLOW, then rename(), which replaces a planted symlink rather than
#     writing through it. A mirror file is read for comparison only through
#     O_NOFOLLOW|O_NONBLOCK and an fstat check, so a planted FIFO cannot hang a
#     launch. Without this, a symlink planted in the mirror would turn the
#     Mac's own refresh into the write path the copy exists to remove.
#   * Compared by content (size first), never by mtime, so a file rewritten
#     within the same second, or edited in the mirror, is still put right.
#   * One refresh at a time: flock on <mirror>.lock, a sibling in the unshared
#     parent. Without it, one refresh would delete another's temp files.
#   * Symlinks in the source are copied as symlinks with the same target text,
#     which is what a bind mount of the source showed the container. Modes are
#     copied (permission bits). A .git anywhere is never copied.
#
# Core modules only, and nothing from the rest of the sandbox, so
# scripts/promote.pl can load it without the launcher's dependencies.
use strict;
use warnings;
use Cwd ();
use Digest::SHA ();
use File::Path ();
use Fcntl qw(O_RDONLY O_WRONLY O_RDWR O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK LOCK_EX LOCK_NB);

# What containers mount from an install root, relative to it. launcher.pl binds
# plugins/ (the ccpraxis-local marketplace, and the backpack scripts and hook
# inside it), skills/<name> (the picker's selection) and scripts/statusline.pl.
our @PATHS = ('plugins', 'skills', 'scripts/statusline.pl');

# Temporary names refresh() writes before renaming. Never copied from a source.
our $TMP_PREFIX = '.ccpraxis-mirror-tmp-';

# Deepest directory refresh() will enter; past it the tree is refused.
our $MAX_DEPTH = 64;

# mirror_dir(home => $h, install_root => $r, os => $os) -> the mirror for that
# install root, or undef off darwin. Without install_root, the live install's.
sub mirror_dir {
    my (%o) = @_;
    my $os = defined $o{os} ? $o{os} : $^O;
    return undef unless $os eq 'darwin';
    my $home = $o{home};
    return undef unless defined $home && !ref $home && length $home;
    $home =~ s{/+\z}{} unless $home eq '/';
    my $base = "$home/.cache/ccpraxis/live-mirror";
    my $root = $o{install_root};
    return $base unless defined $root && !ref $root && length $root;
    my $key = _canon($root);
    return $base if $key eq _canon("$home/.claude/ccpraxis");
    return "$base-" . substr(Digest::SHA::sha1_hex($key), 0, 8);
}

# _canon($path) -> a comparison key: symlinks resolved where the path exists,
# no trailing slash, case folded (APFS is case-insensitive, and abs_path keeps
# the case it was given).
sub _canon {
    my ($p) = @_;
    my $abs = -e $p ? Cwd::abs_path($p) : undef;
    $p = $abs if defined $abs && length $abs;
    $p =~ s{/+\z}{} unless $p eq '/';
    return lc $p;
}

# mirror_path($path, $install_root, $mirror) -> where the mirror holds $path:
# "$mirror/<rel>" when $path is one of @PATHS under $install_root or lies
# inside one, else $path unchanged. The prefix is compared case-insensitively
# on darwin, the only host with a mirror.
sub mirror_path {
    my ($path, $root, $mirror) = @_;
    return $path unless defined $path && defined $root && length $root && defined $mirror && length $mirror;
    (my $r = $root) =~ s{/+\z}{};
    (my $m = $mirror) =~ s{/+\z}{};
    my $fold = $^O eq 'darwin';
    for my $rel (@PATHS) {
        my $base = "$r/$rel";
        my $n = length $base;
        next if length($path) < $n;
        my $head = substr($path, 0, $n);
        next unless $fold ? lc($head) eq lc($base) : $head eq $base;
        my $rest = substr($path, $n);
        next unless $rest eq '' || $rest =~ m{\A/};
        return "$m/$rel$rest";
    }
    return $path;
}

# _filter() -> what refresh() copies from an install root: name -> undef
# (everything below it) or a nested filter, built from @PATHS.
sub _filter {
    my %f;
    for my $rel (@PATHS) {
        my @parts = split m{/}, $rel;
        my $node = \%f;
        while (@parts > 1) {
            my $p = shift @parts;
            $node->{$p} = {} unless ref $node->{$p} eq 'HASH';
            $node = $node->{$p};
        }
        $node->{ $parts[0] } = undef;
    }
    return \%f;
}

# refresh(source => $install_root, mirror => $dir, create => 0|1,
#         lock_timeout => $secs) -> { ok, updated, removed, error }
# Makes $dir hold exactly @PATHS of $source. `create` makes $dir when it is
# missing (its parent must exist); without it a missing $dir is an error.
# `updated` counts files and symlinks written, `removed` the entries deleted.
# Never dies; on failure `error` says why and the mirror keeps whatever whole
# files it had.
sub refresh {
    my (%o) = @_;
    my ($src, $dst) = @o{qw(source mirror)};
    my $res = { ok => 0, updated => 0, removed => 0, error => undef };
    my $fail = sub { $res->{error} = $_[0]; return $res };
    return $fail->('no source directory given') unless defined $src && length $src;
    $src =~ s{/+\z}{};
    return $fail->("the source $src is not a directory") unless -d $src;
    return $fail->('no mirror directory given') unless defined $dst && $dst =~ m{\A/};
    $dst =~ s{/+\z}{};
    return $fail->('the mirror cannot be the source or inside it')
        if _canon($dst) eq _canon($src) || index(_canon($dst) . '/', _canon($src) . '/') == 0;

    my @st = lstat $dst;
    if (!@st) {
        return $fail->("$dst does not exist") unless $o{create};
        (my $parent = $dst) =~ s{/[^/]+\z}{};
        eval { File::Path::make_path($parent) if length $parent && !-d $parent; 1 };
        mkdir($dst, 0755) or return $fail->("cannot create $dst: $!");
        @st = lstat $dst;
    }
    return $fail->("$dst is not a directory (a symlink or a file is refused)") unless @st && -d _;
    return $fail->("$dst is not owned by this user") unless $st[4] == $>;

    my $lockf = "$dst.lock";
    my $lk;
    sysopen($lk, $lockf, O_RDWR | O_CREAT | O_NOFOLLOW, 0600)
        or return $fail->("cannot open the lock $lockf: $!");
    my $wait = defined $o{lock_timeout} ? $o{lock_timeout} : 30;
    my $deadline = time + $wait;
    until (flock($lk, LOCK_EX | LOCK_NB)) {
        if (time >= $deadline) {
            close $lk;
            return $fail->("another refresh of $dst held its lock for ${wait}s");
        }
        select(undef, undef, undef, 0.1);
    }

    # The walk moves the working directory; put it back however it ends.
    my $back_dh;
    undef $back_dh unless opendir($back_dh, '.');
    my $back_path = Cwd::getcwd();
    my $ctx = { res => $res, seq => 0 };
    my $ok = eval {
        opendir(my $dh, $dst) or die "cannot open $dst: $!\n";
        chdir($dh) or die "cannot enter $dst: $!\n";
        die "$dst was replaced while it was being opened\n" unless _same_inode('.', \@st);
        _sync_dir($ctx, $src, _filter(), $dh, '', 0);
        1;
    };
    my $err = $@;
    if ($back_dh) { chdir($back_dh) or (defined $back_path && chdir($back_path)) }
    elsif (defined $back_path) { chdir($back_path) }
    close $lk;
    unless ($ok) {
        $err = 'refresh failed' unless defined $err && length $err;
        chomp $err;
        return $fail->($err);
    }
    $res->{ok} = 1;
    return $res;
}

sub _same_inode {
    my ($path, $st) = @_;
    my @s = stat $path;
    return @s && $s[0] == $st->[0] && $s[1] == $st->[1];
}

sub _label { my ($rel, $name) = @_; return length $rel ? "$rel/$name" : $name }

sub _tmp_name { my ($ctx) = @_; return $TMP_PREFIX . $$ . '-' . (++$ctx->{seq}) }

# _sync_dir($ctx, $src_dir, $filter, $here_dh, $rel, $depth) -- the working
# directory is the mirror directory for $src_dir (held by $here_dh); make it
# hold exactly what $filter selects from $src_dir.
sub _sync_dir {
    my ($ctx, $sdir, $filter, $here, $rel, $depth) = @_;
    die "the tree is deeper than $MAX_DEPTH directories at $rel\n" if $depth > $MAX_DEPTH;
    opendir(my $sh, $sdir) or die "cannot read $sdir: $!\n";
    my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir $sh;
    closedir $sh;
    my %want;
    for my $name (@names) {
        next if $name eq '.git' || index($name, $TMP_PREFIX) == 0;
        next if defined $filter && !exists $filter->{$name};
        my $sub = defined $filter ? $filter->{$name} : undef;
        my $spath = "$sdir/$name";
        my @s = lstat $spath;
        next unless @s;
        my $label = _label($rel, $name);
        if (-l _) {
            my $target = readlink $spath;
            die "cannot read the symlink $spath: $!\n" unless defined $target;
            next if defined $sub;   # only a whole subtree may be a symlink
            $want{$name} = 1;
            _sync_symlink($ctx, $name, $target, $here, $label, $depth);
        } elsif (-d _) {
            # A filtered directory is copied only for what it holds that is
            # wanted (scripts/ for statusline.pl), never as an empty shell.
            next if defined $sub && !grep { -e "$spath/$_" || -l "$spath/$_" } keys %$sub;
            $want{$name} = 1;
            my $dh = _enter_dir($ctx, $name, $s[2] & 07777, $here, $label, $depth);
            _sync_dir($ctx, $spath, $sub, $dh, $label, $depth + 1);
            chdir($here) or die "cannot return from $label: $!\n";
            closedir $dh;
        } elsif (-f _) {
            next if defined $sub;
            $want{$name} = 1;
            _sync_file($ctx, $name, $spath, \@s, $here, $label, $depth);
        }
        # Sockets, FIFOs and devices are not copied: no bind of the live
        # install ever carried one, and a copy could not reproduce it.
    }
    rewinddir $here;
    my @have = grep { $_ ne '.' && $_ ne '..' } readdir $here;
    for my $name (sort @have) {
        next if $want{$name};
        _remove_entry($ctx, $name, $here, _label($rel, $name), $depth);
        $ctx->{res}{removed}++;
    }
}

# _enter_dir(...) -> a handle on the mirror directory $name (created when
# missing, replacing a non-directory) after making it the working directory
# and checking it is the directory lstat saw. Its mode is set to $mode.
sub _enter_dir {
    my ($ctx, $name, $mode, $here, $label, $depth) = @_;
    my @m = lstat $name;
    if (@m && !-d _) {
        unlink($name) or die "cannot remove $label (not a directory): $!\n";
        @m = ();
    }
    unless (@m) {
        mkdir($name, 0700) or die "cannot create $label: $!\n";
        @m = lstat $name;
        die "$label vanished after it was created\n" unless @m && -d _;
    }
    opendir(my $dh, $name) or die "cannot open $label: $!\n";
    chdir($dh) or die "cannot enter $label: $!\n";
    unless (_same_inode('.', \@m)) {
        chdir($here);
        die "$label was replaced while it was being entered\n";
    }
    my @now = stat '.';
    chmod($mode, '.') or die "cannot set the mode of $label: $!\n"
        if @now && ($now[2] & 07777) != $mode;
    return $dh;
}

sub _sync_file {
    my ($ctx, $name, $spath, $s, $here, $label, $depth) = @_;
    my $mode = $s->[2] & 07777;
    my @m = lstat $name;
    if (@m && -f _ && $m[7] == $s->[7] && ($m[2] & 07777) == $mode) {
        return if _same_content($name, \@m, $spath, $label);
    }
    my $tmp = _tmp_name($ctx);
    open(my $in, '<:raw', $spath) or die "cannot read $spath: $!\n";
    my $out;
    sysopen($out, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
        or die "cannot create a temporary file next to $label: $!\n";
    binmode $out;
    my $ok = eval {
        my $buf;
        while (1) {
            my $n = sysread($in, $buf, 65536);
            die "cannot read $spath: $!\n" unless defined $n;
            last if $n == 0;
            my $off = 0;
            while ($off < $n) {
                my $w = syswrite($out, $buf, $n - $off, $off);
                die "cannot write $label: $!\n" unless defined $w;
                $off += $w;
            }
        }
        chmod($mode, $out) or die "cannot set the mode of $label: $!\n";
        utime($s->[8], $s->[9], $out);   # best effort: the content is what matters
        close($out) or die "cannot write $label: $!\n";
        1;
    };
    my $err = $@;
    close $in;
    unless ($ok) { close $out; unlink $tmp; die $err }
    _put($ctx, $tmp, $name, $here, $label, $depth);
}

sub _sync_symlink {
    my ($ctx, $name, $target, $here, $label, $depth) = @_;
    my @m = lstat $name;
    if (@m && -l _) {
        my $cur = readlink $name;
        return if defined $cur && $cur eq $target;
    }
    my $tmp = _tmp_name($ctx);
    symlink($target, $tmp) or die "cannot create the symlink $label: $!\n";
    _put($ctx, $tmp, $name, $here, $label, $depth);
}

# _put(...) -- rename the finished temp entry over $name. rename() replaces a
# file or symlink in one step; a directory in the way (the source changed a
# directory into a file, or the VM planted one) is removed first.
sub _put {
    my ($ctx, $tmp, $name, $here, $label, $depth) = @_;
    unless (rename($tmp, $name)) {
        my $e = $!;
        my @m = lstat $name;
        unless (@m && -d _) { unlink $tmp; die "cannot replace $label: $e\n" }
        eval { _remove_entry($ctx, $name, $here, $label, $depth); 1 } or do { my $x = $@; unlink $tmp; die $x };
        unless (rename($tmp, $name)) { my $e2 = $!; unlink $tmp; die "cannot replace $label: $e2\n" }
    }
    $ctx->{res}{updated}++;
}

# _same_content($name, \@lstat, $spath, $label) -> 1 when the mirror file holds
# exactly the source's bytes. The mirror side is opened without following a
# symlink or blocking on a FIFO, and must still be the file lstat saw.
sub _same_content {
    my ($name, $m, $spath, $label) = @_;
    my $mh;
    sysopen($mh, $name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or return 0;
    my @f = stat $mh;
    unless (@f && -f _ && $f[0] == $m->[0] && $f[1] == $m->[1]) { close $mh; return 0 }
    open(my $sh, '<:raw', $spath) or do { close $mh; die "cannot read $spath: $!\n" };
    binmode $mh;
    my $same = 1;
    while (1) {
        my ($a, $b);
        my $na = sysread($sh, $a, 65536);
        my $nb = sysread($mh, $b, 65536);
        if (!defined $na) { close $mh; close $sh; die "cannot read $spath: $!\n" }
        if (!defined $nb || $na != $nb || ($na && $a ne $b)) { $same = 0; last }
        last if $na == 0;
    }
    close $mh;
    close $sh;
    return $same;
}

# _remove_entry($ctx, $name, $here_dh, $label, $depth) -- delete $name from the
# working directory: unlink a file or symlink (never what it points at); empty
# a real directory from inside it, entered the same checked way, then rmdir it.
sub _remove_entry {
    my ($ctx, $name, $here, $label, $depth) = @_;
    my @m = lstat $name;
    return unless @m;
    unless (-d _) {
        unlink($name) or $!{ENOENT} or die "cannot remove $label: $!\n";
        return;
    }
    die "the tree is deeper than $MAX_DEPTH directories at $label\n" if $depth > $MAX_DEPTH;
    opendir(my $dh, $name) or die "cannot open $label: $!\n";
    chdir($dh) or die "cannot enter $label: $!\n";
    unless (_same_inode('.', \@m)) {
        chdir($here);
        die "$label was replaced while it was being removed\n";
    }
    my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    for my $k (@kids) {
        _remove_entry($ctx, $k, $dh, "$label/$k", $depth + 1);
    }
    chdir($here) or die "cannot return from $label: $!\n";
    closedir $dh;
    rmdir($name) or $!{ENOENT} or die "cannot remove $label: $!\n";
}

1;
