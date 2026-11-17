#!/usr/bin/env perl
# platform: any
# LiveMirror.pm: on macOS the podman machine shares a COPY of what containers
# mount from the install root (plugins/, skills/, scripts/statusline.pl), never
# the live install, because the VM can write an "ro" share and the Mac runs
# the live install's code. Nothing here needs a container runtime or a VM.
#
#   A. mirror_dir: ~/.cache/ccpraxis/live-mirror for the live install, a keyed
#      sibling for any other install root (a fork's, a clone's), undef off darwin.
#   B. mirror_path + MountSpec::map_bind_sources: which bind sources move to
#      the mirror (and that nothing else does).
#   C. refresh: the mirror equals the allowed part of the source -- add,
#      modify (same size and mtime too), delete, modes, symlinks, type changes;
#      nothing outside the allowed paths and no .git; directories updated in
#      place (a running container's bind keeps its directory); no temp files.
#   D. refresh treats the mirror as hostile (the VM can write it): a planted
#      symlink is replaced, never written through; a planted FIFO does not hang
#      it; planted extras are removed without following their links; a mirror
#      that is itself a symlink is refused.
#   E. one refresh at a time (lock), the working directory is restored, and the
#      mirror can never be the source or inside it.
#   F. the launcher, by source text (it is never run): binds from the mirror on
#      darwin and from the install root elsewhere, refreshes it before create
#      and start (the [l] recover flow too), and the preflight checks the
#      mirror except for a connector; every bind it would emit is served by the
#      shares PodmanMachine plans.
#   D2-D4. the VM cannot stop the refresh; case-only renames on APFS;
#      complete(), the launcher's gate before podman create.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use Cwd ();
use POSIX ();
use Digest::SHA ();

plan skip_all => 'the live-install mirror is macOS machinery; its POSIX file semantics (fchdir, O_NOFOLLOW, symlinks, FIFOs) are not representative under MSYS'
    if $^O =~ /^(MSWin32|cygwin|msys)$/;

use LiveMirror ();
use MountSpec ();
use HostPlatform ();
use PodmanMachine ();

sub spew { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "write $p: $!"; print {$fh} $c; close $fh }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $c = <$fh>; close $fh; $c }

# tree($root, $filter) -> { rel => description } of everything under $root
# (lstat, never following a link). $filter, when given, is LiveMirror's own
# @PATHS reproduced independently: only those subtrees of the source count.
sub tree {
    my ($root, %o) = @_;
    my %t;
    my $walk;
    $walk = sub {
        my ($dir, $rel) = @_;
        opendir(my $dh, $dir) or die "opendir $dir: $!";
        for my $n (sort grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
            my $r = length $rel ? "$rel/$n" : $n;
            next if $o{source} && !_allowed($r);
            my @s = lstat "$dir/$n";
            if (-l _) { $t{$r} = 'l:' . readlink("$dir/$n") }
            elsif (-d _) { $t{$r} = sprintf('d:%o', $s[2] & 07777); $walk->("$dir/$n", $r) }
            elsif (-f _) { $t{$r} = sprintf('f:%o:', $s[2] & 07777) . Digest::SHA::sha1_hex(slurp("$dir/$n")) }
            else { $t{$r} = 'other' }
        }
        closedir $dh;
    };
    $walk->($root, '');
    return \%t;
}
sub _allowed {
    my ($r) = @_;
    return 0 if grep { $_ eq '.git' } split m{/}, $r;
    return 1 if $r =~ m{\A(?:plugins|skills)(?:/|\z)};
    return 1 if $r eq 'scripts' || $r eq 'scripts/statusline.pl';
    return 0;
}

