#!/usr/bin/env perl
# platform: host
# Oracle for blueprint hook-continuity-remake, package
# 33-promote-syncs-global-config (scripts/promote.pl). Derived ONLY from
# .ccpraxis-local-data/blueprints/hook-continuity-remake/specs/
# 33-promote-syncs-global-config-spec.md (AC-1..AC-17; AC-18 is a ledger
# step, not testable here) and Decision 109. scripts/promote.pl is NOT read
# while writing this file -- it does not exist yet, so every scenario below
# is expected to fail on "the script is missing / does nothing", never on a
# bug in this file's own fixtures.
#
# EVERYTHING under test is a fixture: a throwaway clone repo, a throwaway
# live-install repo (a real `git clone --no-hardlinks` of the clone, given
# its own local commits where a scenario needs divergence), and a throwaway
# fixture home. Every promote.pl invocation below passes --clone/--live/
# --home explicitly; nothing here ever touches the real ~/.claude or the
# real live install.
#
# AC -> block mapping (grep "AC-<n>:" for every assertion of a criterion):
#   AC-1  stale refresh + backup byte-equal to the old content
#   AC-2  stale-by-line-union (home built from lines each in SOME version)
#   AC-3  local edit refused, offending line(s) reported, no backup
#   AC-4  dirty live refuses the merge (tracked-modified and untracked cases)
#   AC-5  fast-forward, then up-to-date on a second run; a live install
#         with commits of its own is refused, never merged
#   AC-6  a would-be merge conflict is refused the same way, no half state
#   AC-7  payload read AFTER the merge (post-merge HEAD, not pre-merge)
#   AC-8  unchanged (CRLF-only) / installed (missing home file) / symlink
#   AC-9  the settings.json unit-merge table, row by row
#   AC-10 non-ASCII (Andre with an accent) byte round-trip in settings
#   AC-11 settings error paths (unparseable live, missing live)
#   AC-12 marketplaces report-only (action-needed vs in-sync), never written
#   AC-13 dry-run writes nothing, same refusal/exit-code shape as apply
#   AC-14 usage errors (unknown flag, --clone==--live, --help)
#   AC-15 report shape: one of each stable-prefixed line, in order
#   AC-16 perl -c is clean on scripts/promote.pl
#   AC-17 doc edits name scripts/promote.pl and drop the bare-pull framing
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Temp qw(tempdir tempfile);
use JSON::PP;
use Encode qw();

my $ROOT    = "$Bin/../../../..";
my $PROMOTE = "$ROOT/scripts/promote.pl";

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

# ===========================================================================
# AC-16: perl -c is clean on scripts/promote.pl. Expected to fail today
# (file does not exist) -- that is the right reason.
# ===========================================================================
{
    if (-f $PROMOTE) {
        my ($efh, $ename) = tempfile(UNLINK => 1);
        close $efh;
        open(my $saved_err, '>&', \*STDERR) or die "cannot dup STDERR: $!";
        open(STDERR, '>', $ename) or die "cannot redirect STDERR: $!";
        my $rc = system($^X, '-c', $PROMOTE);
        open(STDERR, '>&', $saved_err) or warn "cannot restore STDERR: $!";
        close $saved_err;
        my $err = read_bytes($ename) // '';
        unlink $ename;
        ok($rc == 0, 'AC-16: perl -c exits 0 for scripts/promote.pl') or diag($err);
    } else {
        ok(0, 'AC-16: perl -c exits 0 for scripts/promote.pl (file not found)');
    }
}

# ===========================================================================
# AC-1: stale refresh. Clone history CLAUDE.md v1 then v2; home holds v1
# bytes. After promote: exit 0, home == v2 byte-exact, report says
# "refreshed", a backup dir exists under <home>/.claude/.promotion-backups/,
# and its CLAUDE.md copy is byte-equal to v1 (the pre-run content).
# ===========================================================================
{
    my $V1 = "one\ntwo\nthree\n";
    my $V2 = "one\nTWO-UPDATED\nthree\nfour\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $V1 }, 'claude-md v1' ],
        [ { 'global-config/CLAUDE.md' => $V2 }, 'claude-md v2' ],
    ]);
    write_bytes("$f->{home}/.claude/CLAUDE.md", $V1);

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-1: exit 0 on a stale refresh') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^claude-md: refreshed/m, 'AC-1: report says claude-md: refreshed') or diag($r->{out});
    my $got = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $got && $got eq $V2, 'AC-1: home CLAUDE.md is byte-equal to v2 after promote')
        or diag('got: ' . (defined $got ? "[$got]" : 'undef'));

    my $bdir_glob = "$f->{home}/.claude/.promotion-backups";
    ok(-d $bdir_glob, 'AC-1: a .promotion-backups directory was created') or diag($r->{out});
    my @ts_dirs = -d $bdir_glob ? glob("$bdir_glob/*") : ();
    ok(scalar(@ts_dirs) >= 1, 'AC-1: at least one timestamped backup subdirectory exists');
    my $backup_claude = @ts_dirs ? "$ts_dirs[0]/CLAUDE.md" : undef;
    my $backup_bytes = defined $backup_claude ? read_bytes($backup_claude) : undef;
    ok(defined $backup_bytes && $backup_bytes eq $V1, 'AC-1: the backed-up CLAUDE.md is byte-equal to v1')
        or diag('backup path: ' . (defined $backup_claude ? $backup_claude : 'undef'));
    like($r->{out}, qr/^backup: \S+/m, 'AC-1: report backup: line names a directory');
}

