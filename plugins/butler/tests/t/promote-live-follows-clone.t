#!/usr/bin/env perl
# platform: host
# promote.pl under the dev-clone-only workflow: the live install is produced
# by promotion and nothing else, and ~/.claude/CLAUDE.md is built per host.
#
#   LF-1  no live install: --dry-run reports would-create and creates nothing;
#         apply creates it as a clone of the dev clone (origin = the clone),
#         installs the payload, prints the install.pl next step; a second run
#         is up-to-date.
#   LF-2  a live install with a commit of its own is refused in --dry-run
#         exactly as in apply (exit 2, refused-live-only-commits, resolve
#         line), and the dry-run writes nothing.
#   LF-3  a GitHub origin left by the old workflow is replaced by the dev
#         clone (dry-run: would-set, nothing changed; apply: set, the old
#         remote-tracking refs gone); a live install already following the
#         clone is left alone (no origin line).
#   LF-4  CLAUDE.md is the shared payload file plus THIS host's part only:
#         the other platform's part never reaches the installed file; a line
#         that moved from the shared file into a part is not a local edit; a
#         line in no part's history is.
#   LF-5  a symlink to the shared payload file is replaced by the built file
#         when this host has a part of its own (would-replace-link in
#         --dry-run).
#   LF-6  macOS: a promotion refreshes the sandbox's live-install mirror when
#         it exists (never creates it, never in --dry-run), and a mirror that
#         cannot be refreshed is a warning line, not a failed promotion.
#
# Every invocation passes --clone/--live/--home; nothing here touches the real
# ~/.claude or the real live install. Fixture helpers are the house pattern
# from promote-syncs-global-config.t.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Basename qw(dirname basename);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir tempfile);
use JSON::PP;

my $ROOT    = "$Bin/../../../..";
my $PROMOTE = "$ROOT/scripts/promote.pl";

# This host's part, named independently of GlobalClaudeMd so the test does
# not grade the module with its own answer.
my $HOST_PART = ($^O =~ /^(MSWin32|cygwin|msys)$/) ? 'global-config/CLAUDE.windows.md'
              : ($^O eq 'darwin')                   ? 'global-config/CLAUDE.macos.md'
              :                                       undef;
my $OTHER_PART = ($^O eq 'darwin') ? 'global-config/CLAUDE.windows.md' : 'global-config/CLAUDE.macos.md';