# A fake install root: what containers mount, plus what they must never get.
sub fake_install {
    my $root = Cwd::abs_path(tempdir(CLEANUP => 1)) . '/install';
    make_path("$root/plugins/a/sub", "$root/plugins/.claude-plugin", "$root/skills/s1", "$root/scripts",
              "$root/docs", "$root/.git/hooks", "$root/plugins/a/.git");
    spew("$root/plugins/.claude-plugin/marketplace.json", "{}\n");
    spew("$root/plugins/a/x.pl", "#!/usr/bin/perl\nprint 1;\n"); chmod 0755, "$root/plugins/a/x.pl";
    spew("$root/plugins/a/y.txt", "plain\n");                    chmod 0644, "$root/plugins/a/y.txt";
    spew("$root/plugins/a/sub/z.md", "deep\n");
    spew("$root/plugins/a/empty", '');
    spew("$root/plugins/a/.git/config", "[core]\n");             # a nested .git is never copied
    symlink('x.pl', "$root/plugins/a/link") or die "symlink: $!";
    symlink('/nonexistent/abs/target', "$root/plugins/a/abs") or die "symlink: $!";
    spew("$root/skills/s1/SKILL.md", "---\nname: s1\n---\n");
    spew("$root/scripts/statusline.pl", "#!/usr/bin/perl\n");    chmod 0755, "$root/scripts/statusline.pl";
    spew("$root/scripts/promote.pl", "not mounted\n");
    spew("$root/docs/README.md", "not mounted\n");
    spew("$root/.git/hooks/pre-commit", "#!/bin/sh\n");          chmod 0755, "$root/.git/hooks/pre-commit";
    spew("$root/README.md", "not mounted\n");
    return $root;
}

sub new_mirror { return Cwd::abs_path(tempdir(CLEANUP => 1)) . '/live-mirror' }

sub refresh_ok {
    my ($src, $dst, $what, %o) = @_;
    my $r = LiveMirror::refresh(source => $src, mirror => $dst, create => 1, %o);
    ok($r->{ok}, "$what: refresh succeeds") or diag($r->{error});
    return $r;
}

# ---------------------------------------------------------------------------
# A. mirror_dir
# ---------------------------------------------------------------------------
{
    is(LiveMirror::mirror_dir(os => 'darwin', home => '/Users/u'), '/Users/u/.cache/ccpraxis/live-mirror',
        'A: the live install\'s mirror is ~/.cache/ccpraxis/live-mirror');
    is(LiveMirror::mirror_dir(os => 'darwin', home => '/Users/u/', install_root => '/Users/u/.claude/ccpraxis/'),
        '/Users/u/.cache/ccpraxis/live-mirror', 'A: ...also when the live install is named explicitly');
    is(LiveMirror::mirror_dir(os => 'darwin', home => '/Users/u', install_root => '/USERS/u/.Claude/ccpraxis'),
        '/Users/u/.cache/ccpraxis/live-mirror', 'A: ...compared case-insensitively (APFS)');
    my $fork = LiveMirror::mirror_dir(os => 'darwin', home => '/Users/u', install_root => '/Users/u/Projects/fork');
    my $hex  = substr(Digest::SHA::sha1_hex('/users/u/projects/fork'), 0, 8);
    is($fork, "/Users/u/.cache/ccpraxis/live-mirror-$hex",
        'A: another install root (a fork, a clone run by path) gets its own mirror, keyed by its path');
    isnt($fork, LiveMirror::mirror_dir(os => 'darwin', home => '/Users/u', install_root => '/Users/u/Projects/fork2'),
        'A: ...and two of them do not share one');
    for my $os (qw(linux cygwin msys MSWin32)) {
        ok(!defined LiveMirror::mirror_dir(os => $os, home => '/Users/u'), "A: no mirror on $os (the install root is bound in place)");
    }
    is(PodmanMachine::layout(home => '/Users/u')->{live_mirror}, '/Users/u/.cache/ccpraxis/live-mirror',
        'A: PodmanMachine\'s layout names the same folder');
}