# ===========================================================================
# AC-2: stale by line union. home is made of lines each present in SOME
# payload version, but equal to neither version whole -- still classed
# stale, not a local edit.
# ===========================================================================
{
    my $V1 = "alpha\nbeta\n";
    my $V2 = "gamma\nbeta\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $V1 }, 'claude-md v1' ],
        [ { 'global-config/CLAUDE.md' => $V2 }, 'claude-md v2' ],
    ]);
    write_bytes("$f->{home}/.claude/CLAUDE.md", "alpha\ngamma\n"); # from v1 + from v2, matches neither whole

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-2: exit 0 on a line-union stale file') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^claude-md: refreshed/m, 'AC-2: report says claude-md: refreshed') or diag($r->{out});
    my $got = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $got && $got eq $V2, 'AC-2: home CLAUDE.md becomes v2 (current payload)');
}

# ===========================================================================
# AC-3: local edit refused. home = v1 plus one line the payload never had.
# Exit 1, file left byte-identical, refused-local-edit with the exact line
# number, result: refused, and no .promotion-backups directory at all.
# ===========================================================================
{
    my $V1 = "line-one\nline-two\n";
    my $LOCAL_LINE = "LOCAL-ONLY marker";
    my $home_content = $V1 . "$LOCAL_LINE\n";
    my @v1_lines = split /\n/, $V1;
    my $expected_lineno = scalar(@v1_lines) + 1;

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $V1 }, 'claude-md v1' ],
    ]);
    write_bytes("$f->{home}/.claude/CLAUDE.md", $home_content);

    my $r = run_promote($f);
    is($r->{exit}, 1, 'AC-3: exit 1 on a local edit') or diag($r->{out} . $r->{err});
    my $got = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $got && $got eq $home_content, 'AC-3: home CLAUDE.md is byte-identical to before the run');
    like($r->{out}, qr/^claude-md: refused-local-edit 1 line\(s\)/m, 'AC-3: report says refused-local-edit 1 line(s)')
        or diag($r->{out});
    my $q = quotemeta($LOCAL_LINE);
    like($r->{out}, qr/L$expected_lineno: $q/, "AC-3: an indented line reports L$expected_lineno: $LOCAL_LINE")
        or diag($r->{out});
    like($r->{out}, qr/^result: refused/m, 'AC-3: report says result: refused') or diag($r->{out});
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'AC-3: no .promotion-backups directory was created');
}

