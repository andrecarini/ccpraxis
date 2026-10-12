#!/usr/bin/env perl
# platform: windows
# Oracle for blueprint tooling-backlog, package
# 09-promote-dry-run-merge-tree-preview (scripts/promote.pl). Derived ONLY
# from .ccpraxis-local-data/blueprints/tooling-backlog/specs/
# 09-promote-dry-run-merge-tree-preview-spec.md (AC-1..AC-8). scripts/
# promote.pl is NOT read while writing this file beyond the exact strings
# the spec itself quotes verbatim (section 2.2's caveat text, and the
# existing report-line prefixes already pinned by promote-syncs-global-
# config.t). AC-1, AC-2 and AC-4 exercise the caveat line (the is_ancestor
# + caveat fix, M1) and are expected to PASS against the current,
# already-fixed promote.pl: a caveat line now accompanies the settings
# preview instead of the bare, misleading "removed timeFormat" line.
#
# Fixture helpers below are copied verbatim (per spec S4 instructions) from
# promote-syncs-global-config.t's house pattern: tempdir root via
# HostCaps::tempdir_args() + CLEANUP => 1, hermetic env_git() (own
# GIT_CONFIG_GLOBAL, GIT_CONFIG_NOSYSTEM=1, explicit author/committer),
# `git -c core.autocrlf=false`, clone_extra_commit()/live_extra_commit(),
# _spawn() with stderr captured through a real File::Temp file (never an
# in-memory scalar reopen), and run_promote() which always passes explicit
# --clone/--live/--home. No path under the real ~/.claude is ever read or
# written; no test here calls promote.pl without all three flags.
#
# AC -> block mapping (grep "AC-<n>:" for every assertion of a criterion):
#   AC-1  TF fixture dry-run: would-merge + exactly one correct caveat line
#   AC-2  caveat line ordered directly under settings:, before removed/updated
#   AC-3  that same run writes nothing (home/live byte-unchanged, no backups)
#   AC-4  live-ahead (up-to-date) fixture still gets the caveat
#   AC-5  no-live-only fixture: no caveat line at all
#   AC-6  apply (non-dry-run) on the TF fixture: no caveat, no false "removed"
#   AC-7  sibling promote suites stay green (regression, run as subprocesses)
#   AC-8  is a review check per the spec, not encoded as an assertion here
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Temp qw(tempdir tempfile);
use JSON::PP;

my $ROOT    = "$Bin/../../../..";
my $PROMOTE = "$ROOT/scripts/promote.pl";

plan skip_all => "scripts/promote.pl not found at $PROMOTE" unless -f $PROMOTE;

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

sub short7 {
    my ($sha) = @_;
    return substr($sha, 0, 7);
}

# ---------------------------------------------------------------------------
# fixture builder -- copied verbatim (house pattern) from
# promote-syncs-global-config.t's new_fixture, clone_extra_commit,
# live_extra_commit.
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

    my $live = "$home/.claude/ccpraxis";
    git_clone($f, $clone, $live) or die "git clone into live fixture failed";
    $f->{live} = $live;
    for my $c (@{ $opts{live_commits} // [] }) {
        my ($files, $msg) = @$c;
        for my $rel (sort keys %$files) { write_bytes("$live/$rel", $files->{$rel}); }
        git_run($f, $live, 'add', '-A');
        git_run($f, $live, 'commit', '-q', '-m', $msg);
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

sub canon_json {
    my ($data) = @_;
    return JSON::PP->new->canonical->utf8->encode($data);
}

# ---------------------------------------------------------------------------
# Canonical "TF fixture" (spec S4): clone seed has settings.json without
# timeFormat; live gets its own commit adding timeFormat; clone gets its own
# commit touching a different file (notes.txt, conflict-free); home
# settings.json already holds the live-commit content (as a real install
# would, since it was synced by a prior promote).
# ---------------------------------------------------------------------------
sub make_tf_fixture {
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json({ model => 'opus' }) }, 'settings seed' ],
    ]);
    live_extra_commit($f, { 'global-config/settings.json' => canon_json({ model => 'opus', timeFormat => '24h' }) },
        'live-only: add timeFormat');
    clone_extra_commit($f, { 'notes.txt' => "clone-only change\n" }, 'clone-only: notes.txt');
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ model => 'opus', timeFormat => '24h' }));
    return $f;
}