# ---------------------------------------------------------------------------
# B. which bind sources move to the mirror
# ---------------------------------------------------------------------------
{
    my ($R, $M) = ('/Users/u/.claude/ccpraxis', '/Users/u/.cache/ccpraxis/live-mirror');
    my %cases = (
        "$R/plugins"                                 => "$M/plugins",
        "$R/plugins/backpack/scripts/backpack.pl"    => "$M/plugins/backpack/scripts/backpack.pl",
        "$R/plugins/backpack/hooks/auto-declare.pl"  => "$M/plugins/backpack/hooks/auto-declare.pl",
        "$R/skills/s1"                               => "$M/skills/s1",
        "$R/scripts/statusline.pl"                   => "$M/scripts/statusline.pl",
        "$R/scripts/promote.pl"                      => "$R/scripts/promote.pl",
        "$R/docs"                                    => "$R/docs",
        "$R"                                         => "$R",
        "$R/plugins2"                                => "$R/plugins2",
        "$R/.git/hooks"                              => "$R/.git/hooks",
        '/Users/u/Projects/app'                      => '/Users/u/Projects/app',
    );
    for my $p (sort keys %cases) {
        is(LiveMirror::mirror_path($p, $R, $M), $cases{$p}, "B: mirror_path $p");
    }
    is(LiveMirror::mirror_path("$R/plugins/x", "$R/", "$M/"), "$M/plugins/x", 'B: trailing slashes on the roots do not matter');
    is(LiveMirror::mirror_path("$R/plugins/x", $R, undef), "$R/plugins/x", 'B: no mirror: unchanged');

    my @in = ('create', '-e', 'A=B', '-v', '/h/src:/c/dst:ro', '-v', 'named-vol:/c/vol', '-v', '/h/rw:/c/rw',
              '-v', 'C:/win/path:/c/w:ro', '--name', 'x', 'image:tag');
    is_deeply([MountSpec::map_bind_sources(sub { "/NEW$_[0]" }, @in)],
        ['create', '-e', 'A=B', '-v', '/NEW/h/src:/c/dst:ro', '-v', 'named-vol:/c/vol', '-v', '/NEW/h/rw:/c/rw',
         '-v', '/NEWC:/win/path:/c/w:ro', '--name', 'x', 'image:tag'],
        'B: map_bind_sources rewrites every bind source, keeps targets and options, leaves volumes and other args alone');
    is_deeply([MountSpec::map_bind_sources(sub { $_[0] }, @in)], \@in, 'B: ...and an identity map changes nothing');
    is(MountSpec::v_to_mount('C:/Users/x:/c/w:ro'), 'type=bind,source=C:/Users/x,target=/c/w,readonly',
        'B: v_to_mount still splits a drive-letter source at the right colon');
    is(MountSpec::v_to_mount('vol:/c/v'), 'type=volume,source=vol,target=/c/v', 'B: ...and a bare name is still a volume');
}