# ===========================================================================
# AC-4: dirty live refuses the merge. Exit 2, refused-dirty listing the
# file, live HEAD unchanged, the modification/untracked file still present,
# home CLAUDE.md/settings.json byte-unchanged, sync lines not-run.
# ===========================================================================
for my $case (qw(tracked-modified untracked)) {
    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "seed\n", 'tracked.txt' => "original\n" }, 'seed' ],
        [ { 'global-config/CLAUDE.md' => "payload v2\n" }, 'ahead commit' ],
    ]);
    my $pre_head = head_sha($f, $f->{live});
    write_bytes("$f->{home}/.claude/CLAUDE.md", "some home content\n");
    write_bytes("$f->{home}/.claude/settings.json", "{}\n");
    my $pre_claude = read_bytes("$f->{home}/.claude/CLAUDE.md");
    my $pre_settings = read_bytes("$f->{home}/.claude/settings.json");

    if ($case eq 'tracked-modified') {
        write_bytes("$f->{live}/tracked.txt", "modified in the live tree\n");
    } else {
        write_bytes("$f->{live}/untracked-new-file.txt", "new\n");
    }

    my $r = run_promote($f);
    is($r->{exit}, 2, "AC-4 ($case): exit 2 on a dirty live tree") or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: refused-dirty/m, "AC-4 ($case): report says merge: refused-dirty") or diag($r->{out});
    my $expect_name = $case eq 'tracked-modified' ? 'tracked.txt' : 'untracked-new-file.txt';
    like($r->{out}, qr/\Q$expect_name\E/, "AC-4 ($case): the dirty entry names $expect_name") or diag($r->{out});
    is(head_sha($f, $f->{live}), $pre_head, "AC-4 ($case): live HEAD SHA is unchanged");
    my $post_claude = read_bytes("$f->{home}/.claude/CLAUDE.md");
    my $post_settings = read_bytes("$f->{home}/.claude/settings.json");
    ok(defined $post_claude && $post_claude eq $pre_claude, "AC-4 ($case): home CLAUDE.md byte-unchanged");
    ok(defined $post_settings && $post_settings eq $pre_settings, "AC-4 ($case): home settings.json byte-unchanged");
    like($r->{out}, qr/^claude-md: not-run/m, "AC-4 ($case): claude-md line is not-run") or diag($r->{out});
    like($r->{out}, qr/^settings: not-run/m, "AC-4 ($case): settings line is not-run") or diag($r->{out});
    like($r->{out}, qr/^marketplaces: not-run/m, "AC-4 ($case): marketplaces line is not-run") or diag($r->{out});
}

# ===========================================================================
# AC-5: the live install moves by fast-forward only. Clone main ahead of
# live -> fast-forward (1 parent), clone main becomes live HEAD, and a
# second run reports up-to-date. A live install with a commit of its own
# (the old backup committed there) is REFUSED: exit 2, the commit is named,
# the resolve line says how to bring it into the clone, live is untouched.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "seed\n" }, 'seed' ],
    ]);
    my $clone_main_before = head_sha($f, $f->{clone});
    clone_extra_commit($f, { 'shared.txt' => "clone-only change\n" }, 'clone ahead');
    my $clone_main_after = head_sha($f, $f->{clone});

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-5 (fast-forward): exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: fast-forward/m, 'AC-5 (fast-forward): report says fast-forward') or diag($r->{out});
    ok(is_ancestor($f, $f->{live}, $clone_main_after, 'HEAD'), 'AC-5 (fast-forward): clone main is now an ancestor of live HEAD');
    is(head_parent_count($f, $f->{live}), 1, 'AC-5 (fast-forward): live HEAD has exactly 1 parent');

    my $r2 = run_promote($f);
    is($r2->{exit}, 0, 'AC-5 (second run): exit 0');
    like($r2->{out}, qr/^merge: up-to-date/m, 'AC-5 (second run): report says up-to-date') or diag($r2->{out});
}
{
    my $f = new_fixture(clone_commits => [
        [ { 'README.md' => "seed\n" }, 'seed' ],
    ], live_commits => [
        [ { 'live-only.txt' => "live-side commit\n" }, 'live-only commit' ],
    ]);
    clone_extra_commit($f, { 'clone-only.txt' => "clone-side commit\n" }, 'clone ahead');

    my $pre_head = head_sha($f, $f->{live});

    my $r = run_promote($f);
    is($r->{exit}, 2, 'AC-5 (live-only commit): exit 2') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: refused-live-only-commits/m, 'AC-5 (live-only commit): report says refused-live-only-commits') or diag($r->{out});
    like($r->{out}, qr/^  \S+ live-only commit$/m, 'AC-5 (live-only commit): the live-only commit is listed by subject') or diag($r->{out});
    like($r->{out}, qr/pull --no-rebase \S+ main/, 'AC-5 (live-only commit): the resolve line names the pull into the clone') or diag($r->{out});
    is(head_sha($f, $f->{live}), $pre_head, 'AC-5 (live-only commit): live HEAD unchanged');
    is(head_parent_count($f, $f->{live}), 1, 'AC-5 (live-only commit): no merge commit was made');
    like($r->{out}, qr/^claude-md: not-run/m, 'AC-5 (live-only commit): the syncs did not run') or diag($r->{out});

    # Following the resolve line converges the two: the clone takes the live
    # commit, and the next promote is a plain fast-forward.
    git_run($f, $f->{clone}, 'pull', '-q', '--no-rebase', '--no-edit', to_gp($f->{live}), 'main');
    my $r2 = run_promote($f);
    is($r2->{exit}, 0, 'AC-5 (after the resolve pull): exit 0') or diag($r2->{out} . $r2->{err});
    like($r2->{out}, qr/^merge: fast-forward/m, 'AC-5 (after the resolve pull): fast-forward') or diag($r2->{out});
    is(head_sha($f, $f->{live}), head_sha($f, $f->{clone}), 'AC-5 (after the resolve pull): live HEAD == clone main');
}