# ---------------------------------------------------------------------------
# byte-level file helpers -- no decode/re-encode anywhere in this file.
# ---------------------------------------------------------------------------
sub write_bytes {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $content;
    close $fh;
}
sub read_bytes {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or die "read $path: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# ---------------------------------------------------------------------------
# path + git helpers. Forward-slash Windows form only (C:/...), hand
# translated -- never relying on ambient MSYS2 argv conversion. Every git
# call is list-form, hermetic (own GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1,
# explicit author/committer, -c core.autocrlf=false).
# ---------------------------------------------------------------------------
sub to_gp {
    my ($p) = @_;
    return $p unless defined $p;
    (my $q = $p) =~ s{\\}{/}g;
    return $q;
}

sub env_git {
    my ($f) = @_;
    return (
        GIT_CONFIG_GLOBAL   => $f->{gitconfig},
        GIT_CONFIG_NOSYSTEM => '1',
        GIT_TERMINAL_PROMPT => '0',
        GIT_AUTHOR_NAME     => 'Promote Test',
        GIT_AUTHOR_EMAIL    => 'promote-test@example.invalid',
        GIT_COMMITTER_NAME  => 'Promote Test',
        GIT_COMMITTER_EMAIL => 'promote-test@example.invalid',
    );
}

sub git_run {
    my ($f, $dir, @args) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;
    my $rc = system('git', '-c', 'core.autocrlf=false', '-C', to_gp($dir), @args);
    return $rc == -1 ? -1 : ($rc >> 8);
}

sub git_capture {
    my ($f, $dir, @args) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;
    open my $fh, '-|', 'git', '-c', 'core.autocrlf=false', '-C', to_gp($dir), @args
        or die "cannot spawn git -C $dir @args: $!";
    local $/;
    my $out = <$fh>;
    close $fh;
    return defined $out ? $out : '';
}

sub git_clone {
    my ($f, $src, $dest) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;
    my $rc = system('git', '-c', 'core.autocrlf=false', 'clone', '-q', '--no-hardlinks', to_gp($src), to_gp($dest));
    return $rc == 0;
}

sub head_sha {
    my ($f, $dir) = @_;
    my $s = git_capture($f, $dir, 'rev-parse', 'HEAD');
    $s =~ s/\s+\z//;
    return $s;
}

sub status_porcelain {
    my ($f, $dir) = @_;
    return git_capture($f, $dir, 'status', '--porcelain', '--untracked-files=all');
}

sub head_parent_count {
    my ($f, $dir) = @_;
    my $s = git_capture($f, $dir, 'log', '-1', '--pretty=%P');
    $s =~ s/\s+\z//;
    return 0 if $s eq '';
    my @p = split ' ', $s;
    return scalar(@p);
}

sub is_ancestor {
    my ($f, $dir, $anc, $desc) = @_;
    my $rc = git_run($f, $dir, 'merge-base', '--is-ancestor', $anc, $desc);
    return $rc == 0 ? 1 : 0;
}

# ---------------------------------------------------------------------------
# fixture builder. Scratch lives OUTSIDE this repo, under HostCaps'
# consolidated scratch root (never under $ROOT).
# ---------------------------------------------------------------------------
sub new_fixture {
    my (%opts) = @_;
    my $root = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $f = { root => $root, gitconfig => "$root/empty.gitconfig" };
    write_bytes($f->{gitconfig}, '');

    my $clone = "$root/clone-repo";
    make_path($clone);
    git_run($f, $clone, 'init', '-q');
    git_run($f, $clone, 'symbolic-ref', 'HEAD', 'refs/heads/main');
    $f->{clone} = $clone;

    my @commits = @{ $opts{clone_commits} // [ [ { 'README.md' => "# clone fixture\n" }, 'seed' ] ] };
    for my $c (@commits) {
        my ($files, $msg) = @$c;
        for my $rel (sort keys %$files) { write_bytes("$clone/$rel", $files->{$rel}); }
        git_run($f, $clone, 'add', '-A');
        git_run($f, $clone, 'commit', '-q', '-m', $msg);
    }

    my $home = "$root/home";
    make_path("$home/.claude");
    $f->{home} = $home;

    unless ($opts{no_live}) {
        my $live = "$home/.claude/ccpraxis";
        git_clone($f, $clone, $live) or die "git clone into live fixture failed";
        $f->{live} = $live;
        for my $c (@{ $opts{live_commits} // [] }) {
            my ($files, $msg) = @$c;
            for my $rel (sort keys %$files) { write_bytes("$live/$rel", $files->{$rel}); }
            git_run($f, $live, 'add', '-A');
            git_run($f, $live, 'commit', '-q', '-m', $msg);
        }
    }
    return $f;
}

sub clone_extra_commit {
    my ($f, $files, $msg) = @_;
    for my $rel (sort keys %$files) { write_bytes("$f->{clone}/$rel", $files->{$rel}); }
    git_run($f, $f->{clone}, 'add', '-A');
    git_run($f, $f->{clone}, 'commit', '-q', '-m', $msg);
}

sub live_extra_commit {
    my ($f, $files, $msg) = @_;
    for my $rel (sort keys %$files) { write_bytes("$f->{live}/$rel", $files->{$rel}); }
    git_run($f, $f->{live}, 'add', '-A');
    git_run($f, $f->{live}, 'commit', '-q', '-m', $msg);
}

# ---------------------------------------------------------------------------
# promote.pl spawner. stderr captured through a real File::Temp file, never
# an in-memory scalar reopen (Git-for-Windows "Bad file descriptor" trap).
# ---------------------------------------------------------------------------
sub _spawn {
    my ($f, @args) = @_;
    my %e = env_git($f);
    local @ENV{ keys %e } = values %e;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;
    open(my $saved_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out  = '';
    my $exit = -1;
    my $pid  = open(my $fh, '-|', $^X, $PROMOTE, @args);
    if ($pid) {
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_err) or warn "cannot restore STDERR: $!";
    close $saved_err;
    my $err = read_bytes($ename);
    $err = '' unless defined $err;
    unlink $ename;

    return { out => $out, err => $err, exit => $exit };
}

# Standard invocation: always --clone/--live/--home explicit, per house rule.
sub run_promote {
    my ($f, @extra) = @_;
    return _spawn($f, '--clone', $f->{clone}, '--live', $f->{live}, '--home', $f->{home}, @extra);
}

# Bare invocation for usage-error / --help scenarios (AC-14), which need
# full control over which flags are present.
sub run_promote_raw {
    my ($f, @args) = @_;
    return _spawn($f, @args);
}

sub canon_json {
    my ($data) = @_;
    return JSON::PP->new->canonical->utf8->encode($data);
}

sub decode_bytes_json {
    my ($bytes) = @_;
    return undef unless defined $bytes;
    my $d = eval { decode_json($bytes) };
    return $d;
}

sub git_out {
    my ($f, $dir, @args) = @_;
    my $s = git_capture($f, $dir, @args);
    $s =~ s/\s+\z//;
    return $s;
}

# ===========================================================================
# LF-1: no live install yet.
# ===========================================================================
{
    my $f = new_fixture(no_live => 1, clone_commits => [
        [ { 'global-config/CLAUDE.md' => "shared rule\n", 'install.pl' => "1;\n" }, 'seed' ],
    ]);
    $f->{live} = "$f->{home}/.claude/ccpraxis";

    my $d = run_promote($f, '--dry-run');
    is($d->{exit}, 0, 'LF-1 (dry-run): exit 0') or diag($d->{out} . $d->{err});
    like($d->{out}, qr/^merge: would-create /m, 'LF-1 (dry-run): would-create') or diag($d->{out});
    ok(!-e $f->{live}, 'LF-1 (dry-run): the live install was not created');
    ok(!-e "$f->{home}/.claude/CLAUDE.md", 'LF-1 (dry-run): no CLAUDE.md written');

    my $r = run_promote($f);
    is($r->{exit}, 0, 'LF-1: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: created /m, 'LF-1: report says created') or diag($r->{out});
    like($r->{out}, qr/^  next: perl \S*install\.pl/m, 'LF-1: the install.pl next step is printed') or diag($r->{out});
    ok(-d "$f->{live}/.git", 'LF-1: the live install is a git work tree');
    is(head_sha($f, $f->{live}), head_sha($f, $f->{clone}), 'LF-1: live HEAD == clone main');
    is(git_out($f, $f->{live}, 'rev-parse', '--abbrev-ref', 'HEAD'), 'main', 'LF-1: live is on main');
    my $origin = git_out($f, $f->{live}, 'remote', 'get-url', 'origin');
    is(lc(to_gp($origin)), lc(to_gp($f->{clone})), 'LF-1: live origin is the dev clone');
    ok(-f "$f->{home}/.claude/CLAUDE.md", 'LF-1: CLAUDE.md installed');

    my $r2 = run_promote($f);
    is($r2->{exit}, 0, 'LF-1 (second run): exit 0') or diag($r2->{out} . $r2->{err});
    like($r2->{out}, qr/^merge: up-to-date/m, 'LF-1 (second run): up-to-date') or diag($r2->{out});
    unlike($r2->{out}, qr/^  origin:/m, 'LF-1 (second run): no origin change reported') or diag($r2->{out});
}

# ===========================================================================
# LF-2: live-only commit, dry-run refuses like apply and writes nothing.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => "v1\n" }, 'seed' ],
    ], live_commits => [
        [ { 'global-config/settings.json' => "{}\n" }, 'backup: sync ccpraxis config (1 file(s))' ],
    ]);
    clone_extra_commit($f, { 'global-config/CLAUDE.md' => "v2\n" }, 'clone ahead');
    write_bytes("$f->{home}/.claude/CLAUDE.md", "v1\n");
    my $pre_head = head_sha($f, $f->{live});

    my $d = run_promote($f, '--dry-run');
    is($d->{exit}, 2, 'LF-2 (dry-run): exit 2') or diag($d->{out} . $d->{err});
    like($d->{out}, qr/^merge: refused-live-only-commits/m, 'LF-2 (dry-run): refused-live-only-commits') or diag($d->{out});
    like($d->{out}, qr/pull --no-rebase \S+ main/, 'LF-2 (dry-run): resolve line present') or diag($d->{out});
    like($d->{out}, qr/^claude-md: not-run/m, 'LF-2 (dry-run): the syncs did not run') or diag($d->{out});
    is(read_bytes("$f->{home}/.claude/CLAUDE.md"), "v1\n", 'LF-2 (dry-run): CLAUDE.md untouched');
    is(head_sha($f, $f->{live}), $pre_head, 'LF-2 (dry-run): live HEAD untouched');
}

# ===========================================================================
# LF-3: origin re-pointed from GitHub to the dev clone.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [ [ { 'README.md' => "seed\n" }, 'seed' ] ]);
    my $gh = 'https://github.com/example/ccpraxis.git';
    git_run($f, $f->{live}, 'remote', 'set-url', 'origin', $gh);
    # A stale remote-tracking ref, as a fetch from GitHub would have left.
    git_run($f, $f->{live}, 'update-ref', 'refs/remotes/origin/stale', 'HEAD');

    my $d = run_promote($f, '--dry-run');
    is($d->{exit}, 0, 'LF-3 (dry-run): exit 0') or diag($d->{out} . $d->{err});
    like($d->{out}, qr/^  origin: would-set to the dev clone \S.* \(was \Q$gh\E\)$/m, 'LF-3 (dry-run): would-set, naming the old URL') or diag($d->{out});
    is(git_out($f, $f->{live}, 'remote', 'get-url', 'origin'), $gh, 'LF-3 (dry-run): origin unchanged');

    my $r = run_promote($f);
    is($r->{exit}, 0, 'LF-3: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^  origin: set to the dev clone \S.* \(was \Q$gh\E\)$/m, 'LF-3: origin set, naming the old URL') or diag($r->{out});
    is(lc(to_gp(git_out($f, $f->{live}, 'remote', 'get-url', 'origin'))), lc(to_gp($f->{clone})), 'LF-3: origin is now the dev clone');
    is(git_out($f, $f->{live}, 'for-each-ref', '--format=%(refname)', 'refs/remotes/origin/stale'), '', 'LF-3: the stale GitHub tracking ref is gone');

    my $r2 = run_promote($f);
    unlike($r2->{out}, qr/^  origin:/m, 'LF-3 (second run): nothing to change') or diag($r2->{out});
}

# ===========================================================================
# LF-4: per-host CLAUDE.md.
# ===========================================================================
SKIP: {
    skip 'LF-4: this host has no platform part of its own (Linux)', 1 unless defined $HOST_PART;
    my $SHARED_V1 = "# Global\n\nshared rule\nmoving rule\n";
    my $SHARED_V2 = "# Global\n\nshared rule\n";
    my $HOST      = "## This host\n\nmoving rule\nhost rule\n";
    my $OTHER     = "## Other host\n\nother rule\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $SHARED_V1 }, 'shared v1' ],
        [ { 'global-config/CLAUDE.md' => $SHARED_V2, $HOST_PART => $HOST, $OTHER_PART => $OTHER }, 'split per platform' ],
    ]);
    # Installed from v1, before the split: "moving rule" now lives in the host part.
    write_bytes("$f->{home}/.claude/CLAUDE.md", $SHARED_V1);

    my $r = run_promote($f);
    is($r->{exit}, 0, 'LF-4: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^claude-md: refreshed/m, 'LF-4: a line that moved into a part is not a local edit') or diag($r->{out});
    my $got = read_bytes("$f->{home}/.claude/CLAUDE.md");
    is($got, "$SHARED_V2\n$HOST", 'LF-4: installed = shared file, a blank line, this host\'s part');
    unlike($got // '', qr/other rule/, 'LF-4: the other platform\'s part is not installed');

    my $r2 = run_promote($f);
    like($r2->{out}, qr/^claude-md: unchanged/m, 'LF-4 (second run): unchanged') or diag($r2->{out});

    write_bytes("$f->{home}/.claude/CLAUDE.md", "$SHARED_V2\n$HOST" . "hand-added rule\n");
    my $r3 = run_promote($f);
    is($r3->{exit}, 1, 'LF-4 (hand edit): exit 1') or diag($r3->{out} . $r3->{err});
    like($r3->{out}, qr/^claude-md: refused-local-edit 1 line/m, 'LF-4 (hand edit): refused') or diag($r3->{out});
    like($r3->{out}, qr/^  L\d+: hand-added rule$/m, 'LF-4 (hand edit): the line is shown') or diag($r3->{out});
    like($r3->{out}, qr/\Q$HOST_PART\E/, 'LF-4 (hand edit): the resolve line names this host\'s part') or diag($r3->{out});
}

# ===========================================================================
# LF-5: a link to the shared file cannot carry a host part.
# ===========================================================================
SKIP: {
    skip 'LF-5: this host has no platform part of its own (Linux)', 1 unless defined $HOST_PART;
    my $probe = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $works = eval { write_bytes("$probe/t", "x"); symlink("$probe/t", "$probe/l") or die; -l "$probe/l" };
    skip 'LF-5: symlink() is not supported here', 1 unless $works;

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => "shared\n", $HOST_PART => "host\n" }, 'payload' ],
    ]);
    symlink("$f->{live}/global-config/CLAUDE.md", "$f->{home}/.claude/CLAUDE.md") or die "symlink: $!";

    my $d = run_promote($f, '--dry-run');
    like($d->{out}, qr/^claude-md: would-replace-link/m, 'LF-5 (dry-run): would-replace-link') or diag($d->{out});
    ok(-l "$f->{home}/.claude/CLAUDE.md", 'LF-5 (dry-run): the link is still there');

    my $r = run_promote($f);
    is($r->{exit}, 0, 'LF-5: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^claude-md: replaced-link/m, 'LF-5: replaced-link') or diag($r->{out});
    ok(!-l "$f->{home}/.claude/CLAUDE.md", 'LF-5: the link is now a regular file');
    is(read_bytes("$f->{home}/.claude/CLAUDE.md"), "shared\n\nhost\n", 'LF-5: with the built content');
    is(read_bytes("$f->{live}/global-config/CLAUDE.md"), "shared\n", 'LF-5: the payload file it pointed at is untouched');
}