# ---------------------------------------------------------------------------
# C. refresh: the mirror equals the allowed part of the source
# ---------------------------------------------------------------------------
{
    my $src = fake_install();
    my $dst = new_mirror();
    my $r = refresh_ok($src, $dst, 'C (first)');
    ok($r->{updated} > 0, 'C: the first refresh writes the files');
    is_deeply(tree($dst), tree($src, source => 1),
        'C: the mirror holds exactly plugins/, skills/ and scripts/statusline.pl, with their modes and symlinks');
    ok(!-e "$dst/.git" && !-e "$dst/plugins/a/.git", 'C: no .git, at the top or nested');
    ok(!-e "$dst/docs" && !-e "$dst/README.md" && !-e "$dst/scripts/promote.pl", 'C: nothing outside the mounted paths');
    is(readlink("$dst/plugins/a/link"), 'x.pl', 'C: a relative symlink is copied as a symlink with the same target');
    is(readlink("$dst/plugins/a/abs"), '/nonexistent/abs/target', 'C: ...and so is an absolute one (what a bind showed)');
    is(sprintf('%o', (stat "$dst/plugins/a/x.pl")[2] & 07777), '755', 'C: an executable stays executable');

    my @ino = map { (stat $_)[1] } "$dst/plugins", "$dst/plugins/a", "$dst/skills/s1";
    $r = refresh_ok($src, $dst, 'C (unchanged)');
    is_deeply([$r->{updated}, $r->{removed}], [0, 0], 'C: an unchanged source writes and removes nothing');

    # Same size, same mtime, different bytes: only a content compare sees it.
    my $mt = (stat "$src/plugins/a/y.txt")[9];
    spew("$src/plugins/a/y.txt", "PLAIN\n");
    utime($mt, $mt, "$src/plugins/a/y.txt");
    spew("$src/plugins/a/new.pl", "new\n");
    unlink "$src/plugins/a/sub/z.md";
    remove_tree("$src/skills/s1");
    make_path("$src/skills/s2");
    spew("$src/skills/s2/SKILL.md", "s2\n");
    chmod 0600, "$src/plugins/.claude-plugin/marketplace.json";
    unlink "$src/plugins/a/link";
    symlink('y.txt', "$src/plugins/a/link");
    # type changes both ways: a file becomes a directory, a directory a file
    unlink "$src/plugins/a/empty";
    make_path("$src/plugins/a/empty");
    spew("$src/plugins/a/empty/inside", "now a dir\n");
    remove_tree("$src/plugins/a/sub");
    spew("$src/plugins/a/sub", "now a file\n");
    $r = refresh_ok($src, $dst, 'C (changed)');
    is_deeply(tree($dst), tree($src, source => 1), 'C: additions, edits, deletions, a mode, a retargeted link and type changes all reach the mirror');
    is(slurp("$dst/plugins/a/y.txt"), "PLAIN\n", 'C: a same-size, same-mtime edit is copied (compared by content)');
    ok(!-e "$dst/skills/s1", 'C: a removed skill is removed');
    ok($r->{removed} >= 1, 'C: ...and counted');
    is_deeply([map { (stat $_)[1] } "$dst/plugins", "$dst/plugins/a"], [@ino[0, 1]],
        'C: directories are updated in place (same inode), so a running container\'s bind keeps seeing them');
    my @tmp = grep { /\Q$LiveMirror::TMP_PREFIX\E/ } keys %{ tree($dst) };
    is_deeply(\@tmp, [], 'C: no temporary file is left behind');

    # The statusline goes away: so does scripts/, which held nothing else.
    unlink "$src/scripts/statusline.pl";
    refresh_ok($src, $dst, 'C (no statusline)');
    ok(!-e "$dst/scripts", 'C: without statusline.pl there is no scripts/ in the mirror');

    # A read-only source directory is still filled, and ends with its mode.
    make_path("$src/plugins/ro");
    spew("$src/plugins/ro/f", "in a read-only dir\n");
    chmod 0555, "$src/plugins/ro";
    refresh_ok($src, $dst, 'C (read-only dir)');
    is(slurp("$dst/plugins/ro/f"), "in a read-only dir\n", 'C: a read-only source directory is copied with its files');
    is(sprintf('%o', (stat "$dst/plugins/ro")[2] & 07777), '555', 'C: ...and its mode');
    chmod 0755, "$src/plugins/ro";
    spew("$src/plugins/ro/f", "changed\n");
    chmod 0555, "$src/plugins/ro";
    refresh_ok($src, $dst, 'C (read-only dir, changed)');
    is(slurp("$dst/plugins/ro/f"), "changed\n", 'C: ...and updated inside it later');
    chmod 0755, "$src/plugins/ro", "$dst/plugins/ro";
    remove_tree("$src/plugins/ro");

    my $missing = new_mirror();
    my $nr = LiveMirror::refresh(source => $src, mirror => $missing);
    ok(!$nr->{ok} && $nr->{error} =~ /does not exist/, 'C: without create, a missing mirror is an error, not created');
    ok(!-e $missing, 'C: ...and nothing is created');
}