# ===========================================================================
# AC-6: what used to be a merge conflict (clone and live change the same
# line of one tracked file) never reaches a merge now: live's own commit is
# refused up front. Exit 2, live HEAD == pre-run HEAD, status clean, no
# MERGE_HEAD, home files unchanged.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'shared.txt' => "line1\nline2\nline3\n" }, 'seed shared.txt' ],
    ]);
    clone_extra_commit($f, { 'shared.txt' => "line1\nCLONE-CHANGED\nline3\n" }, 'clone edits line2');
    live_extra_commit($f, { 'shared.txt' => "line1\nLIVE-CHANGED\nline3\n" }, 'live edits line2');
    my $pre_head = head_sha($f, $f->{live}); # the pre-merge HEAD (spec S3.2.6): captured AFTER
                                              # live's own commit, since that commit is what the
                                              # aborted pull must leave HEAD pointing at.
    write_bytes("$f->{home}/.claude/CLAUDE.md", "untouched\n");
    my $pre_claude = read_bytes("$f->{home}/.claude/CLAUDE.md");

    my $r = run_promote($f);
    is($r->{exit}, 2, 'AC-6: exit 2 when live has a conflicting commit of its own') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: refused-live-only-commits/m, 'AC-6: report says refused-live-only-commits') or diag($r->{out});
    is(head_sha($f, $f->{live}), $pre_head, 'AC-6: live HEAD equals the pre-run HEAD');
    is(status_porcelain($f, $f->{live}), '', 'AC-6: git status --porcelain is empty (no half-finished merge)');
    ok(!-f "$f->{live}/.git/MERGE_HEAD", 'AC-6: no MERGE_HEAD file remains');
    my $post_claude = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $post_claude && $post_claude eq $pre_claude, 'AC-6: home CLAUDE.md byte-unchanged');
}

# ===========================================================================
# AC-7: payload read post-merge. Clone gets a NEW commit changing CLAUDE.md
# to v3 while home still holds v2 (a historical version). After one apply
# run home equals v3 (the post-merge live HEAD payload, not the pre-merge
# one).
# ===========================================================================
{
    my $V1 = "v1 alpha\nv1 beta\n";
    my $V2 = "v2 alpha\nv2 beta\n";
    my $V3 = "v3 alpha\nv3 beta\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $V1 }, 'claude-md v1' ],
        [ { 'global-config/CLAUDE.md' => $V2 }, 'claude-md v2' ],
    ]);
    clone_extra_commit($f, { 'global-config/CLAUDE.md' => $V3 }, 'claude-md v3, clone-only');
    write_bytes("$f->{home}/.claude/CLAUDE.md", $V2);

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-7: exit 0 after merge + sync in one run') or diag($r->{out} . $r->{err});
    my $got = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $got && $got eq $V3, 'AC-7: home CLAUDE.md equals v3 (post-merge payload) after one apply run');
}

# ===========================================================================
# AC-8: unchanged (CRLF-only difference) / installed (missing home file) /
# linked (symlink to the payload, where symlink() actually works here).
# ===========================================================================
{
    my $payload = "one\ntwo\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $payload }, 'claude-md' ],
    ]);
    write_bytes("$f->{home}/.claude/CLAUDE.md", "one\r\ntwo\r\n");

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-8 (unchanged/CRLF): exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^claude-md: unchanged/m, 'AC-8 (unchanged/CRLF): report says unchanged') or diag($r->{out});
    like($r->{out}, qr/^backup: none/m, 'AC-8 (unchanged/CRLF): backup: none') or diag($r->{out});
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'AC-8 (unchanged/CRLF): no backup directory created');
}
{
    my $payload = "installed payload\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $payload }, 'claude-md' ],
    ]);
    # home CLAUDE.md deliberately absent.
    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-8 (installed): exit 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^claude-md: installed/m, 'AC-8 (installed): report says installed') or diag($r->{out});
    my $got = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $got && $got eq $payload, 'AC-8 (installed): home CLAUDE.md now equals the payload');
}
SKIP: {
    my $probe_dir = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $symlink_works = eval {
        symlink("$probe_dir/target", "$probe_dir/link") or die;
        1;
    } ? 1 : 0;
    skip 'AC-8 (linked): symlink() is not supported on this host', 1 unless $symlink_works;

    my $payload = "symlinked payload\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $payload }, 'claude-md' ],
    ]);
    unlink "$f->{home}/.claude/CLAUDE.md" if -e "$f->{home}/.claude/CLAUDE.md";
    my $ok_link = eval {
        symlink("$f->{live}/global-config/CLAUDE.md", "$f->{home}/.claude/CLAUDE.md") or die;
        1;
    } ? 1 : 0;
    skip 'AC-8 (linked): could not create the symlink fixture', 1 unless $ok_link;

    my $r = run_promote($f);
    like($r->{out}, qr/^claude-md: linked/m, 'AC-8 (linked): report says linked') or diag($r->{out});
}