# ===========================================================================
# AC-1: diverged TF fixture, --dry-run. Exit 0, merge: would-merge, and
# exactly one caveat line with the correct <L7>/<C7> short SHAs. Expected to
# PASS against the current, already-fixed promote.pl: the caveat line now
# accompanies the settings preview.
# ===========================================================================
{
    my $f = make_tf_fixture();
    my $live_head  = head_sha($f, $f->{live});
    my $clone_main = head_sha($f, $f->{clone});
    my $l7 = short7($live_head);
    my $c7 = short7($clone_main);

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-1: TF fixture dry-run exits 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: would-merge/m, 'AC-1: report says merge: would-merge') or diag($r->{out});

    my $qre = qr/^  caveat: preview ignores live-only commits -- live HEAD \Q$l7\E has commits clone main \Q$c7\E lacks;/m;
    my @hits = ($r->{out} =~ /$qre/mg);
    is(scalar(@hits), 1, "AC-1: exactly one caveat line naming live HEAD $l7 / clone main $c7")
        or diag("expected pattern: $qre\ngot output:\n" . $r->{out});
}

# ===========================================================================
# AC-2: on the same TF-fixture dry-run, the caveat line's index is exactly
# (index of the settings: line) + 1, and any removed/updated line comes
# strictly after it. Expected to PASS against the current, already-fixed
# promote.pl.
# ===========================================================================
{
    my $f = make_tf_fixture();
    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-2: TF fixture dry-run exits 0') or diag($r->{out} . $r->{err});

    my @lines = split /\n/, $r->{out};
    my ($settings_idx) = grep { $lines[$_] =~ /^settings:/ } 0 .. $#lines;
    ok(defined $settings_idx, 'AC-2: a settings: line is present') or diag($r->{out});

  SKIP: {
        skip 'AC-2: no settings: line to anchor on', 3 unless defined $settings_idx;
        my ($caveat_idx) = grep { $lines[$_] =~ /^  caveat: preview ignores live-only commits/ } 0 .. $#lines;
        ok(defined $caveat_idx, 'AC-2: a caveat line is present') or diag($r->{out});
        is($caveat_idx, $settings_idx + 1, 'AC-2: caveat line sits immediately under settings:')
            if defined $caveat_idx;

        like($r->{out}, qr/^  removed timeFormat$/m,
            'AC-2: a removed timeFormat line is present (so the ordering check below is not vacuous)')
            or diag($r->{out});

        my @removed_or_updated_idx = grep { $lines[$_] =~ /^  (removed|updated) / } 0 .. $#lines;
        if (defined $caveat_idx) {
            my @too_early = grep { $_ <= $caveat_idx } @removed_or_updated_idx;
            is(scalar(@too_early), 0, 'AC-2: every removed/updated line comes after the caveat line')
                or diag($r->{out});
        }
    }
}

# ===========================================================================
# AC-3: the same TF-fixture dry-run writes nothing: home settings.json byte-
# unchanged, live HEAD unchanged, live git status clean, no .promotion-
# backups directory. Regression guard -- true both before and after the fix.
# ===========================================================================
{
    my $f = make_tf_fixture();
    my $pre_head     = head_sha($f, $f->{live});
    my $pre_settings = read_bytes("$f->{home}/.claude/settings.json");

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-3: TF fixture dry-run exits 0') or diag($r->{out} . $r->{err});

    my $post_settings = read_bytes("$f->{home}/.claude/settings.json");
    ok(defined $post_settings && $post_settings eq $pre_settings, 'AC-3: home settings.json byte-unchanged');
    is(head_sha($f, $f->{live}), $pre_head, 'AC-3: live HEAD is unchanged');
    is(status_porcelain($f, $f->{live}), '', 'AC-3: live git status is clean');
    ok(!-d "$f->{home}/.claude/.promotion-backups", 'AC-3: no .promotion-backups directory was created');
}