# ---------------------------------------------------------------------------
# D. the mirror is hostile
# ---------------------------------------------------------------------------
{
    my $src = fake_install();
    my $dst = new_mirror();
    refresh_ok($src, $dst, 'D (setup)');
    my $victim = Cwd::abs_path(tempdir(CLEANUP => 1));
    spew("$victim/precious", "keep me\n");
    make_path("$victim/dir");
    spew("$victim/dir/x.pl", "VICTIM\n");   # same name as a mirrored file

    # A whole mirrored directory swapped for a symlink to a Mac folder.
    remove_tree("$dst/plugins/a");
    symlink("$victim/dir", "$dst/plugins/a") or die;
    # A mirrored file swapped for a symlink to a Mac file.
    unlink "$dst/skills/s1/SKILL.md";
    symlink("$victim/precious", "$dst/skills/s1/SKILL.md") or die;
    # Extras planted in the mirror, one of them a directory holding a link out.
    make_path("$dst/evil/deeper", "$dst/.git/hooks");
    spew("$dst/.git/hooks/post-checkout", "#!/bin/sh\n");
    symlink($victim, "$dst/evil/deeper/out") or die;
    symlink("$victim/dir", "$dst/plugins/linkdir") or die;
    # Directories made read-only: a planted one to remove, a mirrored one to update.
    make_path("$dst/stuck");
    spew("$dst/stuck/f", "x\n");
    chmod 0555, "$dst/stuck";
    chmod 0555, "$dst/skills";

    my $r = refresh_ok($src, $dst, 'D (hostile)');
    is(slurp("$victim/dir/x.pl"), "VICTIM\n", 'D: nothing is written through a planted directory symlink');
    is(slurp("$victim/precious"), "keep me\n", 'D: nothing is written through a planted file symlink');
    ok(-e "$victim/dir" && -e "$victim/precious", 'D: removing planted links never removes what they point at');
    ok(!-l "$dst/plugins/a" && -d "$dst/plugins/a", 'D: the planted directory link is replaced by a real directory');
    ok(!-l "$dst/skills/s1/SKILL.md" && -f "$dst/skills/s1/SKILL.md", 'D: the planted file link is replaced by a real file');
    ok(!-e "$dst/evil" && !-e "$dst/.git" && !-e "$dst/plugins/linkdir", 'D: planted extras are removed');
    ok(!-e "$dst/stuck", 'D: ...a read-only planted directory too');
    is(sprintf('%o', (stat "$dst/skills")[2] & 07777), sprintf('%o', (stat "$src/skills")[2] & 07777),
        'D: a mirrored directory made read-only is updated and gets the source\'s mode back');
    is_deeply(tree($dst), tree($src, source => 1), 'D: ...and the mirror equals the source again');

    # A FIFO where an empty mirrored file belongs: compared without blocking.
    unlink "$dst/plugins/a/empty";
    POSIX::mkfifo("$dst/plugins/a/empty", 0644) or die "mkfifo: $!";
    my $done = eval {
        local $SIG{ALRM} = sub { die "hung\n" };
        alarm 20;
        my $x = LiveMirror::refresh(source => $src, mirror => $dst);
        alarm 0;
        $x;
    };
    alarm 0;
    ok($done && $done->{ok}, 'D: a planted FIFO does not hang the refresh') or diag($@ || ($done && $done->{error}));
    ok(-f "$dst/plugins/a/empty" && !-p "$dst/plugins/a/empty", 'D: ...it is replaced by the real (empty) file');

    # The mirror directory itself a symlink: refused, its target untouched.
    my $base = Cwd::abs_path(tempdir(CLEANUP => 1));
    symlink($victim, "$base/live-mirror") or die;
    my $s = LiveMirror::refresh(source => $src, mirror => "$base/live-mirror", create => 1);
    ok(!$s->{ok} && $s->{error} =~ /not a directory/, 'D: a mirror that is itself a symlink is refused');
    ok(!-e "$victim/plugins", 'D: ...and nothing is written into what it points at');
}