# ===========================================================================
# AC-9: the settings.json unit-merge table (spec S3.5 table 17), row by row.
#   a_only_left    -- only_left,  keep live, no report line
#   shared         -- identical, no report line
#   diverge_stale  -- diverged, live value seen in payload history -> updated
#   diverge_local  -- diverged, live value NEVER in history -> kept-local
#   b_only_right   -- only_right, no preference -> added
#   b2_only_right  -- only_right, right-only preference -> kept-pref, not added
#   pref_skip      -- diverged, skip-always preference -> kept-pref, kept live
#   env.X / env.Y  -- dotted expansion: env.X added, sibling env.Y (only_left)
#                     survives unreported
# ===========================================================================
{
    my $payload_v1 = {
        diverge_stale => 'OLD_LIVE_VALUE',
        diverge_local => 'PAYLOAD_LOCAL_V1',
        shared        => 'same_val',
        env           => { X => 'envx_v1' },
        pref_skip     => 'PAYLOAD_PREF_SKIP_V1',
    };
    my $payload_v2 = {
        diverge_stale => 'NEW_PAYLOAD_VALUE',
        diverge_local => 'PAYLOAD_LOCAL_V2',
        shared        => 'same_val',
        env           => { X => 'envx_payload' },
        b_only_right  => 'ADD_ME',
        b2_only_right => 'BLOCKED_ADD',
        pref_skip     => 'PAYLOAD_PREF_SKIP_V2',
    };
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2' ],
    ]);
    my $live_settings = {
        a_only_left   => 'L',
        diverge_stale => 'OLD_LIVE_VALUE',   # was v1's payload value -- stale
        diverge_local => 'WEIRD_LOCAL',      # never any payload value -- local edit
        shared        => 'same_val',
        env           => { Y => 'livey' },
        pref_skip     => 'LIVE_VAL_PREF_SKIP',
    };
    write_bytes("$f->{home}/.claude/settings.json", canon_json($live_settings));

    my $prefs = {
        live_vs_repo => {
            pref_skip     => { category => 'diverged',   action => 'skip-always' },
            b2_only_right => { category => 'only_right', action => 'right-only' },
        },
    };
    write_bytes("$f->{live}/.backup-preferences.json", canon_json($prefs));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-9: exit 0 across the whole settings unit table') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^settings: updated \(\d+ changes\)/m, 'AC-9: report says settings: updated (n changes)')
        or diag($r->{out});
    like($r->{out}, qr/added b_only_right/, 'AC-9: report line "added b_only_right"') or diag($r->{out});
    like($r->{out}, qr/updated diverge_stale/, 'AC-9: report line "updated diverge_stale"') or diag($r->{out});
    like($r->{out}, qr/kept-local diverge_local/, 'AC-9: report line "kept-local diverge_local"') or diag($r->{out});
    like($r->{out}, qr/kept-pref b2_only_right \(right-only\)/, 'AC-9: report line "kept-pref b2_only_right (right-only)"')
        or diag($r->{out});
    like($r->{out}, qr/kept-pref pref_skip \(skip-always\)/, 'AC-9: report line "kept-pref pref_skip (skip-always)"')
        or diag($r->{out});
    like($r->{out}, qr/added env\.X/, 'AC-9: report line "added env.X" (dotted unit)') or diag($r->{out});
    unlike($r->{out}, qr/env\.Y/, 'AC-9: no report line for the surviving live-only env.Y');

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $result = decode_bytes_json($bytes);
    ok(ref($result) eq 'HASH', 'AC-9: resulting settings.json parses as an object') or diag($bytes // 'undef');
    if (ref($result) eq 'HASH') {
        is($result->{a_only_left}, 'L', 'AC-9: only_left key a_only_left is kept');
        is($result->{diverge_stale}, 'NEW_PAYLOAD_VALUE', 'AC-9: stale diverge_stale is updated to the current payload value');
        is($result->{diverge_local}, 'WEIRD_LOCAL', 'AC-9: local-edit diverge_local keeps the live value');
        is($result->{b_only_right}, 'ADD_ME', 'AC-9: payload-only b_only_right is added');
        ok(!exists $result->{b2_only_right}, 'AC-9: right-only-blocked b2_only_right is never added');
        is($result->{pref_skip}, 'LIVE_VAL_PREF_SKIP', 'AC-9: skip-always pref_skip keeps the live value');
        is(ref($result->{env}), 'HASH', 'AC-9: env unit is a hash');
        if (ref($result->{env}) eq 'HASH') {
            is($result->{env}{X}, 'envx_payload', 'AC-9: env.X (only_right) is added from the payload');
            is($result->{env}{Y}, 'livey', 'AC-9: env.Y (only_left, live-only) survives');
        }
    }

    my @ts_dirs = glob("$f->{home}/.claude/.promotion-backups/*");
    my $backup_settings = @ts_dirs ? read_bytes("$ts_dirs[0]/settings.json") : undef;
    ok(defined $backup_settings && $backup_settings eq canon_json($live_settings),
        'AC-9: backed-up settings.json equals the pre-run bytes');
}