# ===========================================================================
# AC-4: live-ahead, clone-behind (up-to-date case). Clone seed + the same
# live-only commit, but NO clone-only commit -- clone main is an ancestor of
# live HEAD. --dry-run prints merge: up-to-date AND the caveat line.
# Expected to PASS against the current, already-fixed promote.pl.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json({ model => 'opus' }) }, 'settings seed' ],
    ]);
    live_extra_commit($f, { 'global-config/settings.json' => canon_json({ model => 'opus', timeFormat => '24h' }) },
        'live-only: add timeFormat');
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ model => 'opus', timeFormat => '24h' }));

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-4: live-ahead dry-run exits 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: up-to-date/m, 'AC-4: report says merge: up-to-date') or diag($r->{out});
    like($r->{out}, qr/^  caveat: preview ignores live-only commits --/m,
        'AC-4: the caveat line is present even in the up-to-date case') or diag($r->{out});
}

# ===========================================================================
# AC-5: no-live-only fixture (clone seed + a clone-only commit, no live-only
# commit at all). --dry-run prints no caveat line. Regression guard.
# ===========================================================================
{
    my $f = new_fixture(clone_commits => [
        [ { 'global-config/settings.json' => canon_json({ model => 'opus' }) }, 'settings seed' ],
    ]);
    clone_extra_commit($f, { 'notes.txt' => "clone-only change\n" }, 'clone-only: notes.txt');
    write_bytes("$f->{home}/.claude/settings.json", canon_json({ model => 'opus' }));

    my $r = run_promote($f, '--dry-run');
    is($r->{exit}, 0, 'AC-5: no-live-only dry-run exits 0') or diag($r->{out} . $r->{err});
    unlike($r->{out}, qr/^  caveat: /m, 'AC-5: no caveat line appears when live has no commits clone main lacks')
        or diag($r->{out});
}

# ===========================================================================
# AC-6: fresh TF fixture, apply (no --dry-run). Exit 0, merge: merged
# present, no false "removed timeFormat" line, no caveat line ever (apply
# path is untouched), and home settings.json's timeFormat stays "24h".
# Regression guard -- true both before and after the fix.
# ===========================================================================
{
    my $f = make_tf_fixture();
    my $r = run_promote($f);
    is($r->{exit}, 0, 'AC-6: TF fixture apply exits 0') or diag($r->{out} . $r->{err});
    like($r->{out}, qr/^merge: merged /m, 'AC-6: report says merge: merged') or diag($r->{out});
    unlike($r->{out}, qr/^  removed timeFormat/m, 'AC-6: no false "removed timeFormat" line under apply')
        or diag($r->{out});
    unlike($r->{out}, qr/^  caveat: /m, 'AC-6: apply never prints a caveat line') or diag($r->{out});

    my $bytes = read_bytes("$f->{home}/.claude/settings.json");
    my $decoded = eval { decode_json($bytes) };
    ok(ref($decoded) eq 'HASH', 'AC-6: home settings.json parses as an object after apply') or diag($bytes // 'undef');
    is($decoded->{timeFormat}, '24h', 'AC-6: home settings.json timeFormat stays "24h" after apply')
        if ref($decoded) eq 'HASH';
}

# AC-7 (the sibling promote suites stay green) is NOT asserted here by running
# them: a test never spawns a sibling .t as a "stays green" floor (Decision 11,
# tests-never-run-tests.t). promote-syncs-global-config.t,
# promote-drops-retired-keys.t and promote-array-merge.t run on their own in
# every sweep; running them again from here only doubled their cost and made
# this file's red mean "some other file is red".

done_testing();