# ---------------------------------------------------------------------------
# D2. the VM cannot stop the refresh (what it wrote would outlive the machine)
# ---------------------------------------------------------------------------
{
    my $src = fake_install();
    my $dst = new_mirror();
    refresh_ok($src, $dst, 'D2 (setup)');
    # Every directory the walk touches gets its mode back before cleanup, so
    # File::Temp can remove the fixture.
    my $unlock = sub {
        my @todo = ($dst);
        while (my $d = shift @todo) {
            chmod 0755, $d;
            opendir(my $dh, $d) or next;
            push @todo, map { "$d/$_" } grep { $_ ne '.' && $_ ne '..' && !-l "$d/$_" && -d "$d/$_" } readdir $dh;
        }
    };

    make_path("$dst/plugins/stuck/inner");
    my $esc = "x\e]0;PWNED\a\e[2J";
    make_path("$dst/$esc");
    my $p = "$dst/skills/deep";
    $p .= '/d' for 1 .. 70;
    make_path($p);                                   # a planted tree past the depth limit
    chmod 0000, "$dst/plugins/stuck";                # a planted directory made unreadable
    chmod 0000, "$dst/$esc";                         # ...with a name that is a terminal escape
    chmod 0000, "$dst/plugins/a";                    # a wanted directory made unreadable
    chmod 0000, $dst;                                # and the share's root

    my $r = LiveMirror::refresh(source => $src, mirror => $dst);
    ok($r->{ok}, 'D2: an unreadable root, unreadable and too-deep planted directories do not fail the refresh') or diag($r->{error});
    is(slurp("$dst/plugins/a/x.pl"), "#!/usr/bin/perl\nprint 1;\n", 'D2: a wanted directory made unreadable is rebuilt with its files');
    my @aside = grep { index($_, $LiveMirror::TMP_PREFIX . 'unreadable-') == 0 } do { opendir(my $dh, "$dst/plugins") or die; readdir $dh };
    is(scalar(@aside), 1, 'D2: ...the unreadable one is moved aside, not followed or deleted');
    my $w = join("\n", @{ $r->{warnings} });
    like($w, qr/plugins\/a could not be read; moved aside/, 'D2: ...and that is reported');
    like($w, qr/left plugins\/stuck: it cannot be read/, 'D2: what cannot be removed is left and reported');
    like($w, qr/left skills\/deep\/(?:d\/)+d: it is deeper than \d+ directories/, 'D2: ...a tree past the depth limit too');
    is(scalar(grep { /[\x00-\x1f\x7f]/ } @{ $r->{warnings} }, $r->{error} // ''), 0, 'D2: no control character reaches a message (names are the VM\'s to choose)');
    like($w, qr/x\\x1b\]0;PWNED\\x07\\x1b\[2J/, 'D2: ...they are escaped instead');
    $unlock->();   # the leftovers stay unreadable until then
    my %t = %{ tree($dst) };
    my %want = %{ tree($src, source => 1) };
    is_deeply([ grep { !exists $t{$_} || $t{$_} ne $want{$_} } sort keys %want ], [],
        'D2: every wanted entry is in place, despite the leftovers');
    $unlock->();

    # Temp names are random, so planting the next one in advance fails nothing.
    my %names = map { (LiveMirror::_tmp_name() => 1) } 1 .. 50;
    is(scalar(keys %names), 50, 'D2: temporary names are not predictable');

    # A directory opened for the walk is never a symlink swapped in after the lstat.
    my $base = Cwd::abs_path(tempdir(CLEANUP => 1));
    make_path("$base/real", "$base/elsewhere");
    my @st = lstat "$base/real";
    symlink("$base/elsewhere", "$base/swapped") or die;
    my $cwd = Cwd::getcwd();
    opendir(my $here, $base) or die;
    chdir($here) or die;
    my $got = eval { LiveMirror::_open_dir('swapped', \@st, $here, 'swapped') };
    my $err = $@;
    my $now = Cwd::getcwd();
    chdir($cwd);
    ok(!$got && $err =~ /cannot open swapped/, 'D2: _open_dir refuses a symlink (O_NOFOLLOW) instead of entering it');
    is($now, Cwd::getcwd() eq $cwd ? Cwd::abs_path($base) : $now, 'D2: ...and never left the directory it started in');
}

# ---------------------------------------------------------------------------
# D3. names that change only in case (APFS: one entry answers to both)
# ---------------------------------------------------------------------------
SKIP: {
    my $probe = Cwd::abs_path(tempdir(CLEANUP => 1));
    spew("$probe/Aa", '');
    skip 'D3: needs a case-insensitive filesystem (APFS)', 6 unless $^O eq 'darwin' && -e "$probe/aa";
    my $src = fake_install();
    my $dst = new_mirror();
    make_path("$src/plugins/casedir");
    spew("$src/plugins/casedir/f", "in casedir\n");
    spew("$src/plugins/casefile", "case file\n");
    refresh_ok($src, $dst, 'D3 (setup)');
    rename("$src/plugins/casedir", "$src/plugins/CaseDir") or die;
    rename("$src/plugins/casefile", "$src/plugins/CaseFile") or die;
    my $r = refresh_ok($src, $dst, 'D3 (renamed by case)');
    is($r->{removed}, 0, 'D3: nothing is removed');
    my %names = map { $_ => 1 } do { opendir(my $dh, "$dst/plugins") or die; readdir $dh };
    ok($names{CaseDir} && !$names{casedir}, 'D3: a directory renamed by case keeps its entry, under the new spelling');
    ok($names{CaseFile} && !$names{casefile}, 'D3: ...and so does a file');
    is(slurp("$dst/plugins/CaseDir/f"), "in casedir\n", 'D3: ...with its contents');
}

# ---------------------------------------------------------------------------
# D4. complete(): what the launcher checks before podman create
# ---------------------------------------------------------------------------
{
    my $src = fake_install();
    my $dst = new_mirror();
    ok(!LiveMirror::complete($src, $dst), 'D4: an absent mirror is not complete');
    refresh_ok($src, $dst, 'D4 (fill)');
    ok(LiveMirror::complete($src, $dst), 'D4: a refreshed mirror is complete');
    unlink "$dst/scripts/statusline.pl";
    ok(!LiveMirror::complete($src, $dst), 'D4: one without the statusline is not (a partial first fill must not pass)');
    remove_tree("$dst/scripts");
    my $elsewhere = Cwd::abs_path(tempdir(CLEANUP => 1));
    make_path("$elsewhere/scripts");
    spew("$elsewhere/scripts/statusline.pl", "x\n");
    symlink("$elsewhere/scripts", "$dst/scripts") or die;
    ok(!LiveMirror::complete($src, $dst), 'D4: a component swapped for a symlink is not followed');
    unlink "$src/scripts/statusline.pl";
    unlink "$dst/scripts";
    ok(LiveMirror::complete($src, $dst), 'D4: only what the source has is required');
}

# ---------------------------------------------------------------------------
# E. lock, working directory, source and mirror never overlap
# ---------------------------------------------------------------------------
{
    my $src = fake_install();
    my $dst = new_mirror();
    refresh_ok($src, $dst, 'E (setup)');
    use Fcntl qw(:flock);
    open(my $lk, '>>', "$dst.lock") or die;
    flock($lk, LOCK_EX) or die;
    my $r = LiveMirror::refresh(source => $src, mirror => $dst, lock_timeout => 0);
    ok(!$r->{ok} && $r->{error} =~ /held its lock/, 'E: a refresh already running holds the lock; another one does not interleave with it');
    close $lk;

    my $cwd = Cwd::getcwd();
    refresh_ok($src, $dst, 'E (cwd)');
    is(Cwd::getcwd(), $cwd, 'E: the working directory is restored after a refresh');
    my $bad = LiveMirror::refresh(source => $src, mirror => "$src/plugins/inner", create => 1);
    ok(!$bad->{ok} && $bad->{error} =~ /cannot be the source or inside it/, 'E: a mirror inside the source is refused');
    ok(!-e "$src/plugins/inner", 'E: ...before anything is created');
    is(Cwd::getcwd(), $cwd, 'E: ...and the working directory is unchanged after a failure');
}

# ---------------------------------------------------------------------------
# F. the launcher, by source text (never run)
# ---------------------------------------------------------------------------
my $src = slurp("$Bin/../../scripts/launcher.pl");
ok(defined $src && length $src, 'F: launcher.pl read as text');
{
    like($src, qr/my \$LIVE_MIRROR = LiveMirror::mirror_dir\(home => PodmanMachine::account_home\(\),\s*install_root => \$INSTALL_ROOT\);/,
        'F: the mirror is keyed by this launcher\'s own install root, under the account home the machine shares from');

    my ($closure) = $src =~ /(\$build_create_args = sub \{.*?\n    \};\n)/s;
    ok(defined $closure, 'F: the podman create closure is found');
    $closure //= '';
    my ($stmt) = $closure =~ /(\@args = MountSpec::map_bind_sources\(.*?\)\s*if defined \$LIVE_MIRROR;)/s;
    ok(defined $stmt, 'F: the create closure maps its bind sources through the mirror when there is one');
    my ($i_img, $i_map, $i_conv) = map { index($closure, $_) } ('push @args, $IMAGE_LATEST;', '@args = MountSpec::map_bind_sources(', 'return convert_v_to_mount(@args);');
    ok($i_img >= 0 && $i_map > $i_img && $i_conv > $i_map, 'F: ...after every bind is in the list and before the --mount conversion');

    SKIP: {
        skip 'F: no mapping statement to evaluate', 3 unless defined $stmt;
        my $INSTALL_ROOT = '/Users/u/.claude/ccpraxis';
        my @launch = ('/usr/bin/podman', 'create', '-it', '--name', 'claude-app-12345678',
            '-v', '/Users/u/Projects/app:/project',
            '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
            '-v', '/Users/u/Projects/app/.ccpraxis-local-data/claude-home:/root/.claude',
            '-v', '/Users/u/Projects/app/.ccpraxis-local-data/claude-home/.launcher:/root/.claude/.launcher:ro',
            '-v', "$INSTALL_ROOT/scripts/statusline.pl:/root/.claude/statusline.pl:ro",
            '-v', '/Users/u/.cache/ccpraxis/container-files/almanac-global-counts.json:/root/.claude/almanac-global-counts.json:ro',
            '-v', "$INSTALL_ROOT/skills/s1:/root/.claude/skills/s1:ro",
            '-v', "$INSTALL_ROOT/plugins:/root/.claude/plugins/marketplaces/ccpraxis-local:ro",
            '-v', '/Users/u/Projects/app/.ccpraxis-local-data/claude-home/.launcher/empty-skill:/root/.claude/plugins/marketplaces/ccpraxis-local/sandbox/skills/x:ro',
            '-v', "$INSTALL_ROOT/plugins/backpack/scripts/backpack.pl:/root/.claude/backpack.pl:ro",
            '-v', "$INSTALL_ROOT/plugins/backpack/hooks/auto-declare.pl:/root/.claude/auto-declare.pl:ro",
            'claude-sandbox:latest');

        my $LIVE_MIRROR;   # every host but macOS
        my @args = @launch;
        eval "$stmt; 1" or die "eval: $@";   ## no critic
        is_deeply(\@args, \@launch, 'F: off macOS the create arguments are byte-identical: binds come from the install root');

        $LIVE_MIRROR = '/Users/u/.cache/ccpraxis/live-mirror';
        @args = @launch;
        eval "$stmt; 1" or die "eval: $@";   ## no critic
        (my $want = join("\n", @launch)) =~ s{\Q$INSTALL_ROOT\E/}{$LIVE_MIRROR/}g;
        is(join("\n", @args), $want,
            'F: on macOS every install-root bind (statusline, skill, plugin tree, backpack) comes from the mirror; container paths, ro flags and all other binds unchanged');

        # Those binds are exactly what the planned machine serves.
        my $L = PodmanMachine::layout(home => '/Users/u');
        my $want_m = PodmanMachine::desired_machine(layout => $L, current => { exists => 0 },
            state => { projects => ['/Users/u/Projects/app'], test_scratch => 1 });
        my @binds = HostPlatform::bind_mounts(MountSpec::convert_v_to_mount(@args));
        is_deeply([HostPlatform::sources_outside_shares(\@binds, $want_m->{shares})], [],
            'F: every bind the macOS launcher emits lies inside a share PodmanMachine plans');
        my @old = HostPlatform::bind_mounts(MountSpec::convert_v_to_mount(@launch));
        ok(scalar(HostPlatform::sources_outside_shares(\@old, $want_m->{shares})),
            'F: ...while binds straight from the live install would not be served (it is no longer shared)');
    }

    like($src, qr/_refuse_unshared_mounts\('preflight', \{ source => \$PROJECT_PATH, readonly => 0 \},\s*\{ source => \(\$LIVE_MIRROR \/\/ \$INSTALL_ROOT\), readonly => 1 \}\)\s*unless \$SESSION_MODE \|\| length \$RESUME_SESSION;/,
        'F: the preflight checks the mirror the binds come from (the install root off macOS), except for a connector, which only joins a running container');
    my $i_rc = index($src, "_refresh_live_mirror('create')");
    my $i_cr = index($src, '@podman_args = $build_create_args->();');
    ok($i_rc > 0 && $i_cr > $i_rc, 'F: the mirror is refreshed before podman create');
    like($src, qr/sub _refresh_live_mirror \{.*?return LiveMirror::complete\(\$INSTALL_ROOT, \$LIVE_MIRROR\) \? 1 : 0;\n\}/s,
        'F: ...and create goes ahead only when the mirror holds everything the binds need (a partial fill does not pass)');
    my $i_rs = index($src, "_stage_container_copies('start');");
    my $i_gate = index($src, 'my $gate_result = s03_run_launch_gate(');
    ok($i_rs > 0 && $i_gate > $i_rs, 'F: ...and refreshed before the container is started');
    like($src, qr/sub _stage_container_copies \{.*?return _refresh_live_mirror\(\$stage, %o\);\n\}/s,
        'F: ...by the one sub every start path uses (counts copy and mirror together)');
    like($src, qr/container_start => sub \{.*?_stage_container_copies\('recover', quiet => 1\);\s*my \$out  = `\$PODMAN start/s,
        'F: the [l] recover flow refreshes them too, quietly, right before its podman start (its machine start may have emptied them)');
    like($src, qr/sub _refresh_live_mirror \{\s*my \(\$stage, %o\) = \@_;\s*return 1 unless defined \$LIVE_MIRROR;/,
        'F: the refresh is a no-op wherever there is no mirror');
    like($src, qr/PodmanMachine::ensure_share_dirs\(PodmanMachine::layout\(home => \$home\),\s*grep \{ defined \} \$LIVE_MIRROR\)/,
        'F: the mirror folder is recreated before the launcher starts the machine (vfkit refuses a missing share)');
}

done_testing();