# ===========================================================================
# AC-10: non-ASCII round trip. A settings string containing "Andre" with an
# accent survives an updated run byte-exact -- the UTF-8 bytes for e-acute
# (0xC3 0xA9) appear once, never re-encoded (which would show as 0xC3 0x83).
# ===========================================================================
{
    # A decoded Perl character string (NOT pre-encoded bytes): canon_json's
    # own ->utf8->encode is the ONE point where this ever becomes UTF-8
    # bytes. Handing it already-encoded bytes would make ->utf8 re-encode
    # them as if they were Latin-1 characters, doubling the encoding.
    my $accented = "Andr\x{e9}"; # decoded text; UTF-8 bytes are 41 6E 64 72 C3 A9
    my $payload_v1 = { note => 'old value, no accent' };
    my $payload_v2 = { note => $accented };
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json($payload_v1) }, 'settings v1' ],
        [ { 'global-config/settings.json' => canon_json($payload_v2) }, 'settings v2 accented' ],
    ]);

    write_bytes("$f->{home}/.claude/settings.json", canon_json({ note => 'old value, no accent' }));

    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-10: exit 0') or diag($r->{out} . $r->{err});
    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    ok(defined $bytes, 'AC-10: settings.json is readable after promote');
    if (defined $bytes) {
        my $count_correct = () = ($bytes =~ /\x41\x6E\x64\x72\xC3\xA9/g);
        my $count_mangled = () = ($bytes =~ /\xC3\x83/g);
        is($count_correct, 1, 'AC-10: the correct UTF-8 bytes for "Andre-accented" appear exactly once');
        is($count_mangled, 0, 'AC-10: no double-encoded 0xC3 0x83 byte pair appears anywhere');
    }
}

# ===========================================================================
# AC-11: settings error paths. Unparseable live settings.json -> exit 2,
# settings: error, file byte-unchanged. Missing live settings.json ->
# skipped-missing-live, file still absent (never created).
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json({ a => 1 }) }, 'settings' ],
    ]);
    my $bad = "{ this is not valid json ";
    write_bytes("$f->{home}/.claude/settings.json", $bad);

    my $r = run_promote($f);
    is($r->{exit}, 2, 'AC-11 (unparseable live): exit 2') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^settings: error/m, 'AC-11 (unparseable live): report says settings: error') or diag($r->{out});
    my $post = read_bytes("$f->{home}/.claude/settings.json");
    ok(defined $post && $post eq $bad, 'AC-11 (unparseable live): file is byte-unchanged');
}
{
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json({ a => 1 }) }, 'settings' ],
    ]);
    # home settings.json deliberately absent.
    my $r = run_promote($f);
    like($r->{out}, qr/^settings: skipped-missing-live/m, 'AC-11 (missing live): report says skipped-missing-live')
        or diag($r->{out});
    ok(!-e "$f->{home}/.claude/settings.json", 'AC-11 (missing live): settings.json is still absent afterward');
}