# ===========================================================================
# LF-6 (macOS): promotion refreshes the sandbox's live-install mirror.
# ===========================================================================
# The podman machine shares a copy of the live install's plugins, skills and
# statusline (plugins/sandbox/scripts/LiveMirror.pm), never the live install.
# A promotion must still reach running sandboxes, so promote.pl refreshes that
# copy -- only where it exists, and never at the cost of the promotion.
SKIP: {
    skip 'LF-6: the live-install mirror exists on macOS only', 19 unless $^O eq 'darwin';
    my $f = new_fixture(clone_commits => [
        [ { 'plugins/p/a.pl' => "v1\n", 'plugins/p/old.pl' => "old\n", 'skills/s/SKILL.md' => "skill\n",
            'scripts/statusline.pl' => "status\n", 'scripts/other.pl' => "not mounted\n", 'README.md' => "readme\n" }, 'seed' ],
    ]);
    my $mirror = "$f->{home}/.cache/ccpraxis/live-mirror";
    my $tree = sub {
        my ($root) = @_;
        my %t;
        my $walk;
        $walk = sub {
            my ($d, $rel) = @_;
            opendir(my $dh, $d) or return;
            for my $n (grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
                my $r = length $rel ? "$rel/$n" : $n;
                if (-d "$d/$n" && !-l "$d/$n") { $walk->("$d/$n", $r) } else { $t{$r} = read_bytes("$d/$n") }
            }
        };
        $walk->($root, '');
        return \%t;
    };
    my $live_part = sub {
        my $t = $tree->($f->{live});
        return { map { $_ => $t->{$_} } grep { m{\A(?:plugins|skills)/} || $_ eq 'scripts/statusline.pl' } keys %$t };
    };

    my $r = run_promote($f);
    is($r->{exit}, 0, 'LF-6 (no mirror): exit 0') or diag($r->{out} . $r->{err});
    unlike($r->{out}, qr/^mirror:/m, 'LF-6 (no mirror): no mirror line when the machine was never set up to share one');
    ok(!-e $mirror, 'LF-6 (no mirror): promote does not create it (podman-machine.pl apply does)');

    make_path($mirror);
    write_bytes("$f->{clone}/plugins/p/a.pl", "v2\n");
    unlink "$f->{clone}/plugins/p/old.pl";
    git_run($f, $f->{clone}, 'add', '-A');
    git_run($f, $f->{clone}, 'commit', '-q', '-m', 'plugin change');

    my $d = run_promote($f, '--dry-run');
    unlike($d->{out}, qr/^mirror:/m, 'LF-6 (dry-run): no mirror line') or diag($d->{out});
    is_deeply($tree->($mirror), {}, 'LF-6 (dry-run): the mirror is untouched');

    $r = run_promote($f);
    is($r->{exit}, 0, 'LF-6: exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^mirror: refreshed \Q$mirror\E \(\d+ written, 0 removed\)$/m, 'LF-6: the mirror is refreshed') or diag($r->{out});
    is(read_bytes("$f->{live}/plugins/p/a.pl"), "v2\n", 'LF-6: the live install was fast-forwarded');
    is_deeply($tree->($mirror), $live_part->(), 'LF-6: the mirror holds exactly the live install\'s plugins, skills and statusline');
    ok(!-e "$mirror/README.md" && !-e "$mirror/.git" && !-e "$mirror/scripts/other.pl", 'LF-6: ...and nothing else (no .git)');

    $r = run_promote($f);
    like($r->{out}, qr/^mirror: up-to-date \Q$mirror\E$/m, 'LF-6 (second run): up-to-date') or diag($r->{out});

    # Something the VM planted is removed by the next promotion.
    write_bytes("$mirror/plugins/planted", "x\n");
    $r = run_promote($f);
    like($r->{out}, qr/^mirror: refreshed \Q$mirror\E \(0 written, 1 removed\)$/m, 'LF-6: a stray entry in the mirror is removed') or diag($r->{out});

    # One the refresh cannot remove (made unreadable) is reported on the same line.
    make_path("$mirror/plugins/stuck/inner");
    chmod 0000, "$mirror/plugins/stuck";
    $r = run_promote($f);
    chmod 0755, "$mirror/plugins/stuck";
    is($r->{exit}, 0, 'LF-6 (planted, unremovable): exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^mirror: up-to-date \Q$mirror\E; warning 1 planted entry could not be removed \(left plugins\/stuck: it cannot be read\)$/m,
        'LF-6 (planted, unremovable): the mirror line says what was left') or diag($r->{out});
    remove_tree("$mirror/plugins/stuck");

    # A mirror that cannot be refreshed is a warning, never a failed promotion.
    my $elsewhere = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    rename($mirror, "$elsewhere/moved") or die "rename: $!";
    symlink("$elsewhere/moved", $mirror) or die "symlink: $!";
    clone_extra_commit($f, { 'plugins/p/a.pl' => "v3\n" }, 'another plugin change');
    $r = run_promote($f);
    is($r->{exit}, 0, 'LF-6 (mirror failure): the promotion still succeeds') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^mirror: warning \Q$mirror\E was not refreshed \(.*not a directory.*\); running sandboxes keep the previous copy$/m,
        'LF-6 (mirror failure): one warning line says so') or diag($r->{out});
    like($r->{out}, qr/^result: ok$/m, 'LF-6 (mirror failure): result ok') or diag($r->{out});
    is(read_bytes("$f->{live}/plugins/p/a.pl"), "v3\n", 'LF-6 (mirror failure): the live install was still fast-forwarded');
    is(read_bytes("$elsewhere/moved/plugins/p/a.pl"), "v2\n", 'LF-6 (mirror failure): nothing was written through the symlink');
}

done_testing();
