#!/usr/bin/env perl
# platform: any
# statusline.pl's two host probes: the background `git fetch` throttle and the
# terminal width.
#
# FETCH. The staleness check read "$workspace/.git/FETCH_HEAD" literally. In a
# linked worktree (.git is a file) or from a subdirectory that path never
# exists, so every render there spawned another fetch. The paths now come
# from `git rev-parse --git-path`, and a stamp in the git dir, written before
# each spawn, throttles attempts where FETCH_HEAD cannot (it is unwritable, or
# the spawned fetch has not reached git yet).
#
# WIDTH. Claude Code runs the statusline with stdout on a pipe, where `tput
# cols` answers from terminfo, not the terminal: 80 on macOS whatever the
# window. Off Windows $COLUMNS now wins, then the controlling terminal, then
# tput. (The /dev/tty step needs a real terminal and is not exercised here;
# every spawn below has none.)
#
# A logging `git` shim in front of the real one counts fetches; the real git
# does everything else, against throwaway repos.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use Time::HiRes ();

# macOS ships no `timeout`; same fallback as the other statusline tests.
unless (grep { -x "$_/timeout" } split /:/, ($ENV{PATH} // q{})) {
    $ENV{PATH} = "$Bin/../../../../scripts/test-bin:" . ($ENV{PATH} // q{})
        if -x "$Bin/../../../../scripts/test-bin/timeout";
}
delete $ENV{COLUMNS};

my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl";
ok(-f $STATUSLINE, 'statusline.pl exists') or BAIL_OUT('statusline.pl missing');

my $IS_WIN = $^O =~ /^(MSWin32|cygwin|msys)$/;
my ($REAL_GIT) = grep { -x $_ } map { "$_/git" } split /:/, $ENV{PATH};
plan skip_all => 'no git on PATH' unless defined $REAL_GIT;

my $T    = tempdir(CLEANUP => 1);
my $SHIM = "$T/shim";
my $LOG  = "$T/git.log";
make_path($SHIM);
{
    open my $fh, '>', "$SHIM/git" or die $!;
    print {$fh} "#!/bin/sh\nfor a in \"\$@\"; do [ \"\$a\" = fetch ] && echo fetch >> '$LOG'; done\nexec '$REAL_GIT' \"\$@\"\n";
    close $fh;
    chmod 0755, "$SHIM/git";
    open $fh, '>', "$SHIM/tput" or die $!;
    print {$fh} "#!/bin/sh\necho 77\n";
    close $fh;
    chmod 0755, "$SHIM/tput";
    # No usable controlling terminal in this test; make that explicit so a
    # run from an interactive shell is not decided by the real window size.
    open $fh, '>', "$SHIM/stty" or die $!;
    print {$fh} "#!/bin/sh\nexit 1\n";
    close $fh;
    chmod 0755, "$SHIM/stty";
}

my %GITENV = (
    GIT_CONFIG_GLOBAL => "$T/gitconfig", GIT_CONFIG_NOSYSTEM => 1, GIT_TERMINAL_PROMPT => 0,
    GIT_AUTHOR_NAME => 'SL', GIT_AUTHOR_EMAIL => 'sl@example.invalid',
    GIT_COMMITTER_NAME => 'SL', GIT_COMMITTER_EMAIL => 'sl@example.invalid',
);
{ open my $fh, '>', $GITENV{GIT_CONFIG_GLOBAL} or die $!; close $fh; }
sub git {
    local @ENV{ keys %GITENV } = values %GITENV;
    system($REAL_GIT, @_) == 0 or die "git @_ failed";
}

sub render {
    my ($dir, %env) = @_;
    my ($fh, $in) = tempfile(DIR => $T);
    print {$fh} encode_json({
        model => { display_name => 'Claude Sonnet 5', id => 'claude-sonnet-5' },
        workspace => { current_dir => $dir },
        context_window => { used_percentage => 10, context_window_size => 200_000 },
    });
    close $fh;
    local %ENV = %ENV;
    @ENV{ keys %GITENV } = values %GITENV;
    $ENV{PATH} = "$SHIM:$ENV{PATH}";
    $ENV{HOME} = $ENV{USERPROFILE} = "$T/home";
    $ENV{CCPRAXIS_DATA_DIR} = "$T/data";
    for my $k (keys %env) { if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} } }
    my $out = `timeout 20 "$^X" "$STATUSLINE" < "$in" 2>/dev/null`;
    return $out // '';
}
sub fetches {
    # the fetch child is detached: give it a moment to log
    my $deadline = Time::HiRes::time() + 3;
    my $n = 0;
    while (1) {
        $n = 0;
        if (open my $fh, '<', $LOG) { $n++ while <$fh>; close $fh; }
        last if $n > 0 || Time::HiRes::time() > $deadline;
        Time::HiRes::sleep(0.1);
    }
    return $n;
}
sub reset_log { unlink $LOG; }
sub vis_len { my ($l) = @_; $l =~ s/\033\[[^m]*m//g; utf8::decode($l); return length $l; }

# A repo whose FETCH_HEAD cannot be written. git truncates FETCH_HEAD at the
# start of every fetch, even one that then fails, so FETCH_HEAD alone throttles
# a normal repo; it cannot when the file is unwritable (here: a directory in
# its place), and it does not cover the gap between a render spawning a fetch
# and that fetch reaching git. The stamp, written before the spawn, covers both.
my $repo = "$T/repo";
make_path("$repo/sub/dir");
git('init', '-q', $repo);
git('-C', $repo, 'commit', '-q', '--allow-empty', '-m', 'seed');
git('-C', $repo, 'remote', 'add', 'origin', "$T/no-such-remote.git");
make_path("$repo/.git/FETCH_HEAD");

# ---------------------------------------------------------------------------
# fetch throttle
# ---------------------------------------------------------------------------
reset_log();
render($repo);
is(fetches(), 1, 'first render of a never-fetched repo starts one background fetch');
ok(-e "$repo/.git/ccpraxis-statusline-fetch", 'the attempt left its throttle stamp in the git dir');
is(`"$REAL_GIT" -C "$repo" status --porcelain`, '', 'the stamp is invisible to git status');

reset_log();
render($repo);
render("$repo/sub/dir");
Time::HiRes::sleep(0.5);
is(fetches(), 0, 'with FETCH_HEAD unwritable, the stamp alone stops a retry on the next renders (root and a subdirectory)');

# an old stamp and no usable FETCH_HEAD -> stale again
utime(time - 3600, time - 3600, "$repo/.git/ccpraxis-statusline-fetch");
reset_log();
render("$repo/sub/dir");
is(fetches(), 1, 'once the stamp is 30 minutes old, a render from a subdirectory fetches again');

# a subdirectory of a repo whose FETCH_HEAD IS fresh: the old literal
# "$workspace/.git/FETCH_HEAD" did not exist below the root, so every render
# from a subdirectory fetched.
my $repo2 = "$T/repo2";
make_path("$repo2/sub");
git('init', '-q', $repo2);
git('-C', $repo2, 'commit', '-q', '--allow-empty', '-m', 'seed');
{ open my $fh, '>', "$repo2/.git/FETCH_HEAD" or die $!; close $fh; }
reset_log();
render("$repo2/sub");
Time::HiRes::sleep(0.5);
is(fetches(), 0, 'a render from a subdirectory finds the root FETCH_HEAD and does not fetch');

# a linked worktree: .git is a FILE; a fresh FETCH_HEAD in the worktree's own
# git dir must be found.
my $wt = "$T/wt";
git('-C', $repo, 'worktree', 'add', '-q', $wt);
my $wt_gitdir = `"$REAL_GIT" -C "$wt" rev-parse --git-path FETCH_HEAD`;
chomp $wt_gitdir;
$wt_gitdir = "$wt/$wt_gitdir" unless $wt_gitdir =~ m{^/};
{ open my $fh, '>', $wt_gitdir or die "$wt_gitdir: $!"; close $fh; }
ok(-f "$wt/.git", '(setup) the worktree has a .git FILE');
reset_log();
render($wt);
Time::HiRes::sleep(0.5);
is(fetches(), 0, 'a linked worktree with a fresh FETCH_HEAD does not fetch (the literal .git/FETCH_HEAD path never existed there)');

# ---------------------------------------------------------------------------
# width
# ---------------------------------------------------------------------------
my $long = "$T/" . ('x' x 150);
make_path($long);
SKIP: {
    skip 'COLUMNS/tty probing is off-Windows only; Windows keeps tput', 3 if $IS_WIN;
    my ($l40)  = split /\n/, render($long, COLUMNS => 40);
    ok(vis_len($l40) <= 40, 'COLUMNS=40 wins over tput (77): row 1 fits 40 columns') or diag("len " . vis_len($l40));
    my ($l200) = split /\n/, render($long, COLUMNS => 200);
    ok(vis_len($l200) > 77, 'COLUMNS=200: row 1 uses more than the 77 tput reports') or diag("len " . vis_len($l200));
    my ($lbad) = split /\n/, render($long, COLUMNS => 'wide');
    ok(vis_len($lbad) <= 77 && vis_len($lbad) > 40, 'a non-numeric COLUMNS is ignored and tput (77) decides');
}
my ($ltput) = split /\n/, render($long, COLUMNS => undef);
ok(vis_len($ltput) <= 77, 'with no COLUMNS and no terminal, tput still decides');

done_testing();