# ===========================================================================
# AC-12: marketplaces are report-only. A payload github entry absent from
# live -> action-needed with a missing-live hint naming the repo. Entries
# differing only in volatile fields -> in-sync. Live file byte-unchanged
# either way.
# ===========================================================================
{
    my $payload_mp = {
        'chrome-devtools-plugins' => {
            lastUpdated => '2026-03-03T00:00:00Z',
            source      => { repo => 'ChromeDevTools/chrome-devtools-mcp', source => 'github' },
        },
    };
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/known_marketplaces.json' => canon_json($payload_mp) }, 'marketplaces' ],
    ]);
    my $live_mp = {};
    my $live_bytes = canon_json($live_mp);
    write_bytes("$f->{home}/.claude/plugins/known_marketplaces.json", $live_bytes);

    my $r = run_promote($f);
    like($r->{out}, qr/^marketplaces: action-needed/m, 'AC-12 (missing-live): report says action-needed') or diag($r->{out});
    like($r->{out}, qr{missing-live chrome-devtools-plugins hint: /plugin marketplace add ChromeDevTools/chrome-devtools-mcp},
        'AC-12 (missing-live): hint names /plugin marketplace add with the owner/repo') or diag($r->{out});
    my $post = read_bytes("$f->{home}/.claude/plugins/known_marketplaces.json");
    ok(defined $post && $post eq $live_bytes, 'AC-12 (missing-live): live known_marketplaces.json byte-unchanged');
}
{
    my $payload_mp = {
        'chrome-devtools-plugins' => {
            lastUpdated => '2026-03-03T00:00:00Z',
            source      => { repo => 'ChromeDevTools/chrome-devtools-mcp', source => 'github' },
        },
    };
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/known_marketplaces.json' => canon_json($payload_mp) }, 'marketplaces' ],
    ]);
    my $live_mp = {
        'chrome-devtools-plugins' => {
            lastUpdated     => '2026-09-01T00:00:00Z',
            installLocation => '/some/machine/local/path',
            source          => { repo => 'ChromeDevTools/chrome-devtools-mcp', source => 'github' },
        },
    };
    my $live_bytes = canon_json($live_mp);
    write_bytes("$f->{home}/.claude/plugins/known_marketplaces.json", $live_bytes);

    my $r = run_promote($f);
    like($r->{out}, qr/^marketplaces: in-sync/m, 'AC-12 (volatile-only diff): report says in-sync') or diag($r->{out});
    my $post = read_bytes("$f->{home}/.claude/plugins/known_marketplaces.json");
    ok(defined $post && $post eq $live_bytes, 'AC-12 (volatile-only diff): live known_marketplaces.json byte-unchanged');
}

# ===========================================================================
# AC-13: dry-run writes nothing. Stale CLAUDE.md + updatable settings +
# clone-ahead-of-live: --dry-run exits 0, prints would-fast-forward/would-refresh/
# would-update, and afterward live HEAD, git status, and every file under
# the fixture .claude are byte-unchanged, with no .promotion-backups
# directory. A local-edit CLAUDE.md under --dry-run exits 1 with the same
# L<n>: lines apply would produce.
# ===========================================================================
{
    my $V1 = "stale one\nstale two\n";
    my $V2 = "fresh one\nfresh two\n";
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $V1 }, 'claude-md v1' ],
    ]);
    my $pre_head = head_sha($f, $f->{live});
    clone_extra_commit($f, { 'global-config/CLAUDE.md' => $V2 }, 'claude-md v2, clone ahead');

    write_bytes("$f->{home}/.claude/CLAUDE.md", $V1);
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ diverge => 'OLD' }));
    # give the payload the same history shape so diverge classifies as stale.
    # (settings history is unioned across clone main and live HEAD in dry-run.)
    my $pre_claude = read_bytes("$f->{home}/.claude/CLAUDE.md");
    my $pre_settings = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-13: dry-run exits 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: would-fast-forward/m, 'AC-13: report says would-fast-forward') or diag($r->{out});
    like($r->{out}, qr/^claude-md: would-refresh/m, 'AC-13: report says claude-md: would-refresh') or diag($r->{out});

    is(head_sha($f, $f->{live}), $pre_head, 'AC-13: live HEAD is unchanged after dry-run');
    is(status_porcelain($f, $f->{live}), '', 'AC-13: live git status is clean after dry-run');
    my $post_claude = read_bytes("$f->{home}/.claude/CLAUDE.md");
    my $post_settings = read_bytes("$f->{home}/.claude/settings.json");
    ok(defined $post_claude && $post_claude eq $pre_claude, 'AC-13: home CLAUDE.md byte-unchanged after dry-run');
    ok(defined $post_settings && $post_settings eq $pre_settings, 'AC-13: home settings.json byte-unchanged after dry-run');
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'AC-13: no .promotion-backups directory created by dry-run');
    like($r->{out}, qr/^backup: none/m, 'AC-13: backup: none under dry-run') or diag($r->{out});
}
{
    my $V1 = "line-one\nline-two\n";
    my $LOCAL_LINE = "LOCAL-ONLY marker";
    my $home_content = $V1 . "$LOCAL_LINE\n";
    my @v1_lines = split /\n/, $V1;
    my $expected_lineno = scalar(@v1_lines) + 1;

    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => $V1 }, 'claude-md v1' ],
    ]);
    write_bytes("$f->{home}/.claude/CLAUDE.md", $home_content);

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 1, 'AC-13 (local edit, dry-run): exit 1') or diag($r->{out} . $r->{err});
    my $q = quotemeta($LOCAL_LINE);
    like($r->{out}, qr/L$expected_lineno: $q/, "AC-13 (local edit, dry-run): reports L$expected_lineno: $LOCAL_LINE")
        or diag($r->{out});
    my $post = read_bytes("$f->{home}/.claude/CLAUDE.md");
    ok(defined $post && $post eq $home_content, 'AC-13 (local edit, dry-run): home CLAUDE.md byte-unchanged');
}

# ===========================================================================
# AC-14: usage errors. Unknown flag -> exit 3. --clone X --live X (same
# dir) -> exit 3. --help -> exit 0.
# ===========================================================================
{
    my $f = new_fixture();
    my $r = run_promote($f, '--not-a-real-flag');
    is($r->{exit}, 3, 'AC-14: an unknown flag exits 3') or diag($r->{out} . $r->{err});
}
{
    my $f = new_fixture();
    my $r = run_promote_raw($f, '--clone', $f->{clone}, '--live', $f->{clone}, '--home', $f->{home});
    is($r->{exit}, 3, 'AC-14: --clone X --live X (same directory) exits 3') or diag($r->{out} . $r->{err});
}
{
    my $f = new_fixture();
    my $r = run_promote_raw($f, '--help');
    is($r->{exit}, 0, 'AC-14: --help exits 0') or diag($r->{out} . $r->{err});
}

# ===========================================================================
# AC-15: report shape. Every run prints exactly one each of the seven
# stable-prefixed lines, in the documented order.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/CLAUDE.md' => "payload\n" }, 'claude-md' ],
    ]);
    write_bytes("$f->{home}/.claude/CLAUDE.md", "payload\n");
    my $r = run_promote($f);

    my @prefixes = qw(promote: merge: claude-md: settings: marketplaces: backup: result:);
    for my $p (@prefixes) {
        my $qp = quotemeta($p);
        my @hits = ($r->{out} =~ /^\Q$p\E/mg);
        is(scalar(@hits), 1, "AC-15: exactly one '$p' line") or diag($r->{out});
    }
    my @lines = split /\n/, $r->{out};
    my @seen_prefixes = grep { my $l = $_; grep { $l =~ /^\Q$_\E/ } @prefixes } @lines;
    my @order = map {
        my $l = $_;
        (grep { $l =~ /^\Q$_\E/ } @prefixes)[0]
    } @seen_prefixes;
    is_deeply_ordered(\@order, \@prefixes);
}

sub is_deeply_ordered {
    my ($got, $expected) = @_;
    my $ok = (scalar(@$got) == scalar(@$expected));
    if ($ok) {
        for my $i (0 .. $#$expected) {
            $ok = 0 unless defined $got->[$i] && $got->[$i] eq $expected->[$i];
        }
    }
    ok($ok, 'AC-15: the seven report lines appear in the documented order')
        or diag('got order: ' . join(',', map { $_ // 'undef' } @$got));
}

# ===========================================================================
# AC-17: doc edits. CLAUDE.md and working-on-ccpraxis.md each name
# scripts/promote.pl, and neither still presents a bare pull as the whole
# promotion. Expected to fail today: these docs have not been edited yet.
# ===========================================================================
{
    my $claude_md = read_bytes("$ROOT/CLAUDE.md") // '';
    my $working_doc = read_bytes("$ROOT/docs/working-on-ccpraxis.md") // '';

    like($claude_md, qr/scripts\/promote\.pl/, 'AC-17: CLAUDE.md names scripts/promote.pl');
    unlike($claude_md, qr/\*\*Promotion is a merge:\*\*/, 'AC-17: CLAUDE.md drops the "Promotion is a merge:" framing');

    like($working_doc, qr/scripts\/promote\.pl/, 'AC-17: working-on-ccpraxis.md names scripts/promote.pl');
    unlike($working_doc, qr/That is the whole promotion\./,
        'AC-17: working-on-ccpraxis.md drops "That is the whole promotion." next to a bare pull');
}

done_testing();
